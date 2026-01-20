const std = @import("std");

const log = std.log.scoped(.xxd);

fn usageAndDie(comptime status: u8) void {
    const usage_msg =
        \\Usage: xxd [ -e | -g <bytes> | -h ] <file> 
        \\ => -e: Endianess, outputs binary in Little Endian
        \\ => -g: Grouping, select the number of bytes in each group
        \\ => -h: Help, show this help
    ;
    std.debug.print(usage_msg, {});
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
        _ = args;

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

    var opts: XxdOptions = .init;

    opts.parse(args);
}
