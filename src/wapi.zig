//! WebAssembly API for zpdf
//!
//! Provides a minimal API for browser-based PDF text extraction.
//! Uses memory-based loading since file I/O is not available in WASM.

const std = @import("std");
const runtime = @import("runtime.zig");
const zpdf = @import("root.zig");
const decompress = @import("decompress.zig");
const resource_limits = @import("resource_limits.zig");

// Use WASM page allocator
var wasm_allocator = std.heap.wasm_allocator;

// Document handle storage (simple slot-based system)
const MAX_DOCUMENTS = 16;
var documents: [MAX_DOCUMENTS]?*zpdf.Document = @splat(null);

fn findFreeSlot() ?usize {
    for (documents, 0..) |doc, i| {
        if (doc == null) return i;
    }
    return null;
}

// ============================================================================
// Memory Management (for JS to allocate buffers)
// ============================================================================

export fn wasm_alloc(len: usize) ?[*]u8 {
    const slice = wasm_allocator.alloc(u8, len) catch return null;
    return slice.ptr;
}

export fn wasm_free(ptr: [*]u8, len: usize) void {
    wasm_allocator.free(ptr[0..len]);
}

// ============================================================================
// Document API
// ============================================================================

/// Open a PDF from memory buffer
/// Returns document handle (0-15) or -1 on error
/// Caller must keep the memory alive until zpdf_close.
export fn zpdf_open_memory_unsafe(data: [*]const u8, len: usize) i32 {
    const slot = findFreeSlot() orelse return -1;
    const slice = data[0..len];

    const doc = zpdf.Document.openFromMemoryUnsafe(wasm_allocator, slice, zpdf.ErrorConfig.default()) catch return -1;
    documents[slot] = doc;
    return @intCast(slot);
}

/// Backward-compatible alias of zpdf_open_memory_unsafe.
export fn zpdf_open_memory(data: [*]const u8, len: usize) i32 {
    return zpdf_open_memory_unsafe(data, len);
}

/// Close a document and free resources
export fn zpdf_close(handle: i32) void {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        doc.close();
        documents[idx] = null;
    }
}

/// Get the number of pages in the document
export fn zpdf_page_count(handle: i32) i32 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return -1;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        return @intCast(doc.pageCount());
    }
    return -1;
}

/// Extract text from a single page
/// Returns pointer to text buffer, sets out_len to buffer length
/// Caller must free with wasm_free
export fn zpdf_extract_page(handle: i32, page_num: i32, out_len: *usize) ?[*]u8 {
    out_len.* = 0;
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    if (page_num < 0) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(wasm_allocator);
        doc.extractText(@intCast(page_num), runtime.arrayListWriter(&buffer, wasm_allocator)) catch return null;

        // Handle empty buffer - toOwnedSlice returns undefined ptr for empty slice
        if (buffer.items.len == 0) {
            out_len.* = 0;
            return null;
        }

        const slice = buffer.toOwnedSlice(wasm_allocator) catch return null;
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages (sequential, single-threaded)
/// Returns pointer to text buffer, sets out_len to buffer length
/// Caller must free with wasm_free
export fn zpdf_extract_all(handle: i32, out_len: *usize) ?[*]u8 {
    out_len.* = 0;
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const slice = doc.extractAllTextStructured(wasm_allocator) catch return null;
        if (slice.len == 0) {
            out_len.* = 0;
            return null;
        }
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages in fast stream-order mode.
export fn zpdf_extract_all_fast(handle: i32, out_len: *usize) ?[*]u8 {
    out_len.* = 0;
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const slice = doc.extractAllTextFast(wasm_allocator) catch return null;
        if (slice.len == 0) {
            out_len.* = 0;
            return null;
        }
        out_len.* = slice.len;
        return slice.ptr;
    }
    return null;
}

/// Extract text from all pages as Markdown with semantic formatting
/// Returns pointer to Markdown text buffer, sets out_len to buffer length
/// Caller must free with wasm_free
export fn zpdf_extract_all_markdown(handle: i32, out_len: *usize) ?[*]u8 {
    out_len.* = 0;
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const result = doc.extractAllMarkdown(wasm_allocator) catch return null;

        // extractAllMarkdown returns an allocated slice; treat zero-length as "no data"
        if (result.len == 0) {
            out_len.* = 0;
            return null;
        }

        out_len.* = result.len;
        return result.ptr;
    }
    return null;
}

