const std = @import("std");
const Random = std.Random;
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ty = @import("blob-db/types.zig");
const Err = ty.Err;
const StoreId = ty.StoreId;

const fns = @import("blob-db/functions.zig");
const trash = @import("blob-db/trash.zig");
const struct_ = @import("blob-db/struct_.zig");
const Blob = @import("blob-db/Blob.zig");
const Client = @import("blob-db/Client.zig");

const fake = @import("fake.zig");

const Args = struct {
    address: []const u8,
    iterations: u64,
};

pub fn main(init: std.process.Init) !void {
    const args = parseArgs(init.minimal.args);
    var client = try Client.connect(init.io, init.gpa, args.address);
    defer client.close(init.gpa);
    var db = TestRig.Db.init(init.gpa);
    defer trash.recycle(&db, init.gpa);
    var rng = Random.DefaultPrng.init(0);
    var rig = TestRig{
        .client = &client,
        .db = &db,
        .arena = init.gpa,
        .rng = rng.random(),
    };
    try go(&rig, args.iterations);
}

fn parseArgs(args: std.process.Args) Args {
    const args_vec = args.vector;
    const program = args_vec[0];
    return parseCoreArgs(args_vec[1..]) catch {
        fns.println("Usage: {s} <address>:<port> <iterations>", .{program});
        std.process.exit(1);
    };
}

fn parseCoreArgs(args: std.process.Args.Vector) !Args {
    if (args.len != 2) {
        return Err.BadArgument;
    }
    const address, const iterations_str = args[0..2].*;
    const span = std.mem.span;
    return .{
        .address = span(address),
        .iterations = try std.fmt.parseInt(u64, span(iterations_str), 10),
    };
}

const TestRig = struct {
    const min_store_id_size: usize = 8;
    const max_store_id_size: usize = 32;
    const min_blob_size: usize = 8;
    const max_blob_size: usize = 1 << 20;
    const load_percent = std.hash_map.default_max_load_percentage;

    const Db = std.HashMap(StoreId, Store, StoreIdHasher, load_percent);
    const Store = std.HashMap(Blob.Id, fake.Blob, BlobIdHasher, load_percent);

    client: *Client,
    db: *Db,
    arena: Allocator,
    rng: Random,

    const StoreIdHasher = HasherFromKeyFunc(StoreId, storeIdKey);
    const BlobIdHasher = HasherFromKeyFunc(Blob.Id, blobIdKey);

    fn storeIdKey(storeId: *const StoreId) []const u8 {
        return storeId.id;
    }

    fn blobIdKey(blobId: *const Blob.Id) []const u8 {
        return blobId;
    }
};

fn HasherFromKeyFunc(Key: type, keyFunc: fn(*const Key) []const u8) type {
    return struct {
        pub fn hash(_: @This(), key: anytype) u64 {
            return std.hash.Wyhash.hash(0, keyFunc(&key));
        }

        pub fn eql(_: @This(), a: anytype, b: anytype) bool {
            return std.mem.eql(u8, keyFunc(&a), keyFunc(&b));
        }
    };
}

const TestFunc = *const fn (*TestRig, Allocator) anyerror!void;

fn go(rig: *TestRig, iterations: u64) !void {
    const Weight = f32;

    const FuncWeightPair = struct {
        func: TestFunc,
        weight: Weight,
        const init = record.init(@This());
    };
    const ops = [_]FuncWeightPair{
        .init(testStoreList, 0.2),
        .init(testStoreCreate, 0.2),
        .init(testStoreDestroy, 0.1),
        .init(testBlobHash, 1),
        .init(testBlobList, 2),
        .init(testBlobInfo, 1),
        .init(testBlobLoad, 1),
        .init(testBlobSave, 1),
        .init(testBlobDelete, 1),
    };
    const weights = fns.map(ops, fns.structField(FuncWeightPair, "weight"));
    try testFuncArena(testStoreList, rig);
    for (0..iterations) |_| {
        const index = rig.rng.weightedIndex(Weight, &weights);
        try testFuncArena(ops[index].func, rig);
    }
    while (rig.db.count() != 0) {
        try testFuncArena(testStoreDestroy, rig);
    }
}

