//! PDF Stream Decompression
//!
//! PDF supports multiple compression filters. In practice:
//! - FlateDecode (zlib/deflate): ~90% of streams
//! - DCTDecode (JPEG): images only
//! - ASCII85Decode: legacy, rare
//! - ASCIIHexDecode: legacy, rare
//! - LZWDecode: legacy, some old PDFs
//! - CCITTFaxDecode: fax images
//!
//! We optimize heavily for FlateDecode since it's the hot path.

const std = @import("std");
const Object = @import("parser.zig").Object;

pub const DecompressError = error{
    UnsupportedFilter,
    InvalidFilterParams,
    DecompressFailed,
    OutputTooLarge,
    InvalidPredictor,
};

/// Maximum decompressed size (prevent DoS)
const MAX_DECOMPRESSED_SIZE: usize = 256 * 1024 * 1024; // 256 MB

/// Per-stage decoded byte limit. This does not bound aggregate live memory.
pub const Options = struct {
    max_output_bytes: usize = MAX_DECOMPRESSED_SIZE,
};

/// Resource refusals must never become successful raw-byte recovery.
pub fn isResourceError(err: anyerror) bool {
    return err == error.OutputTooLarge or err == error.OutOfMemory;
}

/// Decompress a PDF stream based on its /Filter entry
pub fn decompressStream(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter: ?Object,
    params: ?Object,
) ![]u8 {
    return decompressStreamWithOptions(allocator, data, filter, params, .{});
}

pub fn decompressStreamWithOptions(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter: ?Object,
    params: ?Object,
    options: Options,
) ![]u8 {
    const filters = switch (filter orelse return boundedDupe(allocator, data, options.max_output_bytes)) {
        .name => |n| &[_][]const u8{n},
        .array => |arr| blk: {
            var names: [16][]const u8 = undefined;
            var count: usize = 0;
            for (arr) |item| {
                if (item == .name and count < 16) {
                    names[count] = item.name;
                    count += 1;
                }
            }
            break :blk names[0..count];
        },
        else => return boundedDupe(allocator, data, options.max_output_bytes),
    };

    var current = data;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);

    for (filters, 0..) |f, i| {
        const param = if (params) |p| switch (p) {
            .dict => p,
            .array => |arr| if (i < arr.len) arr[i] else null,
            else => null,
        } else null;

        const result = try applyFilter(allocator, current, f, param, options.max_output_bytes);

        if (owned) |o| allocator.free(o);
        owned = result;
        current = result;
    }

    const final = owned orelse try boundedDupe(allocator, data, options.max_output_bytes);
    owned = null; // Prevent double-free
    return final;
}

fn applyFilter(
    allocator: std.mem.Allocator,
    data: []const u8,
    filter_name: []const u8,
    params: ?Object,
    max_size: usize,
) ![]u8 {
    if (std.mem.eql(u8, filter_name, "FlateDecode") or
        std.mem.eql(u8, filter_name, "Fl"))
    {
        return decodeFlateDecodeWithLimit(allocator, data, params, max_size);
    }

    if (std.mem.eql(u8, filter_name, "ASCII85Decode") or
        std.mem.eql(u8, filter_name, "A85"))
    {
        return decodeASCII85WithLimit(allocator, data, max_size);
    }

    if (std.mem.eql(u8, filter_name, "ASCIIHexDecode") or
        std.mem.eql(u8, filter_name, "AHx"))
    {
        return decodeASCIIHexWithLimit(allocator, data, max_size);
    }

    if (std.mem.eql(u8, filter_name, "LZWDecode") or
        std.mem.eql(u8, filter_name, "LZW"))
    {
        const decoded = try decodeLZWWithLimit(allocator, data, params, max_size);
        errdefer allocator.free(decoded);
        if (params) |p| {
            if (p == .dict and (p.dict.getInt("Predictor") orelse 1) != 1) {
                const predicted = try applyDecodePredictor(allocator, decoded, params, max_size);
                allocator.free(decoded);
                return predicted;
            }
        }
        return decoded;
    }

    if (std.mem.eql(u8, filter_name, "RunLengthDecode") or
        std.mem.eql(u8, filter_name, "RL"))
    {
        return decodeRunLengthWithLimit(allocator, data, max_size);
    }

    // DCTDecode (JPEG) and CCITTFaxDecode are for images - pass through for now
    if (std.mem.eql(u8, filter_name, "DCTDecode") or
        std.mem.eql(u8, filter_name, "DCT") or
        std.mem.eql(u8, filter_name, "CCITTFaxDecode") or
        std.mem.eql(u8, filter_name, "CCF") or
        std.mem.eql(u8, filter_name, "JBIG2Decode") or
        std.mem.eql(u8, filter_name, "JPXDecode"))
    {
        // These are image formats - return as-is for image extraction
        return boundedDupe(allocator, data, max_size);
    }

    return DecompressError.UnsupportedFilter;
}

