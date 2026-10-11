//! Evidence-based text availability. Completeness remains unverified: retained
//! spans and successful recognition do not prove that all visible marks were read.
const std = @import("std");
const layout = @import("layout.zig");
const reconcile = @import("reconcile.zig");

pub const Status = enum { text_available, empty_unverified, recovery_required, recovery_failed, recovered };
pub const Completeness = enum { unverified };
pub const RecoveryState = enum { not_required, not_invoked, completed, empty, unavailable, failed, timeout, invalid_output };

pub const Assessment = struct {
    status: Status = .empty_unverified,
    completeness: Completeness = .unverified,
    native_span_count: usize = 0,
    recognized_span_count: usize = 0,
    non_painting_span_count: usize = 0,
    clipped_out_span_count: usize = 0,
    uncertain_paint_span_count: usize = 0,
    requested_recovery: bool = false,
    recovery_state: RecoveryState = .not_required,
    unresolved_region_count: usize = 0,
};

pub fn assessRegion(result: anytype, route: anytype) Assessment {
    var assessment = countSpans(result, route.page_index, route.bbox);
    var unresolved = false;
    if (route.route.needs_ocr) {
        assessment.requested_recovery = true;
        const state = ocrState(result, route.page_index, route.region_index, route.bbox);
        assessment.recovery_state = combine(assessment.recovery_state, state);
        // A reused bitmap target can be larger than its unexplained vector
        // candidate. Output elsewhere in that crop does not recover the candidate.
        const recognized_bbox = if (@hasField(@TypeOf(route), "vector_evidence"))
            if (route.vector_evidence) |candidate| candidate.bbox else route.bbox
        else
            route.bbox;
        unresolved = state != .completed or countRecognized(result, route.page_index, recognized_bbox, .fresh_ocr) == 0;
    }
    if (route.route.needs_formula_model) {
        assessment.requested_recovery = true;
        const state = formulaState(result, route.page_index, route.region_index);
        assessment.recovery_state = combine(assessment.recovery_state, state);
        unresolved = unresolved or state != .completed or countRecognized(result, route.page_index, route.bbox, .formula_model) == 0;
    }
    assessment.unresolved_region_count = @intFromBool(unresolved);
    assessment.status = statusFor(assessment, unresolved);
    return assessment;
}

pub fn assessPage(result: anytype, page_index: u32) Assessment {
    var assessment = countSpans(result, page_index, null);
    var unresolved = false;
    for (result.page_routes) |route| {
        if (route.page_index != page_index or !route.route.needs_ocr) continue;
        // Regional attempts can satisfy a page OCR decision. Assess each
        // routed target below rather than inventing an absent page failure.
        var page_attempt = false;
        var regional_attempt = false;
        for (result.ocr_attempts) |attempt| {
            if (attempt.page_index != page_index) continue;
            if (attempt.region_index == null) page_attempt = true else regional_attempt = true;
        }
        if (!page_attempt and regional_attempt) continue;
        assessment.requested_recovery = true;
        const state = ocrState(result, page_index, null, null);
        assessment.recovery_state = combine(assessment.recovery_state, state);
        unresolved = state != .completed or countRecognized(result, page_index, null, .fresh_ocr) == 0;
    }
    for (result.region_routes) |route| {
        if (route.page_index != page_index) continue;
        const region = assessRegion(result, route);
        if (!region.requested_recovery) continue;
        assessment.requested_recovery = true;
        assessment.recovery_state = combine(assessment.recovery_state, region.recovery_state);
        assessment.unresolved_region_count += region.unresolved_region_count;
        unresolved = unresolved or region.unresolved_region_count > 0;
    }
    assessment.status = statusFor(assessment, unresolved);
    return assessment;
}

fn statusFor(assessment: Assessment, unresolved: bool) Status {
    if (assessment.requested_recovery) {
        if (unresolved) return switch (assessment.recovery_state) {
            .unavailable, .failed, .timeout, .invalid_output => .recovery_failed,
            else => .recovery_required,
        };
        return .recovered;
    }
    if (assessment.status == .text_available) return .text_available;
    return .empty_unverified;
}

fn intersects(a: layout.BBox, b: layout.BBox) bool {
    return @min(a.x1, b.x1) > @max(a.x0, b.x0) and @min(a.y1, b.y1) > @max(a.y0, b.y0);
}

