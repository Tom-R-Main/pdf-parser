//! Isolated demonstration of logical arena boundaries invisible to Memcheck.
//! This deliberately writes into the adjacent object within a live slab.
const std = @import("std");
const runtime = @import("runtime.zig");
pub const memcheck_enabled = @import("memory_options").memcheck;

pub const main = runtime.MainWithArgs(run).main;

fn run(allocator: std.mem.Allocator, _: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const first = try arena.allocator().alloc(u8, 8);
    const second = try arena.allocator().alloc(u8, 8);
    @memset(first, 'a');
    @memset(second, 'b');
    if (@intFromPtr(second.ptr) != @intFromPtr(first.ptr) + first.len) return error.UnexpectedArenaLayout;
    const unchecked: [*]volatile u8 = first.ptr;
    unchecked[first.len] = '#';
    if (second[0] != '#') return error.ProbeDidNotExecute;
    try runtime.writeAllStdout("Arena logical overrun executed inside live backing allocation; logical boundary unchecked\n");
}
