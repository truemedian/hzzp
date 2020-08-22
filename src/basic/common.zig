const std = @import("std");

pub const RequestOptions = struct {
    allocator: *std.mem.Allocator,

    read_buffer_size: usize = 4 * 1024, // 4 KiB

    method: []const u8,
    path: []const u8,
    host: []const u8,

    follow_redirects: bool = false,
};

pub const RequestStatus = struct {
    pub const RequestError = error{
        ClientError,
        ServerError,
        Unknown,
    };

    code: u16,
    kind: RequestStatusKind,

    pub fn init(code: u16) RequestStatus {
        return .{
            .code = code,
            .kind = RequestStatusKind.fromStatusCode(code),
        };
    }

    pub fn isSuccess(self: RequestStatus) bool {
        return self.kind == .informational or self.kind == .success or self.kind == .redirect;
    }

    pub fn isFailure(self: RequestStatus) bool {
        return self.kind == .client_error or self.kind == .server_error or self.kind == .unknown;
    }

    pub fn throwable(self: RequestStatus) RequestError!void {
        switch (self.kind) {
            .client_error => return error.ClientError,
            .server_error => return error.ServerError,
            .unknown => return error.Unknown,
            else => {},
        }
    }
};

pub const RequestStatusKind = enum {
    informational,
    success,
    redirect,
    client_error,
    server_error,
    unknown,

    pub fn fromStatusCode(code: u16) RequestStatusKind {
        switch (code) {
            100...199 => return .informational,
            200...299 => return .success,
            300...399 => return .redirect,
            400...499 => return .client_error,
            500...599 => return .server_error,
            else => return .unknown,
        }
    }
};
