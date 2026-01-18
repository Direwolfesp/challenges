const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const File = std.fs.File;

const log = std.log.scoped(.rm);

const usage =
    \\Usage: rm [-h | -d] <...files> 
    \\ => -h: Show this help
    \\ => -d: Dry run, does not delete anything
    \\ => -v: Verbose, print the files being deleted
    \\ => -r: Recursive, remove subdirectories recursively
;

const RmOptions = packed struct {
    dry_run: bool,
    verbose: bool,
    recursive: bool,

    pub const default = RmOptions{
        .dry_run = false,
        .verbose = false,
        .recursive = false,
    };
};

const RemoveFileError = fs.Dir.DeleteFileError || fmt.BufPrintError;

pub fn deleteFileOptions(name: []const u8, opts: RmOptions) RemoveFileError!void {
    if (opts.dry_run) {
        log.info("(dry-run) would delete file '{s}'", .{name});
        return;
    }

    fs.cwd().deleteFile(name) catch |err| {
        log.err("Could not delete file '{s}'. Err: {t}", .{ name, err });
        return err;
    };

    if (opts.verbose) {
        log.info("deleted '{s}'", .{name});
    }
}

pub fn deleteDirOptions(name: []const u8, opts: RmOptions) RemoveRecursiveError!void {
    var name_buf: [fs.max_name_bytes]u8 = undefined;
    const new_name = if (name[name.len - 1] != '/')
        try fmt.bufPrint(&name_buf, "{s}/", .{name})
    else
        name;

    if (opts.dry_run) {
        log.info("(dry-run) would delete dir '{s}'", .{new_name});
        if (opts.recursive) {
            try removeRecursive(true, new_name, .directory, opts);
        }
    } else {
        fs.cwd().deleteDir(new_name) catch |err| switch (err) {
            error.DirNotEmpty => {
                if (!opts.recursive) {
                    log.err("cannot remove non-empty directory, consider using '-r' flag.", .{});
                    std.process.exit(1);
                }
                try removeRecursive(true, new_name, .directory, opts);
            },
            else => return err,
        };
    }

    if (opts.verbose) {
        log.info("deleted '{s}'", .{new_name});
    }
}

const RemoveRecursiveError = fs.Dir.DeleteDirError || fs.Dir.DeleteFileError || fmt.BufPrintError;

/// Only removes regular files, thus it will fail if the directory contains other
/// type than regular files
fn removeRecursive(comptime is_top: bool, name: []const u8, kind: File.Kind, options: RmOptions) RemoveRecursiveError!void {
    std.debug.assert(options.recursive);

    if (kind == .file) {
        try deleteFileOptions(name, options);
    } else if (kind == .directory) {
        var dir = fs.cwd().openDir(name, .{ .iterate = true }) catch |err| {
            log.err("Could not open directory '{s}': {t}", .{ name, err });
            return;
        };
        defer dir.close();

        // iterate subdirs
        var iter = dir.iterate();
        while (iter.next()) |sub| {
            if (sub == null) break;
            var path_buf: [fs.max_path_bytes]u8 = undefined;
            try removeRecursive(
                false,
                if (is_top)
                    try fmt.bufPrint(&path_buf, "{s}{s}", .{ name, sub.?.name })
                else
                    try fmt.bufPrint(&path_buf, "{s}/{s}", .{ name, sub.?.name }),
                sub.?.kind,
                options,
            );
        } else |iter_err| {
            log.err("Error traversing directory: {t}", .{iter_err});
            return;
        }

        // remove itself (no logging as the caller will do it)
        if (!options.dry_run) {
            try fs.cwd().deleteDir(name);
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
        std.debug.print(usage, .{});
        return;
    }

    var opts: RmOptions = .default;

    // Main loop
    for (1..args.len) |i| {
        const name = args[i];

        // parse options
        if (std.mem.eql(u8, name, "-d")) {
            opts.dry_run = true;
            continue;
        } else if (std.mem.eql(u8, name, "-v")) {
            opts.verbose = true;
            continue;
        } else if (std.mem.eql(u8, name, "-r")) {
            opts.recursive = true;
            continue;
        } else if (std.mem.eql(u8, name, "-h")) {
            std.debug.print(usage, .{});
            return;
        }

        if (opts.verbose and opts.dry_run) {
            log.err("Incompatible flags: -v and -d", .{});
            std.process.exit(1);
        }

        const stat = fs.cwd().statFile(name) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("Cannot remove '{s}', file does not exist.", .{name});
                std.process.exit(1);
            },
            else => return err,
        };

        if (stat.kind == .directory) {
            try deleteDirOptions(name, opts);
        } else if (stat.kind == .file) {
            try deleteFileOptions(name, opts);
        }
    }
}