fn testFuncArena(func: TestFunc, rig: *TestRig) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(rig.arena);
    defer arena.deinit();
    try func(rig, arena.allocator());
}

// Let testFuncArena free the allocations for the functions below.

fn testStoreList(rig: *TestRig, arena: Allocator) anyerror!void {
    const exp_storeIds = try sortedMapKeys(StoreId, rig.db, arena);
    const storeIds = try rig.client.storeList(arena);
    sortMatrix(StoreId, storeIds);
    try testing.expectEqualDeep(exp_storeIds, storeIds);
}

fn testStoreCreate(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const in_db = try randomStore(rig, arena);
    const exp_result = if (in_db) Err.Exists
                       else {};
    const result = rig.client.storeCreate(storeId);
    try testing.expectEqual(exp_result, result);
    if (!in_db) try dbAdd(rig.db, rig.arena, storeId);
}

fn testStoreDestroy(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const in_db = try randomStore(rig, arena);
    const exp_result = if (in_db) {}
                       else Err.NotFound;
    const result = rig.client.storeDestroy(storeId);
    try testing.expectEqual(exp_result, result);
    if (in_db) mapRemove(rig.db, rig.arena, storeId);
}

fn testBlobHash(rig: *TestRig, arena: Allocator) anyerror!void {
    const blob = try fake.blob(rig.rng, arena,
                               TestRig.min_blob_size, TestRig.max_blob_size);
    const exp_blobId = Blob.hashMemory(blob);
    const blobId = rig.client.blobHash(.initMemory(blob));
    try testing.expectEqual(exp_blobId, blobId);
}

fn testBlobList(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const in_db = try randomStore(rig, arena);
    const exp_result =
        if (in_db) try sortedMapKeys(Blob.Id, rig.db.getPtr(storeId).?, arena)
        else Err.NotFound;
    const result = rig.client.blobList(arena, storeId);
    if (result) |blob_ids| {
        sortMatrix(Blob.Id, blob_ids);
    } else |_| {}
    try testing.expectEqualDeep(exp_result, result);
}

fn testBlobInfo(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, _, const blobId, const blob_ok
        = try randomStoreBlob(rig, arena);
    const exp_result = if (blob_ok) rig.db.getPtr(storeId).?.get(blobId).?.len
                       else Err.NotFound;
    const result = rig.client.blobInfo(storeId, blobId);
    try testing.expectEqual(exp_result, result);
}

fn testBlobLoad(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, _, const blobId, const blob_ok
        = try randomStoreBlob(rig, arena);
    const exp_result = if (blob_ok) rig.db.getPtr(storeId).?.get(blobId).?
                       else Err.NotFound;
    const result_stream = rig.client.blobLoad(arena, storeId, blobId);
    const result = if (result_stream) |stream| try slurp(arena, stream.core.stream)
                   else |err| err;
    try testing.expectEqualDeep(exp_result, result);
}

fn testBlobSave(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const store_ok, const sel_blobId, const blob_ok =
        try randomStoreBlob(rig, arena);
    const exp_blobId, const blob =
        if (blob_ok) blob: {
            const store = rig.db.getPtr(storeId).?;
            const blob = store.get(sel_blobId).?;
            break :blob .{sel_blobId, blob};
        } else blob: {
            const blob = try fake.blob(rig.rng, arena,
                TestRig.min_blob_size, TestRig.max_blob_size);
            const blobId = Blob.hashMemory(blob);
            break :blob .{blobId, blob};
        };
    const result = rig.client.blobSave(storeId, .initMemory(blob));
    const Pair = fns.pairGen(bool, bool);
    const exp_result: @TypeOf(result) = switch (Pair.make(store_ok, blob_ok)) {
        Pair.make(true, false) => .init(.created, exp_blobId),
        Pair.make(true, true) => .init(.exists, exp_blobId),
        else => Err.NotFound,
    };
    try testing.expectEqual(exp_result, result);
    if (store_ok and !blob_ok) {
        const store = rig.db.getPtr(storeId).?;
        try storeAdd(store, rig.arena, exp_blobId, blob);
    }
}

