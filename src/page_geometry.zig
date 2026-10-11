const std = @import("std");
const layout = @import("layout.zig");

pub const BBox = layout.BBox;
/// PDF affine convention: x' = a*x + c*y + e; y' = b*x + d*y + f.
pub const Matrix = [6]f64;
pub const Point = struct { x: f64, y: f64 };
pub const identity: Matrix = .{ 1, 0, 0, 1, 0, 0 };
pub const GeometryError = error{
    InvalidBox,
    EmptyCropBox,
    InvalidUserUnit,
    UnsupportedRotation,
    InvalidMatrix,
    SingularMatrix,
    InvalidPoint,
    InvalidDpi,
    InvalidPadding,
    EmptyRegion,
    RasterExtentOverflow,
    InvalidRasterDimensions,
};

/// Apply inner first, then outer. Composition itself does not validate inputs.
pub fn concat(outer: Matrix, inner: Matrix) Matrix {
    return .{
        outer[0] * inner[0] + outer[2] * inner[1],
        outer[1] * inner[0] + outer[3] * inner[1],
        outer[0] * inner[2] + outer[2] * inner[3],
        outer[1] * inner[2] + outer[3] * inner[3],
        outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
        outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    };
}

pub fn inverse(matrix: Matrix) GeometryError!Matrix {
    try validateMatrix(matrix);
    const determinant = matrix[0] * matrix[3] - matrix[1] * matrix[2];
    if (!std.math.isFinite(determinant)) return error.InvalidMatrix;
    if (determinant == 0) return error.SingularMatrix;
    const result: Matrix = .{
        matrix[3] / determinant,
        -matrix[1] / determinant,
        -matrix[2] / determinant,
        matrix[0] / determinant,
        (matrix[2] * matrix[5] - matrix[3] * matrix[4]) / determinant,
        (matrix[1] * matrix[4] - matrix[0] * matrix[5]) / determinant,
    };
    try validateMatrix(result);
    return result;
}

pub fn mapPoint(matrix: Matrix, point: Point) GeometryError!Point {
    try validateMatrix(matrix);
    if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return error.InvalidPoint;
    const result: Point = .{
        .x = matrix[0] * point.x + matrix[2] * point.y + matrix[4],
        .y = matrix[1] * point.x + matrix[3] * point.y + matrix[5],
    };
    if (!std.math.isFinite(result.x) or !std.math.isFinite(result.y)) return error.InvalidPoint;
    return result;
}

/// Map all four corners. Non-quarter Form matrices therefore produce an AABB.
pub fn mapBBox(matrix: Matrix, box: BBox) GeometryError!BBox {
    try validateBox(box, false);
    const corners = [_]Point{
        .{ .x = box.x0, .y = box.y0 },
        .{ .x = box.x0, .y = box.y1 },
        .{ .x = box.x1, .y = box.y0 },
        .{ .x = box.x1, .y = box.y1 },
    };
    const first = try mapPoint(matrix, corners[0]);
    var result: BBox = .{ .x0 = first.x, .y0 = first.y, .x1 = first.x, .y1 = first.y };
    for (corners[1..]) |corner| {
        const mapped = try mapPoint(matrix, corner);
        result.x0 = @min(result.x0, mapped.x);
        result.y0 = @min(result.y0, mapped.y);
        result.x1 = @max(result.x1, mapped.x);
        result.y1 = @max(result.y1, mapped.y);
    }
    return result;
}

pub const BoxKind = enum { media, crop };
pub const QuarterTurn = enum(u16) {
    none = 0,
    clockwise_90 = 90,
    clockwise_180 = 180,
    clockwise_270 = 270,
};

pub const PageView = struct {
    pdf_bbox: BBox,
    /// Physical points (1/72 inch), with the selected box's top-left at zero.
    width_points: f64,
    height_points: f64,
    pdf_to_display: Matrix,
    display_to_pdf: Matrix,
};

