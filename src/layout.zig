const std = @import("std");
const form_scope = @import("form_scope.zig");

pub const TextBoundary = enum { join, space, line_break, block_break, region_break };

pub const SourceKind = enum(u8) {
    native_pdf,
    embedded_ocr,
    fresh_ocr,
    table_model,
    formula_model,
    manual,
    poppler_text,
};

pub const BBox = struct {
    x0: f64 = 0,
    y0: f64 = 0,
    x1: f64 = 0,
    y1: f64 = 0,
};

/// Operator evidence, not a claim about final rendered pixel visibility.
pub const PaintEvidence = struct {
    rendering_mode: ?u8 = null,
    paint_state: enum { painting, non_painting, unknown } = .unknown,
    clip_state: enum { unclipped, inside, outside, partial, unknown } = .unknown,
    clip_bbox: ?BBox = null,

    pub fn forBBox(self: PaintEvidence, box: BBox) PaintEvidence {
        var value = self;
        if (self.clip_state == .unknown) return value;
        if (!std.math.isFinite(box.x0) or !std.math.isFinite(box.y0) or !std.math.isFinite(box.x1) or !std.math.isFinite(box.y1)) {
            value.clip_state = .unknown;
            value.clip_bbox = null;
            return value;
        }
        if (self.clip_bbox) |clip| {
            value.clip_state = if (clip.x0 >= clip.x1 or clip.y0 >= clip.y1 or box.x1 <= clip.x0 or box.x0 >= clip.x1 or box.y1 <= clip.y0 or box.y0 >= clip.y1)
                .outside
            else if (box.x0 >= clip.x0 and box.x1 <= clip.x1 and box.y0 >= clip.y0 and box.y1 <= clip.y1)
                .inside
            else
                .partial;
        }
        return value;
    }
};

pub const FontMetadata = struct {
    name: ?[]const u8 = null,
    size: f64 = 0,
    encoding: ?[]const u8 = null,
    has_to_unicode: ?bool = null,
};

pub const LineRole = enum(u8) {
    body,
    heading,
    list_item,
    header,
    footer,
    caption,
    table_candidate,
    formula_candidate,
    figure_candidate,
};

pub const BlockKind = enum(u8) {
    paragraph,
    heading,
    list_item,
    header,
    footer,
    caption,
    table_candidate,
    formula_candidate,
    figure_candidate,
};

pub const CandidateKind = enum(u8) {
    table,
    formula,
    figure,
};

pub const RulingOrientation = enum {
    horizontal,
    vertical,
};

pub const RulingLine = struct {
    bbox: BBox,
    orientation: RulingOrientation,
    stroke_width: f64 = 1,
};

/// Geometry belongs to a source glyph or semantic replacement group, never
/// an invented character subdivision. Ranges refer to exact span UTF-8 bytes.
pub const GlyphGeometry = struct {
    text_start_byte: usize,
    text_end_byte: usize,
    bbox: BBox,
    quad: ?[4][2]f64 = null,
    precision: enum { glyph, replacement_group } = .glyph,
};

pub const TextSpan = struct {
    page_index: u32 = 0,
    bbox: BBox = .{},
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    text: []const u8,
    source: SourceKind = .native_pdf,
    confidence: f32 = 1.0,
    font: FontMetadata = .{},
    font_size: f64,
    // Private glyph-normal scale in page points. Original PDF font metadata
    // remains unchanged; only the preferred table view consumes this estimate.
    layout_font_size: ?f64 = null,
    page: u32 = 0,
    block_id: ?u32 = null,
    line_id: ?u32 = null,
    mcid: ?i32 = null,
    unicode_map_error: bool = false,
    actual_text: bool = false,
    writing_mode: u8 = 0,
    paint: PaintEvidence = .{},
    content_scope: ?form_scope.Scope = null,
    leading_boundary: ?TextBoundary = null,
    // Internal ownership for reconstructed cells; geometry alone cannot
    // distinguish a shared-rule center from its blank neighboring slot.
    table_cell_owner: ?TableCellOwner = null,
    // Original input ordinal, assigned before layout sorting. Never public IDs.
    native_source_index: ?u32 = null,
    // Controlled aggregate projections have identity without pretending to
    // be one native leaf. Untracked cross-layer evidence may still deduplicate.
    preserve_source_identity: bool = false,
    glyph_geometry: []const GlyphGeometry = &.{},

    pub fn init(args: struct {
        page_index: u32 = 0,
        bbox: BBox,
        text: []const u8,
        source: SourceKind = .native_pdf,
        confidence: f32 = 1.0,
        font: FontMetadata = .{},
        layout_font_size: ?f64 = null,
        block_id: ?u32 = null,
        line_id: ?u32 = null,
        mcid: ?i32 = null,
        unicode_map_error: bool = false,
        actual_text: bool = false,
        writing_mode: u8 = 0,
        paint: PaintEvidence = .{},
        content_scope: ?form_scope.Scope = null,
        leading_boundary: ?TextBoundary = null,
        preserve_source_identity: bool = false,
        glyph_geometry: []const GlyphGeometry = &.{},
    }) TextSpan {
        var font = args.font;
        const font_size = if (font.size != 0) font.size else args.bbox.y1 - args.bbox.y0;
        font.size = font_size;
        return .{
            .page_index = args.page_index,
            .bbox = args.bbox,
            .x0 = args.bbox.x0,
            .y0 = args.bbox.y0,
            .x1 = args.bbox.x1,
            .y1 = args.bbox.y1,
            .text = args.text,
            .source = args.source,
            .confidence = args.confidence,
            .font = font,
            .font_size = font_size,
            .layout_font_size = args.layout_font_size,
            .page = args.page_index,
            .block_id = args.block_id,
            .line_id = args.line_id,
            .mcid = args.mcid,
            .unicode_map_error = args.unicode_map_error,
            .actual_text = args.actual_text,
            .writing_mode = args.writing_mode,
            .paint = args.paint,
            .content_scope = args.content_scope,
            .leading_boundary = args.leading_boundary,
            .preserve_source_identity = args.preserve_source_identity,
            .glyph_geometry = args.glyph_geometry,
        };
    }
};

pub const TableCellOwner = struct {
    region_index: u32,
    row_index: u32,
    column_index: u32,
};

pub const TextWord = struct {
    bounds: TextSpan,
    spans: []const TextSpan,
};

pub const TextLine = struct {
    bounds: TextSpan,
    words: []const TextWord,
    baseline_y: f64,
    role: LineRole = .body,
};

pub const TextColumn = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    index: u32,
};

pub const TextParagraph = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    column_index: u32,
    first_line_indent: f64,
    kind: BlockKind = .paragraph,
};

pub const LayoutBlock = struct {
    bounds: TextSpan,
    lines: []const TextLine,
    column_index: u32,
    kind: BlockKind,
    confidence: f32 = 0.5,
    removed: bool = false,
};

pub const TableCell = struct {
    bounds: TextSpan,
    text: []const u8,
    row_index: u32,
    column_index: u32,
    rowspan: u32 = 1,
    colspan: u32 = 1,
    role: TableCellRole = .data,
    confidence: f32 = 0.70,
};

pub const TableCellRole = enum(u8) {
    data,
    header,
    row_header,
    note,
    footer,
};

pub const TableRow = struct {
    bounds: TextSpan,
    cells: []TableCell,
    row_index: u32,
};

pub const TableGrid = struct {
    bounds: TextSpan,
    block_index: u32,
    block_count: usize = 1,
    rows: []TableRow,
    column_count: usize,
    page_index: u32 = 0,
    confidence: f32 = 0.72,
    logical_table_index: ?u32 = null,
    table_part_index: u32 = 0,
    continued_from_table_index: ?u32 = null,
    continued_to_table_index: ?u32 = null,
    region_index: u32 = 0,
    source_span_indices: []const u32 = &.{},
    member_block_indices: []const u32 = &.{},
    ruled_region: bool = false,
    projection_eligible: bool = false,
};

pub const LayoutCandidate = struct {
    kind: CandidateKind,
    bounds: TextSpan,
    line_index: u32,
    block_index: ?u32 = null,
    caption_line_index: ?u32 = null,
    caption_block_index: ?u32 = null,
    confidence: f32,
};

pub const LayoutResult = struct {
    spans: []const TextSpan,
    lines: []const TextLine,
    columns: []const TextColumn,
    paragraphs: []const TextParagraph,
    blocks: []const LayoutBlock,
    tables: []const TableGrid,
    candidates: []const LayoutCandidate,
    reading_order: []const u32,
    body_font_size: f64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LayoutResult) void {
        self.allocator.free(self.spans);
        freeTextLines(self.allocator, self.lines);
        self.allocator.free(self.lines);
        freeTextColumns(self.allocator, self.columns);
        self.allocator.free(self.columns);
        freeTextParagraphs(self.allocator, self.paragraphs);
        self.allocator.free(self.paragraphs);
        freeLayoutBlocks(self.allocator, self.blocks);
        self.allocator.free(self.blocks);
        freeTableGrids(self.allocator, self.tables);
        self.allocator.free(self.tables);
        self.allocator.free(self.candidates);
        self.allocator.free(self.reading_order);
    }

    /// Get text in reading order
    /// Uses the sorted spans directly (sorted by Y desc, then X asc)
    pub fn getTextInOrder(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        if (self.spans.len == 0) return try allocator.alloc(u8, 0);

        const line_threshold: f64 = 10;

        // Pre-calculate total size needed (worst case: space between every span + newlines)
        var total_len: usize = 0;
        var separator_count: usize = 0;
        var prev_y: f64 = self.spans[0].y0;
        var prev_x1: f64 = self.spans[0].x0;
        var prev_font_size: f64 = self.spans[0].font_size;

        for (self.spans, 0..) |span, i| {
            if (i > 0) {
                if (@abs(span.y0 - prev_y) > line_threshold) {
                    separator_count += 1; // newline
                    prev_y = span.y0;
                } else {
                    // Detect word gaps using font-relative threshold
                    // Typical space width is ~25-33% of em, kerning is <10%
                    const space_width = prev_font_size * 0.15; // 15% of font size
                    const gap = span.x0 - prev_x1;
                    if (gap > space_width) {
                        separator_count += 1; // space
                    }
                }
            }
            total_len += span.text.len;
            prev_x1 = span.x1;
            prev_font_size = span.font_size;
        }

        // Allocate exact size needed
        const result = try allocator.alloc(u8, total_len + separator_count);
        var pos: usize = 0;
        prev_y = self.spans[0].y0;
        prev_x1 = self.spans[0].x0;
        prev_font_size = self.spans[0].font_size;

        for (self.spans, 0..) |span, i| {
            if (i > 0) {
                if (@abs(span.y0 - prev_y) > line_threshold) {
                    result[pos] = '\n';
                    pos += 1;
                    prev_y = span.y0;
                } else {
                    const space_width = prev_font_size * 0.15;
                    const gap = span.x0 - prev_x1;
                    if (gap > space_width) {
                        result[pos] = ' ';
                        pos += 1;
                    }
                }
            }
            @memcpy(result[pos..][0..span.text.len], span.text);
            pos += span.text.len;
            prev_x1 = span.x1;
            prev_font_size = span.font_size;
        }

        return result[0..pos];
    }

    /// Render reconstructed block text, skipping page-furniture candidates and
    /// joining soft hyphenated line breaks inside body paragraphs.
    pub fn getReconstructedText(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        return self.getReconstructedTextOptions(allocator, false);
    }

    /// Render a completeness-preserving candidate for extraction selection.
    /// The caller's inventory oracle decides whether reordered text is safe, so
    /// headers and footers must remain available to that comparison.
    pub fn getCompleteReconstructedText(self: *const LayoutResult, allocator: std.mem.Allocator) ![]u8 {
        return self.getReconstructedTextOptions(allocator, true);
    }

    fn getReconstructedTextOptions(self: *const LayoutResult, allocator: std.mem.Allocator, include_removed: bool) ![]u8 {
        if (self.blocks.len == 0) return self.getTextInOrder(allocator);
        if (self.hasOwnedTables()) return self.getRegionText(allocator, false, include_removed);

        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        var emitted_block = false;
        for (self.blocks, 0..) |block, block_index| {
            if (block.removed and !include_removed) continue;
            if (block.lines.len == 0) continue;

            if (emitted_block and output.items.len > 0 and output.items[output.items.len - 1] != '\n') {
                try output.append(allocator, '\n');
            }
            if (emitted_block) {
                try output.append(allocator, '\n');
            }

            if (self.tableForBlock(block_index)) |table| {
                try appendTablePlain(allocator, &output, table);
                emitted_block = true;
                continue;
            }
            if (self.blockCoveredByTable(block_index)) continue;

            for (block.lines, 0..) |line, line_index| {
                if (line_index > 0) {
                    if (endsWithSoftHyphen(output.items) and lineStartsLowercase(&line)) {
                        _ = output.pop();
                    } else if (block.kind == .paragraph) {
                        try output.append(allocator, ' ');
                    } else {
                        try output.append(allocator, '\n');
                    }
                }
                try appendLineText(allocator, &output, &line);
            }

            emitted_block = true;
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn tableForBlock(self: *const LayoutResult, block_index: usize) ?*const TableGrid {
        for (self.tables) |*table| {
            if (table.block_index == block_index) return table;
        }
        return null;
    }

    pub fn hasOwnedTables(self: *const LayoutResult) bool {
        for (self.tables) |table| if (table.projection_eligible) return true;
        return false;
    }

    pub fn tableRegionForSpan(self: *const LayoutResult, span: TextSpan) ?usize {
        const source_index = span.native_source_index orelse return null;
        for (self.tables, 0..) |table, index| {
            if (table.page_index == span.page_index and table.projection_eligible and containsSourceIndex(table.source_span_indices, source_index)) return index;
        }
        return null;
    }

    pub fn getRegionText(self: *const LayoutResult, allocator: std.mem.Allocator, markdown: bool, include_removed: bool) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        const emitted = try allocator.alloc(bool, self.tables.len);
        defer allocator.free(emitted);
        @memset(emitted, false);
        for (self.blocks) |block| {
            if (block.removed and !include_removed) continue;
            var has_members = false;
            for (block.lines) |line| for (line.words) |word| for (word.spans) |span| {
                if (self.tableRegionForSpan(span) != null) has_members = true;
            };
            if (!has_members) {
                if (block.lines.len == 0) continue;
                if (output.items.len > 0) {
                    if (output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
                    try output.append(allocator, '\n');
                }
                if (markdown and block.kind == .heading) try output.appendSlice(allocator, "## ");
                if (markdown and block.kind == .list_item) try output.appendSlice(allocator, "- ");
                for (block.lines, 0..) |line, index| {
                    if (index > 0) {
                        if (!markdown and endsWithSoftHyphen(output.items) and lineStartsLowercase(&line)) {
                            _ = output.pop();
                        } else try output.append(allocator, if (block.kind == .paragraph) ' ' else '\n');
                    }
                    try appendLineText(allocator, &output, &line);
                }
                if (markdown) try output.append(allocator, '\n');
                continue;
            }
            var previous_residual = false;
            for (block.lines) |line| {
                var owned_line = false;
                for (line.words) |word| for (word.spans) |span| {
                    const table_index = self.tableRegionForSpan(span) orelse continue;
                    owned_line = true;
                    if (emitted[table_index]) continue;
                    if (output.items.len > 0) {
                        if (output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
                        try output.append(allocator, '\n');
                    }
                    if (markdown) try appendTableMarkdown(allocator, &output, &self.tables[table_index]) else try appendTablePlain(allocator, &output, &self.tables[table_index]);
                    emitted[table_index] = true;
                    previous_residual = false;
                };
                var wrote = false;
                for (line.words) |word| {
                    var wrote_word = false;
                    for (word.spans) |span| {
                        if (self.tableRegionForSpan(span) != null) continue;
                        if (std.mem.trim(u8, span.text, " \t\r\n").len == 0) continue;
                        if (!wrote) {
                            if (previous_residual and !owned_line) {
                                if (!markdown and block.kind == .paragraph and endsWithSoftHyphen(output.items) and lineStartsLowercase(&line)) {
                                    _ = output.pop();
                                } else try output.append(allocator, if (block.kind == .paragraph) ' ' else '\n');
                            } else {
                                if (output.items.len > 0) {
                                    if (output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
                                    try output.append(allocator, '\n');
                                }
                                if (markdown and block.kind == .heading) try output.appendSlice(allocator, "## ");
                                if (markdown and block.kind == .list_item) try output.appendSlice(allocator, "- ");
                            }
                        } else if (!wrote_word) try output.append(allocator, ' ');
                        try output.appendSlice(allocator, span.text);
                        wrote = true;
                        wrote_word = true;
                    }
                }
                previous_residual = wrote;
            }
        }
        if (markdown and output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(allocator, '\n');
        return output.toOwnedSlice(allocator);
    }

    pub fn blockCoveredByTable(self: *const LayoutResult, block_index: usize) bool {
        for (self.tables) |table| {
            const start: usize = @intCast(table.block_index);
            if (block_index >= start and block_index < start + table.block_count) return true;
        }
        return false;
    }

    pub fn writeTablesJson(self: *const LayoutResult, writer: anytype) !void {
        try writer.writeByte('[');
        for (self.tables, 0..) |table, table_index| {
            if (table_index > 0) try writer.writeByte(',');
            const logical_index = table.logical_table_index orelse @as(u32, @intCast(table_index));
            try writer.print(
                "{{\"table_id\":\"table-{d}\",\"logical_table_id\":\"logical-table-{d}\",\"table_index\":{},\"table_part_index\":{},\"continued_from_table_id\":",
                .{ table_index, logical_index, table_index, table.table_part_index },
            );
            try writeOptionalTableId(writer, table.continued_from_table_index);
            try writer.writeAll(",\"continued_to_table_id\":");
            try writeOptionalTableId(writer, table.continued_to_table_index);
            try writer.print(
                ",\"page_index\":{},\"block_index\":{},\"block_count\":{},\"column_count\":{},\"confidence\":{d:.3},\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"source_span_ids\":[],\"rows\":[",
                .{ table.page_index, table.block_index, table.block_count, table.column_count, table.confidence, table.bounds.x0, table.bounds.y0, table.bounds.x1, table.bounds.y1 },
            );
            for (table.rows, 0..) |row, row_index| {
                if (row_index > 0) try writer.writeByte(',');
                try writer.writeByte('[');
                var wrote_cell = false;
                for (row.cells) |cell| {
                    if (cell.text.len == 0) continue;
                    if (wrote_cell) try writer.writeByte(',');
                    wrote_cell = true;
                    try writer.writeByte('{');
                    try writer.print(
                        "\"cell_id\":\"table-{d}-cell-{d}-{d}\",\"page\":{},\"page_index\":{},\"row\":{},\"column\":{},\"rowspan\":{},\"colspan\":{},\"role\":\"",
                        .{ table_index, cell.row_index, cell.column_index, cell.bounds.page_index, cell.bounds.page_index, cell.row_index, cell.column_index, cell.rowspan, cell.colspan },
                    );
                    try writer.writeAll(tableCellRoleName(cell.role));
                    try writer.writeAll("\",\"text\":\"");
                    try writeJsonEscaped(writer, cell.text);
                    try writer.writeAll("\",\"raw_text\":\"");
                    try writeJsonEscaped(writer, cell.text);
                    try writer.writeAll("\",\"normalized_text\":\"");
                    try writeNormalizedJsonEscaped(writer, cell.text);
                    try writer.writeAll("\",\"numeric\":");
                    try writeNumericHint(writer, cell.text);
                    try writer.print(
                        ",\"bbox\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"source_span_ids\":[]",
                        .{ cell.bounds.x0, cell.bounds.y0, cell.bounds.x1, cell.bounds.y1 },
                    );
                    try writer.writeByte('}');
                }
                try writer.writeByte(']');
            }
            try writer.writeAll("]}");
        }
        try writer.writeByte(']');
    }
};

fn freeTextLine(allocator: std.mem.Allocator, line: TextLine) void {
    for (line.words) |word| allocator.free(word.spans);
    allocator.free(line.words);
}

fn freeTextLines(allocator: std.mem.Allocator, lines: []const TextLine) void {
    for (lines) |line| freeTextLine(allocator, line);
}

fn freeTextColumns(allocator: std.mem.Allocator, columns: []const TextColumn) void {
    for (columns) |column| allocator.free(column.lines);
}

fn freeTextParagraphs(allocator: std.mem.Allocator, paragraphs: []const TextParagraph) void {
    for (paragraphs) |paragraph| allocator.free(paragraph.lines);
}

fn freeLayoutBlocks(allocator: std.mem.Allocator, blocks: []const LayoutBlock) void {
    for (blocks) |block| allocator.free(block.lines);
}

fn tableCellRoleName(role: TableCellRole) []const u8 {
    return switch (role) {
        .data => "data",
        .header => "header",
        .row_header => "row_header",
        .note => "note",
        .footer => "footer",
    };
}

/// Simple geometric sort: Y (top to bottom), then X (left to right)
/// Matches PyMuPDF's sort=True behavior
pub fn sortGeometric(allocator: std.mem.Allocator, spans: []const TextSpan) ![]u8 {
    if (spans.len == 0) return try allocator.alloc(u8, 0);

    // Sort by Y descending (top to bottom in PDF coords), then X ascending
    const sorted = try allocator.alloc(TextSpan, spans.len);
    defer allocator.free(sorted);
    @memcpy(sorted, spans);
    const line_threshold: f64 = 3; // Tight threshold to match PyMuPDF

    std.mem.sort(TextSpan, sorted, line_threshold, struct {
        fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
            // Group into rows by Y coordinate
            const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
            const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
            if (a_row != b_row) return a_row > b_row; // Higher Y first (top of page)
            return a.x0 < b.x0; // Left to right within row
        }
    }.cmp);

    // Build output text
    var total_len: usize = 0;
    var separator_count: usize = 0;
    var prev_y: f64 = sorted[0].y0;
    var prev_x1: f64 = sorted[0].x0;
    var prev_font_size: f64 = sorted[0].font_size;

    for (sorted, 0..) |span, i| {
        if (i > 0) {
            if (@abs(span.y0 - prev_y) > line_threshold) {
                separator_count += 1; // newline
                prev_y = span.y0;
            } else {
                const space_width = prev_font_size * 0.2;
                const gap = span.x0 - prev_x1;
                if (gap > space_width) {
                    separator_count += 1; // space
                }
            }
        }
        total_len += span.text.len;
        prev_x1 = span.x1;
        prev_font_size = span.font_size;
    }

    const result = try allocator.alloc(u8, total_len + separator_count);
    var pos: usize = 0;
    prev_y = sorted[0].y0;
    prev_x1 = sorted[0].x0;
    prev_font_size = sorted[0].font_size;

    for (sorted, 0..) |span, i| {
        if (i > 0) {
            if (@abs(span.y0 - prev_y) > line_threshold) {
                result[pos] = '\n';
                pos += 1;
                prev_y = span.y0;
            } else {
                const space_width = prev_font_size * 0.2;
                const gap = span.x0 - prev_x1;
                if (gap > space_width) {
                    result[pos] = ' ';
                    pos += 1;
                }
            }
        }
        @memcpy(result[pos..][0..span.text.len], span.text);
        pos += span.text.len;
        prev_x1 = span.x1;
        prev_font_size = span.font_size;
    }

    return result[0..pos];
}

pub fn analyzeLayout(allocator: std.mem.Allocator, spans: []const TextSpan, page_width: f64) !LayoutResult {
    return analyzeLayoutWithRulings(allocator, spans, page_width, &.{});
}

pub fn analyzeLayoutWithRulings(
    allocator: std.mem.Allocator,
    spans: []const TextSpan,
    page_width: f64,
    ruling_lines: []const RulingLine,
) !LayoutResult {
    if (spans.len == 0) return emptyLayoutResult(allocator);

    const line_threshold: f64 = 10;

    // Sort all spans by Y (top to bottom), then X (left to right)
    const sorted = try allocator.alloc(TextSpan, spans.len);
    defer allocator.free(sorted);
    @memcpy(sorted, spans);
    for (sorted, 0..) |*span, index| span.native_source_index = std.math.cast(u32, index) orelse return error.TooManySourceSpans;

    std.mem.sort(TextSpan, sorted, line_threshold, struct {
        fn cmp(threshold: f64, a: TextSpan, b: TextSpan) bool {
            const a_row = @as(i64, @intFromFloat(a.y0 / threshold));
            const b_row = @as(i64, @intFromFloat(b.y0 / threshold));
            if (a_row != b_row) return a_row > b_row;
            return a.x0 < b.x0;
        }
    }.cmp);

    // Count visual line bands, then use whitespace occupancy to locate a real
    // gutter. A page midpoint is not evidence of a column boundary.
    var total_lines: usize = 1;
    var current_y: f64 = sorted[0].y0;
    for (sorted) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            total_lines += 1;
            current_y = span.y0;
        }
    }

    const table_like_rows = countTableLikeRowsInSpans(sorted, line_threshold);
    const table_heavy_page = table_like_rows >= 2 and table_like_rows * 2 >= total_lines;
    const gutter = if (table_heavy_page) null else detectSpanGutter(sorted, page_width, line_threshold);
    const is_two_column = gutter != null;

    var result_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len);
    errdefer result_spans.deinit(allocator);

    if (is_two_column) {
        // Two-column layout: output left column first, then right column
        var left_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer left_spans.deinit(allocator);
        var right_spans = try std.ArrayList(TextSpan).initCapacity(allocator, spans.len / 2);
        defer right_spans.deinit(allocator);

        for (sorted) |span| {
            if (spanRegion(span, gutter.?) == 1) {
                try right_spans.append(allocator, span);
            } else {
                try left_spans.append(allocator, span);
            }
        }

        // Output: left column first, then right column
        for (left_spans.items) |span| {
            try result_spans.append(allocator, span);
        }
        for (right_spans.items) |span| {
            try result_spans.append(allocator, span);
        }
    } else {
        // Single column: just use sorted order
        for (sorted) |span| {
            try result_spans.append(allocator, span);
        }
    }

    // Build lines from the ordered spans
    var lines = try std.ArrayList(TextLine).initCapacity(allocator, spans.len / 10);
    errdefer {
        freeTextLines(allocator, lines.items);
        lines.deinit(allocator);
    }
    var current_line_spans = try std.ArrayList(TextSpan).initCapacity(allocator, 20);
    defer current_line_spans.deinit(allocator);
    current_y = if (result_spans.items.len > 0) result_spans.items[0].y0 else 0;

    for (result_spans.items) |span| {
        if (@abs(span.y0 - current_y) > line_threshold) {
            if (current_line_spans.items.len > 0) {
                const line = try makeLine(allocator, current_line_spans.items);
                errdefer freeTextLine(allocator, line);
                try lines.append(allocator, line);
                current_line_spans.clearRetainingCapacity();
            }
            current_y = span.y0;
        }
        try current_line_spans.append(allocator, span);
    }
    if (current_line_spans.items.len > 0) {
        const line = try makeLine(allocator, current_line_spans.items);
        errdefer freeTextLine(allocator, line);
        try lines.append(allocator, line);
    }

    const body_font_size = try estimateBodyFontSize(allocator, result_spans.items);
    classifyLines(lines.items, body_font_size);

    // Build column structure
    var columns = try std.ArrayList(TextColumn).initCapacity(allocator, 1);
    errdefer {
        freeTextColumns(allocator, columns.items);
        columns.deinit(allocator);
    }
    if (lines.items.len > 0) {
        if (is_two_column) {
            var left_lines: std.ArrayList(TextLine) = .empty;
            errdefer left_lines.deinit(allocator);
            var right_lines: std.ArrayList(TextLine) = .empty;
            errdefer right_lines.deinit(allocator);

            for (lines.items) |line| {
                if (spanRegion(line.bounds, gutter.?) == 1) {
                    try right_lines.append(allocator, line);
                } else {
                    try left_lines.append(allocator, line);
                }
            }

            if (left_lines.items.len > 0) {
                const col_lines = try left_lines.toOwnedSlice(allocator);
                errdefer allocator.free(col_lines);
                try columns.append(allocator, .{
                    .bounds = mergeBounds(col_lines),
                    .lines = col_lines,
                    .index = 0,
                });
            }
            if (right_lines.items.len > 0) {
                const col_lines = try right_lines.toOwnedSlice(allocator);
                errdefer allocator.free(col_lines);
                try columns.append(allocator, .{
                    .bounds = mergeBounds(col_lines),
                    .lines = col_lines,
                    .index = 1,
                });
            }
        } else {
            const all_lines = try allocator.dupe(TextLine, lines.items);
            errdefer allocator.free(all_lines);
            try columns.append(allocator, .{
                .bounds = mergeBounds(all_lines),
                .lines = all_lines,
                .index = 0,
            });
        }
    }

    const order = try allocator.alloc(u32, columns.items.len);
    errdefer allocator.free(order);
    for (order, 0..) |*o, i| {
        o.* = @intCast(i);
    }

    // Detect paragraphs
    var paragraphs = try std.ArrayList(TextParagraph).initCapacity(allocator, columns.items.len * 3);
    errdefer {
        freeTextParagraphs(allocator, paragraphs.items);
        paragraphs.deinit(allocator);
    }
    for (columns.items, 0..) |col, col_idx| {
        try detectParagraphs(allocator, col.lines, @intCast(col_idx), &paragraphs);
    }

    var blocks: std.ArrayList(LayoutBlock) = .empty;
    errdefer {
        for (blocks.items) |block| allocator.free(block.lines);
        blocks.deinit(allocator);
    }
    try buildBlocks(allocator, paragraphs.items, &blocks);

    const tables = try buildTableGridsWithRulings(allocator, blocks.items, result_spans.items, ruling_lines);
    errdefer {
        freeTableGrids(allocator, tables);
        allocator.free(tables);
    }

    var candidates: std.ArrayList(LayoutCandidate) = .empty;
    errdefer candidates.deinit(allocator);
    try collectCandidates(allocator, lines.items, blocks.items, &candidates);

    const final_spans = try result_spans.toOwnedSlice(allocator);
    errdefer allocator.free(final_spans);
    const final_lines = try lines.toOwnedSlice(allocator);
    errdefer {
        freeTextLines(allocator, final_lines);
        allocator.free(final_lines);
    }
    const final_columns = try columns.toOwnedSlice(allocator);
    errdefer {
        freeTextColumns(allocator, final_columns);
        allocator.free(final_columns);
    }
    const final_paragraphs = try paragraphs.toOwnedSlice(allocator);
    errdefer {
        freeTextParagraphs(allocator, final_paragraphs);
        allocator.free(final_paragraphs);
    }
    const final_blocks = try blocks.toOwnedSlice(allocator);
    errdefer {
        freeLayoutBlocks(allocator, final_blocks);
        allocator.free(final_blocks);
    }
    const final_candidates = try candidates.toOwnedSlice(allocator);
    errdefer allocator.free(final_candidates);

    return LayoutResult{
        .spans = final_spans,
        .lines = final_lines,
        .columns = final_columns,
        .paragraphs = final_paragraphs,
        .blocks = final_blocks,
        .tables = tables,
        .candidates = final_candidates,
        .reading_order = order,
        .body_font_size = body_font_size,
        .allocator = allocator,
    };
}

