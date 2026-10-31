//! PDF Page Tree Parser
//!
//! PDFs store pages in a tree structure for efficiency with large documents.
//! Structure: Catalog -> Pages (root) -> [Pages | Page] -> ...
//!
//! We flatten this to a simple array for O(1) page access.

const std = @import("std");
const parser = @import("parser.zig");
const xref_mod = @import("xref.zig");
const encryption = @import("encryption.zig");
const structural = @import("structural.zig");
const decompress = @import("decompress.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const XRefTable = xref_mod.XRefTable;
const MAX_PAGE_TREE_DEPTH: usize = 256;

pub const Page = struct {
    /// Object reference for this page
    ref: ObjRef,
    /// Page dictionary
    dict: Object.Dict,
    /// Inherited MediaBox [x0, y0, x1, y1]
    media_box: [4]f64,
    /// Inherited CropBox (defaults to MediaBox)
    crop_box: [4]f64,
    /// Rotation in degrees (0, 90, 180, 270)
    rotation: i32,
    /// Leaf-only physical scale per PDF user-space unit; NaN if specified but invalid.
    user_unit: f64 = 1,
    /// Inherited Resources dictionary
    resources: ?Object.Dict,
};

pub const PageTreeError = error{
    CatalogNotFound,
    PagesNotFound,
    InvalidPageTree,
    InvalidPageObject,
    CircularReference,
    OutOfMemory,
    OutputTooLarge,
};

pub const BuildOptions = struct {
    security: ?*const encryption.SecurityHandler = null,
    diagnostics: ?*std.ArrayList(structural.Diagnostic) = null,
    diagnostic_allocator: ?std.mem.Allocator = null,
    recover: bool = true,
    decompress_options: decompress.Options = .{},
    /// Propagated through object-stream resolution to bound parameter cycles.
    decode_param_depth: u8 = 0,
};

/// Resolve object reference using XRef table
pub fn resolveRef(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
) !Object {
    return resolveRefWithOptions(allocator, data, xref, ref, resolved_cache, .{});
}

/// Resolve object reference using XRef table, optionally decrypting the
/// resulting indirect object with the document security handler.
pub fn resolveRefWithSecurity(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
    security: ?*const encryption.SecurityHandler,
) !Object {
    return resolveRefWithOptions(allocator, data, xref, ref, resolved_cache, .{ .security = security });
}

pub fn resolveRefWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    ref: ObjRef,
    resolved_cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) !Object {
    // Check cache first
    if (resolved_cache.get(ref.num)) |cached| {
        return cached;
    }

    const entry = xref.get(ref.num) orelse {
        emit(allocator, options, .{
            .code = .missing_object,
            .severity = .warning,
            .stage = .object,
            .object_ref = .{ .num = ref.num, .gen = ref.gen },
            .action = .skipped,
            .message = "Object reference is missing from xref table",
        });
        return Object{ .null = {} };
    };

    switch (entry.entry_type) {
        .free => return Object{ .null = {} },
        .in_use => {
            if (entry.offset >= data.len) {
                emit(allocator, options, .{
                    .code = .missing_object,
                    .severity = .warning,
                    .stage = .object,
                    .offset = entry.offset,
                    .object_ref = .{ .num = ref.num, .gen = ref.gen },
                    .action = .skipped,
                    .message = "Object offset points beyond end of file",
                });
                return Object{ .null = {} };
            }

            var p = parser.Parser.initAtWithOptions(allocator, data, @intCast(entry.offset), .{
                .recover_stream_lengths = options.recover,
                .diagnostics = options.diagnostics,
                .diagnostic_allocator = options.diagnostic_allocator,
            });
            const indirect = p.parseIndirectObject() catch |err| {
                if (err == error.OutOfMemory) return err;
                emit(allocator, options, .{
                    .code = .missing_object,
                    .severity = .warning,
                    .stage = .object,
                    .offset = entry.offset,
                    .object_ref = .{ .num = ref.num, .gen = ref.gen },
                    .action = .skipped,
                    .message = "Failed to parse indirect object",
                });
                return Object{ .null = {} };
            };
            const object = if (options.security) |handler|
                handler.decryptObject(allocator, .{ .num = indirect.num, .gen = indirect.gen }, indirect.obj) catch |err| blk: {
                    if (err == error.OutOfMemory) return err;
                    break :blk Object{ .null = {} };
                }
            else
                indirect.obj;

            const resolved = try resolveStreamDecodeParameters(allocator, data, xref, object, resolved_cache, options);
            try resolved_cache.put(ref.num, resolved);
            return resolved;
        },
        .compressed => {
            // Object is inside an object stream
            return resolveCompressedObject(allocator, data, xref, entry, resolved_cache, options);
        },
    }
}

