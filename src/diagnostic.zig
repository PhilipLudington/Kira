//! Diagnostic rendering for the Kira compiler.
//!
//! Provides centralized formatting for all compiler diagnostics (parser, resolver,
//! type checker) with source snippets, underline carets, color output, and
//! "Did you mean?" suggestions.

const std = @import("std");
const lexer = @import("lexer/root.zig");

pub const Location = lexer.Location;
pub const Span = lexer.Span;

/// ANSI color codes for terminal output
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[36m"; // cyan for notes
    pub const green = "\x1b[32m";
    pub const magenta = "\x1b[35m";

    pub const bold_red = "\x1b[1;31m";
    pub const bold_yellow = "\x1b[1;33m";
    pub const bold_blue = "\x1b[1;36m";
    pub const bold_green = "\x1b[1;32m";
};

/// Severity level for diagnostics
pub const Severity = enum {
    err,
    warning,
    hint,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .hint => "hint",
        };
    }

    pub fn color(self: Severity) []const u8 {
        return switch (self) {
            .err => Color.bold_red,
            .warning => Color.bold_yellow,
            .hint => Color.bold_blue,
        };
    }

    pub fn caretColor(self: Severity) []const u8 {
        return switch (self) {
            .err => Color.red,
            .warning => Color.yellow,
            .hint => Color.blue,
        };
    }
};

/// A secondary location with an annotation message
pub const RelatedInfo = struct {
    message: []const u8,
    span: Span,
};

/// A unified diagnostic that the renderer can display.
/// This is a view type — it doesn't own any memory.
pub const Diagnostic = struct {
    message: []const u8,
    span: Span,
    severity: Severity,
    related: ?[]const RelatedInfo = null,
    suggestion: ?[]const u8 = null,
};

