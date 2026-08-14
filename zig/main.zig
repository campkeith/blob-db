const ty = @import("types.zig");
const Persister = @import("persister.zig").Persister;

pub fn main(init: ty.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();

    const std = @import("std");

    try persister.store_create("bong");
    _ = try persister.store_list();
    const file = try std.Io.Dir.openFileAbsolute(init.io, "/dev/zero", .{});
    const buffer = try std.heap.page_allocator.alloc(u8, 4096);
    const reader = file.reader(init.io, buffer).interface;
    const size = try file.length(init.io);
    var stream: ty.BlobStream = .{.bytes_remain = size, .stream = reader};
    _ = try persister.blob_save("bong", &stream);
    _ = try persister.blob_list("bong");
    _ = try persister.blob_info("bong", "0123456789abcdef0123456789abcdef".*);
    _ = try persister.blob_load("bong", "0123456789abcdef0123456789abcdef".*);
    try persister.blob_delete("bong", "0123456789abcdef0123456789abcdef".*);
    try persister.store_destroy("bong");
}
