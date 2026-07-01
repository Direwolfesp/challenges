const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

// TODO: use alterante buffer, hide cursor
// and add a trap handler for restoring terminal

const cursor_home = "\x1B[2J";
const clear_screen = "\x1B[H";

const CpuMonitor = struct {
    registry: std.AutoHashMap(u32, Timings),
    gpa: Allocator,
    out: *Io.Writer,
    max_cpu: ?u32 = null,

    const Timings = struct {
        busy: u64,
        idle: u64,
        old_busy: ?u64 = null,
        old_idle: ?u64 = null,
    };

    pub fn init(gpa: Allocator, out: *Io.Writer) CpuMonitor {
        return .{
            .out = out,
            .gpa = gpa,
            .registry = .init(gpa),
        };
    }

    pub fn deinit(self: *CpuMonitor) void {
        self.registry.deinit();
    }

    fn readProcStat(io: Io, wr: *Io.Writer) !void {
        const proc = try Io.Dir.cwd().openFile(io, "/proc/stat", .{});
        defer proc.close(io);

        var read_buf: [2048]u8 = undefined;
        var proc_reader = proc.reader(io, &read_buf);
        _ = try proc_reader.interface.streamRemaining(wr);
    }

    fn update(self: *CpuMonitor, contents: []const u8) !void {
        var lines = std.mem.tokenizeScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            var words = std.mem.tokenizeScalar(u8, line, ' ');
            const key = words.next().?;
            // skip 'cpu', allow 'cpuX'
            if (std.mem.startsWith(u8, key, "cpu") and key.len > 3) {
                const user_str = words.next().?;
                const nice_str = words.next().?;
                const system_str = words.next().?;
                const idle_str = words.next().?;
                const iowait_str = words.next().?;
                const irq_str = words.next().?;
                const soft_irq_str = words.next().?;
                const steal_str = words.next().?;
                const guest_str = words.next().?;
                const guest_nice_str = words.next().?;

                const user = try std.fmt.parseInt(u64, user_str, 10);
                const nice = try std.fmt.parseInt(u64, nice_str, 10);
                const system = try std.fmt.parseInt(u64, system_str, 10);
                const idle = try std.fmt.parseInt(u64, idle_str, 10);
                const iowait = try std.fmt.parseInt(u64, iowait_str, 10);
                const irq = try std.fmt.parseInt(u64, irq_str, 10);
                const soft_irq = try std.fmt.parseInt(u64, soft_irq_str, 10);
                const steal = try std.fmt.parseInt(u64, steal_str, 10);
                const guest = try std.fmt.parseInt(u64, guest_str, 10);
                const guest_nice = try std.fmt.parseInt(u64, guest_nice_str, 10);

                const busy_time = user + nice + system + irq + soft_irq + steal + guest + guest_nice;
                const idle_time = idle + iowait;
                const cpu_number = try std.fmt.parseInt(u8, key[3..], 10);

                if (self.max_cpu) |*max_cpu| {
                    max_cpu.* = @max(max_cpu.*, cpu_number);
                } else {
                    self.max_cpu = cpu_number;
                }

                // update old values if present or insert a
                // new entry.
                if (self.registry.getEntry(cpu_number)) |entry| {
                    const timing: *Timings = entry.value_ptr;
                    timing.old_busy = timing.busy;
                    timing.old_idle = timing.idle;
                    timing.busy = busy_time;
                    timing.idle = idle_time;
                } else {
                    try self.registry.put(cpu_number, Timings{
                        .busy = busy_time,
                        .idle = idle_time,
                    });
                }
            }
        }
    }

    fn display(self: *CpuMonitor) !void {
        try self.out.writeAll(cursor_home ++ clear_screen);
        try self.out.print("CPU usage monitor\n", .{});

        for (0..self.max_cpu.? + 1) |cpu| {
            const cpu_num: u32 = @intCast(cpu);
            const timings = self.registry.get(cpu_num) orelse continue;
            try self.printBar(cpu_num, timings);
        }
    }

    const BarOptions = struct {
        pub const LENGTH = 50;
        pub const CHAR = "|";
        pub const EMPTY_CHAR = ' ';
    };

    fn printBar(self: *CpuMonitor, cpu: u32, timing: Timings) !void {
        const busy_delta: f64 = @floatFromInt(timing.busy - (timing.old_busy orelse 0));
        const idle_delta: f64 = @floatFromInt(timing.idle - (timing.old_idle orelse 0));
        const total: f64 = busy_delta + idle_delta;

        const usage: f64 = 100 * busy_delta / total;
        const num_bars: usize = @intFromFloat(try std.math.divFloor(f64, usage * BarOptions.LENGTH, 100));
        const empty_bars: usize = BarOptions.LENGTH - num_bars;

        try self.out.writeByte('[');
        try self.out.splatBytesAll(BarOptions.CHAR, num_bars);
        try self.out.splatByteAll(BarOptions.EMPTY_CHAR, empty_bars);
        try self.out.writeByte(']');
        try self.out.print(" cpu{d: <5} {d:.2}%\n", .{ cpu, usage });
    }

    pub fn runLoopTimed(self: *CpuMonitor, io: Io, timeout: Io.Duration) !void {
        const stat_buf: []u8 = try self.gpa.alloc(u8, 1024 * 20);
        defer self.gpa.free(stat_buf);

        while (true) {
            const start: Io.Timestamp = .now(io, .awake);
            const deadline = start.addDuration(timeout);

            var wr: Io.Writer = .fixed(stat_buf);
            try readProcStat(io, &wr);
            const data = wr.buffered();

            try self.update(data);
            try self.display();

            const end: Io.Timestamp = .now(io, .awake);
            const left = end.durationTo(deadline);
            if (left.toNanoseconds() < 0) continue;
            try io.sleep(left, .awake);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var stdout_buf: [3]u8 = undefined;
    var stdout_wr: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_wr.interface;

    var mon: CpuMonitor = .init(gpa, stdout);
    defer mon.deinit();
    try mon.runLoopTimed(io, .fromMilliseconds(400));

    try stdout.flush();
}
