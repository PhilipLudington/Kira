//! Minimal TOML parser for kira.toml configuration.
//!
//! Supports only the subset needed for Kira project configuration:
//! - `[modules]` section header
//! - `key = "value"` string assignments
//! - `#` comments and blank lines

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A simple TOML table storing string key-value pairs.
pub const TomlTable = std.StringHashMapUnmanaged([]const u8);

/// Errors that can occur during TOML parsing.
pub const ParseError = error{
    InvalidSyntax,
    UnterminatedString,
    InvalidKey,
    OutOfMemory,
};

/// Result of parsing a TOML file.
pub const ParseResult = struct {
    modules: TomlTable,

    /// Free all allocated memory.
    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit(allocator);
    }
};

/// Parse TOML source into a table of modules.
/// Returns a ParseResult that must be freed with deinit().
pub fn parse(allocator: Allocator, source: []const u8) ParseError!ParseResult {
    var result = ParseResult{
        .modules = .{},
    };
    errdefer result.deinit(allocator);

    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }

        // Section header: [section]
        if (trimmed[0] == '[') {
            if (trimmed.len < 2 or trimmed[trimmed.len - 1] != ']') {
                return error.InvalidSyntax;
            }
            current_section = trimmed[1 .. trimmed.len - 1];
            continue;
        }

        // Key-value pair: key = "value"
        // Only process if we're in the [modules] section
        if (current_section) |section| {
            if (!std.mem.eql(u8, section, "modules")) {
                continue;
            }

            const kv = try parseKeyValue(trimmed);
            if (kv) |pair| {
                const key = allocator.dupe(u8, pair.key) catch return error.OutOfMemory;
                errdefer allocator.free(key);

                const value = allocator.dupe(u8, pair.value) catch return error.OutOfMemory;

                result.modules.put(allocator, key, value) catch return error.OutOfMemory;
            }
        }
    }

    return result;
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

/// Parse a key = "value" line.
fn parseKeyValue(line: []const u8) ParseError!?KeyValue {
    // Find the '=' separator
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return null;

    const key = std.mem.trim(u8, line[0..eq_pos], " \t");
    if (key.len == 0) {
        return error.InvalidKey;
    }

    // Validate key characters (alphanumeric, underscore, hyphen)
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
            return error.InvalidKey;
        }
    }

    const value_part = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");

    // Value must be a quoted string
    if (value_part.len < 2) {
        return error.InvalidSyntax;
    }

    if (value_part[0] == '"') {
        // Double-quoted string
        if (value_part[value_part.len - 1] != '"') {
            return error.UnterminatedString;
        }
        return KeyValue{
            .key = key,
            .value = value_part[1 .. value_part.len - 1],
        };
    } else if (value_part[0] == '\'') {
        // Single-quoted string (literal)
        if (value_part[value_part.len - 1] != '\'') {
            return error.UnterminatedString;
        }
        return KeyValue{
            .key = key,
            .value = value_part[1 .. value_part.len - 1],
        };
    }

    return error.InvalidSyntax;
}

// Tests
test "parse empty source" {
    const allocator = std.testing.allocator;
    var result = try parse(allocator, "");
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.modules.count());
}

test "parse modules section" {
    const allocator = std.testing.allocator;
    const source =
        \\# Kira project configuration
        \\
        \\[modules]
        \\kira_test = "lib/kira-test.ki"
        \\geometry = "examples/geometry"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.modules.count());
    try std.testing.expectEqualStrings("lib/kira-test.ki", result.modules.get("kira_test").?);
    try std.testing.expectEqualStrings("examples/geometry", result.modules.get("geometry").?);
}

test "parse with comments" {
    const allocator = std.testing.allocator;
    const source =
        \\[modules]
        \\# This is a comment
        \\foo = "bar"
        \\# Another comment
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.modules.count());
    try std.testing.expectEqualStrings("bar", result.modules.get("foo").?);
}

test "parse single-quoted strings" {
    const allocator = std.testing.allocator;
    const source =
        \\[modules]
        \\test = 'path/to/file'
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("path/to/file", result.modules.get("test").?);
}

test "ignore other sections" {
    const allocator = std.testing.allocator;
    const source =
        \\[other]
        \\ignored = "value"
        \\
        \\[modules]
        \\included = "path"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.modules.count());
    try std.testing.expect(result.modules.get("ignored") == null);
    try std.testing.expectEqualStrings("path", result.modules.get("included").?);
}

test "invalid syntax errors" {
    const allocator = std.testing.allocator;

    // Unterminated section
    const result1 = parse(allocator, "[modules");
    try std.testing.expectError(error.InvalidSyntax, result1);

    // Unterminated string
    const result2 = parse(allocator,
        \\[modules]
        \\key = "unterminated
    );
    try std.testing.expectError(error.UnterminatedString, result2);

    // Invalid key characters
    const result3 = parse(allocator,
        \\[modules]
        \\bad.key = "value"
    );
    try std.testing.expectError(error.InvalidKey, result3);
}
