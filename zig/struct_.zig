const std = @import("std");

pub fn Init(Obj: type) ret: {
    const types = fieldTypes(Obj);
    break :ret switch (types.len) {
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

fn fieldTypes(Obj: type) []const type {
    const fields = std.meta.fields(Obj);
    var out: [16]type = undefined;
    inline for (fields, 0..) |field, index| {
        out[index] = field.type;
    }
    const out_copy = out;
    return out_copy[0..fields.len];
}

fn makeStruct(Obj: type, initializer: anytype) Obj {
    const fields = std.meta.fields(Obj);
    var obj: Obj = undefined;
    inline for (fields, initializer) |field, elem| {
        @field(obj, field.name) = elem;
    }
    return obj;
}
