//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");

test {
    _ = lexer;
    _ = parser;
    _ = std.testing.refAllDecls(@This());
}
