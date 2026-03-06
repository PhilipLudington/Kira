//! Dependency resolution for Kira packages.
//!
//! Resolves dependency versions from path, git, or cached sources.
//! Handles diamond dependencies (same package required by multiple deps)
//! and detects version conflicts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");
const project = @import("project.zig");

/// Semantic version with major.minor.patch components.
pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub const ParseError = error{InvalidVersion};

    /// Parse a version string like "1.2.3" into components.
    pub fn parse(version: []const u8) ParseError!SemVer {
        var parts: [3]u32 = .{ 0, 0, 0 };
        var part_idx: usize = 0;
        var digit_count: usize = 0;

        for (version) |c| {
            if (c == '.') {
                if (digit_count == 0 or part_idx >= 2) return error.InvalidVersion;
                part_idx += 1;
                digit_count = 0;
            } else if (std.ascii.isDigit(c)) {
                parts[part_idx] = parts[part_idx] *| 10 +| (c - '0');
                digit_count += 1;
            } else {
                return error.InvalidVersion;
            }
        }

        if (part_idx != 2 or digit_count == 0) return error.InvalidVersion;

        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    /// Compare two versions. Returns ordering.
    pub fn order(a: SemVer, b: SemVer) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    /// Check equality.
    pub fn eql(a: SemVer, b: SemVer) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
    }
};

/// Check if a version satisfies a constraint.
pub fn satisfiesConstraint(version: SemVer, constraint: toml.VersionConstraint) SemVer.ParseError!bool {
    const constraint_ver = try SemVer.parse(constraint.version);

    return switch (constraint.op) {
        .exact => version.eql(constraint_ver),
        .caret => blk: {
            // ^1.2.3 means >=1.2.3 and <2.0.0 (same major)
            // ^0.2.3 means >=0.2.3 and <0.3.0 (same major.minor when major=0)
            // ^0.0.3 means >=0.0.3 and <0.0.4 (exact patch when major=0,minor=0)
            if (version.order(constraint_ver) == .lt) break :blk false;
            if (constraint_ver.major > 0) {
                break :blk version.major == constraint_ver.major;
            } else if (constraint_ver.minor > 0) {
                break :blk version.major == 0 and version.minor == constraint_ver.minor;
            } else {
                break :blk version.eql(constraint_ver);
            }
        },
        .tilde => blk: {
            // ~1.2.3 means >=1.2.3 and <1.3.0 (same major.minor)
            if (version.order(constraint_ver) == .lt) break :blk false;
            break :blk version.major == constraint_ver.major and version.minor == constraint_ver.minor;
        },
        .gte => version.order(constraint_ver) != .lt,
        .gt => version.order(constraint_ver) == .gt,
        .lte => version.order(constraint_ver) != .gt,
        .lt => version.order(constraint_ver) == .lt,
    };
}

/// Check if two constraints can potentially be satisfied by the same version.
pub fn constraintsCompatible(a: toml.VersionConstraint, b: toml.VersionConstraint) SemVer.ParseError!bool {
    const ver_a = try SemVer.parse(a.version);
    const ver_b = try SemVer.parse(b.version);

    // For exact constraints, both must be the same version
    if (a.op == .exact and b.op == .exact) return ver_a.eql(ver_b);

    // For caret constraints on the same major (or minor for 0.x), they're compatible
    if (a.op == .caret and b.op == .caret) {
        if (ver_a.major > 0 and ver_b.major > 0) return ver_a.major == ver_b.major;
        if (ver_a.major == 0 and ver_b.major == 0) {
            if (ver_a.minor > 0 and ver_b.minor > 0) return ver_a.minor == ver_b.minor;
        }
    }

    // For tilde constraints on the same major.minor, they're compatible
    if (a.op == .tilde and b.op == .tilde) {
        return ver_a.major == ver_b.major and ver_a.minor == ver_b.minor;
    }

    // For mixed constraints, be conservative — check if the higher version satisfies both
    const higher = if (ver_a.order(ver_b) != .lt) ver_a else ver_b;
    const sat_a = try satisfiesConstraint(higher, a);
    const sat_b = try satisfiesConstraint(higher, b);
    return sat_a and sat_b;
}

