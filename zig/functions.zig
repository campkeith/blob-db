const std = @import("std");
const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;

const ty = @import("types.zig");
const Err = ty.Err;

pub fn getEnv(env: *std.process.Environ.Map, name: []const u8) ![]const u8 {
    return env.get(name) orelse err: {
        println("Missing required environment variable: {s}", .{name});
        break :err Err.Internal;
    };
}

pub fn println(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

pub fn writeln(comptime line: []const u8) void {
    std.debug.print(line ++ "\n", .{});
}

pub fn pairGen(A: type, B: type) type {
    const PairStruct = packed struct {
        a: A,
        b: B,
    };
    const Pair = struct {
        pub fn make(a: A, b: B) PairStruct {
            return .{.a = a, .b = b};
        }
    };
    return Pair;
}

pub fn map(array_in: anytype, func: anytype)
        MapReturn(array_in.len, ReturnType(@TypeOf(func))) {
    const ElemOut = returnTypeSansErr(@TypeOf(func));
    var array_out: [array_in.len]ElemOut = undefined;
    inline for (array_in, &array_out) |elem_in, *elem_out| {
        elem_out.* = if (@typeInfo(ReturnType(@TypeOf(func))) == .error_union)
                     try func(elem_in) else func(elem_in);
    }
    return array_out;
}

fn MapReturn(size: usize, FuncReturn: type) type {
    return switch (@typeInfo(FuncReturn)) {
        .error_union => |union_| union_.error_set![size]union_.payload,
        else => [size]FuncReturn,
    };
}

pub fn structField(Obj: type, comptime name: []const u8)
        fn(Obj) @FieldType(Obj, name) {
    return struct {
        fn go(obj: Obj) @FieldType(Obj, name) {
            return @field(obj, name);
        }
    }.go;
}

pub fn argType(param: std.builtin.Type.Fn.Param) type {
    return param.type.?;
}

pub fn returnTypeSansErr(Func: type) type {
    const Return = ReturnType(Func);
    return switch (@typeInfo(Return)) {
        .error_union => |union_| union_.payload,
        else => Return,
    };
}

pub fn ReturnType(Func: type) type {
    return @typeInfo(Func).@"fn".return_type.?;
}

pub fn randomNameAlloc(rng: Random, arena: Allocator, size: usize) ![]u8 {
    const name = try arena.alloc(u8, size);
    randomName(rng, name);
    return name;
}

pub fn randomName(rng: Random, name_out: []u8) void {
    const alphabet = std.fs.base64_alphabet;
    for (name_out) |*char| {
        const index = rng.uintLessThan(usize, alphabet.len);
        char.* = alphabet[index];
    }
}

pub fn peerAddress(stream: *Io.net.Stream) !Io.net.IpAddress {
    const posix = std.posix;
    var addr_buf: posix.sockaddr.storage = undefined;
    var size: posix.socklen_t = @sizeOf(@TypeOf(addr_buf));
    const address: *posix.sockaddr = @ptrCast(&addr_buf);
    try std.posix.getpeername(stream.socket.handle, address, &size);
    return Io.Threaded.addressFromPosix(&.{.any = address.*});
}

pub fn encode8(comptime bytes: *const[8]u8) u64 {
    return std.mem.readInt(u64, bytes, .little);
}

pub fn decode8(code: u64) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, code, .little);
    return out;
}
