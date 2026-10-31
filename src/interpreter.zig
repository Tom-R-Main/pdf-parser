//! PDF Content Stream Interpreter
//!
//! Interprets PDF page content streams to extract text.
//! Handles text positioning, font switching, and output.
//!
//! Key operators:
//! - BT/ET: Begin/end text object
//! - Tf: Set font and size
//! - Tm/Td/TD/T*: Text positioning
//! - Tj/TJ/'/": Show text
//!
//! Streaming architecture: outputs directly to writer, no intermediate buffer

const std = @import("std");
const parser = @import("parser.zig");
const encoding_mod = @import("encoding.zig");
const decompress = @import("decompress.zig");
const simd = @import("simd.zig");
const runtime = @import("runtime.zig");
const paint_mod = @import("paint.zig");
const form_scope = @import("form_scope.zig");
pub const layout = @import("layout.zig");

pub const TextSpan = layout.TextSpan;

const Object = parser.Object;
const ObjRef = parser.ObjRef;
const FontEncoding = encoding_mod.FontEncoding;

pub const GlyphSpan = struct {
    page_index: u32 = 0,
    bbox: layout.BBox = .{},
    quad: ?[4][2]f64 = null,
    text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    font_name: ?[]const u8 = null,
    font_size: f64 = 0,
    source_code: u32 = 0,
    source_bytes: [4]u8 = .{ 0, 0, 0, 0 },
    source_byte_count: u8 = 0,
    text: []const u8 = "",
    advance: f64 = 0,
    font_space_advance: f64 = 0,
    content_scope: ?form_scope.Scope = null,
    raw_glyph_start: ?u32 = null,
    raw_glyph_count: u32 = 1,
    semantic_replacement: bool = false,
    semantic_run_id: ?u32 = null,
    mapping_source: encoding_mod.MappingSource = .unresolved,
    unicode_map_error: bool = false,
    generated: bool = false,
    hyphen: bool = false,
    actual_text: bool = false,
    mcid: ?i32 = null,
    writing_mode: u8 = 0,
    paint: layout.PaintEvidence = .{},
};

pub const CharSpan = struct {
    page_index: u32 = 0,
    glyph_index: u32 = 0,
    bbox: layout.BBox = .{},
    text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    font_name: ?[]const u8 = null,
    font_size: f64 = 0,
    source_code: u32 = 0,
    text: []const u8 = "",
    mapping_source: encoding_mod.MappingSource = .unresolved,
    unicode_map_error: bool = false,
    generated: bool = false,
    hyphen: bool = false,
    actual_text: bool = false,
    mcid: ?i32 = null,
    writing_mode: u8 = 0,
    paint: layout.PaintEvidence = .{},
    content_scope: ?form_scope.Scope = null,
};

/// Authoritative replacement for a contiguous raw glyph range. Text is owned
/// by the collector; glyphs remain raw decoding evidence.
pub const ActualTextRun = struct {
    glyph_start: u32,
    glyph_count: u32,
    text: []const u8,
    mcid: ?i32,
};

/// Text state within a content stream
const TextState = struct {
    /// Character spacing (Tc)
    char_spacing: f64 = 0,
    /// Word spacing (Tw)
    word_spacing: f64 = 0,
    /// Horizontal scaling (Tz) in percent
    horizontal_scale: f64 = 100,
    /// Text leading (TL)
    leading: f64 = 0,
    /// Text rise (Ts)
    rise: f64 = 0,
    /// Current font name
    font_name: ?[]const u8 = null,
    /// Current font size
    font_size: f64 = 12,
    /// Text matrix [a b c d e f]
    text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// Line matrix (start of current line)
    line_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// Previous Y position (for detecting line breaks)
    prev_y: f64 = 0,
    /// Previous X end position (for detecting word breaks)
    prev_x_end: f64 = 0,
};

/// Graphics state (subset relevant to text extraction)
const GraphicsState = struct {
    /// Current transformation matrix
    ctm: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    /// Text state
    text: TextState = .{},
};