fn included(span: anytype, page_index: u32, bbox: ?layout.BBox) bool {
    if (span.span.page_index != page_index or std.mem.trim(u8, span.span.text, " \t\r\n").len == 0) return false;
    return if (bbox) |region| intersects(span.span.bbox, region) else true;
}

fn countSpans(result: anytype, page_index: u32, bbox: ?layout.BBox) Assessment {
    var assessment: Assessment = .{};
    for (result.reconciled.spans) |span| {
        if (!included(span, page_index, bbox)) continue;
        assessment.status = .text_available;
        if (reconcile.hasSource(span.source_mask, .native_pdf) or reconcile.hasSource(span.source_mask, .embedded_ocr)) assessment.native_span_count += 1;
        if (reconcile.hasSource(span.source_mask, .fresh_ocr) or reconcile.hasSource(span.source_mask, .formula_model)) assessment.recognized_span_count += 1;
        if (span.span.paint.paint_state == .non_painting) assessment.non_painting_span_count += 1;
        if (span.span.paint.clip_state == .outside) assessment.clipped_out_span_count += 1;
        if (span.span.paint.paint_state == .unknown or span.span.paint.clip_state == .unknown or span.span.paint.clip_state == .partial) assessment.uncertain_paint_span_count += 1;
    }
    return assessment;
}

fn countRecognized(result: anytype, page_index: u32, bbox: ?layout.BBox, source: layout.SourceKind) usize {
    var count: usize = 0;
    for (result.reconciled.spans) |span| {
        if (included(span, page_index, bbox) and reconcile.hasSource(span.source_mask, source)) count += 1;
    }
    return count;
}

fn ocrState(result: anytype, page_index: u32, region_index: ?u32, bbox: ?layout.BBox) RecoveryState {
    var state: RecoveryState = .not_invoked;
    var found = false;
    for (result.ocr_attempts) |attempt| {
        if (attempt.page_index != page_index or attempt.region_index != region_index) continue;
        found = true;
        state = switch (attempt.status) {
            .not_invoked => .not_invoked,
            .completed => .completed,
            .empty => .empty,
            .unavailable => .unavailable,
            .failed => .failed,
            .timeout => .timeout,
            .invalid_output => .invalid_output,
        };
        if (attempt.selected) return state;
    }
    if (!found and region_index != null) {
        for (result.ocr_attempts) |attempt| {
            if (attempt.page_index == page_index and attempt.region_index == null) return ocrState(result, page_index, null, null);
        }
        // Derived layout regions can be explained by a successful image crop,
        // but a disjoint or only partly covering crop cannot qualify recovery.
        if (bbox) |region| {
            for (result.ocr_attempts) |attempt| {
                if (attempt.page_index != page_index or !attempt.selected or attempt.status != .completed) continue;
                if (attempt.crop_bbox) |crop| {
                    if (crop.x0 <= region.x0 and crop.y0 <= region.y0 and crop.x1 >= region.x1 and crop.y1 >= region.y1) return .completed;
                }
            }
        }
    }
    // A nonselected completed attempt is insufficient to attribute output to it.
    return if (state == .completed) .not_invoked else state;
}

fn formulaState(result: anytype, page_index: u32, region_index: u32) RecoveryState {
    var state: RecoveryState = .not_invoked;
    for (result.formula_attempts) |attempt| {
        if (attempt.page_index != page_index or attempt.region_index != region_index) continue;
        state = switch (attempt.status) {
            .completed => .completed,
            .empty => .empty,
            .unavailable => .unavailable,
            .failed => .failed,
            .timeout => .timeout,
            .invalid_output => .invalid_output,
        };
    }
    return state;
}

fn combine(a: RecoveryState, b: RecoveryState) RecoveryState {
    return if (severity(b) > severity(a)) b else a;
}

fn severity(state: RecoveryState) u8 {
    return switch (state) {
        .not_required => 0,
        .completed => 1,
        .not_invoked => 2,
        .empty => 3,
        .unavailable => 4,
        .failed => 5,
        .timeout => 6,
        .invalid_output => 7,
    };
}

