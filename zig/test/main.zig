const std = @import("std");
const testing = std.testing;

const ty = @import("blob-db/types.zig");
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;

const mem = @import("blob-db/mem.zig");
const funcs = @import("blob-db/funcs.zig");
const debug = @import("blob-db/debug.zig");
const Client = @import("blob-db/Client.zig");

const fake = @import("fake.zig");

const Args = struct {
    address: []const u8,
    iterations: u64,
};

pub fn main(init: std.process.Init) !void {
    const args = parse_args(init.minimal.args);
    var client = try Client.connect(init.io, args.address);
    defer client.close();
    var db = TestRig.Db.init(mem.allocator);
    defer db.deinit();
    var rng_impl = std.Random.DefaultPrng.init(0);
    var rng = rng_impl.random();
    var rig = TestRig{
        .client = &client,
        .db = &db,
        .rng = &rng,
    };
    try go(&rig, args.iterations);
}

fn parse_args(args: std.process.Args) Args {
    const args_vec = args.vector;
    const program = args_vec[0];
    return parse_core_args(args_vec[1..]) catch {
        funcs.debug("Usage: {s} <address>:<port> <iterations>\n", .{program});
        std.process.exit(1);
    };
}

fn parse_core_args(args: std.process.Args.Vector) !Args {
    if (args.len != 2) {
        return ty.Err.BadArgument;
    }
    const address, const iterations_str = args[0..2].*;
    const span = std.mem.span;
    return .{
        .address = span(address),
        .iterations = try std.fmt.parseInt(u64, span(iterations_str), 10),
    };
}

const TestRig = struct {
    const MIN_STORE_ID_SIZE: usize = 8;
    const MAX_STORE_ID_SIZE: usize = 32;
    const MIN_BLOB_SIZE: usize = 8;
    const MAX_BLOB_SIZE: usize = 1 << 20;
    const LOAD_PERCENT = std.hash_map.default_max_load_percentage;

    const Db = std.HashMap(StoreId, Store, StoreIdHasher, LOAD_PERCENT);
    const Store = std.HashMap(BlobId, fake.Blob, BlobIdHasher, LOAD_PERCENT);

    client: *Client,
    db: *Db,
    rng: *std.Random,
};

const StoreIdHasher = HasherFromKeyFunc(struct {
    pub fn key(store_id: *const StoreId) []const u8 {
        return store_id.id;
    }
});

const BlobIdHasher = HasherFromKeyFunc(struct {
    pub fn key(blob_id: *const BlobId) []const u8 {
        return blob_id;
    }
});

fn HasherFromKeyFunc(KeyFunc: type) type {
    return struct {
        pub fn hash(_: @This(), key: anytype) u64 {
            return std.hash.Wyhash.hash(0, KeyFunc.key(&key));
        }

        pub fn eql(_: @This(), a: anytype, b: anytype) bool {
            return std.mem.eql(u8, KeyFunc.key(&a), KeyFunc.key(&b));
        }
    };
}

fn go(rig: *TestRig, iterations: u64) !void {
    const Func = *const fn (*TestRig) anyerror!void;
    const Weight = f32;

    const FuncWeightPair = struct {Func, Weight};
    const ops = [_]FuncWeightPair{
        .{test_store_list, 0.2},
        .{test_store_create, 0.2},
        .{test_store_destroy, 0.1},
        .{test_blob_hash, 1},
        .{test_blob_list, 2},
        .{test_blob_info, 1},
        .{test_blob_load, 1},
        .{test_blob_save, 1},
        .{test_blob_delete, 1},
    };
    const weights = unzip_col(ops, 1);
    try test_store_list(rig);
    for (0..iterations) |_| {
        const index = rig.rng.weightedIndex(Weight, &weights);
        const op, _ = ops[index];
        try op(rig);
    }
    while (rig.db.count() != 0) {
        try test_store_destroy(rig);
    }
}

fn unzip_col(matrix: anytype, comptime index: usize)
        [matrix.len]@TypeOf(matrix[0][index]) {
    var out: [matrix.len]@TypeOf(matrix[0][index]) = undefined;
    for (matrix, &out) |row, *out_elem| out_elem.* = row[index];
    return out;
}

