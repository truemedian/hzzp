const std = @import("std");
const ascii = std.ascii;

const Uri = std.Uri;

const assert = std.debug.assert;

pub const http1 = @import("protocol/http1.zig");

/// HTTP version
pub const Version = enum {
    http1_0, // HTTP/1.0
    http1, // HTTP/1.1
    http2, // HTTP/2
};

/// HTTP method
pub const Method = enum(u256) {
    GET = parse("GET"),
    HEAD = parse("HEAD"),
    POST = parse("POST"),
    PUT = parse("PUT"),
    DELETE = parse("DELETE"),
    CONNECT = parse("CONNECT"),
    OPTIONS = parse("OPTIONS"),
    TRACE = parse("TRACE"),
    PATCH = parse("PATCH"),

    _,

    /// Converts `s` into a type that may be used as a `Method` field.
    /// Asserts that `s` is 32 or fewer bytes.
    pub fn parse(s: []const u8) u256 {
        var x: u256 = 0;
        const len = @min(s.len, @sizeOf(@TypeOf(x)));
        @memcpy(std.mem.asBytes(&x)[0..len], s[0..len]);
        return x;
    }

    pub fn write(self: Method, w: anytype) !void {
        const bytes = std.mem.asBytes(&@intFromEnum(self));
        const str = std.mem.sliceTo(bytes, 0);
        try w.writeAll(str);
    }

    pub fn format(value: Method, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) @TypeOf(writer).Error!void {
        return try value.write(writer);
    }

    /// Returns true if a request of this method is allowed to have a body
    /// Actual behavior from servers may vary and should still be checked
    pub fn requestHasBody(self: Method) bool {
        return switch (self) {
            .POST, .PUT, .PATCH => true,
            .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
            else => true,
        };
    }

    /// Returns true if a response to this method is allowed to have a body
    /// Actual behavior from clients may vary and should still be checked
    pub fn responseHasBody(self: Method) bool {
        return switch (self) {
            .GET, .POST, .DELETE, .CONNECT, .OPTIONS, .PATCH => true,
            .HEAD, .PUT, .TRACE => false,
            else => true,
        };
    }

};

pub const HeaderList = std.ArrayListUnmanaged(Field);
pub const HeaderIndexItem = union(enum) {
    pub const List = std.ArrayListUnmanaged(usize);

    single: usize,
    list: List,
};
pub const HeaderIndex = std.HashMapUnmanaged([]const u8, HeaderIndexItem, CaseInsensitiveStringContext, std.hash_map.default_max_load_percentage);

pub const CaseInsensitiveStringContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        var buf: [64]u8 = undefined;
        var i: usize = 0;

        var h = std.hash.Wyhash.init(0);
        while (i + 64 < s.len) : (i += 64) {
            const ret = ascii.lowerString(buf[0..], s[i..][0..64]);
            h.update(ret);
        }

        const left = @min(64, s.len - i);
        const ret = ascii.lowerString(buf[0..], s[i..][0..left]);
        h.update(ret);

        return h.final();
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        if (a.ptr == b.ptr and a.len == b.len) return true;

        return ascii.eqlIgnoreCase(a, b);
    }
};

/// A HTTP header field. This consists of a case-insensitive name and a value.
pub const Field = struct {
    name: []const u8,
    value: []const u8,

    fn lessThan(_: void, a: Field, b: Field) bool {
        if (a.name.ptr == b.name.ptr) return false;

        return ascii.lessThanIgnoreCase(a.name, b.name);
    }
};