pub const PageGeometry = struct {
    media_box: BBox,
    /// CropBox intersected with MediaBox; defaults to MediaBox if absent.
    crop_box: BBox,
    rotation: QuarterTurn,
    user_unit: f64,
    media: PageView,
    crop: PageView,

    pub fn init(media_box: BBox, crop_box: ?BBox, raw_rotate: i32, user_unit: f64) GeometryError!PageGeometry {
        try validateBox(media_box, true);
        if (!std.math.isFinite(user_unit) or user_unit <= 0 or user_unit > 75000) return error.InvalidUserUnit;
        const normalized = @mod(raw_rotate, 360);
        if (@mod(normalized, 90) != 0) return error.UnsupportedRotation;
        const rotation: QuarterTurn = @fromBackingInt(@intCast(@as(u16, @intCast(normalized))));
        var effective_crop = media_box;
        if (crop_box) |box| {
            try validateBox(box, true);
            effective_crop = intersect(media_box, box) orelse return error.EmptyCropBox;
        }
        return .{
            .media_box = media_box,
            .crop_box = effective_crop,
            .rotation = rotation,
            .user_unit = user_unit,
            .media = try makeView(media_box, rotation, user_unit),
            .crop = try makeView(effective_crop, rotation, user_unit),
        };
    }

    pub fn view(self: PageGeometry, kind: BoxKind) PageView {
        return switch (kind) {
            .media => self.media,
            .crop => self.crop,
        };
    }

    pub fn pdfToDisplay(self: PageGeometry, kind: BoxKind) Matrix {
        return self.view(kind).pdf_to_display;
    }

    pub fn displayToPdf(self: PageGeometry, kind: BoxKind) Matrix {
        return self.view(kind).display_to_pdf;
    }

    pub fn planCrop(self: PageGeometry, region: BBox, options: CropOptions) GeometryError!RasterPlan {
        try validateBox(region, true);
        if (!std.math.isFinite(options.dpi) or options.dpi <= 0) return error.InvalidDpi;
        if (!std.math.isFinite(options.padding_points) or options.padding_points < 0) return error.InvalidPadding;
        const selected = self.view(options.box);
        const effective_dpi = options.dpi * self.user_unit;
        if (!std.math.isFinite(effective_dpi) or effective_dpi <= 0) return error.InvalidDpi;
        // Use the backend's effective DPI directly. Scaling physical extents by
        // requested DPI separately can round an integer extent just above its
        // grid edge while the crop matrix still maps that edge exactly.
        const scale = effective_dpi / 72;
        if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidDpi;
        const raster_view = try makeView(selected.pdf_bbox, self.rotation, 1);
        // Poppler forms the canvas extent as (raw extent * effective DPI) / 72.
        // Keep that evaluation order: 792 * (300 / 72) rounds above 3300.
        const canvas_width = try pixelExtent(raster_view.width_points * effective_dpi / 72);
        const canvas_height = try pixelExtent(raster_view.height_points * effective_dpi / 72);
        const padding_pdf = options.padding_points / self.user_unit;
        const padded: BBox = .{
            .x0 = region.x0 - padding_pdf,
            .y0 = region.y0 - padding_pdf,
            .x1 = region.x1 + padding_pdf,
            .y1 = region.y1 + padding_pdf,
        };
        try validateBox(padded, true);
        const clamped = intersect(selected.pdf_bbox, padded) orelse return error.EmptyRegion;
        const pdf_to_pixel = concat(.{ scale, 0, 0, scale, 0, 0 }, raster_view.pdf_to_display);
        const pixels = try mapBBox(pdf_to_pixel, clamped);
        const x = try pixelCoordinate(@max(0, @floor(pixels.x0)), canvas_width);
        const y = try pixelCoordinate(@max(0, @floor(pixels.y0)), canvas_height);
        const right = try pixelCoordinate(@min(@as(f64, @floatFromInt(canvas_width)), @ceil(pixels.x1)), canvas_width);
        const bottom = try pixelCoordinate(@min(@as(f64, @floatFromInt(canvas_height)), @ceil(pixels.y1)), canvas_height);
        if (right <= x or bottom <= y) return error.EmptyRegion;
        const width = right - x;
        const height = bottom - y;
        const pixel_to_pdf = concat(try inverse(pdf_to_pixel), .{ 1, 0, 0, 1, @floatFromInt(x), @floatFromInt(y) });
        const actual = try mapBBox(pixel_to_pdf, .{ .x0 = 0, .y0 = 0, .x1 = @floatFromInt(width), .y1 = @floatFromInt(height) });
        return .{
            .box = options.box,
            .requested_bbox = region,
            .clamped_bbox = clamped,
            .pdf_bbox = actual,
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .canvas_width = canvas_width,
            .canvas_height = canvas_height,
            .pixel_to_pdf = pixel_to_pdf,
            .requested_dpi = options.dpi,
            .rasterizer_dpi = effective_dpi,
        };
    }

    /// Full-page compatibility maps the complete accepted bitmap to exact PDF
    /// extents, rather than expanding fractional page extents to a DPI grid.
    pub fn fullPagePixelToPdf(self: PageGeometry, kind: BoxKind, accepted_width: u32, accepted_height: u32) GeometryError!Matrix {
        if (accepted_width == 0 or accepted_height == 0 or accepted_width > max_raster_coordinate or accepted_height > max_raster_coordinate) return error.InvalidRasterDimensions;
        const selected = self.view(kind);
        const display_to_pixel: Matrix = .{
            @as(f64, @floatFromInt(accepted_width)) / selected.width_points,
            0,
            0,
            @as(f64, @floatFromInt(accepted_height)) / selected.height_points,
            0,
            0,
        };
        return inverse(concat(display_to_pixel, selected.pdf_to_display));
    }
};

