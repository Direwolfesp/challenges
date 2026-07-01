const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;
const Allocator = std.mem.Allocator;

// Stinky global but its necessary for the signal shutdown
var is_running: std.atomic.Value(bool) = .init(true);

pub const AnsiCodes = struct {
    pub const cursor_home = "\x1B[H";
    pub const clear_screen = "\x1B[2J";
    pub const enable_alternate_buffer = "\x1B[?1049h";
    pub const disable_alternate_buffer = "\x1B[?1049l";
    pub const hide_the_cursor = "\x1B[?25l";
    pub const show_the_cursor = "\x1B[?25h";
};

const CpuMonitor = struct {
    registry: std.AutoHashMap(u32, Timings),
    gpa: Allocator,
    out: *Io.Writer,
    max_cpu: u32 = 0,

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

    /// Streams all `/proc/stat` content to `wr`
    fn readProcStat(io: Io, wr: *Io.Writer) !void {
        const proc = try Io.Dir.cwd().openFile(io, "/proc/stat", .{});
        defer proc.close(io);

        var read_buf: [2048]u8 = undefined;
        var proc_reader = proc.reader(io, &read_buf);
        _ = try proc_reader.interface.streamRemaining(wr);
    }

    /// Parses the /proc/stat data and update the internal timing stats
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

                // Update cpu count
                const cpu_number = try std.fmt.parseInt(u8, key[3..], 10);
                self.max_cpu = @max(self.max_cpu, cpu_number);

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

    /// Renders the main graphics
    fn display(self: *CpuMonitor) !void {
        try self.out.writeAll(AnsiCodes.cursor_home);
        try self.out.writeAll(AnsiCodes.clear_screen);
        try self.out.print("CPU usage monitor\n", .{});

        for (0..self.max_cpu + 1) |cpu| {
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

    /// Renders a CPU usage progress bar
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

    /// Shutdowns the main loop
    fn shutdown(sig: linux.SIG) callconv(.c) void {
        switch (sig) {
            .INT, .TERM => {
                is_running.store(false, .release);
            },
            else => unreachable,
        }
    }

    /// Registers shutdown funcion
    fn enableSignalHandler() void {
        var sa: linux.Sigaction = .{
            .handler = .{ .handler = shutdown },
            .flags = 0,
            .mask = linux.sigemptyset(),
        };
        _ = linux.sigaction(linux.SIG.TERM, &sa, null);
        _ = linux.sigaction(linux.SIG.INT, &sa, null);
    }

    pub fn setUpTerminal(self: *CpuMonitor) !void {
        try self.out.writeAll(AnsiCodes.enable_alternate_buffer);
        try self.out.writeAll(AnsiCodes.hide_the_cursor);
        try self.out.flush();
    }

    pub fn restoreTerminal(self: *CpuMonitor) !void {
        try self.out.writeAll(AnsiCodes.disable_alternate_buffer);
        try self.out.writeAll(AnsiCodes.show_the_cursor);
        try self.out.flush();
    }

    /// Runs the cpu monitor, blocking until a termination signal.
    pub fn runLoopTimed(self: *CpuMonitor, io: Io, timeout: Io.Duration) !void {
        const stat_buf: []u8 = try self.gpa.alloc(u8, 1024 * 20);
        defer self.gpa.free(stat_buf);

        enableSignalHandler();

        try self.setUpTerminal();
        defer self.restoreTerminal() catch @panic("Could not restore terminal");

        while (is_running.load(.acquire)) {
            const start: Io.Timestamp = .now(io, .awake);
            const deadline = start.addDuration(timeout);

            var wr: Io.Writer = .fixed(stat_buf);
            try readProcStat(io, &wr);
            const data = wr.buffered();

            try self.update(data);
            try self.display();
            try self.out.flush();

            const end: Io.Timestamp = .now(io, .awake);
            const left = end.durationTo(deadline);
            if (left.toNanoseconds() < 0) continue;

            // TODO: this does not get interrupted by signals, why?
            try io.sleep(left, .awake);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    var stdout_buf: [2048]u8 = undefined;
    var stdout_wr: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const stdout = &stdout_wr.interface;

    var mon: CpuMonitor = .init(gpa, stdout);
    defer mon.deinit();
    try mon.runLoopTimed(io, .fromMilliseconds(1000));

    try stdout.flush();
}
