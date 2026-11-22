//! Native glyph-first text layout reconstruction.
//!
//! PDF content streams preserve drawing instructions, not words or lines. This
//! module keeps glyph geometry long enough to infer explicit boundaries with
//! confidence and provenance before flattening the page to readable text.

const std = @import("std");
const interpreter = @import("interpreter.zig");
const layout = @import("layout.zig");

pub const GlyphSpan = interpreter.GlyphSpan;
pub const BBox = layout.BBox;

pub const BoundaryKind = layout.TextBoundary;

pub const BoundaryProvenance = enum(u8) {
    content_start,
    explicit_whitespace,
    tj_adjustment,
    geometric_gap,
    baseline_shift,
    paragraph_gap,
    detected_gutter,
};

pub const Boundary = struct {
    before_glyph_index: u32,
    previous_glyph_index: ?u32 = null,
    kind: BoundaryKind,
    confidence: f32,
    provenance: BoundaryProvenance,
    inline_gap: f64 = 0,
    baseline_offset: f64 = 0,
};

pub const Line = struct {
    line_index: u32,
    ordered_start: u32,
    glyph_count: u32,
    bbox: BBox,
    baseline: f64,
    font_size: f64,
    region_index: u32 = 0,
    text_start: u32 = 0,
    text_len: u32 = 0,
};

pub const QualityMetrics = struct {
    word_boundary_precision: ?f64 = null,
    word_boundary_recall: ?f64 = null,
    line_break_f1: ?f64 = null,
    token_f1: ?f64 = null,
    word_error_rate: ?f64 = null,
    max_token_bytes: usize = 0,
    max_line_bytes: usize = 0,
    extreme_token_length_rate: f64 = 0,
    extreme_line_length_rate: f64 = 0,
    raw_non_whitespace_recall: f64 = 1,
    word_boundary_count: usize = 0,
    line_break_count: usize = 0,
    quality_pass: bool = true,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    ordered_glyph_indices: []u32,
    boundaries: []Boundary,
    lines: []Line,
    text: []u8,
    quality: QualityMetrics,
    gutter: ?BBox = null,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.ordered_glyph_indices);
        self.allocator.free(self.boundaries);
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
    }
};

const PendingLine = struct {
    start: usize,
    count: usize,
    baseline_sum: f64,
    baseline_count: usize,
    max_font_size: f64,
    bbox: BBox,
    region_index: u32,

    fn baseline(self: PendingLine) f64 {
        return self.baseline_sum / @as(f64, @floatFromInt(self.baseline_count));
    }
};

const BoundarySignature = struct {
    word: std.ArrayList(u32) = .empty,
    line: std.ArrayList(u32) = .empty,
    non_whitespace: std.ArrayList(u8) = .empty,

    fn deinit(self: *BoundarySignature, allocator: std.mem.Allocator) void {
        self.word.deinit(allocator);
        self.line.deinit(allocator);
        self.non_whitespace.deinit(allocator);
    }
};

pub fn analyze(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    page_bbox: BBox,
    raw_recall_text: []const u8,
) !Result {
    if (glyphs.len == 0) {
        return .{
            .allocator = allocator,
            .ordered_glyph_indices = try allocator.alloc(u32, 0),
            .boundaries = try allocator.alloc(Boundary, 0),
            .lines = try allocator.alloc(Line, 0),
            .text = try allocator.alloc(u8, 0),
            .quality = qualityForText(raw_recall_text, ""),
        };
    }

    const sorted_indices = try allocator.alloc(u32, glyphs.len);
    defer allocator.free(sorted_indices);
    for (sorted_indices, 0..) |*index, glyph_index| index.* = @intCast(glyph_index);
    std.mem.sort(u32, sorted_indices, glyphs, compareGlyphTopDown);

    var line_glyphs: std.ArrayList(u32) = .empty;
    defer line_glyphs.deinit(allocator);
    var pending_lines: std.ArrayList(PendingLine) = .empty;
    defer pending_lines.deinit(allocator);
    var detection = try detectGutter(allocator, glyphs, page_bbox, sorted_indices);
    defer detection.deinit(allocator);
    const gutter = detection.gutter;

    for (sorted_indices) |glyph_index| {
        const glyph = glyphs[glyph_index];
        if (glyph.text.len == 0) continue;
        const glyph_baseline = baselineCoordinate(glyph);
        const glyph_font_size = baselineFontSize(glyph);
        var target_line: ?usize = null;
        var line_index = pending_lines.items.len;
        while (line_index > 0) {
            line_index -= 1;
            const candidate = pending_lines.items[line_index];
            const tolerance = @max(1.5, @max(candidate.max_font_size, glyph_font_size) * 0.55);
            const delta = @abs(glyph_baseline - candidate.baseline());
            if (delta <= tolerance and
                sameOrientation(glyphs[candidateGlyphIndex(line_glyphs.items, candidate)], glyph) and
                detection.compatible(candidate.region_index, detection.region(glyphs, glyph_index)))
            {
                target_line = line_index;
                break;
            }
            if (candidate.baseline() - glyph_baseline > @max(12.0, tolerance * 2.0)) break;
        }

        if (target_line) |existing_index| {
            // Line glyphs are gathered in top-down order. Appending to an older
            // line would make its range discontinuous, so move that line's
            // existing range to the tail before extending it.
            if (existing_index + 1 != pending_lines.items.len) {
                try moveLineToTail(allocator, &line_glyphs, &pending_lines, existing_index);
                target_line = pending_lines.items.len - 1;
            }
            const line = &pending_lines.items[target_line.?];
            try line_glyphs.append(allocator, glyph_index);
            line.count += 1;
            line.baseline_sum += glyph_baseline;
            line.baseline_count += 1;
            line.max_font_size = @max(line.max_font_size, glyph_font_size);
            line.bbox = unionBox(line.bbox, glyph.bbox);
        } else {
            const start = line_glyphs.items.len;
            try line_glyphs.append(allocator, glyph_index);
            try pending_lines.append(allocator, .{
                .start = start,
                .count = 1,
                .baseline_sum = glyph_baseline,
                .baseline_count = 1,
                .max_font_size = glyph_font_size,
                .bbox = glyph.bbox,
                .region_index = detection.region(glyphs, glyph_index),
            });
        }
    }

    for (pending_lines.items) |line| {
        const slice = line_glyphs.items[line.start .. line.start + line.count];
        std.mem.sort(u32, slice, glyphs, compareGlyphInline);
    }

    // The narrow detector already marks full-width bands explicitly; the
    // heading heuristic would turn column-local headings into page breaks.
    const line_order = try orderLinesByRegions(allocator, pending_lines.items, gutter, detection.full_width == null);
    defer allocator.free(line_order);

    var ordered: std.ArrayList(u32) = .empty;
    errdefer ordered.deinit(allocator);
    try ordered.ensureTotalCapacity(allocator, line_glyphs.items.len);
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    for (line_order) |source_line_index| {
        const source = pending_lines.items[source_line_index];
        const ordered_start = ordered.items.len;
        try ordered.appendSlice(allocator, line_glyphs.items[source.start .. source.start + source.count]);
        try lines.append(allocator, .{
            .line_index = @intCast(lines.items.len),
            .ordered_start = @intCast(ordered_start),
            .glyph_count = @intCast(source.count),
            .bbox = source.bbox,
            .baseline = source.baseline(),
            .font_size = source.max_font_size,
            .region_index = source.region_index,
        });
    }

    const owned_ordered = try ordered.toOwnedSlice(allocator);
    errdefer allocator.free(owned_ordered);
    const owned_lines = try lines.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lines);
    const boundaries = try classifyBoundaries(allocator, glyphs, owned_ordered, owned_lines);
    errdefer allocator.free(boundaries);
    const text = try renderReadable(allocator, glyphs, owned_ordered, boundaries, owned_lines);
    errdefer allocator.free(text);

    var quality = qualityForText(raw_recall_text, text);
    quality.word_boundary_count = countBoundaryKind(boundaries, .space);
    quality.line_break_count = countLineBoundaries(boundaries);
    quality.quality_pass = passesQualityGate(quality, glyphs.len);

    return .{
        .allocator = allocator,
        .ordered_glyph_indices = owned_ordered,
        .boundaries = boundaries,
        .lines = owned_lines,
        .text = text,
        .quality = quality,
        .gutter = gutter,
    };
}

pub fn compareAgainstReference(
    allocator: std.mem.Allocator,
    raw_recall_text: []const u8,
    readable_text: []const u8,
    reference_text: []const u8,
) !QualityMetrics {
    var metrics = qualityForText(raw_recall_text, readable_text);
    var expected = try boundarySignature(allocator, reference_text);
    defer expected.deinit(allocator);
    var actual = try boundarySignature(allocator, readable_text);
    defer actual.deinit(allocator);
    metrics.word_boundary_count = actual.word.items.len;
    metrics.line_break_count = actual.line.items.len;

    if (std.mem.eql(u8, expected.non_whitespace.items, actual.non_whitespace.items)) {
        const word = precisionRecall(expected.word.items, actual.word.items);
        metrics.word_boundary_precision = word.precision;
        metrics.word_boundary_recall = word.recall;
        const line = precisionRecall(expected.line.items, actual.line.items);
        metrics.line_break_f1 = f1(line.precision, line.recall);
    }

    const token_metrics = try compareTokens(allocator, reference_text, readable_text);
    metrics.token_f1 = token_metrics.f1;
    metrics.word_error_rate = token_metrics.wer;
    metrics.quality_pass = passesQualityGate(metrics, actual.non_whitespace.items.len);
    return metrics;
}

pub fn buildLineSpans(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    result: *const Result,
    page_index: u32,
) ![]layout.TextSpan {
    return buildLineSpansWithGeometry(allocator, glyphs, result, page_index, false);
}

pub fn buildLineSpansWithGeometry(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    result: *const Result,
    page_index: u32,
    include_geometry: bool,
) ![]layout.TextSpan {
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| {
            allocator.free(@constCast(span.text));
            if (span.font.name) |name| allocator.free(@constCast(name));
            if (span.glyph_geometry.len > 0) allocator.free(span.glyph_geometry);
        }
        spans.deinit(allocator);
    }

    for (result.lines) |line| {
        const start: usize = @intCast(line.ordered_start);
        const count: usize = @intCast(line.glyph_count);
        if (count == 0) continue;

        var segment_start: usize = 0;
        while (segment_start < count) {
            const representative = glyphs[result.ordered_glyph_indices[start + segment_start]];
            var segment_end = segment_start + 1;
            while (segment_end < count) : (segment_end += 1) {
                const candidate = glyphs[result.ordered_glyph_indices[start + segment_end]];
                if (!sameTextSpanProvenance(representative, candidate)) break;
            }

            var text: std.ArrayList(u8) = .empty;
            errdefer text.deinit(allocator);
            var geometry: std.ArrayList(layout.GlyphGeometry) = .empty;
            defer geometry.deinit(allocator);
            var segment_bbox = representative.bbox;
            var layout_font_size: f64 = 0;
            for (segment_start..segment_end) |local_index| {
                const ordered_index = start + local_index;
                const boundary = result.boundaries[ordered_index];
                const glyph = glyphs[result.ordered_glyph_indices[ordered_index]];
                const point_size = baselineFontSize(glyph);
                if (std.math.isFinite(point_size) and point_size > 0) layout_font_size = @max(layout_font_size, point_size);
                segment_bbox = unionBox(segment_bbox, glyph.bbox);
                if (local_index > segment_start and boundary.kind == .space and !endsInWhitespace(text.items) and !(glyph.actual_text and startsInWhitespace(glyph.text))) {
                    try text.append(allocator, ' ');
                }
                const text_start = text.items.len;
                try appendNormalizedGlyph(allocator, &text, glyph.text, glyph.actual_text);
                if (include_geometry and !glyph.generated and text.items.len > text_start) {
                    try geometry.append(allocator, .{
                        .text_start_byte = text_start,
                        .text_end_byte = text.items.len,
                        .bbox = glyph.bbox,
                        .quad = if (glyph.semantic_replacement or glyph.actual_text) null else glyph.quad,
                        .precision = if (glyph.semantic_replacement or glyph.actual_text) .replacement_group else .glyph,
                    });
                }
            }
            if (!representative.actual_text) trimTrailingWhitespace(&text);
            while (geometry.items.len > 0 and geometry.items[geometry.items.len - 1].text_start_byte >= text.items.len) geometry.items.len -= 1;
            if (geometry.items.len > 0) geometry.items[geometry.items.len - 1].text_end_byte = @min(geometry.items[geometry.items.len - 1].text_end_byte, text.items.len);
            if (text.items.len == 0) {
                text.deinit(allocator);
                segment_start = segment_end;
                continue;
            }

            const font_name = if (representative.font_name) |name| try allocator.dupe(u8, name) else null;
            var font_name_transferred = false;
            errdefer if (!font_name_transferred) {
                if (font_name) |name| allocator.free(name);
            };
            try spans.ensureUnusedCapacity(allocator, 1);
            const owned_geometry = try geometry.toOwnedSlice(allocator);
            errdefer allocator.free(owned_geometry);
            const owned_text = try text.toOwnedSlice(allocator);
            const paint = representative.paint.forBBox(segment_bbox);
            spans.appendAssumeCapacity(layout.TextSpan.init(.{
                .page_index = page_index,
                .bbox = segment_bbox,
                .text = owned_text,
                .source = .native_pdf,
                .confidence = lineConfidence(result, line),
                .font = .{ .name = font_name, .size = representative.font_size },
                .layout_font_size = if (layout_font_size > 0) layout_font_size else null,
                .line_id = line.line_index,
                .mcid = representative.mcid,
                .unicode_map_error = representative.unicode_map_error,
                .actual_text = representative.actual_text,
                .writing_mode = representative.writing_mode,
                .leading_boundary = segmentLeadingBoundary(glyphs, result, start + segment_start),
                .content_scope = representative.content_scope,
                .paint = paint,
                .glyph_geometry = owned_geometry,
            }));
            font_name_transferred = true;
            segment_start = segment_end;
        }
    }
    return spans.toOwnedSlice(allocator);
}

fn segmentLeadingBoundary(glyphs: []const GlyphSpan, result: *const Result, ordered_index: usize) BoundaryKind {
    const boundary = result.boundaries[ordered_index].kind;
    // The previous provenance segment may trim an explicit trailing space, or
    // a whitespace-only segment may emit no span. Carry that word boundary
    // forward rather than inferring it again from touching glyph boxes.
    if (boundary == .join and ordered_index > 0) {
        const previous = glyphs[result.ordered_glyph_indices[ordered_index - 1]];
        if (!previous.actual_text and isWhitespace(previous.text)) return .space;
    }
    return boundary;
}

fn sameTextSpanProvenance(a: GlyphSpan, b: GlyphSpan) bool {
    return optionalTextEqual(a.font_name, b.font_name) and
        a.font_size == b.font_size and
        a.mcid == b.mcid and
        a.unicode_map_error == b.unicode_map_error and
        a.actual_text == b.actual_text and
        a.semantic_run_id == b.semantic_run_id and
        a.writing_mode == b.writing_mode and
        std.meta.eql(a.content_scope, b.content_scope) and
        std.meta.eql(a.paint, b.paint);
}

fn optionalTextEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn candidateGlyphIndex(line_glyphs: []const u32, line: PendingLine) u32 {
    return line_glyphs[line.start];
}

fn moveLineToTail(
    allocator: std.mem.Allocator,
    line_glyphs: *std.ArrayList(u32),
    lines: *std.ArrayList(PendingLine),
    line_index: usize,
) !void {
    const source = lines.items[line_index];
    const copy = try allocator.dupe(u32, line_glyphs.items[source.start .. source.start + source.count]);
    defer allocator.free(copy);
    try line_glyphs.appendSlice(allocator, copy);
    var moved = source;
    moved.start = line_glyphs.items.len - source.count;
    _ = lines.orderedRemove(line_index);
    try lines.append(allocator, moved);
}

