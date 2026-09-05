const std = @import("std");
const posix = std.posix;

const Persister = @import("Persister.zig");
const Server = @import("Server.zig");

var server: Server = undefined;

pub fn main(init: std.process.Init) !void {
    var persister = try Persister.create(init);
    defer persister.destroy();
    server = try Server.create(init, &persister);
    registerSignalHandler();
    try server.go(init.gpa);
}

fn registerSignalHandler() void {
    const action = posix.Sigaction {
        .handler =  .{.handler = handleSignal},
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
}

fn handleSignal(_: posix.SIG) callconv(.c) void {
    server.stop();
}
