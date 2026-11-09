const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("dropfu_protocol");
const websocket = @import("websocket.zig");

pub const PendingRoute = struct {
    client_id: u64,
    keep_until_eof: bool = false,
};

pub const AgentConn = struct {
    stream: websocket.Conn,
    hostname: []const u8,
    os_name: []const u8,
    arch: []const u8,
    privilege: []const u8,
    connected_at: i64,
    last_seen: i64,
    write_mutex: std.Io.Mutex = .init,
    alive: bool = true,
};

pub const AgentRegistration = struct {
    id: []const u8,
    conn: *AgentConn,
};

pub const ClientConn = struct {
    id: u64,
    stream: websocket.Conn,
    write_mutex: std.Io.Mutex = .init,
    alive: bool = true,
};

const Self = @This();

allocator: Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
agents: std.StringHashMap(*AgentConn),
clients: std.ArrayList(*ClientConn) = .empty,
pending: std.StringHashMap(PendingRoute), // request_id -> route metadata
next_client_id: u64 = 1,

pub fn init(allocator: Allocator, io: std.Io) Self {
    return .{
        .allocator = allocator,
        .io = io,
        .agents = std.StringHashMap(*AgentConn).init(allocator),
        .pending = std.StringHashMap(PendingRoute).init(allocator),
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
    var pit = self.pending.keyIterator();
    while (pit.next()) |k| self.allocator.free(k.*);
    self.pending.deinit();
}

fn lock(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
}

fn unlock(self: *Self) void {
    self.mutex.unlock(self.io);
}

pub fn addClient(self: *Self, stream: websocket.Conn) !*ClientConn {
    const c = try self.allocator.create(ClientConn);
    self.lock();
    defer self.unlock();
    c.* = .{ .id = self.next_client_id, .stream = stream };
    self.next_client_id += 1;
    try self.clients.append(self.allocator, c);
    return c;
}

pub fn removeClient(self: *Self, client: *ClientConn) void {
    self.lock();
    defer self.unlock();
    client.alive = false;
    for (self.clients.items, 0..) |c, i| {
        if (c == client) {
            _ = self.clients.swapRemove(i);
            break;
        }
    }
    // Drop pending routes owned by this client.
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(self.allocator);
    var it = self.pending.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.client_id == client.id) {
            to_remove.append(self.allocator, entry.key_ptr.*) catch {};
        }
    }
    for (to_remove.items) |k| {
        if (self.pending.fetchRemove(k)) |kv| {
            self.allocator.free(kv.key);
        }
    }
    self.allocator.destroy(client);
}

pub fn registerAgent(self: *Self, allocator: Allocator, raw: []const u8, stream: websocket.Conn) !AgentRegistration {
    var parsed = try protocol.parse(allocator, raw);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMessage,
    };

    const msg_type = protocol.getMsgType(parsed.value) orelse return error.MissingType;
    if (!std.mem.eql(u8, msg_type, protocol.MSG_REGISTER)) return error.ExpectedRegister;

    const agent_id_raw = protocol.getStr(root, "agent_id") orelse return error.MissingAgentId;
    if (!protocol.validateAgentId(agent_id_raw)) return error.InvalidAgentId;
    const payload = protocol.getObj(root, "payload") orelse return error.MissingPayload;

    const id = try self.allocator.dupe(u8, agent_id_raw);
    errdefer self.allocator.free(id);

    const now = protocol.timestamp(self.io);
    const agent = try self.allocator.create(AgentConn);
    errdefer self.allocator.destroy(agent);
    const hostname = try self.allocator.dupe(u8, protocol.getStr(payload, "hostname") orelse "unknown");
    errdefer self.allocator.free(hostname);
    const os_name = try self.allocator.dupe(u8, protocol.getStr(payload, "os") orelse "unknown");
    errdefer self.allocator.free(os_name);
    const arch = try self.allocator.dupe(u8, protocol.getStr(payload, "arch") orelse "unknown");
    errdefer self.allocator.free(arch);
    const privilege = try self.allocator.dupe(u8, protocol.getStr(payload, "privilege") orelse "unknown");
    errdefer self.allocator.free(privilege);
    agent.* = .{
        .stream = stream,
        .hostname = hostname,
        .os_name = os_name,
        .arch = arch,
        .privilege = privilege,
        .connected_at = now,
        .last_seen = now,
    };

    self.lock();
    defer self.unlock();

    if (self.agents.fetchRemove(id)) |old| {
        std.log.warn("replacing existing agent connection for {s}", .{id});
        old.value.alive = false;
        old.value.write_mutex.lockUncancelable(self.io);
        websocket.sendClose(old.value.stream);
        old.value.write_mutex.unlock(self.io);
        // The old handler still owns this registration and frees it on exit.
    }

    try self.agents.put(id, agent);
    std.log.info("agent registered: {s} ({s})", .{ id, agent.hostname });
    return .{ .id = id, .conn = agent };
}

