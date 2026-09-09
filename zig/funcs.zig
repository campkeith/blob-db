const std = @import("std");
const Random = std.Random;
const Environ = std.process.Environ;
const Allocator = std.mem.Allocator;
const Hasher = std.crypto.hash.sha2.Sha256;

const ty = @import("types.zig");
const Err = ty.Err;
const BlobId = ty.BlobId;
const BlobIdStr = ty.BlobIdStr;
const Blob = ty.Blob;

const CHUNK_SIZE: usize = 64 * 1024;

pub fn getEnv(env: *Environ.Map, name: []const u8) ![]const u8 {
    return env.get(name) orelse err: {
        println("Missing required environment variable: {s}", .{name});
        break :err ty.Err.Internal;
    };
}

pub fn println(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

pub fn writeln(comptime line: []const u8) void {
    std.debug.print(line ++ "\n", .{});
}

pub fn hashBlob(arena: Allocator, blob: Blob) !BlobId {
    return switch (blob) {
        .stream => |in| blob_id: {
            var hasher = Hasher.init(.{});
            var chunk = try arena.alloc(u8, CHUNK_SIZE);
            defer arena.free(chunk);
            while (in.bytes_left > 0) {
                const slice = chunk[0 .. @min(in.bytes_left, CHUNK_SIZE)];
                try in.reader.readSliceAll(slice);
                in.bytes_left -= slice.len;
                hasher.update(slice);
            }
            break :blob_id hasher.finalResult();
        },
        .file => |file| blob_id: {
            const mmap_opts: std.Io.File.MemoryMap.CreateOptions = .{
                .len = try file.file.length(file.io),
            };
            var mem_map = try file.file.createMemoryMap(file.io, mmap_opts);
            defer mem_map.destroy(file.io);
            break :blob_id hashMemory(mem_map.memory);
        },
        .memory => |bytes| hashMemory(bytes),
    };
}

pub fn hashCopyBlob(blob: Blob, out: []u8) !BlobId {
    return switch (blob) {
        .stream => |in| blob_id: {
            if (in.bytes_left != out.len) {
                println("hashCopyBlob[stream]: size mismatch: ({d}, {d})",
                            .{in.bytes_left, out.len});
                return ty.Err.Internal;
            }
            var hasher = Hasher.init(.{});
            var index: usize = 0;
            while (index < out.len) : (index += CHUNK_SIZE) {
                const chunk = out[index .. @min(index + CHUNK_SIZE, out.len)];
                try in.reader.readSliceAll(chunk);
                in.bytes_left -= chunk.len;
                hasher.update(chunk);
            }
            break :blob_id hasher.finalResult();
        },
        else => err: {
            const tag = std.meta.activeTag(blob);
            println("hashCopyBlob: {any} not supported.", .{tag});
            break :err ty.Err.Internal;
        },
    };
}

pub fn hashMemory(blob: []const u8) BlobId {
    var blob_id: BlobId = undefined;
    Hasher.hash(blob, &blob_id, .{});
    return blob_id;
}

pub fn hashBytesToHex(hash: BlobId) BlobIdStr {
    return std.mem.toBytes(map(hash, byteToHex));
}

fn byteToHex(byte: u8) [2]u8 {
    const pair: NibblePair = @bitCast(byte);
    return .{ nibbleToHexDigit(pair.hi), nibbleToHexDigit(pair.lo) };
}

fn nibbleToHexDigit(nibble: u4) u8 {
    return switch (nibble) {
        0x0...0x9 => @as(u8, nibble) + '0',
        0xa...0xf => @as(u8, nibble) - 0xa + 'a',
    };
}

pub fn hashHexToBytes(string: BlobIdStr) !BlobId {
    const num_pairs = string.len / 2;
    return map(std.mem.bytesToValue([num_pairs][2]u8, &string), hexToByte);
}

fn hexToByte(hex_pair: [2]u8) !u8 {
    const hi, const lo = hex_pair;
    const nibbles: NibblePair = .{.hi = try hexDigitToNibble(hi),
                                  .lo = try hexDigitToNibble(lo)};
    return @bitCast(nibbles);
}

fn hexDigitToNibble(digit: u8) !u4 {
    return switch (digit) {
        '0'...'9' => @intCast(digit - '0'),
        'a'...'f' => @intCast(digit - 'a' + 0xa),
        else => err: {
            println("hexDigitToNibble: invalid hex digit: '{c}'", .{digit});
            break :err Err.Internal;
        },
    };
}

const NibblePair = packed struct(u8) {
    lo: u4,
    hi: u4,
};

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
        MapReturn(array_in.len, returnType(@TypeOf(func))) {
    const ElemOut = returnTypeSansErr(@TypeOf(func));
    var array_out: [array_in.len]ElemOut = undefined;
    inline for (array_in, &array_out) |elem_in, *elem_out| {
        elem_out.* = if (@typeInfo(returnType(@TypeOf(func))) == .error_union)
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
    const Return = returnType(Func);
    return switch (@typeInfo(Return)) {
        .error_union => |union_| union_.payload,
        else => Return,
    };
}

pub fn returnType(Func: type) type {
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
