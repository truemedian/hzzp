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

    state: State = .ground,

    /// For handling chunked message trailers.
    trailing: bool = false,

    /// The buffer for the message body.
    header_bytes: std.ArrayListUnmanaged(u8) = .{},

    /// Whether resizes of the headers buffer is allowed. If false, the buffer is static and cannot be grown.
    header_bytes_dynamic: bool,

    /// The maximum amount of bytes allowed in a header before it will be rejected.
    header_bytes_max: usize,

    /// The length of the next (or only) chunk of the body.
    next_chunk_length: u64 = 0,

    /// Initializes the parser with a dynamically growing header buffer of up to `max` bytes.
    pub fn initDynamic(max: usize) Parser {
        return .{
            .header_bytes = .{},
            .header_bytes_max = max,
            .header_bytes_dynamic = true,
        };
    }

    /// Initializes the parser with a provided buffer `buf`.
    pub fn initStatic(buf: []u8) Parser {
        return .{
            .header_bytes = .{ .items = buf[0..0], .capacity = buf.len },
            .header_bytes_max = buf.len,
            .header_bytes_dynamic = false,
        };
    }

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

    pub const ReadError = error{InvalidChunkedEncoding} || Connection.ReadError;

    pub fn read(p: *Parser, c: *Connection, buffer: []u8) ReadError!usize {
        assert(p.trailing or !p.state.isHeaders());

        var out_index: usize = 0;
        while (true) switch (p.state) {
            .done => return out_index,
            .invalid => unreachable,
            .ground, .seen_r, .seen_n, .seen_rn, .seen_rnr => {
                try c.fill();

                // TODO: handle trailing headers
                const i = p.findHeadersEnd(c.peek());
                c.drop(@intCast(i));

                if (p.state == .invalid) return error.InvalidChunkedEncoding;
                if (p.state == .finished) p.state = .done;
            },
            .chunk_data_suffix, .chunk_data_suffix_r, .chunk_head_size, .chunk_head_ext, .chunk_head_r => {
                try c.fill();

                const i = p.processChunkedLen(c.peek());
                c.drop(@intCast(i));

                if (p.state == .invalid) return error.InvalidChunkedEncoding;
                if (p.next_chunk_length == 0) {
                    p.trailing = true;
                    p.state = .seen_rn;
                }
            },
            .chunk_data, .finished => {
                const data_avail = p.next_chunk_length;
                const out_avail = buffer.len - out_index;

                const can_read: u32 = @intCast(@min(data_avail, out_avail, std.math.maxInt(u32)));
                const nread = try c.read(buffer[out_index .. out_index + can_read]);

                p.next_chunk_length -= nread;
                out_index += nread;

                if (p.next_chunk_length == 0) switch (p.state) {
                    .chunk_data => {
                        p.state = .chunk_data_suffix;
                        continue;
                    },
                    .finished => p.state = .done,
                    else => unreachable,
                };

                return out_index;
            },
        };
    }

    pub const WaitForHeadersError = error{HeadersExceededLimit} || std.mem.Allocator.Error || Connection.ReadError;

    pub fn waitForHeaders(p: *Parser, allocator: std.mem.Allocator, c: *Connection) WaitForHeadersError!void {
        assert(p.state.isHeaders());

        while (p.state.isHeaders()) {
            try c.fill();

            const i = try p.processHeaders(allocator, c.peek());
            c.drop(@intCast(i));
        }
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

                if (state == .chunk_data) break :blk i + 1;
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

    test findHeadersEnd {
        var p = Parser.initDynamic(1024);

        try std.testing.expectEqual(@as(u32, 16), p.findHeadersEnd("HEAD\r\nHeader\r\n\r\nHello"));
        try std.testing.expectEqual(State.finished, p.state);
    }

    test findChunkedLen {
        var p = Parser.initDynamic(1024);
        p.state = .chunk_head_size;

        try std.testing.expectEqual(@as(u32, 3), p.findChunkedLen("0\r\n\r\n"));
        try std.testing.expectEqual(State.chunk_data, p.state);
        try std.testing.expectEqual(@as(u64, 0), p.next_chunk_length);

        p = Parser.initDynamic(1024);
        p.state = .chunk_head_size;

        try std.testing.expectEqual(@as(u32, 8), p.findChunkedLen("1abcde\r\n"));
        try std.testing.expectEqual(State.chunk_data, p.state);
        try std.testing.expectEqual(@as(u64, 0x1abcde), p.next_chunk_length);
    }
};

