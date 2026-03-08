//! Minimal TOML parser for kira.toml configuration.
//!
//! Supports the subset needed for Kira project configuration:
//! - `[package]` section: `name`, `version`, `description`, `license` (string),
//!   `authors` (inline array of strings)
//! - `[modules]` section: `key = "path"` mappings
//! - `[dependencies]` section: `name = "constraint"` with version operators
//!   (`^`, `~`, `>=`, `>`, `<=`, `<`, `=`)
//! - `key = "value"` string assignments, `#` comments, and blank lines

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

/// A version constraint for a dependency.
pub const VersionConstraint = struct {
    /// The constraint operator.
    op: Op,
    /// The version string (e.g., "1.2.3").
    version: []const u8,

    pub const Op = enum {
        /// Exact match: "= 1.0.0" or just "1.0.0"
        exact,
        /// Compatible (caret): "^1.0.0" — same major
        caret,
        /// Tilde: "~1.0.0" — same major.minor
        tilde,
        /// Greater than or equal: ">= 1.0.0"
        gte,
        /// Greater than: "> 1.0.0"
        gt,
        /// Less than or equal: "<= 1.0.0"
        lte,
        /// Less than: "< 1.0.0"
        lt,
    };
};

/// A dependency declaration from the [dependencies] section.
pub const Dependency = struct {
    /// Package name.
    name: []const u8,
    /// Version constraint (null means any version).
    constraint: ?VersionConstraint,
    /// Git URL (if dependency is from git).
    git: ?[]const u8,
    /// Path (if dependency is local).
    path: ?[]const u8,

    pub fn deinit(self: *Dependency, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.constraint) |c| {
            allocator.free(c.version);
        }
        if (self.git) |g| {
            allocator.free(g);
        }
        if (self.path) |p| {
            allocator.free(p);
        }
    }
};

/// Result of parsing a TOML file.
pub const ParseResult = struct {
    /// Package name from [package] section (null if not specified).
    package_name: ?[]const u8,
    /// Package version from [package] section (null if not specified).
    package_version: ?[]const u8,
    /// Package description from [package] section (null if not specified).
    package_description: ?[]const u8,
    /// Package license from [package] section (null if not specified).
    package_license: ?[]const u8,
    /// Package authors from [package] section.
    package_authors: std.ArrayListUnmanaged([]const u8),
    /// Module mappings from [modules] section.
    modules: TomlTable,
    /// Dependencies from [dependencies] section.
    dependencies: std.ArrayListUnmanaged(Dependency),
    /// Exported module names from [exports] section.
    exports: std.ArrayListUnmanaged([]const u8),

    /// Free all allocated memory.
    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        if (self.package_name) |name| {
            allocator.free(name);
        }
        if (self.package_version) |v| {
            allocator.free(v);
        }
        if (self.package_description) |d| {
            allocator.free(d);
        }
        if (self.package_license) |l| {
            allocator.free(l);
        }
        for (self.package_authors.items) |author| {
            allocator.free(author);
        }
        self.package_authors.deinit(allocator);
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit(allocator);
        for (self.dependencies.items) |*dep| {
            @constCast(dep).deinit(allocator);
        }
        self.dependencies.deinit(allocator);
        for (self.exports.items) |name| {
            allocator.free(name);
        }
        self.exports.deinit(allocator);
    }
};

