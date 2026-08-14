const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;

const funcs = @import("funcs.zig");
const ty = @import("types.zig");
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const BlobSize = ty.BlobSize;
const BlobStream = ty.BlobStream;

const Self = @This();

io: std.Io,
base_dir: Dir,

pub fn create(init: ty.Init) !Self {
    const base_dir_str = try funcs.getEnv(init.environ_map, "BASE_DIR");
    const opts: Dir.OpenOptions = .{
        .iterate = true,
        .follow_symlinks = false,
    };
    const base_dir = try Dir.cwd().openDir(init.io, base_dir_str, opts);
    return .{
        .io = init.io,
        .base_dir = base_dir,
    };
}

pub fn destroy(self: *Self) void {
    self.base_dir.close(self.io);
}

pub fn store_list(self: *Self) !ty.StoreIds {
    var list: std.ArrayList(StoreId) = .empty;
    errdefer {
        for (list.items) |item| {
            funcs.allocator.free(item.id);
        }
        list.deinit(funcs.allocator);
    }
    var iterator = self.base_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .directory) {
            funcs.debug("store_list: Ignoring {any} entry '{s}'\n",
                        .{entry.kind, entry.name});
            continue;
        }
        const name = try funcs.allocator.dupe(u8, entry.name);
        errdefer funcs.allocator.free(name);
        try list.append(funcs.allocator, .{.id = name});
    }
    return try list.toOwnedSlice(funcs.allocator);
}

pub fn store_create(self: *Self, store_id: StoreId) !void {
    self.base_dir.createDir(self.io, store_id.id, .default_dir) catch |err| {
        return switch (err) {
            error.PathAlreadyExists => ty.Err.Exists,
            error.NoSpaceLeft => ty.Err.NoSpace,
            else => err,
        };
    };
}

pub fn store_destroy(self: *Self, store_id: StoreId) !void {
    self.base_dir.deleteTree(self.io, store_id.id) catch |err| {
        return switch (err) {
            // FIXME: this doesn't seem to exist
            // error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    };
}

pub fn blob_list(self: *Self, store_id: StoreId) !ty.BlobIds {
    var list: std.ArrayList(BlobId) = .empty;
    errdefer list.deinit(funcs.allocator);
    var store_dir = self.open_store_dir(store_id) catch |err| {
        return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    };
    defer store_dir.close(self.io);
    var iterator = store_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .file) {
            funcs.debug("blob_list: Ignoring {any} entry '{s}'\n",
                        .{entry.kind, entry.name});
            continue;
        }
        const blob_id = try funcs.hashHexToBytes(entry.name);
        try list.append(funcs.allocator, blob_id);
    }
    return try list.toOwnedSlice(funcs.allocator);
}

pub fn blob_info(self: *Self, store_id: StoreId, blob_id: BlobId) !BlobSize {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    const opts: Dir.StatFileOptions = .{
        .follow_symlinks = false,
    };
    const stat = store_dir.statFile(self.io, &blob_id_str, opts) catch |err| {
        return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    };
    return stat.size;
}

pub fn blob_load(self: *Self, store_id: StoreId, blob_id: BlobId) !BlobStream {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    const opts: Dir.OpenFileOptions = .{
        .allow_directory = false
    };
    const file = store_dir.openFile(self.io, &blob_id_str, opts) catch |err|
        return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    const buffer = try funcs.allocator.alloc(u8, 4096);
    var reader = file.reader(self.io, buffer);
    return .{
        .bytes_remain = reader.size.?,
        .stream = &reader.interface,
    };
}

pub fn blob_save(self: *Self, store_id: StoreId, blob_in: *BlobStream)
        !ty.Response.SaveStatusBlobId {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);

    const opts: Dir.CreateFileAtomicOptions = .{};
    var file = try store_dir.createFileAtomic(self.io, "", opts);
    defer file.deinit(self.io);
    try file.file.setLength(self.io, blob_in.bytes_remain);

    const mmap_opts: File.MemoryMap.CreateOptions = .{
        .len = blob_in.bytes_remain,
    };
    var blob_out = file.file.createMemoryMap(self.io, mmap_opts) catch |err| {
        return switch (err) {
            error.OutOfMemory => ty.Err.NoSpace,
            else => err,
        };
    };
    defer blob_out.destroy(self.io);

    const blob_id = try funcs.hashCopyBlob(blob_in.stream, blob_out.memory);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    file.dest_sub_path = &blob_id_str;
    file.link(self.io) catch |err| {
        return switch (err) {
            error.PathAlreadyExists => .{
                .status = .exists,
                .blob_id = blob_id,
            },
            else => err,
        };
    };
    return .{
        .status = .created,
        .blob_id = blob_id,
    };
}

pub fn blob_delete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);

    const blob_id_str = funcs.hashBytesToHex(blob_id);
    store_dir.deleteFile(self.io, &blob_id_str) catch |err| {
        return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    };
}

fn open_store_dir(self: *Self, store_id: StoreId) !Dir {
    const options: Dir.OpenOptions = .{.iterate = true,
                                       .follow_symlinks = false};
    return self.base_dir.openDir(self.io, store_id.id, options)
        catch |err| switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
}