pub const Request = struct {
    pub const State = enum {
        start, // nothing has been sent, writing the headers
        payload, // headers have been sent, writing the body
        finished, // headers and payload have been sent, client side is done
    };

    pub const Compression = union(enum) {
        pub const Deflate = std.compress.deflate.Compressor(PlainWriter);

        identity,
        deflate: Deflate,
    };

    /// The compression of the payload.
    compression: Compression = .identity,

    /// The length of the request payload, or `chunked` for a chunked message.
    content_length: ContentLength = .none,
    state: State = .start,

    pub const SetCompressionError = error{UnsupportedTransferEncoding} || std.mem.Allocator.Error;

    /// Set the compression to be used in this request. May only be called before sending headers.
    pub fn setCompression(req: *Request, connection: *Connection, allocator: std.mem.Allocator, compression: std.meta.Tag(Compression)) SetCompressionError!void {
        assert(req.state == .start);

        if (compression != .identity and req.content_length != .chunked) {
            return error.UnsupportedTransferEncoding; // Compression is only supported with chunked messages.
        }

        if (compression != req.compression) switch (req.compression) {
            .identity => {},
            .deflate => req.compression.deflate.deinit(),
        };

        req.compression = switch (compression) {
            .identity => .identity,
            .deflate => .{ .deflate = try std.compress.deflate.compressor(allocator, req.plainWriter(connection), .{}) },
        };
    }

    pub const SendOptions = struct {
        uri: std.Uri,
        escape_uri: bool = true,

        method: http.Method = .GET,
        headers: http.Headers,
    };

    pub const SendError = Connection.WriteError || error{UnsupportedTransferEncoding};

    /// Send the HTTP request headers to the server.
    pub fn send(req: *Request, connection: *Connection, options: SendOptions) SendError!void {
        assert(req.state == .start);

        const proxied = false; // TODO: figure out where the proxied field should go

        if (!options.method.requestHasBody() and !req.content_length.isEmpty()) {
            return error.UnsupportedTransferEncoding; // Request isn't allowed to have a body, this transfer encoding implies content.
        }

        const w = connection.writer();

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
            try w.writeAll("Connection: keep-alive, TE\r\n");
        } else {
            const value = options.headers.getFirstValue("connection");
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                connection.keep_alive = false;
            }
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

        if (options.headers.contains("transfer-encoding") or options.headers.contains("content-length")) {
            return error.UnsupportedTransferEncoding; // These headers are not allowed to be set by the user. They are set automatically.
        }

        switch (req.content_length) {
            .none => {},
            .chunked => switch (req.compression) {
                .identity => try w.writeAll("Transfer-Encoding: chunked\r\n"),
                .deflate => try w.writeAll("Transfer-Encoding: deflate, chunked\r\n"),
            },
            else => {
                try w.writeAll("Content-Length: ");
                try std.fmt.formatInt(@intFromEnum(req.content_length), 10, .lower, .{}, w);
                try w.writeAll("\r\n");
            },
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

        try connection.flush();
        req.state = .payload;
    }

    const PlainWriteError = Connection.WriteError || error{ NotWritable, MessageTooLong };

    /// Write data to the request body without any compression.
    fn plainWrite(req: *Request, connection: *Connection, data: []const u8) PlainWriteError!usize {
        assert(req.state == .payload);

        const w = connection.writer();

        switch (req.content_length) {
            .none => return error.NotWritable,
            .chunked => {
                try std.fmt.formatInt(data.len, 16, .lower, .{}, w);
                try w.writeAll("\r\n");
                try w.writeAll(data);
                try w.writeAll("\r\n");

                return data.len;
            },
            else => {
                if (data.len > @intFromEnum(req.content_length)) return error.MessageTooLong; // The amount of data sent would exceed the content length reported to the server.

                // Adjust the content length to account for the data written.
                req.content_length = ContentLength.fromInt(@intFromEnum(req.content_length) - data.len);

                try w.writeAll(data);
                return data.len;
            },
        }
    }

    const PlainWriter = std.io.Writer(PlainWriterWrapped, PlainWriteError, PlainWriterWrapped.write);
    const PlainWriterWrapped = struct {
        req: *Request,
        connection: *Connection,

        fn write(wrapper: PlainWriterWrapped, data: []const u8) PlainWriteError!usize {
            return Request.plainWrite(wrapper.req, wrapper.connection, data);
        }
    };

    fn plainWriter(req: *Request, connection: *Connection) PlainWriter {
        return .{ .context = .{ .req = req, .connection = connection } };
    }

    pub const WriteError = PlainWriteError || Compression.Deflate.Error;

    /// Write data to the request body.
    pub fn write(req: *Request, connection: *Connection, data: []const u8) WriteError!usize {
        assert(req.state == .payload);

        switch (req.compression) {
            .identity => return try req.plainWrite(connection, data),
            .deflate => return try req.compression.deflate.write(data),
        }
    }

    pub const Writer = std.io.Writer(WriterWrapped, WriteError, WriterWrapped.write);
    const WriterWrapped = struct {
        req: *Request,
        connection: *Connection,

        fn write(wrapper: WriterWrapped, data: []const u8) WriteError!usize {
            return Request.write(wrapper.req, wrapper.connection, data);
        }
    };

    pub fn writer(req: *Request, connection: *Connection) Writer {
        return .{ .context = .{ .req = req, .connection = connection } };
    }

    pub const FinishError = WriteError || error{MessageNotComplete};

    /// Finish the request body.
    pub fn finish(req: *Request, connection: *Connection) FinishError!void {
        assert(req.state == .payload);

        const w = connection.writer();

        switch (req.compression) {
            .identity => {},
            .deflate => try req.compression.deflate.flush(),
        }

        switch (req.content_length) {
            .chunked => try w.writeAll("0\r\n\r\n"),
            else => if (!req.content_length.isEmpty()) return error.MessageNotComplete, // We reported a content length to the server, but didn't write that much data.
        }

        try connection.flush();
        req.state = .finished;
    }
};

