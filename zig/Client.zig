const std = @import("std");
const IpAddress = std.Io.net.IpAddress;
const Stream = std.Io.net.Stream;

const send_recv = @import("send_recv.zig");
const funcs = @import("funcs.zig");
const ty = @import("types.zig");
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const BlobSize = ty.BlobSize;
const BlobStream = ty.BlobStream;

const Self = @This();

io: std.Io,
stream: []const u8,
in: ty.Reader,
out: ty.Writer,
read_buf: []u8,
write_buf: []u8,

pub fn connect(init: ty.Init, address_str: []u8) !Self {
    const BUF_SIZE = 4096;

    const address = try IpAddress.parseLiteral(address_str);
    const stream = try address.connect(init.io);
    errdefer stream.close(init.io);

    const read_buf = try funcs.allocator.alloc(u8, BUF_SIZE);
    errdefer funcs.allocator.free(read_buf);
    const in = stream.reader(init.io, read_buf);

    const write_buf = try funcs.allocator.alloc(u8, BUF_SIZE);
    errdefer funcs.allocator.free(write_buf);
    const out = stream.writer(init.io, write_buf);

    return .{
        .io = init.io,
        .stream = stream,
        .in = in,
        .out = out,
        .read_buf = read_buf,
        .write_buf = write_buf,
    };
}

pub fn close(self: *Self) void {
    send_recv.send_request(self.out, .{.bye});
    funcs.allocator.free(self.read_buf);
    funcs.allocator.free(self.write_buf);
    self.stream.close();
}

pub fn store_list(self: *Self) !ty.StoreIds {
    try self.send_call_recv_result(.store_list, void);
}

pub fn store_create(self: *Self, store_id: StoreId) !void {
    try self.send_call_recv_result(.store_create, store_id);
}

pub fn store_destroy(self: *Self, store_id: StoreId) !void {
    try self.send_call_recv_result(.store_destroy, store_id);
}

pub fn blob_hash(self: *Self, blob: *BlobStream) !ty.BlobId {
    try self.send_call_recv_result(.blob_hash, blob);
}

pub fn blob_list(self: *Self, store_id: StoreId) !ty.BlobIds {
    try self.send_call_recv_result(.blob_list, store_id);
}

pub fn blob_info(self: *Self, store_id: StoreId, blob_id: BlobId) !BlobSize {
    try self.send_call_recv_result(.blob_info,
        .{.store_id = store_id, .blob_id = blob_id});
}

pub fn blob_load(self: *Self, store_id: StoreId, blob_id: BlobId) !BlobStream {
    try self.send_call_recv_result(.blob_load,
        .{.store_id = store_id, .blob_id = blob_id});
}

pub fn blob_save(self: *Self, store_id: StoreId, blob: *BlobStream)
        !Response.SaveStatusBlobId  {
    try self.send_call_recv_result(.blob_save,
        .{.store_id = store_id, .blob = blob});
}

pub fn blob_delete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
    try self.send_call_recv_result(.blob_delete,
        .{.store_id = store_id, .blob_id = blob_id});
}

fn send_call_recv_result(self: *Self, comptime call_tag: ty.CallTag,
        args: @FieldType(Request.Call, @tagName(call_tag)))
            !@FieldType(Response.Call, @tagName(call_tag)) {
    const call = @unionInit(Request.Call, @tagName(call_tag), args);
    try send_recv.send_request(self.out, .{.call = call});
    const response = try send_recv.recv_response(self.out, call_tag);
    return switch (response) {
        .call => |result| @field(result, @tagName(call_tag)),
        .err => |err| err,
    };
}
