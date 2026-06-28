//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = Io.net;

const PORT_MAX = std.math.maxInt(u16);

/// Performs a DNS lookup to resolve all ips for the given `hostname`
/// appending results to `results`
fn resolveHostname(io: Io, gpa: Allocator, hostname: []const u8, results: *std.ArrayList([]const u8)) !void {
    const host: net.HostName = try .init(hostname);
    var buf: [24]net.HostName.LookupResult = undefined;
    var q: Io.Queue(net.HostName.LookupResult) = .init(&buf);

    // not sure if the port is relevant here
    try host.lookup(io, &q, .{ .port = 0 });

    while (q.getOne(io)) |resolved_ip| switch (resolved_ip) {
        .address => |ip| {
            if (ip == .ip6) continue;
            const addr = try std.fmt.allocPrint(gpa, "{d}.{d}.{d}.{d}", .{
                ip.ip4.bytes[0],
                ip.ip4.bytes[1],
                ip.ip4.bytes[2],
                ip.ip4.bytes[3],
            });
            errdefer gpa.free(addr);
            try results.append(gpa, addr);
        },
        .canonical_name => continue,
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => {},
    }
}

/// Expands addresses like: 192.168.1.*
/// and resolves hostnames if necessary (ie. "localhost", "example.com")
fn resolveAddress(io: Io, gpa: Allocator, address: []const u8) !std.ArrayList([]const u8) {
    var addresses: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (addresses.items) |a| gpa.free(a);
        addresses.deinit(gpa);
    }

    // Its a textual host name, so resolve it with DNS
    if (std.mem.findAny(u8, address, std.ascii.lowercase)) |_| {
        try resolveHostname(io, gpa, address, &addresses);
    } else { // its a numeric ip
        switch (std.mem.count(u8, address, "*")) {
            0 => {
                try net.HostName.validate(address);
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
                    try net.HostName.validate(addr);
                    const owned_addr = try gpa.dupe(u8, addr);
                    errdefer gpa.free(owned_addr);
                    try addresses.append(gpa, owned_addr);
                }
            },
            else => return error.UnsupportedWildcard,
        }
    }

    return addresses;
}

test resolveAddress {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Expand glob
    {
        var addresses = try resolveAddress(io, gpa, "182.10.133.*");
        defer {
            for (addresses.items) |ip| gpa.free(ip);
            addresses.deinit(gpa);
        }
        try std.testing.expectEqual(256, addresses.items.len);
    }

    // Resolve hostname
    {
        var addresses = try resolveAddress(io, gpa, "localhost");
        defer {
            for (addresses.items) |ip| gpa.free(ip);
            addresses.deinit(gpa);
        }
        try std.testing.expectEqual(1, addresses.items.len);
        try std.testing.expectEqualSlices(u8, "127.0.0.1", addresses.items[0]);
    }
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
    const addr = net.IpAddress.parse(address, port) catch @panic("called with invalid ip");
    const s = addr.connect(io, .{
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
    max_port: u16,
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
        if (port == max_port) {
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
            .open => std.debug.print("Port: {d: >5} is open\n", .{result.port}),
            .closed => {},
        }
    }
}

/// Scans an address in a given range of ports.
/// Its responsible for spawning all the tasks for concurrency.
fn rangedScan(io: Io, address: []const u8, start: u16, end: u16) !void {
    var port_ticket: std.atomic.Value(u16) = .init(start);
    var result_buf: [512]ScanResult = undefined;
    var results: Io.Queue(ScanResult) = .init(&result_buf);
    defer results.close(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    try group.concurrent(io, consumeScanResult, .{ io, &results });

    // TODO: how many should I spawn?
    for (0..10) |_| {
        group.async(io, scannerProducer, .{ io, &results, &port_ticket, address, end });
    }

    try group.await(io);
}

/// Highest level function of the module
pub fn scanPorts(io: Io, gpa: Allocator, address: []const u8, ports: PortRange) !void {
    var addresses = try resolveAddress(io, gpa, address);
    defer {
        for (addresses.items) |ip| gpa.free(ip);
        addresses.deinit(gpa);
    }

    for (addresses.items) |addr| {
        std.debug.print("Scanning host: {s}\n", .{addr});
        switch (ports) {
            .all => {
                try rangedScan(io, addr, 1, PORT_MAX);
            },
            .range => |range| {
                try rangedScan(io, addr, range.start, range.end);
            },
            .one => |port| {
                const open = defaultScan(io, addr, port);
                if (open) {
                    std.debug.print("Port: {d: >5} is open\n", .{port});
                }
            },
        }
    }
}

test {
    _ = std.testing.refAllDecls(@This());
}
