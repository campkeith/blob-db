const std = @import("std");
const File = std.Io.File;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const ty = @import("types.zig");
const Err = ty.Err;
const Code = ty.Code;
const CallTag = ty.CallTag;
const Request = ty.Request;
const Response = ty.Response;
const StoreId = ty.StoreId;

const fns = @import("functions.zig");
const encode8 = fns.encode8;

const Blob = @import("Blob.zig");
const trash = @import("trash.zig");

const ProtoVersion = u16;
const StoreIdSize = u16;
const ArraySize = u64;

const proto_version: ProtoVersion = 1;
const code_open_door = encode8("OpenDoor");

const GreetCode = enum(Code) {
    welcome = encode8("Welcome!"),
    not_welcome = encode8("Go away!"),
};

const code_bye = encode8("Goodbye!");

const Status = enum(Code) {
    okay = encode8("okeydoke"),
    exists = encode8("itexists"),
    not_found = encode8("notfound"),
    no_space = encode8("no-space"),
    bad_argument = encode8("invalarg"),
    internal_error = encode8("internal"),
};

pub fn sendOpenDoor(out: *Writer) !void {
    try sendStruct(out, .{code_open_door, proto_version});
    try out.flush();
}

pub fn sendWelcome(out: *Writer) !void {
    try sendEnum(out, GreetCode.welcome);
    try out.flush();
}

pub fn sendNotWelcome(out: *Writer) !void {
    try sendStruct(out, .{GreetCode.not_welcome, proto_version});
    try out.flush();
}

pub fn sendRequest(out: *Writer, request: Request) !void {
    try switch (request) {
        .call => |call| switch (call) {
            inline else => |args|
                sendStruct(out, .{std.meta.activeTag(call), args}),
        },
        .bye => sendInt(out, code_bye),
    };
    try out.flush();
}

pub fn sendResponse(out: *Writer, response: Response) !void {
    try switch (response) {
        .call => |call| switch (call) {
            .blob_save => |status_blob_id| sendStruct(out, status_blob_id),
            inline else => |result| sendStruct(out, .{Status.okay, result}),
        },
        .err => |err| sendEnum(out, errorToStatus(err)),
    };
    try out.flush();
}

fn errorToStatus(err: Err) Status {
    return switch (err) {
        Err.Exists => .exists,
        Err.NotFound => .not_found,
        Err.NoSpace => .no_space,
        Err.BadArgument => .bad_argument,
        Err.Internal => .internal_error,
    };
}

fn saveStatusToStatus(status: Response.SaveStatus) Status {
    return switch (status) {
        .created => Status.okay,
        .exists => Status.exists,
    };
}

fn send(out: *Writer, obj: anytype) !void {
    return switch (@TypeOf(obj)) {
        Request.StoreIdBlobId, Request.StoreIdBlob => sendStruct(out, obj),
        []StoreId => sendStoreIds(out, obj),
        StoreId => sendStoreId(out, obj),
        []Blob.Id => sendBlobIds(out, obj),
        Blob.Id => sendArray(out, @as([]const u8, &obj)),
        Blob => sendBlob(out, obj),
        GreetCode, CallTag, Status => sendEnum(out, obj),
        Response.SaveStatus => sendEnum(out, saveStatusToStatus(obj)),
        u16, u64 => sendInt(out, obj),
        void => {},
        else => err: {
            fns.println("send: {any} is not supported.", .{@TypeOf(obj)});
            break :err Err.Internal;
        },
    };
}

fn sendStruct(out: *Writer, struct_: anytype) !void {
    inline for (@typeInfo(@TypeOf(struct_)).@"struct".fields) |field| {
        try send(out, @field(struct_, field.name));
    }
}

fn sendStoreIds(out: *Writer, store_ids: []StoreId) !void {
    const size: ArraySize = store_ids.len;
    try sendInt(out, size);
    for (store_ids) |store_id| {
        try sendStoreId(out, store_id);
    }
}

