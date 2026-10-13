//! Adaptive extraction orchestration types.
//!
//! Adaptive extraction orchestration: native spans, layout, complexity routing,
//! optional specialist span producers, reconciliation, and output rendering.

const std = @import("std");
const layout = @import("layout.zig");
const native_layout = @import("native_layout.zig");
const complexity = @import("complexity.zig");
const ocr = @import("ocr.zig");
const reconcile = @import("reconcile.zig");
const runtime = @import("runtime.zig");
const reading_order_graph = @import("reading_order_graph.zig");
const reading_order_regions = @import("reading_order_regions.zig");
const schema = @import("schema.zig");
const specialist_protocol = @import("specialist_protocol.zig");
const specialists = @import("specialists.zig");
const page_geometry = @import("page_geometry.zig");
const vector_routing = @import("vector_routing.zig");

pub const BBox = layout.BBox;
pub const BlockKind = layout.BlockKind;
pub const ReconciledDocument = reconcile.ReconciledDocument;
pub const ReconcileOptions = reconcile.ReconcileOptions;
pub const RouteDecision = complexity.RouteDecision;
pub const SignalScores = complexity.SignalScores;

pub const ExtractOptions = struct {
    page_start: ?usize = null,
    page_end: ?usize = null,
    enable_ocr: bool = true,
    ocr_config: ocr.OcrConfig = .{},
    preserve_layout_order: bool = true,
    /// Optional output from one document-level `pdftotext <input> -` process.
    /// It is consumed page-by-page only when native readable layout fails its
    /// quality gate; ownership remains with the caller.
    fallback_document_text: ?[]const u8 = null,
    /// Optional pre-indexed view of `fallback_document_text`. Streaming callers
    /// use this to share one linear scan across page-scoped extractions.
    fallback_page_index: ?*const DocumentTextPageIndex = null,
    reconcile_options: ReconcileOptions = .{},
    /// Optional formula adapter configuration borrowed for this extraction
    /// call only. `Result` retains only owned lifecycle records.
    formula_specialist: ?specialists.SpecialistConfig = null,
    specialist_context: specialist_protocol.RenderContext = .{},
    /// Keeps region request identities document-global when streaming one page
    /// at a time. Batch callers leave this at zero.
    region_index_base: u32 = 0,
    /// Internal experiment control. Public JSON/JSONL schemas never expose the
    /// graph or this switch.
    reading_order_mode: ReadingOrderMode = .legacy,
    /// Enables tagged-PDF MCID evidence for the projectable V0 flat graph.
    /// Hierarchy diagnostics use synthetic regions without MCID mappings.
    reading_order_include_structure: bool = true,
    /// Controls whether V0 flat-graph structure order is hard or soft evidence.
    reading_order_structure_hard: bool = true,
};

pub const ReadingOrderMode = enum {
    legacy,
    diagnostic,
    graph,
};

pub const ReadingOrderRelation = reading_order_graph.Relation;

pub const OutputFormat = enum {
    text,
    markdown,
    json,
    jsonl,
    rag_jsonl,
    artifact_jsonl,
    hocr,
    alto,
    debug_svg,
};

pub const RouteReason = enum(u5) {
    native_fast_path,
    sparse_text,
    image_dominance,
    bad_unicode,
    missing_tounicode,
    hidden_ocr,
    low_reading_order_confidence,
    table_alignment,
    formula_density,
    ocr_route_stub,
    layout_route_stub,
    table_route_stub,
    formula_route_stub,
    unexplained_vector,
    vector_evidence_limited,
};

pub const RouteReasonMask = u32;

pub const TraceStage = enum {
    native_spans,
    layout_blocks,
    complexity_score,
    route_decision,
    ocr_route_stub,
    ocr_recognize,
    table_route_stub,
    formula_route_stub,
    reconcile,
    output_ready,
};

pub const TraceRecord = struct {
    page_index: u32,
    region_index: ?u32 = null,
    stage: TraceStage,
    route: RouteDecision = .{},
    reason_mask: RouteReasonMask = 0,
    span_count: usize = 0,
    block_count: usize = 0,
};

pub const OcrAttempt = struct {
    attempt_index: u16,
    page_index: u32,
    region_index: ?u32 = null,
    crop_bbox: ?BBox = null,
    crop_image_sha256: ?[32]u8 = null,
    crop_image_byte_length: ?usize = null,
    pixel_to_pdf: ?page_geometry.Matrix = null,
    rasterizer_dpi: ?f64 = null,
    status: ocr.AttemptStatus,
    page_bbox: BBox = .{},
    failure_stage: ?ocr.AttemptStage = null,
    backend: ocr.Backend,
    dpi: u32,
    psm: ocr.PageSegMode,
    lang: []u8,
    grayscale: bool,
    timeout_ms: u32,
    max_image_pixels: usize = 40_000_000,
    max_image_bytes: usize = 32 * 1024 * 1024,
    max_regions_per_page: usize = 8,
    max_attempts_per_page: usize = 16,
    duration_ms: u64 = 0,
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    span_count: usize = 0,
    character_count: usize = 0,
    mean_confidence: f32 = 0,
    text_coverage: f32 = 0,
    exit_code: ?u8 = null,
    diagnostic_code: ?ocr.DiagnosticCode = null,
    stderr_excerpt: []u8,
    selected: bool = false,
};

pub const PageRoute = struct {
    page_index: u32,
    page_geometry: ?page_geometry.PageGeometry = null,
    vector_evidence: ?vector_routing.Summary = null,
    bbox: BBox,
    span_count: usize,
    image_count: usize,
    char_count: usize,
    signals: SignalScores,
    route: RouteDecision,
    reason_mask: RouteReasonMask,

    pub fn fromScore(score: complexity.PageScore) PageRoute {
        return .{
            .page_index = score.page_index,
            .bbox = score.page_bbox,
            .span_count = score.score.span_count,
            .image_count = score.score.image_count,
            .char_count = score.score.char_count,
            .signals = score.score.signals,
            .route = score.score.route,
            .reason_mask = reasonMask(score.score, null),
        };
    }
};

pub const LayoutBlockSummary = struct {
    page_index: u32,
    block_index: u32,
    column_index: u32,
    bbox: BBox,
    kind: BlockKind,
    confidence: f32,
    removed: bool,
    line_count: usize,
};

pub const RegionRoute = struct {
    page_index: u32,
    region_index: u32,
    layout_block_index: ?u32 = null,
    vector_evidence: ?vector_routing.Candidate = null,
    bbox: BBox,
    block_kind: ?BlockKind = null,
    span_count: usize,
    image_count: usize,
    char_count: usize,
    signals: SignalScores,
    table: ?specialists.TableScore = null,
    formula: ?specialists.FormulaScore = null,
    route: RouteDecision,
    reason_mask: RouteReasonMask,

    pub fn fromScore(args: struct {
        region_index: u32,
        layout_block_index: ?u32 = null,
        block_kind: ?BlockKind = null,
        score: complexity.RegionScore,
        specialist: ?specialists.AnalysisResult = null,
    }) RegionRoute {
        const table = if (args.specialist) |analysis| analysis.table else null;
        const formula = if (args.specialist) |analysis| analysis.formula else null;
        var route = args.score.route;
        var mask = reasonMask(args.score, args.specialist);
        if (args.block_kind) |kind| {
            switch (kind) {
                .table_candidate => {
                    route.needs_table_model = true;
                    route.max_signal = @max(route.max_signal, if (table) |score| score.confidence else 0.72);
                    mask |= reasonBit(.table_route_stub);
                },
                .formula_candidate => {
                    route.needs_formula_model = true;
                    route.max_signal = @max(route.max_signal, if (formula) |score| score.confidence else 0.76);
                    mask |= reasonBit(.formula_route_stub);
                },
                else => {},
            }
        }
        const table_confidence = if (table) |score| score.confidence else if (route.needs_table_model) route.max_signal else 0;
        const formula_confidence = if (formula) |score| score.confidence else if (route.needs_formula_model) route.max_signal else 0;
        if (route.needs_table_model or route.needs_formula_model) {
            if (table_confidence >= formula_confidence) {
                route.needs_table_model = true;
                route.needs_formula_model = false;
                mask &= ~(reasonBit(.formula_density) | reasonBit(.formula_route_stub));
            } else {
                route.needs_table_model = false;
                route.needs_formula_model = true;
                mask &= ~(reasonBit(.table_alignment) | reasonBit(.table_route_stub));
            }
            // A table/formula specialist already receives the region geometry;
            // a second generic layout request for the same block is redundant.
            route.needs_layout_model = false;
            mask &= ~(reasonBit(.low_reading_order_confidence) | reasonBit(.layout_route_stub));
        }
        return .{
            .page_index = args.score.page_index,
            .region_index = args.region_index,
            .layout_block_index = args.layout_block_index,
            .bbox = args.score.bbox,
            .block_kind = args.block_kind,
            .span_count = args.score.span_count,
            .image_count = args.score.image_count,
            .char_count = args.score.char_count,
            .signals = args.score.signals,
            .table = table,
            .formula = formula,
            .route = route,
            .reason_mask = mask,
        };
    }
};

pub const FormField = struct {
    name: []u8,
    value: ?[]u8,
    field_type: []u8,
    rect: ?[4]f64,
};

pub const FormulaStatus = enum {
    completed,
    empty,
    unavailable,
    failed,
    timeout,
    invalid_output,
};

pub const FormulaAttempt = struct {
    request_id: []u8,
    page_index: u32,
    region_index: u32,
    status: FormulaStatus,
    specialist_id: []u8,
    duration_ms: u64 = 0,
    exit_code: ?u8 = null,
    diagnostic_code: ?[]u8 = null,
    stderr_excerpt: []u8,
    crop_backed: bool = false,
    crop_bbox: ?BBox = null,
    crop_dpi: ?u32 = null,
    crop_pixel_width: ?u32 = null,
    crop_pixel_height: ?u32 = null,
    crop_pixel_to_pdf: ?page_geometry.Matrix = null,
    crop_rasterizer_dpi: ?f64 = null,
};

pub const FormulaArtifact = struct {
    request_id: []u8,
    formula_id: []u8,
    page_index: u32,
    region_index: u32,
    text: []u8,
    format: []u8,
    confidence: f32,
    specialist_id: []u8,
};

pub const ReadingOrderApplication = enum {
    diagnostic_only,
    applied,
    invalid_graph,
    native_quality_failed,
    ocr_selected,
    unsupported_writing_mode,
    span_mapping_incomplete,
    formula_specialist_enabled,
};

/// Owned diagnostic summary for every layout block, including furniture that
/// is intentionally excluded from graph nodes. It is retained only when a
/// non-legacy reading-order mode builds an internal graph.
pub const ReadingOrderBlock = struct {
    page_index: u32,
    original_block_index: u32,
    bounds: BBox,
    kind: BlockKind,
    column_index: u32,
    removed: bool,
    text: []u8,
};

/// Owned diagnostic copy of the geometric spans used to build page layout.
/// This preserves the pre-block substrate for representation experiments.
pub const ReadingOrderSourceSpan = struct {
    page_index: u32,
    span_index: u32,
    bounds: BBox,
    font_size: f64,
    text: []u8,
};

pub const ReadingOrderRegion = struct {
    page_index: u32,
    id: u32,
    parent_id: ?u32,
    kind: reading_order_regions.RegionKind,
    bounds: BBox,
    source_span_count: usize,
};