/// Content stream interpreter for text extraction
pub fn ContentInterpreter(comptime Writer: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        writer: Writer,

        /// PDF document data
        data: []const u8,
        /// Resolve function for object references
        resolve_fn: *const fn (ObjRef) Object,

        /// Graphics state stack
        state_stack: std.ArrayList(GraphicsState),
        /// Current graphics state
        state: GraphicsState,

        /// Font cache
        fonts: std.StringHashMap(FontEncoding),

        /// Resources dictionary
        resources: ?Object.Dict,

        /// Inside text object (BT...ET)?
        in_text: bool,

        /// Last output ended with space?
        last_was_space: bool,

        pub fn init(
            allocator: std.mem.Allocator,
            writer: Writer,
            data: []const u8,
            resources: ?Object.Dict,
            resolve_fn: *const fn (ObjRef) Object,
        ) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .data = data,
                .resolve_fn = resolve_fn,
                .state_stack = .empty,
                .state = .{},
                .fonts = std.StringHashMap(FontEncoding).init(allocator),
                .resources = resources,
                .in_text = false,
                .last_was_space = true,
            };
        }

        pub fn deinit(self: *Self) void {
            self.state_stack.deinit(self.allocator);

            var it = self.fonts.valueIterator();
            while (it.next()) |font| {
                var f = font.*;
                f.deinit();
            }
            self.fonts.deinit();
        }

        /// Process a content stream
        pub fn process(self: *Self, content: []const u8) !void {
            var lexer = ContentLexer.init(self.allocator, content);
            var operand_stack: [128]Operand = undefined;
            var stack_size: usize = 0;

            while (try lexer.next()) |token| {
                switch (token) {
                    .number => |n| {
                        if (stack_size < 128) {
                            operand_stack[stack_size] = .{ .number = n };
                            stack_size += 1;
                        }
                    },
                    .string => |s| {
                        if (stack_size < 128) {
                            operand_stack[stack_size] = .{ .string = s };
                            stack_size += 1;
                        }
                    },
                    .hex_string => |s| {
                        if (stack_size < 128) {
                            operand_stack[stack_size] = .{ .hex_string = s };
                            stack_size += 1;
                        }
                    },
                    .name => |n| {
                        if (stack_size < 128) {
                            operand_stack[stack_size] = .{ .name = n };
                            stack_size += 1;
                        }
                    },
                    .operator => |op| {
                        try self.executeOperator(op, operand_stack[0..stack_size]);
                        stack_size = 0;
                    },
                    .array => |arr| {
                        if (stack_size < 128) {
                            operand_stack[stack_size] = .{ .array = arr };
                            stack_size += 1;
                        }
                    },
                }
            }
        }

        fn executeOperator(self: *Self, op: []const u8, operands: []const Operand) !void {
            // Graphics state operators
            if (std.mem.eql(u8, op, "q")) {
                try self.state_stack.append(self.allocator, self.state);
            } else if (std.mem.eql(u8, op, "Q")) {
                if (self.state_stack.pop()) |state| {
                    self.state = state;
                }
            } else if (std.mem.eql(u8, op, "cm")) {
                // Modify CTM - not critical for basic text extraction
            }
            // Text object operators
            else if (std.mem.eql(u8, op, "BT")) {
                self.in_text = true;
                self.state.text = .{};
            } else if (std.mem.eql(u8, op, "ET")) {
                self.in_text = false;
            }
            // Text state operators
            else if (std.mem.eql(u8, op, "Tc")) {
                if (self.in_text and operands.len >= 1) {
                    self.state.text.char_spacing = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "Tw")) {
                if (self.in_text and operands.len >= 1) {
                    self.state.text.word_spacing = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "Tz")) {
                if (self.in_text and operands.len >= 1) {
                    self.state.text.horizontal_scale = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "TL")) {
                if (self.in_text and operands.len >= 1) {
                    self.state.text.leading = operands[0].asNumber();
                }
            } else if (std.mem.eql(u8, op, "Tf")) {
                if (self.in_text and operands.len >= 2) {
                    self.state.text.font_name = operands[0].asName();
                    self.state.text.font_size = operands[1].asNumber();
                    try self.loadFont(operands[0].asName() orelse "");
                }
            } else if (std.mem.eql(u8, op, "Tr")) {
                // Text rendering mode - not needed for extraction
            } else if (std.mem.eql(u8, op, "Ts")) {
                if (self.in_text and operands.len >= 1) {
                    self.state.text.rise = operands[0].asNumber();
                }
            }
            // Text positioning operators
            else if (std.mem.eql(u8, op, "Td")) {
                if (self.in_text and operands.len >= 2) {
                    const tx = operands[0].asNumber();
                    const ty = operands[1].asNumber();
                    try self.moveText(tx, ty);
                }
            } else if (std.mem.eql(u8, op, "TD")) {
                if (self.in_text and operands.len >= 2) {
                    const tx = operands[0].asNumber();
                    const ty = operands[1].asNumber();
                    self.state.text.leading = -ty;
                    try self.moveText(tx, ty);
                }
            } else if (std.mem.eql(u8, op, "Tm")) {
                if (self.in_text and operands.len >= 6) {
                    const new_y = operands[5].asNumber();
                    try self.checkLineBreak(new_y);

                    self.state.text.text_matrix = .{
                        operands[0].asNumber(),
                        operands[1].asNumber(),
                        operands[2].asNumber(),
                        operands[3].asNumber(),
                        operands[4].asNumber(),
                        new_y,
                    };
                    self.state.text.line_matrix = self.state.text.text_matrix;
                }
            } else if (std.mem.eql(u8, op, "T*")) {
                if (self.in_text) try self.moveToNextLine();
            }
            // Text showing operators
            else if (std.mem.eql(u8, op, "Tj")) {
                if (self.in_text and operands.len >= 1) {
                    try self.showText(operands[0]);
                }
            } else if (std.mem.eql(u8, op, "TJ")) {
                if (self.in_text and operands.len >= 1) {
                    try self.showTextArray(operands[0]);
                }
            } else if (std.mem.eql(u8, op, "'")) {
                // Move to next line and show text
                if (self.in_text and operands.len >= 1) {
                    try self.moveToNextLine();
                    try self.showText(operands[0]);
                }
            } else if (std.mem.eql(u8, op, "\"")) {
                // Set spacing, move to next line, show text
                if (self.in_text and operands.len >= 3) {
                    self.state.text.word_spacing = operands[0].asNumber();
                    self.state.text.char_spacing = operands[1].asNumber();
                    try self.moveToNextLine();
                    try self.showText(operands[2]);
                }
            }
            // Inline image - skip
            else if (std.mem.eql(u8, op, "BI")) {
                // Would need to skip to EI
            }
        }

        fn moveText(self: *Self, tx: f64, ty: f64) !void {
            // Calculate new position
            const matrix = self.state.text.line_matrix;
            const new_x = matrix[4] + matrix[0] * tx + matrix[2] * ty;
            const new_y = matrix[5] + matrix[1] * tx + matrix[3] * ty;

            try self.checkLineBreak(new_y);

            // Update matrices
            self.state.text.line_matrix[4] = new_x;
            self.state.text.line_matrix[5] = new_y;
            self.state.text.text_matrix = self.state.text.line_matrix;
        }

        fn moveToNextLine(self: *Self) !void {
            const leading = if (self.state.text.leading != 0) self.state.text.leading else self.state.text.font_size;
            try self.moveText(0, -leading);
        }

        fn checkLineBreak(self: *Self, new_y: f64) !void {
            const y_diff = @abs(new_y - self.state.text.prev_y);

            // Significant Y movement = new line
            if (y_diff > self.state.text.font_size * 0.3 and self.state.text.prev_y != 0) {
                try self.writer.writeByte('\n');
                self.last_was_space = true;
            }

            self.state.text.prev_y = new_y;
        }

        fn showText(self: *Self, operand: Operand) !void {
            const str = switch (operand) {
                .string => |s| s,
                .hex_string => |s| s,
                else => return,
            };

            // Get font encoding
            const font_name = self.state.text.font_name orelse "";
            const font = self.fonts.get(font_name);

            if (font) |enc| {
                try enc.decode(str, self.writer);
            } else {
                // Fallback: assume WinAnsi or raw bytes
                for (str) |byte| {
                    if (byte >= 32 and byte < 127) {
                        try self.writer.writeByte(byte);
                    } else if (byte == 0) {
                        // Null often used as separator
                        try self.writer.writeByte(' ');
                    }
                }
            }

            self.last_was_space = false;
        }

        fn showTextArray(self: *Self, operand: Operand) !void {
            const arr = switch (operand) {
                .array => |a| a,
                else => return,
            };

            for (arr) |item| {
                switch (item) {
                    .string, .hex_string => try self.showText(item),
                    .number => |n| {
                        // Negative number = move right (space between glyphs)
                        // Large negative = word space
                        if (n < -100 and !self.last_was_space) {
                            try self.writer.writeByte(' ');
                            self.last_was_space = true;
                        }
                    },
                    else => {},
                }
            }
        }

        fn loadFont(self: *Self, font_name: []const u8) !void {
            // Check if already loaded
            if (self.fonts.contains(font_name)) return;

            // Get font from resources
            const font_dict = blk: {
                const resources = self.resources orelse break :blk null;
                const fonts = resources.getDict("Font") orelse break :blk null;
                const font_obj = fonts.get(font_name) orelse break :blk null;

                // Resolve if reference
                const resolved = switch (font_obj) {
                    .reference => |ref| self.resolve_fn(ref),
                    else => font_obj,
                };

                break :blk switch (resolved) {
                    .dict => |d| d,
                    else => null,
                };
            };

            if (font_dict) |fd| {
                const dummy_ctx: u8 = 0;
                const enc = try encoding_mod.parseFontEncoding(
                    self.allocator,
                    fd,
                    struct {
                        fn resolve(_: *const anyopaque, obj: Object) Object {
                            return obj; // Simplified - would need proper resolution
                        }
                    }.resolve,
                    &dummy_ctx,
                );
                try self.fonts.put(font_name, enc);
            } else {
                // Use default encoding
                const enc = FontEncoding.init(self.allocator);
                try self.fonts.put(font_name, enc);
            }
        }
    };
}