const TestRoute = struct {
    page_index: u32 = 0,
    region_index: u32 = 0,
    bbox: layout.BBox = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 },
    route: struct { needs_ocr: bool = false, needs_formula_model: bool = false, needs_table_model: bool = false } = .{},
    vector_evidence: ?struct { bbox: layout.BBox } = null,
};
const TestOcrStatus = enum { not_invoked, completed, empty, unavailable, failed, timeout, invalid_output };
const TestOcrAttempt = struct { page_index: u32 = 0, region_index: ?u32 = null, crop_bbox: ?layout.BBox = null, status: TestOcrStatus, selected: bool = false };
const TestFormulaStatus = enum { completed, empty, unavailable, failed, timeout, invalid_output };
const TestFormulaAttempt = struct { page_index: u32 = 0, region_index: u32 = 0, status: TestFormulaStatus };
const TestResult = struct {
    reconciled: struct { spans: []const reconcile.ReconciledSpan = &.{} } = .{},
    page_routes: []const TestRoute = &.{},
    region_routes: []const TestRoute = &.{},
    ocr_attempts: []const TestOcrAttempt = &.{},
    formula_attempts: []const TestFormulaAttempt = &.{},
};

fn testSpan(source: layout.SourceKind, bbox: layout.BBox) reconcile.ReconciledSpan {
    return .{
        .span = layout.TextSpan.init(.{ .text = "text", .bbox = bbox, .source = source }),
        .source_mask = @as(reconcile.SourceMask, 1) << @as(u5, @intCast(@backingInt(source))),
        .chosen_source = source,
        .confidence = 1,
    };
}

test "regional OCR recovery scopes include derived regions but exclude disjoint or skipped targets" {
    const recognized = testSpan(.fresh_ocr, .{ .x1 = 10, .y1 = 10 });
    const regions = [_]TestRoute{
        .{ .region_index = 0, .bbox = .{ .x1 = 20, .y1 = 20 }, .route = .{ .needs_ocr = true } },
        .{ .region_index = 1, .bbox = .{ .x1 = 10, .y1 = 10 }, .route = .{ .needs_ocr = true } },
    };
    var result = TestResult{ .page_routes = &.{.{ .route = .{ .needs_ocr = true } }}, .region_routes = &regions, .ocr_attempts = &.{.{ .region_index = 0, .crop_bbox = .{ .x1 = 20, .y1 = 20 }, .selected = true, .status = .completed }}, .reconciled = .{ .spans = &.{recognized} } };
    try std.testing.expectEqual(Status.recovered, assessPage(result, 0).status);
    const disjoint = TestRoute{ .region_index = 2, .bbox = .{ .x0 = 50, .y0 = 50, .x1 = 100, .y1 = 100 }, .route = .{ .needs_ocr = true } };
    try std.testing.expectEqual(Status.recovery_required, assessRegion(result, disjoint).status);
    result.ocr_attempts = &.{
        .{ .region_index = 0, .crop_bbox = .{ .x1 = 20, .y1 = 20 }, .selected = true, .status = .completed },
        .{ .region_index = 1, .crop_bbox = .{ .x1 = 10, .y1 = 10 }, .status = .not_invoked },
    };
    try std.testing.expectEqual(Status.recovery_required, assessPage(result, 0).status);
    try std.testing.expectEqual(@as(usize, 1), assessPage(result, 0).unresolved_region_count);
}

test "reused OCR crops require recognized text within the vector candidate" {
    const candidate_box = layout.BBox{ .x0 = 20, .y0 = 20, .x1 = 40, .y1 = 40 };
    const route = TestRoute{ .route = .{ .needs_ocr = true }, .vector_evidence = .{ .bbox = candidate_box } };
    const disjoint = testSpan(.fresh_ocr, .{ .x0 = 50, .y0 = 50, .x1 = 60, .y1 = 60 });
    var result = TestResult{
        .region_routes = &.{route},
        .ocr_attempts = &.{.{ .region_index = 0, .status = .completed, .selected = true }},
        .reconciled = .{ .spans = &.{disjoint} },
    };
    const unresolved = assessRegion(result, route);
    try std.testing.expectEqual(@as(usize, 1), unresolved.recognized_span_count);
    try std.testing.expectEqual(@as(usize, 1), unresolved.unresolved_region_count);
    try std.testing.expectEqual(Status.recovery_required, unresolved.status);
    try std.testing.expectEqual(Status.recovery_required, assessPage(result, 0).status);
    const overlapping = testSpan(.fresh_ocr, candidate_box);
    result.reconciled.spans = &.{overlapping};
    try std.testing.expectEqual(Status.recovered, assessRegion(result, route).status);
    try std.testing.expectEqual(Status.recovered, assessPage(result, 0).status);
    try std.testing.expectEqual(Completeness.unverified, assessPage(result, 0).completeness);
}

