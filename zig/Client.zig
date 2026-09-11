const std = @import("std");
const Stream = std.Io.net.Stream;
const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const CallTag = ty.CallTag;
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;

const Blob = @import("Blob.zig");
const log = @import("log.zig");
const fmt = @import("format.zig");
const fns = @import("functions.zig");
const send_recv = @import("send_recv.zig");

const Self = @This();

io: std.Io,
stream: Stream,
in: std.Io.net.Stream.Reader,
out: std.Io.net.Stream.Writer,
read_buf: []u8,
write_buf: []u8,

pub const connect = log.call(Self, "connect", connect_);
fn connect_(io: std.Io, arena: Allocator, address_str: []const u8) !Self {
    const buf_size = 16 * 1024;

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

pub const close = log.call(Self, "close", close_);
fn close_(self: *Self, arena: Allocator) void {
    send_recv.sendRequest(&self.out.interface, .bye) catch |err| {
        fns.println("Client.close: failed to send 'bye' due to {t}.", .{err});
    };
    arena.free(self.read_buf);
    arena.free(self.write_buf);
    self.stream.close(self.io);
}

pub fn format(self: Self, out: *std.Io.Writer) !void {
    return fmt.structOpaque(self, out);
}

pub const storeList = log.call(Self, "store_list", storeList_);
fn storeList_(self: *Self, arena: Allocator) ![]StoreId {
    return try self.remoteCall(arena, .store_list, {});
}

pub const storeCreate = log.call(Self, "store_create", storeCreate_);
fn storeCreate_(self: *Self, store_id: StoreId) !void {
    return try self.remoteCall(null, .store_create, store_id);
}

pub const storeDestroy = log.call(Self, "store_destroy", storeDestroy_);
fn storeDestroy_(self: *Self, store_id: StoreId) !void {
    return try self.remoteCall(null, .store_destroy, store_id);
}

pub const blobHash = log.call(Self, "blob_hash", blobHash_);
fn blobHash_(self: *Self, blob: Blob) !Blob.Id {
    return try self.remoteCall(null, .blob_hash, blob);
}

pub const blobList = log.call(Self, "blob_list", blobList_);
fn blobList_(self: *Self, arena: Allocator, store_id: StoreId) ![]Blob.Id {
    return try self.remoteCall(arena, .blob_list, store_id);
}

pub const blobInfo = log.call(Self, "blob_info", blobInfo_);
fn blobInfo_(self: *Self, store_id: StoreId, blob_id: Blob.Id) !Blob.Size {
    return try self.remoteCall(null, .blob_info, .init(store_id, blob_id));
}

pub const blobLoad = log.call(Self, "blob_load", blobLoad_);
fn blobLoad_(self: *Self, arena: Allocator,
                 store_id: StoreId, blob_id: Blob.Id) !Blob {
    return try self.remoteCall(arena, .blob_load, .init(store_id, blob_id));
}

pub const blobSave = log.call(Self, "blob_save", blobSave_);
fn blobSave_(self: *Self, store_id: StoreId, blob: Blob)
        !Response.SaveStatusBlobId  {
    return try self.remoteCall(null, .blob_save, .init(store_id, blob));
}

pub const blobDelete = log.call(Self, "blob_delete", blobDelete_);
fn blobDelete_(self: *Self, store_id: StoreId, blob_id: Blob.Id) !void {
    return try self.remoteCall(null, .blob_delete, .init(store_id, blob_id));
}

fn remoteCall(self: *Self, arena: ?Allocator, comptime call_tag: CallTag,
        args: @FieldType(Request.Call, @tagName(call_tag)))
            !@FieldType(Response.Call, @tagName(call_tag)) {
    const request = Request {
        .call = @unionInit(Request.Call, @tagName(call_tag), args),
    };
    try send_recv.sendRequest(&self.out.interface, request);
    const response = try send_recv.recvResponse(
        &self.in.interface, arena, call_tag);
    return switch (response) {
        .call => |result| result.toOwnedVal(call_tag),
        .err => |err| err,
    };
}
