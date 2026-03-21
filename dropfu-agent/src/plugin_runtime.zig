const std = @import("std");
const Allocator = std.mem.Allocator;

const plugin_dir = "plugins";

/// Download a plugin bundle from the server and store locally.
/// For the MVP the agent fetches via HTTP GET from the server's /plugins/ endpoint.
pub fn install(allocator: Allocator, name: []const u8) ![]const u8 {
    std.fs.cwd().makePath(plugin_dir) catch {};

    const host = std.process.getEnvVarOwned(allocator, "DROPFU_SERVER_HOST") catch
        try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(host);
    const port_str = std.process.getEnvVarOwned(allocator, "DROPFU_CLIENT_PORT") catch
        try allocator.dupe(u8, "8443");
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8443;

    const stream = std.net.tcpConnectToHost(allocator, host, port) catch
        return std.fmt.allocPrint(allocator, "error: cannot connect to server {s}:{d}", .{ host, port });
    defer stream.close();

    var req_buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET /plugins/{s}.pyz HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ name, host }) catch
        return allocator.dupe(u8, "error: request too large");
    _ = stream.write(req) catch return allocator.dupe(u8, "error: failed to send request");

    var resp: std.ArrayList(u8) = .{};
    defer resp.deinit(allocator);
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch break;
        if (n == 0) break;
        try resp.appendSlice(allocator, tmp[0..n]);
    }

    const hdr_end = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse
        return allocator.dupe(u8, "error: invalid HTTP response");

    if (!std.mem.startsWith(u8, resp.items, "HTTP/1.1 200"))
        return std.fmt.allocPrint(allocator, "error: server returned non-200 for plugin '{s}'", .{name});

    const body = resp.items[hdr_end + 4 ..];

    var path_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");

    const file = std.fs.cwd().createFile(dest, .{}) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot write plugin file: {}", .{e});
    defer file.close();
    file.writeAll(body) catch |e|
        return std.fmt.allocPrint(allocator, "error: write failed: {}", .{e});

    return std.fmt.allocPrint(allocator, "plugin '{s}' installed ({d} bytes)", .{ name, body.len });
}

/// Fetch available packages from the server and show install status.
pub fn listPackages(allocator: Allocator) ![]const u8 {
    const host = std.process.getEnvVarOwned(allocator, "DROPFU_SERVER_HOST") catch
        try allocator.dupe(u8, "127.0.0.1");
    defer allocator.free(host);
    const port_str = std.process.getEnvVarOwned(allocator, "DROPFU_CLIENT_PORT") catch
        try allocator.dupe(u8, "8443");
    defer allocator.free(port_str);
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8443;

    const stream = std.net.tcpConnectToHost(allocator, host, port) catch
        return std.fmt.allocPrint(allocator, "error: cannot connect to server {s}:{d}", .{ host, port });
    defer stream.close();

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET /plugins/list HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{host}) catch
        return allocator.dupe(u8, "error: request too large");
    _ = stream.write(req) catch return allocator.dupe(u8, "error: failed to send request");

    var resp: std.ArrayList(u8) = .{};
    defer resp.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch break;
        if (n == 0) break;
        try resp.appendSlice(allocator, tmp[0..n]);
    }

    const hdr_end = std.mem.indexOf(u8, resp.items, "\r\n\r\n") orelse
        return allocator.dupe(u8, "error: invalid server response");
    if (!std.mem.startsWith(u8, resp.items, "HTTP/1.1 200"))
        return allocator.dupe(u8, "error: server returned non-200");

    const body = resp.items[hdr_end + 4 ..];

    var available: std.ArrayList([]const u8) = .{};
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

    var installed_set: std.ArrayList([]const u8) = .{};
    defer installed_set.deinit(allocator);

    if (std.fs.cwd().openDir(plugin_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".pyz")) continue;
            const base = entry.name[0 .. entry.name.len - 4];
            try installed_set.append(allocator, try allocator.dupe(u8, base));
        }
    } else |_| {}
    defer for (installed_set.items) |s| allocator.free(s);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Packages ({d} available):\n\n", .{available.items.len});
    for (available.items) |name| {
        const is_installed = blk: {
            for (installed_set.items) |ins| {
                if (std.mem.eql(u8, ins, name)) break :blk true;
            }
            break :blk false;
        };
        if (is_installed) {
            try w.print("  {s: <20} [installed]\n", .{name});
        } else {
            try w.print("  {s: <20} (not installed)\n", .{name});
        }
    }

    if (available.items.len == 0) {
        try w.writeAll("  (no packages available on server)\n");
    }

    try w.writeAll("\nUse 'plugin install <name>' to install a package.");

    return out.toOwnedSlice(allocator);
}

/// Remove an installed plugin.
pub fn uninstall(allocator: Allocator, name: []const u8) ![]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");

    std.fs.cwd().access(path, .{}) catch
        return std.fmt.allocPrint(allocator, "error: plugin '{s}' is not installed", .{name});

    std.fs.cwd().deleteFile(path) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot remove plugin '{s}': {}", .{ name, e });

    return std.fmt.allocPrint(allocator, "plugin '{s}' uninstalled", .{name});
}

/// Execute a previously installed plugin via the system Python interpreter.
/// Plugins are stored as .zip archives containing __main__.py (zipapp format).
pub fn execute(allocator: Allocator, name: []const u8, args: []const []const u8) ![]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ plugin_dir, name }) catch
        return allocator.dupe(u8, "error: path too long");

    std.fs.cwd().access(path, .{}) catch
        return std.fmt.allocPrint(allocator, "error: plugin '{s}' not installed (run: plugin install {s})", .{ name, name });

    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    try argv.append(allocator, "python3");
    try argv.append(allocator, path);
    for (args) |a| try argv.append(allocator, a);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch |e| return std.fmt.allocPrint(allocator, "error: failed to run plugin: {}", .{e});

    defer allocator.free(result.stderr);
    if (result.stderr.len > 0) {
        const combined = std.fmt.allocPrint(allocator, "{s}\n--- stderr ---\n{s}", .{ result.stdout, result.stderr }) catch return result.stdout;
        allocator.free(result.stdout);
        return combined;
    }
    return result.stdout;
}
