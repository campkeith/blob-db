const std = @import("std");
const Writer = std.Io.Writer;
const print = std.debug.print;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const Blob = @import("Blob.zig");

pub fn Fmt(obj_in: anytype) Formatter(@TypeOf(obj_in)) {
    return Formatter(@TypeOf(obj_in)){.obj = obj_in};
}

fn Formatter(Obj: type) type {
    return struct {
        obj: Obj,

        pub fn format(self: @This(), out: *Writer) !void {
            return obj(self.obj, out);
        }
    };
}

fn obj(obj_in: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj_in);
    if ((@typeInfo(Obj) == .@"struct" or @typeInfo(Obj) == .@"union")
            and @hasDecl(Obj, "format")) {
        try obj_in.format(out);
    } else try switch (Obj) {
        []const u8 => out.print("\"{s}\"", .{obj_in}),
        Blob.Id => out.print("{s}", .{Blob.formatId(obj_in)}),
        ?IpAddress => ipAddress(obj_in, out),
        std.mem.Allocator => struct_(obj_in, out),
        else => switch (@typeInfo(Obj)) {
            .error_union =>
                if (obj_in) |not_err| obj(not_err, out)
                    else |err| out.print("{t}", .{err}),
            .pointer => |pointer| switch (pointer.size) {
                .slice => array(obj_in, out),
                else => out.print("{*}", .{obj_in}),
            },
            .@"struct" => |struct_in|
                if (struct_in.is_tuple) tuple(obj_in, out)
                else structOpaque(obj, out),
            .void => out.writeAll("{}"),
            else => out.print("{any}", .{obj_in}),
        },
    };
}

pub fn tuple(tuple_in: anytype, out: *Writer) !void {
    try out.writeAll("(");
    inline for (tuple_in, 0..) |item, index| {
        try obj(item, out);
        if (index < tuple_in.len - 1) try out.writeAll(", ");
    }
    try out.writeAll(")");
}

pub fn array(array_in: anytype, out: *Writer) !void {
    try out.writeAll("[");
    for (array_in, 0..) |item, index| {
        try obj(item, out);
        if (index < array_in.len - 1) try out.writeAll(", ");
    }
    try out.writeAll("]");
}

pub fn struct_(struct_in: anytype, out: *Writer) !void {
    const Struct = @TypeOf(struct_in);
    try out.print("{s}{{", .{@typeName(Struct)});
    const fields = std.meta.fields(Struct);
    inline for (fields, 0..) |field, index| {
        const name = field.name;
        try out.print("{s} = {f}", .{name, Fmt(@field(struct_in, name))});
        if (index < fields.len - 1) try out.writeAll(", ");
    }
    try out.writeAll("}");
}

pub fn structOpaque(struct_in: anytype, out: *Writer) !void {
    const Struct = @TypeOf(struct_in);
    try out.print("{s}{{..}}", .{@typeName(Struct)});
}

fn ipAddress(opt_address: ?std.Io.net.IpAddress, out: *Writer) !void {
    if (opt_address) |address| address.format(out) catch writePlaceholder(out)
        else writePlaceholder(out);
}

fn writePlaceholder(out: *Writer) void {
    out.writeAll("?") catch {};
}