fn compareGlyphTopDown(glyphs: []const GlyphSpan, a_index: u32, b_index: u32) bool {
    const a = glyphs[a_index];
    const b = glyphs[b_index];
    const ay = baselineCoordinate(a);
    const by = baselineCoordinate(b);
    if (ay != by) return ay > by;
    return inlineCoordinate(a) < inlineCoordinate(b);
}

fn compareGlyphInline(glyphs: []const GlyphSpan, a_index: u32, b_index: u32) bool {
    const a = glyphs[a_index];
    const b = glyphs[b_index];
    const a_coord = inlineCoordinate(a);
    const b_coord = inlineCoordinate(b);
    if (a_coord != b_coord) return a_coord < b_coord;
    return a_index < b_index;
}

fn inlineCoordinate(glyph: GlyphSpan) f64 {
    const axis = writingAxis(glyph);
    return glyph.text_matrix[4] * axis.x + glyph.text_matrix[5] * axis.y;
}

fn baselineCoordinate(glyph: GlyphSpan) f64 {
    const axis = writingAxis(glyph);
    return -glyph.text_matrix[4] * axis.y + glyph.text_matrix[5] * axis.x;
}

fn writingAxis(glyph: GlyphSpan) struct { x: f64, y: f64, scale: f64 } {
    const a = if (glyph.writing_mode == 1) -glyph.text_matrix[2] else glyph.text_matrix[0];
    const b = if (glyph.writing_mode == 1) -glyph.text_matrix[3] else glyph.text_matrix[1];
    const magnitude = @max(0.0001, @sqrt(a * a + b * b));
    return .{ .x = a / magnitude, .y = b / magnitude, .scale = magnitude };
}

fn baselineFontSize(glyph: GlyphSpan) f64 {
    const matrix = glyph.text_matrix;
    const normal_scale = @abs(matrix[0] * matrix[3] - matrix[1] * matrix[2]) / writingAxis(glyph).scale;
    return glyph.font_size * normal_scale;
}

fn sameOrientation(a: GlyphSpan, b: GlyphSpan) bool {
    if (a.writing_mode != b.writing_mode) return false;
    const aa = if (a.writing_mode == 1) -a.text_matrix[2] else a.text_matrix[0];
    const ab = if (a.writing_mode == 1) -a.text_matrix[3] else a.text_matrix[1];
    const ba = if (b.writing_mode == 1) -b.text_matrix[2] else b.text_matrix[0];
    const bb = if (b.writing_mode == 1) -b.text_matrix[3] else b.text_matrix[1];
    const a_len = @sqrt(aa * aa + ab * ab);
    const b_len = @sqrt(ba * ba + bb * bb);
    if (!std.math.isFinite(a_len) or !std.math.isFinite(b_len) or a_len <= 0.0001 or b_len <= 0.0001) return false;
    return (aa * ba + ab * bb) / (a_len * b_len) >= 0.94;
}

const GutterDetection = struct {
    gutter: ?BBox = null,
    /// Set only by the narrow-gutter detector: true for glyphs on rows that
    /// cross the gutter (titles, abstracts, captions, figure labels). Those
    /// rows are full-width reading bands; every other glyph belongs to the
    /// column on its side of the gutter centre line.
    full_width: ?[]bool = null,

    fn deinit(self: *GutterDetection, allocator: std.mem.Allocator) void {
        if (self.full_width) |marks| allocator.free(marks);
        self.* = .{};
    }

    /// The strict detector lets a gutter glyph join either side. Under the
    /// narrow detector every glyph has a definite band, so lines never mix
    /// a full-width row with a column row.
    fn compatible(self: GutterDetection, a: u32, b: u32) bool {
        if (self.full_width != null) return a == b;
        return regionsCompatible(a, b);
    }

    fn region(self: GutterDetection, glyphs: []const GlyphSpan, glyph_index: u32) u32 {
        const marks = self.full_width orelse return regionForGlyph(glyphs[glyph_index].bbox, self.gutter);
        if (marks[glyph_index]) return 2;
        const split = self.gutter.?;
        const bbox = glyphs[glyph_index].bbox;
        return if ((bbox.x0 + bbox.x1) / 2.0 < (split.x0 + split.x1) / 2.0) 0 else 1;
    }
};

fn detectGutter(allocator: std.mem.Allocator, glyphs: []const GlyphSpan, page_bbox: BBox, top_down: []const u32) !GutterDetection {
    if (try detectCentralGutter(allocator, glyphs, page_bbox)) |gutter| return .{ .gutter = gutter };
    return detectNarrowGutter(allocator, glyphs, page_bbox, top_down);
}

fn isUprightGlyph(glyph: GlyphSpan) bool {
    if (glyph.writing_mode != 0) return false;
    const axis = writingAxis(glyph);
    return axis.x > 0.99 and @abs(axis.y) < 0.1;
}

/// Fallback for journal layouts whose gutter is narrower than the strict
/// detector accepts (about 12pt) or is crossed by a minority of full-width
/// rows such as figure captions. Rows are clustered by baseline, occupancy is
/// counted per row at sub-point resolution, and the split is accepted only
/// when both sides look like prose columns: aligned left margins and long
/// lines. Short aligned cells (tables, forms) do not qualify.
fn detectNarrowGutter(allocator: std.mem.Allocator, glyphs: []const GlyphSpan, page_bbox: BBox, top_down: []const u32) !GutterDetection {
    const page_width = page_bbox.x1 - page_bbox.x0;
    if (!std.math.isFinite(page_width) or page_width <= 0 or glyphs.len < 200) return .{};

    // `top_down` is analyze's baseline order; filtering keeps it sorted.
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(allocator);
    for (top_down) |glyph_index| {
        const glyph = glyphs[glyph_index];
        if (glyph.text.len == 0 or !isUprightGlyph(glyph)) continue;
        try order.append(allocator, glyph_index);
    }
    if (order.items.len < 200) return .{};

    // Baseline rows over upright glyphs. row_of uses maxInt for glyphs that
    // are not part of the analysis (empty or rotated text).
    const no_row = std.math.maxInt(u32);
    const row_of = try allocator.alloc(u32, glyphs.len);
    defer allocator.free(row_of);
    @memset(row_of, no_row);
    var row_starts: std.ArrayList(usize) = .empty;
    defer row_starts.deinit(allocator);
    {
        var row_baseline: f64 = 0;
        var row_em: f64 = 0;
        for (order.items, 0..) |glyph_index, position| {
            const glyph = glyphs[glyph_index];
            const baseline = baselineCoordinate(glyph);
            const em = baselineFontSize(glyph);
            if (position == 0 or @abs(row_baseline - baseline) > @max(1.5, @max(row_em, em) * 0.55)) {
                try row_starts.append(allocator, position);
                row_baseline = baseline;
                row_em = em;
            } else row_em = @max(row_em, em);
            row_of[glyph_index] = @intCast(row_starts.items.len - 1);
        }
    }
    const row_count = row_starts.items.len;
    if (row_count < 12) return .{};

    // Bridged ink runs per row, computed once. Word gaps under 0.8 em of the
    // smaller adjacent type are bridged, so a full-width line covers the
    // gutter continuously while a large heading does not reach across a
    // gutter toward small body text.
    const InkRun = struct { x0: f64, x1: f64 };
    var runs: std.ArrayList(InkRun) = .empty;
    defer runs.deinit(allocator);
    const row_run_start = try allocator.alloc(usize, row_count + 1);
    defer allocator.free(row_run_start);
    const row_em_max = try allocator.alloc(f64, row_count);
    defer allocator.free(row_em_max);
    {
        var row_glyphs: std.ArrayList(u32) = .empty;
        defer row_glyphs.deinit(allocator);
        for (row_starts.items, 0..) |start, row| {
            row_run_start[row] = runs.items.len;
            row_em_max[row] = 0;
            const end = if (row + 1 < row_starts.items.len) row_starts.items[row + 1] else order.items.len;
            row_glyphs.clearRetainingCapacity();
            for (order.items[start..end]) |glyph_index| {
                if (!isWhitespace(glyphs[glyph_index].text)) try row_glyphs.append(allocator, glyph_index);
            }
            if (row_glyphs.items.len == 0) continue;
            std.mem.sort(u32, row_glyphs.items, glyphs, compareGlyphX0);
            const first = glyphs[row_glyphs.items[0]];
            var run: InkRun = .{ .x0 = first.bbox.x0, .x1 = glyphInkX1(first) };
            var previous_em = baselineFontSize(first);
            row_em_max[row] = previous_em;
            for (row_glyphs.items[1..]) |glyph_index| {
                const glyph = glyphs[glyph_index];
                const em = baselineFontSize(glyph);
                row_em_max[row] = @max(row_em_max[row], em);
                // previous_em follows the glyph that ends the run, not a
                // smaller mark nested inside it.
                if (glyph.bbox.x0 - run.x1 <= @max(1.0, @min(previous_em, em) * 0.8)) {
                    if (glyphInkX1(glyph) >= run.x1) previous_em = em;
                    run.x1 = @max(run.x1, glyphInkX1(glyph));
                    continue;
                }
                try runs.append(allocator, run);
                run = .{ .x0 = glyph.bbox.x0, .x1 = glyphInkX1(glyph) };
                previous_em = em;
            }
            try runs.append(allocator, run);
        }
        row_run_start[row_count] = runs.items.len;
    }

    // Row occupancy per bin via a difference array. Rows with three or more
    // runs are table or figure cells and do not define the gutter.
    const bin_count = 1024;
    const bin_width = page_width / @as(f64, @floatFromInt(bin_count));
    var occupancy: [bin_count]u32 = @splat(0);
    var counted_rows: usize = 0;
    {
        var diff: [bin_count + 1]i32 = @splat(0);
        for (0..row_count) |row| {
            const row_runs = runs.items[row_run_start[row]..row_run_start[row + 1]];
            if (row_runs.len == 0 or row_runs.len > 2) continue;
            counted_rows += 1;
            var next_free: usize = 0;
            for (row_runs) |run| {
                const range = horizontalBinRange(.{ .x0 = run.x0, .y0 = 0, .x1 = run.x1, .y1 = 0 }, page_bbox, bin_count);
                const first = @max(range.first, next_free);
                if (first > range.last) continue;
                diff[first] += 1;
                diff[range.last + 1] -= 1;
                next_free = range.last + 1;
            }
        }
        var running: i32 = 0;
        for (&occupancy, 0..) |*count, bin| {
            running += diff[bin];
            count.* = @intCast(running);
        }
    }

    const search_start = bin_count * 3 / 10;
    const search_end = bin_count * 7 / 10;
    var min_occupancy: u32 = std.math.maxInt(u32);
    for (occupancy[search_start..search_end]) |count| min_occupancy = @min(min_occupancy, count);
    if (counted_rows < 12 or min_occupancy * 2 > counted_rows) return .{};
    const allowed = min_occupancy + @as(u32, @intCast(@max(1, counted_rows / 40)));
    var best_start: usize = 0;
    var best_len: usize = 0;
    var best_min: u32 = std.math.maxInt(u32);
    var run_start: ?usize = null;
    var run_min: u32 = std.math.maxInt(u32);
    for (search_start..search_end + 1) |bin| {
        if (bin < search_end and occupancy[bin] <= allowed) {
            if (run_start == null) {
                run_start = bin;
                run_min = occupancy[bin];
            } else run_min = @min(run_min, occupancy[bin]);
            continue;
        }
        if (run_start) |start| {
            const len = bin - start;
            if (run_min < best_min or (run_min == best_min and len > best_len)) {
                best_start = start;
                best_len = len;
                best_min = run_min;
            }
            run_start = null;
        }
    }
    const gutter_width = @as(f64, @floatFromInt(best_len)) * bin_width;
    if (gutter_width < @max(6.0, page_width * 0.01)) return .{};
    const gutter = BBox{
        .x0 = page_bbox.x0 + @as(f64, @floatFromInt(best_start)) * bin_width,
        .y0 = page_bbox.y0,
        .x1 = page_bbox.x0 + @as(f64, @floatFromInt(best_start + best_len)) * bin_width,
        .y1 = page_bbox.y1,
    };
    const centre = (gutter.x0 + gutter.x1) / 2.0;

    // Per-row facts from the bridged runs (see RowFacts.addRun).
    const facts = try allocator.alloc(RowFacts, row_count);
    defer allocator.free(facts);
    @memset(facts, .{});
    var ems: std.ArrayList(f64) = .empty;
    defer ems.deinit(allocator);
    for (facts, 0..) |*fact, row| {
        const row_runs = runs.items[row_run_start[row]..row_run_start[row + 1]];
        if (row_runs.len == 0) continue;
        fact.em = row_em_max[row];
        try ems.append(allocator, fact.em);
        for (row_runs) |run| fact.addRun(run.x0, run.x1, centre);
    }
    const body_em = @max(1.0, median(ems.items));

    // Column margins: the dominant start position on each side.
    var left_starts: std.ArrayList(f64) = .empty;
    defer left_starts.deinit(allocator);
    var right_starts: std.ArrayList(f64) = .empty;
    defer right_starts.deinit(allocator);
    var page_starts: std.ArrayList(f64) = .empty;
    defer page_starts.deinit(allocator);
    for (facts) |fact| {
        if (fact.hasLeft() or fact.straddles) try page_starts.append(allocator, fact.left_x0);
        if (fact.straddles) continue;
        if (fact.hasLeft()) try left_starts.append(allocator, fact.left_x0);
        if (fact.hasRight()) try right_starts.append(allocator, fact.right_x0);
    }
    const left_margin = try marginMode(allocator, left_starts.items);
    const right_margin = try marginMode(allocator, right_starts.items);
    if (left_margin.count == 0 or right_margin.count == 0) return .{};

    // A clean split row has prose starting at both column margins with a
    // gutter-width gap between. Clean rows are never merged into full-width
    // bands by the table, header, or short-run rules below.
    var left_ends: std.ArrayList(f64) = .empty;
    defer left_ends.deinit(allocator);
    var right_ends: std.ArrayList(f64) = .empty;
    defer right_ends.deinit(allocator);
    for (facts) |fact| {
        if (fact.straddles) continue;
        if (fact.hasLeft()) try left_ends.append(allocator, fact.left_x1);
        if (fact.hasRight()) try right_ends.append(allocator, fact.right_x1);
    }
    const measure: ColumnMeasure = .{
        .page_width = page_width,
        .body_em = body_em,
        .left_start = left_margin.x,
        .right_start = right_margin.x,
        .left_end = if (left_ends.items.len > 0) @min(gutter.x0, percentile(left_ends.items, 0.9)) else gutter.x0,
        .right_end = percentile(right_ends.items, 0.9),
    };
    const clean = try allocator.alloc(bool, row_count);
    defer allocator.free(clean);
    const crossing = try allocator.alloc(bool, row_count);
    defer allocator.free(crossing);
    const tabular = try allocator.alloc(bool, row_count);
    defer allocator.free(tabular);
    for (facts, 0..) |fact, row| {
        const both = fact.hasLeft() and fact.hasRight();
        const gap = fact.right_x0 - fact.left_x1;
        const indent = 2.5 * body_em;
        clean[row] = !fact.straddles and both and gap >= gutter_width * 0.9 and
            fact.left_x0 >= left_margin.x - 1.0 and fact.left_x0 <= left_margin.x + indent and
            fact.right_x0 >= right_margin.x - 1.0 and fact.right_x0 <= right_margin.x + indent and
            proseSide(fact, measure);
        // Full-width when a bridged run spans the centre (run bridging is
        // em-relative, so large titles with wide word gaps straddle), or
        // when the clear space at the centre is under half the gutter.
        crossing[row] = fact.straddles or (both and gap < gutter_width * 0.5);
        // Table rows have cells on both sides of the centre and no prose
        // side; an equation or local table beside column prose stays split.
        tabular[row] = !clean[row] and both and fact.left_runs + fact.right_runs >= 3 and !proseSide(fact, measure);
    }

    // Running headers and footers sit apart from the body by a clearly larger
    // gap than the line pitch. Pitch is measured within each column so that
    // columns with offset baselines do not halve it.
    {
        const pitch = @max(
            @max(try sidePitch(allocator, glyphs, order.items, row_starts.items, facts, true), try sidePitch(allocator, glyphs, order.items, row_starts.items, facts, false)),
            body_em * 1.1,
        );
        // Edge rows are the first and last rows with ink (whitespace-only
        // rows carry no evidence).
        var content_rows: [4]usize = undefined;
        var top_count: usize = 0;
        for (facts, 0..) |fact, row| {
            if (fact.em == 0) continue;
            content_rows[top_count] = row;
            top_count += 1;
            if (top_count == 2) break;
        }
        var bottom_count: usize = 0;
        var row_index = row_count;
        while (row_index > 0 and bottom_count < 2) {
            row_index -= 1;
            if (facts[row_index].em == 0) continue;
            content_rows[2 + bottom_count] = row_index;
            bottom_count += 1;
        }
        if (top_count == 2 and bottom_count == 2) {
            const first = content_rows[0];
            const second = content_rows[1];
            const last = content_rows[2];
            const before_last = content_rows[3];
            const top_gap = rowBaseline(glyphs, order.items, row_starts.items, first) - rowBaseline(glyphs, order.items, row_starts.items, second);
            if (top_gap > pitch * 1.8 and !clean[first]) crossing[first] = true;
            const bottom_gap = rowBaseline(glyphs, order.items, row_starts.items, before_last) - rowBaseline(glyphs, order.items, row_starts.items, last);
            if (bottom_gap > pitch * 1.8 and !clean[last]) crossing[last] = true;
        }
    }

    // Table rows (cells on both sides of the centre, not margin-aligned prose)
    // are full-width when they come in groups; an isolated one stays put.
    // Decide from a snapshot so the pass does not cascade.
    {
        const snapshot = try allocator.dupe(bool, crossing);
        defer allocator.free(snapshot);
        for (tabular, 0..) |is_tabular, row| {
            if (!is_tabular or snapshot[row]) continue;
            const above = row > 0 and (tabular[row - 1] or snapshot[row - 1]);
            const below = row + 1 < row_count and (tabular[row + 1] or snapshot[row + 1]);
            if (above or below) crossing[row] = true;
        }
    }

    // Column flow is a long vertical run. A few non-crossing rows wedged
    // between crossing rows (wrapped table cells, figure labels), or at a page
    // edge next to a full-width band (running header), join that band unless
    // they contain a clean two-column row.
    {
        var row: usize = 0;
        while (row < row_count) {
            if (crossing[row]) {
                row += 1;
                continue;
            }
            const start = row;
            var has_clean = false;
            while (row < row_count and !crossing[row]) : (row += 1) has_clean = has_clean or clean[row];
            const len = row - start;
            const between = start > 0 and row < row_count and len < 4;
            const edge = len < 3 and ((start == 0 and row < row_count) or (row == row_count and start > 0));
            if ((between or edge) and !has_clean) {
                for (crossing[start..row]) |*mark| mark.* = true;
            }
        }
    }

    var crossing_rows: usize = 0;
    var split_rows: usize = 0;
    left_starts.clearRetainingCapacity();
    right_starts.clearRetainingCapacity();
    var left_widths: std.ArrayList(f64) = .empty;
    defer left_widths.deinit(allocator);
    var right_widths: std.ArrayList(f64) = .empty;
    defer right_widths.deinit(allocator);
    for (facts, 0..) |fact, row| {
        if (crossing[row]) {
            crossing_rows += 1;
            continue;
        }
        if (fact.hasLeft()) {
            try left_starts.append(allocator, fact.left_x0);
            try left_widths.append(allocator, fact.left_x1 - fact.left_x0);
        }
        if (fact.hasRight()) {
            try right_starts.append(allocator, fact.right_x0);
            try right_widths.append(allocator, fact.right_x1 - fact.right_x0);
        }
        if (fact.hasLeft() and fact.hasRight()) split_rows += 1;
    }
    if (crossing_rows * 4 > row_count * 3 or split_rows < 6) return .{};
    // Margins of the rows that remain in columns after full-width bands are
    // removed: both must be aligned, and the left column must start at the
    // page's text margin (an indented split is a table's inner boundary).
    const column_left = try marginMode(allocator, left_starts.items);
    const column_right = try marginMode(allocator, right_starts.items);
    if (!marginAligned(column_left) or !marginAligned(column_right)) return .{};
    if (median(left_widths.items) < page_width * 0.25 or median(right_widths.items) < page_width * 0.25) return .{};
    if (column_left.x > percentile(page_starts.items, 0.05) + 2.0 * body_em) return .{};

    const full_width = try allocator.alloc(bool, glyphs.len);
    errdefer allocator.free(full_width);
    for (full_width, 0..) |*mark, index| {
        const row = row_of[index];
        // Glyphs outside the row analysis keep their geometric side.
        mark.* = row != no_row and crossing[row];
    }
    return .{ .gutter = gutter, .full_width = full_width };
}

