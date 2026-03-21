const std = @import("std");

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Message = struct {
    opcode: Opcode,
    payload: []const u8,
};

pub const RequestKind = enum { websocket, http_get, other };

pub const HttpRequest = struct {
    raw: []const u8,
    method: []const u8,
    path: []const u8,
    kind: RequestKind,
};

/// Read the opening HTTP request from a new TCP connection.
pub fn readHttpRequest(stream: std.net.Stream, buf: []u8) !HttpRequest {
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    const raw = buf[0..total];

    const first_end = std.mem.indexOf(u8, raw, "\r\n") orelse raw.len;
    const first_line = raw[0..first_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.first();
    const path = parts.next() orelse "/";

    const is_upgrade = extractHeader(raw, "Upgrade: ") != null;

    const kind: RequestKind = if (is_upgrade)
        .websocket
    else if (std.mem.eql(u8, method, "GET"))
        .http_get
    else
        .other;

    return .{ .raw = raw, .method = method, .path = path, .kind = kind };
}

/// Finish the server-side WebSocket handshake given a pre-read HTTP request.
pub fn completeHandshake(stream: std.net.Stream, request: []const u8) !void {
    const ws_key = extractHeader(request, "Sec-WebSocket-Key: ") orelse
        return error.MissingKey;

    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(ws_key);
    hasher.update(magic);
    const digest = hasher.finalResult();

    var accept_buf: [28]u8 = undefined;
    const accept_val = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    const prefix = "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Accept: ";
    const suffix = "\r\n\r\n";

    var resp: [prefix.len + 28 + suffix.len]u8 = undefined;
    @memcpy(resp[0..prefix.len], prefix);
    @memcpy(resp[prefix.len..][0..accept_val.len], accept_val);
    @memcpy(resp[prefix.len + accept_val.len ..][0..suffix.len], suffix);
    const total = prefix.len + accept_val.len + suffix.len;
    writeAll(stream, resp[0..total]) catch return error.HandshakeFailed;
}

/// One-shot accept handshake (reads HTTP + completes upgrade).
pub fn acceptHandshake(stream: std.net.Stream) !void {
    var buf: [4096]u8 = undefined;
    const req = try readHttpRequest(stream, &buf);
    if (req.kind != .websocket) return error.NotWebSocket;
    try completeHandshake(stream, req.raw);
}

// ---- frame I/O ------------------------------------------------------------

pub fn readMessage(stream: std.net.Stream, buf: []u8) !Message {
    var hdr: [2]u8 = undefined;
    readExact(stream, &hdr) catch return error.ConnectionClosed;

    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(hdr[0] & 0x0F)));
    const masked = hdr[1] & 0x80 != 0;
    var payload_len: u64 = hdr[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        readExact(stream, &ext) catch return error.ConnectionClosed;
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        readExact(stream, &ext) catch return error.ConnectionClosed;
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) readExact(stream, &mask_key) catch return error.ConnectionClosed;

    if (payload_len > buf.len) return error.PayloadTooLarge;
    const len: usize = @intCast(payload_len);
    readExact(stream, buf[0..len]) catch return error.ConnectionClosed;

    if (masked) {
        for (buf[0..len], 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }
    }
    return .{ .opcode = opcode, .payload = buf[0..len] };
}

pub fn sendText(stream: std.net.Stream, payload: []const u8) !void {
    try writeFrame(stream, .text, payload);
}

pub fn sendClose(stream: std.net.Stream) void {
    writeFrame(stream, .close, &.{}) catch {};
}

pub fn sendPong(stream: std.net.Stream, payload: []const u8) void {
    writeFrame(stream, .pong, payload) catch {};
}

/// Serve a simple HTTP response then close.
pub fn sendHttp(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, content_type, body.len }) catch return;
    _ = stream.write(hdr) catch return;
    if (body.len > 0) _ = stream.write(body) catch {};
}

// ---- internal -------------------------------------------------------------

fn writeFrame(stream: std.net.Stream, opcode: Opcode, payload: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var hdr_len: usize = 2;

    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else if (payload.len <= 0xFFFF) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        hdr_len = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..10], @intCast(payload.len), .big);
        hdr_len = 10;
    }

    writeAll(stream, hdr[0..hdr_len]) catch return error.SendFailed;
    if (payload.len > 0) writeAll(stream, payload) catch return error.SendFailed;
}

fn writeAll(stream: std.net.Stream, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = stream.write(data[off..]) catch return error.SendFailed;
        if (n == 0) return error.SendFailed;
        off += n;
    }
}

fn readExact(stream: std.net.Stream, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = stream.read(buf[off..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

fn extractHeader(request: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, request, "\r\n");
    while (it.next()) |line| {
        if (line.len < name.len) continue;
        if (std.ascii.eqlIgnoreCase(line[0..name.len], name))
            return line[name.len..];
    }
    return null;
}
