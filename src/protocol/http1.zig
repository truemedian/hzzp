const std = @import("std");
const builtin = @import("builtin");

const http = @import("../protocol.zig");
const Connection = @import("../Connection.zig");

const assert = std.debug.assert;

pub const ClientStatus = struct {
    method: http.Method,
    target: []const u8,
    version: http.Version,
};

pub const ServerStatus = struct {
    version: http.Version,
    status: u16,
    reason: []const u8,
};

pub const ContentLength = enum(u64) {
    /// content-length or transfer-encoding not present.
    /// Only valid for server responses.
    none = std.math.maxInt(u64),

    /// Indicates that the message is chunked.
    chunked = std.math.maxInt(u64) - 1,

    /// Any other value indicates the length of the message.
    _,

    pub fn fromInt(value: u64) ContentLength {
        assert(value < std.math.maxInt(u64) - 1);

        return @enumFromInt(value);
    }

    pub fn isEmpty(self: ContentLength) bool {
        return self == .none or @intFromEnum(self) == 0;
    }
};

pub const Parser = struct {
    const buffer_size = 16 * 1024;

    pub const State = enum(u16) {
        invalid,
        done,

        // Parse chunked encoding
        chunk_head_size = 1 << 12,
        chunk_head_ext = 2 << 12,
        chunk_head_r = 3 << 12,
        chunk_data = 4 << 12,
        chunk_data_suffix = 5 << 12,
        chunk_data_suffix_r = 6 << 12,

        // Search for { CR LF CR LF } or { LF LF }.
        ground = 1 << 8,
        seen_r = 2 << 8,
        seen_rn = 3 << 8,
        seen_rnr = 4 << 8,
        seen_n = 5 << 8,
        finished = 6 << 8,

        fn isHeaders(state: State) bool {
            switch (state) {
                .ground, .seen_r, .seen_rn, .seen_rnr, .seen_n => return true,
                else => return false,
            }
        }

        fn isChunkedHeaders(state: State) bool {
            switch (state) {
                .chunk_head_size, .chunk_head_ext, .chunk_head_r, .chunk_data_suffix, .chunk_data_suffix_r => return true,
                else => return false,
            }
        }
    };

    state: State,

    /// The buffer for the message body.
    header_bytes: std.ArrayListUnmanaged(u8) = .{},

    /// Whether resizes of the headers buffer is allowed. If false, the buffer is static and cannot be grown.
    header_bytes_dynamic: bool,

    /// The maximum amount of bytes allowed in a header before it will be rejected.
    header_bytes_max: usize,

    /// The length of the next (or only) chunk of the body.
    next_chunk_length: u64 = 0,

    inline fn mixState(s: State, c: u8) u16 {
        return @as(u16, @intFromEnum(s)) | c;
    }

    pub fn processHeaders(p: *Parser, allocator: std.mem.Allocator, bytes: []const u8) !u32 {
        assert(bytes.len < std.math.maxInt(u32));
        assert(p.state.isHeaders());

        const end = findHeadersEnd(p, bytes);
        const data = bytes[0..end];

        if (p.header_bytes.items.len + data.len > p.header_bytes_max) {
            return error.HeadersExceededLimit;
        } else {
            if (p.header_bytes_dynamic) try p.header_bytes.ensureUnusedCapacity(allocator, data.len);

            p.header_bytes.appendSliceAssumeCapacity(data);
        }

        return end;
    }

    pub fn processChunkedLen(p: *Parser, bytes: []const u8) u32 {
        assert(bytes.len < std.math.maxInt(u32));
        assert(p.state.isChunkedHeaders());

        return findChunkedLen(p, bytes);
    }

    pub fn findHeadersEnd(p: *Parser, bytes: []const u8) u32 {
        assert(bytes.len < std.math.maxInt(u32));
        assert(p.state.isHeaders());

        const len: u32 = @intCast(bytes.len);
        var index: u32 = 0;

        const ptr = bytes.ptr;
        var state = p.state;
        while (index < len and state != .finished) {
            const optimal_vector_size = comptime std.simd.suggestVectorSize(u8) orelse 0;

            if (state == .ground) {
                if (optimal_vector_size != 0 and optimal_vector_size < len - index) {
                    const vec_cr: @Vector(optimal_vector_size, u8) = @splat('\r');
                    const vec_lf: @Vector(optimal_vector_size, u8) = @splat('\n');

                    const vec: @Vector(optimal_vector_size, u8) = @bitCast(ptr[index..][0..optimal_vector_size].*);
                    const matches_cr: @Vector(optimal_vector_size, u1) = @bitCast(vec == vec_cr);
                    const matches_lf: @Vector(optimal_vector_size, u1) = @bitCast(vec == vec_lf);

                    const matches: @Vector(optimal_vector_size, bool) = @bitCast(matches_cr | matches_lf);

                    if (std.simd.firstTrue(matches)) |i| {
                        index += i;
                    } else {
                        index += optimal_vector_size;
                        continue;
                    }
                } else {
                    if (ptr[index] != '\r') {
                        index += 1;
                        continue;
                    }
                }
            }

            switch (mixState(state, ptr[index])) {
                mixState(.ground, '\r') => state = .seen_r,
                mixState(.ground, '\n') => state = .seen_n,
                mixState(.seen_r, '\n') => state = .seen_rn,
                mixState(.seen_rn, '\r') => state = .seen_rnr,
                mixState(.seen_rnr, '\n') => state = .finished,
                mixState(.seen_n, '\n') => state = .finished,
                else => state = .ground,
            }

            index += 1;
        }

        p.state = state;
        return index;
    }

    pub fn findChunkedLen(p: *Parser, bytes: []const u8) u32 {
        assert(bytes.len < std.math.maxInt(u32));
        assert(p.state.isChunkedHeaders());

        var state = p.state;

        // this required for the optimizer to be able to completely optimize out the unreachable cases
        // any code added here must be vetted to ensure that unreachable cases remain unreachable
        @setRuntimeSafety(false);

        const index = blk: for (bytes, 0..) |c, i| {
            if (c == '\r' or c == '\n') {
                switch (mixState(state, c)) {
                    mixState(.chunk_data_suffix, '\r') => state = .chunk_data_suffix_r,
                    mixState(.chunk_data_suffix, '\n') => state = .chunk_head_size,
                    mixState(.chunk_data_suffix_r, '\n') => state = .chunk_head_size,
                    mixState(.chunk_head_size, '\r') => state = .chunk_head_r,
                    mixState(.chunk_head_size, '\n') => state = .chunk_data,
                    mixState(.chunk_head_ext, '\r') => state = .chunk_head_r,
                    mixState(.chunk_head_ext, '\n') => state = .chunk_data,
                    mixState(.chunk_head_r, '\n') => state = .chunk_data,
                    else => {},
                }

                if (state == .chunk_data) break :blk i;
            } else {
                switch (c) {
                    '0'...'9' => switch (state) {
                        .chunk_head_size => {
                            const digit = c - '0';

                            // this addition cannot overflow, because `digit` cannot be greater than 15
                            // however, the multiplication may, so we much check for it.
                            const new_len = p.next_chunk_length *% 16 + digit;
                            if (new_len < p.next_chunk_length) {
                                state = .invalid;
                                break :blk i;
                            }

                            p.next_chunk_length = new_len;
                        },
                        .chunk_head_ext => {},
                        else => {
                            state = .invalid;
                            break :blk i;
                        },
                    },
                    'A'...'F' => switch (state) {
                        .chunk_head_size => {
                            const digit = c - 'A' + 10;

                            // this addition cannot overflow, because `digit` cannot be greater than 15
                            // however, the multiplication may, so we much check for it.
                            const new_len = p.next_chunk_length *% 16 + digit;
                            if (new_len < p.next_chunk_length) {
                                state = .invalid;
                                break :blk i;
                            }

                            p.next_chunk_length = new_len;
                        },
                        .chunk_head_ext => {},
                        else => {
                            state = .invalid;
                            break :blk i;
                        },
                    },
                    'a'...'f' => switch (state) {
                        .chunk_head_size => {
                            const digit = c - 'a' + 10;

                            // this addition cannot overflow, because `digit` cannot be greater than 15
                            // however, the multiplication may, so we much check for it.
                            const new_len = p.next_chunk_length *% 16 + digit;
                            if (new_len < p.next_chunk_length) {
                                state = .invalid;
                                break :blk i;
                            }

                            p.next_chunk_length = new_len;
                        },
                        .chunk_head_ext => {},
                        else => {
                            state = .invalid;
                            break :blk i;
                        },
                    },
                    ';' => switch (state) {
                        .chunk_head_size => state = .chunk_head_ext,
                        .chunk_head_ext => {},
                        else => {
                            state = .invalid;
                            break :blk i;
                        },
                    },
                    '\r', '\n' => unreachable,
                    else => switch (state) {
                        .chunk_head_ext => {},
                        else => {
                            state = .invalid;
                            break :blk i;
                        },
                    },
                }
            }
        } else bytes.len;

        p.state = state;
        return @intCast(index);
    }
};

