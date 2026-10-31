//! Shared, bounded logical-table continuation for batch and streaming output.
const std = @import("std");
const layout = @import("layout.zig");

pub const max_columns = 32;
pub const max_header_bytes = 4096;
pub const max_rows = 256;

/// Owns the header bytes: streaming page allocations can be freed immediately.
const Signature = struct {
    page_index: u32,
    column_count: usize,
    x0: f64,
    width: f64,
    cell_count: usize,
    byte_count: usize = 0,
    bytes: [max_header_bytes]u8 = undefined,
    ends: [max_columns]usize = undefined,
    columns: [max_columns]u32 = undefined,
    rowspans: [max_columns]u32 = undefined,
    colspans: [max_columns]u32 = undefined,

    fn fromTable(table: *const layout.TableGrid) ?Signature {
        if (table.column_count == 0 or table.column_count > max_columns or table.rows.len > max_rows) return null;
        const width = table.bounds.x1 - table.bounds.x0;
        if (!std.math.isFinite(table.bounds.x0) or !std.math.isFinite(width) or width <= 0) return null;
        for (table.rows) |row| {
            if (row.cells.len > max_columns) return null;
            var populated: usize = 0;
            var headers: usize = 0;
            for (row.cells) |cell| {
                if (cell.text.len == 0) continue;
                populated += 1;
                if (cell.role == .header) headers += 1;
            }
            if (populated == 0 or headers * 2 < populated) continue;
            if (row.cells.len == 0 or row.cells.len > max_columns) return null;
            var signature = Signature{
                .page_index = table.page_index,
                .column_count = table.column_count,
                .x0 = table.bounds.x0,
                .width = width,
                .cell_count = row.cells.len,
            };
            for (row.cells, 0..) |cell, index| {
                if (cell.column_index >= table.column_count or cell.colspan == 0 or
                    cell.colspan > table.column_count - cell.column_index or cell.rowspan == 0)
                    return null;
                if (cell.text.len > max_header_bytes - signature.byte_count) return null;
                for (cell.text) |byte| {
                    signature.bytes[signature.byte_count] = std.ascii.toLower(byte);
                    signature.byte_count += 1;
                }
                signature.ends[index] = signature.byte_count;
                signature.columns[index] = cell.column_index;
                signature.rowspans[index] = cell.rowspan;
                signature.colspans[index] = cell.colspan;
            }
            return signature;
        }
        return null;
    }

    fn continuesTo(self: *const Signature, current: *const Signature) bool {
        if (self.page_index == std.math.maxInt(u32) or current.page_index != self.page_index + 1) return false;
        if (current.column_count != self.column_count or current.cell_count != self.cell_count) return false;
        const count = self.cell_count;
        // Exact cell boundaries avoid both hash collisions and ambiguous joins
        // such as ["A|B", "C"] versus ["A", "B|C"]. Partial headers abstain.
        if (!std.mem.eql(usize, self.ends[0..count], current.ends[0..count]) or
            !std.mem.eql(u32, self.columns[0..count], current.columns[0..count]) or
            !std.mem.eql(u32, self.rowspans[0..count], current.rowspans[0..count]) or
            !std.mem.eql(u32, self.colspans[0..count], current.colspans[0..count]) or
            !std.mem.eql(u8, self.bytes[0..self.byte_count], current.bytes[0..current.byte_count])) return false;
        return @abs(self.x0 - current.x0) <= 18.0 and
            @abs(self.width - current.width) <= @max(24.0, self.width * 0.08);
    }
};

pub const Context = struct {
    previous: ?Signature = null,
    table_index: u32 = 0,
    logical_table_index: u32 = 0,
    table_part_index: u32 = 0,

    /// Returns the predecessor index so batch callers can add its forward link.
    /// Every encountered table replaces or clears the previous candidate;
    /// headerless tables and distinct same-page tables cannot be skipped.
    pub fn apply(self: *Context, table: *layout.TableGrid, table_index: u32) ?u32 {
        table.logical_table_index = table_index;
        table.table_part_index = 0;
        table.continued_from_table_index = null;
        table.continued_to_table_index = null;
        const signature = Signature.fromTable(table) orelse {
            self.previous = null;
            return null;
        };
        var predecessor: ?u32 = null;
        if (self.previous) |*previous| {
            if (self.table_part_index < std.math.maxInt(u32) and previous.continuesTo(&signature)) {
                predecessor = self.table_index;
                table.logical_table_index = self.logical_table_index;
                table.table_part_index = self.table_part_index + 1;
                table.continued_from_table_index = self.table_index;
            }
        }
        self.previous = signature;
        self.table_index = table_index;
        self.logical_table_index = table.logical_table_index.?;
        self.table_part_index = table.table_part_index;
        return predecessor;
    }
};

