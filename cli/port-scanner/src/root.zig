//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const MAX_PORT = std.math.maxInt(u16);

/// Expands addresses like: 192.168.1.*
fn expandAddressWildcard(gpa: Allocator, address: []const u8) !std.ArrayList([]const u8) {
    var addresses: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (addresses.items) |a| gpa.free(a);
        addresses.deinit(gpa);
    }

    switch (std.mem.count(u8, address, "*")) {
        0 => {
            try Io.net.HostName.validate(address);
            const owned_addr = try gpa.dupe(u8, address);
            errdefer gpa.free(owned_addr);
            try addresses.append(gpa, owned_addr);
        },
        1 => {
            var components: [4][]const u8 = undefined;
            var wildcard_pos: u8 = 0;
            var i: u8 = 0;

            var iter = std.mem.tokenizeAny(u8, address, ".");
            while (iter.next()) |octect| : (i += 1) {
                if (i >= 4) break;
                components[i] = octect;

                if (octect.len == 1 and octect[0] == '*') {
                    wildcard_pos = i;
                }
            }

            // reserve memory for all options
            try addresses.ensureTotalCapacity(gpa, 0xff);

            // generate all possible combinations
            for (0..0xff + 1) |value| {
                var buf: [64]u8 = undefined;
                var w: Io.Writer = .fixed(&buf);
                inline for (0..4) |j| {
                    if (j == wildcard_pos) {
                        try w.print("{d}", .{value});
                    } else {
                        try w.print("{s}", .{components[j]});
                    }
                    if (j != 3) try w.writeByte('.');
                }

                const addr = w.buffered();

                // asserts its a valid ip
                try Io.net.HostName.validate(addr);
                const owned_addr = try gpa.dupe(u8, addr);
                errdefer gpa.free(owned_addr);
                try addresses.append(gpa, owned_addr);
            }
        },
        else => return error.UnsupportedWildcard,
    }

    return addresses;
}

test expandAddressWildcard {
    const gpa = std.testing.allocator;
    var addresses = try expandAddressWildcard(gpa, "182.10.133.*");
    defer {
        for (addresses.items) |ip| gpa.free(ip);
        addresses.deinit(gpa);
    }
    try std.testing.expectEqual(256, addresses.items.len);
}

pub const PortRange = union(enum) {
    all,
    one: u16,
    range: struct {
        start: u16,
        end: u16,
    },
};

const ScanResult = struct {
    port: u16,
    status: enum {
        open,
        closed,
    },
};

const defaultScan = vanillaScan;

/// The most basic scan, complete a full TCP handshake
/// Returns true if the port is open
fn vanillaScan(io: Io, address: []const u8, port: u16) bool {
    const host = Io.net.HostName.init(address) catch return false;
    const s = host.connect(io, port, .{
        .mode = .stream,
        .protocol = .tcp,
        .timeout = .none,
    }) catch return false;
    s.close(io);
    return true;
}

/// Worker function that updates a global counter and
/// performs the scan at that port, appending the
/// result to `results.`
fn scannerProducer(
    io: Io,
    results: *Io.Queue(ScanResult),
    port_counter: *std.atomic.Value(u16),
    address: []const u8,
) void {
    while (true) {
        const port = port_counter.fetchAdd(1, .monotonic);
        const open = vanillaScan(io, address, port);

        results.putOne(io, .{
            .port = port,
            .status = if (open) .open else .closed,
        }) catch |err| switch (err) {
            error.Canceled => return,
            error.Closed => return,
        };

        // we are scanning the last port
        // close the queue so the comsumer does
        // not halt forever.
        if (port == MAX_PORT) {
            results.close(io);
            break;
        }
    }
}

pub fn consumeScanResult(io: Io, results: *Io.Queue(ScanResult)) void {
    while (true) {
        const result = results.getOne(io) catch |err| switch (err) {
            error.Closed => break,
            error.Canceled => return,
        };

        switch (result.status) {
            .open => std.debug.print("Port: {d} is open\n", .{result.port}),
            .closed => {},
        }
    }
}

pub fn scanPorts(io: Io, gpa: Allocator, address: []const u8, ports: PortRange) !void {
    var addresses = try expandAddressWildcard(gpa, address);
    defer {
        for (addresses.items) |ip| gpa.free(ip);
        addresses.deinit(gpa);
    }

    for (addresses.items) |addr| {
        std.debug.print("Scanning host: {s}\n", .{addr});
        switch (ports) {
            .all => {
                var port_ticket: std.atomic.Value(u16) = .init(1);
                var result_buf: [512]ScanResult = undefined;
                var results: Io.Queue(ScanResult) = .init(&result_buf);
                defer results.close(io);

                var group: Io.Group = .init;
                defer group.cancel(io);

                try group.concurrent(io, consumeScanResult, .{ io, &results });

                // TODO: how many should I spawn?
                for (0..10) |_| {
                    group.async(io, scannerProducer, .{ io, &results, &port_ticket, address });
                }

                try group.await(io);
            },
            .one => |port| {
                const open = defaultScan(io, addr, port);
                if (open) {
                    std.debug.print("Port: {d} is open\n", .{port});
                }
            },
            .range => @panic("TODO: ranged port scan"),
        }
    }
}

test {
    _ = std.testing.refAllDecls(@This());
}
