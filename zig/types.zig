const std = @import("std");

pub const Init = std.process.Init;
pub const EnvMap = std.process.Environ.Map;
pub const Reader = std.Io.Reader;
pub const Writer = std.Io.Writer;

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
        blob_hash: *BlobStream,

        blob_list: StoreId,
        blob_info: StoreIdBlobId,
        blob_load: StoreIdBlobId,
        blob_save: StoreIdBlob,
        blob_delete: StoreIdBlobId,
    };

    pub const StoreIdBlobId = struct {
        store_id: StoreId,
        blob_id: BlobId,
    };

    pub const StoreIdBlob = struct {
        store_id: StoreId,
        blob: *BlobStream,
    };
};

pub const Response = union(enum) {
    call: Call,
    err: Err,

    pub const Call = union(CallTag) {
        store_list: StoreIds,
        store_create,
        store_destroy,
        blob_hash: BlobId,

        blob_list: BlobIds,
        blob_info: BlobSize,
        blob_load: BlobStream,
        blob_save: SaveStatusBlobId,
        blob_delete,
    };

    pub const SaveStatusBlobId = struct {
        status: SaveStatus,
        blob_id: BlobId,
    };

    pub const SaveStatus = enum {
        created,
        exists,
    };
};

pub const Err = error{
    Exists,
    NotFound,
    NoSpace,
    BadArgument,
    Internal,
};

pub const StoreId = struct {
    id: []const u8,
};
pub const StoreIds = []StoreId;
pub const BlobId = [32]u8;
pub const BlobIdStr = [64]u8;
pub const BlobIds = []BlobId;
pub const BlobStream = struct {
    bytes_remain: usize,
    stream: *Reader,
};

pub const Code = u64;
pub const BlobSize = u64;

pub fn encode8(comptime bytes: *const[8]u8) u64 {
    return std.mem.readInt(u64, bytes, .little);
}

pub fn decode8(code: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, code, .little);
    return out;
}
