const std = @import("std");
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;

const assert = std.debug.assert;

pub usingnamespace @import("events.zig");

fn stripCarriageReturn(buffer: []u8) []u8 {
    if (buffer[buffer.len - 1] == '\r') {
        return buffer[0 .. buffer.len - 1];
    } else {
        return buffer;
    }
}

pub fn create(buffer: []u8, reader: anytype, writer: anytype) BaseServer(@TypeOf(reader), @TypeOf(writer)) {
    assert(buffer.len >= 32);

    return BaseServer(@TypeOf(reader), @TypeOf(writer)).init(buffer, reader, writer);
}

pub fn BaseServer(comptime Reader: type, comptime Writer: type) type {
    const ReaderError = if (@typeInfo(Reader) == .Pointer) @typeInfo(Reader).Pointer.child.Error else Reader.Error;
    const WriterError = if (@typeInfo(Writer) == .Pointer) @typeInfo(Writer).Pointer.child.Error else Writer.Error;

    return struct {
        const Self = @This();

        read_buffer: []u8,

        send_encoding: TransferEncoding = .unknown,
        recv_encoding: TransferEncoding = .unknown,

        enc_need: usize = 0,
        enc_read: usize = 0,

        reader: Reader,
        writer: Writer,

        done: bool = false,
        head_sent: bool = false,

        state: ParserState = .initial,

        pub fn init(buffer: []u8, reader: Reader, writer: Writer) Self {
            return Self{
                .read_buffer = buffer,
                .reader = reader,
                .writer = writer,
            };
        }

        pub fn reset(self: *Self) void {
            self.send_encoding = .unknown;
            self.recv_encoding = .unknown;

            self.enc_need = 0;
            self.enc_read = 0;

            self.done = false;
            self.head_sent = false;

            self.state = .initial;
        }

        pub fn writeHead(self: *Self, code: u16, reason: []const u8) WriterError!void {
            try self.writer.writeAll("HTTP/1.1 ");
            try fmt.formatInt(code, 10, true, .{}, self.writer);
            try self.writer.writeAll(" ");
            try self.writer.writeAll(reason);
            try self.writer.writeAll("\r\n");
        }

        pub fn writeHeader(self: *Self, key: []const u8, value: []const u8) WriterError!void {
            if (ascii.eqlIgnoreCase(key, "transfer-encoding")) {
                self.send_encoding = .chunked;
            } else if (ascii.eqlIgnoreCase(key, "content-length")) {
                self.send_encoding = .length;
            }

            try self.writer.writeAll(key);
            try self.writer.writeAll(": ");
            try self.writer.writeAll(value);
            try self.writer.writeAll("\r\n");
        }

        pub fn writeHeadComplete(self: *Self) WriterError!void {
            if (!self.head_sent) {
                try self.writer.writeAll("\r\n");
                self.head_sent = true;
            }
        }

        pub fn writeChunk(self: *Self, data: ?[]const u8) WriterError!void {
            try self.writeHeadComplete();

            switch (self.send_encoding) {
                .chunked => {
                    if (data) |payload| {
                        try fmt.formatInt(payload.len, 16, true, .{}, self.writer);
                        try self.writer.writeAll("\r\n");
                        try self.writer.writeAll(payload);
                        try self.writer.writeAll("\r\n");
                    } else {
                        try self.writer.writeAll("0\r\n");
                    }
                },
                .length, .unknown => {
                    if (data) |payload| {
                        try self.writer.writeAll(payload);
                    }
                },
            }
        }

        var read_byte: [1]u8 = undefined;
        const ReadUntilError = ReaderError || error{BufferOverflow};
        fn readUntilDelimiterOrEof(self: *Self, buf: []u8, delimiter: u8) ReadUntilError!?[]u8 {
            var index: usize = 0;
            while (true) {
                const read_len = try self.reader.read(&read_byte);
                if (read_len < 1) {
                    if (index == 0) return null;
                    return buf[0..index];
                }

                if (read_byte[0] == delimiter) return buf[0..index];
                if (index >= buf.len) return error.BufferOverflow;

                buf[index] = read_byte[0];
                index += 1;
            }
        }

        fn skipUntilDelimiterOrEof(self: *Self, delimiter: u8) ReaderError!void {
            while (true) {
                const read_len = try self.reader.read(&read_byte);
                if (read_len < 1) return;

                if (read_byte[0] == delimiter) return;
            }
        }

        pub const ReadError = ReadUntilError || fmt.ParseIntError;
        pub fn readEvent(self: *Self) ReadError!?ServerEvent {
            if (self.done) return null;

            switch (self.state) {
                .initial => {
                    if (try self.readUntilDelimiterOrEof(self.read_buffer, ' ')) |method| {
                        for (method) |c| {
                            if (!ascii.isAlpha(c) or !ascii.isUpper(c)) {
                                self.done = true;
                                return ServerEvent{
                                    .invalid = .{
                                        .buffer = method,
                                        .message = "invalid HTTP method",
                                        .state = self.state,
                                    },
                                };
                            }
                        }

                        if (try self.readUntilDelimiterOrEof(self.read_buffer[method.len..], ' ')) |path| {
                            if (try self.readUntilDelimiterOrEof(self.read_buffer[method.len + path.len ..], '\n')) |buffer| {
                                const stripped = stripCarriageReturn(buffer);
                                if (!mem.eql(u8, stripped, "HTTP/1.1") and !mem.eql(u8, stripped, "HTTP/1.0")) {
                                    self.done = true;
                                    return ServerEvent{
                                        .invalid = .{
                                            .buffer = buffer,
                                            .message = "expected HTTP/1.1 or HTTP/1.0",
                                            .state = self.state,
                                        },
                                    };
                                }

                                self.state = .headers;

                                return ServerEvent{
                                    .status = .{
                                        .method = method,
                                        .path = path,
                                    },
                                };
                            } else {
                                return ServerEvent.closed;
                            }
                        } else {
                            return ServerEvent.closed;
                        }
                    } else {
                        return ServerEvent.closed;
                    }
                },
                .headers => {
                    if (try self.readUntilDelimiterOrEof(self.read_buffer, '\n')) |buffer| {
                        if (buffer.len == 1 and buffer[0] == '\r') {
                            self.state = .payload;

                            return ServerEvent.head_complete;
                        }

                        const separator = blk: {
                            if (mem.indexOfScalar(u8, buffer, ':')) |pos| {
                                break :blk pos;
                            } else {
                                self.done = true;
                                return ServerEvent{
                                    .invalid = .{
                                        .buffer = buffer,
                                        .message = "expected header to be separated with a ':' (colon)",
                                        .state = self.state,
                                    },
                                };
                            }
                        };

                        var index = separator + 1;

                        while (true) : (index += 1) {
                            if (buffer[index] != ' ') break;
                            if (index >= buffer[index]) {
                                self.done = true;
                                return ServerEvent{
                                    .invalid = .{
                                        .buffer = buffer,
                                        .message = "no header value provided",
                                        .state = self.state,
                                    },
                                };
                            }
                        }

                        const name = buffer[0..separator];
                        const value = stripCarriageReturn(buffer[index..]);

                        if (ascii.eqlIgnoreCase(name, "content-length")) {
                            self.recv_encoding = .length;
                            self.enc_need = try fmt.parseUnsigned(usize, value, 10);
                        } else if (ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                            if (ascii.eqlIgnoreCase(value, "chunked")) {
                                self.recv_encoding = .chunked;
                            }
                        }

                        return ServerEvent{
                            .header = .{
                                .name = name,
                                .value = value,
                            },
                        };
                    } else {
                        return ServerEvent.closed;
                    }
                },
                .payload => {
                    switch (self.recv_encoding) {
                        .unknown => {
                            self.done = true;
                            return ServerEvent.end;
                        },
                        .length => {
                            const left = self.enc_need - self.enc_read;

                            if (left <= self.read_buffer.len) {
                                const read_len = try self.reader.readAll(self.read_buffer[0..left]);
                                if (read_len != left) return ServerEvent.closed;

                                self.recv_encoding = .unknown;
                                
                                return ServerEvent{
                                    .chunk = .{
                                        .data = self.read_buffer[0..read_len],
                                        .final = true,
                                    },
                                };
                            } else {
                                const read_len = try self.reader.read(self.read_buffer);
                                if (read_len == 0) return ServerEvent.closed;

                                self.enc_read += read_len;

                                return ServerEvent{
                                    .chunk = .{
                                        .data = self.read_buffer[0..read_len],
                                    },
                                };
                            }
                        },
                        .chunked => {
                            if (self.enc_need == 0) {
                                if (try self.readUntilDelimiterOrEof(self.read_buffer, '\n')) |buffer| {
                                    const chunk_len = try fmt.parseInt(usize, stripCarriageReturn(buffer), 16);

                                    if (chunk_len == 0) {
                                        try self.skipUntilDelimiterOrEof('\n');

                                        self.done = true;
                                        return ServerEvent.end;
                                    } else if (chunk_len <= self.read_buffer.len) {
                                        const read_len = try self.reader.readAll(self.read_buffer[0..chunk_len]);
                                        if (read_len != chunk_len) return ServerEvent.closed;

                                        try self.skipUntilDelimiterOrEof('\n');

                                        return ServerEvent{
                                            .chunk = .{
                                                .data = self.read_buffer[0..read_len],
                                                .final = true,
                                            },
                                        };
                                    } else {
                                        self.enc_need = chunk_len;
                                        self.enc_read = 0;

                                        const read_len = try self.reader.read(self.read_buffer);
                                        if (read_len != 0) return ServerEvent.closed;

                                        self.enc_read += read_len;

                                        return ServerEvent{
                                            .chunk = .{
                                                .data = self.read_buffer[0..read_len],
                                            },
                                        };
                                    }
                                } else {
                                    return ServerEvent.closed;
                                }
                            } else {
                                const left = self.enc_need - self.enc_read;

                                if (left <= self.read_buffer.len) {
                                    const read_len = try self.reader.readAll(self.read_buffer[0..left]);
                                    if (read_len != left) return ServerEvent.closed;

                                    try self.skipUntilDelimiterOrEof('\n');

                                    self.enc_need = 0;
                                    self.enc_read = 0;

                                    return ServerEvent{
                                        .chunk = .{
                                            .data = self.read_buffer[0..read_len],
                                            .final = true,
                                        },
                                    };
                                } else {
                                    const read_len = try self.reader.read(self.read_buffer);
                                    if (read_len == 0) return ServerEvent.closed;

                                    self.enc_read += read_len;

                                    return ServerEvent{
                                        .chunk = .{
                                            .data = self.read_buffer[0..read_len],
                                        },
                                    };
                                }
                            }
                        },
                    }
                },
            }
        }
    };
}

