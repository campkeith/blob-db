const std = @import("std");

const mem = @import("mem.zig");

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

        pub fn deinit(self: Call) void {
            switch (self) {
                .blob_hash => |*blob| blob.deinit(),
                .blob_save => |*args| args.deinit(),
                else => {},
            }
        }
    };

    pub const StoreIdBlobId = struct {
        store_id: StoreId,
        blob_id: BlobId,

        pub fn init(store_id: StoreId, blob_id: BlobId) StoreIdBlobId {
            return .{.store_id = store_id, .blob_id = blob_id};
        }
    };

    pub const StoreIdBlob = struct {
        store_id: StoreId,
        blob: Blob,

        pub fn init(store_id: StoreId, blob: Blob) StoreIdBlob {
            return .{.store_id = store_id, .blob = blob};
        }

        pub fn deinit(self: StoreIdBlob) void {
            self.blob.deinit();
        }
    };

    pub fn deinit(self: Request) void {
        switch (self) {
            .call => |*call| call.deinit(),
            else => {},
        }
    }
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
        blob_info: Blob.Size,
        blob_load: Blob,
        blob_save: SaveStatusBlobId,
        blob_delete,

        pub fn deinit(self: Call) void {
            switch (self) {
                .blob_load => |blob| blob.deinit(),
                else => {},
            }
        }
    };

    pub const SaveStatusBlobId = struct {
        status: SaveStatus,
        blob_id: BlobId,

        pub fn init(status: SaveStatus, blob_id: BlobId) @This() {
            return .{.status = status, .blob_id = blob_id};
        }
    };

    pub const SaveStatus = enum {
        created,
        exists,
    };

    pub fn deinit(self: Response) void {
        switch (self) {
            .call => |call| call.deinit(),
            else => {},
        }
    }
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

pub const Blob = union(enum) {
    stream: *Stream,
    file: File,
    memory: []u8,

    pub const Size = u64;

    pub const Stream = struct {
        reader: *std.Io.Reader,
        bytes_left: usize,

        pub fn discard(self: *Stream) void {
            self.reader.discardAll(self.bytes_left) catch |err| {
                std.debug.print("Blob.Stream.discard failed due to {}.\n", .{err});
                return;
            };
            self.bytes_left = 0;
        }
    };

    pub const File = struct {
        file: std.Io.File,
        io: std.Io,

        pub fn close(self: File) void {
            self.file.close(self.io);
        }
    };

    pub fn deinit(self: Blob) void {
        switch (self) {
            .stream => |stream| {
                stream.discard();
                mem.destroy(stream);
            },
            .file => |file| file.close(),
            .memory => {},
        }
    }
};

pub const Code = u64;

pub fn encode8(comptime bytes: *const[8]u8) u64 {
    return std.mem.readInt(u64, bytes, .little);
}

pub fn decode8(code: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, code, .little);
    return out;
}
