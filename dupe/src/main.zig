//! Find duplicate files in a directory (recursively)
//! and let the user choose which one to delete

const std = @import("std");
const Md5 = std.crypto.hash.Md5;

const log = std.log.scoped(.dupe);

const FileMeta = struct {
    name: []const u8,
    inode: u64 = 0,
    size: u64 = 0,
};

fn mapFile(file: std.fs.File, size: u64) ![]align(std.heap.page_size_min) u8 {
    return try std.posix.mmap(
        null,
        @intCast(size),
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );
}

const esc = "\x1B";
const csi = esc ++ "[";

pub fn setCursor(out: *std.Io.Writer, x: usize, y: usize) !void {
    try out.print(csi ++ "{};{}H", .{ y + 1, x + 1 });
}

fn clearScreen(out: *std.Io.Writer) !void {
    try out.writeAll(csi ++ "1J");
}

fn printMenu(out: *std.Io.Writer, duplicates: std.ArrayListUnmanaged(*FileMeta)) !void {
    const size = duplicates.items[0].size;
    try out.print("\nFound duplicate (Unique size: {B}, Total size: {B}): \n", .{ size, size * duplicates.items.len });
    var i: u32 = 0;
    for (duplicates.items) |dup| {
        try out.print("{d} -> {s}\n", .{ i, dup.name });
        i += 1;
    }
    try out.print("Select the file or files to delete separated by spaces:\n:: ", .{});
}

pub fn main() !void {
    var alloc: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();

    const args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, args);

    if (args.len != 2) {
        log.err("Usage: dupe <directory>", .{});
        return;
    }

    const dirname: []const u8 = args[1];

    var dir = std.fs.cwd().openDir(dirname, .{ .iterate = true }) catch |err| {
        log.err("Could not open dir '{s}'. Error: {t}", .{ dirname, err });
        return;
    };
    defer dir.close();

    var stdout_buf: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var iter = try dir.walk(arena);
    defer iter.deinit();

    // quickly filter files by size
    var files: std.AutoArrayHashMapUnmanaged(u64, std.ArrayListUnmanaged(FileMeta)) = .empty;
    defer {
        for (files.values()) |*metadatas| {
            for (metadatas.items) |meta|
                arena.free(meta.name);
            metadatas.deinit(arena);
        }
        files.deinit(arena);
    }

    // map that tracks duplicate files based on its hash
    var dupes: std.AutoArrayHashMapUnmanaged(
        [Md5.digest_length]u8,
        std.ArrayListUnmanaged(*FileMeta),
    ) = .empty;
    defer {
        for (dupes.values()) |*duplicates| duplicates.deinit(arena);
        dupes.deinit(arena);
    }

    // register files based on size
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) continue;

        const st = entry.dir.statFile(entry.basename) catch |err| {
            log.err("Could not stat file '{s}': {t}", .{ entry.path, err });
            continue;
        };

        if (files.getEntry(st.size)) |same_size| {
            try same_size.value_ptr.append(arena, .{
                .inode = st.inode,
                .name = try arena.dupe(u8, entry.path),
                .size = st.size,
            });
        } else {
            var metas: std.ArrayListUnmanaged(FileMeta) = try .initCapacity(arena, 5);
            errdefer metas.deinit(arena);
            metas.appendAssumeCapacity(.{
                .inode = st.inode,
                .name = try arena.dupe(u8, entry.path),
                .size = st.size,
            });
            try files.put(arena, st.size, metas);
        }
    }

    // hash files with the same size and register duplicates
    // (TODO: maybe parallelize hashing)
    for (files.keys(), files.values()) |size, metas| {
        if (metas.items.len > 1) {
            for (metas.items) |*file_meta| {
                const file = try dir.openFile(file_meta.name, .{});
                defer file.close();

                const contents = try mapFile(file, size);
                defer std.posix.munmap(contents);

                var hash: [Md5.digest_length]u8 = undefined;
                var md5 = Md5.init(.{});
                md5.update(contents);
                md5.final(&hash);

                // if hash matches any other, register the duplicate
                if (dupes.getEntry(hash)) |entry| {
                    try entry.value_ptr.append(arena, file_meta);
                } else { // or add it if its unique
                    var entries: std.ArrayListUnmanaged(*FileMeta) = try .initCapacity(arena, 1);
                    errdefer entries.deinit(arena);
                    entries.appendAssumeCapacity(file_meta);
                    try dupes.put(arena, hash, entries);
                }
            }
        }
    }

    var stdin_buf: [2048]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var found_dup = false; // flag to check if there were no dupes

    // Display duplicate files
    outer: for (dupes.values()) |possible_dup| {
        if (possible_dup.items.len > 1) {
            // only clear the first time
            if (!found_dup) {
                try clearScreen(stdout);
                try setCursor(stdout, 0, 0);
            }
            found_dup = true;

            try printMenu(stdout, possible_dup);
            try stdout.flush();

            const line = try stdin.takeDelimiterExclusive('\n');
            stdin.toss(1);

            var num_iter = std.mem.splitScalar(u8, line, ' ');
            while (num_iter.next()) |num| {
                if (num.len == 0) continue; // skip empty lines

                const index = std.fmt.parseInt(usize, num, 10) catch {
                    log.warn("Bad input '{s}', skipping...", .{num});
                    continue :outer; // try next duplicates
                };

                if (index < 0 or index >= possible_dup.items.len) {
                    log.warn("Provided index '{d}' out of bounds, skipping...", .{index});
                    continue :outer; // try next duplicates
                }

                const to_delete = possible_dup.items[index].name;
                dir.deleteFile(to_delete) catch |err| {
                    log.err("Error deleting file '{s}'. Err: {t}", .{ to_delete, err });
                    return; // hard exit on error
                };

                try stdout.print("File '{s}' deleted succesfully\n", .{to_delete});
            }
        }
    }

    if (!found_dup) try stdout.print("No duplicate files found\n", .{});

    try stdout.flush();
}