fn emptyLayoutResult(allocator: std.mem.Allocator) !LayoutResult {
    const spans = try allocator.alloc(TextSpan, 0);
    errdefer allocator.free(spans);
    const lines = try allocator.alloc(TextLine, 0);
    errdefer allocator.free(lines);
    const columns = try allocator.alloc(TextColumn, 0);
    errdefer allocator.free(columns);
    const paragraphs = try allocator.alloc(TextParagraph, 0);
    errdefer allocator.free(paragraphs);
    const blocks = try allocator.alloc(LayoutBlock, 0);
    errdefer allocator.free(blocks);
    const tables = try allocator.alloc(TableGrid, 0);
    errdefer allocator.free(tables);
    const candidates = try allocator.alloc(LayoutCandidate, 0);
    errdefer allocator.free(candidates);
    const reading_order = try allocator.alloc(u32, 0);

    return .{
        .spans = spans,
        .lines = lines,
        .columns = columns,
        .paragraphs = paragraphs,
        .blocks = blocks,
        .tables = tables,
        .candidates = candidates,
        .reading_order = reading_order,
        .body_font_size = 0,
        .allocator = allocator,
    };
}

fn countTableLikeRowsInSpans(sorted: []const TextSpan, line_threshold: f64) usize {
    if (sorted.len == 0) return 0;
    var count: usize = 0;
    var row_start: usize = 0;
    var current_y = sorted[0].y0;
    for (sorted, 0..) |span, index| {
        if (@abs(span.y0 - current_y) <= line_threshold) continue;
        if (spanRowLooksLikeTable(sorted[row_start..index])) count += 1;
        row_start = index;
        current_y = span.y0;
    }
    if (spanRowLooksLikeTable(sorted[row_start..])) count += 1;
    return count;
}

const SpanGutter = struct { x0: f64, x1: f64 };

fn detectSpanGutter(spans: []const TextSpan, page_width: f64, line_threshold: f64) ?SpanGutter {
    if (spans.len < 4 or page_width <= 0) return null;
    const bin_count = 64;
    var occupancy: [bin_count]u32 = @splat(0);
    for (spans) |span| {
        const x0 = @max(0, @min(page_width, span.x0));
        const x1 = @max(0, @min(page_width, span.x1));
        const first: usize = @min(bin_count - 1, @as(usize, @intFromFloat(@floor(x0 / page_width * bin_count))));
        const last: usize = @min(bin_count - 1, @as(usize, @intFromFloat(@floor(x1 / page_width * bin_count))));
        var bin = first;
        while (bin <= last) : (bin += 1) occupancy[bin] += 1;
    }

    const search_start = bin_count / 4;
    const search_end = bin_count * 3 / 4;
    var best_start: usize = 0;
    var best_len: usize = 0;
    var run_start: ?usize = null;
    for (search_start..search_end) |bin| {
        if (occupancy[bin] == 0) {
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
    if (best_len == 0) return null;
    const gutter = SpanGutter{
        .x0 = @as(f64, @floatFromInt(best_start)) / bin_count * page_width,
        .x1 = @as(f64, @floatFromInt(best_start + best_len)) / bin_count * page_width,
    };
    if (gutter.x1 - gutter.x0 < @max(12.0, page_width * 0.025)) return null;

    var left_count: usize = 0;
    var right_count: usize = 0;
    var left_bands: [32]f64 = undefined;
    var right_bands: [32]f64 = undefined;
    var left_band_count: usize = 0;
    var right_band_count: usize = 0;
    for (spans) |span| switch (spanRegion(span, gutter)) {
        0 => {
            left_count += 1;
            appendBaselineBand(&left_bands, &left_band_count, span.y0, line_threshold);
        },
        1 => {
            right_count += 1;
            appendBaselineBand(&right_bands, &right_band_count, span.y0, line_threshold);
        },
        else => {},
    };
    if (left_count < 2 or right_count < 2 or left_band_count < 2 or right_band_count < 2) return null;
    return gutter;
}

fn appendBaselineBand(bands: *[32]f64, count: *usize, baseline: f64, tolerance: f64) void {
    for (bands[0..count.*]) |existing| if (@abs(existing - baseline) <= tolerance) return;
    if (count.* == bands.len) return;
    bands[count.*] = baseline;
    count.* += 1;
}

fn spanRegion(span: TextSpan, gutter: SpanGutter) u32 {
    if (span.x1 <= gutter.x0) return 0;
    if (span.x0 >= gutter.x1) return 1;
    return 2;
}

fn spanRowLooksLikeTable(row: []const TextSpan) bool {
    if (row.len < 3) return false;
    var numeric_spans: usize = 0;
    var wide_gaps: usize = 0;
    var prev_x1 = row[0].x1;
    const font_size = @max(1.0, row[0].font_size);

    for (row, 0..) |span, index| {
        if (spanHasDigit(span)) numeric_spans += 1;
        if (index > 0) {
            const gap = span.x0 - prev_x1;
            if (gap > font_size * 1.8) wide_gaps += 1;
        }
        prev_x1 = span.x1;
    }

    return wide_gaps >= 2 or numeric_spans * 2 >= row.len;
}

fn spanHasDigit(span: TextSpan) bool {
    for (span.text) |byte| {
        if (std.ascii.isDigit(byte)) return true;
    }
    return false;
}

/// Detect paragraphs by analyzing line spacing and indentation
fn detectParagraphs(allocator: std.mem.Allocator, col_lines: []const TextLine, col_idx: u32, paragraphs: *std.ArrayList(TextParagraph)) !void {
    if (col_lines.len == 0) return;

    var para_lines = try std.ArrayList(TextLine).initCapacity(allocator, @min(col_lines.len, 20));
    defer para_lines.deinit(allocator);

    var avg_line_spacing: f64 = 0;
    var avg_left_margin: f64 = 0;

    // Calculate average spacing and margins
    if (col_lines.len > 1) {
        var total_spacing: f64 = 0;
        var total_margin: f64 = 0;
        for (col_lines, 0..) |line, i| {
            total_margin += line.bounds.x0;
            if (i > 0) {
                total_spacing += col_lines[i - 1].bounds.y0 - line.bounds.y0;
            }
        }
        avg_line_spacing = total_spacing / @as(f64, @floatFromInt(col_lines.len - 1));
        avg_left_margin = total_margin / @as(f64, @floatFromInt(col_lines.len));
    }

    const para_gap_threshold = avg_line_spacing * 1.5;
    const indent_threshold: f64 = 15;

    for (col_lines, 0..) |line, i| {
        const is_para_break = blk: {
            if (i == 0) break :blk true;

            // Check for large vertical gap
            const prev_line = col_lines[i - 1];
            if (prev_line.role != .body or line.role != .body) break :blk true;
            const gap = prev_line.bounds.y0 - line.bounds.y0;
            if (gap > para_gap_threshold) break :blk true;

            // Check for indentation (first-line indent)
            const indent = line.bounds.x0 - avg_left_margin;
            if (indent > indent_threshold) break :blk true;

            break :blk false;
        };

        if (is_para_break and para_lines.items.len > 0) {
            // Save current paragraph
            const first_indent = para_lines.items[0].bounds.x0 - avg_left_margin;
            const para_lines_copy = try allocator.alloc(TextLine, para_lines.items.len);
            errdefer allocator.free(para_lines_copy);
            for (para_lines.items, 0..) |para_line, idx| {
                para_lines_copy[idx] = .{
                    .bounds = para_line.bounds,
                    .words = para_line.words,
                    .baseline_y = para_line.baseline_y,
                    .role = para_line.role,
                };
            }
            try paragraphs.append(allocator, .{
                .bounds = mergeBounds(para_lines.items),
                .lines = para_lines_copy,
                .column_index = col_idx,
                .first_line_indent = first_indent,
                .kind = paragraphKind(para_lines.items),
            });
            para_lines.clearRetainingCapacity();
        }

        try para_lines.append(allocator, line);
    }

    // Save final paragraph
    if (para_lines.items.len > 0) {
        const first_indent = para_lines.items[0].bounds.x0 - avg_left_margin;
        const para_lines_copy = try allocator.alloc(TextLine, para_lines.items.len);
        errdefer allocator.free(para_lines_copy);
        for (para_lines.items, 0..) |para_line, idx| {
            para_lines_copy[idx] = .{
                .bounds = para_line.bounds,
                .words = para_line.words,
                .baseline_y = para_line.baseline_y,
                .role = para_line.role,
            };
        }
        try paragraphs.append(allocator, .{
            .bounds = mergeBounds(para_lines.items),
            .lines = para_lines_copy,
            .column_index = col_idx,
            .first_line_indent = first_indent,
            .kind = paragraphKind(para_lines.items),
        });
    }
}

fn makeLine(allocator: std.mem.Allocator, spans: []const TextSpan) !TextLine {
    // Estimate words as ~1 per 2-3 spans
    const estimated_words = @max(1, spans.len / 2);
    var words = try std.ArrayList(TextWord).initCapacity(allocator, estimated_words);
    errdefer {
        for (words.items) |word| allocator.free(word.spans);
        words.deinit(allocator);
    }
    var current_word_spans = try std.ArrayList(TextSpan).initCapacity(allocator, 8);
    defer current_word_spans.deinit(allocator);
    const word_gap: f64 = 5;

    var prev_x1: f64 = spans[0].x0;
    for (spans) |span| {
        if (span.x0 - prev_x1 > word_gap and current_word_spans.items.len > 0) {
            const word = try makeWord(allocator, current_word_spans.items);
            errdefer allocator.free(word.spans);
            try words.append(allocator, word);
            current_word_spans.clearRetainingCapacity();
        }
        try current_word_spans.append(allocator, span);
        prev_x1 = span.x1;
    }
    if (current_word_spans.items.len > 0) {
        const word = try makeWord(allocator, current_word_spans.items);
        errdefer allocator.free(word.spans);
        try words.append(allocator, word);
    }

    const bounds = mergeSpanBounds(spans);
    return TextLine{
        .bounds = bounds,
        .words = try words.toOwnedSlice(allocator),
        .baseline_y = bounds.y0,
        .role = .body,
    };
}

const FontSizeBucket = struct {
    key: i64,
    first_size: f64,
    weight: usize,
};

fn estimateBodyFontSize(allocator: std.mem.Allocator, spans: []const TextSpan) !f64 {
    if (spans.len == 0) return 12;

    var buckets = try std.ArrayList(FontSizeBucket).initCapacity(allocator, 8);
    defer buckets.deinit(allocator);

    for (spans) |span| {
        const key: i64 = @intFromFloat(@round(span.font_size * 2));
        for (buckets.items) |*bucket| {
            if (bucket.key == key) {
                bucket.weight += span.text.len;
                break;
            }
        } else {
            try buckets.append(allocator, .{
                .key = key,
                .first_size = span.font_size,
                .weight = span.text.len,
            });
        }
    }

    var best_size = spans[0].font_size;
    var best_weight: usize = 0;
    for (buckets.items) |bucket| {
        if (bucket.weight > best_weight) {
            best_weight = bucket.weight;
            best_size = bucket.first_size;
        }
    }

    return best_size;
}

fn classifyLines(lines: []TextLine, body_font_size: f64) void {
    if (lines.len == 0) return;

    var min_y: f64 = lines[0].bounds.y0;
    var max_y: f64 = lines[0].bounds.y1;
    for (lines) |line| {
        min_y = @min(min_y, line.bounds.y0);
        max_y = @max(max_y, line.bounds.y1);
    }
    const content_height = @max(1, max_y - min_y);

    for (lines, 0..) |*line, line_index| {
        const text_len = lineTextLen(line);
        const top_band = line.bounds.y0 >= min_y + content_height * 0.92;
        const bottom_band = line.bounds.y1 <= min_y + content_height * 0.08;

        line.role = .body;
        const can_detect_furniture = lines.len >= 4;
        if (lineStartsWithCaption(line)) {
            line.role = if (lineStartsWithFigureCaption(line)) .figure_candidate else .caption;
        } else if (lineLooksLikeFormula(line, body_font_size)) {
            line.role = .formula_candidate;
        } else if (lineLooksLikeTable(line)) {
            line.role = .table_candidate;
        } else if (lineStartsWithListMarker(line)) {
            line.role = .list_item;
        } else if (line.bounds.font_size >= body_font_size * 1.18 and text_len <= 160) {
            line.role = .heading;
        } else if (can_detect_furniture and top_band and line_index <= 1 and text_len <= 120) {
            line.role = .header;
        } else if (can_detect_furniture and bottom_band and line_index + 2 >= lines.len and text_len <= 120) {
            line.role = .footer;
        }

        if ((line.role == .body or line.role == .list_item) and line_index > 0 and lineContinuesTable(&lines[line_index - 1], line)) {
            line.role = .table_candidate;
        }
    }
}

fn lineContinuesTable(previous: *const TextLine, current: *const TextLine) bool {
    if (previous.role != .table_candidate) return false;
    if (current.words.len == 0) return false;

    const gap = previous.bounds.y0 - current.bounds.y0;
    const max_gap = @max(previous.bounds.font_size, current.bounds.font_size) * 1.45;
    if (gap < 0 or gap > max_gap) return false;

    const indent = current.bounds.x0 - previous.bounds.x0;
    return indent >= -current.bounds.font_size * 0.5 and indent <= current.bounds.font_size * 2.5;
}

fn paragraphKind(lines: []const TextLine) BlockKind {
    if (lines.len == 0) return .paragraph;
    if (lines.len == 1) return blockKindForRole(lines[0].role);

    var table_count: usize = 0;
    var formula_count: usize = 0;
    var list_count: usize = 0;
    for (lines) |line| {
        switch (line.role) {
            .table_candidate => table_count += 1,
            .formula_candidate => formula_count += 1,
            .list_item => list_count += 1,
            else => {},
        }
    }
    if (table_count >= 2 and table_count * 2 >= lines.len) return .table_candidate;
    if (formula_count >= 1 and formula_count * 2 >= lines.len) return .formula_candidate;
    if (list_count == lines.len) return .list_item;
    return .paragraph;
}

fn blockKindForRole(role: LineRole) BlockKind {
    return switch (role) {
        .body => .paragraph,
        .heading => .heading,
        .list_item => .list_item,
        .header => .header,
        .footer => .footer,
        .caption => .caption,
        .table_candidate => .table_candidate,
        .formula_candidate => .formula_candidate,
        .figure_candidate => .figure_candidate,
    };
}

fn buildBlocks(allocator: std.mem.Allocator, paragraphs: []const TextParagraph, blocks: *std.ArrayList(LayoutBlock)) !void {
    for (paragraphs) |para| {
        if (para.lines.len == 0) continue;

        if (para.kind == .paragraph or para.kind == .table_candidate or para.kind == .formula_candidate) {
            const block_lines = try copyLineShells(allocator, para.lines);
            errdefer allocator.free(block_lines);
            try blocks.append(allocator, .{
                .bounds = para.bounds,
                .lines = block_lines,
                .column_index = para.column_index,
                .kind = para.kind,
                .confidence = confidenceForKind(para.kind),
                .removed = false,
            });
            continue;
        }

        for (para.lines) |line| {
            const block_lines = try copyLineShells(allocator, (&line)[0..1]);
            errdefer allocator.free(block_lines);
            const kind = blockKindForRole(line.role);
            try blocks.append(allocator, .{
                .bounds = line.bounds,
                .lines = block_lines,
                .column_index = para.column_index,
                .kind = kind,
                .confidence = confidenceForKind(kind),
                .removed = kind == .header or kind == .footer,
            });
        }
    }
}

fn collectCandidates(
    allocator: std.mem.Allocator,
    lines: []const TextLine,
    blocks: []const LayoutBlock,
    candidates: *std.ArrayList(LayoutCandidate),
) !void {
    for (lines, 0..) |line, line_index| {
        switch (line.role) {
            .table_candidate => try appendCandidate(allocator, lines, blocks, candidates, .table, &line, line_index, 0.72),
            .formula_candidate => try appendCandidate(allocator, lines, blocks, candidates, .formula, &line, line_index, 0.76),
            .figure_candidate => try appendCandidate(allocator, lines, blocks, candidates, .figure, &line, line_index, 0.68),
            else => {},
        }
    }
}

fn appendCandidate(
    allocator: std.mem.Allocator,
    lines: []const TextLine,
    blocks: []const LayoutBlock,
    candidates: *std.ArrayList(LayoutCandidate),
    kind: CandidateKind,
    line: *const TextLine,
    line_index: usize,
    confidence: f32,
) !void {
    const caption_line_index = findCaptionLine(lines, line_index, kind);
    const caption_block_index = if (caption_line_index) |caption_index|
        findBlockIndex(blocks, &lines[caption_index])
    else
        null;

    try candidates.append(allocator, .{
        .kind = kind,
        .bounds = line.bounds,
        .line_index = @intCast(line_index),
        .block_index = findBlockIndex(blocks, line),
        .caption_line_index = caption_line_index,
        .caption_block_index = caption_block_index,
        .confidence = confidence,
    });
}

fn findCaptionLine(lines: []const TextLine, line_index: usize, kind: CandidateKind) ?u32 {
    if (line_index < lines.len and captionKind(&lines[line_index]) == kind) return @intCast(line_index);

    const max_distance: usize = 3;
    var distance: usize = 1;
    while (distance <= max_distance) : (distance += 1) {
        if (line_index >= distance) {
            const before_index = line_index - distance;
            if (captionKind(&lines[before_index]) == kind) return @intCast(before_index);
        }
        const after_index = line_index + distance;
        if (after_index < lines.len and captionKind(&lines[after_index]) == kind) return @intCast(after_index);
    }

    return null;
}

fn captionKind(line: *const TextLine) ?CandidateKind {
    const first = firstText(line);
    if (std.mem.startsWith(u8, first, "Figure") or
        std.mem.startsWith(u8, first, "Fig.") or
        std.mem.startsWith(u8, first, "Chart"))
    {
        return .figure;
    }
    if (std.mem.startsWith(u8, first, "Table")) return .table;
    if (std.mem.startsWith(u8, first, "Equation") or std.mem.startsWith(u8, first, "Eq.")) return .formula;
    return null;
}

fn findBlockIndex(blocks: []const LayoutBlock, line: *const TextLine) ?u32 {
    for (blocks, 0..) |block, block_index| {
        if (containsBounds(block.bounds, line.bounds)) return @intCast(block_index);
    }
    return null;
}

fn containsBounds(outer: TextSpan, inner: TextSpan) bool {
    const epsilon = 0.01;
    return inner.x0 + epsilon >= outer.x0 and
        inner.x1 <= outer.x1 + epsilon and
        inner.y0 + epsilon >= outer.y0 and
        inner.y1 <= outer.y1 + epsilon;
}

fn copyLineShells(allocator: std.mem.Allocator, lines: []const TextLine) ![]TextLine {
    const out = try allocator.alloc(TextLine, lines.len);
    for (lines, 0..) |line, i| {
        out[i] = .{
            .bounds = line.bounds,
            .words = line.words,
            .baseline_y = line.baseline_y,
            .role = line.role,
        };
    }
    return out;
}

fn confidenceForKind(kind: BlockKind) f32 {
    return switch (kind) {
        .paragraph => 0.64,
        .heading => 0.72,
        .list_item => 0.74,
        .header, .footer => 0.62,
        .caption => 0.76,
        .table_candidate => 0.70,
        .formula_candidate => 0.74,
        .figure_candidate => 0.68,
    };
}

fn appendLineText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), line: *const TextLine) !void {
    var wrote = false;
    for (line.words, 0..) |word, word_index| {
        if (word_index > 0 and wrote) {
            try output.append(allocator, ' ');
        }
        for (word.spans) |span| {
            try output.appendSlice(allocator, span.text);
            wrote = true;
        }
    }
}

fn buildTableGridsWithRulings(
    allocator: std.mem.Allocator,
    blocks: []const LayoutBlock,
    spans: []const TextSpan,
    ruling_lines: []const RulingLine,
) ![]TableGrid {
    return buildRegionalTableGrids(allocator, blocks, spans, ruling_lines) catch |err| {
        if (err == error.TableWorkLimit) return allocator.alloc(TableGrid, 0);
        return err;
    };
}

pub const TableLimits = struct {
    pub const rulings = 512;
    pub const regions = 32;
    pub const comparisons = 2_000_000;
    pub const anchors = 128;
    pub const columns = 32;
    pub const rows = 256;
    pub const cells = 32_768;
    pub const source_spans = 16_384;
};

const TableWork = struct {
    remaining: usize = TableLimits.comparisons,
    cells: usize = 0,

    fn spend(self: *TableWork, count: usize) !void {
        if (count > self.remaining) return error.TableWorkLimit;
        self.remaining -= count;
    }

    fn reserveCells(self: *TableWork, rows: usize, columns: usize) !void {
        if (rows > TableLimits.rows or columns > TableLimits.columns) return error.TableWorkLimit;
        const count = std.math.mul(usize, rows, columns) catch return error.TableWorkLimit;
        if (count > TableLimits.cells - self.cells) return error.TableWorkLimit;
        self.cells += count;
    }
};

pub fn tableHasUsefulRows(table: TableGrid) bool {
    var count: usize = 0;
    for (table.rows) |row| {
        for (row.cells) |cell| {
            if (std.mem.trim(u8, cell.text, " \t\r\n").len > 0) {
                count += 1;
                break;
            }
        }
    }
    return count >= 2;
}

fn containsSourceIndex(indices: []const u32, needle: u32) bool {
    var low: usize = 0;
    var high = indices.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (indices[middle] == needle) return true;
        if (indices[middle] < needle) low = middle + 1 else high = middle;
    }
    return false;
}

fn rulingsTouch(a: RulingLine, b: RulingLine) bool {
    if (a.orientation == b.orientation) {
        if (a.orientation == .horizontal) return @abs(a.bbox.y0 - b.bbox.y0) <= 2 and a.bbox.x0 <= b.bbox.x1 + 2 and b.bbox.x0 <= a.bbox.x1 + 2;
        return @abs(a.bbox.x0 - b.bbox.x0) <= 2 and a.bbox.y0 <= b.bbox.y1 + 2 and b.bbox.y0 <= a.bbox.y1 + 2;
    }
    const v = if (a.orientation == .vertical) a else b;
    const h = if (a.orientation == .horizontal) a else b;
    return v.bbox.x0 >= h.bbox.x0 - 2 and v.bbox.x0 <= h.bbox.x1 + 2 and h.bbox.y0 >= v.bbox.y0 - 2 and h.bbox.y0 <= v.bbox.y1 + 2;
}

fn componentHasOuterBorder(lines: []const RulingLine) bool {
    var left: f64 = std.math.inf(f64);
    var right: f64 = -std.math.inf(f64);
    var bottom: f64 = std.math.inf(f64);
    var top: f64 = -std.math.inf(f64);
    for (lines) |line| {
        left = @min(left, line.bbox.x0);
        right = @max(right, line.bbox.x1);
        bottom = @min(bottom, line.bbox.y0);
        top = @max(top, line.bbox.y1);
    }
    var edges: [4]bool = @splat(false);
    for (lines) |line| {
        if (line.orientation == .horizontal and line.bbox.x0 <= left + 2 and line.bbox.x1 >= right - 2) {
            if (@abs(line.bbox.y0 - bottom) <= 2) edges[0] = true;
            if (@abs(line.bbox.y0 - top) <= 2) edges[1] = true;
        }
        if (line.orientation == .vertical and line.bbox.y0 <= bottom + 2 and line.bbox.y1 >= top - 2) {
            if (@abs(line.bbox.x0 - left) <= 2) edges[2] = true;
            if (@abs(line.bbox.x0 - right) <= 2) edges[3] = true;
        }
    }
    return left < right and bottom < top and edges[0] and edges[1] and edges[2] and edges[3];
}

