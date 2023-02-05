const std = @import("std");

pub fn build(b: *std.Build) void {
    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = b.standardOptimizeOption(.{}),
    });

    const tests = b.step("test", "Run all library tests");
    tests.dependOn(&lib_tests.step);

    const docs = b.option(bool, "emit_docs", "Build library documentation") orelse false;

    if (docs)
        lib_tests.emit_docs = .emit;
}
