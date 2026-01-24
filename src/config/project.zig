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

/// Project configuration loaded from kira.toml.
pub const ProjectConfig = struct {
    /// Package name from [package] section (null for root project without package identity).
    package_name: ?[]const u8,
    /// Module name -> file path mapping from [modules] section.
    modules: std.StringHashMapUnmanaged([]const u8),
    /// The directory containing kira.toml (project root).
    project_root: ?[]const u8,
    /// Whether a config file was successfully loaded.
    loaded: bool,
    /// Nested package configurations (package_name -> PackageConfig).
    packages: std.StringHashMapUnmanaged(PackageConfig),

    /// Create an empty configuration.
    pub fn init() ProjectConfig {
        return .{
            .package_name = null,
            .modules = .{},
            .project_root = null,
            .loaded = false,
            .packages = .{},
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *ProjectConfig, allocator: Allocator) void {
        if (self.package_name) |name| {
            allocator.free(name);
        }

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

            // Transfer package name if present
            if (parse_result.package_name) |name| {
                self.package_name = name; // Take ownership
            }

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
        parse_result.modules.deinit(allocator);

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
