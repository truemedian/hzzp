const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const Connection = @import("Connection.zig");
pub const Client = @import("Client.zig");

pub const tls = @import("tls/openssl.zig");

test {
    std.testing.refAllDecls(@This());
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var client = try Client.init(allocator);

    const uri = std.Uri.parse("https://example.com") catch unreachable;
    var req = try client.open(uri);

    try req.send(.{
        .uri = uri,
        .headers = .{ .allocator = undefined },
    });

    try req.finish();

    var res = try req.wait(allocator);

    const body = try res.reader().readAllAlloc(allocator, 1000000);
    defer allocator.free(body);
    
    std.debug.print("{} : {s}\n{}\n{s}", .{res.status, res.reason, res.headers, body});
}
