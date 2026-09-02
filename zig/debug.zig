const std = @import("std");
const Writer = std.Io.Writer;
const print = std.debug.print;

const ty = @import("types.zig");

const funcs = @import("funcs.zig");

pub fn Fmt(obj: anytype) Formatter(@TypeOf(obj)) {
    return Formatter(@TypeOf(obj)){.obj = obj};
}

fn Formatter(Obj: type) type {
    return struct {
        obj: Obj,

        pub fn format(self: @This(), out: *Writer) !void {
            return format_obj(self.obj, out);
        }
    };
}

pub fn format_obj(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    if ((@typeInfo(Obj) == .@"struct" or @typeInfo(Obj) == .@"union")
            and @hasDecl(Obj, "format")) {
        try obj.format(out);
    } else try switch (Obj) {
        []const u8 => out.print("\"{s}\"", .{obj}),
        ty.BlobId => out.print("{s}", .{funcs.hashBytesToHex(obj)}),
        else => switch (@typeInfo(Obj)) {
            .error_union =>
                if (obj) |not_err| format_obj(not_err, out)
                    else |err| out.print("{t}", .{err}),
            .pointer => |pointer| switch (pointer.size) {
                .slice => format_array(obj, out),
                else => out.print("{*}", .{obj}),
            },
            .@"struct" => |struct_|
                if (struct_.is_tuple) format_tuple(obj, out)
                else format_struct_opaque(obj, out),
            .void => out.writeAll("{}"),
            else => out.print("{any}", .{obj}),
        },
    };
}

pub fn format_tuple(tuple: anytype, out: *Writer) !void {
    try out.writeAll("(");
    inline for (tuple, 0..) |item, index| {
        try format_obj(item, out);
        if (index < tuple.len - 1) try out.writeAll(", ");
    }
    try out.writeAll(")");
}

pub fn format_array(array: anytype, out: *Writer) !void {
    try out.writeAll("[");
    for (array, 0..) |item, index| {
        try format_obj(item, out);
        if (index < array.len - 1) try out.writeAll(", ");
    }
    try out.writeAll("]");
}

pub fn format_struct(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    try out.print("{s}{{", .{@typeName(Obj)});
    const fields = std.meta.fields(Obj);
    inline for (fields, 0..) |field, index| {
        try out.print("{s} = {f}", .{field.name, Fmt(@field(obj, field.name))});
        if (index < fields.len - 1) try out.writeAll(", ");
    }
    out.writeAll("}");
}

pub fn format_struct_opaque(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    try out.print("{s}{{..}}", .{@typeName(Obj)});
}
