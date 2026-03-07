//! Coverage tracking for `kira test --coverage`.
//!
//! Records which source lines are executed during test runs and
//! produces terminal summaries, annotated source, and JSON reports.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast/root.zig");
const Statement = ast.Statement;
const Declaration = ast.Declaration;
const lexer = @import("lexer/root.zig");
const Span = lexer.Span;

/// Tracks line-level coverage during interpreter execution.
///
/// Usage:
/// 1. Create with `init`, passing borrowed `source` and `file_path` slices
///    that must remain valid for the tracker's lifetime.
/// 2. Call `collectCoverableLines` to enumerate statement lines from the AST.
/// 3. Assign `&tracker` to `interpreter.coverage_tracker`.
/// 4. Run tests — `evalStatement` calls `recordHit` automatically.
/// 5. Call emit functions to produce reports.
///
/// Not thread-safe. Designed for single-threaded interpreter execution.
pub const CoverageTracker = struct {
    allocator: Allocator,
    /// Line number -> execution count
    line_hits: std.AutoHashMapUnmanaged(u32, u32),
    /// Set of all coverable line numbers (from AST walk)
    coverable_lines: std.AutoHashMapUnmanaged(u32, void),
    /// Borrowed source content for annotated output. Must outlive the tracker.
    source: []const u8,
    /// Borrowed source file path. Must outlive the tracker.
    file_path: []const u8,

    pub fn init(allocator: Allocator, source: []const u8, file_path: []const u8) CoverageTracker {
        return .{
            .allocator = allocator,
            .line_hits = .{},
            .coverable_lines = .{},
            .source = source,
            .file_path = file_path,
        };
    }

    pub fn deinit(self: *CoverageTracker) void {
        self.line_hits.deinit(self.allocator);
        self.coverable_lines.deinit(self.allocator);
    }

    /// Record that a statement at the given span was executed.
    pub fn recordHit(self: *CoverageTracker, span: Span) void {
        const line = span.start.line;
        if (self.line_hits.getPtr(line)) |count| {
            count.* += 1;
        } else {
            self.line_hits.put(self.allocator, line, 1) catch {};
        }
    }

    /// Walk all declarations to find coverable lines (lines containing statements).
    /// Only collects from declaration kinds that are executed during test runs
    /// (functions, tests, impl/trait methods). Benchmark bodies are excluded
    /// since they are not executed by `kira test`.
    pub fn collectCoverableLines(self: *CoverageTracker, declarations: []const Declaration) void {
        for (declarations) |decl| {
            self.collectFromDeclaration(&decl);
        }
    }

    fn collectFromDeclaration(self: *CoverageTracker, decl: *const Declaration) void {
        switch (decl.kind) {
            .function_decl => |f| {
                if (f.body) |body| self.collectFromStatements(body);
            },
            .test_decl => |t| self.collectFromStatements(t.body),
            .impl_block => |ib| {
                for (ib.methods) |method| {
                    if (method.body) |body| self.collectFromStatements(body);
                }
            },
            .trait_decl => |td| {
                for (td.methods) |method| {
                    if (method.default_body) |body| self.collectFromStatements(body);
                }
            },
            .bench_decl, .const_decl, .let_decl, .type_decl, .module_decl, .import_decl => {},
        }
    }

    fn collectFromStatements(self: *CoverageTracker, stmts: []const Statement) void {
        for (stmts) |stmt| {
            self.collectFromStatement(&stmt);
        }
    }

    fn collectFromStatement(self: *CoverageTracker, stmt: *const Statement) void {
        self.coverable_lines.put(self.allocator, stmt.span.start.line, {}) catch {};

        switch (stmt.kind) {
            .if_statement => |ifs| {
                self.collectFromStatements(ifs.then_branch);
                if (ifs.else_branch) |else_b| {
                    switch (else_b) {
                        .block => |blk| self.collectFromStatements(blk),
                        .else_if => |eif| self.collectFromStatement(eif),
                    }
                }
            },
            .for_loop => |fl| self.collectFromStatements(fl.body),
            .while_loop => |wl| self.collectFromStatements(wl.body),
            .loop_statement => |ls| self.collectFromStatements(ls.body),
            .match_statement => |m| {
                for (m.arms) |arm| {
                    self.collectFromStatements(arm.body);
                }
            },
            .block => |blk| self.collectFromStatements(blk),
            .let_binding, .var_binding, .assignment,
            .return_statement, .break_statement, .expression_statement => {},
        }
    }

    pub const Stats = struct {
        total_lines: u32,
        covered_lines: u32,

        /// Returns coverage percentage. Returns 100.0 when there are no
        /// coverable lines (no code = fully covered by convention).
        pub fn percentage(self: Stats) f64 {
            if (self.total_lines == 0) return 100.0;
            return @as(f64, @floatFromInt(self.covered_lines)) / @as(f64, @floatFromInt(self.total_lines)) * 100.0;
        }
    };

    pub fn getStats(self: *const CoverageTracker) Stats {
        var covered: u32 = 0;
        var iter = self.coverable_lines.iterator();
        while (iter.next()) |entry| {
            if (self.line_hits.contains(entry.key_ptr.*)) {
                covered += 1;
            }
        }
        return .{
            .total_lines = self.coverable_lines.count(),
            .covered_lines = covered,
        };
    }

    /// Emit a terminal coverage summary.
    pub fn emitSummary(self: *const CoverageTracker, file: std.fs.File) !void {
        const stats = self.getStats();
        var buf: [512]u8 = undefined;

        try file.writeAll("\n--- Coverage Report ---\n");

        const pct_msg = std.fmt.bufPrint(&buf, "File: {s}\n", .{self.file_path}) catch return;
        try file.writeAll(pct_msg);

        const summary = std.fmt.bufPrint(&buf, "Lines: {d}/{d} ({d:.1}%)\n", .{
            stats.covered_lines,
            stats.total_lines,
            stats.percentage(),
        }) catch return;
        try file.writeAll(summary);

        // Show uncovered lines
        var uncovered = std.ArrayListUnmanaged(u32){};
        defer uncovered.deinit(self.allocator);

        var iter = self.coverable_lines.iterator();
        while (iter.next()) |entry| {
            if (!self.line_hits.contains(entry.key_ptr.*)) {
                try uncovered.append(self.allocator, entry.key_ptr.*);
            }
        }

        if (uncovered.items.len > 0) {
            std.mem.sort(u32, uncovered.items, {}, std.sort.asc(u32));
            try file.writeAll("Uncovered lines: ");
            for (uncovered.items, 0..) |line, i| {
                if (i > 0) try file.writeAll(", ");
                const line_str = std.fmt.bufPrint(&buf, "{d}", .{line}) catch continue;
                try file.writeAll(line_str);
            }
            try file.writeAll("\n");
        }
    }

    /// Emit annotated source output showing coverage per line.
    /// Lines marked `+` were executed, `-` were not, and unmarked lines
    /// are not coverable (comments, blank lines, declarations).
    pub fn emitAnnotatedSource(self: *const CoverageTracker, file: std.fs.File) !void {
        try file.writeAll("\n--- Annotated Source ---\n");

        var line_num: u32 = 1;
        var line_start: usize = 0;
        const src = self.source;

        while (line_start < src.len) {
            const line_end = std.mem.indexOfScalar(u8, src[line_start..], '\n') orelse src.len - line_start;
            const line_content = src[line_start..][0..line_end];

            var buf: [16]u8 = undefined;
            const is_coverable = self.coverable_lines.contains(line_num);
            const hit_count = self.line_hits.get(line_num);

            const marker: []const u8 = if (!is_coverable)
                "   "
            else if (hit_count != null)
                " + "
            else
                " - ";

            const prefix = std.fmt.bufPrint(&buf, "{d:>4}", .{line_num}) catch "????";
            try file.writeAll(prefix);
            try file.writeAll(marker);
            try file.writeAll(line_content);
            try file.writeAll("\n");

            line_start += line_end + 1;
            line_num += 1;
        }
    }

    /// Emit a machine-readable JSON coverage report.
    pub fn emitJson(self: *const CoverageTracker, file: std.fs.File) !void {
        const stats = self.getStats();
        var buf: [256]u8 = undefined;

        try file.writeAll("{\"file\":\"");
        try writeJsonString(file, self.file_path);
        try file.writeAll("\",");

        const summary = std.fmt.bufPrint(&buf, "\"total_lines\":{d},\"covered_lines\":{d},\"percentage\":{d:.1},", .{
            stats.total_lines,
            stats.covered_lines,
            stats.percentage(),
        }) catch return;
        try file.writeAll(summary);

        // Covered lines array
        try file.writeAll("\"covered\":[");
        var first = true;
        var covered_iter = self.coverable_lines.iterator();
        while (covered_iter.next()) |entry| {
            if (self.line_hits.contains(entry.key_ptr.*)) {
                if (!first) try file.writeAll(",");
                const line_str = std.fmt.bufPrint(&buf, "{d}", .{entry.key_ptr.*}) catch continue;
                try file.writeAll(line_str);
                first = false;
            }
        }
        try file.writeAll("],");

        // Uncovered lines array
        try file.writeAll("\"uncovered\":[");
        first = true;
        var uncov_iter = self.coverable_lines.iterator();
        while (uncov_iter.next()) |entry| {
            if (!self.line_hits.contains(entry.key_ptr.*)) {
                if (!first) try file.writeAll(",");
                const line_str = std.fmt.bufPrint(&buf, "{d}", .{entry.key_ptr.*}) catch continue;
                try file.writeAll(line_str);
                first = false;
            }
        }
        try file.writeAll("],");

        // Per-line hit counts
        try file.writeAll("\"hits\":{");
        first = true;
        var hits_iter = self.line_hits.iterator();
        while (hits_iter.next()) |entry| {
            if (!first) try file.writeAll(",");
            const hit_str = std.fmt.bufPrint(&buf, "\"{d}\":{d}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            try file.writeAll(hit_str);
            first = false;
        }
        try file.writeAll("}}\n");
    }

    /// Write a JSON-escaped string (without surrounding quotes).
    fn writeJsonString(file: std.fs.File, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try file.writeAll("\\\""),
                '\\' => try file.writeAll("\\\\"),
                '\n' => try file.writeAll("\\n"),
                '\r' => try file.writeAll("\\r"),
                '\t' => try file.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        var buf: [6]u8 = undefined;
                        const escaped = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
                        try file.writeAll(escaped);
                    } else {
                        try file.writeAll(&.{c});
                    }
                },
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "CoverageTracker records hits" {
    var tracker = CoverageTracker.init(std.testing.allocator, "", "test.ki");
    defer tracker.deinit();

    const span1 = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };
    const span2 = Span{
        .start = .{ .line = 3, .column = 1, .offset = 20 },
        .end = .{ .line = 3, .column = 10, .offset = 29 },
    };

    try tracker.coverable_lines.put(std.testing.allocator, 1, {});
    try tracker.coverable_lines.put(std.testing.allocator, 3, {});

    tracker.recordHit(span1);
    tracker.recordHit(span1);

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u32, 2), stats.total_lines);
    try std.testing.expectEqual(@as(u32, 1), stats.covered_lines);
    try std.testing.expectEqual(@as(u32, 2), tracker.line_hits.get(1).?);
    try std.testing.expect(!tracker.line_hits.contains(3));

    tracker.recordHit(span2);
    const stats2 = tracker.getStats();
    try std.testing.expectEqual(@as(u32, 2), stats2.covered_lines);
}

