const std = @import("std");
const File = std.Io.File;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const ty = @import("types.zig");
const CallTag = ty.CallTag;
const Request = ty.Request;
const Response = ty.Response;

const mem = @import("mem.zig");
const funcs = @import("funcs.zig");
const debug = @import("debug.zig");

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

pub fn send_open_door(out: *Writer) !void {
    try send_tuple(out, .{CODE_OPEN_DOOR, PROTO_VERSION});
    try out.flush();
}

pub fn send_welcome(out: *Writer) !void {
    try send(out, GreetCode.welcome);
    try out.flush();
}

pub fn send_not_welcome(out: *Writer) !void {
    try send_tuple(out, .{GreetCode.not_welcome, PROTO_VERSION});
    try out.flush();
}

pub fn send_request(out: *Writer, request: Request) !void {
    try switch (request) {
        .call => |call| send_call_request(out, call),
        .bye => send(out, CODE_BYE),
    };
    try out.flush();
}

fn send_call_request(out: *Writer, call: Request.Call) !void {
    try switch (call) {
        .store_list =>
            send(out, CallTag.store_list),
        .store_create => |store_id|
            send_tuple(out, .{CallTag.store_create, store_id}),
        .store_destroy => |store_id|
            send_tuple(out, .{CallTag.store_destroy, store_id}),
        .blob_hash => |blob|
            send_tuple(out, .{CallTag.blob_hash, blob}),
        .blob_list => |store_id|
            send_tuple(out, .{CallTag.blob_list, store_id}),
        .blob_info => |args|
            send_tuple(out, .{CallTag.blob_info, args.store_id, args.blob_id}),
        .blob_load => |args|
            send_tuple(out, .{CallTag.blob_load, args.store_id, args.blob_id}),
        .blob_save => |args|
            send_tuple(out, .{CallTag.blob_save, args.store_id, args.blob}),
        .blob_delete => |args|
            send_tuple(out, .{CallTag.blob_delete, args.store_id, args.blob_id}),
    };
}

pub fn send_response(out: *Writer, response: Response) !void {
    try switch (response) {
        .call => |call| send_call_response(out, call),
        .err => |err| send(out, error_to_status(err)),
    };
    try out.flush();
}

