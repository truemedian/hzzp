const std = @import("std");

const client = @import("base/client.zig");
const server = @import("base/server.zig");

test "refAllDecls" {
    std.meta.refAllDecls(@This());
}