test "CoverageTracker stats percentage" {
    const Stats = CoverageTracker.Stats;

    try std.testing.expectEqual(@as(f64, 100.0), (Stats{ .total_lines = 10, .covered_lines = 10 }).percentage());
    try std.testing.expectEqual(@as(f64, 50.0), (Stats{ .total_lines = 10, .covered_lines = 5 }).percentage());
    try std.testing.expectEqual(@as(f64, 100.0), (Stats{ .total_lines = 0, .covered_lines = 0 }).percentage());
}

test "CoverageTracker emitJson escapes file path" {
    var tracker = CoverageTracker.init(std.testing.allocator, "", "path/with\"quotes\\and\\backslash.ki");
    defer tracker.deinit();

    // Use a pipe to capture output
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    const write_file = std.fs.File{ .handle = pipe[1] };

    try tracker.emitJson(write_file);
    std.posix.close(pipe[1]);

    // Read back
    var output: [1024]u8 = undefined;
    const n = try std.posix.read(pipe[0], &output);
    const json = output[0..n];

    // Verify the file path is escaped
    try std.testing.expect(std.mem.indexOf(u8, json, "path/with\\\"quotes\\\\and\\\\backslash.ki") != null);
    // Verify it's valid JSON structure (starts with { ends with })
    try std.testing.expect(json[0] == '{');
    try std.testing.expect(json[n - 2] == '}'); // last char is \n
}

