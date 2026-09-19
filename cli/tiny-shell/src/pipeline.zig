const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Child = std.process.Child;
const StdIo = std.process.SpawnOptions.StdIo;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    try pipeline(io, gpa, &.{
        .{
            .args = &.{ "cat", "/etc/passwd" },
            .redirect = .{ .stdout = true },
        },
        .{
            .args = &.{ "wc", "-l" },
            .redirect = .{ .stdout = true },
        },
        .{
            .args = &.{"wc"},
            .redirect = .{ .stdout = true },
        },
    });
}

pub const Pipe = struct {
    read_end: Io.File,
    write_end: Io.File,

    /// reader process sucking from him
    reader: ?Child.Id = null,
    /// writer process pumping to him
    writer: ?Child.Id = null,

    pub const PipeError = error{
        SystemFdQuotaExceeded,
        ProcessFdQuotaExceeded,
        Unexpected,
    };

    pub fn init() !Pipe {
        var fds: [2]i32 = undefined;
        return switch (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
            .SUCCESS => .{
                .read_end = .{
                    .handle = fds[0],
                    .flags = .{ .nonblocking = false },
                },
                .write_end = .{
                    .handle = fds[1],
                    .flags = .{ .nonblocking = false },
                },
            },
            .NFILE => error.SystemFdQuotaExceeded,
            .MFILE => error.ProcessFdQuotaExceeded,
            else => error.Unexpected,
        };
    }

    /// Idempotent
    pub fn deinit(self: *Pipe) void {
        if (self.read_end.handle != -1) _ = linux.close(self.read_end.handle);
        if (self.read_end.handle != self.write_end.handle) _ = linux.close(self.write_end.handle);
    }
};

pub const Command = struct {
    args: []const []const u8,
    redirect: Streams,

    pub const Streams = packed struct {
        stdout: bool = true,
        stderr: bool = false,
    };

    pub fn format(self: Command, out: *Io.Writer) Io.Writer.Error!void {
        const tty = Io.Terminal{ .writer = out, .mode = .escape_codes };
        tty.setColor(.bold) catch return Io.Writer.Error.WriteFailed;
        tty.setColor(.bright_cyan) catch return Io.Writer.Error.WriteFailed;
        defer tty.setColor(.reset) catch {};

        for (self.args, 0..) |arg, i| {
            if (std.mem.findAny(u8, arg, &std.ascii.whitespace)) |_| {
                try out.print("'{s}'", .{arg});
            } else if (arg.len == 0) {
                try out.print("''", .{});
            } else {
                try out.print("{s}", .{arg});
            }

            if (i != self.args.len - 1) {
                try out.writeByte(' ');
            }
        }
    }
};

/// Dummy struct for now, only for printing
const Pipeline = struct {
    commands: []const Command,

    pub fn init(commands: []const Command) Pipeline {
        return .{ .commands = commands };
    }

    pub fn format(self: Pipeline, out: *Io.Writer) Io.Writer.Error!void {
        const tty = Io.Terminal{ .writer = out, .mode = .escape_codes };
        defer tty.setColor(.reset) catch {};

        for (self.commands, 0..) |command, i| {
            try tty.writer.print("{f}", .{command});
            if (i != self.commands.len -| 1) {
                tty.setColor(.magenta) catch return Io.Writer.Error.WriteFailed;
                try tty.writer.writeAll(" | ");
                tty.setColor(.reset) catch return Io.Writer.Error.WriteFailed;
            }
        }
    }
};

pub fn pipeline(io: Io, arena: Allocator, commands: []const Command) !void {
    const n_pipes = commands.len -| 1;
    std.log.info("Executing pipeline: {f}", .{Pipeline.init(commands)});

    var pipes: std.ArrayList(Pipe) = try .initCapacity(arena, n_pipes);
    defer {
        for (pipes.items) |*pipe| pipe.deinit();
        pipes.deinit(arena);
    }

    for (0..n_pipes) |_| {
        const pipe: Pipe = try .init();
        pipes.appendAssumeCapacity(pipe);
    }

    var children: std.ArrayList(Child) = try .initCapacity(arena, commands.len);
    defer children.deinit(arena);

    for (commands, 0..) |command, i| {
        const is_unique = commands.len == 1;
        const is_first = i == 0 and !is_unique;
        const is_last = i == commands.len - 1 and !is_first;
        const is_mid = !is_last;

        const child = blk: {
            if (is_unique) {
                const child = try std.process.spawn(io, .{ .argv = command.args });
                std.log.debug("Spawned unique one: {s} 'id={?}'", .{ command.args[0], child.id });
                break :blk child;
            } else if (is_first) {
                std.debug.assert(i == 0);
                const pipe = &pipes.items[i];
                const stdout: StdIo = if (command.redirect.stdout) .{ .file = pipe.write_end } else .inherit;
                const stderr: StdIo = if (command.redirect.stderr) .{ .file = pipe.write_end } else .inherit;
                const child = try std.process.spawn(io, .{
                    .argv = command.args,
                    .stdout = stdout,
                    .stderr = stderr,
                });
                pipe.writer = child.id;
                std.log.debug("Spawned first one: {s} 'id={?}'", .{ command.args[0], child.id });
                break :blk child;
            } else if (is_mid) {
                const pipe_source = &pipes.items[i - 1];
                const pipe_sink = &pipes.items[i];

                const stdin: StdIo = .{ .file = pipe_source.read_end };
                const stdout: StdIo = if (command.redirect.stdout) .{ .file = pipe_sink.write_end } else .inherit;
                const stderr: StdIo = if (command.redirect.stderr) .{ .file = pipe_sink.write_end } else .inherit;
                const child = try std.process.spawn(io, .{
                    .argv = command.args,
                    .stdin = stdin,
                    .stdout = stdout,
                    .stderr = stderr,
                });
                pipe_sink.writer = child.id;
                pipe_source.reader = child.id;
                std.log.debug("Spawned middle one: {s} 'id={?}'", .{ command.args[0], child.id });
                break :blk child;
            } else if (is_last) {
                const pipe = &pipes.items[i - 1];
                const stdin: StdIo = .{ .file = pipe.read_end };
                const child = try std.process.spawn(io, .{
                    .argv = command.args,
                    .stdin = stdin,
                });
                pipe.reader = child.id;
                std.log.debug("Spawned last one: {s} 'id={?}'", .{ command.args[0], child.id });
                break :blk child;
            } else unreachable;
        };

        children.appendAssumeCapacity(child);
    }

    // collect child results
    for (children.items, 0..) |*child, i| {
        const pid = child.id.?;
        const name = commands[i].args[0];
        std.log.debug("Waiting child: {s} 'id={d}'", .{ name, pid });

        const res = try child.wait(io);

        // Its important to close the corresponding pipes
        // the process was using, so the other end can
        // react to the end of streams.
        for (pipes.items) |*pipe| {
            if (pipe.reader) |reader_pid| if (reader_pid == pid)
                pipe.read_end.close(io);
            if (pipe.writer) |writer_pid| if (writer_pid == pid)
                pipe.write_end.close(io);
        }

        switch (res) {
            .exited => |code| {
                std.log.info("Command ({d}) exited with code {d}", .{ pid, code });
            },
            .signal => |sig| {
                std.log.info("Command ({d}) killed by SIG{t}", .{ pid, sig });
            },
            .stopped => |sig| {
                std.log.info("Command ({d}) stoped by SIG{t}", .{ pid, sig });
            },
            .unknown => |code| {
                std.log.info("Command ({d}) terminated by unknown reasons {d}", .{ pid, code });
            },
        }
    }
}