/// Get page dimensions
/// Returns 0 on success, -1 on error
export fn zpdf_get_page_info(handle: i32, page_num: i32, width: *f64, height: *f64, rotation: *i32) i32 {
    if (handle < 0 or handle >= MAX_DOCUMENTS) return -1;
    if (page_num < 0) return -1;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const page_idx: usize = @intCast(page_num);
        if (page_idx >= doc.pages.items.len) return -1;

        const page = doc.pages.items[page_idx];
        width.* = page.media_box[2] - page.media_box[0];
        height.* = page.media_box[3] - page.media_box[1];
        rotation.* = page.rotation;
        return 0;
    }
    return -1;
}

// ============================================================================
// Text with bounds API
// ============================================================================

/// Text span structure for bounds extraction
pub const TextSpan = extern struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text_ptr: [*]const u8,
    text_len: usize,
    font_size: f64,
    page_index: u32,
    source_kind: u8,
    confidence: f32,
    block_id: i32,
    line_id: i32,
    mcid: i32,
};

fn buildTextSpans(allocator: std.mem.Allocator, spans: []const zpdf.TextSpan) ![]TextSpan {
    const output = try allocator.alloc(TextSpan, spans.len);
    var copied: usize = 0;
    errdefer {
        for (output[0..copied]) |span| {
            if (span.text_len > 0) {
                const text_ptr: [*]u8 = @ptrCast(@constCast(span.text_ptr));
                allocator.free(text_ptr[0..span.text_len]);
            }
        }
        allocator.free(output);
    }

    for (spans, output) |span, *target| {
        const text_copy = try allocator.dupe(u8, span.text);
        target.* = .{
            .x0 = span.x0,
            .y0 = span.y0,
            .x1 = span.x1,
            .y1 = span.y1,
            .text_ptr = text_copy.ptr,
            .text_len = text_copy.len,
            .font_size = span.font_size,
            .page_index = span.page_index,
            .source_kind = @backingInt(span.source),
            .confidence = span.confidence,
            .block_id = optionalU32ToC(span.block_id),
            .line_id = optionalU32ToC(span.line_id),
            .mcid = span.mcid orelse -1,
        };
        copied += 1;
    }
    return output;
}

/// Extract text with bounding boxes from a page
/// Returns pointer to TextSpan array, sets out_count to number of spans
/// Caller must free with zpdf_free_bounds
export fn zpdf_extract_bounds(handle: i32, page_num: i32, out_count: *usize) ?[*]TextSpan {
    out_count.* = 0;
    if (handle < 0 or handle >= MAX_DOCUMENTS) return null;
    if (page_num < 0) return null;
    const idx: usize = @intCast(handle);

    if (documents[idx]) |doc| {
        const spans = doc.extractTextWithBounds(@intCast(page_num), wasm_allocator) catch return null;
        defer zpdf.Document.freeTextSpans(wasm_allocator, spans);
        if (spans.len == 0) {
            out_count.* = 0;
            return null;
        }

        const c_spans = buildTextSpans(wasm_allocator, spans) catch return null;

        out_count.* = spans.len;
        return c_spans.ptr;
    }
    return null;
}

fn optionalU32ToC(value: ?u32) i32 {
    return if (value) |v| @intCast(v) else -1;
}

/// Free bounds array
export fn zpdf_free_bounds(ptr: ?[*]TextSpan, count: usize) void {
    if (ptr) |p| {
        for (0..count) |i| {
            const span = p[i];
            if (span.text_len > 0) {
                const text_ptr: [*]u8 = @ptrCast(@constCast(span.text_ptr));
                wasm_allocator.free(text_ptr[0..span.text_len]);
            }
        }
        wasm_allocator.free(p[0..count]);
    }
}