test "CoverageTracker emitAnnotatedSource" {
    const source = "line one\nline two\nline three\n";
    var tracker = CoverageTracker.init(std.testing.allocator, source, "test.ki");
    defer tracker.deinit();

    try tracker.coverable_lines.put(std.testing.allocator, 1, {});
    try tracker.coverable_lines.put(std.testing.allocator, 3, {});
    tracker.recordHit(.{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 8, .offset = 7 },
    });

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    const write_file = std.fs.File{ .handle = pipe[1] };

    try tracker.emitAnnotatedSource(write_file);
    std.posix.close(pipe[1]);

    var output: [1024]u8 = undefined;
    const n = try std.posix.read(pipe[0], &output);
    const text = output[0..n];

    // Line 1 covered (+), line 2 not coverable ( ), line 3 uncovered (-)
    try std.testing.expect(std.mem.indexOf(u8, text, " + line one") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "   line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, " - line three") != null);
}

test "CoverageTracker emitSummary with uncovered lines" {
    var tracker = CoverageTracker.init(std.testing.allocator, "", "test.ki");
    defer tracker.deinit();

    try tracker.coverable_lines.put(std.testing.allocator, 5, {});
    try tracker.coverable_lines.put(std.testing.allocator, 10, {});
    try tracker.coverable_lines.put(std.testing.allocator, 15, {});
    tracker.recordHit(.{
        .start = .{ .line = 10, .column = 1, .offset = 0 },
        .end = .{ .line = 10, .column = 10, .offset = 9 },
    });

    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    const write_file = std.fs.File{ .handle = pipe[1] };

    try tracker.emitSummary(write_file);
    std.posix.close(pipe[1]);

    var output: [1024]u8 = undefined;
    const n = try std.posix.read(pipe[0], &output);
    const text = output[0..n];

    try std.testing.expect(std.mem.indexOf(u8, text, "Lines: 1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Uncovered lines:") != null);
    // Uncovered lines should be sorted
    try std.testing.expect(std.mem.indexOf(u8, text, "5, 15") != null);
}

test "CoverageTracker empty source" {
    var tracker = CoverageTracker.init(std.testing.allocator, "", "empty.ki");
    defer tracker.deinit();

    const stats = tracker.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.total_lines);
    try std.testing.expectEqual(@as(f64, 100.0), stats.percentage());
}

test "writeJsonString escapes control characters" {
    const pipe = try std.posix.pipe();
    defer std.posix.close(pipe[0]);
    const write_file = std.fs.File{ .handle = pipe[1] };

    try CoverageTracker.writeJsonString(write_file, "a\tb\nc");
    std.posix.close(pipe[1]);

    var output: [64]u8 = undefined;
    const n = try std.posix.read(pipe[0], &output);
    try std.testing.expectEqualStrings("a\\tb\\nc", output[0..n]);
}
