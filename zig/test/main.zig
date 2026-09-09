const std = @import("std");
const Random = std.Random;
const Allocator = std.mem.Allocator;

const testing = std.testing;

const ty = @import("blob-db/types.zig");
const StoreId = ty.StoreId;
const BlobId = ty.BlobId;

const funcs = @import("blob-db/funcs.zig");
const trash = @import("blob-db/trash.zig");
const debug = @import("blob-db/debug.zig");
const struct_ = @import("blob-db/struct_.zig");
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
        funcs.println("Usage: {s} <address>:<port> <iterations>", .{program});
        std.process.exit(1);
    };
}

fn parseCoreArgs(args: std.process.Args.Vector) !Args {
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
    arena: Allocator,
    rng: Random,

    const StoreIdHasher = HasherFromKeyFunc(StoreId, storeIdKey);
    const BlobIdHasher = HasherFromKeyFunc(BlobId, blobIdKey);

    fn storeIdKey(storeId: *const StoreId) []const u8 {
        return storeId.id;
    }

    fn blobIdKey(blobId: *const BlobId) []const u8 {
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
        const init = struct_.init(@This());
    };
    const ops = [_]FuncWeightPair{
        .init(test_storeList, 0.2),
        .init(test_storeCreate, 0.2),
        .init(test_storeDestroy, 0.1),
        .init(test_blobHash, 1),
        .init(test_blobList, 2),
        .init(test_blobInfo, 1),
        .init(test_blobLoad, 1),
        .init(test_blobSave, 1),
        .init(test_blobDelete, 1),
    };
    const weights = funcs.map(ops, funcs.structField(FuncWeightPair, "weight"));
    try testFuncArena(test_storeList, rig);
    for (0..iterations) |_| {
        const index = rig.rng.weightedIndex(Weight, &weights);
        try testFuncArena(ops[index].func, rig);
    }
    while (rig.db.count() != 0) {
        try testFuncArena(test_storeDestroy, rig);
    }
}

fn testFuncArena(func: TestFunc, rig: *TestRig) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(rig.arena);
    defer arena.deinit();
    try func(rig, arena.allocator());
}

// Let testFuncArena free the allocations for the functions below.

fn testStoreList(rig: *TestRig, arena: Allocator) anyerror!void {
    const exp_storeIds = try sortedMapKeys(arena, StoreId, rig.db);
    const storeIds = try rig.client.storeList(arena);
    sortMatrix(StoreId, storeIds);
    try testing.expectEqualDeep(exp_storeIds, storeIds);
}

fn testStoreCreate(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const in_db = try randomStore(rig, arena);
    const exp_result = if (in_db) ty.Err.Exists
                       else {};
    const result = rig.client.storeCreate(storeId);
    try testing.expectEqual(exp_result, result);
    if (!in_db) try dbAdd(rig.arena, rig.db, storeId);
}

fn testStoreDestroy(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const in_db = try randomStore(rig, arena);
    const exp_result = if (in_db) {}
                       else ty.Err.NotFound;
    const result = rig.client.storeDestroy(storeId);
    try testing.expectEqual(exp_result, result);
    if (in_db) mapRemove(rig.arena, rig.db, storeId);
}

fn testBlobHash(rig: *TestRig, arena: Allocator) anyerror!void {
    const blob = try fake.blob(rig.rng, arena,
                               TestRig.MIN_BLOB_SIZE, TestRig.MAX_BLOB_SIZE);
    const exp_blobId = funcs.hashMemory(blob);
    const blobId = rig.client.blobHash(.initMemory(blob));
    try testing.expectEqual(exp_blobId, blobId);
}

fn testBlobList(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const in_db = try randomStore(rig, arena);
    const exp_result =
        if (in_db) try sortedMapKeys(arena, BlobId, rig.db.getPtr(storeId).?)
        else ty.Err.NotFound;
    const result = rig.client.blobList(arena, storeId);
    if (result) |blobIds| {
        sortMatrix(BlobId, blobIds);
    } else |_| {}
    try testing.expectEqualDeep(exp_result, result);
}

fn testBlobInfo(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, _, const blobId, const blob_ok
        = try randomStore_blob(rig, arena);
    const exp_result = if (blob_ok) rig.db.getPtr(storeId).?.get(blobId).?.len
                       else ty.Err.NotFound;
    const result = rig.client.blobInfo(storeId, blobId);
    try testing.expectEqual(exp_result, result);
}

fn testBlobLoad(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, _, const blobId, const blob_ok
        = try randomStore_blob(rig, arena);
    const exp_result = if (blob_ok) rig.db.getPtr(storeId).?.get(blobId).?
                       else ty.Err.NotFound;
    const result_stream = rig.client.blobLoad(arena, storeId, blobId);
    const result = if (result_stream) |stream| try slurp(arena, stream.stream)
                   else |err| err;
    try testing.expectEqualDeep(exp_result, result);
}

