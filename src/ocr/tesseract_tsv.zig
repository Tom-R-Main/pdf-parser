//! Tesseract TSV to span conversion.

const std = @import("std");
const layout = @import("../layout.zig");
const types = @import("types.zig");
const page_geometry = @import("../page_geometry.zig");

pub const ParseInput = struct {
    page_index: u32,
    pdf_bbox: layout.BBox,
    pixel_width: u32,
    pixel_height: u32,
    pixel_to_pdf: ?page_geometry.Matrix = null,
    rasterizer_dpi: ?f64 = null,
};

const expected_header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext";

pub fn parse(
    allocator: std.mem.Allocator,
    tsv: []const u8,
    input: ParseInput,
) ![]layout.TextSpan {
    const geometry = types.OcrInput{
        .page_index = input.page_index,
        .pdf_bbox = input.pdf_bbox,
        .image_path = "",
        .pixel_width = input.pixel_width,
        .pixel_height = input.pixel_height,
        .pixel_to_pdf = input.pixel_to_pdf,
        .rasterizer_dpi = input.rasterizer_dpi,
    };
    try geometry.validateGeometry();

    var spans: std.ArrayList(layout.TextSpan) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(@constCast(span.text));
        spans.deinit(allocator);
    }

    var seen_header = false;
    var previous_word: ?Row = null;
    var lines = std.mem.splitScalar(u8, tsv, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (!seen_header) {
            if (!std.mem.eql(u8, line, expected_header)) return error.InvalidTsvHeader;
            seen_header = true;
            continue;
        }

        const row = try parseRow(line);
        if (row.level != 5 or row.confidence < 0 or row.text.len == 0) continue;
        const bbox = try geometry.mapWordBBox(row.left, row.top, row.width, row.height);

        const text = try allocator.dupe(u8, row.text);
        errdefer allocator.free(text);

        try spans.append(allocator, layout.TextSpan.init(.{
            .page_index = input.page_index,
            .bbox = bbox,
            .text = text,
            .source = .fresh_ocr,
            .confidence = @max(0.0, @min(1.0, row.confidence / 100.0)),
            .font = .{
                .name = "tesseract",
                .encoding = "utf-8",
                .has_to_unicode = true,
            },
            .block_id = row.block_num,
            .line_id = row.line_num,
            .leading_boundary = if (previous_word) |previous|
                if (row.page_num != previous.page_num or row.block_num != previous.block_num)
                    .block_break
                else if (row.par_num != previous.par_num or row.line_num != previous.line_num)
                    .line_break
                else
                    .space
            else
                .region_break,
        }));
        previous_word = row;
    }

    if (!seen_header) return error.InvalidTsvHeader;
    return spans.toOwnedSlice(allocator);
}

const Row = struct {
    level: u8,
    page_num: u32,
    block_num: u32,
    par_num: u32,
    line_num: u32,
    word_num: u32,
    left: u32,
    top: u32,
    width: u32,
    height: u32,
    confidence: f32,
    text: []const u8,
};

fn parseRow(line: []const u8) !Row {
    var fields: [12][]const u8 = undefined;
    var rest = line;
    for (0..11) |field_index| {
        const tab_index = std.mem.indexOfScalar(u8, rest, '\t') orelse return error.InvalidTsvRow;
        fields[field_index] = rest[0..tab_index];
        rest = rest[tab_index + 1 ..];
    }
    fields[11] = rest;

    const confidence = std.fmt.parseFloat(f32, fields[10]) catch return error.InvalidConfidence;
    if (!std.math.isFinite(confidence)) return error.InvalidConfidence;
    return .{
        .level = try parseUnsigned(u8, fields[0]),
        .page_num = try parseUnsigned(u32, fields[1]),
        .block_num = try parseUnsigned(u32, fields[2]),
        .par_num = try parseUnsigned(u32, fields[3]),
        .line_num = try parseUnsigned(u32, fields[4]),
        .word_num = try parseUnsigned(u32, fields[5]),
        .left = try parseUnsigned(u32, fields[6]),
        .top = try parseUnsigned(u32, fields[7]),
        .width = try parseUnsigned(u32, fields[8]),
        .height = try parseUnsigned(u32, fields[9]),
        .confidence = confidence,
        .text = fields[11],
    };
}

fn parseUnsigned(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10) catch return error.InvalidCoordinate;
}

fn freeTestSpans(spans: []layout.TextSpan) void {
    for (spans) |span| std.testing.allocator.free(@constCast(span.text));
    std.testing.allocator.free(spans);
}