pub const SpanCollector = struct {
    spans: std.ArrayList(TextSpan),
    glyphs: std.ArrayList(GlyphSpan),
    chars: std.ArrayList(CharSpan),
    text_buffer: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    current_x: f64 = 0,
    current_y: f64 = 0,
    current_font_size: f64 = 12,
    current_font_name: ?[]const u8 = null,
    current_font_has_to_unicode: ?bool = null,
    current_font_is_type3: bool = false,
    current_font_space_width: f64 = 0,
    current_scope: ?form_scope.Scope = null,
    current_text_matrix: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    graphics_state: ?paint_mod.State = null,
    current_char_spacing: f64 = 0,
    current_word_spacing: f64 = 0,
    current_horizontal_scale: f64 = 100,
    current_text_rise: f64 = 0,
    current_writing_mode: u8 = 0,
    page_index: u32 = 0,
    current_block_id: u32 = 0,
    current_line_id: u32 = 0,
    current_mcid: ?i32 = null,
    pending_bbox: ?layout.BBox = null,
    pending_layout_font_size: f64 = 0,
    pending_unicode_map_error: bool = false,
    pending_actual_text: bool = false,
    current_actual_text: ?[]const u8 = null,
    actual_text_runs: std.ArrayList(ActualTextRun) = .empty,
    actual_text_glyph_start: usize = 0,
    actual_text_mcid: ?i32 = null,
    avg_char_width: f64 = 0.5,

    pub fn init(allocator: std.mem.Allocator, page_index: u32) SpanCollector {
        return .{
            .spans = .empty,
            .glyphs = .empty,
            .chars = .empty,
            .text_buffer = .empty,
            .allocator = allocator,
            .page_index = page_index,
            .current_scope = .{ .page_index = page_index },
        };
    }

    pub fn deinit(self: *SpanCollector) void {
        for (self.spans.items) |span| {
            if (span.text.len > 0) {
                self.allocator.free(@constCast(span.text));
            }
            if (span.font.name) |name| {
                self.allocator.free(@constCast(name));
            }
        }
        for (self.glyphs.items) |glyph| {
            if (glyph.text.len > 0) self.allocator.free(@constCast(glyph.text));
            if (glyph.font_name) |name| self.allocator.free(@constCast(name));
        }
        for (self.chars.items) |char| {
            if (char.text.len > 0) self.allocator.free(@constCast(char.text));
            if (char.font_name) |name| self.allocator.free(@constCast(name));
        }
        if (self.current_actual_text) |text| self.allocator.free(@constCast(text));
        for (self.actual_text_runs.items) |run| self.allocator.free(@constCast(run.text));
        self.actual_text_runs.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        self.glyphs.deinit(self.allocator);
        self.chars.deinit(self.allocator);
        self.text_buffer.deinit(self.allocator);
    }

    pub fn setPosition(self: *SpanCollector, x: f64, y: f64) void {
        if (self.current_y != y and self.spans.items.len > 0) {
            self.current_line_id += 1;
        }
        self.current_x = x;
        self.current_y = y;
    }

    pub fn setFontSize(self: *SpanCollector, size: f64) void {
        self.current_font_size = size;
    }

    pub fn setFont(self: *SpanCollector, name: ?[]const u8, size: f64, has_to_unicode: ?bool) void {
        self.current_font_name = name;
        self.current_font_size = size;
        self.current_font_has_to_unicode = has_to_unicode;
    }

    pub fn setTextState(self: *SpanCollector, args: struct {
        char_spacing: f64,
        word_spacing: f64,
        horizontal_scale: f64,
        text_rise: f64,
    }) void {
        self.current_char_spacing = args.char_spacing;
        self.current_word_spacing = args.word_spacing;
        self.current_horizontal_scale = args.horizontal_scale;
        self.current_text_rise = args.text_rise;
    }

    pub fn setTextMatrix(self: *SpanCollector, matrix: [6]f64) void {
        self.current_text_matrix = matrix;
    }

    pub fn setGraphicsState(self: *SpanCollector, state: paint_mod.State) void {
        self.graphics_state = state;
    }

    fn paintEvidence(self: *const SpanCollector, bbox: layout.BBox) layout.PaintEvidence {
        var value: layout.PaintEvidence = if (self.graphics_state) |state| state.evidence(bbox) else .{};
        // Type3 glyph programs determine painting in ordinary modes; 3/7
        // still suppress rendering. Their programs are not interpreted here.
        if (self.current_font_is_type3 and value.paint_state == .painting) value.paint_state = .unknown;
        return value;
    }

    fn userTextMatrix(self: *const SpanCollector) [6]f64 {
        return paint_mod.concat(if (self.graphics_state) |state| state.ctm else paint_mod.identity, self.current_text_matrix);
    }

    pub fn setMcid(self: *SpanCollector, mcid: ?i32) void {
        self.current_mcid = mcid;
    }

    pub fn setContentScope(self: *SpanCollector, scope: ?form_scope.Scope) void {
        self.current_scope = scope;
    }

    pub fn setActualText(self: *SpanCollector, text: ?[]const u8) !void {
        if (self.current_actual_text != null and text != null and std.mem.eql(u8, self.current_actual_text.?, text.?)) return;
        if (self.current_actual_text != null) try self.finishActualTextRun();
        if (text) |value| {
            try self.flush();
            self.current_actual_text = try self.allocator.dupe(u8, value);
            self.actual_text_glyph_start = self.glyphs.items.len;
            self.actual_text_mcid = self.current_mcid;
        }
    }

    fn finishActualTextRun(self: *SpanCollector) !void {
        const text = self.current_actual_text orelse return;
        try self.flush();
        const raw = self.glyphs.items[self.actual_text_glyph_start..];
        if (raw.len == 0) {
            self.allocator.free(@constCast(text));
            self.current_actual_text = null;
            return;
        }
        try self.actual_text_runs.ensureUnusedCapacity(self.allocator, 1);
        if (text.len > 0) {
            try self.spans.ensureUnusedCapacity(self.allocator, 1);
            const owned_text = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(owned_text);
            const glyph = semanticRunGlyph(raw, text, self.actual_text_mcid);
            var point_size: f64 = 0;
            for (raw) |source| {
                if (glyphNormalFontSize(source.text_matrix, source.font_size, source.writing_mode)) |size| point_size = @max(point_size, size);
            }
            const font_name = if (glyph.font_name) |name| try self.allocator.dupe(u8, name) else null;
            self.spans.appendAssumeCapacity(TextSpan.init(.{
                .page_index = self.page_index,
                .bbox = glyph.bbox,
                .text = owned_text,
                .font = .{ .name = font_name, .size = glyph.font_size },
                .layout_font_size = if (point_size > 0) point_size else null,
                .block_id = self.current_block_id,
                .line_id = self.current_line_id,
                .mcid = self.actual_text_mcid,
                .actual_text = true,
                .writing_mode = glyph.writing_mode,
                .paint = glyph.paint,
                .content_scope = glyph.content_scope,
            }));
        }
        self.actual_text_runs.appendAssumeCapacity(.{ .glyph_start = @intCast(self.actual_text_glyph_start), .glyph_count = @intCast(raw.len), .text = text, .mcid = self.actual_text_mcid });
        self.current_actual_text = null;
    }

    pub fn writeAll(self: *SpanCollector, data: []const u8) !void {
        try self.text_buffer.appendSlice(self.allocator, data);
    }

    pub fn writeByte(self: *SpanCollector, byte: u8) !void {
        try self.text_buffer.append(self.allocator, byte);
    }

    pub fn print(_: *SpanCollector, comptime _: []const u8, _: anytype) !void {}

    pub fn writeDecodedGlyph(self: *SpanCollector, decoded: encoding_mod.FontEncoding.DecodedGlyph) !void {
        self.current_writing_mode = decoded.writing_mode;
        const has_actual_text = self.current_actual_text != null;
        const mapping_source = decoded.mapping_source;
        const unicode_map_error = decoded.unicode_map_error or mapping_source == .unresolved;
        const advance = self.scaledAdvance(decoded);
        const bbox = self.currentGlyphBBox(advance, decoded);
        const text = try self.allocator.dupe(u8, decoded.utf8_text);
        var glyph_transferred = false;
        errdefer if (!glyph_transferred) self.allocator.free(text);
        const font_name = if (self.current_font_name) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (!glyph_transferred) {
            if (font_name) |name| self.allocator.free(name);
        };

        var source_bytes: [4]u8 = .{ 0, 0, 0, 0 };
        const source_len = @min(decoded.source_bytes.len, source_bytes.len);
        @memcpy(source_bytes[0..source_len], decoded.source_bytes[0..source_len]);

        const glyph_index: u32 = @intCast(self.glyphs.items.len);
        try self.glyphs.append(self.allocator, .{
            .page_index = self.page_index,
            .bbox = bbox,
            .text_matrix = self.userTextMatrix(),
            .quad = self.currentGlyphQuad(advance, decoded),
            .font_name = font_name,
            .font_size = self.current_font_size,
            .source_code = decoded.source_code,
            .source_bytes = source_bytes,
            .source_byte_count = @intCast(source_len),
            .text = text,
            .advance = advance,
            .font_space_advance = self.spaceAdvance(),
            .content_scope = self.current_scope,
            .raw_glyph_start = glyph_index,
            .semantic_run_id = if (has_actual_text) @intCast(self.actual_text_runs.items.len) else null,
            .mapping_source = mapping_source,
            .unicode_map_error = unicode_map_error,
            .generated = false,
            .hyphen = isHyphenText(decoded.utf8_text),
            .actual_text = has_actual_text,
            .mcid = self.current_mcid,
            .writing_mode = decoded.writing_mode,
            .paint = self.paintEvidence(bbox),
        });
        glyph_transferred = true;

        try self.appendCharsForGlyph(glyph_index, bbox, decoded.source_code, decoded.utf8_text, mapping_source, unicode_map_error, false, has_actual_text, decoded.writing_mode);
        if (!has_actual_text) {
            try self.text_buffer.appendSlice(self.allocator, decoded.utf8_text);
        }
        self.pending_bbox = unionOptionalBBox(self.pending_bbox, bbox);
        if (glyphNormalFontSize(self.userTextMatrix(), self.current_font_size, decoded.writing_mode)) |size| self.pending_layout_font_size = @max(self.pending_layout_font_size, size);
        self.pending_actual_text = self.pending_actual_text or has_actual_text;
        if (!has_actual_text) {
            self.pending_unicode_map_error = self.pending_unicode_map_error or unicode_map_error;
        }

        if (decoded.writing_mode == 1) {
            self.current_x -= self.current_text_matrix[2] * advance;
            self.current_y -= self.current_text_matrix[3] * advance;
        } else {
            self.current_x += self.current_text_matrix[0] * advance;
            self.current_y += self.current_text_matrix[1] * advance;
        }
        self.current_text_matrix[4] = self.current_x;
        self.current_text_matrix[5] = self.current_y;
    }

    pub fn appendFallbackBytes(self: *SpanCollector, data: []const u8) !void {
        for (data) |byte| {
            if (byte == 0) continue;
            var buf: [4]u8 = undefined;
            const text = if (byte >= 32 and byte < 127) blk: {
                buf[0] = byte;
                break :blk buf[0..1];
            } else blk: {
                const codepoint = encoding_mod.win_ansi_encoding[byte];
                if (codepoint == 0) continue;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 1;
                break :blk buf[0..len];
            };
            try self.writeDecodedGlyph(.{
                .source_code = byte,
                .source_bytes = data[0..0],
                .bytes_consumed = 1,
                .utf8_text = text,
                .glyph_width = 600,
                .mapping_source = if (byte >= 128) .unresolved else .simple_encoding,
                .unicode_map_error = byte >= 128,
                .writing_mode = self.current_writing_mode,
            });
        }
    }

    pub fn advanceByTextAdjustment(self: *SpanCollector, adjustment: f64) !void {
        if (adjustment > self.current_font_size * 0.15) {
            try self.flush();
            try self.appendGeneratedSpace(adjustment);
        }
        if (self.current_writing_mode == 1) {
            self.current_x += self.current_text_matrix[2] * adjustment;
            self.current_y += self.current_text_matrix[3] * adjustment;
        } else {
            self.current_x += self.current_text_matrix[0] * adjustment;
            self.current_y += self.current_text_matrix[1] * adjustment;
        }
        self.current_text_matrix[4] = self.current_x;
        self.current_text_matrix[5] = self.current_y;
    }

    pub fn flush(self: *SpanCollector) !void {
        // ActualText belongs to a marked-content scope, not a font/paint run.
        // Closing that scope emits its replacement once using all raw geometry.
        if (self.current_actual_text != null) {
            self.text_buffer.clearRetainingCapacity();
            self.pending_bbox = null;
            self.pending_layout_font_size = 0;
            self.pending_unicode_map_error = false;
            self.pending_actual_text = false;
            return;
        }
        if (self.text_buffer.items.len == 0 and !(self.pending_actual_text and self.pending_bbox != null)) return;

        const span_text = if (self.pending_actual_text) (self.current_actual_text orelse self.text_buffer.items) else self.text_buffer.items;
        const text = try self.allocator.dupe(u8, span_text);
        errdefer self.allocator.free(text);
        const font_name = if (self.current_font_name) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (font_name) |name| self.allocator.free(name);
        const bbox = self.pending_bbox orelse fallbackBBox(self.current_x, self.current_y, @as(f64, @floatFromInt(text.len)) * self.current_font_size * self.avg_char_width, self.current_font_size);

        try self.spans.append(self.allocator, TextSpan.init(.{
            .page_index = self.page_index,
            .bbox = bbox,
            .text = text,
            .source = .native_pdf,
            .confidence = if (self.pending_unicode_map_error) 0.82 else 1.0,
            .font = .{ .name = font_name, .size = self.current_font_size, .has_to_unicode = self.current_font_has_to_unicode },
            .layout_font_size = if (self.pending_layout_font_size > 0) self.pending_layout_font_size else glyphNormalFontSize(self.userTextMatrix(), self.current_font_size, self.current_writing_mode),
            .block_id = self.current_block_id,
            .line_id = self.current_line_id,
            .mcid = self.current_mcid,
            .unicode_map_error = self.pending_unicode_map_error,
            .actual_text = self.pending_actual_text,
            .writing_mode = self.current_writing_mode,
            .paint = self.paintEvidence(bbox),
            .content_scope = self.current_scope,
        }));

        self.text_buffer.clearRetainingCapacity();
        self.pending_bbox = null;
        self.pending_layout_font_size = 0;
        self.pending_unicode_map_error = false;
        self.pending_actual_text = false;
    }

    pub fn getSpans(self: *SpanCollector) []const TextSpan {
        return self.spans.items;
    }

    pub fn getGlyphs(self: *SpanCollector) []const GlyphSpan {
        return self.glyphs.items;
    }

    pub fn getChars(self: *SpanCollector) []const CharSpan {
        return self.chars.items;
    }

    pub fn toOwnedSlice(self: *SpanCollector) ![]TextSpan {
        return self.spans.toOwnedSlice(self.allocator);
    }

    /// Transfer glyph geometry to the caller. Glyph text and font names remain
    /// caller-owned and must be released with the returned slice.
    pub fn toOwnedGlyphSlice(self: *SpanCollector) ![]GlyphSpan {
        return self.glyphs.toOwnedSlice(self.allocator);
    }

    /// Independent semantic view: replacements are indivisible union-bbox
    /// glyphs; empty replacements suppress their entire raw range.
    /// Call before transferring the raw glyph slice.
    pub fn toOwnedSemanticGlyphSlice(self: *SpanCollector) ![]GlyphSpan {
        var projected: std.ArrayList(GlyphSpan) = .empty;
        errdefer {
            for (projected.items) |glyph| {
                self.allocator.free(@constCast(glyph.text));
                if (glyph.font_name) |name| self.allocator.free(@constCast(name));
            }
            projected.deinit(self.allocator);
        }
        var raw_index: usize = 0;
        var run_index: usize = 0;
        while (raw_index < self.glyphs.items.len) {
            var glyph = self.glyphs.items[raw_index];
            if (run_index < self.actual_text_runs.items.len and self.actual_text_runs.items[run_index].glyph_start == raw_index) {
                const run = self.actual_text_runs.items[run_index];
                run_index += 1;
                raw_index += run.glyph_count;
                if (run.text.len == 0) continue;
                glyph = semanticRunGlyph(self.glyphs.items[run.glyph_start..raw_index], run.text, run.mcid);
            } else {
                raw_index += 1;
            }
            try projected.ensureUnusedCapacity(self.allocator, 1);
            glyph.text = try self.allocator.dupe(u8, glyph.text);
            errdefer self.allocator.free(@constCast(glyph.text));
            glyph.font_name = if (glyph.font_name) |name| try self.allocator.dupe(u8, name) else null;
            projected.appendAssumeCapacity(glyph);
        }
        return projected.toOwnedSlice(self.allocator);
    }

    fn semanticRunGlyph(raw: []const GlyphSpan, text: []const u8, mcid: ?i32) GlyphSpan {
        var result = raw[0];
        result.text = text;
        result.mapping_source = .actual_text;
        result.unicode_map_error = false;
        result.actual_text = true;
        result.semantic_replacement = true;
        result.quad = null;
        result.raw_glyph_count = @intCast(raw.len);
        result.source_code = 0;
        result.source_byte_count = 0;
        result.generated = false;
        result.hyphen = isHyphenText(text);
        result.mcid = mcid;
        for (raw[1..]) |glyph| {
            result.bbox = unionOptionalBBox(result.bbox, glyph.bbox).?;
            if (!std.meta.eql(result.paint, glyph.paint)) result.paint = .{};
            if (!std.meta.eql(result.content_scope, glyph.content_scope)) result.content_scope = null;
            if (result.font_name != null and (glyph.font_name == null or !std.mem.eql(u8, result.font_name.?, glyph.font_name.?))) result.font_name = null;
        }
        result.paint = result.paint.forBBox(result.bbox);
        const last = raw[raw.len - 1];
        const axis_x = if (result.writing_mode == 1) -result.text_matrix[2] else result.text_matrix[0];
        const axis_y = if (result.writing_mode == 1) -result.text_matrix[3] else result.text_matrix[1];
        const last_axis_x = if (last.writing_mode == 1) -last.text_matrix[2] else last.text_matrix[0];
        const last_axis_y = if (last.writing_mode == 1) -last.text_matrix[3] else last.text_matrix[1];
        const norm_squared = axis_x * axis_x + axis_y * axis_y;
        result.advance = if (norm_squared > 0.00000001)
            ((last.text_matrix[4] + last_axis_x * last.advance - result.text_matrix[4]) * axis_x + (last.text_matrix[5] + last_axis_y * last.advance - result.text_matrix[5]) * axis_y) / norm_squared
        else
            0;
        return result;
    }

    fn appendGeneratedSpace(self: *SpanCollector, advance: f64) !void {
        const bbox = if (self.current_writing_mode == 1)
            transformedBounds(self.userTextMatrix(), .{ .x0 = 0, .y0 = -advance, .x1 = self.current_font_size * 0.35, .y1 = 0 })
        else
            transformedBounds(self.userTextMatrix(), .{ .x0 = 0, .y0 = 0, .x1 = advance, .y1 = self.current_font_size });
        const text = try self.allocator.dupe(u8, " ");
        var glyph_transferred = false;
        errdefer if (!glyph_transferred) self.allocator.free(text);
        const font_name = if (self.current_font_name) |name| try self.allocator.dupe(u8, name) else null;
        errdefer if (!glyph_transferred) {
            if (font_name) |name| self.allocator.free(name);
        };
        const glyph_index: u32 = @intCast(self.glyphs.items.len);
        try self.glyphs.append(self.allocator, .{
            .page_index = self.page_index,
            .bbox = bbox,
            .text_matrix = self.userTextMatrix(),
            .font_name = font_name,
            .font_size = self.current_font_size,
            .text = text,
            .advance = advance,
            .font_space_advance = self.spaceAdvance(),
            .content_scope = self.current_scope,
            .raw_glyph_start = glyph_index,
            .semantic_run_id = if (self.current_actual_text != null) @intCast(self.actual_text_runs.items.len) else null,
            .generated = true,
            .actual_text = self.current_actual_text != null,
            .mcid = self.current_mcid,
            .writing_mode = self.current_writing_mode,
            .paint = self.paintEvidence(bbox),
        });
        glyph_transferred = true;
        try self.appendCharsForGlyph(glyph_index, bbox, ' ', " ", .unresolved, false, true, self.current_actual_text != null, self.current_writing_mode);
    }

    fn appendCharsForGlyph(self: *SpanCollector, glyph_index: u32, bbox: layout.BBox, source_code: u32, text: []const u8, mapping_source: encoding_mod.MappingSource, unicode_map_error: bool, generated: bool, actual_text: bool, writing_mode: u8) !void {
        var index: usize = 0;
        while (index < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            const end = @min(text.len, index + len);
            const char_text = try self.allocator.dupe(u8, text[index..end]);
            errdefer self.allocator.free(char_text);
            const font_name = if (self.current_font_name) |name| try self.allocator.dupe(u8, name) else null;
            errdefer if (font_name) |name| self.allocator.free(name);
            try self.chars.append(self.allocator, .{
                .page_index = self.page_index,
                .glyph_index = glyph_index,
                .bbox = bbox,
                .text_matrix = self.userTextMatrix(),
                .font_name = font_name,
                .font_size = self.current_font_size,
                .source_code = source_code,
                .text = char_text,
                .mapping_source = mapping_source,
                .unicode_map_error = unicode_map_error,
                .generated = generated,
                .hyphen = isHyphenText(char_text),
                .actual_text = actual_text,
                .mcid = self.current_mcid,
                .writing_mode = writing_mode,
                .paint = self.paintEvidence(bbox),
                .content_scope = self.current_scope,
            });
            index = end;
        }
    }

    fn scaledAdvance(self: *const SpanCollector, decoded: encoding_mod.FontEncoding.DecodedGlyph) f64 {
        var advance = decoded.glyph_width / 1000.0 * self.current_font_size;
        advance += self.current_char_spacing;
        if (std.mem.eql(u8, decoded.utf8_text, " ")) advance += self.current_word_spacing;
        return advance * (self.current_horizontal_scale / 100.0);
    }

    fn spaceAdvance(self: *const SpanCollector) f64 {
        return if (self.current_font_space_width > 0)
            (self.current_font_space_width / 1000.0 * self.current_font_size + self.current_char_spacing + self.current_word_spacing) * self.current_horizontal_scale / 100.0
        else
            0;
    }

    fn currentGlyphBBox(self: *const SpanCollector, advance: f64, decoded: encoding_mod.FontEncoding.DecodedGlyph) layout.BBox {
        const points = self.currentGlyphQuad(advance, decoded);
        return boundsOfPoints(points);
    }

    fn currentGlyphQuad(self: *const SpanCollector, advance: f64, decoded: encoding_mod.FontEncoding.DecodedGlyph) [4][2]f64 {
        const ascender = decoded.ascender / 1000.0 * self.current_font_size;
        const descender = decoded.descender / 1000.0 * self.current_font_size;
        const local = if (decoded.writing_mode == 1)
            layout.BBox{ .x0 = descender, .y0 = -advance, .x1 = ascender, .y1 = 0 }
        else
            layout.BBox{ .x0 = 0, .y0 = self.current_text_rise + descender, .x1 = advance, .y1 = self.current_text_rise + ascender };
        return transformedPoints(self.userTextMatrix(), local);
    }

    fn transformedBounds(matrix: [6]f64, box: layout.BBox) layout.BBox {
        return boundsOfPoints(transformedPoints(matrix, box));
    }

    fn transformedPoints(matrix: [6]f64, box: layout.BBox) [4][2]f64 {
        return .{
            transformPoint(matrix, box.x0, box.y0),
            transformPoint(matrix, box.x1, box.y0),
            transformPoint(matrix, box.x1, box.y1),
            transformPoint(matrix, box.x0, box.y1),
        };
    }

    fn boundsOfPoints(points: [4][2]f64) layout.BBox {
        var x0 = points[0][0];
        var y0 = points[0][1];
        var x1 = x0;
        var y1 = y0;
        for (points[1..]) |point| {
            x0 = @min(x0, point[0]);
            y0 = @min(y0, point[1]);
            x1 = @max(x1, point[0]);
            y1 = @max(y1, point[1]);
        }
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }

    fn transformPoint(matrix: [6]f64, x: f64, y: f64) [2]f64 {
        return .{
            matrix[0] * x + matrix[2] * y + matrix[4],
            matrix[1] * x + matrix[3] * y + matrix[5],
        };
    }

    fn unionOptionalBBox(existing: ?layout.BBox, next: layout.BBox) ?layout.BBox {
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

    fn fallbackBBox(x: f64, y: f64, width: f64, font_size: f64) layout.BBox {
        return .{ .x0 = x, .y0 = y - font_size * 0.2, .x1 = x + width, .y1 = y + font_size };
    }

    fn isHyphenText(text: []const u8) bool {
        return std.mem.eql(u8, text, "-") or
            std.mem.eql(u8, text, "\xC2\xAD") or
            std.mem.eql(u8, text, "\xE2\x80\x90") or
            std.mem.eql(u8, text, "\xE2\x80\x91") or
            std.mem.eql(u8, text, "\xE2\x88\x92");
    }
};

fn glyphNormalFontSize(matrix: [6]f64, declared_size: f64, writing_mode: u8) ?f64 {
    const axis_x = if (writing_mode == 1) -matrix[2] else matrix[0];
    const axis_y = if (writing_mode == 1) -matrix[3] else matrix[1];
    const axis_scale = @sqrt(axis_x * axis_x + axis_y * axis_y);
    if (!std.math.isFinite(axis_scale) or axis_scale <= 0) return null;
    const normal_scale = @abs(matrix[0] * matrix[3] - matrix[1] * matrix[2]) / axis_scale;
    const size = declared_size * normal_scale;
    return if (std.math.isFinite(size) and size > 0) size else null;
}

/// Operand types for content stream
pub const Operand = union(enum) {
    number: f64,
    string: []const u8,
    hex_string: []const u8,
    name: []const u8,
    array: []const Operand,

    pub fn asNumber(self: Operand) f64 {
        return switch (self) {
            .number => |n| n,
            else => 0,
        };
    }

    pub fn asName(self: Operand) ?[]const u8 {
        return switch (self) {
            .name => |n| n,
            else => null,
        };
    }
};

/// Content stream lexer
pub const ContentLexer = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    // Temporary storage for arrays
    array_buffer: [512]Operand = undefined,

    pub const Token = union(enum) {
        number: f64,
        string: []const u8,
        hex_string: []const u8,
        name: []const u8,
        operator: []const u8,
        array: []const Operand,
    };

    pub fn init(allocator: std.mem.Allocator, data: []const u8) ContentLexer {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
        };
    }

    pub fn next(self: *ContentLexer) !?Token {
        self.skipWhitespaceAndComments();

        if (self.pos >= self.data.len) return null;

        const c = self.data[self.pos];

        // String literal
        if (c == '(') return Token{ .string = try self.scanString() };

        // Hex string
        if (c == '<') {
            if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') {
                // Dictionary start - skip for content streams (inline images)
                self.pos += 2;
                return self.next();
            }
            return Token{ .hex_string = try self.scanHexString() };
        }

        // Name
        if (c == '/') return Token{ .name = self.scanName() };

        // Array
        if (c == '[') return Token{ .array = try self.scanArray() };

        // End markers
        if (c == ']' or c == '>') {
            self.pos += 1;
            return self.next();
        }

        // Number
        if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
            return Token{ .number = self.scanNumber() };
        }

        // Operator (identifier)
        if (isAlpha(c) or c == '\'' or c == '"' or c == '*') {
            const op = self.scanOperator();
            if (std.mem.eql(u8, op, "BI")) {
                self.skipInlineImage();
                return self.next();
            }
            return Token{ .operator = op };
        }

        // Unknown - skip
        self.pos += 1;
        return self.next();
    }

    fn skipWhitespaceAndComments(self: *ContentLexer) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00) {
                self.pos += 1;
            } else if (c == '%') {
                // Skip comment
                while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn scanString(self: *ContentLexer) ![]const u8 {
        self.pos += 1; // Skip '('
        var depth: usize = 1;

        // Use stack buffer for most strings (avoids heap allocations)
        var stack_buf: [4096]u8 = undefined;
        var stack_len: usize = 0;
        var overflow: ?std.ArrayList(u8) = null;
        errdefer if (overflow) |*list| list.deinit(self.allocator);

        while (self.pos < self.data.len and depth > 0) {
            const c = self.data[self.pos];

            if (c == '\\' and self.pos + 1 < self.data.len) {
                self.pos += 1;
                const escaped = self.data[self.pos];
                self.pos += 1;

                const decoded: u8 = switch (escaped) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'b' => 0x08,
                    'f' => 0x0C,
                    '(' => '(',
                    ')' => ')',
                    '\\' => '\\',
                    '\r' => {
                        // Line continuation - skip \r and optional \n
                        if (self.pos < self.data.len and self.data[self.pos] == '\n') {
                            self.pos += 1;
                        }
                        continue;
                    },
                    '\n' => continue, // Line continuation
                    '0'...'7' => blk: {
                        // Octal escape (1-3 digits)
                        var octal: u8 = escaped - '0';
                        var count: usize = 1;
                        while (count < 3 and self.pos < self.data.len) {
                            const oc = self.data[self.pos];
                            if (oc >= '0' and oc <= '7') {
                                octal = octal *% 8 +% (oc - '0');
                                self.pos += 1;
                                count += 1;
                            } else break;
                        }
                        break :blk octal;
                    },
                    else => escaped,
                };
                try appendByte(&stack_buf, &stack_len, &overflow, self.allocator, decoded);
            } else if (c == '(') {
                depth += 1;
                try appendByte(&stack_buf, &stack_len, &overflow, self.allocator, c);
                self.pos += 1;
            } else if (c == ')') {
                depth -= 1;
                if (depth > 0) {
                    try appendByte(&stack_buf, &stack_len, &overflow, self.allocator, c);
                }
                self.pos += 1;
            } else {
                try appendByte(&stack_buf, &stack_len, &overflow, self.allocator, c);
                self.pos += 1;
            }
        }

        return finalizeBuf(&stack_buf, stack_len, &overflow, self.allocator);
    }

    fn appendByte(stack_buf: *[4096]u8, stack_len: *usize, overflow: *?std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) !void {
        if (overflow.*) |*list| {
            try list.append(allocator, byte);
        } else if (stack_len.* < stack_buf.len) {
            stack_buf[stack_len.*] = byte;
            stack_len.* += 1;
        } else {
            // Overflow to heap - copy existing stack data first
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(allocator);
            try list.appendSlice(allocator, stack_buf[0..stack_len.*]);
            try list.append(allocator, byte);
            overflow.* = list;
        }
    }

    fn finalizeBuf(stack_buf: *[4096]u8, stack_len: usize, overflow: *?std.ArrayList(u8), allocator: std.mem.Allocator) ![]const u8 {
        if (overflow.*) |*list| {
            return list.toOwnedSlice(allocator);
        }
        if (stack_len == 0) return &.{};
        // Single allocation + copy
        const result = try allocator.alloc(u8, stack_len);
        @memcpy(result, stack_buf[0..stack_len]);
        return result;
    }

    fn scanHexString(self: *ContentLexer) ![]const u8 {
        self.pos += 1; // Skip '<'

        // Use stack buffer for most hex strings (avoids heap allocations)
        var stack_buf: [4096]u8 = undefined;
        var stack_len: usize = 0;
        var overflow: ?std.ArrayList(u8) = null;
        errdefer if (overflow) |*list| list.deinit(self.allocator);

        var high_nibble: ?u8 = null;

        while (self.pos < self.data.len and self.data[self.pos] != '>') {
            const c = self.data[self.pos];
            self.pos += 1;

            // Skip whitespace in hex strings
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

            const nibble: u8 = if (c >= '0' and c <= '9')
                c - '0'
            else if (c >= 'A' and c <= 'F')
                c - 'A' + 10
            else if (c >= 'a' and c <= 'f')
                c - 'a' + 10
            else
                continue;

            if (high_nibble) |high| {
                try appendByte(&stack_buf, &stack_len, &overflow, self.allocator, (high << 4) | nibble);
                high_nibble = null;
            } else {
                high_nibble = nibble;
            }
        }

        // Handle odd number of hex digits (pad with 0)
        if (high_nibble) |high| {
            try appendByte(&stack_buf, &stack_len, &overflow, self.allocator, high << 4);
        }

        if (self.pos < self.data.len) self.pos += 1; // Skip '>'
        return finalizeBuf(&stack_buf, stack_len, &overflow, self.allocator);
    }

    fn scanName(self: *ContentLexer) []const u8 {
        self.pos += 1; // Skip '/'
        const start = self.pos;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }

        return self.data[start..self.pos];
    }

    fn scanNumber(self: *ContentLexer) f64 {
        // Use fast SIMD-optimized float parsing
        if (simd.parseFloat(self.data[self.pos..])) |result| {
            self.pos += result.consumed;
            return result.value;
        }
        // Fallback for edge cases
        const start = self.pos;
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if ((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+') {
                self.pos += 1;
            } else {
                break;
            }
        }
        return std.fmt.parseFloat(f64, self.data[start..self.pos]) catch 0;
    }

    fn scanOperator(self: *ContentLexer) []const u8 {
        const start = self.pos;

        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c) or isDelimiter(c)) break;
            self.pos += 1;
        }

        return self.data[start..self.pos];
    }

    fn skipInlineImage(self: *ContentLexer) void {
        while (self.pos + 1 < self.data.len) {
            if (self.data[self.pos] == 'E' and self.data[self.pos + 1] == 'I') {
                const prev_ws = self.pos == 0 or isWhitespace(self.data[self.pos - 1]);
                const next_ws = self.pos + 2 >= self.data.len or
                    isWhitespace(self.data[self.pos + 2]) or
                    isDelimiter(self.data[self.pos + 2]);
                if (prev_ws and next_ws) {
                    self.pos += 2;
                    return;
                }
            }
            self.pos += 1;
        }
    }

    fn scanArray(self: *ContentLexer) ![]const Operand {
        self.pos += 1; // Skip '['

        var count: usize = 0;
        errdefer for (self.array_buffer[0..count]) |operand| {
            switch (operand) {
                .string, .hex_string => |text| if (text.len > 0) self.allocator.free(text),
                else => {},
            }
        };

        while (self.pos < self.data.len and count < 512) {
            self.skipWhitespaceAndComments();

            if (self.pos >= self.data.len) break;

            const c = self.data[self.pos];

            if (c == ']') {
                self.pos += 1;
                break;
            }

            // Parse element
            if (c == '(') {
                self.array_buffer[count] = .{ .string = try self.scanString() };
                count += 1;
            } else if (c == '<') {
                self.array_buffer[count] = .{ .hex_string = try self.scanHexString() };
                count += 1;
            } else if (c == '-' or c == '+' or c == '.' or (c >= '0' and c <= '9')) {
                self.array_buffer[count] = .{ .number = self.scanNumber() };
                count += 1;
            } else if (c == '/') {
                self.array_buffer[count] = .{ .name = self.scanName() };
                count += 1;
            } else {
                self.pos += 1;
            }
        }

        return self.array_buffer[0..count];
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C or c == 0x00;
}

