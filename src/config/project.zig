//! Project configuration loader for Kira.
//!
//! Searches for `kira.toml` starting from a directory and walking up
//! to find the project root. Provides module path resolution from the config.

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");

/// Project configuration loaded from kira.toml.
pub const ProjectConfig = struct {
    /// Module name -> file path mapping from [modules] section.
    modules: std.StringHashMapUnmanaged([]const u8),
    /// The directory containing kira.toml (project root).
    project_root: ?[]const u8,
    /// Whether a config file was successfully loaded.
    loaded: bool,

    /// Create an empty configuration.
    pub fn init() ProjectConfig {
        return .{
            .modules = .{},
            .project_root = null,
            .loaded = false,
        };
    }

    /// Free all allocated memory.
    pub fn deinit(self: *ProjectConfig, allocator: Allocator) void {
        var iter = self.modules.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.modules.deinit(allocator);

        if (self.project_root) |root| {
            allocator.free(root);
        }
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
            // Don't defer deinit - we're taking ownership of the modules

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

    /// Resolve a module name to its file path using the configuration.
    /// Returns null if the module is not configured.
    pub fn resolveModulePath(self: *const ProjectConfig, module_name: []const u8) ?[]const u8 {
        return self.modules.get(module_name);
    }

    /// Get the full path to a module file by joining project_root with the configured path.
    /// Caller owns the returned slice and must free it.
    pub fn getFullModulePath(self: *const ProjectConfig, allocator: Allocator, module_name: []const u8) ?[]u8 {
        const relative_path = self.modules.get(module_name) orelse return null;
        const root = self.project_root orelse return null;

        return std.fs.path.join(allocator, &.{ root, relative_path }) catch null;
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
