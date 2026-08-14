const std = @import("std");

const ty = @import("types.zig");

pub const allocator = std.heap.page_allocator;
pub const alloc = allocator.alloc;
pub const free = allocator.free;
pub const debug = std.debug.print;

const CHUNK_SIZE: usize = 64 * 1024;
const Hasher = std.crypto.hash.sha2.Sha256;

pub fn getEnv(env: *ty.EnvMap, name: []const u8) ty.Err![]const u8 {
    return env.get(name) orelse {
        debug("Missing required environment variable: {s}\n", .{name});
        return ty.Err.Internal;
    };
}

pub fn hashBlob(blob: ty.Blob) ty.BlobId {
    var blob_id: ty.BlobId = undefined;
    Hasher.hash(blob, &blob_id, .{});
    return blob_id;
}

pub fn hashStream(input: ty.Reader) !ty.BlobId {
    var hasher = Hasher.init(.{});
    var chunk = allocator.alloc(u8, CHUNK_SIZE);
    defer allocator.free(chunk);
    while (try input.readSliceShort(chunk)) |size| {
        hasher.update(chunk[0..size]);
    }
    return hasher.finalResult();
}

pub fn hashCopyStream(input: *ty.Reader, output: []u8) !ty.BlobId {
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