fn appendClosedComponentRegions(allocator: std.mem.Allocator, tables: *std.ArrayList(TableGrid), blocks: []const LayoutBlock, spans: []const TextSpan, lines: []const RulingLine, work: *TableWork) !void {
    // Connected outlines can have a narrower attached footer. Their global
    // bounding box is not itself a closed rectangle. Recover finite closed
    // subregions without allowing a tall sidebar to overlap the wider table.
    var selected: [TableLimits.regions]BBox = undefined;
    var selected_count: usize = 0;
    while (true) {
        var best: ?BBox = null;
        for (lines, 0..) |top, top_index| {
            if (top.orientation != .horizontal) continue;
            for (lines[top_index + 1 ..]) |bottom_line| {
                try work.spend(1);
                const top_y = (top.bbox.y0 + top.bbox.y1) / 2;
                const bottom_y = (bottom_line.bbox.y0 + bottom_line.bbox.y1) / 2;
                if (bottom_line.orientation != .horizontal or @abs(top_y - bottom_y) <= 2) continue;
                const candidate = BBox{
                    .x0 = @max(top.bbox.x0, bottom_line.bbox.x0),
                    .x1 = @min(top.bbox.x1, bottom_line.bbox.x1),
                    .y0 = @min(top_y, bottom_y),
                    .y1 = @max(top_y, bottom_y),
                };
                if (candidate.x1 - candidate.x0 <= 2) continue;
                var overlaps = false;
                for (selected[0..selected_count]) |region| {
                    try work.spend(1);
                    if (@min(region.x1, candidate.x1) > @max(region.x0, candidate.x0) and @min(region.y1, candidate.y1) > @max(region.y0, candidate.y0)) overlaps = true;
                }
                if (overlaps) continue;
                var left = false;
                var right = false;
                for (lines) |vertical| {
                    try work.spend(1);
                    if (vertical.orientation != .vertical or vertical.bbox.y0 > candidate.y0 + 2 or vertical.bbox.y1 < candidate.y1 - 2) continue;
                    const x = (vertical.bbox.x0 + vertical.bbox.x1) / 2;
                    if (@abs(x - candidate.x0) <= 2) left = true;
                    if (@abs(x - candidate.x1) <= 2) right = true;
                }
                if (!left or !right) continue;
                if (best) |current| {
                    const width = candidate.x1 - candidate.x0;
                    const current_width = current.x1 - current.x0;
                    if (width < current_width or (width == current_width and candidate.y1 - candidate.y0 <= current.y1 - current.y0)) continue;
                }
                best = candidate;
            }
        }
        const region = best orelse break;
        if (selected_count == selected.len) return error.TableWorkLimit;
        selected[selected_count] = region;
        selected_count += 1;
        var clipped: [TableLimits.rulings]RulingLine = undefined;
        var clipped_count: usize = 0;
        for (lines) |source| {
            try work.spend(1);
            var line = source;
            if (line.orientation == .horizontal) {
                var y = (line.bbox.y0 + line.bbox.y1) / 2;
                const crosses = line.bbox.x0 <= region.x0 + 2 and line.bbox.x1 >= region.x1 - 2;
                if (crosses and @abs(y - region.y0) <= 2) y = region.y0 else if (crosses and @abs(y - region.y1) <= 2) y = region.y1;
                if (y < region.y0 or y > region.y1) continue;
                line.bbox.y0 = y;
                line.bbox.y1 = y;
                line.bbox.x0 = @max(line.bbox.x0, region.x0);
                line.bbox.x1 = @min(line.bbox.x1, region.x1);
                if (line.bbox.x1 <= line.bbox.x0) continue;
            } else {
                var x = (line.bbox.x0 + line.bbox.x1) / 2;
                const crosses = line.bbox.y0 <= region.y0 + 2 and line.bbox.y1 >= region.y1 - 2;
                // Border admission and clipping use the same junction tolerance.
                // Snap only a full outer-edge axis; never extend its endpoints.
                if (crosses and @abs(x - region.x0) <= 2) x = region.x0 else if (crosses and @abs(x - region.x1) <= 2) x = region.x1;
                if (x < region.x0 or x > region.x1) continue;
                line.bbox.x0 = x;
                line.bbox.x1 = x;
                line.bbox.y0 = @max(line.bbox.y0, region.y0);
                line.bbox.y1 = @min(line.bbox.y1, region.y1);
                if (line.bbox.y1 <= line.bbox.y0) continue;
            }
            clipped[clipped_count] = line;
            clipped_count += 1;
        }
        if (try buildRuledTableGrid(allocator, blocks, spans, clipped[0..clipped_count], work)) |table| {
            errdefer freeTableGrid(allocator, table);
            if (tables.items.len >= TableLimits.regions) return error.TableWorkLimit;
            try tables.append(allocator, table);
        }
    }
}

fn buildRegionalTableGrids(allocator: std.mem.Allocator, blocks: []const LayoutBlock, spans: []const TextSpan, ruling_lines: []const RulingLine) ![]TableGrid {
    if (spans.len > TableLimits.source_spans or ruling_lines.len > TableLimits.rulings) return error.TableWorkLimit;
    var work: TableWork = .{};
    var source_capacity: usize = 0;
    for (spans) |span| {
        const id = span.native_source_index orelse return error.TableWorkLimit;
        if (id >= TableLimits.source_spans) return error.TableWorkLimit;
        source_capacity = @max(source_capacity, @as(usize, id) + 1);
    }
    const owned = try allocator.alloc(bool, source_capacity);
    defer allocator.free(owned);
    const refused = try allocator.alloc(bool, source_capacity);
    defer allocator.free(refused);
    @memset(refused, false);
    @memset(owned, false);
    for (spans) |span| {
        const id = span.native_source_index.?;
        if (owned[id]) return error.TableWorkLimit;
        owned[id] = true;
    }
    @memset(owned, false);
    var tables: std.ArrayList(TableGrid) = .empty;
    errdefer {
        freeTableGrids(allocator, tables.items);
        tables.deinit(allocator);
    }
    const seen = try allocator.alloc(bool, ruling_lines.len);
    defer allocator.free(seen);
    @memset(seen, false);
    var component: std.ArrayList(RulingLine) = .empty;
    defer component.deinit(allocator);
    var frontier: std.ArrayList(usize) = .empty;
    defer frontier.deinit(allocator);
    for (ruling_lines, 0..) |seed, seed_index| {
        if (seen[seed_index]) continue;
        if (!std.math.isFinite(seed.bbox.x0) or !std.math.isFinite(seed.bbox.x1) or !std.math.isFinite(seed.bbox.y0) or !std.math.isFinite(seed.bbox.y1) or seed.bbox.x0 > seed.bbox.x1 or seed.bbox.y0 > seed.bbox.y1) {
            seen[seed_index] = true;
            continue;
        }
        component.clearRetainingCapacity();
        frontier.clearRetainingCapacity();
        try frontier.append(allocator, seed_index);
        seen[seed_index] = true;
        var cursor: usize = 0;
        while (cursor < frontier.items.len) : (cursor += 1) {
            const line = ruling_lines[frontier.items[cursor]];
            try component.append(allocator, line);
            for (ruling_lines, 0..) |other, index| {
                try work.spend(1);
                if (!std.math.isFinite(other.bbox.x0) or !std.math.isFinite(other.bbox.x1) or !std.math.isFinite(other.bbox.y0) or !std.math.isFinite(other.bbox.y1) or other.bbox.x0 > other.bbox.x1 or other.bbox.y0 > other.bbox.y1) {
                    seen[index] = true;
                    continue;
                }
                if (!seen[index] and rulingsTouch(line, other)) {
                    seen[index] = true;
                    try frontier.append(allocator, index);
                }
            }
        }
        if (!componentHasOuterBorder(component.items)) {
            try appendClosedComponentRegions(allocator, &tables, blocks, spans, component.items, &work);
            continue;
        }
        if (try buildRuledTableGrid(allocator, blocks, spans, component.items, &work)) |table| {
            errdefer freeTableGrid(allocator, table);
            if (tables.items.len >= TableLimits.regions) return error.TableWorkLimit;
            try tables.append(allocator, table);
        }
    }
    const native_bands = try buildNativeTableBandsWithRefusals(allocator, spans, tables.items, refused, &work);
    defer allocator.free(native_bands);
    var native_transferred: usize = 0;
    errdefer freeTableGrids(allocator, native_bands[native_transferred..]);
    for (native_bands) |table| {
        if (tables.items.len >= TableLimits.regions) return error.TableWorkLimit;
        try tables.append(allocator, table);
        native_transferred += 1;
    }
    const heuristic = try buildTableGrids(allocator, blocks, &work);
    defer allocator.free(heuristic);
    var transferred: usize = 0;
    errdefer freeTableGrids(allocator, heuristic[transferred..]);
    for (heuristic) |table| {
        if (try tableHasRefusedSources(table, blocks, refused, &work)) {
            freeTableGrid(allocator, table);
            transferred += 1;
            continue;
        }
        if (tables.items.len >= TableLimits.regions) return error.TableWorkLimit;
        try tables.append(allocator, table);
        transferred += 1;
    }
    // Every candidate reserves exact native leaves only after reconstruction.
    var accepted: usize = 0;
    while (accepted < tables.items.len) {
        const table = &tables.items[accepted];
        if (!tableHasUsefulRows(table.*) or !(try attachTableMembers(allocator, table, blocks, spans, owned, &work))) {
            freeTableGrid(allocator, table.*);
            _ = tables.orderedRemove(accepted);
            continue;
        }
        tables.items[accepted].region_index = @intCast(accepted);
        tables.items[accepted].projection_eligible = true;
        accepted += 1;
    }
    std.mem.sort(TableGrid, tables.items, {}, struct {
        fn lessThan(_: void, a: TableGrid, b: TableGrid) bool {
            if (a.bounds.y1 != b.bounds.y1) return a.bounds.y1 > b.bounds.y1;
            if (a.bounds.x0 != b.bounds.x0) return a.bounds.x0 < b.bounds.x0;
            return a.block_index < b.block_index;
        }
    }.lessThan);
    for (tables.items, 0..) |*table, index| table.region_index = @intCast(index);
    assignPageLocalTableIds(tables.items);
    const result = try allocator.dupe(TableGrid, tables.items);
    tables.deinit(allocator);
    return result;
}

fn tableHasRefusedSources(table: TableGrid, blocks: []const LayoutBlock, refused: []const bool, work: *TableWork) !bool {
    const start: usize = table.block_index;
    if (start > blocks.len or table.block_count > blocks.len - start) return true;
    for (blocks[start .. start + table.block_count]) |block| for (block.lines) |line| for (line.words) |word| for (word.spans) |span| {
        try work.spend(1);
        const id = span.native_source_index orelse return true;
        if (id >= refused.len or refused[id]) return true;
    };
    return false;
}

fn attachTableMembers(allocator: std.mem.Allocator, table: *TableGrid, blocks: []const LayoutBlock, spans: []const TextSpan, owned: []bool, work: *TableWork) !bool {
    var ids: std.ArrayList(u32) = .empty;
    defer ids.deinit(allocator);
    var members: std.ArrayList(u32) = .empty;
    defer members.deinit(allocator);
    const selected = try allocator.alloc(bool, owned.len);
    defer allocator.free(selected);
    @memset(selected, false);
    if (table.source_span_indices.len > 0) {
        for (table.source_span_indices) |id| {
            try work.spend(1);
            if (id >= owned.len or selected[id] or owned[id]) return false;
            try ids.append(allocator, id);
            selected[id] = true;
        }
    } else if (table.ruled_region) {
        for (spans) |span| {
            try work.spend(1);
            const cx = (span.x0 + span.x1) / 2;
            const cy = (span.y0 + span.y1) / 2;
            // Match the ruled assignment's outer-edge tolerance exactly.
            if (!intersectsSpan(span, table.bounds) or cx < table.bounds.x0 - 1 or cx > table.bounds.x1 + 1 or cy < table.bounds.y0 - 1 or cy > table.bounds.y1 + 1) continue;
            if (!(try addTableMember(allocator, &ids, span, selected, owned))) return false;
        }
    } else {
        const start: usize = table.block_index;
        if (start > blocks.len or table.block_count > blocks.len - start) return false;
        for (blocks[start .. start + table.block_count]) |block| for (block.lines) |line| for (line.words) |word| for (word.spans) |span| {
            try work.spend(1);
            if (!(try addTableMember(allocator, &ids, span, selected, owned))) return false;
        };
    }
    if (ids.items.len == 0) return false;
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
    for (blocks, 0..) |block, block_index| {
        var belongs = false;
        for (block.lines) |line| for (line.words) |word| for (word.spans) |span| {
            try work.spend(1);
            if (span.native_source_index) |id| {
                if (containsSourceIndex(ids.items, id)) belongs = true;
            }
        };
        if (belongs) try members.append(allocator, @intCast(block_index));
    }
    if (members.items.len == 0) return false;
    const source_ids = try allocator.dupe(u32, ids.items);
    errdefer allocator.free(source_ids);
    const block_ids = try allocator.dupe(u32, members.items);
    if (table.source_span_indices.len > 0) allocator.free(table.source_span_indices);
    table.source_span_indices = source_ids;
    table.member_block_indices = block_ids;
    table.block_index = block_ids[0];
    table.block_count = @as(usize, block_ids[block_ids.len - 1]) - block_ids[0] + 1;
    for (source_ids) |id| owned[id] = true;
    return true;
}

fn nativeBandLineEligible(line: TextLine) bool {
    if (line.role == .heading or line.role == .caption or line.role == .figure_candidate or line.role == .formula_candidate or line.role == .list_item) return false;
    if (line.words.len < 2 or lineWideGapCount(&line) == 0) return false;
    for (line.words) |word| if (wordLooksNumeric(word) or wordIsPlaceholder(word)) return true;
    return lineWideGapCount(&line) >= 2;
}

fn nativeHeaderFields(header: TextLine, starts: *[TableLimits.columns]f64, work: *TableWork) !usize {
    var count: usize = 0;
    for (header.words, 0..) |word, index| {
        try work.spend(1);
        if (wordLooksNumeric(word) or wordIsPlaceholder(word)) return 0;
        if (index > 0 and word.bounds.x0 - header.words[index - 1].bounds.x1 <= header.bounds.font_size * 1.8) continue;
        if (count == starts.len) return error.TableWorkLimit;
        starts[count] = word.bounds.x0;
        count += 1;
    }
    return count;
}

fn nativeHeaderBodyTransition(header: TextLine, body: TextLine, work: *TableWork) !bool {
    var starts: [TableLimits.columns]f64 = undefined;
    if (try nativeHeaderFields(header, &starts, work) < 3) return false;
    const scale = @max(1, @max(header.bounds.font_size, body.bounds.font_size));
    const gap = header.bounds.y0 - body.bounds.y1;
    if (gap < -scale or gap > scale * 8) return false;
    const width = @min(header.bounds.x1 - header.bounds.x0, body.bounds.x1 - body.bounds.x0);
    const overlap = @min(header.bounds.x1, body.bounds.x1) - @max(header.bounds.x0, body.bounds.x0);
    if (width <= 0 or overlap < width * 0.8 or body.words.len == 0) return false;
    const aligned_stub = @abs(body.words[0].bounds.x0 - starts[0]) <= scale * 2;
    var numeric_count: usize = 0;
    for (body.words) |word| {
        try work.spend(1);
        if (wordLooksNumeric(word) or wordIsPlaceholder(word)) numeric_count += 1;
    }
    // A value baseline may precede its wrapped label. Complete-band header
    // corroboration still requires the missing label field to be represented.
    return numeric_count > 0 and (aligned_stub or numeric_count >= 2);
}

fn nativeHeaderCorroborated(header: TextLine, body: []const TextLine, work: *TableWork) !bool {
    var starts: [TableLimits.columns]f64 = undefined;
    const count = try nativeHeaderFields(header, &starts, work);
    if (count < 3) return false;
    var covered: [TableLimits.columns]bool = @splat(false);
    for (body) |line| for (line.words) |word| {
        try work.spend(1);
        // Currency symbols alone do not establish a separate populated field.
        if (wordIsCurrency(word)) continue;
        const numeric = wordLooksNumeric(word) or wordIsPlaceholder(word);
        const point = if (numeric) word.bounds.x1 else word.bounds.x0;
        var field: usize = 0;
        for (starts[1..count], 1..) |start, index| {
            try work.spend(1);
            if (point + @max(6, line.bounds.font_size * 0.75) >= start) field = index;
        }
        covered[field] = true;
    };
    for (covered[0..count]) |present| if (!present) return false;
    return true;
}

const StatementLineKind = enum { automatic, section, prefix, suffix, values, note };

const StatementColumns = struct {
    edges: [TableLimits.columns]f64 = undefined,
    count: usize = 0,
    stub_left: f64,
    stub_right: f64,
    font_size: f64,
};

fn statementHardBarrier(line: TextLine) bool {
    if (line.role == .heading or line.role == .caption or line.role == .figure_candidate or line.role == .formula_candidate or line.role == .list_item) return true;
    // Classification can rank multi-field numeric evidence before list syntax.
    // Preserve a literal narrative marker when it is part of the label text.
    return line.words.len > 0 and !statementMarkerNote(line) and lineStartsWithListMarker(&line) and !wordLooksNumeric(line.words[0]);
}

fn statementMarkerNote(line: TextLine) bool {
    return line.words.len > 0 and std.mem.startsWith(u8, std.mem.trim(u8, firstText(&line), " \t"), "*");
}

fn statementReferencedNote(lines: []const TextLine, start: usize, index: usize, columns: ?StatementColumns, work: *TableWork) !bool {
    if (index <= start or !statementMarkerNote(lines[index]) or !lineContinuesTable(&lines[index - 1], &lines[index])) return false;
    var cursor = index;
    while (cursor > start and index - cursor < 4) {
        cursor -= 1;
        try work.spend(1);
        for (lines[cursor].words) |word| {
            try work.spend(1);
            if (columns) |model| if (word.bounds.x1 > model.stub_right) continue;
            for (word.spans) |span| {
                try work.spend(span.text.len + 1);
                const text = std.mem.trim(u8, span.text, " \t\r\n");
                if (text.len > 1 and text[0] != '*' and std.mem.indexOfScalar(u8, text, '*') != null) return true;
            }
        }
    }
    return false;
}

fn statementValueCount(line: TextLine, columns: StatementColumns, work: *TableWork) !usize {
    if (statementHardBarrier(line) or statementMarkerNote(line)) return 0;
    var matched: [TableLimits.columns]bool = @splat(false);
    var count: usize = 0;
    for (line.words) |word| {
        try work.spend(1);
        if (!(wordLooksNumeric(word) or wordIsPlaceholder(word))) continue;
        for (columns.edges[0..columns.count], 0..) |edge, index| {
            try work.spend(1);
            if (matched[index] or @abs(word.bounds.x1 - edge) > @max(6, columns.font_size * 0.75)) continue;
            matched[index] = true;
            count += 1;
            break;
        }
    }
    return count;
}

fn statementHasStub(line: TextLine, columns: StatementColumns, work: *TableWork) !bool {
    for (line.words) |word| {
        try work.spend(1);
        if (word.bounds.x1 > columns.stub_right) continue;
        for (word.spans) |span| {
            try work.spend(1);
            if (std.mem.trim(u8, span.text, " \t\r\n").len > 0) return true;
        }
    }
    return false;
}

fn statementStubLine(line: TextLine, columns: StatementColumns, work: *TableWork) !bool {
    if (line.words.len == 0 or statementHardBarrier(line)) return false;
    if (line.bounds.font_size < columns.font_size * 0.85 or line.bounds.font_size > columns.font_size * 1.15) return false;
    if (line.bounds.x0 < columns.stub_left - columns.font_size or line.bounds.x0 > columns.stub_left + columns.font_size * 3) return false;
    if (line.bounds.x1 > columns.stub_right) return false;
    return try statementValueCount(line, columns, work) == 0;
}

fn statementSectionStyle(line: TextLine, work: *TableWork) !bool {
    var upper: usize = 0;
    var lower: usize = 0;
    var length: usize = 0;
    var bold = false;
    for (line.words) |word| for (word.spans) |span| {
        try work.spend(span.text.len + 1);
        length += span.text.len;
        for (span.text) |byte| {
            if (std.ascii.isUpper(byte)) upper += 1;
            if (std.ascii.isLower(byte)) lower += 1;
        }
        if (span.font.name) |name| {
            var index: usize = 0;
            while (index + 4 <= name.len) : (index += 1) {
                try work.spend(1);
                if (std.ascii.eqlIgnoreCase(name[index .. index + 4], "bold")) bold = true;
            }
        }
    };
    return length <= 80 and ((upper >= 3 and lower == 0) or bold);
}

fn inferStatementColumns(lines: []const TextLine, start: usize, work: *TableWork) !?StatementColumns {
    var columns = StatementColumns{ .stub_left = lines[start].bounds.x0, .stub_right = lines[start].bounds.x1, .font_size = @max(1, lines[start].bounds.font_size) };
    var first_row: ?usize = null;
    const end = @min(lines.len, start + 9);
    for (lines[start + 1 .. end], start + 1..) |line, index| {
        try work.spend(1);
        if (lines[start].bounds.y0 - line.bounds.y0 > columns.font_size * 16) break;
        if (statementHardBarrier(line)) break;
        if (first_row != null) {
            if (try statementValueCount(line, columns, work) > 0) return columns;
            if (!(try statementStubLine(line, columns, work))) break;
            continue;
        }
        var count: usize = 0;
        var first_left = std.math.inf(f64);
        for (line.words) |word| {
            try work.spend(1);
            if (!(wordLooksNumeric(word) or wordIsPlaceholder(word)) or word.bounds.x0 <= columns.stub_left + columns.font_size * 4) continue;
            if (count == columns.edges.len) return error.TableWorkLimit;
            columns.edges[count] = word.bounds.x1;
            first_left = @min(first_left, word.bounds.x0);
            count += 1;
        }
        if (count >= 2) {
            columns.count = count;
            columns.stub_right = first_left - columns.font_size;
            first_row = index;
        } else if (lineWideGapCount(&line) > 0) break;
    }
    return null;
}

const StatementAttachment = struct { kind: StatementLineKind, count: usize };

fn statementAttachment(lines: []const TextLine, band_start: usize, index: usize, columns: StatementColumns, work: *TableWork) !?StatementAttachment {
    if (!(try statementStubLine(lines[index], columns, work))) return null;
    const font = columns.font_size;
    const before_gap = if (index > band_start) lines[index - 1].bounds.y0 - lines[index].bounds.y0 else std.math.inf(f64);
    if (try statementSectionStyle(lines[index], work)) {
        var next_value = index + 1;
        while (next_value < lines.len and next_value - index < 5) : (next_value += 1) {
            try work.spend(1);
            if (try statementValueCount(lines[next_value], columns, work) > 0) break;
            if (!(try statementStubLine(lines[next_value], columns, work))) break;
            if (next_value > index + 1 and lines[next_value - 1].bounds.y0 - lines[next_value].bounds.y0 > font * 2.6) break;
        }
        const after_gap = if (index + 1 < lines.len) lines[index].bounds.y0 - lines[index + 1].bounds.y0 else std.math.inf(f64);
        const wide_isolation = before_gap > font * 2.5 and after_gap > font * 2.5;
        // Adjacent section labels can precede the same populated detail row.
        // Every intermediate stub must independently carry section styling,
        // stable alignment, and a full-em baseline gap; ordinary wrapped labels
        // do not supply this evidence.
        var section_chain = next_value < lines.len and next_value - index < 5 and
            lines[next_value - 1].bounds.y0 - lines[next_value].bounds.y0 >= font;
        if (section_chain) {
            for (lines[index + 1 .. next_value], index + 1..) |line, cursor| {
                try work.spend(1);
                if (@abs(line.bounds.x0 - columns.stub_left) > font * 0.75 or
                    lines[cursor - 1].bounds.y0 - line.bounds.y0 < font or
                    !(try statementSectionStyle(line, work)))
                {
                    section_chain = false;
                    break;
                }
            }
        }
        const tight_isolation = before_gap >= font and after_gap >= font and
            section_chain and index > band_start and
            @abs(lines[index].bounds.x0 - columns.stub_left) <= font * 0.75 and
            try statementHasStub(lines[index - 1], columns, work) and
            next_value < lines.len and try statementHasStub(lines[next_value], columns, work);
        if (index + 1 < lines.len and (wide_isolation or tight_isolation) and before_gap <= font * 8 and
            after_gap <= font * 8 and
            next_value < lines.len and next_value - index < 5 and
            lines[index].bounds.y0 - lines[next_value].bounds.y0 <= font * 8 and
            try statementValueCount(lines[next_value], columns, work) > 0)
        {
            return .{ .kind = .section, .count = 1 };
        }
    }
    var end = index + 1;
    while (end < lines.len and end - index < 4) : (end += 1) {
        try work.spend(1);
        if (!(try statementStubLine(lines[end], columns, work)) or
            lines[end - 1].bounds.y0 - lines[end].bounds.y0 > font * 2.6 or
            lines[end - 1].bounds.y0 < lines[end].bounds.y0) break;
    }
    if (end < lines.len and end - index == 4 and try statementStubLine(lines[end], columns, work) and
        lines[end - 1].bounds.y0 - lines[end].bounds.y0 <= font * 2.6) return null;
    var previous: ?usize = null;
    var cursor = index;
    while (cursor > band_start and index - cursor < 4) {
        cursor -= 1;
        try work.spend(1);
        if (try statementValueCount(lines[cursor], columns, work) > 0) {
            previous = cursor;
            break;
        }
        if (!(try statementStubLine(lines[cursor], columns, work))) break;
    }
    const previous_gap = if (previous) |row| lines[row].bounds.y0 - lines[index].bounds.y0 else std.math.inf(f64);
    const next_gap = if (end < lines.len and try statementValueCount(lines[end], columns, work) > 0)
        lines[end - 1].bounds.y0 - lines[end].bounds.y0
    else
        std.math.inf(f64);
    const suffix = previous_gap >= 0 and previous_gap <= font * 2.6;
    const prefix = next_gap >= 0 and next_gap <= font * 2.6;
    var terminal_populated_stub = false;
    if (previous) |row| {
        if (!std.math.isFinite(next_gap)) {
            terminal_populated_stub = try statementHasStub(lines[row], columns, work);
        }
    }
    if (suffix and !terminal_populated_stub and (!prefix or previous_gap + font * 0.5 < next_gap)) return .{ .kind = .suffix, .count = end - index };
    if (prefix and (!suffix or next_gap + font * 0.5 < previous_gap)) return .{ .kind = .prefix, .count = end - index };
    return null;
}

fn buildNativeTableBands(allocator: std.mem.Allocator, spans: []const TextSpan, ruled: []const TableGrid, work: *TableWork) ![]TableGrid {
    return buildNativeTableBandsWithRefusals(allocator, spans, ruled, null, work);
}

fn refuseStatementLine(refused: ?[]bool, line: TextLine, work: *TableWork) !void {
    const mask = refused orelse return;
    for (line.words) |word| for (word.spans) |span| {
        try work.spend(1);
        if (std.mem.trim(u8, span.text, " \t\r\n").len == 0) continue;
        const id = span.native_source_index orelse return error.TableWorkLimit;
        if (id >= mask.len) return error.TableWorkLimit;
        mask[id] = true;
    };
}

