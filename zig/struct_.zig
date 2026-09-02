const std = @import("std");
const Type = std.builtin.Type;

const funcs = @import("funcs.zig");

pub fn Init(Obj: type) Return: {
    const types = fieldTypes(Obj);
    break :Return switch (types.len) {
        0 => fn() Obj,
        1 => fn(types[0]) Obj,
        2 => fn(types[0], types[1]) Obj,
        else => unreachable,
    };
} {
    const types = fieldTypes(Obj);
    comptime return switch (types.len) {
        0 => struct {
            fn inner() Obj {
                return makeStruct(Obj, .{});
            }
        }.inner,
        1 => struct {
            fn inner(a: types[0]) Obj {
                return makeStruct(Obj, .{a});
            }
        }.inner,
        2 => struct {
            fn inner(a: types[0], b: types[1]) Obj {
                return makeStruct(Obj, .{a, b});
            }
        }.inner,
        else => unreachable,
    };
}

fn fieldTypes(Obj: type) [std.meta.fields(Obj).len]type {
    const fields = std.meta.fields(Obj);
    return funcs.map(fields, funcs.structField(Type.StructField, "type"));
}

fn makeStruct(Obj: type, initializer: anytype) Obj {
    const fields = std.meta.fields(Obj);
    var obj: Obj = undefined;
    inline for (fields, initializer) |field, elem| {
        @field(obj, field.name) = elem;
    }
    return obj;
}
