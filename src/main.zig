const std = @import("std");

pub const BaseClient = @import("base/client.zig");
pub const BaseServer = @import("base/server.zig");

test "refAllDecls" {
    std.meta.refAllDecls(@This());
}