pub const Request = struct {
    connection: *Connection,

    content_length: ContentLength = .none,

    pub const SendOptions = struct {
        uri: std.Uri,
        escape_uri: bool = true,

        method: http.Method = .GET,
        headers: http.Headers,
    };

    pub const SendError = Connection.WriteError || error{
        UnsupportedTransferEncoding,
        MismatchedTransferEncoding,
        InvalidContentLength,
        MismatchedContentLength,
    };

    /// Send the HTTP request headers to the server.
    pub fn send(req: *Request, options: SendOptions) SendError!void {
        const proxied = false; // TODO: figure out where the proxied field should go

        if (!options.method.requestHasBody() and !req.content_length.isEmpty()) {
            return error.UnsupportedTransferEncoding; // Request isn't allowed to have a body, this transfer encoding implies content.
        }

        const w = req.connection.writer();

        try options.method.write(w);
        try w.writeByte(' ');

        if (options.method == .CONNECT) {
            try options.uri.writeToStream(.{ .authority = true }, w);
        } else {
            try options.uri.writeToStream(.{
                .scheme = proxied,
                .authentication = proxied,
                .authority = proxied,
                .path = true,
                .query = true,
                .raw = !options.escape_uri,
            }, w);
        }

        try w.writeAll(" HTTP/1.1\r\n");

        if (!options.headers.contains("host")) {
            try w.writeAll("Host: ");
            try options.uri.writeToStream(.{ .authority = true }, w);
            try w.writeAll("\r\n");
        }

        if (!options.headers.contains("user-agent")) {
            try w.writeAll("User-Agent: hzzp\r\n");
        }

        if (!options.headers.contains("connection")) {
            try w.writeAll("Connection: keep-alive\r\n");
        }

        if (!options.headers.contains("accept")) {
            try w.writeAll("Accept: */*\r\n");
        }

        if (!options.headers.contains("accept-encoding")) {
            try w.writeAll("Accept-Encoding: gzip, deflate, zstd\r\n");
        }

        if (!options.headers.contains("te")) {
            try w.writeAll("TE: gzip, deflate\r\n");
        }

        const transfer_encoding = options.headers.getFirstValue("transfer-encoding");
        const content_length = options.headers.getFirstValue("content-length");

        if (transfer_encoding) |coding| {
            if (!options.method.requestHasBody()) {
                return error.UnsupportedTransferEncoding; // This method isn't allowed to have a body, this content length implies content.
            }

            if (std.mem.eql(u8, coding, "chunked")) {
                if (!req.content_length.isEmpty()) {
                    return error.MismatchedTransferEncoding; // The value of the transfer-encoding header doesn't match the request field.
                }

                req.content_length = .chunked;
            } else {
                return error.UnsupportedTransferEncoding; // We don't support any other transfer encodings.
            }
        } else if (content_length) |length_str| {
            const length = std.fmt.parseUnsigned(u64, length_str, 10) catch return error.InvalidContentLength;
            if (length != @intFromEnum(req.content_length)) {
                return error.MismatchedContentLength; // The value of the content-length header doesn't match the request field.
            }

            if (length > 0) {
                if (!options.method.requestHasBody()) {
                    return error.UnsupportedTransferEncoding; // This method isn't allowed to have a body, this content length implies content.
                }

                req.content_length = ContentLength.fromInt(length);
            } else {
                req.content_length = .none;
            }
        } else {
            switch (req.content_length) {
                .none => {},
                .chunked => try w.writeAll("Transfer-Encoding: chunked\r\n"),
                else => {
                    try w.writeAll("Content-Length: ");
                    try std.fmt.formatInt(@intFromEnum(req.content_length), 10, .lower, .{}, w);
                    try w.writeAll("\r\n");
                },
            }
        }

        for (options.headers.list.items) |entry| {
            if (entry.value.len == 0) continue;

            try w.writeAll(entry.name);
            try w.writeAll(": ");
            try w.writeAll(entry.value);
            try w.writeAll("\r\n");
        }

        // TODO: handle proxy headers

        try w.writeAll("\r\n");

        try req.connection.flush();
    }

    pub const WriteError = Connection.WriteError || error{ NotWritable, MessageTooLong };

    pub fn write(req: *Request, data: []const u8) WriteError!usize {
        const w = req.connection.writer();

        switch (req.content_length) {
            .none => return error.NotWritable,
            .chunked => {
                try std.fmt.formatInt(@intCast(data.len), 16, .lower, .{}, w);
                try w.writeAll("\r\n");
                try w.writeAll(data);
                try w.writeAll("\r\n");

                return data.len;
            },
            else => {
                if (data.len > @intFromEnum(req.content_length)) return error.MessageTooLong;

                // Adjust the content length to account for the data written.
                req.content_length = ContentLength.fromInt(@intFromEnum(req.content_length) - data.len);

                try w.writeAll(data);
                return data.len;
            },
        }
    }

    pub const Writer = std.io.Writer(*Request, WriteError, write);

    pub fn writer(req: *Request) Writer {
        return .{ .context = req };
    }

    pub const FinishError = Connection.WriteError || error{MessageNotComplete};

    pub fn finish(req: *Request) FinishError!void {
        const w = req.connection.writer();

        switch (req.content_length) {
            .chunked => try w.writeAll("0\r\n\r\n"),
            else => if (!req.content_length.isEmpty()) return error.MessageNotComplete,
        }

        try req.connection.flush();
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
