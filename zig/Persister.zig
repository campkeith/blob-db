const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;
const Allocator = std.mem.Allocator;

const ty = @import("types.zig");
const Err = ty.Err;
const StoreId = ty.StoreId;
const Response = ty.Response;

const log = @import("log.zig");
const fmt = @import("format.zig");
const fns = @import("functions.zig");
const trash = @import("trash.zig");
const Blob = @import("Blob.zig");

const Self = @This();
const TempName = [16]u8;

io: std.Io,
base_dir: Dir,
rng: std.Random.DefaultPrng,

pub const create = log.call(Self, "create", createInner);
fn createInner(init: std.process.Init) !Self {
    const base_dir_str = try fns.getEnv(init.environ_map, "BASE_DIR");
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

pub const destroy = log.call(Self, "destroy", destroyInner);
fn destroyInner(self: *Self) void {
    self.base_dir.close(self.io);
}

pub fn format(self: Self, out: *std.Io.Writer) !void {
    return fmt.structOpaque(self, out);
}

pub const storeList = log.call(Self, "store_list", storeListInner);
fn storeListInner(self: *Self, arena: Allocator) ![]StoreId {
    var list: std.ArrayList(StoreId) = .empty;
    errdefer trash.recycleArrayList(&list, arena);
    var iterator = self.base_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .directory) {
            fns.println("store_list: Ignoring {t} entry \"{s}\"",
                          .{entry.kind, entry.name});
            continue;
        }
        const store_id = try StoreId.create(arena, entry.name);
        errdefer trash.recycle(store_id, arena);
        try list.append(arena, store_id);
    }
    return try list.toOwnedSlice(arena);
}

pub const storeCreate = log.call(Self, "storeCreate", storeCreateInner);
fn storeCreateInner(self: *Self, store_id: StoreId) !void {
    self.base_dir.createDir(self.io, store_id.id, .default_dir)
        catch |err| return switch (err) {
            error.PathAlreadyExists => Err.Exists,
            error.NoSpaceLeft => Err.NoSpace,
            else => err,
        };
}

pub const storeDestroy = log.call(Self, "storeDestroy", storeDestroyInner);
fn storeDestroyInner(self: *Self, store_id: StoreId) !void {
    const temp_dirname = self.tempName();
    self.base_dir.rename(store_id.id, self.base_dir, &temp_dirname, self.io)
        catch |err| return switch (err) {
            error.FileNotFound => Err.NotFound,
            else => err,
        };
    try self.base_dir.deleteTree(self.io, &temp_dirname);
}

pub const blobList = log.call(Self, "blob_list", blobListInner);
fn blobListInner(self: *Self, arena: Allocator, store_id: StoreId) ![]Blob.Id {
    var list: std.ArrayList(Blob.Id) = .empty;
    errdefer list.deinit(arena);
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);
    var iterator = store_dir.iterate();
    while (try iterator.next(self.io)) |entry| {
        if (entry.kind != .file) {
            fns.println("blob_list: Ignoring {t} entry \"{s}\"",
                          .{entry.kind, entry.name});
            continue;
        }
        const blob_id = try nameToBlobId(entry.name);
        try list.append(arena, blob_id);
    }
    return try list.toOwnedSlice(arena);
}

pub const blobInfo = log.call(Self, "blob_info", blobInfoInner);
fn blobInfoInner(self: *Self, store_id: StoreId, blob_id: Blob.Id) !Blob.Size {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = Blob.idToStr(blob_id);
    const opts: Dir.StatFileOptions = .{
        .follow_symlinks = false,
    };
    const stat = store_dir.statFile(self.io, &blob_id_str, opts)
        catch |err| return switch (err) {
            error.FileNotFound => Err.NotFound,
            else => err,
        };
    return stat.size;
}

pub const blobLoad = log.call(Self, "blob_load", blobLoadInner);
fn blobLoadInner(self: *Self, store_id: StoreId, blob_id: Blob.Id) !Blob {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);
    const blob_id_str = Blob.idToStr(blob_id);
    const opts: Dir.OpenFileOptions = .{
        .allow_directory = false
    };
    const file = store_dir.openFile(self.io, &blob_id_str, opts)
        catch |err| return switch (err) {
            error.FileNotFound => Err.NotFound,
            else => err,
        };
    errdefer file.close(self.io);
    return Blob.initFile(file, self.io);
}

pub const blobSave = log.call(Self, "blob_save", blobSaveInner);
fn blobSaveInner(self: *Self, store_id: StoreId, blob: Blob)
        !Response.SaveStatusBlobId {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);

    const temp_filename = self.tempName();
    const opts = Dir.CreateFileOptions{
        .read = true,
        .exclusive = true,
    };
    var file = try store_dir.createFile(self.io, &temp_filename, opts);
    errdefer store_dir.deleteFile(self.io, &temp_filename) catch |err|
        fns.println("blob_save: temp file remove failed due to {t}.", .{err});
    defer file.close(self.io);

    const size = try blob.size();
    try file.setLength(self.io, size);

    const mmap_opts: File.MemoryMap.CreateOptions = .{
        .len = size,
    };
    var blob_out = file.createMemoryMap(self.io, mmap_opts)
        catch |err| return switch (err) {
            error.OutOfMemory => Err.NoSpace,
            else => err,
        };
    defer blob_out.destroy(self.io);

    const blob_id = try blob.hashCopy(blob_out.memory);
    const blob_id_str = Blob.idToStr(blob_id);
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

pub const blobDelete = log.call(Self, "blob_delete", blobDeleteInner);
fn blobDeleteInner(self: *Self, store_id: StoreId, blob_id: Blob.Id) !void {
    var store_dir = try self.openStoreDir(store_id);
    defer store_dir.close(self.io);

    const blob_id_str = Blob.idToStr(blob_id);
    store_dir.deleteFile(self.io, &blob_id_str)
        catch |err| return switch (err) {
            error.FileNotFound => Err.NotFound,
            else => err,
        };
}

fn openStoreDir(self: *Self, store_id: StoreId) !Dir {
    const options: Dir.OpenOptions = .{.iterate = true,
                                       .follow_symlinks = false};
    return self.base_dir.openDir(self.io, store_id.id, options)
        catch |err| switch (err) {
            error.FileNotFound => Err.NotFound,
            else => err,
        };
}

fn nameToBlobId(name: []const u8) !Blob.Id {
    if (name.len != 64) {
        fns.println("nameToBlobId: invalid length name: \"{s}\"\n", .{name});
        return Err.Internal;
    }
    return Blob.strToId(std.mem.bytesToValue(Blob.IdStr, name));
}

fn tempName(self: *Self) TempName {
    var name: TempName = undefined;
    fns.randomName(self.rng.random(), &name);
    return name;
}
