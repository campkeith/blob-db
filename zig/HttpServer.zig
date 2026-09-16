const std = @import("std");
const Io = std.Io;
const http = std.http;
const Server = std.http.Server;
const Method = std.http.Method;
const json = std.json;
const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;
const Allocator = std.mem.Allocator;

const fmt = @import("format.zig");
const Fmt = fmt.Fmt;

const ty = @import("types.zig");
const Err = ty.Err;
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;
const SaveStatus = ty.Response.SaveStatus;

const fns = @import("functions.zig");
const trash = @import("trash.zig");
const http_io = @import("http_io.zig");
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
    while (try self.handleRequest(arena, &server)) {}
}

fn handleRequest(self: *Self, arena: Allocator, server: *Server) !bool {
    var response: Response, var stream = result: {
        const err_request, const opt_stream = try http_io.recvRequest(server, arena);
        var request = err_request
            catch |err| break :result .{.{.err = handleError(err)}, opt_stream.?};
        defer trash.recycle(&request, arena);
        const response = self.processRequest(arena, request)
            orelse return false;
        break :result .{response, opt_stream.?};
    };
    defer trash.recycle(&response, arena);
    try http_io.sendResponse(&stream, arena, response);
    return server.reader.state == .ready;
}

fn processRequest(self: *Self, arena: Allocator, request: Request) ?Response {
    return switch (request) {
        .call => |call|
            if (self.processCallRequest(arena, call))
                |resp| .{.call = resp}
                else |err| .{.err = handleError(err)},
        .bye => null,
    };
}

fn handleError(err: anytype) Err {
    return
        if (fns.errorCast(Err, err)) |local_err| local_err
        else unexpected: {
            fns.println("handleError: Unexpected internal error: {t}", .{err});
            if (@errorReturnTrace()) |trace| {
                const size = @min(trace.index, trace.instruction_addresses.len);
                std.debug.dumpStackTrace(&.{
                    .return_addresses = trace.instruction_addresses[0..size],
                    .skipped = .none,
                });
            }
            break :unexpected Err.Internal;
        };
}

fn processCallRequest(self: *Self, arena: Allocator, call: Request.Call)
        !Response.Call {
    return switch (call) {
        .store_list => .{.store_list =
            try self.inner.storeList(arena)},
        .store_create => |store_id| .{.store_create =
            try self.inner.storeCreate(store_id)},
        .store_destroy => |store_id| .{.store_destroy =
            try self.inner.storeDestroy(store_id)},
        .blob_hash => |blob| .{.blob_hash =
            try blob.hash(arena)},
        .blob_list => |store_id| .{.blob_list =
            try self.inner.blobList(arena, store_id)},
        .blob_info => |args| .{.blob_info =
            try self.inner.blobInfo(args.store_id, args.blob_id)},
        .blob_load => |args| .{.blob_load =
            try self.inner.blobLoad(args.store_id, args.blob_id)},
        .blob_save => |args| .{.blob_save =
            try self.inner.blobSave(args.store_id, args.blob)},
        .blob_delete => |args| .{.blob_delete =
            try self.inner.blobDelete(args.store_id, args.blob_id)},
    };
}

pub fn main(init: std.process.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();
    var server = try @This().create(init, &persister);
    try server.go(init.gpa);
}
