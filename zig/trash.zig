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
                .pointer => |ChildPointer| switch (ChildPointer.size) {
                    .slice => recycleSlice(ChildPointer.child, obj.*, arena),
                    else => Err.Internal,
                },
                .@"struct" => recycleStruct(obj, arena),
                .@"union" => recycleUnion(obj, arena),
                .bool, .int, .float, .@"enum", .error_set, .void => {},
                .array => |Array| if (!Pointer.is_const)
                    recycleArray(Array.child, Array.len, obj, arena),
                else => Err.Internal,
            },
            else => Err.Internal,
        },
        else => Err.Internal,
    }) catch funcs.println("recycle: Ignoring unknown {any} object.", .{Obj});
}

fn recycleStruct(struct_ptr: anytype, arena: Allocator) void {
    const Struct = @TypeOf(struct_ptr.*);
    if (isArrayList(Struct)) recycleArrayList(struct_ptr, arena)
    else if (isHashMap(Struct)) recycleHashMap(struct_ptr, arena)
    else if (@hasDecl(Struct, "deinit"))
        struct_ptr.deinit(arena)
    else
        inline for (std.meta.fields(Struct)) |field| {
            const FieldType = @FieldType(Struct, field.name);
            const field_ptr = if (@typeInfo(FieldType) == .pointer)
                @field(struct_ptr, field.name)
                else &@field(struct_ptr, field.name);
            recycle(field_ptr, arena);
        }
}

fn recycleUnion(union_ptr: anytype, arena: Allocator) void {
    const Union = @TypeOf(union_ptr.*);
    if (@hasDecl(Union, "deinit"))
        union_ptr.deinit(arena)
    else
        switch (union_ptr.*) {
            inline else => |*val| recycle(val, arena),
        }
}

inline fn isArrayList(Obj: type) bool {
    return @hasField(Obj, "items")
        and ArrayList(std.meta.Child(@FieldType(Obj, "items"))) == Obj;
}

inline fn isHashMap(Obj: type) bool {
    return @hasField(Obj, "unmanaged") and unmanaged: {
        const Unmanaged = @FieldType(Obj, "unmanaged");
        break :unmanaged @hasDecl(Unmanaged, "putContext") and check: {
            const Func = @typeInfo(@TypeOf(Unmanaged.putContext)).@"fn";
            const Args = Func.params;
            const Key, const Val, const Hasher
                = .{Args[2].type.?, Args[3].type.?, Args[4].type.?};
            const max_load = std.hash_map.default_max_load_percentage;
            break :check std.HashMap(Key, Val, Hasher, max_load) == Obj;
        };
    };
}

pub fn recycleArrayList(list: anytype, arena: Allocator) void {
    for (list.items) |*item| recycle(item, arena);
    list.deinit(arena);
}

pub fn recycleHashMap(map: anytype, arena: Allocator) void {
    var entry_iter = map.iterator();
    while (entry_iter.next()) |entry| recycle(&entry, arena);
    map.deinit();
}

pub fn recycleSlice(Elem: type, slice: []const Elem, arena: Allocator) void {
    for (slice) |*elem| recycle(elem, arena);
    arena.free(slice);
}

pub fn recycleArray(Elem: type, comptime size: usize, array: *[size]Elem,
                    arena: Allocator) void {
    for (array) |*elem| recycle(elem, arena);
}
