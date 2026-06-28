const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Info = struct {
    short_desc: []const u8,
    long_desc: []const u8,
};

const port_raw_data = @embedFile("port-numbers.json");

pub fn getServicesInfo(arena: Allocator) !std.StringHashMap(Info) {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, port_raw_data, .{});

    const value_obj = switch (parsed) {
        .object => |o| o,
        else => return error.InvalidRoot,
    };

    var services: std.StringHashMap(Info) = .init(arena);
    errdefer services.deinit();

    try services.ensureTotalCapacity(50_000);

    var it = value_obj.iterator();
    while (it.next()) |entry| {
        services.putAssumeCapacity(entry.key_ptr.*, .{
            .short_desc = entry.value_ptr.array.items[0].string,
            .long_desc = entry.value_ptr.array.items[1].string,
        });
    }

    return services;
}
