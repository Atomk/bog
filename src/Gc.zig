const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const bog = @import("bog.zig");
const Value = bog.Value;
const expect = std.testing.expect;

//! A generational non-moving garbage collector.
//! Inspired by https://www.pllab.riec.tohoku.ac.jp/papers/icfp2011UenoOhoriOtomoAuthorVersion.pdf

/// A pool of values prefixed with a header containing two bitmaps for
/// the old and young generation.
const Page = struct {
    const max_size = 1_048_576;
    comptime {
        // 2^20, 1 MiB
        assert(@sizeOf(Page) == max_size);
    }
    const val_count = 25_574;
    const pad_size = max_size - @sizeOf(u32) - (@sizeOf(Value) + @sizeOf(State)) * val_count;

    const State = enum(u8) {
        empty,
        white,
        gray,
        black,
    };

    /// States of all values.
    meta: [val_count]State,
    /// Padding to ensure size is 1 MiB.
    __padding: [pad_size]u8 = @compileError("do not initiate directly"),

    /// Index to the first free slot.
    free: u32,

    /// Actual values, all pointers will stay valid as long as they are
    /// referenced from a root.
    values: [val_count]Value,

    fn create() !*Page {
        const page = try std.heap.page_allocator.create(Page);
        mem.set(usize, mem.bytesAsSlice(usize, mem.asBytes(page)), 0);
        return page;
    }

    fn deinit(page: *Page, gc: *Gc) void {
        for (page.meta) |s, i| {
            if (s == .empty) continue;
            page.values[i].deinit(gc.gpa);
        }
        std.heap.page_allocator.destroy(page);
    }

    fn alloc(page: *Page) ?*Value {
        while (page.free < page.values.len) {
            defer page.free += 1;

            if (page.meta[page.free] == .empty) {
                page.meta[page.free] = .white;
                return &page.values[page.free];
            }
        }
        return null;
    }

    fn clear(page: *Page, gc: *Gc) u32 {
        var freed: u32 = 0;
        for (page.meta) |s, i| {
            switch (s) {
                .black, .gray => {
                    // value lives to see another day
                    page.meta[i] = .white;
                },
                .white => {
                    freed += 1;
                    page.meta[i] = .empty;
                    page.values[i].deinit(gc.gpa);
                    if (page.free > i) {
                        page.free = @truncate(u32, i);
                    }
                },
                .empty => {},
            }
        }
        return freed;
    }
};

const Gc = @This();

pages: std.ArrayListUnmanaged(*Page) = .{},
stack: std.ArrayListUnmanaged(?*Value) = .{},
roots: std.ArrayListUnmanaged(*Value) = .{},
gpa: *Allocator,
page_limit: u32,

const PageAndIndex = struct {
    page: *Page,
    index: usize,
};

fn findInPage(gc: *Gc, value: *const Value) PageAndIndex {
    for (gc.pages.items) |page| {
        // is the value before this page
        if (@ptrToInt(value) < @ptrToInt(page)) continue;
        // is the value after this page
        if (@ptrToInt(value) > @ptrToInt(page) + @sizeOf(Page)) continue;

        // value is in this page
        return .{
            .page = page,
            // calculate index from offset from `Page.values`
            .index = (@ptrToInt(value) - (@ptrToInt(page) + @byteOffsetOf(Page, "values"))) / @sizeOf(Value),
        };
    }

    unreachable; // value was not allocated by the gc.
}

fn markVal(gc: *Gc, value: *const Value) void {
    const loc = gc.findInPage(value);
    if (loc.page.meta[loc.index] == .white) {
        loc.page.meta[loc.index] = .gray;
    }
}

fn markGray(gc: *Gc) void {
    for (gc.pages.items) |page| {
        for (page.meta) |*s, i| {
            if (s.* == .gray) {
                s.* = .black;
                switch (page.values[i]) {
                    .list => |list| {
                        for (list.items) |val| {
                            gc.markVal(val);
                        }
                    },
                    .tuple => |tuple| {
                        for (tuple) |val| {
                            gc.markVal(val);
                        }
                    },
                    .map => |map| {
                        for (map.items()) |*entry| {
                            gc.markVal(entry.key);
                            gc.markVal(entry.value);
                        }
                    },
                    .err => |err| {
                        gc.markVal(err);
                    },
                    .func => |func| {
                        for (func.captures) |val| {
                            gc.markVal(val);
                        }
                    },
                    .iterator => |iter| {
                        gc.markVal(iter.value);
                    },
                    else => {},
                }
            }
        }
    }
}

pub fn collect(gc: *Gc) usize {
    for (gc.stack.items) |val| {
        const loc = gc.findInPage(val orelse continue);

        loc.page.meta[loc.index] = .gray;
    }
    for (gc.roots.items) |val| {
        const loc = gc.findInPage(val);

        loc.page.meta[loc.index] = .gray;
    }
    gc.markGray();
    var freed: usize = 0;
    for (gc.pages.items) |page| {
        freed += page.clear(gc);
    }
    return freed;
}

pub fn init(allocator: *Allocator, page_limit: u32) Gc {
    std.debug.assert(page_limit >= 1);
    return .{
        .gpa = allocator,
        .page_limit = page_limit,
    };
}

