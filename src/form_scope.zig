//! Content-stream identity and deterministic bounds for recursive Form traversal.
const std = @import("std");

pub const Scope = struct {
    page_index: u32,
    stream_object_num: ?u32 = null,
    stream_generation: u16 = 0,
    invocation_index: u32 = 0,

    pub fn page(page_index: u32) Scope {
        return .{ .page_index = page_index };
    }
};

pub const Reference = struct { object_num: u32, generation: u16 = 0 };

/// Keep one traversal per page/extraction. Repeated placements are valid after
/// leaving a frame; recursion through an already active stream is a cycle.
pub const Traversal = struct {
    pub const max_depth = 10;
    page_index: u32,
    max_invocations: u32 = 10_000,
    invocation_count: u32 = 0,
    active: [max_depth]Reference = undefined,
    depth: usize = 0,

    pub fn enter(self: *Traversal, reference: Reference) !Scope {
        for (self.active[0..self.depth]) |parent| {
            if (std.meta.eql(parent, reference)) return error.FormCycleDetected;
        }
        if (self.depth == max_depth) return error.FormDepthLimitExceeded;
        if (self.invocation_count >= self.max_invocations) return error.FormInvocationLimitExceeded;
        self.invocation_count += 1;
        self.active[self.depth] = reference;
        self.depth += 1;
        return .{
            .page_index = self.page_index,
            .stream_object_num = reference.object_num,
            .stream_generation = reference.generation,
            .invocation_index = self.invocation_count,
        };
    }

    pub fn leave(self: *Traversal) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }
};

test "Form scopes distinguish repeated placement and reject only active cycles" {
    var traversal = Traversal{ .page_index = 7 };
    const first = try traversal.enter(.{ .object_num = 42, .generation = 2 });
    try std.testing.expectError(error.FormCycleDetected, traversal.enter(.{ .object_num = 42, .generation = 2 }));
    const other_generation = try traversal.enter(.{ .object_num = 42, .generation = 3 });
    try std.testing.expectEqual(@as(u16, 3), other_generation.stream_generation);
    traversal.leave();
    traversal.leave();
    const second = try traversal.enter(.{ .object_num = 42, .generation = 2 });
    defer traversal.leave();
    try std.testing.expectEqual(@as(u32, 7), second.page_index);
    try std.testing.expectEqual(first.stream_object_num, second.stream_object_num);
    try std.testing.expect(first.invocation_index != second.invocation_index);
}

test "Form traversal depth and invocation bounds fail explicitly without pushing" {
    var traversal = Traversal{ .page_index = 0 };
    for (0..Traversal.max_depth) |index| _ = try traversal.enter(.{ .object_num = @intCast(index) });
    try std.testing.expectError(error.FormDepthLimitExceeded, traversal.enter(.{ .object_num = 99 }));
    try std.testing.expectEqual(Traversal.max_depth, traversal.depth);
    while (traversal.depth > 0) traversal.leave();
    traversal.max_invocations = traversal.invocation_count;
    try std.testing.expectError(error.FormInvocationLimitExceeded, traversal.enter(.{ .object_num = 99 }));
    try std.testing.expectEqual(@as(usize, 0), traversal.depth);
}