const testing = std.testing;
const io = std.io;

test "decodes a simple response" {
    var read_buffer: [32]u8 = undefined;
    var the_void: [1024]u8 = undefined;
    var response = "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\ngood";

    var reader = io.fixedBufferStream(response).reader();
    var writer = io.fixedBufferStream(&the_void).writer();

    var client = create(&read_buffer, reader, writer);

    try client.writeHead(200, "OK");
    try client.writeHeader("Content-Length", "9");
    try client.writeChunk("aaabbbccc");

    var status = (try client.readEvent()).?;
    testing.expect(status == .status and mem.eql(u8, status.status.method, "GET"));
    testing.expect(status == .status and mem.eql(u8, status.status.path, "/"));

    var header1 = (try client.readEvent()).?;
    testing.expect(header1 == .header and mem.eql(u8, header1.header.name, "Host") and mem.eql(u8, header1.header.value, "localhost"));

    var header2 = (try client.readEvent()).?;
    testing.expect(header2 == .header and mem.eql(u8, header2.header.name, "Content-Length") and mem.eql(u8, header2.header.value, "4"));

    var complete = (try client.readEvent()).?;
    testing.expect(complete == .head_complete);

    var body = (try client.readEvent()).?;
    testing.expect(body == .chunk and mem.eql(u8, body.chunk.data, "good") and body.chunk.final);

    var end = (try client.readEvent()).?;
    testing.expect(end == .end);
}