fn boundedDupe(allocator: std.mem.Allocator, data: []const u8, max_size: usize) ![]u8 {
    if (data.len > max_size) return DecompressError.OutputTooLarge;
    return allocator.dupe(u8, data);
}

fn appendBounded(output: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, max_size: usize) !void {
    if (output.items.len > max_size or bytes.len > max_size - output.items.len) return DecompressError.OutputTooLarge;
    try ensureBoundedCapacity(output, allocator, output.items.len + bytes.len, max_size);
    output.appendSliceAssumeCapacity(bytes);
}

// ============================================================================
// FLATEDECODE - THE HOT PATH
// ============================================================================

fn decodeFlateDecodeWithLimit(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
    max_size: usize,
) ![]u8 {
    // Use Zig's built-in zlib/flate decompressor
    var input: std.Io.Reader = .fixed(data);
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = .init(&input, .zlib, &decompress_buffer);

    // Pull bounded chunks and grow capacity precisely so a compression bomb
    // cannot make the allocating writer reserve beyond the configured cap.
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = decomp.reader.readSliceShort(&chunk) catch return DecompressError.DecompressFailed;
        if (output.items.len > max_size or read_count > max_size - output.items.len) {
            return DecompressError.OutputTooLarge;
        }
        const new_len = output.items.len + read_count;
        try ensureBoundedCapacity(&output, allocator, new_len, max_size);
        output.appendSliceAssumeCapacity(chunk[0..read_count]);
        if (read_count < chunk.len) break;
    }

    // Apply predictor if specified
    if (params) |p| {
        if (p == .dict) {
            const predictor_value = p.dict.getInt("Predictor") orelse 1;
            const predictor = std.math.cast(i32, predictor_value) orelse
                return DecompressError.InvalidFilterParams;
            if (predictor < 1) return DecompressError.InvalidPredictor;

            if (predictor > 1) {
                const columns = try positivePredictorParam(p.dict, "Columns", 1);
                const colors = try positivePredictorParam(p.dict, "Colors", 1);
                const bits = try positivePredictorParam(p.dict, "BitsPerComponent", 8);

                const unpredicted = try applyPredictorWithLimit(
                    allocator,
                    output.items,
                    predictor,
                    columns,
                    colors,
                    bits,
                    max_size,
                );
                return unpredicted;
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

fn ensureBoundedCapacity(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    needed: usize,
    max_size: usize,
) !void {
    if (needed <= output.capacity) return;
    std.debug.assert(needed <= max_size);

    var target = @min(max_size, @max(needed, @as(usize, 64 * 1024)));
    if (output.capacity > 0) {
        target = output.capacity;
        while (target < needed) {
            target = if (target > max_size / 2) max_size else target * 2;
        }
    }
    try output.ensureTotalCapacityPrecise(allocator, target);
}

fn applyDecodePredictor(allocator: std.mem.Allocator, data: []const u8, params: ?Object, max_size: usize) ![]u8 {
    const dict = if (params) |p| switch (p) {
        .dict => p.dict,
        else => return boundedDupe(allocator, data, max_size),
    } else return boundedDupe(allocator, data, max_size);
    const predictor = std.math.cast(i32, dict.getInt("Predictor") orelse 1) orelse return DecompressError.InvalidFilterParams;
    return applyPredictorWithLimit(allocator, data, predictor, try positivePredictorParam(dict, "Columns", 1), try positivePredictorParam(dict, "Colors", 1), try positivePredictorParam(dict, "BitsPerComponent", 8), max_size);
}

fn applyPredictorWithLimit(
    allocator: std.mem.Allocator,
    data: []const u8,
    predictor: i32,
    columns: u32,
    colors: u32,
    bits: u32,
    max_size: usize,
) ![]u8 {
    if (predictor == 1) {
        // No prediction
        return boundedDupe(allocator, data, max_size);
    }

    if (predictor == 2) {
        // TIFF Predictor 2
        if (data.len > max_size) return DecompressError.OutputTooLarge;
        return applyTiffPredictor(allocator, data, columns, colors, bits);
    }

    if (predictor >= 10 and predictor <= 15) {
        // PNG predictors
        return applyPngPredictorWithLimit(allocator, data, columns, colors, bits, max_size);
    }

    return DecompressError.InvalidPredictor;
}

fn applyTiffPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    if (columns == 0 or colors == 0 or bits != 8) return DecompressError.InvalidFilterParams;

    const bytes_per_row_u32 = std.math.mul(u32, columns, colors) catch
        return DecompressError.InvalidFilterParams;
    const bytes_per_row: usize = bytes_per_row_u32;
    if (data.len % bytes_per_row != 0) return DecompressError.InvalidPredictor;
    const num_rows = data.len / bytes_per_row;

    var output = try allocator.alloc(u8, data.len);
    errdefer allocator.free(output);

    var row: usize = 0;
    while (row < num_rows) : (row += 1) {
        const row_start = row * bytes_per_row;
        const row_data = data[row_start..][0..bytes_per_row];
        const out_row = output[row_start..][0..bytes_per_row];

        // First pixel unchanged
        var col: usize = 0;
        while (col < colors) : (col += 1) {
            out_row[col] = row_data[col];
        }

        // Subsequent pixels: add to previous
        while (col < bytes_per_row) : (col += 1) {
            out_row[col] = row_data[col] +% out_row[col - colors];
        }
    }

    return output;
}

fn applyPngPredictor(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
) ![]u8 {
    return applyPngPredictorWithLimit(allocator, data, columns, colors, bits, MAX_DECOMPRESSED_SIZE);
}

fn applyPngPredictorWithLimit(
    allocator: std.mem.Allocator,
    data: []const u8,
    columns: u32,
    colors: u32,
    bits: u32,
    max_size: usize,
) ![]u8 {
    if (columns == 0 or colors == 0 or !validPredictorBits(bits)) {
        return DecompressError.InvalidFilterParams;
    }

    const colors_usize: usize = colors;
    const bits_usize: usize = bits;
    const columns_usize: usize = columns;
    const color_bits = std.math.mul(usize, colors_usize, bits_usize) catch
        return DecompressError.InvalidFilterParams;
    const bytes_per_pixel_rounded = std.math.add(usize, color_bits, 7) catch
        return DecompressError.InvalidFilterParams;
    const bytes_per_pixel = bytes_per_pixel_rounded / 8;
    const row_bits = std.math.mul(usize, columns_usize, color_bits) catch
        return DecompressError.InvalidFilterParams;
    const row_bytes_rounded = std.math.add(usize, row_bits, 7) catch
        return DecompressError.InvalidFilterParams;
    const row_bytes = row_bytes_rounded / 8;
    const src_row_bytes = std.math.add(usize, row_bytes, 1) catch
        return DecompressError.InvalidFilterParams;

    if (data.len % src_row_bytes != 0) return DecompressError.InvalidPredictor;

    const num_rows = data.len / src_row_bytes;
    const out_len = std.math.mul(usize, num_rows, row_bytes) catch
        return DecompressError.InvalidFilterParams;

    if (out_len > max_size) return DecompressError.OutputTooLarge;

    var output = try allocator.alloc(u8, out_len);
    errdefer allocator.free(output);

    var prev_row: ?[]const u8 = null;

    var row: usize = 0;
    while (row < num_rows) : (row += 1) {
        const src_start = row * src_row_bytes;
        if (src_start >= data.len) break;

        const filter_type = data[src_start];
        const src_row = data[src_start + 1 ..][0..row_bytes];
        const out_row = output[row * row_bytes ..][0..row_bytes];

        switch (filter_type) {
            0 => {
                // None
                @memcpy(out_row, src_row);
            },
            1 => {
                // Sub
                for (out_row, 0..) |*b, i| {
                    const left: u8 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    b.* = src_row[i] +% left;
                }
            },
            2 => {
                // Up
                for (out_row, 0..) |*b, i| {
                    const up: u8 = if (prev_row) |pr| pr[i] else 0;
                    b.* = src_row[i] +% up;
                }
            },
            3 => {
                // Average
                for (out_row, 0..) |*b, i| {
                    const left: u16 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    const up: u16 = if (prev_row) |pr| pr[i] else 0;
                    b.* = src_row[i] +% @as(u8, @truncate((left + up) / 2));
                }
            },
            4 => {
                // Paeth
                for (out_row, 0..) |*b, i| {
                    const left: i16 = if (i >= bytes_per_pixel) out_row[i - bytes_per_pixel] else 0;
                    const up: i16 = if (prev_row) |pr| pr[i] else 0;
                    const up_left: i16 = if (prev_row != null and i >= bytes_per_pixel)
                        prev_row.?[i - bytes_per_pixel]
                    else
                        0;

                    b.* = src_row[i] +% paeth(left, up, up_left);
                }
            },
            else => {
                return DecompressError.InvalidPredictor;
            },
        }

        prev_row = out_row;
    }

    return output;
}

fn positivePredictorParam(dict: Object.Dict, key: []const u8, default: u32) DecompressError!u32 {
    const value = dict.getInt(key) orelse return default;
    const converted = std.math.cast(u32, value) orelse return DecompressError.InvalidFilterParams;
    if (converted == 0) return DecompressError.InvalidFilterParams;
    return converted;
}

fn validPredictorBits(bits: u32) bool {
    return bits == 1 or bits == 2 or bits == 4 or bits == 8 or bits == 16;
}

fn paeth(a: i16, b: i16, c: i16) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) {
        return @truncate(@as(u16, @bitCast(a)));
    } else if (pb <= pc) {
        return @truncate(@as(u16, @bitCast(b)));
    } else {
        return @truncate(@as(u16, @bitCast(c)));
    }
}

