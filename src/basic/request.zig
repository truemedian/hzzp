const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const io = std.io;

const assert = std.debug.assert;

const base = @import("../main.zig").base;

usingnamespace @import("common.zig");

const AllocError = mem.Allocator.Error;

pub fn create(options: RequestOptions, reader: anytype, writer: anytype) AllocError!Request(@TypeOf(reader), @TypeOf(writer)) {
    return Request(@TypeOf(reader), @TypeOf(writer)).init(options, reader, writer);
}

const RequestLogger = std.log.scoped(.request);
pub fn Request(comptime Reader: type, comptime Writer: type) type {
    const ReaderError = if (@typeInfo(Reader) == .Pointer) @typeInfo(Reader).Pointer.child.Error else Reader.Error;
    const WriterError = if (@typeInfo(Writer) == .Pointer) @typeInfo(Writer).Pointer.child.Error else Writer.Error;

    return struct {
        const Self = @This();

        pub const SendError = WriterError || error{ RequestAlreadySent, InvalidRequest };
        pub const ReadRequestError = InternalClient.ReadError || AllocError || error{ ConnectionClosed, InvalidResponse };
        pub const ReadNextChunkError = InternalClient.ReadError || AllocError || error{ ConnectionClosed, UnconsumedRequestHead, InvalidResponse };
        pub const ReadChunkError = ReadNextChunkError;

        pub const Chunk = base.ChunkEvent;
        pub const InternalClient = base.Client.Client(Reader, Writer);
        pub const ChunkReader = io.Reader(*Self, ReadChunkError, readChunkBuffer);

        options: RequestOptions,
        read_buffer: []u8,

        arena: std.heap.ArenaAllocator,

        internal: InternalClient,

        sent: bool = false,
        status: RequestStatus,
        headers: std.http.Headers,
        payload: std.ArrayList(u8),
        payload_index: usize = 0,

        pub fn init(options: RequestOptions, input: Reader, output: Writer) AllocError!Self {
            var arena = std.heap.ArenaAllocator.init(options.allocator);
            var buffer = try arena.allocator.alloc(u8, options.read_buffer_size);

            return Self{
                .options = options,
                .arena = arena,

                .read_buffer = buffer,
                .internal = InternalClient.init(buffer, input, output),

                .status = undefined,
                .headers = std.http.Headers.init(&arena.allocator),
                .payload = std.ArrayList(u8).init(&arena.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.internal = undefined;

            self.arena.deinit();
        }

        pub fn prepare(self: *Self) SendError!void {
            if (self.internal.head_sent) return error.RequestAlreadySent;

            try self.internal.writeHead(self.options.method, self.options.path);
            try self.internal.writeHeaderValue("Host", self.options.host);
        }

        pub fn addHeaderValue(self: *Self, name: []const u8, value: []const u8) SendError!void {
            if (self.internal.head_sent) return error.RequestAlreadySent;

            try self.internal.writeHeaderValue(name, value);
        }

        pub fn addHeaderValueFormat(self: *Self, name: []const u8, comptime format: []const u8, args: anytype) SendError!void {
            if (self.internal.head_sent) return error.RequestAlreadySent;

            try self.internal.writeHeaderValueFormat(name, format, args);
        }

        pub fn addHeader(self: *Self, header: base.Header) SendError!void {
            if (self.internal.head_sent) return error.RequestAlreadySent;

            try self.internal.writeHeader(header);
        }

        pub fn addHeaders(self: *Self, headers: base.Headers) SendError!void {
            if (self.internal.head_sent) return error.RequestAlreadySent;

            try self.internal.writeHeaders(headers);
        }

        pub fn addStdHeaders(self: *Self, headers: std.http.Headers) SendError!void {
            if (self.internal.head_sent) return error.RequestAlreadySent;

            try self.internal.writeHeaders(headers.toSlice());
        }

        pub fn finish(self: *Self) SendError!void {
            if (self.sent) return error.RequestAlreadySent;

            try self.internal.writeHeadComplete();
            self.sent = true;
        }

        pub fn send(self: *Self, chunk: []const u8) SendError!void {
            if (self.sent) return error.RequestAlreadySent;

            if (self.internal.send_encoding == .unknown) {
                try self.internal.writeHeaderValueFormat("Content-Length", "{d}", .{chunk.len});
            } else if (self.internal.send_encoding == .chunked) {
                return error.InvalidRequest;
            }

            try self.internal.writeHeadComplete();
            try self.internal.writeChunk(chunk);

            self.sent = true;
        }

        pub fn sendChunked(self: *Self, chunk: ?[]const u8) SendError!void {
            if (self.sent) return error.RequestAlreadySent;

            if (self.internal.send_encoding == .unknown) {
                try self.internal.writeHeaderValue("Transfer-Encoding", "chunked");
            } else if (self.internal.send_encoding == .length) {
                return error.InvalidRequest;
            }

            try self.internal.writeHeadComplete();
            try self.internal.writeChunk(chunk);
        }

        pub fn readRequest(self: *Self) ReadRequestError!void {
            if (self.internal.state == .payload) return;

            while (try self.internal.readEvent()) |event| {
                switch (event) {
                    .status => |data| {
                        self.status = RequestStatus.init(data.code);
                    },
                    .header => |header| {
                        var value = try self.arena.allocator.dupe(u8, header.value);
                        // try self.headers.append(header.name, value, null); // this call segfaults for some reason
                    },
                    .head_complete => break,
                    .end, .closed => return error.ConnectionClosed,
                    .invalid => |data| {
                        RequestLogger.warn("invalid response while reading {}: {}", .{ @tagName(data.state), data.message });
                        return error.InvalidResponse;
                    },
                    .chunk => unreachable,
                }
            }
        }

        fn readNextChunk(self: *Self) ReadNextChunkError!?Chunk {
            if (self.internal.state != .payload) return error.UnconsumedRequestHead;

            if (try self.internal.readEvent()) |event| {
                switch (event) {
                    .status, .header, .head_complete => unreachable,
                    .chunk => |chunk| return chunk,
                    .end => return null,
                    .closed => return error.ConnectionClosed,
                    .invalid => |data| {
                        RequestLogger.warn("invalid response while reading {}: {}", .{ @tagName(data.state), data.message });
                        return error.InvalidResponse;
                    },
                }
            }
        }

        pub fn readChunkBuffer(self: *Self, dest: []u8) ReadChunkError!usize {
            if (self.payload_index >= self.read_buffer.len) {
                if (try self.internal.readEvent()) |event| {
                    switch (event) {
                        .status, .header, .head_complete => unreachable,
                        .chunk => |chunk| {
                            const size = std.math.min(dest.len, chunk.data.len);

                            mem.copy(u8, dest[0..size], chunk.data[0..size]);
                            self.payload_index = size;

                            return size;
                        },
                        .end => return 0,
                        .closed => return error.ConnectionClosed,
                        .invalid => |data| {
                            RequestLogger.warn("invalid response while reading {}: {}", .{ @tagName(data.state), data.message });
                            return error.InvalidResponse;
                        },
                    }
                } else {
                    return error.ConnectionClosed;
                }
            } else {
                const start = self.payload_index;
                const size = std.math.min(dest.len, self.read_buffer.len - start);
                const end = start + size;

                mem.copy(u8, dest[0..size], self.read_buffer[start..end]);
                self.payload_index = end;

                return size;
            }
        }

        pub fn payloadReader(self: *Self) ChunkReader {
            return .{ .context = self };
        }
    };
}

const testing = std.testing;

test "test" {
    var the_void: [1024]u8 = undefined;
    var response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ngood";

    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = std.heap.page_allocator; // &gpa.allocator;

    var reader = io.fixedBufferStream(response).reader();
    var writer = io.fixedBufferStream(&the_void).writer();

    var request = try create(.{
        .allocator = allocator,
        .method = "GET",
        .path = "/",
        .host = "www.example.com",
    }, reader, writer);
    defer request.deinit();

    try request.prepare();
    try request.addHeader(.{ .name = "X-Header", .value = "value" });
    try request.addHeaderValue("X-Header-value", "value");
    try request.addHeaderValueFormat("X-Header-Fmt", "random number: {d}", .{42});
    try request.finish();

    try request.readRequest();

    testing.expect(request.status.code == 200);
    testing.expect(request.status.kind == .success);

    var payload_reader = request.payloadReader();
    var payload = payload_reader.readAllAlloc(allocator, 128);

    std.debug.print("{}\n", .{payload});
}
