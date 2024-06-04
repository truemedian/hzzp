const Client = @This();

/// The connection this request is being made on.
connection: net.Stream,

/// A user-provided buffer that will be used to store the response and as
/// scratch space for temporary allocations.
read_buffer: []u8,

/// Amount of available data inside read_buffer.
read_buffer_len: usize,

/// Index into `read_buffer` of the first byte of the next HTTP request.
next_request_start: usize,

/// Whether the client or server has requested that the connection be kept open.
keep_alive: bool,

header_parser: HeaderParser,
chunk_header_parser: ChunkHeaderParser,

send_state: SendState,

pub fn init(connection: net.Stream, read_buffer: []u8) Client {
    return Client{
        .connection = connection,
        .read_buffer = read_buffer,
        .read_buffer_len = 0,
        .next_request_start = 0,
        .keep_alive = false,
        .header_parser = HeaderParser.init,
        .chunk_header_parser = ChunkHeaderParser.init,
        .send_state = .start,
    };
}

/// Used to track the state of a request being sent. This is necessary to handle non-blocking send.
pub const SendState = packed struct(u16) {
    pub const State = enum(u2) {
        start,
        extra,
        privileged,
        done,
    };

    state: State,
    count: u14,
};

/// Any value other than `not_allowed` or `unhandled` means that integer
/// represents how many remaining redirects are allowed.
pub const RedirectBehavior = enum(u16) {
    /// The next redirect will cause an error.
    not_allowed = 0,
    /// Redirects are passed to the client to analyze the redirect response
    /// directly.
    unhandled = std.math.maxInt(u16),
    _,

    pub fn subtractOne(rb: *RedirectBehavior) void {
        switch (rb.*) {
            .not_allowed => unreachable,
            .unhandled => unreachable,
            _ => rb.* = @enumFromInt(@intFromEnum(rb.*) - 1),
        }
    }

    pub fn remaining(rb: RedirectBehavior) u16 {
        assert(rb != .unhandled);
        return @intFromEnum(rb);
    }
};

pub const Request = struct {
    client: *Client,
    options: SendOptions,

    pub fn write(req: *Request, data: []const u8) !usize {
        switch (req.options.transfer) {
            .none => return error.MalformedPayload,
            .close => try req.client.connection.write(data),
            .chunked => {
                var buffer: [20]u8 = undefined; // Theoretically 16 + 2 is enough, but have 2 extra bytes for safety.
                const size = fmt.bufPrint(&buffer, "{x}\r\n", .{data.len}) catch unreachable;

                const iovs: [3]std.posix.iovec_const = .{
                    .{ .iov_base = size.ptr, .iov_len = size.len },
                    .{ .iov_base = data, .iov_len = data.len },
                    .{ .iov_base = "\r\n", .iov_len = 2 },
                };

                try req.client.connection.writevAll(iovs);
            },
            else => |left| {
                if (data.len > @intFromEnum(left))
                    return error.MalformedPayload;

                const written = try req.client.connection.write(data);
                req.options.transfer = @enumFromInt(@intFromEnum(left) -% written);

                return written;
            },
        }
    }

    /// Finish the request. This will finalize any present transfer encoding
    /// and close the connection if necessary.
    ///
    /// This function will preserve consistency over the connection. If any
    /// non-`WouldBlock` error occurs, the connection will be closed.
    pub fn finish(req: *Request) error{ WouldBlock, MalformedPayload }!void {
        switch (req.options.transfer) {
            .none => {},
            .close => req.client.connection.close(),
            .chunked => req.client.connection.writeAll("\r\n0\r\n\r\n") catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock, // pass through WouldBlock.
                else => req.client.connection.close(), // any other error is irrecoverable.
            },
            else => {
                req.client.connection.close();
                return error.MalformedPayload;
            },
        }
    }
};

pub const SendOptions = struct {
    /// This identifies the server to connect to as well as the path to request.
    /// Externally-owned; must outlive the Request.
    uri: std.Uri,
    method: http.Method,
    version: http.Version = .@"HTTP/1.1",

    /// The transfer encoding to use for the request body. If the value is not
    /// `.none` or `.chunked`, the `Content-Length` header will be set to the
    /// value of this field.
    transfer: http.TransferEncoding = .none,

    /// Standard headers that have default, but overridable, behavior.
    standard_headers: Headers = .{},

    /// These headers are kept including when following a redirect to a
    /// different domain.
    /// Externally-owned; must outlive the Request.
    extra_headers: []const http.Header = &.{},

    /// These headers are stripped when following a redirect to a different
    /// domain.
    /// Externally-owned; must outlive the Request.
    privileged_headers: []const http.Header = &.{},

    pub const Headers = struct {
        host: Value = .default,
        user_agent: Value = .default,
        connection: Value = .default,
        accept_encoding: Value = .default,

        pub const Value = union(enum) {
            /// Allow hzzp to generate a sane default value.
            default,

            /// Avoid sending this header altogether.
            omit,

            /// Use the provided string as the header value.
            override: []const u8,
        };
    };
};

