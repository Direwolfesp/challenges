const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const calc = @import("calc");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = std.testing.refAllDecls(@This());
}
