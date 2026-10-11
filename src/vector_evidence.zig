//! Bounded painted-path evidence. Boxes are conservative PDF-user-space hulls,
//! not rendered visibility or retained paths.
const std = @import("std");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const geometry = @import("page_geometry.zig");
const interpreter = @import("interpreter.zig");
const form_scope = @import("form_scope.zig");

pub const Limits = struct {
    max_shapes: u32 = 512,
    max_segments_per_path: u32 = 512,
    max_operators: u32 = 100_000,
    max_graphics_depth: u32 = 32,
    max_form_invocations: u32 = 256,
    max_content_bytes: u32 = 8 * 1024 * 1024,
};
pub const Status = enum { complete, partial, limited };
pub const PaintKind = enum { fill, stroke, fill_stroke };
pub const ClipState = enum { unclipped, inside, partial, outside, unknown };
pub const Shape = struct {
    bbox: layout.BBox,
    paint_kind: PaintKind,
    rectangle_only: bool,
    segment_count: u32,
    subpath_count: u32,
    clip_state: ClipState,
    content_scope: ?form_scope.Scope,
};
pub const Evidence = struct {
    allocator: std.mem.Allocator,
    shapes: []Shape,
    status: Status,
    operator_count: u32,
    content_bytes: u32 = 0,
    unknown_count: u32,
    limits: Limits,

    pub fn deinit(self: *Evidence) void {
        self.allocator.free(self.shapes);
        self.* = undefined;
    }
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    shapes: std.ArrayList(Shape) = .empty,
    status: Status = .complete,
    operator_count: u32 = 0,
    content_bytes: u32 = 0,
    unknown_count: u32 = 0,
    limits: Limits = .{},
    stopped: bool = false,

    pub fn deinit(self: *Builder) void {
        self.shapes.deinit(self.allocator);
    }
    pub fn finish(self: *Builder) !Evidence {
        return .{ .allocator = self.allocator, .shapes = try self.shapes.toOwnedSlice(self.allocator), .status = self.status, .operator_count = self.operator_count, .content_bytes = self.content_bytes, .unknown_count = self.unknown_count, .limits = self.limits };
    }
    pub fn unknown(self: *Builder) void {
        if (self.status == .complete) self.status = .partial;
        self.unknown_count +|= 1;
    }
    pub fn limited(self: *Builder, stop: bool) void {
        self.status = .limited;
        self.stopped = self.stopped or stop;
    }
    pub fn operator(self: *Builder) bool {
        if (self.stopped) return false;
        if (self.operator_count >= self.limits.max_operators) {
            self.limited(true);
            return false;
        }
        self.operator_count += 1;
        return true;
    }
};

pub const Graphics = struct {
    paint_state: paint.State = .{},
    line_width: f64 = 1,
    // Miter joins can extend beyond the control hull.
    miter_limit: f64 = 10,
    line_join: u8 = 0,
};