pub const PageReadingOrder = struct {
    page_index: u32,
    graph: reading_order_graph.PageReadingOrderGraph,
    node_texts: [][]u8,
    blocks: []ReadingOrderBlock,
    source_spans: []ReadingOrderSourceSpan,
    regions: []ReadingOrderRegion,
    application: ReadingOrderApplication,
    structure_enabled: bool,
    eligible: bool,

    pub fn deinit(self: *PageReadingOrder) void {
        for (self.node_texts) |text| self.graph.allocator.free(text);
        self.graph.allocator.free(self.node_texts);
        for (self.blocks) |block| self.graph.allocator.free(block.text);
        self.graph.allocator.free(self.blocks);
        for (self.source_spans) |span| self.graph.allocator.free(span.text);
        self.graph.allocator.free(self.source_spans);
        self.graph.allocator.free(self.regions);
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    reconciled: ReconciledDocument,
    native_pages: [][]layout.TextSpan,
    layout_blocks: []LayoutBlockSummary,
    page_routes: []PageRoute,
    region_routes: []RegionRoute,
    trace_records: []TraceRecord,
    ocr_attempts: []OcrAttempt,
    formula_attempts: []FormulaAttempt,
    formula_artifacts: []FormulaArtifact,
    form_fields: []FormField,
    tables: []layout.TableGrid,
    reading_order_pages: []PageReadingOrder,

    pub fn deinit(self: *Result) void {
        self.reconciled.deinit();
        freeTextSpanPages(self.allocator, self.native_pages);
        self.allocator.free(self.layout_blocks);
        self.allocator.free(self.page_routes);
        self.allocator.free(self.region_routes);
        self.allocator.free(self.trace_records);
        freeOcrAttempts(self.allocator, self.ocr_attempts);
        freeFormulaAttempts(self.allocator, self.formula_attempts);
        freeFormulaArtifacts(self.allocator, self.formula_artifacts);
        freeFormFields(self.allocator, self.form_fields);
        freeOwnedTables(self.allocator, self.tables);
        freeReadingOrderPages(self.allocator, self.reading_order_pages);
    }

    pub fn render(self: *const Result, allocator: std.mem.Allocator, format: OutputFormat) ![]u8 {
        return switch (format) {
            .debug_svg => renderDebugSvg(allocator, self),
            .json => schema.renderArtifactJson(allocator, self, .{}),
            .artifact_jsonl => schema.renderArtifactJsonl(allocator, self, .{}),
            else => renderOutput(allocator, &self.reconciled, format),
        };
    }

    pub fn hasSpecialistFailures(self: *const Result) bool {
        for (self.ocr_attempts) |attempt| {
            switch (attempt.status) {
                .unavailable, .failed, .timeout, .invalid_output => return true,
                else => {},
            }
        }
        for (self.formula_attempts) |attempt| {
            switch (attempt.status) {
                .unavailable, .failed, .timeout, .invalid_output => return true,
                else => {},
            }
        }
        return false;
    }
};

pub fn extractDocument(
    allocator: std.mem.Allocator,
    document: anytype,
    options: ExtractOptions,
) !Result {
    const page_start = options.page_start orelse 0;
    const page_end = options.page_end orelse document.pages.items.len;
    if (page_start > page_end or page_end > document.pages.items.len) return error.InvalidPageRange;

    var owned_fallback_page_index: ?DocumentTextPageIndex = null;
    if (options.fallback_page_index == null) {
        if (options.fallback_document_text) |document_text| {
            owned_fallback_page_index = try DocumentTextPageIndex.init(allocator, document_text, page_end);
        }
    }
    defer if (owned_fallback_page_index) |*index| index.deinit();
    const fallback_page_index: ?*const DocumentTextPageIndex = if (options.fallback_page_index) |index|
        index
    else if (owned_fallback_page_index) |*index|
        index
    else
        null;

    var native_pages: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (native_pages.items) |spans| freeTextSpans(allocator, spans);
        native_pages.deinit(allocator);
    }

    var ocr_pages: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (ocr_pages.items) |spans| ocr.freeSpans(allocator, spans);
        ocr_pages.deinit(allocator);
    }

    var ocr_layer_views: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (ocr_layer_views.items) |view| allocator.free(view);
        ocr_layer_views.deinit(allocator);
    }

    var layout_pages: std.ArrayList([]layout.TextSpan) = .empty;
    defer {
        for (layout_pages.items) |spans| freeTextSpans(allocator, spans);
        layout_pages.deinit(allocator);
    }

    var layers: std.ArrayList(reconcile.SpanLayer) = .empty;
    defer layers.deinit(allocator);

    var layout_blocks: std.ArrayList(LayoutBlockSummary) = .empty;
    defer layout_blocks.deinit(allocator);

    var page_routes: std.ArrayList(PageRoute) = .empty;
    defer page_routes.deinit(allocator);

    var region_routes: std.ArrayList(RegionRoute) = .empty;
    defer region_routes.deinit(allocator);

    var trace_records: std.ArrayList(TraceRecord) = .empty;
    defer trace_records.deinit(allocator);

    var ocr_attempts: std.ArrayList(OcrAttempt) = .empty;
    defer {
        freeOcrAttemptItems(allocator, ocr_attempts.items);
        ocr_attempts.deinit(allocator);
    }

    var tables: std.ArrayList(layout.TableGrid) = .empty;
    defer {
        freeOwnedTableItems(allocator, tables.items);
        tables.deinit(allocator);
    }

    var reading_order_pages: std.ArrayList(PageReadingOrder) = .empty;
    defer {
        freeReadingOrderPageItems(reading_order_pages.items);
        reading_order_pages.deinit(allocator);
    }

    const form_fields = try collectFormFields(allocator, document);
    errdefer freeFormFields(allocator, form_fields);

    const has_structure_tree = document.hasStructureTree();
    var region_index: u32 = options.region_index_base;

    for (page_start..page_end) |page_idx| {
        const page = document.pages.items[page_idx];
        const page_index: u32 = @intCast(page_idx);
        const page_bbox = BBox{
            .x0 = page.media_box[0],
            .y0 = page.media_box[1],
            .x1 = page.media_box[2],
            .y1 = page.media_box[3],
        };

        var content_scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer content_scratch_arena.deinit();
        const content_scratch_allocator = content_scratch_arena.allocator();
        const page_content = document.getPageContentForScratch(page_idx, content_scratch_allocator) catch &.{};

        var geometry = try document.extractNativePageGeometryFromContent(page_idx, allocator, content_scratch_allocator, page_content);
        defer geometry.deinit();
        try native_pages.ensureUnusedCapacity(allocator, 1);
        const spans = try cloneTextSpans(allocator, geometry.spans);
        native_pages.appendAssumeCapacity(spans);

        const raw_recall_text = document.extractTextRawRecall(page_idx, allocator) catch try allocator.alloc(u8, 0);
        defer allocator.free(raw_recall_text);
        const semantic_glyphs = geometry.semantic_glyphs orelse geometry.glyphs;
        var native_result = try native_layout.analyze(allocator, semantic_glyphs, page_bbox, raw_recall_text);
        defer native_result.deinit();
        const fallback_page_text = if (fallback_page_index) |index| index.get(page_idx) else null;
        if (fallback_page_text) |reference_text| {
            native_result.quality = try native_layout.compareAgainstReference(
                allocator,
                raw_recall_text,
                native_result.text,
                reference_text,
            );
        }

        try layout_pages.ensureUnusedCapacity(allocator, 1);
        var readable_spans: []layout.TextSpan = undefined;
        if (native_result.quality.quality_pass) {
            readable_spans = try native_layout.buildLineSpans(allocator, semantic_glyphs, &native_result, page_index);
        } else if (fallback_page_text) |page_text| {
            readable_spans = try fallbackTextSpans(allocator, page_text, page_index, page_bbox);
        } else {
            // Keep the best native readable reconstruction available when the
            // external comparator is unavailable, while preserving the failed
            // quality result as a hard routing signal below.
            readable_spans = try native_layout.buildLineSpans(allocator, semantic_glyphs, &native_result, page_index);
        }
        layout_pages.appendAssumeCapacity(readable_spans);
        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .native_spans,
            .span_count = spans.len,
        });

        const images = try document.getPageImagesFromContent(page_idx, allocator, content_scratch_allocator, page_content);
        defer allocator.free(images);

        const image_boxes = try allocator.alloc(complexity.ImageBox, images.len);
        defer allocator.free(image_boxes);
        for (images, 0..) |image, image_index| {
            image_boxes[image_index] = .{
                .bbox = .{
                    .x0 = image.rect[0],
                    .y0 = image.rect[1],
                    .x1 = image.rect[2],
                    .y1 = image.rect[3],
                },
                .pixel_width = image.width,
                .pixel_height = image.height,
            };
        }

        const page_input = complexity.PageInput{
            .page_index = page_index,
            .bbox = page_bbox,
            .spans = spans,
            .images = image_boxes,
            .has_structure_tree = has_structure_tree,
        };

        const page_score = complexity.scorePage(page_input);
        var page_route = PageRoute.fromScore(page_score);
        if (@hasDecl(@TypeOf(document.*), "getPageGeometry")) page_route.page_geometry = document.getPageGeometry(page_idx);
        var vector_result: ?vector_routing.Result = null;
        defer if (vector_result) |*value| value.deinit();
        if (@hasDecl(@TypeOf(document.*), "getPageVectorEvidenceFromContent")) {
            var evidence = try document.getPageVectorEvidenceFromContent(page_idx, allocator, content_scratch_allocator, page_content);
            defer evidence.deinit();
            vector_result = try vector_routing.classify(allocator, &evidence, spans, page_bbox, page_route.page_geometry);
            page_route.vector_evidence = vector_result.?.summary;
            if (vector_result.?.candidates.len > 0) {
                page_route.route.native_fast_path = false;
                page_route.reason_mask &= ~reasonBit(.native_fast_path);
                page_route.reason_mask |= reasonBit(.unexplained_vector);
            }
            if (evidence.status != .complete or vector_result.?.summary.status != .complete)
                page_route.reason_mask |= reasonBit(.vector_evidence_limited);
        }
        if (!native_result.quality.quality_pass) suppressLayoutSpecialists(&page_route.route, &page_route.reason_mask);
        try page_routes.append(allocator, page_route);
        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .complexity_score,
            .route = page_route.route,
            .reason_mask = page_route.reason_mask,
            .span_count = page_route.span_count,
        });
        try appendRouteTraces(
            allocator,
            &trace_records,
            page_index,
            null,
            page_route.route,
            page_route.reason_mask,
            page_route.span_count,
            0,
        );

        // Image routes precede recognition so attempts retain the exact routed
        // region identity even when native text makes the page score look good.
        const image_route_start = region_routes.items.len;
        const regional_ocr = usesRegionalOcr(page_route, native_result.quality.quality_pass) or
            (vector_result != null and vector_result.?.candidates.len > 0 and !page_route.route.needs_ocr);
        if (regional_ocr) {
            for (image_boxes) |image| {
                const score = complexity.scoreRegion(page_input, image.bbox);
                const route = RegionRoute.fromScore(.{ .region_index = region_index, .score = score });
                try region_routes.append(allocator, route);
                try appendRouteTraces(allocator, &trace_records, page_index, region_index, route.route, route.reason_mask, route.span_count, 0);
                region_index += 1;
            }
            if (vector_result) |value| {
                for (value.candidates) |candidate| {
                    var covered = false;
                    for (region_routes.items[image_route_start..]) |*existing| {
                        if (!existing.route.needs_ocr or existing.bbox.x0 > candidate.bbox.x0 or existing.bbox.y0 > candidate.bbox.y0 or
                            existing.bbox.x1 < candidate.bbox.x1 or existing.bbox.y1 < candidate.bbox.y1) continue;
                        existing.vector_evidence = if (existing.vector_evidence) |old|
                            vector_routing.mergeCandidates(old, candidate, spans) orelse continue
                        else
                            candidate;
                        existing.reason_mask |= reasonBit(.unexplained_vector);
                        covered = true;
                        break;
                    }
                    if (covered) continue;
                    var route = RegionRoute.fromScore(.{ .region_index = region_index, .score = complexity.scoreRegion(page_input, candidate.bbox) });
                    route.vector_evidence = candidate;
                    route.route = .{ .native_fast_path = false, .needs_ocr = true, .max_signal = 1 };
                    route.reason_mask = reasonBit(.unexplained_vector) | reasonBit(.ocr_route_stub);
                    try region_routes.append(allocator, route);
                    try appendRouteTraces(allocator, &trace_records, page_index, region_index, route.route, route.reason_mask, route.span_count, 0);
                    region_index += 1;
                }
            }
        }
        const image_route_end = region_routes.items.len;
        var page_ocr_spans: ?[]layout.TextSpan = null;
        var page_attempt_count: usize = 0;
        if (!regional_ocr and page_route.route.needs_ocr) {
            const target_images = if (vector_result != null and vector_result.?.candidates.len > 0) &.{} else image_boxes;
            const selected = try recognizeOcrTarget(document, allocator, &ocr_attempts, options, page_idx, page_bbox, null, spans, target_images, &page_attempt_count);
            if (selected) |owned| {
                errdefer ocr.freeSpans(allocator, owned);
                try ocr_pages.append(allocator, owned);
                page_ocr_spans = owned;
            }
        } else if (regional_ocr) {
            var combined: std.ArrayList(layout.TextSpan) = .empty;
            defer combined.deinit(allocator);
            errdefer for (combined.items) |span| allocator.free(@constCast(span.text));
            var requested_regions: usize = 0;
            for (region_routes.items[image_route_start..image_route_end]) |route| {
                if (!route.route.needs_ocr) continue;
                if (requested_regions >= options.ocr_config.max_regions_per_page) {
                    _ = try appendOcrAttempt(allocator, &ocr_attempts, options.ocr_config, .{
                        .attempt_index = 0,
                        .page_index = page_index,
                        .region_index = route.region_index,
                        .status = .not_invoked,
                        .page_bbox = route.bbox,
                        .crop_bbox = route.bbox,
                        .diagnostic_code = .ocr_region_limit,
                    });
                    continue;
                }
                requested_regions += 1;
                const target_images = if (route.vector_evidence != null) &.{} else image_boxes;
                if (try recognizeOcrTarget(document, allocator, &ocr_attempts, options, page_idx, route.bbox, route.region_index, spans, target_images, &page_attempt_count)) |owned| {
                    // Transfer strings only after capacity succeeds; free the
                    // temporary array while combined owns its span strings.
                    errdefer ocr.freeSpans(allocator, owned);
                    try combined.appendSlice(allocator, owned);
                    allocator.free(owned);
                }
            }
            if (combined.items.len > 0) {
                const owned = try combined.toOwnedSlice(allocator);
                errdefer ocr.freeSpans(allocator, owned);
                try ocr_pages.append(allocator, owned);
                page_ocr_spans = owned;
            }
        }
        if (page_route.route.needs_ocr or image_route_end > image_route_start) {
            try trace_records.append(allocator, .{
                .page_index = page_index,
                .stage = .ocr_recognize,
                .route = page_route.route,
                .reason_mask = page_route.reason_mask,
                .span_count = if (page_ocr_spans) |ocr_spans| ocr_spans.len else 0,
            });
        }

        const ruling_lines = try document.getPageRulingLinesFromContent(page_idx, allocator, content_scratch_allocator, page_content);
        defer allocator.free(ruling_lines);

        const layout_input_spans = try buildPageSpanView(allocator, spans, page_ocr_spans);
        defer allocator.free(layout_input_spans);
        const page_view_quality_pass = native_result.quality.quality_pass or selectedOcrPageQualityPass(ocr_attempts.items, page_index);
        const structure_input = complexity.PageInput{
            .page_index = page_index,
            .bbox = page_bbox,
            .spans = layout_input_spans,
            .images = image_boxes,
            .has_structure_tree = has_structure_tree,
        };

        const page_width = page.media_box[2] - page.media_box[0];
        var page_layout = try layout.analyzeLayoutWithRulings(allocator, layout_input_spans, page_width, ruling_lines);
        defer page_layout.deinit();
        if (page_ocr_spans == null) reorderSpansToLayoutOrder(spans, page_layout.spans);

        var applied_projected_order: ?[]const u32 = null;
        if (options.reading_order_mode != .legacy) {
            const graph_structure_enabled = options.reading_order_mode == .graph and
                options.reading_order_include_structure;
            var structure_mcids: std.ArrayList(i32) = .empty;
            defer structure_mcids.deinit(allocator);
            if (graph_structure_enabled) {
                if (document.pageMarkedContentOrder(page_idx)) |marked_order| {
                    for (marked_order) |marked| {
                        if (marked.stream_ref != null) continue;
                        try structure_mcids.append(allocator, marked.mcid);
                    }
                }
            }

            var region_tree: ?reading_order_regions.Result = null;
            defer if (region_tree) |*tree| tree.deinit();
            var page_graph = if (options.reading_order_mode == .diagnostic) diagnostic_graph: {
                region_tree = try reading_order_regions.build(allocator, &page_layout);
                break :diagnostic_graph try reading_order_graph.buildForBlocks(
                    allocator,
                    page_index,
                    region_tree.?.blocks,
                    page_layout.body_font_size,
                    .{
                        .include_structure = false,
                        .include_semantics = false,
                        .geometry_model = .hierarchy,
                    },
                );
            } else projectable_v0_graph: {
                // The projectable mode still uses V0 flat layout blocks. The
                // measured hierarchy model above uses synthetic region blocks;
                // it cannot be promoted until those regions map uniquely back
                // to source spans.
                break :projectable_v0_graph try reading_order_graph.build(allocator, page_index, &page_layout, .{
                    .structure_mcid_order = structure_mcids.items,
                    .include_structure = graph_structure_enabled,
                    .structure_is_hard = options.reading_order_structure_hard,
                });
            };
            var graph_transferred = false;
            defer if (!graph_transferred) page_graph.deinit();
            const graph_blocks = if (region_tree) |*tree| tree.blocks else page_layout.blocks;
            const node_texts = try copyGraphNodeTexts(allocator, graph_blocks, &page_graph);
            var node_texts_transferred = false;
            defer if (!node_texts_transferred) freeOwnedStrings(allocator, node_texts);
            const block_summaries = try copyReadingOrderBlocks(allocator, page_index, graph_blocks);
            var block_summaries_transferred = false;
            defer if (!block_summaries_transferred) freeReadingOrderBlocks(allocator, block_summaries);
            const source_span_summaries = if (region_tree != null)
                try copyReadingOrderSourceSpans(allocator, page_index, page_layout.spans)
            else
                try allocator.alloc(ReadingOrderSourceSpan, 0);
            var source_span_summaries_transferred = false;
            defer if (!source_span_summaries_transferred) freeReadingOrderSourceSpans(allocator, source_span_summaries);
            const region_summaries = if (region_tree) |*tree|
                try copyReadingOrderRegions(allocator, page_index, tree.nodes)
            else
                try allocator.alloc(ReadingOrderRegion, 0);
            var region_summaries_transferred = false;
            defer if (!region_summaries_transferred) allocator.free(region_summaries);

            const base_eligible = options.reading_order_mode != .diagnostic and
                page_graph.validity and
                native_result.quality.quality_pass and
                page_ocr_spans == null and
                options.formula_specialist == null and
                horizontalLeftToRight(readable_spans);
            var mapping_complete = false;
            if (base_eligible) {
                const readable_mapping_complete = try reorderSpansByGraph(
                    allocator,
                    readable_spans,
                    &page_layout,
                    &page_graph,
                    false,
                );
                const native_mapping_complete = try reorderSpansByGraph(
                    allocator,
                    spans,
                    &page_layout,
                    &page_graph,
                    false,
                );
                mapping_complete = readable_mapping_complete and native_mapping_complete;
                if (mapping_complete and options.reading_order_mode == .graph) {
                    if (!try reorderSpansByGraph(allocator, readable_spans, &page_layout, &page_graph, true)) {
                        return error.InvalidReadingOrderProjection;
                    }
                    if (!try reorderSpansByGraph(allocator, spans, &page_layout, &page_graph, true)) {
                        return error.InvalidReadingOrderProjection;
                    }
                }
            }
            const graph_eligible = base_eligible and mapping_complete;

            var application: ReadingOrderApplication = .diagnostic_only;
            if (options.reading_order_mode == .graph) {
                application = if (!page_graph.validity)
                    .invalid_graph
                else if (!native_result.quality.quality_pass)
                    .native_quality_failed
                else if (page_ocr_spans != null)
                    .ocr_selected
                else if (options.formula_specialist != null)
                    .formula_specialist_enabled
                else if (!horizontalLeftToRight(readable_spans))
                    .unsupported_writing_mode
                else if (mapping_complete)
                    .applied
                else
                    .span_mapping_incomplete;
                if (application == .applied) applied_projected_order = page_graph.projected_block_order;
            }

            try reading_order_pages.append(allocator, .{
                .page_index = page_index,
                .graph = page_graph,
                .node_texts = node_texts,
                .blocks = block_summaries,
                .source_spans = source_span_summaries,
                .regions = region_summaries,
                .application = application,
                .structure_enabled = graph_structure_enabled,
                .eligible = graph_eligible,
            });
            graph_transferred = true;
            node_texts_transferred = true;
            block_summaries_transferred = true;
            source_span_summaries_transferred = true;
            region_summaries_transferred = true;
        }

        // Axis-aligned table inference uses raw PDF coordinates. On a rotated
        // OCR page those axes differ from the recognizer's rows and columns.
        // Retain its authoritative word order until table inference can share
        // the display transform; candidate routing may still describe evidence.
        const promote_tables = page_view_quality_pass and (page_ocr_spans == null or
            (page_route.page_geometry != null and page_route.page_geometry.?.rotation == .none));
        if (promote_tables) {
            for (page_layout.tables) |table| {
                try tables.ensureUnusedCapacity(allocator, 1);
                tables.appendAssumeCapacity(try copyTableGrid(allocator, table));
            }
        }

        var filtered_ocr_layer_added = false;
        if (promote_tables and page_layout.tables.len > 0 and page_view_quality_pass) {
            try layout_pages.ensureUnusedCapacity(allocator, 1);
            const layout_spans = try buildLayoutLayerSpans(allocator, &page_layout, applied_projected_order);
            if (layout_spans.len > 0) {
                layout_pages.appendAssumeCapacity(layout_spans);
                try layers.append(allocator, .{
                    .spans = layout_spans,
                    .trust = 1.0,
                });
                if (page_ocr_spans) |ocr_spans| {
                    const residual_spans = residual: {
                        const view = try filterSubsumedOcrSpanView(allocator, ocr_spans, layout_spans);
                        errdefer allocator.free(view);
                        try ocr_layer_views.append(allocator, view);
                        break :residual view;
                    };
                    if (residual_spans.len > 0) {
                        try layers.append(allocator, .{
                            .source = .fresh_ocr,
                            .spans = residual_spans,
                            .trust = 0.82,
                        });
                    }
                    filtered_ocr_layer_added = true;
                }
            } else {
                freeTextSpans(allocator, layout_spans);
                try layers.append(allocator, .{
                    .source = .native_pdf,
                    .spans = spans,
                    .trust = 1.0,
                });
            }
        } else {
            try layers.append(allocator, .{
                .spans = readable_spans,
                .trust = if (native_result.quality.quality_pass) 1.0 else 0.88,
            });
        }

        if (!filtered_ocr_layer_added) {
            if (page_ocr_spans) |ocr_spans| {
                if (ocr_spans.len > 0) {
                    try layers.append(allocator, .{
                        .source = .fresh_ocr,
                        .spans = ocr_spans,
                        .trust = 0.82,
                    });
                }
            }
        }

        try trace_records.append(allocator, .{
            .page_index = page_index,
            .stage = .layout_blocks,
            .span_count = layout_input_spans.len,
            .block_count = page_layout.blocks.len,
        });

        if (page_layout.blocks.len == 0) {
            const score = complexity.scoreRegion(structure_input, page_bbox);
            const specialist = specialists.analyzeRegion(.{
                .page_index = page_index,
                .bbox = page_bbox,
                .spans = layout_input_spans,
                .ruling_lines = ruling_lines,
            });
            var route = RegionRoute.fromScore(.{
                .region_index = region_index,
                .score = score,
                .specialist = specialist,
            });
            if (!page_view_quality_pass) suppressLayoutSpecialists(&route.route, &route.reason_mask);
            if (regional_ocr) suppressDerivedOcr(&route, page_input, region_routes.items[image_route_start..image_route_end]);
            try region_routes.append(allocator, route);
            try appendRouteTraces(
                allocator,
                &trace_records,
                page_index,
                region_index,
                route.route,
                route.reason_mask,
                route.span_count,
                0,
            );
            region_index += 1;
            continue;
        }

        for (page_layout.blocks, 0..) |block, block_index| {
            const block_index_u32: u32 = @intCast(block_index);
            try layout_blocks.append(allocator, layoutBlockSummary(page_index, block_index_u32, block));

            const score = complexity.scoreRegion(structure_input, block.bounds.bbox);
            const specialist = specialists.analyzeRegion(.{
                .page_index = page_index,
                .bbox = block.bounds.bbox,
                .spans = layout_input_spans,
                .ruling_lines = ruling_lines,
            });
            var route = RegionRoute.fromScore(.{
                .region_index = region_index,
                .layout_block_index = block_index_u32,
                .block_kind = block.kind,
                .score = score,
                .specialist = specialist,
            });
            if (!page_view_quality_pass) suppressLayoutSpecialists(&route.route, &route.reason_mask);
            if (regional_ocr) suppressDerivedOcr(&route, page_input, region_routes.items[image_route_start..image_route_end]);
            try region_routes.append(allocator, route);
            try appendRouteTraces(
                allocator,
                &trace_records,
                page_index,
                region_index,
                route.route,
                route.reason_mask,
                route.span_count,
                1,
            );
            region_index += 1;
        }
    }

    const form_spans = try formFieldsToSpans(allocator, form_fields);
    defer freeTextSpans(allocator, form_spans);
    if (form_spans.len > 0) {
        try layers.append(allocator, .{
            .source = .manual,
            .spans = form_spans,
            .trust = 1.0,
        });
    }

    var reconcile_options = options.reconcile_options;
    if (options.preserve_layout_order) reconcile_options.preserve_input_order = true;
    var reconciled = try reconcile.reconcile(allocator, layers.items, reconcile_options);
    errdefer reconciled.deinit();
    try trace_records.append(allocator, .{
        .page_index = @intCast(page_start),
        .stage = .reconcile,
        .span_count = reconciled.spans.len,
        .block_count = reconciled.blocks.len,
    });
    try trace_records.append(allocator, .{
        .page_index = @intCast(page_start),
        .stage = .output_ready,
        .span_count = reconciled.spans.len,
        .block_count = reconciled.chunks.len,
    });

    const owned_layout_blocks = try layout_blocks.toOwnedSlice(allocator);
    errdefer allocator.free(owned_layout_blocks);
    const owned_native_pages = try native_pages.toOwnedSlice(allocator);
    errdefer freeTextSpanPages(allocator, owned_native_pages);
    const owned_page_routes = try page_routes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_page_routes);
    const owned_region_routes = try region_routes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_region_routes);
    const owned_trace_records = try trace_records.toOwnedSlice(allocator);
    errdefer allocator.free(owned_trace_records);
    const owned_ocr_attempts = try ocr_attempts.toOwnedSlice(allocator);
    errdefer freeOcrAttempts(allocator, owned_ocr_attempts);
    linkLogicalTables(tables.items);
    const owned_tables = try tables.toOwnedSlice(allocator);
    errdefer freeOwnedTables(allocator, owned_tables);
    const owned_reading_order_pages = try reading_order_pages.toOwnedSlice(allocator);
    errdefer freeReadingOrderPages(allocator, owned_reading_order_pages);
    const empty_formula_attempts = try allocator.alloc(FormulaAttempt, 0);
    errdefer allocator.free(empty_formula_attempts);
    const empty_formula_artifacts = try allocator.alloc(FormulaArtifact, 0);
    errdefer allocator.free(empty_formula_artifacts);

    var result = Result{
        .allocator = allocator,
        .reconciled = reconciled,
        .native_pages = owned_native_pages,
        .layout_blocks = owned_layout_blocks,
        .page_routes = owned_page_routes,
        .region_routes = owned_region_routes,
        .trace_records = owned_trace_records,
        .ocr_attempts = owned_ocr_attempts,
        .formula_attempts = empty_formula_attempts,
        .formula_artifacts = empty_formula_artifacts,
        .form_fields = form_fields,
        .tables = owned_tables,
        .reading_order_pages = owned_reading_order_pages,
    };
    if (options.formula_specialist) |config| {
        try executeFormulaSpecialists(allocator, document, &result, config, options.specialist_context, options.reconcile_options);
    }
    return result;
}

