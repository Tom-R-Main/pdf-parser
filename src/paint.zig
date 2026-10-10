//! Conservative content-stream graphics evidence in PDF user space.
const std = @import("std");
const layout = @import("layout.zig");

pub const identity: [6]f64 = .{ 1, 0, 0, 1, 0, 0 };

pub fn concat(outer: [6]f64, inner: [6]f64) [6]f64 {
    return .{
        outer[0] * inner[0] + outer[2] * inner[1],
        outer[1] * inner[0] + outer[3] * inner[1],
        outer[0] * inner[2] + outer[2] * inner[3],
        outer[1] * inner[2] + outer[3] * inner[3],
        outer[0] * inner[4] + outer[2] * inner[5] + outer[4],
        outer[1] * inner[4] + outer[3] * inner[5] + outer[5],
    };
}

pub const State = struct {
    ctm: [6]f64 = identity,
    geometry_known: bool = true,
    rendering_mode: ?u8 = 0,
    clip_bbox: ?layout.BBox = null,
    clip_unknown: bool = false,

    pub fn evidence(self: State, box: layout.BBox) layout.PaintEvidence {
        const value: layout.PaintEvidence = .{
            .rendering_mode = self.rendering_mode,
            .paint_state = if (self.rendering_mode) |mode| (if (mode == 3 or mode == 7) .non_painting else .painting) else .unknown,
            .clip_state = if (self.clip_unknown or !self.geometry_known) .unknown else .unclipped,
            .clip_bbox = if (self.clip_unknown or !self.geometry_known) null else self.clip_bbox,
        };
        return value.forBBox(box);
    }
};

pub const Tracker = struct {
    state: State = .{},
    stack: std.ArrayList(State) = .empty,
    path_rect: ?layout.BBox = null,
    path_unknown: bool = false,
    pending_clip: bool = false,
    text_clip_pending: bool = false,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
    }

    pub fn save(self: *Tracker, allocator: std.mem.Allocator) !void {
        try self.stack.append(allocator, self.state);
    }

    pub fn restore(self: *Tracker) void {
        if (self.stack.pop()) |state| {
            self.state = state;
        } else {
            self.state.clip_unknown = true;
            self.state.rendering_mode = null;
        }
    }

    pub fn rectangle(self: *Tracker, x: f64, y: f64, width: f64, height: f64) void {
        const m = self.state.ctm;
        const aligned = (m[1] == 0 and m[2] == 0) or (m[0] == 0 and m[3] == 0);
        if (!aligned or !self.state.geometry_known or self.path_rect != null or self.path_unknown) {
            self.path_unknown = true;
            self.path_rect = null;
            return;
        }
        const ax = m[0] * x + m[2] * y + m[4];
        const ay = m[1] * x + m[3] * y + m[5];
        const bx = m[0] * (x + width) + m[2] * (y + height) + m[4];
        const by = m[1] * (x + width) + m[3] * (y + height) + m[5];
        if (!std.math.isFinite(ax) or !std.math.isFinite(ay) or !std.math.isFinite(bx) or !std.math.isFinite(by)) {
            self.path_unknown = true;
            return;
        }
        self.path_rect = .{ .x0 = @min(ax, bx), .y0 = @min(ay, by), .x1 = @max(ax, bx), .y1 = @max(ay, by) };
    }

    pub fn endPath(self: *Tracker) void {
        if (self.pending_clip) {
            if (self.path_unknown or self.path_rect == null or self.state.clip_unknown) {
                self.state.clip_unknown = true;
                self.state.clip_bbox = null;
            } else {
                var next = self.path_rect.?;
                if (self.state.clip_bbox) |old| {
                    next = .{ .x0 = @max(old.x0, next.x0), .y0 = @max(old.y0, next.y0), .x1 = @min(old.x1, next.x1), .y1 = @min(old.y1, next.y1) };
                    // Keep disjoint intersection as an empty rectangle.
                    next.x1 = @max(next.x0, next.x1);
                    next.y1 = @max(next.y0, next.y1);
                }
                self.state.clip_bbox = next;
            }
        }
        self.path_rect = null;
        self.path_unknown = false;
        self.pending_clip = false;
    }

    pub fn shownText(self: *Tracker) void {
        if (self.state.rendering_mode) |mode| {
            if (mode >= 4) self.text_clip_pending = true;
        } else {
            self.text_clip_pending = true;
        }
    }

    pub fn endText(self: *Tracker) void {
        if (self.text_clip_pending) {
            self.state.clip_unknown = true;
            self.state.clip_bbox = null;
        }
        self.text_clip_pending = false;
    }
};

test "rectangular clips classify geometry and intersect conservatively" {
    var tracker: Tracker = .{};
    tracker.rectangle(0, 0, 20, 20);
    tracker.pending_clip = true;
    try std.testing.expectEqual(.unclipped, tracker.state.evidence(.{}).clip_state);
    tracker.endPath();
    try std.testing.expectEqual(.inside, tracker.state.evidence(.{ .x0 = 2, .y0 = 2, .x1 = 8, .y1 = 8 }).clip_state);
    try std.testing.expectEqual(.outside, tracker.state.evidence(.{ .x0 = 30, .y0 = 2, .x1 = 38, .y1 = 8 }).clip_state);
    try std.testing.expectEqual(.partial, tracker.state.evidence(.{ .x0 = 10, .y0 = 2, .x1 = 28, .y1 = 8 }).clip_state);
    tracker.rectangle(30, 0, 20, 20);
    tracker.pending_clip = true;
    tracker.endPath();
    try std.testing.expectEqual(.outside, tracker.state.evidence(.{ .x0 = 25, .y0 = 2, .x1 = 35, .y1 = 8 }).clip_state);
}

test "rotated arbitrary clips are unknown rather than their bounding rectangle" {
    var tracker: Tracker = .{};
    tracker.state.ctm = .{ 1, 1, -1, 1, 0, 0 };
    tracker.rectangle(0, 0, 20, 20);
    tracker.pending_clip = true;
    tracker.endPath();
    try std.testing.expectEqual(.unknown, tracker.state.evidence(.{}).clip_state);
}
