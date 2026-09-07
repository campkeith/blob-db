const std = @import("std");
const HashList = std.HashMap;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const ty = @import("types.zig");
const Err = ty.Err;

const funcs = @import("funcs.zig");

pub fn recycle(obj: anytype, arena: Allocator) void {
    const Obj = @TypeOf(obj);
    @as(Err!void, switch (@typeInfo(Obj)) {
        .pointer => |Pointer| switch (Pointer.size) {
            .slice => recycleSlice(Pointer.child, obj, arena),
            .one => switch(@typeInfo(Pointer.child)) {
                .@"struct" => |Struct|
                    if (isArrayList(Struct)) recycleArrayList(obj, arena)
                    else if (isHashMap(Struct)) recycleHashMap(obj, arena)
                    else Err.Internal,
                else => Err.Internal,
            },
            else => Err.Internal,
        },
        .@"struct" => recycleStruct(obj, arena),
        .@"union" => recycleUnion(obj, arena),
        else => Err.Internal,
    }) catch funcs.println("recycle: Ignoring unknown {any} object.", .{Obj});
}

inline fn isArrayList(Obj: type) bool {
    return @hasField(Obj, "items")
        and ArrayList(std.meta.Child(@FieldType(Obj, "items"))) == Obj;
}

inline fn isHashMap(Obj: type) bool {
    return @hasDecl(Obj, "putContext") and check: {
        const Args = std.meta.ArgsTuple(Obj.putContext);
        _, _, const Key, const Val, const Hasher = Args;
        const max_load = Obj.max_load_percentage; // std.hash_map.default_max_load_percentage;
        break :check std.HashMap(Key, Val, Hasher, max_load) == Obj;
    };
}

pub fn recycleArrayList(list: anytype, arena: Allocator) void {
    for (list.items) |item| recycle(item, arena);
    list.deinit(arena);
}

pub fn recycleHashMap(map: anytype, arena: Allocator) void {
    var entry_iter = map.iterator();
    while (entry_iter.next()) |entry| recycle(entry, arena);
    map.deinit();
}

pub fn recycleSlice(Elem: type, slice: []const Elem, arena: Allocator) void {
    for (slice) |elem| recycle(elem, arena);
    arena.free(slice);
}

pub fn recycleStruct(struct_: anytype, arena: Allocator) void {
    const Struct = @TypeOf(struct_);
    if (@hasDecl(Struct, "deinit"))
        struct_.deinit(arena)
    else
        inline for (std.meta.fields(Struct)) |field|
            recycle(@field(struct_, field.name), arena);
}

pub fn recycleUnion(union_: anytype, arena: Allocator) void {
    const Union = @TypeOf(union_);
    if (@hasDecl(Union, "deinit"))
        union_.deinit(arena)
    else
        switch (union_) {
            inline else => |val| recycle(val, arena),
        }
}