fn isDelimiter(c: u8) bool {
    return c == '(' or c == ')' or c == '<' or c == '>' or
        c == '[' or c == ']' or c == '{' or c == '}' or
        c == '/' or c == '%';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ============================================================================
// TESTS
// ============================================================================

test "lexer basic tokens" {
    const content = "BT /F1 12 Tf (Hello) Tj ET";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    // BT
    const t1 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("BT", t1.operator);

    // /F1
    const t2 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("F1", t2.name);

    // 12
    const t3 = (try lexer.next()).?;
    try std.testing.expectEqual(@as(f64, 12), t3.number);

    // Tf
    const t4 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("Tf", t4.operator);

    // (Hello)
    const t5 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("Hello", t5.string);

    // Tj
    const t6 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("Tj", t6.operator);

    // ET
    const t7 = (try lexer.next()).?;
    try std.testing.expectEqualStrings("ET", t7.operator);

    // EOF
    const t8 = try lexer.next();
    try std.testing.expect(t8 == null);
}

test "lexer TJ array" {
    const content = "[(Hello ) -200 (World)] TJ";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const arr = (try lexer.next()).?;
    try std.testing.expect(arr == .array);
    try std.testing.expectEqual(@as(usize, 3), arr.array.len);

    const op = (try lexer.next()).?;
    try std.testing.expectEqualStrings("TJ", op.operator);
}

fn lexerAllocationProbe(allocator: std.mem.Allocator, content: []const u8, expected_length: usize) !void {
    var lexer = ContentLexer.init(allocator, content);
    const token = (try lexer.next()) orelse return error.TestUnexpectedResult;
    switch (token) {
        .string, .hex_string => |text| {
            defer if (text.len > 0) allocator.free(text);
            try std.testing.expectEqual(expected_length, text.len);
        },
        .array => |operands| {
            defer for (operands) |operand| switch (operand) {
                .string, .hex_string => |text| if (text.len > 0) allocator.free(text),
                else => {},
            };
            try std.testing.expectEqual(expected_length, operands.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "lexer string hex and TJ failures propagate instead of dropping text" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lexerAllocationProbe, .{ "(A)", @as(usize, 1) });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lexerAllocationProbe, .{ "<41>", @as(usize, 1) });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lexerAllocationProbe, .{ "[(A) 3 <42> (C)]", @as(usize, 4) });

    const literal = try std.testing.allocator.alloc(u8, 5002);
    defer std.testing.allocator.free(literal);
    literal[0] = '(';
    @memset(literal[1..5001], 'A');
    literal[5001] = ')';
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lexerAllocationProbe, .{ literal, @as(usize, 5000) });

    const hex = try std.testing.allocator.alloc(u8, 10002);
    defer std.testing.allocator.free(hex);
    hex[0] = '<';
    for (0..5000) |index| {
        hex[1 + 2 * index] = '4';
        hex[2 + 2 * index] = '1';
    }
    hex[10001] = '>';
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lexerAllocationProbe, .{ hex, @as(usize, 5000) });
}

