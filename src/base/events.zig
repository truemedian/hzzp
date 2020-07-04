pub const TransferEncoding = enum {
    length,
    chunked,
    unknown,
};

pub const ParserState = enum {
    initial,
    headers,
    payload,
};

pub const ResponseStatus = struct {
    code: u16,
    reason: []const u8,
};

pub const RequestStatus = struct {
    method: []const u8,
    path: []const u8,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Chunk = struct {
    data: []const u8,
    final: bool = false,
};

pub const Invalid = struct {
    buffer: []const u8,
    message: []const u8,
    state: ParserState,
};

pub const ClientEvent = union(enum) {
    status: ResponseStatus,
    header: Header,
    head_complete: void,
    chunk: Chunk,
    end: void,
    invalid: Invalid,
    closed: void,
};

pub const ServerEvent = union(enum) {
    status: RequestStatus,
    header: Header,
    head_complete: void,
    chunk: Chunk,
    end: void,
    invalid: Invalid,
    closed: void,
};