pub fn touchAgent(self: *Self, registration: AgentRegistration) void {
    self.lock();
    defer self.unlock();
    if (self.agents.get(registration.id)) |current| {
        if (current == registration.conn) current.last_seen = protocol.timestamp(self.io);
    }
}

pub fn removeAgent(self: *Self, registration: AgentRegistration) void {
    self.lock();
    if (self.agents.get(registration.id)) |current| {
        if (current == registration.conn) {
            _ = self.agents.remove(registration.id);
        }
    }
    registration.conn.alive = false;
    registration.conn.write_mutex.lockUncancelable(self.io);
    self.unlock();

    std.log.info("agent disconnected: {s}", .{registration.id});
    registration.conn.write_mutex.unlock(self.io);
    self.allocator.free(registration.id);
    freeAgent(self.allocator, registration.conn);
}

/// Route a client message to an agent and record correlation so replies return to this client.
pub fn routeToAgent(self: *Self, allocator: Allocator, client: *ClientConn, raw: []const u8) !void {
    var parsed = try protocol.parse(allocator, raw);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidMessage,
    };
    const msg_id = protocol.getStr(root, "id") orelse return error.MissingId;
    if (!protocol.validateId(msg_id)) return error.InvalidId;
    const msg_type = protocol.getMsgType(parsed.value) orelse return error.MissingType;

    // Browser heartbeats keep the client connection alive; they are not
    // addressed to an agent. Echo them so the client can also observe liveness.
    if (std.mem.eql(u8, msg_type, protocol.MSG_HEARTBEAT)) {
        client.write_mutex.lockUncancelable(client.stream.io);
        defer client.write_mutex.unlock(client.stream.io);
        try websocket.sendText(client.stream, raw);
        return;
    }

    const target = protocol.getStr(root, "agent_id") orelse return error.MissingAgentId;
    if (!protocol.validateAgentId(target)) return error.InvalidAgentId;

    // Only allow client->agent message types.
    const allowed =
        std.mem.eql(u8, msg_type, protocol.MSG_COMMAND) or
        std.mem.eql(u8, msg_type, protocol.MSG_SHELL_DATA) or
        std.mem.eql(u8, msg_type, protocol.MSG_SHELL_CLOSE) or
        std.mem.eql(u8, msg_type, protocol.MSG_FILE_META) or
        std.mem.eql(u8, msg_type, protocol.MSG_FILE_CHUNK);
    if (!allowed) return error.DisallowedMessageType;

    self.lock();
    const agent = self.agents.get(target) orelse {
        self.unlock();
        return error.AgentNotFound;
    };
    if (!agent.alive) {
        self.unlock();
        return error.AgentNotFound;
    }
    // Record pending correlation for reply-bearing messages.
    if (std.mem.eql(u8, msg_type, protocol.MSG_COMMAND) or
        std.mem.eql(u8, msg_type, protocol.MSG_FILE_META) or
        std.mem.eql(u8, msg_type, protocol.MSG_FILE_CHUNK) or
        std.mem.eql(u8, msg_type, protocol.MSG_SHELL_DATA))
    {
        const persistent_shell = if (std.mem.eql(u8, msg_type, protocol.MSG_COMMAND)) blk: {
            const payload = protocol.getObj(root, "payload") orelse break :blk false;
            const command = protocol.getStr(payload, "command") orelse break :blk false;
            break :blk std.mem.eql(u8, command, "shell");
        } else false;
        if (self.pending.getPtr(msg_id)) |route| {
            route.client_id = client.id;
            route.keep_until_eof = route.keep_until_eof or persistent_shell;
        } else {
            const key = self.allocator.dupe(u8, msg_id) catch {
                self.unlock();
                return error.OutOfMemory;
            };
            self.pending.put(key, .{
                .client_id = client.id,
                .keep_until_eof = persistent_shell,
            }) catch {
                self.allocator.free(key);
                self.unlock();
                return error.OutOfMemory;
            };
        }
    }
    agent.write_mutex.lockUncancelable(self.io);
    const stream = agent.stream;
    self.unlock();

    defer agent.write_mutex.unlock(stream.io);
    try websocket.sendText(stream, raw);
}

