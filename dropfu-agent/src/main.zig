const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("dropfu_protocol");
const websocket = @import("websocket.zig");
const commands = @import("commands.zig");
const system_id = @import("system_id.zig");
const conn = @import("conn.zig");

const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const environ = init.minimal.environ;

    const host = init.environ_map.get("DROPFU_SERVER_HOST") orelse "127.0.0.1";
    const port = envPort(init.environ_map, "DROPFU_SERVER_PORT", 9443) catch |e| {
        std.log.err("invalid DROPFU_SERVER_PORT: {}", .{e});
        return e;
    };
    var token_file_data: ?[]u8 = null;
    defer if (token_file_data) |data| allocator.free(data);
    const token = init.environ_map.get("DROPFU_AGENT_TOKEN") orelse blk: {
        if (init.environ_map.get("DROPFU_AGENT_TOKEN_FILE")) |path| {
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4096)) catch break :blk "";
            token_file_data = data;
            break :blk std.mem.trim(u8, data, &std.ascii.whitespace);
        }
        break :blk "";
    };
    if (token.len < 16) {
        std.log.err("DROPFU_AGENT_TOKEN (or DROPFU_AGENT_TOKEN_FILE) required, min 16 chars", .{});
        return error.MissingToken;
    }

    const sid = try system_id.compute(allocator, io, environ);
    defer allocator.free(sid);

    std.log.info("dropfu-agent v1.0.0 (protocol {d})", .{protocol.PROTOCOL_VERSION});
    std.log.info("  system-id : {s}", .{sid});
    std.log.info("  server    : {s}:{d}", .{ host, port });

    var backoff: u64 = 1;
    while (true) {
        std.log.info("connecting to {s}:{d} ...", .{ host, port });
        const stream = conn.connectHost(io, host, port) catch {
            std.log.warn("connection failed, retrying in {d}s", .{backoff});
            std.Io.sleep(io, .fromSeconds(@intCast(backoff)), .awake) catch {};
            backoff = @min(backoff * 2, 30);
            continue;
        };
        backoff = 1;

        runSession(allocator, io, environ, stream, sid, host, token) catch |e| {
            std.log.err("session error: {}", .{e});
        };
        stream.close();
        std.log.info("disconnected, reconnecting in 2s", .{});
        std.Io.sleep(io, .fromSeconds(2), .awake) catch {};
    }
}

fn runSession(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stream: websocket.Conn,
    agent_id: []const u8,
    host: []const u8,
    token: []const u8,
) !void {
    try websocket.clientHandshake(stream, host, "/agent", token);
    std.log.info("websocket connected", .{});

    var write_mutex: std.Io.Mutex = .init;

    const hn = sysHostname(io);
    const priv = privilegeLevel();
    const registration_id = try protocol.generateId(allocator, io);
    defer allocator.free(registration_id);
    const reg = try protocol.serialize(allocator, protocol.RegisterMsg{
        .id = registration_id,
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(io),
        .payload = .{
            .hostname = hn,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .privilege = priv,
        },
    });
    defer allocator.free(reg);
    {
        write_mutex.lockUncancelable(io);
        defer write_mutex.unlock(io);
        try websocket.sendText(stream, reg);
    }
    std.log.info("registered as {s}", .{agent_id});

    var session_state = SessionState{};
    defer session_state.deinit(allocator, io);

    var buf: [protocol.MAX_PAYLOAD_BYTES]u8 = undefined;
    while (true) {
        const msg = try websocket.readMessage(stream, &buf);
        switch (msg.opcode) {
            .text => handleText(allocator, io, environ, stream, &write_mutex, agent_id, msg.payload, &session_state) catch |e| {
                std.log.err("handle error: {}", .{e});
            },
            .ping => {
                write_mutex.lockUncancelable(io);
                defer write_mutex.unlock(io);
                websocket.sendPong(stream, msg.payload);
            },
            .close => return,
            else => {},
        }
    }
}

const TransferState = struct {
    id: []const u8,
    path: []const u8,
    tmp_path: []const u8,
    expected_size: u64,
    received: u64 = 0,
    hasher: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
};

const SessionState = struct {
    transfer: ?TransferState = null,
    shell: ?commands.ShellSession = null,
    shell_session_id: ?[]const u8 = null,

    fn deinit(self: *SessionState, allocator: Allocator, io: std.Io) void {
        clearTransfer(self, allocator, io, true);
        if (self.shell_session_id) |s| allocator.free(s);
        if (self.shell) |*sh| sh.close();
    }
};