fn sendStoreId(out: *Writer, store_id: StoreId) !void {
    const size: StoreIdSize = @intCast(store_id.id.len);
    try sendInt(out, size);
    try sendArray(out, store_id.id);
}

fn sendBlobIds(out: *Writer, blob_ids: []Blob.Id) !void {
    const size: ArraySize = blob_ids.len;
    try sendInt(out, size);
    try sendArray(out, std.mem.sliceAsBytes(blob_ids));
}

fn sendBlob(out: *Writer, blob: Blob) !void {
    const size: ArraySize = try blob.size();
    try sendInt(out, size);
    switch (blob.core) {
        .stream => |in| {
            try in.reader.streamExact(out, size);
        },
        .file => |file| {
            var reader = file.file.reader(file.io, &.{});
            const sent_size = try out.sendFileAll(&reader, .limited(size));
            if (sent_size != size) {
                fns.println("send_blob: Warning: only {d}/{d} bytes sent.",
                              .{sent_size, size});
            }
        },
        .memory => |bytes| {
            try sendArray(out, bytes);
        },
    }
}

fn sendEnum(out: *Writer, enum_val: anytype) !void {
    try sendInt(out, @intFromEnum(enum_val));
}

fn sendInt(out: *Writer, val: anytype) !void {
    try out.writeInt(@TypeOf(val), val, .little);
}

fn sendArray(out: *Writer, array: anytype) !void {
    const ElemType = std.meta.Child(@TypeOf(array));
    return out.writeSliceEndian(ElemType, array, .little);
}


pub fn recvOpenDoor(in: *Reader) !void {
    const recvd_open_door = try recvInt(in, Code);
    const recvd_proto_version = try recvInt(in, ProtoVersion);
    if (recvd_open_door != code_open_door
            or recvd_proto_version != proto_version) {
        return Err.BadArgument;
    }
}

pub fn recvWelcome(in: *Reader) !void {
    const code = try recvEnum(in, GreetCode);
    return switch (code) {
        .welcome => {},
        .not_welcome => err: {
            const recvd_proto_version = try recvInt(in, ProtoVersion);
            fns.println("recv_welcome: server says we are not welcome; "
                          ++ "client: v{d}, server: v{d}",
                          .{proto_version, recvd_proto_version});
            break :err Err.BadArgument;
        },
    };
}

pub fn recvRequest(in: *Reader, arena: Allocator) !Request {
    const code = try recvInt(in, Code);
    return switch (code) {
        code_bye => .bye,
        else => request: {
            const tag_in = try parseEnumTag(CallTag, code);
            const call = switch(tag_in) {
                inline else => |tag| call: {
                    const Result = @FieldType(Request.Call, @tagName(tag));
                    const result = try recv(in, arena, Result);
                    break :call @unionInit(Request.Call, @tagName(tag), result);
                },
            };
            break :request .{.call = call};
        },
    };
}

pub fn recvResponse(in: *Reader, opt_arena: ?Allocator, tag_in: CallTag) !Response {
    const arena = opt_arena orelse std.mem.Allocator.failing;
    const status = try recvEnum(in, Status);
    return if (tag_in == .blob_save and (status == .okay or status == .exists))
        .{.call = .{.blob_save =
            .init(try statusToSaveStatus(status), try recvBlobId(in))}}
    else if (status == .okay) switch (tag_in) {
        inline else => |tag|
            .{.call = @unionInit(Response.Call, @tagName(tag),
                try recv(in, arena, @FieldType(Response.Call, @tagName(tag))))},
    } else .{.err = statusToError(status)};
}

fn statusToSaveStatus(status: Status) !Response.SaveStatus {
    return switch (status) {
        .okay => .created,
        .exists => .exists,
        else => err: {
            fns.println("statusToSaveStatus: unexpected status {t}",
                          .{status});
            break :err Err.Internal;
        }
    };
}

