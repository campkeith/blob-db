const std = @import("std");

pub const Init = std.process.Init;
pub const EnvMap = std.process.Environ.Map;
pub const Io = std.Io;
pub const Dir = Io.Dir;
pub const File = Io.File;
pub const Reader = Io.Reader;
pub const Writer = Io.Writer;

pub const Request = union(enum) {
    store_list,
    store_create: StoreId,
    store_destroy: StoreId,
    blob_hash: Blob,

    blob_list: StoreId,
    blob_info: struct { store_id: StoreId, blob_id: BlobId },
    blob_load: struct { store_id: StoreId, blob_id: BlobId },
    blob_save: struct { store_id: StoreId, blob: Blob },
    blob_delete: struct { store_id: StoreId, blob_id: BlobId },

    bye,
};

pub const ResponseTag = enum {
    status,
    store_list,
    blob_hash,
    blob_list,
    blob_info,
    blob_load,
    blob_save,
};

pub const Response = union(ResponseTag) {
    status: Status,
    store_list: StoreIds,
    blob_hash: BlobId,
    blob_list: BlobIds,
    blob_info: BlobSize,
    blob_load: BlobFile,
    blob_save: struct { status: SaveStatus, blob_id: BlobId },
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

pub const StoreId = []const u8;
pub const StoreIds = []StoreId;
pub const BlobId = [32]u8;
pub const BlobIdStr = [64]u8;
pub const BlobIds = []BlobId;
pub const Blob = []u8;
pub const BlobFile = File;
pub const BlobStream = struct {
    bytes_remain: usize,
    stream: Reader,
};

pub const Code = u64;
pub const BlobSize = u64;

fn code(comptime bytes: *const[8]u8) Code {
    return std.mem.readInt(u64, bytes, .little);
}
