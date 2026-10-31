//! PDF Document Outline (Bookmarks / Table of Contents)
//!
//! Parses the /Outlines tree from the document catalog.
//! The outline is a linked-list tree:
//!   Catalog → /Outlines → {/First, /Last, /Count}
//!   Each item: {/Title, /Dest or /A, /Next, /First, /Last, /Count, /Parent}

const std = @import("std");
const parser = @import("parser.zig");
const pagetree = @import("pagetree.zig");
const xref_mod = @import("xref.zig");
const root = @import("root.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;
const Page = pagetree.Page;

const max_outline_depth: u32 = 64;
const max_outline_items: usize = 10_000;
const Visited = std.AutoHashMap(ObjRef, void);

pub const OutlineItem = struct {
    title: []const u8,
    page: ?usize,
    level: u32,
};

/// Parse the document outline tree into a flat list of items.
pub fn parseOutline(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
) ![]OutlineItem {
    return parseOutlineWithOptions(allocator, arena, data, xref, cache, pages, .{});
}

pub fn parseOutlineWithOptions(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
    options: pagetree.BuildOptions,
) ![]OutlineItem {
    // Get catalog
    const root_ref = switch (xref.trailer.get("Root") orelse return allocator.alloc(OutlineItem, 0)) {
        .reference => |r| r,
        else => return allocator.alloc(OutlineItem, 0),
    };
    const catalog = try pagetree.resolveRefWithOptions(arena, data, xref, root_ref, cache, options);
    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return allocator.alloc(OutlineItem, 0),
    };

    // Get /Outlines dict
    const outlines_obj = catalog_dict.get("Outlines") orelse return allocator.alloc(OutlineItem, 0);
    const outlines_dict = switch (outlines_obj) {
        .dict => |d| d,
        .reference => |r| blk: {
            const obj = pagetree.resolveRefWithOptions(arena, data, xref, r, cache, options) catch |err| {
                if (@import("decompress.zig").isResourceError(err)) return err;
                return allocator.alloc(OutlineItem, 0);
            };
            break :blk switch (obj) {
                .dict => |d| d,
                else => return allocator.alloc(OutlineItem, 0),
            };
        },
        else => return allocator.alloc(OutlineItem, 0),
    };

    // Get /First child
    const first_obj = outlines_dict.get("First") orelse return allocator.alloc(OutlineItem, 0);

    var items: std.ArrayList(OutlineItem) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(@constCast(item.title));
        }
        items.deinit(allocator);
    }

    var visited = Visited.init(allocator);
    defer visited.deinit();
    try walkOutlineChain(allocator, arena, data, xref, cache, pages, first_obj, 0, &items, options, &visited);

    return items.toOwnedSlice(allocator);
}

fn walkOutlineChain(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
    first_obj: Object,
    level: u32,
    items: *std.ArrayList(OutlineItem),
    options: pagetree.BuildOptions,
    visited: *Visited,
) !void {
    // Bound stack depth independently of total items, including direct dicts.
    if (level >= max_outline_depth) return;
    var current_obj = first_obj;

    while (items.items.len < max_outline_items) {
        const item_dict = switch (current_obj) {
            .dict => |d| d,
            .reference => |r| blk: {
                // Share identity across child and sibling walks. Returning from
                // a cyclic child still lets its parent visit a later sibling.
                const entry = try visited.getOrPut(r);
                if (entry.found_existing) return;
                const obj = pagetree.resolveRefWithOptions(arena, data, xref, r, cache, options) catch |err| {
                    if (@import("decompress.zig").isResourceError(err)) return err;
                    return;
                };
                break :blk switch (obj) {
                    .dict => |d| d,
                    else => return,
                };
            },
            else => return,
        };

        // Extract /Title (may be UTF-16BE encoded)
        const title_raw = item_dict.getString("Title") orelse "";
        const title = root.decodePdfString(allocator, title_raw) catch |err| blk: {
            if (@import("decompress.zig").isResourceError(err)) return err;
            break :blk try allocator.dupe(u8, title_raw);
        };
        var title_owned = true;
        errdefer if (title_owned) allocator.free(title);

        // Resolve destination page
        var dest_page: ?usize = null;

        // Try /Dest first
        if (item_dict.get("Dest")) |dest_obj| {
            dest_page = try resolveDestToPage(arena, data, xref, cache, pages, dest_obj, options);
        }

        // Try /A (action) if no /Dest
        if (dest_page == null) {
            if (item_dict.get("A")) |action_obj| {
                const action = switch (action_obj) {
                    .dict => |d| d,
                    .reference => |r| blk: {
                        const obj = pagetree.resolveRefWithOptions(arena, data, xref, r, cache, options) catch |err| inner: {
                            if (@import("decompress.zig").isResourceError(err)) return err;
                            break :inner null;
                        };
                        break :blk if (obj) |o| switch (o) {
                            .dict => |d| d,
                            else => null,
                        } else null;
                    },
                    else => null,
                };
                if (action) |act| {
                    const action_type = act.getName("S");
                    if (action_type) |s| {
                        if (std.mem.eql(u8, s, "GoTo")) {
                            if (act.get("D")) |d_obj| {
                                dest_page = try resolveDestToPage(arena, data, xref, cache, pages, d_obj, options);
                            }
                        }
                    }
                }
            }
        }

        try items.append(allocator, .{
            .title = title,
            .page = dest_page,
            .level = level,
        });
        title_owned = false;

        // Recurse into children
        if (item_dict.get("First")) |child_first| {
            try walkOutlineChain(allocator, arena, data, xref, cache, pages, child_first, level + 1, items, options, visited);
        }

        // Follow /Next sibling
        const next_obj = item_dict.get("Next") orelse return;
        current_obj = next_obj;
    }
}

