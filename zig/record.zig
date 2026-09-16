const std = @import("std");
const Type = std.builtin.Type;

const fns = @import("functions.zig");

pub fn init(Obj: type) Return: {
    const types = fieldTypes(Obj);
    break :Return switch (types.len) {
        0 => fn() Obj,
        1 => fn(types[0]) Obj,
        2 => fn(types[0], types[1]) Obj,
        3 => fn(types[0], types[1], types[2]) Obj,
        4 => fn(types[0], types[1], types[2], types[3]) Obj,
        else => @compileError(
            std.fmt.comptimePrint("Unsupported field count: {d}", types.len)),
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
        3 => struct {
            fn inner(a: types[0], b: types[1], c: types[2]) Obj {
                return makeStruct(Obj, .{a, b, c});
            }
        }.inner,
        4 => struct {
            fn inner(a: types[0], b: types[1], c: types[2], d: types[3]) Obj {
                return makeStruct(Obj, .{a, b, c, d});
            }
        }.inner,
        else => @compileError(
            std.fmt.comptimePrint("Unsupported field count: {d}", types.len)),
    };
}

fn fieldTypes(Obj: type) [std.meta.fields(Obj).len]type {
    const fields = std.meta.fields(Obj);
    return fns.map(fields, fns.structField(Type.StructField, "type"));
}

fn makeStruct(Obj: type, initializer: anytype) Obj {
    const fields = std.meta.fields(Obj);
    var obj: Obj = undefined;
    inline for (fields, initializer) |field, elem| {
        @field(obj, field.name) = elem;
    }
    return obj;
}
