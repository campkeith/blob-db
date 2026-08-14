const std = @import("std");

pub const Init = std.process.Init;
pub const EnvMap = std.process.Environ.Map;
pub const Reader = std.Io.Reader;
pub const Writer = std.Io.Writer;

pub const RequestTag = enum(Code) {
    store_list,
    store_create,
    store_destroy,
    blob_hash,

    blob_list,
    blob_info,
    blob_load,
    blob_save,
    blob_delete,

    bye,
};

pub const Request = union(RequestTag) {
    store_list,
    store_create: StoreId,
    store_destroy: StoreId,
    blob_hash: BlobStream,

    blob_list: StoreId,
    blob_info: StoreIdBlobId,
    blob_load: StoreIdBlobId,
    blob_save: StoreIdBlob,
    blob_delete: StoreIdBlobId,

    bye,

    pub const StoreIdBlobId = struct {
        store_id: StoreId,
        blob_id: BlobId,
    };
    pub const StoreIdBlob = struct {
        store_id: StoreId,
        blob: BlobStream,
    };
};

pub const ResponseTag = enum(Code) {
    store_list,
    store_create,
    store_destroy,
    blob_hash,

    blob_list,
    blob_info,
    blob_load,
    blob_save,
    blob_delete,

    err,
};

pub const Response = union(ResponseTag) {
    store_list: StoreIds,
    store_create,
    store_destroy,
    blob_hash: BlobId,

    blob_list: BlobIds,
    blob_info: BlobSize,
    blob_load: BlobStream,
    blob_save: SaveStatusBlobId,
    blob_delete,

    err: Err,

    pub const SaveStatusBlobId = struct {
        status: SaveStatus,
        blob_id: BlobId,
    };
};

pub const Status = enum(Code) {
    okay = code("okeydoke"),
    exists = code("itexists"),
    not_found = code("notfound"),
    no_space = code("no-space"),
    bad_argument = code("invalarg"),
    internal_error = code("internal"),
};

pub const SaveStatus = enum(Code) {
    created = @intFromEnum(Status.okay),
    exists = @intFromEnum(Status.exists),
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

pub fn code(comptime bytes: *const[8]u8) Code {
    return std.mem.readInt(u64, bytes, .little);
}

pub fn decode(code_: Code) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, code_, .little);
    return out;
}
