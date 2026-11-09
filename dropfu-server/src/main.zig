const std = @import("std");
const builtin = @import("builtin");
const websocket = @import("websocket.zig");
const State = @import("state.zig");
const auth = @import("auth.zig");
const protocol = @import("dropfu_protocol");

const Config = struct {
    client_port: u16,
    agent_port: u16,
    plugin_dir: []const u8,
    static_dir: []const u8,
    bind_loopback: bool,
    allow_insecure: bool,
    allowed_origins: []const []const u8,
    tokens: auth.Tokens,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const allow_insecure = envBool(init.environ_map, "DROPFU_ALLOW_INSECURE", false);
    const bind_loopback = !envBool(init.environ_map, "DROPFU_BIND_ALL", false);

    const tokens = auth.Tokens.fromEnv(io, init.environ_map) catch |e| {
        std.log.err("auth config required: set DROPFU_OPERATOR_TOKEN and DROPFU_AGENT_TOKEN (or *_FILE). error: {}", .{e});
        std.log.err("tokens must be at least 16 characters", .{});
        return e;
    };

    var origins_list: std.ArrayList([]const u8) = .empty;
    defer origins_list.deinit(allocator);
    try origins_list.append(allocator, "http://127.0.0.1:3000");
    try origins_list.append(allocator, "http://localhost:3000");
    try origins_list.append(allocator, "https://127.0.0.1");
    try origins_list.append(allocator, "https://localhost");
    if (init.environ_map.get("DROPFU_ALLOWED_ORIGINS")) |raw| {
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |o| {
            const t = std.mem.trim(u8, o, &std.ascii.whitespace);
            if (t.len > 0) try origins_list.append(allocator, t);
        }
    }

    const client_port = envPort(init.environ_map, "DROPFU_CLIENT_PORT", 8443) catch |e| {
        std.log.err("invalid DROPFU_CLIENT_PORT: {}", .{e});
        return e;
    };
    const agent_port = envPort(init.environ_map, "DROPFU_AGENT_PORT", 9443) catch |e| {
        std.log.err("invalid DROPFU_AGENT_PORT: {}", .{e});
        return e;
    };
    if (client_port == agent_port) {
        std.log.err("client and agent ports must be different", .{});
        return error.PortConflict;
    }

    const instance_lock = acquireInstanceLock(allocator, io, init.environ_map, client_port, agent_port) catch |e| {
        if (e == error.ServerAlreadyRunning) {
            std.log.err("another dropfu-server already owns ports {d}/{d}", .{ client_port, agent_port });
        } else {
            std.log.err("cannot acquire server instance lock: {}", .{e});
        }
        return e;
    };
    defer {
        instance_lock.unlock(io);
        instance_lock.close(io);
    }

    const cfg = Config{
        .client_port = client_port,
        .agent_port = agent_port,
        .plugin_dir = init.environ_map.get("DROPFU_PLUGIN_DIR") orelse "./plugins",
        .static_dir = init.environ_map.get("DROPFU_STATIC_DIR") orelse "",
        .bind_loopback = bind_loopback,
        .allow_insecure = allow_insecure,
        .allowed_origins = origins_list.items,
        .tokens = tokens,
    };

    var state = State.init(allocator, io);
    defer state.deinit();

    const client_address: std.Io.net.IpAddress = if (cfg.bind_loopback)
        .{ .ip4 = .loopback(cfg.client_port) }
    else
        .{ .ip4 = .unspecified(cfg.client_port) };
    if (portAcceptingConnections(io, client_address)) {
        std.log.err("client port {d} is already in use", .{cfg.client_port});
        return error.AddressInUse;
    }
    // Zig's reuse_address also enables SO_REUSEPORT on POSIX. The instance
    // lock above prevents duplicate dropfu servers, while SO_REUSEADDR permits
    // immediate restart when prior connections remain in TIME_WAIT.
    var client_server = client_address.listen(io, .{ .reuse_address = true }) catch |e| {
        std.log.err("client listen failed: {}", .{e});
        return e;
    };
    errdefer client_server.deinit(io);

    const agent_address: std.Io.net.IpAddress = if (cfg.bind_loopback)
        .{ .ip4 = .loopback(cfg.agent_port) }
    else
        .{ .ip4 = .unspecified(cfg.agent_port) };
    if (portAcceptingConnections(io, agent_address)) {
        std.log.err("agent port {d} is already in use", .{cfg.agent_port});
        return error.AddressInUse;
    }
    var agent_server = agent_address.listen(io, .{ .reuse_address = true }) catch |e| {
        std.log.err("agent listen failed: {}", .{e});
        return e;
    };
    errdefer agent_server.deinit(io);

    std.log.info("dropfu-server v1.0.0 (protocol {d})", .{protocol.PROTOCOL_VERSION});
    std.log.info("  client port : {d}", .{cfg.client_port});
    std.log.info("  agent  port : {d}", .{cfg.agent_port});
    std.log.info("  plugin dir  : {s}", .{cfg.plugin_dir});
    std.log.info("  bind mode   : {s}", .{if (cfg.bind_loopback) "loopback" else "all interfaces"});
    if (cfg.allow_insecure) std.log.warn("DROPFU_ALLOW_INSECURE=1 — cleartext allowed for development", .{});

    const t1 = try std.Thread.spawn(.{}, listenClients, .{ allocator, &state, &cfg, client_server });
    const t2 = try std.Thread.spawn(.{}, listenAgents, .{ allocator, &state, &cfg, agent_server });
    t1.join();
    t2.join();
}

