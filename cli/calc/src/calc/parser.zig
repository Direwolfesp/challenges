const std = @import("std");
const Allocator = std.mem.Allocator;

const Tokens = @import("lexer.zig").Tokens;

pub const ParseError = error{
    IncompleteExpr,
    MissingOpeningParent,
    MissingClosingParent,
} || Allocator.Error;

pub fn intoReverseNotation(gpa: Allocator, tokens: []const Tokens) ParseError![]Tokens {
    // Implements https://en.wikipedia.org/wiki/Shunting_yard_algorithm
    var output_queue: std.ArrayList(Tokens) = try .initCapacity(gpa, tokens.len);
    defer output_queue.deinit(gpa);

    var operator_stack: std.ArrayList(Tokens) = .empty;
    defer operator_stack.deinit(gpa);

    for (tokens) |tok| {
        switch (tok) {
            .operator => |op| {
                while (operator_stack.getLastOrNull()) |last| {
                    if (last == .opening_bracket or
                        last.operator.precedence() < op.precedence())
                        break;
                    try output_queue.append(gpa, operator_stack.pop() orelse return error.IncompleteExpr);
                }
                try operator_stack.append(gpa, tok);
            },
            .closing_bracket => {
                while (operator_stack.getLastOrNull()) |last| {
                    if (last == .opening_bracket) break;
                    try output_queue.append(gpa, operator_stack.pop().?);
                }
                const pop = operator_stack.pop() orelse return error.MissingOpeningParent;
                if (pop != .opening_bracket) return error.MissingOpeningParent;
            },
            .opening_bracket => try operator_stack.append(gpa, tok),
            .operand => try output_queue.append(gpa, tok),
        }
    }

    while (operator_stack.pop()) |op| {
        if (op == .opening_bracket)
            return error.MissingClosingParent;
        try output_queue.append(gpa, op);
    }

    return try output_queue.toOwnedSlice(gpa);
}

test "into reverse notation: basic math" {
    const gpa = std.testing.allocator;

    // 3 + 4 ==> 3 4 +
    const initial = &[_]Tokens{
        .{ .operand = 3 },
        .{ .operator = .add },
        .{ .operand = 4 },
    };
    const expected = &[_]Tokens{
        .{ .operand = 3 },
        .{ .operand = 4 },
        .{ .operator = .add },
    };

    const rpn = try intoReverseNotation(gpa, initial);
    defer gpa.free(rpn);
    try std.testing.expectEqualSlices(Tokens, expected, rpn);
}

test "into reverse notation: multiple operators" {
    const gpa = std.testing.allocator;

    // 3 + 4 * 2 - 1 => 3 4 2 * + 1 -
    const initial = &[_]Tokens{
        .{ .operand = 3 },
        .{ .operator = .add },
        .{ .operand = 4 },
        .{ .operator = .multiply },
        .{ .operand = 2 },
        .{ .operator = .subtract },
        .{ .operand = 1 },
    };
    const expected = &[_]Tokens{
        .{ .operand = 3 },
        .{ .operand = 4 },
        .{ .operand = 2 },
        .{ .operator = .multiply },
        .{ .operator = .add },
        .{ .operand = 1 },
        .{ .operator = .subtract },
    };

    const rpn = try intoReverseNotation(gpa, initial);
    defer gpa.free(rpn);
    try std.testing.expectEqualSlices(Tokens, expected, rpn);
}

test "into reverse notation: brackets" {
    const gpa = std.testing.allocator;

    // (3 + 4) * 2 - 1 =>
    const initial = &[_]Tokens{
        .opening_bracket,
        .{ .operand = 3 },
        .{ .operator = .add },
        .{ .operand = 4 },
        .closing_bracket,
        .{ .operator = .multiply },
        .{ .operand = 2 },
        .{ .operator = .subtract },
        .{ .operand = 1 },
    };
    const expected = &[_]Tokens{
        .{ .operand = 3 },
        .{ .operand = 4 },
        .{ .operator = .add },
        .{ .operand = 2 },
        .{ .operator = .multiply },
        .{ .operand = 1 },
        .{ .operator = .subtract },
    };

    const rpn = try intoReverseNotation(gpa, initial);
    defer gpa.free(rpn);
    try std.testing.expectEqualSlices(Tokens, expected, rpn);
}
