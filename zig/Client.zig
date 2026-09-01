const std = @import("std");
const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const Blob = ty.Blob;

const log = @import("log.zig");
const mem = @import("mem.zig");
const funcs = @import("funcs.zig");
const send_recv = @import("send_recv.zig");

const Self = @This();

io: std.Io,
stream: Stream,
in: std.Io.net.Stream.Reader,
out: std.Io.net.Stream.Writer,
read_buf: []u8,
write_buf: []u8,

pub const connect = log.call(Self, "connect", _connect);
fn _connect(io: std.Io, address_str: []const u8) !Self {
    const BUF_SIZE = 4096;

    const address = try IpAddress.parseLiteral(address_str);
    const stream = try address.connect(io, .{.mode = .stream});
    errdefer stream.close(io);

    const read_buf = try mem.alloc(u8, BUF_SIZE);
    errdefer mem.free(read_buf);
    const in = stream.reader(io, read_buf);

    const write_buf = try mem.alloc(u8, BUF_SIZE);
    errdefer mem.free(write_buf);
    const out = stream.writer(io, write_buf);

    var client: Self = .{
        .io = io,
        .stream = stream,
        .in = in,
        .out = out,
        .read_buf = read_buf,
        .write_buf = write_buf,
    };
    try client.shake_hands();
    return client;
}

fn shake_hands(self: *Self) !void {
    try send_recv.send_open_door(&self.out.interface);
    try send_recv.recv_welcome(&self.in.interface);
}

pub const close = log.call(Self, "close", _close);
fn _close(self: *Self) void {
    send_recv.send_request(&self.out.interface, .bye) catch |err| {
        funcs.debug("Client.close: failed to send 'bye' due to {}", .{err});
    };
    mem.free(self.read_buf);
    mem.free(self.write_buf);
    self.stream.close(self.io);
}

pub const store_list = log.call(Self, "store_list", _store_list);
fn _store_list(self: *Self) !ty.StoreIds {
    return try self.send_call_recv_result(.store_list, {});
}

pub const store_create = log.call(Self, "store_create", _store_create);
fn _store_create(self: *Self, store_id: StoreId) !void {
    return try self.send_call_recv_result(.store_create, store_id);
}

pub const store_destroy = log.call(Self, "store_destroy", _store_destroy);
fn _store_destroy(self: *Self, store_id: StoreId) !void {
    return try self.send_call_recv_result(.store_destroy, store_id);
}

pub const blob_hash = log.call(Self, "blob_hash", _blob_hash);
fn _blob_hash(self: *Self, blob: Blob) !ty.BlobId {
    return try self.send_call_recv_result(.blob_hash, blob);
}

pub const blob_list = log.call(Self, "blob_list", _blob_list);
fn _blob_list(self: *Self, store_id: StoreId) !ty.BlobIds {
    return try self.send_call_recv_result(.blob_list, store_id);
}

pub const blob_info = log.call(Self, "blob_info", _blob_info);
fn _blob_info(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob.Size {
    return try self.send_call_recv_result(.blob_info, .init(store_id, blob_id));
}

pub const blob_load = log.call(Self, "blob_load", _blob_load);
fn _blob_load(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob {
    return try self.send_call_recv_result(.blob_load, .init(store_id, blob_id));
}

pub const blob_save = log.call(Self, "blob_save", _blob_save);
fn _blob_save(self: *Self, store_id: StoreId, blob: Blob)
        !Response.SaveStatusBlobId  {
    return try self.send_call_recv_result(.blob_save, .init(store_id, blob));
}

pub const blob_delete = log.call(Self, "blob_delete", _blob_delete);
fn _blob_delete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
    return try self.send_call_recv_result(.blob_delete, .init(store_id, blob_id));
}

fn send_call_recv_result(self: *Self, comptime call_tag: ty.CallTag,
        args: @FieldType(Request.Call, @tagName(call_tag)))
            !@FieldType(Response.Call, @tagName(call_tag)) {
    var request = Request{
        .call = @unionInit(Request.Call, @tagName(call_tag), args),
    };
    defer request.deinit();
    try send_recv.send_request(&self.out.interface, request);
    const response = try send_recv.recv_response(&self.in.interface, call_tag);
    return switch (response) {
        .call => |result| @field(result, @tagName(call_tag)),
        .err => |err| err,
    };
}
