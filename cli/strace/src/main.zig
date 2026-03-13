const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const log = std.log.scoped(.strace);

const Tracee = struct {
    /// program name
    name: []const u8,
    /// program arguments
    args: []const []const u8,
    /// only print a summary
    summary: bool,

    const usage = "Usage: strace [ -h | --help | -c | --summary-only ] <prog> [args...]";

    pub fn init(gpa: Allocator, argv: []const [*:0]const u8) !Tracee {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        var summary = false;
        var name: ?[]const u8 = null;

        for (argv[1..]) |old| {
            const old_: []const u8 = std.mem.span(old);
            if (std.mem.eql(u8, old_, "--help") or std.mem.eql(u8, old_, "-h")) {
                std.debug.print(usage, .{});
                std.process.exit(0);
            } else if (std.mem.eql(u8, old_, "-c") or std.mem.eql(u8, old_, "--summary-only")) {
                summary = true;
            } else {
                const tmp = try gpa.dupe(u8, old_);
                if (name == null) {
                    name = tmp;
                } else {
                    try args.append(gpa, tmp);
                }
            }
        }

        return .{
            .name = name orelse std.process.fatal("Missing a <prog> to trace", .{}),
            .args = try args.toOwnedSlice(gpa),
            .summary = summary,
        };
    }

    pub fn deinit(self: *Tracee, gpa: Allocator) void {
        for (self.args) |a|
            gpa.free(a);
        gpa.free(self.args);
        gpa.free(self.name);
    }
};

pub fn main(init: std.process.Init) !void {
    // const gpa = init.arena.allocator();
    const gpa = init.gpa;
    const args = init.minimal.args.vector;

    var t: Tracee = try .init(gpa, args);
    defer t.deinit(gpa);

    const child = linux.fork();
    if (child == 0) { // child
        var shit = try gpa.alloc([]const u8, t.args.len + 1);
        shit[0] = t.name;
        @memcpy(shit[1..], t.args);
        switch (std.process.replace(init.io, .{ .argv = shit })) {
            else => |err| std.process.fatal("Cant spawn child: {t}", .{err}),
        }
    } else if (child > 0) { // parent
        if (t.summary) {
            log.debug("summary is on", .{});
        }
        const ret = std.c.waitpid(@intCast(child), null, 0);
        if (ret == -1) {
            log.err("waitpid: {t}", .{linux.errno(@intCast(ret))});
        }
    } else {
        log.err("Could not fork", .{});
    }
}
