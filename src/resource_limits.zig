//! Explicit budgets for serialized output and live allocator-owned bytes.
const std = @import("std");

pub fn LimitedWriter(comptime Writer: type) type {
    return struct {
        writer: Writer,
        max_bytes: ?usize,
        written: usize = 0,

        pub fn ensureCapacity(self: *const @This(), count: usize) !void {
            if (self.max_bytes) |limit| {
                if (count > limit - self.written) return error.OutputLimitExceeded;
            }
            if (count > std.math.maxInt(usize) - self.written) return error.OutputLimitExceeded;
        }

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.ensureCapacity(bytes.len);
            try self.writer.writeAll(bytes);
            self.written += bytes.len;
        }

        pub fn writeByte(self: *@This(), byte: u8) !void {
            try self.ensureCapacity(1);
            try self.writer.writeByte(byte);
            self.written += 1;
        }

        pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
            const count = std.fmt.count(fmt, args);
            try self.ensureCapacity(count);
            try self.writer.print(fmt, args);
            self.written += count;
        }
    };
}

pub const CountingWriter = struct {
    written: usize = 0,

    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        self.written = std.math.add(usize, self.written, bytes.len) catch return error.OutputLimitExceeded;
    }

    pub fn writeByte(self: *@This(), _: u8) !void {
        self.written = std.math.add(usize, self.written, 1) catch return error.OutputLimitExceeded;
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        self.written = std.math.add(usize, self.written, std.fmt.count(fmt, args)) catch return error.OutputLimitExceeded;
    }
};

/// Must remain at a stable address until every borrowed allocation is freed.
/// Counts requested live bytes, including simultaneous old/new realloc buffers;
/// excludes parent allocator metadata, document caches, and subprocess memory.
pub const BudgetAllocator = struct {
    parent: std.mem.Allocator,
    max_bytes: usize,
    live_bytes: std.atomic.Value(usize) = .init(0),
    limit_hit: std.atomic.Value(bool) = .init(false),

    pub fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn reserve(self: *BudgetAllocator, count: usize) bool {
        var live = self.live_bytes.load(.monotonic);
        while (true) {
            if (count > self.max_bytes - live) {
                self.limit_hit.store(true, .monotonic);
                return false;
            }
            live = self.live_bytes.cmpxchgWeak(live, live + count, .monotonic, .monotonic) orelse return true;
        }
    }

    fn release(self: *BudgetAllocator, count: usize) void {
        const previous = self.live_bytes.fetchSub(count, .monotonic);
        std.debug.assert(previous >= count);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        if (!self.reserve(len)) return null;
        return self.parent.rawAlloc(len, alignment, ra) orelse {
            self.release(len);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        const growth = new_len -| memory.len;
        if (!self.reserve(growth)) return false;
        if (!self.parent.rawResize(memory, alignment, new_len, ra)) {
            self.release(growth);
            return false;
        }
        self.release(memory.len -| new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        const growth = new_len -| memory.len;
        if (!self.reserve(growth)) return null;
        const ptr = self.parent.rawRemap(memory, alignment, new_len, ra) orelse {
            self.release(growth);
            return null;
        };
        self.release(memory.len -| new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(memory, alignment, ra);
        self.release(memory.len);
    }
};

test "limited writer rejects every operation before overrun" {
    const runtime = @import("runtime.zig");
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    var writer = LimitedWriter(runtime.ArrayListWriter){ .writer = runtime.arrayListWriter(&bytes, std.testing.allocator), .max_bytes = 5 };
    try writer.writeAll("ab");
    try writer.print("{d}", .{@as(u8, 12)});
    try std.testing.expectError(error.OutputLimitExceeded, writer.writeAll("cd"));
    try std.testing.expectError(error.OutputLimitExceeded, writer.print("{d}", .{@as(u8, 12)}));
    try writer.writeByte('!');
    try std.testing.expectError(error.OutputLimitExceeded, writer.writeByte('!'));
    try std.testing.expectEqualStrings("ab12!", bytes.items);
}

test "budget allocator accounts allocation resize remap and free" {
    var storage: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var budget = BudgetAllocator{ .parent = fixed.allocator(), .max_bytes = 16 };
    const allocator = budget.allocator();
    var bytes = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), budget.live_bytes.load(.monotonic));
    try std.testing.expect(allocator.resize(bytes, 12));
    bytes = bytes.ptr[0..12];
    try std.testing.expectEqual(@as(usize, 12), budget.live_bytes.load(.monotonic));
    try std.testing.expect(!allocator.resize(bytes, 17));
    try std.testing.expect(allocator.remap(bytes, 17) == null);
    try std.testing.expectEqual(@as(usize, 12), budget.live_bytes.load(.monotonic));
    bytes = allocator.remap(bytes, 4).?;
    try std.testing.expectEqual(@as(usize, 4), budget.live_bytes.load(.monotonic));
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.live_bytes.load(.monotonic));
    try std.testing.expect(budget.limit_hit.load(.monotonic));
}

test "budget allocator rolls back underlying allocation resize and remap failures" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var budget = BudgetAllocator{ .parent = failing.allocator(), .max_bytes = 64 };
    const allocator = budget.allocator();
    const bytes = try allocator.alloc(u8, 8);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 8));
    try std.testing.expect(!allocator.resize(bytes, 16));
    try std.testing.expect(allocator.remap(bytes, 16) == null);
    try std.testing.expectEqual(@as(usize, 8), budget.live_bytes.load(.monotonic));
    try std.testing.expect(!budget.limit_hit.load(.monotonic));
    allocator.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.live_bytes.load(.monotonic));
}

test "budget allocator concurrent reservations cannot overcommit" {
    var budget = BudgetAllocator{ .parent = std.testing.allocator, .max_bytes = 8 };
    var attempted = std.atomic.Value(usize).init(0);
    var admitted = std.atomic.Value(usize).init(0);
    const worker = try std.Thread.spawn(.{}, reservationWorker, .{ &budget, &attempted, &admitted });
    reservationWorker(&budget, &attempted, &admitted);
    worker.join();
    try std.testing.expectEqual(@as(usize, 1), admitted.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), budget.live_bytes.load(.monotonic));
}

fn reservationWorker(budget: *BudgetAllocator, attempted: *std.atomic.Value(usize), admitted: *std.atomic.Value(usize)) void {
    const accepted = budget.reserve(8);
    if (accepted) _ = admitted.fetchAdd(1, .monotonic);
    _ = attempted.fetchAdd(1, .monotonic);
    while (attempted.load(.monotonic) < 2) std.atomic.spinLoopHint();
    if (accepted) budget.release(8);
}
