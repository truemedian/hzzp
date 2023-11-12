const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("hzzp", .{
        .source_file = .{ .path = "src/main.zig" },
    });
    _ = module;

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
    });

    main_tests.linkLibC();
    main_tests.linkSystemLibrary("ssl");
    main_tests.linkSystemLibrary("crypto");

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const test_exe = b.addExecutable(.{
        .name = "hzzp_test2",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = .ReleaseFast,
    });

    b.installArtifact(test_exe);
}
