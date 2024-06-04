const HeaderParser = @This();

pub const State = enum(u16) {
    ground = 1 << 8,
    seen_r = 1 << 9,
    seen_rn = 1 << 10,
    seen_rnr = 1 << 11,
    finished = 1 << 12,
};

pub const init: HeaderParser = .{
    .state = .ground,
};

state: State = .ground,

pub fn feed(p: *HeaderParser, bytes: []const u8) usize {
    assert(p.state != .finished);

    const end: [*]const u8 = bytes.ptr + bytes.len;

    // a multi-pointer is used here to avoid the need for extraneous bounds checks.
    var ptr = bytes.ptr;
    var state = p.state;
    while (ptr != end) {
        if (state == .ground) {
            found_cr: {
                // skip 8 bytes at a time until we find a '\r'
                while (@intFromPtr(ptr) +% 8 <= @intFromPtr(end)) {
                    const value_ptr: *align(1) const u64 = @ptrCast(ptr);

                    const mask = hasvalue(value_ptr.*, '\r');
                    if (mask == 0) {
                        ptr += 8;
                        continue;
                    }

                    ptr += valueindex(mask);
                    break :found_cr;
                }

                // we have less than 8 bytes left, so check them one by one.
                while (@intFromPtr(ptr) < @intFromPtr(end)) {
                    if (ptr[0] == '\r')
                        break :found_cr;
                    ptr += 1;
                }

                // we reached the end of the buffer without finding a '\r', the parser is still in the ground state.
                return bytes.len;
            }

            // if we have at least 4 bytes left, we can check for '\r\n\r\n' in one go.
            if (@intFromPtr(ptr) +% 4 <= @intFromPtr(end)) {
                const value_ptr: *align(1) const u32 = @ptrCast(ptr);
                const crlfcrlf: u32 = @bitCast([4]u8{ '\r', '\n', '\r', '\n' });
                const value = value_ptr.*;

                ptr += 4;
                if (value == crlfcrlf) {
                    state = .finished;
                    break;
                }

                // if it wasn't a `\r\n\r\n`, we failed and need to continue parsing the ground state.
                continue;
            }
        }

        // either we are continuing from a saved state, or we are in the ground state with less than 4 bytes left.
        // either way, we parse bytes one at a time with a state machine which optimizes rather well.
        switch (mixState(state, ptr[0])) {
            mixState(.ground, '\r') => state = .seen_r,
            mixState(.seen_r, '\n') => state = .seen_rn,
            mixState(.seen_rn, '\r') => state = .seen_rnr,
            mixState(.seen_rnr, '\n') => {
                state = .finished;

                ptr += 1;
                break;
            },
            else => state = .ground,
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
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nHello";

    for (0..35) |i| {
        var p = init;
        try testing.expectEqual(i, p.feed(data[0..i]));
        try testing.expectEqual(35 - i, p.feed(data[i..]));
        try testing.expectEqual(.finished, p.state);
    }

    for (36..data.len) |i| {
        var p = init;
        try testing.expectEqual(35, p.feed(data[0..i]));
        try testing.expectEqual(.finished, p.state);
    }
}
