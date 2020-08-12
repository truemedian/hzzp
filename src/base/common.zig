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

pub const HeaderEvent = Header;

pub const ChunkEvent = struct {
    data: []const u8,
    final: bool = false,
};

pub const InvalidEvent = struct {
    buffer: []const u8,
    message: []const u8,
    state: ParserState,
};

pub const ClientEvent = union(enum) {
    status: ResponseStatus,
    header: HeaderEvent,
    head_complete: void,
    chunk: ChunkEvent,
    end: void,
    invalid: InvalidEvent,
    closed: void,
};

pub const ServerEvent = union(enum) {
    status: RequestStatus,
    header: HeaderEvent,
    head_complete: void,
    chunk: ChunkEvent,
    end: void,
    invalid: InvalidEvent,
    closed: void,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = []const Header;
