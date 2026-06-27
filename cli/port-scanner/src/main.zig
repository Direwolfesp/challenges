const std = @import("std");
const Io = std.Io;

const port_scanner = @import("port_scanner");

pub const Args = struct {
    help: bool = false,
    host: []const u8 = "localhost",
    port: ?u16 = null,

    pub const stringToArg: std.StaticStringMap(std.meta.FieldEnum(Args)) = .initComptime(.{
        .{ "-h", .help },
        .{ "--help", .help },
        .{ "--host", .host },
        .{ "-p", .port },
        .{ "--port", .port },
    });

    pub const usage =
        \\Usage: {s} [--port | --host | --help]
        \\
        \\Port scanner utility.
    ;
};

pub fn parseArgs(args: []const []const u8) !Args {
    var options: Args = .{};

    var i: u32 = 1;
    while (i < args.len) : (i += 1) {
        if (Args.stringToArg.get(args[i])) |val| switch (val) {
            .help => {
                std.debug.print("{s}", .{Args.usage});
                std.process.exit(0);
            },
            .host => {
                i += 1;
                if (i == args.len) std.process.fatal("Missing host argument!", .{});
                options.host = args[i];
            },
            .port => {
                i += 1;
                if (i == args.len) std.process.fatal("Missing port argument!", .{});
                options.port = std.fmt.parseInt(u16, args[i], 10) catch {
                    std.process.fatal("Invalid port number. Only values from 1..={d} are allowed", .{
                        std.math.maxInt(u16),
                    });
                };
            },
        } else return error.UnknownArgument;
    }

    return options;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;
    const gpa = init.gpa;

    const options = try parseArgs(args);

    const port_range: port_scanner.PortRange = if (options.port) |p|
        .{ .one = p }
    else
        .all;

    try port_scanner.scanPorts(io, gpa, options.host, port_range);
}
