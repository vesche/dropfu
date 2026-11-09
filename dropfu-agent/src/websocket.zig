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

pub fn clientHandshake(stream: Conn, host: []const u8, path: []const u8, token: []const u8) !void {
    var key_bytes: [16]u8 = undefined;
    std.Io.random(stream.io, &key_bytes);
    var key_buf: [24]u8 = undefined;
    const ws_key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

    var req_buf: [2048]u8 = undefined;
    const req = if (token.len > 0)
        std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\nAuthorization: Bearer {s}\r\n\r\n", .{ path, host, ws_key, token }) catch return error.HandshakeFailed
    else
        std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ path, host, ws_key }) catch return error.HandshakeFailed;

    try stream.writeAll(req);

    var resp: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < resp.len) {
        const n = stream.read(resp[total..]) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed;
        total += n;
        if (std.mem.find(u8, resp[0..total], "\r\n\r\n") != null) break;
    }

    if (std.mem.startsWith(u8, resp[0..total], "HTTP/1.1 401")) return error.Unauthorized;
    if (!std.mem.startsWith(u8, resp[0..total], "HTTP/1.1 101")) return error.UpgradeRejected;
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
    try writeFrameMasked(stream, .text, payload);
}

pub fn sendClose(stream: Conn) void {
    writeFrameMasked(stream, .close, &.{}) catch {};
}

pub fn sendPong(stream: Conn, payload: []const u8) void {
    writeFrameMasked(stream, .pong, payload) catch {};
}

pub fn sendPing(stream: Conn) void {
    writeFrameMasked(stream, .ping, &.{}) catch {};
}

fn writeFrameMasked(stream: Conn, opcode: Opcode, payload: []const u8) !void {
    var hdr: [14]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @backingInt(opcode));
    var hdr_len: usize = 6;

    if (payload.len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        hdr[1] = 0x80 | 126;
        std.mem.writeInt(u16, hdr[2..][0..2], @intCast(payload.len), .big);
        hdr_len = 8;
    } else {
        hdr[1] = 0x80 | 127;
        std.mem.writeInt(u64, hdr[2..][0..8], @intCast(payload.len), .big);
        hdr_len = 14;
    }

    var mask_key: [4]u8 = undefined;
    std.Io.random(stream.io, &mask_key);
    @memcpy(hdr[hdr_len - 4 .. hdr_len], &mask_key);

    try stream.writeAll(hdr[0..hdr_len]);

    var tmp: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const chunk = @min(payload.len - off, tmp.len);
        for (0..chunk) |i| {
            tmp[i] = payload[off + i] ^ mask_key[(off + i) % 4];
        }
        try stream.writeAll(tmp[0..chunk]);
        off += chunk;
    }
}

fn readExact(stream: Conn, buf: []u8) !void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = stream.read(buf[off..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        off += n;
    }
}
