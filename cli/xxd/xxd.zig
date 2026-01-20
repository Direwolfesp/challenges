//! A small implementation of xxd (binary hex dump) in Zig from scratch
//!
const std = @import("std");

const log = std.log.scoped(.xxd);

// TODO: implement -e, -g <bytes>, -l <length>, -c <columns>, -s <seek>
// - each line always prints 16 bytes of the file at maximum unless set by -c
// - '-s' seek should just exist successfully if the provided value is greater
//   than the input at runtime
const usage_msg =
    \\Usage: xxd [ -e | -g <bytes> | -c <columns> | -l <length> | -s <seek> | -h ] <file> 
    \\ => -h: Help, show this help
    \\ => -e: Endianess, outputs binary in Little Endian (default: Big Endian)
    \\ => -g: Grouping, select the number of bytes in each group (default: 2)
    \\ => -l: Length, how many bytes to show in total (default: inf)
    \\ => -c: Columns, the amount of bytes to show per row (default: 16)
    \\ => -s: Seek, start at that offset from the file (default: 0)
    \\ => <file>: Input file that will be read (default: stdin)
    \\ Note: Combined short flags such as `-el 1` are not supported.
;

fn usageAndDie(comptime status: u8) noreturn {
    std.debug.print(usage_msg, .{});
    std.process.exit(status);
}

const XxdOptions = struct {
    const Endianness = enum { big, little };

    endian: Endianness = endianDefault,
    grouping: u32 = groupingDefault, // clamped by 0..=16
    file: ?[]const u8 = null,
    columns: u8 = columnsDefault,
    seek: u64 = seekDefault,
    length: u64 = lengthDefault,

    const endianDefault: Endianness = .big;
    const columnsMax = 256;
    const columnsDefault = 16;
    const groupingDefault = 2;
    const seekDefault = 0;
    const lengthDefault = std.math.maxInt(u64);

    pub const default = XxdOptions{};

    const Self = @This();

    pub fn parse(self: *Self, args: []const []const u8) void {
        var i: u32 = 1;
        var grouping_modified = false;

        while (i < args.len) : (i += 1) {
            const curr = args[i];
            if (std.mem.eql(u8, curr, "-h")) {
                usageAndDie(0);
            } else if (std.mem.eql(u8, curr, "-e")) {
                self.endian = .little;
            } else if (std.mem.eql(u8, curr, "-g")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.grouping = std.fmt.parseInt(u32, value, 10) catch groupingDefault;
                    grouping_modified = true;
                } else {
                    log.err("Missing <bytes> argument for -g", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.eql(u8, curr, "-c")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.columns = std.fmt.parseInt(u8, value, 10) catch columnsDefault;
                } else {
                    log.err("Missing <columns> argument for -c", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.eql(u8, curr, "-l")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.length = std.fmt.parseInt(u64, value, 10) catch lengthDefault;
                } else {
                    log.err("Missing <length> argument for -l", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.eql(u8, curr, "-s")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.seek = std.fmt.parseInt(u64, value, 10) catch seekDefault;
                } else {
                    log.err("Missing <seek> argument for -s", .{});
                    std.process.exit(1);
                }
            } else if (curr[0] == '-') {
                log.err("Unknown flag '{s}'", .{curr});
                std.process.exit(1);
            } else {
                self.file = curr;
                break;
            }
        }

        self.verify(grouping_modified);
    }

    /// Modifies options based on the state of the arguments provided by user
    fn verify(self: *Self, grouping_modified: bool) void {
        // Based on what xxd does:
        // - Default grouping is 2
        // - '-e' little endian flag changes grouping to 4 if no grouping was provided
        if (grouping_modified) {
            self.grouping = std.math.clamp(self.grouping, 0, 16);
            if (self.grouping == 0) {
                self.grouping = 16;
            }
        } else if (self.endian == .little) {
            self.grouping = 4;
        }

        if (self.columns > columnsMax) {
            log.err("invalid number of columns (max. {d})", .{columnsMax});
            std.process.exit(1);
        }
    }
};

pub fn main() !void {
    var alloc: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();

    const args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_wr = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_wr.interface;

    var opts: XxdOptions = .default;
    opts.parse(args);

    const in_file = if (opts.file) |file|
        std.fs.cwd().openFile(file, .{}) catch |err| {
            log.err("{s}: {t}", .{ file, err });
            std.process.exit(1);
        }
    else
        std.fs.File.stdin();

    var input_buf: [4096]u8 = undefined;
    var input_reader = in_file.reader(&input_buf);
    const input = &input_reader.interface;

    var index: u32 = 0;

    while (input.peek(opts.columns)) |bytes| : (index += opts.columns) {
        input.toss(opts.columns);

        // TODO(abstract): Print index
        try stdout.print("{x:0>8}: ", .{index});

        // Print all groups
        const num_groups = opts.columns / opts.grouping;
        for (0..num_groups) |i| {
            const start = i * opts.grouping;
            const end = start + opts.grouping;

            if (opts.endian == .big) {
                try stdout.print("{x} ", .{bytes[start .. start + opts.grouping]});
            } else if (opts.endian == .little) {
                var j = end - 1;
                while (j >= start) : (j -= 1) {
                    try stdout.print("{x:0>2}", .{bytes[j]});
                    if (j == 0) break;
                }
                try stdout.writeByte(' ');
            }
        }

        // TODO(abstract): separator
        try stdout.writeByte(' ');

        // //TODO(abstract): Print: ascii view
        for (bytes) |b| {
            if (std.ascii.isAlphanumeric(b)) {
                try stdout.print("{c}", .{b});
            } else {
                try stdout.print(".", .{});
            }
        }
        try stdout.print("\n", .{});

        // when piping stdout to another process stdin, it
        // could stop reading from us in any moment
        stdout.flush() catch if (stdout_wr.err) |err| switch (err) {
            error.BrokenPipe => break,
            else => return err,
        };
    } else |err| switch (err) {
        // small input treatment
        error.EndOfStream => {
            var remaining: [XxdOptions.columnsMax]u8 = undefined;
            const read = try input.readSliceShort(&remaining);
            const bytes = remaining[0..read];
            _ = bytes;
            @panic("TODO: do the same as in the loop");
        },
        error.ReadFailed => return input_reader.err.?,
    }

    // ignore broken pipe
    stdout.flush() catch if (stdout_wr.err) |err| switch (err) {
        error.BrokenPipe => {},
        else => return err,
    };
}