fn send_call_response(out: *Writer, call: Response.Call) !void {
    try switch (call) {
        .store_list => |store_ids|
            send_tuple(out, .{Status.okay, store_ids}),
        .blob_hash => |blob_id|
            send_tuple(out, .{Status.okay, blob_id}),
        .blob_list => |blob_ids|
            send_tuple(out, .{Status.okay, blob_ids}),
        .blob_info => |blob_size|
            send_tuple(out, .{Status.okay, blob_size}),
        .blob_load => |blob|
            send_tuple(out, .{Status.okay, blob}),
        .blob_save => |result|
            send_tuple(out, .{result.status, result.blob_id}),
        .store_create, .store_destroy, .blob_delete =>
            send(out, Status.okay),
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

fn save_status_to_status(status: ty.Response.SaveStatus) Status {
    return switch (status) {
        .created => Status.okay,
        .exists => Status.exists,
    };
}

fn send(out: *Writer, obj: anytype) SendError!void {
    return switch (@TypeOf(obj)) {
        ty.StoreIds => send_store_ids(out, obj),
        ty.StoreId => send_store_id(out, obj),
        ty.BlobId => send_array(out, @as([]const u8, &obj)),
        ty.BlobIds => send_blob_ids(out, obj),
        ty.Blob => send_blob(out, obj),
        []const u8 => send_array(out, obj),
        GreetCode, CallTag, Status => send_enum(out, obj),
        Response.SaveStatus => send_enum(out, save_status_to_status(obj)),
        u16, u64 => out.writeInt(@TypeOf(obj), obj, .little),
        else => {
            funcs.debug("send: {any} is not supported.\n", .{@TypeOf(obj)});
            return ty.Err.Internal;
        },
    };
}

const SendError = ty.Err || Reader.Error || Writer.Error
                || File.MemoryMap.CreateError || File.StatError;

fn send_store_ids(out: *Writer, store_ids: ty.StoreIds) !void {
    const size: ArraySize = store_ids.len;
    try send(out, size);
    for (store_ids) |store_id| {
        try send(out, store_id);
    }
}

fn send_store_id(out: *Writer, store_id: ty.StoreId) !void {
    const size: StoreIdSize = @intCast(store_id.id.len);
    try send_tuple(out, .{size, store_id.id});
}

fn send_blob_ids(out: *Writer, blob_ids: ty.BlobIds) !void {
    const size: ArraySize = blob_ids.len;
    try send(out, size);
    try send_array(out, std.mem.sliceAsBytes(blob_ids));
}

fn send_blob(out: *Writer, blob: ty.Blob) !void {
    switch (blob) {
        .stream => |in| {
            const size: ArraySize = in.bytes_left;
            try send(out, size);
            try in.reader.streamExact(out, size);
        },
        .file => |file| {
            const size: ArraySize = try file.file.length(file.io);
            const mmap_opts: File.MemoryMap.CreateOptions = .{
                .len = size,
                .protection = .{.read = true, .write = false},
            };
            var mem_map = try file.file.createMemoryMap(file.io, mmap_opts);
            defer mem_map.destroy(file.io);
            try send(out, size);
            try send_array(out, mem_map.memory);
        },
        .memory => |bytes| {
            try send(out, @as(ArraySize, bytes.len));
            try send_array(out, bytes);
        },
    }
}

fn send_enum(out: *Writer, enum_val: anytype) !void {
    const tag = @intFromEnum(enum_val);
    try out.writeInt(@TypeOf(tag), tag, .little);
}

fn send_tuple(out: *Writer, tuple: anytype) !void {
    inline for (tuple) |item| {
        try send(out, item);
    }
}

fn send_array(out: *Writer, array: anytype) !void {
    const ElemType = std.meta.Child(@TypeOf(array));
    return out.writeSliceEndian(ElemType, array, .little);
}


pub fn recv_open_door(in: *Reader) !void {
    const open_door = try recv(in, ty.Code);
    const proto_version = try recv(in, ProtoVersion);
    if (open_door != CODE_OPEN_DOOR or proto_version != PROTO_VERSION) {
        return ty.Err.BadArgument;
    }
}

pub fn recv_welcome(in: *Reader) !void {
    const code = try recv(in, GreetCode);
    return switch (code) {
        .welcome => {},
        .not_welcome => out: {
            const proto_version = try recv(in, ProtoVersion);
            funcs.debug("recv_welcome: server says we are not welcome; "
                        ++ "client: v{d}, server: v{d}",
                        .{PROTO_VERSION, proto_version});
            break :out ty.Err.BadArgument;
        },
    };
}

pub fn recv_request(in: *Reader) !Request {
    const code = try recv(in, ty.Code);
    const request: Request = switch (code) {
        CODE_BYE => .bye,
        else => .{.call =
            try recv_call_request(in, try parse_enum_tag(CallTag, code))},
    };
    return request;
}

fn recv_call_request(in: *Reader, call_tag: CallTag) !Request.Call {
    return switch(call_tag) {
        .store_list =>
            .store_list,
        .store_create =>
            .{.store_create = try recv(in, ty.StoreId)},
        .store_destroy =>
            .{.store_destroy = try recv(in, ty.StoreId)},
        .blob_hash =>
            .{.blob_hash = try recv(in, ty.Blob)},
        .blob_list =>
            .{.blob_list = try recv(in, ty.StoreId)},
        .blob_info =>
            .{.blob_info = try recv(in, Request.StoreIdBlobId)},
        .blob_load =>
            .{.blob_load = try recv(in, Request.StoreIdBlobId)},
        .blob_save =>
            .{.blob_save = try recv(in, Request.StoreIdBlob)},
        .blob_delete =>
            .{.blob_delete = try recv(in, Request.StoreIdBlobId)},
    };
}

pub fn recv_response(in: *Reader, call_tag: CallTag) !Response {
    const status = try recv(in, Status);
    const Pair = funcs.pairGen(@TypeOf(status), @TypeOf(call_tag));
    const response: Response = switch (Pair.make(status, call_tag)) {
        Pair.make(.okay, .store_list) =>
            .{.call = .{.store_list = try recv(in, ty.StoreIds)}},
        Pair.make(.okay, .store_create) =>
            .{.call = .store_create},
        Pair.make(.okay, .store_destroy) =>
            .{.call = .store_destroy},
        Pair.make(.okay, .blob_hash) =>
            .{.call = .{.blob_hash = try recv(in, ty.BlobId)}},
        Pair.make(.okay, .blob_list) =>
            .{.call = .{.blob_list = try recv(in, ty.BlobIds)}},
        Pair.make(.okay, .blob_info) =>
            .{.call = .{.blob_info = try recv(in, ty.Blob.Size)}},
        Pair.make(.okay, .blob_load) =>
            .{.call = .{.blob_load = try recv(in, ty.Blob)}},
        Pair.make(.okay, .blob_save) =>
            .{.call = .{.blob_save = .init(.created, try recv(in, ty.BlobId))}},
        Pair.make(.exists, .blob_save) =>
            .{.call = .{.blob_save = .init(.exists, try recv(in, ty.BlobId))}},
        Pair.make(.okay, .blob_delete) =>
            .{.call = .blob_delete},
        else =>
            .{.err = status_to_error(status)},
    };
    return response;
}

fn status_to_error(status: Status) ty.Err {
    return switch (status) {
        Status.exists => ty.Err.Exists,
        Status.not_found => ty.Err.NotFound,
        Status.no_space => ty.Err.NoSpace,
        Status.bad_argument => ty.Err.BadArgument,
        Status.internal_error => ty.Err.Internal,
        Status.okay => out: {
            funcs.debug("status_to_error: 'Okay' is not an error!\n", .{});
            break :out ty.Err.Internal;
        }
    };
}

fn recv(in: *Reader, ObjType: type) !ObjType {
    return switch (ObjType) {
        Request.StoreIdBlobId, Request.StoreIdBlob, Response.SaveStatusBlobId =>
            try recv_tuple(in, ObjType),
        ty.StoreIds =>
            try recv_store_ids(in),
        ty.StoreId =>
            try recv_store_id(in),
        ty.BlobIds =>
            try recv_blob_ids(in),
        ty.BlobId =>
            try recv_blob_id(in),
        ty.Blob =>
            try recv_blob(in),
        GreetCode, CallTag, Status =>
            try recv_enum(in, ObjType),
        u16, u64 =>
            try in.takeInt(ObjType, .little),
        else => {
            funcs.debug("recv: {any} is not supported.\n", .{ObjType});
            return ty.Err.Internal;
        },
    };
}

fn recv_store_ids(in: *Reader) !ty.StoreIds {
    const array_size = try recv(in, ArraySize);
    const store_ids = try mem.alloc(ty.StoreId, array_size);
    for (store_ids) |*store_id| {
        store_id.* = try recv_store_id(in);
    }
    return store_ids;
}

fn recv_store_id(in: *Reader) !ty.StoreId {
    const size = try recv(in, StoreIdSize);
    const store_id = try mem.alloc(u8, size);
    try recv_array(in, u8, store_id);
    return .init(store_id);
}

fn recv_blob_ids(in: *Reader) !ty.BlobIds {
    const array_size = try recv(in, ArraySize);
    const blob_ids = try mem.alloc(ty.BlobId, array_size);
    try recv_array(in, u8, std.mem.sliceAsBytes(blob_ids));
    return blob_ids;
}

fn recv_blob_id(in: *Reader) !ty.BlobId {
    var blob_id: ty.BlobId = undefined;
    try recv_array(in, u8, &blob_id);
    return blob_id;
}

fn recv_blob(in: *Reader) !ty.Blob {
    const array_size = try recv(in, ArraySize);
    const stream = try mem.create(ty.Blob.Stream);
    errdefer mem.free(stream);
    stream.* = .{
        .reader = in,
        .bytes_left = array_size,
    };
    return .{.stream = stream};
}

fn recv_enum(in: *Reader, Enum: type) !Enum {
    const Tag = @typeInfo(Enum).@"enum".tag_type;
    const tag = try in.takeInt(Tag, .little);
    return parse_enum_tag(Enum, tag);
}

fn parse_enum_tag(Enum: type, tag: anytype) !Enum {
    return if (std.enums.fromInt(Enum, tag)) |val| val else out: {
        funcs.debug("parse_enum_tag: '{s}' is not a {s} value.\n",
                    .{ty.decode8(tag), @typeName(Enum)});
        break :out ty.Err.BadArgument;
    };
}

fn recv_tuple(in: *Reader, comptime Tuple: anytype) !Tuple {
    var out: Tuple = undefined;
    inline for (std.meta.fields(Tuple)) |field| {
        @field(out, field.name) = try recv(in, field.type);
    }
    return out;
}

fn recv_array(in: *Reader, ElemType: type, array: []ElemType) !void {
    return in.readSliceEndian(ElemType, array, .little);
}
