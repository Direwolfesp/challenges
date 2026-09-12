//! My intention is to directly use the low level linux primitives
//! instead of the std abstractions.
//!
const std = @import("std");
const linux = std.os.linux;

const prompt = "$ ";
const exit_msg = "bye user!";
const default_PATH = "/usr/local/bin:/bin/:/usr/bin";

fn intHandler(_: linux.SIG) callconv(.c) void {}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var sa: linux.Sigaction = .{
        .flags = 0,
        .handler = .{ .handler = intHandler },
        .mask = linux.sigemptyset(),
    };
    if (linux.errno(linux.sigaction(.INT, &sa, null)) != .SUCCESS) {
        std.log.warn("Failed to register SIGINT handler. C^ may not work", .{});
    }

    var stdin_buf: [512]u8 = undefined;
    while (true) {
        defer _ = init.arena.reset(.retain_capacity);
        std.debug.print("{s}", .{prompt});
        const n = linux.read(linux.STDIN_FILENO, &stdin_buf, stdin_buf.len);

        if (linux.errno(n) != .SUCCESS) {
            switch (linux.errno(n)) {
                .INTR => {
                    std.debug.print("\n", .{});
                    continue;
                },
                else => return error.ReadFailed,
            }
        }

        if (n == 0) break; // EOF

        const line_raw = stdin_buf[0..n];
        const line = std.mem.trim(u8, line_raw, &std.ascii.whitespace);
        if (line.len == 0) continue;

        var args: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);
        while (it.next()) |word| {
            const path = try std.fs.path.resolve(arena, &.{word});
            try args.append(arena, path);
        }

        // basic builtin commands
        if (std.mem.eql(u8, args.items[0], "exit")) {
            std.debug.print("{s}", .{exit_msg});
            break;
        } else if (std.mem.eql(u8, args.items[0], "cd")) {
            const dest = if (args.items.len > 1)
                args.items[1]
            else if (init.environ_map.get("HOME")) |home_dir|
                home_dir
            else
                try std.process.currentPathAlloc(io, arena);
            std.process.setCurrentPath(io, dest) catch |err| {
                std.log.err("cd: '{s}' does not exist ({t})", .{ dest, err });
            };
            continue;
        }

        const pid = linux.fork();

        if (pid == -1) {
            std.log.err("fork error: {t}", .{linux.errno(pid)});
        } else if (pid == 0) { // child
            const argv_buf = try arena.allocSentinel(?[*:0]const u8, args.items.len, null);
            for (args.items, 0..) |arg, i| {
                const arg_sentinel = try arena.dupeSentinel(u8, arg, '\x00');
                argv_buf[i] = arg_sentinel.ptr;
            }
            const command_name = argv_buf[0].?;

            const path = init.environ_map.get("PATH") orelse default_PATH;
            var path_it = std.mem.tokenizeScalar(u8, path, ':');
            while (path_it.next()) |p| {
                var path_buf: [linux.PATH_MAX]u8 = undefined;
                const sep = if (std.mem.endsWith(u8, p, "/")) "" else "/";
                const cmd = try std.fmt.bufPrintSentinel(&path_buf, "{s}{s}{s}", .{ p, sep, command_name }, '\x00');
                _ = linux.execve(cmd, argv_buf, init.minimal.environ.block.slice);
            }
            std.log.err("Cannot execute '{s}': command not found", .{command_name});
            linux.exit(127);
        } else { // parent
            // wait for child
            var status: u32 = 0;
            _ = linux.waitpid(@intCast(pid), &status, 0);
            if (linux.W.IFSIGNALED(status)) {
                const signal = linux.W.TERMSIG(status);
                std.debug.print("Child terminated by a signal {t}\n", .{signal});
            } else if (linux.W.IFEXITED(status)) {}
        }
    }
}
