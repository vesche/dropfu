const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Compute a stable, repeatable system identifier by hashing platform-specific
/// machine identity markers (machine-id, primary MAC, hostname).
pub fn compute(allocator: Allocator) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    switch (builtin.os.tag) {
        .linux => {
            feedFile(&hasher, "/etc/machine-id");
            feedFile(&hasher, "/var/lib/dbus/machine-id");
            feedMac(&hasher, allocator);
        },
        .macos => {
            feedCommand(&hasher, allocator, &.{ "ioreg", "-rd1", "-c", "IOPlatformExpertDevice" });
            feedMac(&hasher, allocator);
        },
        .windows => {
            if (std.process.getEnvVarOwned(allocator, "COMPUTERNAME")) |v| {
                hasher.update(v);
                allocator.free(v);
            } else |_| {}
            if (std.process.getEnvVarOwned(allocator, "USERDOMAIN")) |v| {
                hasher.update(v);
                allocator.free(v);
            } else |_| {}
        },
        else => {},
    }

    feedHostname(&hasher, allocator);

    const digest = hasher.finalResult();
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = "0123456789abcdef"[b >> 4];
        hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return allocator.dupe(u8, &hex);
}

// ---------------------------------------------------------------------------
fn feedFile(hasher: *std.crypto.hash.sha2.Sha256, path: []const u8) void {
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.read(&buf) catch return;
    hasher.update(std.mem.trim(u8, buf[0..n], &std.ascii.whitespace));
}

fn feedHostname(hasher: *std.crypto.hash.sha2.Sha256, allocator: Allocator) void {
    if (builtin.os.tag == .windows) {
        if (std.process.getEnvVarOwned(allocator, "COMPUTERNAME")) |v| {
            hasher.update(v);
            allocator.free(v);
        } else |_| {}
    } else {
        var buf: [256]u8 = undefined;
        const f = std.fs.openFileAbsolute("/etc/hostname", .{}) catch return;
        defer f.close();
        const n = f.read(&buf) catch return;
        hasher.update(std.mem.trim(u8, buf[0..n], &std.ascii.whitespace));
    }
}

fn feedMac(hasher: *std.crypto.hash.sha2.Sha256, _: Allocator) void {
    if (builtin.os.tag != .linux) return;
    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (std.mem.eql(u8, entry.name, "lo")) continue;
        var pbuf: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "/sys/class/net/{s}/address", .{entry.name}) catch continue;
        const f = std.fs.openFileAbsolute(p, .{}) catch continue;
        defer f.close();
        var mbuf: [64]u8 = undefined;
        const n = f.read(&mbuf) catch continue;
        const mac = std.mem.trim(u8, mbuf[0..n], &std.ascii.whitespace);
        if (mac.len > 0 and !std.mem.eql(u8, mac, "00:00:00:00:00:00")) {
            hasher.update(mac);
            return;
        }
    }
}

fn feedCommand(hasher: *std.crypto.hash.sha2.Sha256, allocator: Allocator, argv: []const []const u8) void {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    hasher.update(result.stdout);
}