fn test_store_list(rig: *TestRig) anyerror!void {
    const exp_store_ids = try sorted_map_keys(StoreId, rig.db);
    defer mem.free(exp_store_ids);
    const store_ids = try rig.client.store_list();
    sort_matrix(StoreId, store_ids);
    try testing.expectEqualDeep(exp_store_ids, store_ids);
}

fn test_store_create(rig: *TestRig) anyerror!void {
    const store_id, const in_db = try random_store(rig);
    const exp_result = if (in_db) ty.Err.Exists
                       else {};
    const result = rig.client.store_create(store_id);
    try testing.expectEqual(exp_result, result);
    if (!in_db) {
        var store = TestRig.Store.init(mem.allocator);
        errdefer store.deinit();
        try rig.db.putNoClobber(store_id, store);
    }
}

fn test_store_destroy(rig: *TestRig) anyerror!void {
    const store_id, const in_db = try random_store(rig);
    const exp_result = if (in_db) {}
                       else ty.Err.NotFound;
    const result = rig.client.store_destroy(store_id);
    try testing.expectEqual(exp_result, result);
    if (in_db) db_remove(rig.db, store_id);
}

fn test_blob_hash(rig: *TestRig) anyerror!void {
    const blob = try fake.blob(rig.rng, TestRig.MIN_BLOB_SIZE,
                                        TestRig.MAX_BLOB_SIZE);
    defer mem.free(blob);
    const exp_blob_id = funcs.hashMemory(blob);
    const blob_id = rig.client.blob_hash(.{.memory = blob});
    try testing.expectEqual(exp_blob_id, blob_id);
}

fn test_blob_list(rig: *TestRig) anyerror!void {
    const store_id, const in_db = try random_store(rig);
    const exp_result =
        if (in_db) try sorted_map_keys(BlobId, rig.db.getPtr(store_id).?)
        else ty.Err.NotFound;
    defer if (exp_result) |blob_ids| mem.free(blob_ids) else |_| {};
    const result = rig.client.blob_list(store_id);
    if (result) |blob_ids| {
        sort_matrix(BlobId, blob_ids);
    } else |_| {}
    try testing.expectEqualDeep(exp_result, result);
}

fn test_blob_info(rig: *TestRig) anyerror!void {
    const store_id, _, const blob_id, const blob_ok = try random_store_blob(rig);
    const exp_result = if (blob_ok) rig.db.getPtr(store_id).?.get(blob_id).?.len
                       else ty.Err.NotFound;
    const result = rig.client.blob_info(store_id, blob_id);
    try testing.expectEqual(exp_result, result);
}

fn test_blob_load(rig: *TestRig) anyerror!void {
    const store_id, _, const blob_id, const blob_ok = try random_store_blob(rig);
    const exp_result = if (blob_ok) rig.db.getPtr(store_id).?.get(blob_id).?
                       else ty.Err.NotFound;
    const result_stream = rig.client.blob_load(store_id, blob_id);
    const result = if (result_stream) |stream| try slurp(stream.stream)
                   else |err| err;
    defer if (result) |blob| mem.free(blob) else |_| {};
    try testing.expectEqualDeep(exp_result, result);
}

fn test_blob_save(rig: *TestRig) anyerror!void {
    const store_id, const store_ok, const sel_blob_id, const blob_ok =
        try random_store_blob(rig);
    const exp_blob_id, const blob =
        if (blob_ok) blob: {
            const store = rig.db.getPtr(store_id).?;
            const blob = store.get(sel_blob_id).?;
            break :blob .{sel_blob_id, blob};
        } else blob: {
            const blob = try fake.blob(rig.rng, TestRig.MIN_BLOB_SIZE,
                                                TestRig.MAX_BLOB_SIZE);
            errdefer mem.free(blob);
            const blob_id = funcs.hashMemory(blob);
            break :blob .{blob_id, blob};
        };
    defer if (!store_ok) mem.free(blob);
    errdefer if (store_ok and !blob_ok) mem.free(blob);
    const result = rig.client.blob_save(store_id, .{.memory = blob});
    const Pair = funcs.pairGen(bool, bool);
    const exp_result: @TypeOf(result) = switch (Pair.make(store_ok, blob_ok)) {
        Pair.make(true, false) => .init(.created, exp_blob_id),
        Pair.make(true, true) => .init(.exists, exp_blob_id),
        else => ty.Err.NotFound,
    };
    try testing.expectEqual(exp_result, result);
    if (store_ok and !blob_ok) {
        const store = rig.db.getPtr(store_id).?;
        try store.putNoClobber(exp_blob_id, blob);
    }
}

