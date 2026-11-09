const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PROTOCOL_VERSION: u32 = 1;

pub const MSG_REGISTER = "register";
pub const MSG_AGENT_LIST = "agent_list";
pub const MSG_COMMAND = "command";
pub const MSG_RESULT = "result";
pub const MSG_SHELL_DATA = "shell_data";
pub const MSG_SHELL_CLOSE = "shell_close";
pub const MSG_FILE_META = "file_meta";
pub const MSG_FILE_CHUNK = "file_chunk";
pub const MSG_FILE_ACK = "file_ack";
pub const MSG_ERROR = "error";
pub const MSG_HEARTBEAT = "heartbeat";
pub const MSG_AUTH_OK = "auth_ok";

pub const MAX_PAYLOAD_BYTES: usize = 256 * 1024;
pub const MAX_STRING_LEN: usize = 4096;
pub const MAX_ARGS: usize = 64;
pub const MAX_FILE_CHUNK_RAW: usize = 48 * 1024;
pub const MAX_TRANSFER_BYTES: u64 = 100 * 1024 * 1024;
pub const MAX_PLUGIN_BYTES: usize = 50 * 1024 * 1024;
pub const MAX_COMMAND_OUTPUT: usize = 2 * 1024 * 1024;
pub const HEARTBEAT_INTERVAL_SECS: i64 = 15;
pub const HEARTBEAT_TIMEOUT_SECS: i64 = 45;

pub const RegisterMsg = struct {
    type: []const u8 = MSG_REGISTER,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: RegisterPayload,

    pub const RegisterPayload = struct {
        hostname: []const u8,
        os: []const u8,
        arch: []const u8,
        privilege: []const u8,
        version: []const u8 = "1.0.0",
    };
};

pub const AgentListMsg = struct {
    type: []const u8 = MSG_AGENT_LIST,
    id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: AgentListPayload,

    pub const AgentListPayload = struct {
        agents: []const AgentEntry,
    };

    pub const AgentEntry = struct {
        agent_id: []const u8,
        hostname: []const u8,
        os: []const u8,
        arch: []const u8,
        privilege: []const u8,
        connected_at: i64,
        last_seen: i64,
    };
};

pub const CommandMsg = struct {
    type: []const u8 = MSG_COMMAND,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: CommandPayload,

    pub const CommandPayload = struct {
        command: []const u8,
        args: []const []const u8,
    };
};

pub const ResultMsg = struct {
    type: []const u8 = MSG_RESULT,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: ResultPayload,

    pub const ResultPayload = struct {
        status: []const u8,
        data: []const u8,
    };
};

pub const ShellDataMsg = struct {
    type: []const u8 = MSG_SHELL_DATA,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: ShellPayload,

    pub const ShellPayload = struct {
        data: []const u8,
        eof: bool = false,
    };
};

pub const ShellCloseMsg = struct {
    type: []const u8 = MSG_SHELL_CLOSE,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: struct {} = .{},
};

pub const FileMetaMsg = struct {
    type: []const u8 = MSG_FILE_META,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: FileMetaPayload,

    pub const FileMetaPayload = struct {
        direction: []const u8,
        filename: []const u8,
        size: u64,
        sha256: []const u8 = "",
    };
};

pub const FileChunkMsg = struct {
    type: []const u8 = MSG_FILE_CHUNK,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: FileChunkPayload,

    pub const FileChunkPayload = struct {
        offset: u64,
        data: []const u8,
        final: bool = false,
    };
};

pub const FileAckMsg = struct {
    type: []const u8 = MSG_FILE_ACK,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: FileAckPayload,

    pub const FileAckPayload = struct {
        status: []const u8,
        sha256: []const u8 = "",
        message: []const u8 = "",
    };
};

pub const ErrorMsg = struct {
    type: []const u8 = MSG_ERROR,
    id: []const u8,
    agent_id: []const u8 = "",
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: ErrorPayload,

    pub const ErrorPayload = struct {
        code: []const u8,
        message: []const u8,
    };
};

