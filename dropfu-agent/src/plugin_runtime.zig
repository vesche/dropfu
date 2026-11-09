const std = @import("std");
const Allocator = std.mem.Allocator;
const conn = @import("conn.zig");
const protocol = @import("dropfu_protocol");

const plugin_dir = "plugins";

pub fn install(allocator: Allocator, io: std.Io, environ: std.process.Environ, name: []const u8) ![]const u8 {
    if (!protocol.validatePluginName(name)) return allocator.dupe(u8, "error: invalid plugin name");

    std.Io.Dir.cwd().createDirPath(io, plugin_dir) catch |e|
        return allocator.print("error: cannot create plugin directory: {}", .{e});

    const host = try envOwned(allocator, environ, "DROPFU_SERVER_HOST", "127.0.0.1");
    defer allocator.free(host);
    const port_str = try envOwned(allocator, environ, "DROPFU_CLIENT_PORT", "8443");
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8443;
    const token = try envOwned(allocator, environ, "DROPFU_AGENT_TOKEN", "");
    defer allocator.free(token);

    const stream = conn.connectHost(io, host, port) catch
        return allocator.print("error: cannot connect to server {s}:{d}", .{ host, port });
    defer stream.close();

    var req_buf: [2048]u8 = undefined;
    const req = if (token.len > 0)
        std.fmt.bufPrint(&req_buf, "GET /plugins/{s}.pyz HTTP/1.1\r\nHost: {s}\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{ name, host, token }) catch
            return allocator.dupe(u8, "error: request too large")
    else
        std.fmt.bufPrint(&req_buf, "GET /plugins/{s}.pyz HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ name, host }) catch
            return allocator.dupe(u8, "error: request too large");
    stream.writeAll(req) catch return allocator.dupe(u8, "error: failed to send request");

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var tmp: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = stream.read(&tmp) catch |e|
            return allocator.print("error: plugin download failed: {}", .{e});
        if (n == 0) break;
        total += n;
        if (total > protocol.MAX_PLUGIN_BYTES + 8192) {
            return allocator.dupe(u8, "error: plugin response too large");
        }
        try resp.appendSlice(allocator, tmp[0..n]);
    }

    const hdr_end = std.mem.find(u8, resp.items, "\r\n\r\n") orelse
        return allocator.dupe(u8, "error: invalid HTTP response");

    if (!std.mem.startsWith(u8, resp.items, "HTTP/1.1 200"))
        return allocator.print("error: server returned non-200 for plugin '{s}'", .{name});

    const body = resp.items[hdr_end + 4 ..];
    if (body.len > protocol.MAX_PLUGIN_BYTES)
        return allocator.dupe(u8, "error: plugin too large");
    if (contentLength(resp.items[0..hdr_end])) |expected| {
        if (body.len != expected)
            return allocator.print("error: incomplete plugin response (expected {d} bytes, received {d})", .{ expected, body.len });
    } else {
        return allocator.dupe(u8, "error: plugin response missing Content-Length");
    }

    // Atomic install: write to temp then rename.
    var tmp_buf: [512]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}/{s}.pyz.tmp", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");
    var path_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");

    writePluginAtomically(io, std.Io.Dir.cwd(), tmp_path, dest, body) catch |e|
        return allocator.print("error: plugin install failed: {}", .{e});

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(body);
    const digest = hasher.finalResult();
    const hex = try protocol.hexEncode(allocator, &digest);
    defer allocator.free(hex);

    return allocator.print("plugin '{s}' installed ({d} bytes, sha256={s})", .{ name, body.len, hex });
}

pub fn listPackages(allocator: Allocator, io: std.Io, environ: std.process.Environ) ![]const u8 {
    const host = try envOwned(allocator, environ, "DROPFU_SERVER_HOST", "127.0.0.1");
    defer allocator.free(host);
    const port_str = try envOwned(allocator, environ, "DROPFU_CLIENT_PORT", "8443");
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8443;
    const token = try envOwned(allocator, environ, "DROPFU_AGENT_TOKEN", "");
    defer allocator.free(token);

    const stream = conn.connectHost(io, host, port) catch
        return allocator.print("error: cannot connect to server {s}:{d}", .{ host, port });
    defer stream.close();

    var req_buf: [1024]u8 = undefined;
    const req = if (token.len > 0)
        std.fmt.bufPrint(&req_buf, "GET /plugins/list HTTP/1.1\r\nHost: {s}\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{ host, token }) catch
            return allocator.dupe(u8, "error: request too large")
    else
        std.fmt.bufPrint(&req_buf, "GET /plugins/list HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host}) catch
            return allocator.dupe(u8, "error: request too large");
    stream.writeAll(req) catch return allocator.dupe(u8, "error: failed to send request");

    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = stream.read(&tmp) catch |e|
            return allocator.print("error: plugin list download failed: {}", .{e});
        if (n == 0) break;
        total += n;
        if (total > 1024 * 1024) return allocator.dupe(u8, "error: list response too large");
        try resp.appendSlice(allocator, tmp[0..n]);
    }

    const hdr_end = std.mem.find(u8, resp.items, "\r\n\r\n") orelse
        return allocator.dupe(u8, "error: invalid server response");
    if (!std.mem.startsWith(u8, resp.items, "HTTP/1.1 200"))
        return allocator.dupe(u8, "error: server returned non-200");

    const body = resp.items[hdr_end + 4 ..];

    var available: std.ArrayList([]const u8) = .empty;
    defer available.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] == '"') {
            const start = i + 1;
            i += 1;
            while (i < body.len and body[i] != '"') : (i += 1) {}
            if (i <= body.len) {
                try available.append(allocator, body[start..i]);
            }
        }
    }

    var installed_set: std.ArrayList([]const u8) = .empty;
    defer installed_set.deinit(allocator);

    if (std.Io.Dir.cwd().openDir(io, plugin_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".pyz")) continue;
            const base = entry.name[0 .. entry.name.len - 4];
            try installed_set.append(allocator, try allocator.dupe(u8, base));
        }
    } else |_| {}
    defer for (installed_set.items) |s| allocator.free(s);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try out.writer.print("Packages ({d} available):\n\n", .{available.items.len});
    for (available.items) |name| {
        const is_installed = blk: {
            for (installed_set.items) |ins| {
                if (std.mem.eql(u8, ins, name)) break :blk true;
            }
            break :blk false;
        };
        if (is_installed) {
            try out.writer.print("  {s: <20} [installed]\n", .{name});
        } else {
            try out.writer.print("  {s: <20} (not installed)\n", .{name});
        }
    }

    if (available.items.len == 0) {
        try out.writer.writeAll("  (no packages available on server)\n");
    }

    try out.writer.writeAll("\nUse 'plugin install <name>' to install a package.");
    return try out.toOwnedSlice();
}

