const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Operators = enum {
    add,
    subtract,
    multiply,
    divide,
    modulus,
};

pub const Tokens = union(enum) {
    operand: i64,
    operator: Operators,
    opening_bracket: void,
    closing_bracket: void,
};

const LexerError = Allocator.Error || std.fmt.ParseIntError || error{UnknownToken};

fn tokenize(gpa: Allocator, input: []const u8, tokens: *std.ArrayList(Tokens)) LexerError!void {
    var last_num: ?i64 = null;

    for (input, 0..) |c, i| {
        try switch (c) {
            ' ',
            '(',
            ')',
            '*',
            '+',
            '-',
            '/',
            '%',
            => |symbol| {
                if (last_num) |num| try tokens.append(gpa, .{ .operand = num });
                last_num = null;
                switch (symbol) {
                    ' ' => continue,
                    '(' => try tokens.append(gpa, .opening_bracket),
                    ')' => try tokens.append(gpa, .closing_bracket),
                    '*' => try tokens.append(gpa, .{ .operator = .multiply }),
                    '+' => try tokens.append(gpa, .{ .operator = .add }),
                    '-' => try tokens.append(gpa, .{ .operator = .subtract }),
                    '/' => try tokens.append(gpa, .{ .operator = .divide }),
                    '%' => try tokens.append(gpa, .{ .operator = .modulus }),
                    else => unreachable,
                }
            },
            '0'...'9' => |digit| {
                const n = try std.fmt.parseInt(i64, &[_]u8{digit}, 10);
                if (last_num) |*num| {
                    num.* *= 10;
                    num.* += n;
                    last_num = num.*;
                } else {
                    last_num = n;
                }

                // if the digit is the last input, add it up
                if (i == input.len - 1 and last_num != null) {
                    try tokens.append(gpa, .{ .operand = last_num.? });
                }
            },
            else => error.UnknownToken,
        };
    }
}

test tokenize {
    const alloc = std.testing.allocator;
    const input = "(11 + 1) * 5";

    var out: std.ArrayList(Tokens) = .empty;
    defer out.deinit(alloc);

    try tokenize(alloc, input, &out);

    const expected = [_]Tokens{
        .opening_bracket,
        .{ .operand = 11 },
        .{ .operator = .add },
        .{ .operand = 1 },
        .closing_bracket,
        .{ .operator = .multiply },
        .{ .operand = 5 },
    };

    try std.testing.expectEqualSlices(Tokens, &expected, out.items);
}

test "basic math expression with all operators" {
    const alloc = std.testing.allocator;
    const input = "10 + 20 - 30 * 40 / 50 % 6";

    var out: std.ArrayList(Tokens) = .empty;
    defer out.deinit(alloc);

    try tokenize(alloc, input, &out);

    const expected = [_]Tokens{
        .{ .operand = 10 },
        .{ .operator = .add },
        .{ .operand = 20 },
        .{ .operator = .subtract },
        .{ .operand = 30 },
        .{ .operator = .multiply },
        .{ .operand = 40 },
        .{ .operator = .divide },
        .{ .operand = 50 },
        .{ .operator = .modulus },
        .{ .operand = 6 },
    };

    try std.testing.expectEqualSlices(Tokens, &expected, out.items);
}

test "nested brackets" {
    const alloc = std.testing.allocator;
    const input = "((1))";

    var out: std.ArrayList(Tokens) = .empty;
    defer out.deinit(alloc);

    try tokenize(alloc, input, &out);

    const expected = [_]Tokens{
        .opening_bracket,
        .opening_bracket,
        .{ .operand = 1 },
        .closing_bracket,
        .closing_bracket,
    };

    try std.testing.expectEqualSlices(Tokens, &expected, out.items);
}

test "multiple spaces and no spaces" {
    const alloc = std.testing.allocator;
    const input = "   42   +10";

    var out: std.ArrayList(Tokens) = .empty;
    defer out.deinit(alloc);

    try tokenize(alloc, input, &out);

    const expected = [_]Tokens{
        .{ .operand = 42 },
        .{ .operator = .add },
        .{ .operand = 10 },
    };

    try std.testing.expectEqualSlices(Tokens, &expected, out.items);
}

test "single digit at the very end" {
    const alloc = std.testing.allocator;
    const input = "                                 5";

    var out: std.ArrayList(Tokens) = .empty;
    defer out.deinit(alloc);

    try tokenize(alloc, input, &out);

    const expected = [_]Tokens{
        .{ .operand = 5 },
    };

    try std.testing.expectEqualSlices(Tokens, &expected, out.items);
}

test "bad input: invalid characters" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(Tokens) = .empty;
    defer out.deinit(alloc);

    const input_with_letter = "12 + a";
    try std.testing.expectError(error.UnknownToken, tokenize(alloc, input_with_letter, &out));

    const input_with_symbol = "5 $ 3";
    try std.testing.expectError(error.UnknownToken, tokenize(alloc, input_with_symbol, &out));
}