/// Median baseline step between consecutive rows that have content on one side.
fn sidePitch(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    order: []const u32,
    row_starts: []const usize,
    facts: []const RowFacts,
    left: bool,
) !f64 {
    var pitches: std.ArrayList(f64) = .empty;
    defer pitches.deinit(allocator);
    var previous: ?f64 = null;
    for (facts, 0..) |fact, row| {
        if (fact.straddles) {
            previous = null;
            continue;
        }
        const present = if (left) fact.hasLeft() else fact.hasRight();
        if (!present) continue;
        const baseline = rowBaseline(glyphs, order, row_starts, row);
        if (previous) |above| try pitches.append(allocator, above - baseline);
        previous = baseline;
    }
    return median(pitches.items);
}

/// Right edge of a glyph's ink: the box minus positive character spacing,
/// which pads the advance but paints nothing.
fn glyphInkX1(glyph: GlyphSpan) f64 {
    const spacing = glyph.spacing_advance * writingAxis(glyph).scale;
    if (!(spacing > 0)) return glyph.bbox.x1;
    return @max(glyph.bbox.x0, glyph.bbox.x1 - spacing);
}

/// Column measure used to judge whether a side is prose.
const ColumnMeasure = struct {
    page_width: f64,
    body_em: f64,
    /// Column margins where prose lines start.
    left_start: f64,
    right_start: f64,
    /// Where full lines end: the gutter for the left column, the typical
    /// right edge for the right column.
    left_end: f64,
    right_end: f64,
};

/// A side reads as prose when it starts at its column margin, spans a
/// column-like width, runs to the column's far edge (as justified lines do; a
/// table stub stops short), and its runs are separated by word-sized gaps
/// rather than cell gaps. A long description cell of a full-width table
/// starts away from the column margin.
fn sideIsProse(runs: u32, x0: f64, x1: f64, max_gap: f64, start: f64, end: f64, measure: ColumnMeasure) bool {
    if (runs == 0) return false;
    return x0 >= start - 1.0 and x0 <= start + 2.5 * measure.body_em and
        x1 - x0 >= measure.page_width * 0.25 and x1 >= end - 2.0 * measure.body_em and
        (runs == 1 or max_gap <= measure.body_em * 1.5);
}

/// At least one side of a split row is column prose. A stub beside several
/// cells is a table row, not column prose.
fn proseSide(fact: RowFacts, measure: ColumnMeasure) bool {
    if (fact.left_runs + fact.right_runs <= 2) return fact.left_runs == 1 or fact.right_runs == 1;
    return sideIsProse(fact.left_runs, fact.left_x0, fact.left_x1, fact.left_max_gap, measure.left_start, measure.left_end, measure) or
        sideIsProse(fact.right_runs, fact.right_x0, fact.right_x1, fact.right_max_gap, measure.right_start, measure.right_end, measure);
}

fn rowBaseline(glyphs: []const GlyphSpan, order: []const u32, row_starts: []const usize, row: usize) f64 {
    return baselineCoordinate(glyphs[order[row_starts[row]]]);
}

fn compareGlyphX0(glyphs: []const GlyphSpan, a: u32, b: u32) bool {
    return glyphs[a].bbox.x0 < glyphs[b].bbox.x0;
}

const RowFacts = struct {
    left_x0: f64 = std.math.inf(f64),
    left_x1: f64 = -std.math.inf(f64),
    right_x0: f64 = std.math.inf(f64),
    right_x1: f64 = -std.math.inf(f64),
    left_runs: u32 = 0,
    right_runs: u32 = 0,
    /// Widest gap between consecutive runs on each side.
    left_max_gap: f64 = 0,
    right_max_gap: f64 = 0,
    straddles: bool = false,
    em: f64 = 0,

    fn hasLeft(self: RowFacts) bool {
        return self.left_runs > 0;
    }

    fn hasRight(self: RowFacts) bool {
        return self.right_runs > 0;
    }

    /// Add one bridged ink run. A run spanning the centre line marks a
    /// full-width row; otherwise the run belongs to the side of its centre.
    fn addRun(self: *RowFacts, x0: f64, x1: f64, centre: f64) void {
        if (x0 < centre and x1 > centre) {
            self.straddles = true;
            self.left_x0 = @min(self.left_x0, x0);
            return;
        }
        if ((x0 + x1) / 2.0 < centre) {
            if (self.left_runs > 0) self.left_max_gap = @max(self.left_max_gap, x0 - self.left_x1);
            self.left_x0 = @min(self.left_x0, x0);
            self.left_x1 = @max(self.left_x1, x1);
            self.left_runs += 1;
        } else {
            if (self.right_runs > 0) self.right_max_gap = @max(self.right_max_gap, x0 - self.right_x1);
            self.right_x0 = @min(self.right_x0, x0);
            self.right_x1 = @max(self.right_x1, x1);
            self.right_runs += 1;
        }
    }
};

const MarginMode = struct { x: f64 = 0, count: usize = 0, total: usize = 0 };

/// Most common start position (within a 1.5pt window) in O(n log n).
fn marginMode(allocator: std.mem.Allocator, starts: []const f64) !MarginMode {
    if (starts.len == 0) return .{};
    const sorted = try allocator.dupe(f64, starts);
    defer allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    var best: MarginMode = .{ .total = sorted.len };
    var low: usize = 0;
    for (sorted, 0..) |x, high| {
        while (x - sorted[low] > 1.5) low += 1;
        if (high - low + 1 > best.count) {
            best.count = high - low + 1;
            best.x = sorted[low];
        }
    }
    return best;
}

/// True when a meaningful share of rows begin at one common x position, which
/// is what a column's left margin looks like (paragraph indents excepted).
fn marginAligned(mode: MarginMode) bool {
    return mode.total >= 6 and mode.count * 100 >= mode.total * 35;
}

fn median(values: []f64) f64 {
    return percentile(values, 0.5);
}

fn percentile(values: []f64, fraction_value: f64) f64 {
    if (values.len == 0) return 0;
    std.mem.sort(f64, values, {}, std.sort.asc(f64));
    const index: usize = @intFromFloat(@floor(@as(f64, @floatFromInt(values.len - 1)) * fraction_value));
    return values[index];
}

fn detectCentralGutter(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    page_bbox: BBox,
) !?BBox {
    _ = allocator;
    const page_width = page_bbox.x1 - page_bbox.x0;
    if (page_width <= 0 or glyphs.len < 24) return null;
    const bin_count = 96;
    var occupancy: [bin_count]u32 = @splat(0);
    var first_baseline: [bin_count]?f64 = @splat(null);
    var first_em: [bin_count]f64 = @splat(0);
    var repeated_baseline: [bin_count]bool = @splat(false);
    var left_count: usize = 0;
    var right_count: usize = 0;

    for (glyphs) |glyph| {
        if (glyph.text.len == 0 or isWhitespace(glyph.text)) continue;
        const range = horizontalBinRange(glyph.bbox, page_bbox, bin_count);
        const baseline = baselineCoordinate(glyph);
        const em = baselineFontSize(glyph);
        for (range.first..range.last + 1) |bin| {
            if (first_baseline[bin]) |first| {
                if (@abs(first - baseline) > @max(1.5, @max(first_em[bin], em) * 0.55)) repeated_baseline[bin] = true;
            } else {
                first_baseline[bin] = baseline;
                first_em[bin] = em;
            }
        }
    }

    // Isolated centered footers must not carve a false edge into a real
    // gutter. Keep whole native runs when any of their occupied columns has
    // another baseline of support; do not truncate longer supported lines.
    var native_run_start: usize = 0;
    while (native_run_start < glyphs.len) {
        var run_end = native_run_start + 1;
        var run_bbox = glyphs[native_run_start].bbox;
        while (run_end < glyphs.len and inlineNeighbors(glyphs[run_end - 1], glyphs[run_end])) : (run_end += 1) {
            run_bbox = unionBox(run_bbox, glyphs[run_end].bbox);
        }
        const run_range = horizontalBinRange(run_bbox, page_bbox, bin_count);
        var supported = false;
        for (run_range.first..run_range.last + 1) |bin| supported = supported or repeated_baseline[bin];
        if (supported) for (glyphs[native_run_start..run_end]) |glyph| {
            if (glyph.text.len == 0 or isWhitespace(glyph.text)) continue;
            const range = horizontalBinRange(glyph.bbox, page_bbox, bin_count);
            for (range.first..range.last + 1) |bin| occupancy[bin] += 1;
        };
        native_run_start = run_end;
    }

    const allowed: u32 = @intCast(@max(1, glyphs.len / 800));
    const search_start = bin_count * 3 / 10;
    const search_end = bin_count * 7 / 10;
    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: ?usize = null;
    var bin: usize = search_start;
    while (bin < search_end) : (bin += 1) {
        if (occupancy[bin] <= allowed) {
            if (run_start == null) run_start = bin;
        } else if (run_start) |start| {
            if (bin - start > best_len) {
                best_start = start;
                best_len = bin - start;
            }
            run_start = null;
        }
    }
    if (run_start) |start| {
        if (search_end - start > best_len) {
            best_start = start;
            best_len = search_end - start;
        }
    }

    const gutter_width = @as(f64, @floatFromInt(best_len)) / bin_count * page_width;
    if (gutter_width < @max(12.0, page_width * 0.025)) return null;
    const gutter_x0 = page_bbox.x0 + @as(f64, @floatFromInt(best_start)) / bin_count * page_width;
    const gutter_x1 = gutter_x0 + gutter_width;
    const proposed_gutter = BBox{ .x0 = gutter_x0, .y0 = page_bbox.y0, .x1 = gutter_x1, .y1 = page_bbox.y1 };
    if (splitsContinuousWord(glyphs, proposed_gutter)) return null;
    for (glyphs) |glyph| {
        if (isWhitespace(glyph.text)) continue;
        const center = (glyph.bbox.x0 + glyph.bbox.x1) / 2.0;
        if (center < gutter_x0) left_count += 1;
        if (center > gutter_x1) right_count += 1;
    }
    if (left_count < 10 or right_count < 10) return null;
    if (baselineBandCount(glyphs, gutter_x0, true) < 2 or baselineBandCount(glyphs, gutter_x1, false) < 2) return null;
    return .{ .x0 = gutter_x0, .y0 = page_bbox.y0, .x1 = gutter_x1, .y1 = page_bbox.y1 };
}

