const std = @import("std");
const hzzp = @import("hzzp");

const Benchmark = @import("data.zig").Benchmark;

const tests = .{
    "response1.http",
    "response2.http",
    "response3.http",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    inline for (tests) |name| {
        const response_content = try std.fs.cwd().readFileAlloc(allocator, name, 2048);
        defer allocator.free(response_content);

        var benchmark = Benchmark(.{ "status", "headers", "payload", "other" }, 10){};
        var timer = std.time.Timer.start() catch unreachable;

        while (benchmark.run()) {
            var response = std.io.fixedBufferStream(response_content);
            const reader = response.reader();

            var start: u64 = undefined;
            var stop: u64 = undefined;

            var pos_start: usize = undefined;
            var pos_stop: usize = undefined;

            var buffer: [512]u8 = undefined;
            var client = hzzp.base.client.create(&buffer, reader, std.io.null_writer);

            pos_start = response.pos;
            start = timer.read();
            while (try client.next()) |event| {
                stop = timer.read();
                pos_stop = response.pos;

                switch (event) {
                    .status => benchmark.add("status", stop - start, pos_stop - pos_start),
                    .header => benchmark.add("headers", stop - start, pos_stop - pos_start),
                    .payload => benchmark.add("payload", stop - start, pos_stop - pos_start),
                    else => benchmark.add("other", stop - start, pos_stop - pos_start),
                }

                pos_start = response.pos;
                start = timer.read();
            }
        }

        benchmark.reportBasic();
    }
}

// zig run benchmark.zig --pkg-begin hzzp ../src/main.zig --pkg-end
