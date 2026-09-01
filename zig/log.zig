const std = @import("std");

const debug = @import("debug.zig");
const funcs = @import("funcs.zig");

pub fn call(comptime func: anytype, name: []const u8) @TypeOf(func) {
    const Func = @typeInfo(@TypeOf(func)).@"fn";
    const Args = args_tuple(Func.params);
    const Return = Func.return_type.?;

    comptime return switch(Args.len) {
        0 => struct {
            fn inner() Return {
                return args_call_ret(func, .{}, name);
            }
        }.inner,
        1 => struct {
            fn inner(a: Args[0]) Return {
                return args_call_ret(func, .{a}, name);
            }
        }.inner,
        2 => struct {
            fn inner(a: Args[0], b: Args[1]) Return {
                return args_call_ret(func, .{a, b}, name);
            }
        }.inner,
        3 => struct {
            fn inner(a: Args[0], b: Args[1], c: Args[2]) Return {
                return args_call_ret(func, .{a, b, c}, name);
            }
        }.inner,
        else => unreachable,
    };
}

fn args_tuple(params: []const std.builtin.Type.Fn.Param) []const type {
    var out: [16]type = undefined;
    inline for (params, 0..) |param, index| {
        out[index] = param.type.?;
    }
    const out_copy = out;
    return out_copy[0..params.len];
}

fn args_call_ret(func: anytype, args: anytype, name: []const u8)
        @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    funcs.debug("{s}", .{name});
    debug.dump_tuple(args);
    funcs.debug(":\n", .{});

    const result = @call(.auto, func, args);

    funcs.debug("{s} -> ", .{name});
    debug.dump(result);
    funcs.debug("\n", .{});

    return result;
}
