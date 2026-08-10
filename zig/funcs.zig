const std = @import("std");
const ty = @import("types.zig");

const CHUNK_SIZE: usize = 64 * 1024;
const allocator = std.heap.page_allocator;
const Hasher = std.crypto.hash.sha2.Sha256;

fn env_get(env: std.process.EnvMap, name: []const u8) ty.Err![]const u8 {
    return env.get(name) orelse {
        std.debug.print("Missing required environment variable: {s}", .{name});
        return ty.Err.internal;
    };
}

fn blob_hash(blob: ty.Blob) ty.BlobId {
    var blob_id: ty.BlobId = undefined;
    Hasher.hash(blob, &blob_id, .{});
    return blob_id;
}

fn stream_hash(input: std.Io.Reader) !ty.BlobId {
    var hasher = Hasher.init(.{});
    var chunk = allocator.alloc(u8, CHUNK_SIZE);
    defer allocator.free(chunk);
    while (try input.readSliceShort(chunk)) |size| {
        hasher.update(chunk[0..size]);
    }
    return hasher.finalResult();
}

fn stream_hash_copy(input: std.Io.Reader, output: []u8) !ty.BlobId {
    var hasher = Hasher.init(.{});
    var index: usize = 0;
    while (index < output.len) : (index += CHUNK_SIZE) {
        const chunk = output[index .. @min(index + CHUNK_SIZE, output.len)];
        try input.readSliceExact(chunk);
        hasher.update(chunk);
    }
    return hasher.finalResult();
}

fn hash_to_str(hash: ty.BlobId) ty.BlobIdStr {
    var string: ty.BlobIdStr = undefined;
    for (hash, 0..) |byte, index| {
        @memcpy(slice_chunk(&string, index, 2), byte_to_hex(byte));
    }
    return string;
}

fn byte_to_hex(byte: u8) [2]u8 {
    return .{ nibble_to_hex_digit(byte >> 4), nibble_to_hex_digit(byte & 0xf) };
}

fn nibble_to_hex_digit(nibble: u4) u8 {
    return switch (nibble) {
        0x0...0x9 => nibble + '0',
        0xa...0xf => nibble - 0xa + 'a',
    };
}

fn str_to_hash(string: ty.BlobIdStr) ty.Err!ty.BlobId {
    var hash: ty.BlobId = undefined;
    for (&hash, 0..) |*byte, index| {
        byte.* = try hex_to_byte(slice_chunk(string, index, 2));
    }
    return hash;
}

fn hex_to_byte(hex_pair: [2]u8) ty.Err!u8 {
    const hi, const lo = hex_pair;
    return try hex_digit_to_nibble(hi) << 4 | try hex_digit_to_nibble(lo);
}

fn hex_digit_to_nibble(digit: u8) ty.Err!u4 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 0xa,
        else => {
            std.debug.print("hex_digit_to_nibble: invalid hex digit: '{c}'",
                            .{digit});
            return ty.Err.internal;
        },
    };
}

fn slice_chunk(slice: anytype, chunk_num: usize, chunk_size: usize)
        []std.meta.Child(@TypeOf(slice)) {
    return slice[chunk_size * chunk_num .. chunk_size * (chunk_num + 1)];
}