fn freeFormulaAttempts(allocator: std.mem.Allocator, attempts: []FormulaAttempt) void {
    freeFormulaAttemptItems(allocator, attempts);
    allocator.free(attempts);
}

fn freeFormulaAttemptItems(allocator: std.mem.Allocator, attempts: []FormulaAttempt) void {
    for (attempts) |attempt| {
        allocator.free(attempt.request_id);
        allocator.free(attempt.specialist_id);
        if (attempt.diagnostic_code) |code| allocator.free(code);
        allocator.free(attempt.stderr_excerpt);
    }
}

fn freeFormulaArtifacts(allocator: std.mem.Allocator, artifacts: []FormulaArtifact) void {
    freeFormulaArtifactItems(allocator, artifacts);
    allocator.free(artifacts);
}

fn freeReadingOrderPages(allocator: std.mem.Allocator, pages: []PageReadingOrder) void {
    freeReadingOrderPageItems(pages);
    allocator.free(pages);
}

fn freeReadingOrderPageItems(pages: []PageReadingOrder) void {
    for (pages) |*page| page.deinit();
}

fn freeFormulaArtifactItems(allocator: std.mem.Allocator, artifacts: []FormulaArtifact) void {
    for (artifacts) |artifact| {
        allocator.free(artifact.request_id);
        allocator.free(artifact.formula_id);
        allocator.free(artifact.text);
        allocator.free(artifact.format);
        allocator.free(artifact.specialist_id);
    }
}

fn executeFormulaSpecialists(
    allocator: std.mem.Allocator,
    document: anytype,
    result: *Result,
    config: specialists.SpecialistConfig,
    context: specialist_protocol.RenderContext,
    reconcile_options: ReconcileOptions,
) !void {
    var attempts: std.ArrayList(FormulaAttempt) = .empty;
    errdefer {
        freeFormulaAttemptItems(allocator, attempts.items);
        attempts.deinit(allocator);
    }
    var artifacts: std.ArrayList(FormulaArtifact) = .empty;
    errdefer {
        freeFormulaArtifactItems(allocator, artifacts.items);
        artifacts.deinit(allocator);
    }

    for (result.region_routes, 0..) |route, route_index| {
        if (!route.route.needs_formula_model) continue;
        const request_id = try specialist_protocol.allocRequestId(allocator, .formula, route.page_index, route.region_index);
        errdefer allocator.free(request_id);
        var crop_outcome = try document.rasterizeFormulaRegionDetailed(allocator, route.page_index, route.bbox, config);
        defer crop_outcome.deinit(allocator);
        const crop_input = crop_outcome.input;
        var execution = if (crop_input) |crop| blk: {
            var crop_context = context;
            crop_context.crop_geometry = .{
                .pixel_to_pdf = crop.pixel_to_pdf,
                .rasterizer_dpi = crop.rasterizer_dpi,
                .pixel_width = crop.pixel_width,
                .pixel_height = crop.pixel_height,
            };
            const request_jsonl = try specialist_protocol.renderRegionRequestJsonl(allocator, result, crop_context, route_index, crop.image_path);
            defer allocator.free(request_jsonl);
            var completed = try specialists.runFormulaJsonl(
                allocator,
                request_jsonl,
                request_id,
                specialist_protocol.schema_version,
                config,
            );
            completed.duration_ms += crop_outcome.duration_ms;
            break :blk completed;
        } else try specialists.makeFormulaFailure(
            allocator,
            crop_outcome.status,
            crop_outcome.duration_ms,
            crop_outcome.diagnostic_code orelse "formula_crop_failed",
            "formula-rasterizer",
            crop_outcome.exit_code,
            crop_outcome.stderr,
        );
        defer execution.deinit(allocator);

        for (execution.artifacts, 0..) |artifact, artifact_index| {
            const artifact_request_id = try allocator.dupe(u8, request_id);
            errdefer allocator.free(artifact_request_id);
            const formula_id = try std.fmt.allocPrint(allocator, "formula-region-{d}-{d}", .{ route.region_index, artifact_index });
            errdefer allocator.free(formula_id);
            const text = try allocator.dupe(u8, artifact.text);
            errdefer allocator.free(text);
            const format = try allocator.dupe(u8, artifact.format);
            errdefer allocator.free(format);
            const artifact_specialist_id = try allocator.dupe(u8, execution.specialist_id);
            errdefer allocator.free(artifact_specialist_id);
            try artifacts.append(allocator, .{
                .request_id = artifact_request_id,
                .formula_id = formula_id,
                .page_index = route.page_index,
                .region_index = route.region_index,
                .text = text,
                .format = format,
                .confidence = artifact.confidence,
                .specialist_id = artifact_specialist_id,
            });
        }

        const specialist_id = try allocator.dupe(u8, execution.specialist_id);
        errdefer allocator.free(specialist_id);
        const diagnostic_code = if (execution.diagnostic_code) |code| try allocator.dupe(u8, code) else null;
        errdefer if (diagnostic_code) |code| allocator.free(code);
        const stderr_excerpt = try allocator.dupe(u8, execution.stderr_excerpt);
        errdefer allocator.free(stderr_excerpt);
        try attempts.append(allocator, .{
            .request_id = request_id,
            .page_index = route.page_index,
            .region_index = route.region_index,
            .status = switch (execution.status) {
                .completed => .completed,
                .empty => .empty,
                .unavailable => .unavailable,
                .failed => .failed,
                .timeout => .timeout,
                .invalid_output => .invalid_output,
            },
            .specialist_id = specialist_id,
            .duration_ms = execution.duration_ms,
            .exit_code = execution.exit_code,
            .diagnostic_code = diagnostic_code,
            .stderr_excerpt = stderr_excerpt,
            .crop_backed = crop_input != null,
            .crop_bbox = if (crop_input) |crop| crop.pdf_bbox else null,
            .crop_dpi = if (crop_input) |crop| crop.dpi else null,
            .crop_pixel_width = if (crop_input) |crop| crop.pixel_width else null,
            .crop_pixel_height = if (crop_input) |crop| crop.pixel_height else null,
            .crop_pixel_to_pdf = if (crop_input) |crop| crop.pixel_to_pdf else null,
            .crop_rasterizer_dpi = if (crop_input) |crop| crop.rasterizer_dpi else null,
        });
    }

    const owned_attempts = try attempts.toOwnedSlice(allocator);
    errdefer freeFormulaAttempts(allocator, owned_attempts);
    const owned_artifacts = try artifacts.toOwnedSlice(allocator);
    errdefer freeFormulaArtifacts(allocator, owned_artifacts);
    try reconcile.applyFormulaArtifacts(&result.reconciled, owned_artifacts, result.region_routes, reconcile_options);
    allocator.free(result.formula_attempts);
    allocator.free(result.formula_artifacts);
    result.formula_attempts = owned_attempts;
    result.formula_artifacts = owned_artifacts;
}

fn freeTextSpanPages(allocator: std.mem.Allocator, pages: [][]layout.TextSpan) void {
    for (pages) |spans| freeTextSpans(allocator, spans);
    allocator.free(pages);
}

fn suppressLayoutSpecialists(route: *RouteDecision, mask: *RouteReasonMask) void {
    route.native_fast_path = false;
    route.needs_layout_model = false;
    route.needs_table_model = false;
    route.needs_formula_model = false;
    mask.* &= ~(reasonBit(.low_reading_order_confidence) |
        reasonBit(.table_alignment) |
        reasonBit(.formula_density) |
        reasonBit(.layout_route_stub) |
        reasonBit(.table_route_stub) |
        reasonBit(.formula_route_stub));
}

fn collectFormFields(allocator: std.mem.Allocator, document: anytype) ![]FormField {
    const DocumentPtr = @TypeOf(document);
    const document_info = @typeInfo(DocumentPtr);
    if (document_info != .pointer) return allocator.alloc(FormField, 0);
    const DocumentType = document_info.pointer.child;
    if (!@hasDecl(DocumentType, "getFormFields") or !@hasDecl(DocumentType, "freeFormFields")) {
        return allocator.alloc(FormField, 0);
    }

    const source_fields = try document.getFormFields(allocator);
    defer DocumentType.freeFormFields(allocator, source_fields);

    var fields: std.ArrayList(FormField) = .empty;
    errdefer {
        for (fields.items) |field| freeFormField(allocator, field);
        fields.deinit(allocator);
    }

    for (source_fields) |field| {
        const copied_name = try allocator.dupe(u8, field.name);
        errdefer allocator.free(copied_name);

        const copied_value = if (field.value) |value| try allocator.dupe(u8, value) else null;
        errdefer if (copied_value) |value| allocator.free(value);

        const copied_type = try allocator.dupe(u8, @tagName(field.field_type));
        errdefer allocator.free(copied_type);

        try fields.append(allocator, .{
            .name = copied_name,
            .value = copied_value,
            .field_type = copied_type,
            .rect = field.rect,
        });
    }

    return fields.toOwnedSlice(allocator);
}

fn freeFormFields(allocator: std.mem.Allocator, fields: []FormField) void {
    for (fields) |field| freeFormField(allocator, field);
    allocator.free(fields);
}

fn freeFormField(allocator: std.mem.Allocator, field: FormField) void {
    allocator.free(field.name);
    if (field.value) |value| allocator.free(value);
    allocator.free(field.field_type);
}

fn copyTableGrid(allocator: std.mem.Allocator, source: layout.TableGrid) !layout.TableGrid {
    const source_ids = try allocator.dupe(u32, source.source_span_indices);
    errdefer allocator.free(source_ids);
    const block_ids = try allocator.dupe(u32, source.member_block_indices);
    errdefer allocator.free(block_ids);
    const rows = try allocator.alloc(layout.TableRow, source.rows.len);
    var completed_rows: usize = 0;
    errdefer {
        for (rows[0..completed_rows]) |row| {
            for (row.cells) |cell| allocator.free(@constCast(cell.text));
            allocator.free(row.cells);
        }
        allocator.free(rows);
    }

    for (source.rows, 0..) |row, row_index| {
        rows[row_index] = try copyTableRow(allocator, row);
        completed_rows += 1;
    }

    var copied_table = source;
    copied_table.rows = rows;
    copied_table.source_span_indices = source_ids;
    copied_table.member_block_indices = block_ids;
    return copied_table;
}