/// Deliver an agent message only to the originating client.
pub fn deliverFromAgent(self: *Self, allocator: Allocator, raw: []const u8) void {
    var parsed = protocol.parse(allocator, raw) catch return;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const msg_type = protocol.getMsgType(parsed.value) orelse return;
    const id = protocol.getStr(root, "id") orelse return;
    if (!protocol.validateId(id)) return;

    self.lock();
    defer self.unlock();
    const route = self.pending.get(id) orelse return;
    // Keep download correlation through the final result and shell correlation
    // through EOF; upload correlation ends at its file acknowledgement.
    const drop = (std.mem.eql(u8, msg_type, protocol.MSG_RESULT) and !route.keep_until_eof) or
        std.mem.eql(u8, msg_type, protocol.MSG_ERROR) or
        std.mem.eql(u8, msg_type, protocol.MSG_FILE_ACK) or
        (std.mem.eql(u8, msg_type, protocol.MSG_SHELL_DATA) and blk: {
            const payload = protocol.getObj(root, "payload") orelse break :blk false;
            break :blk protocol.getBool(payload, "eof") orelse false;
        });
    if (drop) {
        if (self.pending.fetchRemove(id)) |kv| {
            self.allocator.free(kv.key);
        }
    }
    for (self.clients.items) |c| {
        if (c.id == route.client_id and c.alive) {
            c.write_mutex.lockUncancelable(c.stream.io);
            defer c.write_mutex.unlock(c.stream.io);
            websocket.sendText(c.stream, raw) catch {};
            return;
        }
    }
}

pub fn broadcastToClients(self: *Self, raw: []const u8) void {
    self.lock();
    defer self.unlock();
    for (self.clients.items) |c| {
        if (!c.alive) continue;
        c.write_mutex.lockUncancelable(c.stream.io);
        defer c.write_mutex.unlock(c.stream.io);
        websocket.sendText(c.stream, raw) catch {};
    }
}

pub fn sendAgentList(self: *Self, allocator: Allocator, stream: websocket.Conn) !void {
    const msg = try self.buildAgentListJson(allocator);
    defer allocator.free(msg);
    try websocket.sendText(stream, msg);
}

pub fn broadcastAgentList(self: *Self, allocator: Allocator) void {
    const msg = self.buildAgentListJson(allocator) catch return;
    defer allocator.free(msg);
    self.broadcastToClients(msg);
}

pub fn sendErrorToClient(
    self: *Self,
    allocator: Allocator,
    client: *ClientConn,
    msg_id: []const u8,
    code: []const u8,
    message: []const u8,
) void {
    _ = self;
    const msg = protocol.serialize(allocator, protocol.ErrorMsg{
        .id = msg_id,
        .timestamp = protocol.timestamp(client.stream.io),
        .payload = .{ .code = code, .message = message },
    }) catch return;
    defer allocator.free(msg);
    client.write_mutex.lockUncancelable(client.stream.io);
    defer client.write_mutex.unlock(client.stream.io);
    websocket.sendText(client.stream, msg) catch {};
}

fn buildAgentListJson(self: *Self, allocator: Allocator) ![]const u8 {
    var arena_impl = std.heap.ArenaAllocator.init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    self.lock();
    defer self.unlock();

    var entries: std.ArrayList(protocol.AgentListMsg.AgentEntry) = .empty;
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
            .last_seen = a.last_seen,
        });
    }

    const msg = protocol.AgentListMsg{
        .id = try protocol.generateId(arena, self.io),
        .timestamp = protocol.timestamp(self.io),
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

test "pending map basics" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var state = Self.init(allocator, io);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.pending.count());
}