fn testTable(page: u32, rows: []layout.TableRow) layout.TableGrid {
    return .{
        .bounds = layout.TextSpan.init(.{ .page_index = page, .bbox = .{ .x0 = 60, .y0 = 60, .x1 = 550, .y1 = 180 }, .text = "", .source = .native_pdf }),
        .block_index = 0,
        .rows = rows,
        .column_count = 4,
        .page_index = page,
    };
}

test "continuation requires exact headers adjacent pages and compatible geometry" {
    const bounds = layout.TextSpan.init(.{ .page_index = 0, .bbox = .{ .x0 = 60, .y0 = 60, .x1 = 550, .y1 = 180 }, .text = "", .source = .native_pdf });
    var cells: [4]layout.TableCell = undefined;
    for ([_][]const u8{ "Account", "Current", "Previous", "Budget" }, 0..) |text, index| {
        cells[index] = .{ .bounds = bounds, .text = text, .row_index = 0, .column_index = @intCast(index), .role = .header };
    }
    var rows = [_]layout.TableRow{.{ .bounds = bounds, .cells = &cells, .row_index = 0 }};
    var first = testTable(0, &rows);
    var context = Context{};
    try std.testing.expectEqual(@as(?u32, null), context.apply(&first, 7));
    // The retained signature owns its bytes rather than borrowing this page.
    cells[0].text = "ACCOUNT";
    var second = testTable(1, &rows);
    try std.testing.expectEqual(@as(?u32, 7), context.apply(&second, 8));
    try std.testing.expectEqual(@as(?u32, 7), second.logical_table_index);
    try std.testing.expectEqual(@as(u32, 1), second.table_part_index);
    cells[3].text = "Forecast";
    var partial = testTable(2, &rows);
    try std.testing.expectEqual(@as(?u32, null), context.apply(&partial, 9));
    var gap = testTable(4, &rows);
    try std.testing.expectEqual(@as(?u32, null), context.apply(&gap, 10));
    var shifted = testTable(5, &rows);
    shifted.bounds.x0 += 30;
    shifted.bounds.x1 += 30;
    try std.testing.expectEqual(@as(?u32, null), context.apply(&shifted, 11));
    try std.testing.expectEqual(@as(?u32, 11), shifted.logical_table_index);
}

test "intervening headerless or distinct same-page tables break continuation" {
    const bounds = layout.TextSpan.init(.{ .page_index = 0, .bbox = .{ .x0 = 60, .y0 = 60, .x1 = 550, .y1 = 180 }, .text = "", .source = .native_pdf });
    var cells = [_]layout.TableCell{.{ .bounds = bounds, .text = "Header", .row_index = 0, .column_index = 0, .role = .header }};
    var rows = [_]layout.TableRow{.{ .bounds = bounds, .cells = &cells, .row_index = 0 }};
    var first = testTable(0, &rows);
    var context = Context{};
    _ = context.apply(&first, 0);
    cells[0].text = "Different";
    var intervening = testTable(0, &rows);
    try std.testing.expectEqual(@as(?u32, null), context.apply(&intervening, 1));
    cells[0].text = "Header";
    var next = testTable(1, &rows);
    try std.testing.expectEqual(@as(?u32, null), context.apply(&next, 2));
    cells[0].role = .data;
    var headerless = testTable(1, &rows);
    _ = context.apply(&headerless, 3);
    cells[0].role = .header;
    next.page_index = 2;
    try std.testing.expectEqual(@as(?u32, null), context.apply(&next, 4));
}

test "continuation signatures preserve cell boundaries topology and finite bounds" {
    const bounds = layout.TextSpan.init(.{ .page_index = 0, .bbox = .{ .x0 = 60, .y0 = 60, .x1 = 550, .y1 = 180 }, .text = "", .source = .native_pdf });
    var cells = [_]layout.TableCell{
        .{ .bounds = bounds, .text = "A|B", .row_index = 0, .column_index = 0, .role = .header },
        .{ .bounds = bounds, .text = "C", .row_index = 0, .column_index = 1, .role = .header },
    };
    var rows = [_]layout.TableRow{.{ .bounds = bounds, .cells = &cells, .row_index = 0 }};
    var first = testTable(0, &rows);
    var context = Context{};
    _ = context.apply(&first, 0);
    cells[0].text = "A";
    cells[1].text = "B|C";
    var next = testTable(1, &rows);
    try std.testing.expectEqual(@as(?u32, null), context.apply(&next, 1));
    cells[1].colspan = 2;
    next.page_index = 2;
    try std.testing.expectEqual(@as(?u32, null), context.apply(&next, 2));
    next.bounds.x0 = std.math.nan(f64);
    try std.testing.expect(Signature.fromTable(&next) == null);
    next.bounds = bounds;
    next.column_count = max_columns + 1;
    try std.testing.expect(Signature.fromTable(&next) == null);
    next.column_count = 4;
    const oversized: [max_header_bytes + 1]u8 = @splat('x');
    cells[0].text = &oversized;
    try std.testing.expect(Signature.fromTable(&next) == null);
}