/// Renders diagnostics with source snippets, underline carets, and optional color.
pub const DiagnosticRenderer = struct {
    source: []const u8,
    path: []const u8,
    use_color: bool,

    pub fn init(source: []const u8, path: []const u8, use_color: bool) DiagnosticRenderer {
        return .{
            .source = source,
            .path = path,
            .use_color = use_color,
        };
    }

    /// Render a complete diagnostic with source context.
    pub fn render(self: DiagnosticRenderer, writer: anytype, diag: Diagnostic) !void {
        // Header: "error: message"
        try self.writeHeader(writer, diag.severity, diag.message);

        // Location: "  --> path:line:column"
        try self.writeLocation(writer, diag.span);

        // Source snippet with underline
        try self.writeSourceSnippet(writer, diag.span, diag.severity);

        // "Did you mean?" suggestion
        if (diag.suggestion) |suggestion| {
            try self.writeSuggestion(writer, suggestion);
        }

        // Related info with source context
        if (diag.related) |related| {
            for (related) |info| {
                try self.writeRelatedInfo(writer, info);
            }
        }

        try writer.writeAll("\n");
    }

    fn writeHeader(self: DiagnosticRenderer, writer: anytype, severity: Severity, message: []const u8) !void {
        if (self.use_color) {
            try writer.writeAll(severity.color());
            try writer.writeAll(severity.label());
            try writer.writeAll(Color.reset);
            try writer.writeAll(Color.bold);
            try writer.writeAll(": ");
            try writer.writeAll(message);
            try writer.writeAll(Color.reset);
        } else {
            try writer.writeAll(severity.label());
            try writer.writeAll(": ");
            try writer.writeAll(message);
        }
        try writer.writeAll("\n");
    }

    fn writeLocation(self: DiagnosticRenderer, writer: anytype, span: Span) !void {
        var buf: [512]u8 = undefined;
        if (self.use_color) {
            const loc = std.fmt.bufPrint(&buf, "  {s}-->{s} {s}:{d}:{d}\n", .{
                Color.blue,
                Color.reset,
                self.path,
                span.start.line,
                span.start.column,
            }) catch return;
            try writer.writeAll(loc);
        } else {
            const loc = std.fmt.bufPrint(&buf, "  --> {s}:{d}:{d}\n", .{
                self.path,
                span.start.line,
                span.start.column,
            }) catch return;
            try writer.writeAll(loc);
        }
    }

    fn writeSourceSnippet(self: DiagnosticRenderer, writer: anytype, span: Span, severity: Severity) !void {
        const line = getSourceLine(self.source, span.start.line) orelse return;
        const line_num = span.start.line;

        // Calculate gutter width for alignment
        var line_buf: [32]u8 = undefined;
        const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{line_num}) catch return;
        const gutter_width = line_str.len + 1; // +1 for padding

        // Empty gutter line
        try self.writeGutterPad(writer, gutter_width);
        if (self.use_color) {
            try writer.writeAll(Color.blue);
            try writer.writeAll("|\n");
            try writer.writeAll(Color.reset);
        } else {
            try writer.writeAll("|\n");
        }

        // Source line with line number
        if (self.use_color) {
            try writer.writeAll(Color.blue);
        }
        try self.writeGutterNum(writer, gutter_width, line_num);
        if (self.use_color) {
            try writer.writeAll("| ");
            try writer.writeAll(Color.reset);
        } else {
            try writer.writeAll("| ");
        }
        try writeExpandedLine(writer, line);
        try writer.writeAll("\n");

        // Underline caret line
        try self.writeGutterPad(writer, gutter_width);
        if (self.use_color) {
            try writer.writeAll(Color.blue);
            try writer.writeAll("| ");
            try writer.writeAll(Color.reset);
            try writer.writeAll(severity.caretColor());
        } else {
            try writer.writeAll("| ");
        }

        // Calculate underline position (accounting for tabs)
        const start_col = span.start.column;
        const end_col = if (span.end.line == span.start.line and span.end.column > span.start.column)
            span.end.column
        else
            start_col + 1;

        // Write spaces up to caret position (accounting for tabs in source)
        try writeSpacesForColumns(writer, line, start_col);

        // Write carets
        const caret_count = if (end_col > start_col) end_col - start_col else 1;
        var i: u32 = 0;
        while (i < caret_count) : (i += 1) {
            try writer.writeAll("^");
        }

        if (self.use_color) {
            try writer.writeAll(Color.reset);
        }
        try writer.writeAll("\n");
    }

    fn writeSuggestion(self: DiagnosticRenderer, writer: anytype, suggestion: []const u8) !void {
        if (self.use_color) {
            try writer.writeAll("  ");
            try writer.writeAll(Color.bold_green);
            try writer.writeAll("help: ");
            try writer.writeAll(Color.reset);
        } else {
            try writer.writeAll("  help: ");
        }
        try writer.writeAll("did you mean '");
        if (self.use_color) {
            try writer.writeAll(Color.bold);
        }
        try writer.writeAll(suggestion);
        if (self.use_color) {
            try writer.writeAll(Color.reset);
        }
        try writer.writeAll("'?\n");
    }

    fn writeRelatedInfo(self: DiagnosticRenderer, writer: anytype, info: RelatedInfo) !void {
        // Note header
        if (self.use_color) {
            try writer.writeAll("  ");
            try writer.writeAll(Color.bold_blue);
            try writer.writeAll("note: ");
            try writer.writeAll(Color.reset);
        } else {
            try writer.writeAll("  note: ");
        }
        try writer.writeAll(info.message);
        try writer.writeAll("\n");

        // Related source snippet (if we have valid location)
        if (info.span.start.line > 0) {
            var buf: [512]u8 = undefined;
            if (self.use_color) {
                const loc = std.fmt.bufPrint(&buf, "  {s}-->{s} {s}:{d}:{d}\n", .{
                    Color.blue,
                    Color.reset,
                    self.path,
                    info.span.start.line,
                    info.span.start.column,
                }) catch return;
                try writer.writeAll(loc);
            } else {
                const loc = std.fmt.bufPrint(&buf, "  --> {s}:{d}:{d}\n", .{
                    self.path,
                    info.span.start.line,
                    info.span.start.column,
                }) catch return;
                try writer.writeAll(loc);
            }
        }
    }

    fn writeGutterPad(self: DiagnosticRenderer, writer: anytype, width: usize) !void {
        _ = self;
        var i: usize = 0;
        while (i < width) : (i += 1) {
            try writer.writeAll(" ");
        }
    }

    fn writeGutterNum(self: DiagnosticRenderer, writer: anytype, width: usize, line_num: u32) !void {
        _ = self;
        var buf: [32]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "{d}", .{line_num}) catch return;
        // Right-align the number
        var padding = if (width > num_str.len) width - num_str.len else 0;
        while (padding > 0) : (padding -= 1) {
            try writer.writeAll(" ");
        }
        try writer.writeAll(num_str);
    }
};

