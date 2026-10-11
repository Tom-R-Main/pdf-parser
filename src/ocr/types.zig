const std = @import("std");
const layout = @import("../layout.zig");
const page_geometry = @import("../page_geometry.zig");

pub const Backend = enum {
    tesseract_cli,
    tesseract_c,
};

pub const AttemptStatus = enum {
    not_invoked,
    completed,
    empty,
    unavailable,
    failed,
    timeout,
    invalid_output,
};

pub const AttemptStage = enum {
    rasterize,
    recognize,
};

pub const DiagnosticCode = enum {
    ocr_disabled,
    rasterizer_requires_file,
    rasterizer_unavailable,
    rasterizer_failed,
    rasterizer_timeout,
    rasterizer_output_limit,
    invalid_raster_image,
    rasterizer_pixel_limit,
    rasterizer_image_byte_limit,
    rasterizer_rotation_unsupported,
    invalid_crop_geometry,
    ocr_region_limit,
    ocr_attempt_limit,
    tesseract_unavailable,
    tesseract_failed,
    tesseract_timeout,
    tesseract_output_limit,
    invalid_tesseract_output,
    tesseract_c_backend_disabled,
};

pub const Policy = enum {
    single,
    bounded,
};

pub const PageSegMode = enum(u8) {
    osd_only = 0,
    auto_osd = 1,
    auto_only = 2,
    auto = 3,
    single_column = 4,
    single_block_vertical = 5,
    single_block = 6,
    single_line = 7,
    single_word = 8,
    circle_word = 9,
    single_char = 10,
    sparse_text = 11,
    sparse_text_osd = 12,
    raw_line = 13,

    pub fn tesseractNumber(self: PageSegMode) u8 {
        return @backingInt(self);
    }
};

pub const OcrConfig = struct {
    backend: Backend = .tesseract_cli,
    policy: Policy = .bounded,
    executable: []const u8 = "tesseract",
    rasterizer_executable: []const u8 = "pdftoppm",
    lang: []const u8 = "eng",
    psm: PageSegMode = .single_block,
    dpi: u32 = 200,
    fallback_psm: PageSegMode = .sparse_text,
    fallback_dpi: u32 = 300,
    max_attempts: u8 = 2,
    retry_min_character_count: usize = 8,
    retry_min_mean_confidence: f32 = 0.65,
    retry_min_text_coverage: f32 = 0.0005,
    rasterize_grayscale: bool = true,
    timeout_ms: u32 = 10_000,
    stdout_limit: usize = 16 * 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
    max_image_pixels: usize = 40_000_000,
    max_image_bytes: usize = 32 * 1024 * 1024,
    max_regions_per_page: usize = 8,
    max_attempts_per_page: usize = 16,
    crop_padding_points: f64 = 2,
};

pub const OcrInput = struct {
    page_index: u32,
    pdf_bbox: layout.BBox,
    image_path: []const u8,
    pixel_width: u32,
    pixel_height: u32,
    pixel_to_pdf: ?page_geometry.Matrix = null,
    rasterizer_dpi: ?f64 = null,
    image_sha256: ?[32]u8 = null,
    image_byte_length: ?usize = null,

    pub fn validateGeometry(self: OcrInput) !void {
        if (self.pixel_width == 0 or self.pixel_height == 0) return error.EmptyImage;
        _ = try page_geometry.mapBBox(page_geometry.identity, self.pdf_bbox);
        if (self.pdf_bbox.x1 <= self.pdf_bbox.x0 or self.pdf_bbox.y1 <= self.pdf_bbox.y0) return error.InvalidBox;
        if (self.rasterizer_dpi) |dpi| {
            if (!std.math.isFinite(dpi) or dpi <= 0) return error.InvalidDpi;
        }
        if (self.pixel_to_pdf) |matrix| {
            _ = try page_geometry.inverse(matrix);
            _ = try page_geometry.mapBBox(matrix, .{
                .x0 = 0,
                .y0 = 0,
                .x1 = @floatFromInt(self.pixel_width),
                .y1 = @floatFromInt(self.pixel_height),
            });
        }
    }

    pub fn mapWordBBox(self: OcrInput, left: u32, top: u32, width: u32, height: u32) !layout.BBox {
        try self.validateGeometry();
        const right = @as(u64, left) + width;
        const bottom = @as(u64, top) + height;
        if (width == 0 or height == 0 or right > self.pixel_width or bottom > self.pixel_height) return error.InvalidWordBounds;
        if (self.pixel_to_pdf) |matrix| {
            const bbox = try page_geometry.mapBBox(matrix, .{
                .x0 = @floatFromInt(left),
                .y0 = @floatFromInt(top),
                .x1 = @floatFromInt(right),
                .y1 = @floatFromInt(bottom),
            });
            if (bbox.x1 <= bbox.x0 or bbox.y1 <= bbox.y0) return error.InvalidWordBounds;
            return bbox;
        }
        // Keep the original proportional calculation for callers without a
        // raster transform, including its exact outward-crop bbox semantics.
        const x_scale = (self.pdf_bbox.x1 - self.pdf_bbox.x0) / @as(f64, @floatFromInt(self.pixel_width));
        const y_scale = (self.pdf_bbox.y1 - self.pdf_bbox.y0) / @as(f64, @floatFromInt(self.pixel_height));
        const x0 = self.pdf_bbox.x0 + @as(f64, @floatFromInt(left)) * x_scale;
        const y1 = self.pdf_bbox.y1 - @as(f64, @floatFromInt(top)) * y_scale;
        const bbox = layout.BBox{
            .x0 = x0,
            .y0 = y1 - @as(f64, @floatFromInt(height)) * y_scale,
            .x1 = x0 + @as(f64, @floatFromInt(width)) * x_scale,
            .y1 = y1,
        };
        _ = try page_geometry.mapBBox(page_geometry.identity, bbox);
        if (bbox.x1 <= bbox.x0 or bbox.y1 <= bbox.y0) return error.InvalidWordBounds;
        return bbox;
    }
};

pub const RasterizeOutcome = struct {
    status: AttemptStatus,
    input: ?OcrInput = null,
    exit_code: ?u8 = null,
    stderr: []u8 = &.{},
    duration_ms: u64 = 0,
    diagnostic_code: ?DiagnosticCode = null,

    pub fn deinit(self: *RasterizeOutcome, allocator: anytype) void {
        if (self.stderr.len > 0) allocator.free(self.stderr);
        self.stderr = &.{};
    }
};

pub const RecognitionOutcome = struct {
    status: AttemptStatus,
    spans: []layout.TextSpan = &.{},
    exit_code: ?u8 = null,
    stderr: []u8 = &.{},
    duration_ms: u64 = 0,
    diagnostic_code: ?DiagnosticCode = null,

    pub fn deinit(self: *RecognitionOutcome, allocator: anytype) void {
        for (self.spans) |span| {
            if (span.text.len > 0) allocator.free(@constCast(span.text));
        }
        if (self.spans.len > 0) allocator.free(self.spans);
        if (self.stderr.len > 0) allocator.free(self.stderr);
        self.spans = &.{};
        self.stderr = &.{};
    }
};
