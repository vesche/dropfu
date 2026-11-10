const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocol_dep = b.dependency("dropfu_protocol", .{
        .target = target,
        .optimize = optimize,
    });

    const runtime_module_root: std.Build.LazyPath = if (b.option(
        []const u8,
        "python-runtime-archive",
        "Use a prebuilt dropfu Python runtime archive instead of downloading one",
    )) |path| blk: {
        const files = b.addWriteFiles();
        _ = files.addCopyFile(
            .{ .cwd_relative = path },
            "dropfu-python-runtime.tar.gz",
        );
        break :blk files.add(
            "python_runtime_data.zig",
            "pub const archive: []const u8 = @embedFile(\"dropfu-python-runtime.tar.gz\");\n",
        );
    } else blk: {
        const prepare = b.addSystemCommand(&.{"python3"});
        prepare.addFileArg(b.path("tools/prepare_python_runtime.py"));
        prepare.addArgs(&.{ "--target", pythonRuntimeTarget(target.result), "--output-dir" });
        const runtime_dir = prepare.addOutputDirectoryArg("python-runtime");
        break :blk runtime_dir.path(b, "python_runtime_data.zig");
    };
    const python_runtime = b.createModule(.{
        .root_source_file = runtime_module_root,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addImport("dropfu_protocol", protocol_dep.module("dropfu_protocol"));
    root_mod.addImport("python_runtime", python_runtime);

    const exe = b.addExecutable(.{
        .name = "dropfu-agent",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the dropfu-agent");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/commands.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unit_tests.root_module.addImport("dropfu_protocol", protocol_dep.module("dropfu_protocol"));
    unit_tests.root_module.addImport("python_runtime", b.createModule(.{
        .root_source_file = b.path("src/python_runtime_test_data.zig"),
    }));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run agent unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn pythonRuntimeTarget(target: std.Target) []const u8 {
    const arch = switch (target.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => @panic("embedded CPython supports only x86_64 and aarch64"),
    };
    return switch (target.os.tag) {
        .macos => if (target.cpu.arch == .x86_64)
            "x86_64-apple-darwin"
        else
            "aarch64-apple-darwin",
        .windows => if (target.cpu.arch == .x86_64)
            "x86_64-pc-windows-msvc"
        else
            "aarch64-pc-windows-msvc",
        .linux => switch (target.abi) {
            .musl, .musleabi, .musleabihf => if (target.cpu.arch == .x86_64)
                "x86_64-unknown-linux-musl"
            else
                "aarch64-unknown-linux-musl",
            else => if (target.cpu.arch == .x86_64)
                "x86_64-unknown-linux-gnu"
            else
                "aarch64-unknown-linux-gnu",
        },
        else => std.debug.panic(
            "embedded CPython does not support {s}-{s}",
            .{ arch, @tagName(target.os.tag) },
        ),
    };
}
