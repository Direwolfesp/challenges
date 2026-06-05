const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const TreeWalker = struct {
    out: *Io.Writer,
    num_directories: u32 = 0,
    num_files: u32 = 0,

    const inner_symbols = [_][]const u8{ "├── ", "│   " };
    const outer_symbols = [_][]const u8{ "└── ", "    " };

    const Self = @This();

    pub fn init(out: *Io.Writer) Self {
        return .{ .out = out };
    }

    pub fn summary(self: *Self) !void {
        try self.out.print("{d} directories, {d} files\n", .{ self.num_directories, self.num_files });
    }

    fn walkInner(self: *Self, io: Io, alloc: Allocator, directory: []const u8, prefix: []const u8) !void {
        var dir = Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch |err| {
            std.log.err("Could not open {s}: {t}", .{ directory, err });
            return;
        };
        defer dir.close(io);

        var paths: std.ArrayList(Io.Dir.Entry) = .empty;
        defer {
            for (paths.items) |entry| alloc.free(entry.name);
            paths.deinit(alloc);
        }

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            try paths.append(alloc, .{
                .name = try alloc.dupe(u8, entry.name),
                .inode = entry.inode,
                .kind = entry.kind,
            });
        }

        std.mem.sort(Io.Dir.Entry, paths.items, {}, struct {
            pub fn sort(_: void, a: Io.Dir.Entry, b: Io.Dir.Entry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.sort);

        for (paths.items, 0..) |entry, i| {
            const symbols = if (i != paths.items.len - 1)
                TreeWalker.inner_symbols
            else
                TreeWalker.outer_symbols;

            try self.out.print("{s}{s}{s}\n", .{ prefix, symbols[0], entry.name });

            if (entry.kind == .directory) {
                self.num_directories += 1;
                const new_prefix = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, symbols[1] });
                defer alloc.free(new_prefix);
                const new_path = try Io.Dir.path.join(alloc, &[_][]const u8{ directory, entry.name });
                defer alloc.free(new_path);
                try self.walkInner(io, alloc, new_path, new_prefix);
            } else {
                self.num_files += 1;
            }
        }
    }

    pub fn walk(self: *Self, io: Io, alloc: Allocator, directory: []const u8) !void {
        try self.out.print("{s}\n", .{directory});
        try self.walkInner(io, alloc, directory, "");
        try self.out.writeByte('\n');
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = if (builtin.mode == .Debug) init.gpa else std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    const dir_name = if (args.len > 1) args[1] else ".";

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var w: TreeWalker = .init(stdout);
    try w.walk(io, gpa, dir_name);
    try w.summary();
    try stdout.flush();
}
