const std = @import("std");
const Stream = std.Io.net.Stream;
const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const Blob = ty.Blob;

const log = @import("log.zig");
const funcs = @import("funcs.zig");
const debug = @import("debug.zig");
const send_recv = @import("send_recv.zig");

const Self = @This();

io: std.Io,
stream: Stream,
in: std.Io.net.Stream.Reader,
out: std.Io.net.Stream.Writer,
read_buf: []u8,
write_buf: []u8,

pub const connect = log.call(Self, "connect", connect);
fn _connect(io: std.Io, arena: Allocator, address_str: []const u8) !Self {
    const BUF_SIZE = 4096;

    const address = try IpAddress.parseLiteral(address_str);
    const stream = try address.connect(io, .{.mode = .stream});
    errdefer stream.close(io);

    const read_buf = try arena.alloc(u8, BUF_SIZE);
    errdefer arena.free(read_buf);
    const in = stream.reader(io, read_buf);

    const write_buf = try arena.alloc(u8, BUF_SIZE);
    errdefer arena.free(write_buf);
    const out = stream.writer(io, write_buf);

    var client: Self = .{
        .io = io,
        .stream = stream,
        .in = in,
        .out = out,
        .read_buf = read_buf,
        .write_buf = write_buf,
    };
    try client.shakeHands();
    return client;
}

fn shakeHands(self: *Self) !void {
    try send_recv.sendOpenDoor(&self.out.interface);
    try send_recv.recvWelcome(&self.in.interface);
}

pub const close = log.call(Self, "close", close);
fn _close(self: *Self, arena: Allocator) void {
    send_recv.sendRequest(&self.out.interface, .bye) catch |err| {
        funcs.println("Client.close: failed to send 'bye' due to {t}.", .{err});
    };
    arena.free(self.read_buf);
    arena.free(self.write_buf);
    self.stream.close(self.io);
}

pub fn format(self: Self, out: *std.Io.Writer) !void {
    return debug.formatStructOpaque(self, out);
}

pub const storeList = log.call(Self, "store_list", _storeList);
fn _storeList(self: *Self, arena: Allocator) !ty.StoreIds {
    return try self.remoteCall(arena, .store_list, {});
}

pub const storeCreate = log.call(Self, "store_create", _storeCreate);
fn _storeCreate(self: *Self, store_id: StoreId) !void {
    return try self.remoteCall(null, .store_create, store_id);
}

pub const storeDestroy = log.call(Self, "store_destroy", _storeDestroy);
fn _storeDestroy(self: *Self, store_id: StoreId) !void {
    return try self.remoteCall(null, .store_destroy, store_id);
}

pub const blobHas = log.call(Self, "blob_hash", _blobHash);
fn _blobHash(self: *Self, blob: Blob) !ty.BlobId {
    return try self.remoteCall(null, .blob_hash, blob);
}

pub const blobList = log.call(Self, "blob_list", _blobList);
fn _blobList(self: *Self, arena: Allocator, store_id: StoreId) !ty.BlobIds {
    return try self.remoteCall(arena, .blob_list, store_id);
}

pub const blobInfo = log.call(Self, "blob_info", _blobInfo);
fn _blobInfo(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob.Size {
    return try self.remoteCall(null, .blob_info, .init(store_id, blob_id));
}

pub const blobLoad = log.call(Self, "blob_load", _blobLoad);
fn _blobLoad(self: *Self, arena: Allocator,
              store_id: StoreId, blob_id: BlobId) !Blob {
    return try self.remoteCall(arena, .blob_load, .init(store_id, blob_id));
}

pub const blobSave = log.call(Self, "blob_save", _blobSave);
fn _blobSave(self: *Self, store_id: StoreId, blob: Blob)
        !Response.SaveStatusBlobId  {
    return try self.remoteCall(null, .blob_save, .init(store_id, blob));
}

pub const blobDelete = log.call(Self, "blob_delete", _blobDelete);
fn _blobDelete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
    return try self.remoteCall(null, .blob_delete, .init(store_id, blob_id));
}

fn remoteCall(self: *Self, arena: ?Allocator, comptime call_tag: ty.CallTag,
        args: @FieldType(Request.Call, @tagName(call_tag)))
            !@FieldType(Response.Call, @tagName(call_tag)) {
    const request = Request {
        .call = @unionInit(Request.Call, @tagName(call_tag), args),
    };
    try send_recv.sendRequest(&self.out.interface, request);
    const response = try send_recv.recvResponse(&self.in.interface, arena, call_tag);
    return switch (response) {
        .call => |result| result.toOwnedVal(call_tag),
        .err => |err| err,
    };
}
