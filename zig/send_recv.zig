const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const ty = @import("types.zig");
const CallTag = ty.CallTag;
const Request = ty.Request;
const Response = ty.Response;

const funcs = @import("funcs.zig");

const ReaderWriterError = Writer.Error || Reader.Error;

const ProtoVersion = u16;
const StoreIdSize = u16;
const ArraySize = u64;

const PROTO_VERSION: ProtoVersion = 1;
const CODE_OPEN_DOOR = ty.encode8("OpenDoor");

const GreetCode = enum(ty.Code) {
    welcome = ty.encode8("Welcome!"),
    not_welcome = ty.encode8("Go away!"),
};

const CODE_BYE = ty.encode8("Goodbye!");

pub const Status = enum(ty.Code) {
    okay = ty.encode8("okeydoke"),
    exists = ty.encode8("itexists"),
    not_found = ty.encode8("notfound"),
    no_space = ty.encode8("no-space"),
    bad_argument = ty.encode8("invalarg"),
    internal_error = ty.encode8("internal"),
};

pub fn send_open_door(stream: *Writer) !void {
    try send_tuple(stream, .{CODE_OPEN_DOOR, PROTO_VERSION});
}

pub fn send_welcome(stream: *Writer) !void {
    try send(stream, GreetCode.welcome);
}

pub fn send_not_welcome(stream: *Writer) !void {
    try send_tuple(stream, .{GreetCode.not_welcome, PROTO_VERSION});
}

pub fn send_request(stream: *Writer, request: Request) !void {
    try switch (request) {
        .call => |call| send_call_request(stream, call),
        .bye => send(stream, CODE_BYE),
    };
}

fn send_call_request(stream: *Writer, call: Request.Call) !void {
    try switch (call) {
        .store_list =>
            send(stream, CallTag.store_list),
        .store_create => |store_id|
            send_tuple(stream, .{CallTag.store_create, store_id}),
        .store_destroy => |store_id|
            send_tuple(stream, .{CallTag.store_destroy, store_id}),
        .blob_hash => |blob|
            send_tuple(stream, .{CallTag.blob_hash, blob}),
        .blob_list => |store_id|
            send_tuple(stream, .{CallTag.blob_list, store_id}),
        .blob_info => |store_id, blob_id|
            send_tuple(stream, .{CallTag.blob_info, store_id, blob_id}),
        .blob_load => |store_id, blob_id|
            send_tuple(stream, .{CallTag.blob_load, store_id, blob_id}),
        .blob_save => |store_id, blob|
            send_tuple(stream, .{CallTag.blob_save, store_id, blob}),
        .blob_delete => |store_id, blob_id|
            send_tuple(stream, .{CallTag.blob_delete, store_id, blob_id}),
    };
}

pub fn send_response(stream: *Writer, response: Response) !void {
    try switch (response) {
        .call => |call| send_call_resp(stream, call),
        .err => |err| send(stream, error_to_status(err)),
    };
}

fn send_call_resp(stream: *Writer, call: Response.Call) !void {
    try switch (call) {
        .store_list => |store_ids|
            send_tuple(stream, .{Status.okay, store_ids}),
        .blob_hash => |blob_id|
            send_tuple(stream, .{Status.okay, blob_id}),
        .blob_list => |blob_ids|
            send_tuple(stream, .{Status.okay, blob_ids}),
        .blob_info => |blob_size|
            send_tuple(stream, .{Status.okay, blob_size}),
        .blob_load => |blob|
            send_tuple(stream, .{Status.okay, blob}),
        .blob_save => |status, blob_id|
            send_tuple(stream, .{status, blob_id}),
        .store_create, .store_destroy, .blob_delete =>
            send(stream, Status.okay),
    };
}

fn error_to_status(err: ty.Err) Status {
    return switch (err) {
        ty.Err.Exists => Status.exists,
        ty.Err.NotFound => Status.not_found,
        ty.Err.NoSpace => Status.no_space,
        ty.Err.BadArgument => Status.bad_argument,
        ty.Err.Internal => Status.internal_error,
    };
}

fn send(stream: *Writer, obj: anytype) ReaderWriterError!void {
    return switch (@TypeOf(obj)) {
        ty.StoreIds => send_store_ids(stream, obj),
        ty.StoreId => send_store_id(stream, obj),
        ty.BlobIds => send_blob_ids(stream, obj),
        ty.BlobStream => send_blob_stream(stream, obj),
        GreetCode, CallTag, Status => send_enum(stream, obj),
        u16, u64 => stream.writeInt(@TypeOf(obj), obj, .little),
        else => unreachable,
    };
}