fn refuseStatementChain(refused: ?[]bool, lines: []const TextLine, start: usize, columns: StatementColumns, work: *TableWork) !void {
    var index = start;
    while (index < lines.len and try statementStubLine(lines[index], columns, work)) : (index += 1) {
        if (index - start >= TableLimits.rows) return error.TableWorkLimit;
        if (index > start and lines[index - 1].bounds.y0 - lines[index].bounds.y0 > columns.font_size * 2.6) break;
        try refuseStatementLine(refused, lines[index], work);
    }
}

fn buildNativeTableBandsWithRefusals(allocator: std.mem.Allocator, spans: []const TextSpan, ruled: []const TableGrid, refused: ?[]bool, work: *TableWork) ![]TableGrid {
    var view: std.ArrayList(TextSpan) = .empty;
    defer view.deinit(allocator);
    const useful_ruled = try allocator.alloc(bool, ruled.len);
    defer allocator.free(useful_ruled);
    for (ruled, useful_ruled) |table, *useful| useful.* = tableHasUsefulRows(table);
    for (spans) |span| {
        var covered = false;
        for (ruled, useful_ruled) |table, useful| {
            try work.spend(1);
            if (!useful) continue;
            const cx = (span.x0 + span.x1) / 2;
            const cy = (span.y0 + span.y1) / 2;
            if (intersectsSpan(span, table.bounds) and cx >= table.bounds.x0 - 1 and cx <= table.bounds.x1 + 1 and cy >= table.bounds.y0 - 1 and cy <= table.bounds.y1 + 1) covered = true;
        }
        if (!covered) {
            var table_span = span;
            if (span.layout_font_size) |size| {
                if (std.math.isFinite(size) and size > 0) table_span.font_size = size;
            }
            try view.append(allocator, table_span);
        }
    }
    std.mem.sort(TextSpan, view.items, {}, struct {
        fn lessThan(_: void, a: TextSpan, b: TextSpan) bool {
            const a_band = @as(i64, @intFromFloat(@floor(a.y0 / 5)));
            const b_band = @as(i64, @intFromFloat(@floor(b.y0 / 5)));
            if (a_band != b_band) return a_band > b_band;
            return a.x0 < b.x0;
        }
    }.lessThan);
    var lines: std.ArrayList(TextLine) = .empty;
    defer {
        freeTextLines(allocator, lines.items);
        lines.deinit(allocator);
    }
    var start: usize = 0;
    while (start < view.items.len) {
        var end = start + 1;
        const tolerance = @min(10, @max(3, view.items[start].font_size * 0.7));
        while (end < view.items.len and @abs(view.items[start].y0 - view.items[end].y0) <= tolerance) : (end += 1) {}
        // A merged baseline may contain adjacent Y bins. Word construction
        // requires increasing X even when raised text sorted into the first bin.
        std.mem.sort(TextSpan, view.items[start..end], {}, struct {
            fn lessThan(_: void, a: TextSpan, b: TextSpan) bool {
                if (a.x0 != b.x0) return a.x0 < b.x0;
                if (a.y0 != b.y0) return a.y0 > b.y0;
                return (a.native_source_index orelse 0) < (b.native_source_index orelse 0);
            }
        }.lessThan);
        var line = try makeLine(allocator, view.items[start..end]);
        // makeLine retains the original public font object in its bounds.
        // Its table-only scalar uses the measured normal scale in page points.
        var point_size: f64 = 0;
        for (view.items[start..end]) |span| point_size = @max(point_size, span.font_size);
        line.bounds.font_size = point_size;
        errdefer freeTextLine(allocator, line);
        try lines.append(allocator, line);
        start = end;
    }
    classifyLines(lines.items, try estimateBodyFontSize(allocator, view.items));
    var output: std.ArrayList(TableGrid) = .empty;
    errdefer {
        freeTableGrids(allocator, output.items);
        output.deinit(allocator);
    }
    var index: usize = 0;
    while (index < lines.items.len) {
        if (statementMarkerNote(lines.items[index]) or statementHardBarrier(lines.items[index])) {
            // A rejected seed must retain the same source refusal as a barrier
            // encountered inside a band. Otherwise the legacy path can claim
            // it as its second numeric row.
            try refuseStatementLine(refused, lines.items[index], work);
            index += 1;
            continue;
        }
        if (!nativeBandLineEligible(lines.items[index]) or lineWideGapCount(&lines.items[index]) < 2) {
            index += 1;
            continue;
        }
        var end = index + 1;
        var bridged_header = false;
        var kinds: [TableLimits.rows]StatementLineKind = @splat(.automatic);
        const statement_columns = try inferStatementColumns(lines.items, index, work);
        var has_values = if (statement_columns) |columns| try statementValueCount(lines.items[index], columns, work) > 0 else false;
        while (end < lines.items.len) : (end += 1) {
            if (end - index >= kinds.len) return error.TableWorkLimit;
            if (try statementReferencedNote(lines.items, index, end, statement_columns, work)) {
                kinds[end - index] = .note;
                continue;
            }
            if (statementHardBarrier(lines.items[end]) or statementMarkerNote(lines.items[end])) {
                try refuseStatementLine(refused, lines.items[end], work);
                break;
            }
            var value_count: usize = 0;
            if (statement_columns) |columns| {
                value_count = try statementValueCount(lines.items[end], columns, work);
                // Repeated field headers start a new report even if the amounts
                // and fonts match the current report.
                if (has_values and value_count == 0 and lineWideGapCount(&lines.items[end]) >= 2) break;
                if (value_count == 0) {
                    if (try statementAttachment(lines.items, index, end, columns, work)) |attachment| {
                        if (attachment.count > kinds.len - (end - index)) return error.TableWorkLimit;
                        @memset(kinds[end - index .. end - index + attachment.count], attachment.kind);
                        end += attachment.count - 1;
                        continue;
                    }
                    // A close stub line with two plausible targets is not an
                    // implicit backward continuation. Leave its native leaves.
                    if (try statementStubLine(lines.items[end], columns, work)) {
                        try refuseStatementChain(refused, lines.items, end, columns, work);
                        break;
                    }
                } else {
                    kinds[end - index] = .values;
                }
            }
            const continuation = lines.items[end].role == .table_candidate and lineContinuesTable(&lines.items[end - 1], &lines.items[end]);
            if (!nativeBandLineEligible(lines.items[end]) and !continuation and value_count == 0) break;
            const previous = LayoutBlock{ .bounds = lines.items[end - 1].bounds, .lines = lines.items[end - 1 .. end], .column_index = 0, .kind = .table_candidate };
            const next = LayoutBlock{ .bounds = lines.items[end].bounds, .lines = lines.items[end .. end + 1], .column_index = 0, .kind = .table_candidate };
            const previous_kind = kinds[end - index - 1];
            const attached_transition = value_count > 0 and (previous_kind == .section or previous_kind == .prefix or previous_kind == .suffix) and
                lines.items[end - 1].bounds.y0 - lines.items[end].bounds.y0 <= lines.items[end].bounds.font_size * 8;
            if (!attached_transition and !(try compatibleTableFragments(previous, next, work))) {
                // A wide header gap needs corroboration from the complete body,
                // and is only considered in the native field-band path.
                if (end != index + 1 or !(try nativeHeaderBodyTransition(lines.items[index], lines.items[end], work))) break;
                bridged_header = true;
            }
            if (value_count > 0) has_values = true;
        }
        var block = LayoutBlock{ .bounds = mergeBounds(lines.items[index..end]), .lines = lines.items[index..end], .column_index = 0, .kind = .table_candidate, .confidence = 0.72 };
        block.bounds.font_size = 0;
        for (block.lines) |line| block.bounds.font_size = @max(block.bounds.font_size, line.bounds.font_size);
        var body_rows: usize = 0;
        for (block.lines, kinds[0 .. end - index]) |line, kind| {
            if (kind == .section or kind == .prefix or kind == .suffix or kind == .note) continue;
            for (line.words) |word| if (wordLooksNumeric(word) or wordIsPlaceholder(word)) {
                body_rows += 1;
                break;
            };
        }
        if (body_rows < 2) {
            index = end;
            continue;
        }
        if (bridged_header and !(try nativeHeaderCorroborated(block.lines[0], block.lines[1..], work))) {
            index += 1;
            continue;
        }
        if (try buildTableGridForStatement(allocator, block, 0, kinds[0 .. end - index], work)) |built| {
            var table = built;
            errdefer freeTableGrid(allocator, table);
            if (tableHasUsefulRows(table)) {
                var ids: std.ArrayList(u32) = .empty;
                defer ids.deinit(allocator);
                for (block.lines) |line| for (line.words) |word| for (word.spans) |span| {
                    try work.spend(1);
                    if (std.mem.trim(u8, span.text, " \t\r\n").len == 0) continue;
                    try ids.append(allocator, span.native_source_index orelse return error.TableWorkLimit);
                };
                table.source_span_indices = try allocator.dupe(u32, ids.items);
                std.mem.sort(u32, @constCast(table.source_span_indices), {}, std.sort.asc(u32));
                if (output.items.len >= TableLimits.regions) return error.TableWorkLimit;
                try output.append(allocator, table);
            } else freeTableGrid(allocator, table);
        }
        index = end;
    }
    const result = try allocator.dupe(TableGrid, output.items);
    output.deinit(allocator);
    return result;
}

fn addTableMember(allocator: std.mem.Allocator, ids: *std.ArrayList(u32), span: TextSpan, selected: []bool, owned: []const bool) !bool {
    if (std.mem.trim(u8, span.text, " \t\r\n").len == 0) return true;
    const id = span.native_source_index orelse return false;
    if (id >= selected.len or selected[id] or owned[id]) return false;
    try ids.append(allocator, id);
    selected[id] = true;
    return true;
}

fn buildTableGrids(allocator: std.mem.Allocator, blocks: []const LayoutBlock, work: *TableWork) ![]TableGrid {
    var tables: std.ArrayList(TableGrid) = .empty;
    errdefer {
        freeTableGrids(allocator, tables.items);
        tables.deinit(allocator);
    }

    var block_index: usize = 0;
    while (block_index < blocks.len) {
        const block = blocks[block_index];
        if (!tableFragmentEligible(block)) {
            block_index += 1;
            continue;
        }

        var run_end = block_index + 1;
        while (run_end < blocks.len and
            tableFragmentEligible(blocks[run_end]) and
            blocks[run_end].column_index == block.column_index and
            !blocks[run_end].removed and
            (try compatibleTableFragments(blocks[run_end - 1], blocks[run_end], work))) : (run_end += 1)
        {}

        if (run_end - block_index > 1) {
            var line_count: usize = 0;
            for (blocks[block_index..run_end]) |run_block| line_count += run_block.lines.len;
            if (line_count > TableLimits.rows) return error.TableWorkLimit;

            const run_lines = try allocator.alloc(TextLine, line_count);
            defer allocator.free(run_lines);
            var line_index: usize = 0;
            for (blocks[block_index..run_end]) |run_block| {
                for (run_block.lines) |line| {
                    run_lines[line_index] = line;
                    line_index += 1;
                }
            }

            const run_block = LayoutBlock{
                .bounds = mergeBounds(run_lines),
                .lines = run_lines,
                .column_index = block.column_index,
                .kind = .table_candidate,
                .confidence = block.confidence,
                .removed = false,
            };
            if (try buildTableGridForBlock(allocator, run_block, @intCast(block_index), work)) |built_table| {
                var table = built_table;
                errdefer freeTableGrid(allocator, table);
                table.block_count = run_end - block_index;
                if (tables.items.len >= TableLimits.regions) return error.TableWorkLimit;
                try tables.append(allocator, table);
                block_index = run_end;
                continue;
            }
        }

        if (try buildTableGridForBlock(allocator, block, @intCast(block_index), work)) |table| {
            errdefer freeTableGrid(allocator, table);
            if (tables.items.len >= TableLimits.regions) return error.TableWorkLimit;
            try tables.append(allocator, table);
        }
        block_index += 1;
    }

    assignPageLocalTableIds(tables.items);
    const result = try allocator.dupe(TableGrid, tables.items);
    tables.deinit(allocator);
    return result;
}

fn freeTableGrid(allocator: std.mem.Allocator, table: TableGrid) void {
    for (table.rows) |row| freeTableRow(allocator, row);
    allocator.free(table.rows);
    if (table.source_span_indices.len > 0) allocator.free(table.source_span_indices);
    if (table.member_block_indices.len > 0) allocator.free(table.member_block_indices);
}

fn compatibleTableFragments(previous: LayoutBlock, next: LayoutBlock, work: *TableWork) !bool {
    const gap = previous.bounds.y0 - next.bounds.y1;
    const scale = @max(1, @max(previous.bounds.font_size, next.bounds.font_size));
    if (gap > scale * 8 or gap < -scale) return false;
    const overlap = @min(previous.bounds.x1, next.bounds.x1) - @max(previous.bounds.x0, next.bounds.x0);
    const width = @min(previous.bounds.x1 - previous.bounds.x0, next.bounds.x1 - next.bounds.x0);
    if (width <= 0 or overlap < width * 0.8) return false;
    var previous_edges: [TableLimits.columns]f64 = undefined;
    var next_edges: [TableLimits.columns]f64 = undefined;
    var previous_left: [TableLimits.columns]f64 = undefined;
    var next_left: [TableLimits.columns]f64 = undefined;
    var previous_count: usize = 0;
    var next_count: usize = 0;
    for (previous.lines) |line| {
        var count: usize = 0;
        for (line.words) |word| {
            try work.spend(1);
            if (!(wordLooksNumeric(word) or wordIsPlaceholder(word)) or count >= previous_edges.len) continue;
            previous_edges[count] = word.bounds.x1;
            previous_left[count] = word.bounds.x0;
            count += 1;
        }
        if (count > 0) previous_count = count;
    }
    for (next.lines) |line| {
        for (line.words) |word| {
            try work.spend(1);
            if (!(wordLooksNumeric(word) or wordIsPlaceholder(word)) or next_count >= next_edges.len) continue;
            next_edges[next_count] = word.bounds.x1;
            next_left[next_count] = word.bounds.x0;
            next_count += 1;
        }
        if (next_count > 0) break;
    }
    if (previous_count == 0 or next_count == 0) return gap <= scale * 2.5;
    var matched: usize = 0;
    var used: [TableLimits.columns]bool = @splat(false);
    for (previous_edges[0..previous_count], previous_left[0..previous_count]) |a, left_a| {
        for (next_edges[0..next_count], next_left[0..next_count], 0..) |b, left_b, index| {
            try work.spend(1);
            if (used[index]) continue;
            if (@abs(a - b) <= @max(6, scale * 0.75) or @abs(left_a - left_b) <= @max(6, scale * 0.75)) {
                used[index] = true;
                matched += 1;
                break;
            }
        }
    }
    return matched >= (@min(previous_count, next_count) + 1) / 2;
}

fn tableFragmentEligible(block: LayoutBlock) bool {
    if (block.removed) return false;
    if (block.kind == .table_candidate) return true;
    if (block.kind != .paragraph or block.lines.len != 1) return false;
    const line = block.lines[0];
    if (line.words.len < 2 or lineWideGapCount(&line) == 0) return false;
    for (line.words) |word| if (wordLooksNumeric(word) or wordIsPlaceholder(word)) return true;
    return false;
}

fn freeTableRow(allocator: std.mem.Allocator, row: TableRow) void {
    for (row.cells) |cell| allocator.free(cell.text);
    allocator.free(row.cells);
}

fn freeTableGrids(allocator: std.mem.Allocator, tables: []const TableGrid) void {
    for (tables) |table| freeTableGrid(allocator, table);
}

const ColumnAnchor = struct {
    x: f64,
    count: usize,
    last_row: usize,
    numeric: bool = false,
    left: f64,
    right: f64,
    right_aligned: bool = false,
};

fn buildTableGridForBlock(
    allocator: std.mem.Allocator,
    block: LayoutBlock,
    block_index: u32,
    work: *TableWork,
) !?TableGrid {
    return buildTableGridForStatement(allocator, block, block_index, null, work);
}

fn buildTableGridForStatement(
    allocator: std.mem.Allocator,
    block: LayoutBlock,
    block_index: u32,
    kinds: ?[]const StatementLineKind,
    work: *TableWork,
) !?TableGrid {
    if (block.lines.len < 2) return null;
    if (block.lines.len > TableLimits.rows) return error.TableWorkLimit;
    if (kinds) |items| if (items.len != block.lines.len) return null;

    var anchors: std.ArrayList(ColumnAnchor) = .empty;
    defer anchors.deinit(allocator);

    const tolerance = @max(6.0, block.bounds.font_size * 0.75);
    var table_line_count: usize = 0;
    var max_words: usize = 0;
    var numeric_rows: usize = 0;
    var body_fields: usize = 0;
    for (block.lines, 0..) |line, row_index| {
        if (kinds) |items| if (items[row_index] == .section or items[row_index] == .prefix or items[row_index] == .suffix or items[row_index] == .note) continue;
        if (!lineContributesColumnAnchors(&line)) continue;
        table_line_count += 1;
        max_words = @max(max_words, line.words.len);
        for (line.words) |word| if (wordLooksNumeric(word) or wordIsPlaceholder(word)) {
            numeric_rows += 1;
            body_fields = @max(body_fields, lineWideGapCount(&line) + 1);
            break;
        };
        try addLineColumnAnchors(allocator, &anchors, &line, tolerance, row_index, work);
    }

    var supported: usize = 0;
    const supported_mask = try allocator.alloc(bool, anchors.items.len);
    defer allocator.free(supported_mask);
    var header_fields: usize = 0;
    if (block.lines.len > 0) {
        const header = block.lines[0];
        var numeric_header = false;
        for (header.words) |word| if (wordLooksNumeric(word) or wordIsPlaceholder(word)) {
            numeric_header = true;
            break;
        };
        if (!numeric_header and lineWideGapCount(&header) >= 1) header_fields = lineWideGapCount(&header) + 1;
    }
    const corroborated_header = numeric_rows >= 2 and header_fields >= 3 and header_fields >= body_fields and header_fields <= body_fields + 1;
    for (anchors.items, 0..) |anchor, index| {
        const minimum: usize = if (anchor.numeric and corroborated_header) 1 else 2;
        supported_mask[index] = anchor.count >= minimum;
        for (anchors.items) |other| {
            try work.spend(1);
            if (anchor.numeric) {
                if (!other.numeric or anchor.right_aligned == other.right_aligned or other.count < minimum) continue;
                if (anchor.left > other.right + 2 or other.left > anchor.right + 2) continue;
                if (other.count > anchor.count or (other.count == anchor.count and other.right_aligned)) supported_mask[index] = false;
            } else {
                if (other.numeric or other.count < 2 or @abs(anchor.x - other.x) > tolerance * 2) continue;
                if (anchor.left >= other.right or other.left >= anchor.right) continue;
                if (other.count > anchor.count or (other.count == anchor.count and other.x < anchor.x)) supported_mask[index] = false;
            }
        }
    }
    // A sectioned statement with one header label field and repeated amount
    // fields has a single stub. Indented detail labels do not create another
    // column. Headers with multiple text fields retain those distinct fields.
    var has_section = false;
    if (kinds) |items| for (items) |kind| {
        if (kind == .section) has_section = true;
    };
    if (has_section) {
        var numeric_columns: usize = 0;
        var first_numeric = std.math.inf(f64);
        for (anchors.items, supported_mask) |anchor, supported_anchor| {
            try work.spend(1);
            if (!supported_anchor or !anchor.numeric) continue;
            numeric_columns += 1;
            first_numeric = @min(first_numeric, anchor.left);
        }
        if (header_fields == numeric_columns + 1) {
            for (anchors.items, supported_mask) |anchor, *supported_anchor| {
                try work.spend(1);
                if (!anchor.numeric and anchor.x < first_numeric and anchor.x > block.lines[0].bounds.x0 + tolerance) supported_anchor.* = false;
            }
        }
    }
    for (anchors.items, 0..) |anchor, index| {
        if (!supported_mask[index]) continue;
        anchors.items[supported] = anchor;
        supported += 1;
    }
    anchors.items.len = supported;
    if (table_line_count < 2 or max_words < 2 or anchors.items.len < 2) return null;
    std.mem.sort(ColumnAnchor, anchors.items, {}, struct {
        fn cmp(_: void, a: ColumnAnchor, b: ColumnAnchor) bool {
            return a.x < b.x;
        }
    }.cmp);

    if (anchors.items[0].numeric) {
        if (kinds) |items| for (items) |kind| {
            // A directed label requires a retained stub column. Reject rather
            // than placing its text into the first amount column.
            if (kind == .section or kind == .prefix or kind == .suffix) return null;
        };
    }
    const column_count = anchors.items.len;
    try work.reserveCells(block.lines.len, column_count);
    var rows: std.ArrayList(TableRow) = .empty;
    errdefer {
        for (rows.items) |row| freeTableRow(allocator, row);
        rows.deinit(allocator);
    }

    var line_index: usize = 0;
    while (line_index < block.lines.len) : (line_index += 1) {
        const line = block.lines[line_index];
        if (line.words.len == 0) continue;
        try work.spend(line.words.len * column_count);
        const kind: StatementLineKind = if (kinds) |items| items[line_index] else .automatic;
        if (kind == .prefix) {
            var target_index = line_index + 1;
            while (target_index < block.lines.len and kinds.?[target_index] == .prefix) : (target_index += 1) {
                try work.spend(1);
            }
            if (target_index == block.lines.len or kinds.?[target_index] != .values) {
                for (rows.items) |row| freeTableRow(allocator, row);
                rows.deinit(allocator);
                return null;
            }
            try work.spend(block.lines[target_index].words.len * column_count);
            var row = try buildTableRow(allocator, block.lines[target_index], anchors.items, block.bounds, @intCast(rows.items.len));
            errdefer freeTableRow(allocator, row);
            var prefix_index = target_index;
            while (prefix_index > line_index) {
                prefix_index -= 1;
                try work.spend(block.lines[prefix_index].words.len * column_count);
                const prefix = try buildTableRowWithRegularLabel(allocator, block.lines[prefix_index], anchors.items, block.bounds, @intCast(rows.items.len), true);
                defer freeTableRow(allocator, prefix);
                for (prefix.cells, 0..) |cell, column_index| {
                    try work.spend(1);
                    if (cell.text.len > 0) try prependCellContinuation(allocator, &row.cells[column_index], cell);
                }
                row.bounds = mergeTwoBounds(prefix.bounds, row.bounds);
            }
            try rows.append(allocator, row);
            line_index = target_index;
            continue;
        }
        const row = if (kind == .note)
            try buildMergedTextRow(allocator, line, anchors.items, block.bounds, @intCast(rows.items.len))
        else
            try buildTableRowWithRegularLabel(allocator, line, anchors.items, block.bounds, @intCast(rows.items.len), kind == .section or kind == .suffix);
        errdefer freeTableRow(allocator, row);
        const occupied_cells = occupiedCellCount(row);
        if (kind == .section or kind == .values or occupied_cells >= 2 or rows.items.len == 0 or rowIsNote(row)) {
            try rows.append(allocator, row);
        } else {
            try mergeContinuationRow(allocator, &rows.items[rows.items.len - 1], row);
            freeTableRow(allocator, row);
        }
    }

    if (rows.items.len < 2) {
        for (rows.items) |row| freeTableRow(allocator, row);
        rows.deinit(allocator);
        return null;
    }

    markFooterRows(rows.items);

    return TableGrid{
        .bounds = block.bounds,
        .block_index = block_index,
        .block_count = 1,
        .rows = try rows.toOwnedSlice(allocator),
        .column_count = column_count,
        .page_index = block.bounds.page_index,
        .confidence = block.confidence,
    };
}

const CellBucket = struct {
    spans: std.ArrayList(TextSpan) = .empty,
};

fn buildRuledTableGrid(
    allocator: std.mem.Allocator,
    blocks: []const LayoutBlock,
    spans: []const TextSpan,
    ruling_lines: []const RulingLine,
    work: *TableWork,
) !?TableGrid {
    if (blocks.len == 0 or ruling_lines.len < 4) return null;

    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(allocator);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(allocator);

    for (ruling_lines) |line| {
        try work.spend(xs.items.len + ys.items.len + 1);
        switch (line.orientation) {
            .vertical => try addCoord(allocator, &xs, (line.bbox.x0 + line.bbox.x1) / 2.0, 2.0),
            .horizontal => try addCoord(allocator, &ys, (line.bbox.y0 + line.bbox.y1) / 2.0, 2.0),
        }
    }
    if (xs.items.len < 2 or ys.items.len < 2) return null;

    std.mem.sort(f64, xs.items, {}, struct {
        fn cmp(_: void, a: f64, b: f64) bool {
            return a < b;
        }
    }.cmp);
    std.mem.sort(f64, ys.items, {}, struct {
        fn cmp(_: void, a: f64, b: f64) bool {
            return a > b;
        }
    }.cmp);

    const column_count = xs.items.len - 1;
    const row_count = ys.items.len - 1;
    if (column_count < 2 or row_count < 1) return null;
    try work.reserveCells(row_count, column_count);

    const grid_bbox = TextSpan.init(.{
        .page_index = blocks[0].bounds.page_index,
        .bbox = .{
            .x0 = xs.items[0],
            .y0 = ys.items[ys.items.len - 1],
            .x1 = xs.items[xs.items.len - 1],
            .y1 = ys.items[0],
        },
        .text = "",
        .source = .table_model,
        .confidence = 0.86,
        .font = .{},
    });

    var first_block_index: ?u32 = null;
    var block_count: usize = 0;
    for (blocks, 0..) |block, block_index| {
        if (!intersectsSpan(block.bounds, grid_bbox)) continue;
        if (first_block_index == null) first_block_index = @intCast(block_index);
        block_count += 1;
    }
    if (block_count == 0) return null;

    var rows: std.ArrayList(TableRow) = .empty;
    errdefer {
        for (rows.items) |row| freeTableRow(allocator, row);
        rows.deinit(allocator);
    }

    for (0..row_count) |row_index| {
        const top = ys.items[row_index];
        const bottom = ys.items[row_index + 1];
        var buckets = try allocator.alloc(CellBucket, column_count);
        defer {
            for (buckets) |*bucket| bucket.spans.deinit(allocator);
            allocator.free(buckets);
        }
        for (buckets) |*bucket| bucket.* = .{};

        // Ruling geometry is a stronger boundary than the deliberately
        // forgiving baseline tolerance used to build layout words. Assign the
        // original spans so raised or wrapped text cannot absorb a neighbor.
        for (spans) |span| {
            try work.spend(1 + column_count + row_count);
            if (!intersectsSpan(span, grid_bbox)) continue;
            const cx = (span.x0 + span.x1) / 2.0;
            const cy = (span.y0 + span.y1) / 2.0;
            if ((rowForY(ys.items, cy) orelse continue) != row_index) continue;
            const col_index = columnForX(xs.items, cx) orelse continue;
            try buckets[col_index].spans.append(allocator, span);
        }

        const cells = cells_block: {
            const built_cells = try allocator.alloc(TableCell, column_count);
            var initialized: usize = 0;
            errdefer {
                for (built_cells[0..initialized]) |cell| allocator.free(cell.text);
                allocator.free(built_cells);
            }
            for (built_cells, 0..) |*cell, column_index| {
                try work.spend(ruling_lines.len * (row_count + column_count));
                const bucket_spans = buckets[column_index].spans.items;
                const text = try ruledCellText(allocator, bucket_spans);
                const cell_bbox = TextSpan.init(.{
                    .page_index = grid_bbox.page_index,
                    .bbox = .{
                        .x0 = xs.items[column_index],
                        .y0 = bottom,
                        .x1 = xs.items[column_index + 1],
                        .y1 = top,
                    },
                    .text = "",
                    .source = .table_model,
                    .confidence = 0.82,
                    .font = .{},
                });
                cell.* = .{
                    .bounds = if (bucket_spans.len > 0) mergeSpanBounds(bucket_spans) else cell_bbox,
                    .text = text,
                    .row_index = @intCast(rows.items.len),
                    .column_index = @intCast(column_index),
                    .rowspan = if (text.len > 0) inferredRowspan(ruling_lines, ys.items, row_index, xs.items[column_index], xs.items[column_index + 1]) else 1,
                    .colspan = inferredColspan(ruling_lines, xs.items, column_index, bottom, top),
                    .role = ruledCellRole(@intCast(row_index), @intCast(column_index), text),
                    .confidence = if (text.len > 0) 0.86 else 0.42,
                };
                initialized += 1;
            }
            break :cells_block built_cells;
        };

        const row = TableRow{
            .bounds = TextSpan.init(.{
                .page_index = grid_bbox.page_index,
                .bbox = .{ .x0 = grid_bbox.x0, .y0 = bottom, .x1 = grid_bbox.x1, .y1 = top },
                .text = "",
                .source = .table_model,
                .confidence = 0.86,
                .font = .{},
            }),
            .cells = cells,
            .row_index = @intCast(rows.items.len),
        };
        var row_transferred = false;
        errdefer if (!row_transferred) freeTableRow(allocator, row);
        var occupied_cells: usize = 0;
        for (row.cells) |cell| if (cell.text.len > 0) {
            occupied_cells += 1;
        };
        if (occupied_cells == 0) {
            freeTableRow(allocator, row);
            continue;
        }
        var max_lines: usize = 1;
        for (buckets) |bucket| {
            try work.spend(bucket.spans.items.len);
            max_lines = @max(max_lines, ruledCellLineCount(bucket.spans.items));
        }
        if (max_lines > 1) try work.reserveCells(max_lines - 1, column_count);
        if (rows.items.len + max_lines > TableLimits.rows) {
            return error.TableWorkLimit;
        }
        row_transferred = true;
        try appendRuledRowOrSplit(allocator, &rows, row, buckets);
    }

    if (rows.items.len == 0) return null;
    markFooterRows(rows.items);

    return TableGrid{
        .bounds = grid_bbox,
        .block_index = first_block_index.?,
        .block_count = block_count,
        .rows = try rows.toOwnedSlice(allocator),
        .column_count = column_count,
        .page_index = grid_bbox.page_index,
        .confidence = 0.86,
        .ruled_region = true,
    };
}