fn copyTableRow(allocator: std.mem.Allocator, source: layout.TableRow) !layout.TableRow {
    const cells = try allocator.alloc(layout.TableCell, source.cells.len);
    var completed_cells: usize = 0;
    errdefer {
        for (cells[0..completed_cells]) |cell| allocator.free(@constCast(cell.text));
        allocator.free(cells);
    }

    for (source.cells, 0..) |cell, cell_index| {
        var copied = cell;
        copied.text = try allocator.dupe(u8, cell.text);
        cells[cell_index] = copied;
        completed_cells += 1;
    }

    var copied_row = source;
    copied_row.cells = cells;
    return copied_row;
}

fn freeOwnedTables(allocator: std.mem.Allocator, tables: []layout.TableGrid) void {
    freeOwnedTableItems(allocator, tables);
    allocator.free(tables);
}

fn freeOwnedTableItems(allocator: std.mem.Allocator, tables: []layout.TableGrid) void {
    for (tables) |table| {
        for (table.rows) |row| {
            for (row.cells) |cell| allocator.free(@constCast(cell.text));
            allocator.free(row.cells);
        }
        allocator.free(table.rows);
        if (table.source_span_indices.len > 0) allocator.free(table.source_span_indices);
        if (table.member_block_indices.len > 0) allocator.free(table.member_block_indices);
    }
}

fn linkLogicalTables(tables: []layout.TableGrid) void {
    for (tables, 0..) |*table, index| {
        table.logical_table_index = @intCast(index);
        table.table_part_index = 0;
        table.continued_from_table_index = null;
        table.continued_to_table_index = null;
    }

    if (tables.len < 2) return;

    for (1..tables.len) |index| {
        const previous_index = index - 1;
        if (!tablesLikelyContinue(tables[previous_index], tables[index])) continue;

        const logical_index = tables[previous_index].logical_table_index orelse @as(u32, @intCast(previous_index));
        tables[index].logical_table_index = logical_index;
        tables[index].table_part_index = tables[previous_index].table_part_index + 1;
        tables[index].continued_from_table_index = @intCast(previous_index);
        tables[previous_index].continued_to_table_index = @intCast(index);
    }
}

fn tablesLikelyContinue(previous: layout.TableGrid, current: layout.TableGrid) bool {
    if (current.page_index <= previous.page_index) return false;
    if (current.column_count == 0 or previous.column_count != current.column_count) return false;
    if (!tableHeadersMatch(previous, current)) return false;

    const previous_width = @max(1.0, previous.bounds.x1 - previous.bounds.x0);
    const current_width = @max(1.0, current.bounds.x1 - current.bounds.x0);
    const width_delta = @abs(previous_width - current_width);
    const left_delta = @abs(previous.bounds.x0 - current.bounds.x0);
    return left_delta <= 18.0 and width_delta <= @max(24.0, previous_width * 0.08);
}

fn tableHeadersMatch(previous: layout.TableGrid, current: layout.TableGrid) bool {
    const previous_header = firstHeaderRow(previous) orelse return false;
    const current_header = firstHeaderRow(current) orelse return false;
    if (previous_header.cells.len != current_header.cells.len) return false;

    var comparable_cells: usize = 0;
    var matched_cells: usize = 0;
    for (previous_header.cells, current_header.cells) |prev_cell, curr_cell| {
        if (prev_cell.text.len == 0 and curr_cell.text.len == 0) continue;
        comparable_cells += 1;
        if (std.ascii.eqlIgnoreCase(prev_cell.text, curr_cell.text)) matched_cells += 1;
    }
    return comparable_cells > 0 and matchedCellsEnough(matched_cells, comparable_cells);
}

fn firstHeaderRow(table: layout.TableGrid) ?layout.TableRow {
    for (table.rows) |row| {
        var header_cells: usize = 0;
        var text_cells: usize = 0;
        for (row.cells) |cell| {
            if (cell.text.len == 0) continue;
            text_cells += 1;
            if (cell.role == .header) header_cells += 1;
        }
        if (text_cells > 0 and header_cells * 2 >= text_cells) return row;
    }
    return null;
}

fn matchedCellsEnough(matched_cells: usize, comparable_cells: usize) bool {
    return matched_cells == comparable_cells or matched_cells * 100 >= comparable_cells * 75;
}

fn formFieldsToSpans(allocator: std.mem.Allocator, fields: []const FormField) ![]layout.TextSpan {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| freeOwnedTextSpan(allocator, span);
        spans.deinit(allocator);
    }

    for (fields) |field| {
        const value = field.value orelse continue;
        if (field.name.len == 0 or value.len == 0) continue;

        var text = try std.ArrayList(u8).initCapacity(allocator, field.name.len + 1 + value.len);
        errdefer text.deinit(allocator);
        try text.appendSlice(allocator, field.name);
        try text.append(allocator, ' ');
        try text.appendSlice(allocator, value);
        const owned_text = try text.toOwnedSlice(allocator);
        errdefer allocator.free(owned_text);

        const bbox = if (field.rect) |rect|
            BBox{ .x0 = rect[0], .y0 = rect[1], .x1 = rect[2], .y1 = rect[3] }
        else
            BBox{ .x0 = 36, .y0 = 36, .x1 = 576, .y1 = 50 };

        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = bbox,
            .text = owned_text,
            .source = .manual,
            .confidence = 1.0,
            .font = .{ .size = 10 },
        }));
    }

    return spans.toOwnedSlice(allocator);
}

fn filterOcrSpansForPage(
    allocator: std.mem.Allocator,
    ocr_spans: []layout.TextSpan,
    native_spans: []const layout.TextSpan,
    images: []const complexity.ImageBox,
) ![]layout.TextSpan {
    if (ocr_spans.len == 0 or native_spans.len == 0 or images.len == 0) return ocr_spans;

    var input_owned = true;
    errdefer if (input_owned) ocr.freeSpans(allocator, ocr_spans);
    var kept = try std.ArrayList(layout.TextSpan).initCapacity(allocator, ocr_spans.len);
    errdefer {
        for (kept.items) |span| allocator.free(@constCast(span.text));
        kept.deinit(allocator);
    }

    for (ocr_spans) |span| {
        if (spanOverlapsAnyImage(span, images)) {
            kept.appendAssumeCapacity(span);
        } else {
            allocator.free(@constCast(span.text));
        }
    }
    allocator.free(ocr_spans);
    input_owned = false;
    return kept.toOwnedSlice(allocator);
}

fn buildPageSpanView(
    allocator: std.mem.Allocator,
    native_spans: []const layout.TextSpan,
    maybe_ocr_spans: ?[]layout.TextSpan,
) ![]layout.TextSpan {
    const ocr_spans: []const layout.TextSpan = if (maybe_ocr_spans) |spans| spans else &.{};
    const merged = try allocator.alloc(layout.TextSpan, native_spans.len + ocr_spans.len);
    @memcpy(merged[0..native_spans.len], native_spans);
    @memcpy(merged[native_spans.len..], ocr_spans);
    return merged;
}

fn filterSubsumedOcrSpanView(
    allocator: std.mem.Allocator,
    ocr_spans: []const layout.TextSpan,
    represented_spans: []const layout.TextSpan,
) ![]layout.TextSpan {
    var kept = try std.ArrayList(layout.TextSpan).initCapacity(allocator, ocr_spans.len);
    errdefer kept.deinit(allocator);
    for (ocr_spans) |ocr_span| {
        var represented = false;
        for (represented_spans) |candidate| {
            if (spanSubsumesOcr(candidate, ocr_span)) {
                represented = true;
                break;
            }
        }
        if (!represented) kept.appendAssumeCapacity(ocr_span);
    }
    return kept.toOwnedSlice(allocator);
}

fn spanSubsumesOcr(represented: layout.TextSpan, ocr_span: layout.TextSpan) bool {
    if (represented.page_index != ocr_span.page_index) return false;
    const ocr_area = width(ocr_span.bbox) * height(ocr_span.bbox);
    if (ocr_area <= 0 or overlapArea(represented.bbox, ocr_span.bbox) / ocr_area < 0.65) return false;

    const needle = std.mem.trim(u8, ocr_span.text, " \t\r\n");
    if (needle.len == 0 or represented.text.len < needle.len) return false;
    const offset = std.ascii.findIgnoreCase(represented.text, needle) orelse return false;
    const before_ok = offset == 0 or std.ascii.isWhitespace(represented.text[offset - 1]);
    const after = offset + needle.len;
    const after_ok = after == represented.text.len or std.ascii.isWhitespace(represented.text[after]);
    return before_ok and after_ok;
}

fn usesRegionalOcr(route: PageRoute, native_quality_pass: bool) bool {
    return route.image_count > 0 and route.span_count > 0 and native_quality_pass and
        route.signals.bad_unicode < 0.35 and route.signals.hidden_ocr < 0.45;
}

fn suppressDerivedOcr(route: *RegionRoute, input: complexity.PageInput, image_routes: []const RegionRoute) void {
    if (!route.route.needs_ocr or route.image_count == 0) return;
    // Score the original native evidence: newly recognized spans may carry an
    // OCR font name or lower confidence, neither of which requests another OCR
    // pass over the same crop. Missing ToUnicode alone is not broken text.
    const native_score = complexity.scoreRegion(input, route.bbox);
    if (native_score.signals.hidden_ocr >= 0.45 or native_score.signals.bad_unicode >= 0.35) return;
    // Only suppress an image-driven duplicate when every intersecting image
    // already has its own requested crop. A crop elsewhere on the page cannot
    // explain a hidden or damaged text region.
    var matched_image = false;
    for (input.images) |image| {
        if (overlapArea(route.bbox, image.bbox) <= 0) continue;
        var owned = false;
        for (image_routes) |owner| {
            if (owner.page_index == route.page_index and owner.route.needs_ocr and
                owner.bbox.x0 <= image.bbox.x0 and owner.bbox.y0 <= image.bbox.y0 and
                owner.bbox.x1 >= image.bbox.x1 and owner.bbox.y1 >= image.bbox.y1)
            {
                owned = true;
                break;
            }
        }
        if (!owned) return;
        matched_image = true;
    }
    if (!matched_image) return;
    route.route.needs_ocr = false;
    route.reason_mask &= ~reasonBit(.ocr_route_stub);
}

fn recognizeOcrTarget(
    document: anytype,
    allocator: std.mem.Allocator,
    attempts: *std.ArrayList(OcrAttempt),
    options: ExtractOptions,
    page_idx: usize,
    page_bbox: BBox,
    region_id: ?u32,
    spans: []const layout.TextSpan,
    image_boxes: []const complexity.ImageBox,
    attempt_count: *usize,
) !?[]layout.TextSpan {
    const page_index: u32 = @intCast(page_idx);
    if (!options.enable_ocr) {
        _ = try appendOcrAttempt(allocator, attempts, options.ocr_config, .{
            .attempt_index = 0,
            .page_index = page_index,
            .status = .not_invoked,
            .page_bbox = page_bbox,
            .region_index = region_id,
            .crop_bbox = if (region_id != null) page_bbox else null,
            .diagnostic_code = .ocr_disabled,
        });
    } else {
        var best_spans: ?[]layout.TextSpan = null;
        errdefer if (best_spans) |owned| ocr.freeSpans(allocator, owned);
        var best_attempt_index: ?usize = null;
        const configured_attempts: usize = if (options.ocr_config.policy == .bounded)
            @max(1, @min(@as(usize, options.ocr_config.max_attempts), 2))
        else
            1;

        for (0..configured_attempts) |attempt_index| {
            var attempt_config = options.ocr_config;
            if (attempt_index > 0) {
                attempt_config.dpi = options.ocr_config.fallback_dpi;
                attempt_config.psm = options.ocr_config.fallback_psm;
            }

            if (attempt_count.* >= options.ocr_config.max_attempts_per_page) {
                _ = try appendOcrAttempt(allocator, attempts, attempt_config, .{
                    .attempt_index = @intCast(attempt_index),
                    .page_index = page_index,
                    .region_index = region_id,
                    .page_bbox = page_bbox,
                    .crop_bbox = if (region_id != null) page_bbox else null,
                    .status = .not_invoked,
                    .diagnostic_code = .ocr_attempt_limit,
                });
                break;
            }
            attempt_count.* += 1;
            var raster_outcome = if (region_id != null)
                try document.rasterizeOcrRegionDetailed(allocator, page_idx, page_bbox, attempt_config)
            else
                try document.rasterizePageForOcrDetailed(allocator, page_idx, attempt_config);
            defer raster_outcome.deinit(allocator);
            if (raster_outcome.status != .completed or raster_outcome.input == null) {
                _ = try appendOcrAttempt(allocator, attempts, attempt_config, .{
                    .attempt_index = @intCast(attempt_index),
                    .page_index = page_index,
                    .status = raster_outcome.status,
                    .page_bbox = page_bbox,
                    .region_index = region_id,
                    .crop_bbox = if (region_id != null) page_bbox else null,
                    .failure_stage = .rasterize,
                    .duration_ms = raster_outcome.duration_ms,
                    .exit_code = raster_outcome.exit_code,
                    .diagnostic_code = raster_outcome.diagnostic_code,
                    .stderr = raster_outcome.stderr,
                });
                break;
            }

            const ocr_input = raster_outcome.input.?;
            defer {
                runtime.deleteFileCwd(ocr_input.image_path);
                allocator.free(@constCast(ocr_input.image_path));
            }

            var recognition = try ocr.recognizeRegionDetailed(allocator, ocr_input, attempt_config);
            defer recognition.deinit(allocator);
            if (recognition.status != .completed and recognition.status != .empty) {
                _ = try appendOcrAttempt(allocator, attempts, attempt_config, .{
                    .attempt_index = @intCast(attempt_index),
                    .page_index = page_index,
                    .status = recognition.status,
                    .page_bbox = page_bbox,
                    .region_index = region_id,
                    .failure_stage = .recognize,
                    .duration_ms = raster_outcome.duration_ms + recognition.duration_ms,
                    .pixel_width = ocr_input.pixel_width,
                    .pixel_height = ocr_input.pixel_height,
                    .pixel_to_pdf = ocr_input.pixel_to_pdf,
                    .rasterizer_dpi = ocr_input.rasterizer_dpi,
                    .crop_bbox = if (region_id != null) ocr_input.pdf_bbox else null,
                    .crop_image_sha256 = if (region_id != null) ocr_input.image_sha256 else null,
                    .crop_image_byte_length = if (region_id != null) ocr_input.image_byte_length else null,
                    .exit_code = recognition.exit_code,
                    .diagnostic_code = recognition.diagnostic_code,
                    .stderr = recognition.stderr,
                });
                break;
            }

            const raw_ocr_spans = recognition.spans;
            recognition.spans = &.{};
            const candidate_spans = try filterOcrSpansForPage(allocator, raw_ocr_spans, spans, image_boxes);
            errdefer ocr.freeSpans(allocator, candidate_spans);
            const recorded_index = try appendOcrAttempt(allocator, attempts, attempt_config, .{
                .attempt_index = @intCast(attempt_index),
                .page_index = page_index,
                .status = if (candidate_spans.len > 0) .completed else .empty,
                .page_bbox = page_bbox,
                .region_index = region_id,
                .duration_ms = raster_outcome.duration_ms + recognition.duration_ms,
                .pixel_width = ocr_input.pixel_width,
                .pixel_height = ocr_input.pixel_height,
                .pixel_to_pdf = ocr_input.pixel_to_pdf,
                .rasterizer_dpi = ocr_input.rasterizer_dpi,
                .crop_bbox = if (region_id != null) ocr_input.pdf_bbox else null,
                .crop_image_sha256 = if (region_id != null) ocr_input.image_sha256 else null,
                .crop_image_byte_length = if (region_id != null) ocr_input.image_byte_length else null,
                .spans = candidate_spans,
                .exit_code = recognition.exit_code,
                .stderr = if (recognition.stderr.len > 0) recognition.stderr else raster_outcome.stderr,
            });

            if (best_attempt_index == null or betterOcrAttempt(attempts.items[recorded_index], attempts.items[best_attempt_index.?])) {
                if (best_spans) |owned| ocr.freeSpans(allocator, owned);
                best_spans = candidate_spans;
                best_attempt_index = recorded_index;
            } else {
                ocr.freeSpans(allocator, candidate_spans);
            }

            if (attempt_index + 1 >= configured_attempts or !shouldRetryOcrAttempt(attempts.items[recorded_index], options.ocr_config)) break;
        }

        if (best_attempt_index) |selected_index| {
            attempts.items[selected_index].selected = true;
            const selected_spans = best_spans.?;
            best_spans = null;
            return selected_spans;
        }
    }

    return null;
}

