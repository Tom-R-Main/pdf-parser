//! Bounded, conservative candidates for unexplained painted vector lettering.
//! Geometry suggests OCR targets; it does not establish text or visibility.
const std = @import("std");
const layout = @import("layout.zig");
const geometry = @import("page_geometry.zig");
const vector = @import("vector_evidence.zig");

pub const Summary = struct {
    status: vector.Status = .complete,
    shape_count: u32 = 0,
    unknown_count: u32 = 0,
    ignored_rule_count: u32 = 0,
    clipped_out_count: u32 = 0,
    native_accounted_count: u32 = 0,
    simple_graphic_count: u32 = 0,
    ambiguous_shape_count: u32 = 0,
    candidate_region_count: u32 = 0,
    max_shapes: u32 = 512,
    max_segments_per_path: u32 = 512,
    max_operators: u32 = 100_000,
    operator_count: u32 = 0,
    content_bytes: u32 = 0,
    max_content_bytes: u32 = 8 * 1024 * 1024,
    max_graphics_depth: u32 = 32,
    max_form_invocations: u32 = 256,
    max_candidate_regions: u32 = 64,
};
pub const Candidate = struct {
    bbox: layout.BBox,
    shape_count: u32,
    segment_count: u32,
    subpath_count: u32,
    native_coverage: f64,
    decision: enum { unexplained_vector } = .unexplained_vector,
};
pub const Result = struct {
    allocator: std.mem.Allocator,
    summary: Summary,
    candidates: []Candidate,
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.candidates);
        self.* = undefined;
    }
};

pub fn mergeCandidates(a: Candidate, b: Candidate, spans: []const layout.TextSpan) ?Candidate {
    const box = unionBox(a.bbox, b.bbox);
    var checks: usize = 0;
    const coverage = nativeCoverage(box, spans, &checks);
    if (!coverage.complete) return null;
    return .{ .bbox = box, .shape_count = a.shape_count + b.shape_count, .segment_count = a.segment_count + b.segment_count, .subpath_count = a.subpath_count + b.subpath_count, .native_coverage = coverage.fraction };
}
const max_shapes = 512;
const max_native_checks = 1_000_000;
const Pending = struct { raw: layout.BBox, display: layout.BBox, segments: u32, subpaths: u32, parent: usize };