fn addCoord(allocator: std.mem.Allocator, coords: *std.ArrayList(f64), value: f64, tolerance: f64) !void {
    for (coords.items) |*coord| {
        if (@abs(coord.* - value) <= tolerance) {
            coord.* = (coord.* + value) / 2.0;
            return;
        }
    }
    try coords.append(allocator, value);
}

fn intersectsSpan(a: TextSpan, b: TextSpan) bool {
    return a.x0 <= b.x1 and a.x1 >= b.x0 and a.y0 <= b.y1 and a.y1 >= b.y0;
}

fn columnForX(xs: []const f64, x: f64) ?usize {
    if (xs.len < 2 or !std.math.isFinite(x)) return null;
    // Tolerance applies only to the outside edge. Shared rules have one
    // owner: the column to their right, never both adjacent columns.
    if (x < xs[0] - 1.0 or x > xs[xs.len - 1] + 1.0) return null;
    for (0..xs.len - 1) |index| {
        if (x < xs[index + 1] or index == xs.len - 2) return index;
    }
    return null;
}

fn rowForY(ys: []const f64, y: f64) ?usize {
    if (ys.len < 2 or !std.math.isFinite(y)) return null;
    // Coordinates descend in PDF space. A shared horizontal rule belongs
    // to the row below it; the bottom outside edge remains inclusive.
    if (y > ys[0] + 1.0 or y < ys[ys.len - 1] - 1.0) return null;
    for (0..ys.len - 1) |index| {
        if (y > ys[index + 1] or index == ys.len - 2) return index;
    }
    return null;
}

fn ruledCellText(allocator: std.mem.Allocator, spans: []const TextSpan) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (spans) |span| {
        const trimmed = std.mem.trim(u8, span.text, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (text.items.len > 0) try text.append(allocator, ' ');
        try text.appendSlice(allocator, trimmed);
    }
    return text.toOwnedSlice(allocator);
}

fn appendRuledRowOrSplit(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TableRow),
    row: TableRow,
    buckets: []const CellBucket,
) !void {
    errdefer freeTableRow(allocator, row);

    if (rows.items.len == 0) {
        for (row.cells, buckets, 0..) |cell, bucket, column_index| {
            if (cell.colspan <= 1 or ruledCellLineCount(bucket.spans.items) != 2) continue;
            if (column_index + cell.colspan > row.cells.len) continue;
            try appendNestedRuledHeader(allocator, rows, row, buckets, column_index);
            freeTableRow(allocator, row);
            return;
        }
    }

    var split_count: ?usize = null;
    for (row.cells, buckets) |cell, bucket| {
        if (cell.text.len == 0) continue;
        const line_count = ruledCellLineCount(bucket.spans.items);
        if (line_count <= 1) {
            try rows.append(allocator, row);
            return;
        }
        if (split_count) |expected| {
            if (line_count != expected) {
                try rows.append(allocator, row);
                return;
            }
        } else {
            split_count = line_count;
        }
    }

    const count = split_count orelse {
        try rows.append(allocator, row);
        return;
    };
    for (0..count) |line_index| {
        {
            const cells = try allocator.alloc(TableCell, row.cells.len);
            var initialized: usize = 0;
            errdefer {
                for (cells[0..initialized]) |cell| allocator.free(cell.text);
                allocator.free(cells);
            }
            for (row.cells, 0..) |source, column_index| {
                cells[column_index] = source;
                cells[column_index].text = try ruledCellTextLine(allocator, buckets[column_index].spans.items, line_index);
                cells[column_index].row_index = @intCast(rows.items.len);
                initialized += 1;
            }
            const split_row = TableRow{
                .bounds = row.bounds,
                .cells = cells,
                .row_index = @intCast(rows.items.len),
            };
            try rows.append(allocator, split_row);
        }
    }
    freeTableRow(allocator, row);
}

fn appendNestedRuledHeader(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(TableRow),
    row: TableRow,
    buckets: []const CellBucket,
    group_column: usize,
) !void {
    const group_end = group_column + row.cells[group_column].colspan;

    for (0..2) |level| {
        {
            const cells = try allocator.alloc(TableCell, row.cells.len);
            var initialized: usize = 0;
            errdefer {
                for (cells[0..initialized]) |cell| allocator.free(cell.text);
                allocator.free(cells);
            }
            for (row.cells, 0..) |source, column_index| {
                cells[column_index] = source;
                cells[column_index].row_index = @intCast(rows.items.len);
                cells[column_index].role = .header;

                const inside_group = column_index >= group_column and column_index < group_end;
                if (level == 0) {
                    if (column_index == group_column) {
                        cells[column_index].text = try ruledCellTextLine(allocator, buckets[column_index].spans.items, 0);
                    } else if (inside_group) {
                        cells[column_index].text = try allocator.alloc(u8, 0);
                    } else {
                        cells[column_index].text = try allocator.dupe(u8, source.text);
                        if (source.text.len > 0) cells[column_index].rowspan = 2;
                    }
                } else if (inside_group) {
                    cells[column_index].text = if (column_index == group_column)
                        try ruledCellTextLine(allocator, buckets[column_index].spans.items, 1)
                    else
                        try allocator.dupe(u8, source.text);
                    cells[column_index].colspan = 1;
                    cells[column_index].rowspan = 1;
                } else {
                    cells[column_index].text = try allocator.alloc(u8, 0);
                    cells[column_index].colspan = 1;
                    cells[column_index].rowspan = 1;
                }
                initialized += 1;
            }
            const nested_row = TableRow{
                .bounds = row.bounds,
                .cells = cells,
                .row_index = @intCast(rows.items.len),
            };
            try rows.append(allocator, nested_row);
        }
    }
}

fn ruledCellLineCount(spans: []const TextSpan) usize {
    var count: usize = 0;
    var previous_y: ?f64 = null;
    var previous_font_size: f64 = 0;
    for (spans) |span| {
        if (std.mem.trim(u8, span.text, " \t\r\n").len == 0) continue;
        if (previous_y == null or @abs(span.y0 - previous_y.?) > @max(previous_font_size, span.font_size) * 0.7) {
            count += 1;
        }
        previous_y = span.y0;
        previous_font_size = span.font_size;
    }
    return count;
}

fn ruledCellTextLine(allocator: std.mem.Allocator, spans: []const TextSpan, target: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    var line_index: usize = 0;
    var previous_y: ?f64 = null;
    var previous_font_size: f64 = 0;
    for (spans) |span| {
        const trimmed = std.mem.trim(u8, span.text, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (previous_y != null and @abs(span.y0 - previous_y.?) > @max(previous_font_size, span.font_size) * 0.7) {
            line_index += 1;
        }
        if (line_index == target) {
            if (text.items.len > 0) try text.append(allocator, ' ');
            try text.appendSlice(allocator, trimmed);
        }
        previous_y = span.y0;
        previous_font_size = span.font_size;
    }
    return text.toOwnedSlice(allocator);
}

fn inferredColspan(ruling_lines: []const RulingLine, xs: []const f64, column_index: usize, bottom: f64, top: f64) u32 {
    var span: u32 = 1;
    var boundary_index = column_index + 1;
    while (boundary_index < xs.len - 1) : (boundary_index += 1) {
        if (verticalBoundaryCrossesRow(ruling_lines, xs[boundary_index], bottom, top)) break;
        span += 1;
    }
    return span;
}

fn inferredRowspan(ruling_lines: []const RulingLine, ys: []const f64, row_index: usize, left: f64, right: f64) u32 {
    var span: u32 = 1;
    var boundary_index = row_index + 1;
    while (boundary_index < ys.len - 1) : (boundary_index += 1) {
        if (horizontalBoundaryCrossesColumn(ruling_lines, ys[boundary_index], left, right)) break;
        span += 1;
    }
    return span;
}

fn verticalBoundaryCrossesRow(ruling_lines: []const RulingLine, x: f64, bottom: f64, top: f64) bool {
    const mid_y = (bottom + top) / 2.0;
    for (ruling_lines) |line| {
        if (line.orientation != .vertical) continue;
        const line_x = (line.bbox.x0 + line.bbox.x1) / 2.0;
        if (@abs(line_x - x) > 2.0) continue;
        if (line.bbox.y0 <= mid_y + 1.0 and line.bbox.y1 >= mid_y - 1.0) return true;
    }
    return false;
}

fn horizontalBoundaryCrossesColumn(ruling_lines: []const RulingLine, y: f64, left: f64, right: f64) bool {
    const mid_x = (left + right) / 2.0;
    for (ruling_lines) |line| {
        if (line.orientation != .horizontal) continue;
        const line_y = (line.bbox.y0 + line.bbox.y1) / 2.0;
        if (@abs(line_y - y) > 2.0) continue;
        if (line.bbox.x0 <= mid_x + 1.0 and line.bbox.x1 >= mid_x - 1.0) return true;
    }
    return false;
}

fn ruledCellRole(row_index: u32, column_index: u32, text: []const u8) TableCellRole {
    if (text.len > 0 and text[0] == '*') return .note;
    if (row_index == 0) return .header;
    if (column_index == 0) return .row_header;
    return .data;
}

fn lineContributesColumnAnchors(line: *const TextLine) bool {
    if (line.words.len < 2) return false;
    var numeric_words: usize = 0;
    for (line.words) |word| {
        if (wordLooksNumeric(word) or wordIsPlaceholder(word)) numeric_words += 1;
    }
    if (numeric_words > 0) return true;
    return lineLooksLikeTable(line);
}

fn addLineColumnAnchors(
    allocator: std.mem.Allocator,
    anchors: *std.ArrayList(ColumnAnchor),
    line: *const TextLine,
    tolerance: f64,
    row_index: usize,
    work: *TableWork,
) !void {
    var has_numeric = false;
    for (line.words) |word| {
        if (wordLooksNumeric(word) or wordIsPlaceholder(word)) {
            has_numeric = true;
            break;
        }
    }

    if (!has_numeric) {
        for (line.words) |word| try addColumnAnchor(allocator, anchors, word.bounds.x0, word.bounds.x0, word.bounds.x1, false, false, tolerance, row_index, work);
        return;
    }

    var previous_right: ?f64 = null;
    var previous_numeric = false;
    for (line.words) |word| {
        var aligns_existing_field = false;
        for (anchors.items) |anchor| {
            try work.spend(1);
            if (!anchor.numeric and @abs(anchor.x - word.bounds.x0) <= tolerance) aligns_existing_field = true;
        }
        if (wordLooksNumeric(word) or wordIsPlaceholder(word)) {
            try addColumnAnchor(allocator, anchors, word.bounds.x1, word.bounds.x0, word.bounds.x1, true, true, tolerance, row_index, work);
            try addColumnAnchor(allocator, anchors, word.bounds.x0, word.bounds.x0, word.bounds.x1, true, false, tolerance, row_index, work);
        } else if (!wordIsCurrency(word) and (previous_right == null or previous_numeric or aligns_existing_field or word.bounds.x0 - previous_right.? > line.bounds.font_size * 1.8)) {
            try addColumnAnchor(allocator, anchors, word.bounds.x0, word.bounds.x0, word.bounds.x1, false, false, tolerance, row_index, work);
        }
        previous_numeric = wordLooksNumeric(word) or wordIsPlaceholder(word);
        previous_right = word.bounds.x1;
    }
}

fn addColumnAnchor(
    allocator: std.mem.Allocator,
    anchors: *std.ArrayList(ColumnAnchor),
    x: f64,
    left: f64,
    right: f64,
    numeric: bool,
    right_aligned: bool,
    tolerance: f64,
    row_index: usize,
    work: *TableWork,
) !void {
    for (anchors.items) |*anchor| {
        try work.spend(1);
        if (anchor.numeric == numeric and anchor.right_aligned == right_aligned and @abs(anchor.x - x) <= tolerance) {
            anchor.left = @min(anchor.left, left);
            anchor.right = @max(anchor.right, right);
            if (anchor.last_row == row_index) return;
            const old_count_f: f64 = @floatFromInt(anchor.count);
            const new_count = anchor.count + 1;
            anchor.x = ((anchor.x * old_count_f) + x) / @as(f64, @floatFromInt(new_count));
            anchor.count = new_count;
            anchor.last_row = row_index;
            return;
        }
    }
    if (anchors.items.len >= TableLimits.anchors) return error.TableWorkLimit;
    try anchors.append(allocator, .{ .x = x, .left = left, .right = right, .numeric = numeric, .right_aligned = right_aligned, .last_row = row_index, .count = 1 });
}

fn wordLooksNumeric(word: TextWord) bool {
    var saw_digit = false;
    for (word.spans) |span| for (span.text) |byte| {
        if (std.ascii.isDigit(byte)) {
            saw_digit = true;
            continue;
        }
        switch (byte) {
            ' ', '\t', '\r', '\n', ',', '.', '-', '+', '(', ')', '$', '%' => {},
            else => return false,
        }
    };
    return saw_digit;
}

fn wordIsCurrency(word: TextWord) bool {
    return word.spans.len == 1 and std.mem.eql(u8, std.mem.trim(u8, word.spans[0].text, " \t"), "$");
}

fn wordIsPlaceholder(word: TextWord) bool {
    // A literal dash can share a word with a currency symbol and retained
    // padding glyphs. Recognize that field without rewriting its source text.
    if (word.spans.len > 64) return false;
    var byte_count: usize = 0;
    for (word.spans) |span| {
        if (span.text.len > 256 - byte_count) return false;
        byte_count += span.text.len;
    }
    var saw_currency = false;
    var saw_dash = false;
    for (word.spans) |span| for (span.text) |byte| {
        switch (byte) {
            ' ', '\t', '\r', '\n' => {},
            '$' => {
                if (saw_currency or saw_dash) return false;
                saw_currency = true;
            },
            '-' => {
                if (saw_dash) return false;
                saw_dash = true;
            },
            else => return false,
        }
    };
    return saw_dash;
}

fn columnForWord(anchors: []const ColumnAnchor, word: TextWord) usize {
    if (wordLooksNumeric(word) or wordIsCurrency(word) or wordIsPlaceholder(word)) {
        var best: ?usize = null;
        var distance: f64 = std.math.inf(f64);
        for (anchors, 0..) |anchor, index| {
            if (!anchor.numeric) continue;
            const point = if (anchor.right_aligned) word.bounds.x1 else word.bounds.x0;
            const gap = @abs(anchor.x - point);
            if (gap < distance) {
                distance = gap;
                best = index;
            }
        }
        if (best) |index| return index;
    } else {
        for (anchors, 0..) |anchor, index| if (word.bounds.x0 <= anchor.x + 2) return index;
        return anchors.len - 1;
    }
    return nearestColumn(anchors, word.bounds.x0);
}

fn buildTableRow(
    allocator: std.mem.Allocator,
    line: TextLine,
    anchors: []const ColumnAnchor,
    table_bounds: TextSpan,
    row_index: u32,
) !TableRow {
    return buildTableRowWithRegularLabel(allocator, line, anchors, table_bounds, row_index, false);
}

fn buildTableRowWithRegularLabel(
    allocator: std.mem.Allocator,
    line: TextLine,
    anchors: []const ColumnAnchor,
    table_bounds: TextSpan,
    row_index: u32,
    regular_label: bool,
) !TableRow {
    if (!regular_label and lineLooksLikeMergedTextRow(&line, anchors.len, table_bounds)) {
        return buildMergedTextRow(allocator, line, anchors, table_bounds, row_index);
    }

    var texts = try allocator.alloc(std.ArrayList(u8), anchors.len);
    defer allocator.free(texts);
    for (texts) |*text| text.* = .empty;
    defer for (texts) |*text| text.deinit(allocator);

    var bounds = try allocator.alloc(?TextSpan, anchors.len);
    defer allocator.free(bounds);
    @memset(bounds, null);

    var first_numeric: ?usize = null;
    for (line.words, 0..) |word, index| if (wordLooksNumeric(word) or wordIsPlaceholder(word)) {
        first_numeric = index;
        break;
    };
    for (line.words, 0..) |word, index| {
        var column_index = columnForWord(anchors, word);
        if (!anchors[0].numeric and first_numeric != null and index < first_numeric.? and !wordIsCurrency(word)) {
            column_index = 0;
            for (anchors, 0..) |anchor, anchor_index| {
                if (!anchor.numeric and anchor.x <= word.bounds.x0 + 2) column_index = anchor_index;
            }
        }
        if (wordIsCurrency(word) and index + 1 < line.words.len and wordLooksNumeric(line.words[index + 1]) and line.words[index + 1].bounds.x0 - word.bounds.x1 <= line.bounds.font_size * 2) column_index = columnForWord(anchors, line.words[index + 1]);
        if (regular_label) column_index = 0;
        if (texts[column_index].items.len > 0) try texts[column_index].append(allocator, ' ');
        try appendWordText(allocator, &texts[column_index], word);
        bounds[column_index] = if (bounds[column_index]) |existing|
            mergeTwoBounds(existing, word.bounds)
        else
            word.bounds;
    }

    const cells = try allocator.alloc(TableCell, anchors.len);
    var initialized_cell_count: usize = 0;
    errdefer {
        for (cells[0..initialized_cell_count]) |cell| allocator.free(cell.text);
        allocator.free(cells);
    }

    for (cells, 0..) |*cell, column_index| {
        const text = try texts[column_index].toOwnedSlice(allocator);
        cell.* = .{
            .bounds = bounds[column_index] orelse inferredEmptyCellBounds(line, anchors, column_index, table_bounds),
            .text = text,
            .row_index = row_index,
            .column_index = @intCast(column_index),
            .role = heuristicCellRole(row_index, @intCast(column_index), text),
            .confidence = if (text.len > 0) 0.78 else 0.45,
        };
        initialized_cell_count += 1;
    }

    return .{
        .bounds = line.bounds,
        .cells = cells,
        .row_index = row_index,
    };
}

fn lineLooksLikeMergedTextRow(line: *const TextLine, column_count: usize, table_bounds: TextSpan) bool {
    if (column_count < 2 or line.words.len == 0) return false;
    for (line.words) |word| {
        if (wordHasDigit(word) or wordIsPlaceholder(word)) return false;
    }
    const table_width = @max(1, table_bounds.x1 - table_bounds.x0);
    const line_width = line.bounds.x1 - line.bounds.x0;
    return line_width <= table_width * 0.65 or line.words.len < column_count;
}

fn buildMergedTextRow(
    allocator: std.mem.Allocator,
    line: TextLine,
    anchors: []const ColumnAnchor,
    table_bounds: TextSpan,
    row_index: u32,
) !TableRow {
    const cells = try allocator.alloc(TableCell, anchors.len);
    var initialized_cell_count: usize = 0;
    errdefer {
        for (cells[0..initialized_cell_count]) |cell| allocator.free(cell.text);
        allocator.free(cells);
    }

    const target_column = nearestColumn(anchors, line.bounds.x0);
    for (cells, 0..) |*cell, column_index| {
        const text = if (column_index == target_column)
            try lineTextOwned(allocator, &line)
        else
            try allocator.alloc(u8, 0);
        cell.* = .{
            .bounds = if (column_index == target_column) line.bounds else inferredEmptyCellBounds(line, anchors, column_index, table_bounds),
            .text = text,
            .row_index = row_index,
            .column_index = @intCast(column_index),
            .colspan = if (column_index == target_column and text.len > 0) @intCast(anchors.len - target_column) else 1,
            .role = heuristicCellRole(row_index, @intCast(column_index), text),
            .confidence = if (text.len > 0) 0.72 else 0.45,
        };
        initialized_cell_count += 1;
    }

    return .{
        .bounds = line.bounds,
        .cells = cells,
        .row_index = row_index,
    };
}

fn inferredEmptyCellBounds(line: TextLine, anchors: []const ColumnAnchor, column_index: usize, table_bounds: TextSpan) TextSpan {
    const left = if (column_index == 0) table_bounds.x0 else (anchors[column_index - 1].x + anchors[column_index].x) / 2;
    const right = if (column_index + 1 == anchors.len) table_bounds.x1 else (anchors[column_index].x + anchors[column_index + 1].x) / 2;
    return TextSpan.init(.{
        .page_index = line.bounds.page_index,
        .bbox = .{ .x0 = left, .x1 = @max(left + 0.01, right), .y0 = line.bounds.y0, .y1 = @max(line.bounds.y0 + 0.01, line.bounds.y1) },
        .text = "",
        .source = .table_model,
        .confidence = 0.45,
        .font = line.bounds.font,
    });
}

fn heuristicCellRole(row_index: u32, column_index: u32, text: []const u8) TableCellRole {
    if (text.len > 0 and text[0] == '*') return .note;
    if (row_index == 0) return .header;
    if (column_index == 0) return .row_header;
    return .data;
}

fn markFooterRows(rows: []TableRow) void {
    if (rows.len < 3) return;

    var row_index = rows.len;
    while (row_index > 0) {
        row_index -= 1;
        if (rowIsNote(rows[row_index])) continue;
        if (!rowLooksLikeFooter(rows[row_index])) return;
        for (rows[row_index].cells) |*cell| {
            if (cell.text.len > 0) cell.role = .footer;
        }
        return;
    }
}

fn rowLooksLikeFooter(row: TableRow) bool {
    var first_text: ?[]const u8 = null;
    var numeric_count: usize = 0;
    for (row.cells) |cell| {
        if (cell.text.len == 0) continue;
        if (first_text == null) first_text = cell.text;
        if (cellLooksNumeric(cell.text)) numeric_count += 1;
    }
    const label = first_text orelse return false;
    return numeric_count > 0 and startsWithFinancialFooterLabel(label);
}

fn startsWithFinancialFooterLabel(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return startsWithIgnoreCase(trimmed, "total") or
        startsWithIgnoreCase(trimmed, "subtotal") or
        startsWithIgnoreCase(trimmed, "net income") or
        startsWithIgnoreCase(trimmed, "net loss") or
        startsWithIgnoreCase(trimmed, "ending balance");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

fn cellLooksNumeric(text: []const u8) bool {
    var saw_digit = false;
    for (text) |byte| {
        if (std.ascii.isDigit(byte)) {
            saw_digit = true;
            continue;
        }
        switch (byte) {
            ' ', '\t', '\r', '\n', ',', '.', '-', '+', '(', ')', '$', '%' => {},
            else => return false,
        }
    }
    return saw_digit;
}

fn assignPageLocalTableIds(tables: []TableGrid) void {
    for (tables, 0..) |*table, index| {
        table.logical_table_index = @intCast(index);
        table.table_part_index = 0;
        table.continued_from_table_index = null;
        table.continued_to_table_index = null;
    }
}

fn lineTextOwned(allocator: std.mem.Allocator, line: *const TextLine) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendLineText(allocator, &out, line);
    return out.toOwnedSlice(allocator);
}

fn occupiedCellCount(row: TableRow) usize {
    var count: usize = 0;
    for (row.cells) |cell| {
        if (cell.text.len > 0) count += 1;
    }
    return count;
}

fn rowIsNote(row: TableRow) bool {
    for (row.cells) |cell| {
        if (cell.text.len > 0 and cell.role == .note) return true;
    }
    return false;
}

fn mergeContinuationRow(allocator: std.mem.Allocator, target: *TableRow, continuation: TableRow) !void {
    target.bounds = mergeTwoBounds(target.bounds, continuation.bounds);
    for (continuation.cells, 0..) |cell, column_index| {
        if (cell.text.len == 0) continue;
        try appendCellContinuation(allocator, &target.cells[column_index], cell);
    }
}

fn appendCellContinuation(allocator: std.mem.Allocator, target: *TableCell, continuation: TableCell) !void {
    if (target.text.len == 0) {
        const text = try allocator.dupe(u8, continuation.text);
        allocator.free(target.text);
        target.text = text;
        target.bounds = continuation.bounds;
        target.confidence = @min(target.confidence, continuation.confidence);
        return;
    }

    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(allocator);
    try merged.ensureTotalCapacity(allocator, target.text.len + 1 + continuation.text.len);
    try merged.appendSlice(allocator, target.text);
    try merged.append(allocator, ' ');
    try merged.appendSlice(allocator, continuation.text);

    const owned_text = try allocator.dupe(u8, merged.items);
    allocator.free(target.text);
    target.text = owned_text;
    target.bounds = mergeTwoBounds(target.bounds, continuation.bounds);
    target.confidence = @min(target.confidence, continuation.confidence);
}

fn prependCellContinuation(allocator: std.mem.Allocator, target: *TableCell, prefix: TableCell) !void {
    if (target.text.len == 0) return appendCellContinuation(allocator, target, prefix);
    var merged: std.ArrayList(u8) = .empty;
    defer merged.deinit(allocator);
    try merged.ensureTotalCapacity(allocator, prefix.text.len + 1 + target.text.len);
    try merged.appendSlice(allocator, prefix.text);
    try merged.append(allocator, ' ');
    try merged.appendSlice(allocator, target.text);
    const owned_text = try allocator.dupe(u8, merged.items);
    allocator.free(target.text);
    target.text = owned_text;
    target.bounds = mergeTwoBounds(prefix.bounds, target.bounds);
    target.confidence = @min(target.confidence, prefix.confidence);
}

fn nearestColumn(anchors: []const ColumnAnchor, x: f64) usize {
    var best_index: usize = 0;
    var best_distance = @abs(anchors[0].x - x);
    for (anchors[1..], 1..) |anchor, index| {
        const distance = @abs(anchor.x - x);
        if (distance < best_distance) {
            best_distance = distance;
            best_index = index;
        }
    }
    return best_index;
}

fn appendWordText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), word: TextWord) !void {
    for (word.spans) |span| {
        try output.appendSlice(allocator, span.text);
    }
}