fn isLzwFilter(filter: Object) bool {
    return filter == .name and (std.mem.eql(u8, filter.name, "LZWDecode") or std.mem.eql(u8, filter.name, "LZW"));
}

fn resolveDecodeParameter(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    cache: *std.AutoHashMap(u32, Object),
    object: Object,
    options: BuildOptions,
    depth: *u8,
) anyerror!Object {
    var value = object;
    while (value == .reference) {
        if (depth.* >= 16) return error.InvalidFilterParams;
        depth.* += 1;
        var nested = options;
        nested.decode_param_depth = depth.*;
        value = try resolveRefWithOptions(allocator, data, xref, value.reference, cache, nested);
    }
    return value;
}

fn resolveEarlyChange(allocator: std.mem.Allocator, data: []const u8, xref: *const XRefTable, cache: *std.AutoHashMap(u32, Object), params: Object, options: BuildOptions, depth: *u8) anyerror!void {
    if (params != .dict) return;
    for (params.dict.entries) |*entry| {
        if (std.mem.eql(u8, entry.key, "EarlyChange")) {
            entry.value = try resolveDecodeParameter(allocator, data, xref, cache, entry.value, options, depth);
            return;
        }
    }
}

// Resolve LZW policy at the document boundary, where xref/security/cache state
// exists. Parsed metadata belongs to the parse allocator; normalized values
// retain that lifetime. Never cache a stream before normalization succeeds.
fn resolveStreamDecodeParameters(allocator: std.mem.Allocator, data: []const u8, xref: *const XRefTable, object: Object, cache: *std.AutoHashMap(u32, Object), options: BuildOptions) anyerror!Object {
    if (object != .stream) return object;
    const filter = object.stream.dict.get("Filter") orelse return object;
    var has_lzw = isLzwFilter(filter);
    if (filter == .array) {
        for (filter.array[0..@min(filter.array.len, 16)]) |item| has_lzw = has_lzw or isLzwFilter(item);
    }
    if (!has_lzw) return object;
    for (object.stream.dict.entries) |*entry| {
        if (!std.mem.eql(u8, entry.key, "DecodeParms")) continue;
        var depth = options.decode_param_depth;
        const params = try resolveDecodeParameter(allocator, data, xref, cache, entry.value, options, &depth);
        if (params == .array and filter == .array) {
            for (filter.array[0..@min(filter.array.len, 16)], 0..) |item, index| {
                if (!isLzwFilter(item) or index >= params.array.len) continue;
                var item_depth = depth;
                const value = try resolveDecodeParameter(allocator, data, xref, cache, params.array[index], options, &item_depth);
                try resolveEarlyChange(allocator, data, xref, cache, value, options, &item_depth);
                params.array[index] = value;
            }
        } else {
            try resolveEarlyChange(allocator, data, xref, cache, params, options, &depth);
        }
        entry.value = params;
        return object;
    }
    return object;
}

