//! Real recognition and teardown for the optional Memcheck OCR lane.
const std = @import("std");
const runtime = @import("runtime.zig");
const ocr = @import("ocr.zig");
pub const memcheck_enabled = @import("memory_options").memcheck;

pub const main = runtime.MainWithArgs(run).main;

fn token(data: []const u8, position: *usize) ![]const u8 {
    while (position.* < data.len) {
        if (std.ascii.isWhitespace(data[position.*])) {
            position.* += 1;
        } else if (data[position.*] == '#') {
            while (position.* < data.len and data[position.*] != '\n') position.* += 1;
        } else break;
    }
    const start = position.*;
    while (position.* < data.len and !std.ascii.isWhitespace(data[position.*])) position.* += 1;
    if (start == position.*) return error.InvalidRaster;
    return data[start..position.*];
}

fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 2) return error.ExpectedPgmPath;
    // Read only the generated PGM header through libc. Zig's positional vector
    // reader calls preadv, absent from the macOS fork's syscall wrappers.
    const path_z = try allocator.dupeSentinel(u8, args[1], 0);
    defer allocator.free(path_z);
    const file = std.c.fopen(path_z, "rb") orelse return error.ImageReadFailed;
    defer _ = std.c.fclose(file);
    var header: [4096]u8 = undefined;
    const count = std.c.fread(&header, 1, header.len, file);
    const image = header[0..count];
    var position: usize = 0;
    if (!std.mem.eql(u8, try token(image, &position), "P5")) return error.InvalidRaster;
    const width = try std.fmt.parseInt(u32, try token(image, &position), 10);
    const height = try std.fmt.parseInt(u32, try token(image, &position), 10);
    if (!std.mem.eql(u8, try token(image, &position), "255")) return error.InvalidRaster;
    if (width == 0 or height == 0) return error.InvalidRaster;

    for (0..3) |_| {
        const spans = try ocr.recognizeRegion(allocator, .{
            .page_index = 0,
            .pdf_bbox = .{ .x0 = 0, .y0 = 0, .x1 = @floatFromInt(width), .y1 = @floatFromInt(height) },
            .image_path = args[1],
            .pixel_width = width,
            .pixel_height = height,
        }, .{ .backend = .tesseract_c, .psm = .single_block, .dpi = 200 });
        defer ocr.freeSpans(allocator, spans);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (spans) |span| {
            try text.appendSlice(allocator, span.text);
            try text.append(allocator, ' ');
        }
        if (std.mem.indexOf(u8, text.items, "SCANNED") == null or
            std.mem.indexOf(u8, text.items, "TYPEWRITTEN") == null) return error.UnexpectedRecognition;
    }
    try runtime.writeAllStdout("OCR recognition and teardown passed (3 iterations)\n");
}