pub fn classify(allocator: std.mem.Allocator, evidence: *const vector.Evidence, spans: []const layout.TextSpan, page_bbox: layout.BBox, page_geometry: ?geometry.PageGeometry) !Result {
    var summary = Summary{
        .status = evidence.status,
        .shape_count = @intCast(evidence.shapes.len),
        .unknown_count = evidence.unknown_count,
        .max_shapes = evidence.limits.max_shapes,
        .max_segments_per_path = evidence.limits.max_segments_per_path,
        .max_operators = evidence.limits.max_operators,
        .operator_count = evidence.operator_count,
        .content_bytes = evidence.content_bytes,
        .max_content_bytes = evidence.limits.max_content_bytes,
        .max_graphics_depth = evidence.limits.max_graphics_depth,
        .max_form_invocations = evidence.limits.max_form_invocations,
    };
    var pending: [max_shapes]Pending = undefined;
    var count: usize = 0;
    var native_checks: usize = 0;
    for (evidence.shapes) |shape| {
        if (shape.clip_state == .outside) {
            summary.clipped_out_count += 1;
            continue;
        }
        if (shape.clip_state == .unknown) {
            summary.ambiguous_shape_count += 1;
            continue;
        }
        const raw = intersection(shape.bbox, page_bbox) orelse {
            summary.clipped_out_count += 1;
            continue;
        };
        const display = if (page_geometry) |page| geometry.mapBBox(page.pdfToDisplay(.media), raw) catch {
            summary.ambiguous_shape_count += 1;
            continue;
        } else raw;
        const width = display.x1 - display.x0;
        const height = display.y1 - display.y0;
        if (@min(width, height) <= 3 and @max(width, height) >= @max(1, @min(width, height)) * 12) {
            summary.ignored_rule_count += 1;
            continue;
        }
        const coverage = nativeCoverage(raw, spans, &native_checks);
        if (!coverage.complete) {
            if (summary.status != .limited) summary.status = .partial;
            summary.ambiguous_shape_count += 1;
            continue;
        }
        if (coverage.fraction >= 0.75) {
            summary.native_accounted_count += 1;
            continue;
        }
        if (shape.rectangle_only) {
            summary.simple_graphic_count += 1;
            continue;
        }
        if (count == pending.len) {
            summary.status = .limited;
            summary.ambiguous_shape_count += 1;
            continue;
        }
        pending[count] = .{ .raw = raw, .display = display, .segments = shape.segment_count, .subpaths = shape.subpath_count, .parent = count };
        count += 1;
    }
    if (native_checks >= max_native_checks and summary.status != .limited) summary.status = .partial;
    for (0..count) |i| {
        for (i + 1..count) |j| {
            const a = pending[i].display;
            const b = pending[j].display;
            const ha = a.y1 - a.y0;
            const hb = b.y1 - b.y0;
            const h = @max(ha, hb);
            const dy = @abs((a.y0 + a.y1) / 2 - (b.y0 + b.y1) / 2);
            const gap = @max(a.x0, b.x0) - @min(a.x1, b.x1);
            if (h <= @max(0.1, @min(ha, hb)) * 3 and dy <= h * 0.6 and gap <= h * 0.8) {
                const first = find(&pending, i);
                const second = find(&pending, j);
                pending[second].parent = first;
            }
        }
    }
    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer candidates.deinit(allocator);
    for (0..count) |i| {
        if (find(&pending, i) != i) continue;
        var raw = pending[i].raw;
        var display = pending[i].display;
        var shapes: u32 = 0;
        var segments: u32 = 0;
        var subpaths: u32 = 0;
        for (0..count) |j| {
            if (find(&pending, j) != i) continue;
            raw = unionBox(raw, pending[j].raw);
            display = unionBox(display, pending[j].display);
            shapes += 1;
            segments += pending[j].segments;
            subpaths += pending[j].subpaths;
        }
        const ratio = (display.x1 - display.x0) / @max(0.1, display.y1 - display.y0);
        // Several similarly placed contours suggest lettering. Single symbols,
        // oversized panels and dense drawings remain ambiguous evidence.
        if ((shapes < 3 and subpaths < 3) or segments < @max(10, shapes * 6) or ratio < 1.2 or ratio > 80 or shapes > 128) {
            summary.ambiguous_shape_count += shapes;
            continue;
        }
        if (candidates.items.len == summary.max_candidate_regions) {
            summary.status = .limited;
            summary.ambiguous_shape_count += shapes;
            continue;
        }
        const coverage = nativeCoverage(raw, spans, &native_checks);
        if (!coverage.complete) {
            if (summary.status != .limited) summary.status = .partial;
            summary.ambiguous_shape_count += shapes;
            continue;
        }
        try candidates.append(allocator, .{
            .bbox = raw,
            .shape_count = shapes,
            .segment_count = segments,
            .subpath_count = subpaths,
            .native_coverage = coverage.fraction,
        });
    }
    summary.candidate_region_count = @intCast(candidates.items.len);
    if (native_checks >= max_native_checks and summary.status != .limited) summary.status = .partial;
    return .{ .allocator = allocator, .summary = summary, .candidates = try candidates.toOwnedSlice(allocator) };
}

fn find(items: *[max_shapes]Pending, start: usize) usize {
    var index = start;
    while (items[index].parent != index) index = items[index].parent;
    return index;
}
fn intersection(a: layout.BBox, b: layout.BBox) ?layout.BBox {
    const box = layout.BBox{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    return if (box.x1 > box.x0 and box.y1 > box.y0) box else null;
}
fn unionBox(a: layout.BBox, b: layout.BBox) layout.BBox {
    return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
}
const Interval = struct { start: f64, end: f64 };
fn less(_: void, a: f64, b: f64) bool {
    return a < b;
}
fn intervalLess(_: void, a: Interval, b: Interval) bool {
    return a.start < b.start;
}

/// Exact rectangle union prevents overlapping native spans inflating coverage.
const Coverage = struct { fraction: f64 = 0, complete: bool = true };
fn nativeCoverage(box: layout.BBox, spans: []const layout.TextSpan, checks: *usize) Coverage {
    var rects: [64]layout.BBox = undefined;
    var count: usize = 0;
    for (spans) |span| {
        if (checks.* >= max_native_checks) return .{ .complete = false };
        checks.* += 1;
        if (span.paint.paint_state != .painting or span.paint.clip_state == .outside or span.paint.clip_state == .unknown) continue;
        if (std.mem.trim(u8, span.text, " \r\n\t").len == 0) continue;
        const visible = if (span.paint.clip_bbox) |clip| intersection(span.bbox, clip) orelse continue else span.bbox;
        if (intersection(box, visible)) |rect| {
            if (count == rects.len) return .{ .complete = false };
            rects[count] = rect;
            count += 1;
        }
    }
    var xs: [128]f64 = undefined;
    for (rects[0..count], 0..) |rect, i| {
        xs[i * 2] = rect.x0;
        xs[i * 2 + 1] = rect.x1;
    }
    std.mem.sort(f64, xs[0 .. count * 2], {}, less);
    var covered: f64 = 0;
    if (count > 0) for (xs[0 .. count * 2 - 1], 0..) |x, i| {
        const next = xs[i + 1];
        if (next <= x) continue;
        var ys: [64]Interval = undefined;
        var n: usize = 0;
        for (rects[0..count]) |rect| if (rect.x0 <= x and rect.x1 >= next) {
            ys[n] = .{ .start = rect.y0, .end = rect.y1 };
            n += 1;
        };
        std.mem.sort(Interval, ys[0..n], {}, intervalLess);
        var length: f64 = 0;
        var end: f64 = -std.math.inf(f64);
        for (ys[0..n]) |y| {
            length += @max(0, y.end - @max(end, y.start));
            end = @max(end, y.end);
        }
        covered += (next - x) * length;
    };
    return .{ .fraction = @min(1, covered / ((box.x1 - box.x0) * (box.y1 - box.y0))) };
}

test "native coverage unions overlap and ignores invisible text" {
    const box = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 10 };
    var span = layout.TextSpan.init(.{ .text = "caption", .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 10 }, .paint = .{ .paint_state = .painting, .clip_state = .unclipped } });
    var checks: usize = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), nativeCoverage(box, &.{ span, span }, &checks).fraction, 0.0001);
    span.paint.paint_state = .non_painting;
    try std.testing.expectEqual(@as(f64, 0), nativeCoverage(box, &.{span}, &checks).fraction);
}

