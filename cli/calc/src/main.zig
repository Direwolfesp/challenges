const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const calc = @import("calc");

const help =
    \\ Usage: {s} [expression] 
    \\
    \\ Simple calculator program.
    \\ If no expression is provided, starts a REPL.
    \\
    \\ Flags:
    \\ -h/--help: Show this help
;
const promp = "> ";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len <= 1) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
        const stdin = &stdin_reader.interface;

        std.debug.print("{s}", .{promp});
        while (try stdin.takeDelimiter('\n')) |line| : (std.debug.print("{s}", .{promp})) {
            const result = calc.evalExpr(gpa, line) catch |err| {
                std.log.err("{t}", .{err});
                continue;
            };
            std.debug.print("{d}\n", .{result});
        }
    } else if (std.mem.eql(u8, "-h", args[1]) or std.mem.eql(u8, "--help", args[1])) {
        std.debug.print(help, .{args[0]});
    } else {
        const expr = args[1];
        const result = try calc.evalExpr(gpa, expr);
        var stdout = Io.File.stdout().writer(io, &.{});
        try stdout.interface.print("{d}", .{result});
    }
}
