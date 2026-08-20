const std = @import("std");

const ty = @import("blob-db/types.zig");
const mem = @import("blob-db/mem.zig");
const funcs = @import("blob-db/funcs.zig");

pub const StoreId = []u8;
pub const Blob = []u8;

pub fn store_id(rng: *std.Random, max_size: usize) !ty.StoreId {
    const size = size_geometric(rng, max_size);
    const alphabet = std.fs.base64_alphabet;
    const id = try mem.alloc(u8, size);
    for (id) |*char| {
        const index = rng.uintLessThan(usize, alphabet.len);
        char.* = alphabet[index];
    }
    return .{.id = id};
}

pub fn blob_id(rng: *std.Random) ty.BlobId {
    var out: ty.BlobId = undefined;
    rng.bytes(&out);
    return out;
}

pub fn blob(rng: *std.Random, max_size: usize) !Blob {
    const size = size_geometric(rng, max_size);
    const out = try mem.alloc(u8, size);
    errdefer mem.free(out);
    rng.bytes(out);
    return out;
}

pub fn size_geometric(rng: *std.Random, max_size: usize) usize {
    // We add one as max_size is an inclusive upper-bound while the uniform
    // random distribution and floor quantization exclude the upper-bound.
    const max_f64: f64 = @floatFromInt(max_size + 1);
    const log_size = @log(max_f64) * rng.float(f64);
    const size: usize = @intFromFloat(@exp(log_size));
    // Clip to max_size when floating-point error causes size to exceed it.
    return @min(size, max_size);
}