fn resolveCompressedObject(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    entry: xref_mod.XRefEntry,
    resolved_cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) !Object {
    const objstm_num = std.math.cast(u32, entry.offset) orelse {
        emit(allocator, options, objectStreamDiagnostic(0, null, "Object stream number exceeds u32"));
        return Object{ .null = {} };
    };
    const index = entry.gen_or_index;

    // Get the object stream
    const objstm_entry = xref.get(objstm_num) orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, null, "Object stream reference is missing"));
        return Object{ .null = {} };
    };
    if (objstm_entry.entry_type != .in_use) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, null, "Object stream entry is not an in-use object"));
        return Object{ .null = {} };
    }
    if (objstm_entry.offset >= data.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream offset points beyond EOF"));
        return Object{ .null = {} };
    }

    var p = parser.Parser.initAtWithOptions(allocator, data, @intCast(objstm_entry.offset), .{
        .recover_stream_lengths = options.recover,
        .diagnostics = options.diagnostics,
        .diagnostic_allocator = options.diagnostic_allocator,
    });
    const indirect = p.parseIndirectObject() catch |err| {
        if (err == error.OutOfMemory) return err;
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Failed to parse object stream object"));
        return Object{ .null = {} };
    };

    const decrypted_objstm = if (options.security) |handler|
        handler.decryptObject(allocator, .{ .num = indirect.num, .gen = indirect.gen }, indirect.obj) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            break :blk Object{ .null = {} };
        }
    else
        indirect.obj;
    const objstm_obj = try resolveStreamDecodeParameters(allocator, data, xref, decrypted_objstm, resolved_cache, options);

    const stream = switch (objstm_obj) {
        .stream => |s| s,
        else => {
            emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream reference did not resolve to a stream"));
            return Object{ .null = {} };
        },
    };

    // Decompress stream (arena-allocated, no need to free)
    const decoded = decompress.decompressStreamWithOptions(
        allocator,
        stream.data,
        stream.dict.get("Filter"),
        stream.dict.get("DecodeParms"),
        options.decompress_options,
    ) catch |err| {
        if (decompress.isResourceError(err)) return err;
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Failed to decompress object stream"));
        return Object{ .null = {} };
    };

    // Parse object stream header
    const n = stream.dict.getInt("N") orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream is missing /N"));
        return Object{ .null = {} };
    };
    const first = stream.dict.getInt("First") orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream is missing /First"));
        return Object{ .null = {} };
    };

    if (n <= 0 or first < 0 or first >= decoded.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream has invalid /N or /First"));
        return Object{ .null = {} };
    }

    // Parse offset pairs from header
    var header_parser = parser.Parser.init(allocator, decoded);
    var offsets: std.ArrayList(struct { num: u32, offset: u64 }) = .empty;
    defer offsets.deinit(allocator);

    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const obj = header_parser.parseObject() catch |err| {
            if (err == error.OutOfMemory) return err;
            emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream header ended early"));
            break;
        };
        const num: u32 = switch (obj) {
            .integer => |int| std.math.cast(u32, int) orelse {
                emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream header contains an invalid object number"));
                break;
            },
            else => break,
        };

        const offset_obj = header_parser.parseObject() catch |err| {
            if (err == error.OutOfMemory) return err;
            emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream header offset ended early"));
            break;
        };
        const offset: u64 = switch (offset_obj) {
            .integer => |int| std.math.cast(u64, int) orelse {
                emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream header contains an invalid object offset"));
                break;
            },
            else => break,
        };

        try offsets.append(allocator, .{ .num = num, .offset = offset });
    }

    // Find our object
    if (index >= offsets.items.len) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream target index is out of range"));
        return Object{ .null = {} };
    }

    const obj_offset: usize = @intCast(first);
    const rel_offset = offsets.items[index].offset;
    const rel_offset_usize = std.math.cast(usize, rel_offset) orelse {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream target offset exceeds addressable memory"));
        return Object{ .null = {} };
    };

    if (obj_offset >= decoded.len or rel_offset_usize >= decoded.len - obj_offset) {
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Object stream target offset is out of range"));
        return Object{ .null = {} };
    }

    var obj_parser = parser.Parser.initAt(allocator, decoded, obj_offset + rel_offset_usize);
    const result = obj_parser.parseObject() catch |err| {
        if (err == error.OutOfMemory) return err;
        emit(allocator, options, objectStreamDiagnostic(objstm_num, objstm_entry.offset, "Failed to parse compressed object"));
        return Object{ .null = {} };
    };

    try resolved_cache.put(offsets.items[index].num, result);
    return result;
}

/// Build page array from PDF document
pub fn buildPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
) PageTreeError![]Page {
    return buildPageTreeWithSecurity(allocator, data, xref, null);
}

pub fn buildPageTreeWithSecurity(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    security: ?*const encryption.SecurityHandler,
) PageTreeError![]Page {
    return buildPageTreeWithOptions(allocator, data, xref, .{ .security = security });
}

pub fn buildPageTreeWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    options: BuildOptions,
) PageTreeError![]Page {
    var resolved_cache = std.AutoHashMap(u32, Object).init(allocator);
    defer resolved_cache.deinit();

    // Get Root from trailer
    const root_ref = switch (xref.trailer.get("Root") orelse return PageTreeError.CatalogNotFound) {
        .reference => |r| r,
        else => return PageTreeError.CatalogNotFound,
    };

    // Resolve catalog
    const catalog = resolveRefWithOptions(allocator, data, xref, root_ref, &resolved_cache, options) catch |err| {
        if (err == error.OutputTooLarge) return error.OutputTooLarge;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return PageTreeError.CatalogNotFound;
    };

    const catalog_dict = switch (catalog) {
        .dict => |d| d,
        else => return PageTreeError.CatalogNotFound,
    };

    // Get Pages reference
    const pages_ref = switch (catalog_dict.get("Pages") orelse return PageTreeError.PagesNotFound) {
        .reference => |r| r,
        else => return PageTreeError.PagesNotFound,
    };

    // Build page list
    var pages: std.ArrayList(Page) = .empty;
    errdefer pages.deinit(allocator);

    // Track visited nodes to detect cycles
    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();

    // Inherited attributes
    const default_mediabox = [4]f64{ 0, 0, 612, 792 }; // Letter size default

    try walkPageTree(
        allocator,
        data,
        xref,
        options,
        &resolved_cache,
        &visited,
        &pages,
        pages_ref,
        0,
        default_mediabox,
        null, // crop_box
        0, // rotation
        null, // resources
    );

    return pages.toOwnedSlice(allocator);
}

