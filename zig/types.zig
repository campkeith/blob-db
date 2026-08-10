const std = @import("std");


const Request = union(enum) {
    store_list,
    store_create: StoreId,
    store_destroy: StoreId,
    blob_hash: Blob,

    blob_list: StoreId,
    blob_info: struct {store_id: StoreId, blob_id: BlobId},
    blob_load: struct {store_id: StoreId, blob_id: BlobId},
    blob_save: struct {store_id: StoreId, blob: Blob},
    blob_delete: struct {store_id: StoreId, blob_id: BlobId},

    bye,
};

const Response = union(enum) {
    status: Status,
    store_list: StoreIds,
    blob_hash: BlobId,
    blob_list: BlobIds,
    blob_info: BlobSize,
    blob_load: BlobFile,
    blob_save: struct {status: SaveStatus, blob_id: BlobId},
};

const Status = enum(Code) {
    okay = code("okeydoke"),
    exists = code("itexists"),
    not_found = code("notfound"),
    no_space = code("no-space"),
    bad_argument = code("invalarg"),
    internal_error = code("internal"),
};

const SaveStatus = enum(Code) {
    created = Status.okay,
    exists = Status.exists,
};

const StoreId = []u8;
const StoreIds = []StoreId;
const BlobId = [32]u8;
const BlobIdStr = [64]u8;
const BlobIds = []BlobId;
const Blob = []u8;
const BlobFile = std.Io.File;
const BlobStream = struct {
    bytes_remain: usize,
    stream: std.Io.Reader,
};

const Code = u64;
const BlobSize = u64;


fn code(comptime bytes: [8]u8) Code {
    return std.mem.readInt(u64, bytes, .little);
}