fn selectedOcrPageQualityPass(attempts: []const OcrAttempt, page_index: u32) bool {
    for (attempts) |attempt| {
        if (attempt.page_index == page_index and attempt.region_index == null and attempt.selected) {
            return attempt.status == .completed and attempt.span_count > 0 and attempt.character_count > 0;
        }
    }
    return false;
}

fn spanOverlapsAnyImage(span: layout.TextSpan, images: []const complexity.ImageBox) bool {
    const span_area = width(span.bbox) * height(span.bbox);
    if (span_area <= 0) return false;
    for (images) |image| {
        const overlap = overlapArea(span.bbox, image.bbox);
        if (overlap / span_area >= 0.50) return true;
    }
    return false;
}

fn overlapArea(a: BBox, b: BBox) f64 {
    const x0 = @max(a.x0, b.x0);
    const y0 = @max(a.y0, b.y0);
    const x1 = @min(a.x1, b.x1);
    const y1 = @min(a.y1, b.y1);
    if (x1 <= x0 or y1 <= y0) return 0;
    return (x1 - x0) * (y1 - y0);
}

fn reorderSpansToLayoutOrder(spans: []layout.TextSpan, ordered: []const layout.TextSpan) void {
    if (spans.len != ordered.len) return;
    @memcpy(spans, ordered);
}

const RankedReadableSpan = struct {
    span: layout.TextSpan,
    block_rank: usize,
    original_index: usize,
};

fn copyGraphNodeTexts(
    allocator: std.mem.Allocator,
    blocks: []const layout.LayoutBlock,
    graph: *const reading_order_graph.PageReadingOrderGraph,
) ![][]u8 {
    const texts = try allocator.alloc([]u8, graph.nodes.len);
    var initialized: usize = 0;
    errdefer {
        for (texts[0..initialized]) |text| allocator.free(text);
        allocator.free(texts);
    }

    for (graph.nodes, 0..) |node, node_index| {
        if (node.original_block_index >= blocks.len) return error.InvalidReadingOrderProjection;
        texts[node_index] = try layoutBlockTextOwned(allocator, &blocks[node.original_block_index]);
        initialized += 1;
    }
    return texts;
}

fn copyReadingOrderBlocks(
    allocator: std.mem.Allocator,
    page_index: u32,
    source_blocks: []const layout.LayoutBlock,
) ![]ReadingOrderBlock {
    const blocks = try allocator.alloc(ReadingOrderBlock, source_blocks.len);
    var initialized: usize = 0;
    errdefer {
        for (blocks[0..initialized]) |block| allocator.free(block.text);
        allocator.free(blocks);
    }

    for (source_blocks, 0..) |*block, block_index| {
        blocks[block_index] = .{
            .page_index = page_index,
            .original_block_index = @intCast(block_index),
            .bounds = block.bounds.bbox,
            .kind = block.kind,
            .column_index = block.column_index,
            .removed = block.removed,
            .text = try layoutBlockTextOwned(allocator, block),
        };
        initialized += 1;
    }
    return blocks;
}

fn copyReadingOrderRegions(
    allocator: std.mem.Allocator,
    page_index: u32,
    source_regions: []const reading_order_regions.RegionNode,
) ![]ReadingOrderRegion {
    const regions = try allocator.alloc(ReadingOrderRegion, source_regions.len);
    for (source_regions, regions) |source, *region| {
        region.* = .{
            .page_index = page_index,
            .id = source.id,
            .parent_id = source.parent_id,
            .kind = source.kind,
            .bounds = source.bounds,
            .source_span_count = source.source_span_count,
        };
    }
    return regions;
}

fn copyReadingOrderSourceSpans(
    allocator: std.mem.Allocator,
    page_index: u32,
    source_spans: []const layout.TextSpan,
) ![]ReadingOrderSourceSpan {
    const spans = try allocator.alloc(ReadingOrderSourceSpan, source_spans.len);
    var initialized: usize = 0;
    errdefer {
        for (spans[0..initialized]) |span| allocator.free(span.text);
        allocator.free(spans);
    }
    for (source_spans, 0..) |source_span, span_index| {
        spans[span_index] = .{
            .page_index = page_index,
            .span_index = @intCast(span_index),
            .bounds = source_span.bbox,
            .font_size = source_span.font_size,
            .text = try allocator.dupe(u8, source_span.text),
        };
        initialized += 1;
    }
    return spans;
}

fn layoutBlockTextOwned(allocator: std.mem.Allocator, block: *const layout.LayoutBlock) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (block.lines) |*line| {
        const owned_line = try lineTextOwned(allocator, line);
        defer allocator.free(owned_line);
        if (owned_line.len == 0) continue;
        if (text.items.len > 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, owned_line);
    }
    return text.toOwnedSlice(allocator);
}

fn freeOwnedStrings(allocator: std.mem.Allocator, strings: [][]u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

fn freeReadingOrderBlocks(allocator: std.mem.Allocator, blocks: []ReadingOrderBlock) void {
    for (blocks) |block| allocator.free(block.text);
    allocator.free(blocks);
}

fn freeReadingOrderSourceSpans(allocator: std.mem.Allocator, spans: []ReadingOrderSourceSpan) void {
    for (spans) |span| allocator.free(span.text);
    allocator.free(spans);
}

fn horizontalLeftToRight(spans: []const layout.TextSpan) bool {
    for (spans) |span| {
        if (span.writing_mode != 0) return false;
        var offset: usize = 0;
        while (offset < span.text.len) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(span.text[offset]) catch return false;
            const length: usize = @intCast(sequence_len);
            if (offset + length > span.text.len) return false;
            const codepoint = std.unicode.utf8Decode(span.text[offset .. offset + length]) catch return false;
            if ((codepoint >= 0x0590 and codepoint <= 0x08ff) or
                (codepoint >= 0xfb1d and codepoint <= 0xfdff) or
                (codepoint >= 0xfe70 and codepoint <= 0xfeff))
            {
                return false;
            }
            offset += length;
        }
    }
    return true;
}

fn reorderSpansByGraph(
    allocator: std.mem.Allocator,
    readable_spans: []layout.TextSpan,
    page_layout: *const layout.LayoutResult,
    graph: *const reading_order_graph.PageReadingOrderGraph,
    apply_projection: bool,
) !bool {
    if (readable_spans.len == 0) return graph.nodes.len == 0;
    if (graph.projected_block_order.len != graph.nodes.len) return false;

    const no_rank = std.math.maxInt(usize);
    const block_ranks = try allocator.alloc(usize, page_layout.blocks.len);
    defer allocator.free(block_ranks);
    @memset(block_ranks, no_rank);
    for (graph.projected_block_order, 0..) |block_index, rank| {
        if (block_index >= block_ranks.len or block_ranks[block_index] != no_rank) return false;
        block_ranks[block_index] = rank;
    }

    const mapped_blocks = try allocator.alloc(usize, readable_spans.len);
    defer allocator.free(mapped_blocks);
    for (readable_spans, 0..) |span, span_index| {
        const span_area = overlapArea(span.bbox, span.bbox);
        if (span_area <= 0) return false;
        const center_x = (span.bbox.x0 + span.bbox.x1) / 2.0;
        const center_y = (span.bbox.y0 + span.bbox.y1) / 2.0;
        var best_block: ?usize = null;
        var best_coverage: f64 = 0;
        var ambiguous = false;

        for (page_layout.blocks, 0..) |block, block_index| {
            const bounds = block.bounds.bbox;
            const epsilon = 0.5;
            if (center_x < bounds.x0 - epsilon or center_x > bounds.x1 + epsilon or
                center_y < bounds.y0 - epsilon or center_y > bounds.y1 + epsilon)
            {
                continue;
            }

            var covered_area: f64 = 0;
            for (block.lines) |line| {
                for (line.words) |word| {
                    for (word.spans) |leaf| {
                        covered_area += overlapArea(span.bbox, leaf.bbox);
                    }
                }
            }
            const coverage = @min(1.0, covered_area / span_area);
            if (coverage < 0.90) continue;
            if (coverage > best_coverage + 0.000001) {
                best_block = block_index;
                best_coverage = coverage;
                ambiguous = false;
            } else if (@abs(coverage - best_coverage) <= 0.000001) {
                ambiguous = true;
            }
        }
        if (ambiguous or best_block == null) return false;
        mapped_blocks[span_index] = best_block.?;
    }

    var live_positions: std.ArrayList(usize) = .empty;
    defer live_positions.deinit(allocator);
    var ranked: std.ArrayList(RankedReadableSpan) = .empty;
    defer ranked.deinit(allocator);
    for (readable_spans, mapped_blocks, 0..) |span, block_index, original_index| {
        if (page_layout.blocks[block_index].removed) continue;
        const block_rank = block_ranks[block_index];
        if (block_rank == no_rank) return false;
        try live_positions.append(allocator, original_index);
        try ranked.append(allocator, .{
            .span = span,
            .block_rank = block_rank,
            .original_index = original_index,
        });
    }

    std.mem.sort(RankedReadableSpan, ranked.items, {}, struct {
        fn lessThan(_: void, left: RankedReadableSpan, right: RankedReadableSpan) bool {
            if (left.block_rank != right.block_rank) return left.block_rank < right.block_rank;
            return left.original_index < right.original_index;
        }
    }.lessThan);
    if (apply_projection) {
        for (live_positions.items, ranked.items) |position, item| readable_spans[position] = item.span;
    }
    return true;
}

fn buildLayoutLayerSpans(
    allocator: std.mem.Allocator,
    page_layout: *const layout.LayoutResult,
    projected_block_order: ?[]const u32,
) ![]layout.TextSpan {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }
    const emitted = try allocator.alloc(bool, page_layout.tables.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    if (projected_block_order) |order| {
        for (order) |block_index| {
            if (block_index >= page_layout.blocks.len) return error.InvalidReadingOrderProjection;
            try appendLayoutBlockSpans(allocator, &spans, page_layout, block_index, emitted);
        }
    } else {
        for (page_layout.blocks, 0..) |_, block_index| {
            try appendLayoutBlockSpans(allocator, &spans, page_layout, block_index, emitted);
        }
    }

    return spans.toOwnedSlice(allocator);
}

fn appendLayoutBlockSpans(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    page_layout: *const layout.LayoutResult,
    block_index: usize,
    emitted: []bool,
) !void {
    const block = page_layout.blocks[block_index];
    if (block.lines.len == 0) return;
    if (page_layout.hasOwnedTables()) {
        for (block.lines) |line| for (line.words) |word| for (word.spans) |leaf| {
            if (page_layout.tableRegionForSpan(leaf)) |table_index| {
                if (!emitted[table_index]) {
                    try appendTableCellSpans(allocator, spans, &page_layout.tables[table_index]);
                    emitted[table_index] = true;
                }
            } else {
                var span = leaf;
                span.preserve_source_identity = true;
                span.text = try allocator.dupe(u8, leaf.text);
                errdefer allocator.free(@constCast(span.text));
                span.font = stableFont(leaf.font);
                try spans.append(allocator, span);
            }
        };
        return;
    }
    // The table layer replaces the native page layer. Furniture suppression
    // is a text-rendering choice, not authority to erase that source evidence.

    if (page_layout.tableForBlock(block_index)) |table| {
        if (tableHasUsefulTextRows(table)) {
            try appendBlockLinesOutsideTable(allocator, spans, block, table, true);
            try appendTableCellSpans(allocator, spans, table);
            try appendBlockLinesOutsideTable(allocator, spans, block, table, false);
            return;
        }
    }
    if (page_layout.blockCoveredByTable(block_index)) {
        var skip_covered = false;
        if (tableCoveringBlock(page_layout.tables, block_index)) |table| {
            skip_covered = tableHasUsefulTextRows(table);
        }
        if (skip_covered) {
            if (tableCoveringBlock(page_layout.tables, block_index)) |table| {
                try appendBlockLinesOutsideTable(allocator, spans, block, table, true);
                try appendBlockLinesOutsideTable(allocator, spans, block, table, false);
            }
            return;
        }
    }

    for (block.lines) |line| {
        // A reconstructed line must not erase distinct operator evidence.
        // Keep its original spans when paint differs across that line.
        var distinct_paint = false;
        for (line.words) |word| {
            for (word.spans) |span| {
                if (!std.meta.eql(span.paint, line.bounds.paint) or !std.meta.eql(span.content_scope, line.bounds.content_scope)) distinct_paint = true;
            }
        }
        if (distinct_paint) {
            for (line.words) |word| {
                for (word.spans) |source_span| {
                    var span = source_span;
                    span.preserve_source_identity = true;
                    span.text = try allocator.dupe(u8, source_span.text);
                    errdefer allocator.free(@constCast(span.text));
                    span.font = stableFont(source_span.font);
                    try spans.append(allocator, span);
                }
            }
            continue;
        }
        const text = try lineTextOwned(allocator, &line);
        errdefer allocator.free(text);
        if (text.len == 0) {
            allocator.free(text);
            continue;
        }
        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = line.bounds.page_index,
            .bbox = line.bounds.bbox,
            .text = text,
            .source = line.bounds.source,
            .confidence = block.confidence,
            .font = stableFont(line.bounds.font),
            .block_id = line.bounds.block_id,
            .line_id = line.bounds.line_id,
            .mcid = line.bounds.mcid,
            .actual_text = line.bounds.actual_text,
            .unicode_map_error = line.bounds.unicode_map_error,
            .writing_mode = line.bounds.writing_mode,
            .paint = line.bounds.paint,
            .content_scope = line.bounds.content_scope,
            .leading_boundary = line.bounds.leading_boundary,
            .preserve_source_identity = true,
        }));
    }
}

fn tableCoveringBlock(tables: []const layout.TableGrid, block_index: usize) ?*const layout.TableGrid {
    for (tables) |*table| {
        const start: usize = @intCast(table.block_index);
        if (block_index >= start and block_index < start + table.block_count) return table;
    }
    return null;
}

fn tableHasUsefulTextRows(table: *const layout.TableGrid) bool {
    return layout.tableHasUsefulRows(table.*);
}

fn appendTableCellSpans(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    table: *const layout.TableGrid,
) !void {
    for (table.rows) |row| {
        for (row.cells) |cell| {
            // A full-row bbox cannot identify which cell owns its text:
            // its center can even fall in an empty numeric cell. Retain the
            // already reconstructed cell granularity through reconciliation.
            if (std.mem.trim(u8, cell.text, " \t\r\n").len == 0) continue;
            const text = try allocator.dupe(u8, cell.text);
            errdefer allocator.free(text);
            var span = layout.TextSpan.init(.{
                .page_index = cell.bounds.page_index,
                .bbox = cell.bounds.bbox,
                .text = text,
                .source = .table_model,
                .confidence = cell.confidence,
                .font = stableFont(cell.bounds.font),
                .block_id = cell.bounds.block_id,
                .line_id = cell.bounds.line_id,
                .mcid = cell.bounds.mcid,
            });
            span.table_cell_owner = .{
                .region_index = table.region_index,
                .row_index = cell.row_index,
                .column_index = cell.column_index,
            };
            try spans.append(allocator, span);
        }
    }
}

fn appendBlockLinesOutsideTable(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    block: layout.LayoutBlock,
    table: *const layout.TableGrid,
    before: bool,
) !void {
    for (block.lines) |line| {
        if (spansIntersect(line.bounds, table.bounds)) continue;
        const above = line.bounds.y0 >= table.bounds.y1;
        if (above != before) continue;
        try appendLineSpan(allocator, spans, line, block.confidence);
    }
}

fn appendLineSpan(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(layout.TextSpan),
    line: layout.TextLine,
    confidence: f32,
) !void {
    const text = try lineTextOwned(allocator, &line);
    errdefer allocator.free(text);
    if (text.len == 0) {
        allocator.free(text);
        return;
    }
    try spans.append(allocator, layout.TextSpan.init(.{
        .preserve_source_identity = true,
        .page_index = line.bounds.page_index,
        .bbox = line.bounds.bbox,
        .text = text,
        .source = line.bounds.source,
        .confidence = confidence,
        .font = stableFont(line.bounds.font),
        .block_id = line.bounds.block_id,
        .line_id = line.bounds.line_id,
        .mcid = line.bounds.mcid,
    }));
}

