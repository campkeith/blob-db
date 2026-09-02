const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;

const ty = @import("types.zig");
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;
const Blob = ty.Blob;
const BlobSize = ty.BlobSize;

const log = @import("log.zig");
const mem = @import("mem.zig");
const funcs = @import("funcs.zig");

const Self = @This();

io: std.Io,
base_dir: Dir,

pub const create = log.call(Self, "create", _create);
fn _create(init: std.process.Init) !Self {
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

pub const destroy = log.call(Self, "destroy", _destroy);
fn _destroy(self: *Self) void {
    self.base_dir.close(self.io);
}

pub const store_list = log.call(Self, "store_list", _store_list);
fn _store_list(self: *Self) !ty.StoreIds {
    var list: std.ArrayList(StoreId) = .empty;
    errdefer {
        for (list.items) |item| {
            mem.free(item.id);
        }
        list.deinit(mem.allocator);
    }
    var iterator = self.base_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .directory) {
            funcs.debug("store_list: Ignoring {any} entry '{s}'\n",
                        .{entry.kind, entry.name});
            continue;
        }
        const name = try mem.dupe(u8, entry.name);
        errdefer mem.free(name);
        try list.append(mem.allocator, .init(name));
    }
    return try list.toOwnedSlice(mem.allocator);
}

pub const store_create = log.call(Self, "store_create", _store_create);
fn _store_create(self: *Self, store_id: StoreId) !void {
    self.base_dir.createDir(self.io, store_id.id, .default_dir) catch |err|
        return switch (err) {
            error.PathAlreadyExists => ty.Err.Exists,
            error.NoSpaceLeft => ty.Err.NoSpace,
            else => err,
        };
}

pub const store_destroy = log.call(Self, "store_destroy", _store_destroy);
fn _store_destroy(self: *Self, store_id: StoreId) !void {
    // FIXME: randomly generate
    const tmp_dirname = "whatever";
    self.base_dir.rename(store_id.id, self.base_dir, tmp_dirname, self.io)
        catch |err| return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    try self.base_dir.deleteTree(self.io, tmp_dirname);
}

pub const blob_list = log.call(Self, "blob_list", _blob_list);
fn _blob_list(self: *Self, store_id: StoreId) !ty.BlobIds {
    var list: std.ArrayList(BlobId) = .empty;
    errdefer list.deinit(mem.allocator);
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);
    var iterator = store_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .file) {
            funcs.debug("blob_list: Ignoring {any} entry '{s}'\n",
                        .{entry.kind, entry.name});
            continue;
        }
        const blob_id = try funcs.hashHexToBytes(entry.name);
        try list.append(mem.allocator, blob_id);
    }
    return try list.toOwnedSlice(mem.allocator);
}

pub const blob_info = log.call(Self, "blob_info", _blob_info);
fn _blob_info(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob.Size {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    const opts: Dir.StatFileOptions = .{
        .follow_symlinks = false,
    };
    const stat = store_dir.statFile(self.io, &blob_id_str, opts) catch |err|
        return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
        };
    return stat.size;
}

pub const blob_load = log.call(Self, "blob_load", _blob_load);
fn _blob_load(self: *Self, store_id: StoreId, blob_id: BlobId) !Blob {
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
    return .{.file = .{
        .file = file,
        .io = self.io,
    }};
}

pub const blob_save = log.call(Self, "blob_save", _blob_save);
fn _blob_save(self: *Self, store_id: StoreId, blob: Blob)
        !ty.Response.SaveStatusBlobId {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);

    const opts = Dir.CreateFileOptions{
        .read = true,
        .exclusive = true,
    };
    // FIXME: generate random string
    const tmp_filename = "whatever";
    var file = try store_dir.createFile(self.io, tmp_filename, opts);
    errdefer store_dir.deleteFile(self.io, tmp_filename) catch |err|
        funcs.debug("blob_save: temp file remove failed due to {}\n.", .{err});
    defer file.close(self.io);

    const size = try funcs.blobSize(blob);
    try file.setLength(self.io, size);

    const mmap_opts: File.MemoryMap.CreateOptions = .{
        .len = size,
    };
    var blob_out = file.createMemoryMap(self.io, mmap_opts) catch |err|
        return switch (err) {
            error.OutOfMemory => ty.Err.NoSpace,
            else => err,
        };
    defer blob_out.destroy(self.io);

    const blob_id = try funcs.hashCopyBlob(blob, blob_out.memory);
    const blob_id_str = funcs.hashBytesToHex(blob_id);
    store_dir.renamePreserve(tmp_filename, store_dir, &blob_id_str, self.io)
        catch |err| return switch (err) {
            error.PathAlreadyExists => out: {
                try store_dir.deleteFile(self.io, tmp_filename);
                break :out .init(.exists, blob_id);
            },
            else => err,
        };
    return .init(.created, blob_id);
}

pub const blob_delete = log.call(Self, "blob_delete", _blob_delete);
fn _blob_delete(self: *Self, store_id: StoreId, blob_id: BlobId) !void {
    var store_dir = try self.open_store_dir(store_id);
    defer store_dir.close(self.io);

    const blob_id_str = funcs.hashBytesToHex(blob_id);
    store_dir.deleteFile(self.io, &blob_id_str) catch |err|
        return switch (err) {
            error.FileNotFound => ty.Err.NotFound,
            else => err,
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
