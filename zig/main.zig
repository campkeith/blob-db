const std = @import("std");

const Persister = @import("Persister.zig");
const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();
    var server = try Server.create(init, &persister);
    try server.go(init.gpa);
}