/// Frees all values and their allocations.
pub fn deinit(gc: *Gc) void {
    for (gc.pages.items) |page| page.deinit(gc);
    gc.pages.deinit(gc.gpa);
    gc.stack.deinit(gc.gpa);
    gc.roots.deinit(gc.gpa);
}

/// Allocate a new Value on the heap.
pub fn alloc(gc: *Gc) !*Value {
    if (gc.pages.items.len == 0) {
        const page = try Page.create();
        errdefer page.deinit(gc);
        try gc.pages.append(gc.gpa, page);

        // we just created this page so it is empty.
        return page.alloc() orelse unreachable;
    }

    for (gc.pages.items) |page| {
        if (page.alloc()) |some| return some;
    }

    const freed = gc.collect();

    if (freed < Page.val_count / 4 and gc.pages.items.len != gc.page_limit) {
        const page = try Page.create();
        errdefer page.deinit(gc);
        try gc.pages.append(gc.gpa, page);

        // we just created this page so it is empty.
        return page.alloc() orelse unreachable;
    } else if (freed != 0) {
        // we just freed over Page.val_count / 4, values, allocation cannot fail
        return gc.alloc() catch unreachable;
    }

    // no values could be collected and page_limit has been reached
    return error.OutOfMemory;
}

/// Allocates a shallow copy of `val`.
pub fn dupe(gc: *Gc, val: *const Value) !*Value {
    // no need to copy always memoized values
    switch (val.*) {
        .none => return &Value.None,
        .bool => |b| return if (b) &Value.True else &Value.False,
        else => {},
    }

    const new = try gc.alloc();
    switch (val.*) {
        .list => |*l| {
            new.* = .{ .list = .{} };
            try new.list.appendSlice(gc.gpa, l.items);
        },
        .tuple => |t| {
            new.* = .{ .tuple = try gc.gpa.dupe(*Value, t) };
        },
        .map => |*m| {
            new.* = .{ .map = try m.clone(gc.gpa) };
        },
        .str => |*s| {
            if (s.capacity != 0) {
                new.* = .{
                    .str = .{
                        .data = try gc.gpa.dupe(u8, s.data),
                        .capacity = s.data.len,
                    },
                };
            } else {
                new.* = val.*;
            }
        },
        else => new.* = val.*,
    }
    return new;
}

/// Get value from stack at `index`.
/// Returns `error.NullPtrDeref` if stack has no value at `index`.
pub fn stackGet(gc: *Gc, index: usize) !*Value {
    if (index >= gc.stack.items.len)
        return error.NullPtrDeref;

    return gc.stack.items[index] orelse
        error.NullPtrDeref;
}

/// Only valid until next `stackAlloc` call.
pub fn stackRef(gc: *Gc, index: usize) !*?*Value {
    while (index >= gc.stack.items.len) {
        try gc.stack.append(gc.gpa, null);
    }
    return &gc.stack.items[index];
}

/// Allocates new value on stack, invalidates all references to stack values.
pub fn stackAlloc(gc: *Gc, index: usize) !*Value {
    const val = try gc.stackRef(index);
    if (val.*) |some| switch (some.*) {
        .int, .num, .native, .tagged, .str => {},
        else => val.* = try gc.alloc(),
    } else {
        val.* = try gc.alloc();
    }
    return val.*.?;
}

/// Shrinks stack to `size`, doesn't free any memory.
pub fn stackShrink(gc: *Gc, size: usize) void {
    if (size > gc.stack.items.len) return;
    gc.stack.items.len = size;
}

pub fn removeRoot(gc: *Gc, opt_val: ?*Value) void {
    const val = opt_val orelse return;
    for (gc.roots.items) |root, i| {
        if (root == val) {
            _ = gc.roots.swapRemove(i);
            return;
        }
    }
}

test "basic collect" {
    var gc = Gc.init(std.testing.allocator, 1);
    defer gc.deinit();

    var tuple = try gc.stackAlloc(0);
    tuple.* = .{ .tuple = try gc.gpa.alloc(*Value, 32) };

    for (tuple.tuple) |*e, i| {
        const val = try gc.alloc();
        val.* = .{ .int = @intCast(i64, i) };
        e.* = val;
    }

    var i: i64 = 0;
    while (i < (1024 - 32 - 1 - 2)) : (i += 1) {
        const val = try gc.alloc();
        val.* = .{ .int = @intCast(i64, i) };
    }

    {
        // self referencing values should be collected
        const a = try gc.alloc();
        const b = try gc.alloc();
        a.* = .{ .err = b };
        b.* = .{ .err = a };
    }

    expect(gc.pages.items[0].free == 1024);
    expect(gc.collect() == 1024 - 32 - 1);
    expect(gc.pages.items[0].free == 33);
}

test "major collection" {
    var gc = Gc.init(std.testing.allocator, 2);
    defer gc.deinit();

    // ensure we allocate at least 2 pages.
    const alloc_count = Page.val_count + Page.val_count / 2;

    // create a looped chain of values
    var i: i64 = 0;
    var first: *Value = try gc.stackAlloc(0);
    var prev: *Value = first;
    while (i < alloc_count) : (i += 1) {
        const val = try gc.alloc();
        prev.* = .{ .err = val };
        prev = val;
        val.* = .{ .int = 1 };
    }
    prev.* = .{ .err = first };

    gc.stack.items.len = 0;
    expect(gc.collect() == alloc_count + 1);
}