fn horizontalBinRange(bbox: BBox, page_bbox: BBox, comptime count: usize) struct { first: usize, last: usize } {
    const scale = @as(f64, @floatFromInt(count)) / (page_bbox.x1 - page_bbox.x0);
    const x0 = @max(page_bbox.x0, @min(page_bbox.x1, bbox.x0));
    const x1 = @max(page_bbox.x0, @min(page_bbox.x1, bbox.x1));
    return .{
        .first = @min(count - 1, @as(usize, @intFromFloat(@floor((x0 - page_bbox.x0) * scale)))),
        .last = @min(count - 1, @as(usize, @intFromFloat(@floor((x1 - page_bbox.x0) * scale)))),
    };
}

fn inlineNeighbors(previous: GlyphSpan, current: GlyphSpan) bool {
    if (!sameOrientation(previous, current)) return false;
    const axis = writingAxis(previous);
    const dx = current.text_matrix[4] - previous.text_matrix[4];
    const dy = current.text_matrix[5] - previous.text_matrix[5];
    const normal_em = @max(baselineFontSize(previous), baselineFontSize(current));
    if (@abs(-dx * axis.y + dy * axis.x) > @max(1.5, normal_em * 0.55)) return false;
    const em = @max(1.0, @max(previous.font_size * axis.scale, current.font_size * writingAxis(current).scale));
    const font_space = @max(previous.font_space_advance * axis.scale, current.font_space_advance * writingAxis(current).scale);
    const threshold = if (font_space > 0 and std.math.isFinite(font_space)) font_space * 0.5 else em * 0.105;
    const gap = inlineGap(previous, current);
    return gap >= -em * 0.5 and gap <= threshold;
}

fn splitsContinuousWord(glyphs: []const GlyphSpan, gutter: BBox) bool {
    if (glyphs.len < 2) return false;
    for (glyphs[0 .. glyphs.len - 1], glyphs[1..]) |previous, current| {
        if (isWhitespace(previous.text) or isWhitespace(current.text) or !sameOrientation(previous, current) or
            regionForGlyph(previous.bbox, gutter) == regionForGlyph(current.bbox, gutter)) continue;
        if (inlineNeighbors(previous, current)) return true;
    }
    return false;
}

fn baselineBandCount(glyphs: []const GlyphSpan, split_x: f64, left_side: bool) usize {
    var bands: [64]f64 = undefined;
    var count: usize = 0;
    for (glyphs) |glyph| {
        if (isWhitespace(glyph.text)) continue;
        const center = (glyph.bbox.x0 + glyph.bbox.x1) / 2.0;
        if ((left_side and center >= split_x) or (!left_side and center <= split_x)) continue;
        const baseline = baselineCoordinate(glyph);
        var found = false;
        for (bands[0..count]) |existing| {
            if (@abs(existing - baseline) <= @max(1.5, glyph.font_size * 0.55)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (count == bands.len) return count;
            bands[count] = baseline;
            count += 1;
        }
    }
    return count;
}

fn orderLinesByRegions(
    allocator: std.mem.Allocator,
    lines: []const PendingLine,
    gutter: ?BBox,
    column_headings: bool,
) ![]u32 {
    const order = try allocator.alloc(u32, lines.len);
    errdefer allocator.free(order);
    if (gutter == null) {
        for (order, 0..) |*entry, index| entry.* = @intCast(index);
        return order;
    }

    var output: std.ArrayList(u32) = .empty;
    defer output.deinit(allocator);
    var weighted_size: f64 = 0;
    var glyph_count: usize = 0;
    var left_margin: f64 = std.math.inf(f64);
    for (lines) |line| {
        weighted_size += line.max_font_size * @as(f64, @floatFromInt(line.count));
        glyph_count += line.count;
        if (line.region_index == 0) left_margin = @min(left_margin, line.bbox.x0);
    }
    const body_size = if (glyph_count > 0) weighted_size / @as(f64, @floatFromInt(glyph_count)) else 12;
    var section_start: usize = 0;
    for (lines, 0..) |line, line_index| {
        if (line.region_index != 2 and !(column_headings and isColumnSectionHeading(lines, line_index, body_size, left_margin))) continue;
        try appendColumnSection(allocator, &output, lines, section_start, line_index);
        try output.append(allocator, @intCast(line_index));
        section_start = line_index + 1;
    }
    try appendColumnSection(allocator, &output, lines, section_start, lines.len);
    @memcpy(order, output.items);
    return order;
}

fn isColumnSectionHeading(lines: []const PendingLine, index: usize, body_size: f64, left_margin: f64) bool {
    const heading = lines[index];
    if (heading.region_index != 0 or heading.max_font_size < body_size * 1.18 or
        heading.bbox.x0 > left_margin + heading.max_font_size) return false;
    // A large left-column label is not by itself a section boundary. Require
    // a clear baseline across both columns, then content in both flows below
    // it before another heading. This leaves column-local headings local.
    const tolerance = @max(1.5, heading.max_font_size * 0.55);
    var previous_index = index;
    while (previous_index > 0) {
        previous_index -= 1;
        const line = lines[previous_index];
        if (line.baseline() - heading.baseline() > tolerance) break;
        if (line.region_index == 1 and @abs(line.baseline() - heading.baseline()) <= tolerance) return false;
    }
    for (lines[index + 1 ..]) |line| {
        if (heading.baseline() - line.baseline() > tolerance) break;
        if (line.region_index == 1 and @abs(line.baseline() - heading.baseline()) <= tolerance) return false;
    }
    var has_left = false;
    var has_right = false;
    for (lines[index + 1 ..]) |line| {
        if (line.baseline() >= heading.baseline() - tolerance) continue;
        if (line.region_index == 2 or
            (line.region_index == 0 and line.max_font_size >= body_size * 1.18 and
                line.bbox.x0 <= left_margin + line.max_font_size)) break;
        if (line.region_index == 0) has_left = true;
        if (line.region_index == 1) has_right = true;
        if (has_left and has_right) return true;
    }
    return false;
}

fn appendColumnSection(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u32),
    lines: []const PendingLine,
    start: usize,
    end: usize,
) !void {
    for (start..end) |index| {
        if (lines[index].region_index == 0) try output.append(allocator, @intCast(index));
    }
    for (start..end) |index| {
        if (lines[index].region_index == 1) try output.append(allocator, @intCast(index));
    }
}

fn regionForLine(bbox: BBox, gutter: ?BBox) u32 {
    const split = gutter orelse return 0;
    if (bbox.x1 <= split.x0) return 0;
    if (bbox.x0 >= split.x1) return 1;
    return 2;
}

fn regionForGlyph(bbox: BBox, gutter: ?BBox) u32 {
    const split = gutter orelse return 0;
    const center = (bbox.x0 + bbox.x1) / 2.0;
    if (center < split.x0) return 0;
    if (center > split.x1) return 1;
    return 2;
}

fn regionsCompatible(a: u32, b: u32) bool {
    return a == b or a == 2 or b == 2;
}

fn classifyBoundaries(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    ordered: []const u32,
    lines: []const Line,
) ![]Boundary {
    const boundaries = try allocator.alloc(Boundary, ordered.len);
    if (ordered.len == 0) return boundaries;
    // Short lines with too few pairs to judge inherit the page's evidence.
    var page_cancels_tracking = false;
    for (lines, 0..) |line, index| {
        const end = if (index + 1 < lines.len) lines[index + 1].ordered_start else ordered.len;
        if (lineCancelsTracking(glyphs, ordered[line.ordered_start..end]) == .cancelled) {
            page_cancels_tracking = true;
            break;
        }
    }
    var line_index: usize = 0;
    var next_line_start: usize = if (lines.len > 1) @intCast(lines[1].ordered_start) else ordered.len;
    var cancelled_tracking = lines.len > 0 and usesInkGaps(lineCancelsTracking(glyphs, ordered[0..next_line_start]), page_cancels_tracking);

    for (ordered, 0..) |glyph_index, ordered_index| {
        if (ordered_index == 0) {
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .kind = .region_break,
                .confidence = 1,
                .provenance = .content_start,
            };
            continue;
        }
        if (ordered_index == next_line_start) {
            const previous_line = lines[line_index];
            line_index += 1;
            const current_line = lines[line_index];
            next_line_start = if (line_index + 1 < lines.len) @intCast(lines[line_index + 1].ordered_start) else ordered.len;
            cancelled_tracking = usesInkGaps(lineCancelsTracking(glyphs, ordered[ordered_index..next_line_start]), page_cancels_tracking);
            const baseline_gap = @abs(previous_line.baseline - current_line.baseline);
            const paragraph_threshold = @max(previous_line.font_size, current_line.font_size) * 2.0;
            const region_changed = previous_line.region_index != current_line.region_index;
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .previous_glyph_index = ordered[ordered_index - 1],
                .kind = if (region_changed) .region_break else if (baseline_gap > paragraph_threshold) .block_break else .line_break,
                .confidence = if (region_changed) 0.88 else if (baseline_gap > paragraph_threshold) 0.86 else 0.93,
                .provenance = if (region_changed) .detected_gutter else if (baseline_gap > paragraph_threshold) .paragraph_gap else .baseline_shift,
                .baseline_offset = baseline_gap,
            };
            continue;
        }

        const previous_index = ordered[ordered_index - 1];
        const previous = glyphs[previous_index];
        const current = glyphs[glyph_index];
        if (isWhitespace(current.text)) {
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .previous_glyph_index = previous_index,
                .kind = .space,
                .confidence = if (current.generated) 0.96 else 0.995,
                .provenance = if (current.generated) .tj_adjustment else .explicit_whitespace,
            };
            continue;
        }
        if (isWhitespace(previous.text)) {
            boundaries[ordered_index] = .{
                .before_glyph_index = glyph_index,
                .previous_glyph_index = previous_index,
                .kind = .join,
                .confidence = 0.995,
                .provenance = if (previous.generated) .tj_adjustment else .explicit_whitespace,
            };
            continue;
        }

        const ink_gaps = cancelled_tracking or
            spacedEllipsisPair(glyphs, ordered, lines[line_index].ordered_start, ordered_index, next_line_start);
        const gap = if (ink_gaps) inlineGap(previous, current) + trackingAdvance(previous) else inlineGap(previous, current);
        const em = @max(1.0, @max(previous.font_size * writingAxis(previous).scale, current.font_size * writingAxis(current).scale));
        // Ink gaps exclude tracking, so the space width they are compared
        // with must exclude each glyph's own tracking too.
        const previous_space = previous.font_space_advance * writingAxis(previous).scale - (if (ink_gaps) trackingAdvance(previous) else 0);
        // The current glyph's tracking pads the gap after it, never before.
        const current_space = current.font_space_advance * writingAxis(current).scale - trackingAdvance(current);
        const font_space = @max(previous_space, current_space);
        const space_threshold = if (font_space > 0 and std.math.isFinite(font_space)) font_space * 0.5 else em * 0.105;
        const is_space = gap > space_threshold;
        const ratio = gap / em;
        boundaries[ordered_index] = .{
            .before_glyph_index = glyph_index,
            .previous_glyph_index = previous_index,
            .kind = if (is_space) .space else .join,
            .confidence = if (is_space) @floatCast(@min(0.96, 0.68 + ratio)) else @floatCast(@min(0.98, 0.82 + @max(0.0, (space_threshold - gap) / em))),
            .provenance = .geometric_gap,
            .inline_gap = gap,
            .baseline_offset = @abs(baselineCoordinate(previous) - baselineCoordinate(current)),
        };
    }
    return boundaries;
}

fn inlineGap(previous: GlyphSpan, current: GlyphSpan) f64 {
    const axis = writingAxis(previous);
    return (current.text_matrix[4] - previous.text_matrix[4]) * axis.x +
        (current.text_matrix[5] - previous.text_matrix[5]) * axis.y - previous.advance * axis.scale;
}

/// Positive character spacing carried by a glyph, in page units.
fn trackingAdvance(glyph: GlyphSpan) f64 {
    const spacing = glyph.spacing_advance * writingAxis(glyph).scale;
    return if (spacing > 0) spacing else 0;
}

/// Lines set with large positive character spacing that TJ kerns cancel
/// inside words (the gap between words is then only the spacing itself).
/// Ordinary tracking, which no kern cancels, keeps advance-based gaps so
/// letter-spaced headings stay whole.
fn lineCancelsTracking(glyphs: []const GlyphSpan, ordered: []const u32) TrackingEvidence {
    if (ordered.len < 2) return .none;
    var tracked_pairs: usize = 0;
    var cancelled_pairs: usize = 0;
    for (ordered[0 .. ordered.len - 1], ordered[1..]) |previous_index, current_index| {
        const previous = glyphs[previous_index];
        const current = glyphs[current_index];
        if (isWhitespace(previous.text) or isWhitespace(current.text)) continue;
        const em = @max(1.0, previous.font_size * writingAxis(previous).scale);
        const tracking = trackingAdvance(previous);
        if (tracking <= em * 0.15) continue;
        tracked_pairs += 1;
        if (inlineGap(previous, current) < -tracking * 0.7) cancelled_pairs += 1;
    }
    if (tracked_pairs == 0) return .none;
    // Cancelled tracking kerns every pair inside words, so at least half of
    // the tracked pairs cancel; optical kerning in a heading touches a few.
    if (tracked_pairs >= 4 and cancelled_pairs * 2 >= tracked_pairs) return .cancelled;
    return if (tracked_pairs < 4 and cancelled_pairs > 0) .inconclusive else .none;
}

const TrackingEvidence = enum { none, inconclusive, cancelled };

/// Spaced ellipses (". . .") are often set as periods, and the character
/// before them, carrying character spacing of about one word space with no
/// cancelling kerns; each visible gap is then a space. Only pairs touching a
/// run of at least two periods qualify, so a tracked "U.S.A." stays whole.
fn spacedEllipsisPair(glyphs: []const GlyphSpan, ordered: []const u32, line_start: usize, index: usize, line_end: usize) bool {
    const previous = glyphs[ordered[index - 1]];
    const current = glyphs[ordered[index]];
    if (!tracksByWordSpace(previous)) return false;
    if (isPeriod(previous)) {
        if (isPeriod(current)) return true;
        return index >= line_start + 2 and isPeriod(glyphs[ordered[index - 2]]);
    }
    return isPeriod(current) and index + 1 < line_end and isPeriod(glyphs[ordered[index + 1]]);
}

fn isPeriod(glyph: GlyphSpan) bool {
    return std.mem.eql(u8, glyph.text, ".");
}

/// Character spacing close to a word space. The declared space can carry
/// word spacing (Tw) or be missing in subset fonts, so it is capped at a
/// typical quarter-em space.
fn tracksByWordSpace(glyph: GlyphSpan) bool {
    const tracking = trackingAdvance(glyph);
    if (tracking <= 0) return false;
    const quarter_em = glyph.font_size * writingAxis(glyph).scale * 0.25;
    const declared = glyph.font_space_advance * writingAxis(glyph).scale - tracking;
    const reference = if (declared > 0 and std.math.isFinite(declared)) @min(declared, quarter_em) else quarter_em;
    return reference > 0 and tracking >= reference * 0.8;
}

fn usesInkGaps(evidence: TrackingEvidence, page_cancels_tracking: bool) bool {
    return evidence == .cancelled or (evidence == .inconclusive and page_cancels_tracking);
}