/// Source type for a resolved dependency.
pub const DepSource = enum {
    /// Local filesystem path.
    path,
    /// Cloned from git repository.
    git,
    /// Found in local cache.
    cache,
};

/// A fully resolved dependency with its local path.
pub const ResolvedDependency = struct {
    /// Package name.
    name: []const u8,
    /// Resolved version (null if version unknown, e.g., path dep without manifest version).
    version: ?SemVer,
    /// Local filesystem path to the package root.
    local_path: []const u8,
    /// How the dependency was resolved.
    source: DepSource,

    pub fn deinit(self: *ResolvedDependency, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.local_path);
    }
};

/// Errors from dependency resolution.
pub const ResolveError = error{
    VersionConflict,
    DependencyNotFound,
    NoSourceSpecified,
    GitCloneFailed,
    InvalidManifest,
    CircularDependency,
    OutOfMemory,
    InvalidVersion,
};

/// Resolves project dependencies to local paths.
pub const DependencyResolver = struct {
    allocator: Allocator,
    /// Cache directory for downloaded packages (e.g., ~/.kira/cache/packages).
    cache_dir: []const u8,
    /// Project root directory for resolving relative paths.
    project_root: []const u8,
    /// Already-resolved packages (name -> resolved info).
    resolved: std.StringHashMapUnmanaged(ResolvedDependency),
    /// Packages currently being resolved (for cycle detection).
    in_progress: std.StringHashMapUnmanaged(void),
    /// Constraints collected for each package from all dependents.
    constraints: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(toml.VersionConstraint)),

    pub fn init(allocator: Allocator, project_root: []const u8, cache_dir: []const u8) ResolveError!DependencyResolver {
        const cache_dir_copy = allocator.dupe(u8, cache_dir) catch return error.OutOfMemory;
        errdefer allocator.free(cache_dir_copy);
        const project_root_copy = allocator.dupe(u8, project_root) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .cache_dir = cache_dir_copy,
            .project_root = project_root_copy,
            .resolved = .{},
            .in_progress = .{},
            .constraints = .{},
        };
    }

    pub fn deinit(self: *DependencyResolver) void {
        var res_iter = self.resolved.iterator();
        while (res_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.*;
            val.deinit(self.allocator);
        }
        self.resolved.deinit(self.allocator);

        var ip_iter = self.in_progress.iterator();
        while (ip_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.in_progress.deinit(self.allocator);

        var con_iter = self.constraints.iterator();
        while (con_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |c| {
                self.allocator.free(c.version);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.constraints.deinit(self.allocator);

        self.allocator.free(self.cache_dir);
        self.allocator.free(self.project_root);
    }

    /// Resolve all dependencies from a project config.
    /// Returns a list of resolved dependencies. Caller owns the returned slice.
    pub fn resolveAll(self: *DependencyResolver, config: *const project.ProjectConfig) ResolveError![]ResolvedDependency {
        for (config.dependencies.items) |dep| {
            try self.resolveSingle(dep);
        }

        // Build result list
        var result = std.ArrayListUnmanaged(ResolvedDependency){};
        errdefer {
            for (result.items) |*r| {
                r.deinit(self.allocator);
            }
            result.deinit(self.allocator);
        }

        var iter = self.resolved.iterator();
        while (iter.next()) |entry| {
            const copy = ResolvedDependency{
                .name = self.allocator.dupe(u8, entry.value_ptr.name) catch return error.OutOfMemory,
                .version = entry.value_ptr.version,
                .local_path = self.allocator.dupe(u8, entry.value_ptr.local_path) catch return error.OutOfMemory,
                .source = entry.value_ptr.source,
            };
            result.append(self.allocator, copy) catch return error.OutOfMemory;
        }

        return result.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    /// Resolve a single dependency, recursively resolving its own dependencies.
    fn resolveSingle(self: *DependencyResolver, dep: toml.Dependency) ResolveError!void {
        // Already resolved — check constraint compatibility
        if (self.resolved.get(dep.name)) |existing| {
            if (dep.constraint) |new_constraint| {
                if (existing.version) |ver| {
                    const satisfied = satisfiesConstraint(ver, new_constraint) catch return error.InvalidVersion;
                    if (!satisfied) return error.VersionConflict;
                }
                // Record the additional constraint
                try self.addConstraint(dep.name, new_constraint);
            }
            return;
        }

        // Cycle detection
        if (self.in_progress.get(dep.name) != null) {
            return error.CircularDependency;
        }
        const ip_key = self.allocator.dupe(u8, dep.name) catch return error.OutOfMemory;
        self.in_progress.put(self.allocator, ip_key, {}) catch return error.OutOfMemory;
        errdefer {
            if (self.in_progress.fetchRemove(dep.name)) |kv| {
                self.allocator.free(kv.key);
            }
        }

        // Record constraint
        if (dep.constraint) |c| {
            try self.addConstraint(dep.name, c);
        }

        // Resolve based on source type
        const resolved = if (dep.path) |path|
            try self.resolvePathDep(dep.name, path)
        else if (dep.git) |git_url|
            try self.resolveGitDep(dep.name, git_url)
        else if (dep.constraint != null)
            try self.resolveCachedDep(dep.name, dep.constraint.?)
        else
            return error.NoSourceSpecified;

        // Store resolved dependency
        const key = self.allocator.dupe(u8, dep.name) catch return error.OutOfMemory;
        self.resolved.put(self.allocator, key, resolved) catch return error.OutOfMemory;

        // Remove from in-progress
        if (self.in_progress.fetchRemove(dep.name)) |kv| {
            self.allocator.free(kv.key);
        }

        // Recursively resolve transitive dependencies
        try self.resolveTransitive(resolved.local_path);
    }

    /// Resolve a path-based dependency.
    fn resolvePathDep(self: *DependencyResolver, name: []const u8, rel_path: []const u8) ResolveError!ResolvedDependency {
        // Resolve relative to project root
        const abs_path = std.fs.path.join(self.allocator, &.{ self.project_root, rel_path }) catch return error.OutOfMemory;
        errdefer self.allocator.free(abs_path);

        // Verify directory exists
        std.fs.cwd().access(abs_path, .{}) catch return error.DependencyNotFound;

        // Try to read version from kira.toml
        const version = self.readPackageVersion(abs_path);

        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = version,
            .local_path = abs_path,
            .source = .path,
        };
    }

    /// Resolve a git-based dependency by cloning to cache.
    fn resolveGitDep(self: *DependencyResolver, name: []const u8, git_url: []const u8) ResolveError!ResolvedDependency {
        // Target: <cache_dir>/<name>
        const pkg_dir = std.fs.path.join(self.allocator, &.{ self.cache_dir, name }) catch return error.OutOfMemory;
        errdefer self.allocator.free(pkg_dir);

        // Check if already cached
        const is_cached = blk: {
            std.fs.cwd().access(pkg_dir, .{}) catch break :blk false;
            // Verify kira.toml exists in cached dir
            const toml_path = std.fs.path.join(self.allocator, &.{ pkg_dir, "kira.toml" }) catch break :blk false;
            defer self.allocator.free(toml_path);
            std.fs.cwd().access(toml_path, .{}) catch break :blk false;
            break :blk true;
        };

        if (!is_cached) {
            // Clone the repository
            try self.gitClone(git_url, pkg_dir);
        }

        const version = self.readPackageVersion(pkg_dir);

        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = version,
            .local_path = pkg_dir,
            .source = if (is_cached) .cache else .git,
        };
    }

    /// Resolve a dependency from the local cache by version constraint.
    fn resolveCachedDep(self: *DependencyResolver, name: []const u8, constraint: toml.VersionConstraint) ResolveError!ResolvedDependency {
        // Look in cache_dir for the package
        const pkg_dir = std.fs.path.join(self.allocator, &.{ self.cache_dir, name }) catch return error.OutOfMemory;
        errdefer self.allocator.free(pkg_dir);

        // Check if the package exists in cache
        std.fs.cwd().access(pkg_dir, .{}) catch return error.DependencyNotFound;

        // Read version and check constraint
        const version = self.readPackageVersion(pkg_dir);
        if (version) |ver| {
            const satisfied = satisfiesConstraint(ver, constraint) catch return error.InvalidVersion;
            if (!satisfied) return error.VersionConflict;
        }

        return .{
            .name = self.allocator.dupe(u8, name) catch return error.OutOfMemory,
            .version = version,
            .local_path = pkg_dir,
            .source = .cache,
        };
    }

    /// Read the version from a package's kira.toml.
    fn readPackageVersion(self: *DependencyResolver, pkg_dir: []const u8) ?SemVer {
        const toml_path = std.fs.path.join(self.allocator, &.{ pkg_dir, "kira.toml" }) catch return null;
        defer self.allocator.free(toml_path);

        const file = std.fs.cwd().openFile(toml_path, .{}) catch return null;
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return null;
        defer self.allocator.free(source);

        var parse_result = toml.parse(self.allocator, source) catch return null;
        defer parse_result.deinit(self.allocator);

        const version_str = parse_result.package_version orelse return null;
        return SemVer.parse(version_str) catch null;
    }

    /// Resolve transitive dependencies from a package's kira.toml.
    fn resolveTransitive(self: *DependencyResolver, pkg_dir: []const u8) ResolveError!void {
        const toml_path = std.fs.path.join(self.allocator, &.{ pkg_dir, "kira.toml" }) catch return error.OutOfMemory;
        defer self.allocator.free(toml_path);

        const file = std.fs.cwd().openFile(toml_path, .{}) catch return;
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(source);

        var parse_result = toml.parse(self.allocator, source) catch return;
        defer parse_result.deinit(self.allocator);

        for (parse_result.dependencies.items) |dep| {
            // Adjust path deps to be relative to the package, not the project root
            if (dep.path != null) {
                var adjusted = dep;
                const abs_path = std.fs.path.join(self.allocator, &.{ pkg_dir, dep.path.? }) catch return error.OutOfMemory;
                defer self.allocator.free(abs_path);

                // Create a dep with absolute path
                var abs_dep = toml.Dependency{
                    .name = dep.name,
                    .constraint = dep.constraint,
                    .git = dep.git,
                    .path = abs_path,
                };
                _ = &adjusted;
                try self.resolveSingle(abs_dep);
                abs_dep.path = null; // Don't free — it's deferred above
                abs_dep.name = ""; // Don't free — owned by parse_result
                abs_dep.constraint = null;
                abs_dep.git = null;
            } else {
                try self.resolveSingle(dep);
            }
        }
    }

    /// Record a version constraint for a dependency name.
    fn addConstraint(self: *DependencyResolver, name: []const u8, constraint: toml.VersionConstraint) ResolveError!void {
        const gop = self.constraints.getOrPut(self.allocator, name) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
            gop.value_ptr.* = .{};
        }
        const version_copy = self.allocator.dupe(u8, constraint.version) catch return error.OutOfMemory;
        gop.value_ptr.append(self.allocator, .{
            .op = constraint.op,
            .version = version_copy,
        }) catch return error.OutOfMemory;
    }

    /// Clone a git repository to a target directory.
    fn gitClone(self: *DependencyResolver, url: []const u8, target: []const u8) ResolveError!void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(target)) |parent| {
            std.fs.cwd().makePath(parent) catch return error.GitCloneFailed;
        }

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "git", "clone", "--depth", "1", url, target },
        }) catch return error.GitCloneFailed;

        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) return error.GitCloneFailed;
    }

    /// Check all collected constraints for a package are mutually compatible.
    pub fn checkConstraints(self: *DependencyResolver, name: []const u8) ResolveError!bool {
        const constraint_list = self.constraints.get(name) orelse return true;
        if (constraint_list.items.len <= 1) return true;

        // Check each pair of constraints
        for (constraint_list.items[0 .. constraint_list.items.len - 1], 0..) |a, i| {
            for (constraint_list.items[i + 1 ..]) |b| {
                const compat = constraintsCompatible(a, b) catch return error.InvalidVersion;
                if (!compat) return false;
            }
        }

        return true;
    }
};

