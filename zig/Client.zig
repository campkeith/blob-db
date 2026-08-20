const std = @import("std");
const Stream = std.Io.net.Stream;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const Blob = ty.Blob;

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

pub fn connect(io: std.Io, address_str: []const u8) !Self {
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

pub fn close(self: *Self) void {
    send_recv.send_request(&self.out.interface, .bye) catch |err| {
        funcs.debug("Client.close: failed to send 'bye' due to {}", .{err});
    };
    mem.free(self.read_buf);
    mem.free(self.write_buf);
    self.stream.close(self.io);
}

pub fn store_list(self: *Self) !ty.StoreIds {
    return try self.send_call_recv_result(.store_list, {});
}

pub fn store_create(self: *Self, store_id: StoreId) !void {
    return try self.send_call_recv_result(.store_create, store_id);
}

pub fn store_destroy(self: *Self, store_id: StoreId) !void {
    return try self.send_call_recv_result(.store_destroy, store_id);
}

pub fn blob_hash(self: *Self, blob: Blob) !ty.BlobId {
    return try self.send_call_recv_result(.blob_hash, blob);
}

pub fn blob_list(self: *Self, store_id: StoreId) !ty.BlobIds {
    return try self.send_call_recv_result(.blob_list, store_id);
}

pub fn blob_info(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob.Size {
    return try self.send_call_recv_result(.blob_info, .init(store_id, blob_id));
}

pub fn blob_load(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob {
    return try self.send_call_recv_result(.blob_load, .init(store_id, blob_id));
}

pub fn blob_save(self: *Self, store_id: StoreId, blob: Blob)
        !Response.SaveStatusBlobId  {
    return try self.send_call_recv_result(.blob_save, .init(store_id, blob));
}

pub fn blob_delete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
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
    var response = try send_recv.recv_response(&self.in.interface, call_tag);
    defer response.deinit();
    return switch (response) {
        .call => |result| @field(result, @tagName(call_tag)),
        .err => |err| err,
    };
}
