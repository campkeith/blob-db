const std = @import("std");
const IpAddress = std.Io.net.IpAddress;
const Stream = std.Io.net.Stream;

const Persister = @import("Persister.zig");
const send_recv = @import("send_recv.zig");
const funcs = @import("funcs.zig");
const ty = @import("types.zig");

const Self = @This();

io: std.Io,
inner: *Persister,
address_str: []const u8,


pub fn create(init: ty.Init, inner: *Persister) !Self {
    const address_str = try funcs.getEnv(init.environ_map, "BIND_ADDRESS");
    return .{
        .io = init.io,
        .inner = inner,
        .address_str = address_str,
    };
}

pub fn go(self: *Self) !void {
    const address = try IpAddress.parseLiteral(self.address_str);
    const opts: IpAddress.ListenOptions = .{
        .reuse_address = false,
    };
    var server = try address.listen(self.io, opts);
    var q: [32:0]u8 = undefined;
    q[0] = '?';
    q[1] = 0;
    const addr_str = format_address(server.socket.address) catch q;
    funcs.debug("Server at {s} is up.\n", .{addr_str});
    defer server.deinit(self.io);

    while (true) {
        var stream = server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.WouldBlock => {
                funcs.debug("Fatal server error: {any}\n", .{err});
                return err;
            }, else => {
                funcs.debug("Error connecting to client: {any}\n", .{err});
                continue;
            },
        };
        defer stream.close(self.io);
        self.clientSession(&stream);
    }
}

pub fn clientSession(self: *Self, stream: *Stream) void {
    var q: [32:0]u8 = undefined;
    q[0] = '?';
    q[1] = 0;
    const peer_addr = peer_address(stream) catch null;
    const peer_addr_str = if (peer_addr) |addr| format_address(addr) catch q
                          else q;
    funcs.debug("Client at {s} connected.\n", .{peer_addr_str});
    self.handle_stream(stream) catch |err| {
        funcs.debug("Dropping client at {s} due to {any}\n", .{peer_addr_str, err});
        return;
    };
    funcs.debug("Client at {s} disconnected.\n", .{peer_addr_str});
}

pub fn handle_stream(self: *Self, stream: *Stream) !void {
    const BUF_SIZE = 4096;
    const buffer = try funcs.allocator.alloc(u8, BUF_SIZE);
    defer funcs.allocator.free(buffer);
    var stream_in = stream.reader(self.io, buffer).interface;
    var stream_out = stream.writer(self.io, buffer).interface;
    try shake_hands(&stream_in, &stream_out);
    while (try self.handle_request(&stream_in, &stream_out)) {}
}

pub fn shake_hands(in: *ty.Reader, out: *ty.Writer) !void {
    send_recv.recv_open_door(in) catch |err| switch (err) {
        ty.Err.BadArgument => {
            try send_recv.send_not_welcome(out);
            return;
        },
        else => return err,
    };
    try send_recv.send_welcome(out);
}

pub fn handle_request(self: *Self, in: *ty.Reader, out: *ty.Writer) !bool {
    var request = try send_recv.recv_request(in);
    const opt_response = self.process_request(&request) catch |err|
        ty.Response{.err = handle_error(err)};
    if (opt_response) |response| {
        try send_recv.send_response(out, response);
        return true;
    } else {
        return false;
    }
}

pub fn process_request(self: *Self, request: *ty.Request) !?ty.Response {
    return switch (request.*) {
        .store_list =>
            .{.store_list = try self.inner.store_list()},
        .store_create => |store_id|
            .{.store_create = try self.inner.store_create(store_id)},
        .store_destroy => |store_id|
            .{.store_destroy = try self.inner.store_destroy(store_id)},
        .blob_hash => |*blob|
            .{.blob_hash = try funcs.hashBlob(blob)},
        .blob_list => |store_id|
            .{.blob_list = try self.inner.blob_list(store_id)},
        // Zig does not support tuple destructuring in a switch capture...
        .blob_info => |args|
            .{.blob_info = try self.inner.blob_info(args.store_id, args.blob_id)},
        .blob_load => |args|
            .{.blob_load = try self.inner.blob_load(args.store_id, args.blob_id)},
        .blob_save => |*args|
            .{.blob_save = try self.inner.blob_save(args.store_id, &args.blob)},
        .blob_delete => |args|
            .{.blob_delete = try self.inner.blob_delete(args.store_id, args.blob_id)},
        .bye =>
            null,
    };
}

fn handle_error(err: anytype) ty.Err {
    return switch (@TypeOf(err)) {
        ty.Err => err,
        else => {
            funcs.debug("handle_error: Unexpected internal error:\n", .{});
            std.debug.dumpCurrentStackTrace(.{});
            return ty.Err.Internal;
        }
    };
}

fn format_address(address: IpAddress) ![32:0]u8 {
    var buf: [32:0]u8 = .{0} ** 32;
    var writer = std.Io.Writer.fixed(&buf);
    try address.format(&writer);
    return buf;
}

fn peer_address(stream: *Stream) !IpAddress {
    var addr_buf: std.posix.sockaddr.storage = undefined;
    var size: std.posix.socklen_t = @sizeOf(@TypeOf(addr_buf));
    const address: *std.posix.sockaddr = @ptrCast(&addr_buf);
    try std.posix.getpeername(stream.socket.handle, address, &size);
    return try sock_to_ip_addr(address);
}

fn sock_to_ip_addr(address: *const std.posix.sockaddr) !IpAddress {
    switch (address.family) {
        std.posix.AF.INET => {
            const addr_v4: *const std.posix.sockaddr.in = @alignCast(@ptrCast(address));
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, addr_v4.addr, .big);
            return .{.ip4 = .{
                .bytes = bytes,
                .port = std.mem.bigToNative(u16, addr_v4.port),
            }};
        },
        std.posix.AF.INET6 => {
            const addr_v6: *const std.posix.sockaddr.in6 = @alignCast(@ptrCast(address));
            return .{.ip6 = .{
                .bytes = addr_v6.addr,
                .port = std.mem.bigToNative(u16, addr_v6.port),
                .flow = addr_v6.flowinfo,
                .interface = .{
                    .index = addr_v6.scope_id,
                },
            }};
        },
        else => {
            funcs.debug("sockaddr_to_ip_address: unsupported family: {d}\n",
                        .{address.family});
            return ty.Err.Internal;
        },
    }
}
