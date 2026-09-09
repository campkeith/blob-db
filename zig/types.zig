const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const fmt = @import("format.zig");
const Fmt = fmt.Fmt;

const fns = @import("functions.zig");
const encode8 = fns.encode8;

const Blob = @import("Blob.zig");
const struct_ = @import("struct_.zig");

pub const Code = u64;

pub const CallTag = enum(Code) {
    store_list = encode8("storlist"),
    store_create = encode8("storenew"),
    store_destroy = encode8("storedel"),
    blob_hash = encode8("blobhash"),

    blob_list = encode8("bloblist"),
    blob_info = encode8("blobinfo"),
    blob_load = encode8("blobload"),
    blob_save = encode8("blobsave"),
    blob_delete = encode8("blobdrop"),
};

pub const Request = union(enum) {
    call: Call,
    bye,

    pub const Call = union(CallTag) {
        store_list,
        store_create: StoreId,
        store_destroy: StoreId,
        blob_hash: Blob,

        blob_list: StoreId,
        blob_info: StoreIdBlobId,
        blob_load: StoreIdBlobId,
        blob_save: StoreIdBlob,
        blob_delete: StoreIdBlobId,
    };

    pub const StoreIdBlobId = struct {
        store_id: StoreId,
        blob_id: Blob.Id,

        pub const init = struct_.init(@This());
    };

    pub const StoreIdBlob = struct {
        store_id: StoreId,
        blob: Blob,

        pub const init = struct_.init(@This());
    };
};

pub const Response = union(enum) {
    call: Call,
    err: Err,

    pub const Call = union(CallTag) {
        store_list: []StoreId,
        store_create,
        store_destroy,
        blob_hash: Blob.Id,

        blob_list: []Blob.Id,
        blob_info: Blob.Size,
        blob_load: Blob,
        blob_save: SaveStatusBlobId,
        blob_delete,

        pub fn toOwnedVal(self: Call, comptime tag: CallTag)
                @FieldType(Call, @tagName(tag)) {
            return @field(self, @tagName(tag));
        }
    };

    pub const SaveStatusBlobId = struct {
        status: SaveStatus,
        blob_id: Blob.Id,

        pub const init = struct_.init(@This());

        pub fn format(self: SaveStatusBlobId, writer: *Writer) !void {
            try writer.print("{{{t}, {f}}}", .{self.status, Fmt(self.blob_id)});
        }
    };

    pub const SaveStatus = enum {
        created,
        exists,
    };
};

pub const Err = error {
    Exists,
    NotFound,
    NoSpace,
    BadArgument,
    Internal,
};

pub const StoreId = struct {
    id: []const u8,

    pub const init = struct_.init(@This());

    pub fn create(arena: Allocator, id_in: []const u8) !StoreId {
        const id = try arena.dupe(u8, id_in);
        return .init(id);
    }

    pub fn format(self: StoreId, writer: *Writer) !void {
        try writer.print("\"{s}\"", .{self.id});
    }
};