fn renderReadable(
    allocator: std.mem.Allocator,
    glyphs: []const GlyphSpan,
    ordered: []const u32,
    boundaries: []const Boundary,
    lines: []Line,
) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var mutable_lines = @constCast(lines);
    var line_index: usize = 0;

    for (ordered, 0..) |glyph_index, ordered_index| {
        const boundary = boundaries[ordered_index];
        if (ordered_index > 0) switch (boundary.kind) {
            .join => {},
            .space => if (!endsInWhitespace(output.items) and !(glyphs[glyph_index].actual_text and startsInWhitespace(glyphs[glyph_index].text))) try output.append(allocator, ' '),
            .line_break => try appendBreak(allocator, &output, 1),
            .block_break, .region_break => try appendBreak(allocator, &output, 2),
        };
        while (line_index + 1 < mutable_lines.len and ordered_index == mutable_lines[line_index + 1].ordered_start) {
            mutable_lines[line_index].text_len = @intCast(output.items.len - mutable_lines[line_index].text_start);
            line_index += 1;
            mutable_lines[line_index].text_start = @intCast(output.items.len);
        }
        try appendNormalizedGlyph(allocator, &output, glyphs[glyph_index].text, glyphs[glyph_index].actual_text);
    }
    if (mutable_lines.len > 0) {
        mutable_lines[line_index].text_len = @intCast(output.items.len - mutable_lines[line_index].text_start);
    }
    if (ordered.len == 0 or !glyphs[ordered[ordered.len - 1]].actual_text) trimTrailingWhitespace(&output);
    synchronizeLineTextRanges(mutable_lines, output.items.len);
    return output.toOwnedSlice(allocator);
}

fn synchronizeLineTextRanges(lines: []Line, text_len: usize) void {
    // Final trimming can remove separators assigned to preceding lines and all
    // bytes from whitespace-only trailing lines. Keep every recorded range
    // inside the finalized output rather than retaining offsets to trimmed data.
    for (lines) |*line| {
        const original_start: usize = @intCast(line.text_start);
        const synchronized_start = @min(original_start, text_len);
        const available_len = text_len - synchronized_start;
        line.text_start = @intCast(synchronized_start);
        line.text_len = @intCast(@min(@as(usize, @intCast(line.text_len)), available_len));
    }
}

fn appendNormalizedGlyph(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8, actual_text: bool) !void {
    if (actual_text) {
        try output.appendSlice(allocator, text);
        return;
    }
    if (isWhitespace(text)) {
        if (output.items.len > 0 and !endsInWhitespace(output.items)) try output.append(allocator, ' ');
        return;
    }
    try output.appendSlice(allocator, text);
}

fn appendBreak(allocator: std.mem.Allocator, output: *std.ArrayList(u8), count: usize) !void {
    trimTrailingSpaces(output);
    var existing: usize = 0;
    var index = output.items.len;
    while (index > 0 and output.items[index - 1] == '\n') : (index -= 1) existing += 1;
    var needed = count -| existing;
    while (needed > 0) : (needed -= 1) try output.append(allocator, '\n');
}

fn isWhitespace(text: []const u8) bool {
    if (text.len == 0) return false;
    var index: usize = 0;
    while (index < text.len) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch return false;
        if (index + sequence_len > text.len) return false;
        const codepoint = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch return false;
        if (!isWhitespaceCodepoint(codepoint)) return false;
        index += sequence_len;
    }
    return true;
}

fn isWhitespaceCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009...0x000d,
        0x0020,
        0x0085,
        0x00a0,
        0x1680,
        0x2000...0x200a,
        0x2028,
        0x2029,
        0x202f,
        0x205f,
        0x3000,
        => true,
        else => false,
    };
}

fn qualityForText(raw: []const u8, readable: []const u8) QualityMetrics {
    var metrics = QualityMetrics{};
    metrics.raw_non_whitespace_recall = byteMultisetRecall(raw, readable);
    var token_len: usize = 0;
    var line_len: usize = 0;
    var token_count: usize = 0;
    var line_count: usize = 0;
    var extreme_tokens: usize = 0;
    var extreme_lines: usize = 0;
    for (readable) |byte| {
        if (byte == '\n' or byte == '\r') {
            metrics.max_line_bytes = @max(metrics.max_line_bytes, line_len);
            metrics.max_token_bytes = @max(metrics.max_token_bytes, token_len);
            if (line_len > 0) {
                line_count += 1;
                if (line_len > 1000) extreme_lines += 1;
            }
            if (token_len > 0) {
                token_count += 1;
                if (token_len > 80) extreme_tokens += 1;
            }
            line_len = 0;
            token_len = 0;
        } else {
            line_len += 1;
            if (std.ascii.isWhitespace(byte)) {
                metrics.max_token_bytes = @max(metrics.max_token_bytes, token_len);
                if (token_len > 0) {
                    token_count += 1;
                    if (token_len > 80) extreme_tokens += 1;
                }
                token_len = 0;
            } else {
                token_len += 1;
            }
        }
    }
    metrics.max_line_bytes = @max(metrics.max_line_bytes, line_len);
    metrics.max_token_bytes = @max(metrics.max_token_bytes, token_len);
    if (line_len > 0) {
        line_count += 1;
        if (line_len > 1000) extreme_lines += 1;
    }
    if (token_len > 0) {
        token_count += 1;
        if (token_len > 80) extreme_tokens += 1;
    }
    metrics.extreme_token_length_rate = fraction(extreme_tokens, token_count);
    metrics.extreme_line_length_rate = fraction(extreme_lines, line_count);
    return metrics;
}

fn passesQualityGate(metrics: QualityMetrics, glyph_count: usize) bool {
    if (metrics.raw_non_whitespace_recall < 0.995) return false;
    if (metrics.max_token_bytes > 160 or metrics.max_line_bytes > 4096) return false;
    if (metrics.extreme_token_length_rate > 0.02 or metrics.extreme_line_length_rate > 0.05) return false;
    if (glyph_count >= 200 and metrics.word_boundary_count == 0) return false;
    if (metrics.word_boundary_precision) |value| if (value < 0.80) return false;
    if (metrics.word_boundary_recall) |value| if (value < 0.80) return false;
    if (metrics.line_break_f1) |value| if (value < 0.70) return false;
    if (metrics.token_f1) |value| if (value < 0.85) return false;
    if (metrics.word_error_rate) |value| if (value > 0.25) return false;
    return true;
}

fn fraction(numerator: usize, denominator: usize) f64 {
    if (denominator == 0) return 0;
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn byteMultisetRecall(expected: []const u8, actual: []const u8) f64 {
    var expected_counts: [256]usize = @splat(0);
    var actual_counts: [256]usize = @splat(0);
    var expected_total: usize = 0;
    for (expected) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        expected_counts[byte] += 1;
        expected_total += 1;
    }
    if (expected_total == 0) return 1;
    for (actual) |byte| {
        if (std.ascii.isWhitespace(byte)) continue;
        actual_counts[byte] += 1;
    }
    var matched: usize = 0;
    for (expected_counts, actual_counts) |expected_count, actual_count| matched += @min(expected_count, actual_count);
    return @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(expected_total));
}

fn boundarySignature(allocator: std.mem.Allocator, text: []const u8) !BoundarySignature {
    var signature = BoundarySignature{};
    errdefer signature.deinit(allocator);
    var non_whitespace_count: u32 = 0;
    var pending_word = false;
    var pending_line = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_word = true;
            if (byte == '\n' or byte == '\r' or byte == '\x0c') pending_line = true;
            continue;
        }
        if (non_whitespace_count > 0) {
            if (pending_word) try appendUniqueBoundary(allocator, &signature.word, non_whitespace_count);
            if (pending_line) try appendUniqueBoundary(allocator, &signature.line, non_whitespace_count);
        }
        try signature.non_whitespace.append(allocator, byte);
        non_whitespace_count += 1;
        pending_word = false;
        pending_line = false;
    }
    return signature;
}

fn appendUniqueBoundary(allocator: std.mem.Allocator, list: *std.ArrayList(u32), boundary: u32) !void {
    if (list.items.len == 0 or list.items[list.items.len - 1] != boundary) try list.append(allocator, boundary);
}

const PrecisionRecall = struct { precision: f64, recall: f64 };

fn precisionRecall(expected: []const u32, actual: []const u32) PrecisionRecall {
    var expected_index: usize = 0;
    var actual_index: usize = 0;
    var matched: usize = 0;
    while (expected_index < expected.len and actual_index < actual.len) {
        if (expected[expected_index] == actual[actual_index]) {
            matched += 1;
            expected_index += 1;
            actual_index += 1;
        } else if (expected[expected_index] < actual[actual_index]) {
            expected_index += 1;
        } else {
            actual_index += 1;
        }
    }
    return .{
        .precision = if (actual.len == 0) if (expected.len == 0) 1 else 0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(actual.len)),
        .recall = if (expected.len == 0) if (actual.len == 0) 1 else 0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(expected.len)),
    };
}

fn f1(precision: f64, recall: f64) f64 {
    if (precision + recall == 0) return 0;
    return 2.0 * precision * recall / (precision + recall);
}

const TokenMetrics = struct { f1: f64, wer: f64 };

fn compareTokens(allocator: std.mem.Allocator, expected_text: []const u8, actual_text: []const u8) !TokenMetrics {
    const expected = try tokenize(allocator, expected_text);
    defer allocator.free(expected);
    const actual = try tokenize(allocator, actual_text);
    defer allocator.free(actual);

    var counts = std.StringHashMap(usize).init(allocator);
    defer counts.deinit();
    for (expected) |token| {
        const entry = try counts.getOrPut(token);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    var matched: usize = 0;
    for (actual) |token| {
        if (counts.getPtr(token)) |count| {
            if (count.* > 0) {
                count.* -= 1;
                matched += 1;
            }
        }
    }
    const precision: f64 = if (actual.len == 0) if (expected.len == 0) 1.0 else 0.0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(actual.len));
    const recall: f64 = if (expected.len == 0) if (actual.len == 0) 1.0 else 0.0 else @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(expected.len));
    const edits = try tokenEditDistance(allocator, expected, actual);
    return .{
        .f1 = f1(precision, recall),
        .wer = if (expected.len == 0) if (actual.len == 0) @as(f64, 0) else @as(f64, 1) else @as(f64, @floatFromInt(edits)) / @as(f64, @floatFromInt(expected.len)),
    };
}

fn tokenize(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    errdefer tokens.deinit(allocator);
    var iterator = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
    while (iterator.next()) |token| try tokens.append(allocator, token);
    return tokens.toOwnedSlice(allocator);
}

fn tokenEditDistance(allocator: std.mem.Allocator, expected: []const []const u8, actual: []const []const u8) !usize {
    var previous = try allocator.alloc(usize, actual.len + 1);
    defer allocator.free(previous);
    var current = try allocator.alloc(usize, actual.len + 1);
    defer allocator.free(current);
    for (previous, 0..) |*value, index| value.* = index;
    for (expected, 0..) |expected_token, expected_index| {
        current[0] = expected_index + 1;
        for (actual, 0..) |actual_token, actual_index| {
            const substitution = previous[actual_index] + @intFromBool(!std.mem.eql(u8, expected_token, actual_token));
            current[actual_index + 1] = @min(substitution, @min(current[actual_index] + 1, previous[actual_index + 1] + 1));
        }
        const swap = previous;
        previous = current;
        current = swap;
    }
    return previous[actual.len];
}

fn countBoundaryKind(boundaries: []const Boundary, kind: BoundaryKind) usize {
    var count: usize = 0;
    for (boundaries) |boundary| count += @intFromBool(boundary.kind == kind);
    return count;
}

fn countLineBoundaries(boundaries: []const Boundary) usize {
    var count: usize = 0;
    for (boundaries) |boundary| switch (boundary.kind) {
        .line_break, .block_break, .region_break => count += 1,
        else => {},
    };
    return count -| 1;
}

fn lineConfidence(result: *const Result, line: Line) f32 {
    const start: usize = @intCast(line.ordered_start);
    const end = start + @as(usize, @intCast(line.glyph_count));
    if (end <= start) return 0;
    var sum: f32 = 0;
    for (result.boundaries[start..end]) |boundary| sum += boundary.confidence;
    return sum / @as(f32, @floatFromInt(end - start));
}

fn endsInWhitespace(text: []const u8) bool {
    if (text.len == 0) return false;
    return std.ascii.isWhitespace(text[text.len - 1]);
}

fn startsInWhitespace(text: []const u8) bool {
    if (text.len == 0) return false;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return false;
    if (len > text.len) return false;
    return isWhitespaceCodepoint(std.unicode.utf8Decode(text[0..len]) catch return false);
}

fn trimTrailingSpaces(output: *std.ArrayList(u8)) void {
    while (output.items.len > 0 and (output.items[output.items.len - 1] == ' ' or output.items[output.items.len - 1] == '\t')) _ = output.pop();
}

fn trimTrailingWhitespace(output: *std.ArrayList(u8)) void {
    while (output.items.len > 0 and std.ascii.isWhitespace(output.items[output.items.len - 1])) _ = output.pop();
}

fn unionBox(a: BBox, b: BBox) BBox {
    return .{
        .x0 = @min(a.x0, b.x0),
        .y0 = @min(a.y0, b.y0),
        .x1 = @max(a.x1, b.x1),
        .y1 = @max(a.y1, b.y1),
    };
}

fn testGlyph(text: []const u8, x: f64, y: f64, advance: f64) GlyphSpan {
    return .{
        .bbox = .{ .x0 = x, .y0 = y - 2, .x1 = x + advance, .y1 = y + 9 },
        .text_matrix = .{ 1, 0, 0, 1, x, y },
        .font_size = 12,
        .text = text,
        .advance = advance,
    };
}

test "line spans retain original Tf while carrying private glyph normal scale" {
    var glyph = testGlyph("A", 100, 700, 6);
    glyph.font_size = 1;
    glyph.text_matrix = .{ 12, 0, 0, 12, 100, 700 };
    glyph.bbox.y0 = 698;
    glyph.bbox.y1 = 710.28;
    var result = try analyze(std.testing.allocator, &.{glyph}, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "A");
    defer result.deinit();
    const spans = try buildLineSpans(std.testing.allocator, &.{glyph}, &result, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(f64, 1), spans[0].font.size);
    try std.testing.expectEqual(@as(f64, 1), spans[0].font_size);
    try std.testing.expectEqual(@as(?f64, 12), spans[0].layout_font_size);
    try std.testing.expectApproxEqAbs(@as(f64, 12.28), spans[0].y1 - spans[0].y0, 0.000001);
}

