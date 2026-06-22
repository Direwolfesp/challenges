const std = @import("std");
const print = std.debug.print;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const calc = @import("calc");

const promp = "> ";

const help =
    \\ Usage: {s} [expression] 
    \\
    \\ Simple calculator program.
    \\ If no expression is provided, starts a REPL.
    \\
    \\ Flags:
    \\ -h/--help: Show this help
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len <= 1) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        print(
            \\Welcome to the interactive calculator!
            \\Enter 'quit' to exit.
            \\{s}
        , .{promp});

        while (try stdin.takeDelimiter('\n')) |line| : (print("{s}", .{promp})) {
            const result = calc.evalExpr(gpa, line) catch |err| switch (err) {
                error.EmptyExpression => continue,
                error.ShutdownRequest => break,
                else => {
                    std.log.err("{t}", .{err});
                    continue;
                },
            };
            print("{d}\n", .{result});
        }
    } else if (std.mem.eql(u8, "-h", args[1]) or std.mem.eql(u8, "--help", args[1])) {
        print(help, .{args[0]});
    } else {
        const expr = args[1];
        const result = try calc.evalExpr(gpa, expr);
        var stdout = Io.File.stdout().writer(io, &.{});
        try stdout.interface.print("{d}", .{result});
    }
}