pub const Response = struct {
    pub const State = enum {
        start,
        initializing,
        payload,
        closed,
    };

    pub const Decompression = union(enum) {
        pub const Deflate = std.compress.deflate.Decompressor(PlainReader);
        pub const Gzip = std.compress.gzip.Decompress(PlainReader);
        pub const Zstd = std.compress.zstd.DecompressStream(PlainReader, .{});

        identity,
        gzip: Gzip,
        deflate: Deflate,
        zstd: Zstd,
    };

    parser: Parser,

    status: http.Status = undefined,
    reason: []const u8 = undefined,
    headers: http.Headers,

    decompression: Decompression = .identity,
    content_length: ContentLength = .none,
    state: State = .start,

    pub const WaitOptions = struct {
        wait_for_continue: bool = false,
    };

    pub const WaitError = error{ HeadersInvalid, UnsupportedTransferEncoding, DecompressionInitializationFailed } || std.mem.Allocator.Error || Parser.WaitForHeadersError;

    fn int64(b: *const [8]u8) u64 {
        const p: *align(1) const u64 = @ptrCast(b);
        return p.*;
    }

    /// Waits for a response from the server.
    pub fn wait(res: *Response, connection: *Connection, allocator: std.mem.Allocator, send_options: Request.SendOptions) WaitError!void {
        try res.parser.waitForHeaders(allocator, connection);
        const headers_bytes = res.parser.header_bytes.items;

        var line_iterator = std.mem.tokenizeAny(u8, headers_bytes, "\r\n");

        const first_line = line_iterator.next() orelse unreachable;
        if (first_line.len < 13) return error.HeadersInvalid; // The first line must be at least 13 bytes long "HTTP/1.1 000 "

        switch (int64(first_line[0..8])) {
            int64("HTTP/1.1") => {},
            else => return error.HeadersInvalid, // This is not a supported HTTP version
        }

        if (first_line[8] != ' ') return error.HeadersInvalid; // The status code must be separated from the version by a space.
        const status_code = std.fmt.parseUnsigned(u64, first_line[9..12], 10) catch return error.HeadersInvalid; // The status code must be 3 digits.

        if (first_line[12] != ' ') return error.HeadersInvalid; // The reason phrase must be separated from the status code by a space.
        const reason = first_line[13..];

        res.status = @enumFromInt(status_code);
        res.reason = reason;

        res.headers.clearRetainingCapacity();

        while (line_iterator.next()) |line| {
            var name_it = std.mem.tokenizeAny(u8, line, ": ");
            const header_name = name_it.next() orelse return error.HeadersInvalid; // There is no `:` in the line.
            const header_value = name_it.rest();

            try res.headers.append(header_name, header_value);
        }

        if (send_options.method == .CONNECT and res.status.class() == .success) {
            // the connection is placed into tunnel mode, the protocol involved is no longer http
            return;
        }

        const transfer_encoding = res.headers.getFirstValue("transfer-encoding");
        const content_length = res.headers.getFirstValue("content-length");

        var compression: std.meta.Tag(Decompression) = .identity;
        if (transfer_encoding) |codings| {
            var coding_it = std.mem.splitBackwardsScalar(u8, codings, ',');

            const first = std.mem.trim(u8, coding_it.first(), " ");
            if (std.ascii.eqlIgnoreCase(first, "chunked")) {
                res.content_length = .chunked;

                if (coding_it.next()) |second_untrimmed| {
                    const second = std.mem.trim(u8, second_untrimmed, " ");

                    if (std.meta.stringToEnum(@TypeOf(compression), second)) |decomp| {
                        compression = decomp;
                    } else {
                        return error.UnsupportedTransferEncoding; // We don't support any other transfer encodings.
                    }
                }
            } else if (std.meta.stringToEnum(@TypeOf(compression), first)) |decomp| {
                compression = decomp;
            } else {
                return error.UnsupportedTransferEncoding; // We don't support any other transfer encodings.
            }
        } else if (content_length) |length_str| {
            const length = std.fmt.parseUnsigned(u64, length_str, 10) catch return error.HeadersInvalid; // The content length must be a valid unsigned integer.

            res.content_length = ContentLength.fromInt(length);
        } else {
            res.content_length = .none;
        }

        if (res.headers.getFirstValue("content-encoding")) |coding| {
            if (compression != .identity) return error.HeadersInvalid; // We can only handle one compression at a time at the moment.
            const trimmed = std.mem.trim(u8, coding, " ");

            if (std.meta.stringToEnum(std.meta.Tag(Decompression), trimmed)) |decomp| {
                compression = decomp;
            } else {
                return error.UnsupportedTransferEncoding; // We don't support any other content encodings.
            }
        }

        if (res.headers.getFirstValue("connection")) |keepalive| {
            if (std.ascii.eqlIgnoreCase(keepalive, "close")) {
                connection.keep_alive = false;
            }
        }

        switch (res.content_length) {
            .none => {},
            .chunked => res.parser.state = .chunk_head_size,
            else => res.parser.next_chunk_length = @intFromEnum(res.content_length),
        }

        if (send_options.method == .HEAD or res.status.class() == .informational or res.status == .no_content or res.status == .not_modified) {
            // these responses have no content, regardless of headers
            res.content_length = .none;
            compression = .identity;
        }

        res.state = .initializing;

        try setDecompression(res, connection, allocator, compression);

        res.state = .payload;
    }

    const SetDecompressionError = error{DecompressionInitializationFailed} || std.mem.Allocator.Error;

    /// Sets the decompression to be used on the response payload.
    fn setDecompression(res: *Response, connection: *Connection, allocator: std.mem.Allocator, decompression: std.meta.Tag(Decompression)) SetDecompressionError!void {
        assert(res.state == .initializing);

        if (decompression != res.decompression) switch (res.decompression) {
            .identity => {},
            .deflate => res.decompression.deflate.deinit(),
            .gzip => res.decompression.gzip.deinit(),
            .zstd => res.decompression.zstd.deinit(),
        };

        res.decompression = switch (decompression) {
            .identity => .identity,
            .deflate => .{ .deflate = std.compress.deflate.decompressor(allocator, res.plainReader(connection), null) catch return error.DecompressionInitializationFailed },
            .gzip => .{ .gzip = std.compress.gzip.decompress(allocator, res.plainReader(connection)) catch return error.DecompressionInitializationFailed },
            .zstd => .{ .zstd = std.compress.zstd.decompressStream(allocator, res.plainReader(connection)) },
        };
    }

    const PlainReadError = Parser.ReadError;

    /// Read data from the response body without decompression.
    fn plainRead(res: *Response, connection: *Connection, buffer: []u8) PlainReadError!usize {
        assert(res.state == .payload or res.state == .initializing);

        return res.parser.read(connection, buffer);
    }

    const PlainReader = std.io.Reader(PlainReaderWrapped, PlainReadError, PlainReaderWrapped.read);
    const PlainReaderWrapped = struct {
        res: *Response,
        connection: *Connection,

        fn read(wrapper: PlainReaderWrapped, buffer: []u8) PlainReadError!usize {
            return Response.plainRead(wrapper.res, wrapper.connection, buffer);
        }
    };

    fn plainReader(res: *Response, connection: *Connection) PlainReader {
        return .{ .context = .{ .res = res, .connection = connection } };
    }

    pub const ReadError = PlainReadError || Decompression.Gzip.Error || Decompression.Deflate.Error || Decompression.Zstd.Error;

    /// Read data from the response body.
    pub fn read(res: *Response, connection: *Connection, buffer: []u8) ReadError!usize {
        assert(res.state == .payload);

        switch (res.decompression) {
            .identity => return try res.plainRead(connection, buffer),
            .deflate => return try res.decompression.deflate.read(buffer),
            .gzip => return try res.decompression.gzip.read(buffer),
            .zstd => return try res.decompression.zstd.read(buffer),
        }
    }

    pub const Reader = std.io.Reader(ReaderWrapped, ReadError, ReaderWrapped.read);
    const ReaderWrapped = struct {
        res: *Response,
        connection: *Connection,

        fn read(wrapper: ReaderWrapped, buffer: []u8) ReadError!usize {
            return Response.read(wrapper.res, wrapper.connection, buffer);
        }
    };

    pub fn reader(res: *Response, connection: *Connection) Reader {
        return .{ .context = .{ .res = res, .connection = connection } };
    }

    /// Closes this response. All associated resources are released.
    pub fn close(res: *Response) void {
        res.state = .closed;
    }
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