test "lexer hex string decoding" {
    const content = "<48656C6C6F> Tj"; // "Hello" in hex

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const hex = (try lexer.next()).?;
    try std.testing.expect(hex == .hex_string);
    try std.testing.expectEqualStrings("Hello", hex.hex_string);
}

test "lexer hex string with whitespace" {
    const content = "<48 65 6C 6C 6F> Tj"; // "Hello" with spaces

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const hex = (try lexer.next()).?;
    try std.testing.expect(hex == .hex_string);
    try std.testing.expectEqualStrings("Hello", hex.hex_string);
}

test "lexer hex string odd digits" {
    const content = "<4F3> Tj"; // Odd number of hex digits, should pad with 0

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const hex = (try lexer.next()).?;
    try std.testing.expect(hex == .hex_string);
    // "4F" = 'O', "30" = '0' (padded)
    try std.testing.expectEqual(@as(u8, 'O'), hex.hex_string[0]);
    try std.testing.expectEqual(@as(u8, 0x30), hex.hex_string[1]);
}

test "lexer hex string CID codes" {
    const content = "<01F9020101FC> Tj"; // CID font codes

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const hex = (try lexer.next()).?;
    try std.testing.expect(hex == .hex_string);
    try std.testing.expectEqual(@as(usize, 6), hex.hex_string.len);
    try std.testing.expectEqual(@as(u8, 0x01), hex.hex_string[0]);
    try std.testing.expectEqual(@as(u8, 0xF9), hex.hex_string[1]);
    try std.testing.expectEqual(@as(u8, 0x02), hex.hex_string[2]);
    try std.testing.expectEqual(@as(u8, 0x01), hex.hex_string[3]);
}

