const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const sys = @cImport(@cInclude("sys/user.h"));
const log = std.log.scoped(.strace);
const sys_meta: []const u8 = @embedFile("syscalls.json");

const SyscallInfo = struct {
    name: []const u8,
    number: u32,
    arguments: []const []const u8,
    regs: []const []const u8,
};

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

        var stdout_buf: [4096]u8 = undefined;
        var stdout_wr = std.Io.File.stdout().writer(init.io, &stdout_buf);
        const stdout = &stdout_wr.interface;

        var json_data = try std.json.parseFromSlice([]SyscallInfo, gpa, sys_meta, .{});
        defer json_data.deinit();

        var data: std.AutoHashMapUnmanaged(u32, SyscallInfo) = .empty;
        defer data.deinit(gpa);
        for (json_data.value) |value| {
            try data.put(gpa, value.number, .{
                .name = value.name,
                .number = value.number,
                .arguments = value.arguments,
                .regs = value.regs,
            });
        }

        var status: c_int = 0;
        var enter = false;

        while (std.c.waitpid(child, &status, 0) != -1) : (enter = !enter) {
            // the child was stopped by a signal
            if (std.c.W.IFSTOPPED(@intCast(status))) {
                var regs = std.mem.zeroes(sys.user_regs_struct);
                if (linux.ptrace(linux.PTRACE.GETREGS, child, 0, @intFromPtr(&regs), 0) == -1) {
                    log.err("strace getregs failed", .{});
                }

                // Only process the syscall at exit for now
                if (!enter) {
                    const syscall = std.enums.fromInt(linux.syscalls.X64, regs.orig_rax) orelse {
                        std.process.fatal("Unkown syscall number: {d}", .{regs.orig_rax});
                    };
                    const s: SyscallInfo = data.get(@intCast(@intFromEnum(syscall))).?;
                    try printSyscall(stdout, s, regs);
                }

                if (linux.ptrace(linux.PTRACE.SYSCALL, child, 0, 0, 0) == -1) {
                    log.err("strace syscall failed", .{});
                }
            }
        }
        try stdout.flush();
    } else {
        log.err("Could not fork", .{});
    }
}

fn printSyscall(out: *std.Io.Writer, syscall: SyscallInfo, registers: sys.user_regs_struct) !void {
    try out.print("{s}(", .{syscall.name});
    for (syscall.regs, 0..) |reg_name, i| {
        const reg_val: u64 = getRegisterValue(reg_name, registers);
        try out.print("{d}", .{reg_val});
        if (i != syscall.regs.len - 1) {
            try out.writeAll(", ");
        }
    }
    try out.print(") = {d}\n", .{registers.rax});
}

fn getRegisterValue(reg_name: []const u8, registers: sys.user_regs_struct) u64 {
    const val: u64 = blk: inline for (comptime std.meta.fieldNames(sys.user_regs_struct)) |name| {
        if (std.mem.eql(u8, reg_name, name)) {
            break :blk @intCast(@field(registers, name));
        }
    } else std.process.fatal("Could not find field {s}", .{reg_name});

    return val;
}
