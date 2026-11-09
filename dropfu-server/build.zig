const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protocol_dep = b.dependency("dropfu_protocol", .{
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("dropfu_protocol", protocol_dep.module("dropfu_protocol"));

    const exe = b.addExecutable(.{
        .name = "dropfu-server",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the dropfu-server");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            // Test from the application root so tests in auth, state, websocket,
            // and other imported modules are all discovered.
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("dropfu_protocol", protocol_dep.module("dropfu_protocol"));
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run server unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
