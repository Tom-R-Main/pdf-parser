//! Conservative section annotations. IDs name existing document-global blocks;
//! this pass never edits text, source maps, chunk boundaries, or reading order.
const std = @import("std");

pub const max_depth = 12;
pub const Signal = enum { bookmark, numbering, style };
pub const Bookmark = struct { title: []const u8, page: ?usize, level: u32 };
pub const Annotation = struct {
    heading_level: ?u8 = null,
    heading_signal: ?Signal = null,
    section_id: ?u32 = null,
    parent_section_id: ?u32 = null,
    ancestry: [max_depth]u32 = @splat(0),
    ancestry_len: u8 = 0,
};

pub const State = struct {
    ids: [max_depth]?u32 = @splat(null),
    part_seen: bool = false,
    /// Shared by batch and page streaming; degenerate outline matching abstains.
    match_work_remaining: usize = 2_000_000,
};

/// Borrowed outline items may be any type with title/page/level fields.
pub fn annotate(blocks: anytype, bookmarks: anytype, state: *State, block_base: u32) void {
    for (blocks, 0..) |*block, block_index| {
        block.section = .{};
        var level: ?u8 = null;
        var signal: ?Signal = null;
        const match = bookmarkLevel(blocks, block_index, bookmarks, state);
        if (match.ambiguous or (match.limited and block.kind == .heading)) {
            // An unresolved boundary must not silently attribute subsequent
            // content to the section preceding that boundary.
            state.ids = @splat(null);
            state.part_seen = false;
        }
        if (match.level) |value| {
            level = value;
            signal = .bookmark;
        } else if (!match.ambiguous and !match.limited and block.kind == .heading and !looksLikeNumericBody(block.text)) {
            if (numberingLevel(block.text, state.part_seen)) |number| {
                level = number.level;
                signal = .numbering;
                if (number.is_part) state.part_seen = true;
            } else {
                // A detected heading is evidence of a section boundary, but its
                // size alone does not establish a reliable nested level.
                level = 1;
                signal = .style;
            }
        }
        if (level) |heading_level| {
            if (numberingLevel(block.text, state.part_seen)) |number| {
                if (number.is_part) state.part_seen = true;
            }
            const slot = heading_level - 1;
            for (state.ids[slot..]) |*id| id.* = null;
            state.ids[slot] = block_base + @as(u32, @intCast(block_index));
            block.section.heading_level = heading_level;
            block.section.heading_signal = signal;
        }
        for (state.ids) |id| {
            if (id) |value| {
                const count = block.section.ancestry_len;
                block.section.ancestry[count] = value;
                block.section.ancestry_len += 1;
            }
        }
        const count = block.section.ancestry_len;
        if (count > 0) block.section.section_id = block.section.ancestry[count - 1];
        if (count > 1) block.section.parent_section_id = block.section.ancestry[count - 2];
    }
}

const BookmarkMatch = struct { level: ?u8 = null, ambiguous: bool = false, limited: bool = false };
fn bookmarkLevel(blocks: anytype, block_index: usize, bookmarks: anytype, state: *State) BookmarkMatch {
    const block = blocks[block_index];
    if (block.text.len > 2048) return .{};
    var result = BookmarkMatch{};
    for (bookmarks) |bookmark| {
        if (state.match_work_remaining == 0) return .{ .limited = true };
        state.match_work_remaining -= 1;
        const page = bookmark.page orelse continue;
        if (page != block.page_index or bookmark.title.len > 2048 or !titleMatches(block.text, bookmark.title)) continue;
        var candidates: usize = 0;
        for (blocks) |candidate| {
            if (candidate.page_index != page) continue;
            if (state.match_work_remaining == 0) return .{ .limited = true };
            state.match_work_remaining -= 1;
            if (candidate.page_index == page and candidate.text.len <= 2048 and titleMatches(candidate.text, bookmark.title)) candidates += 1;
        }
        if (candidates != 1) return .{ .ambiguous = true };
        const value: u8 = @intCast(@min(bookmark.level, max_depth - 1) + 1);
        if (result.level != null and result.level.? != value) return .{ .ambiguous = true };
        result.level = value;
    }
    return result;
}

