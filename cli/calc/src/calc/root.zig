//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const lexer = @import("lexer.zig");
const Tokens = lexer.Tokens;
const parser = @import("parser.zig");

pub const CalcError = parser.ParserError || lexer.LexerError || error{
    DivisionByZero,
    NegativeDenominator,
    EmptyExpression,
};

pub fn evalExpr(gpa: Allocator, source: []const u8) CalcError!i64 {
    var tokens: std.ArrayList(Tokens) = .empty;
    defer tokens.deinit(gpa);

    try lexer.tokenize(gpa, source, &tokens);

    // all spaces
    if (tokens.items.len == 0) {
        return error.EmptyExpression;
    }

    const reversed = try parser.intoReverseNotation(gpa, tokens.items);
    defer gpa.free(reversed);

    var stack: std.ArrayList(i64) = .empty;
    defer stack.deinit(gpa);

    for (reversed) |elem| switch (elem) {
        .operand => |number| try stack.append(gpa, number),
        .operator => |op| {
            const right = stack.pop().?;
            const left = stack.pop().?;
            const res = try op.operate(left, right);
            try stack.append(gpa, res);
        },
        else => unreachable, // reverse notation lacks other symbols (brackets)
    };

    return stack.pop().?; // the result is accumulated as the last elem
}

test "evaluate simple expressions" {
    const gpa = std.testing.allocator;
    {
        const res = try evalExpr(gpa, "3 + 3");
        try std.testing.expectEqual(6, res);
    }
    {
        const res = try evalExpr(gpa, "10+10");
        try std.testing.expectEqual(20, res);
    }
    {
        const res = try evalExpr(gpa, " 0 +              1");
        try std.testing.expectEqual(1, res);
    }
    {
        const res = try evalExpr(gpa, " (3)+             5");
        try std.testing.expectEqual(8, res);
    }
    {
        const res = try evalExpr(gpa, "( (12) +3)");
        try std.testing.expectEqual(15, res);
    }
    {
        const res = try evalExpr(gpa, "( (3) /3)");
        try std.testing.expectEqual(1, res);
    }
}

test "evaluate more complex expressions" {
    const gpa = std.testing.allocator;
    const res = try evalExpr(gpa, "34 * (94 + 12 / (2 - 1))");
    try std.testing.expectEqual(3604, res);
}

test "illegal expresions" {
    const gpa = std.testing.allocator;
    {
        const res = evalExpr(gpa, "( (3) / 0)");
        try std.testing.expectError(error.DivisionByZero, res);
    }
    {
        const res = evalExpr(gpa, "( (3) % 0)");
        try std.testing.expectError(error.DivisionByZero, res);
    }
    {
        const res = evalExpr(gpa, "( (3) % 0 ");
        try std.testing.expectError(error.MissingClosingParent, res);
    }
    {
        const res = evalExpr(gpa, "  (3) % 0)");
        try std.testing.expectError(error.MissingOpeningParent, res);
    }
    {
        const res = evalExpr(gpa, "          ");
        try std.testing.expectError(error.EmptyExpression, res);
    }
}

test {
    _ = lexer;
    _ = parser;
    _ = std.testing.refAllDecls(@This());
}
