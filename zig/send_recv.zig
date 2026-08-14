const std = @import("std");

const ty = @import("types.zig");
const funcs = @import("funcs.zig");

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

fn send_open_door(stream: ty.Writer) !void {
    send_tuple(stream, .{CODE_OPEN_DOOR, PROTO_VERSION});
}

fn send_welcome(stream: ty.Writer) !void {
    send(stream, GreetCode.welcome);
}

pub fn send_request(stream: ty.Writer, request: ty.Request) !void {
    return switch (request) {
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

pub fn send_response(stream: ty.Writer, response: ty.Response) !void {
    return switch (response) {
        .status => |status|
            send(stream, status),
        .store_list => |store_ids|
            send_tuple(stream, .{ty.Status.Okay, store_ids}),
        .blob_hash => |blob_id|
            send_tuple(stream, .{ty.Status.Okay, blob_id}),
        .blob_list => |blob_ids|
            send_tuple(stream, .{ty.Status.Okay, blob_ids}),
        .blob_info => |blob_size|
            send_tuple(stream, .{ty.Status.Okay, blob_size}),
        .blob_load => |blob|
            send_tuple(stream, .{ty.Status.Okay, blob}),
        .blob_save => |status, blob_id|
            send_tuple(stream, .{status, blob_id}),
    };
}

fn send_store_ids(stream: ty.Writer, store_ids: ty.StoreIds) !void {
    try send(stream, @as(ArraySize, store_ids.len));
    for (store_ids) |store_id| {
        try send(stream, store_id);
    }
}

fn send_store_id(stream: ty.Writer, store_id: ty.StoreId) !void {
    const size: StoreIdSize = store_id.len;
    return send_tuple(stream, .{size, store_id});
}

fn send_blob_ids(stream: ty.Writer, blob_ids: ty.BlobIds) !void {
    const size: ArraySize = blob_ids.len;
    return send_tuple(stream, .{size, blob_ids});
}

fn send_blob(stream: ty.Writer, blob: ty.Blob) !void {
    const size: ArraySize = blob.len;
    return send_tuple(stream, .{size, blob});
}

fn send_tuple(stream: ty.Writer, tuple: anytype) !void {
    inline for (tuple) |item| {
        try send(stream, item);
    }
}

fn send(stream: ty.Writer, obj: anytype) !void {
    return switch (@TypeOf(obj)) {
        ty.StoreIds => send_store_ids(stream, obj),
        ty.StoreId => send_store_id(stream, obj),
        ty.BlobIds => send_blob_ids(stream, obj),
        ty.Blob => send_blob(stream, obj),
        u16, u64 => stream.writeInt(@TypeOf(obj), obj, .little),
    };
}

fn send_array(stream: ty.Writer, array: anytype) !void {
    const ElemType = meta.Child(@TypeOf(array));
    return stream.writeSliceEndian(ElemType, array, .little);
}


fn recv_request(stream: ty.Reader) !ty.Request {
    const code = try recv(stream, RequestCode);
    return switch(code) {
        .store_list =>
            .{.store_list},
        .store_create =>
            .{.store_create = try recv(stream, ty.StoreId)},
        .store_destroy =>
            .{.store_destroy = try recv(stream, ty.StoreId)},
        .blob_hash =>
            .{.blob_hash = try recv(stream, ty.Blob)},
        .blob_list =>
            .{.blob_list = try recv(stream, ty.StoreId)},
        .blob_info =>
            .{.blob_info = try recv_tuple(stream, .{ty.StoreId, ty.BlobId})},
        .blob_load =>
            .{.blob_load = try recv_tuple(stream, .{ty.StoreId, ty.BlobId})},
        .blob_save =>
            .{.blob_save = try recv_tuple(stream, .{ty.StoreId, ty.Blob})},
        .blob_delete =>
            .{.blob_delete = try recv_tuple(stream, .{ty.StoreId, ty.BlobId})},
        .bye =>
            .{.bye},
    };
}

fn recv_response(stream: ty.Reader, request_context: ty.Request) !ty.Response {
    const status = recv(stream, ty.Status);
    switch (request_context) {
        .store_list => .{.store_list = .{try recv(stream, ty.StoreIds)}},
        .blob_hash => .{.blob_hash = .{try recv(stream, ty.BlobId)}},
        .blob_list => .{.blob_list = .{try recv(stream, ty.BlobIds)}},
        .blob_info => .{.blob_info = .{try recv(stream, ty.BlobSize)}},
        .blob_load => .{.blob_load = .{try recv(stream, ty.Blob)}},
        .blob_save => switch (status) {
            .okay => .{.blob_save = .{.created, try recv(stream, ty.BlobId)}},
            .exists => .{.blob_save = .{.exists, try recv(stream, ty.BlobId)}},
            else => .{.status = status},
        },
        .status => .{.status = status},
    }
}

fn recv_store_ids(stream: ty.Reader) !ty.StoreIds {
    const array_size = try recv(stream, ArraySize);
    const store_ids = funcs.alloc(ty.StoreId, array_size);
    for (&store_ids) |*store_id| {
        store_id.* = try recv_store_id(stream);
    }
    return store_ids;
}

fn recv_store_id(stream: ty.Reader) !ty.StoreId {
    const size = try recv(stream, StoreIdSize);
    const store_id = funcs.alloc(u8, size);
    try recv_array(stream, store_id);
    return store_id;
}

fn recv_blob_ids(stream: ty.Reader) !ty.BlobIds {
    const array_size = try recv(stream, ArraySize);
    const blob_ids = funcs.alloc(ty.BlobId, array_size);
    for (&blob_ids) |*blob_id| {
        blob_id.* = try recv(stream, ty.BlobId);
    }
    return blob_ids;
}

fn recv_blob(stream: ty.Reader) !ty.Blob {
    const array_size = try recv(stream, ArraySize);
    const blob = funcs.alloc(u8, array_size);
    try recv_array(stream, blob);
    return blob;
}

fn recv_tuple(stream: ty.Writer, types: anytype) types {
    const out = .{};
    inline for (types) |Type| {
        out = out ++ .{try recv(stream, Type)};
    }
    return out;
}

fn recv(stream: ty.Reader, ObjType: type) !ObjType {
    return switch (ObjType) {
        ty.StoreIds => recv_store_ids(stream),
        ty.StoreId => recv_store_id(stream),
        ty.BlobIds => recv_blob_ids(stream),
        ty.Blob => recv_blob(stream),
        u16, u64, ty.BlobId => stream.readInt(ObjType, .little),
    };
}

fn recv_array(stream: ty.Writer, array: anytype) !void {
    const ElemType = std.meta.Child(@TypeOf(array));
    return stream.readSliceEndian(ElemType, array, .little);
}
