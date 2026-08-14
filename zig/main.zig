const ty = @import("types.zig");
const Persister = @import("Persister.zig");
const Server = @import("Server.zig");

pub fn main(init: ty.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();
    var server = try Server.create(init, &persister);
    try server.go();
}
