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
    const gutter = detectCentralGutter(allocator, glyphs, page_bbox) catch null;

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
                regionsCompatible(candidate.region_index, regionForGlyph(glyph.bbox, gutter)))
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
                .region_index = regionForGlyph(glyph.bbox, gutter),
            });
        }
    }

    for (pending_lines.items) |line| {
        const slice = line_glyphs.items[line.start .. line.start + line.count];
        std.mem.sort(u32, slice, glyphs, compareGlyphInline);
    }

    const line_order = try orderLinesByRegions(allocator, pending_lines.items, gutter);
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
    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| {
            allocator.free(@constCast(span.text));
            if (span.font.name) |name| allocator.free(@constCast(name));
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
                try appendNormalizedGlyph(allocator, &text, glyph.text, glyph.actual_text);
            }
            if (!representative.actual_text) trimTrailingWhitespace(&text);
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
    const aa = a.text_matrix[0];
    const ab = a.text_matrix[1];
    const ba = b.text_matrix[0];
    const bb = b.text_matrix[1];
    const a_len = @sqrt(aa * aa + ab * ab);
    const b_len = @sqrt(ba * ba + bb * bb);
    if (a_len <= 0.0001 or b_len <= 0.0001) return true;
    return @abs((aa * ba + ab * bb) / (a_len * b_len)) >= 0.94;
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
        if (line.region_index != 2 and !isColumnSectionHeading(lines, line_index, body_size, left_margin)) continue;
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
    var line_index: usize = 0;
    var next_line_start: usize = if (lines.len > 1) @intCast(lines[1].ordered_start) else ordered.len;

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

        const gap = inlineGap(previous, current);
        const em = @max(1.0, @max(previous.font_size * writingAxis(previous).scale, current.font_size * writingAxis(current).scale));
        const font_space = @max(previous.font_space_advance * writingAxis(previous).scale, current.font_space_advance * writingAxis(current).scale);
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
    const order = try orderLinesByRegions(std.testing.allocator, &lines, gutter);
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
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        lineSpanAllocationProbe,
        .{},
    );
}