pub const CropOptions = struct {
    box: BoxKind = .media,
    /// Physical points; divide by UserUnit before padding raw PDF coordinates.
    padding_points: f64 = 0,
    dpi: f64,
};

test "raster canvas preserves exact letter fallback dimensions at 300 DPI" {
    const page = try PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = 612, .y1 = 792 }, null, 0, 1);
    const plan = try page.planCrop(page.media_box, .{ .dpi = 300 });
    try std.testing.expectEqual(@as(u32, 2550), plan.canvas_width);
    try std.testing.expectEqual(@as(u32, 3300), plan.canvas_height);
    try std.testing.expectEqual(plan.canvas_width, plan.width);
    try std.testing.expectEqual(plan.canvas_height, plan.height);
}

pub const RasterPlan = struct {
    box: BoxKind,
    requested_bbox: BBox,
    clamped_bbox: BBox,
    /// Outward DPI-grid extent; may exceed a fractional page edge by <1 pixel.
    pdf_bbox: BBox,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    canvas_width: u32,
    canvas_height: u32,
    /// Crop-local top-left pixel edges to canonical, unrotated PDF user space.
    pixel_to_pdf: Matrix,
    requested_dpi: f64,
    /// The selected rasterizer ignores UserUnit, so physical scale uses this DPI.
    rasterizer_dpi: f64,

    pub fn pixelCount(self: RasterPlan) u64 {
        return @as(u64, self.width) * self.height;
    }
};

const max_raster_coordinate: u32 = std.math.maxInt(i32);

fn validateMatrix(matrix: Matrix) GeometryError!void {
    for (matrix) |value| if (!std.math.isFinite(value)) return error.InvalidMatrix;
}

fn validateBox(box: BBox, nonempty: bool) GeometryError!void {
    if (!std.math.isFinite(box.x0) or !std.math.isFinite(box.y0) or !std.math.isFinite(box.x1) or !std.math.isFinite(box.y1)) return error.InvalidBox;
    if (box.x1 < box.x0 or box.y1 < box.y0 or (nonempty and (box.x1 == box.x0 or box.y1 == box.y0))) return error.InvalidBox;
    if (!std.math.isFinite(box.x1 - box.x0) or !std.math.isFinite(box.y1 - box.y0)) return error.InvalidBox;
}

fn intersect(a: BBox, b: BBox) ?BBox {
    const result: BBox = .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    if (result.x0 >= result.x1 or result.y0 >= result.y1) return null;
    return result;
}

fn makeView(box: BBox, rotation: QuarterTurn, unit: f64) GeometryError!PageView {
    const matrix: Matrix = switch (rotation) {
        .none => .{ unit, 0, 0, -unit, -unit * box.x0, unit * box.y1 },
        .clockwise_90 => .{ 0, unit, unit, 0, -unit * box.y0, -unit * box.x0 },
        .clockwise_180 => .{ -unit, 0, 0, unit, unit * box.x1, -unit * box.y0 },
        .clockwise_270 => .{ 0, -unit, -unit, 0, unit * box.y1, unit * box.x1 },
    };
    const sideways = rotation == .clockwise_90 or rotation == .clockwise_270;
    const width = (if (sideways) box.y1 - box.y0 else box.x1 - box.x0) * unit;
    const height = (if (sideways) box.x1 - box.x0 else box.y1 - box.y0) * unit;
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0) return error.InvalidBox;
    return .{ .pdf_bbox = box, .width_points = width, .height_points = height, .pdf_to_display = matrix, .display_to_pdf = try inverse(matrix) };
}