// --- Tests ---

test "SemVer parse valid" {
    const v = try SemVer.parse("1.2.3");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 2), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
}

test "SemVer parse zero" {
    const v = try SemVer.parse("0.0.0");
    try std.testing.expectEqual(@as(u32, 0), v.major);
    try std.testing.expectEqual(@as(u32, 0), v.minor);
    try std.testing.expectEqual(@as(u32, 0), v.patch);
}

test "SemVer parse large" {
    const v = try SemVer.parse("10.20.30");
    try std.testing.expectEqual(@as(u32, 10), v.major);
    try std.testing.expectEqual(@as(u32, 20), v.minor);
    try std.testing.expectEqual(@as(u32, 30), v.patch);
}

test "SemVer parse invalid" {
    try std.testing.expectError(error.InvalidVersion, SemVer.parse(""));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse("1"));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse("1.0"));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse("1.0.0.0"));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse("abc"));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse("1..0"));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse(".1.0"));
    try std.testing.expectError(error.InvalidVersion, SemVer.parse("1.0."));
}

test "SemVer order" {
    const v100 = try SemVer.parse("1.0.0");
    const v110 = try SemVer.parse("1.1.0");
    const v111 = try SemVer.parse("1.1.1");
    const v200 = try SemVer.parse("2.0.0");

    try std.testing.expectEqual(std.math.Order.eq, v100.order(v100));
    try std.testing.expectEqual(std.math.Order.lt, v100.order(v110));
    try std.testing.expectEqual(std.math.Order.lt, v110.order(v111));
    try std.testing.expectEqual(std.math.Order.lt, v111.order(v200));
    try std.testing.expectEqual(std.math.Order.gt, v200.order(v100));
}

