//! Project configuration loader for Kira.
//!
//! Searches for `kira.toml` starting from a directory and walking up
//! to find the project root. Provides module path resolution from the config.
//!
//! Supports nested package configurations: when a module path points to a
//! directory containing its own `kira.toml`, that package's internal module
//! mappings are used for resolving imports within the package.

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");

/// Configuration for a nested package (loaded from a dependency's kira.toml).
pub const PackageConfig = struct {
    /// The package name from [package] section.
    name: []const u8,
    /// The root directory of the package.
    root: []const u8,
    /// Module name -> file path mapping from [modules] section.
    modules: std.StringHashMapUnmanaged([]const u8),

    pub fn deinit(self: *PackageConfig, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.root);
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit(allocator);
    }
};

/// Errors from validating a project configuration.
pub const ValidationError = error{
    MissingPackageName,
    MissingPackageVersion,
    InvalidVersion,
};

/// Project configuration loaded from kira.toml.
pub const ProjectConfig = struct {
    /// Package name from [package] section (null for root project without package identity).
    package_name: ?[]const u8,
    /// Package version from [package] section (null if not specified).
    package_version: ?[]const u8,
    /// Package description from [package] section (null if not specified).
    package_description: ?[]const u8,
    /// Package license from [package] section (null if not specified).
    package_license: ?[]const u8,
    /// Package authors from [package] section.
    package_authors: std.ArrayListUnmanaged([]const u8),
    /// Module name -> file path mapping from [modules] section.
    modules: std.StringHashMapUnmanaged([]const u8),
    /// The directory containing kira.toml (project root).
    project_root: ?[]const u8,
    /// Whether a config file was successfully loaded.
    loaded: bool,
    /// Nested package configurations (package_name -> PackageConfig).
    packages: std.StringHashMapUnmanaged(PackageConfig),
    /// Dependencies from [dependencies] section.
    dependencies: std.ArrayListUnmanaged(toml.Dependency),
    /// Exported module names from [exports] section (opt-in; empty = no exports).
    exports: std.ArrayListUnmanaged([]const u8),

    /// Create an empty configuration.
    pub fn init() ProjectConfig {
        return .{
            .package_name = null,
            .package_version = null,
            .package_description = null,
            .package_license = null,
            .package_authors = .{},
            .modules = .{},
            .project_root = null,
            .loaded = false,
            .packages = .{},
            .dependencies = .{},
            .exports = .{},
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *ProjectConfig, allocator: Allocator) void {
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

        if (self.project_root) |root| {
            allocator.free(root);
        }

        // Free nested package configs
        var pkg_iter = self.packages.iterator();
        while (pkg_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.packages.deinit(allocator);

        for (self.dependencies.items) |*dep| {
            @constCast(dep).deinit(allocator);
        }
        self.dependencies.deinit(allocator);

        for (self.exports.items) |name| {
            allocator.free(name);
        }
        self.exports.deinit(allocator);
    }

    /// Search for and load kira.toml starting from `start_dir` and walking up.
    /// Returns true if a config file was found and loaded.
    pub fn loadFromDirectory(self: *ProjectConfig, allocator: Allocator, start_dir: []const u8) !bool {
        // Get absolute path for start_dir
        const abs_start = std.fs.cwd().realpathAlloc(allocator, start_dir) catch {
            // If start_dir doesn't exist, try current directory
            return self.loadFromDirectory(allocator, ".");
        };
        defer allocator.free(abs_start);

        var current_dir = try allocator.dupe(u8, abs_start);
        defer allocator.free(current_dir);

        // Walk up directory tree looking for kira.toml
        while (true) {
            const config_path = std.fs.path.join(allocator, &.{ current_dir, "kira.toml" }) catch break;
            defer allocator.free(config_path);

            // Try to open and read the config file
            const file = std.fs.cwd().openFile(config_path, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound => {
                        // Try parent directory
                        if (std.fs.path.dirname(current_dir)) |parent| {
                            if (std.mem.eql(u8, parent, current_dir)) {
                                // Reached filesystem root
                                break;
                            }
                            const new_dir = try allocator.dupe(u8, parent);
                            allocator.free(current_dir);
                            current_dir = new_dir;
                            continue;
                        }
                        break;
                    },
                    else => break,
                }
            };
            defer file.close();

            // Read file contents
            const source = file.readToEndAlloc(allocator, 1024 * 1024) catch break;
            defer allocator.free(source);

            // Parse TOML
            var parse_result = toml.parse(allocator, source) catch break;
            // Don't defer deinit - we're taking ownership of the data

            // Transfer package fields (null out source to prevent double-free
            // if parse_result.deinit() is ever called after partial transfer)
            if (parse_result.package_name) |name| {
                self.package_name = name;
                parse_result.package_name = null;
            }
            if (parse_result.package_version) |v| {
                self.package_version = v;
                parse_result.package_version = null;
            }
            if (parse_result.package_description) |d| {
                self.package_description = d;
                parse_result.package_description = null;
            }
            if (parse_result.package_license) |l| {
                self.package_license = l;
                parse_result.package_license = null;
            }
            // Transfer authors
            for (parse_result.package_authors.items) |author| {
                self.package_authors.append(allocator, author) catch {
                    allocator.free(author);
                    continue;
                };
            }
            parse_result.package_authors.deinit(allocator);

            // Transfer module mappings
            var modules_iter = parse_result.modules.iterator();
            while (modules_iter.next()) |entry| {
                // Keys and values are already allocated, just transfer ownership
                self.modules.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                    continue;
                };
            }
            // Free the hashmap structure itself (entries are transferred)
            parse_result.modules.deinit(allocator);

            // Transfer dependencies
            for (parse_result.dependencies.items) |dep| {
                self.dependencies.append(allocator, dep) catch {
                    var mutable_dep = dep;
                    mutable_dep.deinit(allocator);
                    continue;
                };
            }
            parse_result.dependencies.deinit(allocator);

            // Transfer exports
            for (parse_result.exports.items) |name| {
                self.exports.append(allocator, name) catch {
                    allocator.free(name);
                    continue;
                };
            }
            parse_result.exports.deinit(allocator);

            // Store project root
            self.project_root = try allocator.dupe(u8, current_dir);
            self.loaded = true;

            return true;
        }

        return false;
    }

    /// Load a nested package configuration from a directory.
    /// Called when a module path points to a directory with its own kira.toml.
    pub fn loadPackage(self: *ProjectConfig, allocator: Allocator, package_dir: []const u8) !?[]const u8 {
        const config_path = std.fs.path.join(allocator, &.{ package_dir, "kira.toml" }) catch return null;
        defer allocator.free(config_path);

        const file = std.fs.cwd().openFile(config_path, .{}) catch return null;
        defer file.close();

        const source = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
        defer allocator.free(source);

        var parse_result = toml.parse(allocator, source) catch return null;

        // Package must have a name
        const pkg_name = parse_result.package_name orelse {
            parse_result.deinit(allocator);
            return null;
        };

        // Check if already loaded - get the existing package BEFORE freeing pkg_name
        if (self.packages.getPtr(pkg_name)) |existing_pkg| {
            const existing_name = existing_pkg.name;
            parse_result.deinit(allocator);
            return existing_name;
        }

        // Create package config
        var pkg_config = PackageConfig{
            .name = pkg_name, // Take ownership
            .root = try allocator.dupe(u8, package_dir),
            .modules = .{},
        };
        errdefer pkg_config.deinit(allocator);

        // Transfer module mappings
        var modules_iter = parse_result.modules.iterator();
        while (modules_iter.next()) |entry| {
            pkg_config.modules.put(allocator, entry.key_ptr.*, entry.value_ptr.*) catch {
                allocator.free(entry.key_ptr.*);
                allocator.free(entry.value_ptr.*);
                continue;
            };
        }
        // Module entries transferred to pkg_config; just free the hashmap shell
        parse_result.modules.deinit(allocator);

        // Free remaining parse_result fields we don't use
        // (package_name ownership moved to pkg_config.name, modules transferred above)
        parse_result.package_name = null;
        parse_result.modules = .{};
        parse_result.deinit(allocator);

        // Store in packages map
        const key = try allocator.dupe(u8, pkg_name);
        try self.packages.put(allocator, key, pkg_config);

        return pkg_name;
    }

    /// Resolve a module name to its file path using the configuration.
    /// Returns null if the module is not configured.
    pub fn resolveModulePath(self: *const ProjectConfig, module_name: []const u8) ?[]const u8 {
        return self.modules.get(module_name);
    }

    /// Get the full path to a module file by joining project_root with the configured path.
    /// Caller owns the returned slice and must free it.
    ///
    /// For nested packages: if module_name starts with a known package name (e.g., "mytool.helpers"),
    /// resolves using that package's internal module mappings.
    pub fn getFullModulePath(self: *const ProjectConfig, allocator: Allocator, module_name: []const u8) ?[]u8 {
        // First, check if this is a nested package module
        // e.g., "mytool.helpers" -> look up "mytool" package, then "helpers" in its modules
        if (std.mem.indexOfScalar(u8, module_name, '.')) |dot_pos| {
            const first_segment = module_name[0..dot_pos];

            // Check if we have a package with this name
            if (self.packages.get(first_segment)) |pkg| {
                // Get the submodule name (e.g., "helpers" from "mytool.helpers")
                const submodule = module_name[dot_pos + 1 ..];

                // Handle nested module paths (e.g., "mytool.sub.module" -> submodule = "sub.module")
                // First try direct lookup for simple case
                if (std.mem.indexOfScalar(u8, submodule, '.') == null) {
                    // Simple case: no nested path
                    if (pkg.modules.get(submodule)) |relative_path| {
                        return std.fs.path.join(allocator, &.{ pkg.root, relative_path }) catch null;
                    }
                }

                // Try as a path within the package (mytool.sub.module -> sub/module.ki)
                var path_builder = std.ArrayListUnmanaged(u8){};
                for (submodule) |c| {
                    if (c == '.') {
                        path_builder.append(allocator, std.fs.path.sep) catch return null;
                    } else {
                        path_builder.append(allocator, c) catch return null;
                    }
                }
                path_builder.appendSlice(allocator, ".ki") catch return null;
                const sub_path = path_builder.toOwnedSlice(allocator) catch return null;
                defer allocator.free(sub_path);

                return std.fs.path.join(allocator, &.{ pkg.root, sub_path }) catch null;
            }
        }

        // Fall back to project-level module resolution
        const relative_path = self.modules.get(module_name) orelse return null;
        const root = self.project_root orelse return null;

        return std.fs.path.join(allocator, &.{ root, relative_path }) catch null;
    }

    /// Get a package by name.
    pub fn getPackage(self: *const ProjectConfig, package_name: []const u8) ?*const PackageConfig {
        return if (self.packages.getPtr(package_name)) |ptr| ptr else null;
    }

    /// Check if the configuration is loaded.
    pub fn isLoaded(self: *const ProjectConfig) bool {
        return self.loaded;
    }

    /// Return the list of exported module names (empty = no exports configured).
    pub fn getExports(self: *const ProjectConfig) []const []const u8 {
        return self.exports.items;
    }

    /// Check if a module name is in the exports list.
    /// If no exports are configured, returns false (opt-in).
    pub fn isExported(self: *const ProjectConfig, module_name: []const u8) bool {
        for (self.exports.items) |name| {
            if (std.mem.eql(u8, name, module_name)) return true;
        }
        return false;
    }

    /// Validate the configuration for use as a publishable package.
    /// Requires name and version at minimum.
    pub fn validate(self: *const ProjectConfig) ValidationError!void {
        if (self.package_name == null) return error.MissingPackageName;
        const version = self.package_version orelse return error.MissingPackageVersion;
        if (!isValidSemver(version)) return error.InvalidVersion;
    }

    /// Check if a string is a valid semantic version (major.minor.patch).
    fn isValidSemver(version: []const u8) bool {
        var parts: usize = 0;
        var digit_count: usize = 0;
        for (version) |c| {
            if (c == '.') {
                if (digit_count == 0) return false;
                parts += 1;
                digit_count = 0;
            } else if (std.ascii.isDigit(c)) {
                digit_count += 1;
            } else {
                return false;
            }
        }
        // Must have exactly 2 dots (3 parts) and final part must have digits
        return parts == 2 and digit_count > 0;
    }

    /// Get a dependency by name. Returns a copy of the dependency value.
    pub fn getDependency(self: *const ProjectConfig, name: []const u8) ?toml.Dependency {
        for (self.dependencies.items) |dep| {
            if (std.mem.eql(u8, dep.name, name)) return dep;
        }
        return null;
    }
};

