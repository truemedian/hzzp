const std = @import("std");

var filters: [1][]const u8 = undefined;
var filters_len: usize = 0;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Filter the executed library tests");
    const emit_docs = b.option(bool, "emit-docs", "Build library documentation") orelse false;

    const module = b.addModule("hzzp", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const test_compile_step = b.addTest(.{
        .root_source_file = module.root_source_file.?,
        .target = target,
        .optimize = optimize,
    });
    if (test_filter) |_| {
        filters[0] = test_filter.?;
        filters_len += 1;
    }
    test_compile_step.filters = filters[0..filters_len];

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
