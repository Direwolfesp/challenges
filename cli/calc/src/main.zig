const std = @import("std");
const print = std.debug.print;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const calc = @import("calc");
const c = @import("c");

const promp = "> ";

const welcome =
    \\Welcome to the interactive calculator!
    \\Enter 'quit' to exit.
    \\
;

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
        print(welcome, .{});

        while (c.readline(promp)) |line| {
            defer c.free(line);
            c.add_history(line);

            const result = calc.evalExpr(gpa, std.mem.span(line)) catch |err| switch (err) {
                error.ShutdownRequest => break,
                else => {
                    std.log.err("{t}", .{err});
                    continue;
                },
            };
            if (result) |value| {
                print("{d}\n", .{value});
            }
        }
    } else if (std.mem.eql(u8, "-h", args[1]) or std.mem.eql(u8, "--help", args[1])) {
        print(help, .{args[0]});
    } else {
        var stdout = Io.File.stdout().writer(io, &.{});
        const expr = args[1];
        if (try calc.evalExpr(gpa, expr)) |result| {
            try stdout.interface.print("{d}", .{result});
        }
    }
}