fn pixelExtent(value: f64) GeometryError!u32 {
    if (!std.math.isFinite(value) or value <= 0) return error.RasterExtentOverflow;
    const rounded = @ceil(value);
    if (rounded > @as(f64, @floatFromInt(max_raster_coordinate))) return error.RasterExtentOverflow;
    return @intFromFloat(rounded);
}

fn pixelCoordinate(value: f64, limit: u32) GeometryError!u32 {
    if (!std.math.isFinite(value) or value < 0 or value > @as(f64, @floatFromInt(limit))) return error.RasterExtentOverflow;
    return @intFromFloat(value);
}

fn expectMatrix(expected: Matrix, actual: Matrix) !void {
    for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, 1e-9);
}

fn expectBox(expected: BBox, actual: BBox) !void {
    try std.testing.expectApproxEqAbs(expected.x0, actual.x0, 1e-9);
    try std.testing.expectApproxEqAbs(expected.y0, actual.y0, 1e-9);
    try std.testing.expectApproxEqAbs(expected.x1, actual.x1, 1e-9);
    try std.testing.expectApproxEqAbs(expected.y1, actual.y1, 1e-9);
}

fn expectWindow(expected: [4]u32, actual: RasterPlan) !void {
    try std.testing.expectEqual(expected[0], actual.x);
    try std.testing.expectEqual(expected[1], actual.y);
    try std.testing.expectEqual(expected[2], actual.width);
    try std.testing.expectEqual(expected[3], actual.height);
}

test "geometry affine composition inverse and four-corner bounds" {
    const form: Matrix = .{ 0, 2, -2, 0, 80, 40 };
    const local: BBox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 5 };
    try expectBox(.{ .x0 = 70, .y0 = 40, .x1 = 80, .y1 = 60 }, try mapBBox(form, local));
    try expectMatrix(identity, concat(try inverse(form), form));
    try expectMatrix(.{ 0, 4, -6, 0, 240, 90 }, concat(.{ 3, 0, 0, 2, 0, 10 }, form));
    const diagonal: Matrix = .{ 1, 1, -1, 1, 0, 0 };
    try expectBox(.{ .x0 = -5, .y0 = 0, .x1 = 10, .y1 = 15 }, try mapBBox(diagonal, local));
    try std.testing.expectError(error.SingularMatrix, inverse(.{ 1, 2, 2, 4, 0, 0 }));
    try std.testing.expectError(error.InvalidMatrix, inverse(.{ std.math.inf(f64), 0, 0, 1, 0, 0 }));
    try std.testing.expectError(error.InvalidPoint, mapPoint(identity, .{ .x = std.math.nan(f64), .y = 0 }));
}

