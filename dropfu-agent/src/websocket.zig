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

/// Perform a client-side WebSocket opening handshake (RFC 6455 §4.1).
pub fn clientHandshake(stream: std.net.Stream, host: []const u8, path: []const u8) !void {
    var key_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&key_bytes);
    var key_buf: [24]u8 = undefined;
    const ws_key = std.base64.standard.Encoder.encode(&key_buf, &key_bytes);

    var req_buf: [1024]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ path, host, ws_key }) catch return error.HandshakeFailed;

    _ = stream.write(req) catch return error.HandshakeFailed;

    var resp: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < resp.len) {
        const n = stream.read(resp[total..]) catch return error.HandshakeFailed;
        if (n == 0) return error.HandshakeFailed;
        total += n;
        if (std.mem.indexOf(u8, resp[0..total], "\r\n\r\n") != null) break;
    }

    if (!std.mem.startsWith(u8, resp[0..total], "HTTP/1.1 101")) return error.UpgradeRejected;
}

/// Read one WebSocket frame. Caller provides scratch buffer.
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
    if (masked) {
        readExact(stream, &mask_key) catch return error.ConnectionClosed;
    }

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

/// Send a text frame (client → server, masked per RFC 6455 §5.3).
pub fn sendText(stream: std.net.Stream, payload: []const u8) !void {
    try writeFrameMasked(stream, .text, payload);
}

pub fn sendClose(stream: std.net.Stream) void {
    writeFrameMasked(stream, .close, &.{}) catch {};
}

pub fn sendPong(stream: std.net.Stream, payload: []const u8) void {
    writeFrameMasked(stream, .pong, payload) catch {};
}

// ---------------------------------------------------------------------------
fn writeFrameMasked(stream: std.net.Stream, opcode: Opcode, payload: []const u8) !void {
    var hdr: [14]u8 = undefined;
    hdr[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var hdr_len: usize = 6; // 2 header + 4 mask

    if (payload.len < 126) {
        hdr[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        hdr[1] = 0x80 | 126;
        std.mem.writeInt(u16, hdr[2..4], @intCast(payload.len), .big);
        hdr_len = 8;
    } else {
        hdr[1] = 0x80 | 127;
        std.mem.writeInt(u64, hdr[2..10], @intCast(payload.len), .big);
        hdr_len = 14;
    }

    var mask_key: [4]u8 = undefined;
    std.crypto.random.bytes(&mask_key);
    @memcpy(hdr[hdr_len - 4 .. hdr_len], &mask_key);

    _ = stream.write(hdr[0..hdr_len]) catch return error.SendFailed;

    // mask payload on the fly in chunks
    var tmp: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const chunk = @min(payload.len - off, tmp.len);
        for (0..chunk) |i| {
            tmp[i] = payload[off + i] ^ mask_key[(off + i) % 4];
        }
        _ = stream.write(tmp[0..chunk]) catch return error.SendFailed;
        off += chunk;
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