pub fn send(client: *Client, options: SendOptions) !Request {
    var fba = std.heap.FixedBufferAllocator.init(client.read_buffer);

    // enough iovecs for the request line, standard headers, 10 extra headers and the final \r\n\r\n
    var iovs: [5 + 5 * 2 + 10 * 4 + 1]net.IoSliceConst = undefined;
    var iovs_len: u8 = 0;

    var pending_state = client.send_state;
    if (pending_state.state == .start) {
        iovs[iovs_len].set(@tagName(options.method));
        iovs_len += 1;

        iovs[iovs_len].set(" ");
        iovs_len += 1;

        const proxied = false; // TODO: implement proxy support
        if (options.method == .CONNECT) {
            const target = try fmt.allocPrint(fba.allocator(), "{+}", .{options.uri});
            iovs[iovs_len].set(target);
            iovs_len += 1;
        } else if (proxied) {
            const target = try fmt.allocPrint(fba.allocator(), "{;@+/?}", .{options.uri});
            iovs[iovs_len].set(target);
            iovs_len += 1;
        } else {
            const target = try fmt.allocPrint(fba.allocator(), "{/?}", .{options.uri});
            iovs[iovs_len].set(target);
            iovs_len += 1;
        }

        iovs[iovs_len].set(" ");
        iovs_len += 1;

        iovs[iovs_len].set(@tagName(options.version));
        iovs_len += 1;

        if (options.standard_headers.host != .omit) {
            // TODO: fetch host from connection, uri.host is not correct
            iovs[iovs_len].set("\r\nHost: ");
            iovs_len += 1;

            iovs[iovs_len].set(switch (options.standard_headers.host) {
                .default => options.uri.host.?,
                .override => |override| override,
                .omit => unreachable,
            });
            iovs_len += 1;
        }

        if (options.standard_headers.user_agent != .omit) {
            iovs[iovs_len].set("\r\nUser-Agent: ");
            iovs_len += 1;

            iovs[iovs_len].set(switch (options.standard_headers.user_agent) {
                .default => "hzzp/0.1",
                .override => |override| override,
                .omit => unreachable,
            });
            iovs_len += 1;
        }

        if (options.standard_headers.connection != .omit) {
            iovs[iovs_len].set("\r\nConnection: ");
            iovs_len += 1;

            // by default we send keep-alive, but the user can opt-out of keep-alive
            // by setting the connection header to "close"
            client.keep_alive = switch (options.standard_headers.connection) {
                .default => true,
                .override => |override| !std.ascii.eqlIgnoreCase(override, "close"),
                .omit => unreachable,
            };

            iovs[iovs_len].set(switch (options.standard_headers.connection) {
                .default => "keep-alive",
                .override => |override| override,
                .omit => unreachable,
            });
            iovs_len += 1;
        } else {
            client.keep_alive = switch (options.version) {
                .@"HTTP/1.1" => true,
                .@"HTTP/1.1" => false,
                else => unreachable,
            };
        }

        if (options.standard_headers.accept_encoding != .omit) {
            iovs[iovs_len].set("\r\nAccept-Encoding: ");
            iovs_len += 1;

            iovs[iovs_len].set(switch (options.standard_headers.accept_encoding) {
                .default => "gzip, deflate",
                .override => |s| s,
            });
            iovs_len += 1;
        }

        switch (options.transfer) {
            .none => {},
            .chunked => {
                iovs[iovs_len].set("\r\nTransfer-Encoding: chunked");
                iovs_len += 1;
            },
            else => |n| {
                const content_length = try fmt.allocPrint(fba.allocator(), "{d}", .{@intFromEnum(n)});

                iovs[iovs_len].set("\r\nContent-Length: ");
                iovs_len += 1;

                iovs[iovs_len].set(content_length);
                iovs_len += 1;
            },
        }

        // We're done with the standard headers, continue with the first extra header
        pending_state.state = .extra;
        pending_state.count = 0;
    }

    // Up to this point we're guaranteed to have enough iovecs for the headers,
    // but past this point we might need to flush the headers.

    // We need to send the extra headers before the privileged headers.
    if (pending_state.state == .extra) {
        assert(pending_state.count < options.extra_headers.len);

        for (options.extra_headers[pending_state.count..], pending_state.count..) |header, i| {
            if (iovs_len + 4 >= iovs.len) {
                try client.connection.writevAll(iovs[0..iovs_len]);
                iovs_len = 0;

                pending_state.count = i; // save the current index so that we can continue from it
                client.send_state = pending_state;
            }

            iovs[iovs_len].set("\r\n");
            iovs_len += 1;

            iovs[iovs_len].set(header.name);
            iovs_len += 1;

            iovs[iovs_len].set(": ");
            iovs_len += 1;

            iovs[iovs_len].set(header.value);
            iovs_len += 1;
        }

        pending_state.state = .privileged;
        pending_state.count = 0;
    }

    if (pending_state.state == .privileged) {
        for (options.privileged_headers[pending_state.count..], pending_state.count..) |header, i| {
            if (iovs_len + 4 >= iovs.len) {
                try client.connection.writevAll(iovs[0..iovs_len]);
                iovs_len = 0;

                pending_state.count = i; // save the current index so that we can continue from it
                client.send_state = pending_state;
            }

            iovs[iovs_len].set("\r\n");
            iovs_len += 1;

            iovs[iovs_len].set(header.name);
            iovs_len += 1;

            iovs[iovs_len].set(": ");
            iovs_len += 1;

            iovs[iovs_len].set(header.value);
            iovs_len += 1;
        }

        pending_state.state = .done;
        pending_state.count = 0;
    }

    if (pending_state.state == .done and pending_state.count == 0) {
        if (iovs_len + 1 >= iovs.len) {
            try client.connection.writevAll(iovs[0..iovs_len]);
            iovs_len = 0;

            client.send_state = pending_state;
        }

        iovs[iovs_len].set("\r\n\r\n");
        iovs_len += 1;

        try client.connection.writevAll(iovs[0..iovs_len]);

        pending_state.count = 1;
        client.send_state = pending_state;
    }

    return Request{
        .client = client,
        .options = options,
    };
}

const std = @import("std");
const http = @import("http.zig");

const HeaderParser = @import("HeaderParser.zig");
const ChunkHeaderParser = @import("ChunkHeaderParser.zig");

const math = std.math;
const net = std.net;
const fmt = std.fmt;

const assert = std.debug.assert;
