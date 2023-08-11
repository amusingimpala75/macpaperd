const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    if (!target.isDarwin()) {
        std.builtin.panic("only macOS is supported\n", null, null);
    }

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "macpaperd",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("sqlite", sqlite.module("sqlite"));

    const use_builtin_sqlite = b.option(bool, "bundle-sqlite", "Use the sqlite library that comes with the zig bindings instead of the system installation") orelse false;
    if (use_builtin_sqlite) {
        exe.linkLibrary(sqlite.artifact("sqlite"));
    } else {
        exe.linkSystemLibrary("sqlite3");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
