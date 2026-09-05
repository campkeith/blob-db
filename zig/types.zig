const std = @import("std");
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const activeTag = std.meta.activeTag;

const struct_ = @import("struct_.zig");
const funcs = @import("funcs.zig");

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

        pub fn deinit(self: Call, arena: Allocator) void {
            switch (self) {
                .store_list => {},
                .store_create, .store_destroy, .blob_list =>
                    |store_id| store_id.destroy(arena),
                .blob_hash => |blob| blob.deinit(arena),
                .blob_info, .blob_load, .blob_delete =>
                    |store_id_blob_id| store_id_blob_id.deinit(arena),
                .blob_save => |store_id_blob| store_id_blob.deinit(arena),
            }
        }
    };

    pub const StoreIdBlobId = struct {
        store_id: StoreId,
        blob_id: BlobId,

        pub const init = struct_.Init(@This());

        pub fn deinit(self: StoreIdBlobId, arena: Allocator) void {
            self.store_id.destroy(arena);
        }
    };

    pub const StoreIdBlob = struct {
        store_id: StoreId,
        blob: Blob,

        pub const init = struct_.Init(@This());

        pub fn deinit(self: StoreIdBlob, arena: Allocator) void {
            self.store_id.destroy(arena);
            self.blob.deinit(arena);
        }
    };

    pub fn deinit(self: Request, arena: Allocator) void {
        switch (self) {
            .call => |call| call.deinit(arena),
            .bye => {},
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

        pub fn deinit(self: Call, arena: Allocator) void {
            switch (self) {
                .store_list => |list| {
                    for (list) |*item| item.destroy(arena);
                    arena.free(list);
                },
                .store_create, .store_destroy, .blob_hash,
                    .blob_info, .blob_save, .blob_delete => {},
                .blob_list => |list| arena.free(list),
                .blob_load => |blob| blob.deinit(arena),
            }
        }

        pub fn toOwnedVal(self: Call, comptime tag: CallTag)
                @FieldType(Call, @tagName(tag)) {
            return @field(self, @tagName(tag));
        }
    };

    pub const SaveStatusBlobId = struct {
        status: SaveStatus,
        blob_id: BlobId,

        pub const init = struct_.Init(@This());

        pub fn format(self: SaveStatusBlobId, writer: *Writer) !void {
            try writer.print("{{{t}, {s}}}",
                .{self.status, funcs.hashBytesToHex(self.blob_id)});
        }
    };

    pub const SaveStatus = enum {
        created,
        exists,
    };

    pub fn deinit(self: Response, arena: Allocator) void {
        switch (self) {
            .call => |call| call.deinit(arena),
            .err => {},
        }
    }
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

    pub const init = struct_.Init(@This());

    pub fn create(arena: Allocator, id_in: []const u8) !StoreId {
        const id = try arena.dupe(u8, id_in);
        return .init(id);
    }

    pub fn destroy(self: StoreId, arena: Allocator) void {
        arena.free(self.id);
    }

    pub fn format(self: StoreId, writer: *Writer) !void {
        try writer.print("\"{s}\"", .{self.id});
    }
};
pub const StoreIds = []StoreId;

pub const BlobId = [32]u8;
pub const BlobIdStr = [64]u8;
pub const BlobIds = []BlobId;

pub const Blob = union(enum) {
    stream: *Stream,
    file: File,
    memory: []const u8,

    pub const Size = u64;

    pub const Stream = struct {
        reader: *Reader,
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
        file: Io.File,
        io: Io,

        pub fn close(self: File) void {
            self.file.close(self.io);
        }

        pub fn size(self: File) !usize {
            return try self.file.length(self.io);
        }
    };

    pub fn initStream(arena: Allocator, reader: *Reader, size_: usize) !Blob {
        const stream = try arena.create(Stream);
        errdefer arena.destroy(stream);
        stream.* = .{.reader = reader, .bytes_left = size_};
        return .{.stream = stream};
    }

    pub fn initFile(file: Io.File, io: Io) Blob {
        return .{.file = .{.file = file, .io = io}};
    }

    pub fn initMemory(memory: []const u8) Blob {
        return .{.memory = memory};
    }

    pub fn deinit(self: Blob, arena: Allocator) void {
        switch (self) {
            .stream => |stream| {
                stream.discard();
                arena.destroy(stream);
            },
            .file => |file| file.close(),
            .memory => {},
        }
    }

    pub fn format(self: Blob, out: *Writer) !void {
        const tag = activeTag(self);
        const size_: ?Size = self.size() catch null;
        try out.print("Blob(type = {t}, size = {?d})", .{tag, size_});
    }

    pub fn size(self: Blob) !Size {
        return switch (self) {
            .stream => |in| in.bytes_left,
            .file => |file| try file.size(),
            .memory => |bytes| bytes.len,
        };
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