test "lexer string escape sequences" {
    const content = "(Hello\\nWorld\\t!) Tj";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const str = (try lexer.next()).?;
    try std.testing.expect(str == .string);
    try std.testing.expectEqualStrings("Hello\nWorld\t!", str.string);
}

test "lexer string octal escape" {
    const content = "(\\101\\102\\103) Tj"; // ABC in octal

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const str = (try lexer.next()).?;
    try std.testing.expect(str == .string);
    try std.testing.expectEqualStrings("ABC", str.string);
}

test "lexer nested parentheses" {
    const content = "(Hello (nested) World) Tj";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const str = (try lexer.next()).?;
    try std.testing.expect(str == .string);
    try std.testing.expectEqualStrings("Hello (nested) World", str.string);
}

test "lexer negative numbers" {
    const content = "-100 -3.14 Td";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const n1 = (try lexer.next()).?;
    try std.testing.expectEqual(@as(f64, -100), n1.number);

    const n2 = (try lexer.next()).?;
    try std.testing.expectApproxEqAbs(@as(f64, -3.14), n2.number, 0.001);
}

test "lexer skips BI/EI inline image block" {
    // Content stream with an inline image sandwiched between two Tj operators.
    // The binary bytes \xAA\xBB\xCC are safe: they won't form a whitespace-bounded "EI".
    const content = "BT (Before) Tj BI /W 2 /H 2 ID \xAA\xBB\xCC EI (After) Tj ET";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    var tj_count: usize = 0;
    while (try lexer.next()) |tok| {
        switch (tok) {
            .operator => |op| {
                // BI and EI must never surface as operators — they are consumed
                try std.testing.expect(!std.mem.eql(u8, op, "BI"));
                try std.testing.expect(!std.mem.eql(u8, op, "EI"));
                if (std.mem.eql(u8, op, "Tj")) tj_count += 1;
            },
            else => {},
        }
    }

    // Both Tj operators (for "Before" and "After") must be present
    try std.testing.expectEqual(@as(usize, 2), tj_count);
}

