const std = @import("std");

const ty = @import("types.zig");
const funcs = @import("funcs.zig");

const ReaderWriterError = ty.Writer.Error || ty.Reader.Error;

const ProtoVersion = u16;
const StoreIdSize = u16;
const ArraySize = u64;

const PROTO_VERSION: ProtoVersion = 1;
const CODE_OPEN_DOOR: ty.Code = ty.code("OpenDoor");

const GreetCode = enum(ty.Code) {
    welcome = ty.code("Welcome!"),
    not_welcome = ty.code("Go away!"),
};

const RequestCode = enum(ty.Code) {
    store_list = ty.code("storlist"),
    store_create = ty.code("storenew"),
    store_destroy = ty.code("storedel"),
    blob_hash = ty.code("blobhash"),

    blob_list = ty.code("bloblist"),
    blob_info = ty.code("blobinfo"),
    blob_load = ty.code("blobload"),
    blob_save = ty.code("blobsave"),
    blob_delete = ty.code("blobdrop"),

    bye = ty.code("Goodbye!"),
};

pub fn send_open_door(stream: *ty.Writer) !void {
    try send_tuple(stream, .{CODE_OPEN_DOOR, PROTO_VERSION});
}

pub fn send_welcome(stream: *ty.Writer) !void {
    try send(stream, GreetCode.welcome);
}

pub fn send_not_welcome(stream: *ty.Writer) !void {
    try send_tuple(stream, .{GreetCode.not_welcome, PROTO_VERSION});
}

pub fn send_request(stream: *ty.Writer, request: ty.Request) !void {
    try switch (request) {
        .store_list =>
            send(stream, RequestCode.store_list),
        .store_create => |store_id|
            send_tuple(stream, .{RequestCode.store_create, store_id}),
        .store_destroy => |store_id|
            send_tuple(stream, .{RequestCode.store_destroy, store_id}),
        .blob_hash => |blob|
            send_tuple(stream, .{RequestCode.blob_hash, blob}),
        .blob_list => |store_id|
            send_tuple(stream, .{RequestCode.blob_list, store_id}),
        .blob_info => |store_id, blob_id|
            send_tuple(stream, .{RequestCode.blob_info, store_id, blob_id}),
        .blob_load => |store_id, blob_id|
            send_tuple(stream, .{RequestCode.blob_load, store_id, blob_id}),
        .blob_save => |store_id, blob|
            send_tuple(stream, .{RequestCode.blob_save, store_id, blob}),
        .blob_delete => |store_id, blob_id|
            send_tuple(stream, .{RequestCode.blob_delete, store_id, blob_id}),
        .bye =>
            send(stream, RequestCode.bye),
    };
}

pub fn send_response(stream: *ty.Writer, response: ty.Response) !void {
    try switch (response) {
        .store_list => |store_ids|
            send_tuple(stream, .{ty.Status.okay, store_ids}),
        .blob_hash => |blob_id|
            send_tuple(stream, .{ty.Status.okay, blob_id}),
        .blob_list => |blob_ids|
            send_tuple(stream, .{ty.Status.okay, blob_ids}),
        .blob_info => |blob_size|
            send_tuple(stream, .{ty.Status.okay, blob_size}),
        .blob_load => |blob|
            send_tuple(stream, .{ty.Status.okay, blob}),
        .blob_save => |status, blob_id|
            send_tuple(stream, .{status, blob_id}),
        .store_create, .store_destroy, .blob_delete =>
            send(stream, ty.Status.okay),
        .err => |err|
            send(stream, error_to_status(err)),
    };
}

fn error_to_status(err: ty.Err) ty.Status {
    return switch (err) {
        ty.Err.Exists => ty.Status.exists,
        ty.Err.NotFound => ty.Status.not_found,
        ty.Err.NoSpace => ty.Status.no_space,
        ty.Err.BadArgument => ty.Status.bad_argument,
        ty.Err.Internal => ty.Status.internal_error,
    };
}

fn send_store_ids(stream: *ty.Writer, store_ids: ty.StoreIds) !void {
    const size: ArraySize = store_ids.len;
    try send(stream, size);
    for (store_ids) |store_id| {
        try send(stream, store_id);
    }
}