/// Write a source line with tabs expanded to spaces (4-space tab stops)
fn writeExpandedLine(writer: anytype, line: []const u8) !void {
    var col: usize = 0;
    for (line) |ch| {
        if (ch == '\t') {
            const spaces = 4 - (col % 4);
            var i: usize = 0;
            while (i < spaces) : (i += 1) {
                try writer.writeAll(" ");
            }
            col += spaces;
        } else {
            try writer.writeAll(&[_]u8{ch});
            col += 1;
        }
    }
}

/// Write spaces matching the visual width of columns in a source line (tab-aware)
fn writeSpacesForColumns(writer: anytype, line: []const u8, target_col: u32) !void {
    if (target_col <= 1) return;

    var visual_col: usize = 0;
    var source_col: u32 = 1;
    for (line) |ch| {
        if (source_col >= target_col) break;
        if (ch == '\t') {
            const spaces = 4 - (visual_col % 4);
            var i: usize = 0;
            while (i < spaces) : (i += 1) {
                try writer.writeAll(" ");
            }
            visual_col += spaces;
        } else {
            try writer.writeAll(" ");
            visual_col += 1;
        }
        source_col += 1;
    }
}

/// Extract a specific line from source code (1-indexed).
pub fn getSourceLine(source: []const u8, line_num: u32) ?[]const u8 {
    if (line_num == 0) return null;

    var current_line: u32 = 1;
    var start: usize = 0;

    for (source, 0..) |c, i| {
        if (current_line == line_num) {
            var end = i;
            while (end < source.len and source[end] != '\n') {
                end += 1;
            }
            return source[start..end];
        }
        if (c == '\n') {
            current_line += 1;
            start = i + 1;
        }
    }

    if (current_line == line_num and start < source.len) {
        return source[start..];
    }

    return null;
}

/// Map a byte offset in source to a Location (line/column).
pub fn offsetToLocation(source: []const u8, offset: usize) Location {
    var line: u32 = 1;
    var col: u32 = 1;

    const limit = if (offset < source.len) offset else source.len;
    for (source[0..limit]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }

    return .{ .line = line, .column = col, .offset = offset };
}

/// Compute Levenshtein edit distance between two strings.
/// Returns null if distance would exceed max_distance (early cutoff).
pub fn editDistance(a: []const u8, b: []const u8, max_distance: usize) ?usize {
    if (a.len == 0) return if (b.len <= max_distance) b.len else null;
    if (b.len == 0) return if (a.len <= max_distance) a.len else null;

    // Quick length check
    const len_diff = if (a.len > b.len) a.len - b.len else b.len - a.len;
    if (len_diff > max_distance) return null;

    // Use single-row optimization
    const cols = b.len + 1;
    var prev_row: [256]usize = undefined;
    if (cols > 256) return null; // Safety limit

    // Initialize first row
    for (0..cols) |j| {
        prev_row[j] = j;
    }

    for (a, 0..) |ca, i| {
        var current_row: [256]usize = undefined;
        current_row[0] = i + 1;

        var min_in_row: usize = current_row[0];

        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            const insert = current_row[j] + 1;
            const delete = prev_row[j + 1] + 1;
            const replace = prev_row[j] + cost;
            current_row[j + 1] = @min(insert, @min(delete, replace));

            if (current_row[j + 1] < min_in_row) {
                min_in_row = current_row[j + 1];
            }
        }

        // Early termination if all values exceed max
        if (min_in_row > max_distance) return null;

        prev_row = current_row;
    }

    const result = prev_row[b.len];
    return if (result <= max_distance) result else null;
}