fn walkPageTree(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    options: BuildOptions,
    cache: *std.AutoHashMap(u32, Object),
    visited: *std.AutoHashMap(u32, void),
    pages: *std.ArrayList(Page),
    node_ref: ObjRef,
    depth: usize,
    inherited_mediabox: [4]f64,
    inherited_cropbox: ?[4]f64,
    inherited_rotation: i32,
    inherited_resources: ?Object.Dict,
) PageTreeError!void {
    if (!pageTreeDepthAllowed(depth)) return PageTreeError.InvalidPageTree;

    // Cycle detection
    if (visited.contains(node_ref.num)) {
        emit(allocator, options, .{
            .code = .page_tree_circular_reference,
            .severity = .warning,
            .stage = .page_tree,
            .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
            .action = if (options.recover) .skipped else .failed,
            .message = "Circular page-tree reference",
        });
        return PageTreeError.CircularReference;
    }
    visited.put(node_ref.num, {}) catch return PageTreeError.OutOfMemory;
    defer _ = visited.remove(node_ref.num);

    // Resolve node
    const node = resolveRefWithOptions(allocator, data, xref, node_ref, cache, options) catch |err| {
        if (err == error.OutputTooLarge) return error.OutputTooLarge;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return PageTreeError.InvalidPageTree;
    };

    const dict = switch (node) {
        .dict => |d| d,
        else => return PageTreeError.InvalidPageTree,
    };

    // Check Type — some generators omit /Type; infer from structure
    const type_name = dict.getName("Type") orelse blk: {
        emit(allocator, options, .{
            .code = .page_tree_missing_type,
            .severity = .warning,
            .stage = .page_tree,
            .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
            .action = .recovered,
            .message = "Page-tree node is missing /Type; inferred from structure",
        });
        break :blk if (dict.get("Kids") != null) "Pages" else "Page";
    };

    // Get inherited attributes at this level
    const mediabox = extractBox(dict, "MediaBox") orelse blk: {
        if (dict.get("MediaBox") != null) {
            emit(allocator, options, .{
                .code = .page_tree_missing_box,
                .severity = .warning,
                .stage = .page_tree,
                .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                .action = .recovered,
                .message = "Invalid MediaBox; using inherited/default box",
            });
        }
        break :blk inherited_mediabox;
    };
    const cropbox = extractBox(dict, "CropBox") orelse inherited_cropbox;
    const rotation_value = dict.getInt("Rotate") orelse inherited_rotation;
    const rotation = std.math.cast(i32, rotation_value) orelse inherited_rotation;

    var resources = inherited_resources;
    if (dict.get("Resources")) |res_obj| {
        const resolved = switch (res_obj) {
            .reference => |r| resolveRefWithOptions(allocator, data, xref, r, cache, options) catch |err| blk: {
                if (err == error.OutputTooLarge) return error.OutputTooLarge;
                if (err == error.OutOfMemory) return error.OutOfMemory;
                break :blk res_obj;
            },
            else => res_obj,
        };
        if (resolved == .dict) {
            resources = resolved.dict;
        }
    }

    if (std.mem.eql(u8, type_name, "Pages")) {
        // Intermediate node - recurse into Kids
        const kids = blk: {
            const kids_obj = dict.get("Kids") orelse break :blk null;
            const resolved = switch (kids_obj) {
                .reference => |ref| resolveRefWithOptions(allocator, data, xref, ref, cache, options) catch |err| {
                    if (err == error.OutputTooLarge) return error.OutputTooLarge;
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    break :blk null;
                },
                else => kids_obj,
            };
            break :blk switch (resolved) {
                .array => |items| items,
                else => null,
            };
        } orelse {
            emit(allocator, options, .{
                .code = .page_tree_missing_kids,
                .severity = if (options.recover) .warning else .error_,
                .stage = .page_tree,
                .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                .action = if (options.recover) .skipped else .failed,
                .message = "Pages node is missing /Kids",
            });
            if (options.recover) return;
            return PageTreeError.InvalidPageTree;
        };
        if (dict.getInt("Count")) |declared_count| {
            if (declared_count != @as(i64, @intCast(kids.len))) {
                emit(allocator, options, .{
                    .code = .page_tree_wrong_count,
                    .severity = .warning,
                    .stage = .page_tree,
                    .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                    .action = .recovered,
                    .message = "Pages node /Count does not match immediate /Kids count",
                });
            }
        }

        for (kids) |kid| {
            const kid_ref = switch (kid) {
                .reference => |r| r,
                else => {
                    emit(allocator, options, .{
                        .code = .page_tree_bad_kid,
                        .severity = .warning,
                        .stage = .page_tree,
                        .object_ref = .{ .num = node_ref.num, .gen = node_ref.gen },
                        .action = .skipped,
                        .message = "Skipped non-reference page-tree kid",
                    });
                    continue;
                },
            };

            walkPageTree(
                allocator,
                data,
                xref,
                options,
                cache,
                visited,
                pages,
                kid_ref,
                depth + 1,
                mediabox,
                cropbox,
                rotation,
                resources,
            ) catch |err| {
                if (decompress.isResourceError(err)) return err;
                emit(allocator, options, .{
                    .code = .page_tree_recovered_child,
                    .severity = if (options.recover) .warning else .error_,
                    .stage = .page_tree,
                    .object_ref = .{ .num = kid_ref.num, .gen = kid_ref.gen },
                    .action = if (options.recover) .skipped else .failed,
                    .message = "Skipped unrecoverable page-tree child",
                });
                if (!options.recover) return err;
            };
        }
    } else if (std.mem.eql(u8, type_name, "Page")) {
        // Leaf node - add to pages list
        const user_unit = try leafUserUnit(allocator, data, xref, dict, cache, options);
        pages.append(allocator, .{
            .ref = node_ref,
            .dict = dict,
            .media_box = mediabox,
            .crop_box = cropbox orelse mediabox,
            .rotation = rotation,
            .user_unit = user_unit,
            .resources = resources,
        }) catch return PageTreeError.OutOfMemory;
    }
    // Ignore unknown types
}

