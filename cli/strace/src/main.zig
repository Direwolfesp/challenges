const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const user = @cImport(@cInclude("sys/user.h"));
const log = std.log.scoped(.strace);

const StraceOptions = struct {
    /// program name
    name: []const u8,
    /// program arguments
    args: []const []const u8,
    /// only print a summary
    summary: bool,

    const usage = "Usage: strace [ -h | --help | -c | --summary-only ] <prog> [args...]";

    pub fn init(gpa: Allocator, argv: []const [*:0]const u8) !StraceOptions {
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

    pub fn deinit(self: *StraceOptions, gpa: Allocator) void {
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

    var t: StraceOptions = try .init(gpa, args);
    defer t.deinit(gpa);

    const child: i32 = @intCast(linux.fork());
    if (child == 0) { // child
        var shit = try gpa.alloc([]const u8, t.args.len + 1);
        shit[0] = t.name;
        @memcpy(shit[1..], t.args);

        const r = linux.ptrace(linux.PTRACE.TRACEME, 0, 0, 0, 0);
        if (r == -1) {
            std.process.fatal("Could not trace child: {t}", .{std.c.errno(r)});
        }

        // redirect child stdout and stderr to null device.
        const file = try std.Io.Dir.openFileAbsolute(init.io, "/dev/null", .{ .mode = .write_only });
        _ = linux.dup2(file.handle, linux.STDOUT_FILENO);
        _ = linux.dup2(file.handle, linux.STDERR_FILENO);

        switch (std.process.replace(init.io, .{ .argv = shit })) {
            else => |err| std.process.fatal("Could not spawn child: {t}", .{err}),
        }
    } else if (child > 0) { // parent
        const r = linux.ptrace(linux.PTRACE.SYSCALL, child, 0, 0, 0);
        if (r == -1) {
            std.process.fatal("Could not trace syscalls: {t}", .{std.c.errno(r)});
        }

        var status: c_int = 0;
        var enter = false;
        while (std.c.waitpid(child, &status, 0) != -1) {
            // the child was stopped by a signal
            if (std.c.W.IFSTOPPED(@intCast(status))) {
                // TODO:
                var regs = std.mem.zeroes(user.user_regs_struct);
                if (linux.ptrace(linux.PTRACE.GETREGS, child, 0, @intFromPtr(&regs), 0) == -1) {
                    log.err("strace getregs failed", .{});
                }

                const syscall: linux.syscalls.X64 = @enumFromInt(regs.orig_rax);
                if (!enter) {
                    std.debug.print("{t}({d}, {d}, {d}) = {d}\n", .{
                        syscall,
                        regs.rdi,
                        regs.rsi,
                        regs.rdx,
                        regs.rax,
                    });
                }

                if (linux.ptrace(linux.PTRACE.SYSCALL, child, 0, 0, 0) == -1) {
                    log.err("strace syscall failed", .{});
                }
                enter = !enter;
            }
        }
    } else {
        log.err("Could not fork", .{});
    }
}
