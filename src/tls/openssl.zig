const std = @import("std");

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const Client = struct {
    ssl: *c.SSL,
    fatally_closed: bool,
};

pub const Context = struct {
    ctx: *c.SSL_CTX,

    pub fn init(ctx: *Context) !void {
        const method = c.TLS_client_method() orelse return error.TlsInitializationFailed;
        ctx.ctx = c.SSL_CTX_new(method) orelse return error.TlsInitializationFailed;
        _ = c.SSL_CTX_set_min_proto_version(ctx.ctx, c.TLS1_2_VERSION);
    }

    pub fn deinit(ctx: *Context, allocator: std.mem.Allocator) void {
        _ = allocator;
        c.SSL_CTX_free(ctx.ctx);
    }

    pub fn rescan(ctx: *Context, allocator: std.mem.Allocator) !void {
        _ = allocator;
        _ = c.SSL_CTX_use_certificate_chain_file(ctx.ctx, "/etc/ssl/certs/ca-certificates.crt");
    }
};

pub fn init(stream: std.net.Stream, ctx: *Context, host: [:0]const u8) !Client {
    var client: Client = undefined;

    client.fatally_closed = false;
    client.ssl = c.SSL_new(ctx.ctx) orelse return error.TlsInitializationFailed;
    errdefer c.SSL_free(client.ssl);

    if (c.SSL_set_tlsext_host_name(client.ssl, host) != 1) {
        return error.TlsInitializationFailed;
    }

    if (c.SSL_set_fd(client.ssl, @intCast(stream.handle)) != 1) {
        return error.TlsInitializationFailed;
    }

    if (c.SSL_connect(client.ssl) != 1) {
        return error.TlsInitializationFailed;
    }

    return client;
}

const ReadError = error{
    TlsFailure,
    UnexpectedReadFailure,
    ConnectionTimedOut,
    ConnectionResetByPeer,
};

pub fn readv(client: *Client, stream: std.net.Stream, iovecs: []std.os.iovec) ReadError!usize {
    _ = stream;

    while (true) {
        const ret = c.SSL_read(client.ssl, iovecs[0].iov_base, @intCast(iovecs[0].iov_len));

        switch (c.SSL_get_error(client.ssl, ret)) {
            c.SSL_ERROR_NONE => return @intCast(ret),
            c.SSL_ERROR_WANT_READ => continue,
            c.SSL_ERROR_WANT_WRITE => continue,
            c.SSL_ERROR_ZERO_RETURN => return 0,
            c.SSL_ERROR_SSL => {
                c.ERR_print_errors_fp(c.stderr);
                return error.TlsFailure;
            },
            c.SSL_ERROR_SYSCALL => {
                client.fatally_closed = true;
                if (c.ERR_get_error() == 0) {
                    switch (std.c.getErrno(-1)) {
                        .TIMEDOUT => return error.ConnectionTimedOut,
                        .CONNRESET => return error.ConnectionResetByPeer,
                        else => return error.UnexpectedReadFailure,
                    }
                } else {
                    return error.UnexpectedReadFailure;
                }
            },
            else => {
                client.fatally_closed = true;
                return error.UnexpectedReadFailure;
            },
        }
    }
}

const WriteError = error{
    TlsFailure,
    UnexpectedWriteFailure,
    ConnectionResetByPeer,
};

pub fn writevAll(client: *Client, stream: std.net.Stream, iovecs: []std.os.iovec_const) WriteError!void {
    _ = stream;

    loop: for (iovecs) |iovec| {
        while (true) {
            const ret = c.SSL_write(client.ssl, iovec.iov_base, @intCast(iovec.iov_len));

            switch (c.SSL_get_error(client.ssl, ret)) {
                c.SSL_ERROR_NONE => continue :loop,
                c.SSL_ERROR_WANT_READ => continue,
                c.SSL_ERROR_WANT_WRITE => continue,
                c.SSL_ERROR_ZERO_RETURN => return error.UnexpectedWriteFailure,
                c.SSL_ERROR_SSL => return error.TlsFailure,
                c.SSL_ERROR_SYSCALL => {
                    client.fatally_closed = true;

                    if (c.ERR_get_error() == 0) {
                        switch (std.c.getErrno(-1)) {
                            .CONNRESET => return error.ConnectionResetByPeer,
                            else => return error.UnexpectedWriteFailure,
                        }
                    } else {
                        return error.UnexpectedWriteFailure;
                    }
                },
                else => {
                    client.fatally_closed = true;
                    return error.UnexpectedWriteFailure;
                },
            }
        }
    }
}

pub fn close(client: *Client, stream: std.net.Stream) void {
    _ = stream;
    if (!client.fatally_closed) {
        _ = c.SSL_shutdown(client.ssl);
    }
}
