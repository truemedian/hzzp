const std = @import("std");

pub usingnamespace @import("common.zig");

pub const Client = @import("client.zig");
pub const Server = @import("server.zig");

test "refAllDecls" {
    std.meta.refAllDecls(@This());
}
