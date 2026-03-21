const std = @import("std");
const protocol = @import("protocol.zig");
const websocket = @import("websocket.zig");
const State = @import("state.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const client_port = envPort("DROPFU_CLIENT_PORT", 8443);
    const agent_port = envPort("DROPFU_AGENT_PORT", 9443);

    const plugin_dir: []const u8 = std.process.getEnvVarOwned(allocator, "DROPFU_PLUGIN_DIR") catch
        try allocator.dupe(u8, "./plugins");
    defer allocator.free(plugin_dir);

    var state = State.init(allocator);
    defer state.deinit();

    std.log.info("dropfu-server v1.0.0", .{});
    std.log.info("  client port : {d}", .{client_port});
    std.log.info("  agent  port : {d}", .{agent_port});
    std.log.info("  plugin dir  : {s}", .{plugin_dir});

    const t1 = try std.Thread.spawn(.{}, listenClients, .{ allocator, &state, client_port, plugin_dir });
    const t2 = try std.Thread.spawn(.{}, listenAgents, .{ allocator, &state, agent_port });
    t1.join();
    t2.join();
}

// ---------------------------------------------------------------------------
// Client listener (WebSocket + HTTP plugin download)
// ---------------------------------------------------------------------------

fn listenClients(allocator: std.mem.Allocator, state: *State, port: u16, plugin_dir: []const u8) void {
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = addr.listen(.{ .reuse_address = true }) catch |e| {
        std.log.err("client listen failed: {}", .{e});
        return;
    };
    defer server.deinit();
    std.log.info("client listener ready on :{d}", .{port});

    while (true) {
        const conn = server.accept() catch continue;
        _ = std.Thread.spawn(.{}, handleClientConn, .{ allocator, state, conn.stream, plugin_dir }) catch continue;
    }
}

fn handleClientConn(allocator: std.mem.Allocator, state: *State, stream: std.net.Stream, plugin_dir: []const u8) void {
    defer stream.close();
    var http_buf: [8192]u8 = undefined;
    const req = websocket.readHttpRequest(stream, &http_buf) catch |e| {
        std.log.err("client: read request failed: {}", .{e});
        return;
    };

    std.log.info("client: {s} {s} kind={s}", .{
        req.method,
        req.path,
        switch (req.kind) {
            .websocket => @as([]const u8, "ws"),
            .http_get => "get",
            .other => "other",
        },
    });

    switch (req.kind) {
        .websocket => {
            websocket.completeHandshake(stream, req.raw) catch |e| {
                std.log.err("client: handshake failed: {}", .{e});
                return;
            };
            std.log.info("client: websocket established", .{});
            runClientWs(allocator, state, stream);
        },
        .http_get => serveHttp(stream, req.path, plugin_dir),
        .other => websocket.sendHttp(stream, "405 Method Not Allowed", "text/plain", "method not allowed"),
    }
}

fn runClientWs(allocator: std.mem.Allocator, state: *State, stream: std.net.Stream) void {
    const client = state.addClient(stream) catch |e| {
        std.log.err("client: addClient failed: {}", .{e});
        return;
    };
    defer state.removeClient(client);

    state.sendAgentList(allocator, stream) catch |e| {
        std.log.err("client: sendAgentList failed: {}", .{e});
    };

    std.log.info("client: entering message loop", .{});
    var buf: [1 << 18]u8 = undefined;
    while (true) {
        const msg = websocket.readMessage(stream, &buf) catch |e| {
            std.log.info("client: readMessage error: {}", .{e});
            break;
        };
        switch (msg.opcode) {
            .text => state.routeToAgent(allocator, msg.payload) catch {},
            .ping => websocket.sendPong(stream, msg.payload),
            .close => {
                std.log.info("client: received close frame", .{});
                break;
            },
            else => {},
        }
    }
}

fn serveHttp(stream: std.net.Stream, path: []const u8, plugin_dir: []const u8) void {
    if (std.mem.eql(u8, path, "/plugins/list")) {
        servePluginList(stream, plugin_dir);
        return;
    }
    if (std.mem.startsWith(u8, path, "/plugins/")) {
        const name = path["/plugins/".len..];
        if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) {
            websocket.sendHttp(stream, "400 Bad Request", "text/plain", "bad path");
            return;
        }
        var path_buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ plugin_dir, name }) catch {
            websocket.sendHttp(stream, "500 Internal Server Error", "text/plain", "path error");
            return;
        };
        const file = std.fs.cwd().openFile(full, .{}) catch {
            websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        defer file.close();
        const data = file.readToEndAlloc(std.heap.page_allocator, 50 * 1024 * 1024) catch {
            websocket.sendHttp(stream, "500 Internal Server Error", "text/plain", "read error");
            return;
        };
        defer std.heap.page_allocator.free(data);
        websocket.sendHttp(stream, "200 OK", "application/octet-stream", data);
    } else if (std.mem.eql(u8, path, "/health")) {
        websocket.sendHttp(stream, "200 OK", "text/plain", "ok");
    } else {
        websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
    }
}

fn servePluginList(stream: std.net.Stream, plugin_dir: []const u8) void {
    var dir = std.fs.cwd().openDir(plugin_dir, .{ .iterate = true }) catch {
        websocket.sendHttp(stream, "200 OK", "application/json", "[]");
        return;
    };
    defer dir.close();

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(std.heap.page_allocator);
    const w = out.writer(std.heap.page_allocator);
    w.writeByte('[') catch return;

    var first = true;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".pyz")) continue;
        const base = name[0 .. name.len - 4];
        if (!first) w.writeByte(',') catch {};
        w.print("\"{s}\"", .{base}) catch {};
        first = false;
    }
    w.writeByte(']') catch return;
    websocket.sendHttp(stream, "200 OK", "application/json", out.items);
}

// ---------------------------------------------------------------------------
// Agent listener (WebSocket only)
// ---------------------------------------------------------------------------

fn listenAgents(allocator: std.mem.Allocator, state: *State, port: u16) void {
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = addr.listen(.{ .reuse_address = true }) catch |e| {
        std.log.err("agent listen failed: {}", .{e});
        return;
    };
    defer server.deinit();
    std.log.info("agent listener ready on :{d}", .{port});

    while (true) {
        const conn = server.accept() catch continue;
        _ = std.Thread.spawn(.{}, handleAgentConn, .{ allocator, state, conn.stream }) catch continue;
    }
}

fn handleAgentConn(allocator: std.mem.Allocator, state: *State, stream: std.net.Stream) void {
    defer stream.close();
    websocket.acceptHandshake(stream) catch return;

    var buf: [1 << 18]u8 = undefined;
    const reg = websocket.readMessage(stream, &buf) catch return;
    if (reg.opcode != .text) return;

    const agent_id = state.registerAgent(allocator, reg.payload, stream) catch return;
    defer state.removeAgent(agent_id);
    state.broadcastAgentList(allocator);

    while (true) {
        const msg = websocket.readMessage(stream, &buf) catch break;
        switch (msg.opcode) {
            .text => state.broadcastToClients(msg.payload),
            .ping => websocket.sendPong(stream, msg.payload),
            .close => break,
            else => {},
        }
    }
    state.broadcastAgentList(allocator);
}

// ---------------------------------------------------------------------------
fn envPort(name: []const u8, default: u16) u16 {
    const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return default;
    defer std.heap.page_allocator.free(val);
    return std.fmt.parseInt(u16, val, 10) catch default;
}