pub fn uninstall(allocator: Allocator, io: std.Io, name: []const u8) ![]const u8 {
    if (!protocol.validatePluginName(name)) return allocator.dupe(u8, "error: invalid plugin name");
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");

    std.Io.Dir.cwd().access(io, path, .{}) catch
        return allocator.print("error: plugin '{s}' is not installed", .{name});

    std.Io.Dir.cwd().deleteFile(io, path) catch |e|
        return allocator.print("error: cannot remove plugin '{s}': {}", .{ name, e });

    return allocator.print("plugin '{s}' uninstalled", .{name});
}

pub fn execute(allocator: Allocator, io: std.Io, name: []const u8, args: []const []const u8) ![]const u8 {
    if (!protocol.validatePluginName(name)) return allocator.dupe(u8, "error: invalid plugin name");
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");

    std.Io.Dir.cwd().access(io, path, .{}) catch
        return allocator.print("error: plugin '{s}' not installed (run: plugin install {s})", .{ name, name });

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, "python3");
    try argv.append(allocator, path);
    for (args) |a| try argv.append(allocator, a);

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(protocol.MAX_COMMAND_OUTPUT),
        .stderr_limit = .limited(256 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    }) catch |e| return allocator.print("error: failed to run plugin: {}", .{e});

    defer allocator.free(result.stderr);
    const exit_ok = result.term.success();

    if (result.stderr.len > 0) {
        const combined = allocator.print("{s}\n--- stderr ---\n{s}\n(exit ok={})", .{ result.stdout, result.stderr, exit_ok }) catch {
            return result.stdout;
        };
        allocator.free(result.stdout);
        return combined;
    }
    if (!exit_ok) {
        const msg = allocator.print("{s}\n(plugin exited with failure)", .{result.stdout}) catch return result.stdout;
        allocator.free(result.stdout);
        return msg;
    }
    return result.stdout;
}

fn envOwned(allocator: Allocator, environ: std.process.Environ, key: []const u8, default: []const u8) ![]u8 {
    return std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => try allocator.dupe(u8, default),
        else => |e| return e,
    };
}

fn contentLength(headers: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], &std.ascii.whitespace), "Content-Length")) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
        return std.fmt.parseInt(usize, value, 10) catch null;
    }
    return null;
}

fn writePluginAtomically(io: std.Io, dir: std.Io.Dir, tmp_path: []const u8, dest: []const u8, body: []const u8) !void {
    const file = try dir.createFile(io, tmp_path, .{ .truncate = true });
    errdefer dir.deleteFile(io, tmp_path) catch {};
    {
        defer file.close(io);
        try file.writeStreamingAll(io, body);
    }
    try dir.rename(tmp_path, dir, dest, io);
}

test "content length parsing" {
    try std.testing.expectEqual(@as(?usize, 123), contentLength("HTTP/1.1 200 OK\r\ncontent-length: 123\r\nContent-Type: application/octet-stream"));
    try std.testing.expectEqual(@as(?usize, null), contentLength("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream"));
    try std.testing.expectEqual(@as(?usize, null), contentLength("HTTP/1.1 200 OK\r\nContent-Length: invalid"));
}

test "plugin file install is atomic and closes once" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePluginAtomically(io, tmp.dir, "portscan.pyz.tmp", "portscan.pyz", "plugin-body");
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "portscan.pyz.tmp", .{}));

    const installed = try tmp.dir.readFileAlloc(io, "portscan.pyz", allocator, .limited(64));
    defer allocator.free(installed);
    try std.testing.expectEqualStrings("plugin-body", installed);
}
