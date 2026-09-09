const std = @import("std");
const Random = std.Random;
const Allocator = std.mem.Allocator;

const ty = @import("blob-db/types.zig");
const StoreId = ty.StoreId;

const fns = @import("blob-db/functions.zig");
const RealBlob = @import("blob-db/Blob.zig");

pub const Blob = []u8;

pub fn storeId(rng: Random, arena: Allocator,
                min_size: usize, max_size: usize) !StoreId {
    const size = sizeGeometric(rng, min_size, max_size);
    const id = try fns.randomNameAlloc(rng, arena, size);
    return .init(id);
}

pub fn blobId(rng: Random) RealBlob.Id {
    var out: RealBlob.Id = undefined;
    rng.bytes(&out);
    return out;
}

pub fn blob(rng: Random, arena: Allocator,
            min_size: usize, max_size: usize) !Blob {
    const size = sizeGeometric(rng, min_size, max_size);
    const out = try arena.alloc(u8, size);
    errdefer arena.free(out);
    rng.bytes(out);
    return out;
}

pub fn sizeGeometric(rng: Random, min_size: usize, max_size: usize) usize {
    // We add one as max_size is an inclusive upper-bound while the uniform
    // random distribution and floor quantization exclude the upper-bound.
    const min_f64: f64 = @floatFromInt(min_size);
    const max_f64: f64 = @floatFromInt(max_size + 1);
    const log_size = @log(min_f64)
                   + rng.float(f64) * (@log(max_f64) - @log(min_f64));
    const size: usize = @intFromFloat(@exp(log_size));
    // Clip to size range when floating-point error causes size to fall outside.
    return @min(@max(size, min_size), max_size);
}
