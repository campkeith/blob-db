const std = @import("std");
const Environ = std.process.Environ;
const Hasher = std.crypto.hash.sha2.Sha256;

const ty = @import("types.zig");
const mem = @import("mem.zig");

const CHUNK_SIZE: usize = 64 * 1024;

pub fn getEnv(env: *Environ.Map, name: []const u8) ty.Err![]const u8 {
    return env.get(name) orelse out: {
        debug("Missing required environment variable: {s}\n", .{name});
        break :out ty.Err.Internal;
    };
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    std.debug.print(format, args);
}

pub fn hashBlob(blob: *ty.Blob) !ty.BlobId {
    return switch (blob.*) {
        .stream => |*in| out: {
            var hasher = Hasher.init(.{});
            var chunk = try mem.alloc(u8, CHUNK_SIZE);
            defer mem.free(chunk);
            while (in.bytes_left > 0) {
                const slice = chunk[0 .. @min(in.bytes_left, CHUNK_SIZE)];
                try in.reader.readSliceAll(slice);
                hasher.update(slice);
            }
            break :out hasher.finalResult();
        },
        .file => |*file| out: {
            const mmap_opts: std.Io.File.MemoryMap.CreateOptions = .{
                .len = try file.file.length(file.io),
            };
            var mem_map = try file.file.createMemoryMap(file.io, mmap_opts);
            defer mem_map.destroy(file.io);
            break :out hashMemory(mem_map.memory);
        },
        .memory => |bytes| hashMemory(bytes),
    };
}

pub fn hashCopyBlob(input: *std.Io.Reader, output: []u8) !ty.BlobId {
    var hasher = Hasher.init(.{});
    var index: usize = 0;
    while (index < output.len) : (index += CHUNK_SIZE) {
        const chunk = output[index .. @min(index + CHUNK_SIZE, output.len)];
        try input.readSliceAll(chunk);
        hasher.update(chunk);
    }
    return hasher.finalResult();
}

pub fn hashMemory(blob: []u8) ty.BlobId {
    var blob_id: ty.BlobId = undefined;
    Hasher.hash(blob, &blob_id, .{});
    return blob_id;
}

pub fn hashBytesToHex(hash: ty.BlobId) ty.BlobIdStr {
    var string: ty.BlobIdStr = undefined;
    for (hash, 0..) |byte, index| {
        @memcpy(sliceChunk(2, @as([]u8, &string), index), &byteToHex(byte));
    }
    return string;
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

pub fn hashHexToBytes(string: []const u8) ty.Err!ty.BlobId {
    if (string.len != 64) {
        debug("hashHexToBytes: invalid length string: '{s}'\n", .{string});
        return ty.Err.Internal;
    }
    var hash: ty.BlobId = undefined;
    for (&hash, 0..) |*byte, index| {
        const slice = sliceChunk(2, string, index);
        byte.* = try hexToByte(@ptrCast(slice));
    }
    return hash;
}

fn hexToByte(hex_pair: *const[2]u8) ty.Err!u8 {
    const hi, const lo = hex_pair.*;
    const nibbles: NibblePair = .{.hi = try hexDigitToNibble(hi),
                                  .lo = try hexDigitToNibble(lo)};
    return @bitCast(nibbles);
}

fn hexDigitToNibble(digit: u8) ty.Err!u4 {
    return switch (digit) {
        '0'...'9' => @intCast(digit - '0'),
        'a'...'f' => @intCast(digit - 'a' + 0xa),
        else => out: {
            debug("hexDigitToNibble: " ++
                  "invalid hex digit: '{c}'\n", .{digit});
            break :out ty.Err.Internal;
        },
    };
}

const NibblePair = packed struct(u8) {
    lo: u4,
    hi: u4,
};

fn sliceChunk(comptime chunk_size: usize, slice: anytype, chunk_num: usize)
        @TypeOf(slice) {
    return slice[chunk_size * chunk_num .. chunk_size * (chunk_num + 1)];
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