fn handleText(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stream: websocket.Conn,
    write_mutex: *std.Io.Mutex,
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
    if (!protocol.validateId(msg_id)) return;

    // A shell that exits on its own (syntax error, `exit`, crash) still occupies
    // the session until something reaps it. Do that before any command so the
    // next `shell` is not refused as "already active".
    reapShellIfExited(allocator, ss);

    if (std.mem.eql(u8, msg_type, protocol.MSG_HEARTBEAT)) {
        const hb = try protocol.serialize(allocator, protocol.HeartbeatMsg{
            .id = msg_id,
            .agent_id = agent_id,
            .timestamp = protocol.timestamp(io),
        });
        defer allocator.free(hb);
        write_mutex.lockUncancelable(io);
        defer write_mutex.unlock(io);
        try websocket.sendText(stream, hb);
        return;
    }

    if (std.mem.eql(u8, msg_type, protocol.MSG_SHELL_CLOSE)) {
        if (ss.shell) |*sh| {
            sh.close();
            ss.shell = null;
        }
        if (ss.shell_session_id) |s| {
            allocator.free(s);
            ss.shell_session_id = null;
        }
        return;
    }

    if (std.mem.eql(u8, msg_type, protocol.MSG_SHELL_DATA)) {
        if (ss.shell_session_id) |sid| {
            if (!std.mem.eql(u8, sid, msg_id)) return;
        } else return;
        if (ss.shell) |*sh| {
            const payload = protocol.getObj(root, "payload") orelse return;
            const data = protocol.getStr(payload, "data") orelse return;
            sh.writeInput(data);
        }
        return;
    }

    if (std.mem.eql(u8, msg_type, protocol.MSG_FILE_META)) {
        const payload = protocol.getObj(root, "payload") orelse return;
        const direction = protocol.getStr(payload, "direction") orelse return;
        if (!std.mem.eql(u8, direction, "upload")) return;
        const filename = protocol.getStr(payload, "filename") orelse return;
        const size = protocol.getU64(payload, "size") orelse return;
        if (size > protocol.MAX_TRANSFER_BYTES) {
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "file too large");
            return;
        }
        // Prepare transfer; dest path comes from a prior upload command or filename.
        const dest = if (ss.transfer) |t| t.path else filename;
        _ = dest;
        return;
    }

    if (std.mem.eql(u8, msg_type, protocol.MSG_FILE_CHUNK)) {
        try handleUploadChunk(allocator, io, stream, write_mutex, agent_id, msg_id, root, ss);
        return;
    }

    if (!std.mem.eql(u8, msg_type, protocol.MSG_COMMAND)) return;

    const payload = protocol.getObj(root, "payload") orelse return;
    const cmd = protocol.getStr(payload, "command") orelse return;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    if (protocol.getArr(payload, "args")) |arr| {
        if (arr.len > protocol.MAX_ARGS) {
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "too many args");
            return;
        }
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
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "usage: download <file_path>");
            return;
        }
        commands.handleDownload(allocator, stream, write_mutex, agent_id, msg_id, args[0]) catch |e| {
            const em = try allocator.print("download error: {}", .{e});
            defer allocator.free(em);
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", em);
            return;
        };
        try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "success", "download complete");
        return;
    }

    if (std.mem.eql(u8, cmd, "upload")) {
        if (args.len == 0) {
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "usage: upload <dest_path>");
            return;
        }
        const expected_size = if (args.len > 1) std.fmt.parseInt(u64, args[1], 10) catch {
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "invalid upload size");
            return;
        } else 0;
        if (expected_size > protocol.MAX_TRANSFER_BYTES) {
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "file too large");
            return;
        }

        clearTransfer(ss, allocator, io, true);
        const transfer: TransferState = blk: {
            const dest = try allocator.dupe(u8, args[0]);
            errdefer allocator.free(dest);
            const tmp = try allocator.print("{s}.dropfu.upload", .{dest});
            errdefer allocator.free(tmp);
            const tid = try allocator.dupe(u8, msg_id);
            errdefer allocator.free(tid);
            // Truncate temp file before publishing the transfer state.
            const f = std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true }) catch |e| {
                const em = try allocator.print("cannot create upload temp: {}", .{e});
                defer allocator.free(em);
                try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", em);
                return;
            };
            f.close(io);
            break :blk .{
                .id = tid,
                .path = dest,
                .tmp_path = tmp,
                .expected_size = expected_size,
            };
        };
        ss.transfer = transfer;
        try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "success", "ready for upload");
        return;
    }

    const result = commands.dispatch(allocator, io, environ, cmd, args) catch |e| {
        const em = try allocator.print("command error: {}", .{e});
        defer allocator.free(em);
        try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", em);
        return;
    };

    switch (result) {
        .output => |data| {
            defer allocator.free(data);
            try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "success", data);
        },
        .action => |act| switch (act) {
            .shell => {
                if (ss.shell != null) {
                    try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "shell already active; close it first");
                    return;
                }
                if (commands.startShell(allocator, stream, write_mutex, agent_id, msg_id)) |sh| {
                    ss.shell = sh;
                    ss.shell_session_id = try allocator.dupe(u8, msg_id);
                    try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "success", "shell session started");
                } else {
                    try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "failed to start shell");
                }
            },
            .seppuku => {
                try sendResult(allocator, io, stream, write_mutex, msg_id, agent_id, "success", "seppuku initiated – farewell");
                commands.doSeppuku(io, allocator);
            },
        },
    }
}

fn reapShellIfExited(allocator: Allocator, ss: *SessionState) void {
    const shell = &(ss.shell orelse return);
    if (!shell.hasExited()) return;
    shell.close();
    ss.shell = null;
    if (ss.shell_session_id) |sid| {
        allocator.free(sid);
        ss.shell_session_id = null;
    }
}