test "parse tesseract TSV words into fresh OCR spans" {
    const tsv =
        expected_header ++ "\n" ++
        "1\t1\t0\t0\t0\t0\t0\t0\t1000\t2000\t-1\t\n" ++
        "5\t1\t2\t1\t3\t1\t100\t200\t300\t40\t87.5\tHello\n" ++
        "5\t1\t2\t1\t3\t2\t450\t200\t200\t40\t93\tworld\n";

    const spans = try parse(std.testing.allocator, tsv, .{
        .page_index = 4,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 500, .y1 = 1000 },
        .pixel_width = 1000,
        .pixel_height = 2000,
    });
    defer freeTestSpans(spans);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(layout.SourceKind.fresh_ocr, spans[0].source);
    try std.testing.expectEqual(@as(u32, 4), spans[0].page_index);
    try std.testing.expectEqualStrings("Hello", spans[0].text);
    try std.testing.expectApproxEqAbs(@as(f32, 0.875), spans[0].confidence, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 50), spans[0].bbox.x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 880), spans[0].bbox.y0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 200), spans[0].bbox.x1, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 900), spans[0].bbox.y1, 0.001);
}

test "parse rejects TSV without standard header" {
    try std.testing.expectError(error.InvalidTsvHeader, parse(std.testing.allocator, "not-a-header\n", .{
        .page_index = 0,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .pixel_width = 10,
        .pixel_height = 10,
    }));
}

test "parse skips empty and rejected word rows" {
    const tsv =
        expected_header ++ "\n" ++
        "5\t1\t1\t1\t1\t1\t0\t0\t10\t10\t-1\tnoise\n" ++
        "5\t1\t1\t1\t1\t2\t0\t0\t10\t10\t80\t\n";

    const spans = try parse(std.testing.allocator, tsv, .{
        .page_index = 0,
        .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .pixel_width = 10,
        .pixel_height = 10,
    });
    defer freeTestSpans(spans);

    try std.testing.expectEqual(@as(usize, 0), spans.len);
}

fn mappingTestInput() ParseInput {
    return .{
        .page_index = 3,
        .pdf_bbox = .{ .x0 = 10, .y0 = 20, .x1 = 200, .y1 = 300 },
        .pixel_width = 100,
        .pixel_height = 100,
    };
}

test "TSV uses literal quarter turn and affine four corner pixel mapping" {
    const row = expected_header ++ "\n5\t1\t1\t1\t1\t1\t10\t20\t30\t5\t90\tword\n";
    const cases = [_]struct { matrix: page_geometry.Matrix, expected: layout.BBox }{
        .{ .matrix = .{ 0, -0.5, -0.5, 0, 200, 300 }, .expected = .{ .x0 = 187.5, .y0 = 280, .x1 = 190, .y1 = 295 } },
        .{ .matrix = .{ -0.5, 0, 0, 0.5, 200, 20 }, .expected = .{ .x0 = 180, .y0 = 30, .x1 = 195, .y1 = 32.5 } },
        .{ .matrix = .{ 0, 0.5, 0.5, 0, 10, 20 }, .expected = .{ .x0 = 20, .y0 = 25, .x1 = 22.5, .y1 = 40 } },
        // A shear with opposite edge extrema requires all four corners.
        .{ .matrix = .{ 1, 0.5, -1, 1, 10, 20 }, .expected = .{ .x0 = -5, .y0 = 45, .x1 = 30, .y1 = 65 } },
    };
    for (cases) |case| {
        var input = mappingTestInput();
        input.pixel_to_pdf = case.matrix;
        input.rasterizer_dpi = 144;
        const spans = try parse(std.testing.allocator, row, input);
        defer freeTestSpans(spans);
        try std.testing.expectEqual(@as(usize, 1), spans.len);
        try std.testing.expectEqualDeep(case.expected, spans[0].bbox);
        try std.testing.expectEqual(layout.TextBoundary.region_break, spans[0].leading_boundary.?);
    }
}

test "TSV boundaries follow selected word identities and isolate independent regions" {
    const tsv = expected_header ++ "\n" ++
        "5\t1\t8\t1\t1\t1\t0\t0\t10\t10\t-1\trejected\n" ++
        "5\t1\t8\t1\t1\t2\t0\t0\t10\t10\t90\t\n" ++
        "5\t1\t1\t1\t1\t1\t10\t20\t10\t5\t90\tA\n" ++
        "5\t1\t99\t1\t9\t1\t0\t0\t10\t10\t-1\tignored\n" ++
        "5\t1\t1\t1\t1\t2\t30\t20\t10\t5\t90\tB\n" ++
        "5\t1\t1\t1\t2\t1\t10\t40\t10\t5\t90\tC\n" ++
        "5\t1\t1\t2\t1\t1\t10\t60\t10\t5\t90\tD\n" ++
        "5\t1\t2\t1\t1\t1\t10\t80\t10\t5\t90\tE\n";
    var input = mappingTestInput();
    input.pixel_to_pdf = .{ 0, -0.5, -0.5, 0, 200, 300 };
    // Each OCR call begins a region even when its first selected IDs match
    // those of another crop. Skipped words never determine a boundary.
    for (0..2) |_| {
        const spans = try parse(std.testing.allocator, tsv, input);
        defer freeTestSpans(spans);
        try std.testing.expectEqual(@as(usize, 5), spans.len);
        for (spans, [_]layout.TextBoundary{ .region_break, .space, .line_break, .line_break, .block_break }) |span, expected| {
            try std.testing.expectEqual(expected, span.leading_boundary.?);
        }
    }
}

