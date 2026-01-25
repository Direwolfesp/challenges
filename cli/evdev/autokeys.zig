//! Dumb keyboard typer for linux.
//! Compile with: zig build-exe autokeys.zig -lc
//! Zig version: 0.15.2

const std = @import("std");
const linux = @cImport(@cInclude("linux/input.h"));

const KeyAction = enum(i32) {
    PRESSED = 1,
    RELEASED = 0,
    HOLD = 2,
};

const KeyCode = enum(i32) {
    // zig fmt: off
    // letters
    a = linux.KEY_A, b = linux.KEY_B, c = linux.KEY_C,
    d = linux.KEY_D, e = linux.KEY_E, f = linux.KEY_F,
    g = linux.KEY_G, h = linux.KEY_H, i = linux.KEY_I,
    j = linux.KEY_J, k = linux.KEY_K, l = linux.KEY_L,
    m = linux.KEY_M, n = linux.KEY_N, o = linux.KEY_O,
    p = linux.KEY_P, q = linux.KEY_Q, r = linux.KEY_R,
    s = linux.KEY_S, t = linux.KEY_T, u = linux.KEY_U,
    v = linux.KEY_V, w = linux.KEY_W, x = linux.KEY_X,
    y = linux.KEY_Y, z = linux.KEY_Z,

    // numbers
    zero  = linux.KEY_0, one   = linux.KEY_1, two   = linux.KEY_2,
    three = linux.KEY_3, four  = linux.KEY_4, five  = linux.KEY_5,
    six   = linux.KEY_6, seven = linux.KEY_7, eight = linux.KEY_8,
    nine  = linux.KEY_9,

    // keypad numbers
    zero_kp  = linux.KEY_KP0, one_kp   = linux.KEY_KP1, two_kp   = linux.KEY_KP2,
    three_kp = linux.KEY_KP3, four_kp  = linux.KEY_KP4, five_kp  = linux.KEY_KP5,
    six_kp   = linux.KEY_KP6, seven_kp = linux.KEY_KP7, eight_kp = linux.KEY_KP8,
    nine_kp  = linux.KEY_KP9,

    // special
    space = linux.KEY_SPACE,
    comma = linux.KEY_COMMA,
    dot = linux.KEY_DOT,
    enter = linux.KEY_ENTER,
    // zig fmt: on

    pub fn toString(self: KeyCode) []const u8 {
        return switch (self) {
            .space => " ",
            .comma => ",",
            .dot => ".",
            .enter => "\n",
            .one, .one_kp => "1",
            .two, .two_kp => "2",
            .three, .three_kp => "3",
            .four, .four_kp => "4",
            .five, .five_kp => "5",
            .six, .six_kp => "6",
            .seven, .seven_kp => "7",
            .eight, .eight_kp => "8",
            .nine, .nine_kp => "9",
            else => |letter| @tagName(letter),
        };
    }

    pub fn fromString(char: u8) ?KeyCode {
        return switch (char) {
            'a'...'z' => std.meta.stringToEnum(KeyCode, &.{char}) orelse unreachable,
            'A'...'Z' => std.meta.stringToEnum(KeyCode, &.{char + 32}) orelse unreachable,
            '0' => .zero,
            '1' => .one,
            '2' => .two,
            '3' => .three,
            '4' => .four,
            '5' => .five,
            '6' => .six,
            '7' => .seven,
            '8' => .eight,
            '9' => .nine,
            ',' => .comma,
            '.' => .dot,
            ' ' => .space,
            '\n' => .enter,
            else => null,
        };
    }
};

fn syncEventFromKey(key: KeyCode) linux.input_event {
    var sync_ev: linux.input_event = .{
        .type = linux.EV_MSC,
        .code = linux.MSC_SCAN,
        .value = @intFromEnum(key),
    };
    _ = linux.gettimeofday(&sync_ev.time, null);
    return sync_ev;
}

fn keyEvent(key: KeyCode, action: KeyAction) linux.input_event {
    var key_press = linux.input_event{
        .type = linux.EV_KEY,
        .code = @intCast(@intFromEnum(key)),
        .value = @intFromEnum(action),
    };
    _ = linux.gettimeofday(&key_press.time, null);
    return key_press;
}

pub fn main() !void {
    var alloc: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer alloc.deinit();
    const arena = alloc.allocator();

    const args = try std.process.argsAlloc(arena);
    defer std.process.argsFree(arena, args);

    if (args.len != 3) {
        std.log.err(
            \\Sends <text> via key events (EV_KEY) to the desired device_file.
            \\Usage: ./main <device_file> <text> Elevated privileges may be needed.
        , .{});
        std.process.exit(1);
    }

    const filename, const text = .{ args[1], args[2] };

    const f = std.fs.openFileAbsolute(filename, .{ .mode = .write_only }) catch |err| {
        std.log.err("Cannot open file '{s}': {t}", .{ filename, err });
        std.process.exit(1);
    };
    defer f.close();

    var write_buf: [1024]u8 = undefined;
    var file_writer = f.writer(&write_buf);
    const file = &file_writer.interface;

    for (text) |b| {
        const key = KeyCode.fromString(b) orelse continue;

        const sync_ev = syncEventFromKey(key);
        const key_press = keyEvent(key, .PRESSED);
        const sync2_ev = syncEventFromKey(key);
        const key_release = keyEvent(key, .RELEASED);
        const sync3_ev = syncEventFromKey(key);

        try file.writeStruct(sync_ev, .little);
        try file.writeStruct(key_press, .little);
        try file.writeStruct(sync2_ev, .little);
        try file.writeStruct(key_release, .little);
        try file.writeStruct(sync3_ev, .little);
        try file.flush();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    try file.flush();
}
