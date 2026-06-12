const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const FileWatcher = struct {
    notify_fd: i32,
    watched_files: std.ArrayList(WatchedFile),
    allocator: Allocator,

    pub const WatchedFile = struct {
        path: []const u8,
        wd: i32,
    };

    /// Events to watch in the files
    pub const EVENTS =
        linux.IN.DELETE |
        linux.IN.MODIFY |
        linux.IN.MOVE |
        linux.IN.CREATE;

    pub fn init(allocator: Allocator, extra_paths: ?[]const [:0]const u8) !FileWatcher {
        const ino_fd: i32 = @intCast(linux.inotify_init1(linux.IN.NONBLOCK));
        if (linux.errno(@intCast(ino_fd)) != .SUCCESS) return error.InotifyCreateFailed;

        // Initially we just register the base files or directories that are provided to
        // the file watcher. Later we will recurse each of them and register their
        // subtrees if possible.
        const watched_files: std.ArrayList(WatchedFile) = blk: {
            if (extra_paths) |paths| {
                var tmp: std.ArrayList(WatchedFile) = try .initCapacity(allocator, paths.len);
                for (paths) |p| {
                    const new_p = try allocator.dupe(u8, p);
                    const wd = try addFileWatch(ino_fd, p);
                    tmp.appendAssumeCapacity(.{
                        .wd = wd,
                        .path = new_p,
                    });
                }
                break :blk tmp;
            } else {
                var tmp: std.ArrayList(WatchedFile) = .empty;
                const default_dir = try allocator.dupeZ(u8, "."); // just to make deinit easier
                const wd = try addFileWatch(ino_fd, default_dir);
                try tmp.append(allocator, .{
                    .path = default_dir,
                    .wd = wd,
                });
                break :blk tmp;
            }
        };

        return .{
            .allocator = allocator,
            .notify_fd = ino_fd,
            .watched_files = watched_files,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        std.debug.assert(linux.close(self.notify_fd) == 0);

        for (self.watched_files.items) |watched| {
            std.debug.assert(linux.close(watched.wd) == 0);
            self.allocator.free(watched.path);
        }
        self.watched_files.deinit(self.allocator);
    }

    /// Loops forever and processes all the events from the
    /// inotify file descriptor.
    pub fn watch(self: *FileWatcher, io: Io) !void {
        // must be done as close as posible to the moment of polling the events,
        // to minimize race conditions and missing events
        try self.registerSubTrees(io);

        // we only poll ino
        var poll_fds = [1]linux.pollfd{
            .{
                .fd = self.notify_fd,
                .events = linux.POLL.IN,
                .revents = 0,
            },
        };

        // trick to wrap the raw fd into a file like
        // structure so we can reuse its std.Io.Reader vtable
        var ino_file = std.Io.File{
            .handle = self.notify_fd,
            .flags = .{ .nonblocking = true },
        };

        var inotify_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var reader = ino_file.reader(io, &inotify_buf);
        const ino_reader = &reader.interface;

        while (true) {
            const poll_num: i32 = @intCast(linux.poll(poll_fds[0..].ptr, poll_fds.len, -1));
            if (poll_num == -1) {
                @panic("poll failed");
            }

            if (poll_fds[0].revents & linux.POLL.IN != 0) {
                self.consumeEvents(ino_reader) catch |err| switch (err) {
                    error.ReadFailed => if (reader.err) |read_err| switch (read_err) {
                        error.WouldBlock => continue,
                        else => |e| return e,
                    },
                    else => |e| return e,
                };
            }
        }
    }

    /// Helper to add files to a inotify descriptor
    fn addFileWatch(notify_fd: i32, path: [*:0]const u8) !i32 {
        const watch_fd: i32 = @intCast(linux.inotify_add_watch(notify_fd, path, EVENTS));
        return if (watch_fd == -1)
            error.InotifyAddFailed
        else
            watch_fd;
    }

    /// Register all subdirectories of the initial watched files.
    /// This is necesary because inotify watches are not recursive
    /// in case of directories. So we must walk all of them and
    /// add the watches.
    fn registerSubTrees(self: *FileWatcher, io: Io) !void {
        for (self.watched_files.items) |watched| {
            const stat = try Io.Dir.cwd().statFile(io, watched.path, .{});

            if (stat.kind == .directory) {
                var dir = try Io.Dir.cwd().openDir(io, watched.path, .{ .iterate = true });
                defer dir.close(io);

                var iter = try dir.walk(self.allocator);
                defer iter.deinit();

                while (try iter.next(io)) |entry| {
                    if (entry.kind == .directory) {
                        const entry_path = try self.allocator.dupe(u8, entry.path);
                        const wd = try addFileWatch(self.notify_fd, entry.path);

                        try self.watched_files.append(self.allocator, .{
                            .path = entry_path,
                            .wd = wd,
                        });
                    }
                }
            }
        }
    }

    fn consumeEvents(self: *FileWatcher, inotify_reader: *std.Io.Reader) !void {
        while (inotify_reader.take(@sizeOf(linux.inotify_event))) |bytes| {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(bytes.ptr));

            if (event.mask & linux.IN.DELETE != 0) {
                std.debug.print("deleted ", .{});
            } else if (event.mask & linux.IN.MODIFY != 0) {
                std.debug.print("written ", .{});
            } else if (event.mask & linux.IN.CREATE != 0) {
                std.debug.print("created ", .{});
            } else if (event.mask & linux.IN.MOVED_FROM != 0) {
                std.debug.print("moved ", .{});
            } else if (event.mask & linux.IN.MOVED_TO != 0) {
                std.debug.print("to ", .{});
            }

            // read name if present, advancing the seek position
            if (event.len > 0) {
                const name = try inotify_reader.take(event.len);
                std.debug.print("'{s}' ", .{name});
            }

            // Skip curent MOVED_FROM iteration so we can print the
            // MOVED_TO afterwards without polluting the output
            if (event.mask & linux.IN.MOVED_FROM != 0) {
                continue;
            }

            for (self.watched_files.items) |file| {
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
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const paths = if (args.len <= 1) null else args;
    var watcher: FileWatcher = try .init(init.gpa, paths);
    defer watcher.deinit();
    try watcher.watch(init.io);
}
