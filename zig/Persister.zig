const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

const ty = @import("types.zig");
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const Blob = ty.Blob;
const BlobSize = ty.BlobSize;

const log = @import("log.zig");
const debug = @import("debug.zig");
const funcs = @import("funcs.zig");
const trash = @import("trash.zig");

const Self = @This();
const TempName = [16]u8;

io: std.Io,
base_dir: Dir,
rng: std.Random.DefaultPrng,

pub const create = log.call(Self, "create", _create);
fn _create(init: std.process.Init) !Self {
    const base_dir_str = try funcs.getEnv(init.environ_map, "BASE_DIR");
    const opts: Dir.OpenOptions = .{
        .iterate = true,
        .follow_symlinks = false,
    };
    const base_dir = try Dir.cwd().openDir(init.io, base_dir_str, opts);
    errdefer base_dir.close(init.io);
    return .{
        .io = init.io,
        .base_dir = base_dir,
        .rng = .init(0),
    };
}

pub const destroy = log.call(Self, "destroy", _destroy);
fn _destroy(self: *Self) void {
    self.base_dir.close(self.io);
}

pub fn format(self: Self, out: *std.Io.Writer) !void {
    return debug.formatStructOpaque(self, out);
}

pub const storeList = log.call(Self, "store_list", _storeList);
fn _storeList(self: *Self, arena: Allocator) !ty.StoreIds {
    var list: std.ArrayList(StoreId) = .empty;
    errdefer trash.recycleArrayList(&list, arena);
    var iterator = self.base_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .directory) {
            funcs.println("store_list: Ignoring {t} entry \"{s}\"",
                          .{entry.kind, entry.name});
            continue;
        }
        const store_id = try StoreId.create(arena, entry.name);
        errdefer trash.recycle(store_id, arena);
        try list.append(arena, store_id);
    }
    return try list.toOwnedSlice(arena);
}

pub const storeCreate = log.call(Self, "storeCreate", _storeCreate);
fn _storeCreate(self: *Self, store_id: StoreId) !void {
    self.base_dir.createDir(self.io, store_id.id, .default_dir)
        catch |err| return switch (err) {
            error.PathAlreadyExists => ty.Err.Exists,
            error.NoSpaceLeft => ty.Err.NoSpace,
            else => err,
        };
}

pub const storeDestroy = log.call(Self, "storeDestroy", _storeDestroy);
fn _storeDestroy(self: *Self, store_id: StoreId) !void {
    const temp_dirname = self.tempName();
    self.base_dir.rename(store_id.id, self.base_dir, &temp_dirname, self.io)
        catch |err| return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    try self.base_dir.deleteTree(self.io, &temp_dirname);
}

pub const blobList = log.call(Self, "blob_list", _blobList);
fn _blobList(self: *Self, arena: Allocator, store_id: StoreId) !ty.BlobIds {
    var list: std.ArrayList(BlobId) = .empty;
    errdefer list.deinit(arena);
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);
    var iterator = store_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .file) {
            funcs.println("blob_list: Ignoring {t} entry \"{s}\"",
                          .{entry.kind, entry.name});
            continue;
        }
        const blob_id = try nameToBlobId(entry.name);
        try list.append(arena, blob_id);
    }
    return try list.toOwnedSlice(arena);
}

pub const blobInfo = log.call(Self, "blob_info", _blobInfo);
fn _blobInfo(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob.Size {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    const opts: Dir.StatFileOptions = .{
        .follow_symlinks = false,
    };
    const stat = store_dir.statFile(self.io, &blob_id_str, opts)
        catch |err| return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    return stat.size;
}

pub const blobLoad = log.call(Self, "blob_load", _blobLoad);
fn _blobLoad(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    const opts: Dir.OpenFileOptions = .{
        .allow_directory = false
    };
    const file = store_dir.openFile(self.io, &blob_id_str, opts)
        catch |err| return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    errdefer file.close(self.io);
    return Blob.initFile(file, self.io);
}

pub const blobSave = log.call(Self, "blob_save", _blobSave);
fn _blobSave(self: *Self, store_id: StoreId, blob: Blob)
        !ty.Response.SaveStatusBlobId {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);

    const temp_filename = self.tempName();
    const opts = Dir.CreateFileOptions{
        .read = true,
        .exclusive = true,
    };
    var file = try store_dir.createFile(self.io, &temp_filename, opts);
    errdefer store_dir.deleteFile(self.io, &temp_filename) catch |err|
        funcs.println("blob_save: temp file remove failed due to {t}.", .{err});
    defer file.close(self.io);

    const size = try blob.size();
    try file.setLength(self.io, size);

    const mmap_opts: File.MemoryMap.CreateOptions = .{
        .len = size,
    };
    var blob_out = file.createMemoryMap(self.io, mmap_opts)
        catch |err| return switch (err) {
            error.OutOfMemory => ty.Err.NoSpace,
            else => err,
        };
    defer blob_out.destroy(self.io);

    const blob_id = try funcs.hashCopyBlob(blob, blob_out.memory);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    store_dir.renamePreserve(&temp_filename, store_dir, &blob_id_str, self.io)
        catch |err| return switch (err) {
            error.PathAlreadyExists => out: {
                try store_dir.deleteFile(self.io, &temp_filename);
                break :out .init(.exists, blob_id);
            },
            else => err,
        };
    return .init(.created, blob_id);
}

pub const blobDelete = log.call(Self, "blob_delete", _blobDelete);
fn _blobDelete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);

    const blob_id_str = funcs.hashBytesToHex(blob_id);
    store_dir.deleteFile(self.io, &blob_id_str)
        catch |err| return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
}

fn openStoreDir(self: *Self, store_id: StoreId) !Dir {
    const options: Dir.OpenOptions = .{.iterate = true,
                                       .follow_symlinks = false};
    return self.base_dir.openDir(self.io, store_id.id, options)
        catch |err| switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
}

fn nameToBlobId(name: []const u8) !BlobId {
    if (name.len != 64) {
        funcs.println("nameToBlobId: invalid length name: \"{s}\"\n", .{name});
        return ty.Err.Internal;
    }
    return funcs.hashHexToBytes(std.mem.bytesToValue(ty.BlobIdStr, name));
}

fn tempName(self: *Self) TempName {
    var name: TempName = undefined;
    funcs.randomName(self.rng.random(), &name);
    return name;
}
