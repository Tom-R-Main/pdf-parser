const std = @import("std");

/// Diagnostic accounting preserves the backing allocator's actual addresses and
/// allocation boundaries. Counts describe requested live bytes, not libc's
/// reserved bytes. Read both totals only while parser operations are quiescent.
pub const TrackingAllocator = struct {
    backing: std.mem.Allocator,
    live_allocations: std.atomic.Value(u64) = .init(0),
    live_bytes: std.atomic.Value(u64) = .init(0),

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn liveAllocations(self: *const TrackingAllocator) u64 {
        return self.live_allocations.load(.monotonic);
    }

    pub fn liveBytes(self: *const TrackingAllocator) u64 {
        return self.live_bytes.load(.monotonic);
    }

    fn changeSize(self: *TrackingAllocator, previous: usize, next: usize) void {
        if (next >= previous) {
            _ = self.live_bytes.fetchAdd(@intCast(next - previous), .monotonic);
        } else {
            _ = self.live_bytes.fetchSub(@intCast(previous - next), .monotonic);
        }
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.live_allocations.fetchAdd(1, .monotonic);
        _ = self.live_bytes.fetchAdd(@intCast(len), .monotonic);
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.changeSize(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const new_memory = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.changeSize(memory.len, new_len);
        return new_memory;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        _ = self.live_allocations.fetchSub(1, .monotonic);
        _ = self.live_bytes.fetchSub(@intCast(memory.len), .monotonic);
    }
};

var libc_tracking: TrackingAllocator = .{ .backing = std.heap.c_allocator };

pub fn allocator() std.mem.Allocator {
    return libc_tracking.allocator();
}

pub fn liveAllocations() u64 {
    return libc_tracking.liveAllocations();
}

pub fn liveBytes() u64 {
    return libc_tracking.liveBytes();
}