fn handleUploadChunk(
    allocator: Allocator,
    io: std.Io,
    stream: websocket.Conn,
    write_mutex: *std.Io.Mutex,
    agent_id: []const u8,
    msg_id: []const u8,
    root: std.json.ObjectMap,
    ss: *SessionState,
) !void {
    const t = &(ss.transfer orelse return);
    if (!std.mem.eql(u8, t.id, msg_id)) {
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "wrong transfer id");
        return;
    }
    const payload = protocol.getObj(root, "payload") orelse return;
    const offset = protocol.getU64(payload, "offset") orelse return;
    const b64_data = protocol.getStr(payload, "data") orelse return;
    const is_final = protocol.getBool(payload, "final") orelse false;

    if (offset != t.received) {
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "offset mismatch");
        return;
    }

    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_data) catch {
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "invalid base64");
        return;
    };
    if (decoded_size > protocol.MAX_FILE_CHUNK_RAW) {
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "chunk too large");
        return;
    }
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, b64_data) catch {
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "invalid base64");
        return;
    };

    if (t.received + decoded.len > protocol.MAX_TRANSFER_BYTES) {
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "transfer too large");
        return;
    }

    {
        const file = std.Io.Dir.cwd().openFile(io, t.tmp_path, .{ .mode = .write_only }) catch {
            try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "cannot open temp");
            return;
        };
        defer file.close(io);
        file.writePositionalAll(io, decoded, offset) catch {
            try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "write failed");
            return;
        };
    }
    t.hasher.update(decoded);
    t.received += decoded.len;

    if (is_final) {
        if (t.expected_size != 0 and t.received != t.expected_size) {
            try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", "", "size mismatch");
            clearTransfer(ss, allocator, io, true);
            return;
        }
        const digest = t.hasher.finalResult();
        const hex = try protocol.hexEncode(allocator, &digest);
        defer allocator.free(hex);

        std.Io.Dir.cwd().rename(t.tmp_path, std.Io.Dir.cwd(), t.path, io) catch {
            try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "error", hex, "rename failed");
            clearTransfer(ss, allocator, io, true);
            return;
        };
        try sendFileAck(allocator, io, stream, write_mutex, msg_id, agent_id, "success", hex, "upload complete");
        clearTransfer(ss, allocator, io, false);
    }
}

fn clearTransfer(ss: *SessionState, allocator: Allocator, io: std.Io, delete_temp: bool) void {
    if (ss.transfer) |t| {
        if (delete_temp) std.Io.Dir.cwd().deleteFile(io, t.tmp_path) catch {};
        allocator.free(t.id);
        allocator.free(t.path);
        allocator.free(t.tmp_path);
        ss.transfer = null;
    }
}

fn sendFileAck(
    allocator: Allocator,
    io: std.Io,
    stream: websocket.Conn,
    write_mutex: *std.Io.Mutex,
    msg_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    sha256: []const u8,
    message: []const u8,
) !void {
    const msg = try protocol.serialize(allocator, protocol.FileAckMsg{
        .id = msg_id,
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(io),
        .payload = .{ .status = status, .sha256 = sha256, .message = message },
    });
    defer allocator.free(msg);
    write_mutex.lockUncancelable(io);
    defer write_mutex.unlock(io);
    try websocket.sendText(stream, msg);
}

fn sendResult(
    allocator: Allocator,
    io: std.Io,
    stream: websocket.Conn,
    write_mutex: *std.Io.Mutex,
    msg_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    data: []const u8,
) !void {
    const msg = try protocol.serialize(allocator, protocol.ResultMsg{
        .id = msg_id,
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(io),
        .payload = .{ .status = status, .data = data },
    });
    defer allocator.free(msg);
    write_mutex.lockUncancelable(io);
    defer write_mutex.unlock(io);
    try websocket.sendText(stream, msg);
}

fn sysHostname(io: std.Io) []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
        var val: []const u8 = "";
    };
    if (S.val.len > 0) return S.val;
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const f = std.Io.Dir.openFileAbsolute(io, "/etc/hostname", .{}) catch return "unknown";
        defer f.close(io);
        const n = f.readPositionalAll(io, &S.buf, 0) catch return "unknown";
        S.val = std.mem.trim(u8, S.buf[0..n], &std.ascii.whitespace);
        return S.val;
    }
    return "unknown";
}

fn privilegeLevel() []const u8 {
    if (builtin.os.tag == .windows) {
        // Best-effort: without Win32 IsUserAnAdmin, report user.
        return "user";
    }
    if (builtin.os.tag == .linux) {
        return if (std.os.linux.geteuid() == 0) "root" else "user";
    }
    // macOS: try geteuid via libc when linked
    if (builtin.os.tag == .macos) {
        return if (std.c.geteuid() == 0) "root" else "user";
    }
    return "user";
}

fn envPort(map: *std.process.Environ.Map, name: []const u8, default: u16) !u16 {
    const val = map.get(name) orelse return default;
    const port = std.fmt.parseInt(u16, val, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}
