//! Streaming adaptive extraction.
//!
//! This module emits the public schema as JSONL while processing one page at a
//! time, so host applications can persist stage artifacts and enqueue chunk
//! embeddings before the full document has completed.

const std = @import("std");
const adaptive = @import("adaptive.zig");
const layout = @import("layout.zig");
const runtime = @import("runtime.zig");
const schema = @import("schema.zig");
const specialist_protocol = @import("specialist_protocol.zig");
const visual_assets = @import("visual_assets.zig");
const resource_limits = @import("resource_limits.zig");
const table_continuation = @import("table_continuation.zig");

pub const StreamingEventType = enum {
    document_manifest,
    page_started,
    span,
    block,
    table,
    rag_chunk,
    route_trace,
    specialist_request,
    specialist_attempt,
    specialist_response,
    specialist_result,
    page_finished,
    document_finished,
    debug_asset,
};

pub const StreamingOptions = struct {
    adaptive_options: adaptive.ExtractOptions = .{},
    schema_options: schema.RenderOptions = .{},
    include_debug_asset_refs: bool = true,
    max_output_bytes: ?usize = null,
    max_page_memory_bytes: ?usize = null,
};

pub const StreamingSummary = struct {
    page_count: usize = 0,
    event_count: u64 = 0,
    artifact_counts: schema.StreamCounts = .{},
    route_counts: schema.RouteTotals = .{},
    specialist_failure_count: usize = 0,
    elapsed_ms: u64 = 0,
};