/// Parse TOML source into a table of modules.
/// Returns a ParseResult that must be freed with deinit().
pub fn parse(allocator: Allocator, source: []const u8) ParseError!ParseResult {
    var result = ParseResult{
        .package_name = null,
        .package_version = null,
        .package_description = null,
        .package_license = null,
        .package_authors = .{},
        .modules = .{},
        .dependencies = .{},
        .exports = .{},
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
        if (current_section) |section| {
            if (std.mem.eql(u8, section, "package")) {
                // First check for array-valued keys (authors = [...])
                if (parseAuthorsLine(trimmed)) |authors_str| {
                    try parseArrayValues(allocator, authors_str, &result.package_authors);
                } else {
                    // Regular string-valued key
                    const kv = try parseKeyValue(trimmed);
                    if (kv) |pair| {
                        if (std.mem.eql(u8, pair.key, "name")) {
                            if (result.package_name) |old| allocator.free(old);
                            result.package_name = allocator.dupe(u8, pair.value) catch return error.OutOfMemory;
                        } else if (std.mem.eql(u8, pair.key, "version")) {
                            if (result.package_version) |old| allocator.free(old);
                            result.package_version = allocator.dupe(u8, pair.value) catch return error.OutOfMemory;
                        } else if (std.mem.eql(u8, pair.key, "description")) {
                            if (result.package_description) |old| allocator.free(old);
                            result.package_description = allocator.dupe(u8, pair.value) catch return error.OutOfMemory;
                        } else if (std.mem.eql(u8, pair.key, "license")) {
                            if (result.package_license) |old| allocator.free(old);
                            result.package_license = allocator.dupe(u8, pair.value) catch return error.OutOfMemory;
                        }
                    }
                }
            } else if (std.mem.eql(u8, section, "modules")) {
                const kv = try parseKeyValue(trimmed);
                if (kv) |pair| {
                    const key = allocator.dupe(u8, pair.key) catch return error.OutOfMemory;
                    errdefer allocator.free(key);
                    const value = allocator.dupe(u8, pair.value) catch return error.OutOfMemory;
                    result.modules.put(allocator, key, value) catch return error.OutOfMemory;
                }
            } else if (std.mem.eql(u8, section, "dependencies")) {
                // Dependencies: name = "^1.0.0" or name = { version = "^1.0.0", git = "..." }
                const kv = try parseKeyValue(trimmed);
                if (kv) |pair| {
                    var dep = Dependency{
                        .name = allocator.dupe(u8, pair.key) catch return error.OutOfMemory,
                        .constraint = null,
                        .git = null,
                        .path = null,
                    };
                    errdefer dep.deinit(allocator);

                    // Simple form: name = "^1.0.0"
                    dep.constraint = try parseVersionConstraint(allocator, pair.value);

                    result.dependencies.append(allocator, dep) catch return error.OutOfMemory;
                }
            } else if (std.mem.eql(u8, section, "exports")) {
                // Exports: modules = ["mod1", "mod2"] (array form)
                if (parseArrayLine(trimmed, "modules")) |array_content| {
                    try parseArrayValues(allocator, array_content, &result.exports);
                }
            }
            // Ignore other sections
        }
    }

    return result;
}

/// Parse a version constraint string like "^1.0.0", "~1.0.0", ">= 1.0.0", "1.0.0".
fn parseVersionConstraint(allocator: Allocator, value: []const u8) ParseError!?VersionConstraint {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;

    var op: VersionConstraint.Op = .exact;
    var version_start: usize = 0;

    if (std.mem.startsWith(u8, trimmed, "^")) {
        op = .caret;
        version_start = 1;
    } else if (std.mem.startsWith(u8, trimmed, "~")) {
        op = .tilde;
        version_start = 1;
    } else if (std.mem.startsWith(u8, trimmed, ">=")) {
        op = .gte;
        version_start = 2;
    } else if (std.mem.startsWith(u8, trimmed, ">")) {
        op = .gt;
        version_start = 1;
    } else if (std.mem.startsWith(u8, trimmed, "<=")) {
        op = .lte;
        version_start = 2;
    } else if (std.mem.startsWith(u8, trimmed, "<")) {
        op = .lt;
        version_start = 1;
    } else if (std.mem.startsWith(u8, trimmed, "=")) {
        op = .exact;
        version_start = 1;
    }

    const version_str = std.mem.trim(u8, trimmed[version_start..], " \t");
    if (version_str.len == 0) return error.InvalidSyntax;

    return VersionConstraint{
        .op = op,
        .version = allocator.dupe(u8, version_str) catch return error.OutOfMemory,
    };
}

