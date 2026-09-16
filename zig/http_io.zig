const std = @import("std");
const http = std.http;
const json = std.json;
const Method = http.Method;
const Server = std.http.Server;
const Allocator = std.mem.Allocator;
const activeTag = std.meta.activeTag;

const ty = @import("types.zig");
const Err = ty.Err;
const CallTag = ty.CallTag;
const StoreId = ty.StoreId;
const Request = ty.Request;
const Response = ty.Response;
const SaveStatus = ty.Response.SaveStatus;

const trash = @import("trash.zig");
const fns = @import("functions.zig");
const Blob = @import("Blob.zig");
const record = @import("record.zig");

const Route = struct {
    tag: CallTag,
    method: Method,
    body_type: BodyType,
    path: []const u8,

    const BodyType = enum {
        empty,
        blob,
    };

    const init = record.init(@This());
};

const buf_size: usize = 64 * 1024;

pub fn recvRequest(server: *Server, arena: Allocator)
        !struct{fns.ErrUnionErrs(recvRequestCallReturn)!Request, ?Server.Request} {
    var in = server.receiveHead() catch |err| return switch (err) {
        error.HttpConnectionClosing => .{.bye, null},
        else => err,
    };
    const call = recvRequestCall(&in, arena) catch |err| return .{err, in};
    return .{.{.call = call}, in};
}

const recvRequestCallReturn = fns.ReturnType(@TypeOf(recvRequestCall));

fn recvRequestCall(in: *Server.Request, arena: Allocator) !Request.Call {
    const routes = comptime [_]Route {
        .init(.store_list,    .GET,    .empty, "/stores"),
        .init(.store_create,  .PUT,    .empty, "/stores/:parseStoreId"),
        .init(.store_destroy, .DELETE, .empty, "/stores/:parseStoreId"),
        .init(.blob_hash,     .POST,   .blob,  "/blob_hash"),
        .init(.blob_list,     .GET,    .empty, "/stores/:parseStoreId/blobs"),
        .init(.blob_info,     .HEAD,   .empty, "/stores/:parseStoreId/blobs/:parseBlobId"),
        .init(.blob_load,     .GET,    .empty, "/stores/:parseStoreId/blobs/:parseBlobId"),
        .init(.blob_save,     .POST,   .blob,  "/stores/:parseStoreId/blobs"),
        .init(.blob_delete,   .DELETE, .empty, "/stores/:parseStoreId/blobs/:parseBlobId"),
    };

    inline for (routes) |route| {
        if (matchHead(in.head, route, arena)) |path_args| {
            errdefer trash.recycle(&path_args, arena);
            return recvRequestRoute(in, arena, route, path_args);
        } else |err| switch (err) {
            Err.NotFound => {},
            else => return err,
        }
    } else return Err.NotFound;
}

fn matchHead(head: Server.Request.Head, comptime route: Route, arena: Allocator)
        !PathArgs(route.path) {
    return if (head.method == route.method)
               matchPath(head.target, route.path, arena)
           else Err.NotFound;
}

fn matchPath(path: []const u8, comptime pattern: []const u8, arena: Allocator)
        !PathArgs(pattern) {
    var path_iter = std.mem.splitScalar(u8, path, '/');
    comptime var pattern_iter = std.mem.splitScalar(u8, pattern, '/');
    var args: PathArgs(pattern) = undefined;
    comptime var index: usize = 0;
    inline while (comptime pattern_iter.next()) |pattern_seg| {
        errdefer inline for (0..index) |sub_index|
            trash.recycle(&args[sub_index], arena);
        const path_seg = path_iter.next() orelse return Err.NotFound;
        if (pattern_seg.len > 0 and pattern_seg[0] == ':') {
            const parseFunc = @field(@This(), pattern_seg[1..]);
            args[index] = try parseFunc(path_seg, arena);
            index += 1;
        } else {
            if (!std.mem.eql(u8, path_seg, pattern_seg)) return Err.NotFound;
        }
    }
    return if (path_iter.next() == null) args else Err.NotFound;
}

fn PathArgs(pattern: []const u8) type {
    var args: [64]type = undefined;
    var index: usize = 0;
    var seg_iter = std.mem.splitScalar(u8, pattern, '/');
    inline while (seg_iter.next()) |segment| {
        if (segment.len > 0 and segment[0] == ':') {
            const parseFunc = @field(@This(), segment[1..]);
            const ReturnType = fns.ReturnType(@TypeOf(parseFunc));
            args[index] = @typeInfo(ReturnType).error_union.payload;
            index += 1;
        }
    }
    return @Tuple(args[0..index]);
}

fn parseStoreId(in: []const u8, arena: Allocator) !StoreId {
    // TODO: Consider doing this without allocation and copy.
    return .create(arena, in);
}

fn parseBlobId(in: []const u8, _: Allocator) !Blob.Id {
    return Blob.parseId(in);
}

fn recvRequestRoute(in: *Server.Request, arena: Allocator,
                    comptime route: Route, path_args: anytype) !Request.Call {
    const args_tuple = switch(route.body_type) {
        .blob => out: {
            const blob = try reqBodyBlob(in, arena);
            break :out path_args ++ .{blob};
        },
        .empty => out: {
            try reqBodyCheckEmpty(in);
            break :out path_args;
        },
    };
    const Args = @FieldType(Request.Call, @tagName(route.tag));
    const args = switch (std.meta.fields(@TypeOf(args_tuple)).len) {
        0 => {},
        1 => args_tuple[0],
        else => fns.structCast(Args, args_tuple),
    };
    return @unionInit(Request.Call, @tagName(route.tag), args);
}