pub const Collector = struct {
    builder: *Builder,
    graphics: Graphics = .{},
    scope: ?form_scope.Scope = null,
    stack: [32]Graphics = undefined,
    depth: usize = 0,
    bbox: ?layout.BBox = null,
    segments: u32 = 0,
    subpaths: u32 = 0,
    rectangle_only: bool = true,
    path_invalid: bool = false,
    current_point: bool = false,
    pending_clip: bool = false,
    clip_exact_rectangle: bool = true,
    text_clip_pending: bool = false,

    fn invalidate(self: *Collector) void {
        self.builder.unknown();
        self.path_invalid = true;
    }
    fn numbers(operands: []const interpreter.Operand, count: usize) ?[6]f64 {
        if (operands.len != count) return null;
        var values: [6]f64 = @splat(0);
        for (operands, 0..) |operand, index| {
            if (operand != .number or !std.math.isFinite(operand.number)) return null;
            values[index] = operand.number;
        }
        return values;
    }
    fn point(self: *Collector, x: f64, y: f64) void {
        if (!self.graphics.paint_state.geometry_known) {
            self.path_invalid = true;
            return;
        }
        const p = geometry.mapPoint(self.graphics.paint_state.ctm, .{ .x = x, .y = y }) catch {
            self.invalidate();
            return;
        };
        if (self.bbox) |*box| {
            box.x0 = @min(box.x0, p.x);
            box.y0 = @min(box.y0, p.y);
            box.x1 = @max(box.x1, p.x);
            box.y1 = @max(box.y1, p.y);
        } else self.bbox = .{ .x0 = p.x, .y0 = p.y, .x1 = p.x, .y1 = p.y };
    }
    fn segment(self: *Collector, count: u32) bool {
        if (count > self.builder.limits.max_segments_per_path -| self.segments) {
            self.builder.limited(false);
            self.path_invalid = true;
            return false;
        }
        self.segments += count;
        return true;
    }
    fn resetPath(self: *Collector) void {
        self.bbox = null;
        self.segments = 0;
        self.subpaths = 0;
        self.rectangle_only = true;
        self.path_invalid = false;
        self.current_point = false;
        self.pending_clip = false;
        self.clip_exact_rectangle = true;
    }
    fn endPath(self: *Collector, kind: ?PaintKind) !void {
        // Painting uses the previous clip; W is applied only at path end.
        if (kind) |paint_kind| {
            if (!self.path_invalid and self.segments > 0 and self.bbox != null) {
                var box = self.bbox.?;
                if (paint_kind != .fill) {
                    const m = self.graphics.paint_state.ctm;
                    const join_scale = if (self.graphics.line_join == 0 and self.segments > 2) @max(1, self.graphics.miter_limit) else 1;
                    const radius = self.graphics.line_width * 0.5 * join_scale;
                    const dx = radius * (@abs(m[0]) + @abs(m[2]));
                    const dy = radius * (@abs(m[1]) + @abs(m[3]));
                    box = .{ .x0 = box.x0 - dx, .y0 = box.y0 - dy, .x1 = box.x1 + dx, .y1 = box.y1 + dy };
                }
                if (!std.math.isFinite(box.x0) or !std.math.isFinite(box.y0) or !std.math.isFinite(box.x1) or !std.math.isFinite(box.y1)) {
                    self.builder.unknown();
                } else if (self.builder.shapes.items.len >= self.builder.limits.max_shapes) {
                    self.builder.limited(true);
                } else {
                    const clip = self.graphics.paint_state.evidence(box).clip_state;
                    if (clip == .partial) {
                        if (self.graphics.paint_state.clip_bbox) |bounds| {
                            box = .{ .x0 = @max(box.x0, bounds.x0), .y0 = @max(box.y0, bounds.y0), .x1 = @min(box.x1, bounds.x1), .y1 = @min(box.y1, bounds.y1) };
                        }
                    }
                    try self.builder.shapes.append(self.builder.allocator, .{ .bbox = box, .paint_kind = paint_kind, .rectangle_only = self.rectangle_only, .segment_count = self.segments, .subpath_count = self.subpaths, .clip_state = switch (clip) {
                        .unclipped => .unclipped,
                        .inside => .inside,
                        .outside => .outside,
                        .partial => .partial,
                        .unknown => .unknown,
                    }, .content_scope = self.scope });
                }
            }
        }
        if (self.pending_clip) {
            if (self.path_invalid or self.bbox == null or !self.clip_exact_rectangle or self.subpaths != 1 or !self.rectangle_only) {
                self.graphics.paint_state.clip_unknown = true;
                self.graphics.paint_state.clip_bbox = null;
                self.builder.unknown();
            } else if (!self.graphics.paint_state.clip_unknown) {
                var box = self.bbox.?;
                if (self.graphics.paint_state.clip_bbox) |old| {
                    box.x0 = @max(box.x0, old.x0);
                    box.y0 = @max(box.y0, old.y0);
                    box.x1 = @max(box.x0, @min(box.x1, old.x1));
                    box.y1 = @max(box.y0, @min(box.y1, old.y1));
                }
                self.graphics.paint_state.clip_bbox = box;
            }
        }
        self.resetPath();
    }

    /// Caller counts operators once, including Do handled outside this module.
    pub fn consume(self: *Collector, op: []const u8, operands: []const interpreter.Operand) !void {
        if (std.mem.eql(u8, op, "q")) {
            if (operands.len != 0) {
                self.invalidate();
                return;
            }
            if (self.depth >= @min(self.stack.len, self.builder.limits.max_graphics_depth)) {
                self.builder.limited(true);
                return;
            }
            self.stack[self.depth] = self.graphics;
            self.depth += 1;
        } else if (std.mem.eql(u8, op, "Q")) {
            if (operands.len != 0 or self.depth == 0) {
                self.invalidate();
                self.graphics.paint_state.geometry_known = false;
                return;
            }
            self.depth -= 1;
            self.graphics = self.stack[self.depth];
        } else if (std.mem.eql(u8, op, "cm")) {
            const values = numbers(operands, 6) orelse {
                self.invalidate();
                self.graphics.paint_state.geometry_known = false;
                return;
            };
            const matrix = paint.concat(self.graphics.paint_state.ctm, values);
            for (matrix) |value| if (!std.math.isFinite(value)) {
                self.invalidate();
                self.graphics.paint_state.geometry_known = false;
                return;
            };
            self.graphics.paint_state.ctm = matrix;
        } else if (std.mem.eql(u8, op, "m") or std.mem.eql(u8, op, "l")) {
            const values = numbers(operands, 2) orelse {
                self.invalidate();
                return;
            };
            const move = std.mem.eql(u8, op, "m");
            if (!move and !self.current_point) {
                self.invalidate();
                return;
            }
            if (!self.segment(1)) return;
            if (move) self.subpaths += 1;
            self.current_point = true;
            self.rectangle_only = false;
            self.point(values[0], values[1]);
        } else if (std.mem.eql(u8, op, "c") or std.mem.eql(u8, op, "v") or std.mem.eql(u8, op, "y")) {
            const count: usize = if (std.mem.eql(u8, op, "c")) 6 else 4;
            const values = numbers(operands, count) orelse {
                self.invalidate();
                return;
            };
            if (!self.current_point) {
                self.invalidate();
                return;
            }
            if (!self.segment(1)) return;
            self.rectangle_only = false;
            var index: usize = 0;
            while (index < count) : (index += 2) self.point(values[index], values[index + 1]);
        } else if (std.mem.eql(u8, op, "re")) {
            const values = numbers(operands, 4) orelse {
                self.invalidate();
                return;
            };
            if (!self.segment(4)) return;
            self.subpaths += 1;
            self.current_point = true;
            const m = self.graphics.paint_state.ctm;
            self.clip_exact_rectangle = self.clip_exact_rectangle and ((m[1] == 0 and m[2] == 0) or (m[0] == 0 and m[3] == 0));
            self.point(values[0], values[1]);
            self.point(values[0] + values[2], values[1]);
            self.point(values[0], values[1] + values[3]);
            self.point(values[0] + values[2], values[1] + values[3]);
        } else if (std.mem.eql(u8, op, "h")) {
            if (operands.len != 0 or !self.current_point) {
                self.invalidate();
                return;
            }
            _ = self.segment(1);
        } else if (std.mem.eql(u8, op, "W") or std.mem.eql(u8, op, "W*")) {
            if (operands.len != 0) self.invalidate();
            self.pending_clip = true;
        } else if (std.mem.eql(u8, op, "n") or std.mem.eql(u8, op, "f") or std.mem.eql(u8, op, "F") or std.mem.eql(u8, op, "f*") or std.mem.eql(u8, op, "S") or std.mem.eql(u8, op, "s") or std.mem.eql(u8, op, "B") or std.mem.eql(u8, op, "B*") or std.mem.eql(u8, op, "b") or std.mem.eql(u8, op, "b*")) {
            if (operands.len != 0) self.invalidate();
            if (std.mem.eql(u8, op, "s") or std.mem.eql(u8, op, "b") or std.mem.eql(u8, op, "b*")) {
                if (!self.current_point) self.invalidate() else _ = self.segment(1);
            }
            const kind: ?PaintKind = if (std.mem.eql(u8, op, "n")) null else if (op[0] == 'S' or op[0] == 's') .stroke else if (op[0] == 'B' or op[0] == 'b') .fill_stroke else .fill;
            try self.endPath(kind);
        } else if (std.mem.eql(u8, op, "w") or std.mem.eql(u8, op, "M") or std.mem.eql(u8, op, "j")) {
            const values = numbers(operands, 1) orelse {
                self.invalidate();
                self.graphics.paint_state.geometry_known = false;
                return;
            };
            if (std.mem.eql(u8, op, "w")) {
                if (values[0] <= 0) {
                    self.builder.unknown();
                    self.graphics.paint_state.geometry_known = false;
                } else self.graphics.line_width = values[0];
            } else if (std.mem.eql(u8, op, "M")) {
                if (values[0] < 1) {
                    self.invalidate();
                    self.graphics.paint_state.geometry_known = false;
                } else self.graphics.miter_limit = values[0];
            } else {
                if (values[0] < 0 or values[0] > 2 or @floor(values[0]) != values[0]) {
                    self.invalidate();
                    self.graphics.paint_state.geometry_known = false;
                } else self.graphics.line_join = @intFromFloat(values[0]);
            }
        } else if (std.mem.eql(u8, op, "gs")) {
            self.builder.unknown();
            self.graphics.paint_state.geometry_known = false;
            self.graphics.paint_state.clip_unknown = true;
        } else if (std.mem.eql(u8, op, "Tr")) {
            const values = numbers(operands, 1) orelse {
                self.builder.unknown();
                self.graphics.paint_state.rendering_mode = null;
                return;
            };
            if (values[0] < 0 or values[0] > 7 or @floor(values[0]) != values[0]) {
                self.builder.unknown();
                self.graphics.paint_state.rendering_mode = null;
            } else self.graphics.paint_state.rendering_mode = @intFromFloat(values[0]);
        } else if (std.mem.eql(u8, op, "Tj") or std.mem.eql(u8, op, "TJ") or std.mem.eql(u8, op, "'") or std.mem.eql(u8, op, "\"")) {
            if (self.graphics.paint_state.rendering_mode == null or self.graphics.paint_state.rendering_mode.? >= 4) self.text_clip_pending = true;
        } else if (std.mem.eql(u8, op, "ET")) {
            if (self.text_clip_pending) {
                self.graphics.paint_state.clip_unknown = true;
                self.graphics.paint_state.clip_bbox = null;
                self.builder.unknown();
            }
            self.text_clip_pending = false;
        } else {
            const ignored = [_][]const u8{ "Do", "BT", "Tf", "Tm", "Td", "TD", "T*", "Tc", "Tw", "Tz", "TL", "Ts", "J", "d", "ri", "i", "CS", "cs", "SC", "SCN", "sc", "scn", "G", "g", "RG", "rg", "K", "k", "BMC", "BDC", "EMC", "MP", "DP", "BX", "EX" };
            for (ignored) |known| if (std.mem.eql(u8, op, known)) return;
            self.builder.unknown();
            self.graphics.paint_state.geometry_known = false;
        }
    }
    pub fn endStream(self: *Collector) void {
        if (self.depth != 0 or self.bbox != null or self.pending_clip or self.text_clip_pending) self.builder.unknown();
    }
};