fn testBlobSave(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, const store_ok, const sel_blobId, const blob_ok =
        try randomStore_blob(rig, arena);
    const exp_blobId, const blob =
        if (blob_ok) blob: {
            const store = rig.db.getPtr(storeId).?;
            const blob = store.get(sel_blobId).?;
            break :blob .{sel_blobId, blob};
        } else blob: {
            const blob = try fake.blob(rig.rng, arena,
                TestRig.MIN_BLOB_SIZE, TestRig.MAX_BLOB_SIZE);
            const blobId = funcs.hashMemory(blob);
            break :blob .{blobId, blob};
        };
    const result = rig.client.blobSave(storeId, .initMemory(blob));
    const Pair = funcs.pairGen(bool, bool);
    const exp_result: @TypeOf(result) = switch (Pair.make(store_ok, blob_ok)) {
        Pair.make(true, false) => .init(.created, exp_blobId),
        Pair.make(true, true) => .init(.exists, exp_blobId),
        else => ty.Err.NotFound,
    };
    try testing.expectEqual(exp_result, result);
    if (store_ok and !blob_ok) {
        const store = rig.db.getPtr(storeId).?;
        try storeAdd(rig.arena, store, exp_blobId, blob);
    }
}

fn testBlobDelete(rig: *TestRig, arena: Allocator) anyerror!void {
    const storeId, _, const blobId, const blob_ok
        = try randomStore_blob(rig, arena);
    const exp_result = if (blob_ok) {}
                       else ty.Err.NotFound;
    const result = rig.client.blobDelete(storeId, blobId);
    try testing.expectEqual(exp_result, result);
    if (blob_ok) mapRemove(rig.arena, rig.db.getPtr(storeId).?, blobId);
}

fn slurp(arena: Allocator, stream: *ty.Blob.Stream) !fake.Blob {
    const blob = try arena.alloc(u8, stream.bytes_left);
    errdefer arena.free(blob);
    try stream.reader.readSliceAll(blob);
    return blob;
}

fn dbAdd(db: *TestRig.Db, storeId_in: StoreId, arena: Allocator) !void {
    const storeId = StoreId.create(storeId_in.id);
    errdefer trash.recycle(storeId, arena);
    var store = TestRig.Store.init(arena);
    errdefer store.deinit();
    try db.putNoClobber(storeId, store);
}

fn storeAdd(store: *TestRig.Store, blobId: BlobId, blob_in: fake.Blob,
             arena: Allocator) !void {
    const blob = try arena.dupe(u8, blob_in);
    errdefer arena.free(blob);
    try store.putNoClobber(blobId, blob);
}

fn mapRemove(map: anytype, key: anytype, arena: Allocator) void {
    const item = map.fetchRemove(key) orelse unreachable;
    trash.recycle(item);
}

fn randomStoreBlob(rig: *TestRig, arena: Allocator)
        !struct {StoreId, bool, BlobId, bool} {
    const storeId, const store_ok = try randomStore_with_p(rig, arena, 0.8);
    const blobId, const blob_ok =
        if (store_ok) blob: {
            const store = rig.db.getPtr(storeId).?;
            const blob_ok = store.count() != 0 and rig.rng.float(f32) > 0.8;
            break :blob
                if (blob_ok) .{try mapChoose(rig.rng, store, BlobId), true}
                else .{fake.blobId(rig.rng), false};
        } else .{fake.blobId(rig.rng), false};
    return .{storeId, store_ok, blobId, blob_ok};
}

fn randomStore(rig: *TestRig, arena: Allocator) !struct {StoreId, bool} {
    return try randomStore_with_p(rig, arena, 0.6);
}

fn randomStoreWithP(rig: *TestRig, arena: Allocator, in_db_p: f32)
        !struct {StoreId, bool} {
    const in_db = rig.db.count() != 0 and rig.rng.float(f32) < in_db_p;
    const storeId = if (in_db) try mapChoose(rig.rng, rig.db, StoreId)
                     else try fake.storeId(rig.rng, arena,
                                            TestRig.MIN_STORE_ID_SIZE,
                                            TestRig.MAX_STORE_ID_SIZE);
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

fn mapChoose(Val: Type, map: anytype, arena: Allocator) !Val {
    const index = rng.uintLessThan(usize, map.count());
    return mapIndex(Val, map, index);
}

fn mapIndex(Val: Type, map: anytype, index: usize) !Val {
    var map_iter = map.keyIterator();
    for (0 .. index) |_| {
        _ = map_iter.next().?;
    }
    return map_iter.next().?.*;
}
