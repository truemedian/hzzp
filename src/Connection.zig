const std = @import("std");

const TlsImpl = @import("tls/openssl.zig");
const TlsClient = if (TlsImpl == void) void else TlsImpl.Client;

const Connection = @This();

pub const buffer_size = 1 << 14;
const BufferSize = std.math.IntFittingRange(0, buffer_size);

/// The stream this connection is using.
stream: std.net.Stream,

/// The TLS context for this connection. Will be undefined if this connection is not using TLS.
tls: TlsClient = undefined,

/// Whether this connection is using TLS.
is_tls: bool,

/// The buffer used for buffering reads from the stream.
read_buffer: [buffer_size]u8 = undefined,
read_start: BufferSize = 0,
read_end: BufferSize = 0,

/// The buffer used for buffering writes to the stream.
write_buffer: [buffer_size]u8 = undefined,
write_end: BufferSize = 0,

pub const ReadError = error{ ConnectionTimedOut, ConnectionResetByPeer, UnexpectedReadFailure, EndOfStream };

fn readvDirect(c: *Connection, iovecs: []std.os.iovec) ReadError!usize {
    if (c.is_tls) {
        if (TlsImpl == void) unreachable;

        if (@hasDecl(TlsImpl, "readv")) {
            return TlsImpl.readv(&c.tls, c.stream, iovecs) catch |err| switch (err) {
                error.ConnectionTimedOut => return error.ConnectionTimedOut,
                error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
                else => return error.UnexpectedReadFailure,
            };
        } else {
            const iovec = iovecs[0];
            return TlsImpl.read(&c.tls, c.stream, iovec.iov_base[0..iovec.iov_len]) catch |err| switch (err) {
                error.ConnectionTimedOut => return error.ConnectionTimedOut,
                error.ConnectionResetByPeer, error.BrokenPipe => return error.ConnectionResetByPeer,
                else => return error.UnexpectedReadFailure,
            };
        }
    }

    return c.stream.readv(iovecs) catch |err| switch (err) {
        error.ConnectionTimedOut => return error.ConnectionTimedOut,
        error.ConnectionResetByPeer, error.BrokenPipe => return error.ConnectionResetByPeer,
        else => return error.UnexpectedReadFailure,
    };
}

/// Read data from the stream into the internal buffer.
pub fn fill(c: *Connection) ReadError!void {
    if (c.read_end != c.read_start) return;

    var iovecs = [1]std.os.iovec{
        .{ .iov_base = &c.read_buffer, .iov_len = c.read_buffer.len },
    };
    const nread = try c.readvDirect(&iovecs);
    if (nread == 0) return error.EndOfStream;
    c.read_start = 0;
    c.read_end = @intCast(nread);
}

/// Return the contents of the internal buffer.
pub fn peek(c: *Connection) []const u8 {
    return c.read_buffer[c.read_start..c.read_end];
}

/// Drop the first `num` bytes from the internal buffer.
pub fn drop(c: *Connection, num: BufferSize) void {
    c.read_start += num;
}

/// Read data from the buffered stream into the given buffer.
pub fn read(c: *Connection, buffer: []u8) ReadError!usize {
    const available_read = c.read_end - c.read_start;
    const available_buffer = buffer.len;

    if (available_read > available_buffer) { // partially read buffered data
        @memcpy(buffer[0..available_buffer], c.read_buffer[c.read_start..c.read_end][0..available_buffer]);
        c.read_start += @intCast(available_buffer);

        return available_buffer;
    } else if (available_read > 0) { // fully read buffered data
        @memcpy(buffer[0..available_read], c.read_buffer[c.read_start..c.read_end]);
        c.read_start += available_read;

        return available_read;
    }

    var iovecs = [2]std.os.iovec{
        .{ .iov_base = buffer.ptr, .iov_len = buffer.len },
        .{ .iov_base = &c.read_buffer, .iov_len = c.read_buffer.len },
    };
    const nread = try c.readvDirect(&iovecs);

    if (nread > buffer.len) {
        c.read_start = 0;
        c.read_end = @intCast(nread - buffer.len);
        return buffer.len;
    }

    return nread;
}

pub const Reader = std.io.Reader(*Connection, ReadError, read);

pub fn reader(c: *Connection) Reader {
    return Reader{ .context = c };
}

pub const WriteError = error{
    ConnectionResetByPeer,
    UnexpectedWriteFailure,
};

fn writevAllDirect(c: *Connection, iovecs: []std.os.iovec_const) WriteError!void {
    if (c.is_tls) {
        if (TlsImpl == void) unreachable;

        if (@hasDecl(TlsImpl, "writevAll")) {
            TlsImpl.writevAll(&c.tls, c.stream, iovecs) catch |err| switch (err) {
                error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
                else => return error.UnexpectedWriteFailure,
            };
        } else {
            for (iovecs) |iovec| {
                TlsImpl.writeAll(&c.tls, c.stream, iovec.iov_base[0..iovec.io]) catch |err| switch (err) {
                    error.ConnectionResetByPeer, error.BrokenPipe => return error.ConnectionResetByPeer,
                    else => return error.UnexpectedWriteFailure,
                };
            }
        }
    }

    return c.stream.writevAll(iovecs) catch |err| switch (err) {
        error.BrokenPipe, error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
        else => return error.UnexpectedWriteFailure,
    };
}

/// Write data to the buffered stream.
pub fn write(c: *Connection, buffer: []const u8) WriteError!usize {
    if (c.write_end + buffer.len > c.write_buffer.len) {
        // buffer needs to be flushed to fit this data

        if (buffer.len > c.write_buffer.len) {
            // data won't fit in empty buffer, flush the buffer and write the data directly
            var iovecs = [2]std.os.iovec_const{
                .{ .iov_base = &c.write_buffer, .iov_len = c.write_end },
                .{ .iov_base = buffer.ptr, .iov_len = buffer.len },
            };

            try c.writevAllDirect(&iovecs);
            c.write_end = 0;
        } else {
            // data will fit in empty buffer, flush the buffer and buffer this write
            var iovecs = [1]std.os.iovec_const{
                .{ .iov_base = &c.write_buffer, .iov_len = c.write_end },
            };

            try c.writevAllDirect(&iovecs);
            c.write_end = 0;
        }
    }

    @memcpy(c.write_buffer[c.write_end..][0..buffer.len], buffer);
    c.write_end += @intCast(buffer.len);

    return buffer.len;
}

/// Flush the buffered stream, this ensures that all buffered data is written to the stream.
pub fn flush(c: *Connection) WriteError!void {
    if (c.write_end == 0) return;

    var iovecs = [1]std.os.iovec_const{
        .{ .iov_base = &c.write_buffer, .iov_len = c.write_end },
    };

    try c.writevAllDirect(&iovecs);
    c.write_end = 0;
}

pub const Writer = std.io.Writer(*Connection, WriteError, write);

pub fn writer(c: *Connection) Writer {
    return Writer{ .context = c };
}

/// Close the connection. Will perform a TLS shutdown if the connection is using TLS.
pub fn close(c: *Connection) void {
    if (c.is_tls) {
        if (TlsImpl == void) unreachable;

        TlsImpl.close(&c.tls, c.stream);
    }

    c.stream.close();
}

test {
    std.testing.refAllDeclsRecursive(@This());
}