/// An indexed list of HTTP headers.
pub const Headers = struct {
    allocator: std.mem.Allocator,
    list: HeaderList = .{},
    index: HeaderIndex = .{},

    /// When this is false, names and values will not be duplicated.
    owned: bool = true,

    /// Creates a new, empty Headers instance.
    pub fn init(allocator: std.mem.Allocator) Headers {
        return .{ .allocator = allocator };
    }

    /// Creates a new Headers instance filled with all headers in `fields`.
    pub fn initList(allocator: std.mem.Allocator, fields: []const Field) !Headers {
        var new = Headers.init(allocator);

        try new.list.ensureTotalCapacity(allocator, fields.len);
        try new.index.ensureTotalCapacity(allocator, fields.len);
        for (fields) |field| {
            try new.append(field.name, field.value);
        }

        return new;
    }

    /// Frees this Headers instance. The instance must not be used after this.
    /// Will free field names and values if this instance is `owned`.
    pub fn deinit(h: *Headers) void {
        h.freeIndexListsAndFields();
        h.index.deinit(h.allocator);
        h.list.deinit(h.allocator);
    }

    /// Clears this Headers instance and frees all memory.
    /// Will free field names and values if this instance is `owned`.
    pub fn clearAndFree(h: *Headers) void {
        h.freeIndexListsAndFields();
        h.index.clearAndFree(h.allocator);
        h.list.clearAndFree(h.allocator);
    }

    /// Clears this Headers instance, but does not free the index.
    /// Will free field names and values if this instance is `owned`.
    pub fn clearRetainingCapacity(h: *Headers) void {
        h.freeIndexListsAndFields();
        h.index.clearRetainingCapacity();
        h.list.clearRetainingCapacity();
    }

    /// Frees all index lists. Will free field names and values if this instance is `owned`.
    fn freeIndexListsAndFields(h: *Headers) void {
        var it = h.index.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr == .list) {
                entry.value_ptr.list.deinit(h.allocator);
            }

            if (h.owned)
                h.allocator.free(entry.key_ptr.*);
        }

        if (h.owned) {
            for (h.list.items) |entry| {
                h.allocator.free(entry.value);
            }
        }
    }

    fn rebuildIndex(h: *Headers) void {
        var it = h.index.iterator();

        // clear out index lists
        while (it.next()) |entry| {
            if (entry.value_ptr == .list) {
                entry.value_ptr.list.shrinkRetainingCapacity(0);
            }
        }

        // refill index, reuse existing lists
        for (h.list.items, 0..) |entry, i| {
            const index = h.index.getEntry(entry.name).?;

            if (index.value_ptr == .single) {
                index.value_ptr.* = .{ .single = i };
            } else {
                try index.value_ptr.list.appendAssumeCapacity(h.allocator, i);
            }
        }
    }

    /// Clone this Headers instance. Will duplicate all field names and values.
    pub fn clone(h: Headers, allocator: std.mem.Allocator) !Headers {
        return try Headers.initList(allocator, h.list.items);
    }

    /// Appends a header to the list. Both name and value are copied if this instance is `owned`.
    pub fn append(h: *Headers, name: []const u8, value: []const u8) !void {
        const n = h.list.items.len;

        const value_duped = if (h.owned) try h.allocator.dupe(u8, value) else value;
        errdefer if (h.owned) h.allocator.free(value_duped);

        var entry = Field{ .name = undefined, .value = value_duped };

        if (h.index.getEntry(name)) |kv| {
            entry.name = kv.key_ptr.*;

            if (kv.value_ptr == .single) {
                const list = try HeaderIndexItem.List.initCapacity(h.allocator, 2);
                errdefer list.deinit(h.allocator);

                list.appendAssumeCapacity(h.allocator, kv.value_ptr.single);
                list.appendAssumeCapacity(h.allocator, n);

                kv.value_ptr.* = .{ .list = list };
            } else {
                try kv.value_ptr.append(h.allocator, n);
            }
        } else {
            const name_duped = if (h.owned) try std.ascii.allocLowerString(h.allocator, name) else name;
            errdefer if (h.owned) h.allocator.free(name_duped);

            entry.name = name_duped;

            try h.index.put(h.allocator, name_duped, .{ .single = n });
        }

        try h.list.append(h.allocator, entry);
    }

    /// Removes all headers with the given name.
    pub fn delete(h: *Headers, name: []const u8) bool {
        if (h.index.fetchRemove(name)) |kv| {
            if (kv.value == .single) {
                const removed = h.list.swapRemove(kv.value.single);

                // assert that the index is still valid
                assert(removed.name == kv.key);
            } else {
                const list = kv.value.list;
                var i = list.items.len;
                while (i > 0) {
                    i -= 1;

                    const removed = h.list.swapRemove(list.items[i]);

                    // assert that the index is still valid
                    assert(removed.name == kv.key);
                }

                list.deinit(h.allocator);
            }

            if (h.owned)
                h.allocator.free(kv.key);

            h.rebuildIndex();

            return true;
        } else {
            return false;
        }
    }

    /// Sorts the list of headers lexicographically by name.
    pub fn sort(h: *Headers) void {
        std.mem.sortUnstable(Field, h.list.items, {}, Field.lessThan);
        h.rebuildIndex();
    }

    /// Returns whether this Headers instance contains a header with the given name.
    pub fn contains(h: Headers, name: []const u8) bool {
        return h.index.contains(name);
    }

    /// Returns the index of the first header entry with the given name.
    pub fn firstIndexOf(h: Headers, name: []const u8) ?usize {
        const index = h.index.get(name) orelse return null;

        switch (index) {
            .single => |n| return n,
            .list => |list| return list.items[0],
        }
    }

    /// Returns the first header entry with the given name.
    pub fn getFirstEntry(h: Headers, name: []const u8) ?Field {
        const first_index = h.firstIndexOf(name) orelse return null;
        return h.list.items[first_index];
    }

    /// Returns the first header value with the given name.
    pub fn getFirstValue(h: Headers, name: []const u8) ?[]const u8 {
        const first_entry = h.getFirstEntry(name) orelse return null;
        return first_entry.value;
    }

    /// Allocates a list of all header entries with the given name.
    /// The caller owns the returned slice, but not the values within.
    pub fn getEntries(h: Headers, allocator: std.mem.Allocator, name: []const u8) !?[]const Field {
        const index = h.index.get(name) orelse return null;
        const n = if (index == .single) 1 else index.list.items.len;

        const buf = try allocator.alloc(Field, n);
        switch (index) {
            .single => |i| buf[0] = h.list.items[i],
            .list => |list| for (list.items, 0..) |i, buf_idx| {
                buf[buf_idx] = h.list.items[i];
            },
        }

        return buf;
    }

    /// Allocates a list of all header values with the given name.
    /// The caller owns the returned slice, but not the values within.
    pub fn getValues(h: Headers, allocator: std.mem.Allocator, name: []const u8) !?[]const []const u8 {
        const index = h.index.get(name) orelse return null;
        const n = if (index == .single) 1 else index.list.items.len;

        const buf = try allocator.alloc([]const u8, n);
        switch (index) {
            .single => |i| buf[0] = h.list.items[i].value,
            .list => |list| for (list.items, 0..) |i, buf_idx| {
                buf[buf_idx] = h.list.items[i].value;
            },
        }

        return buf;
    }

    pub fn format(
        h: Headers,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        w: anytype,
    ) @TypeOf(w).Error!void {
        _ = fmt;

        for (h.list.items) |entry| {
            try w.writeAll(entry.name);
            try w.writeAll(": ");
            try w.writeAll(entry.value);
            try w.writeAll("\r\n");
        }
    }

    pub fn formatCommaSeparated(
        h: Headers,
        name: []const u8,
        w: anytype,
    ) @TypeOf(w).Error!void {
        const index = h.index.get(name) orelse return;

        try w.writeAll(name);
        try w.writeAll(": ");

        switch (index) {
            .single => |i| try w.writeAll(h.list.items[i].value),
            .list => |list| for (list.items, 0..) |i, n| {
                if (n != 0) try w.writeAll(", ");
                try w.writeAll(h.list.items[i].value);
            },
        }

        try w.writeAll("\r\n");
    }
};

test {
    std.testing.refAllDecls(@This());
}