test "coverage retains nonpainting clipped and uncertain evidence counts" {
    var hidden = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    hidden.span.paint = .{ .rendering_mode = 3, .paint_state = .non_painting, .clip_state = .unclipped };
    var clipped = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    clipped.span.paint = .{ .rendering_mode = 0, .paint_state = .painting, .clip_state = .outside, .clip_bbox = .{ .x0 = 20, .y0 = 20, .x1 = 30, .y1 = 30 } };
    const unknown = testSpan(.manual, .{ .x1 = 10, .y1 = 10 });
    const assessed = assessPage(TestResult{ .reconciled = .{ .spans = &.{ hidden, clipped, unknown } } }, 0);
    try std.testing.expectEqual(@as(usize, 1), assessed.non_painting_span_count);
    try std.testing.expectEqual(@as(usize, 1), assessed.clipped_out_span_count);
    try std.testing.expectEqual(@as(usize, 1), assessed.uncertain_paint_span_count);
    try std.testing.expectEqual(Completeness.unverified, assessed.completeness);
}

test "coverage never proves blankness or completeness from text presence" {
    const empty = assessPage(TestResult{}, 0);
    try std.testing.expectEqual(Status.empty_unverified, empty.status);
    try std.testing.expectEqual(Completeness.unverified, empty.completeness);
    const native = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    const text = assessPage(TestResult{ .reconciled = .{ .spans = &.{native} } }, 0);
    try std.testing.expectEqual(Status.text_available, text.status);
    try std.testing.expectEqual(Completeness.unverified, text.completeness);
}

test "coverage distinguishes disabled unavailable empty and selected OCR recovery" {
    const route: TestRoute = .{ .route = .{ .needs_ocr = true } };
    const recognized = testSpan(.fresh_ocr, .{ .x1 = 10, .y1 = 10 });
    for ([_]TestOcrStatus{ .not_invoked, .unavailable, .failed, .timeout, .invalid_output, .empty }) |state| {
        const assessed = assessPage(TestResult{ .page_routes = &.{route}, .ocr_attempts = &.{.{ .status = state }} }, 0);
        try std.testing.expectEqual(if (state == .empty or state == .not_invoked) Status.recovery_required else Status.recovery_failed, assessed.status);
        try std.testing.expectEqualStrings(@tagName(state), @tagName(assessed.recovery_state));
    }
    const recovered = assessPage(TestResult{ .page_routes = &.{route}, .reconciled = .{ .spans = &.{recognized} }, .ocr_attempts = &.{ .{ .status = .failed }, .{ .status = .completed, .selected = true } } }, 0);
    try std.testing.expectEqual(Status.recovered, recovered.status);
    try std.testing.expectEqual(RecoveryState.completed, recovered.recovery_state);
    const unselected = assessPage(TestResult{ .page_routes = &.{route}, .reconciled = .{ .spans = &.{recognized} }, .ocr_attempts = &.{.{ .status = .completed }} }, 0);
    try std.testing.expectEqual(Status.recovery_required, unselected.status);
}

test "coverage page OCR does not recover a disjoint scan region" {
    const native = testSpan(.native_pdf, .{ .x1 = 20, .y1 = 20 });
    const recognized = testSpan(.fresh_ocr, .{ .x1 = 20, .y1 = 20 });
    const scan: TestRoute = .{ .bbox = .{ .x0 = 50, .y0 = 50, .x1 = 100, .y1 = 100 }, .route = .{ .needs_ocr = true } };
    const result: TestResult = .{ .region_routes = &.{scan}, .reconciled = .{ .spans = &.{ native, recognized } }, .ocr_attempts = &.{.{ .status = .completed, .selected = true }} };
    try std.testing.expectEqual(Status.recovery_required, assessRegion(result, scan).status);
    const page = assessPage(result, 0);
    try std.testing.expectEqual(Status.recovery_required, page.status);
    try std.testing.expectEqual(@as(usize, 1), page.unresolved_region_count);
    try std.testing.expectEqual(@as(usize, 1), page.native_span_count);
}

