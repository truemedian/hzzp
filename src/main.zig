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

    const uri = std.Uri.parse("https://httpbin.org/post") catch unreachable;
    var message = try client.open(allocator, uri);

    message.request.content_length = .chunked;

    try message.send(.{
        .method = .POST,
        .uri = uri,
        .headers = .{ .allocator = undefined },
    });

    try message.writer().writeAll("Hello, World!");

    try message.finish();
    try message.wait();

    const body = try message.reader().readAllAlloc(allocator, 1000000);
    defer allocator.free(body);
    
    std.debug.print("{} : {s}\n{}\n{s}", .{message.response.status, message.response.reason, message.response.headers, body});
}