test "satisfiesConstraint exact" {
    const v = try SemVer.parse("1.2.3");
    const c = toml.VersionConstraint{ .op = .exact, .version = "1.2.3" };
    try std.testing.expect(try satisfiesConstraint(v, c));

    const c2 = toml.VersionConstraint{ .op = .exact, .version = "1.2.4" };
    try std.testing.expect(!try satisfiesConstraint(v, c2));
}

test "satisfiesConstraint caret" {
    // ^1.2.3 means >=1.2.3, <2.0.0
    const c = toml.VersionConstraint{ .op = .caret, .version = "1.2.3" };
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("1.2.3"), c));
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("1.9.9"), c));
    try std.testing.expect(!try satisfiesConstraint(try SemVer.parse("2.0.0"), c));
    try std.testing.expect(!try satisfiesConstraint(try SemVer.parse("1.2.2"), c));

    // ^0.2.3 means >=0.2.3, <0.3.0
    const c0 = toml.VersionConstraint{ .op = .caret, .version = "0.2.3" };
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("0.2.3"), c0));
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("0.2.9"), c0));
    try std.testing.expect(!try satisfiesConstraint(try SemVer.parse("0.3.0"), c0));

    // ^0.0.3 means exactly 0.0.3
    const c00 = toml.VersionConstraint{ .op = .caret, .version = "0.0.3" };
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("0.0.3"), c00));
    try std.testing.expect(!try satisfiesConstraint(try SemVer.parse("0.0.4"), c00));
}