fn leafUserUnit(
    allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    dict: Object.Dict,
    cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) PageTreeError!f64 {
    var value = dict.get("UserUnit") orelse return 1;
    // UserUnit is not inherited. Bound indirect chains, including cyclic refs,
    // and retain invalid specified values as unavailable geometry, not unit 1.
    var remaining: usize = 16;
    while (value == .reference) {
        if (remaining == 0) return std.math.nan(f64);
        remaining -= 1;
        value = resolveRefWithOptions(allocator, data, xref, value.reference, cache, options) catch |err| {
            if (err == error.OutputTooLarge) return error.OutputTooLarge;
            return error.OutOfMemory;
        };
    }
    const number: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .real => |real| real,
        else => return std.math.nan(f64),
    };
    if (!std.math.isFinite(number) or number <= 0 or number > 75000) return std.math.nan(f64);
    return number;
}

fn emit(allocator: std.mem.Allocator, options: BuildOptions, diagnostic: structural.Diagnostic) void {
    structural.appendDiagnostic(options.diagnostic_allocator orelse allocator, options.diagnostics, diagnostic);
}

fn pageTreeDepthAllowed(depth: usize) bool {
    return depth < MAX_PAGE_TREE_DEPTH;
}

fn objectStreamDiagnostic(objstm_num: u32, offset: ?u64, message: []const u8) structural.Diagnostic {
    return .{
        .code = .malformed_object_stream,
        .severity = .warning,
        .stage = .object_stream,
        .offset = offset,
        .object_ref = .{ .num = objstm_num, .gen = 0 },
        .action = .skipped,
        .message = message,
    };
}

fn extractBox(dict: Object.Dict, key: []const u8) ?[4]f64 {
    const array = dict.getArray(key) orelse return null;
    if (array.len != 4) return null;

    var box: [4]f64 = undefined;
    for (array, 0..) |elem, i| {
        box[i] = switch (elem) {
            .integer => |n| @floatFromInt(n),
            .real => |n| n,
            else => return null,
        };
    }
    return box;
}

/// Get page content stream(s)
pub fn getPageContents(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
) ![]const u8 {
    return getPageContentsWithSecurity(parse_allocator, scratch_allocator, data, xref, page, cache, null);
}

pub fn getPageContentsWithSecurity(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
    security: ?*const encryption.SecurityHandler,
) ![]const u8 {
    return getPageContentsWithOptions(parse_allocator, scratch_allocator, data, xref, page, cache, .{ .security = security });
}

pub fn getPageContentsWithOptions(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    page: Page,
    cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) ![]const u8 {
    const contents = page.dict.get("Contents") orelse return &[_]u8{};

    return getStreamData(parse_allocator, scratch_allocator, data, xref, contents, cache, options);
}

