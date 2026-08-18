const std = @import("std");

const ty = @import("types.zig");

pub const allocator = std.heap.page_allocator;
pub const debug = std.debug.print;

const CHUNK_SIZE: usize = 64 * 1024;
const Hasher = std.crypto.hash.sha2.Sha256;

pub fn getEnv(env: *ty.EnvMap, name: []const u8) ty.Err![]const u8 {
    return env.get(name) orelse {
        debug("Missing required environment variable: {s}\n", .{name});
        return ty.Err.Internal;
    };
}

pub fn hashBlob(blob: []u8) ty.BlobId {
    var out: ty.BlobId = undefined;
    Hasher.hash(blob, &out, .{});
    return out;
}

pub fn hashBlobStream(blob: *ty.BlobStream) !ty.BlobId {
    var hasher = Hasher.init(.{});
    var chunk = try allocator.alloc(u8, CHUNK_SIZE);
    defer allocator.free(chunk);
    while (blob.bytes_remain > 0) {
        const slice = chunk[0 .. @min(blob.bytes_remain, CHUNK_SIZE)];
        try blob.stream.readSliceAll(slice);
        hasher.update(slice);
    }
    return hasher.finalResult();
}

pub fn hashCopyBlob(input: *ty.Reader, output: []u8) !ty.BlobId {
    var hasher = Hasher.init(.{});
    var index: usize = 0;
    while (index < output.len) : (index += CHUNK_SIZE) {
        const chunk = output[index .. @min(index + CHUNK_SIZE, output.len)];
        try input.readSliceAll(chunk);
        hasher.update(chunk);
    }
    return hasher.finalResult();
}

pub fn hashBytesToHex(hash: ty.BlobId) ty.BlobIdStr {
    var string: ty.BlobIdStr = undefined;
    for (hash, 0..) |byte, index| {
        @memcpy(string[2 * index .. 2 * (index + 1)], &byteToHex(byte));
        //@memcpy(sliceChunk(2, string, index), &byteToHex(byte));
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
        const slice = string[2 * index .. 2 * (index + 1)];
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
        else => {
            debug("hexDigitToNibble: " ++
                  "invalid hex digit: '{c}'\n", .{digit});
            return ty.Err.Internal;
        },
    };
}

const NibblePair = packed struct(u8) {
    lo: u4,
    hi: u4,
};

fn sliceChunk(comptime chunk_size: usize, slice: anytype, chunk_num: usize)
        []std.meta.Child(@TypeOf(slice)) {
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