test "geometry literal quarter-turn display and raster goldens at nonzero origin" {
    const media: BBox = .{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 220 };
    const region: BBox = .{ .x0 = 25, .y0 = 40, .x1 = 55, .y1 = 100 };
    const rotations = [_]i32{ 0, 90, 180, 270 };
    const expected_matrices = [_]Matrix{
        .{ 1, 0, 0, -1, -10, 220 },
        .{ 0, 1, 1, 0, -20, -10 },
        .{ -1, 0, 0, 1, 110, -20 },
        .{ 0, -1, -1, 0, 220, 110 },
    };
    const expected_display = [_]BBox{
        .{ .x0 = 15, .y0 = 120, .x1 = 45, .y1 = 180 },
        .{ .x0 = 20, .y0 = 15, .x1 = 80, .y1 = 45 },
        .{ .x0 = 55, .y0 = 20, .x1 = 85, .y1 = 80 },
        .{ .x0 = 120, .y0 = 55, .x1 = 180, .y1 = 85 },
    };
    const expected_windows = [_][4]u32{ .{ 30, 240, 60, 120 }, .{ 40, 30, 120, 60 }, .{ 110, 40, 60, 120 }, .{ 240, 110, 120, 60 } };
    const expected_canvas = [_][2]u32{ .{ 200, 400 }, .{ 400, 200 }, .{ 200, 400 }, .{ 400, 200 } };
    const expected_pixel_to_pdf = [_]Matrix{
        .{ 0.5, 0, 0, -0.5, 25, 100 },
        .{ 0, 0.5, 0.5, 0, 25, 40 },
        .{ -0.5, 0, 0, 0.5, 55, 40 },
        .{ 0, -0.5, -0.5, 0, 55, 100 },
    };
    for (rotations, 0..) |rotation, index| {
        const page = try PageGeometry.init(media, null, rotation, 1);
        try expectMatrix(expected_matrices[index], page.pdfToDisplay(.media));
        try expectBox(expected_display[index], try mapBBox(page.pdfToDisplay(.media), region));
        const plan = try page.planCrop(region, .{ .dpi = 144 });
        try expectWindow(expected_windows[index], plan);
        try std.testing.expectEqual(expected_canvas[index][0], plan.canvas_width);
        try std.testing.expectEqual(expected_canvas[index][1], plan.canvas_height);
        try expectMatrix(expected_pixel_to_pdf[index], plan.pixel_to_pdf);
        try expectBox(region, plan.pdf_bbox);
        try expectBox(region, try mapBBox(page.displayToPdf(.media), expected_display[index]));
    }
}

test "geometry UserUnit physical scaling and literal Form coordinates are applied once" {
    const media: BBox = .{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 220 };
    const page = try PageGeometry.init(media, null, 90, 2);
    const form: Matrix = .{ 0, 2, -2, 0, 80, 40 };
    const canonical = try mapBBox(form, .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 5 });
    try expectBox(.{ .x0 = 70, .y0 = 40, .x1 = 80, .y1 = 60 }, canonical);
    try expectBox(.{ .x0 = 40, .y0 = 120, .x1 = 80, .y1 = 140 }, try mapBBox(page.pdfToDisplay(.media), canonical));
    const form_plan = try page.planCrop(canonical, .{ .dpi = 144 });
    try expectWindow(.{ 80, 240, 80, 40 }, form_plan);
    try expectMatrix(.{ 0, 0.25, 0.25, 0, 70, 40 }, form_plan.pixel_to_pdf);
    try std.testing.expectEqual(@as(f64, 288), form_plan.rasterizer_dpi);
    const plan = try page.planCrop(.{ .x0 = 25, .y0 = 40, .x1 = 55, .y1 = 100 }, .{ .dpi = 144 });
    try expectWindow(.{ 80, 60, 240, 120 }, plan);
    try std.testing.expectEqual(@as(u32, 800), plan.canvas_width);
    try std.testing.expectEqual(@as(u32, 400), plan.canvas_height);
    try std.testing.expectEqual(@as(u64, 28800), plan.pixelCount());
}

test "geometry crop intersection and independent MediaBox CropBox display origins" {
    const media: BBox = .{ .x0 = 10, .y0 = 20, .x1 = 210, .y1 = 120 };
    const crop: BBox = .{ .x0 = 25, .y0 = 40, .x1 = 175, .y1 = 100 };
    const page = try PageGeometry.init(media, crop, 90, 1);
    try std.testing.expectEqual(@as(f64, 100), page.media.width_points);
    try std.testing.expectEqual(@as(f64, 200), page.media.height_points);
    try std.testing.expectEqual(@as(f64, 60), page.crop.width_points);
    try std.testing.expectEqual(@as(f64, 150), page.crop.height_points);
    const point: Point = .{ .x = 40, .y = 50 };
    try std.testing.expectEqual(Point{ .x = 30, .y = 30 }, try mapPoint(page.pdfToDisplay(.media), point));
    try std.testing.expectEqual(Point{ .x = 10, .y = 15 }, try mapPoint(page.pdfToDisplay(.crop), point));
    const clipped = try PageGeometry.init(media, .{ .x0 = 0, .y0 = 0, .x1 = 175, .y1 = 100 }, 0, 1);
    try expectBox(.{ .x0 = 10, .y0 = 20, .x1 = 175, .y1 = 100 }, clipped.crop_box);
    const crop_plan = try page.planCrop(media, .{ .box = .crop, .dpi = 72 });
    try expectWindow(.{ 0, 0, 60, 150 }, crop_plan);
    try expectBox(crop, crop_plan.pdf_bbox);
}