fn reqBodyCheckEmpty(in: *Server.Request) !void {
    _ = in.readerExpectNone(&.{});
    const state = in.server.reader.state;
    return switch (state) {
        .body_remaining_content_length, .body_remaining_chunk_len => err: {
            fns.println("reqBodyCheckEmpty: nonempty body: {t}", .{activeTag(state)});
            break :err Err.BadArgument;
        },
        else => {},
    };
}

fn reqBodyBlob(in: *Server.Request, arena: Allocator) !Blob {
    const reader = in.readerExpectNone(&.{});
    const size = in.head.content_length orelse return Err.BadArgument;
    return .initStream(arena, reader, size);
}


pub fn sendResponse(out: *Server.Request, arena: Allocator, response: Response)
        !void {
    try switch (response) {
        .call => |call| switch (call) {
            .store_create => send(out, arena, .created, {}),
            .blob_save => |result| out: {
                const http_status = saveToHttpStatus(result.status);
                break :out send(out, arena, http_status, result);
            },
            inline else => |result| send(out, arena, .ok, result),
        },
        .err => |err| send(out, arena, errorToHttpStatus(err), {}),
    };
}

fn saveToHttpStatus(status: SaveStatus) http.Status {
    return switch (status) {
        .created => .created,
        .exists => .conflict,
    };
}

fn errorToHttpStatus(err: Err) http.Status {
    return switch (err) {
        error.Exists => .conflict,
        error.NotFound => .not_found,
        error.NoSpace => .insufficient_storage,
        error.BadArgument => .bad_request,
        error.Internal => .internal_server_error,
    };
}

fn send(out: *Server.Request, arena: Allocator,
        status: http.Status, obj: anytype) !void {
    const Obj = @TypeOf(obj);
    return switch (Obj) {
        StoreId, []StoreId, Blob.Id, []Blob.Id, Response.SaveStatusBlobId =>
            sendJson(out, arena, status, obj),
        Blob.Size => sendBlobHead(out, arena, obj),
        Blob => sendBlob(out, arena, obj),
        void => sendStatus(out, arena, status),
        else => @compileError("Unsupported type: " ++ @typeName(Obj)),
    };
}

fn sendStatus(out: *Server.Request, arena: Allocator, status: http.Status)
        !void {
    const Status = struct {status: http.Status};
    return sendJson(out, arena, status, Status{.status = status});
}

fn sendJson(out: *Server.Request, arena: Allocator,
            status: http.Status, obj: anytype) !void {
    const mime_type = "application/json";
    var writer = try RespBodyWriter.create(out, arena, status, mime_type, null);
    defer writer.destroy(arena);
    var stringify = json.Stringify {
        .writer = &writer.out.writer,
        .options = .{.whitespace = .indent_tab},
    };
    try stringify.write(obj);
    // There does not appear to be an option to add a trailing newline...
    try writer.out.writer.writeAll("\n");
    try writer.out.end();
}

fn sendBlobHead(out: *Server.Request, arena: Allocator, size: Blob.Size) !void {
    const mime_type = "application/octet-stream";
    var writer = try RespBodyWriter.create(out, arena, .ok, mime_type, size);
    try writer.out.writer.splatByteAll(0, size);
    try writer.out.end();
}

fn sendBlob(out: *Server.Request, arena: Allocator, blob: Blob) !void {
    const size = try blob.size();
    var body_writer = try RespBodyWriter.createBlob(out, arena, blob);
    defer body_writer.destroy(arena);
    switch (blob.core) {
        .file => |file| {
            var reader = file.file.reader(file.io, &.{});
            const writer = &body_writer.out.writer;
            const bytes_sent = try writer.sendFileAll(&reader, .limited(size));
            if (bytes_sent != size) return Err.Internal;
        },
        else => {
            fns.println("respondBlob: Unhandled blob type: {t}.",
                        .{activeTag(blob.core)});
            return Err.Internal;
        }
    }
    try body_writer.out.end();
}

const RespBodyWriter = struct {
    const Self = @This();

    buffer: []u8,
    out: http.BodyWriter,

    fn create(out: *Server.Request, arena: Allocator, status: http.Status,
              content_type: ?[]const u8, content_length: ?u64) !Self {
        const head = Server.Request.RespondStreamingOptions {
            .content_length = content_length,
            .respond_options = .{
                .status = status,
                .extra_headers = if (content_type) |type_| &.{
                    headerInit("content-type", type_),
                } else &.{},
                .transfer_encoding = if (content_type == null) .none else null,
            },
        };
        const buffer = try arena.alloc(u8, buf_size);
        errdefer arena.free(buffer);
        const writer = try out.respondStreaming(buffer, head);
        return .{.buffer = buffer, .out = writer};
    }

    fn createBlob(out: *Server.Request, arena: Allocator, blob: Blob) !Self {
        const size = try blob.size();
        const mime_type = try mimeType(blob);
        return create(out, arena, .ok, mime_type, size);
    }

    fn destroy(self: *Self, arena: Allocator) void {
        arena.free(self.buffer);
    }
};

fn mimeType(blob: Blob) ![]const u8 {
    return switch(blob.core) {
        .file => |file| out: {
            var buffer: [256]u8 = undefined;
            const bytes_read = try file.file.readPositional(file.io, &.{&buffer}, 0);
            const head = buffer[0..bytes_read];
            break :out if (anyZero(head)) "application/octet-stream"
                       else "text/plain";
        },
        else => out: {
            fns.println("mimeType: Unhandled blob type: {t}.",
                        .{activeTag(blob.core)});
            break :out "application/octet-stream";
        },
    };
}

fn anyZero(buffer: []u8) bool {
    for (buffer) |char| {
        if (char == 0) return true;
    } else return false;
}

fn headerInit(name: []const u8, value: []const u8) http.Header {
    return .{.name = name, .value = value};
}
