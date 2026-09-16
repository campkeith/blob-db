const std = @import("std");
const Io = std.Io;
const json = std.json;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const activeTag = std.meta.activeTag;
const Hasher = std.crypto.hash.sha2.Sha256;

const ty = @import("types.zig");
const Err = ty.Err;

const fns = @import("functions.zig");
const record = @import("record.zig");

const chunk_size: usize = 64 * 1024;

const Self = @This();

core: Core,

const Core = union(enum) {
    stream: *Stream,
    file: File,
    memory: []const u8,
};

pub const Id = struct {
    hash: [32]u8,

    pub const init = record.init(Id);

    pub fn jsonStringify(self: Id, stringify: *json.Stringify) !void {
        return stringify.write(formatId(self));
    }

    pub fn format(self: Id, writer: *Writer) !void {
        try writer.writeAll(&formatId(self));
    }

    pub fn lessThan(_: void, a: Id, b: Id) bool {
        return std.mem.lessThan(u8, &a.hash, &b.hash);
    }
};

pub const IdStr = [64]u8;
pub const Size = u64;

pub const Stream = struct {
    reader: *Reader,
    bytes_left: usize,

    pub fn discard(self: *Stream) void {
        self.reader.discardAll(self.bytes_left) catch |err| {
            std.debug.print("Self.Stream.discard failed due to {}.\n", .{err});
            return;
        };
        self.bytes_left = 0;
    }
};

pub const File = struct {
    file: Io.File,
    io: Io,

    pub fn close(self: File) void {
        self.file.close(self.io);
    }

    pub fn size(self: File) !usize {
        return try self.file.length(self.io);
    }
};

const init = record.init(Self);

pub fn initStream(arena: Allocator, reader: *Reader, size_: usize) !Self {
    const stream = try arena.create(Stream);
    errdefer arena.destroy(stream);
    stream.* = .{.reader = reader, .bytes_left = size_};
    return .init(.{.stream = stream});
}

pub fn initFile(file: Io.File, io: Io) Self {
    return .init(.{.file = .{.file = file, .io = io}});
}

pub fn initMemory(memory: []const u8) Self {
    return .init(.{.memory = memory});
}

pub fn deinit(self: Self, arena: Allocator) void {
    switch (self.core) {
        .stream => |stream| {
            stream.discard();
            arena.destroy(stream);
        },
        .file => |file| file.close(),
        .memory => {},
    }
}

pub fn format(self: Self, out: *Writer) !void {
    const tag = activeTag(self.core);
    const size_: ?Size = self.size() catch null;
    try out.print("Self(type = {t}, size = {?d})", .{tag, size_});
}

pub fn size(self: Self) !Size {
    return switch (self.core) {
        .stream => |in| in.bytes_left,
        .file => |file| try file.size(),
        .memory => |bytes| bytes.len,
    };
}

pub fn hash(self: Self, arena: Allocator) !Id {
    return switch (self.core) {
        .stream => |in| blob_id: {
            var hasher = Hasher.init(.{});
            var chunk = try arena.alloc(u8, chunk_size);
            defer arena.free(chunk);
            while (in.bytes_left > 0) {
                const slice = chunk[0 .. @min(in.bytes_left, chunk_size)];
                try in.reader.readSliceAll(slice);
                in.bytes_left -= slice.len;
                hasher.update(slice);
            }
            break :blob_id .init(hasher.finalResult());
        },
        .file => |file| blob_id: {
            const mmap_opts: std.Io.File.MemoryMap.CreateOptions = .{
                .len = try file.file.length(file.io),
            };
            var mem_map = try file.file.createMemoryMap(file.io, mmap_opts);
            defer mem_map.destroy(file.io);
            break :blob_id hashMemory(mem_map.memory);
        },
        .memory => |bytes| hashMemory(bytes),
    };
}

pub fn hashCopy(self: Self, out: []u8) !Id {
    return switch (self.core) {
        .stream => |in| blob_id: {
            if (in.bytes_left != out.len) {
                fns.println("hashCopySelf[stream]: size mismatch: ({d}, {d})",
                            .{in.bytes_left, out.len});
                return Err.Internal;
            }
            var hasher = Hasher.init(.{});
            var index: usize = 0;
            while (index < out.len) : (index += chunk_size) {
                const chunk = out[index .. @min(index + chunk_size, out.len)];
                try in.reader.readSliceAll(chunk);
                in.bytes_left -= chunk.len;
                hasher.update(chunk);
            }
            break :blob_id .init(hasher.finalResult());
        },
        else => err: {
            const tag = activeTag(self.core);
            fns.println("hashCopy: {any} not supported.", .{tag});
            break :err Err.Internal;
        },
    };
}


pub fn hashMemory(memory: []const u8) Id {
    var id: @FieldType(Id, "hash") = undefined;
    Hasher.hash(memory, &id, .{});
    return .init(id);
}

pub fn formatId(id: Id) IdStr {
    return std.mem.toBytes(fns.map(id.hash, byteToHexPair));
}

fn byteToHexPair(byte: u8) [2]u8 {
    const pair: NibblePair = @bitCast(byte);
    return .{nibbleToHex(pair.hi), nibbleToHex(pair.lo)};
}

fn nibbleToHex(nibble: u4) u8 {
    return switch (nibble) {
        0x0...0x9 => @as(u8, nibble) + '0',
        0xa...0xf => @as(u8, nibble) - 0xa + 'a',
    };
}

pub fn parseId(id_str: []const u8) !Id {
    if (id_str.len != @typeInfo(IdStr).array.len) {
        fns.println("Blob.parseId: invalid length id: \"{s}\"", .{id_str});
        return Err.BadArgument;
    }
    const HexPairs = [@typeInfo(@FieldType(Id, "hash")).array.len][2]u8;
    const id = try fns.map(std.mem.bytesToValue(HexPairs, id_str), hexPairToByte);
    return .init(id);
}

fn hexPairToByte(hex_pair: [2]u8) !u8 {
    const hi, const lo = hex_pair;
    const nibbles: NibblePair = .{.hi = try hexToNibble(hi),
                                  .lo = try hexToNibble(lo)};
    return @bitCast(nibbles);
}

fn hexToNibble(digit: u8) !u4 {
    return switch (digit) {
        '0'...'9' => @intCast(digit - '0'),
        'a'...'f' => @intCast(digit - 'a' + 0xa),
        else => err: {
            fns.println("hexDigitToNibble: not a hex digit: '{c}'", .{digit});
            break :err Err.BadArgument;
        },
    };
}

const NibblePair = packed struct(u8) {
    lo: u4,
    hi: u4,
};