/// Check if a line is an authors = [...] declaration and return the array content.
fn parseAuthorsLine(line: []const u8) ?[]const u8 {
    return parseArrayLine(line, "authors");
}

/// Check if a line is a `key = [...]` declaration and return the array content.
fn parseArrayLine(line: []const u8, expected_key: []const u8) ?[]const u8 {
    const eq_pos = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = std.mem.trim(u8, line[0..eq_pos], " \t");
    if (!std.mem.eql(u8, key, expected_key)) return null;

    const value_part = std.mem.trim(u8, line[eq_pos + 1 ..], " \t");
    if (value_part.len < 2 or value_part[0] != '[' or value_part[value_part.len - 1] != ']') return null;

    return value_part[1 .. value_part.len - 1];
}

/// Parse comma-separated quoted values from an array content string.
fn parseArrayValues(allocator: Allocator, content: []const u8, list: *std.ArrayListUnmanaged([]const u8)) ParseError!void {
    var rest = content;
    while (rest.len > 0) {
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len == 0) break;

        // Find opening quote
        if (rest[0] != '"') {
            // Skip non-string content (e.g., trailing comma)
            if (rest[0] == ',') {
                rest = rest[1..];
                continue;
            }
            break;
        }

        // Find closing quote
        const end_quote = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.UnterminatedString;
        const value = rest[1..end_quote];
        const duped = allocator.dupe(u8, value) catch return error.OutOfMemory;
        list.append(allocator, duped) catch {
            allocator.free(duped);
            return error.OutOfMemory;
        };

        rest = rest[end_quote + 1 ..];
        // Skip comma
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0 and rest[0] == ',') {
            rest = rest[1..];
        }
    }
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

    try std.testing.expect(result.package_name == null);
    try std.testing.expectEqual(@as(usize, 0), result.modules.count());
}

test "parse package section" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "mytool"
        \\
        \\[modules]
        \\helpers = "src/helpers.ki"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("mytool", result.package_name.?);
    try std.testing.expectEqual(@as(usize, 1), result.modules.count());
    try std.testing.expectEqualStrings("src/helpers.ki", result.modules.get("helpers").?);
}

test "parse full package manifest" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "myapp"
        \\version = "1.2.3"
        \\description = "A sample Kira application"
        \\license = "MIT"
        \\authors = ["Alice", "Bob"]
        \\
        \\[dependencies]
        \\json = "^1.0.0"
        \\http = "~2.1.0"
        \\utils = ">= 0.5.0"
        \\
        \\[modules]
        \\app = "src/app.ki"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("myapp", result.package_name.?);
    try std.testing.expectEqualStrings("1.2.3", result.package_version.?);
    try std.testing.expectEqualStrings("A sample Kira application", result.package_description.?);
    try std.testing.expectEqualStrings("MIT", result.package_license.?);

    try std.testing.expectEqual(@as(usize, 2), result.package_authors.items.len);
    try std.testing.expectEqualStrings("Alice", result.package_authors.items[0]);
    try std.testing.expectEqualStrings("Bob", result.package_authors.items[1]);

    try std.testing.expectEqual(@as(usize, 3), result.dependencies.items.len);

    // json = "^1.0.0"
    try std.testing.expectEqualStrings("json", result.dependencies.items[0].name);
    try std.testing.expectEqual(VersionConstraint.Op.caret, result.dependencies.items[0].constraint.?.op);
    try std.testing.expectEqualStrings("1.0.0", result.dependencies.items[0].constraint.?.version);

    // http = "~2.1.0"
    try std.testing.expectEqualStrings("http", result.dependencies.items[1].name);
    try std.testing.expectEqual(VersionConstraint.Op.tilde, result.dependencies.items[1].constraint.?.op);
    try std.testing.expectEqualStrings("2.1.0", result.dependencies.items[1].constraint.?.version);

    // utils = ">= 0.5.0"
    try std.testing.expectEqualStrings("utils", result.dependencies.items[2].name);
    try std.testing.expectEqual(VersionConstraint.Op.gte, result.dependencies.items[2].constraint.?.op);
    try std.testing.expectEqualStrings("0.5.0", result.dependencies.items[2].constraint.?.version);

    try std.testing.expectEqual(@as(usize, 1), result.modules.count());
}

