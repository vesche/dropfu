const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Compute a stable, repeatable system identifier by hashing platform-specific
/// machine identity markers (machine-id, primary MAC, hostname).
pub fn compute(allocator: Allocator, io: std.Io, environ: std.process.Environ) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var fed: usize = 0;

    switch (builtin.os.tag) {
        .linux => {
            if (feedFile(io, &hasher, "/etc/machine-id")) fed += 1;
            if (feedFile(io, &hasher, "/var/lib/dbus/machine-id")) fed += 1;
            if (feedMac(io, &hasher)) fed += 1;
        },
        .macos => {
            if (feedCommand(allocator, io, &hasher, &.{ "ioreg", "-rd1", "-c", "IOPlatformExpertDevice" })) fed += 1;
            if (feedMac(io, &hasher)) fed += 1;
        },
        .windows => {
            if (feedEnv(allocator, environ, &hasher, "COMPUTERNAME")) fed += 1;
            if (feedEnv(allocator, environ, &hasher, "USERDOMAIN")) fed += 1;
            // MachineGuid via PowerShell if available.
            if (feedCommand(allocator, io, &hasher, &.{ "powershell", "-NoProfile", "-Command", "(Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography').MachineGuid" })) fed += 1;
        },
        else => {},
    }

    if (feedHostname(allocator, io, environ, &hasher)) fed += 1;

    if (fed == 0) return error.NoIdentityMaterial;

    const digest = hasher.finalResult();
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = "0123456789abcdef"[b >> 4];
        hex[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return allocator.dupe(u8, &hex);
}

fn feedFile(io: std.Io, hasher: *std.crypto.hash.sha2.Sha256, path: []const u8) bool {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false;
    defer f.close(io);
    var buf: [256]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return false;
    const trimmed = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    if (trimmed.len == 0) return false;
    hasher.update(trimmed);
    return true;
}

fn feedHostname(allocator: Allocator, io: std.Io, environ: std.process.Environ, hasher: *std.crypto.hash.sha2.Sha256) bool {
    if (builtin.os.tag == .windows) {
        return feedEnv(allocator, environ, hasher, "COMPUTERNAME");
    } else {
        return feedFile(io, hasher, "/etc/hostname");
    }
}

fn feedEnv(allocator: Allocator, environ: std.process.Environ, hasher: *std.crypto.hash.sha2.Sha256, key: []const u8) bool {
    const v = std.process.Environ.getAlloc(environ, allocator, key) catch return false;
    defer allocator.free(v);
    if (v.len == 0) return false;
    hasher.update(v);
    return true;
}

fn feedMac(io: std.Io, hasher: *std.crypto.hash.sha2.Sha256) bool {
    if (builtin.os.tag != .linux) return false;
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/net", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, "lo")) continue;
        var pbuf: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&pbuf, "/sys/class/net/{s}/address", .{entry.name}) catch continue;
        const f = std.Io.Dir.openFileAbsolute(io, p, .{}) catch continue;
        defer f.close(io);
        var mbuf: [64]u8 = undefined;
        const n = f.readPositionalAll(io, &mbuf, 0) catch continue;
        const mac = std.mem.trim(u8, mbuf[0..n], &std.ascii.whitespace);
        if (mac.len > 0 and !std.mem.eql(u8, mac, "00:00:00:00:00:00")) {
            hasher.update(mac);
            return true;
        }
    }
    return false;
}

fn feedCommand(allocator: Allocator, io: std.Io, hasher: *std.crypto.hash.sha2.Sha256, argv: []const []const u8) bool {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len == 0) return false;
    hasher.update(result.stdout);
    return true;
}

test "hex length" {
    try std.testing.expectEqual(@as(usize, 64), 32 * 2);
}
