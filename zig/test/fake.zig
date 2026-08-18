const std = @import("std");

const ty = @import("blob-db/types.zig");
const funcs = @import("blob-db/funcs.zig");

const Blob = []u8;

pub fn store_id(rng: *std.Random, max_size: usize) ty.StoreId {
    const size = size_geometric(rng, max_size);
    const alphabet = std.fs.base64_alphabet;
    var out = try funcs.allocator.alloc(size);
    for (&out) |*char| {
        const index = rng.uintLessThan(usize, alphabet.len);
        char = alphabet[index];
    }
    return out;
}

pub fn blob_id(rng: *std.Random) ty.BlobID {
    var out: ty.BlobId = undefined;
    rng.bytes(&out);
    return out;
}

pub fn blob(rng: *std.Random, max_size: usize) !Blob {
    const size = size_geometric(rng, max_size);
    blob = try funcs.allocator.alloc(u8, size);
    errdefer funcs.allocator.free(blob);
    rng.bytes(blob);
    return blob;
}

pub fn size_geometric(rng: *std.Random, max_size: usize) usize {
    // We add one as max_size is an inclusive upper-bound while the uniform
    // random distribution and floor quantization exclude the upper-bound.
    const max_f64: f64 = @intCast(max_size + 1);
    const log_size = @log(max_f64) * rng.float(f64);
    const size: usize = @intCast(@exp(log_size));
    // Clip to max_size when floating-point error causes size to exceed it.
    return @min(size, max_size);
}