fn spansIntersect(a: layout.TextSpan, b: layout.TextSpan) bool {
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
}

fn lineTextOwned(allocator: std.mem.Allocator, line: *const layout.TextLine) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var wrote = false;
    for (line.words, 0..) |word, word_index| {
        if (word_index > 0 and wrote) try output.append(allocator, ' ');
        for (word.spans) |span| {
            try output.appendSlice(allocator, span.text);
            wrote = true;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn stableFont(font: layout.FontMetadata) layout.FontMetadata {
    return .{
        .size = font.size,
        .has_to_unicode = font.has_to_unicode,
    };
}

pub fn reasonBit(reason: RouteReason) RouteReasonMask {
    return @as(RouteReasonMask, 1) << @backingInt(reason);
}

pub fn hasReason(mask: RouteReasonMask, reason: RouteReason) bool {
    return (mask & reasonBit(reason)) != 0;
}

pub fn reasonMask(score: complexity.RegionScore, specialist: ?specialists.AnalysisResult) RouteReasonMask {
    var mask: RouteReasonMask = 0;
    const route = score.route;
    const signals = score.signals;

    if (route.native_fast_path) mask |= reasonBit(.native_fast_path);
    if (signals.sparse_text >= 0.50) mask |= reasonBit(.sparse_text);
    if (signals.image_dominance >= 0.20) mask |= reasonBit(.image_dominance);
    if (signals.bad_unicode >= 0.20) mask |= reasonBit(.bad_unicode);
    if (signals.missing_tounicode >= 0.20) mask |= reasonBit(.missing_tounicode);
    if (signals.hidden_ocr >= 0.20) mask |= reasonBit(.hidden_ocr);
    if (signals.low_reading_order_confidence >= 0.20) mask |= reasonBit(.low_reading_order_confidence);
    if (signals.table_alignment >= 0.20) mask |= reasonBit(.table_alignment);
    if (signals.formula_density >= 0.20) mask |= reasonBit(.formula_density);

    if (route.needs_ocr) mask |= reasonBit(.ocr_route_stub);
    if (route.needs_layout_model) mask |= reasonBit(.layout_route_stub);
    if (route.needs_table_model) mask |= reasonBit(.table_route_stub);
    if (route.needs_formula_model) mask |= reasonBit(.formula_route_stub);

    if (specialist) |analysis| {
        if (analysis.table.needsSpecialist()) mask |= reasonBit(.table_route_stub);
        if (analysis.formula.needsSpecialist()) mask |= reasonBit(.formula_route_stub);
    }

    return mask;
}

pub fn layoutBlockSummary(page_index: u32, block_index: u32, block: layout.LayoutBlock) LayoutBlockSummary {
    return .{
        .page_index = page_index,
        .block_index = block_index,
        .column_index = block.column_index,
        .bbox = block.bounds.bbox,
        .kind = block.kind,
        .confidence = block.confidence,
        .removed = block.removed,
        .line_count = block.lines.len,
    };
}

pub fn appendRouteTraces(
    allocator: std.mem.Allocator,
    traces: *std.ArrayList(TraceRecord),
    page_index: u32,
    region_index: ?u32,
    route: RouteDecision,
    reason_mask: RouteReasonMask,
    span_count: usize,
    block_count: usize,
) !void {
    if (route.needs_ocr) {
        try traces.append(allocator, .{
            .page_index = page_index,
            .region_index = region_index,
            .stage = .ocr_route_stub,
            .route = route,
            .reason_mask = reason_mask,
            .span_count = span_count,
            .block_count = block_count,
        });
    }
    if (route.needs_table_model or hasReason(reason_mask, .table_route_stub)) {
        try traces.append(allocator, .{
            .page_index = page_index,
            .region_index = region_index,
            .stage = .table_route_stub,
            .route = route,
            .reason_mask = reason_mask,
            .span_count = span_count,
            .block_count = block_count,
        });
    }
    if (route.needs_formula_model or hasReason(reason_mask, .formula_route_stub)) {
        try traces.append(allocator, .{
            .page_index = page_index,
            .region_index = region_index,
            .stage = .formula_route_stub,
            .route = route,
            .reason_mask = reason_mask,
            .span_count = span_count,
            .block_count = block_count,
        });
    }
}

pub fn renderOutput(
    allocator: std.mem.Allocator,
    doc: *const ReconciledDocument,
    format: OutputFormat,
) ![]u8 {
    return switch (format) {
        .text => renderText(allocator, doc),
        .markdown => reconcile.renderMarkdown(allocator, doc),
        .json => reconcile.renderJson(allocator, doc),
        .jsonl => reconcile.renderJsonl(allocator, doc, .spans),
        .rag_jsonl => reconcile.renderRagJsonl(allocator, doc),
        .artifact_jsonl => unreachable,
        .hocr => reconcile.renderHocr(allocator, doc),
        .alto => reconcile.renderAlto(allocator, doc),
        .debug_svg => reconcile.renderDebugSvg(allocator, doc),
    };
}

pub fn renderDebugSvg(allocator: std.mem.Allocator, result: *const Result) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    const box = debugDocumentBox(result);
    try writer.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\" data-debug-svg=\"adaptive\">\n",
        .{ box.x0, box.y0, @max(1, width(box)), @max(1, height(box)) },
    );
    try writer.writeAll("<style>");
    try writer.writeAll(".page{fill:#fff;stroke:#111827;stroke-width:1.2}.native-span{fill:#2563eb;fill-opacity:.18;stroke:#2563eb;stroke-width:.55}.layout-block{fill:none;stroke-width:1.3;stroke-dasharray:5 3}.layout-col-0{stroke:#16a34a}.layout-col-1{stroke:#7c3aed}.layout-col-n{stroke:#0891b2}.table-candidate{fill:#f59e0b;fill-opacity:.16;stroke:#b45309;stroke-width:2}.formula-candidate{fill:#ec4899;fill-opacity:.16;stroke:#be185d;stroke-width:2}.header-footer{fill:#64748b;fill-opacity:.12;stroke:#475569;stroke-width:1.5}.ocr-needed{fill:#ef4444;fill-opacity:.10;stroke:#dc2626;stroke-width:2.2;stroke-dasharray:8 4}.low-confidence{fill:#f97316;fill-opacity:.10;stroke:#ea580c;stroke-width:1.7;stroke-dasharray:3 3}.label{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:8px;paint-order:stroke;stroke:white;stroke-width:2px;stroke-linejoin:round}.legend{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:9px}");
    try writer.writeAll("</style>\n");
    try writer.writeAll("<rect class=\"page\" width=\"100%\" height=\"100%\"/>\n");
    try writer.writeAll("<g class=\"legend\"><text x=\"8\" y=\"14\">debug-svg: native spans, layout blocks, table/formula candidates, headers/footers, OCR/low confidence regions</text></g>\n");

    try writer.writeAll("<g id=\"native-spans\">\n");
    for (result.reconciled.spans) |span| {
        try writer.print(
            "<rect class=\"native-span\" data-page=\"{d}\" data-source=\"{s}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"><title>",
            .{ span.span.page_index, sourceName(span.chosen_source), span.span.bbox.x0, span.span.bbox.y0, width(span.span.bbox), height(span.span.bbox) },
        );
        try writeXmlEscaped(writer, span.span.text);
        try writer.writeAll("</title></rect>\n");
    }
    try writer.writeAll("</g>\n");

    try writer.writeAll("<g id=\"layout-blocks\">\n");
    for (result.layout_blocks) |block| {
        const class = if (block.kind == .header or block.kind == .footer)
            "layout-block header-footer"
        else if (block.column_index == 0)
            "layout-block layout-col-0"
        else if (block.column_index == 1)
            "layout-block layout-col-1"
        else
            "layout-block layout-col-n";
        try writer.print(
            "<rect class=\"{s}\" data-layer=\"layout-block\" data-page=\"{d}\" data-block=\"{d}\" data-column=\"{d}\" data-kind=\"{s}\" data-removed=\"{}\" data-confidence=\"{d:.3}\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
            .{
                class,
                block.page_index,
                block.block_index,
                block.column_index,
                blockKindName(block.kind),
                block.removed,
                block.confidence,
                block.bbox.x0,
                block.bbox.y0,
                width(block.bbox),
                height(block.bbox),
            },
        );
        try writer.print(
            "<text class=\"label\" data-layer=\"layout-label\" x=\"{d:.2}\" y=\"{d:.2}\" fill=\"{s}\">block {d} col {d} {s}</text>\n",
            .{ block.bbox.x0, block.bbox.y0 - 3, columnColor(block.column_index), block.block_index, block.column_index, blockKindName(block.kind) },
        );
    }
    try writer.writeAll("</g>\n");

    try writer.writeAll("<g id=\"route-regions\">\n");
    for (result.page_routes) |route| {
        if (!route.route.needs_ocr and routeConfidence(route.route) >= 0.45) continue;
        const class = if (route.route.needs_ocr) "ocr-needed" else "low-confidence";
        try writeRouteRect(writer, class, "page", route.page_index, null, route.bbox, route.route, route.reason_mask);
    }
    for (result.region_routes) |route| {
        if (isTableCandidate(route)) {
            try writeRouteRect(writer, "table-candidate", "table", route.page_index, route.region_index, route.bbox, route.route, route.reason_mask);
        }
        if (isFormulaCandidate(route)) {
            try writeRouteRect(writer, "formula-candidate", "formula", route.page_index, route.region_index, route.bbox, route.route, route.reason_mask);
        }
        if (route.route.needs_ocr or routeConfidence(route.route) < 0.45) {
            const class = if (route.route.needs_ocr) "ocr-needed" else "low-confidence";
            try writeRouteRect(writer, class, "region", route.page_index, route.region_index, route.bbox, route.route, route.reason_mask);
        }
    }
    try writer.writeAll("</g>\n");

    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice(allocator);
}

fn renderText(allocator: std.mem.Allocator, doc: *const ReconciledDocument) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const writer = runtime.arrayListWriter(&output, allocator);

    var previous_page: ?u32 = null;
    for (doc.blocks, 0..) |block, index| {
        if (block.kind == .header or block.kind == .footer) continue;
        if (previous_page) |page| {
            if (page != block.page_index) try writer.writeByte('\x0c');
        }
        previous_page = block.page_index;

        if (index > 0 and output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
            try writer.writeAll("\n\n");
        }
        try writer.writeAll(block.text);
    }

    return output.toOwnedSlice(allocator);
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            else => if (byte < 0x20) {
                try writer.print("\\u00{X:0>2}", .{byte});
            } else {
                try writer.writeByte(byte);
            },
        }
    }
}

fn writeRouteRect(
    writer: anytype,
    class: []const u8,
    layer: []const u8,
    page_index: u32,
    region_index: ?u32,
    bbox: BBox,
    route: RouteDecision,
    reason_mask: RouteReasonMask,
) !void {
    try writer.print(
        "<rect class=\"{s}\" data-layer=\"{s}\" data-page=\"{d}\" ",
        .{ class, layer, page_index },
    );
    if (region_index) |index| try writer.print("data-region=\"{d}\" ", .{index});
    try writer.print(
        "data-route=\"{s}\" data-confidence=\"{d:.3}\" data-reasons=\"",
        .{ routeName(route), routeConfidence(route) },
    );
    try writeReasonCsv(writer, reason_mask);
    try writer.print(
        "\" x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\"/>\n",
        .{ bbox.x0, bbox.y0, width(bbox), height(bbox) },
    );
}

fn debugDocumentBox(result: *const Result) BBox {
    var maybe_box: ?BBox = null;
    for (result.page_routes) |route| maybe_box = unionMaybeBox(maybe_box, route.bbox);
    for (result.layout_blocks) |block| maybe_box = unionMaybeBox(maybe_box, block.bbox);
    for (result.region_routes) |route| maybe_box = unionMaybeBox(maybe_box, route.bbox);
    for (result.reconciled.spans) |span| maybe_box = unionMaybeBox(maybe_box, span.span.bbox);
    return maybe_box orelse .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 };
}

fn unionMaybeBox(existing: ?BBox, next: BBox) BBox {
    if (width(next) <= 0 and height(next) <= 0) return existing orelse next;
    if (existing) |box| {
        return .{
            .x0 = @min(box.x0, next.x0),
            .y0 = @min(box.y0, next.y0),
            .x1 = @max(box.x1, next.x1),
            .y1 = @max(box.y1, next.y1),
        };
    }
    return next;
}

fn isTableCandidate(route: RegionRoute) bool {
    return route.route.needs_table_model or
        hasReason(route.reason_mask, .table_alignment) or
        hasReason(route.reason_mask, .table_route_stub) or
        route.block_kind == .table_candidate or
        (route.table != null and route.table.?.needsSpecialist());
}

fn isFormulaCandidate(route: RegionRoute) bool {
    return route.route.needs_formula_model or
        hasReason(route.reason_mask, .formula_density) or
        hasReason(route.reason_mask, .formula_route_stub) or
        route.block_kind == .formula_candidate or
        (route.formula != null and route.formula.?.needsSpecialist());
}

fn routeName(route: RouteDecision) []const u8 {
    if (route.native_fast_path) return "use_native";
    if (route.needs_ocr) return "queue_ocr";
    if (route.needs_table_model and route.needs_formula_model) return "candidate_table_formula";
    if (route.needs_table_model) return "candidate_table";
    if (route.needs_formula_model) return "candidate_formula";
    if (route.needs_layout_model) return "candidate_layout";
    return "review";
}

fn routeConfidence(route: RouteDecision) f32 {
    const signal = @max(0.0, @min(1.0, route.max_signal));
    if (route.native_fast_path) return 1.0 - signal;
    return signal;
}

fn writeReasonCsv(writer: anytype, mask: RouteReasonMask) !void {
    const reasons = [_]RouteReason{
        .native_fast_path,
        .sparse_text,
        .image_dominance,
        .bad_unicode,
        .missing_tounicode,
        .hidden_ocr,
        .low_reading_order_confidence,
        .table_alignment,
        .formula_density,
        .ocr_route_stub,
        .layout_route_stub,
        .table_route_stub,
        .formula_route_stub,
    };
    var first = true;
    for (reasons) |reason| {
        if (!hasReason(mask, reason)) continue;
        if (!first) try writer.writeByte(',');
        try writer.writeAll(reasonName(reason));
        first = false;
    }
}

fn reasonName(reason: RouteReason) []const u8 {
    return switch (reason) {
        .native_fast_path => "native_fast_path",
        .sparse_text => "sparse_text",
        .image_dominance => "image_dominant",
        .bad_unicode => "bad_unicode",
        .missing_tounicode => "missing_tounicode",
        .hidden_ocr => "hidden_ocr",
        .low_reading_order_confidence => "low_reading_order_confidence",
        .table_alignment => "table_alignment",
        .formula_density => "formula_density",
        .ocr_route_stub => "ocr_route_stub",
        .layout_route_stub => "layout_route_stub",
        .table_route_stub => "table_route_stub",
        .formula_route_stub => "formula_route_stub",
        .unexplained_vector => "unexplained_vector",
        .vector_evidence_limited => "vector_evidence_limited",
    };
}

fn blockKindName(kind: BlockKind) []const u8 {
    return switch (kind) {
        .paragraph => "paragraph",
        .heading => "heading",
        .list_item => "list_item",
        .header => "header",
        .footer => "footer",
        .caption => "caption",
        .table_candidate => "table_candidate",
        .formula_candidate => "formula_candidate",
        .figure_candidate => "figure_candidate",
    };
}

fn sourceName(source: layout.SourceKind) []const u8 {
    return switch (source) {
        .native_pdf => "native_pdf",
        .embedded_ocr => "embedded_ocr",
        .fresh_ocr => "fresh_ocr",
        .table_model => "table_model",
        .formula_model => "formula_model",
        .manual => "manual",
        .poppler_text => "poppler_text",
    };
}

fn columnColor(column_index: u32) []const u8 {
    return switch (column_index) {
        0 => "#16a34a",
        1 => "#7c3aed",
        else => "#0891b2",
    };
}

fn width(box: BBox) f64 {
    return @max(0, box.x1 - box.x0);
}

fn height(box: BBox) f64 {
    return @max(0, box.y1 - box.y0);
}

fn writeXmlEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        else => try writer.writeByte(byte),
    };
}

fn freeTextSpans(allocator: std.mem.Allocator, spans: []layout.TextSpan) void {
    if (spans.len == 0) return;
    for (spans) |span| freeOwnedTextSpan(allocator, span);
    allocator.free(spans);
}

