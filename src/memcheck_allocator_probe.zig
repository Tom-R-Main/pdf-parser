const std = @import("std");
const tracking = @import("memcheck_allocator.zig");

fn expectTotals(counter: *const tracking.TrackingAllocator, allocations: u64, bytes: u64) !void {
    if (counter.liveAllocations() != allocations or counter.liveBytes() != bytes) {
        return error.AllocationAccountingMismatch;
    }
}

const RejectedResize = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return std.heap.c_allocator.rawAlloc(len, alignment, ret_addr);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        std.heap.c_allocator.rawFree(memory, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = free,
    };
};

pub fn main() !void {
    // A deliberately retained allocation must be observable before cleanup.
    // These are the same singleton counters exposed by the diagnostic library.
    const global_allocator = tracking.allocator();
    if (tracking.liveAllocations() != 0 or tracking.liveBytes() != 0) return error.NonzeroInitialTotals;
    const retained = try global_allocator.alloc(u8, 37);
    if (tracking.liveAllocations() != 1 or tracking.liveBytes() != 37) return error.RetainedAllocationInvisible;
    global_allocator.free(retained);
    if (tracking.liveAllocations() != 0 or tracking.liveBytes() != 0) return error.RetainedAllocationNotFreed;

    var counter: tracking.TrackingAllocator = .{ .backing = std.heap.c_allocator };
    const allocator = counter.allocator();
    var memory = try allocator.alloc(u8, 128);
    try expectTotals(&counter, 1, 128);
    if (!allocator.resize(memory, 64)) return error.LibcShrinkFailed;
    memory = memory[0..64];
    try expectTotals(&counter, 1, 64);
    const remapped = allocator.rawRemap(memory, .@"1", 8192, @returnAddress()) orelse return error.LibcRemapFailed;
    memory = remapped[0..8192];
    try expectTotals(&counter, 1, 8192);
    // Realloc may remap or allocate-copy-free; both must preserve one live block.
    memory = try allocator.realloc(memory, 16384);
    try expectTotals(&counter, 1, 16384);
    allocator.free(memory);
    try expectTotals(&counter, 0, 0);

    var context: u8 = 0;
    var rejected: tracking.TrackingAllocator = .{
        .backing = .{ .ptr = &context, .vtable = &RejectedResize.vtable },
    };
    const rejected_allocator = rejected.allocator();
    var fallback = try rejected_allocator.alloc(u8, 11);
    if (rejected_allocator.resize(fallback, 7)) return error.RejectedResizeSucceeded;
    if (rejected_allocator.rawRemap(fallback, .@"1", 29, @returnAddress()) != null) return error.RejectedRemapSucceeded;
    try expectTotals(&rejected, 1, 11);
    fallback = try rejected_allocator.realloc(fallback, 29);
    try expectTotals(&rejected, 1, 29);
    rejected_allocator.free(fallback);
    try expectTotals(&rejected, 0, 0);

    const failed_vtable: std.mem.Allocator.VTable = .{
        .alloc = std.mem.Allocator.noAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = RejectedResize.free,
    };
    var failed: tracking.TrackingAllocator = .{
        .backing = .{ .ptr = &context, .vtable = &failed_vtable },
    };
    if (failed.allocator().rawAlloc(23, .@"1", @returnAddress()) != null) return error.RejectedAllocationSucceeded;
    try expectTotals(&failed, 0, 0);
}