test "satisfiesConstraint tilde" {
    // ~1.2.3 means >=1.2.3, <1.3.0
    const c = toml.VersionConstraint{ .op = .tilde, .version = "1.2.3" };
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("1.2.3"), c));
    try std.testing.expect(try satisfiesConstraint(try SemVer.parse("1.2.9"), c));
    try std.testing.expect(!try satisfiesConstraint(try SemVer.parse("1.3.0"), c));
    try std.testing.expect(!try satisfiesConstraint(try SemVer.parse("1.2.2"), c));
}

test "satisfiesConstraint comparison operators" {
    const v = try SemVer.parse("1.5.0");

    try std.testing.expect(try satisfiesConstraint(v, .{ .op = .gte, .version = "1.0.0" }));
    try std.testing.expect(try satisfiesConstraint(v, .{ .op = .gte, .version = "1.5.0" }));
    try std.testing.expect(!try satisfiesConstraint(v, .{ .op = .gte, .version = "2.0.0" }));

    try std.testing.expect(try satisfiesConstraint(v, .{ .op = .gt, .version = "1.0.0" }));
    try std.testing.expect(!try satisfiesConstraint(v, .{ .op = .gt, .version = "1.5.0" }));

    try std.testing.expect(try satisfiesConstraint(v, .{ .op = .lte, .version = "2.0.0" }));
    try std.testing.expect(try satisfiesConstraint(v, .{ .op = .lte, .version = "1.5.0" }));
    try std.testing.expect(!try satisfiesConstraint(v, .{ .op = .lte, .version = "1.0.0" }));

    try std.testing.expect(try satisfiesConstraint(v, .{ .op = .lt, .version = "2.0.0" }));
    try std.testing.expect(!try satisfiesConstraint(v, .{ .op = .lt, .version = "1.5.0" }));
}

