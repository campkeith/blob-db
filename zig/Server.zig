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

const fmt = @import("format.zig");
const Fmt = fmt.Fmt;

const ty = @import("types.zig");
const Err = ty.Err;
const Request = ty.Request;
const Response = ty.Response;

const fns = @import("functions.zig");
const Blob = @import("Blob.zig");
const trash = @import("trash.zig");
const Persister = @import("Persister.zig");
const send_recv = @import("send_recv.zig");

const Self = @This();

const Selector = Io.Select(AcceptSleepResult);
const AcceptSleepResult = union(enum) {
    accept: fns.returnType(@TypeOf(Server.accept)),
    sleep: fns.returnType(@TypeOf(Io.sleep)),
};

io: Io,
inner: *Persister,
address: IpAddress,
running: bool,

pub fn create(init: std.process.Init, inner: *Persister) !Self {
    const address_str = try fns.getEnv(init.environ_map, "BIND_ADDRESS");
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
    fns.println("Server at {f} is up.", .{Fmt(server.socket.address)});

    var select_buf: [2]AcceptSleepResult = undefined;
    var select: Selector = .init(self.io, &select_buf);
    defer select.cancelDiscard();
    self.startAccept(&select, &server);
    self.startSleep(&select);
    while (self.running) {
        const result = try select.await();
        switch (result) {
            .accept => |accept_result| {
                {
                    var stream = accept_result catch |err| switch (err) {
                        error.SocketNotListening, error.WouldBlock => {
                            fns.println("Fatal server error: {t}", .{err});
                            return err;
                        },
                        else => {
                            fns.println("Error connecting to client: {t}",
                                          .{err});
                            continue;
                        },
                    };
                    defer stream.close(self.io);
                    self.clientSession(arena, &stream);
                }
                self.startAccept(&select, &server);
            },
            .sleep => |sleep_result| {
                try sleep_result;
                self.startSleep(&select);
            },
        }
    }
}

pub fn stop(self: *Self) void {
    self.running = false;
}

fn startAccept(self: *Self, select: *Selector, server: *Server) void {
    select.async(.accept, Server.accept, .{server, self.io});
}

fn startSleep(self: *Self, select: *Selector) void {
    select.async(.sleep, Io.sleep, .{self.io, .fromSeconds(1), .awake});
}

fn clientSession(self: *Self, arena: Allocator, stream: *Stream) void {
    const peer_addr = peerAddress(stream) catch null;
    fns.println("Client at {f} connected.", .{Fmt(peer_addr)});

    self.handleStream(arena, stream) catch |raw_err| {
        const err = handleError(raw_err);
        fns.println("Dropping client at {f} due to {t}.",
                      .{Fmt(peer_addr), err});
        return;
    };
    fns.println("Client at {f} disconnected.", .{Fmt(peer_addr)});
}

fn handleStream(self: *Self, arena: Allocator, stream: *Stream) !void {
    const BUF_SIZE = 4096;
    const read_buf = try arena.alloc(u8, BUF_SIZE);
    defer arena.free(read_buf);
    var in = stream.reader(self.io, read_buf);
    const write_buf = try arena.alloc(u8, BUF_SIZE);
    defer arena.free(write_buf);
    var out = stream.writer(self.io, write_buf);

    try shakeHands(&in.interface, &out.interface);
    while (try self.handleRequest(arena, &in.interface, &out.interface)) {}
}

fn shakeHands(in: *Reader, out: *Writer) !void {
    send_recv.recvOpenDoor(in) catch |err| return switch (err) {
        Err.BadArgument => out: {
            try send_recv.sendNotWelcome(out);
            break :out Err.BadArgument;
        },
        else => err,
    };
    try send_recv.sendWelcome(out);
}

fn handleRequest(self: *Self, arena: Allocator,
                      in: *Reader, out: *Writer) !bool {
    var request = try send_recv.recvRequest(in, arena);
    defer trash.recycle(&request, arena);
    var response = self.processRequest(arena, request)
        orelse return false;
    defer trash.recycle(&response, arena);
    try send_recv.sendResponse(out, response);
    return true;
}

fn processRequest(self: *Self, arena: Allocator, request: Request) ?Response {
    return switch (request) {
        .call => |call|
            if (self.processCallRequest(arena, call))
                |resp| .{.call = resp}
                else |err| .{.err = handleError(err)},
        .bye => null,
    };
}

fn processCallRequest(self: *Self, arena: Allocator, call: Request.Call)
        !Response.Call {
    return switch (call) {
        .store_list => .{.store_list =
            try self.inner.storeList(arena)},
        .store_create => |store_id| .{.store_create =
            try self.inner.storeCreate(store_id)},
        .store_destroy => |store_id| .{.store_destroy =
            try self.inner.storeDestroy(store_id)},
        .blob_hash => |blob| .{.blob_hash =
            try blob.hash(arena)},
        .blob_list => |store_id| .{.blob_list =
            try self.inner.blobList(arena, store_id)},
        .blob_info => |args| .{.blob_info =
            try self.inner.blobInfo(args.store_id, args.blob_id)},
        .blob_load => |args| .{.blob_load =
            try self.inner.blobLoad(args.store_id, args.blob_id)},
        .blob_save => |args| .{.blob_save =
            try self.inner.blobSave(args.store_id, args.blob)},
        .blob_delete => |args| .{.blob_delete =
            try self.inner.blobDelete(args.store_id, args.blob_id)},
    };
}

fn handleError(err: anytype) Err {
    return switch (err) {
        Err.NotFound, Err.Exists, Err.BadArgument, Err.Internal =>
            |err_| err_,
        else => unexpected: {
            fns.println("handleError: Unexpected internal error: {t}", .{err});
            if (@errorReturnTrace()) |trace| {
                const size = @min(trace.index, trace.instruction_addresses.len);
                std.debug.dumpStackTrace(&.{
                    .return_addresses = trace.instruction_addresses[0..size],
                    .skipped = .none,
                });
            }
            break :unexpected Err.Internal;
        }
    };
}

fn peerAddress(stream: *Stream) !IpAddress {
    var addr_buf: sockaddr.storage = undefined;
    var size: std.posix.socklen_t = @sizeOf(@TypeOf(addr_buf));
    const address: *sockaddr = @ptrCast(&addr_buf);
    try std.posix.getpeername(stream.socket.handle, address, &size);
    return Io.Threaded.addressFromPosix(&.{.any = address.*});
}
