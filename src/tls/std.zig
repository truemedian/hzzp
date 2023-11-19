const std = @import("std");

pub const Client = std.crypto.tls.Client;
pub const Context = struct {
    ca_bundle: std.crypto.Certificate.Bundle = .{},

    pub fn init(ctx: *Context) !void {
        ctx.ca_bundle = .{};
    }

    pub fn deinit(ctx: *Context, allocator: std.mem.Allocator) void {
        ctx.ca_bundle.deinit(allocator);
    }

    pub fn rescan(ctx: *Context, allocator: std.mem.Allocator) !void {
        try ctx.ca_bundle.rescan(allocator);
    }
};

pub fn init(stream: std.net.Stream, ctx: *Context, host: [:0]const u8) !Client {
    var client = Client.init(stream, ctx.ca_bundle, host) catch return error.TlsInitializationFailed;
    client.allow_truncation_attacks = true;

    return client;
}

const ReadError = error{
    TlsFailure,
    UnexpectedReadFailure,
    ConnectionTimedOut,
    ConnectionResetByPeer,
};

pub fn readv(client: *Client, stream: std.net.Stream, iovecs: []std.os.iovec) ReadError!usize {
    return client.readv(stream, iovecs) catch |err| switch (err) {
        error.TlsConnectionTruncated, error.TlsRecordOverflow, error.TlsDecodeError, error.TlsBadRecordMac, error.TlsBadLength, error.TlsIllegalParameter, error.TlsUnexpectedMessage => return error.TlsFailure,
        error.ConnectionTimedOut => return error.ConnectionTimedOut,
        error.ConnectionResetByPeer, error.BrokenPipe => return error.ConnectionResetByPeer,
        else => return error.UnexpectedReadFailure,
    };
}

const WriteError = error{
    TlsFailure,
    UnexpectedWriteFailure,
    ConnectionResetByPeer,
};

pub fn writevAll(client: *Client, stream: std.net.Stream, iovecs: []std.os.iovec_const) WriteError!void {
    for (iovecs) |iovec| {
        client.writeAll(stream, iovec.iov_base[0..iovec.iov_len]) catch |err| switch (err) {
            error.ConnectionResetByPeer, error.BrokenPipe => return error.ConnectionResetByPeer,
            else => return error.UnexpectedWriteFailure,
        };
    }
}

pub fn close(client: *Client, stream: std.net.Stream) void {
    _ = client.writeEnd(stream, "", true) catch {};
}