test "constraintsCompatible same caret major" {
    const a = toml.VersionConstraint{ .op = .caret, .version = "1.2.0" };
    const b = toml.VersionConstraint{ .op = .caret, .version = "1.5.0" };
    try std.testing.expect(try constraintsCompatible(a, b));
}

test "constraintsCompatible different caret major" {
    const a = toml.VersionConstraint{ .op = .caret, .version = "1.2.0" };
    const b = toml.VersionConstraint{ .op = .caret, .version = "2.0.0" };
    try std.testing.expect(!try constraintsCompatible(a, b));
}

test "constraintsCompatible exact conflict" {
    const a = toml.VersionConstraint{ .op = .exact, .version = "1.0.0" };
    const b = toml.VersionConstraint{ .op = .exact, .version = "2.0.0" };
    try std.testing.expect(!try constraintsCompatible(a, b));
}

test "constraintsCompatible exact match" {
    const a = toml.VersionConstraint{ .op = .exact, .version = "1.0.0" };
    const b = toml.VersionConstraint{ .op = .exact, .version = "1.0.0" };
    try std.testing.expect(try constraintsCompatible(a, b));
}

test "constraintsCompatible tilde same minor" {
    const a = toml.VersionConstraint{ .op = .tilde, .version = "1.2.0" };
    const b = toml.VersionConstraint{ .op = .tilde, .version = "1.2.5" };
    try std.testing.expect(try constraintsCompatible(a, b));
}

test "constraintsCompatible tilde different minor" {
    const a = toml.VersionConstraint{ .op = .tilde, .version = "1.2.0" };
    const b = toml.VersionConstraint{ .op = .tilde, .version = "1.3.0" };
    try std.testing.expect(!try constraintsCompatible(a, b));
}

test "resolve single path dependency" {
    const allocator = std.testing.allocator;

    // Create a temporary directory structure for testing
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a package directory with kira.toml
    tmp.dir.makeDir("mylib") catch {};
    const toml_content = "[package]\nname = \"mylib\"\nversion = \"1.0.0\"\n";
    const pkg_toml = tmp.dir.createFile("mylib/kira.toml", .{}) catch unreachable;
    pkg_toml.writeAll(toml_content) catch unreachable;
    pkg_toml.close();

    // Get the tmp dir path
    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_path);

    const cache_path = std.fs.path.join(allocator, &.{ tmp_path, ".cache" }) catch unreachable;
    defer allocator.free(cache_path);

    var resolver = DependencyResolver.init(allocator, tmp_path, cache_path) catch unreachable;
    defer resolver.deinit();

    // Create a config with one path dependency
    var config = project.ProjectConfig.init();
    defer config.deinit(allocator);

    const dep = toml.Dependency{
        .name = try allocator.dupe(u8, "mylib"),
        .constraint = null,
        .git = null,
        .path = try allocator.dupe(u8, "mylib"),
    };
    try config.dependencies.append(allocator, dep);

    const resolved = try resolver.resolveAll(&config);
    defer {
        for (resolved) |*r| {
            @constCast(r).deinit(allocator);
        }
        allocator.free(resolved);
    }

    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("mylib", resolved[0].name);
    try std.testing.expectEqual(DepSource.path, resolved[0].source);
    try std.testing.expectEqual(@as(u32, 1), resolved[0].version.?.major);
    try std.testing.expectEqual(@as(u32, 0), resolved[0].version.?.minor);
    try std.testing.expectEqual(@as(u32, 0), resolved[0].version.?.patch);
}