// ============================================================================
// Versioned browser API. Legacy slots above remain independent and compatible.
// ============================================================================

const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    invalid_handle = 2,
    invalid_page = 3,
    capacity = 4,
    open_error = 5,
    extract_error = 6,
    resource_limit = 7,
};

const max_generation: u32 = @as(u32, std.math.maxInt(i32)) >> 4;
const VersionedDocument = struct {
    document: ?*zpdf.Document = null,
    // Zero permanently retires an exhausted slot; tokens never wrap.
    generation: u32 = 1,
};
var versioned_documents: [MAX_DOCUMENTS]VersionedDocument = @splat(.{});

fn statusCode(value: Status) i32 {
    return @backingInt(value);
}

fn validRange(address: usize, len: usize, alignment: usize) bool {
    const memory_bytes = @as(u64, @wasmMemorySize(0)) * 65536;
    const start: u64 = address;
    return address != 0 and address % alignment == 0 and start <= memory_bytes and len <= memory_bytes - start;
}

fn scalarPointer(comptime T: type, address: usize) ?*T {
    if (!validRange(address, @sizeOf(T), @alignOf(T))) return null;
    return @ptrFromInt(address);
}

fn clearScalar(comptime T: type, address: usize) ?*T {
    const ptr = scalarPointer(T, address) orelse return null;
    ptr.* = 0;
    return ptr;
}

const OutputPointers = struct { ptr: *usize, len: *usize };

fn prepareOutput(out_ptr_address: usize, out_len_address: usize) ?OutputPointers {
    // Clear either valid scalar even when its partner is invalid.
    const ptr = clearScalar(usize, out_ptr_address);
    const len = clearScalar(usize, out_len_address);
    if (out_ptr_address == out_len_address) return null;
    return .{ .ptr = ptr orelse return null, .len = len orelse return null };
}

fn rangesOverlap(a: usize, a_len: usize, b: usize, b_len: usize) bool {
    return @as(u64, a) < @as(u64, b) + b_len and @as(u64, b) < @as(u64, a) + a_len;
}

fn versionedSlot(handle: u32) ?*VersionedDocument {
    if (handle > std.math.maxInt(i32)) return null;
    const generation = handle >> 4;
    if (generation == 0) return null;
    const slot = &versioned_documents[handle & (MAX_DOCUMENTS - 1)];
    if (slot.generation != generation or slot.document == null) return null;
    return slot;
}

fn failureStatus(err: anyerror, fallback: Status) i32 {
    return statusCode(if (decompress.isResourceError(err) or err == error.OutputLimitExceeded) .resource_limit else fallback);
}

export fn pdf_parser_wasm_abi_version() u32 {
    return 2;
}

/// Input is borrowed until versioned close. Callers must own valid guest
/// allocations; range checks do not establish allocation ownership.
export fn pdf_parser_wasm_open(data_address: usize, len: usize, max_decoded_bytes: usize, out_handle_address: usize) i32 {
    const out_handle = scalarPointer(u32, out_handle_address) orelse return statusCode(.invalid_argument);
    // Reject input/output aliasing before clearing: even a failed open must
    // not overwrite bytes borrowed by another live document.
    if (rangesOverlap(data_address, len, out_handle_address, @sizeOf(u32))) return statusCode(.invalid_argument);
    out_handle.* = 0;
    if (len == 0 or max_decoded_bytes == 0 or !validRange(data_address, len, 1)) return statusCode(.invalid_argument);
    const data: [*]const u8 = @ptrFromInt(data_address);
    const header = data[0..@min(len, 1024)];
    if (std.mem.indexOf(u8, header, "%PDF-") == null) return statusCode(.open_error);

    for (&versioned_documents, 0..) |*slot, index| {
        if (slot.document != null or slot.generation == 0) continue;
        var config = zpdf.ErrorConfig.default();
        config.decompress_options.max_output_bytes = max_decoded_bytes;
        const doc = zpdf.Document.openFromMemoryUnsafe(wasm_allocator, data[0..len], config) catch |err| {
            return failureStatus(err, .open_error);
        };
        slot.document = doc;
        out_handle.* = (slot.generation << 4) | @as(u32, @intCast(index));
        return statusCode(.ok);
    }
    return statusCode(.capacity);
}

