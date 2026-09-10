const std = @import("std");
const Type = std.builtin.Type;

const fmt = @import("format.zig");
const Fmt = fmt.Fmt;

const fns = @import("functions.zig");

pub fn call(Parent: type, comptime name: []const u8, comptime func: anytype)
        @TypeOf(func) {
    const full_name = @typeName(Parent) ++ "." ++ name;
    const Func = @typeInfo(@TypeOf(func)).@"fn";
    const Args = fns.map(Func.params, fns.argType);
    const Return = Func.return_type.?;

    comptime return switch(Args.len) {
        0 => struct {
            fn inner() Return {
                return argsCallRet(func, .{}, full_name);
            }
        }.inner,
        1 => struct {
            fn inner(a: Args[0]) Return {
                return argsCallRet(func, .{a}, full_name);
            }
        }.inner,
        2 => struct {
            fn inner(a: Args[0], b: Args[1]) Return {
                return argsCallRet(func, .{a, b}, full_name);
            }
        }.inner,
        3 => struct {
            fn inner(a: Args[0], b: Args[1], c: Args[2]) Return {
                return argsCallRet(func, .{a, b, c}, full_name);
            }
        }.inner,
        4 => struct {
            fn inner(a: Args[0], b: Args[1], c: Args[2], d: Args[3]) Return {
                return argsCallRet(func, .{a, b, c, d}, full_name);
            }
        }.inner,
        else => unreachable,
    };
}

fn argsCallRet(comptime func: anytype, args: anytype, name: []const u8)
        fns.ReturnType(@TypeOf(func)) {
    fns.println("{s}{f}:", .{name, Fmt(args)});
    const result = @call(.auto, func, args);
    fns.println("{s} -> {f}", .{name, Fmt(result)});
    return result;
}