test "lexer text operators" {
    const content = "BT Tf Tj TJ T* Td TD Tm ' \" ET";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lexer = ContentLexer.init(arena.allocator(), content);

    const ops = [_][]const u8{ "BT", "Tf", "Tj", "TJ", "T*", "Td", "TD", "Tm", "'", "\"", "ET" };
    for (ops) |expected| {
        const tok = (try lexer.next()).?;
        try std.testing.expectEqualStrings(expected, tok.operator);
    }
}

fn resolveNoop(_: ObjRef) Object {
    return .null;
}

test "content interpreter ignores text outside text objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    const writer = runtime.arrayListWriter(&output, std.testing.allocator);
    var interp = ContentInterpreter(@TypeOf(writer)).init(
        arena.allocator(),
        writer,
        "",
        null,
        resolveNoop,
    );
    defer interp.deinit();

    try interp.process("(Outside) Tj BT /F1 12 Tf (Inside) Tj ET (After) Tj");
    try std.testing.expectEqualStrings("Inside", output.items);
}

test "content interpreter applies leading and line text operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    const writer = runtime.arrayListWriter(&output, std.testing.allocator);
    var interp = ContentInterpreter(@TypeOf(writer)).init(
        arena.allocator(),
        writer,
        "",
        null,
        resolveNoop,
    );
    defer interp.deinit();

    const content =
        "BT " ++
        "/F1 12 Tf " ++
        "14 TL " ++
        "100 700 Td " ++
        "(Line1) Tj " ++
        "T* " ++
        "(Line2) Tj " ++
        "(Line3) ' " ++
        "0 0 (Line4) \" " ++
        "ET";

    try interp.process(content);
    try std.testing.expectEqualStrings("Line1\nLine2\nLine3\nLine4", output.items);
}