test "geometry fractional origins outward grid and full-page extent compatibility" {
    const media: BBox = .{ .x0 = 10.25, .y0 = 20.5, .x1 = 110.25, .y1 = 220.5 };
    const region: BBox = .{ .x0 = 25.2, .y0 = 35.3, .x1 = 50.4, .y1 = 70.6 };
    for ([_]i32{ 0, 90 }, 0..) |rotation, index| {
        const page = try PageGeometry.init(media, null, rotation, 1);
        const plan = try page.planCrop(region, .{ .dpi = 144 });
        try expectWindow(([_][4]u32{ .{ 29, 299, 52, 72 }, .{ 29, 29, 72, 52 } })[index], plan);
        try expectBox(.{ .x0 = 24.75, .y0 = 35, .x1 = 50.75, .y1 = 71 }, plan.pdf_bbox);
    }
    const fractional: BBox = .{ .x0 = 0, .y0 = 0, .x1 = 9.8, .y1 = 19.8 };
    const unrotated = try PageGeometry.init(fractional, null, 0, 1);
    try expectMatrix(.{ 0.98, 0, 0, -0.99, 0, 19.8 }, try unrotated.fullPagePixelToPdf(.media, 10, 20));
    const rotated = try PageGeometry.init(fractional, null, 90, 2);
    try expectMatrix(.{ 0, 0.99, 0.98, 0, 0, 0 }, try rotated.fullPagePixelToPdf(.media, 20, 10));
    // The quarter rotation swaps extents: PDF x spans the bitmap's height.
    try expectBox(fractional, try mapBBox(try rotated.fullPagePixelToPdf(.media, 20, 10), .{ .x0 = 0, .y0 = 0, .x1 = 20, .y1 = 10 }));
    const probe = try PageGeometry.init(.{ .x0 = 10, .y0 = 20, .x1 = 210, .y1 = 120 }, null, 0, 1);
    const fractional_dpi = try probe.planCrop(probe.media_box, .{ .dpi = 144.5 });
    try std.testing.expectEqual(@as(u32, 402), fractional_dpi.canvas_width);
    try std.testing.expectEqual(@as(u32, 201), fractional_dpi.canvas_height);
    try std.testing.expectEqual(@as(f64, 144.5), fractional_dpi.rasterizer_dpi);
}

test "geometry clamping physical padding and fractional edge expansion" {
    const page = try PageGeometry.init(.{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 220 }, null, 0, 2);
    const plan = try page.planCrop(.{ .x0 = 12, .y0 = 40, .x1 = 20, .y1 = 50 }, .{ .padding_points = 10, .dpi = 72 });
    try expectBox(.{ .x0 = 10, .y0 = 35, .x1 = 25, .y1 = 55 }, plan.clamped_bbox);
    try expectWindow(.{ 0, 330, 30, 40 }, plan);
    try std.testing.expectError(error.EmptyRegion, page.planCrop(.{ .x0 = 200, .y0 = 300, .x1 = 210, .y1 = 310 }, .{ .dpi = 72 }));
    const fractional = try PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = 9.8, .y1 = 19.8 }, null, 0, 1);
    const full_grid = try fractional.planCrop(fractional.media_box, .{ .dpi = 72 });
    try expectWindow(.{ 0, 0, 10, 20 }, full_grid);
    try expectBox(.{ .x0 = 0, .y0 = -0.2, .x1 = 10, .y1 = 19.8 }, full_grid.pdf_bbox);
}

test "geometry literal full-page extent matrices for every quarter and UserUnit" {
    const box: BBox = .{ .x0 = 10, .y0 = 20, .x1 = 19.8, .y1 = 39.8 };
    const rotations = [_]i32{ 0, 90, 180, 270 };
    const dimensions = [_][2]u32{ .{ 10, 20 }, .{ 20, 10 }, .{ 10, 20 }, .{ 20, 10 } };
    const expected = [_]Matrix{
        .{ 0.98, 0, 0, -0.99, 10, 39.8 },
        .{ 0, 0.99, 0.98, 0, 10, 20 },
        .{ -0.98, 0, 0, 0.99, 19.8, 20 },
        .{ 0, -0.99, -0.98, 0, 19.8, 39.8 },
    };
    for ([_]f64{ 1, 2 }) |unit| {
        for (rotations, 0..) |rotation, index| {
            const page = try PageGeometry.init(box, null, rotation, unit);
            const matrix = try page.fullPagePixelToPdf(.media, dimensions[index][0], dimensions[index][1]);
            try expectMatrix(expected[index], matrix);
            try expectBox(box, try mapBBox(matrix, .{
                .x0 = 0,
                .y0 = 0,
                .x1 = @floatFromInt(dimensions[index][0]),
                .y1 = @floatFromInt(dimensions[index][1]),
            }));
        }
    }
}

