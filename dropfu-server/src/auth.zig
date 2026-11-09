const std = @import("std");
const protocol = @import("dropfu_protocol");

pub const Tokens = struct {
    operator_hash: [32]u8,
    agent_hash: [32]u8,
    session_secret: [32]u8,

    pub fn fromEnv(io: std.Io, environ_map: *std.process.Environ.Map) !Tokens {
        const op = try loadSecret(io, environ_map, "DROPFU_OPERATOR_TOKEN", "DROPFU_OPERATOR_TOKEN_FILE");
        defer wipe(op);
        const ag = try loadSecret(io, environ_map, "DROPFU_AGENT_TOKEN", "DROPFU_AGENT_TOKEN_FILE");
        defer wipe(ag);

        if (op.len < 16 or ag.len < 16) return error.TokenTooShort;

        var session_secret: [32]u8 = undefined;
        std.Io.random(io, &session_secret);

        return .{
            .operator_hash = protocol.hashToken(op),
            .agent_hash = protocol.hashToken(ag),
            .session_secret = session_secret,
        };
    }

    pub fn verifyOperator(self: Tokens, presented: []const u8) bool {
        const h = protocol.hashToken(presented);
        return std.crypto.timing_safe.eql([32]u8, self.operator_hash, h);
    }

    pub fn verifyAgent(self: Tokens, presented: []const u8) bool {
        const h = protocol.hashToken(presented);
        return std.crypto.timing_safe.eql([32]u8, self.agent_hash, h);
    }

    pub fn mintSession(self: Tokens, allocator: std.mem.Allocator, io: std.Io) ![]u8 {
        var nonce: [16]u8 = undefined;
        std.Io.random(io, &nonce);
        const exp: i64 = protocol.timestamp(io) + 12 * 60 * 60; // 12h
        var payload_buf: [48]u8 = undefined;
        @memcpy(payload_buf[0..16], &nonce);
        std.mem.writeInt(i64, payload_buf[16..24], exp, .big);

        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, payload_buf[0..24], &self.session_secret);

        const out = try allocator.alloc(u8, 24 + 32);
        @memcpy(out[0..24], payload_buf[0..24]);
        @memcpy(out[24..], &mac);
        const hex = try protocol.hexEncode(allocator, out);
        allocator.free(out);
        return hex;
    }

    pub fn verifySession(self: Tokens, allocator: std.mem.Allocator, io: std.Io, token_hex: []const u8) bool {
        const raw = protocol.hexDecode(allocator, token_hex) catch return false;
        defer allocator.free(raw);
        if (raw.len != 56) return false;

        var expected: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&expected, raw[0..24], &self.session_secret);
        if (!std.crypto.timing_safe.eql([32]u8, expected, raw[24..56].*)) return false;

        const exp = std.mem.readInt(i64, raw[16..24], .big);
        return protocol.timestamp(io) <= exp;
    }
};

fn loadSecret(io: std.Io, map: *std.process.Environ.Map, env_key: []const u8, file_key: []const u8) ![]u8 {
    if (map.get(file_key)) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(4096));
        const trimmed = std.mem.trim(u8, data, &std.ascii.whitespace);
        if (trimmed.ptr != data.ptr or trimmed.len != data.len) {
            const copy = try std.heap.page_allocator.dupe(u8, trimmed);
            std.heap.page_allocator.free(data);
            return copy;
        }
        return data;
    }
    if (map.get(env_key)) |val| {
        return try std.heap.page_allocator.dupe(u8, val);
    }
    return error.MissingToken;
}

fn wipe(buf: []u8) void {
    @memset(buf, 0);
    std.heap.page_allocator.free(buf);
}

pub fn extractBearer(auth_header: ?[]const u8) ?[]const u8 {
    const h = auth_header orelse return null;
    if (h.len < 8) return null;
    if (!std.ascii.eqlIgnoreCase(h[0..7], "Bearer ")) return null;
    return h[7..];
}

pub fn extractCookie(cookie_header: ?[]const u8, name: []const u8) ?[]const u8 {
    const h = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, h, ';');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (std.mem.startsWith(u8, trimmed, name) and trimmed.len > name.len and trimmed[name.len] == '=') {
            return trimmed[name.len + 1 ..];
        }
    }
    return null;
}

pub fn headerValue(request: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, request, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |line| {
        if (line.len == 0) break;
        if (line.len < name.len + 1) continue;
        if (std.ascii.eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            return std.mem.trim(u8, line[name.len + 1 ..], &std.ascii.whitespace);
        }
    }
    return null;
}

pub fn originAllowed(origin: ?[]const u8, allowed: []const []const u8) bool {
    const o = origin orelse return false;
    for (allowed) |a| {
        if (std.mem.eql(u8, o, a)) return true;
    }
    return false;
}

test "session mint verify and tamper rejection" {
    const allocator = std.testing.allocator;
    var session_secret: [32]u8 = undefined;
    @memset(&session_secret, 0x5a);
    const tokens = Tokens{
        .operator_hash = protocol.hashToken("operator-token-1234"),
        .agent_hash = protocol.hashToken("agent-token-123456"),
        .session_secret = session_secret,
    };
    const session = try tokens.mintSession(allocator, std.testing.io);
    defer allocator.free(session);
    try std.testing.expect(tokens.verifySession(allocator, std.testing.io, session));

    session[0] = if (session[0] == '0') '1' else '0';
    try std.testing.expect(!tokens.verifySession(allocator, std.testing.io, session));
}

test "cookie and bearer parsing" {
    try std.testing.expectEqualStrings("secret", extractBearer("Bearer secret").?);
    try std.testing.expect(extractBearer("Basic secret") == null);
    try std.testing.expectEqualStrings("abc123", extractCookie("other=x; dropfu_session=abc123; last=y", "dropfu_session").?);
    try std.testing.expect(extractCookie("other=x", "dropfu_session") == null);
}

test "origin allowlist requires exact match" {
    const allowed = [_][]const u8{ "http://127.0.0.1:3000", "https://dropfu.example" };
    try std.testing.expect(originAllowed("http://127.0.0.1:3000", &allowed));
    try std.testing.expect(!originAllowed("http://127.0.0.1:3000.evil", &allowed));
    try std.testing.expect(!originAllowed(null, &allowed));
}