pub const HeartbeatMsg = struct {
    type: []const u8 = MSG_HEARTBEAT,
    id: []const u8,
    agent_id: []const u8 = "",
    timestamp: i64,
    protocol_version: u32 = PROTOCOL_VERSION,
    payload: struct {} = .{},
};

pub fn generateId(allocator: Allocator, io: std.Io) ![]const u8 {
    var rand_bytes: [8]u8 = undefined;
    std.Io.random(io, &rand_bytes);
    const ts: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    return allocator.print("{x:0>16}{x:0>16}", .{
        ts,
        std.mem.readInt(u64, &rand_bytes, .big),
    });
}

pub fn timestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

pub fn serialize(allocator: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn parse(allocator: Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    if (data.len > MAX_PAYLOAD_BYTES) return error.PayloadTooLarge;
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{
        .allocate = .alloc_always,
    });
}

pub fn getMsgType(root: std.json.Value) ?[]const u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    return getStr(obj, "type");
}

pub fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getU64(obj: std.json.ObjectMap, key: []const u8) ?u64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn getObj(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

pub fn getArr(obj: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .array => |a| a.items,
        else => null,
    };
}

pub fn getProtocolVersion(obj: std.json.ObjectMap) u32 {
    if (getU64(obj, "protocol_version")) |v| return @intCast(v);
    return 0;
}

pub fn validateId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

pub fn validateAgentId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128) return false;
    for (id) |c| {
        const ok = (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

pub fn validatePluginName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn timingSafeEql(a: []const u8, b: []const u8) bool {
    // Hash to fixed-size digests so comparison is length-independent and constant-time.
    const ha = hashToken(a);
    const hb = hashToken(b);
    return std.crypto.timing_safe.eql([32]u8, ha, hb);
}

/// Hash a token with SHA-256 for storage/comparison of secrets at rest in memory.
pub fn hashToken(token: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(token);
    return hasher.finalResult();
}

pub fn hexEncode(allocator: Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = "0123456789abcdef"[b >> 4];
        out[i * 2 + 1] = "0123456789abcdef"[b & 0x0F];
    }
    return out;
}

pub fn hexDecode(allocator: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    for (0..out.len) |i| {
        const hi = try hexNibble(hex[i * 2]);
        const lo = try hexNibble(hex[i * 2 + 1]);
        out[i] = (@as(u8, hi) << 4) | lo;
    }
    return out;
}

fn hexNibble(c: u8) !u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => error.InvalidHex,
    };
}

test "validatePluginName" {
    try std.testing.expect(validatePluginName("ps"));
    try std.testing.expect(validatePluginName("portscan"));
    try std.testing.expect(!validatePluginName("../etc"));
    try std.testing.expect(!validatePluginName("a/b"));
    try std.testing.expect(!validatePluginName(""));
}

test "validateAgentId" {
    try std.testing.expect(validateAgentId("abcdef0123456789"));
    try std.testing.expect(!validateAgentId("not hex!"));
    try std.testing.expect(!validateAgentId(""));
}

test "timingSafeEql" {
    try std.testing.expect(timingSafeEql("abc", "abc"));
    try std.testing.expect(!timingSafeEql("abc", "abd"));
    try std.testing.expect(!timingSafeEql("abc", "ab"));
}

test "hashToken deterministic" {
    const a = hashToken("secret");
    const b = hashToken("secret");
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "hex roundtrip" {
    const allocator = std.testing.allocator;
    const original = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hex = try hexEncode(allocator, &original);
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("deadbeef", hex);
    const decoded = try hexDecode(allocator, hex);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &original, decoded);
}

test "protocol serialize parse" {
    const allocator = std.testing.allocator;
    const msg = ResultMsg{
        .id = "abc",
        .agent_id = "def",
        .timestamp = 1,
        .payload = .{ .status = "success", .data = "ok" },
    };
    const json = try serialize(allocator, msg);
    defer allocator.free(json);
    var parsed = try parse(allocator, json);
    defer parsed.deinit();
    const t = getMsgType(parsed.value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(MSG_RESULT, t);
}
