//! A small implementation of xxd (binary hex dump) in Zig from scratch
//!
const std = @import("std");

const log = std.log.scoped(.xxd);

const usage_msg =
    \\Usage: xxd [ -e | -g <bytes> | -c <columns> | -l <length> | -s <seek> | -R <color> | -h ] <file> 
    \\ => -h: Help, show this help
    \\ => -e: Endianess, outputs binary in Little Endian (default: Big Endian)
    \\ => -g: Grouping, select the number of bytes in each group (default: 2)
    \\ => -l: Length, how many bytes to show in total (default: inf)
    \\ => -c: Columns, the amount of bytes to show per row (default: 16)
    \\ => -s: Seek, start at <seek> bytes abs. (or +: rel.) infile offset. (default: 0)
    \\ => -R: Color, can be 'always', 'auto' or 'never' (default: auto)
    \\ => <file>: Input file that will be read (default: stdin)
    \\ Note: Combined short flags such as `-el 1` are not supported.
;

fn usageAndDie(comptime status: u8) noreturn {
    std.debug.print(usage_msg, .{});
    std.process.exit(status);
}

const Colors = struct {
    const printableDefault = "\x1b[36m"; // cyan
    const whitespaceDefault = "\x1b[32m"; // green
    const asciiOtherDefault = "\x1b[35m"; // magenta
    const nonAsciiDefault = "\x1b[33m"; // yellow
    const nullByteDefault = "\x1b[90m"; // grey
    const reset = "\x1b[0m";
    const none = "";
};