fn listenClients(allocator: std.mem.Allocator, state: *State, cfg: *const Config, server_arg: std.Io.net.Server) void {
    const io = state.io;
    var server = server_arg;
    defer server.deinit(io);
    std.log.info("client listener ready on :{d}", .{cfg.client_port});

    while (true) {
        const accepted = server.accept(io) catch continue;
        const c: websocket.Conn = .{ .io = io, .stream = accepted };
        _ = std.Thread.spawn(.{}, handleClientConn, .{ allocator, state, c, cfg }) catch {
            c.close();
            continue;
        };
    }
}

fn handleClientConn(allocator: std.mem.Allocator, state: *State, stream: websocket.Conn, cfg: *const Config) void {
    defer stream.close();
    var http_buf: [16384]u8 = undefined;
    const req = websocket.readHttpRequest(stream, &http_buf) catch return;

    switch (req.kind) {
        .websocket => {
            if (!authorizeClientWs(allocator, state.io, cfg, req.raw)) {
                websocket.sendHttp(stream, "401 Unauthorized", "text/plain", "unauthorized");
                return;
            }
            const origin = websocket.extractHeader(req.raw, "Origin");
            if (origin != null and !auth.originAllowed(origin, cfg.allowed_origins)) {
                // Allow missing Origin (non-browser) but reject bad browser Origin.
                websocket.sendHttp(stream, "403 Forbidden", "text/plain", "origin not allowed");
                return;
            }
            websocket.completeHandshake(stream, req.raw) catch return;
            runClientWs(allocator, state, stream);
        },
        .http_get => serveHttp(allocator, state.io, stream, req, cfg),
        .http_post => serveHttpPost(allocator, state.io, stream, req, cfg),
        .other => websocket.sendHttp(stream, "405 Method Not Allowed", "text/plain", "method not allowed"),
    }
}

fn authorizeClientWs(allocator: std.mem.Allocator, io: std.Io, cfg: *const Config, raw: []const u8) bool {
    if (auth.extractBearer(websocket.extractHeader(raw, "Authorization"))) |tok| {
        return cfg.tokens.verifyOperator(tok);
    }
    if (auth.extractCookie(websocket.extractHeader(raw, "Cookie"), "dropfu_session")) |sess| {
        return cfg.tokens.verifySession(allocator, io, sess);
    }
    // Also allow query token for browser WS (cookies preferred).
    return false;
}

fn runClientWs(allocator: std.mem.Allocator, state: *State, stream: websocket.Conn) void {
    const client = state.addClient(stream) catch return;
    defer state.removeClient(client);

    client.write_mutex.lockUncancelable(stream.io);
    state.sendAgentList(allocator, stream) catch {};
    client.write_mutex.unlock(stream.io);

    var buf: [protocol.MAX_PAYLOAD_BYTES]u8 = undefined;
    while (true) {
        const msg = websocket.readMessage(stream, &buf) catch break;
        switch (msg.opcode) {
            .text => {
                state.routeToAgent(allocator, client, msg.payload) catch |e| {
                    const code = switch (e) {
                        error.AgentNotFound => "agent_not_found",
                        error.DisallowedMessageType => "disallowed",
                        else => "route_error",
                    };
                    state.sendErrorToClient(allocator, client, "0", code, @errorName(e));
                };
            },
            .ping => {
                client.write_mutex.lockUncancelable(stream.io);
                defer client.write_mutex.unlock(stream.io);
                websocket.sendPong(stream, msg.payload);
            },
            .close => break,
            else => {},
        }
    }
}

