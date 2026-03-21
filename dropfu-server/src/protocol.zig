const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MSG_REGISTER = "register";
pub const MSG_AGENT_LIST = "agent_list";
pub const MSG_COMMAND = "command";
pub const MSG_RESULT = "result";
pub const MSG_SHELL_DATA = "shell_data";
pub const MSG_FILE_META = "file_meta";
pub const MSG_FILE_CHUNK = "file_chunk";
pub const MSG_ERROR = "error";

// ---------------------------------------------------------------------------
// Serialisation structs – each maps 1-to-1 with a JSON wire message
// ---------------------------------------------------------------------------

pub const RegisterMsg = struct {
    type: []const u8 = MSG_REGISTER,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
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
    payload: ShellPayload,

    pub const ShellPayload = struct {
        data: []const u8,
        eof: bool = false,
    };
};

pub const FileMetaMsg = struct {
    type: []const u8 = MSG_FILE_META,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    payload: FileMetaPayload,

    pub const FileMetaPayload = struct {
        direction: []const u8,
        filename: []const u8,
        size: u64,
    };
};

pub const FileChunkMsg = struct {
    type: []const u8 = MSG_FILE_CHUNK,
    id: []const u8,
    agent_id: []const u8,
    timestamp: i64,
    payload: FileChunkPayload,

    pub const FileChunkPayload = struct {
        offset: u64,
        data: []const u8,
        final: bool = false,
    };
};

pub const ErrorMsg = struct {
    type: []const u8 = MSG_ERROR,
    id: []const u8,
    agent_id: []const u8 = "",
    timestamp: i64,
    payload: ErrorPayload,

    pub const ErrorPayload = struct {
        code: []const u8,
        message: []const u8,
    };
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn generateId(allocator: Allocator) ![]const u8 {
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    const ts: u64 = @intCast(std.time.milliTimestamp());
    return std.fmt.allocPrint(allocator, "{x:0>16}{x:0>16}", .{
        ts,
        std.mem.readInt(u64, &rand_bytes, .big),
    });
}

pub fn timestamp() i64 {
    return std.time.timestamp();
}

pub fn serialize(allocator: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Light-weight parse: returns the dynamic Value tree.  Caller owns deinit.
pub fn parse(allocator: Allocator, data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, data, .{
        .allocate = .alloc_always,
    });
}

pub fn getMsgType(root: std.json.Value) ?[]const u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const val = obj.get("type") orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
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
