
# HZZP

Hzzp is a HTTP/1.1 library for Zig.

## BaseClient and BaseServer

These are designed with performance in mind, no allocations are made by the parser. However, you must guarentee that
the buffer provided to `create` is long enough for the largest chunk that will be parsed. In BaseClient this is will
be a `Header: value` pair (including CRLF), in BaseServer it will be the requested path. If your buffer is too short
you `readEvent` will throw a `BufferOverflow` error.

## Todo

- [x] low-level allocation-free client and server parser
- [ ] higher-level allocating, but easier to use client and server parser
- [ ] very simple request wrapper (probably around the high-level allocating client)
- [x] "prettyify" error sets