fn mergeTwoBounds(a: TextSpan, b: TextSpan) TextSpan {
    return TextSpan.init(.{
        .page_index = a.page_index,
        .bbox = .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        },
        .text = a.text,
        .source = a.source,
        .confidence = @min(a.confidence, b.confidence),
        .font = a.font,
        .block_id = a.block_id,
        .line_id = a.line_id,
        .mcid = a.mcid,
    });
}

fn emptyCellBounds(line: TextLine, column_index: u32) TextSpan {
    _ = column_index;
    return TextSpan.init(.{
        .page_index = line.bounds.page_index,
        .bbox = .{
            .x0 = line.bounds.x0,
            .y0 = line.bounds.y0,
            .x1 = line.bounds.x0,
            .y1 = line.bounds.y1,
        },
        .text = "",
        .source = line.bounds.source,
        .confidence = 0.45,
        .font = line.bounds.font,
        .block_id = line.bounds.block_id,
        .line_id = line.bounds.line_id,
        .mcid = line.bounds.mcid,
    });
}

fn appendTablePlain(allocator: std.mem.Allocator, output: *std.ArrayList(u8), table: *const TableGrid) !void {
    for (table.rows, 0..) |row, row_index| {
        if (row_index > 0) try output.append(allocator, '\n');
        var wrote_cell = false;
        for (row.cells) |cell| {
            if (cell.text.len == 0) continue;
            if (wrote_cell) try output.append(allocator, ' ');
            try appendNormalizedCellText(allocator, output, cell.text);
            wrote_cell = true;
        }
    }
}

fn appendNormalizedCellText(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    var pending_space = false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = output.items.len > 0;
            continue;
        }
        if (pending_space) try output.append(allocator, ' ');
        try output.append(allocator, byte);
        pending_space = false;
    }
}

pub fn appendTableMarkdown(allocator: std.mem.Allocator, output: *std.ArrayList(u8), table: *const TableGrid) !void {
    if (table.rows.len == 0) return;
    try appendMarkdownRow(allocator, output, table.rows[0]);
    try output.append(allocator, '|');
    for (0..table.column_count) |_| try output.appendSlice(allocator, " --- |");
    try output.append(allocator, '\n');
    for (table.rows[1..]) |row| try appendMarkdownRow(allocator, output, row);
}

fn appendMarkdownRow(allocator: std.mem.Allocator, output: *std.ArrayList(u8), row: TableRow) !void {
    try output.append(allocator, '|');
    for (row.cells) |cell| {
        try output.append(allocator, ' ');
        try appendMarkdownEscaped(allocator, output, cell.text);
        try output.appendSlice(allocator, " |");
    }
    try output.append(allocator, '\n');
}

fn appendMarkdownEscaped(allocator: std.mem.Allocator, output: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| {
        if (byte == '|') try output.append(allocator, '\\');
        try output.append(allocator, byte);
    }
}

fn writeJsonEscaped(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        try writeJsonEscapedByte(writer, byte);
    }
}

fn writeJsonEscapedByte(writer: anytype, byte: u8) !void {
    switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (byte < 0x20) {
                try writer.print("\\u00{X:0>2}", .{byte});
            } else {
                try writer.writeByte(byte);
            }
        },
    }
}

fn writeOptionalTableId(writer: anytype, table_index: ?u32) !void {
    if (table_index) |index| {
        try writer.print("\"table-{d}\"", .{index});
    } else {
        try writer.writeAll("null");
    }
}

fn writeNormalizedJsonEscaped(writer: anytype, text: []const u8) !void {
    var previous_space = true;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!previous_space) {
                try writer.writeByte(' ');
                previous_space = true;
            }
        } else {
            try writeJsonEscapedByte(writer, byte);
            previous_space = false;
        }
    }
}

fn writeNumericHint(writer: anytype, text: []const u8) !void {
    if (parseNumericCell(text)) |numeric| {
        try writer.print(
            "{{\"is_numeric\":true,\"value\":{d:.6},\"negative\":{},\"format\":\"{s}\"}}",
            .{ numeric.value, numeric.negative, numeric.format },
        );
    } else {
        try writer.writeAll("{\"is_numeric\":false,\"value\":null,\"negative\":false,\"format\":null}");
    }
}

const NumericCell = struct {
    value: f64,
    negative: bool,
    format: []const u8,
};

fn parseNumericCell(text: []const u8) ?NumericCell {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 96) return null;

    var buf: [128]u8 = undefined;
    var len: usize = 0;
    var saw_digit = false;
    var negative = false;
    var paren_negative = false;
    var minus_negative = false;

    for (trimmed, 0..) |byte, index| {
        switch (byte) {
            '0'...'9' => {
                saw_digit = true;
                buf[len] = byte;
                len += 1;
            },
            '.' => {
                buf[len] = byte;
                len += 1;
            },
            ',', ' ', '\t', '$', '%' => {},
            '(' => {
                if (index != 0) return null;
                negative = true;
                paren_negative = true;
            },
            ')' => {
                if (!paren_negative or index + 1 != trimmed.len) return null;
            },
            '-' => {
                if (len != 0) return null;
                negative = true;
                minus_negative = true;
            },
            '+' => {
                if (len != 0) return null;
            },
            else => return null,
        }
        if (len >= buf.len) return null;
    }
    if (!saw_digit or len == 0) return null;
    const value = std.fmt.parseFloat(f64, buf[0..len]) catch return null;
    return .{
        .value = if (negative) -value else value,
        .negative = negative,
        .format = if (paren_negative) "parentheses" else if (minus_negative) "minus" else "plain",
    };
}

fn endsWithSoftHyphen(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[text.len - 1] != '-') return false;
    if (text.len == 1) return true;
    const prev = text[text.len - 2];
    return std.ascii.isAlphabetic(prev);
}

fn lineStartsLowercase(line: *const TextLine) bool {
    for (line.words) |word| {
        for (word.spans) |span| {
            if (span.text.len == 0) continue;
            return std.ascii.isLower(span.text[0]);
        }
    }
    return false;
}

fn lineTextLen(line: *const TextLine) usize {
    var len: usize = 0;
    for (line.words) |word| {
        for (word.spans) |span| len += span.text.len;
        if (len > 0) len += 1;
    }
    return len;
}

fn firstText(line: *const TextLine) []const u8 {
    for (line.words) |word| {
        for (word.spans) |span| {
            if (span.text.len > 0) return span.text;
        }
    }
    return "";
}

fn lineStartsWithCaption(line: *const TextLine) bool {
    const first = firstText(line);
    return std.mem.startsWith(u8, first, "Figure") or
        std.mem.startsWith(u8, first, "Fig.") or
        std.mem.startsWith(u8, first, "Table") or
        std.mem.startsWith(u8, first, "Chart") or
        std.mem.startsWith(u8, first, "Equation") or
        std.mem.startsWith(u8, first, "Eq.");
}

fn lineStartsWithFigureCaption(line: *const TextLine) bool {
    const first = firstText(line);
    return std.mem.startsWith(u8, first, "Figure") or
        std.mem.startsWith(u8, first, "Fig.") or
        std.mem.startsWith(u8, first, "Chart");
}

fn lineStartsWithListMarker(line: *const TextLine) bool {
    const first = firstText(line);
    if (first.len == 0) return false;
    if (std.mem.eql(u8, first, "-") or std.mem.eql(u8, first, "*")) return true;
    if (std.mem.startsWith(u8, first, "•") or std.mem.startsWith(u8, first, "◦")) return true;
    if (!std.ascii.isDigit(first[0])) return false;

    var i: usize = 1;
    while (i < first.len and i < 4 and std.ascii.isDigit(first[i])) : (i += 1) {}
    return i < first.len and (first[i] == '.' or first[i] == ')');
}

fn lineLooksLikeFormula(line: *const TextLine, body_font_size: f64) bool {
    var text_bytes: usize = 0;
    var math_marks: usize = 0;
    var small_offset_count: usize = 0;

    for (line.words) |word| {
        for (word.spans) |span| {
            text_bytes += span.text.len;
            for (span.text) |byte| {
                if (byte == '=' or byte == '+' or byte == '*' or byte == '/' or byte == '<' or byte == '>' or byte == '^' or byte == '_') {
                    math_marks += 1;
                }
            }
            if (containsMathUnicode(span.text)) math_marks += 2;
            if (span.font_size < body_font_size * 0.82 and @abs(span.y0 - line.baseline_y) > body_font_size * 0.15) {
                small_offset_count += 1;
            }
        }
    }

    if (small_offset_count > 0 and math_marks > 0) return true;
    if (text_bytes == 0) return false;
    return math_marks * 4 >= text_bytes and lineTextLen(line) <= 120;
}

fn containsMathUnicode(text: []const u8) bool {
    const marks = [_][]const u8{ "∑", "∫", "√", "≤", "≥", "≈", "∞", "π", "α", "β", "γ", "Δ" };
    for (marks) |mark| {
        if (std.mem.indexOf(u8, text, mark) != null) return true;
    }
    return false;
}

fn lineLooksLikeTable(line: *const TextLine) bool {
    if (line.words.len < 3) return false;

    var numeric_words: usize = 0;
    for (line.words) |word| {
        if (wordHasDigit(word)) numeric_words += 1;
    }

    return lineWideGapCount(line) >= 2 or numeric_words * 2 >= line.words.len;
}

fn lineWideGapCount(line: *const TextLine) usize {
    if (line.words.len < 2) return 0;
    var wide_gaps: usize = 0;
    var prev_x1 = line.words[0].bounds.x1;
    for (line.words[1..]) |word| {
        const gap = word.bounds.x0 - prev_x1;
        if (gap > line.bounds.font_size * 1.8) wide_gaps += 1;
        prev_x1 = word.bounds.x1;
    }
    return wide_gaps;
}

fn wordHasDigit(word: TextWord) bool {
    for (word.spans) |span| {
        for (span.text) |byte| {
            if (std.ascii.isDigit(byte)) return true;
        }
    }
    return false;
}

fn makeWord(allocator: std.mem.Allocator, spans: []const TextSpan) !TextWord {
    const spans_copy = try allocator.dupe(TextSpan, spans);
    return TextWord{
        .bounds = mergeSpanBounds(spans),
        .spans = spans_copy,
    };
}

fn mergeSpanBounds(spans: []const TextSpan) TextSpan {
    var x0 = spans[0].x0;
    var y0 = spans[0].y0;
    var x1 = spans[0].x1;
    var y1 = spans[0].y1;
    var paint = spans[0].paint;
    var content_scope = spans[0].content_scope;

    for (spans[1..]) |s| {
        x0 = @min(x0, s.x0);
        y0 = @min(y0, s.y0);
        x1 = @max(x1, s.x1);
        y1 = @max(y1, s.y1);
        if (!std.meta.eql(paint, s.paint)) paint = .{};
        if (!std.meta.eql(content_scope, s.content_scope)) content_scope = null;
    }

    return TextSpan.init(.{
        .page_index = spans[0].page_index,
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = spans[0].text,
        .source = spans[0].source,
        .confidence = spans[0].confidence,
        .font = spans[0].font,
        .block_id = spans[0].block_id,
        .line_id = spans[0].line_id,
        .mcid = spans[0].mcid,
        .paint = paint.forBBox(.{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }),
        .content_scope = content_scope,
        .leading_boundary = spans[0].leading_boundary,
    });
}

fn mergeBounds(lines: []const TextLine) TextSpan {
    var x0 = lines[0].bounds.x0;
    var y0 = lines[0].bounds.y0;
    var x1 = lines[0].bounds.x1;
    var y1 = lines[0].bounds.y1;
    var paint = lines[0].bounds.paint;
    var content_scope = lines[0].bounds.content_scope;

    for (lines[1..]) |l| {
        x0 = @min(x0, l.bounds.x0);
        y0 = @min(y0, l.bounds.y0);
        x1 = @max(x1, l.bounds.x1);
        y1 = @max(y1, l.bounds.y1);
        if (!std.meta.eql(paint, l.bounds.paint)) paint = .{};
        if (!std.meta.eql(content_scope, l.bounds.content_scope)) content_scope = null;
    }

    return TextSpan.init(.{
        .page_index = lines[0].bounds.page_index,
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = "",
        .source = lines[0].bounds.source,
        .confidence = lines[0].bounds.confidence,
        .font = lines[0].bounds.font,
        .block_id = lines[0].bounds.block_id,
        .line_id = lines[0].bounds.line_id,
        .mcid = lines[0].bounds.mcid,
        .paint = paint.forBBox(.{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 }),
        .content_scope = content_scope,
        .leading_boundary = lines[0].bounds.leading_boundary,
    });
}

test "TextSpan carries provenance and semantic identity" {
    const span = TextSpan.init(.{
        .page_index = 3,
        .bbox = .{ .x0 = 10, .y0 = 20, .x1 = 30, .y1 = 42 },
        .text = "alpha",
        .source = .native_pdf,
        .confidence = 0.98,
        .font = .{ .name = "F1", .size = 12, .encoding = "WinAnsiEncoding", .has_to_unicode = true },
        .block_id = 7,
        .line_id = 9,
        .mcid = 11,
    });

    try std.testing.expectEqual(@as(u32, 3), span.page_index);
    try std.testing.expectEqual(@as(u32, 3), span.page);
    try std.testing.expectEqual(@as(f64, 10), span.bbox.x0);
    try std.testing.expectEqual(@as(f64, 30), span.x1);
    try std.testing.expectEqual(SourceKind.native_pdf, span.source);
    try std.testing.expectEqual(@as(f32, 0.98), span.confidence);
    try std.testing.expectEqualStrings("F1", span.font.name.?);
    try std.testing.expectEqual(@as(u32, 7), span.block_id.?);
    try std.testing.expectEqual(@as(u32, 9), span.line_id.?);
    try std.testing.expectEqual(@as(i32, 11), span.mcid.?);
}

test "layout bounds preserve homogeneous paint and withhold mixed paint claims" {
    const hidden = TextSpan.init(.{ .bbox = .{ .x0 = 10, .y0 = 10, .x1 = 20, .y1 = 20 }, .text = "A", .paint = .{ .rendering_mode = 3, .paint_state = .non_painting, .clip_state = .unclipped } });
    var second = hidden;
    second.bbox.x0 = 20;
    second.bbox.x1 = 30;
    second.x0 = 20;
    second.x1 = 30;
    const homogeneous = mergeSpanBounds(&.{ hidden, second });
    try std.testing.expect(std.meta.eql(hidden.paint, homogeneous.paint));
    second.paint = .{ .rendering_mode = 0, .paint_state = .painting, .clip_state = .unclipped };
    const mixed = mergeSpanBounds(&.{ hidden, second });
    try std.testing.expectEqual(.unknown, mixed.paint.paint_state);
    try std.testing.expectEqual(@as(?u8, null), mixed.paint.rendering_mode);
}

test "layout bounds preserve scoped origin only when every span shares it" {
    var first = TextSpan.init(.{ .bbox = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 }, .text = "A", .content_scope = .{ .page_index = 3, .stream_object_num = 19, .invocation_index = 1 }, .leading_boundary = .region_break });
    first.page_index = 3;
    var second = first;
    second.text = "B";
    second.leading_boundary = .space;
    const same = mergeSpanBounds(&.{ first, second });
    try std.testing.expect(std.meta.eql(first.content_scope, same.content_scope));
    try std.testing.expectEqual(TextBoundary.region_break, same.leading_boundary.?);
    second.content_scope.?.invocation_index = 2;
    const mixed = mergeSpanBounds(&.{ first, second });
    try std.testing.expectEqual(@as(?form_scope.Scope, null), mixed.content_scope);
}

fn testSpan(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64) TextSpan {
    return TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Body", .size = y1 - y0, .has_to_unicode = true },
    });
}

fn testSpanSized(text: []const u8, x0: f64, y0: f64, x1: f64, y1: f64, size: f64) TextSpan {
    return TextSpan.init(.{
        .bbox = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 },
        .text = text,
        .font = .{ .name = "Body", .size = size, .has_to_unicode = true },
    });
}

fn emptyLayoutAllocationProbe(allocator: std.mem.Allocator) !void {
    var result = try analyzeLayout(allocator, &.{}, 612);
    defer result.deinit();
}

test "empty layout ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        emptyLayoutAllocationProbe,
        .{},
    );
}

fn tableLayoutAllocationProbe(allocator: std.mem.Allocator) !void {
    const spans = [_]TextSpan{
        testSpan("Year", 80, 720, 110, 732),
        testSpan("Revenue", 200, 720, 250, 732),
        testSpan("Margin", 320, 720, 365, 732),
        testSpan("2019", 80, 700, 112, 712),
        testSpan("100", 200, 700, 224, 712),
        testSpan("20", 320, 700, 336, 712),
        testSpan("2020", 80, 680, 112, 692),
        testSpan("125", 200, 680, 224, 692),
        testSpan("23", 320, 680, 336, 692),
    };
    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();
}

test "table layout ownership is safe across every allocation failure" {
    // Refuse resizing deterministically so every fallible fallback allocation
    // is exercised, independent of the backing allocator's remap placement.
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(
        backing.allocator(),
        tableLayoutAllocationProbe,
        .{},
    );
}

test "layout reconstruction clusters lines and dehyphenates paragraphs" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("The", 72, 700, 92, 712),
        testSpan("docu-", 98, 700, 132, 712),
        testSpan("ment", 72, 686, 104, 698),
        testSpan("works.", 110, 686, 150, 698),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.lines.len);
    try std.testing.expectEqual(@as(usize, 1), result.blocks.len);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("The document works.", text);
}

test "ruled table shared boundaries have exactly one band owner" {
    const xs = [_]f64{ 60, 220, 380 };
    const ys = [_]f64{ 720, 680, 640 };
    try std.testing.expectEqual(@as(?usize, 1), columnForX(&xs, 220));
    try std.testing.expectEqual(@as(?usize, 0), columnForX(&xs, 219.9));
    try std.testing.expectEqual(@as(?usize, 1), rowForY(&ys, 680));
    try std.testing.expectEqual(@as(?usize, 0), rowForY(&ys, 680.1));
    try std.testing.expectEqual(@as(?usize, 1), rowForY(&ys, 679.9));
    try std.testing.expectEqual(@as(?usize, 1), rowForY(&ys, 640));
    try std.testing.expectEqual(@as(?usize, null), rowForY(&ys, 638));
    try std.testing.expectEqual(@as(?usize, null), columnForX(&xs, std.math.nan(f64)));
}

test "ruled table text crossing a rule is not duplicated into adjacent rows" {
    const spans = [_]TextSpan{
        testSpan("Account", 70, 698, 115, 710),
        testSpan("Amount", 230, 698, 275, 710),
        testSpan("Boundary", 70, 674, 125, 686),
        testSpan("0", 230, 655, 240, 667),
    };
    const rulings = [_]RulingLine{
        .{ .orientation = .vertical, .bbox = .{ .x0 = 60, .x1 = 60, .y0 = 640, .y1 = 720 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 220, .x1 = 220, .y0 = 640, .y1 = 720 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 380, .x1 = 380, .y0 = 640, .y1 = 720 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 60, .x1 = 380, .y0 = 720, .y1 = 720 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 60, .x1 = 380, .y0 = 680, .y1 = 680 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 60, .x1 = 380, .y0 = 640, .y1 = 640 } },
    };
    var result = try analyzeLayoutWithRulings(std.testing.allocator, &spans, 612, &rulings);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    try std.testing.expectEqualStrings("Account", result.tables[0].rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Boundary", result.tables[0].rows[1].cells[0].text);
}

test "layout reconstruction records two columns in reading order" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("L1", 72, 700, 90, 712),
        testSpan("R1", 330, 700, 348, 712),
        testSpan("L2", 72, 680, 90, 692),
        testSpan("R2", 330, 680, 348, 692),
        testSpan("L3", 72, 660, 90, 672),
        testSpan("R3", 330, 660, 348, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.columns.len);
    try std.testing.expectEqual(@as(u32, 0), result.reading_order[0]);
    try std.testing.expectEqual(@as(u32, 1), result.reading_order[1]);

    const text = try result.getTextInOrder(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("L1\nL2\nL3\nR1\nR2\nR3", text);
}

test "layout reconstruction does not split table-heavy rows into page columns" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Date", 76, 708, 104, 720),
        testSpan("Description", 132, 708, 206, 720),
        testSpan("Debit", 292, 708, 326, 720),
        testSpan("Credit", 372, 708, 414, 720),
        testSpan("Balance", 456, 708, 506, 720),
        testSpan("01/02", 76, 682, 116, 694),
        testSpan("Payroll", 132, 682, 182, 694),
        testSpan("ACME", 184, 682, 218, 694),
        testSpan("2,450", 372, 682, 412, 694),
        testSpan("4,100", 456, 682, 496, 694),
        testSpan("01/03", 76, 656, 116, 668),
        testSpan("Rent", 132, 656, 162, 668),
        testSpan("(1,200)", 292, 656, 342, 668),
        testSpan("2,900", 456, 656, 496, 668),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.columns.len);
    try std.testing.expect(result.lines[0].words.len >= 5);
    try std.testing.expect(result.tables.len >= 1);
}

test "aligned numbered rows are classified as a borderless table" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Clause", 76, 708, 112, 720),
        testSpan("Party", 180, 708, 214, 720),
        testSpan("Amount", 282, 708, 328, 720),
        testSpan("Notes", 360, 708, 394, 720),
        testSpan("1.1", 76, 680, 96, 692),
        testSpan("Seller", 180, 680, 218, 692),
        testSpan("1,000", 282, 680, 322, 692),
        testSpan("Escrow release", 360, 680, 448, 692),
        testSpan("2.4", 76, 652, 96, 664),
        testSpan("Buyer", 180, 652, 214, 664),
        testSpan("(250)", 282, 652, 322, 664),
        testSpan("Credit memo", 360, 652, 430, 664),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    try std.testing.expectEqual(@as(usize, 3), result.tables[0].rows.len);
    try std.testing.expectEqualStrings("1.1", result.tables[0].rows[1].cells[0].text);
    try std.testing.expectEqualStrings("Escrow release", result.tables[0].rows[1].cells[3].text);
}

test "layout reconstruction detects headings and list items" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpanSized("A", 72, 720, 82, 738, 18),
        testSpanSized("Heading", 90, 720, 160, 738, 18),
        testSpan("Body", 72, 690, 104, 702),
        testSpan("text", 110, 690, 136, 702),
        testSpan("1.", 72, 660, 86, 672),
        testSpan("First", 96, 660, 126, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(LineRole.heading, result.lines[0].role);
    try std.testing.expectEqual(LineRole.list_item, result.lines[2].role);
    try std.testing.expectEqual(BlockKind.heading, result.blocks[0].kind);
}

test "layout reconstruction suppresses header and footer candidates" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Chapter", 72, 760, 122, 772),
        testSpan("The", 72, 700, 92, 712),
        testSpan("body", 98, 700, 130, 712),
        testSpan("continues", 72, 682, 128, 694),
        testSpan("42", 300, 60, 314, 72),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(LineRole.header, result.lines[0].role);
    try std.testing.expectEqual(LineRole.footer, result.lines[result.lines.len - 1].role);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Chapter") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "42") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "The body continues") != null);
}

test "layout reconstruction emits table formula and figure candidates" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Body", 72, 740, 106, 752),
        testSpan("intro", 112, 740, 146, 752),
        testSpan("Table", 72, 720, 112, 732),
        testSpan("1.", 118, 720, 132, 732),
        testSpan("2019", 72, 700, 104, 712),
        testSpan("120", 180, 700, 204, 712),
        testSpan("240", 300, 700, 324, 712),
        testSpan("E", 72, 660, 80, 672),
        testSpan("=", 86, 660, 92, 672),
        testSpan("mc", 98, 660, 114, 672),
        testSpanSized("2", 116, 668, 122, 674, 7),
        testSpan("Figure", 72, 620, 112, 632),
        testSpan("1.", 118, 620, 132, 632),
        testSpan("System", 138, 620, 180, 632),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    var saw_table = false;
    var saw_formula = false;
    var saw_figure = false;
    for (result.candidates) |candidate| {
        switch (candidate.kind) {
            .table => {
                saw_table = true;
                try std.testing.expect(candidate.caption_line_index != null);
                try std.testing.expect(candidate.caption_block_index != null);
            },
            .formula => saw_formula = true,
            .figure => {
                saw_figure = true;
                try std.testing.expectEqual(candidate.line_index, candidate.caption_line_index.?);
            },
        }
    }

    try std.testing.expect(saw_table);
    try std.testing.expect(saw_formula);
    try std.testing.expect(saw_figure);
}

test "layout reconstruction builds table grid cells from aligned financial rows" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Table", 72, 740, 112, 752),
        testSpan("1.", 118, 740, 132, 752),
        testSpan("Year", 80, 720, 110, 732),
        testSpan("Revenue", 200, 720, 250, 732),
        testSpan("Margin", 320, 720, 365, 732),
        testSpan("2019", 80, 700, 112, 712),
        testSpan("100", 200, 700, 224, 712),
        testSpan("20", 320, 700, 336, 712),
        testSpan("2020", 80, 680, 112, 692),
        testSpan("125", 200, 680, 224, 692),
        testSpan("23", 320, 680, 336, 692),
        testSpan("2021", 80, 660, 112, 672),
        testSpan("140", 200, 660, 224, 672),
        testSpan("25", 320, 660, 336, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("Year", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Revenue", table.rows[0].cells[1].text);
    try std.testing.expectEqualStrings("Margin", table.rows[0].cells[2].text);
    try std.testing.expectEqualStrings("2021", table.rows[3].cells[0].text);
    try std.testing.expectEqualStrings("140", table.rows[3].cells[1].text);
    try std.testing.expectEqualStrings("25", table.rows[3].cells[2].text);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Year Revenue Margin") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2021 140 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "YearRevenueMargin") == null);

    var markdown: std.ArrayList(u8) = .empty;
    defer markdown.deinit(allocator);
    try appendTableMarkdown(allocator, &markdown, &table);
    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "| Year | Revenue | Margin |") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown.items, "| 2021 | 140 | 25 |") != null);
}