const AppendOcrAttemptOptions = struct {
    attempt_index: u16,
    page_index: u32,
    region_index: ?u32 = null,
    crop_bbox: ?BBox = null,
    crop_image_sha256: ?[32]u8 = null,
    crop_image_byte_length: ?usize = null,
    status: ocr.AttemptStatus,
    page_bbox: BBox = .{},
    failure_stage: ?ocr.AttemptStage = null,
    duration_ms: u64 = 0,
    pixel_width: u32 = 0,
    pixel_height: u32 = 0,
    pixel_to_pdf: ?page_geometry.Matrix = null,
    rasterizer_dpi: ?f64 = null,
    spans: []const layout.TextSpan = &.{},
    exit_code: ?u8 = null,
    diagnostic_code: ?ocr.DiagnosticCode = null,
    stderr: []const u8 = "",
    selected: bool = false,
};

fn appendOcrAttempt(
    allocator: std.mem.Allocator,
    attempts: *std.ArrayList(OcrAttempt),
    config: ocr.OcrConfig,
    options: AppendOcrAttemptOptions,
) !usize {
    const lang = try allocator.dupe(u8, config.lang);
    errdefer allocator.free(lang);
    const stderr_excerpt = try sanitizeDiagnosticExcerpt(allocator, options.stderr, 4096);
    errdefer allocator.free(stderr_excerpt);

    var character_count: usize = 0;
    var confidence_total: f64 = 0;
    var covered_area: f64 = 0;
    for (options.spans) |span| {
        character_count += span.text.len;
        confidence_total += span.confidence;
        covered_area += width(span.bbox) * height(span.bbox);
    }
    const page_area = width(options.page_bbox) * height(options.page_bbox);

    const index = attempts.items.len;
    try attempts.append(allocator, .{
        .attempt_index = options.attempt_index,
        .page_index = options.page_index,
        .region_index = options.region_index,
        .crop_bbox = options.crop_bbox,
        .crop_image_sha256 = options.crop_image_sha256,
        .crop_image_byte_length = options.crop_image_byte_length,
        .status = options.status,
        .page_bbox = options.page_bbox,
        .failure_stage = options.failure_stage,
        .backend = config.backend,
        .dpi = config.dpi,
        .psm = config.psm,
        .lang = lang,
        .grayscale = config.rasterize_grayscale,
        .timeout_ms = config.timeout_ms,
        .max_image_pixels = config.max_image_pixels,
        .max_image_bytes = config.max_image_bytes,
        .max_regions_per_page = config.max_regions_per_page,
        .max_attempts_per_page = config.max_attempts_per_page,
        .duration_ms = options.duration_ms,
        .pixel_width = options.pixel_width,
        .pixel_height = options.pixel_height,
        .pixel_to_pdf = options.pixel_to_pdf,
        .rasterizer_dpi = options.rasterizer_dpi,
        .span_count = options.spans.len,
        .character_count = character_count,
        .mean_confidence = if (options.spans.len > 0) @floatCast(confidence_total / @as(f64, @floatFromInt(options.spans.len))) else 0,
        .text_coverage = if (page_area > 0) @floatCast(@min(1.0, covered_area / page_area)) else 0,
        .exit_code = options.exit_code,
        .diagnostic_code = options.diagnostic_code,
        .stderr_excerpt = stderr_excerpt,
        .selected = options.selected,
    });
    return index;
}

fn shouldRetryOcrAttempt(attempt: OcrAttempt, config: ocr.OcrConfig) bool {
    if (attempt.status == .empty) return true;
    if (attempt.status != .completed) return false;
    return attempt.character_count < config.retry_min_character_count or
        attempt.mean_confidence < config.retry_min_mean_confidence or
        attempt.text_coverage < config.retry_min_text_coverage;
}

fn betterOcrAttempt(candidate: OcrAttempt, current: OcrAttempt) bool {
    const candidate_rank = ocrAttemptRank(candidate.status);
    const current_rank = ocrAttemptRank(current.status);
    if (candidate_rank != current_rank) return candidate_rank > current_rank;
    if (candidate.mean_confidence != current.mean_confidence) return candidate.mean_confidence > current.mean_confidence;
    if (candidate.text_coverage != current.text_coverage) return candidate.text_coverage > current.text_coverage;
    if (candidate.character_count != current.character_count) return candidate.character_count > current.character_count;
    if (candidate.dpi != current.dpi) return candidate.dpi < current.dpi;
    return candidate.attempt_index < current.attempt_index;
}

fn ocrAttemptRank(status: ocr.AttemptStatus) u8 {
    return switch (status) {
        .completed => 2,
        .empty => 1,
        else => 0,
    };
}

fn sanitizeDiagnosticExcerpt(allocator: std.mem.Allocator, source: []const u8, limit: usize) ![]u8 {
    const bounded = source[0..@min(source.len, limit)];
    const output = try allocator.alloc(u8, bounded.len);
    for (bounded, output) |byte, *slot| {
        slot.* = if (byte == '\n' or byte == '\r' or byte == '\t' or byte >= 0x20) byte else ' ';
    }
    return output;
}

fn freeOcrAttempts(allocator: std.mem.Allocator, attempts: []OcrAttempt) void {
    freeOcrAttemptItems(allocator, attempts);
    allocator.free(attempts);
}

fn freeOcrAttemptItems(allocator: std.mem.Allocator, attempts: []OcrAttempt) void {
    for (attempts) |attempt| {
        allocator.free(attempt.lang);
        allocator.free(attempt.stderr_excerpt);
    }
}

fn cloneTextSpans(allocator: std.mem.Allocator, source: []const layout.TextSpan) ![]layout.TextSpan {
    const cloned = try allocator.alloc(layout.TextSpan, source.len);
    errdefer allocator.free(cloned);
    var initialized: usize = 0;
    errdefer for (cloned[0..initialized]) |span| freeOwnedTextSpan(allocator, span);
    for (source, cloned) |span, *copy| {
        copy.* = span;
        copy.text = try allocator.dupe(u8, span.text);
        errdefer allocator.free(@constCast(copy.text));
        if (span.font.name) |name| copy.font.name = try allocator.dupe(u8, name);
        initialized += 1;
    }
    return cloned;
}

fn fallbackTextSpans(
    allocator: std.mem.Allocator,
    page_text: []const u8,
    page_index: u32,
    page_bbox: BBox,
) ![]layout.TextSpan {
    const trimmed = std.mem.trim(u8, page_text, " \t\r\n");
    if (trimmed.len == 0) return allocator.alloc(layout.TextSpan, 0);
    const spans = try allocator.alloc(layout.TextSpan, 1);
    errdefer allocator.free(spans);
    const text = try allocator.dupe(u8, trimmed);
    spans[0] = layout.TextSpan.init(.{
        .page_index = page_index,
        .bbox = page_bbox,
        .text = text,
        .source = .poppler_text,
        .confidence = 0.98,
    });
    return spans;
}

pub const DocumentTextPageIndex = struct {
    allocator: std.mem.Allocator,
    pages: []?[]const u8,

    pub fn init(allocator: std.mem.Allocator, document_text: []const u8, page_count: usize) !DocumentTextPageIndex {
        const pages = try allocator.alloc(?[]const u8, page_count);
        @memset(pages, null);

        var page: usize = 0;
        var start: usize = 0;
        for (document_text, 0..) |byte, index| {
            if (byte != '\x0c') continue;
            if (page < pages.len) pages[page] = document_text[start..index];
            page += 1;
            start = index + 1;
            if (page >= pages.len) break;
        }
        if (page < pages.len) pages[page] = document_text[start..];

        return .{ .allocator = allocator, .pages = pages };
    }

    pub fn deinit(self: *DocumentTextPageIndex) void {
        self.allocator.free(self.pages);
        self.* = undefined;
    }

    fn get(self: DocumentTextPageIndex, page: usize) ?[]const u8 {
        if (page >= self.pages.len) return null;
        return self.pages[page];
    }
};

test "document text page index preserves form-feed page boundaries" {
    var index = try DocumentTextPageIndex.init(std.testing.allocator, "first\x0csecond\x0c", 4);
    defer index.deinit();

    try std.testing.expectEqualStrings("first", index.get(0).?);
    try std.testing.expectEqualStrings("second", index.get(1).?);
    try std.testing.expectEqualStrings("", index.get(2).?);
    try std.testing.expect(index.get(3) == null);
    try std.testing.expect(index.get(4) == null);
}

fn freeOwnedTextSpan(allocator: std.mem.Allocator, span: layout.TextSpan) void {
    if (span.text.len > 0) allocator.free(@constCast(span.text));
    if (span.font.name) |name| allocator.free(@constCast(name));
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) layout.TextSpan {
    return layout.TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Body", .size = y1 - y0, .has_to_unicode = true },
    });
}

fn readingOrderBlockAllocationProbe(allocator: std.mem.Allocator) !void {
    const span = testSpan("Owned block text", 10, 20, 100, 32);
    const words = [_]layout.TextWord{.{ .bounds = span, .spans = &.{span} }};
    const lines = [_]layout.TextLine{.{ .bounds = span, .words = &words, .baseline_y = 20 }};
    const blocks = [_]layout.LayoutBlock{.{
        .bounds = span,
        .lines = &lines,
        .column_index = 0,
        .kind = .paragraph,
    }};
    const page_layout: layout.LayoutResult = .{
        .spans = &.{span},
        .lines = &.{},
        .columns = &.{},
        .paragraphs = &.{},
        .blocks = &blocks,
        .tables = &.{},
        .candidates = &.{},
        .reading_order = &.{},
        .body_font_size = 12,
        .allocator = allocator,
    };
    const summaries = try copyReadingOrderBlocks(allocator, 3, page_layout.blocks);
    defer freeReadingOrderBlocks(allocator, summaries);
    if (summaries.len != 1 or !std.mem.eql(u8, summaries[0].text, "Owned block text")) {
        return error.InvalidReadingOrderBlockSummary;
    }
    const source_summaries = try copyReadingOrderSourceSpans(allocator, 3, page_layout.spans);
    defer freeReadingOrderSourceSpans(allocator, source_summaries);
    if (source_summaries.len != 1 or !std.mem.eql(u8, source_summaries[0].text, "Owned block text")) {
        return error.InvalidReadingOrderSourceSpanSummary;
    }

    const source_indices = [_]u32{0};
    const source_regions = [_]reading_order_regions.RegionNode{.{
        .id = 0,
        .parent_id = null,
        .kind = .root,
        .bounds = span.bbox,
        .source_span_count = 1,
        .source_span_indices = &source_indices,
    }};
    const region_summaries = try copyReadingOrderRegions(allocator, 3, &source_regions);
    defer allocator.free(region_summaries);
    if (region_summaries.len != 1 or region_summaries[0].source_span_count != 1) {
        return error.InvalidReadingOrderRegionSummary;
    }
}

test "reading-order block diagnostics clean up every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readingOrderBlockAllocationProbe,
        .{},
    );
}

test "page route records native fast path for clean native text" {
    const spans = [_]layout.TextSpan{
        testSpan("Native text extraction keeps this paragraph readable", 72, 700, 360, 712),
        testSpan("without OCR or specialist escalation for this route", 72, 684, 350, 696),
        testSpan("because the text density and Unicode signals are healthy", 72, 668, 380, 680),
        testSpan("and reading order is backed by document structure", 72, 652, 340, 664),
    };
    const score = complexity.scorePage(.{
        .page_index = 0,
        .bbox = .{ .x0 = 60, .y0 = 640, .x1 = 400, .y1 = 720 },
        .spans = &spans,
        .has_structure_tree = true,
    });
    const route = PageRoute.fromScore(score);

    try std.testing.expect(route.route.native_fast_path);
    try std.testing.expect(hasReason(route.reason_mask, .native_fast_path));
    try std.testing.expect(!hasReason(route.reason_mask, .ocr_route_stub));
}

test "route traces emit OCR stub when route needs OCR" {
    var traces: std.ArrayList(TraceRecord) = .empty;
    defer traces.deinit(std.testing.allocator);

    const route = RouteDecision{
        .native_fast_path = false,
        .needs_ocr = true,
        .max_signal = 1,
    };
    const mask = reasonBit(.ocr_route_stub);
    try appendRouteTraces(std.testing.allocator, &traces, 2, null, route, mask, 0, 0);

    try std.testing.expectEqual(@as(usize, 1), traces.items.len);
    try std.testing.expectEqual(TraceStage.ocr_route_stub, traces.items[0].stage);
}

test "graph span projection preserves removed furniture slots" {
    const header = testSpan("Header", 10, 110, 50, 120);
    const left = testSpan("Left", 10, 80, 40, 90);
    const right = testSpan("Right", 70, 80, 105, 90);
    const header_words = [_]layout.TextWord{.{ .bounds = header, .spans = &.{header} }};
    const left_words = [_]layout.TextWord{.{ .bounds = left, .spans = &.{left} }};
    const right_words = [_]layout.TextWord{.{ .bounds = right, .spans = &.{right} }};
    const header_lines = [_]layout.TextLine{.{ .bounds = header, .words = &header_words, .baseline_y = 110, .role = .header }};
    const left_lines = [_]layout.TextLine{.{ .bounds = left, .words = &left_words, .baseline_y = 80 }};
    const right_lines = [_]layout.TextLine{.{ .bounds = right, .words = &right_words, .baseline_y = 80 }};
    const blocks = [_]layout.LayoutBlock{
        .{ .bounds = header, .lines = &header_lines, .column_index = 0, .kind = .header, .removed = true },
        .{ .bounds = left, .lines = &left_lines, .column_index = 0, .kind = .paragraph },
        .{ .bounds = right, .lines = &right_lines, .column_index = 1, .kind = .paragraph },
    };
    const page_layout: layout.LayoutResult = .{
        .spans = &.{},
        .lines = &.{},
        .columns = &.{},
        .paragraphs = &.{},
        .blocks = &blocks,
        .tables = &.{},
        .candidates = &.{},
        .reading_order = &.{},
        .body_font_size = 10,
        .allocator = std.testing.allocator,
    };
    var graph = try reading_order_graph.build(std.testing.allocator, 0, &page_layout, .{});
    defer graph.deinit();

    var spans = [_]layout.TextSpan{ header, right, left };
    try std.testing.expect(try reorderSpansByGraph(std.testing.allocator, &spans, &page_layout, &graph, true));
    try std.testing.expectEqualStrings("Header", spans[0].text);
    try std.testing.expectEqualStrings("Left", spans[1].text);
    try std.testing.expectEqualStrings("Right", spans[2].text);
}

test "debug svg marks low-confidence review regions" {
    var spans = [_]reconcile.ReconciledSpan{};
    var blocks = [_]reconcile.ReconciledBlock{};
    var chunks = [_]reconcile.RagChunk{};
    const doc = ReconciledDocument{
        .allocator = std.testing.allocator,
        .spans = &spans,
        .blocks = &blocks,
        .chunks = &chunks,
    };
    var layout_blocks = [_]LayoutBlockSummary{};
    var page_routes = [_]PageRoute{
        .{
            .page_index = 0,
            .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
            .span_count = 1,
            .image_count = 0,
            .char_count = 8,
            .signals = .{},
            .route = .{ .native_fast_path = false, .max_signal = 0.25 },
            .reason_mask = reasonBit(.low_reading_order_confidence),
        },
    };
    var region_routes = [_]RegionRoute{};
    var trace_records = [_]TraceRecord{};
    const result = Result{
        .allocator = std.testing.allocator,
        .reconciled = doc,
        .native_pages = &.{},
        .layout_blocks = &layout_blocks,
        .page_routes = &page_routes,
        .region_routes = &region_routes,
        .trace_records = &trace_records,
        .ocr_attempts = &.{},
        .formula_attempts = &.{},
        .formula_artifacts = &.{},
        .form_fields = &.{},
        .tables = &.{},
        .reading_order_pages = &.{},
    };

    const svg = try renderDebugSvg(std.testing.allocator, &result);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "class=\"low-confidence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "low_reading_order_confidence") != null);
}

test "mixed native OCR filter keeps image OCR and drops page furniture OCR" {
    const allocator = std.testing.allocator;

    var ocr_spans = try allocator.alloc(layout.TextSpan, 2);
    ocr_spans[0] = layout.TextSpan.init(.{
        .page_index = 0,
        .bbox = .{ .x0 = 10, .y0 = 10, .x1 = 40, .y1 = 24 },
        .text = try allocator.dupe(u8, "native duplicate"),
        .source = .fresh_ocr,
    });
    ocr_spans[1] = layout.TextSpan.init(.{
        .page_index = 0,
        .bbox = .{ .x0 = 110, .y0 = 110, .x1 = 160, .y1 = 124 },
        .text = try allocator.dupe(u8, "scan text"),
        .source = .fresh_ocr,
    });

    const native_spans = [_]layout.TextSpan{
        layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = .{ .x0 = 10, .y0 = 10, .x1 = 40, .y1 = 24 },
            .text = "native duplicate",
        }),
    };
    const images = [_]complexity.ImageBox{
        .{
            .bbox = .{ .x0 = 100, .y0 = 100, .x1 = 200, .y1 = 200 },
            .pixel_width = 1000,
            .pixel_height = 1000,
        },
    };

    const filtered = try filterOcrSpansForPage(allocator, ocr_spans, &native_spans, &images);
    defer {
        for (filtered) |span| allocator.free(@constCast(span.text));
        allocator.free(filtered);
    }

    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("scan text", filtered[0].text);
}

