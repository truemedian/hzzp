const std = @import("std");

pub const base = @import("base/base.zig");

test "refAllDecls" {
    std.meta.refAllDecls(@This());
}