fn getStreamData(
    parse_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    data: []const u8,
    xref: *const XRefTable,
    obj: Object,
    cache: *std.AutoHashMap(u32, Object),
    options: BuildOptions,
) ![]const u8 {
    switch (obj) {
        .reference => |ref| {
            const resolved = try resolveRefWithOptions(parse_allocator, data, xref, ref, cache, options);
            return getStreamData(parse_allocator, scratch_allocator, data, xref, resolved, cache, options);
        },
        .stream => |s| {
            return decompress.decompressStreamWithOptions(
                scratch_allocator,
                s.data,
                s.dict.get("Filter"),
                s.dict.get("DecodeParms"),
                options.decompress_options,
            ) catch |err| {
                if (decompress.isResourceError(err)) return err;
                return s.data;
            };
        },
        .array => |arr| {
            // Concatenate multiple content streams
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(scratch_allocator);

            for (arr) |item| {
                const stream_data = try getStreamData(parse_allocator, scratch_allocator, data, xref, item, cache, options);
                // stream_data is arena-allocated, no need to free
                try result.appendSlice(scratch_allocator, stream_data);
                try result.append(scratch_allocator, '\n'); // Separate streams
            }

            return result.toOwnedSlice(scratch_allocator);
        },
        else => return &[_]u8{},
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "LZW decode parameters resolve indirect dictionaries arrays and integers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var xref = XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    var cache = std.AutoHashMap(u32, Object).init(std.testing.allocator);
    defer cache.deinit();
    var params_entries = [_]Object.Dict.Entry{.{ .key = "EarlyChange", .value = .{ .reference = .{ .num = 7, .gen = 0 } } }};
    var params_array = [_]Object{ .null, .{ .reference = .{ .num = 6, .gen = 0 } } };
    try cache.put(6, .{ .dict = .{ .entries = &params_entries } });
    try cache.put(7, .{ .integer = 0 });
    try cache.put(8, .{ .array = &params_array });
    var filters = [_]Object{ .{ .name = "ASCIIHexDecode" }, .{ .name = "LZW" } };
    var entries = [_]Object.Dict.Entry{
        .{ .key = "Filter", .value = .{ .array = &filters } },
        .{ .key = "DecodeParms", .value = .{ .reference = .{ .num = 8, .gen = 0 } } },
    };
    const stream: Object = .{ .stream = .{ .dict = .{ .entries = &entries }, .data = "" } };
    const resolved = try resolveStreamDecodeParameters(arena.allocator(), "", &xref, stream, &cache, .{});
    const params = resolved.stream.dict.getArray("DecodeParms").?;
    try std.testing.expect(params[0] == .null);
    try std.testing.expectEqual(@as(?i64, 0), params[1].dict.getInt("EarlyChange"));
}

test "LZW decode parameter cycles stop before publishing streams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var xref = XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    var cache = std.AutoHashMap(u32, Object).init(std.testing.allocator);
    defer cache.deinit();
    try cache.put(6, .{ .reference = .{ .num = 7, .gen = 0 } });
    try cache.put(7, .{ .reference = .{ .num = 6, .gen = 0 } });
    var entries = [_]Object.Dict.Entry{
        .{ .key = "Filter", .value = .{ .name = "LZWDecode" } },
        .{ .key = "DecodeParms", .value = .{ .reference = .{ .num = 6, .gen = 0 } } },
    };
    const stream: Object = .{ .stream = .{ .dict = .{ .entries = &entries }, .data = "" } };
    try std.testing.expectError(error.InvalidFilterParams, resolveStreamDecodeParameters(arena.allocator(), "", &xref, stream, &cache, .{}));
    try std.testing.expect(entries[1].value == .reference);

    // The integer needed to decode ObjStm 2 is stored inside that same stream.
    // Recursive object-stream resolution must inherit the parameter depth.
    const data = "2 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Filter /LZWDecode /DecodeParms << /EarlyChange 3 0 R >> /Length 6 >>\nstream\n3 0 0 \nendstream\nendobj\n";
    try xref.entries.put(2, .{ .offset = 0, .gen_or_index = 0, .entry_type = .in_use });
    try xref.entries.put(3, .{ .offset = 2, .gen_or_index = 0, .entry_type = .compressed });
    try std.testing.expectError(error.InvalidFilterParams, resolveRefWithOptions(arena.allocator(), data, &xref, .{ .num = 3, .gen = 0 }, &cache, .{}));
    try std.testing.expect(!cache.contains(2));
    try std.testing.expect(!cache.contains(3));
}

test "LZW decode parameter resolution preserves compressed-object byte limits" {
    const data = "2 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Length 6 >>\nstream\n3 0 0 \nendstream\nendobj\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var xref = XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    try xref.entries.put(2, .{ .offset = 0, .gen_or_index = 0, .entry_type = .in_use });
    try xref.entries.put(3, .{ .offset = 2, .gen_or_index = 0, .entry_type = .compressed });
    var cache = std.AutoHashMap(u32, Object).init(std.testing.allocator);
    defer cache.deinit();
    var params = [_]Object.Dict.Entry{.{ .key = "EarlyChange", .value = .{ .reference = .{ .num = 3, .gen = 0 } } }};
    var entries = [_]Object.Dict.Entry{
        .{ .key = "Filter", .value = .{ .name = "LZWDecode" } },
        .{ .key = "DecodeParms", .value = .{ .dict = .{ .entries = &params } } },
    };
    const stream: Object = .{ .stream = .{ .dict = .{ .entries = &entries }, .data = "" } };
    try std.testing.expectError(error.OutputTooLarge, resolveStreamDecodeParameters(arena.allocator(), data, &xref, stream, &cache, .{ .decompress_options = .{ .max_output_bytes = 5 } }));
    try std.testing.expect(params[0].value == .reference);
    const resolved = try resolveStreamDecodeParameters(arena.allocator(), data, &xref, stream, &cache, .{ .decompress_options = .{ .max_output_bytes = 6 } });
    try std.testing.expectEqual(@as(?i64, 0), resolved.stream.dict.getDict("DecodeParms").?.getInt("EarlyChange"));
}