test "coverage formula recovery requires matching region output and table routes remain native" {
    const formula: TestRoute = .{ .region_index = 3, .route = .{ .needs_formula_model = true } };
    const recognized = testSpan(.formula_model, .{ .x1 = 10, .y1 = 10 });
    const result: TestResult = .{ .region_routes = &.{formula}, .reconciled = .{ .spans = &.{recognized} }, .formula_attempts = &.{ .{ .region_index = 9, .status = .failed }, .{ .region_index = 3, .status = .completed } } };
    try std.testing.expectEqual(Status.recovered, assessRegion(result, formula).status);
    try std.testing.expectEqual(Status.recovered, assessPage(result, 0).status);
    const absent_output = assessRegion(TestResult{ .formula_attempts = result.formula_attempts }, formula);
    try std.testing.expectEqual(Status.recovery_required, absent_output.status);
    const native = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    const table: TestRoute = .{ .route = .{ .needs_table_model = true } };
    const table_assessment = assessRegion(TestResult{ .reconciled = .{ .spans = &.{native} } }, table);
    try std.testing.expectEqual(Status.text_available, table_assessment.status);
    try std.testing.expect(!table_assessment.requested_recovery);
}

test "coverage ignores whitespace and other pages but recognizes retained merged provenance" {
    var whitespace = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    whitespace.span.text = " \t\n";
    var other_page = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    other_page.span.page_index = 1;
    try std.testing.expectEqual(Status.empty_unverified, assessPage(TestResult{ .reconciled = .{ .spans = &.{ whitespace, other_page } } }, 0).status);
    var merged = testSpan(.native_pdf, .{ .x1 = 10, .y1 = 10 });
    merged.source_mask |= @as(reconcile.SourceMask, 1) << @as(u5, @intCast(@backingInt(layout.SourceKind.fresh_ocr)));
    const route: TestRoute = .{ .route = .{ .needs_ocr = true } };
    const result: TestResult = .{ .page_routes = &.{route}, .reconciled = .{ .spans = &.{merged} }, .ocr_attempts = &.{.{ .status = .completed, .selected = true }} };
    const assessed = assessPage(result, 0);
    try std.testing.expectEqual(Status.recovered, assessed.status);
    try std.testing.expectEqual(@as(usize, 1), assessed.native_span_count);
    try std.testing.expectEqual(@as(usize, 1), assessed.recognized_span_count);
}

test "coverage successful OCR cannot hide failed formula recovery on a mixed page" {
    const scan: TestRoute = .{ .region_index = 1, .route = .{ .needs_ocr = true } };
    const formula: TestRoute = .{ .region_index = 2, .route = .{ .needs_formula_model = true } };
    const recognized = testSpan(.fresh_ocr, .{ .x1 = 10, .y1 = 10 });
    const failed: TestResult = .{
        .region_routes = &.{ scan, formula },
        .reconciled = .{ .spans = &.{recognized} },
        .ocr_attempts = &.{.{ .status = .completed, .selected = true }},
        .formula_attempts = &.{.{ .region_index = 2, .status = .failed }},
    };
    const assessed = assessPage(failed, 0);
    try std.testing.expectEqual(Status.recovery_failed, assessed.status);
    try std.testing.expectEqual(RecoveryState.failed, assessed.recovery_state);
    try std.testing.expectEqual(@as(usize, 1), assessed.unresolved_region_count);
    const formula_span = testSpan(.formula_model, .{ .x1 = 10, .y1 = 10 });
    const retried: TestResult = .{
        .region_routes = failed.region_routes,
        .reconciled = .{ .spans = &.{ recognized, formula_span } },
        .ocr_attempts = failed.ocr_attempts,
        .formula_attempts = &.{ .{ .region_index = 2, .status = .failed }, .{ .region_index = 2, .status = .completed } },
    };
    try std.testing.expectEqual(Status.recovered, assessPage(retried, 0).status);
}