fn testBlobDelete(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, _, const blobId, const blob_ok
        = try randomStoreBlob(rig, arena);
    const exp_result = if (blob_ok) {}
                       else Err.NotFound;
    const result = rig.client.blobDelete(storeId, blobId);
    try testing.expectEqual(exp_result, result);
    if (blob_ok) mapRemove(rig.db.getPtr(storeId).?, rig.arena, blobId);
}

fn slurp(arena: Allocator, stream: *Blob.Stream) !fake.Blob {
    const blob = try arena.alloc(u8, stream.bytes_left);
    errdefer arena.free(blob);
    try stream.reader.readSliceAll(blob);
    return blob;
}

fn dbAdd(db: *TestRig.Db, arena: Allocator, storeId_in: StoreId) !void {
    var storeId = try StoreId.create(arena, storeId_in.id);
    errdefer trash.recycle(&storeId, arena);
    var store = TestRig.Store.init(arena);
    errdefer store.deinit();
    try db.putNoClobber(storeId, store);
}

fn storeAdd(store: *TestRig.Store, arena: Allocator,
            blobId: Blob.Id, blob_in: fake.Blob) !void {
    const blob = try arena.dupe(u8, blob_in);
    errdefer arena.free(blob);
    try store.putNoClobber(blobId, blob);
}

fn mapRemove(map: anytype, arena: Allocator, key: anytype) void {
    var item = map.fetchRemove(key) orelse unreachable;
    trash.recycle(&item, arena);
}

fn randomStoreBlob(rig: *TestRig, arena: Allocator)
        !struct {StoreId, bool, Blob.Id, bool} {
    const storeId, const store_ok = try randomStoreWithP(rig, arena, 0.8);
    const blobId, const blob_ok =
        if (store_ok) blob: {
            const store = rig.db.getPtr(storeId).?;
            const blob_ok = store.count() != 0 and rig.rng.float(f32) > 0.8;
            break :blob
                if (blob_ok) .{try mapChoose(rig.rng, Blob.Id, store), true}
                else .{fake.blobId(rig.rng), false};
        } else .{fake.blobId(rig.rng), false};
    return .{storeId, store_ok, blobId, blob_ok};
}

fn randomStore(rig: *TestRig, arena: Allocator) !struct {StoreId, bool} {
    return try randomStoreWithP(rig, arena, 0.6);
}

fn randomStoreWithP(rig: *TestRig, arena: Allocator, in_db_p: f32)
        !struct {StoreId, bool} {
    const in_db = rig.db.count() != 0 and rig.rng.float(f32) < in_db_p;
    const storeId = if (in_db) try mapChoose(rig.rng, StoreId, rig.db)
                     else try fake.storeId(rig.rng, arena,
                                            TestRig.min_store_id_size,
                                            TestRig.max_store_id_size);
    return .{storeId, in_db};
}

fn sortedMapKeys(Key: type, map: anytype, arena: Allocator) ![]Key {
    const size = map.count();
    const out = try arena.alloc(Key, size);
    errdefer arena.free(out);
    var map_iter = map.keyIterator();
    for (out) |*elem| {
        elem.* = map_iter.next().?.*;
    }
    std.debug.assert(map_iter.next() == null);
    sortMatrix(Key, out);
    return out;
}

fn sortMatrix(Row: type, matrix: []Row) void {
    switch (Row) {
        StoreId => std.mem.sort(StoreId, matrix, {}, storeIdLessThan),
        Blob.Id => std.mem.sort(Blob.Id, matrix, {}, blobIdLessThan),
        else => unreachable,
    }
}

fn storeIdLessThan(_: void, a: StoreId, b: StoreId) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn blobIdLessThan(_: void, a: Blob.Id, b: Blob.Id) bool {
    return std.mem.lessThan(u8, &a, &b);
}

fn mapChoose(rng: Random, Val: type, map: anytype) !Val {
    const index = rng.uintLessThan(usize, map.count());
    return mapIndex(Val, map, index);
}

fn mapIndex(Val: type, map: anytype, index: usize) !Val {
    var map_iter = map.keyIterator();
    for (0 .. index) |_| {
        _ = map_iter.next().?;
    }
    return map_iter.next().?.*;
}
