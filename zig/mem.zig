const std = @import("std");

pub const allocator = std.heap.page_allocator;

pub fn create(Obj: type) !*Obj {
    return try allocator.create(Obj);
}

pub fn destroy(obj: anytype) void {
    allocator.destroy(obj);
}

pub fn alloc(Elem: type, count: usize) ![]Elem {
    return try allocator.alloc(Elem, count);
}

pub fn free(slice: anytype) void {
    allocator.free(slice);
}

pub fn dupe(Elem: type, source: []const Elem) ![]Elem {
    return try allocator.dupe(Elem, source);
}