test "content stream recovery preserves resource refusals and malformed fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var xref = XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    var cache = std.AutoHashMap(u32, Object).init(std.testing.allocator);
    defer cache.deinit();
    var entries = [_]Object.Dict.Entry{.{ .key = "Filter", .value = .{ .name = "RunLengthDecode" } }};
    const object: Object = .{ .stream = .{ .dict = .{ .entries = &entries }, .data = &.{ 129, 'X', 128 } } };
    for ([_]bool{ true, false }) |recover| {
        try std.testing.expectError(error.OutputTooLarge, getStreamData(arena.allocator(), arena.allocator(), "", &xref, object, &cache, .{
            .recover = recover,
            .decompress_options = .{ .max_output_bytes = 127 },
        }));
    }
    const exact = try getStreamData(arena.allocator(), arena.allocator(), "", &xref, object, &cache, .{ .decompress_options = .{ .max_output_bytes = 128 } });
    try std.testing.expectEqual(@as(usize, 128), exact.len);
    entries[0].value = .{ .name = "UnsupportedMalformedFilter" };
    const recovered = try getStreamData(arena.allocator(), arena.allocator(), "", &xref, object, &cache, .{});
    try std.testing.expectEqualSlices(u8, object.stream.data, recovered);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    entries[0].value = .{ .name = "RunLengthDecode" };
    try std.testing.expectError(error.OutOfMemory, getStreamData(arena.allocator(), failing.allocator(), "", &xref, object, &cache, .{}));
}

test "object stream cap survives null and page tree recovery" {
    const data = "2 0 obj\n<< /Type /ObjStm /N 1 /First 4 /Length 6 >>\nstream\n3 0 42\nendstream\nendobj\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var xref = XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    try xref.entries.put(2, .{ .offset = 0, .gen_or_index = 0, .entry_type = .in_use });
    try xref.entries.put(3, .{ .offset = 2, .gen_or_index = 0, .entry_type = .compressed });
    var trailer = [_]Object.Dict.Entry{.{ .key = "Root", .value = .{ .reference = .{ .num = 3, .gen = 0 } } }};
    xref.trailer = .{ .entries = &trailer };
    var cache = std.AutoHashMap(u32, Object).init(std.testing.allocator);
    defer cache.deinit();
    const options: BuildOptions = .{ .decompress_options = .{ .max_output_bytes = 5 } };
    try std.testing.expectError(error.OutputTooLarge, resolveRefWithOptions(arena.allocator(), data, &xref, .{ .num = 3, .gen = 0 }, &cache, options));
    try std.testing.expect(!cache.contains(3));
    try std.testing.expectError(error.OutputTooLarge, buildPageTreeWithOptions(arena.allocator(), data, &xref, options));
    const resolved = try resolveRefWithOptions(arena.allocator(), data, &xref, .{ .num = 3, .gen = 0 }, &cache, .{ .decompress_options = .{ .max_output_bytes = 6 } });
    try std.testing.expectEqual(@as(i64, 42), resolved.integer);
}

test "page tree traversal has a fixed recursion limit" {
    try std.testing.expect(pageTreeDepthAllowed(MAX_PAGE_TREE_DEPTH - 1));
    try std.testing.expect(!pageTreeDepthAllowed(MAX_PAGE_TREE_DEPTH));
}

test "extractBox" {
    const allocator = std.testing.allocator;

    // Create a simple dict with MediaBox
    var entries = [_]Object.Dict.Entry{
        .{
            .key = "MediaBox",
            .value = Object{
                .array = @constCast(&[_]Object{
                    .{ .integer = 0 },
                    .{ .integer = 0 },
                    .{ .integer = 612 },
                    .{ .integer = 792 },
                }),
            },
        },
    };

    const dict = Object.Dict{ .entries = &entries };

    const box = extractBox(dict, "MediaBox");
    try std.testing.expect(box != null);
    try std.testing.expectApproxEqRel(@as(f64, 0), box.?[0], 0.001);
    try std.testing.expectApproxEqRel(@as(f64, 612), box.?[2], 0.001);

    _ = allocator;
}