fn titleMatches(text: []const u8, title: []const u8) bool {
    return normalizedEqual(text, title) or normalizedEqual(stripMarker(text), stripMarker(title));
}

fn normalizedEqual(a: []const u8, b: []const u8) bool {
    var ai = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var bi = std.mem.tokenizeAny(u8, b, " \t\r\n");
    var any = false;
    while (ai.next()) |word| {
        const other = bi.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(word, other)) return false;
        any = true;
    }
    return any and bi.next() == null;
}

fn stripMarker(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var pos: usize = 0;
    while (pos < trimmed.len and (std.ascii.isDigit(trimmed[pos]) or trimmed[pos] == '.')) : (pos += 1) {}
    if (pos == 0 or pos >= trimmed.len) return trimmed;
    if (trimmed[pos] == ')') pos += 1;
    if (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) return std.mem.trimStart(u8, trimmed[pos..], " \t\r\n");
    return trimmed;
}

const Numbering = struct { level: u8, is_part: bool = false };
fn numberingLevel(text: []const u8, part_seen: bool) ?Numbering {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var words = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const first = words.next() orelse return null;
    if (std.ascii.eqlIgnoreCase(first, "part")) {
        const marker = words.next() orelse return null;
        if (isEnumerator(marker)) return .{ .level = 1, .is_part = true };
        return null;
    }
    if (std.ascii.eqlIgnoreCase(first, "chapter")) {
        const marker = words.next() orelse return null;
        if (isEnumerator(marker)) return .{ .level = if (part_seen) 2 else 1 };
        return null;
    }
    var pos: usize = 0;
    var components: u8 = 0;
    while (pos < trimmed.len) {
        const start = pos;
        while (pos < trimmed.len and std.ascii.isDigit(trimmed[pos])) : (pos += 1) {}
        if (pos == start or pos - start > 2) return null;
        // The output depth is capped; saturate before arithmetic so a long
        // marker (including the optional PART offset) cannot overflow u8.
        if (components < max_depth) components += 1;
        if (pos == trimmed.len) return null;
        if (trimmed[pos] == '.') {
            pos += 1;
            if (pos < trimmed.len and std.ascii.isDigit(trimmed[pos])) continue;
        } else if (trimmed[pos] == ')') {
            pos += 1;
        } else if (components == 1) return null;
        if (pos < trimmed.len and std.ascii.isWhitespace(trimmed[pos])) {
            if (std.mem.trim(u8, trimmed[pos..], " \t\r\n").len == 0) return null;
            return .{ .level = @min(max_depth, components + @as(u8, if (part_seen) 1 else 0)) };
        }
        return null;
    }
    return null;
}

fn isEnumerator(text: []const u8) bool {
    if (text.len == 0 or text.len > 8) return false;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and std.mem.indexOfScalar(u8, "IVXLCDMivxlcdm", byte) == null) return false;
    }
    return true;
}

fn looksLikeNumericBody(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '(' or trimmed[0] == '[') return true;
    if (!std.ascii.isDigit(trimmed[0])) return false;
    var words = std.mem.tokenizeAny(u8, trimmed, " \t\r\n");
    const first = words.next().?;
    var digits: usize = 0;
    while (digits < first.len and std.ascii.isDigit(first[digits])) : (digits += 1) {}
    return digits >= 3 or std.mem.indexOfScalar(u8, first, ':') != null or
        std.mem.indexOfScalar(u8, first, '-') != null or std.mem.indexOfScalar(u8, first, '/') != null;
}