fn collectForTest(allocator: std.mem.Allocator, content: []const u8, limits: Limits) !Evidence {
    var builder = Builder{ .allocator = allocator, .limits = limits };
    defer builder.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var lexer = interpreter.ContentLexer.init(scratch.allocator(), content);
    var operands: [128]interpreter.Operand = undefined;
    var count: usize = 0;
    var collector = Collector{ .builder = &builder };
    while (!builder.stopped) {
        const token = (try lexer.next()) orelse break;
        switch (token) {
            .operator => |op| {
                if (!builder.operator()) break;
                try collector.consume(op, operands[0..count]);
                count = 0;
            },
            else => {
                if (count == operands.len) {
                    builder.limited(true);
                    break;
                }
                operands[count] = switch (token) {
                    .number => |v| .{ .number = v },
                    .name => |v| .{ .name = v },
                    .string => |v| .{ .string = v },
                    .hex_string => |v| .{ .hex_string = v },
                    .array => |v| .{ .array = v },
                    .operator => unreachable,
                };
                count += 1;
            },
        }
    }
    collector.endStream();
    return builder.finish();
}

test "vector evidence paints paths with transformed conservative cubic hulls" {
    var evidence = try collectForTest(std.testing.allocator, "q 2 0 0 3 10 20 cm 0 0 m 5 10 15 -5 20 0 c h f Q 1 2 3 4 re B", .{});
    defer evidence.deinit();
    try std.testing.expectEqual(.complete, evidence.status);
    try std.testing.expectEqual(@as(usize, 2), evidence.shapes.len);
    const curve = evidence.shapes[0];
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = 10, .y0 = 5, .x1 = 50, .y1 = 50 }, curve.bbox);
    try std.testing.expect(!curve.rectangle_only);
    try std.testing.expectEqual(@as(u32, 3), curve.segment_count);
    try std.testing.expectEqual(@as(u32, 1), curve.subpath_count);
    try std.testing.expectEqual(.fill_stroke, evidence.shapes[1].paint_kind);
    try std.testing.expect(evidence.shapes[1].rectangle_only);
}

