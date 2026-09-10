const std = @import("std");
const Io = std.Io;
const Server = std.http.Server;
const Method = std.http.Method;
const Request = std.http.Server.Request;
const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;
const Allocator = std.mem.Allocator;

const fmt = @import("format.zig");
const Fmt = fmt.Fmt;

const ty = @import("types.zig");
const Err = ty.Err;
const StoreId = ty.StoreId;

const fns = @import("functions.zig");
const Blob = @import("Blob.zig");
const record = @import("record.zig");
const Persister = @import("Persister.zig");

const Self = @This();

const buf_size: usize = 64 * 1024;

io: Io,
inner: *Persister,
address: IpAddress,
running: bool,

pub fn create(init: std.process.Init, inner: *Persister) !Self {
    const address_str = try fns.getEnv(init.environ_map, "BIND_ADDRESS_HTTP");
    const address = try IpAddress.parseLiteral(address_str);
    return .{
        .io = init.io,
        .inner = inner,
        .address = address,
        .running = false,
    };
}

pub fn go(self: *Self, arena: Allocator) !noreturn {
    const opts: IpAddress.ListenOptions = .{
        .reuse_address = true,
    };
    var server = try self.address.listen(self.io, opts);
    defer server.deinit(self.io);
    fns.println("Server at {f} is up.", .{Fmt(server.socket.address)});

    while (true) {
        var stream = server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.WouldBlock => {
                fns.println("Fatal server error: {t}", .{err});
                return err;
            },
            else => {
                fns.println("Error connecting to client: {t}", .{err});
                continue;
            }
        };
        defer stream.close(self.io);
        self.clientSession(arena, &stream);
    }
}

pub fn clientSession(self: *Self, arena: Allocator, stream: *Stream) void {
    const peer_addr = fns.peerAddress(stream) catch null;
    fns.println("Client at {f} connected.", .{Fmt(peer_addr)});

    self.handleStream(arena, stream) catch |err| {
        fns.println("Dropping client at {f} due to {t}.",
                    .{Fmt(peer_addr), err});
        return;
    };
    fns.println("Client at {f} disconnected.", .{Fmt(peer_addr)});
}

pub fn handleStream(self: *Self, arena: Allocator, stream: *Stream) !void {
    const read_buf = try arena.alloc(u8, buf_size);
    defer arena.free(read_buf);
    var in = stream.reader(self.io, read_buf);
    const write_buf = try arena.alloc(u8, buf_size);
    defer arena.free(write_buf);
    var out = stream.writer(self.io, write_buf);

    var server = Server.init(&in.interface, &out.interface);
    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        // Ignore upgrade request
        try self.handleRequest(&request);
    }
}

const Route = struct {
    method: Method,
    path: []const u8,
    handler: []const u8,

    const init = record.init(@This());
};

fn handleRequest(self: *Self, request: *Request) !void {
    const routes = comptime [_]Route {
        .init(.GET, "/stores", "storeList"),
        .init(.PUT, "/stores/:parseStoreId", "storeCreate"),
        .init(.DELETE, "/stores/:parseStoreId", "storeDestroy"),
        .init(.POST, "/blob_hash", "blobHash"),
        .init(.GET, "/stores/:parseStoreId/blobs", "blobList"),
        .init(.HEAD, "/stores/:parseStoreId/blobs/:parseBlobId", "blobInfo"),
        .init(.GET, "/stores/:parseStoreId/blobs/:parseBlobId", "blobLoad"),
        .init(.POST, "/stores/:parseStoreId/blobs", "blobSave"),
        .init(.DELETE, "/stores/:parseStoreId/blobs/:parseBlobId", "blobDelete"),
    };
    inline for (routes) |route| {
        if (matchHead(request.head, route)) |args| {
            const handlerFunc = @field(@This(), route.handler);
            try @call(.auto, handlerFunc, .{self, request} ++ args);
            break;
        }
    } else return Err.NotFound;
}

fn matchHead(head: Request.Head, comptime route: Route) ?Args(route.path) {
    return if (head.method == route.method) matchPath(head.target, route.path)
           else null;
}

fn matchPath(path: []const u8, comptime pattern: []const u8) ?Args(pattern) {
    var path_iter = std.mem.splitScalar(u8, path, '/');
    comptime var pattern_iter = std.mem.splitScalar(u8, pattern, '/');
    var args: Args(pattern) = undefined;
    comptime var index: usize = 0;
    inline while (comptime pattern_iter.next()) |pattern_seg| {
        const path_seg = path_iter.next() orelse return null;
        if (pattern_seg.len > 0 and pattern_seg[0] == ':') {
            const parseFunc = @field(@This(), pattern_seg[1..]);
            args[index] = parseFunc(path_seg) orelse return null;
            index += 1;
        } else {
            if (!std.mem.eql(u8, path_seg, pattern_seg)) return null;
        }
    }
    return if (path_iter.next() == null) args else null;
}

fn Args(pattern: []const u8) type {
    var args: [64]type = undefined;
    var index: usize = 0;
    var seg_iter = std.mem.splitScalar(u8, pattern, '/');
    inline while (seg_iter.next()) |segment| {
        if (segment.len > 0 and segment[0] == ':') {
            const parseFunc = @field(@This(), segment[1..]);
            const ReturnType = fns.ReturnType(@TypeOf(parseFunc));
            args[index] = @typeInfo(ReturnType).optional.child;
            index += 1;
        }
    }
    return @Tuple(args[0..index]);
}

fn parseStoreId(in: []const u8) ?StoreId {
    return .init(in);
}

fn parseBlobId(in: []const u8) ?Blob.Id {
    return Blob.parseId(in) catch null;
}

fn storeList(self: *Self, request: *Request) !void {
    _, _ = .{self, request};
    return Err.Internal;
}

fn storeCreate(self: *Self, request: *Request, store_id: StoreId) !void {
    _, _, _ = .{self, request, store_id};
    return Err.Internal;
}

fn storeDestroy(self: *Self, request: *Request, store_id: StoreId) !void {
    _, _, _ = .{self, request, store_id};
    return Err.Internal;
}

fn blobHash(self: *Self, request: *Request) !void {
    _, _ = .{self, request};
    return Err.Internal;
}

fn blobList(self: *Self, request: *Request, store_id: StoreId) !void {
    _, _, _ = .{self, request, store_id};
    return Err.Internal;
}

fn blobInfo(self: *Self, request: *Request, store_id: StoreId, blob_id: Blob.Id)
        !void {
    _, _, _, _ = .{self, request, store_id, blob_id};
    return Err.Internal;
}

fn blobLoad(self: *Self, request: *Request, store_id: StoreId, blob_id: Blob.Id)
        !void {
    _, _, _, _ = .{self, request, store_id, blob_id};
    return Err.Internal;
}

fn blobSave(self: *Self, request: *Request, store_id: StoreId) !void {
    _, _, _ = .{self, request, store_id};
    return Err.Internal;
}

fn blobDelete(self: *Self, request: *Request, store_id: StoreId, blob_id: Blob.Id)
        !void {
    _, _, _, _ = .{self, request, store_id, blob_id};
    return Err.Internal;
}

pub fn main(init: std.process.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();
    var server = try @This().create(init, &persister);
    try server.go(init.gpa);
}