fn resolveDestToPage(
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    pages: []const Page,
    dest_obj: Object,
    options: pagetree.BuildOptions,
) !?usize {
    const arr = switch (dest_obj) {
        .array => |a| a,
        .reference => |r| blk: {
            const obj = pagetree.resolveRefWithOptions(arena, data, xref, r, cache, options) catch |err| {
                if (@import("decompress.zig").isResourceError(err)) return err;
                return null;
            };
            break :blk switch (obj) {
                .array => |a| a,
                else => return null,
            };
        },
        else => return null,
    };
    if (arr.len == 0) return null;

    // First element should be a page reference
    const page_ref = switch (arr[0]) {
        .reference => |r| r,
        else => return null,
    };

    for (pages, 0..) |p, idx| {
        if (p.ref.eql(page_ref)) return idx;
    }
    return null;
}

pub fn freeOutline(allocator: std.mem.Allocator, items: []OutlineItem) void {
    for (items) |item| {
        allocator.free(@constCast(item.title));
    }
    allocator.free(items);
}

fn cyclicOutlineProbe(allocator: std.mem.Allocator) !void {
    var table = XRefTable.init(allocator);
    defer table.deinit();
    var cache = std.AutoHashMap(u32, Object).init(allocator);
    defer cache.deinit();
    var first = [_]Object.Dict.Entry{
        .{ .key = "Title", .value = .{ .string = "First" } },
        .{ .key = "First", .value = .{ .reference = .{ .num = 2, .gen = 0 } } },
        .{ .key = "Next", .value = .{ .reference = .{ .num = 3, .gen = 0 } } },
    };
    var child = [_]Object.Dict.Entry{
        .{ .key = "Title", .value = .{ .string = "Child" } },
        .{ .key = "First", .value = .{ .reference = .{ .num = 1, .gen = 0 } } },
    };
    var sibling = [_]Object.Dict.Entry{
        .{ .key = "Title", .value = .{ .string = "Sibling" } },
        .{ .key = "First", .value = .{ .reference = .{ .num = 3, .gen = 0 } } },
        .{ .key = "Next", .value = .{ .reference = .{ .num = 3, .gen = 0 } } },
    };
    try cache.put(1, .{ .dict = .{ .entries = &first } });
    try cache.put(2, .{ .dict = .{ .entries = &child } });
    try cache.put(3, .{ .dict = .{ .entries = &sibling } });
    var visited = Visited.init(allocator);
    defer visited.deinit();
    var items: std.ArrayList(OutlineItem) = .empty;
    defer {
        for (items.items) |item| allocator.free(item.title);
        items.deinit(allocator);
    }
    try walkOutlineChain(allocator, allocator, "", &table, &cache, &.{}, .{ .reference = .{ .num = 1, .gen = 0 } }, 0, &items, .{}, &visited);
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    for (items.items, [_][]const u8{ "First", "Child", "Sibling" }, [_]u32{ 0, 1, 0 }) |item, title, level| {
        try std.testing.expectEqualStrings(title, item.title);
        try std.testing.expectEqual(level, item.level);
    }
}

test "outline child and sibling cycles preserve later siblings and allocation cleanup" {
    try cyclicOutlineProbe(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cyclicOutlineProbe, .{});
}

test "outline depth is bounded independently of item count and sibling traversal" {
    const allocator = std.testing.allocator;
    var table = XRefTable.init(allocator);
    defer table.deinit();
    var cache = std.AutoHashMap(u32, Object).init(allocator);
    defer cache.deinit();
    const depth = max_outline_depth + 2;
    var nodes: [depth][3]Object.Dict.Entry = undefined;
    for (&nodes, 0..) |*entries, index| {
        entries.* = .{
            .{ .key = "Title", .value = .{ .string = "Nested" } },
            .{ .key = "First", .value = .{ .reference = .{ .num = @intCast(index + 2), .gen = 0 } } },
            .{ .key = "Next", .value = if (index == 0) .{ .reference = .{ .num = 1000, .gen = 0 } } else .{ .null = {} } },
        };
        try cache.put(@intCast(index + 1), .{ .dict = .{ .entries = entries } });
    }
    var sibling = [_]Object.Dict.Entry{.{ .key = "Title", .value = .{ .string = "Later sibling" } }};
    try cache.put(1000, .{ .dict = .{ .entries = &sibling } });
    var visited = Visited.init(allocator);
    defer visited.deinit();
    var items: std.ArrayList(OutlineItem) = .empty;
    defer {
        for (items.items) |item| allocator.free(item.title);
        items.deinit(allocator);
    }
    try walkOutlineChain(allocator, allocator, "", &table, &cache, &.{}, .{ .reference = .{ .num = 1, .gen = 0 } }, 0, &items, .{}, &visited);
    try std.testing.expectEqual(@as(usize, max_outline_depth + 1), items.items.len);
    for (items.items[0..max_outline_depth], 0..) |item, index| try std.testing.expectEqual(@as(u32, @intCast(index)), item.level);
    try std.testing.expectEqualStrings("Later sibling", items.items[max_outline_depth].title);
    try std.testing.expectEqual(@as(u32, 0), items.items[max_outline_depth].level);
}