test "line spans retain inverse-scaled Tf120 with private 12pt normal scale" {
    var glyph = testGlyph("A", 100, 700, 6);
    glyph.font_size = 120;
    glyph.text_matrix = .{ 0.1, 0, 0, 0.1, 100, 700 };
    var result = try analyze(std.testing.allocator, &.{glyph}, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "A");
    defer result.deinit();
    const spans = try buildLineSpans(std.testing.allocator, &.{glyph}, &result, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(@as(f64, 120), spans[0].font.size);
    try std.testing.expectEqual(@as(f64, 120), spans[0].font_size);
    try std.testing.expectApproxEqAbs(@as(f64, 12), spans[0].layout_font_size.?, 0.000001);
}

test "glyph geometry reconstructs missing spaces and line breaks" {
    const glyphs = [_]GlyphSpan{
        testGlyph("Hello", 72, 700, 26),
        testGlyph("world", 102, 700, 27),
        testGlyph("Second", 72, 682, 36),
        testGlyph("line", 112, 682, 18),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "Helloworld\nSecondline");
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello world\nSecond line", result.text);
    try std.testing.expect(result.quality.quality_pass);
    try std.testing.expectEqual(BoundaryKind.space, result.boundaries[1].kind);
    try std.testing.expectEqual(BoundaryKind.line_break, result.boundaries[2].kind);
}

fn rotatedTestGlyph(text: []const u8, distance: f64, vertical: bool) GlyphSpan {
    const component = @sqrt(@as(f64, 0.5));
    var glyph = testGlyph(text, 100 + distance * component * 2, 100 + distance * component * 2 * (if (vertical) @as(f64, -1) else 1), 6);
    glyph.text_matrix[0] = component * 2;
    glyph.text_matrix[1] = component * 2;
    glyph.text_matrix[2] = -component * 2;
    glyph.text_matrix[3] = component * 2;
    glyph.font_space_advance = 3;
    glyph.writing_mode = if (vertical) 1 else 0;
    return glyph;
}

test "opposite writing axes remain separate lines on a coincident baseline" {
    const first = testGlyph("A", 0, 0, 6);
    var opposite = testGlyph("B", 10, 0, 6);
    opposite.text_matrix[0] = -1;
    opposite.text_matrix[3] = -1;
    const glyphs = [_]GlyphSpan{ first, opposite };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = -100, .y0 = -100, .x1 = 100, .y1 = 100 }, "AB");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expect(std.mem.indexOfScalar(u8, result.text, 'A') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, result.text, 'B') != null);
    try std.testing.expect(sameOrientation(first, first));
    try std.testing.expect(!sameOrientation(first, opposite));
    var quarter_turn = first;
    quarter_turn.text_matrix = .{ 0, 1, -1, 0, 0, 0 };
    try std.testing.expect(!sameOrientation(first, quarter_turn));
    var invalid = first;
    invalid.text_matrix = @splat(0);
    try std.testing.expect(!sameOrientation(first, invalid));
    var vertical = first;
    vertical.writing_mode = 1;
    var vertical_opposite = vertical;
    vertical_opposite.text_matrix[3] = -1;
    try std.testing.expect(!sameOrientation(vertical, vertical_opposite));
}

fn glyphGeometryAllocationProbe(allocator: std.mem.Allocator) !void {
    var first = testGlyph("fi", 10, 10, 6);
    first.quad = .{ .{ 10, 8 }, .{ 16, 8 }, .{ 16, 20 }, .{ 10, 20 } };
    var replacement = testGlyph("semantic", 25, 10, 12);
    replacement.actual_text = true;
    replacement.semantic_replacement = true;
    const glyphs = [_]GlyphSpan{ first, replacement };
    var result = try analyze(allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 200 }, "fisemantic");
    defer result.deinit();
    const spans = try buildLineSpansWithGeometry(allocator, &glyphs, &result, 0, true);
    defer {
        for (spans) |span| {
            allocator.free(span.text);
            if (span.font.name) |name| allocator.free(name);
            allocator.free(span.glyph_geometry);
        }
        allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("fi", spans[0].text);
    try std.testing.expectEqual(@as(usize, 1), spans[0].glyph_geometry.len);
    const ligature = spans[0].glyph_geometry[0];
    try std.testing.expectEqual(@as(usize, 2), ligature.text_end_byte);
    try std.testing.expect(ligature.quad != null);
    const semantic = spans[1].glyph_geometry[0];
    try std.testing.expect(semantic.precision == .replacement_group);
    try std.testing.expect(semantic.quad == null);
    try std.testing.expectEqualStrings("semantic", spans[1].text[semantic.text_start_byte..semantic.text_end_byte]);
}

test "source glyph geometry retains ligatures and coarse ActualText through allocation failure" {
    try glyphGeometryAllocationProbe(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, glyphGeometryAllocationProbe, .{});
}

test "projected rotated advances preserve within-word joins and real word gaps" {
    const glyphs = [_]GlyphSpan{
        rotatedTestGlyph("A", 0, false),  rotatedTestGlyph("B", 6, false),
        rotatedTestGlyph("C", 15, false), rotatedTestGlyph("D", 21, false),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 300 }, "ABCD");
    defer result.deinit();
    try std.testing.expectEqualStrings("AB CD", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqual(BoundaryKind.join, result.boundaries[1].kind);
    try std.testing.expectEqual(BoundaryKind.space, result.boundaries[2].kind);
}

test "projected vertical advances support rotation and font-space evidence" {
    const glyphs = [_]GlyphSpan{
        rotatedTestGlyph("A", 0, true),  rotatedTestGlyph("B", 6, true),
        rotatedTestGlyph("C", 15, true), rotatedTestGlyph("D", 21, true),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 300 }, "ABCD");
    defer result.deinit();
    try std.testing.expectEqualStrings("AB CD", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
}

test "scaled baseline bands retain mixed-font superscripts on the same line" {
    var first = testGlyph("F", 100, 100, 6);
    first.text_matrix[0] = 2;
    first.text_matrix[3] = 2;
    var superscript = testGlyph("1", 112, 110, 4);
    superscript.font_size = 8;
    superscript.text_matrix[0] = 2;
    superscript.text_matrix[3] = 2;
    var tail = testGlyph(".25", 120, 100, 12);
    tail.text_matrix[0] = 2;
    tail.text_matrix[3] = 2;
    const glyphs = [_]GlyphSpan{ first, superscript, tail };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 300 }, "F1.25");
    defer result.deinit();
    try std.testing.expectEqualStrings("F1.25", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
}

test "column order resets at corroborated section headings" {
    var lines: [10]PendingLine = undefined;
    for (&lines, 0..) |*line, index| {
        const local = index % 5;
        const heading = local == 0;
        const right = local == 2 or local == 4;
        const y: f64 = 750 - @as(f64, @floatFromInt(index / 5)) * 190 -
            (if (heading) @as(f64, 0) else if (local <= 2) @as(f64, 50) else @as(f64, 100));
        line.* = .{ .start = index, .count = 20, .baseline_sum = y * 20, .baseline_count = 20, .max_font_size = if (heading) 18 else 12, .bbox = .{ .x0 = if (right) 330 else 60, .x1 = if (right) 500 else 200, .y0 = y, .y1 = y + 12 }, .region_index = if (right) 1 else 0 };
    }
    const gutter = BBox{ .x0 = 280, .x1 = 310, .y0 = 0, .y1 = 792 };
    const order = try orderLinesByRegions(std.testing.allocator, &lines, gutter, true);
    defer std.testing.allocator.free(order);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 3, 2, 4, 5, 6, 8, 7, 9 }, order);
    // A right-flow label on the same baseline is contrary evidence, even
    // when the left label is larger than body text.
    lines[6].baseline_sum = lines[5].baseline_sum;
    lines[6].region_index = 1;
    try std.testing.expect(!isColumnSectionHeading(&lines, 5, 13, 60));
}

test "column gutter cannot split a continuous transformed word at paint boundaries" {
    const words = [_][]const u8{ "VISIBLE", "HIDDEN", "CLIPPED", "TRANSFORMED" };
    const xs = [_]f64{ 20, 20, 180, 50 };
    const ys = [_]f64{ 260, 230, 180, 60 };
    var glyphs: [31]GlyphSpan = undefined;
    var count: usize = 0;
    for (words, 0..) |word, row| {
        for (word, 0..) |_, letter| {
            const scale: f64 = if (row == 3) 2 else 1;
            const advance: f64 = if (row == 3) 8 else 6;
            const x = xs[row] + @as(f64, @floatFromInt(letter)) * advance * scale;
            var glyph = testGlyph(word[letter .. letter + 1], x, ys[row], advance);
            glyph.text_matrix[0] = scale;
            glyph.text_matrix[3] = scale;
            glyph.bbox.x1 = x + advance * scale;
            glyph.font_space_advance = 3;
            if (row == 3) {
                glyph.paint = (layout.PaintEvidence{ .rendering_mode = 0, .paint_state = .painting, .clip_bbox = .{ .x0 = 30, .y0 = 40, .x1 = 130, .y1 = 140 } }).forBBox(glyph.bbox);
            }
            glyphs[count] = glyph;
            count += 1;
        }
    }
    var native = try analyze(std.testing.allocator, glyphs[0..count], .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 300 }, "VISIBLE HIDDEN CLIPPED TRANSFORMED");
    defer native.deinit();
    try std.testing.expect(native.gutter == null);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "TRANSFORMED") != null);
    const spans = try buildLineSpans(std.testing.allocator, glyphs[0..count], &native, 0);
    defer {
        for (spans) |span| std.testing.allocator.free(@constCast(span.text));
        std.testing.allocator.free(spans);
    }
    var reconciled = try @import("reconcile.zig").reconcile(std.testing.allocator, &.{.{ .spans = spans }}, .{ .preserve_input_order = true });
    defer reconciled.deinit();
    try std.testing.expect(std.mem.indexOf(u8, reconciled.chunks[0].content, "TRANSFORMED") != null);
}

test "word-continuity guard preserves corroborated two-column gutters" {
    var glyphs: [54]GlyphSpan = undefined;
    var count: usize = 0;
    for ([_]f64{ 260, 240 }) |y| {
        for ([_][]const u8{ "LEFTPARAGRAPH", "RIGHTPARAGRAPH" }, 0..) |word, column| {
            const x: f64 = if (column == 0) 20 else 180;
            for (word, 0..) |_, index| {
                var glyph = testGlyph(word[index .. index + 1], x + @as(f64, @floatFromInt(index)) * 6, y, 6);
                glyph.font_space_advance = 3;
                glyphs[count] = glyph;
                count += 1;
            }
        }
    }
    var native = try analyze(std.testing.allocator, glyphs[0..count], .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 300 }, "LEFTPARAGRAPH RIGHTPARAGRAPH LEFTPARAGRAPH RIGHTPARAGRAPH");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try std.testing.expectEqualStrings("LEFTPARAGRAPH\nLEFTPARAGRAPH\n\nRIGHTPARAGRAPH\nRIGHTPARAGRAPH", native.text);
}

test "central footer does not veto corroborated columns or split its own word" {
    var glyphs: [56]GlyphSpan = undefined;
    var count: usize = 0;
    for ([_]f64{ 720, 700 }) |y| {
        for ([_][]const u8{ "LEFTPARAGRAPH", "RIGHTPARAGRAPH" }, 0..) |word, column| {
            const x: f64 = if (column == 0) 72 else 330;
            for (word, 0..) |_, index| {
                var glyph = testGlyph(word[index .. index + 1], x + @as(f64, @floatFromInt(index)) * 6, y, 6);
                glyph.font_space_advance = 3;
                glyphs[count] = glyph;
                count += 1;
            }
        }
    }
    glyphs[count] = testGlyph("4", 300, 60, 6);
    glyphs[count + 1] = testGlyph("2", 306, 60, 6);
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "LEFTPARAGRAPH RIGHTPARAGRAPH LEFTPARAGRAPH RIGHTPARAGRAPH 42");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try std.testing.expectEqualStrings("LEFTPARAGRAPH\nLEFTPARAGRAPH\n\nRIGHTPARAGRAPH\nRIGHTPARAGRAPH\n\n42", native.text);
}

fn appendTestWord(list: *std.ArrayList(GlyphSpan), allocator: std.mem.Allocator, word: []const u8, x: f64, y: f64) !f64 {
    for (word, 0..) |_, index| {
        try list.append(allocator, testGlyph(word[index .. index + 1], x + @as(f64, @floatFromInt(index)) * 6, y, 6));
    }
    return x + @as(f64, @floatFromInt(word.len)) * 6;
}

/// A journal page: a 12pt gutter (narrower than the strict detector accepts),
/// a full-width caption crossing it, optional table rows, then prose columns.
fn narrowGutterPage(allocator: std.mem.Allocator, with_table: bool) !std.ArrayList(GlyphSpan) {
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    errdefer glyphs.deinit(allocator);
    var y: f64 = 740;
    var x: f64 = 49;
    for (0..6) |_| x = try appendTestWord(&glyphs, allocator, "Caption", x, y) + 3;
    if (with_table) {
        for ([_][]const u8{ "Tablea", "Tableb", "Tablec" }) |cell| {
            y -= 20;
            for ([_]f64{ 49, 200, 330, 480 }) |cell_x| _ = try appendTestWord(&glyphs, allocator, cell, cell_x, y);
        }
    }
    for (0..12) |row| {
        y -= 20;
        const left_markers = [_][]const u8{ "Laxxx", "Lbxxx", "Lcxxx", "Ldxxx", "Lexxx", "Lfxxx", "Lgxxx", "Lhxxx", "Lixxx", "Ljxxx", "Lkxxx", "Llxxx" };
        const right_markers = [_][]const u8{ "Raxxx", "Rbxxx", "Rcxxx", "Rdxxx", "Rexxx", "Rfxxx", "Rgxxx", "Rhxxx", "Rixxx", "Rjxxx", "Rkxxx", "Rlxxx" };
        for ([_]f64{ 49, 312 }, [_][]const u8{ left_markers[row], right_markers[row] }) |column_x, marker| {
            var word_x = column_x;
            word_x = try appendTestWord(&glyphs, allocator, marker, word_x, y) + 4;
            for (0..6) |_| word_x = try appendTestWord(&glyphs, allocator, "words", word_x, y) + 4;
        }
    }
    return glyphs;
}

test "narrow journal gutter with a crossing caption reads columns in order" {
    const allocator = std.testing.allocator;
    var glyphs = try narrowGutterPage(allocator, false);
    defer glyphs.deinit(allocator);
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 783 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    const text = native.text;
    const caption = std.mem.indexOf(u8, text, "Caption").?;
    const left_first = std.mem.indexOf(u8, text, "Laxxx").?;
    const left_last = std.mem.indexOf(u8, text, "Llxxx").?;
    const right_first = std.mem.indexOf(u8, text, "Raxxx").?;
    try std.testing.expect(caption < left_first);
    try std.testing.expect(left_first < left_last);
    try std.testing.expect(left_last < right_first);
    // No line mixes the two columns.
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(!(std.mem.indexOfScalar(u8, line, 'L') != null and std.mem.indexOfScalar(u8, line, 'R') != null));
    }
}

test "table rows above narrow columns stay in row order" {
    const allocator = std.testing.allocator;
    var glyphs = try narrowGutterPage(allocator, true);
    defer glyphs.deinit(allocator);
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 783 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    const text = native.text;
    // Each table row is read across before the next row starts.
    const row_a = std.mem.lastIndexOf(u8, text, "Tablea").?;
    const row_b = std.mem.indexOf(u8, text, "Tableb").?;
    try std.testing.expect(row_a < row_b);
    try std.testing.expect(std.mem.indexOf(u8, text, "Tablea Tablea Tablea Tablea") != null);
    try std.testing.expect(std.mem.lastIndexOf(u8, text, "Tablec").? < std.mem.indexOf(u8, text, "Laxxx").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Llxxx").? < std.mem.indexOf(u8, text, "Raxxx").?);
}

test "single-column prose with an aligned river is not split into columns" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    // Every line has a wide gap at the same x, but the text after it starts at
    // varying positions, so it is not a column margin.
    for (0..16) |row| {
        const y = 700 - @as(f64, @floatFromInt(row)) * 20;
        var x: f64 = 72;
        for (0..6) |_| x = try appendTestWord(&glyphs, allocator, "words", x, y) + 4;
        x = 286 + @as(f64, @floatFromInt(row % 5)) * 3;
        for (0..6) |_| x = try appendTestWord(&glyphs, allocator, "after", x, y) + 4;
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter == null);
}

