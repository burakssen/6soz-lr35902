const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lr35902_mod = b.addModule("lr35902", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    const tests = b.addTest(.{ .root_module = lr35902_mod });
    const test_step = b.step("test", "Run LR35902 tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const lr35902 = b.addLibrary(.{
        .name = "lr35902",
        .root_module = lr35902_mod,
    });
    b.installArtifact(lr35902);
}