const TestBlock = struct { text: []const u8, page_index: u32 = 0, kind: enum { heading, paragraph } = .heading, section: Annotation = .{} };
test "bookmark precedence ambiguity wrong page and numeric body abstention" {
    var blocks = [_]TestBlock{
        .{ .text = "1. Scope" },        .{ .text = "1.1 Definitions" },
        .{ .text = "Duplicate" },       .{ .text = "Duplicate" },
        .{ .text = "Wrong page" },      .{ .text = "2024 Annual report" },
        .{ .text = "3:00 PM Session" }, .{ .text = "(a) list item", .kind = .paragraph },
    };
    const bookmarks = [_]Bookmark{
        .{ .title = "Scope", .page = 0, .level = 1 },
        .{ .title = "Duplicate", .page = 0, .level = 0 },
        .{ .title = "Wrong page", .page = 1, .level = 3 },
    };
    var state = State{};
    annotate(&blocks, &bookmarks, &state, 0);
    try std.testing.expectEqual(@as(?u8, 2), blocks[0].section.heading_level);
    try std.testing.expectEqual(Signal.bookmark, blocks[0].section.heading_signal.?);
    try std.testing.expectEqual(Signal.numbering, blocks[1].section.heading_signal.?);
    try std.testing.expect(blocks[2].section.heading_level == null);
    try std.testing.expect(blocks[3].section.heading_level == null);
    try std.testing.expect(blocks[2].section.section_id == null);
    try std.testing.expect(blocks[3].section.section_id == null);
    try std.testing.expect(blocks[4].section.heading_signal != .bookmark);
    for (blocks[5..]) |block| try std.testing.expect(block.section.heading_level == null);
}

test "page streaming and batch retain identical document-global section paths" {
    const initial = [_]TestBlock{
        .{ .text = "PART I" },                           .{ .text = "1. Scope" },
        .{ .text = "body", .kind = .paragraph },         .{ .text = "next page body", .page_index = 1, .kind = .paragraph },
        .{ .text = "1.1 Definitions", .page_index = 1 }, .{ .text = "body two", .page_index = 1, .kind = .paragraph },
    };
    var batch = initial;
    var pages = initial;
    var batch_state = State{};
    var page_state = State{};
    const bookmarks = [_]Bookmark{};
    annotate(&batch, &bookmarks, &batch_state, 0);
    annotate(pages[0..3], &bookmarks, &page_state, 0);
    annotate(pages[3..], &bookmarks, &page_state, 3);
    for (batch, pages) |a, b| try std.testing.expectEqualDeep(a.section, b.section);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4 }, batch[5].section.ancestry[0..batch[5].section.ancestry_len]);
}

test "outline matching work bound abstains without changing content" {
    var blocks = [_]TestBlock{.{ .text = "Scope" }};
    var state = State{ .match_work_remaining = 0 };
    const bookmarks = [_]Bookmark{.{ .title = "Scope", .page = 0, .level = 0 }};
    annotate(&blocks, &bookmarks, &state, 0);
    try std.testing.expect(blocks[0].section.heading_level == null);
    try std.testing.expectEqualStrings("Scope", blocks[0].text);
}

test "deep numeric headings saturate before counter and PART offset overflow" {
    var text: [2 * 1024 + 6]u8 = undefined;
    for ([_]usize{ 11, 12, 13, 255, 256, 1024 }) |count| {
        for (0..count) |index| @memcpy(text[index * 2 ..][0..2], "1.");
        @memcpy(text[count * 2 ..][0..6], " Scope");
        const heading = text[0 .. count * 2 + 6];
        for ([_]bool{ false, true }) |part_seen| {
            const expected: u8 = @intCast(@min(max_depth, count + @intFromBool(part_seen)));
            try std.testing.expectEqual(expected, numberingLevel(heading, part_seen).?.level);
            var blocks = [_]TestBlock{.{ .text = heading }};
            var state = State{ .part_seen = part_seen };
            annotate(&blocks, &[_]Bookmark{}, &state, 0);
            try std.testing.expectEqual(@as(?u8, expected), blocks[0].section.heading_level);
            try std.testing.expectEqual(Signal.numbering, blocks[0].section.heading_signal.?);
            try std.testing.expectEqualStrings(heading, blocks[0].text);
        }
    }
}