/// Core attributes and state of the program
const XxdOptions = struct {
    /// byte ordering
    endian: std.builtin.Endian = endianDefault,
    /// clamped by 0..=16
    grouping: u32 = groupingDefault,
    /// file from which we get the input
    file: ?[]const u8 = null,
    /// number of **input** bytes that will be displayed per row
    columns: u8 = columnsDefault,
    /// where to start reading from the file
    seek: i64 = 0,
    /// the amount of bytes that will be read at max from the file
    length: u64 = std.math.maxInt(u64),
    /// will trigger request_stop when it reaches `self.length`
    processed: u64 = 0,
    /// internal flag to stop processing bytes
    request_stop: bool = false,
    /// the amount of bytes the hex view will span, taking into account groups,
    /// length and spaces, so that the ascii view is not misaligned
    span: u64 = 0,
    /// When to output ansi colors. By default, colors will be disabled when
    /// stdout is not a tty (ie. a file or other program)
    colored_output: enum { auto, always, never } = .auto,

    // Color config attributes
    printable_color: []const u8 = Colors.printableDefault,
    white_space_color: []const u8 = Colors.whitespaceDefault,
    ascii_other_color: []const u8 = Colors.asciiOtherDefault,
    non_ascii_color: []const u8 = Colors.nonAsciiDefault,
    null_byte_color: []const u8 = Colors.nullByteDefault,
    reset: []const u8 = Colors.reset,

    // Default config constants
    const endianDefault: std.builtin.Endian = .big;
    const columnsMax = 256;
    const columnsDefault = 16;
    const groupingDefault = 2;

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
                    self.length = std.fmt.parseInt(u64, value, 10) catch std.math.maxInt(u64);
                } else {
                    log.err("Missing <length> argument for -l", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.eql(u8, curr, "-s")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.seek = std.fmt.parseInt(i64, value, 10) catch 0;
                } else {
                    log.err("Missing <seek> argument for -s", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.eql(u8, curr, "-R")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.colored_output = if (std.mem.eql(u8, value, "auto"))
                        .auto
                    else if (std.mem.eql(u8, value, "never"))
                        .never
                    else if (std.mem.eql(u8, value, "always"))
                        .always
                    else
                        usageAndDie(1);
                } else {
                    log.err("Missing <color> argument for -R", .{});
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

    /// Sanitize options based on the arguments provided by user.
    /// Based on the behaviour of xxd:
    /// - Default grouping is 2
    /// - '-e' little endian flag changes grouping to 4 if no grouping was provided
    /// - '-e' little endian flag does not allow non power of 2 grouping
    /// - cap columns limit
    /// - colored output
    fn verify(self: *Self, grouping_modified: bool) void {
        if (grouping_modified) {
            self.grouping = std.math.clamp(self.grouping, 0, 16);
            if (self.grouping == 0) {
                self.grouping = 16;
            }

            if (self.endian == .little and @popCount(self.grouping) != 1) {
                log.err("number of octets per group must be a power of 2 with -e", .{});
                std.process.exit(1);
            }
        } else if (self.endian == .little) {
            self.grouping = 4;
        }

        if (self.columns > columnsMax) {
            log.err("invalid number of columns (max. {d})", .{columnsMax});
            std.process.exit(1);
        }

        // set colored output, the user can set it: disabled/enabled/automatic
        if (!std.fs.File.stdout().isTty() and self.colored_output == .auto) {
            self.disableColors();
        } else if (self.colored_output == .never) {
            self.disableColors();
        }

        const bytes_per_group = std.math.divCeil(u32, @intCast(self.columns), self.grouping) catch unreachable; // SAFETY: there is a 0 check of self.grouping above
        self.span = (2 * self.columns) + bytes_per_group + 1;
    }

    fn disableColors(self: *Self) void {
        self.printable_color = Colors.none;
        self.white_space_color = Colors.none;
        self.non_ascii_color = Colors.none;
        self.null_byte_color = Colors.none;
        self.reset = Colors.none;
        self.ascii_other_color = Colors.none;
    }

    fn getColor(self: Self, byte: u8) []const u8 {
        return if (std.ascii.isPrint(byte))
            self.printable_color
        else if (std.ascii.isWhitespace(byte))
            self.white_space_color
        else if (std.ascii.isControl(byte))
            self.ascii_other_color
        else if (byte == 0x00)
            self.null_byte_color
        else // binary
            self.non_ascii_color;
    }

    fn getChar(self: Self, byte: u8) u8 {
        _ = self;
        return if (std.ascii.isPrint(byte))
            byte
        else if (std.ascii.isWhitespace(byte))
            '_'
        else if (std.ascii.isControl(byte))
            '.'
        else if (byte == 0x00)
            ' '
        else
            'x';
    }
};

fn printByteOptions(out: *std.Io.Writer, byte: u8, opts: *const XxdOptions) !void {
    try out.print("{s}{x:0>2}{s}", .{
        opts.getColor(byte),
        byte,
        opts.reset,
    });
}

fn printSliceHexEndianOptions(
    out: *std.Io.Writer,
    bytes: []const u8,
    endian: std.builtin.Endian,
    opts: *XxdOptions,
) !void {
    if (endian == .little) {
        var i: usize = bytes.len;
        while (i > 0) {
            if (opts.processed == opts.length) {
                opts.request_stop = true;
                break;
            }

            i -= 1;
            try printByteOptions(out, bytes[i], opts);
            opts.processed += 1;
        }
    } else {
        for (bytes) |b| {
            if (opts.processed == opts.length) {
                opts.request_stop = true;
                break;
            }
            try printByteOptions(out, b, opts);
            opts.processed += 1;
        }
    }
}

pub fn processLineOptions(bytes: []const u8, index: u32, out: *std.Io.Writer, opts: *XxdOptions) !void {
    // print index
    try out.print("{s}{x:0>8}{s}: ", .{
        opts.printable_color,
        index,
        opts.reset,
    });

    // track the ammount of spaces we will need after printing the bytes
    var to_span = opts.span;

    // print all groups
    const n_groups = try std.math.divCeil(u32, @intCast(bytes.len), opts.grouping);
    for (0..n_groups) |i| {
        const start = i * opts.grouping;
        const end = @min(bytes.len, (start + opts.grouping));
        const group = bytes[start..end];
        try printSliceHexEndianOptions(out, group, opts.endian, opts);
        if (opts.request_stop)
            break;
        to_span -= (2 * group.len) + 1;
        try out.writeByte(' ');
    }

    // add some padding
    _ = try out.splatByteAll(' ', to_span);

    // print ascii representation
    for (bytes) |b| {
        try out.print("{s}{c}{s}", .{
            opts.getColor(b),
            opts.getChar(b),
            opts.reset,
        });
    }
    try out.print("\n", .{});
}

/// Calculates final file offset based on the seek argument.
/// A negative value will seek backwards from the end `seek` bytes.
/// Seeking before the byte 0 will result in an error.
pub fn calcSeekPosition(file: std.fs.File, seek: i64) !u64 {
    return if (seek < 0) blk: {
        const st = try file.stat();

        // prevent seeking backwards out of bounds
        if (@abs(seek) > st.size) {
            log.err("Sorry, cannot seek.", .{});
            std.process.exit(1);
        }
        const seek_pos = st.size - @abs(seek);
        break :blk seek_pos;
    } else @abs(seek);
}

pub fn main() !void {
    var alloc: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();

    const args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_wr = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_wr.interface;

    var opts: XxdOptions = .{};
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

    // seek the input
    const seek_pos = try calcSeekPosition(in_file, opts.seek);
    try input_reader.seekTo(seek_pos);

    var index: u32 = 0;

    while (input.peek(opts.columns)) |bytes| : (index += opts.columns) {
        // we reached desired `length`
        if (opts.request_stop)
            break;

        // process row
        input.toss(opts.columns);
        try processLineOptions(bytes, index, stdout, &opts);

        // when piping stdout to another process stdin, it
        // could stop reading from us in any moment (ie. user presses CTRL-C)
        stdout.flush() catch if (stdout_wr.err) |err| switch (err) {
            error.BrokenPipe => break,
            else => return err,
        };
    } else |err| switch (err) {
        error.EndOfStream => { // small input treatment
            var remaining: [XxdOptions.columnsMax]u8 = undefined;
            const read = try input.readSliceShort(&remaining);
            if (read == 0) return;
            const bytes = remaining[0..read];
            try processLineOptions(bytes, index, stdout, &opts);
        },
        error.ReadFailed => return input_reader.err.?,
    }

    // ignore broken pipe
    stdout.flush() catch if (stdout_wr.err) |err| switch (err) {
        error.BrokenPipe => {},
        else => return err,
    };
}