fn tableCellSpanAllocationProbe(allocator: std.mem.Allocator) !void {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    defer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }
    const left = layout.TextSpan.init(.{ .bbox = .{ .x0 = 10, .y0 = 50, .x1 = 40, .y1 = 62 }, .text = "" });
    const right = layout.TextSpan.init(.{ .bbox = .{ .x0 = 100, .y0 = 50, .x1 = 110, .y1 = 62 }, .text = "" });
    var cells = [_]layout.TableCell{
        .{ .bounds = left, .text = "Cash", .row_index = 0, .column_index = 0 },
        .{ .bounds = right, .text = "0", .row_index = 0, .column_index = 1 },
        .{ .bounds = right, .text = "", .row_index = 0, .column_index = 2 },
    };
    var rows = [_]layout.TableRow{.{ .bounds = left, .cells = &cells, .row_index = 0 }};
    const table = layout.TableGrid{ .bounds = left, .block_index = 0, .rows = &rows, .column_count = 3 };
    try appendTableCellSpans(allocator, &spans, &table);
    try std.testing.expectEqual(@as(usize, 2), spans.items.len);
    try std.testing.expectEqualStrings("Cash", spans.items[0].text);
    try std.testing.expectEqualStrings("0", spans.items[1].text);
    try std.testing.expectEqualDeep(left.bbox, spans.items[0].bbox);
    try std.testing.expectEqualDeep(right.bbox, spans.items[1].bbox);
    try std.testing.expectEqual(layout.SourceKind.table_model, spans.items[0].source);
}

test "table evidence retains cell granularity and excludes blank placeholders" {
    try tableCellSpanAllocationProbe(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, tableCellSpanAllocationProbe, .{});
}

test "table layout layer suppresses represented OCR words but keeps residual totals" {
    const represented = [_]layout.TextSpan{
        layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = .{ .x0 = 20, .y0 = 560, .x1 = 500, .y1 = 590 },
            .text = "03/21/2026 ALPHA SUPPLY 1250.00",
            .source = .table_model,
        }),
    };
    const ocr_spans = [_]layout.TextSpan{
        layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = .{ .x0 = 220, .y0 = 565, .x1 = 280, .y1 = 585 },
            .text = "ALPHA",
            .source = .fresh_ocr,
        }),
        layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = .{ .x0 = 20, .y0 = 560, .x1 = 500, .y1 = 590 },
            .text = "03/21/2026 ALPHA SUPPLY 1250.00",
            .source = .fresh_ocr,
        }),
        layout.TextSpan.init(.{
            .page_index = 0,
            .bbox = .{ .x0 = 350, .y0 = 300, .x1 = 410, .y1 = 320 },
            .text = "TOTAL",
            .source = .fresh_ocr,
        }),
    };

    const residual = try filterSubsumedOcrSpanView(std.testing.allocator, &ocr_spans, &represented);
    defer std.testing.allocator.free(residual);

    try std.testing.expectEqual(@as(usize, 1), residual.len);
    try std.testing.expectEqualStrings("TOTAL", residual[0].text);
}

fn adaptiveOwnedListCleanupAllocationProbe(allocator: std.mem.Allocator) !void {
    var attempts: std.ArrayList(OcrAttempt) = .empty;
    defer {
        freeOcrAttemptItems(allocator, attempts.items);
        attempts.deinit(allocator);
    }
    _ = try appendOcrAttempt(allocator, &attempts, .{}, .{
        .attempt_index = 0,
        .page_index = 0,
        .status = .not_invoked,
    });

    const bounds = layout.TextSpan.init(.{
        .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .text = "cell",
    });
    var source_cells = [_]layout.TableCell{.{
        .bounds = bounds,
        .text = "cell",
        .row_index = 0,
        .column_index = 0,
    }};
    var source_rows = [_]layout.TableRow{.{
        .bounds = bounds,
        .cells = &source_cells,
        .row_index = 0,
    }};
    const source_table = layout.TableGrid{
        .bounds = bounds,
        .block_index = 0,
        .rows = &source_rows,
        .column_count = 1,
        .region_index = 11,
        .source_span_indices = &.{ 2, 7 },
        .member_block_indices = &.{ 0, 3 },
    };

    var tables: std.ArrayList(layout.TableGrid) = .empty;
    defer {
        freeOwnedTableItems(allocator, tables.items);
        tables.deinit(allocator);
    }
    try tables.ensureUnusedCapacity(allocator, 1);
    tables.appendAssumeCapacity(try copyTableGrid(allocator, source_table));
    try std.testing.expectEqual(@as(u32, 11), tables.items[0].region_index);
    try std.testing.expectEqualSlices(u32, source_table.source_span_indices, tables.items[0].source_span_indices);
    try std.testing.expectEqualSlices(u32, source_table.member_block_indices, tables.items[0].member_block_indices);
    try std.testing.expect(source_table.source_span_indices.ptr != tables.items[0].source_span_indices.ptr);
    try std.testing.expect(source_table.member_block_indices.ptr != tables.items[0].member_block_indices.ptr);

    const tail = try allocator.alloc(u8, 1);
    defer allocator.free(tail);
}

test "adaptive owned lists are safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        adaptiveOwnedListCleanupAllocationProbe,
        .{},
    );
}

test "two owned grids sharing one block preserve partial-line prose across projections" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "Upper", "Value", "First", "10", "Lower", "Value", "Second", "20", "Unowned prose" };
    var native: [names.len]layout.TextSpan = undefined;
    var words: [names.len]layout.TextWord = undefined;
    for (&native, &words, names, 0..) |*span, *word, name, index| {
        span.* = layout.TextSpan.init(.{ .bbox = .{ .x0 = 10, .y0 = 50, .x1 = 90, .y1 = 62 }, .text = name });
        span.native_source_index = @intCast(index);
        word.* = .{ .bounds = span.*, .spans = native[index .. index + 1] };
    }
    var cells: [8]layout.TableCell = undefined;
    for (&cells, 0..) |*cell, index| cell.* = .{
        .bounds = native[index],
        .text = names[index],
        .row_index = @intCast((index % 4) / 2),
        .column_index = @intCast(index % 2),
    };
    var rows: [4]layout.TableRow = undefined;
    for (&rows, 0..) |*row, index| row.* = .{ .bounds = native[index * 2], .cells = cells[index * 2 .. index * 2 + 2], .row_index = @intCast(index % 2) };
    const tables = [_]layout.TableGrid{
        .{ .bounds = native[0], .block_index = 0, .rows = rows[0..2], .column_count = 2, .region_index = 0, .source_span_indices = &.{ 0, 1, 2, 3 }, .member_block_indices = &.{0}, .projection_eligible = true },
        .{ .bounds = native[4], .block_index = 0, .rows = rows[2..4], .column_count = 2, .region_index = 1, .source_span_indices = &.{ 4, 5, 6, 7 }, .member_block_indices = &.{0}, .projection_eligible = true },
    };
    const lines = [_]layout.TextLine{.{ .bounds = native[0], .words = &words, .baseline_y = 50 }};
    const blocks = [_]layout.LayoutBlock{.{ .bounds = native[0], .lines = &lines, .column_index = 0, .kind = .paragraph }};
    const page_layout: layout.LayoutResult = .{
        .allocator = allocator,
        .spans = &native,
        .lines = &lines,
        .columns = &.{},
        .paragraphs = &.{},
        .blocks = &blocks,
        .tables = &tables,
        .candidates = &.{},
        .reading_order = &.{},
    };
    const projected = try buildLayoutLayerSpans(allocator, &page_layout, null);
    defer {
        for (projected) |span| allocator.free(@constCast(span.text));
        allocator.free(projected);
    }
    try std.testing.expectEqual(@as(usize, names.len), projected.len);
    for (projected[0..8], 0..) |span, index| {
        const owner = span.table_cell_owner orelse return error.MissingTableOwner;
        try std.testing.expectEqual(@as(u32, @intCast(index / 4)), owner.region_index);
    }
    try std.testing.expectEqualStrings("Unowned prose", projected[8].text);
    try std.testing.expectEqual(@as(?layout.TableCellOwner, null), projected[8].table_cell_owner);
    for ([_]bool{ false, true }) |markdown| {
        const text = try page_layout.getRegionText(allocator, markdown, true);
        defer allocator.free(text);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Upper"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Lower"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "Unowned prose"));
    }
}

test "regional OCR attempts preserve route identity and enforce per-page invocation cap" {
    const FakeDocument = struct {
        calls: usize = 0,
        pub fn rasterizeOcrRegionDetailed(self: *@This(), _: std.mem.Allocator, _: usize, _: BBox, _: ocr.OcrConfig) !ocr.RasterizeOutcome {
            self.calls += 1;
            return .{ .status = .unavailable, .diagnostic_code = .rasterizer_unavailable };
        }
        pub fn rasterizePageForOcrDetailed(self: *@This(), _: std.mem.Allocator, _: usize, _: ocr.OcrConfig) !ocr.RasterizeOutcome {
            self.calls += 1;
            return .{ .status = .unavailable, .diagnostic_code = .rasterizer_unavailable };
        }
    };
    var doc = FakeDocument{};
    const allocator = std.testing.allocator;
    var attempts: std.ArrayList(OcrAttempt) = .empty;
    defer {
        freeOcrAttemptItems(allocator, attempts.items);
        attempts.deinit(allocator);
    }
    var count: usize = 0;
    const bbox = BBox{ .x0 = 10, .y0 = 20, .x1 = 50, .y1 = 60 };
    try std.testing.expectEqual(@as(?[]layout.TextSpan, null), try recognizeOcrTarget(&doc, allocator, &attempts, .{ .enable_ocr = false }, 2, bbox, 37, &.{}, &.{}, &count));
    try std.testing.expectEqual(@as(usize, 0), doc.calls);
    try std.testing.expectEqual(@as(?u32, 37), attempts.items[0].region_index);
    try std.testing.expectEqual(ocr.DiagnosticCode.ocr_disabled, attempts.items[0].diagnostic_code.?);
    _ = try recognizeOcrTarget(&doc, allocator, &attempts, .{ .ocr_config = .{ .max_attempts_per_page = 0 } }, 2, bbox, 38, &.{}, &.{}, &count);
    try std.testing.expectEqual(@as(usize, 0), doc.calls);
    try std.testing.expectEqual(@as(?u32, 38), attempts.items[1].region_index);
    try std.testing.expectEqual(ocr.DiagnosticCode.ocr_attempt_limit, attempts.items[1].diagnostic_code.?);
    _ = try recognizeOcrTarget(&doc, allocator, &attempts, .{ .ocr_config = .{ .max_attempts_per_page = 1 } }, 2, bbox, 39, &.{}, &.{}, &count);
    try std.testing.expectEqual(@as(usize, 1), doc.calls);
    try std.testing.expectEqual(@as(?u32, 39), attempts.items[2].region_index);
    try std.testing.expectEqual(ocr.AttemptStatus.unavailable, attempts.items[2].status);
    _ = try recognizeOcrTarget(&doc, allocator, &attempts, .{ .ocr_config = .{ .max_attempts_per_page = 1 } }, 2, bbox, 40, &.{}, &.{}, &count);
    try std.testing.expectEqual(@as(usize, 1), doc.calls);
    try std.testing.expectEqual(ocr.DiagnosticCode.ocr_attempt_limit, attempts.items[3].diagnostic_code.?);
    try std.testing.expect(!attempts.items[3].selected);
}

test "native-good minority hidden text without images keeps its independent OCR route" {
    var hidden = testSpan("Hidden text", 10, 10, 110, 20);
    hidden.paint = .{ .rendering_mode = 3, .paint_state = .non_painting };
    const spans = [_]layout.TextSpan{
        testSpan("Readable native paragraph with substantial ordinary text", 10, 100, 500, 300),
        testSpan("Readable native paragraph with substantial ordinary text", 10, 300, 500, 500),
        testSpan("Readable native paragraph with substantial ordinary text", 10, 500, 500, 700),
        hidden,
    };
    const input = complexity.PageInput{ .page_index = 0, .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, .spans = &spans };
    const page_route = PageRoute.fromScore(complexity.scorePage(input));
    try std.testing.expect(page_route.signals.hidden_ocr < 0.45);
    try std.testing.expect(!usesRegionalOcr(page_route, true));
    var region = RegionRoute.fromScore(.{ .region_index = 0, .score = complexity.scoreRegion(input, hidden.bbox) });
    try std.testing.expect(region.route.needs_ocr);
    suppressDerivedOcr(&region, input, &.{});
    try std.testing.expect(region.route.needs_ocr);
}

test "a crop does not explain independent hidden or bad-Unicode recovery" {
    var hidden = testSpan("Hidden text", 10, 10, 110, 20);
    hidden.paint = .{ .rendering_mode = 3, .paint_state = .non_painting };
    const images = [_]complexity.ImageBox{.{ .bbox = .{ .x0 = 300, .y0 = 400, .x1 = 500, .y1 = 600 } }};
    const input = complexity.PageInput{ .page_index = 0, .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, .spans = &.{hidden}, .images = &images };
    const crop = RegionRoute.fromScore(.{ .region_index = 6, .score = complexity.scoreRegion(input, images[0].bbox) });
    var target = RegionRoute.fromScore(.{ .region_index = 7, .score = complexity.scoreRegion(input, hidden.bbox) });
    try std.testing.expect(target.route.needs_ocr);
    suppressDerivedOcr(&target, input, &.{crop});
    try std.testing.expect(target.route.needs_ocr);
    hidden.paint = .{};
    hidden.unicode_map_error = true;
    const broken_input = complexity.PageInput{ .page_index = 0, .bbox = input.bbox, .spans = &.{hidden}, .images = &images };
    var broken = RegionRoute.fromScore(.{ .region_index = 8, .score = complexity.scoreRegion(broken_input, hidden.bbox) });
    try std.testing.expect(broken.route.needs_ocr);
    suppressDerivedOcr(&broken, broken_input, &.{crop});
    try std.testing.expect(broken.route.needs_ocr);
    var duplicate = crop;
    suppressDerivedOcr(&duplicate, input, &.{crop});
    try std.testing.expect(!duplicate.route.needs_ocr);
    var unowned = crop;
    suppressDerivedOcr(&unowned, input, &.{});
    try std.testing.expect(unowned.route.needs_ocr);
}

test "recognized crop metadata does not request OCR again over readable native text" {
    var native = testSpan("Native cover text", 60, 730, 190, 750);
    native.font.has_to_unicode = false;
    const images = [_]complexity.ImageBox{.{ .bbox = .{ .x0 = 46, .y0 = 30, .x1 = 566, .y1 = 720 } }};
    const original = complexity.PageInput{ .page_index = 0, .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, .spans = &.{native}, .images = &images };
    const owner = RegionRoute.fromScore(.{ .region_index = 0, .score = complexity.scoreRegion(original, images[0].bbox) });
    var recognized = testSpan("Recovered image text", 65, 590, 450, 625);
    recognized.source = .fresh_ocr;
    recognized.font.name = "TesseractOCR";
    recognized.confidence = 0.8;
    const enriched = complexity.PageInput{ .page_index = 0, .bbox = original.bbox, .spans = &.{ native, recognized }, .images = &images };
    var derived = RegionRoute.fromScore(.{ .region_index = 1, .score = complexity.scoreRegion(enriched, .{ .x0 = 60, .y0 = 580, .x1 = 450, .y1 = 750 }) });
    try std.testing.expect(derived.route.needs_ocr);
    try std.testing.expect(derived.signals.hidden_ocr >= 0.45);
    try std.testing.expect(derived.signals.bad_unicode >= 0.35);
    suppressDerivedOcr(&derived, original, &.{owner});
    try std.testing.expect(!derived.route.needs_ocr);
    native.unicode_map_error = true;
    const damaged = complexity.PageInput{ .page_index = 0, .bbox = original.bbox, .spans = &.{native}, .images = &images };
    var substantive = RegionRoute.fromScore(.{ .region_index = 2, .score = complexity.scoreRegion(enriched, derived.bbox) });
    suppressDerivedOcr(&substantive, damaged, &.{owner});
    try std.testing.expect(substantive.route.needs_ocr);
}