// Tests
test "empty config" {
    var config = ProjectConfig.init();
    defer config.deinit(std.testing.allocator);

    try std.testing.expect(!config.isLoaded());
    try std.testing.expect(config.resolveModulePath("anything") == null);
}

test "load from non-existent directory" {
    var config = ProjectConfig.init();
    defer config.deinit(std.testing.allocator);

    // Should not crash, just return false
    const loaded = config.loadFromDirectory(std.testing.allocator, "/non/existent/path/that/should/not/exist") catch false;
    try std.testing.expect(!loaded);
}

test "validate requires name" {
    var config = ProjectConfig.init();
    defer config.deinit(std.testing.allocator);

    try std.testing.expectError(error.MissingPackageName, config.validate());
}

test "validate requires version" {
    const allocator = std.testing.allocator;
    var config = ProjectConfig.init();
    defer config.deinit(allocator);

    config.package_name = try allocator.dupe(u8, "test");
    try std.testing.expectError(error.MissingPackageVersion, config.validate());
}

test "validate rejects invalid version" {
    const allocator = std.testing.allocator;
    var config = ProjectConfig.init();
    defer config.deinit(allocator);

    config.package_name = try allocator.dupe(u8, "test");
    config.package_version = try allocator.dupe(u8, "not-a-version");
    try std.testing.expectError(error.InvalidVersion, config.validate());
}

