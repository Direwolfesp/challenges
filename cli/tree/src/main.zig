const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const clap = @import("clap");

const log = std.log.scoped(.tree);

pub const TreeWalker = struct {
    out: *Io.Writer,
    num_directories: u32 = 0,
    num_files: u32 = 0,
    show_all: bool = false,

    const inner_symbols = [_][]const u8{ "├── ", "│   " };
    const outer_symbols = [_][]const u8{ "└── ", "    " };

    const WalkError = Io.Writer.Error || Io.Dir.OpenError || Allocator.Error;

    pub fn init(out: *Io.Writer, show_all: bool) TreeWalker {
        return .{ .out = out, .show_all = show_all };
    }

    pub fn summary(self: *TreeWalker) !void {
        try self.out.print("{d} directories, {d} files\n", .{ self.num_directories, self.num_files });
    }

    fn walkInner(self: *TreeWalker, io: Io, alloc: Allocator, dir: Io.Dir, prefix: []const u8) WalkError!void {
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
            if (!self.show_all and entry.name[0] == '.')
                continue;

            const symbols = if (i != paths.items.len - 1)
                TreeWalker.inner_symbols
            else
                TreeWalker.outer_symbols;

            try self.out.print("{s}{s}{s}\n", .{ prefix, symbols[0], entry.name });

            if (entry.kind == .directory) {
                self.num_directories += 1;
                const new_prefix = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, symbols[1] });
                defer alloc.free(new_prefix);
                const new_dir = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer new_dir.close(io);
                try self.walkInner(io, alloc, new_dir, new_prefix);
            } else {
                self.num_files += 1;
            }
        }
    }

    pub fn walk(self: *TreeWalker, io: Io, alloc: Allocator, directory: []const u8) WalkError!void {
        const root = try Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer root.close(io);
        self.num_directories += 1;
        try self.out.print("{s}\n", .{directory});
        try self.walkInner(io, alloc, root, "");
        try self.out.writeByte('\n');
    }
};

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help         Display this help and exit.
        \\-a, --all          Show hidden files and directories.
        \\<str>...           Directories to show. (Defaults to '.')
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.helpToFile(init.io, .stderr(), clap.Help, &params, .{});

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const show_all = res.args.all != 0;
    var directories = blk: {
        var arr: std.ArrayList([]const u8) = .empty;
        for (res.positionals[0]) |pos|
            try arr.append(init.gpa, pos);
        if (arr.items.len == 0)
            try arr.append(init.gpa, ".");
        break :blk arr;
    };
    defer directories.deinit(init.gpa);

    var w: TreeWalker = .init(stdout, show_all);
    for (directories.items) |dir| {
        w.walk(init.io, init.gpa, dir) catch |err| switch (err) {
            error.FileNotFound => log.err("Directory '{s}' not found", .{dir}),
            error.NotDir => log.err("'{s}' is not a directory", .{dir}),
            else => |e| return e,
        };
    }
    try w.summary();
    try stdout.flush();
}
