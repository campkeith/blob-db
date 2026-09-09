const std = @import("std");
const Writer = std.Io.Writer;
const print = std.debug.print;
const IpAddress = std.Io.net.IpAddress;

const ty = @import("types.zig");
const funcs = @import("funcs.zig");

pub fn Fmt(obj: anytype) Formatter(@TypeOf(obj)) {
    return Formatter(@TypeOf(obj)){.obj = obj};
}

fn Formatter(Obj: type) type {
    return struct {
        obj: Obj,

        pub fn format(self: @This(), out: *Writer) !void {
            return formatObj(self.obj, out);
        }
    };
}

pub fn formatObj(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    if ((@typeInfo(Obj) == .@"struct" or @typeInfo(Obj) == .@"union")
            and @hasDecl(Obj, "format")) {
        try obj.format(out);
    } else try switch (Obj) {
        []const u8 => out.print("\"{s}\"", .{obj}),
        ty.BlobId => out.print("{s}", .{funcs.hashBytesToHex(obj)}),
        ?IpAddress => formatAddress(obj, out),
        std.mem.Allocator => formatStruct(obj, out),
        else => switch (@typeInfo(Obj)) {
            .error_union =>
                if (obj) |not_err| formatObj(not_err, out)
                    else |err| out.print("{t}", .{err}),
            .pointer => |pointer| switch (pointer.size) {
                .slice => formatArray(obj, out),
                else => out.print("{*}", .{obj}),
            },
            .@"struct" => |struct_|
                if (struct_.is_tuple) formatTuple(obj, out)
                else formatStruct_opaque(obj, out),
            .void => out.writeAll("{}"),
            else => out.print("{any}", .{obj}),
        },
    };
}

pub fn formatTuple(tuple: anytype, out: *Writer) !void {
    try out.writeAll("(");
    inline for (tuple, 0..) |item, index| {
        try formatObj(item, out);
        if (index < tuple.len - 1) try out.writeAll(", ");
    }
    try out.writeAll(")");
}

pub fn formatArray(array: anytype, out: *Writer) !void {
    try out.writeAll("[");
    for (array, 0..) |item, index| {
        try formatObj(item, out);
        if (index < array.len - 1) try out.writeAll(", ");
    }
    try out.writeAll("]");
}

pub fn formatStruct(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    try out.print("{s}{{", .{@typeName(Obj)});
    const fields = std.meta.fields(Obj);
    inline for (fields, 0..) |field, index| {
        try out.print("{s} = {f}", .{field.name, Fmt(@field(obj, field.name))});
        if (index < fields.len - 1) try out.writeAll(", ");
    }
    try out.writeAll("}");
}

pub fn formatStruct_opaque(obj: anytype, out: *Writer) !void {
    const Obj = @TypeOf(obj);
    try out.print("{s}{{..}}", .{@typeName(Obj)});
}

fn formatAddress(opt_address: ?std.Io.net.IpAddress, out: *Writer) !void {
    if (opt_address) |address| address.format(out) catch writePlaceholder(out)
        else writePlaceholder(out);
}

fn writePlaceholder(out: *Writer) void {
    out.writeAll("?") catch {};
}
