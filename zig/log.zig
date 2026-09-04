const std = @import("std");
const Type = std.builtin.Type;

const debug = @import("debug.zig");
const funcs = @import("funcs.zig");

pub fn call(Parent: type, comptime name: []const u8, comptime func: anytype)
        @TypeOf(func) {
    const full_name = @typeName(Parent) ++ "." ++ name;
    const Func = @typeInfo(@TypeOf(func)).@"fn";
    const Args = funcs.map(Func.params, argType);
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

fn argType(param: Type.Fn.Param) type {
    return param.type.?;
}

fn argsCallRet(comptime func: anytype, args: anytype, name: []const u8)
        @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    funcs.debug("{s}{f}:\n", .{name, debug.Fmt(args)});
    const result = @call(.auto, func, args);
    funcs.debug("{s} -> {f}\n", .{name, debug.Fmt(result)});
    return result;
}
