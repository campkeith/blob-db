const std = @import("std");
const Io = std.Io;
const sockaddr = std.posix.sockaddr;
const IpAddress = std.Io.net.IpAddress;
const Server = std.Io.net.Server;
const Stream = std.Io.net.Stream;
const Future = std.Io.Future;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const debug = @import("debug.zig");
const Fmt = debug.Fmt;

const ty = @import("types.zig");
const funcs = @import("funcs.zig");
const trash = @import("trash.zig");
const Persister = @import("Persister.zig");
const send_recv = @import("send_recv.zig");

const Self = @This();

const Selector = Io.Select(AcceptSleepResult);
const AcceptSleepResult = union(enum) {
    accept: funcs.returnType(@TypeOf(Server.accept)),
    sleep: funcs.returnType(@TypeOf(Io.sleep)),
};

io: Io,
inner: *Persister,
address: IpAddress,
running: bool,

pub fn create(init: std.process.Init, inner: *Persister) !Self {
    const address_str = try funcs.getEnv(init.environ_map, "BIND_ADDRESS");
    const address = try IpAddress.parseLiteral(address_str);
    return .{
        .io = init.io,
        .inner = inner,
        .address = address,
        .running = false,
    };
}

pub fn go(self: *Self, arena: Allocator) !void {
    const opts: IpAddress.ListenOptions = .{
        .reuse_address = true,
    };
    var server = try self.address.listen(self.io, opts);
    defer server.deinit(self.io);
    self.running = true;
    funcs.println("Server at {f} is up.", .{Fmt(server.socket.address)});

    var select_buf: [2]AcceptSleepResult = undefined;
    var select: Selector = .init(self.io, &select_buf);
    defer select.cancelDiscard();
    self.start_accept(&select, &server);
    self.start_sleep(&select);
    while (self.running) {
        const result = try select.await();
        switch (result) {
            .accept => |accept_result| {
                {
                    var stream = accept_result catch |err| switch (err) {
                        error.SocketNotListening, error.WouldBlock => {
                            funcs.println("Fatal server error: {t}", .{err});
                            return err;
                        },
                        else => {
                            funcs.println("Error connecting to client: {t}",
                                          .{err});
                            continue;
                        },
                    };
                    defer stream.close(self.io);
                    self.clientSession(arena, &stream);
                }
                self.start_accept(&select, &server);
            },
            .sleep => |sleep_result| {
                try sleep_result;
                self.start_sleep(&select);
            },
        }
    }
}

pub fn stop(self: *Self) void {
    self.running = false;
}

fn start_accept(self: *Self, select: *Selector, server: *Server) void {
    select.async(.accept, Server.accept, .{server, self.io});
}

fn start_sleep(self: *Self, select: *Selector) void {
    select.async(.sleep, Io.sleep, .{self.io, .fromSeconds(1), .awake});
}

fn clientSession(self: *Self, arena: Allocator, stream: *Stream) void {
    const peer_addr = peer_address(stream) catch null;
    funcs.println("Client at {f} connected.", .{Fmt(peer_addr)});

    self.handle_stream(arena, stream) catch |raw_err| {
        const err = handle_error(raw_err);
        funcs.println("Dropping client at {f} due to {t}.",
                      .{Fmt(peer_addr), err});
        return;
    };
    funcs.println("Client at {f} disconnected.", .{Fmt(peer_addr)});
}

fn handle_stream(self: *Self, arena: Allocator, stream: *Stream) !void {
    const BUF_SIZE = 4096;
    const read_buf = try arena.alloc(u8, BUF_SIZE);
    defer arena.free(read_buf);
    var in = stream.reader(self.io, read_buf);
    const write_buf = try arena.alloc(u8, BUF_SIZE);
    defer arena.free(write_buf);
    var out = stream.writer(self.io, write_buf);

    try shake_hands(&in.interface, &out.interface);
    while (try self.handle_request(arena, &in.interface, &out.interface)) {}
}

fn shake_hands(in: *Reader, out: *Writer) !void {
    send_recv.recvOpenDoor(in) catch |err| return switch (err) {
        ty.Err.BadArgument => out: {
            try send_recv.sendNotWelcome(out);
            break :out ty.Err.BadArgument;
        },
        else => err,
    };
    try send_recv.sendWelcome(out);
}

fn handle_request(self: *Self, arena: Allocator,
                      in: *Reader, out: *Writer) !bool {
    const request = try send_recv.recvRequest(in, arena);
    defer trash.recycle(request, arena);
    const response = self.process_request(arena, request)
        orelse return false;
    defer trash.recycle(response, arena);
    try send_recv.sendResponse(out, response);
    return true;
}

fn process_request(self: *Self, arena: Allocator, request: ty.Request)
        ?ty.Response {
    return switch (request) {
        .call => |call|
            if (self.process_call_request(arena, call))
                |resp| .{.call = resp}
                else |err| .{.err = handle_error(err)},
        .bye => null,
    };
}

fn process_call_request(self: *Self, arena: Allocator, call: ty.Request.Call)
        !ty.Response.Call {
    return switch (call) {
        .store_list => .{.store_list =
            try self.inner.store_list(arena)},
        .store_create => |store_id| .{.store_create =
            try self.inner.store_create(store_id)},
        .store_destroy => |store_id| .{.store_destroy =
            try self.inner.store_destroy(store_id)},
        .blob_hash => |blob| .{.blob_hash =
            try funcs.hashBlob(arena, blob)},
        .blob_list => |store_id| .{.blob_list =
            try self.inner.blob_list(arena, store_id)},
        .blob_info => |args| .{.blob_info =
            try self.inner.blob_info(args.store_id, args.blob_id)},
        .blob_load => |args| .{.blob_load =
            try self.inner.blob_load(args.store_id, args.blob_id)},
        .blob_save => |args| .{.blob_save =
            try self.inner.blob_save(args.store_id, args.blob)},
        .blob_delete => |args| .{.blob_delete =
            try self.inner.blob_delete(args.store_id, args.blob_id)},
    };
}

fn handle_error(err: anytype) ty.Err {
    return switch (err) {
        ty.Err.NotFound, ty.Err.Exists, ty.Err.BadArgument, ty.Err.Internal =>
            |err_| err_,
        else => unexpected: {
            funcs.println("handle_error: Unexpected internal error: {t}", .{err});
            if (@errorReturnTrace()) |trace| {
                const size = @min(trace.index, trace.instruction_addresses.len);
                std.debug.dumpStackTrace(&.{
                    .return_addresses = trace.instruction_addresses[0..size],
                    .skipped = .none,
                });
            }
            break :unexpected ty.Err.Internal;
        }
    };
}

fn peer_address(stream: *Stream) !IpAddress {
    var addr_buf: sockaddr.storage = undefined;
    var size: std.posix.socklen_t = @sizeOf(@TypeOf(addr_buf));
    const address: *sockaddr = @ptrCast(&addr_buf);
    try std.posix.getpeername(stream.socket.handle, address, &size);
    return Io.Threaded.addressFromPosix(&.{.any = address.*});
}