test "table grid merges multiline labels negatives and footnotes into cells" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Account", 80, 720, 130, 732),
        testSpan("Revenue", 190, 720, 242, 732),
        testSpan("Variance", 280, 720, 336, 732),
        testSpan("Subscriptions", 80, 700, 164, 712),
        testSpan("1,200", 190, 700, 230, 712),
        testSpan("(35)", 280, 700, 312, 712),
        testSpan("North America", 94, 686, 184, 698),
        testSpan("Services*", 80, 666, 144, 678),
        testSpan("-250", 190, 666, 222, 678),
        testSpan("12", 280, 666, 296, 678),
        testSpan("* excludes setup fees", 94, 652, 220, 664),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("Account", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Subscriptions North America", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("(35)", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("Services*", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("-250", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("12", table.rows[2].cells[2].text);
    try std.testing.expectEqualStrings("* excludes setup fees", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.note, table.rows[3].cells[0].role);
    try std.testing.expectEqual(@as(u32, 3), table.rows[3].cells[0].colspan);

    const text = try result.getReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Subscriptions North America 1,200 (35)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Services* -250 12\n* excludes setup fees") != null);
}

test "table grid preserves multiword merged labels without inventing columns" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Account", 80, 720, 130, 732),
        testSpan("Revenue", 180, 720, 232, 732),
        testSpan("Expense", 260, 720, 310, 732),
        testSpan("Net", 320, 720, 344, 732),
        testSpan("Total", 80, 700, 116, 712),
        testSpan("revenue", 122, 700, 174, 712),
        testSpan("1,200", 180, 700, 220, 712),
        testSpan("(950)", 260, 700, 300, 712),
        testSpan("250", 320, 700, 344, 712),
        testSpan("Services*", 80, 680, 144, 692),
        testSpan("-300", 180, 680, 212, 692),
        testSpan("(450)", 260, 680, 300, 692),
        testSpan("(750)", 320, 680, 360, 692),
        testSpan("*", 94, 666, 100, 678),
        testSpan("excludes", 108, 666, 160, 678),
        testSpan("setup", 168, 666, 206, 678),
        testSpan("fees", 214, 666, 244, 678),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 4), table.column_count);
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("Account", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Revenue", table.rows[0].cells[1].text);
    try std.testing.expectEqualStrings("Expense", table.rows[0].cells[2].text);
    try std.testing.expectEqualStrings("Net", table.rows[0].cells[3].text);
    try std.testing.expectEqualStrings("Total revenue", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("(950)", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("250", table.rows[1].cells[3].text);
    try std.testing.expectEqualStrings("Services*", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("-300", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("(450)", table.rows[2].cells[2].text);
    try std.testing.expectEqualStrings("(750)", table.rows[2].cells[3].text);
    try std.testing.expectEqualStrings("* excludes setup fees", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.note, table.rows[3].cells[0].role);
    try std.testing.expectEqual(@as(u32, 4), table.rows[3].cells[0].colspan);
}

test "table grid marks bottom financial total rows as footer" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Account", 80, 720, 130, 732),
        testSpan("Actual", 200, 720, 242, 732),
        testSpan("Budget", 300, 720, 346, 732),
        testSpan("Cash", 80, 700, 112, 712),
        testSpan("1,000", 200, 700, 240, 712),
        testSpan("900", 300, 700, 324, 712),
        testSpan("Debt", 80, 680, 112, 692),
        testSpan("(200)", 200, 680, 240, 692),
        testSpan("(175)", 300, 680, 340, 692),
        testSpan("Total assets", 80, 660, 154, 672),
        testSpan("800", 200, 660, 224, 672),
        testSpan("725", 300, 660, 324, 672),
    };

    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqualStrings("Total assets", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.footer, table.rows[3].cells[0].role);
    try std.testing.expectEqual(TableCellRole.footer, table.rows[3].cells[1].role);
    try std.testing.expectEqual(TableCellRole.footer, table.rows[3].cells[2].role);
}

test "native layout identity survives sorting from unassigned input spans" {
    const spans = [_]TextSpan{ testSpan("Lower", 20, 100, 60, 112), testSpan("Upper", 20, 300, 60, 312) };
    var result = try analyzeLayout(std.testing.allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(?u32, null), spans[0].native_source_index);
    try std.testing.expectEqual(@as(?u32, 1), result.spans[0].native_source_index);
    try std.testing.expectEqual(@as(?u32, 0), result.spans[1].native_source_index);
}

test "connected L-shaped invoice outlines retain wrapped cells and separate footer rows" {
    const spans = [_]TextSpan{
        testSpan("Item", 76, 708, 100, 720),              testSpan("Description", 132, 708, 198, 720), testSpan("Qty", 318, 708, 336, 720),
        testSpan("Unit", 372, 708, 396, 720),             testSpan("Total", 456, 708, 486, 720),       testSpan("A-1", 76, 682, 94, 694),
        testSpan("Implementation", 132, 686, 216, 698),   testSpan("services", 132, 670, 180, 682),    testSpan("2", 318, 678, 324, 690),
        testSpan("1,250", 372, 678, 402, 690),            testSpan("2,500", 456, 678, 486, 690),       testSpan("B-9", 76, 642, 94, 654),
        testSpan("Support retainer", 132, 642, 228, 654), testSpan("1", 318, 642, 324, 654),           testSpan("850", 372, 642, 390, 654),
        testSpan("850", 456, 642, 474, 654),              testSpan("Subtotal", 372, 604, 420, 616),    testSpan("3,350", 456, 604, 486, 616),
        testSpan("Tax", 372, 584, 390, 596),              testSpan("268", 456, 584, 474, 596),         testSpan("Total", 372, 564, 402, 576),
        testSpan("3,618", 456, 564, 486, 576),
    };
    const rules = [_]RulingLine{
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 72, .y0 = 724, .x1 = 524, .y1 = 724 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 72, .y0 = 696, .x1 = 524, .y1 = 696 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 72, .y0 = 658, .x1 = 524, .y1 = 658 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 72, .y0 = 626, .x1 = 524, .y1 = 626 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 360, .y0 = 616, .x1 = 524, .y1 = 616 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 360, .y0 = 556, .x1 = 524, .y1 = 556 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 72, .y0 = 626, .x1 = 72, .y1 = 724 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 120, .y0 = 626, .x1 = 120, .y1 = 724 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 304, .y0 = 626, .x1 = 304, .y1 = 724 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 360, .y0 = 556, .x1 = 360, .y1 = 724 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 444, .y0 = 556, .x1 = 444, .y1 = 724 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 524, .y0 = 556, .x1 = 524, .y1 = 724 } },
    };
    try std.testing.expect(!componentHasOuterBorder(&rules));
    var result = try analyzeLayoutWithRulings(std.testing.allocator, &spans, 612, &rules);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.tables.len);
    const main = result.tables[0];
    const footer = result.tables[1];
    try std.testing.expect(main.ruled_region and footer.ruled_region);
    try std.testing.expectEqual(@as(usize, 5), main.column_count);
    try std.testing.expectEqual(@as(usize, 3), main.rows.len);
    try std.testing.expectEqualStrings("A-1", main.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("Implementation services", main.rows[1].cells[1].text);
    try std.testing.expectEqual(@as(usize, 2), footer.column_count);
    try std.testing.expectEqual(@as(usize, 3), footer.rows.len);
    for (footer.rows, [_][]const u8{ "Subtotal", "Tax", "Total" }) |row, label| try std.testing.expectEqualStrings(label, row.cells[0].text);
    try std.testing.expectEqual(@as(usize, 16), main.source_span_indices.len);
    try std.testing.expectEqual(@as(usize, 6), footer.source_span_indices.len);
    for (main.source_span_indices) |id| try std.testing.expect(!containsSourceIndex(footer.source_span_indices, id));
    // Native ruling extraction retains the stroke envelope around the segment
    // centerline. It must yield the same regions as zero-width geometry.
    var stroked_rules = rules;
    for (&stroked_rules) |*line| {
        if (line.orientation == .horizontal) {
            line.bbox.y0 -= 0.25;
            line.bbox.y1 += 0.25;
        } else {
            line.bbox.x0 -= 0.25;
            line.bbox.x1 += 0.25;
        }
    }
    var stroked = try analyzeLayoutWithRulings(std.testing.allocator, &spans, 612, &stroked_rules);
    defer stroked.deinit();
    try std.testing.expectEqual(result.tables.len, stroked.tables.len);
    for (result.tables, stroked.tables) |expected, actual| {
        try std.testing.expectEqual(expected.column_count, actual.column_count);
        try std.testing.expectEqual(expected.rows.len, actual.rows.len);
        try std.testing.expectEqualSlices(u32, expected.source_span_indices, actual.source_span_indices);
        for (expected.rows, actual.rows) |expected_row, actual_row| for (expected_row.cells, actual_row.cells) |expected_cell, actual_cell| try std.testing.expectEqualStrings(expected_cell.text, actual_cell.text);
    }
    // Real path joints may miss by a point while still satisfying the bounded
    // border tolerance. An admitted outer axis must survive region clipping.
    stroked_rules[6].bbox.x0 -= 1;
    stroked_rules[6].bbox.x1 -= 1;
    stroked_rules[0].bbox.y0 += 1;
    stroked_rules[0].bbox.y1 += 1;
    var perturbed = try analyzeLayoutWithRulings(std.testing.allocator, &spans, 612, &stroked_rules);
    defer perturbed.deinit();
    try std.testing.expectEqual(result.tables.len, perturbed.tables.len);
    for (result.tables, perturbed.tables) |expected, actual| {
        try std.testing.expectEqual(expected.column_count, actual.column_count);
        try std.testing.expectEqual(expected.rows.len, actual.rows.len);
        try std.testing.expectEqualSlices(u32, expected.source_span_indices, actual.source_span_indices);
        for (expected.rows, actual.rows) |expected_row, actual_row| for (expected_row.cells, actual_row.cells) |expected_cell, actual_cell| try std.testing.expectEqualStrings(expected_cell.text, actual_cell.text);
    }
}

test "component subregions require continuous finite outer borders" {
    var rules = [_]RulingLine{
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 50, .y0 = 700, .x1 = 250, .y1 = 700 } },
        .{ .orientation = .horizontal, .bbox = .{ .x0 = 50, .y0 = 600, .x1 = 250, .y1 = 600 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 50, .y0 = 615, .x1 = 50, .y1 = 700 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 250, .y0 = 600, .x1 = 250, .y1 = 700 } },
        .{ .orientation = .vertical, .bbox = .{ .x0 = 150, .y0 = 600, .x1 = 150, .y1 = 700 } },
    };
    const spans = [_]TextSpan{
        testSpan("A", 60, 670, 70, 680), testSpan("1", 180, 670, 190, 680),
        testSpan("B", 60, 630, 70, 640), testSpan("2", 180, 630, 190, 640),
    };
    const blocks = [_]LayoutBlock{.{ .bounds = testSpan("", 50, 600, 250, 700), .lines = &.{}, .column_index = 0, .kind = .table_candidate }};
    var work: TableWork = .{};
    var tables: std.ArrayList(TableGrid) = .empty;
    defer {
        freeTableGrids(std.testing.allocator, tables.items);
        tables.deinit(std.testing.allocator);
    }
    try appendClosedComponentRegions(std.testing.allocator, &tables, &blocks, &spans, &rules, &work);
    try std.testing.expectEqual(@as(usize, 0), tables.items.len);
    // The same populated region must promote when its missing edge is restored;
    // empty input or a one-column rejection cannot mask the negative control.
    rules[2].bbox.y0 = 600;
    try appendClosedComponentRegions(std.testing.allocator, &tables, &blocks, &spans, &rules, &work);
    try std.testing.expectEqual(@as(usize, 1), tables.items.len);
    try std.testing.expectEqual(@as(usize, 2), tables.items[0].rows.len);
    try std.testing.expectEqual(@as(usize, 2), tables.items[0].column_count);
    const expected = [_][2][]const u8{ .{ "A", "1" }, .{ "B", "2" } };
    for (tables.items[0].rows, expected) |row, values| for (row.cells, values) |cell, text| try std.testing.expectEqualStrings(text, cell.text);
}

fn regionalTableAllocationProbe(allocator: std.mem.Allocator) !void {
    const spans = [_]TextSpan{
        testSpan("Item", 60, 645, 90, 655),     testSpan("Value", 165, 645, 200, 655),
        testSpan("First", 60, 625, 90, 635),    testSpan("10", 180, 625, 200, 635),
        testSpan("Second", 60, 605, 100, 615),  testSpan("0", 190, 605, 200, 615),
        testSpan("Between", 60, 560, 110, 572), testSpan("Name", 60, 505, 90, 515),
        testSpan("Count", 165, 505, 200, 515),  testSpan("Third", 60, 485, 90, 495),
        testSpan("9", 190, 485, 200, 495),      testSpan("Fourth", 60, 465, 100, 475),
        testSpan("1", 190, 465, 200, 475),
    };
    const rules = [_]RulingLine{
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 660, .y1 = 660 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 640, .y1 = 640 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 620, .y1 = 620 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 600, .y1 = 600 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 50, .y0 = 600, .y1 = 660 }, .orientation = .vertical },
        .{ .bbox = .{ .x0 = 150, .x1 = 150, .y0 = 600, .y1 = 660 }, .orientation = .vertical },
        .{ .bbox = .{ .x0 = 250, .x1 = 250, .y0 = 600, .y1 = 660 }, .orientation = .vertical },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 520, .y1 = 520 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 500, .y1 = 500 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 480, .y1 = 480 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 250, .y0 = 460, .y1 = 460 }, .orientation = .horizontal },
        .{ .bbox = .{ .x0 = 50, .x1 = 50, .y0 = 460, .y1 = 520 }, .orientation = .vertical },
        .{ .bbox = .{ .x0 = 150, .x1 = 150, .y0 = 460, .y1 = 520 }, .orientation = .vertical },
        .{ .bbox = .{ .x0 = 250, .x1 = 250, .y0 = 460, .y1 = 520 }, .orientation = .vertical },
    };
    var result = try analyzeLayoutWithRulings(allocator, &spans, 612, &rules);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.tables.len);
    try std.testing.expectEqual(@as(u32, 0), result.tables[0].region_index);
    try std.testing.expectEqual(@as(u32, 1), result.tables[1].region_index);
    try std.testing.expectEqual(@as(usize, 6), result.tables[0].source_span_indices.len);
    try std.testing.expectEqual(@as(usize, 6), result.tables[1].source_span_indices.len);
    try std.testing.expectEqual(@as(?usize, null), result.tableRegionForSpan(result.spans[6]));
    const text = try result.getCompleteReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Between") != null);
}

test "disconnected finite grids have exclusive members and preserve intervening prose" {
    try regionalTableAllocationProbe(std.testing.allocator);
}

test "regional table ownership rolls back every allocation failure" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), regionalTableAllocationProbe, .{});
}

test "table ruling limit falls back without suppressing native source" {
    const spans = [_]TextSpan{testSpan("Preserved", 20, 300, 100, 312)};
    var rules: [TableLimits.rulings + 1]RulingLine = undefined;
    @memset(&rules, .{ .bbox = .{}, .orientation = .horizontal });
    var result = try analyzeLayoutWithRulings(std.testing.allocator, &spans, 612, &rules);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.tables.len);
    try std.testing.expectEqualStrings("Preserved", result.spans[0].text);
}

test "continuation allocation failure retains the live original cell buffer" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2, .resize_fail_index = 0 });
    const allocator = failing.allocator();
    const bounds = testSpan("", 10, 20, 90, 32);
    var target = TableCell{ .bounds = bounds, .text = try allocator.dupe(u8, "Original"), .row_index = 0, .column_index = 0 };
    defer allocator.free(target.text);
    const original_ptr = target.text.ptr;
    const continuation = TableCell{ .bounds = bounds, .text = "continued", .row_index = 1, .column_index = 0 };
    try std.testing.expectError(error.OutOfMemory, appendCellContinuation(allocator, &target, continuation));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(target.text.ptr == original_ptr);
    try std.testing.expectEqualStrings("Original", target.text);
}

test "owned table projection preserves ordinary paragraph joins and surrounding styles" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "Key", "Value", "A", "10", "Before", "dehyphen-", "ated", "After" };
    var spans: [names.len]TextSpan = undefined;
    var words: [names.len]TextWord = undefined;
    for (&spans, &words, names, 0..) |*span, *word, name, index| {
        span.* = testSpan(name, 10, 100, 80, 112);
        span.native_source_index = @intCast(index);
        word.* = .{ .bounds = span.*, .spans = spans[index .. index + 1] };
    }
    var cells: [4]TableCell = undefined;
    for (&cells, 0..) |*cell, index| cell.* = .{ .bounds = spans[index], .text = names[index], .row_index = @intCast(index / 2), .column_index = @intCast(index % 2) };
    var rows = [_]TableRow{
        .{ .bounds = spans[0], .cells = cells[0..2], .row_index = 0 }, .{ .bounds = spans[2], .cells = cells[2..4], .row_index = 1 },
    };
    const tables = [_]TableGrid{.{ .bounds = spans[0], .block_index = 1, .rows = &rows, .column_count = 2, .source_span_indices = &.{ 0, 1, 2, 3 }, .member_block_indices = &.{1}, .projection_eligible = true }};
    const lines = [_]TextLine{
        .{ .bounds = spans[4], .words = words[4..5], .baseline_y = 100 },
        .{ .bounds = spans[0], .words = words[0..4], .baseline_y = 100 },
        .{ .bounds = spans[5], .words = words[5..6], .baseline_y = 100 },
        .{ .bounds = spans[6], .words = words[6..7], .baseline_y = 100 },
        .{ .bounds = spans[7], .words = words[7..8], .baseline_y = 100 },
    };
    const blocks = [_]LayoutBlock{
        .{ .bounds = spans[4], .lines = lines[0..1], .column_index = 0, .kind = .heading },
        .{ .bounds = spans[0], .lines = lines[1..2], .column_index = 0, .kind = .table_candidate },
        .{ .bounds = spans[5], .lines = lines[2..4], .column_index = 0, .kind = .paragraph },
        .{ .bounds = spans[7], .lines = lines[4..5], .column_index = 0, .kind = .list_item },
    };
    const result = LayoutResult{ .allocator = allocator, .spans = &spans, .lines = &lines, .columns = &.{}, .paragraphs = &.{}, .blocks = &blocks, .tables = &tables, .candidates = &.{}, .reading_order = &.{} };
    const plain = try result.getCompleteReconstructedText(allocator);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("Before\n\nKey Value\nA 10\n\ndehyphenated\n\nAfter", plain);
    const markdown = try result.getRegionText(allocator, true, false);
    defer allocator.free(markdown);
    try std.testing.expectEqualStrings("## Before\n\n| Key | Value |\n| --- | --- |\n| A | 10 |\n\ndehyphen- ated\n\n- After\n", markdown);
    var mixed_block = blocks[1];
    mixed_block.kind = .paragraph;
    mixed_block.lines = lines[1..4];
    const mixed_blocks = [_]LayoutBlock{ blocks[0], mixed_block, blocks[3] };
    var mixed = result;
    mixed.blocks = &mixed_blocks;
    const mixed_plain = try mixed.getCompleteReconstructedText(allocator);
    defer allocator.free(mixed_plain);
    try std.testing.expectEqualStrings(plain, mixed_plain);
    const mixed_markdown = try mixed.getRegionText(allocator, true, false);
    defer allocator.free(mixed_markdown);
    try std.testing.expectEqualStrings(markdown, mixed_markdown);
}

test "native field bands preserve separate text fields before numeric columns" {
    const spans = [_]TextSpan{
        testSpan("Date", 76, 700, 104, 712),         testSpan("01/02", 76, 660, 116, 672),     testSpan("01/03", 76, 620, 116, 632),
        testSpan("Description", 132, 700, 206, 712), testSpan("Payroll ", 132, 660, 180, 672), testSpan("ACME", 184, 660, 218, 672),
        testSpan("Rent", 132, 620, 162, 632),        testSpan("Amount", 300, 700, 346, 712),   testSpan("1,200", 310, 660, 350, 672),
        testSpan("0", 342, 620, 350, 632),
    };
    var result = try analyzeLayout(std.testing.allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqualStrings("Date", table.rows[0].cells[0].text);
    try std.testing.expectEqualStrings("Description", table.rows[0].cells[1].text);
    try std.testing.expectEqualStrings("Amount", table.rows[0].cells[2].text);
    try std.testing.expectEqualStrings("01/02", table.rows[1].cells[0].text);
    try std.testing.expectEqualStrings("Payroll ACME", table.rows[1].cells[1].text);
    try std.testing.expectEqualStrings("1,200", table.rows[1].cells[2].text);
    try std.testing.expectEqualStrings("01/03", table.rows[2].cells[0].text);
    try std.testing.expectEqualStrings("Rent", table.rows[2].cells[1].text);
    try std.testing.expectEqualStrings("0", table.rows[2].cells[2].text);
}

test "native header corroborates a sparse populated column without turning blank into zero" {
    const spans = [_]TextSpan{
        testSpan("Task", 62, 700, 90, 712), testSpan("Due", 348, 700, 366, 712), testSpan("Done", 448, 700, 472, 712),
        testSpan("Load", 62, 660, 90, 672), testSpan("17", 410, 660, 424, 672),  testSpan("15", 510, 660, 524, 672),
        testSpan("Ship", 62, 620, 90, 632), testSpan("0", 516, 620, 524, 632),
    };
    var result = try analyzeLayout(std.testing.allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    try std.testing.expectEqual(@as(usize, 3), result.tables[0].column_count);
    try std.testing.expectEqualStrings("17", result.tables[0].rows[1].cells[1].text);
    const blank = result.tables[0].rows[2].cells[1];
    try std.testing.expectEqualStrings("", blank.text);
    try std.testing.expect(blank.bounds.x1 > blank.bounds.x0);
    try std.testing.expectEqualStrings("0", result.tables[0].rows[2].cells[2].text);
}

test "preferred native header bridge uses body union at PDF glyph height and wide gaps" {
    const expected = [_][3][]const u8{ .{ "Task", "Due", "Done" }, .{ "A", "", "15" }, .{ "B", "17", "0" } };
    for ([_]f64{ 36, 40, 44 }) |baseline_gap| {
        for ([_]bool{ false, true }) |centered| {
            const due_x: f64 = if (centered) 381 else 348;
            const done_x: f64 = if (centered) 478 else 448;
            const body_y = 700 - baseline_gap;
            var spans = [_]TextSpan{
                testSpanSized("Task", 62, 698, 86, 705.86, 10),
                testSpanSized("Due", due_x, 698, due_x + 18, 705.86, 10),
                testSpanSized("Done", done_x, 698, done_x + 24, 705.86, 10),
                testSpanSized("A", 62, body_y - 2, 68, body_y + 5.86, 10),
                testSpanSized("15", 512, body_y - 2, 524, body_y + 5.86, 10),
                testSpanSized("B", 62, body_y - 38, 68, body_y - 30.14, 10),
                testSpanSized("17", 412, body_y - 38, 424, body_y - 30.14, 10),
                testSpanSized("0", 518, body_y - 38, 524, body_y - 30.14, 10),
            };
            for (&spans, 0..) |*span, index| span.native_source_index = @intCast(index);
            var work: TableWork = .{};
            const bands = try buildNativeTableBands(std.testing.allocator, &spans, &.{}, &work);
            defer {
                freeTableGrids(std.testing.allocator, bands);
                std.testing.allocator.free(bands);
            }
            try std.testing.expectEqual(@as(usize, 1), bands.len);
            try std.testing.expectEqual(@as(usize, 3), bands[0].column_count);
            try std.testing.expectEqual(@as(usize, 3), bands[0].rows.len);
            try std.testing.expectEqual(@as(usize, spans.len), bands[0].source_span_indices.len);
            for (bands[0].rows, expected) |row, values| for (row.cells, values) |cell, text| try std.testing.expectEqualStrings(text, cell.text);
            const blank = bands[0].rows[1].cells[1];
            try std.testing.expect(blank.bounds.x1 > blank.bounds.x0);
        }
    }
}

test "preferred wide header bridge rejects fields absent from all body rows" {
    var spans = [_]TextSpan{
        testSpanSized("Task", 62, 698, 86, 705.86, 10),
        testSpanSized("Due", 348, 698, 366, 705.86, 10),
        testSpanSized("Done", 448, 698, 472, 705.86, 10),
        testSpanSized("A", 62, 654, 68, 661.86, 10),
        testSpanSized("15", 512, 654, 524, 661.86, 10),
        testSpanSized("B", 62, 618, 68, 625.86, 10),
        testSpanSized("0", 518, 618, 524, 625.86, 10),
    };
    for (&spans, 0..) |*span, index| span.native_source_index = @intCast(index);
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(std.testing.allocator, &spans, &.{}, &work);
    defer {
        freeTableGrids(std.testing.allocator, bands);
        std.testing.allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 0), bands.len);
}

test "preferred native table bands do not promote ordinary two-column prose" {
    const spans = [_]TextSpan{
        testSpan("Left first sentence", 60, 700, 180, 712),  testSpan("Right first sentence", 340, 700, 470, 712),
        testSpan("Left second sentence", 60, 660, 190, 672), testSpan("Right second sentence", 340, 660, 480, 672),
        testSpan("Left third sentence", 60, 620, 180, 632),  testSpan("Right third sentence", 340, 620, 470, 632),
    };
    var result = try analyzeLayout(std.testing.allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.tables.len);
    try std.testing.expectEqual(@as(usize, 2), result.columns.len);
}

fn statementAssemblyAllocationProbe(allocator: std.mem.Allocator) !void {
    var spans = [_]TextSpan{
        testSpanSized("Item", 68, 698, 92, 705.86, 10),     testSpanSized("Now", 408, 698, 426, 705.86, 10),     testSpanSized("Prior", 506, 698, 536, 705.86, 10),
        testSpanSized("CAPITAL", 68, 662, 110, 669.86, 10), testSpanSized("Long", 68, 626, 92, 633.86, 10),      testSpanSized("label", 88, 610, 118, 617.86, 10),
        testSpanSized("12", 414, 592, 426, 599.86, 10),     testSpanSized("10", 524, 592, 536, 599.86, 10),      testSpanSized("4", 420, 552, 426, 559.86, 10),
        testSpanSized("3", 530, 552, 536, 559.86, 10),      testSpanSized("Portable", 68, 528, 116, 535.86, 10), testSpanSized("carrier", 88, 512, 130, 519.86, 10),
        testSpanSized("Tail", 68, 472, 92, 479.86, 10),     testSpanSized("16", 414, 472, 426, 479.86, 10),      testSpanSized("13", 524, 472, 536, 479.86, 10),
    };
    for (&spans, 0..) |*span, index| span.native_source_index = @intCast(index);
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(allocator, &spans, &.{}, &work);
    defer {
        freeTableGrids(allocator, bands);
        allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 1), bands.len);
    const table = bands[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 5), table.rows.len);
    const expected = [_][3][]const u8{
        .{ "Item", "Now", "Prior" }, .{ "CAPITAL", "", "" }, .{ "Long label", "12", "10" }, .{ "Portable carrier", "4", "3" }, .{ "Tail", "16", "13" },
    };
    for (table.rows, expected) |row, values| for (row.cells, values) |cell, text| {
        try std.testing.expectEqualStrings(text, cell.text);
        try std.testing.expectEqual(@as(u32, 1), cell.colspan);
    };
    try std.testing.expectEqual(@as(usize, spans.len), table.source_span_indices.len);
    try std.testing.expect(table.rows[2].bounds.y0 <= spans[6].y0 and table.rows[2].bounds.y1 >= spans[4].y1);
    try std.testing.expect(table.rows[3].bounds.y0 <= spans[11].y0 and table.rows[3].bounds.y1 >= spans[8].y1);
    try std.testing.expect(table.rows[2].bounds.y0 > table.rows[3].bounds.y1);
    try std.testing.expect(table.rows[3].bounds.y0 > table.rows[4].bounds.y1);
}