fn serveHttpPost(allocator: std.mem.Allocator, io: std.Io, stream: websocket.Conn, req: websocket.HttpRequest, cfg: *const Config) void {
    if (std.mem.eql(u8, req.path, "/login")) {
        // Body may follow headers in the same buffer.
        const hdr_end = std.mem.find(u8, req.raw, "\r\n\r\n") orelse {
            websocket.sendHttp(stream, "400 Bad Request", "text/plain", "bad request");
            return;
        };
        const content_length_raw = websocket.extractHeader(req.raw, "Content-Length") orelse {
            websocket.sendHttp(stream, "411 Length Required", "text/plain", "content length required");
            return;
        };
        const content_length = std.fmt.parseInt(usize, content_length_raw, 10) catch {
            websocket.sendHttp(stream, "400 Bad Request", "text/plain", "invalid content length");
            return;
        };
        var body_buf: [4096]u8 = undefined;
        if (content_length > body_buf.len) {
            websocket.sendHttp(stream, "413 Content Too Large", "text/plain", "request body too large");
            return;
        }
        const initial = req.raw[hdr_end + 4 ..];
        const initial_len = @min(initial.len, content_length);
        @memcpy(body_buf[0..initial_len], initial[0..initial_len]);
        var body_len = initial_len;
        while (body_len < content_length) {
            const n = stream.read(body_buf[body_len..content_length]) catch {
                websocket.sendHttp(stream, "400 Bad Request", "text/plain", "incomplete request body");
                return;
            };
            if (n == 0) {
                websocket.sendHttp(stream, "400 Bad Request", "text/plain", "incomplete request body");
                return;
            }
            body_len += n;
        }
        const body = body_buf[0..content_length];
        // Expect {"token":"..."}
        var parsed = protocol.parse(allocator, body) catch {
            websocket.sendHttp(stream, "400 Bad Request", "text/plain", "invalid json");
            return;
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => {
                websocket.sendHttp(stream, "400 Bad Request", "text/plain", "invalid json");
                return;
            },
        };
        const token = protocol.getStr(root, "token") orelse {
            websocket.sendHttp(stream, "400 Bad Request", "text/plain", "missing token");
            return;
        };
        if (!cfg.tokens.verifyOperator(token)) {
            websocket.sendHttp(stream, "401 Unauthorized", "text/plain", "unauthorized");
            return;
        }
        const session = cfg.tokens.mintSession(allocator, io) catch {
            websocket.sendHttp(stream, "500 Internal Server Error", "text/plain", "session error");
            return;
        };
        defer allocator.free(session);

        var cookie_hdr: [512]u8 = undefined;
        const cookie = std.fmt.bufPrint(&cookie_hdr, "Set-Cookie: dropfu_session={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200{s}", .{
            session,
            if (cfg.allow_insecure) "" else "; Secure",
        }) catch {
            websocket.sendHttp(stream, "500 Internal Server Error", "text/plain", "cookie error");
            return;
        };
        websocket.sendHttpExtra(stream, "200 OK", "application/json", "{\"ok\":true}", &.{cookie});
        return;
    }
    websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
}