fn send_store_ids(stream: *Writer, store_ids: ty.StoreIds) !void {
    const size: ArraySize = store_ids.len;
    try send(stream, size);
    for (store_ids) |store_id| {
        try send(stream, store_id);
    }
}

fn send_store_id(stream: *Writer, store_id: ty.StoreId) !void {
    const size: StoreIdSize = @intCast(store_id.id.len);
    try send_tuple(stream, .{size, store_id.id});
}

fn send_blob_ids(stream: *Writer, blob_ids: ty.BlobIds) !void {
    const size: ArraySize = blob_ids.len;
    try send(stream, size);
    try send_array(stream, std.mem.sliceAsBytes(blob_ids));
}

fn send_blob_stream(stream: *Writer, blob_in: ty.BlobStream) !void {
    const size: ArraySize = blob_in.bytes_remain;
    try send(stream, size);
    try blob_in.stream.streamExact(stream, size);
}

fn send_enum(stream: *Writer, enum_val: anytype) !void {
    const tag = @intFromEnum(enum_val);
    try stream.writeInt(@TypeOf(tag), tag, .little);
}

fn send_tuple(stream: *Writer, tuple: anytype) !void {
    inline for (tuple) |item| {
        try send(stream, item);
    }
}

fn send_array(stream: *Writer, array: anytype) !void {
    const ElemType = std.meta.Child(@TypeOf(array));
    return stream.writeSliceEndian(ElemType, array, .little);
}


pub fn recv_open_door(stream: *Reader) !void {
    const open_door = try recv(stream, ty.Code);
    const proto_version = try recv(stream, ProtoVersion);
    if (open_door != CODE_OPEN_DOOR or proto_version != PROTO_VERSION) {
        return ty.Err.BadArgument;
    }
}

pub fn recv_welcome(stream: *Reader) !void {
    const code = try recv(stream, GreetCode);
    switch (code) {
        .welcome => {
            return;
        },
        .not_welcome => {
            const proto_version = try recv(stream, ProtoVersion);
            funcs.debug("recv_welcome: server says we are not welcome; "
                        ++ "client: v{d}, server: v{d}",
                        .{PROTO_VERSION, proto_version});
            return ty.Err.BadArgument;
        },
    }
}

pub fn recv_request(stream: *Reader) !Request {
    const code = try recv(stream, ty.Code);
    return switch (code) {
        CODE_BYE => .bye,
        else => .{.call =
            try recv_call_request(stream, try parse_enum_tag(CallTag, code))},
    };
}

fn recv_call_request(stream: *Reader, call_tag: CallTag) !Request.Call {
    return switch(call_tag) {
        .store_list =>
            .store_list,
        .store_create =>
            .{.store_create = try recv(stream, ty.StoreId)},
        .store_destroy =>
            .{.store_destroy = try recv(stream, ty.StoreId)},
        .blob_hash =>
            .{.blob_hash = try recv(stream, ty.BlobStream)},
        .blob_list =>
            .{.blob_list = try recv(stream, ty.StoreId)},
        .blob_info =>
            .{.blob_info = try recv(stream, Request.StoreIdBlobId)},
        .blob_load =>
            .{.blob_load = try recv(stream, Request.StoreIdBlobId)},
        .blob_save =>
            .{.blob_save = try recv(stream, Request.StoreIdBlob)},
        .blob_delete =>
            .{.blob_delete = try recv(stream, Request.StoreIdBlobId)},
    };
}

pub fn recv_response(stream: *Reader, call_tag: CallTag) !Response {
    const status = try recv(stream, Status);
    const Pair = funcs.pairGen(@TypeOf(status), @TypeOf(call_tag));
    return switch (Pair.make(status, call_tag)) {
        Pair.make(.okay, .store_list) =>
            .{.call = .{.store_list = try recv(stream, ty.StoreIds)}},
        Pair.make(.okay, .store_create) =>
            .{.call = .store_create},
        Pair.make(.okay, .store_destroy) =>
            .{.call = .store_destroy},
        Pair.make(.okay, .blob_hash) =>
            .{.call = .{.blob_hash = try recv(stream, ty.BlobId)}},
        Pair.make(.okay, .blob_list) =>
            .{.call = .{.blob_list = try recv(stream, ty.BlobIds)}},
        Pair.make(.okay, .blob_info) =>
            .{.call = .{.blob_info = try recv(stream, ty.BlobSize)}},
        Pair.make(.okay, .blob_load) =>
            .{.call = .{.blob_load = try recv(stream, ty.BlobStream)}},
        Pair.make(.okay, .blob_save) =>
            .{.call = .{.blob_save =
                .{.status = .created, .blob_id = try recv(stream, ty.BlobId)}}},
        Pair.make(.exists, .blob_save) =>
            .{.call = .{.blob_save =
                .{.status = .exists, .blob_id = try recv(stream, ty.BlobId)}}},
        Pair.make(.okay, .blob_delete) =>
            .{.call = .blob_delete},
        else =>
            .{.err = status_to_error(status)},
    };
}