test "character spacing cancelled by kerning keeps visible word gaps" {
    // Tc = 4pt pads every advance; TJ kerns cancel it inside words, so the
    // only real gaps are between words (the page-12 pattern of the Rosengren
    // et al. 2020 paper).
    const words = [_][]const u8{ "ab", "cd", "ef", "gh" };
    var glyphs: [8]GlyphSpan = undefined;
    var x: f64 = 0;
    var count: usize = 0;
    for (words) |word| {
        for (word, 0..) |_, index| {
            var glyph = testGlyph(word[index .. index + 1], x, 100, 10);
            glyph.spacing_advance = 4;
            glyphs[count] = glyph;
            count += 1;
            x += if (index + 1 < word.len) 6 else 10;
        }
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 200 }, "ab cd ef gh");
    defer native.deinit();
    try std.testing.expectEqualStrings("ab cd ef gh", native.text);
}

test "periods tracked by a full space read as a spaced ellipsis" {
    var glyphs: [6]GlyphSpan = undefined;
    // "so. . . Then": each period carries Tc equal to the bare space width.
    const texts = [_][]const u8{ "s", "o", ".", ".", ".", "T" };
    const xs = [_]f64{ 100, 105, 110, 115, 120, 125 };
    for (texts, xs, 0..) |text, x, index| {
        var glyph = testGlyph(text, x, 700, 5);
        glyph.font_space_advance = 2.5;
        if (std.mem.eql(u8, text, ".")) {
            glyph.spacing_advance = 2.5;
            glyph.font_space_advance = 5;
        }
        glyphs[index] = glyph;
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "so. . . T");
    defer native.deinit();
    try std.testing.expectEqualStrings("so. . . T", native.text);
}

test "a tracked word before a spaced ellipsis keeps its space" {
    var glyphs: [6]GlyphSpan = undefined;
    // QuarkXPress sets the tracking on the letter before the first period.
    const texts = [_][]const u8{ "s", "o", ".", ".", ".", "T" };
    for (texts, 0..) |text, index| {
        var glyph = testGlyph(text, 100 + @as(f64, @floatFromInt(index)) * 5, 700, 5);
        glyph.font_space_advance = 2.5;
        if (index >= 1 and index <= 4) {
            glyph.spacing_advance = 2.5;
            glyph.font_space_advance = 5;
        }
        glyphs[index] = glyph;
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "so . . . T");
    defer native.deinit();
    try std.testing.expectEqualStrings("so . . . T", native.text);
}

test "single periods in a word-space tracked heading stay joined" {
    var glyphs: [5]GlyphSpan = undefined;
    for ("U.S.A", 0..) |_, index| {
        var glyph = testGlyph("U.S.A"[index .. index + 1], 100 + @as(f64, @floatFromInt(index)) * 10, 700, 10);
        glyph.spacing_advance = 3;
        glyph.font_space_advance = 6;
        glyphs[index] = glyph;
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "U.S.A");
    defer native.deinit();
    try std.testing.expectEqualStrings("U.S.A", native.text);
}

test "letter-spaced heading without cancelling kerns stays one word" {
    var glyphs: [7]GlyphSpan = undefined;
    for ("HEADING", 0..) |_, index| {
        const x = 100 + @as(f64, @floatFromInt(index)) * 9; // 7pt ink + 2pt Tc
        var glyph = testGlyph("HEADING"[index .. index + 1], x, 700, 9);
        glyph.spacing_advance = 2;
        glyphs[index] = glyph;
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "HEADING");
    defer native.deinit();
    try std.testing.expectEqualStrings("HEADING", native.text);
}

fn appendSizedWord(list: *std.ArrayList(GlyphSpan), allocator: std.mem.Allocator, word: []const u8, x: f64, y: f64, size: f64) !f64 {
    const step = size * 0.6;
    for (word, 0..) |_, index| {
        var glyph = testGlyph(word[index .. index + 1], x + @as(f64, @floatFromInt(index)) * step, y, step);
        glyph.font_size = size;
        glyph.bbox.y1 = y + size * 0.75;
        try list.append(allocator, glyph);
    }
    return x + @as(f64, @floatFromInt(word.len)) * step;
}

fn appendProseLine(list: *std.ArrayList(GlyphSpan), allocator: std.mem.Allocator, marker: []const u8, x0: f64, x1: f64, y: f64, size: f64) !void {
    var x = try appendSizedWord(list, allocator, marker, x0, y, size) + size * 0.3;
    while (x + 5 * size * 0.6 <= x1) x = try appendSizedWord(list, allocator, "words", x, y, size) + size * 0.3;
}

const test_left_markers = [_][]const u8{ "La", "Lb", "Lc", "Ld", "Le", "Lf", "Lg", "Lh", "Li", "Lj", "Lk", "Ll", "Lm", "Ln", "Lo", "Lp", "Lq", "Lr", "Ls", "Lt", "Lu", "Lv" };
const test_right_markers = [_][]const u8{ "Ra", "Rb", "Rc", "Rd", "Re", "Rf", "Rg", "Rh", "Ri", "Rj", "Rk", "Rl", "Rm", "Rn", "Ro", "Rp", "Rq", "Rr", "Rs", "Rt", "Ru", "Rv" };

fn expectNoMixedColumnLines(text: []const u8, left_mark: u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const has_left = std.mem.indexOfScalar(u8, line, left_mark) != null or std.mem.indexOf(u8, line, "Tcell") != null;
        try std.testing.expect(!(has_left and std.mem.indexOfScalar(u8, line, 'R') != null));
    }
}

test "column-local table keeps the other column's prose in its own column" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 760, 9);
    for (0..20) |row| {
        const y = 730 - @as(f64, @floatFromInt(row)) * 12;
        try appendProseLine(&glyphs, allocator, test_right_markers[row], 312, 563, y, 9);
        if (row >= 7 and row <= 11) {
            for ([_]f64{ 49, 130, 220 }) |cell_x| _ = try appendSizedWord(&glyphs, allocator, "Tcell", cell_x, y, 9);
        } else {
            try appendProseLine(&glyphs, allocator, test_left_markers[row], 49, 300, y, 9);
        }
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try expectNoMixedColumnLines(native.text, 'L');
    const text = native.text;
    try std.testing.expect(std.mem.lastIndexOf(u8, text, "Tcell").? < std.mem.indexOf(u8, text, "Lm").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Lt").? < std.mem.indexOf(u8, text, "Ra").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Ra").? < std.mem.indexOf(u8, text, "Rt").?);
}

test "offset column baselines do not fuse the last body row" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 770, 9);
    // The right column sits half a line lower for most rows (as after a
    // display equation), then realigns for the last rows.
    for (0..22) |row| {
        const y = 730 - @as(f64, @floatFromInt(row)) * 12;
        try appendProseLine(&glyphs, allocator, test_left_markers[row], 49, 300, y, 9);
        const offset: f64 = if (row >= 3 and row < 18) 6 else 0;
        try appendProseLine(&glyphs, allocator, test_right_markers[row], 312, 563, y - offset, 9);
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try expectNoMixedColumnLines(native.text, 'L');
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Lv").? < std.mem.indexOf(u8, native.text, "Ra").?);
}

test "a large title's word gap at the centre is not a column break" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    // A 30pt title mid-page whose 13pt word gap lands on the 12pt gutter.
    for (0..20) |row| {
        const y = 760 - @as(f64, @floatFromInt(row)) * 12 - @as(f64, if (row >= 5) 40 else 0);
        try appendProseLine(&glyphs, allocator, test_left_markers[row], 49, 300, y, 9);
        try appendProseLine(&glyphs, allocator, test_right_markers[row], 312, 563, y, 9);
    }
    const title_end = try appendSizedWord(&glyphs, allocator, "Durablejob", 299.5 - 10 * 18, 690, 30);
    _ = try appendSizedWord(&glyphs, allocator, "queues", title_end + 13, 690, 30);
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Durablejob queues") != null);
}

fn twoColumnBody(list: *std.ArrayList(GlyphSpan), allocator: std.mem.Allocator, top: f64, rows: usize, skip_left: []const usize, skip_right: []const usize) !void {
    for (0..rows) |row| {
        const y = top - @as(f64, @floatFromInt(row)) * 12;
        if (std.mem.indexOfScalar(usize, skip_left, row) == null) try appendProseLine(list, allocator, test_left_markers[row], 49, 300, y, 9);
        if (std.mem.indexOfScalar(usize, skip_right, row) == null) try appendProseLine(list, allocator, test_right_markers[row], 312, 563, y, 9);
    }
}

test "a column heading larger than the gutter does not fuse the columns" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 760, 9);
    try twoColumnBody(&glyphs, allocator, 730, 20, &.{}, &.{8});
    // The left line ends at 297.4pt; a 13pt gap is under the heading em.
    _ = try appendSizedWord(&glyphs, allocator, "Section", 310.4, 730 - 8 * 12, 14);
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try expectNoMixedColumnLines(native.text, 'L');
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Lt").? < std.mem.indexOf(u8, native.text, "Ra").?);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Rh").? < std.mem.indexOf(u8, native.text, "Section").?);
}

test "a column-local table opposite empty space stays in its column" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 760, 9);
    try twoColumnBody(&glyphs, allocator, 730, 20, &.{ 7, 8, 9, 10, 11 }, &.{ 7, 8, 9, 10, 11 });
    for (7..12) |row| {
        const y = 730 - @as(f64, @floatFromInt(row)) * 12;
        for ([_]f64{ 49, 130, 220 }) |cell_x| _ = try appendSizedWord(&glyphs, allocator, "Tcell", cell_x, y, 9);
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    const text = native.text;
    try std.testing.expect(std.mem.lastIndexOf(u8, text, "Tcell").? < std.mem.indexOf(u8, text, "Lm").?);
    try std.testing.expect(std.mem.indexOf(u8, text, "Lt").? < std.mem.indexOf(u8, text, "Ra").?);
}

test "an indented two-part table under full-width rows is not a column layout" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    // A caption crossing the gutter keeps the strict detector out; the
    // table rows have cells on both sides of the centre at the page margin.
    try appendProseLine(&glyphs, allocator, "Caption", 49, 563, 780, 9);
    for (0..14) |row| {
        const y = 760 - @as(f64, @floatFromInt(row)) * 12;
        for ([_]f64{ 49, 200, 330, 480 }) |cell_x| _ = try appendSizedWord(&glyphs, allocator, "Cell", cell_x, y, 9);
    }
    for (0..12) |row| {
        const y = 580 - @as(f64, @floatFromInt(row)) * 12;
        try appendProseLine(&glyphs, allocator, test_left_markers[row], 120, 300, y, 9);
        try appendProseLine(&glyphs, allocator, test_right_markers[row], 312, 563, y, 9);
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter == null);
}

test "a full-width stub table above columns keeps row order" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 780, 9);
    const stubs = [_][]const u8{ "Stuba", "Stubb", "Stubc", "Stubd", "Stube" };
    for (stubs, 0..) |stub, row| {
        const y = 760 - @as(f64, @floatFromInt(row)) * 12;
        _ = try appendSizedWord(&glyphs, allocator, stub, 49, y, 9);
        for ([_]f64{ 320, 410, 500 }) |cell_x| _ = try appendSizedWord(&glyphs, allocator, "num", cell_x, y, 9);
    }
    try twoColumnBody(&glyphs, allocator, 690, 20, &.{}, &.{});
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Stuba num num num") != null);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Stube num num num") != null);
}

fn trackedLine(glyphs: []GlyphSpan, words: []const []const u8, y: f64, font_space: f64) usize {
    // Tc = 4pt; kerns cancel it inside words, between words a 1.5pt kern
    // leaves a 2.5pt visible space.
    var x: f64 = 0;
    var count: usize = 0;
    for (words) |word| {
        for (word, 0..) |_, index| {
            var glyph = testGlyph(word[index .. index + 1], x, y, 10);
            glyph.spacing_advance = 4;
            glyph.font_space_advance = font_space;
            glyphs[count] = glyph;
            count += 1;
            x += if (index + 1 < word.len) 6 else 8.5;
        }
    }
    return count;
}

test "cancelled tracking keeps word gaps when the font declares a space" {
    var glyphs: [8]GlyphSpan = undefined;
    const count = trackedLine(&glyphs, &.{ "ab", "cd", "ef", "gh" }, 100, 6.5);
    var native = try analyze(std.testing.allocator, glyphs[0..count], .{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 200 }, "ab cd ef gh");
    defer native.deinit();
    try std.testing.expectEqualStrings("ab cd ef gh", native.text);
}

test "a short cancelled-tracking line inherits the page's evidence" {
    var glyphs: [12]GlyphSpan = undefined;
    var count = trackedLine(&glyphs, &.{ "ab", "cd", "ef", "gh" }, 100, 0);
    count += trackedLine(glyphs[count..], &.{ "we", "do" }, 80, 0);
    var native = try analyze(std.testing.allocator, glyphs[0..count], .{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 200 }, "ab cd ef gh we do");
    defer native.deinit();
    try std.testing.expectEqualStrings("ab cd ef gh\nwe do", native.text);
}

test "a tracked heading with optical kerning stays one word" {
    // Tc = 0.18 em with -0.10 em optical kerns on AV/VA/AT/TA.
    var glyphs: [6]GlyphSpan = undefined;
    var x: f64 = 100;
    for ("AVATAR", 0..) |_, index| {
        var glyph = testGlyph("AVATAR"[index .. index + 1], x, 700, 9.16);
        glyph.spacing_advance = 2.16;
        glyphs[index] = glyph;
        x += 9.16 - (if (index < 4) @as(f64, 1.2) else 0);
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "AVATAR");
    defer native.deinit();
    try std.testing.expectEqualStrings("AVATAR", native.text);
}

fn appendJustifiedLine(list: *std.ArrayList(GlyphSpan), allocator: std.mem.Allocator, marker: []const u8, x0: f64, y: f64) !void {
    // Loose justification: one 8pt (0.9 em) word gap in a 9pt line.
    var x = try appendSizedWord(list, allocator, marker, x0, y, 9) + 2.7;
    for (0..3) |_| x = try appendSizedWord(list, allocator, "words", x, y, 9) + 2.7;
    x += 5.3;
    for (0..4) |_| x = try appendSizedWord(list, allocator, "words", x, y, 9) + 2.7;
    // Justified lines run to the column edge.
    _ = try appendSizedWord(list, allocator, "wor", x, y, 9);
}

test "loosely justified rows on both sides stay in their columns" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 760, 9);
    try twoColumnBody(&glyphs, allocator, 730, 20, &.{ 8, 9 }, &.{ 8, 9 });
    for ([_]usize{ 8, 9 }) |row| {
        const y = 730 - @as(f64, @floatFromInt(row)) * 12;
        try appendJustifiedLine(&glyphs, allocator, test_left_markers[row], 49, y);
        try appendJustifiedLine(&glyphs, allocator, test_right_markers[row], 312, y);
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try expectNoMixedColumnLines(native.text, 'L');
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Lt").? < std.mem.indexOf(u8, native.text, "Ra").?);
}

test "a display equation beside right-column prose stays in its column" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 760, 9);
    try twoColumnBody(&glyphs, allocator, 730, 20, &.{ 8, 9 }, &.{});
    for ([_]usize{ 8, 9 }) |row| {
        const y = 730 - @as(f64, @floatFromInt(row)) * 12;
        for ([_]f64{ 100, 150, 200 }) |piece_x| _ = try appendSizedWord(&glyphs, allocator, "Eq", piece_x, y, 9);
        _ = try appendSizedWord(&glyphs, allocator, "(1)", 285, y, 9);
    }
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    var lines = std.mem.splitScalar(u8, native.text, '\n');
    while (lines.next()) |line| try std.testing.expect(!(std.mem.indexOf(u8, line, "Eq") != null and std.mem.indexOfScalar(u8, line, 'R') != null));
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Lt").? < std.mem.indexOf(u8, native.text, "Ra").?);
}