fn serveHttp(allocator: std.mem.Allocator, io: std.Io, stream: websocket.Conn, req: websocket.HttpRequest, cfg: *const Config) void {
    if (std.mem.eql(u8, req.path, "/health")) {
        websocket.sendHttp(stream, "200 OK", "text/plain", "ok");
        return;
    }

    if (std.mem.eql(u8, req.path, "/plugins/list") or std.mem.startsWith(u8, req.path, "/plugins/")) {
        if (!authorizePluginHttp(allocator, io, cfg, req.raw)) {
            websocket.sendHttp(stream, "401 Unauthorized", "text/plain", "unauthorized");
            return;
        }
        if (std.mem.eql(u8, req.path, "/plugins/list")) {
            servePluginList(stream, cfg.plugin_dir);
            return;
        }
        const name = req.path["/plugins/".len..];
        const base = if (std.mem.endsWith(u8, name, ".pyz")) name[0 .. name.len - 4] else name;
        if (!protocol.validatePluginName(base)) {
            websocket.sendHttp(stream, "400 Bad Request", "text/plain", "bad plugin name");
            return;
        }
        var path_buf: [1024]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buf, "{s}/{s}.pyz", .{ cfg.plugin_dir, base }) catch {
            websocket.sendHttp(stream, "500 Internal Server Error", "text/plain", "path error");
            return;
        };

        const data = std.Io.Dir.cwd().readFileAlloc(io, full, std.heap.page_allocator, .limited(protocol.MAX_PLUGIN_BYTES)) catch {
            websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        defer std.heap.page_allocator.free(data);
        websocket.sendHttp(stream, "200 OK", "application/octet-stream", data);
        return;
    }

    // Static SPA assets
    if (cfg.static_dir.len > 0) {
        serveStatic(io, stream, req.path, cfg.static_dir);
        return;
    }
    websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
}

fn authorizePluginHttp(allocator: std.mem.Allocator, io: std.Io, cfg: *const Config, raw: []const u8) bool {
    if (auth.extractBearer(websocket.extractHeader(raw, "Authorization"))) |tok| {
        return cfg.tokens.verifyAgent(tok) or cfg.tokens.verifyOperator(tok);
    }
    if (auth.extractCookie(websocket.extractHeader(raw, "Cookie"), "dropfu_session")) |sess| {
        return cfg.tokens.verifySession(allocator, io, sess);
    }
    return false;
}

fn serveStatic(io: std.Io, stream: websocket.Conn, path: []const u8, static_dir: []const u8) void {
    const rel = if (std.mem.eql(u8, path, "/") or path.len == 0) "/index.html" else path;
    if (std.mem.find(u8, rel, "..") != null) {
        websocket.sendHttp(stream, "400 Bad Request", "text/plain", "bad path");
        return;
    }
    var path_buf: [1024]u8 = undefined;
    const full = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ static_dir, rel }) catch {
        websocket.sendHttp(stream, "500 Internal Server Error", "text/plain", "path error");
        return;
    };
    const data = std.Io.Dir.cwd().readFileAlloc(io, full, std.heap.page_allocator, .limited(5 * 1024 * 1024)) catch {
        // SPA fallback
        var index_buf: [1024]u8 = undefined;
        const index = std.fmt.bufPrint(&index_buf, "{s}/index.html", .{static_dir}) catch {
            websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        const idx = std.Io.Dir.cwd().readFileAlloc(io, index, std.heap.page_allocator, .limited(5 * 1024 * 1024)) catch {
            websocket.sendHttp(stream, "404 Not Found", "text/plain", "not found");
            return;
        };
        defer std.heap.page_allocator.free(idx);
        websocket.sendHttpExtra(stream, "200 OK", "text/html; charset=utf-8", idx, &.{
            "Cache-Control: no-cache",
            "Content-Security-Policy: default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'",
        });
        return;
    };
    defer std.heap.page_allocator.free(data);
    const ctype: []const u8 = if (std.mem.endsWith(u8, rel, ".js"))
        "application/javascript"
    else if (std.mem.endsWith(u8, rel, ".css"))
        "text/css"
    else if (std.mem.endsWith(u8, rel, ".html"))
        "text/html; charset=utf-8"
    else if (std.mem.endsWith(u8, rel, ".svg"))
        "image/svg+xml"
    else if (std.mem.endsWith(u8, rel, ".png"))
        "image/png"
    else
        "application/octet-stream";
    const cache: []const u8 = if (std.mem.endsWith(u8, rel, ".html"))
        "Cache-Control: no-cache"
    else
        "Cache-Control: public, max-age=31536000, immutable";
    websocket.sendHttpExtra(stream, "200 OK", ctype, data, &.{cache});
}