test "single stroked segments have no miter join expansion" {
    var evidence = try collectForTest(std.testing.allocator, "0.5 w 40 155 m 360 155 l S", .{});
    defer evidence.deinit();
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = 39.75, .y0 = 154.75, .x1 = 360.25, .y1 = 155.25 }, evidence.shapes[0].bbox);
}

test "vector evidence clipping-only paths emit no shape and graphics restore clip" {
    var evidence = try collectForTest(std.testing.allocator, "q 0 0 20 20 re W n 2 2 3 3 re f 30 30 2 2 re f 18 18 5 5 re f Q 30 30 2 2 re f", .{});
    defer evidence.deinit();
    try std.testing.expectEqual(.complete, evidence.status);
    try std.testing.expectEqual(@as(usize, 4), evidence.shapes.len);
    try std.testing.expectEqual(.inside, evidence.shapes[0].clip_state);
    try std.testing.expectEqual(.outside, evidence.shapes[1].clip_state);
    try std.testing.expectEqual(.partial, evidence.shapes[2].clip_state);
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = 18, .y0 = 18, .x1 = 20, .y1 = 20 }, evidence.shapes[2].bbox);
    try std.testing.expectEqual(.unclipped, evidence.shapes[3].clip_state);
    var uncertain = try collectForTest(std.testing.allocator, "0 0 m 20 0 l 10 20 l h W* n 2 2 3 3 re f", .{});
    defer uncertain.deinit();
    try std.testing.expectEqual(.partial, uncertain.status);
    try std.testing.expectEqual(.unknown, uncertain.shapes[0].clip_state);
}