test "a large right-column heading does not bridge the gutter to small prose" {
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 760, 9);
    try twoColumnBody(&glyphs, allocator, 730, 20, &.{}, &.{8});
    // 17pt heading 13pt after the left line, which ends at 297.4pt.
    _ = try appendSizedWord(&glyphs, allocator, "Section", 310.4, 730 - 8 * 12, 17);
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try expectNoMixedColumnLines(native.text, 'L');
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Lt").? < std.mem.indexOf(u8, native.text, "Ra").?);
}

test "a full-width table with long row labels keeps row order" {
    // Labels span about a third of the page but stop well short of the
    // gutter, unlike justified column prose (Table 4 of the Rosengren paper).
    const allocator = std.testing.allocator;
    var glyphs: std.ArrayList(GlyphSpan) = .empty;
    defer glyphs.deinit(allocator);
    try appendProseLine(&glyphs, allocator, "Header", 49, 563, 780, 9);
    const labels = [_][]const u8{ "Labela", "Labelb", "Labelc", "Labeld", "Labele" };
    for (labels, 0..) |label, row| {
        const y = 760 - @as(f64, @floatFromInt(row)) * 12;
        const x = try appendSizedWord(&glyphs, allocator, label, 49, y, 9) + 2.7;
        try appendProseLine(&glyphs, allocator, "ab", x, 260, y, 9);
        for ([_]f64{ 330, 410, 500 }) |cell_x| _ = try appendSizedWord(&glyphs, allocator, "num", cell_x, y, 9);
    }
    try twoColumnBody(&glyphs, allocator, 690, 20, &.{}, &.{});
    var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
    defer native.deinit();
    try std.testing.expect(native.gutter != null);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "num num num\nLabelb") != null);
    try std.testing.expect(std.mem.indexOf(u8, native.text, "Lt").? < std.mem.indexOf(u8, native.text, "Ra").?);
}

test "a full-width table with a long description column keeps row order" {
    // The description cell reaches the page edge but starts away from the
    // right column margin, so it is a table cell, not column prose.
    const allocator = std.testing.allocator;
    for ([_]f64{ 345, 380 }) |desc_x| {
        var glyphs: std.ArrayList(GlyphSpan) = .empty;
        defer glyphs.deinit(allocator);
        try appendProseLine(&glyphs, allocator, "Header", 49, 563, 780, 9);
        const labels = [_][]const u8{ "Vara", "Varb", "Varc", "Vard", "Vare" };
        for (labels, 0..) |label, row| {
            const y = 760 - @as(f64, @floatFromInt(row)) * 12;
            _ = try appendSizedWord(&glyphs, allocator, label, 49, y, 9);
            for ([_]f64{ 130, 220 }) |cell_x| _ = try appendSizedWord(&glyphs, allocator, "num", cell_x, y, 9);
            try appendProseLine(&glyphs, allocator, "Dsc", desc_x, 563, y, 9);
        }
        try twoColumnBody(&glyphs, allocator, 690, 20, &.{}, &.{});
        var native = try analyze(allocator, glyphs.items, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "");
        defer native.deinit();
        try std.testing.expect(native.gutter != null);
        var across: usize = 0;
        var lines = std.mem.splitScalar(u8, native.text, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "Var") != null and std.mem.indexOf(u8, line, "Dsc") != null) across += 1;
        }
        try std.testing.expectEqual(@as(usize, 5), across);
        try std.testing.expect(std.mem.indexOf(u8, native.text, "Lt").? < std.mem.indexOf(u8, native.text, "Ra").?);
    }
}

test "a tracked heading with Times kerning stays one word" {
    // Tc = 0.18 em; AV and VA kern -0.135 em, AT -0.111 em, TA -0.093 em.
    const kerns = [_]f64{ 0.135, 0.135, 0.111, 0.093, 0 };
    var glyphs: [6]GlyphSpan = undefined;
    var x: f64 = 100;
    for ("AVATAR", 0..) |_, index| {
        var glyph = testGlyph("AVATAR"[index .. index + 1], x, 700, 9.16);
        glyph.spacing_advance = 2.16;
        glyphs[index] = glyph;
        if (index < kerns.len) x += 9.16 - kerns[index] * 12;
    }
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "AVATAR");
    defer native.deinit();
    try std.testing.expectEqualStrings("AVATAR", native.text);
}

test "semantic ActualText spans retain exact whitespace through native layout" {
    var glyph = testGlyph("  first\nsecond  ", 72, 700, 30);
    glyph.actual_text = true;
    const glyphs = [_]GlyphSpan{glyph};
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 800 }, glyph.text);
    defer result.deinit();
    try std.testing.expectEqualStrings(glyph.text, result.text);
    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &result, 0);
    defer {
        for (spans) |span| std.testing.allocator.free(@constCast(span.text));
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqualStrings(glyph.text, spans[0].text);
}

test "scoped provenance splits put synthetic separators outside exact span text" {
    var first = testGlyph("A", 100, 700, 6);
    first.content_scope = .{ .page_index = 0, .stream_object_num = 17, .invocation_index = 1 };
    var second = testGlyph("C", 108, 700, 6);
    second.content_scope = .{ .page_index = 0, .stream_object_num = 17, .invocation_index = 2 };
    const glyphs = [_]GlyphSpan{ first, second };
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 800 }, "AC");
    defer native.deinit();
    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &native, 0);
    defer {
        for (spans) |span| std.testing.allocator.free(@constCast(span.text));
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqualStrings("A", spans[0].text);
    try std.testing.expectEqualStrings("C", spans[1].text);
    try std.testing.expectEqual(BoundaryKind.space, spans[1].leading_boundary.?);
    var reconciled = try @import("reconcile.zig").reconcile(std.testing.allocator, &.{.{ .spans = spans }}, .{ .preserve_input_order = true });
    defer reconciled.deinit();
    try std.testing.expectEqualStrings("A C", reconciled.blocks[0].text);
    try std.testing.expectEqual(@as(usize, 2), reconciled.spans[1].block_text_start);
}

test "whitespace-only ActualText scopes retain one exact authored separator" {
    var separator = testGlyph("\u{a0}", 106, 700, 4);
    separator.actual_text = true;
    separator.semantic_run_id = 1;
    separator.semantic_replacement = true;
    const glyphs = [_]GlyphSpan{ testGlyph("A", 100, 700, 6), separator, testGlyph("B", 110, 700, 6) };
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 300, .y1 = 800 }, "A\u{a0}B");
    defer native.deinit();
    try std.testing.expectEqualStrings("A\u{a0}B", native.text);
    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &native, 0);
    defer {
        for (spans) |span| std.testing.allocator.free(@constCast(span.text));
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqualStrings("\u{a0}", spans[1].text);
    var reconciled = try @import("reconcile.zig").reconcile(std.testing.allocator, &.{.{ .spans = spans }}, .{ .preserve_input_order = true });
    defer reconciled.deinit();
    try std.testing.expectEqualStrings("A\u{a0}B", reconciled.blocks[0].text);
}

test "mathematical font switches retain explicit word spaces after segment trimming" {
    // Derived from the checked-in mathematical-pi fixture: each comparison
    // operator uses another font immediately after an explicit text space.
    const tokens = [_][]const u8{ "BMI", " ", "<", "25 BMI", " ", ">", "30 IRP", " ", "≥", " upper limit", " ", "→", " muscle" };
    var glyphs: [tokens.len]GlyphSpan = undefined;
    var x: f64 = 100;
    for (tokens, 0..) |token, index| {
        glyphs[index] = testGlyph(token, x, 700, 6);
        glyphs[index].font_name = if (index == 2 or index == 5 or index == 8) "MathematicalPi-One" else if (index == 11) "Symbol" else "Body";
        x += 6;
    }
    const expected = "BMI <25 BMI >30 IRP ≥ upper limit → muscle";
    var native = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, expected);
    defer native.deinit();
    try std.testing.expectEqualStrings(expected, native.text);
    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &native, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    var reconciled = try @import("reconcile.zig").reconcile(std.testing.allocator, &.{.{ .spans = spans }}, .{ .preserve_input_order = true });
    defer reconciled.deinit();
    try std.testing.expectEqualStrings(expected, reconciled.blocks[0].text);
    try std.testing.expectEqualStrings(expected, reconciled.chunks[0].content);
}

test "line spans preserve representative font and vertical provenance" {
    var glyph = testGlyph("日", 300, 700, 12);
    glyph.font_name = "FVertical";
    glyph.writing_mode = 1;
    glyph.actual_text = true;
    glyph.mcid = 7;
    glyph.paint = .{ .rendering_mode = 3, .paint_state = .non_painting, .clip_state = .outside, .clip_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 20 } };
    const glyphs = [_]GlyphSpan{glyph};
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "日");
    defer result.deinit();

    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &result, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("FVertical", spans[0].font.name.?);
    try std.testing.expectEqual(@as(u8, 1), spans[0].writing_mode);
    try std.testing.expect(spans[0].actual_text);
    try std.testing.expectEqual(@as(?i32, 7), spans[0].mcid);
    try std.testing.expect(std.meta.eql(glyph.paint, spans[0].paint));
}

test "line spans split equal-font glyphs at paint evidence changes" {
    var visible = testGlyph("A", 72, 700, 6);
    visible.paint = .{ .rendering_mode = 0, .paint_state = .painting, .clip_state = .inside, .clip_bbox = .{ .x0 = 70, .y0 = 690, .x1 = 100, .y1 = 720 } };
    var hidden = testGlyph("B", 78, 700, 6);
    hidden.paint = visible.paint;
    hidden.paint.rendering_mode = 3;
    hidden.paint.paint_state = .non_painting;
    const glyphs = [_]GlyphSpan{ visible, hidden };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "AB");
    defer result.deinit();
    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &result, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(.painting, spans[0].paint.paint_state);
    try std.testing.expectEqual(.non_painting, spans[1].paint.paint_state);
}

test "line span aggregate clip evidence is conservative across separated outside glyphs" {
    var left = testGlyph("A", 72, 700, 6);
    left.paint = .{ .rendering_mode = 0, .paint_state = .painting, .clip_state = .outside, .clip_bbox = .{ .x0 = 79, .y0 = 690, .x1 = 81, .y1 = 720 } };
    var right = testGlyph("B", 82, 700, 6);
    right.paint = left.paint;
    const glyphs = [_]GlyphSpan{ left, right };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "AB");
    defer result.deinit();
    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &result, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqual(.partial, spans[0].paint.clip_state);
}

test "line spans split mixed font and marked-content provenance" {
    var regular = testGlyph("Alpha", 72, 700, 25);
    regular.font_name = "Regular";
    regular.mcid = 3;
    var bold = testGlyph("Bold", 97, 700, 20);
    bold.font_name = "Bold";
    bold.mcid = 4;
    bold.actual_text = true;
    const glyphs = [_]GlyphSpan{ regular, bold };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "AlphaBold");
    defer result.deinit();

    const spans = try buildLineSpans(std.testing.allocator, &glyphs, &result, 0);
    defer {
        for (spans) |span| {
            std.testing.allocator.free(@constCast(span.text));
            if (span.font.name) |name| std.testing.allocator.free(@constCast(name));
        }
        std.testing.allocator.free(spans);
    }
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("Alpha", spans[0].text);
    try std.testing.expectEqualStrings("Bold", spans[1].text);
    try std.testing.expectEqualStrings("Regular", spans[0].font.name.?);
    try std.testing.expectEqualStrings("Bold", spans[1].font.name.?);
    try std.testing.expectEqual(@as(?i32, 3), spans[0].mcid);
    try std.testing.expectEqual(@as(?i32, 4), spans[1].mcid);
    try std.testing.expect(!spans[0].actual_text);
    try std.testing.expect(spans[1].actual_text);
}

test "explicit and generated whitespace retain provenance" {
    var generated = testGlyph(" ", 98, 700, 4);
    generated.generated = true;
    const glyphs = [_]GlyphSpan{
        testGlyph("Hello", 72, 700, 26),
        generated,
        testGlyph("world", 102, 700, 27),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "Hello world");
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello world", result.text);
    try std.testing.expectEqual(BoundaryProvenance.tj_adjustment, result.boundaries[1].provenance);
}

test "trailing whitespace-only lines keep text ranges within rendered output" {
    const glyphs = [_]GlyphSpan{
        testGlyph("Visible", 72, 700, 36),
        testGlyph(" ", 72, 682, 4),
        testGlyph("\t", 72, 664, 4),
    };
    var result = try analyze(std.testing.allocator, &glyphs, .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, "Visible \t");
    defer result.deinit();

    try std.testing.expectEqualStrings("Visible", result.text);
    try std.testing.expectEqual(@as(usize, 3), result.lines.len);
    try std.testing.expectEqual(@as(u32, 0), result.lines[0].text_start);
    try std.testing.expectEqual(@as(u32, 7), result.lines[0].text_len);
    try std.testing.expectEqual(@as(u32, 7), result.lines[1].text_start);
    try std.testing.expectEqual(@as(u32, 0), result.lines[1].text_len);
    try std.testing.expectEqual(@as(u32, 7), result.lines[2].text_start);
    try std.testing.expectEqual(@as(u32, 0), result.lines[2].text_len);
    for (result.lines) |line| {
        const text_start: usize = @intCast(line.text_start);
        const text_len: usize = @intCast(line.text_len);
        try std.testing.expect(text_start <= result.text.len);
        try std.testing.expect(text_len <= result.text.len - text_start);
    }
}

test "quality comparison reports boundary line token and recall metrics" {
    const metrics = try compareAgainstReference(std.testing.allocator, "AlphaBetaGammaDelta", "Alpha Beta\nGamma Delta", "Alpha Beta\nGamma Delta");
    try std.testing.expectEqual(@as(?f64, 1), metrics.word_boundary_precision);
    try std.testing.expectEqual(@as(?f64, 1), metrics.word_boundary_recall);
    try std.testing.expectEqual(@as(?f64, 1), metrics.line_break_f1);
    try std.testing.expectEqual(@as(?f64, 1), metrics.token_f1);
    try std.testing.expectEqual(@as(?f64, 0), metrics.word_error_rate);
    try std.testing.expectApproxEqAbs(@as(f64, 1), metrics.raw_non_whitespace_recall, 0.0001);
}

test "quality gate reports extreme token and line rates" {
    const long_token = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const metrics = qualityForText(long_token, long_token);
    try std.testing.expect(metrics.max_token_bytes > 160);
    try std.testing.expectEqual(@as(f64, 1), metrics.extreme_token_length_rate);
    try std.testing.expect(!passesQualityGate(metrics, long_token.len));
}

fn lineSpanAllocationProbe(allocator: std.mem.Allocator) !void {
    var glyphs = [_]GlyphSpan{
        testGlyph("Hello", 72, 700, 26),
        testGlyph("world", 102, 700, 27),
        testGlyph("Second", 72, 682, 36),
        testGlyph("line", 112, 682, 18),
    };
    glyphs[1].font_name = "Alternate";
    glyphs[2].content_scope = .{ .page_index = 0, .stream_object_num = 17, .invocation_index = 1 };
    glyphs[3].semantic_run_id = 2;
    var result = try analyze(
        allocator,
        &glyphs,
        .{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 },
        "Helloworld\nSecondline",
    );
    defer result.deinit();

    const spans = try buildLineSpans(allocator, &glyphs, &result, 0);
    defer {
        for (spans) |span| {
            allocator.free(@constCast(span.text));
            if (span.font.name) |name| allocator.free(@constCast(name));
        }
        allocator.free(spans);
    }
}

test "native line span ownership is safe across every allocation failure" {
    // Shrinking an ArrayList can remap in place depending on heap placement.
    // Force the allocating path so every injected failure index is repeatable.
    var no_remap = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(
        no_remap.allocator(),
        lineSpanAllocationProbe,
        .{},
    );
}