pub fn extractAdaptiveStreaming(
    allocator: std.mem.Allocator,
    document: anytype,
    output_writer: anytype,
    options: StreamingOptions,
) !StreamingSummary {
    if (options.max_output_bytes == 0 or options.max_page_memory_bytes == 0) return error.InvalidResourceLimit;
    var limited_writer = resource_limits.LimitedWriter(@TypeOf(output_writer)){
        .writer = output_writer,
        .max_bytes = options.max_output_bytes,
    };
    const writer = &limited_writer;
    const page_start = options.adaptive_options.page_start orelse 0;
    const page_end = options.adaptive_options.page_end orelse document.pages.items.len;
    if (page_start > page_end or page_end > document.pages.items.len) return error.InvalidPageRange;

    const started_ns = runtime.nanoTimestamp();
    var summary = StreamingSummary{ .page_count = page_end - page_start };
    var event_index: u64 = 0;
    var table_context = StreamTableContext{};
    var region_index_base: u32 = 0;
    var local_section_state = adaptive.section_hierarchy.State{};
    const owned_section_bookmarks = if (options.adaptive_options.section_bookmarks == null)
        try adaptive.collectSectionBookmarks(allocator, document)
    else
        null;
    defer if (owned_section_bookmarks) |items| adaptive.freeSectionBookmarks(allocator, items);
    const section_bookmarks = options.adaptive_options.section_bookmarks orelse owned_section_bookmarks.?;

    var owned_fallback_page_index: ?adaptive.DocumentTextPageIndex = null;
    if (options.adaptive_options.fallback_page_index == null) {
        if (options.adaptive_options.fallback_document_text) |document_text| {
            owned_fallback_page_index = try adaptive.DocumentTextPageIndex.init(allocator, document_text, page_end);
        }
    }
    defer if (owned_fallback_page_index) |*index| index.deinit();
    const fallback_page_index: ?*const adaptive.DocumentTextPageIndex = if (options.adaptive_options.fallback_page_index) |index|
        index
    else if (owned_fallback_page_index) |*index|
        index
    else
        null;

    var manifest_options = options.schema_options;
    manifest_options.include_debug_asset_refs = options.include_debug_asset_refs;
    if (manifest_options.page_count == null) manifest_options.page_count = document.pages.items.len;

    try schema.writeStreamManifestRecord(writer, manifest_options, event_index);
    event_index += 1;
    try writer.writeByte('\n');

    for (page_start..page_end) |page_idx| {
        const page = document.pages.items[page_idx];
        const page_index: u32 = @intCast(page_idx);
        const page_bbox = pageBBox(page);

        try schema.writePageStartedRecord(writer, manifest_options.document_id, manifest_options.source_id, manifest_options.input_sha256, page_index, page_bbox, event_index);
        event_index += 1;
        try writer.writeByte('\n');

        var page_options = options.adaptive_options;
        page_options.page_start = page_idx;
        page_options.page_end = page_idx + 1;
        page_options.fallback_page_index = fallback_page_index;
        page_options.region_index_base = region_index_base;
        page_options.section_bookmarks = section_bookmarks;
        page_options.section_state = options.adaptive_options.section_state orelse &local_section_state;
        page_options.section_block_base = options.adaptive_options.section_block_base + @as(u32, @intCast(summary.artifact_counts.blocks));

        var page_budget = resource_limits.BudgetAllocator{
            .parent = allocator,
            .max_bytes = options.max_page_memory_bytes orelse std.math.maxInt(usize),
        };
        const page_allocator = if (options.max_page_memory_bytes != null) page_budget.allocator() else allocator;
        var page_result = adaptive.extractDocument(page_allocator, document, page_options) catch |err| {
            if (page_budget.limit_hit.load(.monotonic)) return error.MemoryBudgetExceeded;
            return err;
        };
        defer page_result.deinit();
        // Some native fallbacks deliberately tolerate allocation errors. A
        // budget breach must still fail the stream rather than publish omission.
        if (page_budget.limit_hit.load(.monotonic)) return error.MemoryBudgetExceeded;
        region_index_base += @intCast(page_result.region_routes.len);
        if (page_result.hasSpecialistFailures()) summary.specialist_failure_count += 1;

        const page_counts = writePageArtifacts(
            page_allocator,
            writer,
            manifest_options.document_id,
            manifest_options.source_id,
            manifest_options.input_sha256,
            manifest_options.debug_assets_dir,
            page_index,
            &page_result,
            summary.artifact_counts,
            &table_context,
            &event_index,
        ) catch |err| {
            if (page_budget.limit_hit.load(.monotonic)) return error.MemoryBudgetExceeded;
            return err;
        };
        summary.artifact_counts.spans += page_counts.spans;
        summary.artifact_counts.blocks += page_counts.blocks;
        summary.artifact_counts.tables += page_counts.tables;
        summary.artifact_counts.route_traces += page_counts.route_traces;
        summary.artifact_counts.specialist_requests += page_counts.specialist_requests;
        summary.artifact_counts.specialist_attempts += page_counts.specialist_attempts;
        summary.artifact_counts.specialist_responses += page_counts.specialist_responses;
        summary.artifact_counts.specialist_results += page_counts.specialist_results;
        summary.artifact_counts.rag_chunks += page_counts.rag_chunks;
        summary.artifact_counts.debug_assets += page_counts.debug_assets;

        const page_routes = routeTotals(&page_result);
        addRouteTotals(&summary.route_counts, page_routes);

        try schema.writePageFinishedRecord(
            writer,
            manifest_options.document_id,
            manifest_options.source_id,
            manifest_options.input_sha256,
            page_index,
            page_bbox,
            page_counts,
            page_routes,
            event_index,
        );
        event_index += 1;
        try writer.writeByte('\n');
    }

    if (options.include_debug_asset_refs) {
        const document_debug_assets = try visual_assets.collectDocumentRefs(allocator, manifest_options.debug_assets_dir);
        defer visual_assets.deinitRecords(allocator, document_debug_assets);
        summary.artifact_counts.debug_assets += try schema.writeDebugAssetStreamRecords(writer, manifest_options.document_id, manifest_options.source_id, manifest_options.input_sha256, document_debug_assets, &event_index);
    }

    const elapsed_ns = runtime.nanoTimestamp() - started_ns;
    summary.elapsed_ms = if (elapsed_ns > 0) @intCast(@divTrunc(elapsed_ns, 1_000_000)) else 0;
    // Reserve the whole terminal record before emitting any of it. A bounded
    // failure can leave an incomplete artifact, but never a completion marker.
    var terminal_counter = resource_limits.CountingWriter{};
    try schema.writeDocumentFinishedRecord(
        &terminal_counter,
        manifest_options.document_id,
        manifest_options.source_id,
        manifest_options.input_sha256,
        summary.artifact_counts,
        summary.route_counts,
        summary.elapsed_ms,
        event_index,
    );
    try terminal_counter.writeByte('\n');
    try limited_writer.ensureCapacity(terminal_counter.written);
    try schema.writeDocumentFinishedRecord(
        writer,
        manifest_options.document_id,
        manifest_options.source_id,
        manifest_options.input_sha256,
        summary.artifact_counts,
        summary.route_counts,
        summary.elapsed_ms,
        event_index,
    );
    event_index += 1;
    try writer.writeByte('\n');

    summary.event_count = event_index;
    return summary;
}

