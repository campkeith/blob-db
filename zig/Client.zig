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

pub const connect = log.call(Self, "connect", connectInner);
fn connectInner(io: std.Io, arena: Allocator, address_str: []const u8) !Self {
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

pub const close = log.call(Self, "close", closeInner);
fn closeInner(self: *Self, arena: Allocator) void {
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

pub const storeList = log.call(Self, "store_list", storeListInner);
fn storeListInner(self: *Self, arena: Allocator) ![]StoreId {
    return try self.remoteCall(arena, .store_list, {});
}

pub const storeCreate = log.call(Self, "store_create", storeCreateInner);
fn storeCreateInner(self: *Self, store_id: StoreId) !void {
    return try self.remoteCall(null, .store_create, store_id);
}

pub const storeDestroy = log.call(Self, "store_destroy", storeDestroyInner);
fn storeDestroyInner(self: *Self, store_id: StoreId) !void {
    return try self.remoteCall(null, .store_destroy, store_id);
}

pub const blobHash = log.call(Self, "blob_hash", blobHashInner);
fn blobHashInner(self: *Self, blob: Blob) !Blob.Id {
    return try self.remoteCall(null, .blob_hash, blob);
}

pub const blobList = log.call(Self, "blob_list", blobListInner);
fn blobListInner(self: *Self, arena: Allocator, store_id: StoreId) ![]Blob.Id {
    return try self.remoteCall(arena, .blob_list, store_id);
}

pub const blobInfo = log.call(Self, "blob_info", blobInfoInner);
fn blobInfoInner(self: *Self, store_id: StoreId, blob_id: Blob.Id) !Blob.Size {
    return try self.remoteCall(null, .blob_info, .init(store_id, blob_id));
}

pub const blobLoad = log.call(Self, "blob_load", blobLoadInner);
fn blobLoadInner(self: *Self, arena: Allocator,
                 store_id: StoreId, blob_id: Blob.Id) !Blob {
    return try self.remoteCall(arena, .blob_load, .init(store_id, blob_id));
}

pub const blobSave = log.call(Self, "blob_save", blobSaveInner);
fn blobSaveInner(self: *Self, store_id: StoreId, blob: Blob)
        !Response.SaveStatusBlobId  {
    return try self.remoteCall(null, .blob_save, .init(store_id, blob));
}

pub const blobDelete = log.call(Self, "blob_delete", blobDeleteInner);
fn blobDeleteInner(self: *Self, store_id: StoreId, blob_id: Blob.Id) !void {
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
