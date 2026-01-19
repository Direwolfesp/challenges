//! A simple `rm` implementation made by hand
//!

const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const File = std.fs.File;

const log = std.log.scoped(.rm);

const usage =
    \\Usage: rm [ -h | -d | -v | -r | -f | -i ] <...files> 
    \\ => -h: Show this help
    \\ => -d: Dry run, does not delete anything
    \\ => -v: Verbose, print the files being deleted
    \\ => -r: Recursive, remove subdirectories recursively
    \\ => -f: Force, suppress error when no file 
    \\ => -i: Interactive, ask user to confirm action
    \\ Note: Combined flags such as '-rf' are not supported
    \\ Note: To delete a file that starts with '-', pass '--' first. (Ie. 'rm -- -some_file')
;

const RmOptions = packed struct {
    dry_run: bool,
    verbose: bool,
    recursive: bool,
    force: bool,
    interactive: bool,
    end_flags: bool,

    pub const default = RmOptions{
        .dry_run = false,
        .verbose = false,
        .recursive = false,
        .force = false,
        .interactive = false,
        .end_flags = false,
    };

    const Self = @This();

    /// Parse options. Returns a boolean that specifies if
    /// the `arg` should be skipped or not.
    pub fn parse(self: *Self, arg: []const u8) !bool {
        // caller should skip to next arg
        const skip = true;

        // If the user has manually passed '--', ignore
        // the rest of arguments and treat them as filenames.
        // Thus the caller should not skip it
        if (self.end_flags) {
            return !skip;
        }

        if (std.mem.eql(u8, arg, "-d")) {
            self.dry_run = true;
            return skip;
        } else if (std.mem.eql(u8, arg, "-v")) {
            self.verbose = true;
            return skip;
        } else if (std.mem.eql(u8, arg, "-r")) {
            self.recursive = true;
            return skip;
        } else if (std.mem.eql(u8, arg, "-f")) {
            self.force = true;
            return skip;
        } else if (std.mem.eql(u8, arg, "-i")) {
            self.interactive = true;
            return skip;
        } else if (std.mem.eql(u8, arg, "-h")) {
            std.debug.print(usage, .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--")) {
            self.end_flags = true;
            return skip;
        } else if (arg[0] == '-') { // unescaped unknown flag
            return error.InvalidFlagArgument;
        } else return !skip; // its a filename
    }

    /// Asserts logical invariants of flags
    pub fn verify(self: Self) void {
        if (self.verbose and self.dry_run) {
            // you either want to delete them or not
            log.err("Incompatible flags: -v and -d", .{});
            std.process.exit(1);
        } else if (self.interactive and self.dry_run) {
            // If you do a dry run there is no point in asking to the user
            log.err("Incompatible flags: -i and -d", .{});
            std.process.exit(1);
        }
    }
};

const RemoveFileError = fs.Dir.DeleteFileError || fmt.BufPrintError || error{ ReadFailed, StreamTooLong };

pub fn askConfirmation(file: []const u8) !bool {
    var buf: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        std.debug.print("remove '{s}'? [Y/N]: ", .{file});
        const res = try stdin.takeDelimiter('\n') orelse continue;
        if (res.len == 1) {
            switch (res[0]) {
                'Y', 'y' => return true,
                'N', 'n' => return false,
                else => {},
            }
        }
        std.debug.print("\r", .{});
    }
}

pub fn deleteFileOptions(name: []const u8, opts: RmOptions) RemoveFileError!void {
    const delete = delete: {
        if (opts.dry_run) {
            log.info("(dry-run) would delete file '{s}'", .{name});
            break :delete false;
        } else if (opts.interactive) {
            break :delete try askConfirmation(name);
        } else break :delete true;
    };

    if (!delete) {
        return;
    }

    fs.cwd().deleteFile(name) catch |err| switch (err) {
        error.FileNotFound => {
            if (!opts.force) {
                log.err("Could not delete file '{s}'. {t}", .{ name, err });
                std.process.exit(1);
            }
        },
        else => return err,
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
            error.FileNotFound => {
                if (!opts.force) {
                    log.err("Could not delete dir '{s}'. {t}", .{ name, err });
                    std.process.exit(1);
                }
            },
            else => return err,
        };
    }

    if (opts.verbose) {
        log.info("deleted '{s}'", .{new_name});
    }
}

const RemoveRecursiveError = fs.Dir.DeleteDirError || RemoveFileError;

/// Only removes regular files, thus it will fail if the directory contains other
/// type than regular files
fn removeRecursive(
    comptime is_top: bool,
    name: []const u8,
    kind: File.Kind,
    options: RmOptions,
) RemoveRecursiveError!void {
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

        if (opts.parse(name) catch {
            log.err("Unknown flag '{s}'", .{name});
            std.process.exit(1);
        }) {
            continue;
        }

        opts.verify();

        const stat = fs.cwd().statFile(name) catch |err| switch (err) {
            error.FileNotFound => {
                if (!opts.force) {
                    log.err("File '{s}' does not exist.", .{name});
                    std.process.exit(1);
                }
                continue;
            },
            else => return err,
        };

        if (opts.interactive and !(try askConfirmation(name))) {
            return;
        }

        if (stat.kind == .directory) {
            try deleteDirOptions(name, opts);
        } else if (stat.kind == .file) {
            try deleteFileOptions(name, opts);
        }
    }
}