// ============================================================================
// ASCII85DECODE
// ============================================================================

fn decodeASCII85(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return decodeASCII85WithLimit(allocator, data, MAX_DECOMPRESSED_SIZE);
}

fn decodeASCII85WithLimit(allocator: std.mem.Allocator, data: []const u8, max_size: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var tuple: u32 = 0;
    var count: u8 = 0;
    var i: usize = 0;

    while (i < data.len) : (i += 1) {
        const c = data[i];

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

        // End of data marker
        if (c == '~') {
            if (i + 1 < data.len and data[i + 1] == '>') break;
            continue;
        }

        // 'z' represents 4 zero bytes
        if (c == 'z') {
            if (count != 0) return DecompressError.DecompressFailed;
            try appendBounded(&output, allocator, &[_]u8{ 0, 0, 0, 0 }, max_size);
            continue;
        }

        // Regular ASCII85 character
        if (c < '!' or c > 'u') continue;

        tuple = tuple * 85 + (c - '!');
        count += 1;

        if (count == 5) {
            try appendBounded(&output, allocator, &.{ @truncate(tuple >> 24), @truncate(tuple >> 16), @truncate(tuple >> 8), @truncate(tuple) }, max_size);
            tuple = 0;
            count = 0;
        }
    }

    // Handle remaining bytes
    if (count > 0) {
        var j: u8 = count;
        while (j < 5) : (j += 1) {
            tuple = tuple * 85 + 84;
        }

        const tail = [_]u8{ @truncate(tuple >> 24), @truncate(tuple >> 16), @truncate(tuple >> 8) };
        if (count >= 2) try appendBounded(&output, allocator, tail[0 .. count - 1], max_size);
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// ASCIIHEXDECODE
// ============================================================================

fn decodeASCIIHex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return decodeASCIIHexWithLimit(allocator, data, MAX_DECOMPRESSED_SIZE);
}

fn decodeASCIIHexWithLimit(allocator: std.mem.Allocator, data: []const u8, max_size: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var high: ?u4 = null;

    for (data) |c| {
        // End marker
        if (c == '>') break;

        // Skip whitespace
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;

        const nibble: ?u4 = if (c >= '0' and c <= '9')
            @truncate(c - '0')
        else if (c >= 'A' and c <= 'F')
            @truncate(c - 'A' + 10)
        else if (c >= 'a' and c <= 'f')
            @truncate(c - 'a' + 10)
        else
            null;

        if (nibble) |n| {
            if (high) |h| {
                try appendBounded(&output, allocator, &.{(@as(u8, h) << 4) | n}, max_size);
                high = null;
            } else {
                high = n;
            }
        }
    }

    // Trailing nibble is padded with 0
    if (high) |h| {
        try appendBounded(&output, allocator, &.{@as(u8, h) << 4}, max_size);
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// LZWDECODE
// ============================================================================

const lzw_single_byte_entries = blk: {
    var values: [256]u8 = undefined;
    for (&values, 0..) |*value, index| value.* = @truncate(index);
    break :blk values;
};

fn decodeLZW(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
) ![]u8 {
    return decodeLZWWithLimit(allocator, data, params, MAX_DECOMPRESSED_SIZE);
}

fn decodeLZWWithLimit(
    allocator: std.mem.Allocator,
    data: []const u8,
    params: ?Object,
    max_size: usize,
) ![]u8 {
    _ = params; // TODO: EarlyChange parameter

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    // LZW uses variable-length codes
    const LzwTable = struct {
        entries: [4096][]const u8,
        size: u16,

        fn init() @This() {
            var table: @This() = undefined;
            table.size = 258;

            // Initialize with single-byte entries
            var i: u16 = 0;
            while (i < 256) : (i += 1) {
                table.entries[i] = lzw_single_byte_entries[i..][0..1];
            }

            return table;
        }

        fn add(self: *@This(), entry: []const u8) bool {
            if (self.size < 4096) {
                self.entries[self.size] = entry;
                self.size += 1;
                return true;
            }
            return false;
        }

        fn get(self: @This(), code: u16) ?[]const u8 {
            if (code < self.size) return self.entries[code];
            return null;
        }

        fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            var index: u16 = 258;
            while (index < self.size) : (index += 1) {
                alloc.free(@constCast(self.entries[index]));
            }
            self.size = 258;
        }
    };

    var table = LzwTable.init();
    defer table.deinit(allocator);
    var bit_pos: usize = 0;
    var code_size: u4 = 9;
    var prev_code: ?u16 = null;

    while (true) {
        // Read next code
        const code = readBits(data, bit_pos, code_size) orelse break;
        bit_pos += code_size;

        // Clear table
        if (code == 256) {
            table.deinit(allocator);
            table = LzwTable.init();
            code_size = 9;
            prev_code = null;
            continue;
        }

        // End of data
        if (code == 257) break;

        // Output string for code
        if (table.get(code)) |entry| {
            try appendBounded(&output, allocator, entry, max_size);

            if (prev_code) |pc| {
                if (table.get(pc)) |prev_entry| {
                    // Add new entry: prev_entry + first byte of current
                    var new_entry = try allocator.alloc(u8, prev_entry.len + 1);
                    @memcpy(new_entry[0..prev_entry.len], prev_entry);
                    new_entry[prev_entry.len] = entry[0];
                    if (!table.add(new_entry)) allocator.free(new_entry);
                }
            }
        } else {
            // KwKwK is valid only for the next dictionary slot. Arbitrary
            // future codes are malformed input, not another special case.
            if (code != table.size) return DecompressError.DecompressFailed;
            const pc = prev_code orelse return DecompressError.DecompressFailed;
            const prev_entry = table.get(pc) orelse return DecompressError.DecompressFailed;
            if (output.items.len > max_size or prev_entry.len >= max_size - output.items.len) return DecompressError.OutputTooLarge;
            var new_entry = try allocator.alloc(u8, prev_entry.len + 1);
            @memcpy(new_entry[0..prev_entry.len], prev_entry);
            new_entry[prev_entry.len] = prev_entry[0];
            appendBounded(&output, allocator, new_entry, max_size) catch |err| {
                allocator.free(new_entry);
                return err;
            };
            if (!table.add(new_entry)) allocator.free(new_entry);
        }

        prev_code = code;

        // Increase code size when needed
        if (table.size >= (@as(u16, 1) << code_size) and code_size < 12) {
            code_size += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

fn readBits(data: []const u8, bit_pos: usize, count: u4) ?u16 {
    if (count == 0) return 0;
    const total_bits = std.math.mul(usize, data.len, 8) catch return null;
    if (bit_pos > total_bits or count > total_bits - bit_pos) return null;

    var value: u16 = 0;
    for (0..count) |offset| {
        const source_pos = bit_pos + offset;
        const byte = data[source_pos / 8];
        const shift: u3 = @intCast(7 - (source_pos % 8));
        value = (value << 1) | @as(u16, (byte >> shift) & 1);
    }
    return value;
}

// ============================================================================
// RUNLENGTHDECODE
// ============================================================================

fn decodeRunLength(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    return decodeRunLengthWithLimit(allocator, data, MAX_DECOMPRESSED_SIZE);
}

fn decodeRunLengthWithLimit(allocator: std.mem.Allocator, data: []const u8, max_size: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        const length = data[i];
        i += 1;

        if (length == 128) {
            // End of data
            break;
        } else if (length < 128) {
            // Copy next length+1 bytes literally
            const copy_len = @as(usize, length) + 1;
            if (i + copy_len > data.len) break;
            try appendBounded(&output, allocator, data[i..][0..copy_len], max_size);
            i += copy_len;
        } else {
            // Repeat next byte (257-length) times
            const repeat_count = 257 - @as(usize, length);
            if (i >= data.len) break;
            const byte = data[i];
            i += 1;
            if (output.items.len > max_size or repeat_count > max_size - output.items.len) return DecompressError.OutputTooLarge;
            try ensureBoundedCapacity(&output, allocator, output.items.len + repeat_count, max_size);
            output.appendNTimesAssumeCapacity(byte, repeat_count);
        }
    }

    return output.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "decodeASCIIHex" {
    const allocator = std.testing.allocator;

    const input = "48656C6C6F>";
    const result = try decodeASCIIHex(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeASCIIHex with whitespace" {
    const allocator = std.testing.allocator;

    const input = "48 65 6C\n6C 6F>";
    const result = try decodeASCIIHex(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello", result);
}

test "decodeASCII85" {
    const allocator = std.testing.allocator;

    // "Hello world" in ASCII85
    const input = "87cURD]j7BEbo7~>";
    const result = try decodeASCII85(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello world", result);
}

test "decodeRunLength" {
    const allocator = std.testing.allocator;

    // [2, 'A', 'B', 'C'] = copy 3 bytes
    // [254, 'X'] = repeat 'X' 3 times
    // [128] = end
    const input = [_]u8{ 2, 'A', 'B', 'C', 254, 'X', 128 };
    const result = try decodeRunLength(allocator, &input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("ABCXXX", result);
}

test "public decoder caps every filter and pass-through at exact boundaries" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { filter: ?[]const u8, encoded: []const u8, expected: []const u8 }{
        .{ .filter = null, .encoded = "AB", .expected = "AB" },
        .{ .filter = "DCTDecode", .encoded = "AB", .expected = "AB" },
        .{ .filter = "CCITTFaxDecode", .encoded = "AB", .expected = "AB" },
        .{ .filter = "JBIG2Decode", .encoded = "AB", .expected = "AB" },
        .{ .filter = "JPXDecode", .encoded = "AB", .expected = "AB" },
        .{ .filter = "ASCIIHexDecode", .encoded = "4142>", .expected = "AB" },
        .{ .filter = "ASCIIHexDecode", .encoded = "414>", .expected = "A@" },
        .{ .filter = "ASCII85Decode", .encoded = "z~>", .expected = &.{ 0, 0, 0, 0 } },
        .{ .filter = "ASCII85Decode", .encoded = "87cURD]j7BEbo7~>", .expected = "Hello world" },
        .{ .filter = "RunLengthDecode", .encoded = &.{ 255, 'X', 128 }, .expected = "XX" },
        .{ .filter = "RunLengthDecode", .encoded = &.{ 1, 'A', 'B', 128 }, .expected = "AB" },
        .{ .filter = "LZWDecode", .encoded = &.{ 128, 16, 72, 80, 16 }, .expected = "AB" },
        .{ .filter = "LZWDecode", .encoded = &.{ 128, 16, 96, 80, 16 }, .expected = "AAA" },
    };
    for (cases) |case| {
        const filter: ?Object = if (case.filter) |name| .{ .name = name } else null;
        for ([_]usize{ case.expected.len, case.expected.len + 1 }) |limit| {
            const decoded = try decompressStreamWithOptions(allocator, case.encoded, filter, null, .{ .max_output_bytes = limit });
            defer allocator.free(decoded);
            try std.testing.expectEqualSlices(u8, case.expected, decoded);
        }
        try std.testing.expectError(error.OutputTooLarge, decompressStreamWithOptions(allocator, case.encoded, filter, null, .{ .max_output_bytes = case.expected.len - 1 }));
    }
    const empty = try decompressStreamWithOptions(allocator, "", null, null, .{ .max_output_bytes = 0 });
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.OutputTooLarge, decompressStreamWithOptions(allocator, "A", null, null, .{ .max_output_bytes = 0 }));
}

test "public decoder caps intermediate filter and predictor stages" {
    const allocator = std.testing.allocator;
    var filters = [_]Object{ .{ .name = "ASCIIHexDecode" }, .{ .name = "RunLengthDecode" } };
    const filter: Object = .{ .array = &filters };
    const output = try decompressStreamWithOptions(allocator, "FF4180>", filter, null, .{ .max_output_bytes = 3 });
    defer allocator.free(output);
    try std.testing.expectEqualStrings("AA", output);
    // Final output fits two bytes; the first decoded stage still needs three.
    try std.testing.expectError(error.OutputTooLarge, decompressStreamWithOptions(allocator, "FF4180>", filter, null, .{ .max_output_bytes = 2 }));

    var entries = [_]Object.Dict.Entry{
        .{ .key = "Predictor", .value = .{ .integer = 12 } },
        .{ .key = "Columns", .value = .{ .integer = 3 } },
    };
    const params: Object = .{ .dict = .{ .entries = &entries } };
    const compressed = try compressZlibForTest(allocator, &.{ 0, 10, 11, 13 });
    defer allocator.free(compressed);
    const predicted = try decompressStreamWithOptions(allocator, compressed, .{ .name = "FlateDecode" }, params, .{ .max_output_bytes = 4 });
    defer allocator.free(predicted);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 13 }, predicted);
    try std.testing.expectError(error.OutputTooLarge, decompressStreamWithOptions(allocator, compressed, .{ .name = "FlateDecode" }, params, .{ .max_output_bytes = 3 }));
    const exact = try applyPredictorWithLimit(allocator, &.{ 0, 10, 11, 13 }, 12, 3, 1, 8, 3);
    defer allocator.free(exact);
    try std.testing.expectError(error.OutputTooLarge, applyPredictorWithLimit(allocator, &.{ 0, 10, 11, 13 }, 12, 3, 1, 8, 2));
    try std.testing.expectError(error.OutputTooLarge, applyPredictorWithLimit(allocator, &.{ 10, 1, 2 }, 2, 3, 1, 8, 2));

    entries[0].value = .{ .integer = 2 };
    entries[1].value = .{ .integer = 2 };
    const lzw_predicted = try decompressStreamWithOptions(allocator, &.{ 128, 16, 72, 80, 16 }, .{ .name = "LZWDecode" }, params, .{ .max_output_bytes = 2 });
    defer allocator.free(lzw_predicted);
    try std.testing.expectEqualSlices(u8, &.{ 65, 131 }, lzw_predicted);
}

fn filterChainAllocationProbe(allocator: std.mem.Allocator, compressed: []const u8) !void {
    var filters = [_]Object{ .{ .name = "ASCIIHexDecode" }, .{ .name = "RunLengthDecode" } };
    const decoded = try decompressStreamWithOptions(allocator, "FF4180>", .{ .array = &filters }, null, .{ .max_output_bytes = 3 });
    defer allocator.free(decoded);
    const flate = try decompressStreamWithOptions(allocator, compressed, .{ .name = "FlateDecode" }, null, .{ .max_output_bytes = 4 });
    defer allocator.free(flate);
    const predicted = try applyPredictorWithLimit(allocator, &.{ 0, 10, 11, 13 }, 12, 3, 1, 8, 3);
    defer allocator.free(predicted);
    const lzw = try decompressStreamWithOptions(allocator, &.{ 128, 16, 72, 80, 16 }, .{ .name = "LZWDecode" }, null, .{ .max_output_bytes = 2 });
    defer allocator.free(lzw);
}

test "configured filter chain and predictor clean up every allocation failure" {
    const compressed = try compressZlibForTest(std.testing.allocator, "ABCD");
    defer std.testing.allocator.free(compressed);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, filterChainAllocationProbe, .{compressed});
}

fn compressZlibForTest(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    defer output.deinit();
    const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(history);
    var compressor = try std.compress.flate.Compress.init(
        &output.writer,
        history,
        .zlib,
        .default,
    );
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return output.toOwnedSlice();
}

test "FlateDecode enforces exact output-cap boundaries while streaming" {
    const allocator = std.testing.allocator;
    const input: [1024]u8 = @splat('A');
    const compressed = try compressZlibForTest(allocator, &input);
    defer allocator.free(compressed);

    const exact = try decodeFlateDecodeWithLimit(allocator, compressed, null, input.len);
    defer allocator.free(exact);
    try std.testing.expectEqualSlices(u8, &input, exact);

    try std.testing.expectError(
        DecompressError.OutputTooLarge,
        decodeFlateDecodeWithLimit(allocator, compressed, null, input.len - 1),
    );
}

fn flateAllocationProbe(allocator: std.mem.Allocator, compressed: []const u8) !void {
    const output = try decodeFlateDecodeWithLimit(allocator, compressed, null, 1024);
    defer allocator.free(output);
}

test "FlateDecode releases bounded output on allocation failure" {
    const input: [1024]u8 = @splat('B');
    const compressed = try compressZlibForTest(std.testing.allocator, &input);
    defer std.testing.allocator.free(compressed);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        flateAllocationProbe,
        .{compressed},
    );
}

test "LZW dictionary entries are released after decoding" {
    // Codes: clear(256), 'A'(65), 'B'(66), end(257), packed at 9 bits.
    const encoded = [_]u8{ 128, 16, 72, 80, 16 };
    const decoded = try decodeLZW(std.testing.allocator, &encoded, null);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("AB", decoded);
}

fn lzwAllocationProbe(allocator: std.mem.Allocator) !void {
    const encoded = [_]u8{ 128, 16, 72, 80, 16 };
    const decoded = try decodeLZW(allocator, &encoded, null);
    defer allocator.free(decoded);
}

test "LZW bit reader accepts final one-byte and two-byte windows" {
    const one_byte = [_]u8{0b1010_1100};
    try std.testing.expectEqual(@as(?u16, 0b1010_1100), readBits(&one_byte, 0, 8));
    try std.testing.expectEqual(@as(?u16, 0b1100), readBits(&one_byte, 4, 4));

    const two_bytes = [_]u8{ 0b0000_0001, 0b1000_0000 };
    try std.testing.expectEqual(@as(?u16, 0b11), readBits(&two_bytes, 7, 2));
    try std.testing.expectEqual(@as(?u16, null), readBits(&two_bytes, 8, 9));
}

test "LZW releases output and dictionary entries on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        lzwAllocationProbe,
        .{},
    );
}

test "TIFF predictor reconstructs a row and rejects unsafe dimensions" {
    const allocator = std.testing.allocator;
    const encoded = [_]u8{ 10, 1, 2 };
    const decoded = try applyTiffPredictor(allocator, &encoded, 3, 1, 8);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 13 }, decoded);
    try std.testing.expectError(
        DecompressError.InvalidFilterParams,
        applyTiffPredictor(allocator, &encoded, 0, 1, 8),
    );
    try std.testing.expectError(
        DecompressError.InvalidFilterParams,
        applyTiffPredictor(allocator, &encoded, std.math.maxInt(u32), 2, 8),
    );
    try std.testing.expectError(
        DecompressError.InvalidFilterParams,
        applyTiffPredictor(allocator, &encoded, 3, 1, 16),
    );
}

test "PNG predictor reconstructs a row and rejects unsafe parameters" {
    const allocator = std.testing.allocator;
    const encoded = [_]u8{ 1, 10, 1, 2 };
    const decoded = try applyPngPredictor(allocator, &encoded, 3, 1, 8);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 13 }, decoded);
    try std.testing.expectError(
        DecompressError.InvalidFilterParams,
        applyPngPredictor(allocator, &encoded, 0, 1, 8),
    );
    try std.testing.expectError(
        DecompressError.InvalidFilterParams,
        applyPngPredictor(allocator, &encoded, 3, 1, 3),
    );
    try std.testing.expectError(
        DecompressError.InvalidPredictor,
        applyPngPredictor(allocator, encoded[0..3], 3, 1, 8),
    );
}
