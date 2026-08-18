const std = @import("std");

const fake = @import("fake.zig");
const Client = @import("blob-db/Client.zig");

pub fn main() !void {
    var rng_impl = std.Random.DefaultPrng.init(0);
    const rng = rng_impl.random();
    _ = rng;
}