test "parse version constraints" {
    const allocator = std.testing.allocator;

    // Exact version
    const c1 = (try parseVersionConstraint(allocator, "1.0.0")).?;
    defer allocator.free(c1.version);
    try std.testing.expectEqual(VersionConstraint.Op.exact, c1.op);
    try std.testing.expectEqualStrings("1.0.0", c1.version);

    // Explicit exact
    const c2 = (try parseVersionConstraint(allocator, "= 2.0.0")).?;
    defer allocator.free(c2.version);
    try std.testing.expectEqual(VersionConstraint.Op.exact, c2.op);
    try std.testing.expectEqualStrings("2.0.0", c2.version);

    // Caret (compatible)
    const c_caret = (try parseVersionConstraint(allocator, "^1.0.0")).?;
    defer allocator.free(c_caret.version);
    try std.testing.expectEqual(VersionConstraint.Op.caret, c_caret.op);
    try std.testing.expectEqualStrings("1.0.0", c_caret.version);

    // Tilde
    const c_tilde = (try parseVersionConstraint(allocator, "~2.1.0")).?;
    defer allocator.free(c_tilde.version);
    try std.testing.expectEqual(VersionConstraint.Op.tilde, c_tilde.op);
    try std.testing.expectEqualStrings("2.1.0", c_tilde.version);

    // Greater than
    const c3 = (try parseVersionConstraint(allocator, "> 1.5.0")).?;
    defer allocator.free(c3.version);
    try std.testing.expectEqual(VersionConstraint.Op.gt, c3.op);

    // Less than or equal
    const c4 = (try parseVersionConstraint(allocator, "<= 3.0.0")).?;
    defer allocator.free(c4.version);
    try std.testing.expectEqual(VersionConstraint.Op.lte, c4.op);

    // Less than
    const c5 = (try parseVersionConstraint(allocator, "< 4.0.0")).?;
    defer allocator.free(c5.version);
    try std.testing.expectEqual(VersionConstraint.Op.lt, c5.op);

    // Empty returns null
    const c6 = try parseVersionConstraint(allocator, "");
    try std.testing.expect(c6 == null);

    // Operator-only (no version) returns error
    try std.testing.expectError(error.InvalidSyntax, parseVersionConstraint(allocator, "^"));
    try std.testing.expectError(error.InvalidSyntax, parseVersionConstraint(allocator, ">="));
    try std.testing.expectError(error.InvalidSyntax, parseVersionConstraint(allocator, "~"));
}

test "parse single author" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "solo"
        \\authors = ["Alice"]
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.package_authors.items.len);
    try std.testing.expectEqualStrings("Alice", result.package_authors.items[0]);
}

test "parse empty authors array" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "empty"
        \\authors = []
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.package_authors.items.len);
}

test "duplicate key uses last value" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "first"
        \\name = "second"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("second", result.package_name.?);
}

test "parse empty dependencies" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "nodeps"
        \\version = "0.1.0"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.dependencies.items.len);
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

    try std.testing.expect(result.package_name == null);
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

test "parse exports section" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "mylib"
        \\version = "1.0.0"
        \\
        \\[exports]
        \\modules = ["math", "utils"]
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), result.exports.items.len);
    try std.testing.expectEqualStrings("math", result.exports.items[0]);
    try std.testing.expectEqualStrings("utils", result.exports.items[1]);
}

test "parse empty exports" {
    const allocator = std.testing.allocator;
    const source =
        \\[exports]
        \\modules = []
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.exports.items.len);
}

test "no exports section means empty list" {
    const allocator = std.testing.allocator;
    const source =
        \\[package]
        \\name = "noexports"
    ;

    var result = try parse(allocator, source);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), result.exports.items.len);
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
