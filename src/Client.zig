const std = @import("std");

const Connection = @import("Connection.zig");
const protocol = @import("protocol.zig");
const hzzp = @import("main.zig");

const Client = @This();

pub const ConnectionPool = struct {
    pub const Node = struct {
        host: [:0]const u8,
        port: u16,

        connection: Connection,
    };

    pub const Queue = std.DoublyLinkedList(Node);

    mutex: std.Thread.Mutex = .{},

    used_list: Queue = .{},
    free_list: Queue = .{},

    free_len: usize = 0,
    free_max: usize = 32,

    pub const ConnectError = std.mem.Allocator.Error || std.net.TcpConnectToHostError || error{TlsInitializationFailed};

    /// Forms a connection to the given host and port. This function is threadsafe.
    ///
    /// If a connection to the given host and port already exists, it will be returned instead.
    pub fn connect(pool: *ConnectionPool, client: *Client, host: []const u8, port: u16, is_tls: bool) !*Connection {
        if (pool.find(host, port, is_tls)) |c| return c;

        const stream = try std.net.tcpConnectToHost(client.allocator, host, port);
        errdefer stream.close();

        const node = try client.allocator.create(Queue.Node);
        errdefer client.allocator.destroy(node);

        node.data = .{
            .host = try client.allocator.dupeZ(u8, host),
            .port = port,
            .connection = .{ .stream = stream, .is_tls = is_tls },
        };

        if (is_tls) {
            node.data.connection.tls = try hzzp.tls.initClient(stream, &client.tls_context, node.data.host);
        }

        pool.mutex.lock();
        defer pool.mutex.unlock();

        pool.used_list.append(node);
        return &node.data.connection;
    }

    /// Find an existing connection in the pool. This function is threadsafe.
    pub fn find(pool: *ConnectionPool, host: []const u8, port: u16, is_tls: bool) ?*Connection {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        var next = pool.free_list.first;
        while (next) |node| : (next = node.next) {
            if (node.data.connection.is_tls != is_tls) continue;
            if (node.data.port != port) continue;
            if (!std.ascii.eqlIgnoreCase(node.data.host, host)) continue;

            pool.free_list.remove(node);
            pool.free_len -= 1;

            pool.used_list.append(node);

            return &node.data.connection;
        }

        return null;
    }

    /// Release the given connection back to the pool. This function is threadsafe.
    /// If the connection is not to be kept alive, it will be closed now.
    pub fn release(pool: *ConnectionPool, client: *Client, connection: *Connection) void {
        const pool_node = @fieldParentPtr(Node, "connection", connection);
        const node = @fieldParentPtr(Queue.Node, "data", pool_node);

        pool.mutex.lock();
        defer pool.mutex.unlock();

        pool.used_list.remove(node);

        if (!connection.keep_alive or pool.free_max == 0) {
            connection.close();

            client.allocator.free(pool_node.host);
            client.allocator.destroy(node);

            return;
        }

        while (pool.free_len >= pool.free_max) {
            const popped = pool.free_list.popFirst();
            pool.free_len -= 1;

            popped.data.connection.close();

            client.allocator.free(popped.data.host);
            client.allocator.destroy(popped);
        }

        pool.free_list.append(node);
        pool.free_len += 1;
    }

    /// Resize the pool. This function is threadsafe.
    ///
    /// If the new maximum is smaller than the current number of connections, the oldest excess connections will be closed.
    pub fn resize(pool: *ConnectionPool, client: *Client, new_max: usize) void {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        pool.free_max = new_max;

        while (pool.free_len > pool.free_max) {
            const popped = pool.free_list.popFirst();
            pool.free_len -= 1;

            popped.data.connection.close();

            client.allocator.free(popped.data.host);
            client.allocator.destroy(popped);
        }
    }

    /// Close all connections in the pool. This function is threadsafe.
    /// Any attempt to use this thread pool after calling this function will result in a deadlock.
    pub fn deinit(pool: *ConnectionPool, client: *Client) void {
        pool.mutex.lock();

        while (pool.used_list.first) |node| {
            pool.used_list.remove(node);

            node.data.connection.close();

            client.allocator.free(node.data.host);
            client.allocator.destroy(node);
        }

        while (pool.free_list.first) |node| {
            pool.free_list.remove(node);

            node.data.connection.close();

            client.allocator.free(node.data.host);
            client.allocator.destroy(node);
        }
    }
};

allocator: std.mem.Allocator,

tls_context: hzzp.tls.Context,

connection_pool: ConnectionPool = .{},

pub fn init(allocator: std.mem.Allocator) !Client {
    var client = Client{ .allocator = allocator, .tls_context = undefined };

    try client.tls_context.init();
    try client.tls_context.rescan(allocator);

    return client;
}

pub fn deinit(client: *Client) void {
    client.tls_context.deinit(client.allocator);
    client.connection_pool.deinit(client);
}

const protocol_map = std.ComptimeStringMap(u16, .{
    .{ "http", 80 },
    .{ "https", 443 },
});

pub fn open(client: *Client, uri: std.Uri) !protocol.http1.Request {
    const host = uri.host orelse return error.MissingHost;
    const port = uri.port orelse protocol_map.get(uri.scheme) orelse return error.MissingPort;
    const is_tls = std.ascii.eqlIgnoreCase(uri.scheme, "https");

    return protocol.http1.Request{ .connection = try client.connection_pool.connect(client, host, port, is_tls) };
}