fn userUnitPageFixture(allocator: std.mem.Allocator, data: []const u8, object_count: u32) ![]Page {
    var xref = XRefTable.init(allocator);
    defer xref.deinit();
    var trailer_entries = [_]Object.Dict.Entry{.{ .key = "Root", .value = .{ .reference = .{ .num = 1, .gen = 0 } } }};
    xref.trailer = .{ .entries = &trailer_entries };
    var number: u32 = 1;
    while (number <= object_count) : (number += 1) {
        var needle_buffer: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buffer, "{d} 0 obj", .{number});
        const offset = std.mem.indexOf(u8, data, needle) orelse return error.MissingTestObject;
        try xref.entries.put(number, .{ .offset = offset, .gen_or_index = 0, .entry_type = .in_use });
    }
    return buildPageTreeWithOptions(allocator, data, &xref, .{ .recover = false });
}

test "UserUnit is leaf only while page boxes and rotation remain inherited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n" ++
        "2 0 obj << /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] /UserUnit 3 /MediaBox [10 20 110 220] /CropBox [25 40 100 200] /Rotate 90 >> endobj\n" ++
        "3 0 obj << /Type /Page /Parent 2 0 R /UserUnit 2 >> endobj\n" ++
        "4 0 obj << /Type /Page /Parent 2 0 R >> endobj\n";
    const pages = try userUnitPageFixture(arena.allocator(), data, 4);
    try std.testing.expectEqual(@as(usize, 2), pages.len);
    try std.testing.expectEqual(@as(f64, 2), pages[0].user_unit);
    try std.testing.expectEqual(@as(f64, 1), pages[1].user_unit);
    for (pages) |page| {
        try std.testing.expectEqualSlices(f64, &.{ 10, 20, 110, 220 }, &page.media_box);
        try std.testing.expectEqualSlices(f64, &.{ 25, 40, 100, 200 }, &page.crop_box);
        try std.testing.expectEqual(@as(i32, 90), page.rotation);
    }
}

test "UserUnit resolves indirect integer and real numbers without fabricating invalid values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data =
        "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n" ++
        "2 0 obj << /Type /Pages /Count 4 /Kids [3 0 R 4 0 R 5 0 R 6 0 R] /MediaBox [0 0 100 200] >> endobj\n" ++
        "3 0 obj << /Type /Page /Parent 2 0 R /UserUnit 7 0 R >> endobj\n" ++
        "4 0 obj << /Type /Page /Parent 2 0 R /UserUnit 8 0 R >> endobj\n" ++
        "5 0 obj << /Type /Page /Parent 2 0 R /UserUnit 0 >> endobj\n" ++
        "6 0 obj << /Type /Page /Parent 2 0 R /UserUnit /Invalid >> endobj\n" ++
        "7 0 obj 1.5 endobj\n" ++
        "8 0 obj 2 endobj\n";
    const pages = try userUnitPageFixture(arena.allocator(), data, 8);
    try std.testing.expectEqual(@as(usize, 4), pages.len);
    try std.testing.expectEqual(@as(f64, 1.5), pages[0].user_unit);
    try std.testing.expectEqual(@as(f64, 2), pages[1].user_unit);
    try std.testing.expect(std.math.isNan(pages[2].user_unit));
    try std.testing.expect(std.math.isNan(pages[3].user_unit));
}

test "UserUnit invalid numbers missing refs and cyclic refs stay unavailable" {
    var xref = XRefTable.init(std.testing.allocator);
    defer xref.deinit();
    var cache = std.AutoHashMap(u32, Object).init(std.testing.allocator);
    defer cache.deinit();
    try cache.put(7, .{ .reference = .{ .num = 8, .gen = 0 } });
    try cache.put(8, .{ .reference = .{ .num = 7, .gen = 0 } });
    var entries = [_]Object.Dict.Entry{.{ .key = "UserUnit", .value = .{ .integer = 0 } }};
    const dict: Object.Dict = .{ .entries = &entries };
    const values = [_]Object{
        .{ .integer = -1 },
        .{ .integer = 75001 },
        .{ .real = std.math.nan(f64) },
        .{ .real = std.math.inf(f64) },
        .{ .reference = .{ .num = 99, .gen = 0 } },
        .{ .reference = .{ .num = 7, .gen = 0 } },
    };
    for (values) |value| {
        entries[0].value = value;
        try std.testing.expect(std.math.isNan(try leafUserUnit(std.testing.allocator, "", &xref, dict, &cache, .{})));
    }
    entries[0].value = .{ .integer = 75000 };
    try std.testing.expectEqual(@as(f64, 75000), try leafUserUnit(std.testing.allocator, "", &xref, dict, &cache, .{}));
}