fn servePluginList(stream: websocket.Conn, plugin_dir: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(stream.io, plugin_dir, .{ .iterate = true }) catch {
        websocket.sendHttp(stream, "200 OK", "application/json", "[]");
        return;
    };
    defer dir.close(stream.io);

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    out.writer.writeByte('[') catch return;

    var first = true;
    var it = dir.iterate();
    while (it.next(stream.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".pyz")) continue;
        const base = name[0 .. name.len - 4];
        if (!protocol.validatePluginName(base)) continue;
        if (!first) out.writer.writeByte(',') catch {};
        out.writer.print("\"{s}\"", .{base}) catch {};
        first = false;
    }
    out.writer.writeByte(']') catch return;
    websocket.sendHttp(stream, "200 OK", "application/json", out.writer.buffered());
}

fn listenAgents(allocator: std.mem.Allocator, state: *State, cfg: *const Config, server_arg: std.Io.net.Server) void {
    const io = state.io;
    var server = server_arg;
    defer server.deinit(io);
    std.log.info("agent listener ready on :{d}", .{cfg.agent_port});

    while (true) {
        const accepted = server.accept(io) catch continue;
        const c: websocket.Conn = .{ .io = io, .stream = accepted };
        _ = std.Thread.spawn(.{}, handleAgentConn, .{ allocator, state, c, cfg }) catch {
            c.close();
            continue;
        };
    }
}

fn handleAgentConn(allocator: std.mem.Allocator, state: *State, stream: websocket.Conn, cfg: *const Config) void {
    defer stream.close();
    var http_buf: [8192]u8 = undefined;
    const req = websocket.readHttpRequest(stream, &http_buf) catch return;
    if (req.kind != .websocket) return;

    const bearer = auth.extractBearer(websocket.extractHeader(req.raw, "Authorization"));
    if (bearer == null or !cfg.tokens.verifyAgent(bearer.?)) {
        websocket.sendHttp(stream, "401 Unauthorized", "text/plain", "unauthorized");
        return;
    }

    websocket.completeHandshake(stream, req.raw) catch return;

    var buf: [protocol.MAX_PAYLOAD_BYTES]u8 = undefined;
    const reg = websocket.readMessage(stream, &buf) catch return;
    if (reg.opcode != .text) return;

    const registration = state.registerAgent(allocator, reg.payload, stream) catch return;
    defer {
        state.removeAgent(registration);
        state.broadcastAgentList(allocator);
    }
    state.broadcastAgentList(allocator);

    while (true) {
        const msg = websocket.readMessage(stream, &buf) catch break;
        switch (msg.opcode) {
            .text => {
                state.touchAgent(registration);
                state.deliverFromAgent(allocator, msg.payload);
            },
            .ping => {
                state.touchAgent(registration);
                registration.conn.write_mutex.lockUncancelable(stream.io);
                defer registration.conn.write_mutex.unlock(stream.io);
                websocket.sendPong(stream, msg.payload);
            },
            .pong => state.touchAgent(registration),
            .close => break,
            else => {},
        }
    }
}

fn envPort(map: *std.process.Environ.Map, name: []const u8, default: u16) !u16 {
    const val = map.get(name) orelse return default;
    const port = std.fmt.parseInt(u16, val, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn envBool(map: *std.process.Environ.Map, name: []const u8, default: bool) bool {
    const val = map.get(name) orelse return default;
    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes");
}

fn acquireInstanceLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    map: *std.process.Environ.Map,
    client_port: u16,
    agent_port: u16,
) !std.Io.File {
    const lock_dir = map.get("XDG_RUNTIME_DIR") orelse
        map.get("TMPDIR") orelse
        map.get("TEMP") orelse
        if (builtin.os.tag == .windows) "." else "/tmp";
    const lock_name = try std.fmt.allocPrint(allocator, "dropfu-server-{d}-{d}.lock", .{ client_port, agent_port });
    defer allocator.free(lock_name);
    const lock_path = try std.fs.path.join(allocator, &.{ lock_dir, lock_name });
    defer allocator.free(lock_path);

    const file = if (std.fs.path.isAbsolute(lock_path))
        try std.Io.Dir.createFileAbsolute(io, lock_path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, lock_path, .{});
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.ServerAlreadyRunning;
    return file;
}

fn portAcceptingConnections(io: std.Io, address: std.Io.net.IpAddress) bool {
    const stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return false;
    stream.close(io);
    return true;
}