fn send_store_id(stream: *ty.Writer, store_id: ty.StoreId) !void {
    const size: StoreIdSize = @intCast(store_id.id.len);
    try send_tuple(stream, .{size, store_id.id});
}

fn send_blob_ids(stream: *ty.Writer, blob_ids: ty.BlobIds) !void {
    const size: ArraySize = blob_ids.len;
    try send(stream, size);
    try send_array(stream, std.mem.sliceAsBytes(blob_ids));
}

fn send_blob_stream(stream: *ty.Writer, blob_in: ty.BlobStream) !void {
    const size: ArraySize = blob_in.bytes_remain;
    try send(stream, size);
    try blob_in.stream.streamExact(stream, size);
}

fn send_enum(stream: *ty.Writer, enum_val: anytype) !void {
    const tag = @intFromEnum(enum_val);
    try stream.writeInt(@TypeOf(tag), tag, .little);
}

fn send_tuple(stream: *ty.Writer, tuple: anytype) !void {
    inline for (tuple) |item| {
        try send(stream, item);
    }
}

fn send(stream: *ty.Writer, obj: anytype) ReaderWriterError!void {
    return switch (@TypeOf(obj)) {
        ty.StoreIds => send_store_ids(stream, obj),
        ty.StoreId => send_store_id(stream, obj),
        ty.BlobIds => send_blob_ids(stream, obj),
        ty.BlobStream => send_blob_stream(stream, obj),
        RequestCode, ty.Status => send_enum(stream, obj),
        u16, u64 => stream.writeInt(@TypeOf(obj), obj, .little),
        else => unreachable,
    };
}

fn send_array(stream: *ty.Writer, array: anytype) !void {
    const ElemType = std.meta.Child(@TypeOf(array));
    return stream.writeSliceEndian(ElemType, array, .little);
}


pub fn recv_open_door(stream: *ty.Reader) !void {
    const open_door = try recv(stream, ty.Code);
    const proto_version = try recv(stream, ProtoVersion);
    if (open_door != CODE_OPEN_DOOR or proto_version != PROTO_VERSION) {
        return ty.Err.BadArgument;
    }
}

pub fn recv_welcome(stream: *ty.Reader) !void {
    const code = recv(stream, ty.Code);
    switch (code) {
        GreetCode.Welcome => {
            return;
        },
        GreetCode.NotWelcome => {
            const proto_version = recv(stream, ProtoVersion);
            funcs.debug("recv_welcome: server says we are not welcome; "
                        ++ "client: v{d}, server: v{d}",
                        .{PROTO_VERSION, proto_version});
            return ty.Err.BadArgument;
        },
        else => {
            funcs.debug("recv_welcome: unexpected response: {s}",
                        .{ty.decode(code)});
            return ty.Err.InternalError;
        },
    }
}

pub fn recv_request(stream: *ty.Reader) !ty.Request {
    const code = try recv(stream, RequestCode);
    return switch(code) {
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
            .{.blob_info = try recv(stream, ty.Request.StoreIdBlobId)},
        .blob_load =>
            .{.blob_load = try recv(stream, ty.Request.StoreIdBlobId)},
        .blob_save =>
            .{.blob_save = try recv(stream, ty.Request.StoreIdBlob)},
        .blob_delete =>
            .{.blob_delete = try recv(stream, ty.Request.StoreIdBlobId)},
        .bye =>
            .bye,
    };
}

pub fn recv_response(stream: *ty.Reader, context: ty.RequestTag) !ty.Response {
    const status = try recv(stream, ty.Status);
    const Pair = pair_gen(ty.Status, ty.RequestTag);
    return switch (Pair.make(status, context)) {
        Pair.make(.okay, .store_list) =>
            .{.store_list = try recv(stream, ty.StoreIds)},
        Pair.make(.okay, .store_create) =>
            .store_create,
        Pair.make(.okay, .store_destroy) =>
            .store_destroy,
        Pair.make(.okay, .blob_hash) =>
            .{.blob_hash = try recv(stream, ty.BlobId)},
        Pair.make(.okay, .blob_list) =>
            .{.blob_list = try recv(stream, ty.BlobIds)},
        Pair.make(.okay, .blob_info) =>
            .{.blob_info = try recv(stream, ty.BlobSize)},
        Pair.make(.okay, .blob_load) =>
            .{.blob_load = try recv(stream, ty.BlobStream)},
        Pair.make(.okay, .blob_save) =>
            .{.blob_save = .{.status = .created,
                             .blob_id = try recv(stream, ty.BlobId)}},
        Pair.make(.exists, .blob_save) =>
            .{.blob_save = .{.status = .exists,
                             .blob_id = try recv(stream, ty.BlobId)}},
        Pair.make(.okay, .blob_delete) =>
            .blob_delete,
        else =>
            .{.err = status_to_error(status)},
    };
}

