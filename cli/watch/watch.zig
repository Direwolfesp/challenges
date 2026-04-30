const std = @import("std");
const linux = std.os.linux;

const WatchedFile = struct {
    path: []const u8,
    wd: i32,
};

/// Events to watch in the files
const EVENTS =
    linux.IN.DELETE |
    linux.IN.MODIFY |
    linux.IN.CREATE;

/// Helper to add files to a inotify descriptor
fn addFileWatch(notify: i32, path: [*:0]const u8) !i32 {
    const watch_fd: i32 = @intCast(linux.inotify_add_watch(notify, path, EVENTS));
    return if (watch_fd == -1)
        error.InotifyAddFailed
    else
        watch_fd;
}

pub fn main() !void {
    var alloc: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();

    const args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, args);

    const ino_fd: i32 = @intCast(linux.inotify_init1(linux.IN.NONBLOCK));
    if (ino_fd == -1) {
        std.process.fatal("inotify failed", .{});
    }
    defer _ = linux.close(ino_fd);

    var watched_files = try std.ArrayList(WatchedFile).initCapacity(arena, args.len);
    defer {
        for (watched_files.items) |f| {
            std.debug.assert(linux.close(f.wd) == 0);
        }
        watched_files.deinit(arena);
    }

    // default to cwd if no params
    if (args.len <= 1) {
        const cwd = try std.process.getCwdAlloc(arena);
        const nulled = try arena.dupeZ(u8, cwd); // leak
        const watch_fd: i32 = try addFileWatch(ino_fd, nulled);
        try watched_files.append(arena, .{
            .path = cwd,
            .wd = watch_fd,
        });
    } else {
        // add all args to watched files
        for (args[1..]) |arg| {
            const watch_fd: i32 = try addFileWatch(ino_fd, arg);
            try watched_files.append(arena, .{
                .path = arg,
                .wd = watch_fd,
            });
        }
    }

    for (watched_files.items) |f| {
        std.debug.print("Watching: '{s}'\n", .{f.path});
    }

    // we only poll ino
    var poll_fds = [1]linux.pollfd{
        .{
            .fd = ino_fd,
            .events = linux.POLL.IN,
            .revents = 0,
        },
    };

    // trick to wrap the raw fd into a file like
    // structure so i can reuse its std.Io.Reader
    // vtable.
    var ino_file = std.fs.File{
        .handle = ino_fd,
    };

    var inotify_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    var reader = ino_file.reader(&inotify_buf);
    const ino_reader = &reader.interface;

    while (true) {
        const poll_num: i32 = @intCast(linux.poll(poll_fds[0..].ptr, poll_fds.len, -1));
        if (poll_num == -1) {
            @panic("poll failed");
        }

        if (poll_fds[0].revents & linux.POLL.IN != 0) {
            consumeEvents(ino_reader, &watched_files) catch |err| switch (err) {
                error.ReadFailed => if (reader.err) |read_err| switch (read_err) {
                    error.WouldBlock => continue,
                    else => |e| return e,
                },
                else => |e| return e,
            };
        }
    }
}

fn consumeEvents(
    inotify_reader: *std.Io.Reader,
    files: *const std.ArrayList(WatchedFile),
) !void {
    while (inotify_reader.take(@sizeOf(linux.inotify_event))) |bytes| {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(bytes.ptr));

        if (event.mask & linux.IN.DELETE != 0) {
            std.debug.print("deleted ", .{});
        }
        if (event.mask & linux.IN.MODIFY != 0) {
            std.debug.print("written ", .{});
        }
        if (event.mask & linux.IN.CREATE != 0) {
            std.debug.print("created ", .{});
        }

        // read name if present, advancing the seek position
        if (event.len > 0) {
            const name = try inotify_reader.take(event.len);
            std.debug.print("'{s}' ", .{name});
        }

        for (files.items) |file| {
            if (file.wd == event.wd) {
                std.debug.print("in {s} ", .{file.path});
                break;
            }
        }

        if (event.mask & linux.IN.ISDIR != 0) {
            std.debug.print("[directory]", .{});
        } else {
            std.debug.print("[file]", .{});
        }

        std.debug.print("\n", .{});
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
}
