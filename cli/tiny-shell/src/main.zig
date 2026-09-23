//! My intention is to directly use the low level linux primitives
//! instead of the std abstractions.
//!
const std = @import("std");
const linux = std.os.linux;

const Pipeline = @import("pipeline.zig").Pipeline;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const prompt = "$ ";
const exit_msg = "bye user!";

const log = std.log.scoped(.shell);

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

        // Parse args and quotes
        var args: std.ArrayList([]const u8) = .empty;
        var start_arg: usize = 0;
        var is_quoted = false;
        for (line, 0..) |char, i| {
            const maybe_word: ?[]const u8 = blk: {
                if (char == '\"') {
                    if (is_quoted) {
                        is_quoted = false;
                        defer start_arg = i + 1;
                        break :blk line[start_arg..i];
                    } else {
                        is_quoted = true;
                        start_arg = i + 1;
                        break :blk null;
                    }
                } else if (!is_quoted and std.ascii.isWhitespace(char)) {
                    defer start_arg = i + 1;
                    break :blk line[start_arg..i];
                } else if (i == line.len - 1) {
                    break :blk line[start_arg..];
                } else {
                    break :blk null;
                }
            };
            if (maybe_word) |word| {
                const path = try std.fs.path.resolve(arena, &.{word});
                try args.append(arena, path);
            }
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

        // Execute pipeline
        // TODO: integrate builtins as part of the pipeline
        var p: Pipeline = try .init(arena, args.items);
        const res = try p.run(io, arena);

        switch (res) {
            .status => |st| switch (st.term) {
                .exited => |exit| {
                    log.info("Command ({d}) exited with code {d}", .{ st.pid, exit });
                },
                .signal => |sig| {
                    log.info("Command ({d}) killed by SIG{t}", .{ st.pid, sig });
                },
                .stopped => |sig| {
                    log.info("Command ({d}) stoped by SIG{t}", .{ st.pid, sig });
                },
                .unknown => |code| {
                    log.info("Command ({d}) terminated by unknown reasons {d}", .{ st.pid, code });
                },
            },
            .error_msg => |err| {
                log.err("{s}", .{err});
            },
        }
    }
}