test "TSV refuses invalid image transform dpi and accepted word bounds" {
    const row = expected_header ++ "\n5\t1\t1\t1\t1\t1\t10\t20\t30\t5\t90\tword\n";
    var input = mappingTestInput();
    input.pixel_width = 0;
    try std.testing.expectError(error.EmptyImage, parse(std.testing.allocator, row, input));
    input = mappingTestInput();
    input.pixel_height = 0;
    try std.testing.expectError(error.EmptyImage, parse(std.testing.allocator, row, input));
    input = mappingTestInput();
    input.pdf_bbox.x0 = std.math.nan(f64);
    try std.testing.expectError(error.InvalidBox, parse(std.testing.allocator, row, input));
    input = mappingTestInput();
    input.pdf_bbox.x1 = input.pdf_bbox.x0;
    try std.testing.expectError(error.InvalidBox, parse(std.testing.allocator, row, input));
    input = mappingTestInput();
    for ([_]page_geometry.Matrix{ .{ std.math.nan(f64), 0, 0, 1, 0, 0 }, .{ 1, 0, 0, 1, std.math.inf(f64), 0 } }) |matrix| {
        input.pixel_to_pdf = matrix;
        try std.testing.expectError(error.InvalidMatrix, parse(std.testing.allocator, row, input));
    }
    input.pixel_to_pdf = .{ 0, 0, 0, 1, 0, 0 };
    try std.testing.expectError(error.SingularMatrix, parse(std.testing.allocator, row, input));
    input = mappingTestInput();
    for ([_]f64{ 0, -1, std.math.nan(f64), std.math.inf(f64) }) |dpi| {
        input.rasterizer_dpi = dpi;
        try std.testing.expectError(error.InvalidDpi, parse(std.testing.allocator, row, input));
    }
    input = mappingTestInput();
    for ([_][]const u8{
        "5\t1\t1\t1\t1\t1\t90\t20\t30\t5\t90\tword\n",
        "5\t1\t1\t1\t1\t1\t10\t99\t30\t5\t90\tword\n",
        "5\t1\t1\t1\t1\t1\t10\t20\t0\t5\t90\tword\n",
        "5\t1\t1\t1\t1\t1\t4294967295\t0\t4294967295\t5\t90\tword\n",
    }) |bad_row| {
        const data = try std.mem.concat(std.testing.allocator, u8, &.{ row, bad_row });
        defer std.testing.allocator.free(data);
        // A later malformed word must release the earlier accepted span.
        try std.testing.expectError(error.InvalidWordBounds, parse(std.testing.allocator, data, input));
    }
}

test "TSV rejects malformed selected identities and nonfinite confidence" {
    for ([_]struct { row: []const u8, failure: anyerror }{
        .{ .row = "5\t1\t1\tbad\t1\t1\t0\t0\t5\t5\t90\tword\n", .failure = error.InvalidCoordinate },
        .{ .row = "5\t1\t1\t1\t1\tbad\t0\t0\t5\t5\t90\tword\n", .failure = error.InvalidCoordinate },
        .{ .row = "5\t1\t1\t1\t1\t1\t-1\t0\t5\t5\t90\tword\n", .failure = error.InvalidCoordinate },
        .{ .row = "5\t1\t1\t1\t1\t1\t0\t0\t5\t5\tnan\tword\n", .failure = error.InvalidConfidence },
        .{ .row = "5\t1\t1\t1\t1\t1\t0\t0\t5\t5\tinf\tword\n", .failure = error.InvalidConfidence },
        .{ .row = "5\t1\t1\n", .failure = error.InvalidTsvRow },
    }) |case| {
        const data = try std.mem.concat(std.testing.allocator, u8, &.{ expected_header, "\n", case.row });
        defer std.testing.allocator.free(data);
        try std.testing.expectError(case.failure, parse(std.testing.allocator, data, mappingTestInput()));
    }
}
