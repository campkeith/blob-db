const std = @import("std");

const funcs = @import("funcs.zig");
const ty = @import("types.zig");

pub const Persister = struct {
    base_dir: ty.Dir,
    io: ty.Io,

    pub fn create(init: ty.Init) !Persister {
        const base_dir_str = try funcs.getEnv(init.environ_map, "BASE_DIR");
        const base_dir = try ty.Dir.cwd().openDir(init.io, base_dir_str,
            .{.iterate = true, .follow_symlinks = false});
        return .{
            .base_dir = base_dir,
            .io = init.io,
        };
    }

    pub fn destroy(self: *Persister) void {
        self.base_dir.close(self.io);
    }

    pub fn store_list(self: *Persister) !ty.StoreIds {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| {
                funcs.allocator.free(item);
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
            try list.append(funcs.allocator, name);
        }
        return try list.toOwnedSlice(funcs.allocator);
    }

    pub fn store_create(self: *Persister, store_id: ty.StoreId) !void {
        self.base_dir.createDir(self.io, store_id, .default_dir) catch |err| {
            return switch (err) {
                error.PathAlreadyExists => ty.Err.Exists,
                error.NoSpaceLeft => ty.Err.NoSpace,
                else => err,
            };
        };
    }

    pub fn store_destroy(self: *Persister, store_id: ty.StoreId) !void {
        self.base_dir.deleteTree(self.io, store_id) catch |err| {
            return switch (err) {
                // FIXME: this doesn't seem to exist
                // error.FileNotFound => ty.Err.NotFound,
                else => err,
            };
        };
    }

    pub fn blob_list(self: *Persister, store_id: ty.StoreId) !ty.BlobIds {
        var list: std.ArrayList(ty.BlobId) = .empty;
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

    pub fn blob_info(self: *Persister, store_id: ty.StoreId, blob_id: ty.BlobId)
            !ty.BlobSize {
        var store_dir = try self.open_store_dir(store_id);
        defer store_dir.close(self.io);
        const blob_id_str = funcs.hashBytesToHex(blob_id);
        const opts: ty.Dir.StatFileOptions = .{.follow_symlinks = false};
        const stat = store_dir.statFile(self.io, &blob_id_str, opts) catch |err| {
            return switch (err) {
                error.FileNotFound => ty.Err.NotFound,
                else => err,
            };
        };
        return stat.size;
    }

    pub fn blob_load(self: *Persister, store_id: ty.StoreId, blob_id: ty.BlobId)
            !ty.BlobFile {
        var store_dir = try self.open_store_dir(store_id);
        defer store_dir.close(self.io);
        const blob_id_str = funcs.hashBytesToHex(blob_id);
        const opts: ty.Dir.OpenFileOptions = .{.allow_directory = false};
        return store_dir.openFile(self.io, &blob_id_str, opts) catch |err|
            switch (err) {
                error.FileNotFound => ty.Err.NotFound,
                else => err,
            };
    }

    pub fn blob_save(self: *Persister, store_id: ty.StoreId,
            blob_in: *ty.BlobStream) !struct {ty.SaveStatus, ty.BlobId} {
        var store_dir = try self.open_store_dir(store_id);
        defer store_dir.close(self.io);

        var file = try store_dir.createFileAtomic(self.io, "", .{});
        defer file.deinit(self.io);
        try file.file.setLength(self.io, blob_in.bytes_remain);

        const mmap_opts: ty.File.MemoryMap.CreateOptions =
            .{.len = blob_in.bytes_remain};
        var blob_out = file.file.createMemoryMap(self.io, mmap_opts) catch |err| {
            return switch (err) {
                error.OutOfMemory => ty.Err.NoSpace,
                else => err,
            };
        };
        defer blob_out.destroy(self.io);

        const blob_id = try funcs.hashCopyStream(&blob_in.stream, blob_out.memory);
        file.dest_sub_path = &funcs.hashBytesToHex(blob_id);
        file.link(self.io) catch |err| {
            return switch (err) {
                error.PathAlreadyExists => .{.exists, blob_id},
                else => err,
            };
        };
        return .{.created, blob_id};
    }

    pub fn blob_delete(self: *Persister, store_id: ty.StoreId, blob_id: ty.BlobId)
            !void {
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

    fn open_store_dir(self: *Persister, store_id: ty.StoreId) !ty.Dir {
        const options: ty.Dir.OpenOptions = .{.iterate = true,
                                              .follow_symlinks = false};
        return self.base_dir.openDir(self.io, store_id, options)
            catch |err| switch (err) {
                error.FileNotFound => ty.Err.NotFound,
                else => err,
            };
    }
};
