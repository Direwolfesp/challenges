//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const lexer = @import("lexer.zig");

test {
    _ = @import("lexer.zig");
    _ = std.testing.refAllDecls(@This());
}