export fn pdf_parser_wasm_close(handle: u32) i32 {
    const slot = versionedSlot(handle) orelse return statusCode(.invalid_handle);
    const doc = slot.document.?;
    slot.document = null;
    slot.generation = if (slot.generation == max_generation) 0 else slot.generation + 1;
    doc.close();
    return statusCode(.ok);
}

export fn pdf_parser_wasm_page_count(handle: u32, out_count_address: usize) i32 {
    const out_count = clearScalar(u32, out_count_address) orelse return statusCode(.invalid_argument);
    const slot = versionedSlot(handle) orelse return statusCode(.invalid_handle);
    out_count.* = @intCast(slot.document.?.pageCount());
    return statusCode(.ok);
}

/// Number of recoverable parser diagnostics, not a completeness guarantee.
export fn pdf_parser_wasm_error_count(handle: u32, out_count_address: usize) i32 {
    const out_count = clearScalar(u32, out_count_address) orelse return statusCode(.invalid_argument);
    const slot = versionedSlot(handle) orelse return statusCode(.invalid_handle);
    out_count.* = @intCast(slot.document.?.errors.items.len);
    return statusCode(.ok);
}

fn extractVersioned(doc: *zpdf.Document, page_start: usize, page_end: usize, max_output_bytes: usize, out_ptr: *usize, out_len: *usize) i32 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(wasm_allocator);
    var writer = resource_limits.LimitedWriter(runtime.ArrayListWriter){
        .writer = runtime.arrayListWriter(&buffer, wasm_allocator),
        .max_bytes = max_output_bytes,
    };
    for (page_start..page_end) |page_index| {
        if (page_index > page_start) writer.writeByte('\x0c') catch |err| return failureStatus(err, .extract_error);
        // This budget bounds serialized output, not the temporary page result
        // or document caches. The module memory maximum is a separate ceiling.
        const page_text = doc.extractTextStructured(page_index, wasm_allocator) catch |err| return failureStatus(err, .extract_error);
        defer wasm_allocator.free(page_text);
        writer.writeAll(page_text) catch |err| return failureStatus(err, .extract_error);
    }
    if (buffer.items.len == 0) return statusCode(.ok);
    const owned = buffer.toOwnedSlice(wasm_allocator) catch |err| return failureStatus(err, .extract_error);
    out_ptr.* = @intFromPtr(owned.ptr);
    out_len.* = owned.len;
    return statusCode(.ok);
}

export fn pdf_parser_wasm_extract_page(handle: u32, page_num: i32, max_output_bytes: usize, out_ptr_address: usize, out_len_address: usize) i32 {
    const output = prepareOutput(out_ptr_address, out_len_address) orelse return statusCode(.invalid_argument);
    if (max_output_bytes == 0) return statusCode(.invalid_argument);
    const slot = versionedSlot(handle) orelse return statusCode(.invalid_handle);
    const doc = slot.document.?;
    if (page_num < 0 or @as(usize, @intCast(page_num)) >= doc.pageCount()) return statusCode(.invalid_page);
    const page_index: usize = @intCast(page_num);
    return extractVersioned(doc, page_index, page_index + 1, max_output_bytes, output.ptr, output.len);
}

export fn pdf_parser_wasm_extract_all(handle: u32, max_output_bytes: usize, out_ptr_address: usize, out_len_address: usize) i32 {
    const output = prepareOutput(out_ptr_address, out_len_address) orelse return statusCode(.invalid_argument);
    if (max_output_bytes == 0) return statusCode(.invalid_argument);
    const slot = versionedSlot(handle) orelse return statusCode(.invalid_handle);
    const doc = slot.document.?;
    return extractVersioned(doc, 0, doc.pageCount(), max_output_bytes, output.ptr, output.len);
}
