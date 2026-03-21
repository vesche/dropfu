const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const websocket = @import("websocket.zig");

pub const AgentConn = struct {
    stream: std.net.Stream,
    hostname: []const u8,
    os_name: []const u8,
    arch: []const u8,
    privilege: []const u8,
    connected_at: i64,
    write_mutex: std.Thread.Mutex = .{},
};

pub const ClientConn = struct {
    stream: std.net.Stream,
    write_mutex: std.Thread.Mutex = .{},
};

const Self = @This();

allocator: Allocator,
mutex: std.Thread.Mutex = .{},
agents: std.StringHashMap(*AgentConn),
clients: std.ArrayList(*ClientConn) = .{},

pub fn init(allocator: Allocator) Self {
    return .{
        .allocator = allocator,
        .agents = std.StringHashMap(*AgentConn).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    var it = self.agents.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        freeAgent(self.allocator, entry.value_ptr.*);
    }
    self.agents.deinit();
    for (self.clients.items) |c| self.allocator.destroy(c);
    self.clients.deinit(self.allocator);
}

// -- clients ----------------------------------------------------------------

pub fn addClient(self: *Self, stream: std.net.Stream) !*ClientConn {
    const c = try self.allocator.create(ClientConn);
    c.* = .{ .stream = stream };
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.clients.append(self.allocator, c);
    return c;
}

pub fn removeClient(self: *Self, client: *ClientConn) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.clients.items, 0..) |c, i| {
        if (c == client) {
            _ = self.clients.swapRemove(i);
            break;
        }
    }
    self.allocator.destroy(client);
}

// -- agents -----------------------------------------------------------------

pub fn registerAgent(self: *Self, allocator: Allocator, raw: []const u8, stream: std.net.Stream) ![]const u8 {
    var parsed = try protocol.parse(allocator, raw);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMessage,
    };

    const agent_id_raw = protocol.getStr(root, "agent_id") orelse return error.MissingAgentId;
    const payload = protocol.getObj(root, "payload") orelse return error.MissingPayload;

    const id = try self.allocator.dupe(u8, agent_id_raw);
    errdefer self.allocator.free(id);

    const agent = try self.allocator.create(AgentConn);
    agent.* = .{
        .stream = stream,
        .hostname = try self.allocator.dupe(u8, protocol.getStr(payload, "hostname") orelse "unknown"),
        .os_name = try self.allocator.dupe(u8, protocol.getStr(payload, "os") orelse "unknown"),
        .arch = try self.allocator.dupe(u8, protocol.getStr(payload, "arch") orelse "unknown"),
        .privilege = try self.allocator.dupe(u8, protocol.getStr(payload, "privilege") orelse "unknown"),
        .connected_at = std.time.timestamp(),
    };

    self.mutex.lock();
    defer self.mutex.unlock();
    try self.agents.put(id, agent);
    std.log.info("agent registered: {s} ({s})", .{ id, agent.hostname });
    return id;
}

pub fn removeAgent(self: *Self, agent_id: []const u8) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.agents.fetchRemove(agent_id)) |kv| {
        self.allocator.free(kv.key);
        freeAgent(self.allocator, kv.value);
        std.log.info("agent disconnected: {s}", .{agent_id});
    }
}

// -- routing ----------------------------------------------------------------

pub fn routeToAgent(self: *Self, allocator: Allocator, raw: []const u8) !void {
    var parsed = try protocol.parse(allocator, raw);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMessage,
    };
    const target = protocol.getStr(root, "agent_id") orelse return error.MissingAgentId;

    self.mutex.lock();
    const agent = self.agents.get(target) orelse {
        self.mutex.unlock();
        return error.AgentNotFound;
    };
    self.mutex.unlock();

    agent.write_mutex.lock();
    defer agent.write_mutex.unlock();
    try websocket.sendText(agent.stream, raw);
}

pub fn broadcastToClients(self: *Self, raw: []const u8) void {
    self.mutex.lock();
    const snapshot = self.allocator.dupe(*ClientConn, self.clients.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);

    for (snapshot) |c| {
        c.write_mutex.lock();
        defer c.write_mutex.unlock();
        websocket.sendText(c.stream, raw) catch {};
    }
}

pub fn sendAgentList(self: *Self, allocator: Allocator, stream: std.net.Stream) !void {
    const msg = try self.buildAgentListJson(allocator);
    defer allocator.free(msg);
    try websocket.sendText(stream, msg);
}

pub fn broadcastAgentList(self: *Self, allocator: Allocator) void {
    const msg = self.buildAgentListJson(allocator) catch return;
    defer allocator.free(msg);

    self.mutex.lock();
    const snapshot = self.allocator.dupe(*ClientConn, self.clients.items) catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    defer self.allocator.free(snapshot);

    for (snapshot) |c| {
        c.write_mutex.lock();
        defer c.write_mutex.unlock();
        websocket.sendText(c.stream, msg) catch {};
    }
}

// -- internals --------------------------------------------------------------

fn buildAgentListJson(self: *Self, allocator: Allocator) ![]const u8 {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    self.mutex.lock();
    defer self.mutex.unlock();

    var entries: std.ArrayList(protocol.AgentListMsg.AgentEntry) = .{};
    defer entries.deinit(arena);

    var it = self.agents.iterator();
    while (it.next()) |entry| {
        const a = entry.value_ptr.*;
        try entries.append(arena, .{
            .agent_id = entry.key_ptr.*,
            .hostname = a.hostname,
            .os = a.os_name,
            .arch = a.arch,
            .privilege = a.privilege,
            .connected_at = a.connected_at,
            .last_seen = std.time.timestamp(),
        });
    }

    const msg = protocol.AgentListMsg{
        .id = try protocol.generateId(arena),
        .timestamp = protocol.timestamp(),
        .payload = .{ .agents = entries.items },
    };
    return try protocol.serialize(allocator, msg);
}

fn freeAgent(allocator: Allocator, a: *AgentConn) void {
    allocator.free(a.hostname);
    allocator.free(a.os_name);
    allocator.free(a.arch);
    allocator.free(a.privilege);
    allocator.destroy(a);
}
