const std = @import("std");
const Io = std.Io;

const fatal = std.process.fatal;

const port_scanner = @import("port_scanner");

pub const Args = struct {
    help: bool = false,
    host: []const u8 = "localhost",
    port: port_scanner.PortRange,

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
        \\=> --port: The port or ports to scan. Ex. --port 8080, --port 400..8080
        \\=> --host: The hostname to scan. Ex. --host localhost, --host 192.168.1.* 
        \\=> --help: Show this help
    ;
};

pub fn parseArgs(args: []const []const u8) !Args {
    var options: Args = .{ .port = .all };

    var i: u32 = 1;
    while (i < args.len) : (i += 1) {
        if (Args.stringToArg.get(args[i])) |val| switch (val) {
            .help => {
                std.debug.print("{s}", .{Args.usage});
                std.process.exit(0);
            },
            .host => {
                i += 1;
                if (i == args.len) fatal("Missing host argument!", .{});
                options.host = args[i];
            },
            .port => {
                i += 1;
                if (i == args.len) fatal("Missing port argument!", .{});

                var iter = std.mem.tokenizeSequence(u8, args[i], "..");
                const start = iter.next();
                const end = iter.next();

                if (start != null and end != null) {
                    options.port = .{
                        .range = .{
                            .start = std.fmt.parseInt(u16, start.?, 10) catch |e|
                                fatal("Invalid starting port: {t}", .{e}),
                            .end = std.fmt.parseInt(u16, end.?, 10) catch |e|
                                fatal("Invalid ending port: {t}", .{e}),
                        },
                    };
                } else if (start != null and end == null) {
                    options.port = .{
                        .one = std.fmt.parseInt(u16, start.?, 10) catch |e|
                            fatal("Invalid port: {t}", .{e}),
                    };
                } else {
                    fatal("Invalid port range", .{});
                }
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
    try port_scanner.scanPorts(io, gpa, options.host, options.port);
}
