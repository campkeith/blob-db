const std = @import("std");
const Io = std.Io;
const http = std.http;
const Server = std.http.Server;
const Method = std.http.Method;
const Request = std.http.Server.Request;
const json = std.json;
const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;
const Allocator = std.mem.Allocator;

const fmt = @import("format.zig");
const Fmt = fmt.Fmt;

const ty = @import("types.zig");
const Err = ty.Err;
const StoreId = ty.StoreId;
const SaveStatus = ty.Response.SaveStatus;

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
        try self.handleRequest(arena, &request);
    }
}

const Route = struct {
    method: Method,
    path: []const u8,
    handler: []const u8,

    const init = record.init(@This());
};

fn handleRequest(self: *Self, arena: Allocator, request: *Request) !void {
    // IDEA: Map to a comptime-built union instead of functions
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
            // TODO: Add error handler that translates to http status codes
            try @call(.auto, handlerFunc, .{self, arena, request} ++ args);
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

fn storeList(self: *Self, arena: Allocator, request: *Request) !void {
    try reqBodyCheckEmpty(request);
    const store_ids = try self.inner.storeList(arena);
    try respondJson(request, .ok, store_ids);
}

fn storeCreate(self: *Self, _: Allocator, request: *Request,
               store_id: StoreId) !void {
    try reqBodyCheckEmpty(request);
    try self.inner.storeCreate(store_id);
    try respondStatus(request, .no_content);
}

fn storeDestroy(self: *Self, _: Allocator, request: *Request,
                store_id: StoreId) !void {
    try reqBodyCheckEmpty(request);
    try self.inner.storeDestroy(store_id);
    try respondStatus(request, .no_content);
}

fn blobHash(_: *Self, arena: Allocator, request: *Request) !void {
    const blob = try reqBodyBlob(request, arena);
    const blob_id = try blob.hash(arena);
    try respondJson(request, .ok, blob_id);
}

fn blobList(self: *Self, arena: Allocator, request: *Request,
            store_id: StoreId) !void {
    try reqBodyCheckEmpty(request);
    const blob_ids = try self.inner.blobList(arena, store_id);
    try respondJson(request, .ok, blob_ids);
}

fn blobInfo(self: *Self, _: Allocator, request: *Request,
            store_id: StoreId, blob_id: Blob.Id) !void {
    try reqBodyCheckEmpty(request);
    const blob_size = try self.inner.blobInfo(store_id, blob_id);
    try respondBlobHead(request, blob_size);
}

fn blobLoad(self: *Self, _: Allocator, request: *Request,
            store_id: StoreId, blob_id: Blob.Id) !void {
    try reqBodyCheckEmpty(request);
    const blob = try self.inner.blobLoad(store_id, blob_id);
    try respondBlob(request, blob);
}

fn blobSave(self: *Self, arena: Allocator, request: *Request,
            store_id: StoreId) !void {
    const blob = try reqBodyBlob(request, arena);
    const result = try self.inner.blobSave(store_id, blob);
    // TODO: add location header
    try respondJson(request, saveToHttpStatus(result.status), result);
}

fn blobDelete(self: *Self, _: Allocator, request: *Request,
              store_id: StoreId, blob_id: Blob.Id) !void {
    try reqBodyCheckEmpty(request);
    try self.inner.blobDelete(store_id, blob_id);
    try respondStatus(request, .no_content);
}

fn saveToHttpStatus(status: SaveStatus) http.Status {
    return switch (status) {
        .created => .created,
        .exists => .conflict,
    };
}

fn reqBodyCheckEmpty(request: *Request) !void {
    // TODO: Determine how best to handle this in practice
    const reader = request.readerExpectNone(&.{});
    _ = try reader.discard(.nothing);
}

fn reqBodyBlob(request: *Request, arena: Allocator) !Blob {
    const reader = request.readerExpectNone(&.{});
    const size = request.head.content_length orelse return Err.BadArgument;
    return .initStream(arena, reader, size);
}

fn respondStatus(request: *Request, status: http.Status) !void {
    var writer = try respBodyWriter(request, status, null, null);
    try writer.end();
}

fn respondJson(request: *Request, status: http.Status, val: anytype) !void {
    var writer = try respBodyWriter(request, status, "application/json", null);
    var stringify = json.Stringify {
        .writer = &writer.writer,
        .options = .{.whitespace = .indent_tab},
    };
    try stringify.write(val);
    // There does not appear to be an option to add a trailing newline...
    try writer.writer.writeAll("\n");
    try writer.end();
}

fn respondBlobHead(request: *Request, size: Blob.Size) !void {
    var writer = try respBodyBlobWriter(request, size);
    try writer.writer.splatByteAll(0, size);
    try writer.end();
}

fn respondBlob(request: *Request, blob: Blob) !void {
    const size = try blob.size();
    var writer = try respBodyBlobWriter(request, size);
    switch (blob.core) {
        .file => |file| {
            var reader = file.file.reader(file.io, &.{});
            const bytes_sent = try writer.writer.sendFileAll(&reader, .limited(size));
            if (bytes_sent != size) return Err.Internal;
        },
        else => {
            fns.println("respondBlob: Unhandled blob type: {t}.",
                        .{std.meta.activeTag(blob.core)});
            return Err.Internal;
        }
    }
    try writer.end();
}

fn respBodyWriter(request: *Request, status: http.Status,
                  content_type: ?[]const u8, content_length: ?u64)
        !http.BodyWriter {
    const head = Request.RespondStreamingOptions {
        .content_length = content_length,
        .respond_options = .{
            .status = status,
            .extra_headers = if (content_type) |type_| &.{
                headerInit("content-type", type_),
            } else &.{},
            .transfer_encoding = if (content_type == null) .none else null,
        },
    };
    // FIXME: Hack
    return try request.respondStreaming(request.server.reader.in.buffer, head);
}

fn respBodyBlobWriter(request: *Request, size: Blob.Size) !http.BodyWriter {
    return respBodyWriter(request, .ok, "application/octet-stream", size);
}

fn headerInit(name: []const u8, value: []const u8) http.Header {
    return .{.name = name, .value = value};
}

pub fn main(init: std.process.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();
    var server = try @This().create(init, &persister);
    try server.go(init.gpa);
}