test "statement sections and directional wrapped labels retain exact rows and geometry" {
    try statementAssemblyAllocationProbe(std.testing.allocator);
}

test "statement assembly rolls back every allocation failure including prefix merging" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), statementAssemblyAllocationProbe, .{});
}

test "prefix allocation failure retains original text and geometry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2, .resize_fail_index = 0 });
    const allocator = failing.allocator();
    const bounds = testSpan("", 10, 20, 90, 32);
    var target = TableCell{ .bounds = bounds, .text = try allocator.dupe(u8, "Original"), .row_index = 0, .column_index = 0 };
    defer allocator.free(target.text);
    const original_ptr = target.text.ptr;
    const prefix = TableCell{ .bounds = testSpan("", 10, 40, 90, 52), .text = "Earlier", .row_index = 0, .column_index = 0 };
    try std.testing.expectError(error.OutOfMemory, prependCellContinuation(allocator, &target, prefix));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(target.text.ptr == original_ptr);
    try std.testing.expectEqualStrings("Original", target.text);
    try std.testing.expect(std.meta.eql(bounds, target.bounds));
}

test "equidistant stub fragments have no inferred numeric row attachment" {
    const spans = [_]TextSpan{
        testSpanSized("A", 68, 678, 74, 685.86, 10),           testSpanSized("1", 420, 678, 426, 685.86, 10), testSpanSized("2", 530, 678, 536, 685.86, 10),
        testSpanSized("unassigned", 68, 662, 128, 669.86, 10), testSpanSized("B", 68, 646, 74, 653.86, 10),   testSpanSized("3", 420, 646, 426, 653.86, 10),
        testSpanSized("4", 530, 646, 536, 653.86, 10),
    };
    const allocator = std.testing.allocator;
    const previous = try makeLine(allocator, spans[0..3]);
    defer freeTextLine(allocator, previous);
    const fragment = try makeLine(allocator, spans[3..4]);
    defer freeTextLine(allocator, fragment);
    const next = try makeLine(allocator, spans[4..7]);
    defer freeTextLine(allocator, next);
    var columns = StatementColumns{ .stub_left = 68, .stub_right = 400, .font_size = 10, .count = 2 };
    columns.edges[0] = 426;
    columns.edges[1] = 536;
    var work: TableWork = .{};
    try std.testing.expectEqual(@as(?StatementAttachment, null), try statementAttachment(&.{ previous, fragment, next }, 0, 1, columns, &work));
}

test "admitted indented stub words including isolated digits remain in the label cell" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{ testSpanSized("Series", 88, 610, 124, 617.86, 10), testSpanSized("2", 134, 610, 140, 617.86, 10) };
    const line = try makeLine(allocator, &spans);
    defer freeTextLine(allocator, line);
    try std.testing.expectEqual(@as(usize, 2), line.words.len);
    try std.testing.expect(wordLooksNumeric(line.words[1]));
    var columns = StatementColumns{ .stub_left = 68, .stub_right = 400, .font_size = 10, .count = 2 };
    columns.edges[0] = 426;
    columns.edges[1] = 536;
    var work: TableWork = .{};
    try std.testing.expect(try statementStubLine(line, columns, &work));
    const anchors = [_]ColumnAnchor{
        .{ .x = 68, .left = 68, .right = 120, .count = 2, .last_row = 0 },
        .{ .x = 426, .left = 414, .right = 426, .count = 2, .last_row = 0, .numeric = true, .right_aligned = true },
        .{ .x = 536, .left = 524, .right = 536, .count = 2, .last_row = 0, .numeric = true, .right_aligned = true },
    };
    const row = try buildTableRowWithRegularLabel(allocator, line, &anchors, testSpanSized("", 68, 600, 536, 700, 10), 1, true);
    defer freeTableRow(allocator, row);
    try std.testing.expectEqualStrings("Series 2", row.cells[0].text);
    try std.testing.expectEqualStrings("", row.cells[1].text);
    try std.testing.expectEqualStrings("", row.cells[2].text);
}

test "aligned numeric captions figures formulas and narrative lists remain outside statements" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "Table values note", "Figure values note", "x=+", "1. Narrative" }) |label| {
        const spans = [_]TextSpan{
            testSpanSized("Item", 68, 698, 92, 705.86, 10),  testSpanSized("Now", 408, 698, 426, 705.86, 10), testSpanSized("Prior", 506, 698, 536, 705.86, 10),
            testSpanSized("A", 68, 662, 74, 669.86, 10),     testSpanSized("1", 420, 662, 426, 669.86, 10),   testSpanSized("2", 530, 662, 536, 669.86, 10),
            testSpanSized("Total", 68, 626, 98, 633.86, 10), testSpanSized("3", 420, 626, 426, 633.86, 10),   testSpanSized("4", 530, 626, 536, 633.86, 10),
            testSpanSized(label, 68, 610, 170, 617.86, 10),  testSpanSized("5", 420, 610, 426, 617.86, 10),   testSpanSized("6", 530, 610, 536, 617.86, 10),
        };
        var result = try analyzeLayout(allocator, &spans, 612);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.tables.len);
        try std.testing.expectEqual(@as(usize, 3), result.tables[0].rows.len);
        try std.testing.expectEqual(@as(usize, 9), result.tables[0].source_span_indices.len);
        for ([_]u32{ 9, 10, 11 }) |id| try std.testing.expect(!containsSourceIndex(result.tables[0].source_span_indices, id));
        const text = try result.getCompleteReconstructedText(allocator);
        defer allocator.free(text);
        try std.testing.expect(std.mem.indexOf(u8, text, label) != null);
    }
    const numeric = [_]TextSpan{ testSpan("5", 420, 610, 426, 620), testSpan("6", 530, 610, 536, 620) };
    var line = try makeLine(allocator, &numeric);
    defer freeTextLine(allocator, line);
    var columns = StatementColumns{ .stub_left = 68, .stub_right = 400, .font_size = 10, .count = 2 };
    columns.edges[0] = 426;
    columns.edges[1] = 536;
    var work: TableWork = .{};
    for ([_]LineRole{ .heading, .caption, .figure_candidate, .formula_candidate, .list_item }) |role| {
        line.role = role;
        try std.testing.expect(statementHardBarrier(line));
        try std.testing.expectEqual(@as(usize, 0), try statementValueCount(line, columns, &work));
    }
}

test "near-final prose and small footnotes retain native identity after a populated total" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "Inventory checked weekly", "Note: quantities unverified" }, [_]f64{ 10, 8 }) |label, font| {
        const spans = [_]TextSpan{
            testSpanSized("Item", 68, 698, 92, 705.86, 10),   testSpanSized("Now", 408, 698, 426, 705.86, 10), testSpanSized("Prior", 506, 698, 536, 705.86, 10),
            testSpanSized("A", 68, 662, 74, 669.86, 10),      testSpanSized("1", 420, 662, 426, 669.86, 10),   testSpanSized("2", 530, 662, 536, 669.86, 10),
            testSpanSized("Total", 68, 626, 98, 633.86, 10),  testSpanSized("3", 420, 626, 426, 633.86, 10),   testSpanSized("4", 530, 626, 536, 633.86, 10),
            testSpanSized(label, 68, 610, 218, 617.86, font),
        };
        var result = try analyzeLayout(allocator, &spans, 612);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.tables.len);
        const table = result.tables[0];
        try std.testing.expectEqual(@as(usize, 3), table.rows.len);
        try std.testing.expectEqualStrings("Total", table.rows[2].cells[0].text);
        try std.testing.expectEqual(@as(usize, 9), table.source_span_indices.len);
        try std.testing.expect(!containsSourceIndex(table.source_span_indices, 9));
        const text = try result.getCompleteReconstructedText(allocator);
        defer allocator.free(text);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, label));
    }
}

fn statementRefusalAllocationProbe(allocator: std.mem.Allocator) !void {
    const ambiguous = [_]TextSpan{
        testSpan("Item", 68, 698, 92, 710),        testSpan("Now", 408, 698, 426, 710), testSpan("Prior", 506, 698, 536, 710),
        testSpan("A", 68, 678, 74, 690),           testSpan("1", 420, 678, 426, 690),   testSpan("2", 530, 678, 536, 690),
        testSpan("unassigned", 68, 662, 128, 674), testSpan("B", 68, 646, 74, 658),     testSpan("3", 420, 646, 426, 658),
        testSpan("4", 530, 646, 536, 658),
    };
    var result = try analyzeLayout(allocator, &ambiguous, 612);
    defer result.deinit();
    for (result.tables) |table| {
        try std.testing.expect(!containsSourceIndex(table.source_span_indices, 6));
        for (table.rows) |row| for (row.cells) |cell| try std.testing.expect(std.mem.indexOf(u8, cell.text, "unassigned") == null);
    }
    const text = try result.getCompleteReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "unassigned"));
}

test "top-level ambiguous label refusal cannot be reclaimed by legacy fallback" {
    try statementRefusalAllocationProbe(std.testing.allocator);
}

test "fallback refusal ownership rolls back every allocation failure" {
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), statementRefusalAllocationProbe, .{});
}

test "one body row before a numeric narrative list cannot bypass refusal through fallback" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Item", 68, 698, 92, 710),          testSpan("Now", 408, 698, 426, 710), testSpan("Prior", 506, 698, 536, 710),
        testSpan("A", 68, 678, 74, 690),             testSpan("1", 420, 678, 426, 690),   testSpan("2", 530, 678, 536, 690),
        testSpan("1. Narrative", 68, 662, 146, 674), testSpan("5", 420, 662, 426, 674),   testSpan("6", 530, 662, 536, 674),
        testSpan("B", 68, 646, 74, 658),             testSpan("3", 420, 646, 426, 658),   testSpan("4", 530, 646, 536, 658),
    };
    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();
    for (result.tables) |table| for ([_]u32{ 6, 7, 8 }) |id| try std.testing.expect(!containsSourceIndex(table.source_span_indices, id));
    const text = try result.getCompleteReconstructedText(allocator);
    defer allocator.free(text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "1. Narrative"));
}

test "barrier-first numeric lists and unsupported notes remain native through fallback" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "1. Narrative", "* unsupported note" }) |label| {
        const spans = [_]TextSpan{
            testSpan(label, 68, 678, 182, 690), testSpan("5", 420, 678, 426, 690), testSpan("6", 530, 678, 536, 690),
            testSpan("A", 68, 646, 74, 658),    testSpan("1", 420, 646, 426, 658), testSpan("2", 530, 646, 536, 658),
        };
        var result = try analyzeLayout(allocator, &spans, 612);
        defer result.deinit();
        for (result.tables) |table| for ([_]u32{ 0, 1, 2 }) |id| try std.testing.expect(!containsSourceIndex(table.source_span_indices, id));
        const text = try result.getCompleteReconstructedText(allocator);
        defer allocator.free(text);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, label));
        try std.testing.expect(std.mem.indexOf(u8, text, "A") != null);
    }
}

test "referenced literal notes retain digits without becoming amount rows" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{
        testSpan("Item", 68, 698, 92, 710),       testSpan("Now", 408, 698, 426, 710), testSpan("Prior", 506, 698, 536, 710),
        testSpan("A", 68, 678, 74, 690),          testSpan("1", 420, 678, 426, 690),   testSpan("2", 530, 678, 536, 690),
        testSpan("Services*", 68, 658, 122, 670), testSpan("3", 420, 658, 426, 670),   testSpan("4", 530, 658, 536, 670),
        testSpan("* note", 68, 644, 110, 656),    testSpan("5", 420, 644, 426, 656),   testSpan("6", 530, 644, 536, 656),
    };
    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 4), table.rows.len);
    try std.testing.expectEqualStrings("* note 5 6", table.rows[3].cells[0].text);
    try std.testing.expectEqual(TableCellRole.note, table.rows[3].cells[0].role);
    try std.testing.expectEqual(@as(u32, 3), table.rows[3].cells[0].colspan);
    try std.testing.expectEqualStrings("", table.rows[3].cells[1].text);
    try std.testing.expectEqualStrings("", table.rows[3].cells[2].text);
    try std.testing.expectEqual(@as(usize, spans.len), table.source_span_indices.len);
    var unreferenced = spans;
    unreferenced[6].text = "B";
    var native_note = try analyzeLayout(allocator, &unreferenced, 612);
    defer native_note.deinit();
    for (native_note.tables) |candidate| for ([_]u32{ 9, 10, 11 }) |id| try std.testing.expect(!containsSourceIndex(candidate.source_span_indices, id));
}

test "transformed Tf1 statement uses private point scale and tight section cadence" {
    var spans = [_]TextSpan{
        testSpanSized("Item", 68, 698, 92, 710.28, 1),      testSpanSized("Now", 408, 698, 426, 710.28, 1), testSpanSized("Prior", 506, 698, 536, 710.28, 1),
        testSpanSized("A", 68, 678, 74, 690.28, 1),         testSpanSized("1", 420, 678, 426, 690.28, 1),   testSpanSized("2", 530, 678, 536, 690.28, 1),
        testSpanSized("SEGMENT", 68, 664.8, 110, 674.9, 1), testSpanSized("B", 68, 645.2, 74, 657.48, 1),   testSpanSized("3", 420, 645.2, 426, 657.48, 1),
        testSpanSized("4", 530, 645.2, 536, 657.48, 1),
    };
    for (&spans, 0..) |*span, index| {
        span.layout_font_size = 12;
        span.native_source_index = @intCast(index);
    }
    const allocator = std.testing.allocator;
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(allocator, &spans, &.{}, &work);
    defer {
        freeTableGrids(allocator, bands);
        allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 1), bands.len);
    try std.testing.expectEqual(@as(usize, 3), bands[0].column_count);
    try std.testing.expectEqual(@as(usize, 4), bands[0].rows.len);
    const expected = [_][3][]const u8{ .{ "Item", "Now", "Prior" }, .{ "A", "1", "2" }, .{ "SEGMENT", "", "" }, .{ "B", "3", "4" } };
    for (bands[0].rows, expected) |row, values| for (row.cells, values) |cell, text| {
        try std.testing.expectEqualStrings(text, cell.text);
        try std.testing.expectEqual(@as(u32, 1), cell.colspan);
        try std.testing.expectEqual(@as(f64, 1), cell.bounds.font.size);
    };
    try std.testing.expectEqual(@as(usize, spans.len), bands[0].source_span_indices.len);
    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    try std.testing.expectEqual(@as(usize, 4), result.tables[0].rows.len);
    for (result.spans) |span| {
        try std.testing.expectEqual(@as(f64, 1), span.font.size);
        try std.testing.expectEqual(@as(f64, 1), span.font_size);
        try std.testing.expectEqual(@as(?f64, 12), span.layout_font_size);
    }
}

test "transformed nested sections and padded currency dash retain distinct owned rows" {
    var spans = [_]TextSpan{
        testSpanSized("Item", 40.56, 462.2, 64.56, 474.48, 1),     testSpanSized("Now", 408, 462.2, 426, 474.48, 1),              testSpanSized("Prior", 506, 462.2, 536, 474.48, 1),
        testSpanSized("Total", 40.56, 426.2, 70.56, 438.48, 1),    testSpanSized("3", 420, 426.2, 426, 438.48, 1),                testSpanSized("4", 530, 426.2, 536, 438.48, 1),
        testSpanSized("SECTION", 40.56, 402.67, 90.56, 412.77, 1), testSpanSized("SUBSECTION", 40.56, 386.47, 112.56, 396.57, 1), testSpanSized("Deferred charges", 40.56, 370.28, 140.56, 382.56, 1),
        testSpanSized("$", 336.96, 370.28, 344, 382.56, 1),        testSpanSized("    ", 344, 370.28, 420, 382.56, 1),            testSpanSized("-", 422, 370.28, 425.95, 382.56, 1),
        testSpanSized(" ", 425.95, 370.28, 428, 382.56, 1),        testSpanSized("$ 19", 506, 370.28, 536, 382.56, 1),            testSpanSized("Final", 40.56, 334.28, 70.56, 346.56, 1),
        testSpanSized("5", 420, 334.28, 426, 346.56, 1),           testSpanSized("6", 530, 334.28, 536, 346.56, 1),
    };
    for (&spans, 0..) |*span, index| {
        span.layout_font_size = 12;
        span.native_source_index = @intCast(index);
    }
    const allocator = std.testing.allocator;
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(allocator, &spans, &.{}, &work);
    defer {
        freeTableGrids(allocator, bands);
        allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 1), bands.len);
    try std.testing.expectEqual(@as(usize, 3), bands[0].column_count);
    try std.testing.expectEqual(@as(usize, 6), bands[0].rows.len);
    const expected = [_][3][]const u8{
        .{ "Item", "Now", "Prior" }, .{ "Total", "3", "4" },                     .{ "SECTION", "", "" },
        .{ "SUBSECTION", "", "" },   .{ "Deferred charges", "$    - ", "$ 19" }, .{ "Final", "5", "6" },
    };
    for (bands[0].rows, expected) |row, values| for (row.cells, values) |cell, text| {
        try std.testing.expectEqualStrings(text, cell.text);
        try std.testing.expectEqual(@as(u32, 1), cell.colspan);
        try std.testing.expectEqual(@as(f64, 1), cell.bounds.font.size);
    };
    try std.testing.expectEqual(@as(usize, 15), bands[0].source_span_indices.len);
    for ([_]u32{ 6, 7, 8, 9, 11, 13 }) |id| try std.testing.expect(containsSourceIndex(bands[0].source_span_indices, id));
    for (bands[0].rows[0 .. bands[0].rows.len - 1], bands[0].rows[1..]) |upper, lower| try std.testing.expect(upper.bounds.y0 > lower.bounds.y1);
    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    try std.testing.expectEqual(@as(usize, 6), result.tables[0].rows.len);
    try std.testing.expectEqualStrings("Deferred charges", result.tables[0].rows[4].cells[0].text);
    try std.testing.expectEqualStrings("$    - ", result.tables[0].rows[4].cells[1].text);
}

test "currency dash placeholder requires only one dash and an optional preceding currency symbol" {
    for ([_][]const u8{ " - ", " $ - ", "--", "-$", "Due -", "$" }, [_]bool{ true, true, false, false, false, false }) |text, expected| {
        const spans = [_]TextSpan{testSpan(text, 10, 20, 30, 32)};
        try std.testing.expectEqual(expected, wordIsPlaceholder(.{ .bounds = spans[0], .spans = &spans }));
    }
    var padded: [257]u8 = @splat(' ');
    padded[255] = '-';
    var padded_span = [_]TextSpan{testSpan(&padded, 10, 20, 30, 32)};
    try std.testing.expect(!wordIsPlaceholder(.{ .bounds = padded_span[0], .spans = &padded_span }));
    padded_span[0].text = padded[0..256];
    try std.testing.expect(wordIsPlaceholder(.{ .bounds = padded_span[0], .spans = &padded_span }));
    var fragments: [65]TextSpan = @splat(testSpan(" ", 10, 20, 30, 32));
    fragments[63].text = "-";
    try std.testing.expect(!wordIsPlaceholder(.{ .bounds = fragments[0], .spans = &fragments }));
    try std.testing.expect(wordIsPlaceholder(.{ .bounds = fragments[0], .spans = fragments[0..64] }));
}

test "short final section-chain gap preserves the whole ambiguous native chain" {
    const allocator = std.testing.allocator;
    var spans = [_]TextSpan{
        testSpanSized("Item", 68, 714, 92, 717, 12),     testSpanSized("Now", 408, 714, 426, 717, 12),       testSpanSized("Prior", 506, 714, 536, 717, 12),
        testSpanSized("Total", 68, 678, 98, 681, 12),    testSpanSized("1", 420, 678, 426, 681, 12),         testSpanSized("2", 530, 678, 536, 681, 12),
        testSpanSized("SECTION", 68, 664, 110, 667, 12), testSpanSized("SUBSECTION", 68, 650, 132, 653, 12), testSpanSized("Detail", 68, 640, 104, 643, 12),
        testSpanSized("3", 420, 640, 426, 643, 12),      testSpanSized("4", 530, 640, 536, 643, 12),         testSpanSized("Final", 68, 604, 98, 607, 12),
        testSpanSized("5", 420, 604, 426, 607, 12),      testSpanSized("6", 530, 604, 536, 607, 12),
    };
    for (&spans, 0..) |*span, index| span.native_source_index = @intCast(index);
    const lines = [_]TextLine{
        try makeLine(allocator, spans[3..6]), try makeLine(allocator, spans[6..7]),
        try makeLine(allocator, spans[7..8]), try makeLine(allocator, spans[8..11]),
    };
    defer for (lines) |line| freeTextLine(allocator, line);
    var columns = StatementColumns{ .stub_left = 68, .stub_right = 400, .font_size = 12, .count = 2 };
    columns.edges[0] = 426;
    columns.edges[1] = 536;
    var work: TableWork = .{};
    try std.testing.expect((try statementAttachment(&lines, 0, 1, columns, &work)) == null);
    var result = try analyzeLayout(allocator, &spans, 612);
    defer result.deinit();
    for (result.tables) |table| for ([_]u32{ 6, 7 }) |id| try std.testing.expect(!containsSourceIndex(table.source_span_indices, id));
    const text = try result.getCompleteReconstructedText(allocator);
    defer allocator.free(text);
    // SECTION occurs once alone and once inside the literal SUBSECTION label.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "SECTION"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "SUBSECTION"));
}

test "short math-marked numeric labels preserve formula barriers" {
    const allocator = std.testing.allocator;
    const spans = [_]TextSpan{ testSpan("B*", 68, 658, 80, 670), testSpan("3", 420, 658, 426, 670), testSpan("4", 530, 658, 536, 670) };
    var lines = [_]TextLine{try makeLine(allocator, &spans)};
    defer freeTextLine(allocator, lines[0]);
    classifyLines(&lines, 12);
    try std.testing.expectEqual(LineRole.formula_candidate, lines[0].role);
    try std.testing.expect(statementHardBarrier(lines[0]));
}

test "inverse transformed Tf120 uses measured table scalars while retaining public font metadata" {
    var spans = [_]TextSpan{
        testSpanSized("Item", 68, 698, 92, 710.28, 120), testSpanSized("Now", 408, 698, 426, 710.28, 120), testSpanSized("Prior", 506, 698, 536, 710.28, 120),
        testSpanSized("A", 68, 662, 74, 674.28, 120),    testSpanSized("1", 420, 662, 426, 674.28, 120),   testSpanSized("2", 530, 662, 536, 674.28, 120),
        testSpanSized("B", 68, 626, 74, 638.28, 120),    testSpanSized("3", 420, 626, 426, 638.28, 120),   testSpanSized("4", 530, 626, 536, 638.28, 120),
    };
    for (&spans, 0..) |*span, index| {
        span.layout_font_size = 12;
        span.native_source_index = @intCast(index);
    }
    const allocator = std.testing.allocator;
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(allocator, &spans, &.{}, &work);
    defer {
        freeTableGrids(allocator, bands);
        allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 1), bands.len);
    try std.testing.expectEqual(@as(usize, 3), bands[0].column_count);
    try std.testing.expectEqual(@as(usize, 3), bands[0].rows.len);
    const expected = [_][3][]const u8{ .{ "Item", "Now", "Prior" }, .{ "A", "1", "2" }, .{ "B", "3", "4" } };
    for (bands[0].rows, expected) |row, values| for (row.cells, values) |cell, text| {
        try std.testing.expectEqualStrings(text, cell.text);
        try std.testing.expectEqual(@as(f64, 120), cell.bounds.font.size);
    };
    try std.testing.expectEqual(@as(f64, 12), bands[0].bounds.font_size);
    try std.testing.expectEqual(@as(f64, 120), spans[0].font_size);
}

test "tight all-caps fragment beside a numeric-only baseline remains a wrapped label" {
    var spans = [_]TextSpan{
        testSpanSized("Item", 68, 698, 92, 710.28, 1), testSpanSized("Now", 408, 698, 426, 710.28, 1), testSpanSized("Prior", 506, 698, 536, 710.28, 1),
        testSpanSized("ACME", 68, 664, 92, 676.28, 1), testSpanSized("12", 414, 638, 426, 650.28, 1),  testSpanSized("10", 524, 638, 536, 650.28, 1),
        testSpanSized("Tail", 68, 604, 92, 616.28, 1), testSpanSized("1", 420, 604, 426, 616.28, 1),   testSpanSized("2", 530, 604, 536, 616.28, 1),
    };
    for (&spans, 0..) |*span, index| {
        span.layout_font_size = 12;
        span.native_source_index = @intCast(index);
    }
    const allocator = std.testing.allocator;
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(allocator, &spans, &.{}, &work);
    defer {
        freeTableGrids(allocator, bands);
        allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 1), bands.len);
    try std.testing.expectEqual(@as(usize, 3), bands[0].column_count);
    try std.testing.expectEqual(@as(usize, 3), bands[0].rows.len);
    try std.testing.expectEqualStrings("ACME", bands[0].rows[1].cells[0].text);
    try std.testing.expectEqualStrings("12", bands[0].rows[1].cells[1].text);
    try std.testing.expectEqualStrings("10", bands[0].rows[1].cells[2].text);
    try std.testing.expectEqual(@as(usize, spans.len), bands[0].source_span_indices.len);
}

test "native baseline bands sort staggered text by X before grouping words" {
    const spans = [_]TextSpan{
        testSpan("Item", 60, 704, 90, 716), testSpan("Left", 150, 704, 180, 716), testSpan("Right", 300, 706, 340, 718),
        testSpan("A", 60, 664, 78, 676),    testSpan("11", 156, 666, 180, 678),   testSpan("12", 300, 666, 324, 678),
        testSpan("B", 60, 624, 78, 636),    testSpan("21", 156, 626, 180, 638),   testSpan("22", 300, 626, 324, 638),
    };
    var result = try analyzeLayout(std.testing.allocator, &spans, 612);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.tables.len);
    const table = result.tables[0];
    try std.testing.expectEqual(@as(usize, 3), table.column_count);
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    const expected = [_][3][]const u8{ .{ "Item", "Left", "Right" }, .{ "A", "11", "12" }, .{ "B", "21", "22" } };
    for (table.rows, expected) |row, values| for (row.cells, values) |cell, text| try std.testing.expectEqualStrings(text, cell.text);
    // Exercise the preferred builder directly so legacy fallback cannot mask
    // an incorrect baseline grouping in the end-to-end layout assertion.
    var tracked = spans;
    for (&tracked, 0..) |*span, index| span.native_source_index = @intCast(index);
    var work: TableWork = .{};
    const bands = try buildNativeTableBands(std.testing.allocator, &tracked, &.{}, &work);
    defer {
        freeTableGrids(std.testing.allocator, bands);
        std.testing.allocator.free(bands);
    }
    try std.testing.expectEqual(@as(usize, 1), bands.len);
    try std.testing.expectEqual(@as(usize, 3), bands[0].column_count);
    try std.testing.expectEqual(@as(usize, 3), bands[0].rows.len);
    for (bands[0].rows, expected) |row, values| for (row.cells, values) |cell, text| try std.testing.expectEqualStrings(text, cell.text);
}