fn writePageArtifacts(
    allocator: std.mem.Allocator,
    writer: anytype,
    document_id: []const u8,
    source_id: ?[]const u8,
    input_sha256: ?[]const u8,
    debug_assets_dir: ?[]const u8,
    page_index: u32,
    result: anytype,
    global_counts: schema.StreamCounts,
    table_context: *StreamTableContext,
    event_index: *u64,
) !schema.StreamCounts {
    var counts = schema.StreamCounts{};
    const offsets = schema.RecordOffsets{
        .span_base = @intCast(global_counts.spans),
        .block_base = @intCast(global_counts.blocks),
        .table_base = @intCast(global_counts.tables),
        .chunk_base = @intCast(global_counts.rag_chunks),
        .route_base = @intCast(global_counts.route_traces),
    };

    counts.route_traces = try schema.writeRouteTraceStreamRecords(writer, document_id, source_id, input_sha256, result, offsets, event_index);
    const specialist_context = specialist_protocol.RenderContext{
        .document_id = document_id,
        .source_id = source_id,
        .input_sha256 = input_sha256,
        .span_base = offsets.span_base,
        .block_base = offsets.block_base,
    };
    counts.specialist_requests = try specialist_protocol.writePageRequestsJsonl(writer, result, specialist_context, page_index, event_index);
    counts.specialist_attempts = try specialist_protocol.writePageAttemptsJsonl(writer, result, specialist_context, page_index, event_index);
    counts.specialist_responses = try specialist_protocol.writePageResponsesJsonl(writer, result, specialist_context, page_index, event_index);
    counts.specialist_results = try specialist_protocol.writePageResultsJsonl(writer, result, specialist_context, page_index, event_index);

    for (result.reconciled.spans, 0..) |span, local_index| {
        if (span.span.page_index != page_index) continue;
        try schema.writeSpanStreamRecord(writer, result, document_id, source_id, input_sha256, span, offsets.span_base + @as(u32, @intCast(local_index)), offsets, .{
            .event_type = "span",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.spans += 1;
        try writer.writeByte('\n');
    }

    for (result.reconciled.blocks) |block| {
        if (block.page_index != page_index) continue;
        try schema.writeBlockStreamRecord(writer, result, document_id, source_id, input_sha256, block, offsets, .{
            .event_type = "block",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.blocks += 1;
        try writer.writeByte('\n');
    }

    var table_scratch: schema.TableRenderScratch = .{};
    defer table_scratch.deinit(allocator);
    for (result.tables, 0..) |table, local_index| {
        if (table.page_index != page_index) continue;
        const global_table_index = offsets.table_base + @as(u32, @intCast(local_index));
        var stream_table = table;
        _ = table_context.apply(&stream_table, global_table_index);
        try schema.writeTableStreamRecord(allocator, writer, document_id, source_id, input_sha256, result, stream_table, global_table_index, offsets, .{
            .event_type = "table",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        }, &table_scratch);
        event_index.* += 1;
        counts.tables += 1;
        try writer.writeByte('\n');
    }

    for (result.reconciled.chunks) |chunk| {
        if (chunk.page_start > page_index or chunk.page_end < page_index) continue;
        try schema.writeRagChunkStreamRecord(writer, result, document_id, source_id, input_sha256, chunk, offsets, .{
            .event_type = "rag_chunk",
            .event_index = event_index.*,
            .page_index = page_index,
            .sequence_scope = "page",
        });
        event_index.* += 1;
        counts.rag_chunks += 1;
        try writer.writeByte('\n');
    }

    const page_debug_assets = try visual_assets.collectPageMaterialized(allocator, result, debug_assets_dir, page_index);
    defer visual_assets.deinitRecords(allocator, page_debug_assets);
    counts.debug_assets = try schema.writeDebugAssetStreamRecords(writer, document_id, source_id, input_sha256, page_debug_assets, event_index);

    return counts;
}

const StreamTableContext = table_continuation.Context;

fn pageBBox(page: anytype) layout.BBox {
    return .{
        .x0 = page.media_box[0],
        .y0 = page.media_box[1],
        .x1 = page.media_box[2],
        .y1 = page.media_box[3],
    };
}

fn routeTotals(result: anytype) schema.RouteTotals {
    var totals = schema.RouteTotals{
        .page_routes = result.page_routes.len,
        .region_routes = result.region_routes.len,
    };
    for (result.page_routes) |route| {
        if (route.route.native_fast_path) totals.native_pages += 1;
    }
    for (result.region_routes) |route| {
        if (route.route.needs_ocr) totals.ocr_regions += 1;
        if (route.route.needs_table_model) totals.table_regions += 1;
        if (route.route.needs_formula_model) totals.formula_regions += 1;
    }
    return totals;
}

fn addRouteTotals(total: *schema.RouteTotals, add: schema.RouteTotals) void {
    total.native_pages += add.native_pages;
    total.page_routes += add.page_routes;
    total.region_routes += add.region_routes;
    total.ocr_regions += add.ocr_regions;
    total.table_regions += add.table_regions;
    total.formula_regions += add.formula_regions;
}

test "streaming event enum includes lifecycle and artifact records" {
    try std.testing.expectEqual(StreamingEventType.document_manifest, StreamingEventType.document_manifest);
    try std.testing.expectEqual(StreamingEventType.document_finished, StreamingEventType.document_finished);
}

test "stream output cap reserves terminal record atomically" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());
    const root = @import("root.zig");
    const pdf_data = try @import("testpdf.zig").generateCleanNativePdf(allocator);
    defer allocator.free(pdf_data);
    const doc = try root.Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const options = StreamingOptions{ .adaptive_options = .{ .page_start = 0, .page_end = 0, .enable_ocr = false }, .include_debug_asset_refs = false };
    _ = try extractAdaptiveStreaming(allocator, doc, runtime.arrayListWriter(&output, allocator), options);
    const terminal_start = std.mem.lastIndexOfScalar(u8, output.items[0 .. output.items.len - 1], '\n').? + 1;
    output.clearRetainingCapacity();
    var limited_options = options;
    limited_options.max_output_bytes = terminal_start + 1;
    try std.testing.expectError(error.OutputLimitExceeded, extractAdaptiveStreaming(allocator, doc, runtime.arrayListWriter(&output, allocator), limited_options));
    try std.testing.expectEqual(terminal_start, output.items.len);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "document_finished") == null);
}

test "stream page allocation budget failures clean up partial extraction" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());
    const root = @import("root.zig");
    const pdf_data = try @import("testpdf.zig").generateCleanNativePdf(allocator);
    defer allocator.free(pdf_data);
    const doc = try root.Document.openFromMemory(allocator, pdf_data, root.ErrorConfig.default());
    defer doc.close();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var failed_count: usize = 0;
    for ([_]usize{ 1, 32, 128, 512, 2048, 8192, 32768 }) |limit| {
        output.clearRetainingCapacity();
        if (extractAdaptiveStreaming(allocator, doc, runtime.arrayListWriter(&output, allocator), .{
            .adaptive_options = .{ .enable_ocr = false },
            .include_debug_asset_refs = false,
            .max_page_memory_bytes = limit,
        })) |_| {} else |err| {
            try std.testing.expectEqual(error.MemoryBudgetExceeded, err);
            try std.testing.expect(std.mem.indexOf(u8, output.items, "document_finished") == null);
            failed_count += 1;
        }
    }
    try std.testing.expect(failed_count > 0);
}