test "geometry fractional UserUnit raster scale matches backend canvas seam" {
    // Installed Poppler 26.02 renders MediaBox [0 0 .9 10], UserUnit 3,
    // with effective -r 240 as 3x34. Physical display metadata remains 2.7x30.
    const page = try PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = 0.9, .y1 = 10 }, null, 0, 3);
    const plan = try page.planCrop(page.media_box, .{ .dpi = 80 });
    try std.testing.expectApproxEqAbs(@as(f64, 2.7), page.media.width_points, 1e-12);
    try std.testing.expectEqual(@as(f64, 240), plan.rasterizer_dpi);
    try std.testing.expectEqual(@as(u32, 3), plan.canvas_width);
    try std.testing.expectEqual(@as(u32, 34), plan.canvas_height);
    try expectWindow(.{ 0, 0, 3, 34 }, plan);
    try expectMatrix(.{ 0.3, 0, 0, -0.3, 0, 10 }, plan.pixel_to_pdf);
}

test "geometry rotation normalization finite inputs and bounded raster integers" {
    const box: BBox = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 200 };
    try std.testing.expectEqual(QuarterTurn.clockwise_270, (try PageGeometry.init(box, null, -90, 1)).rotation);
    try std.testing.expectEqual(QuarterTurn.clockwise_90, (try PageGeometry.init(box, null, 450, 1)).rotation);
    try std.testing.expectError(error.UnsupportedRotation, PageGeometry.init(box, null, 45, 1));
    for ([_]f64{ 0, -1, 75000.1, std.math.nan(f64), std.math.inf(f64) }) |unit| {
        try std.testing.expectError(error.InvalidUserUnit, PageGeometry.init(box, null, 0, unit));
    }
    _ = try PageGeometry.init(box, null, 0, 75000);
    try std.testing.expectError(error.InvalidBox, PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 1 }, null, 0, 1));
    try std.testing.expectError(error.InvalidBox, PageGeometry.init(.{ .x0 = 2, .y0 = 0, .x1 = 1, .y1 = 1 }, null, 0, 1));
    try std.testing.expectError(error.InvalidBox, PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = std.math.nan(f64), .y1 = 1 }, null, 0, 1));
    try std.testing.expectError(error.EmptyCropBox, PageGeometry.init(box, .{ .x0 = 300, .y0 = 0, .x1 = 400, .y1 = 100 }, 0, 1));
    const page = try PageGeometry.init(box, null, 0, 1);
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |dpi| {
        try std.testing.expectError(error.InvalidDpi, page.planCrop(box, .{ .dpi = dpi }));
    }
    try std.testing.expectError(error.InvalidPadding, page.planCrop(box, .{ .dpi = 72, .padding_points = -1 }));
    try std.testing.expectError(error.InvalidRasterDimensions, page.fullPagePixelToPdf(.media, 0, 1));
    try std.testing.expectError(error.InvalidRasterDimensions, page.fullPagePixelToPdf(.media, std.math.maxInt(u32), 1));
    const huge = try PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = 2147483648, .y1 = 1 }, null, 0, 1);
    try std.testing.expectError(error.RasterExtentOverflow, huge.planCrop(huge.media_box, .{ .dpi = 72 }));
    const edge = try PageGeometry.init(.{ .x0 = 0, .y0 = 0, .x1 = 2147483647, .y1 = 1 }, null, 0, 1);
    const bounded = try edge.planCrop(edge.media_box, .{ .dpi = 72 });
    try std.testing.expectEqual(max_raster_coordinate, bounded.width);
    try std.testing.expectEqual(@as(u64, max_raster_coordinate), bounded.pixelCount());
}