/// Find the best "Did you mean?" suggestion from a list of candidates.
/// Returns the closest match within a reasonable edit distance, or null.
pub fn findSuggestion(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (name.len == 0 or candidates.len == 0) return null;

    // Max edit distance: 1 for short names, 2 for medium, 3 for long
    const max_dist: usize = if (name.len <= 3) 1 else if (name.len <= 7) 2 else 3;

    var best: ?[]const u8 = null;
    var best_dist: usize = max_dist + 1;

    for (candidates) |candidate| {
        if (editDistance(name, candidate, max_dist)) |dist| {
            if (dist < best_dist) {
                best_dist = dist;
                best = candidate;
            }
        }
    }

    return best;
}

/// Check if a file descriptor is connected to a TTY
pub fn isTTY(file: std.fs.File) bool {
    return file.supportsAnsiEscapeCodes();
}

// ============================================================================
// Tests
// ============================================================================

test "getSourceLine basic" {
    const source = "line one\nline two\nline three";
    try std.testing.expectEqualStrings("line one", getSourceLine(source, 1).?);
    try std.testing.expectEqualStrings("line two", getSourceLine(source, 2).?);
    try std.testing.expectEqualStrings("line three", getSourceLine(source, 3).?);
    try std.testing.expect(getSourceLine(source, 0) == null);
    try std.testing.expect(getSourceLine(source, 4) == null);
}

test "getSourceLine single line no newline" {
    const source = "hello world";
    try std.testing.expectEqualStrings("hello world", getSourceLine(source, 1).?);
    try std.testing.expect(getSourceLine(source, 2) == null);
}

test "getSourceLine empty lines" {
    const source = "a\n\nc";
    try std.testing.expectEqualStrings("a", getSourceLine(source, 1).?);
    try std.testing.expectEqualStrings("", getSourceLine(source, 2).?);
    try std.testing.expectEqualStrings("c", getSourceLine(source, 3).?);
}

test "offsetToLocation basic" {
    const source = "abc\ndef\nghi";
    const loc1 = offsetToLocation(source, 0);
    try std.testing.expectEqual(@as(u32, 1), loc1.line);
    try std.testing.expectEqual(@as(u32, 1), loc1.column);

    const loc2 = offsetToLocation(source, 5); // 'd' on line 2
    try std.testing.expectEqual(@as(u32, 2), loc2.line);
    try std.testing.expectEqual(@as(u32, 2), loc2.column);

    const loc3 = offsetToLocation(source, 8); // 'g' on line 3
    try std.testing.expectEqual(@as(u32, 3), loc3.line);
    try std.testing.expectEqual(@as(u32, 1), loc3.column);
}

test "offsetToLocation at newline" {
    const source = "ab\ncd";
    const loc = offsetToLocation(source, 2); // the '\n' itself
    try std.testing.expectEqual(@as(u32, 1), loc.line);
    try std.testing.expectEqual(@as(u32, 3), loc.column);
}

test "editDistance identical" {
    try std.testing.expectEqual(@as(?usize, 0), editDistance("hello", "hello", 3));
}

test "editDistance single char" {
    try std.testing.expectEqual(@as(?usize, 1), editDistance("hello", "hallo", 3));
    try std.testing.expectEqual(@as(?usize, 1), editDistance("cat", "bat", 3));
}

test "editDistance insertion deletion" {
    try std.testing.expectEqual(@as(?usize, 1), editDistance("hello", "hell", 3));
    try std.testing.expectEqual(@as(?usize, 1), editDistance("hell", "hello", 3));
}

test "editDistance exceeds max" {
    try std.testing.expect(editDistance("abc", "xyz", 2) == null);
}

test "editDistance empty strings" {
    try std.testing.expectEqual(@as(?usize, 0), editDistance("", "", 3));
    try std.testing.expectEqual(@as(?usize, 3), editDistance("", "abc", 3));
    try std.testing.expectEqual(@as(?usize, 3), editDistance("abc", "", 3));
    try std.testing.expect(editDistance("", "abcd", 3) == null);
}

test "findSuggestion basic" {
    const candidates = [_][]const u8{ "println", "print", "parse", "process" };
    try std.testing.expectEqualStrings("println", findSuggestion("printl", &candidates).?);
    // "pritn" -> "println" is closer than "print" because Levenshtein
    // sees pritn->print as 2 edits (swap t,n) but pritn->println as 2 edits also,
    // and "println" comes first in iteration order.
    // Test a clear single-edit case instead:
    try std.testing.expectEqualStrings("print", findSuggestion("pint", &candidates).?);
    try std.testing.expect(findSuggestion("xyz", &candidates) == null);
}

