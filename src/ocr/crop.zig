//! Pixel-aligned PDF crop geometry and bounded raster identity.
const std = @import("std");
const layout = @import("../layout.zig");
const page_geometry = @import("../page_geometry.zig");
const runtime = @import("../runtime.zig");

pub const Geometry = struct {
    pdf_bbox: layout.BBox,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub fn geometry(page: layout.BBox, region: layout.BBox, padding: f64, dpi: u32) ?Geometry {
    const page_transform = page_geometry.PageGeometry.init(page, null, 0, 1) catch return null;
    const plan = page_transform.planCrop(region, .{ .padding_points = padding, .dpi = @floatFromInt(dpi) }) catch return null;
    return .{
        .pdf_bbox = plan.pdf_bbox,
        .x = plan.x,
        .y = plan.y,
        .width = plan.width,
        .height = plan.height,
    };
}

pub fn withinPixelLimit(width: u32, height: u32, max_pixels: usize) bool {
    if (width == 0 or height == 0) return false;
    return @as(u64, width) * @as(u64, height) <= max_pixels;
}

pub const ImageIdentity = struct { width: u32, height: u32, sha256: [32]u8, byte_length: usize };

pub fn readIdentity(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize, max_pixels: usize) !ImageIdentity {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > max_bytes) return error.ImageByteLimitExceeded;
    if (size < 24) return error.InvalidRasterImage;
    var header: [24]u8 = undefined;
    if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidRasterImage;
    if (!std.mem.eql(u8, header[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, header[12..16], "IHDR")) return error.InvalidRasterImage;
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (!withinPixelLimit(width, height, max_pixels)) return error.ImagePixelLimitExceeded;
    const data = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(data);
    if (try file.readPositionalAll(io, data, 0) != data.len) return error.InvalidRasterImage;
    // Check growth after the bounded read as well. Never allocate from an
    // unvalidated file size or accept a changed file as the same artifact.
    if ((try file.stat(io)).size != size or !std.mem.eql(u8, data[0..24], &header)) return error.InvalidRasterImage;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return .{ .width = width, .height = height, .sha256 = digest, .byte_length = data.len };
}

test "OCR crops clamp and map nonzero page origins with outward pixel rounding" {
    const crop = geometry(.{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 120 }, .{ .x0 = 25.2, .y0 = 35.3, .x1 = 50.4, .y1 = 70.6 }, 0, 144).?;
    try std.testing.expectEqual(@as(u32, 30), crop.x);
    try std.testing.expectEqual(@as(u32, 98), crop.y);
    try std.testing.expectEqual(@as(u32, 51), crop.width);
    try std.testing.expectEqual(@as(u32, 72), crop.height);
    try std.testing.expectEqual(@as(f64, 25), crop.pdf_bbox.x0);
    try std.testing.expectEqual(@as(f64, 35), crop.pdf_bbox.y0);
    const edge = geometry(.{ .x0 = 10, .y0 = 20, .x1 = 110, .y1 = 120 }, .{ .x0 = 5, .y0 = 110, .x1 = 25, .y1 = 125 }, 2, 72).?;
    try std.testing.expectEqual(@as(u32, 0), edge.x);
    try std.testing.expectEqual(@as(u32, 0), edge.y);
    try std.testing.expectEqual(@as(u32, 17), edge.width);
    try std.testing.expectEqual(@as(u32, 12), edge.height);
}

test "OCR crop geometry rejects invalid bounds and pixel limits do not overflow" {
    const page = layout.BBox{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    try std.testing.expect(geometry(page, page, 0, 0) == null);
    try std.testing.expect(geometry(page, page, -1, 72) == null);
    try std.testing.expect(geometry(page, .{ .x0 = 200, .y0 = 200, .x1 = 300, .y1 = 300 }, 0, 72) == null);
    try std.testing.expect(geometry(page, .{ .x0 = std.math.nan(f64), .y0 = 0, .x1 = 1, .y1 = 1 }, 0, 72) == null);
    try std.testing.expect(!withinPixelLimit(std.math.maxInt(u32), std.math.maxInt(u32), 100));
    try std.testing.expect(withinPixelLimit(10, 10, 100));
    try std.testing.expect(!withinPixelLimit(10, 10, 99));
}

fn imageAllocationProbe(allocator: std.mem.Allocator, path: []const u8) !void {
    const image = try readIdentity(allocator, path, 24, 200);
    try std.testing.expectEqual(@as(usize, 24), image.byte_length);
}

test "bounded raster identity validates bytes pixels hashes and allocation cleanup" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    runtime.setIo(threaded.io());
    const path = try std.fmt.allocPrint(std.testing.allocator, ".pdf-parser-crop-identity-{x}.png", .{runtime.nanoTimestamp()});
    defer std.testing.allocator.free(path);
    defer runtime.deleteFileCwd(path);
    const header = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x0a\x00\x00\x00\x14";
    const file = try runtime.createFileCwd(path);
    try runtime.writeAllFile(file, header);
    runtime.closeFile(file);
    const image = try readIdentity(std.testing.allocator, path, 24, 200);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(header, &hash, .{});
    try std.testing.expectEqualSlices(u8, &hash, &image.sha256);
    try std.testing.expectEqual(@as(u32, 10), image.width);
    try std.testing.expectEqual(@as(u32, 20), image.height);
    try std.testing.expectError(error.ImageByteLimitExceeded, readIdentity(std.testing.allocator, path, 23, 200));
    try std.testing.expectError(error.ImagePixelLimitExceeded, readIdentity(std.testing.allocator, path, 24, 199));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, imageAllocationProbe, .{path});
}
