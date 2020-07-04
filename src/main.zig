const std = @import("std");

const client = @import("base/client.zig");

test "refAllDecls" {
    std.meta.refAllDecls(@This());
}