test "span collector derives bounds from decoded glyph advances" {
    var collector = SpanCollector.init(std.testing.allocator, 0);
    defer collector.deinit();

    collector.setPosition(100, 200);
    collector.setFont("F1", 10, true);
    collector.setTextMatrix(.{ 1, 0, 0, 1, 100, 200 });
    try collector.writeDecodedGlyph(.{
        .source_code = 'A',
        .source_bytes = "A",
        .bytes_consumed = 1,
        .utf8_text = "A",
        .glyph_width = 750,
        .ascender = 800,
        .descender = -200,
    });
    try collector.flush();

    try std.testing.expectEqual(@as(usize, 1), collector.getSpans().len);
    try std.testing.expectEqual(@as(usize, 1), collector.getGlyphs().len);
    try std.testing.expectEqual(@as(usize, 1), collector.getChars().len);

    const span = collector.getSpans()[0];
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), span.bbox.x1 - span.bbox.x0, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), span.bbox.y1 - span.bbox.y0, 0.001);
    try std.testing.expectEqualStrings("A", span.text);
    try std.testing.expectEqual(@as(?u8, null), span.paint.rendering_mode);
    try std.testing.expectEqual(.unknown, span.paint.paint_state);
    try std.testing.expectEqual(.unknown, collector.getGlyphs()[0].paint.clip_state);
    try std.testing.expectEqual(.unknown, collector.getChars()[0].paint.paint_state);
}

test "span collector retains declared Tf and records Tm CTM and inverse point scales" {
    const variants = [_]struct { font: f64, text_scale: f64, ctm_scale: f64 }{
        .{ .font = 1, .text_scale = 12, .ctm_scale = 1 },
        .{ .font = 120, .text_scale = 0.1, .ctm_scale = 1 },
        .{ .font = 1, .text_scale = 1, .ctm_scale = 12 },
    };
    for (variants) |variant| {
        var collector = SpanCollector.init(std.testing.allocator, 0);
        defer collector.deinit();
        collector.setFont("F1", variant.font, true);
        collector.setPosition(100, 200);
        collector.setTextMatrix(.{ variant.text_scale, 0, 0, variant.text_scale, 100, 200 });
        collector.setGraphicsState(.{ .ctm = .{ variant.ctm_scale, 0, 0, variant.ctm_scale, 0, 0 } });
        try collector.writeDecodedGlyph(.{ .source_code = 'A', .source_bytes = "A", .bytes_consumed = 1, .utf8_text = "A", .glyph_width = 750, .ascender = 800, .descender = -200 });
        try collector.flush();
        const span = collector.getSpans()[0];
        try std.testing.expectEqual(variant.font, span.font.size);
        try std.testing.expectEqual(variant.font, span.font_size);
        try std.testing.expectApproxEqAbs(@as(f64, 12), span.layout_font_size.?, 0.000001);
        try std.testing.expectApproxEqAbs(@as(f64, 12), span.y1 - span.y0, 0.000001);
        try std.testing.expectEqual(@as(f64, 0), collector.pending_layout_font_size);
        try collector.setActualText("Exact replacement");
        try collector.writeDecodedGlyph(.{ .source_code = 'B', .source_bytes = "B", .bytes_consumed = 1, .utf8_text = "B", .glyph_width = 750, .ascender = 800, .descender = -200 });
        try collector.setActualText(null);
        const replacement = collector.getSpans()[1];
        try std.testing.expectEqualStrings("Exact replacement", replacement.text);
        try std.testing.expectEqual(variant.font, replacement.font.size);
        try std.testing.expectApproxEqAbs(@as(f64, 12), replacement.layout_font_size.?, 0.000001);
    }
    try std.testing.expectEqual(@as(?f64, null), glyphNormalFontSize(.{ 0, 0, 0, 0, 0, 0 }, 12, 0));
}

test "span collector records generated gaps and vertical glyph movement" {
    var collector = SpanCollector.init(std.testing.allocator, 0);
    defer collector.deinit();

    collector.setPosition(50, 300);
    collector.setFont("Fv", 12, true);
    try collector.writeDecodedGlyph(.{
        .source_code = 0x41,
        .source_bytes = &[_]u8{ 0x00, 0x41 },
        .bytes_consumed = 2,
        .utf8_text = "A",
        .glyph_width = 1000,
        .writing_mode = 1,
    });
    try collector.advanceByTextAdjustment(6);
    try collector.flush();

    try std.testing.expect(collector.current_y < 300);
    var saw_generated = false;
    for (collector.getChars()) |char| {
        if (char.generated and std.mem.eql(u8, char.text, " ")) saw_generated = true;
    }
    try std.testing.expect(saw_generated);
}

test "semantic projection retains raw decoding errors bytes and scoped evidence independently" {
    const allocator = std.testing.allocator;
    var collector = SpanCollector.init(allocator, 3);
    defer collector.deinit();
    collector.setContentScope(.{ .page_index = 3, .stream_object_num = 42, .invocation_index = 9 });
    try collector.setActualText("correct 😀");
    try collector.writeDecodedGlyph(.{ .source_code = 255, .source_bytes = "\xff", .bytes_consumed = 1, .utf8_text = "bad", .glyph_width = 500, .mapping_source = .explicit_to_unicode, .unicode_map_error = true });
    try collector.setActualText(null);
    const projected = try collector.toOwnedSemanticGlyphSlice();
    defer {
        for (projected) |glyph| {
            allocator.free(@constCast(glyph.text));
            if (glyph.font_name) |name| allocator.free(@constCast(name));
        }
        allocator.free(projected);
    }
    try std.testing.expectEqualStrings("bad", collector.glyphs.items[0].text);
    try std.testing.expect(collector.glyphs.items[0].unicode_map_error);
    try std.testing.expect(collector.chars.items[0].unicode_map_error);
    try std.testing.expectEqual(@as(u8, 255), collector.glyphs.items[0].source_bytes[0]);
    try std.testing.expectEqualStrings("correct 😀", projected[0].text);
    try std.testing.expect(!projected[0].unicode_map_error);
    try std.testing.expectEqual(@as(?u32, 42), projected[0].content_scope.?.stream_object_num);
    try std.testing.expectEqual(@as(?u32, 42), collector.spans.items[0].content_scope.?.stream_object_num);
}

test "glyph and space advances scale spacing before the text matrix without invented zero widths" {
    var collector = SpanCollector.init(std.testing.allocator, 0);
    defer collector.deinit();
    collector.setFont("F1", 10, true);
    collector.current_font_space_width = 200;
    collector.setTextState(.{ .char_spacing = 1, .word_spacing = 2, .horizontal_scale = 200, .text_rise = 0 });
    collector.setTextMatrix(.{ 2, 0, 0, 2, 0, 0 });
    try collector.writeDecodedGlyph(.{ .source_code = 32, .source_bytes = " ", .bytes_consumed = 1, .utf8_text = " ", .glyph_width = 200 });
    try std.testing.expectEqual(@as(f64, 10), collector.glyphs.items[0].advance);
    try std.testing.expectEqual(@as(f64, 10), collector.glyphs.items[0].font_space_advance);
    try std.testing.expectEqual(@as(f64, 20), collector.current_x);
    try collector.writeDecodedGlyph(.{ .source_code = 88, .source_bytes = "X", .bytes_consumed = 1, .utf8_text = "X", .glyph_width = 0 });
    try std.testing.expectEqual(@as(f64, 2), collector.glyphs.items[1].advance);
}

fn spanCollectorAllocationProbe(allocator: std.mem.Allocator) !void {
    var collector = SpanCollector.init(allocator, 0);
    defer collector.deinit();

    collector.setPosition(50, 300);
    collector.setFont("F1", 12, true);
    try collector.writeDecodedGlyph(.{
        .source_code = 0x41,
        .source_bytes = "A",
        .bytes_consumed = 1,
        .utf8_text = "AB",
        .glyph_width = 1000,
    });
    try collector.advanceByTextAdjustment(6);
    try collector.flush();
}

test "span collector ownership is safe across every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        spanCollectorAllocationProbe,
        .{},
    );
}