fn pair_gen(A: type, B: type) type {
    const PairStruct = packed struct {
        a: A,
        b: B,
    };
    const Pair = struct {
        fn make(a: A, b: B) PairStruct {
            return .{.a = a, .b = b};
        }
    };
    return Pair;
}

fn status_to_error(status: ty.Status) ty.Err {
    return switch (status) {
        ty.Status.exists => ty.Err.Exists,
        ty.Status.not_found => ty.Err.NotFound,
        ty.Status.no_space => ty.Err.NoSpace,
        ty.Status.bad_argument => ty.Err.BadArgument,
        ty.Status.internal_error => ty.Err.Internal,
        ty.Status.okay => {
            funcs.debug("status_to_error: 'Okay' is not an error!\n", .{});
            return ty.Err.Internal;
        }
    };
}

fn recv(stream: *ty.Reader, ObjType: type) !ObjType {
    return switch (ObjType) {
        ty.Request.StoreIdBlobId, ty.Request.StoreIdBlob,
                ty.Response.SaveStatusBlobId =>
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
        RequestCode, ty.Status =>
            try recv_enum(stream, ObjType),
        u16, u64 =>
            try stream.takeInt(ObjType, .little),
        else =>
            unreachable,
    };
}

fn recv_store_ids(stream: *ty.Reader) !ty.StoreIds {
    const array_size = try recv(stream, ArraySize);
    const store_ids = try funcs.allocator.alloc(ty.StoreId, array_size);
    for (store_ids) |*store_id| {
        store_id.* = try recv_store_id(stream);
    }
    return store_ids;
}

fn recv_store_id(stream: *ty.Reader) !ty.StoreId {
    const size = try recv(stream, StoreIdSize);
    const store_id = try funcs.allocator.alloc(u8, size);
    try recv_array(stream, u8, store_id);
    return .{
        .id = store_id,
    };
}

fn recv_blob_ids(stream: *ty.Reader) !ty.BlobIds {
    const array_size = try recv(stream, ArraySize);
    const blob_ids = try funcs.allocator.alloc(ty.BlobId, array_size);
    try recv_array(stream, u8, std.mem.sliceAsBytes(blob_ids));
    return blob_ids;
}

fn recv_blob_id(stream: *ty.Reader) !ty.BlobId {
    var blob_id: ty.BlobId = undefined;
    try recv_array(stream, u8, &blob_id);
    return blob_id;
}

fn recv_blob_stream(stream: *ty.Reader) !ty.BlobStream {
    const array_size = try recv(stream, ArraySize);
    return .{
        .bytes_remain = array_size,
        .stream = stream,
    };
}

fn recv_enum(stream: *ty.Reader, Enum: type) !Enum {
    const Tag = @typeInfo(Enum).@"enum".tag_type;
    const tag = try stream.takeInt(Tag, .little);
    return @enumFromInt(tag);
}

fn recv_tuple(stream: *ty.Reader, comptime Tuple: anytype) !Tuple {
    var out: Tuple = undefined;
    inline for (std.meta.fields(Tuple)) |field| {
        @field(out, field.name) = try recv(stream, field.type);
    }
    return out;
}

fn recv_array(stream: *ty.Reader, ElemType: type, array: []ElemType) !void {
    return stream.readSliceEndian(ElemType, array, .little);
}

test "whatever" {
    var in = ty.Reader.fixed("");
    var out = ty.Writer.fixed("");
    const request = recv_request(&in) catch .store_list;
    _ = send_request(&out, request) catch void;
    const response = recv_response(&in, request) catch .store_create;
    _ = send_response(&out, response) catch void;
}
