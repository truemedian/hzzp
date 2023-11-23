const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter the executed library tests");
    const emit_docs = b.option(bool, "emit-docs", "Build library documentation") orelse false;

    const module = b.addModule("hzzp", .{
        .source_file = .{ .path = "src/main.zig" },
    });

    const test_compile_step = b.addTest(.{
        .root_source_file = module.source_file,
        .target = target,
        .optimize = optimize,
    });
    test_compile_step.filter = test_filter;

    const test_run_step = b.addRunArtifact(test_compile_step);

    const test_step = b.step("test", "Run all library tests");
    if (emit_docs) {
        const docs = b.addInstallDirectory(.{
            .source_dir = test_compile_step.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "doc",
        });
        test_step.dependOn(&test_compile_step.step);
        test_step.dependOn(&docs.step);
    } else {
        test_step.dependOn(&test_run_step.step);
    }
}