test "resolve diamond dependency" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create shared dependency: "shared" v1.0.0
    tmp.dir.makeDir("shared") catch {};
    const shared_toml = tmp.dir.createFile("shared/kira.toml", .{}) catch unreachable;
    shared_toml.writeAll("[package]\nname = \"shared\"\nversion = \"1.0.0\"\n") catch unreachable;
    shared_toml.close();

    // Create "liba" which depends on "shared" ^1.0.0
    tmp.dir.makeDir("liba") catch {};
    const liba_toml = tmp.dir.createFile("liba/kira.toml", .{}) catch unreachable;
    liba_toml.writeAll("[package]\nname = \"liba\"\nversion = \"1.0.0\"\n\n[dependencies]\nshared = \"^1.0.0\"\n") catch unreachable;
    liba_toml.close();

    // Create "libb" which also depends on "shared" ^1.0.0
    tmp.dir.makeDir("libb") catch {};
    const libb_toml = tmp.dir.createFile("libb/kira.toml", .{}) catch unreachable;
    libb_toml.writeAll("[package]\nname = \"libb\"\nversion = \"1.0.0\"\n\n[dependencies]\nshared = \"^1.0.0\"\n") catch unreachable;
    libb_toml.close();

    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_path);

    // Use the tmp dir itself as cache so transitive deps can find "shared"
    var resolver = DependencyResolver.init(allocator, tmp_path, tmp_path) catch unreachable;
    defer resolver.deinit();

    // Root depends on both liba and libb (diamond -> shared)
    var config = project.ProjectConfig.init();
    defer config.deinit(allocator);

    const dep_a = toml.Dependency{
        .name = try allocator.dupe(u8, "liba"),
        .constraint = null,
        .git = null,
        .path = try allocator.dupe(u8, "liba"),
    };
    try config.dependencies.append(allocator, dep_a);

    const dep_b = toml.Dependency{
        .name = try allocator.dupe(u8, "libb"),
        .constraint = null,
        .git = null,
        .path = try allocator.dupe(u8, "libb"),
    };
    try config.dependencies.append(allocator, dep_b);

    const resolved = try resolver.resolveAll(&config);
    defer {
        for (resolved) |*r| {
            @constCast(r).deinit(allocator);
        }
        allocator.free(resolved);
    }

    // Should have 3 resolved: liba, libb, shared (shared resolved once for both)
    try std.testing.expectEqual(@as(usize, 3), resolved.len);

    // Verify shared is resolved exactly once
    var shared_count: usize = 0;
    for (resolved) |r| {
        if (std.mem.eql(u8, r.name, "shared")) shared_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shared_count);
}

