const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const Connection = @import("Connection.zig");

test {
    std.testing.refAllDecls(@This());
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const stream = try std.net.tcpConnectToHost(allocator, "github.com", 443);

    var tls_ctx: Connection.TlsImpl.Context = undefined;
    try tls_ctx.init();
    try tls_ctx.rescan(allocator);
    
    var tls_client = try Connection.TlsImpl.init(stream, &tls_ctx, "github.com");

    var conn = Connection{ .stream = stream, .tls = tls_client, .is_tls = true };
    defer conn.close();

    var req = protocol.http1.Request{ .connection = &conn };
    try req.send(.{
        .uri = std.Uri.parse("http://github.com") catch unreachable,
        .headers = .{ .allocator = undefined },
    });

    try req.finish();

    var res = try req.wait(allocator);

    const body = try res.reader().readAllAlloc(allocator, 1000000);
    defer allocator.free(body);
    
    std.debug.print("{} : {s}\n{}\n{s}", .{res.status, res.reason, res.headers, body});
}
