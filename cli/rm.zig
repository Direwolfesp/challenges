const std = @import("std");
const fs = std.fs;
const File = std.fs.File;

const log = std.log.scoped(.rm);

const dry_run = false;

/// Only removes regular files, thus it will fail if the directory contains other
/// type than regular files
fn removeRecursive(comptime is_top: bool, name: []const u8, kind: File.Kind) !void {
    if (kind == .file) {
        if (!dry_run) {
            fs.cwd().deleteFile(name) catch |err| {
                log.err("Could not delete file '{s}: {t}'", .{ name, err });
            };
        } else log.info("(dry-run) would delete file '{s}'", .{name});
    } else if (kind == .directory) {
        var dir = fs.cwd().openDir(name, .{ .iterate = true }) catch |err| {
            log.err("Could not open directory '{s}': {t}", .{ name, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |sub| {
            var path_buf: [fs.max_path_bytes]u8 = undefined;
            const final_name = if (is_top)
                try std.fmt.bufPrint(&path_buf, "{s}{s}", .{ name, sub.name })
            else
                try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ name, sub.name });
            try removeRecursive(false, final_name, sub.kind);
        }

        // remove itself
        if (!dry_run) {
            try fs.cwd().deleteDir(name);
        } else {
            log.info("(dry-run) would delete folder '{s}'", .{name});
        }
    }
}

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const gpa = debug.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        std.debug.print( // TODO: flags
            \\Usage: rm [-h | -d] <names...> 
            \\ => -h: Show this help
            \\ => -d: Dry run, does not delete anything
            \\ => For directories, `recursive` deletion is implied
        , .{});
        return;
    }

    for (1..args.len) |i| {
        const name = args[i];
        const stat = fs.cwd().statFile(name) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("File '{s}' does not exist", .{name});
                return;
            },
            else => return err,
        };

        var name_buf: [fs.max_name_bytes]u8 = undefined;
        const new_name = if (stat.kind == .directory and name[name.len - 1] != '/')
            try std.fmt.bufPrint(&name_buf, "{s}/", .{name})
        else
            name;

        try removeRecursive(true, new_name, stat.kind);
    }
}