test "vector evidence malformed and unknown graphics withhold invented geometry" {
    var evidence = try collectForTest(std.testing.allocator, "0 0 m /bad 1 l f q /Alpha gs 0 0 2 2 re f Q 10 20 2 3 re f", .{});
    defer evidence.deinit();
    try std.testing.expectEqual(.partial, evidence.status);
    try std.testing.expectEqual(@as(usize, 1), evidence.shapes.len);
    try std.testing.expectEqualDeep(layout.BBox{ .x0 = 10, .y0 = 20, .x1 = 12, .y1 = 23 }, evidence.shapes[0].bbox);
    var builder = Builder{ .allocator = std.testing.allocator };
    defer builder.deinit();
    var collector = Collector{ .builder = &builder };
    try collector.consume("re", &.{ .{ .number = std.math.inf(f64) }, .{ .number = 0 }, .{ .number = 2 }, .{ .number = 3 } });
    try collector.consume("f", &.{});
    try std.testing.expectEqual(.partial, builder.status);
    try std.testing.expectEqual(@as(usize, 0), builder.shapes.items.len);
}

test "vector evidence resource caps preserve only bounded painted prefixes" {
    var shapes = try collectForTest(std.testing.allocator, "0 0 2 2 re f 3 3 2 2 re f", .{ .max_shapes = 1 });
    defer shapes.deinit();
    try std.testing.expectEqual(.limited, shapes.status);
    try std.testing.expectEqual(@as(usize, 1), shapes.shapes.len);
    var segments = try collectForTest(std.testing.allocator, "0 0 m 1 1 l 2 2 l f 3 3 m 4 4 l S", .{ .max_segments_per_path = 2 });
    defer segments.deinit();
    try std.testing.expectEqual(.limited, segments.status);
    try std.testing.expectEqual(@as(usize, 1), segments.shapes.len);
    var ops = try collectForTest(std.testing.allocator, "0 0 2 2 re f 3 3 2 2 re f", .{ .max_operators = 2 });
    defer ops.deinit();
    try std.testing.expectEqual(.limited, ops.status);
    try std.testing.expectEqual(@as(u32, 2), ops.operator_count);
    try std.testing.expectEqual(@as(usize, 1), ops.shapes.len);
    var stack = try collectForTest(std.testing.allocator, "q q 0 0 2 2 re f Q Q", .{ .max_graphics_depth = 1 });
    defer stack.deinit();
    try std.testing.expectEqual(.limited, stack.status);
    try std.testing.expectEqual(@as(usize, 0), stack.shapes.len);
}

test "vector evidence invalid stroke style persists past path end until graphics restore" {
    for ([_][]const u8{ "q /bad w n 0 0 2 2 re S Q 10 20 2 3 re f", "q -1 w n 0 0 2 2 re S Q 10 20 2 3 re f", "q 0 M n 0 0 2 2 re S Q 10 20 2 3 re f", "q 3 j n 0 0 2 2 re S Q 10 20 2 3 re f" }) |content| {
        var evidence = try collectForTest(std.testing.allocator, content, .{});
        defer evidence.deinit();
        try std.testing.expectEqual(.partial, evidence.status);
        try std.testing.expectEqual(@as(usize, 1), evidence.shapes.len);
        try std.testing.expectEqualDeep(layout.BBox{ .x0 = 10, .y0 = 20, .x1 = 12, .y1 = 23 }, evidence.shapes[0].bbox);
    }
}

fn vectorAllocationProbe(allocator: std.mem.Allocator) !void {
    var evidence = try collectForTest(allocator, "q 2 0 0 3 10 20 cm 0 0 20 20 re f Q 0 0 m 2 4 3 4 5 0 c S", .{});
    defer evidence.deinit();
    try std.testing.expectEqual(@as(usize, 2), evidence.shapes.len);
}

test "vector evidence frees partial allocations at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, vectorAllocationProbe, .{});
}