test "findSuggestion case sensitive" {
    const candidates = [_][]const u8{ "String", "string", "Strong" };
    try std.testing.expectEqualStrings("String", findSuggestion("Strng", &candidates).?);
}

test "findSuggestion empty" {
    const candidates = [_][]const u8{};
    try std.testing.expect(findSuggestion("hello", &candidates) == null);
    try std.testing.expect(findSuggestion("", &candidates) == null);
}

test "renderer single-token caret" {
    const source = "let x = 42";
    const renderer = DiagnosticRenderer.init(source, "test.ki", false);
    const diag = Diagnostic{
        .message = "undefined variable 'x'",
        .span = .{
            .start = .{ .line = 1, .column = 5, .offset = 4 },
            .end = .{ .line = 1, .column = 6, .offset = 5 },
        },
        .severity = .err,
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderer.render(fbs.writer(), diag);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "error: undefined variable 'x'") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test.ki:1:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "let x = 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "^") != null);
}

test "renderer multi-token underline" {
    const source = "let result = foo + bar";
    const renderer = DiagnosticRenderer.init(source, "test.ki", false);
    const diag = Diagnostic{
        .message = "type mismatch",
        .span = .{
            .start = .{ .line = 1, .column = 14, .offset = 13 },
            .end = .{ .line = 1, .column = 23, .offset = 22 },
        },
        .severity = .err,
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderer.render(fbs.writer(), diag);
    const output = fbs.getWritten();

    // Should have multi-char underline for "foo + bar" (9 chars)
    try std.testing.expect(std.mem.indexOf(u8, output, "^^^^^^^^^") != null);
}

test "renderer with tab handling" {
    const source = "\tlet x = 42";
    const renderer = DiagnosticRenderer.init(source, "test.ki", false);
    const diag = Diagnostic{
        .message = "test",
        .span = .{
            .start = .{ .line = 1, .column = 6, .offset = 5 },
            .end = .{ .line = 1, .column = 7, .offset = 6 },
        },
        .severity = .err,
    };

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderer.render(fbs.writer(), diag);
    const output = fbs.getWritten();

    // Tab should be expanded in displayed source
    try std.testing.expect(std.mem.indexOf(u8, output, "\t") == null);
    // Should contain the expanded line
    try std.testing.expect(std.mem.indexOf(u8, output, "    let x = 42") != null);
}

test "renderer with suggestion" {
    const source = "let x = pritnln(42)";
    const renderer = DiagnosticRenderer.init(source, "test.ki", false);
    const diag = Diagnostic{
        .message = "undefined function 'pritnln'",
        .span = .{
            .start = .{ .line = 1, .column = 9, .offset = 8 },
            .end = .{ .line = 1, .column = 16, .offset = 15 },
        },
        .severity = .err,
        .suggestion = "println",
    };

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderer.render(fbs.writer(), diag);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "did you mean 'println'?") != null);
}

test "renderer with related info" {
    const source = "let x = 1\nlet x = 2";
    const renderer = DiagnosticRenderer.init(source, "test.ki", false);
    const related = [_]RelatedInfo{.{
        .message = "first defined here",
        .span = .{
            .start = .{ .line = 1, .column = 5, .offset = 4 },
            .end = .{ .line = 1, .column = 6, .offset = 5 },
        },
    }};
    const diag = Diagnostic{
        .message = "duplicate definition of 'x'",
        .span = .{
            .start = .{ .line = 2, .column = 5, .offset = 14 },
            .end = .{ .line = 2, .column = 6, .offset = 15 },
        },
        .severity = .err,
        .related = &related,
    };

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try renderer.render(fbs.writer(), diag);
    const output = fbs.getWritten();

    try std.testing.expect(std.mem.indexOf(u8, output, "note: first defined here") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test.ki:1:5") != null);
}

test "isTTY returns bool" {
    // Just verify it doesn't crash - actual TTY detection depends on environment
    const stderr = std.fs.File.stderr();
    _ = isTTY(stderr);
}