fn testShapes() [3]vector.Shape {
    var shapes: [3]vector.Shape = undefined;
    for (&shapes, 0..) |*shape, i| {
        const x: f64 = 10 + @as(f64, @floatFromInt(i)) * 7;
        shape.* = .{ .bbox = .{ .x0 = x, .y0 = 10, .x1 = x + 6, .y1 = 20 }, .paint_kind = .fill, .rectangle_only = false, .segment_count = 10, .subpath_count = 1, .clip_state = .unclipped, .content_scope = null };
    }
    return shapes;
}
fn classificationProbe(allocator: std.mem.Allocator) !void {
    var shapes = testShapes();
    const evidence = vector.Evidence{ .allocator = allocator, .shapes = &shapes, .status = .complete, .operator_count = 30, .unknown_count = 0, .limits = .{} };
    var result = try classify(allocator, &evidence, &.{}, .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 }, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.candidates.len);
}
test "vector classifier candidate ownership survives allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, classificationProbe, .{});
}
test "vector classification respects native coverage graphics and clipping" {
    var shapes = testShapes();
    const evidence = vector.Evidence{ .allocator = std.testing.allocator, .shapes = &shapes, .status = .complete, .operator_count = 30, .unknown_count = 0, .limits = .{} };
    const page = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const native = layout.TextSpan.init(.{ .text = "native", .bbox = page, .paint = .{ .paint_state = .painting, .clip_state = .unclipped } });
    var accounted = try classify(std.testing.allocator, &evidence, &.{native}, page, null);
    defer accounted.deinit();
    try std.testing.expectEqual(@as(u32, 3), accounted.summary.native_accounted_count);
    try std.testing.expectEqual(@as(usize, 0), accounted.candidates.len);
    for (&shapes) |*shape| shape.rectangle_only = true;
    var graphics = try classify(std.testing.allocator, &evidence, &.{}, page, null);
    defer graphics.deinit();
    try std.testing.expectEqual(@as(u32, 3), graphics.summary.simple_graphic_count);
    for (&shapes) |*shape| shape.clip_state = .outside;
    var clipped = try classify(std.testing.allocator, &evidence, &.{}, page, null);
    defer clipped.deinit();
    try std.testing.expectEqual(@as(u32, 3), clipped.summary.clipped_out_count);
}

test "partial native clips cannot explain the unpainted portion of a span" {
    const box = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 10 };
    const span = layout.TextSpan.init(.{ .text = "wide native text", .bbox = box, .paint = .{
        .paint_state = .painting,
        .clip_state = .partial,
        .clip_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 10 },
    } });
    var checks: usize = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), nativeCoverage(box, &.{span}, &checks).fraction, 0.00001);
}

test "native coverage exhaustion abstains instead of publishing zero coverage" {
    var shapes = testShapes();
    const page = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    const native = layout.TextSpan.init(.{ .text = "native", .bbox = page, .paint = .{ .paint_state = .painting, .clip_state = .unclipped } });
    var spans: [65]layout.TextSpan = @splat(native);
    const evidence = vector.Evidence{ .allocator = std.testing.allocator, .shapes = &shapes, .status = .complete, .operator_count = 30, .unknown_count = 0, .limits = .{} };
    var result = try classify(std.testing.allocator, &evidence, &spans, page, null);
    defer result.deinit();
    try std.testing.expectEqual(.partial, result.summary.status);
    try std.testing.expectEqual(@as(u32, 3), result.summary.ambiguous_shape_count);
    try std.testing.expectEqual(@as(usize, 0), result.candidates.len);
}