fn test_blob_delete(rig: *TestRig) anyerror!void {
    const store_id, _, const blob_id, const blob_ok = try random_store_blob(rig);
    const exp_result = if (blob_ok) {}
                       else ty.Err.NotFound;
    const result = rig.client.blob_delete(store_id, blob_id);
    try testing.expectEqual(exp_result, result);
    if (blob_ok) store_remove(rig.db.getPtr(store_id).?, blob_id);
}

fn slurp(stream: *ty.Blob.Stream) !fake.Blob {
    const blob = try mem.alloc(u8, stream.bytes_left);
    errdefer mem.free(blob);
    try stream.reader.readSliceAll(blob);
    return blob;
}

fn db_remove(db: *TestRig.Db, store_id: StoreId) void {
    const store = db.getPtr(store_id).?;
    free_store(store);
    const item = db.fetchRemove(store_id) orelse unreachable;
    mem.free(item.key.id);
}

fn free_store(store: *TestRig.Store) void {
    var val_iter = store.valueIterator();
    while (val_iter.next()) |blob| {
        mem.free(blob.*);
    }
    store.deinit();
}

fn store_remove(store: *TestRig.Store, blob_id: BlobId) void {
    if (store.fetchRemove(blob_id)) |item| {
        mem.free(item.value);
    }
}

fn random_store_blob(rig: *TestRig) !struct {StoreId, bool, BlobId, bool} {
    const store_id, const store_ok = try random_store_with_p(rig, 0.8);
    const blob_id, const blob_ok =
        if (store_ok) blob: {
            const store = rig.db.getPtr(store_id).?;
            const blob_ok = store.count() != 0 and rig.rng.float(f32) > 0.8;
            break :blob
                if (blob_ok) .{try map_choose(rig.rng, store, BlobId), true}
                else .{fake.blob_id(rig.rng), false};
        } else .{fake.blob_id(rig.rng), false};
    return .{store_id, store_ok, blob_id, blob_ok};
}

fn random_store(rig: *TestRig) !struct {StoreId, bool} {
    return try random_store_with_p(rig, 0.6);
}

fn random_store_with_p(rig: *TestRig, in_db_p: f32) !struct {StoreId, bool} {
    const in_db = rig.db.count() != 0 and rig.rng.float(f32) < in_db_p;
    const store_id = if (in_db) try map_choose(rig.rng, rig.db, StoreId)
                     else try fake.store_id(rig.rng, TestRig.MIN_STORE_ID_SIZE,
                                                     TestRig.MAX_STORE_ID_SIZE);
    return .{store_id, in_db};
}

fn sorted_map_keys(Key: type, map: anytype) ![]Key {
    const size = map.count();
    const out = try mem.alloc(Key, size);
    var map_iter = map.keyIterator();
    for (out) |*elem| {
        elem.* = map_iter.next().?.*;
    }
    std.debug.assert(map_iter.next() == null);
    sort_matrix(Key, out);
    return out;
}

fn sort_matrix(Row: type, matrix: []Row) void {
    switch (Row) {
        StoreId => std.mem.sort(StoreId, matrix, {}, storeIdLessThan),
        BlobId => std.mem.sort(BlobId, matrix, {}, blobIdLessThan),
        else => unreachable,
    }
}

fn storeIdLessThan(_: void, a: StoreId, b: StoreId) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn blobIdLessThan(_: void, a: BlobId, b: BlobId) bool {
    return std.mem.lessThan(u8, &a, &b);
}

fn map_choose(rng: *std.Random, map: anytype, Val: type) !Val {
    const index = rng.uintLessThan(usize, map.count());
    return map_index(map, index, Val);
}

fn map_index(map: anytype, index: usize, Val: type) !Val {
    var map_iter = map.keyIterator();
    for (0 .. index) |_| {
        _ = map_iter.next().?;
    }
    return map_iter.next().?.*;
}