fn statusToError(status: Status) Err {
    return switch (status) {
        .exists => Err.Exists,
        .not_found => Err.NotFound,
        .no_space => Err.NoSpace,
        .bad_argument => Err.BadArgument,
        .internal_error => Err.Internal,
        .okay => err: {
            fns.writeln("status_to_error: 'Okay' is not an error!");
            break :err Err.Internal;
        }
    };
}

fn recv(in: *Reader, arena: Allocator, ObjType: type) !ObjType {
    return switch (ObjType) {
        Request.StoreIdBlobId, Request.StoreIdBlob,
            Response.SaveStatusBlobId => try recvStruct(in, arena, ObjType),
        []StoreId => try recvStoreIds(in, arena),
        StoreId => try recvStoreId(in, arena),
        []Blob.Id => try recvBlobIds(in, arena),
        Blob.Id => try recvBlobId(in),
        Blob => try recvBlob(in, arena),
        GreetCode, CallTag, Status => try recvEnum(in, ObjType),
        u16, u64 => try recvInt(in, ObjType),
        void => {},
        else => err: {
            fns.println("recv: {any} is not supported.", .{ObjType});
            break :err Err.Internal;
        },
    };
}

fn recvStruct(in: *Reader, arena: Allocator, Struct: type) !Struct {
    var out: Struct = undefined;
    const fields = std.meta.fields(Struct);
    inline for (fields, 0..) |field, index| {
        errdefer inline for (fields[0..index]) |recvd_field|
            trash.recycle(&@field(out, recvd_field.name), arena);
        @field(out, field.name) = try recv(in, arena, field.type);
    }
    return out;
}

fn recvStoreIds(in: *Reader, arena: Allocator) ![]StoreId {
    const size = try recvInt(in, ArraySize);
    var list: std.ArrayList(StoreId) = try .initCapacity(arena, size);
    errdefer trash.recycleArrayList(&list, arena);
    for (0..size) |_| {
        const item = try recvStoreId(in, arena);
        errdefer trash.recycle(&item, arena);
        try list.append(arena, item);
    }
    return try list.toOwnedSlice(arena);
}

fn recvStoreId(in: *Reader, arena: Allocator) !StoreId {
    const size = try recvInt(in, StoreIdSize);
    const store_id = try arena.alloc(u8, size);
    errdefer arena.free(store_id);
    try recvArray(in, u8, store_id);
    return .init(store_id);
}

fn recvBlobIds(in: *Reader, arena: Allocator) ![]Blob.Id {
    const size = try recvInt(in, ArraySize);
    const blob_ids = try arena.alloc(Blob.Id, size);
    errdefer arena.free(blob_ids);
    try recvArray(in, u8, std.mem.sliceAsBytes(blob_ids));
    return blob_ids;
}

fn recvBlobId(in: *Reader) !Blob.Id {
    var blob_id: Blob.Id = undefined;
    try recvArray(in, u8, &blob_id);
    return blob_id;
}

fn recvBlob(in: *Reader, arena: Allocator) !Blob {
    const size = try recvInt(in, ArraySize);
    return try Blob.initStream(arena, in, size);
}

fn recvEnum(in: *Reader, Enum: type) !Enum {
    const Tag = @typeInfo(Enum).@"enum".tag_type;
    const tag = try in.takeInt(Tag, .little);
    return parseEnumTag(Enum, tag);
}

fn recvInt(in: *Reader, IntType: type) !IntType {
    return try in.takeInt(IntType, .little);
}

fn parseEnumTag(Enum: type, tag: anytype) !Enum {
    return if (std.enums.fromInt(Enum, tag)) |val| val else err: {
        fns.println("parse_enum_tag: '{s}' is not a {s} value.",
                     .{fns.decode8(tag), @typeName(Enum)});
        break :err Err.BadArgument;
    };
}

fn recvArray(in: *Reader, ElemType: type, array: []ElemType) !void {
    return in.readSliceEndian(ElemType, array, .little);
}
