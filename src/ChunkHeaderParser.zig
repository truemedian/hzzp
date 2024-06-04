const ChunkHeaderParser = @This();

pub const State = enum(u16) {
    suffix = 1 << 8,
    suffix_r = 1 << 9,
    head_size = 1 << 10,
    head_ext = 1 << 11,
    head_r = 1 << 12,
    finished = 1 << 13,
    invalid = 1 << 14,
};

pub const init_first: ChunkHeaderParser = .{
    .state = .head_size,
    .chunk_len = 0,
};

pub const init_chunk: ChunkHeaderParser = .{
    .state = .suffix,
    .chunk_len = 0,
};

state: State,

chunk_len: u64,

pub fn feed(p: *ChunkHeaderParser, bytes: []const u8) usize {
    assert(p.state != .finished and p.state != .invalid);

    const end: [*]const u8 = bytes.ptr + bytes.len;

    var ptr = bytes.ptr;
    var state = p.state;

    // handle the suffix, it must appear first and will never reappear.
    if (state == .suffix and bytes.len >= 2) {
        const value_ptr: *align(1) const u16 = @ptrCast(ptr);
        const crlf: u16 = @bitCast([2]u8{ '\r', '\n' });
        const value = value_ptr.*;

        ptr += 2;
        if (value == crlf) {
            state = .head_size;
        } else {
            state = .invalid;
            return 0;
        }
    } else if (state == .suffix_r) {
        if (ptr[0] == '\n') {
            state = .head_size;
            ptr += 1;
        } else {
            state = .invalid;
            return 0;
        }
    }

    while (ptr != end) {
        if (state == .head_size) {
            while (ptr != end) {
                const char = ptr[0];

                // first check that the character is a valid hex nibble, then use a bit of math to convert it to a number.
                const digit = switch (char) {
                    '0'...'9', 'a'...'f', 'A'...'F' => ((char & 0xf) +% (char >> 6) *% 9),
                    else => break,
                };

                // Ensure that we can store another nibble without overflowing.
                if (p.chunk_len > comptime (math.maxInt(usize) >> 4))
                    break;

                p.chunk_len <<= 4;
                p.chunk_len +%= digit;

                ptr += 1;
            }
        } else if (state == .head_ext) outer: { // chug through as much data as possible to find the end of the extension.
            while (@intFromPtr(ptr) +% 8 <= @intFromPtr(end)) {
                const value_ptr: *align(1) const u64 = @ptrCast(ptr);

                const mask = hasvalue(value_ptr.*, '\r');
                if (mask == 0) {
                    ptr += 8;
                    continue;
                }

                ptr += @ctz(mask) / 8;
                break :outer;
            }

            while (ptr != end) {
                if (ptr[0] == '\r')
                    break :outer;
                ptr += 1;
            }

            return bytes.len;
        }

        if ((state == .head_size or state == .head_ext) and @intFromPtr(ptr) +% 2 <= @intFromPtr(end)) {
            const value_ptr: *align(1) const u16 = @ptrCast(ptr);
            const cr: u16 = @bitCast([2]u8{ '\r', '\n' });

            ptr += 2;
            if (value_ptr.* == cr) {
                state = .finished;
            } else {
                state = .invalid;
            }

            break;
        }

        switch (mixState(state, ptr[0])) {
            mixState(.head_size, '\r') => state = .head_r,
            mixState(.head_size, ';') => state = .head_ext,
            mixState(.head_size, ' ') => state = .head_ext,
            mixState(.head_size, '\t') => state = .head_ext,
            mixState(.head_ext, '\r') => state = .head_r,
            mixState(.head_r, '\n') => {
                state = .finished;

                ptr += 1;
                break;
            },
            else => {
                state = .invalid;
                break;
            },
        }

        ptr += 1;
    }

    p.state = state;
    return @intFromPtr(ptr) -% @intFromPtr(bytes.ptr);
}

/// Mixes the current state with the next byte to obtain a switchable value.
inline fn mixState(s: State, c: u8) u16 {
    return @as(u16, @intFromEnum(s)) | c;
}

/// https://graphics.stanford.edu/~seander/bithacks.html#ZeroInWord
/// Implemented as `hasless(v, 1)`
inline fn haszero(v: anytype) @TypeOf(v) {
    const mask01 = ~@as(@TypeOf(v), 0) / 255;
    const mask80 = mask01 * 0x80;

    return (v -% mask01) & ~v & mask80;
}

/// https://graphics.stanford.edu/~seander/bithacks.html#ValueInWord
inline fn hasvalue(v: anytype, comptime n: comptime_int) @TypeOf(v) {
    const mask01 = ~@as(@TypeOf(v), 0) / 255;

    return haszero(v ^ (mask01 * n));
}

/// Returns the byte index of the first byte with the most significant bit set.
inline fn valueindex(mask: anytype) math.Log2IntCeil(@TypeOf(mask)) {
    switch (comptime builtin.cpu.arch.endian()) {
        .little => return @ctz(mask) / 8,
        .big => return @clz(mask) / 8,
    }
}

const std = @import("std");
const builtin = @import("builtin");

const math = std.math;
const testing = std.testing;

const assert = std.debug.assert;

test feed {
    const data = "Ff\r\nf0f000 ; ext\r\n0\r\nffffffffffffffffffffffffffffffffffffffff\r\n";

    var p = init_first;
    const first = p.feed(data[0..]);
    try testing.expectEqual(@as(u32, 4), first);
    try testing.expectEqual(@as(u64, 0xff), p.chunk_len);
    try testing.expectEqual(.data, p.state);

    p = init_first;
    const second = p.feed(data[first..]);
    try testing.expectEqual(@as(u32, 14), second);
    try testing.expectEqual(@as(u64, 0xf0f000), p.chunk_len);
    try testing.expectEqual(.data, p.state);

    p = init_first;
    const third = p.feed(data[first + second ..]);
    try testing.expectEqual(@as(u32, 3), third);
    try testing.expectEqual(@as(u64, 0), p.chunk_len);
    try testing.expectEqual(.data, p.state);

    p = init_first;
    const fourth = p.feed(data[first + second + third ..]);
    try testing.expectEqual(@as(u32, 16), fourth);
    try testing.expectEqual(@as(u64, 0xffffffffffffffff), p.chunk_len);
    try testing.expectEqual(.invalid, p.state);
}
