const std = @import("std");

const log = std.log.scoped(.xxd);

const LINE_SIZE = 16;

const usage_msg =
    \\Usage: xxd [ -e | -g <bytes> | -h ] <file> 
    \\ => -h: Help, show this help
    \\ => -e: Endianess, outputs binary in Little Endian (default: Big Endian)
    \\ => -g: Grouping, select the number of bytes in each group (default: 4)
    \\ => <file>: Input file that will be read (default: stdin)
;

fn usageAndDie(comptime status: u8) noreturn {
    std.debug.print(usage_msg, .{});
    std.process.exit(status);
}

const XxdOptions = struct {
    endiand: enum { big, little },
    grouping: u32,
    file: []const u8,

    pub const init = XxdOptions{
        .endiand = .big,
        .grouping = 4, // clamped by 0..=16
        .file = &.{},
    };

    const Self = @This();

    pub fn parse(self: *Self, args: []const []const u8) void {
        var i: u32 = 1;

        while (i < args.len) : (i += 1) {
            const curr = args[i];

            if (std.mem.eql(u8, curr, "-h")) {
                usageAndDie(0);
            } else if (std.mem.eql(u8, curr, "-e")) {
                self.endiand = .little;
            } else if (std.mem.eql(u8, curr, "-g")) {
                if (i < args.len - 1) {
                    i += 1;
                    const value = args[i];
                    self.grouping = std.fmt.parseInt(u32, value, 10) catch 4;
                } else {
                    log.err("Missing <bytes> argument for -g", .{});
                    std.process.exit(1);
                }
            } else if (curr[0] == '-') {
                log.err("Unknown flag '{s}'", .{curr});
                std.process.exit(1);
            } else {
                self.file = curr;
                return;
            }
        }
        self.verify();
    }

    fn verify(self: *Self) void {
        self.grouping = std.math.clamp(self.grouping, 0, 16);
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

    var opts: XxdOptions = .init;
    opts.parse(args);

    const in_file = std.fs.cwd().openFile(opts.file, .{}) catch |err| file: switch (err) {
        error.FileNotFound => break :file std.fs.File.stdin(),
        else => return err,
    };

    var input_buf: [4096]u8 = undefined;
    var input_reader = in_file.reader(&input_buf);
    const input = &input_reader.interface;

    while (input.peek(LINE_SIZE)) |bytes| {
        input.toss(LINE_SIZE);

        // TODO
        try stdout.print("{x}\n", .{bytes});

        // when piping stdout to another process stdin, it
        // could stop reading from us in any moment
        stdout.flush() catch if (stdout_wr.err) |err| switch (err) {
            error.BrokenPipe => break,
            else => return err,
        };
    } else |err| switch (err) {
        // small input treatment
        error.EndOfStream => {
            var remaining: [LINE_SIZE]u8 = undefined;
            const read = try input.readSliceShort(&remaining);
            const bytes = remaining[0..read];
            try stdout.print("{x}", .{bytes});
            // TODO
        },
        error.ReadFailed => return input_reader.err.?,
    }
    try stdout.flush();
}
