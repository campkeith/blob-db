const std = @import("std");
const print = std.debug.print;

const ty = @import("types.zig");
const Request = ty.Request;
const Response = ty.Response;
const Client = @import("Client.zig");
const Persister = @import("Persister.zig");

const funcs = @import("funcs.zig");

pub fn dump_tuple(tuple: anytype) void {
    print("(", .{});
    inline for (tuple, 0..) |item, index| {
        dump(item);
        if (index < tuple.len - 1) print(", ", .{});
    }
    print(")", .{});
}

pub fn dump(obj: anytype) void {
    if (@typeInfo(@TypeOf(obj)) == .error_union) {
        if (obj) |not_err| dump(not_err)
            else |err| dump(err);
    } else {
        switch (@TypeOf(obj)) {
            Request => dump_request(obj),
            Response => dump_response(obj),
            *Client, *Persister => print("{*}", .{obj}),
            ty.StoreId => print("'{s}'", .{obj.id}),
            ty.BlobId => print("{s}", .{funcs.hashBytesToHex(obj)}),
            ty.Blob => dump_blob(obj),
            ty.StoreIds, ty.BlobIds => dump_array(obj),
            ty.Response.SaveStatusBlobId => dump_tuple(.{obj.status, obj.blob_id}),
            void => print("{{}}", .{}),
            else => print("{any}", .{obj}),
        }
    }
}

fn dump_blob(blob: ty.Blob) void {
    const type_ = std.meta.activeTag(blob);
    const size = funcs.blobSize(blob) catch 0;
    print("Blob(type = {any}, size = {d})", .{type_, size});
}

fn dump_array(array: anytype) void {
    print("[", .{});
    for (array, 0..) |item, index| {
        dump(item);
        if (index < array.len - 1) print(", ", .{});
    }
    print("]", .{});
}

pub fn dump_request(request: Request) void {
    switch (request) {
        .call => |call| dump_call_request(call),
        .bye => print("bye", .{}),
    }
    print("\n", .{});
}

fn dump_call_request(call: Request.Call) void {
    switch (call) {
        .store_list =>
            dump_call("store_list", .{}),
        .store_create => |store_id|
            dump_call("store_create", .{store_id}),
        .store_destroy => |store_id|
            dump_call("store_destroy", .{store_id}),
        .blob_hash => |blob|
            dump_call("blob_hash", .{blob}),
        .blob_list => |store_id|
            dump_call("blob_list", .{store_id}),
        .blob_info => |args|
            dump_call("blob_info", .{args.store_id, args.blob_id}),
        .blob_load => |args|
            dump_call("blob_load", .{args.store_id, args.blob_id}),
        .blob_save => |args|
            dump_call("blob_save", .{args.store_id, args.blob}),
        .blob_delete => |args|
            dump_call("blob_delete", .{args.store_id, args.blob_id}),
    }
}

fn dump_call(name: []const u8, args: anytype) void {
    print("{s}", .{name});
    dump_tuple(args);
}

pub fn dump_response(response: Response) void {
    print("-> ", .{});
    switch (response) {
        .call => |call| dump_call_response(call),
        .err => |err| print("{any}", .{err}),
    }
    print("\n", .{});
}

fn dump_call_response(call: Response.Call) void {
    switch (call) {
        .store_list => |store_ids|
            dump(store_ids),
        .blob_hash => |blob_id|
            dump(blob_id),
        .blob_list => |blob_ids|
            dump(blob_ids),
        .blob_info => |size|
            dump(size),
        .blob_load => |blob|
            dump(blob),
        .blob_save => |result|
            dump_tuple(.{result.status, result.blob_id}),
        .store_create, .store_destroy, .blob_delete =>
            print("ok", .{}),
    }
}
