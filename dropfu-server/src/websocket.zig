const std = @import("std");
const conn = @import("conn.zig");

pub const Conn = conn.Conn;

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

pub const RequestKind = enum { websocket, http_get, http_post, other };

pub const HttpRequest = struct {
    raw: []const u8,
    method: []const u8,
    path: []const u8,
    kind: RequestKind,
};

pub fn readHttpRequest(stream: Conn, buf: []u8) !HttpRequest {
    var total: usize = 0;
    while (total < buf.len) {
        const n = stream.read(buf[total..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        total += n;
        if (std.mem.find(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    if (std.mem.find(u8, buf[0..total], "\r\n\r\n") == null) return error.HeadersTooLarge;
    const raw = buf[0..total];

    const first_end = std.mem.find(u8, raw, "\r\n") orelse raw.len;
    const first_line = raw[0..first_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.first();
    const path_raw = parts.next() orelse "/";
    const path = if (std.mem.findScalar(u8, path_raw, '?')) |q| path_raw[0..q] else path_raw;

    const is_upgrade = extractHeader(raw, "Upgrade") != null and
        std.ascii.eqlIgnoreCase(extractHeader(raw, "Upgrade").?, "websocket");

    const kind: RequestKind = if (is_upgrade)
        .websocket
    else if (std.mem.eql(u8, method, "GET"))
        .http_get
    else if (std.mem.eql(u8, method, "POST"))
        .http_post
    else
        .other;

    return .{ .raw = raw, .method = method, .path = path, .kind = kind };
}

pub fn completeHandshake(stream: Conn, request: []const u8) !void {
    const ws_key = extractHeader(request, "Sec-WebSocket-Key") orelse
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
    try stream.writeAll(resp[0..total]);
}

pub fn acceptHandshake(stream: Conn) !void {
    var buf: [8192]u8 = undefined;
    const req = try readHttpRequest(stream, &buf);
    if (req.kind != .websocket) return error.NotWebSocket;
    try completeHandshake(stream, req.raw);
}

pub fn readMessage(stream: Conn, buf: []u8) !Message {
    var hdr: [2]u8 = undefined;
    try readExact(stream, &hdr);

    if (hdr[0] & 0x70 != 0) return error.UnsupportedWebSocketExtension;
    if (hdr[0] & 0x80 == 0) return error.FragmentedMessageUnsupported;
    const opcode: Opcode = @fromBackingInt(@intCast(@as(u4, @truncate(hdr[0] & 0x0F))));
    const masked = hdr[1] & 0x80 != 0;
    var payload_len: u64 = hdr[1] & 0x7F;

    if (payload_len == 126) {
        var ext: [2]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u16, &ext, .big);
    } else if (payload_len == 127) {
        var ext: [8]u8 = undefined;
        try readExact(stream, &ext);
        payload_len = std.mem.readInt(u64, &ext, .big);
    }

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) try readExact(stream, &mask_key);

    if (payload_len > buf.len) return error.PayloadTooLarge;
    const len: usize = @intCast(payload_len);
    try readExact(stream, buf[0..len]);

    if (masked) {
        for (buf[0..len], 0..) |*b, i| {
            b.* ^= mask_key[i % 4];
        }
    }
    return .{ .opcode = opcode, .payload = buf[0..len] };
}

pub fn sendText(stream: Conn, payload: []const u8) !void {
    try writeFrame(stream, .text, payload);
}

pub fn sendClose(stream: Conn) void {
    writeFrame(stream, .close, &.{}) catch {};
}

pub fn sendPong(stream: Conn, payload: []const u8) void {
    writeFrame(stream, .pong, payload) catch {};
}

pub fn sendPing(stream: Conn) void {
    writeFrame(stream, .ping, &.{}) catch {};
}

pub fn sendHttp(stream: Conn, status: []const u8, content_type: []const u8, body: []const u8) void {
    sendHttpExtra(stream, status, content_type, body, &.{});
}

pub fn sendHttpExtra(
    stream: Conn,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    extra_headers: []const []const u8,
) void {
    var hdr_buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&hdr_buf);
    fbs.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n", .{
        status,
        content_type,
        body.len,
    }) catch return;
    for (extra_headers) |h| {
        fbs.writeAll(h) catch return;
        fbs.writeAll("\r\n") catch return;
    }
    fbs.writeAll("\r\n") catch return;
    stream.writeAll(fbs.buffered()) catch return;
    if (body.len > 0) stream.writeAll(body) catch {};
}

fn writeFrame(stream: Conn, opcode: Opcode, payload: []const u8) !void {
    var hdr: [10]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @backingInt(opcode));
    var hdr_len: usize = 2;

    if (payload.len < 126) {
        hdr[1] = @intCast(payload.len);
    } else if (payload.len <= 0xFFFF) {
        hdr[1] = 126;
        std.mem.writeInt(u16, hdr[2..][0..2], @intCast(payload.len), .big);
        hdr_len = 4;
    } else {
        hdr[1] = 127;
        std.mem.writeInt(u64, hdr[2..][0..8], @intCast(payload.len), .big);
        hdr_len = 10;
    }

    try stream.writeAll(hdr[0..hdr_len]);
    if (payload.len > 0) try stream.writeAll(payload);
}

fn readExact(stream: Conn, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = stream.read(buf[off..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}

pub fn extractHeader(request: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, request, "\r\n");
    while (it.next()) |line| {
        if (line.len < name.len + 1) continue;
        if (std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            return std.mem.trim(u8, line[name.len + 1 ..], &std.ascii.whitespace);
        }
    }
    return null;
}
