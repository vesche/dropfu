const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("dropfu_protocol");
const runtime_data = @import("python_runtime");

const Allocator = std.mem.Allocator;

pub const version = "3.14.10";

const plugin_bootstrap =
    \\import json, runpy, sys, zipfile
    \\path = sys.argv[1]
    \\with zipfile.ZipFile(path) as archive:
    \\    manifest = json.loads(archive.read("dropfu-plugin.json"))
    \\expected = f"{sys.version_info.major}.{sys.version_info.minor}"
    \\if manifest.get("format") != 1 or manifest.get("python") != expected:
    \\    raise RuntimeError(f"plugin requires CPython {manifest.get('python')}; embedded runtime is {expected}")
    \\sys.argv = sys.argv[1:]
    \\runpy.run_path(path, run_name="__main__")
;

const max_runtime_bytes: u64 = 768 * 1024 * 1024;
const max_runtime_file_bytes: u64 = 256 * 1024 * 1024;

/// Execute a plugin with the CPython distribution carried inside the agent.
///
/// The runtime is expanded lazily into one private temporary directory and
/// reused for the lifetime of the agent. Each plugin still runs in its own
/// process so time and output limits remain enforceable.
pub fn runPlugin(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    plugin_path: []const u8,
    args: []const []const u8,
) !std.process.RunResult {
    const python_exe = try ensureRuntime(allocator, io, environ);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, python_exe);
    // Isolated mode ignores PYTHONHOME/PYTHONPATH and user site packages. -S
    // also prevents site customization; -B avoids endpoint bytecode writes.
    try argv.appendSlice(allocator, &.{ "-I", "-S", "-B", "-c", plugin_bootstrap, plugin_path });
    for (args) |arg| try argv.append(allocator, arg);

    return std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(protocol.MAX_COMMAND_OUTPUT),
        .stderr_limit = .limited(256 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(120), .clock = .awake } },
    });
}

const RuntimeState = struct {
    allocator: Allocator,
    root: []u8,
    python_exe: []u8,

    fn init(allocator: Allocator, io: std.Io, environ: std.process.Environ) !RuntimeState {
        if (runtime_data.archive.len == 0) return error.EmbeddedPythonUnavailable;

        const temp_base = try tempBaseOwned(allocator, environ);
        defer allocator.free(temp_base);

        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const runtime_leaf = try std.fmt.allocPrint(allocator, ".dropfu-python-{s}", .{nonce_hex});
        defer allocator.free(runtime_leaf);
        const runtime_root = try std.fs.path.join(allocator, &.{ temp_base, runtime_leaf });
        errdefer allocator.free(runtime_root);

        var runtime_permissions: std.Io.Dir.Permissions = .default_dir;
        if (builtin.os.tag != .windows) {
            runtime_permissions = .fromMode(0o700);
        }
        if (try std.Io.Dir.cwd().createDirPathStatus(io, runtime_root, runtime_permissions) == .existed) {
            return error.RuntimeDirectoryCollision;
        }
        errdefer std.Io.Dir.cwd().deleteTree(io, runtime_root) catch {};
        try extractRuntime(io, runtime_root);

        const python_relative = switch (builtin.os.tag) {
            .windows => "python/python.exe",
            else => "python/bin/python3",
        };
        const python_exe = try std.fs.path.join(allocator, &.{ runtime_root, python_relative });
        errdefer allocator.free(python_exe);

        return .{
            .allocator = allocator,
            .root = runtime_root,
            .python_exe = python_exe,
        };
    }

    fn deinit(self: *RuntimeState, io: std.Io) void {
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
        self.allocator.free(self.python_exe);
        self.allocator.free(self.root);
        self.* = undefined;
    }
};

var runtime_mutex: std.Io.Mutex = .init;
var runtime_state: ?RuntimeState = null;

fn ensureRuntime(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
) ![]const u8 {
    runtime_mutex.lockUncancelable(io);
    defer runtime_mutex.unlock(io);

    if (runtime_state) |*state| return state.python_exe;
    runtime_state = try RuntimeState.init(allocator, io, environ);
    return runtime_state.?.python_exe;
}

/// Remove the process-lifetime runtime cache. `process.exit` bypasses defers,
/// so callers must invoke this explicitly before self-destruction.
pub fn deinit(io: std.Io) void {
    runtime_mutex.lockUncancelable(io);
    defer runtime_mutex.unlock(io);

    if (runtime_state) |*state| state.deinit(io);
    runtime_state = null;
}

fn tempBaseOwned(allocator: Allocator, environ: std.process.Environ) ![]u8 {
    const key = if (builtin.os.tag == .windows) "TEMP" else "TMPDIR";
    return std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => allocator.dupe(
            u8,
            if (builtin.os.tag == .windows) "." else "/tmp",
        ),
        else => |e| return e,
    };
}

fn extractRuntime(io: std.Io, root: []const u8) !void {
    var compressed_reader: std.Io.Reader = .fixed(runtime_data.archive);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(
        &compressed_reader,
        .gzip,
        &window,
    );
    var name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var archive: std.tar.Iterator = .init(&decompressor.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });

    var total: u64 = 0;
    while (try archive.next()) |entry| {
        if (!safeArchivePath(entry.name)) return error.UnsafeRuntimeArchive;
        if (!std.mem.eql(u8, entry.name, "python") and
            !std.mem.startsWith(u8, entry.name, "python/"))
        {
            return error.UnsafeRuntimeArchive;
        }
        if (entry.kind == .sym_link) return error.UnsupportedRuntimeArchive;
        if (entry.size > max_runtime_file_bytes) return error.RuntimeArchiveTooLarge;
        total = std.math.add(u64, total, entry.size) catch
            return error.RuntimeArchiveTooLarge;
        if (total > max_runtime_bytes) return error.RuntimeArchiveTooLarge;

        const destination = try std.fs.path.join(std.heap.page_allocator, &.{ root, entry.name });
        defer std.heap.page_allocator.free(destination);

        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, destination),
            .file => {
                if (std.fs.path.dirname(destination)) |parent| {
                    try std.Io.Dir.cwd().createDirPath(io, parent);
                }
                var create_options: std.Io.Dir.CreateFileOptions = .{};
                if (builtin.os.tag != .windows) {
                    create_options.permissions = .fromMode(@intCast(entry.mode & 0o777));
                }
                const file = try std.Io.Dir.cwd().createFile(io, destination, create_options);
                defer file.close(io);
                var write_buffer: [64 * 1024]u8 = undefined;
                var writer = file.writerStreaming(io, &write_buffer);
                try archive.streamRemaining(entry, &writer.interface);
                try writer.interface.flush();
            },
            .sym_link => unreachable,
        }
    }
}

fn safeArchivePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

test "runtime archive paths cannot escape extraction root" {
    try std.testing.expect(safeArchivePath("python/bin/python3"));
    try std.testing.expect(!safeArchivePath("../python"));
    try std.testing.expect(!safeArchivePath("python/../../escape"));
    try std.testing.expect(!safeArchivePath("/python/bin/python3"));
    try std.testing.expect(!safeArchivePath("python\\..\\escape"));
}