test "validate accepts valid config" {
    const allocator = std.testing.allocator;
    var config = ProjectConfig.init();
    defer config.deinit(allocator);

    config.package_name = try allocator.dupe(u8, "myapp");
    config.package_version = try allocator.dupe(u8, "1.0.0");
    try config.validate();
}

test "isValidSemver" {
    try std.testing.expect(ProjectConfig.isValidSemver("0.0.1"));
    try std.testing.expect(ProjectConfig.isValidSemver("1.2.3"));
    try std.testing.expect(ProjectConfig.isValidSemver("10.20.30"));
    try std.testing.expect(!ProjectConfig.isValidSemver("1.0"));
    try std.testing.expect(!ProjectConfig.isValidSemver("1"));
    try std.testing.expect(!ProjectConfig.isValidSemver("1.0.0.0"));
    try std.testing.expect(!ProjectConfig.isValidSemver(""));
    try std.testing.expect(!ProjectConfig.isValidSemver("abc"));
    try std.testing.expect(!ProjectConfig.isValidSemver("1..0"));
    try std.testing.expect(!ProjectConfig.isValidSemver(".1.0"));
}

test "exports methods" {
    const allocator = std.testing.allocator;
    var config = ProjectConfig.init();
    defer config.deinit(allocator);

    // Initially no exports
    try std.testing.expectEqual(@as(usize, 0), config.getExports().len);
    try std.testing.expect(!config.isExported("math"));

    // Add exports
    try config.exports.append(allocator, try allocator.dupe(u8, "math"));
    try config.exports.append(allocator, try allocator.dupe(u8, "utils"));

    try std.testing.expectEqual(@as(usize, 2), config.getExports().len);
    try std.testing.expect(config.isExported("math"));
    try std.testing.expect(config.isExported("utils"));
    try std.testing.expect(!config.isExported("other"));
}

test "getDependency" {
    const allocator = std.testing.allocator;
    var config = ProjectConfig.init();
    defer config.deinit(allocator);

    const dep = toml.Dependency{
        .name = try allocator.dupe(u8, "json"),
        .constraint = .{
            .op = .caret,
            .version = try allocator.dupe(u8, "1.0.0"),
        },
        .git = null,
        .path = null,
    };
    try config.dependencies.append(allocator, dep);

    // Returns a value copy, safe to use without lifetime concerns
    const found = config.getDependency("json");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("json", found.?.name);
    try std.testing.expectEqual(toml.VersionConstraint.Op.caret, found.?.constraint.?.op);

    try std.testing.expect(config.getDependency("nonexistent") == null);
}