test "version conflict produces error" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create "shared" v2.0.0 (only version available)
    tmp.dir.makeDir("shared") catch {};
    const shared_toml = tmp.dir.createFile("shared/kira.toml", .{}) catch unreachable;
    shared_toml.writeAll("[package]\nname = \"shared\"\nversion = \"2.0.0\"\n") catch unreachable;
    shared_toml.close();

    // Create "liba" which depends on "shared" ^2.0.0
    tmp.dir.makeDir("liba") catch {};
    const liba_toml = tmp.dir.createFile("liba/kira.toml", .{}) catch unreachable;
    liba_toml.writeAll("[package]\nname = \"liba\"\nversion = \"1.0.0\"\n\n[dependencies]\nshared = \"^2.0.0\"\n") catch unreachable;
    liba_toml.close();

    // Create "libb" which depends on "shared" ^1.0.0 (conflict with v2.0.0!)
    tmp.dir.makeDir("libb") catch {};
    const libb_toml = tmp.dir.createFile("libb/kira.toml", .{}) catch unreachable;
    libb_toml.writeAll("[package]\nname = \"libb\"\nversion = \"1.0.0\"\n\n[dependencies]\nshared = \"^1.0.0\"\n") catch unreachable;
    libb_toml.close();

    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_path);

    var resolver = DependencyResolver.init(allocator, tmp_path, tmp_path) catch unreachable;
    defer resolver.deinit();

    var config = project.ProjectConfig.init();
    defer config.deinit(allocator);

    const dep_a = toml.Dependency{
        .name = try allocator.dupe(u8, "liba"),
        .constraint = null,
        .git = null,
        .path = try allocator.dupe(u8, "liba"),
    };
    try config.dependencies.append(allocator, dep_a);

    const dep_b = toml.Dependency{
        .name = try allocator.dupe(u8, "libb"),
        .constraint = null,
        .git = null,
        .path = try allocator.dupe(u8, "libb"),
    };
    try config.dependencies.append(allocator, dep_b);

    const result = resolver.resolveAll(&config);
    try std.testing.expectError(error.VersionConflict, result);
}

test "cached dependency skips download" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pre-populate cache with "json" package
    tmp.dir.makeDir("cache") catch {};
    tmp.dir.makeDir("cache/json") catch {};
    const json_toml = tmp.dir.createFile("cache/json/kira.toml", .{}) catch unreachable;
    json_toml.writeAll("[package]\nname = \"json\"\nversion = \"1.5.0\"\n") catch unreachable;
    json_toml.close();

    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_path);

    const cache_path = std.fs.path.join(allocator, &.{ tmp_path, "cache" }) catch unreachable;
    defer allocator.free(cache_path);

    var resolver = DependencyResolver.init(allocator, tmp_path, cache_path) catch unreachable;
    defer resolver.deinit();

    var config = project.ProjectConfig.init();
    defer config.deinit(allocator);

    // Depend on json ^1.0.0 — should find 1.5.0 in cache
    const dep = toml.Dependency{
        .name = try allocator.dupe(u8, "json"),
        .constraint = .{ .op = .caret, .version = try allocator.dupe(u8, "1.0.0") },
        .git = null,
        .path = null,
    };
    try config.dependencies.append(allocator, dep);

    const resolved = try resolver.resolveAll(&config);
    defer {
        for (resolved) |*r| {
            @constCast(r).deinit(allocator);
        }
        allocator.free(resolved);
    }

    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("json", resolved[0].name);
    try std.testing.expectEqual(DepSource.cache, resolved[0].source);
    try std.testing.expectEqual(@as(u32, 1), resolved[0].version.?.major);
    try std.testing.expectEqual(@as(u32, 5), resolved[0].version.?.minor);
}

test "dependency not found" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_path);

    var resolver = DependencyResolver.init(allocator, tmp_path, tmp_path) catch unreachable;
    defer resolver.deinit();

    var config = project.ProjectConfig.init();
    defer config.deinit(allocator);

    const dep = toml.Dependency{
        .name = try allocator.dupe(u8, "nonexistent"),
        .constraint = null,
        .git = null,
        .path = try allocator.dupe(u8, "nonexistent"),
    };
    try config.dependencies.append(allocator, dep);

    try std.testing.expectError(error.DependencyNotFound, resolver.resolveAll(&config));
}

test "no source specified" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    defer allocator.free(tmp_path);

    var resolver = DependencyResolver.init(allocator, tmp_path, tmp_path) catch unreachable;
    defer resolver.deinit();

    var config = project.ProjectConfig.init();
    defer config.deinit(allocator);

    // Dep with no path, no git, no constraint
    const dep = toml.Dependency{
        .name = try allocator.dupe(u8, "orphan"),
        .constraint = null,
        .git = null,
        .path = null,
    };
    try config.dependencies.append(allocator, dep);

    try std.testing.expectError(error.NoSourceSpecified, resolver.resolveAll(&config));
}