test "decodes a chunked response" {
    var read_buffer: [32]u8 = undefined;
    var the_void: [1024]u8 = undefined;
    var response = "GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ngood\r\n0\r\n";

    var reader = io.fixedBufferStream(response).reader();
    var writer = io.fixedBufferStream(&the_void).writer();

    var client = create(&read_buffer, reader, writer);

    try client.writeHead(200, "OK");
    try client.writeHeader("Content-Length", "9");
    try client.writeChunk("aaabbbccc");

    var status = (try client.readEvent()).?;
    testing.expect(status == .status and mem.eql(u8, status.status.method, "GET"));
    testing.expect(status == .status and mem.eql(u8, status.status.path, "/"));

    var header1 = (try client.readEvent()).?;
    testing.expect(header1 == .header and mem.eql(u8, header1.header.name, "Host") and mem.eql(u8, header1.header.value, "localhost"));

    var header2 = (try client.readEvent()).?;
    testing.expect(header2 == .header and mem.eql(u8, header2.header.name, "Transfer-Encoding") and mem.eql(u8, header2.header.value, "chunked"));

    var complete = (try client.readEvent()).?;
    testing.expect(complete == .head_complete);

    var body = (try client.readEvent()).?;
    testing.expect(body == .chunk and mem.eql(u8, body.chunk.data, "good") and body.chunk.final);

    var end = (try client.readEvent()).?;
    testing.expect(end == .end);
}

test "refAllDecls" {
    std.meta.refAllDecls(@This());
}
