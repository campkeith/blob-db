const std = @import("std");
const Writer = std.Io.Writer;
const print = std.debug.print;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const Blob = @import("Blob.zig");

pub fn Fmt(obj: anytype) Formatter(@TypeOf(obj)) {
    return Formatter(@TypeOf(obj)){.obj = obj};
}

fn Formatter(Obj: type) type {
    return struct {
        obj: Obj,

        pub fn format(self: @This(), out: *Writer) !void {
            return any(self.obj, out);
        }
    };
}

fn any(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    if ((@typeInfo(Obj) == .@"struct" or @typeInfo(Obj) == .@"union")
            and @hasDecl(Obj, "format")) {
        try obj.format(out);
    } else try switch (Obj) {
        []const u8 => out.print("\"{s}\"", .{obj}),
        Blob.Id => out.print("{s}", .{Blob.formatId(obj)}),
        ?IpAddress => ipAddress(obj, out),
        std.mem.Allocator => struct_(obj, out),
        else => switch (@typeInfo(Obj)) {
            .error_union =>
                if (obj) |not_err| any(not_err, out)
                    else |err| out.print("{t}", .{err}),
            .pointer => |pointer| switch (pointer.size) {
                .slice => array(obj, out),
                else => out.print("{*}", .{obj}),
            },
            .@"struct" => |struct_in|
                if (struct_in.is_tuple) tuple(obj, out)
                else structOpaque(obj, out),
            .void => out.writeAll("{}"),
            else => out.print("{any}", .{obj}),
        },
    };
}

pub fn tuple(tuple_in: anytype, out: *Writer) !void {
    try out.writeAll("(");
    inline for (tuple_in, 0..) |item, index| {
        try any(item, out);
        if (index < tuple_in.len - 1) try out.writeAll(", ");
    }
    try out.writeAll(")");
}

pub fn array(array_in: anytype, out: *Writer) !void {
    try out.writeAll("[");
    for (array_in, 0..) |item, index| {
        try any(item, out);
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