fn status_to_error(status: Status) ty.Err {
    return switch (status) {
        Status.exists => ty.Err.Exists,
        Status.not_found => ty.Err.NotFound,
        Status.no_space => ty.Err.NoSpace,
        Status.bad_argument => ty.Err.BadArgument,
        Status.internal_error => ty.Err.Internal,
        Status.okay => {
            funcs.debug("status_to_error: 'Okay' is not an error!\n", .{});
            return ty.Err.Internal;
        }
    };
}

fn recv(stream: *Reader, ObjType: type) !ObjType {
    return switch (ObjType) {
        Request.StoreIdBlobId, Request.StoreIdBlob, Response.SaveStatusBlobId =>
            try recv_tuple(stream, ObjType),
        ty.StoreIds =>
            try recv_store_ids(stream),
        ty.StoreId =>
            try recv_store_id(stream),
        ty.BlobIds =>
            try recv_blob_ids(stream),
        ty.BlobId =>
            try recv_blob_id(stream),
        ty.BlobStream =>
            try recv_blob_stream(stream),
        GreetCode, CallTag, Status =>
            try recv_enum(stream, ObjType),
        u16, u64 =>
            try stream.takeInt(ObjType, .little),
        else =>
            unreachable,
    };
}

fn recv_store_ids(stream: *Reader) !ty.StoreIds {
    const array_size = try recv(stream, ArraySize);
    const store_ids = try funcs.allocator.alloc(ty.StoreId, array_size);
    for (store_ids) |*store_id| {
        store_id.* = try recv_store_id(stream);
    }
    return store_ids;
}

fn recv_store_id(stream: *Reader) !ty.StoreId {
    const size = try recv(stream, StoreIdSize);
    const store_id = try funcs.allocator.alloc(u8, size);
    try recv_array(stream, u8, store_id);
    return .{
        .id = store_id,
    };
}

fn recv_blob_ids(stream: *Reader) !ty.BlobIds {
    const array_size = try recv(stream, ArraySize);
    const blob_ids = try funcs.allocator.alloc(ty.BlobId, array_size);
    try recv_array(stream, u8, std.mem.sliceAsBytes(blob_ids));
    return blob_ids;
}

fn recv_blob_id(stream: *Reader) !ty.BlobId {
    var blob_id: ty.BlobId = undefined;
    try recv_array(stream, u8, &blob_id);
    return blob_id;
}

fn recv_blob_stream(stream: *Reader) !ty.BlobStream {
    const array_size = try recv(stream, ArraySize);
    return .{
        .bytes_remain = array_size,
        .stream = stream,
    };
}

fn recv_enum(stream: *Reader, Enum: type) !Enum {
    const Tag = @typeInfo(Enum).@"enum".tag_type;
    const tag = try stream.takeInt(Tag, .little);
    return parse_enum_tag(Enum, tag);
}

fn parse_enum_tag(Enum: type, tag: anytype) !Enum {
    return if (std.enums.fromInt(Enum, tag)) |val| val else {
        funcs.debug("parse_enum_tag: {s} is not a {s} value.",
                    .{@typeName(Enum), ty.decode8(tag)});
        return ty.Err.BadArgument;
    };
}

fn recv_tuple(stream: *Reader, comptime Tuple: anytype) !Tuple {
    var out: Tuple = undefined;
    inline for (std.meta.fields(Tuple)) |field| {
        @field(out, field.name) = try recv(stream, field.type);
    }
    return out;
}

fn recv_array(stream: *Reader, ElemType: type, array: []ElemType) !void {
    return stream.readSliceEndian(ElemType, array, .little);
}

test "whatever" {
    var in = Reader.fixed("");
    var out = Writer.fixed("");
    const request = recv_request(&in) catch .store_list;
    _ = send_request(&out, request) catch void;
    const response = recv_response(&in, request) catch .store_create;
    _ = send_response(&out, response) catch void;
}
