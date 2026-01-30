//! Module Loader for the Kira language.
//!
//! The module loader handles cross-file module loading, allowing code to
//! import modules from separate .ki files. It handles:
//! - Module path to file path conversion (geometry.shapes → geometry/shapes.ki)
//! - Search path management
//! - Circular dependency detection
//! - Module caching to avoid re-parsing

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const parser_mod = @import("../parser/root.zig");
const lexer_mod = @import("../lexer/root.zig");
const table_mod = @import("../symbols/table.zig");
const symbol_mod = @import("../symbols/symbol.zig");
const scope_mod = @import("../symbols/scope.zig");
const config_mod = @import("../config/root.zig");

pub const Program = ast.Program;
pub const SymbolTable = table_mod.SymbolTable;
pub const ScopeId = symbol_mod.ScopeId;
pub const Parser = parser_mod.Parser;
pub const Lexer = lexer_mod.Lexer;
pub const Span = ast.Span;

/// Errors that can occur during module loading
pub const LoadError = error{
    ModuleNotFound,
    CircularDependency,
    ParseError,
    ResolveError,
    FileReadError,
    OutOfMemory,
    InvalidPath,
    TotalBytesExceeded,
    MaxImportDepthExceeded,
};

/// Information about a loaded module
pub const LoadedModule = struct {
    /// The scope ID where the module's symbols live
    scope_id: ScopeId,
    /// The file path this module was loaded from
    file_path: []const u8,
    /// The parsed program (kept for interpreter)
    program: ?*Program,
    /// The source code (kept for error reporting)
    source: ?[]const u8,
};

/// Default maximum total bytes that can be loaded across all modules
pub const default_max_total_bytes: usize = 100 * 1024 * 1024; // 100MB

/// Default maximum import depth (to prevent infinite recursion via imports)
pub const default_max_import_depth: usize = 64;

/// The module loader handles cross-file module loading
pub const ModuleLoader = struct {
    allocator: Allocator,
    /// The symbol table to populate
    table: *SymbolTable,
    /// Directories to search for module files
    search_paths: std.ArrayListUnmanaged([]const u8),
    /// Modules currently being loaded (for cycle detection)
    loading_modules: std.StringHashMapUnmanaged(void),
    /// Already loaded modules (cache)
    loaded_modules: std.StringHashMapUnmanaged(LoadedModule),
    /// Errors encountered during loading
    errors: std.ArrayListUnmanaged(LoadErrorInfo),
    /// Optional project configuration for module path resolution
    config: ?*const config_mod.ProjectConfig,
    /// Total bytes loaded so far (for resource exhaustion protection)
    total_bytes_loaded: usize,
    /// Maximum total bytes allowed (configurable)
    max_total_bytes: usize,
    /// Current import depth (for deeply nested import protection)
    current_import_depth: usize,
    /// Maximum import depth allowed (configurable)
    max_import_depth: usize,

    /// Information about a load error
    pub const LoadErrorInfo = struct {
        module_path: []const u8,
        message: []const u8,
        file_path: ?[]const u8,
        span: ?Span,
        /// Paths that were searched when looking for this module (for error messages).
        searched_paths: ?[]const []const u8,
    };

    /// Create a new module loader
    pub fn init(allocator: Allocator, table: *SymbolTable) ModuleLoader {
        return .{
            .allocator = allocator,
            .table = table,
            .search_paths = .{},
            .loading_modules = .{},
            .loaded_modules = .{},
            .errors = .{},
            .config = null,
            .total_bytes_loaded = 0,
            .max_total_bytes = default_max_total_bytes,
            .current_import_depth = 0,
            .max_import_depth = default_max_import_depth,
        };
    }

    /// Create a new module loader with project configuration
    pub fn initWithConfig(allocator: Allocator, table: *SymbolTable, cfg: ?*const config_mod.ProjectConfig) ModuleLoader {
        return .{
            .allocator = allocator,
            .table = table,
            .search_paths = .{},
            .loading_modules = .{},
            .loaded_modules = .{},
            .errors = .{},
            .config = cfg,
            .total_bytes_loaded = 0,
            .max_total_bytes = default_max_total_bytes,
            .current_import_depth = 0,
            .max_import_depth = default_max_import_depth,
        };
    }

    /// Free all resources
    pub fn deinit(self: *ModuleLoader) void {
        // Free search paths
        for (self.search_paths.items) |path| {
            self.allocator.free(path);
        }
        self.search_paths.deinit(self.allocator);

        // Free loading modules keys
        var loading_iter = self.loading_modules.keyIterator();
        while (loading_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.loading_modules.deinit(self.allocator);

        // Free loaded modules
        var loaded_iter = self.loaded_modules.iterator();
        while (loaded_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.file_path);
            if (entry.value_ptr.program) |prog| {
                prog.deinit();
                self.allocator.destroy(prog);
            }
            if (entry.value_ptr.source) |src| {
                self.allocator.free(src);
            }
        }
        self.loaded_modules.deinit(self.allocator);

        // Free errors
        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.module_path);
            self.allocator.free(err_info.message);
            if (err_info.file_path) |fp| {
                self.allocator.free(fp);
            }
            if (err_info.searched_paths) |paths| {
                for (paths) |p| {
                    self.allocator.free(p);
                }
                self.allocator.free(paths);
            }
        }
        self.errors.deinit(self.allocator);
    }

    /// Add a directory to the search path
    pub fn addSearchPath(self: *ModuleLoader, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        try self.search_paths.append(self.allocator, path_copy);
    }

    /// Load a module by its module path (e.g., "geometry.shapes")
    /// Returns the scope ID of the loaded module, or null if not found
    pub fn loadModule(self: *ModuleLoader, module_path: []const u8) LoadError!?ScopeId {
        // Check import depth limit to prevent deeply nested imports
        if (self.current_import_depth >= self.max_import_depth) {
            try self.addLoadError(module_path, "Maximum import depth exceeded", null, null, null);
            return error.MaxImportDepthExceeded;
        }

        // Validate module path to prevent path traversal
        if (!validateModulePath(module_path)) {
            try self.addLoadError(module_path, "Invalid module path (contains path traversal or invalid characters)", null, null, null);
            return error.InvalidPath;
        }

        // Check if already loaded
        if (self.loaded_modules.get(module_path)) |loaded| {
            return loaded.scope_id;
        }

        // Check if we're already loading this module (cycle detection)
        if (self.loading_modules.contains(module_path)) {
            try self.addLoadError(module_path, "Circular dependency detected", null, null, null);
            return error.CircularDependency;
        }

        // Increment depth for this load operation
        self.current_import_depth += 1;
        defer self.current_import_depth -= 1;

        // Extract the root module name (first segment before any '.')
        const root_module_name = blk: {
            if (std.mem.indexOfScalar(u8, module_path, '.')) |dot_pos| {
                break :blk module_path[0..dot_pos];
            }
            break :blk module_path;
        };

        // Track searched paths for error reporting
        var searched = std.ArrayListUnmanaged([]const u8){};
        defer {
            for (searched.items) |p| {
                self.allocator.free(p);
            }
            searched.deinit(self.allocator);
        }

        var file_path: ?[]u8 = null;

        // First, check project config for module path mapping
        if (self.config) |cfg| {
            // Try to load the root module as a package first (check for nested kira.toml)
            if (cfg.getFullModulePath(self.allocator, root_module_name)) |root_path| {
                // Check if it's a directory with its own kira.toml (a package)
                const is_package = blk: {
                    var dir = std.fs.cwd().openDir(root_path, .{}) catch {
                        self.allocator.free(root_path);
                        break :blk false;
                    };
                    defer dir.close();
                    // Try to load package config
                    const pkg_name = @constCast(cfg).loadPackage(self.allocator, root_path) catch {
                        self.allocator.free(root_path);
                        break :blk false;
                    };
                    break :blk pkg_name != null;
                };

                if (is_package) {
                    self.allocator.free(root_path);
                    // Now use getFullModulePath again - it will use the loaded package config
                    if (cfg.getFullModulePath(self.allocator, module_path)) |pkg_module_path| {
                        const pkg_searched_copy = self.allocator.dupe(u8, pkg_module_path) catch null;
                        if (pkg_searched_copy) |psc| {
                            searched.append(self.allocator, psc) catch {};
                        }

                        if (std.fs.cwd().openFile(pkg_module_path, .{})) |f| {
                            f.close();
                            file_path = pkg_module_path;
                        } else |_| {
                            self.allocator.free(pkg_module_path);
                        }
                    }
                }
                // If not a package, root_path was already freed in the blk
            }

            // If not found via package, try direct module mapping
            if (file_path == null) {
                if (cfg.getFullModulePath(self.allocator, root_module_name)) |config_path| {
                    // Add to searched paths list
                    const searched_copy = self.allocator.dupe(u8, config_path) catch null;
                    if (searched_copy) |sc| {
                        searched.append(self.allocator, sc) catch {};
                    }

                    // Try to open the configured path (could be file or directory)
                    if (std.fs.cwd().openFile(config_path, .{})) |f| {
                        f.close();
                        file_path = config_path;
                    } else |_| {
                        // Try as directory with mod.ki
                        const mod_path = std.fs.path.join(self.allocator, &.{ config_path, "mod.ki" }) catch null;
                        self.allocator.free(config_path);

                        if (mod_path) |mp| {
                            const mod_searched_copy = self.allocator.dupe(u8, mp) catch null;
                            if (mod_searched_copy) |msc| {
                                searched.append(self.allocator, msc) catch {};
                            }

                            if (std.fs.cwd().openFile(mp, .{})) |f| {
                                f.close();
                                file_path = mp;
                            } else |_| {
                                self.allocator.free(mp);
                            }
                        }
                    }
                }
            }
        }

        // Fall back to search path resolution if config didn't find it
        if (file_path == null) {
            // Convert module path to file path
            const relative_path = try self.modulePathToFilePath(module_path);
            defer self.allocator.free(relative_path);

            // Search for the file in search paths, collecting searched paths
            file_path = self.findModuleFileWithTracking(relative_path, &searched);
        }

        // If still not found, report error with searched paths
        if (file_path == null) {
            // Convert searched paths to owned slice for error info
            var searched_owned: ?[]const []const u8 = null;
            if (searched.items.len > 0) {
                const paths_copy = self.allocator.alloc([]const u8, searched.items.len) catch null;
                if (paths_copy) |pc| {
                    for (searched.items, 0..) |p, i| {
                        pc[i] = self.allocator.dupe(u8, p) catch "";
                    }
                    searched_owned = pc;
                }
            }
            try self.addLoadError(module_path, "Module file not found", null, null, searched_owned);
            return error.ModuleNotFound;
        }

        defer self.allocator.free(file_path.?);

        // Mark as loading (for cycle detection)
        const module_path_copy = try self.allocator.dupe(u8, module_path);
        try self.loading_modules.put(self.allocator, module_path_copy, {});

        // Load and resolve the file
        const result = self.loadAndResolveFile(file_path.?, module_path) catch |err| {
            // Remove from loading set on error
            if (self.loading_modules.fetchRemove(module_path_copy)) |_| {
                self.allocator.free(module_path_copy);
            }
            return err;
        };

        // Remove from loading set
        if (self.loading_modules.fetchRemove(module_path_copy)) |_| {
            self.allocator.free(module_path_copy);
        }

        // Cache the loaded module
        const cached_path = try self.allocator.dupe(u8, module_path);
        const cached_file = try self.allocator.dupe(u8, file_path.?);
        try self.loaded_modules.put(self.allocator, cached_path, .{
            .scope_id = result.scope_id,
            .file_path = cached_file,
            .program = result.program,
            .source = result.source,
        });

        return result.scope_id;
    }

    /// Validate a module path to prevent path traversal attacks.
    /// Module paths must not contain:
    /// - ".." segments (directory traversal)
    /// - "." segments (current directory, ambiguous)
    /// - Path separators (/ or \)
    /// - Empty segments (e.g., "foo..bar" or leading/trailing dots)
    fn validateModulePath(module_path: []const u8) bool {
        if (module_path.len == 0) return false;

        var iter = std.mem.splitScalar(u8, module_path, '.');
        while (iter.next()) |segment| {
            // Empty segment (e.g., from ".." or leading/trailing dots)
            if (segment.len == 0) return false;
            // Directory traversal
            if (std.mem.eql(u8, segment, "..")) return false;
            // Current directory (shouldn't appear as a segment)
            // Note: single "." would create empty segment anyway via split
            // Check for path separators in segment
            for (segment) |c| {
                if (c == '/' or c == '\\') return false;
            }
        }
        return true;
    }

    /// Convert a module path like "geometry.shapes" to a file path like "geometry/shapes.ki"
    pub fn modulePathToFilePath(self: *ModuleLoader, module_path: []const u8) ![]u8 {
        // Validate module path before conversion
        if (!validateModulePath(module_path)) {
            return error.InvalidPath;
        }

        var result = std.ArrayListUnmanaged(u8){};
        errdefer result.deinit(self.allocator);

        for (module_path) |c| {
            if (c == '.') {
                try result.append(self.allocator, std.fs.path.sep);
            } else {
                try result.append(self.allocator, c);
            }
        }

        try result.appendSlice(self.allocator, ".ki");

        return result.toOwnedSlice(self.allocator);
    }

    /// Find a module file by searching in all search paths
    pub fn findModuleFile(self: *ModuleLoader, relative_path: []const u8) ?[]u8 {
        // Try each search path
        for (self.search_paths.items) |search_path| {
            const full_path = std.fs.path.join(self.allocator, &.{ search_path, relative_path }) catch continue;
            defer self.allocator.free(full_path);

            // Check if file exists
            const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
            file.close();

            // File exists, return a copy of the path
            return self.allocator.dupe(u8, full_path) catch null;
        }

        // Also try the relative path directly (for current directory)
        {
            const file = std.fs.cwd().openFile(relative_path, .{}) catch return null;
            file.close();
            return self.allocator.dupe(u8, relative_path) catch null;
        }
    }

    /// Find a module file by searching in all search paths, tracking searched paths.
    /// The searched_paths list is populated with copies of all paths tried.
    fn findModuleFileWithTracking(
        self: *ModuleLoader,
        relative_path: []const u8,
        searched_paths: *std.ArrayListUnmanaged([]const u8),
    ) ?[]u8 {
        // Try each search path
        for (self.search_paths.items) |search_path| {
            const full_path = std.fs.path.join(self.allocator, &.{ search_path, relative_path }) catch continue;

            // Track this path
            const path_copy = self.allocator.dupe(u8, full_path) catch null;
            if (path_copy) |pc| {
                searched_paths.append(self.allocator, pc) catch {};
            }

            // Check if file exists
            if (std.fs.cwd().openFile(full_path, .{})) |file| {
                file.close();
                // File exists, return the path (already allocated)
                return full_path;
            } else |_| {
                self.allocator.free(full_path);

                // Also try mod.ki in a directory with the same name (minus .ki extension)
                if (std.mem.endsWith(u8, relative_path, ".ki")) {
                    const dir_name = relative_path[0 .. relative_path.len - 3];
                    const mod_path = std.fs.path.join(self.allocator, &.{ search_path, dir_name, "mod.ki" }) catch continue;

                    // Track this path too
                    const mod_path_copy = self.allocator.dupe(u8, mod_path) catch null;
                    if (mod_path_copy) |mpc| {
                        searched_paths.append(self.allocator, mpc) catch {};
                    }

                    if (std.fs.cwd().openFile(mod_path, .{})) |file| {
                        file.close();
                        return mod_path;
                    } else |_| {
                        self.allocator.free(mod_path);
                    }
                }
            }
        }

        // Also try the relative path directly (for current directory)
        {
            const rel_copy = self.allocator.dupe(u8, relative_path) catch null;
            if (rel_copy) |rc| {
                searched_paths.append(self.allocator, rc) catch {};
            }

            if (std.fs.cwd().openFile(relative_path, .{})) |file| {
                file.close();
                return self.allocator.dupe(u8, relative_path) catch null;
            } else |_| {}
        }

        return null;
    }

    /// Result of loading a file
    const LoadResult = struct {
        scope_id: ScopeId,
        program: *Program,
        source: []const u8,
    };

    /// Load and resolve a file, returning the module scope ID and program
    fn loadAndResolveFile(self: *ModuleLoader, file_path: []const u8, expected_module: []const u8) LoadError!LoadResult {
        // Read the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try self.addLoadError(expected_module, "Cannot open file", file_path, null, null);
            return error.FileReadError;
        };
        defer file.close();

        // Check file size before reading to enforce total bytes limit
        const stat = file.stat() catch {
            try self.addLoadError(expected_module, "Cannot stat file", file_path, null, null);
            return error.FileReadError;
        };
        const file_size = stat.size;

        // Check if this file would exceed total bytes limit
        if (self.total_bytes_loaded + file_size > self.max_total_bytes) {
            try self.addLoadError(expected_module, "Total bytes limit exceeded", file_path, null, null);
            return error.TotalBytesExceeded;
        }

        const source = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            try self.addLoadError(expected_module, "Cannot read file", file_path, null, null);
            return error.FileReadError;
        };
        errdefer self.allocator.free(source);

        // Track loaded bytes
        self.total_bytes_loaded += source.len;

        // Create arena for AST allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        // Tokenize
        var lex = Lexer.init(source);
        var tokens = lex.scanAllTokens(self.allocator) catch {
            try self.addLoadError(expected_module, "Lexer error", file_path, null, null);
            return error.ParseError;
        };
        defer tokens.deinit(self.allocator);

        // Parse using arena for AST nodes
        var parser = Parser.init(arena.allocator(), tokens.items);
        defer parser.deinit();

        var program = parser.parseProgram() catch {
            try self.addLoadError(expected_module, "Parse error", file_path, null, null);
            return error.ParseError;
        };
        program.arena = arena;
        errdefer program.deinit();

        // Find the module declaration and verify it matches expected path
        var found_module_scope: ?ScopeId = null;

        // Process module declaration if present (stored in separate field, not declarations array)
        if (program.module_decl) |_| {
            // Create module scope
            const module_scope_id = self.table.enterScope(.module) catch return error.OutOfMemory;

            // Register module with expected path (for import resolution)
            self.table.registerModule(expected_module, module_scope_id) catch {};

            found_module_scope = module_scope_id;

            // Leave module scope for now (we'll re-enter to add symbols)
            self.table.leaveScope() catch {};
        }

        // If we found a module scope, populate it with the file's declarations
        if (found_module_scope) |scope_id| {
            // Re-enter the module scope
            self.table.setCurrentScope(scope_id) catch return error.OutOfMemory;

            // Process all declarations
            for (program.declarations) |*decl| {
                switch (decl.kind) {
                    .function_decl => |f| {
                        self.addFunctionSymbol(&f, decl.span, decl.doc_comment) catch {};
                    },
                    .type_decl => |t| {
                        self.addTypeSymbol(&t, decl.span, decl.doc_comment) catch {};
                    },
                    .const_decl => |c| {
                        self.addConstSymbol(&c, decl.span, decl.doc_comment) catch {};
                    },
                    .let_decl => |l| {
                        self.addLetSymbol(&l, decl.span, decl.doc_comment) catch {};
                    },
                    else => {},
                }
            }

            // Process imports from this module (recursively load dependencies)
            for (program.imports) |import_decl| {
                // Build the full module path from import segments
                var path_builder = std.ArrayListUnmanaged(u8){};
                defer path_builder.deinit(self.allocator);
                for (import_decl.path, 0..) |segment, i| {
                    if (i > 0) path_builder.append(self.allocator, '.') catch continue;
                    path_builder.appendSlice(self.allocator, segment) catch continue;
                }
                const import_path = path_builder.toOwnedSlice(self.allocator) catch continue;
                defer self.allocator.free(import_path);

                // Recursively load the imported module
                _ = self.loadModule(import_path) catch continue;
            }

            // Return to global scope
            self.table.setCurrentScope(0) catch {};

            // Allocate program on heap to keep it alive
            const heap_program = self.allocator.create(Program) catch return error.OutOfMemory;
            heap_program.* = program;

            return LoadResult{
                .scope_id = scope_id,
                .program = heap_program,
                .source = source,
            };
        }

        // No module declaration found - this is an error for cross-file imports
        try self.addLoadError(expected_module, "No module declaration found in file", file_path, null, null);
        return error.ResolveError;
    }

    /// Add a function symbol to the current scope
    fn addFunctionSymbol(
        self: *ModuleLoader,
        func: *const ast.Declaration.FunctionDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) !void {
        // Convert generic params
        var generic_params: ?[]symbol_mod.Symbol.GenericParamInfo = null;
        if (func.generic_params) |params| {
            var gp = std.ArrayListUnmanaged(symbol_mod.Symbol.GenericParamInfo){};
            for (params) |p| {
                try gp.append(self.allocator, .{
                    .name = p.name,
                    .constraints = p.constraints,
                });
            }
            generic_params = try gp.toOwnedSlice(self.allocator);
        }

        // Collect parameter info
        var param_types = std.ArrayListUnmanaged(*ast.Type){};
        var param_names = std.ArrayListUnmanaged([]const u8){};
        for (func.parameters) |p| {
            try param_types.append(self.allocator, p.param_type);
            try param_names.append(self.allocator, p.name);
        }

        const func_symbol = symbol_mod.Symbol.FunctionSymbol{
            .generic_params = generic_params,
            .parameter_types = try param_types.toOwnedSlice(self.allocator),
            .parameter_names = try param_names.toOwnedSlice(self.allocator),
            .return_type = func.return_type,
            .is_effect = func.is_effect,
            .has_body = func.body != null,
        };

        var sym = symbol_mod.Symbol.function(0, func.name, func_symbol, func.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch {};
    }

    /// Add a type symbol to the current scope
    fn addTypeSymbol(
        self: *ModuleLoader,
        type_decl: *const ast.Declaration.TypeDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) !void {
        // Convert generic params
        var generic_params: ?[]symbol_mod.Symbol.GenericParamInfo = null;
        if (type_decl.generic_params) |params| {
            var gp = std.ArrayListUnmanaged(symbol_mod.Symbol.GenericParamInfo){};
            for (params) |p| {
                try gp.append(self.allocator, .{
                    .name = p.name,
                    .constraints = p.constraints,
                });
            }
            generic_params = try gp.toOwnedSlice(self.allocator);
        }

        // Convert type definition
        const def_kind: symbol_mod.Symbol.TypeDefKind = switch (type_decl.definition) {
            .sum_type => |s| blk: {
                var variants = std.ArrayListUnmanaged(symbol_mod.Symbol.VariantInfo){};
                for (s.variants) |v| {
                    const fields: ?symbol_mod.Symbol.VariantFields = if (v.fields) |vf| switch (vf) {
                        .tuple_fields => |tf| .{ .tuple_fields = tf },
                        .record_fields => |rf| inner: {
                            var record_fields = std.ArrayListUnmanaged(symbol_mod.Symbol.RecordFieldInfo){};
                            for (rf) |f| {
                                try record_fields.append(self.allocator, .{
                                    .name = f.name,
                                    .field_type = f.field_type,
                                    .span = f.span,
                                });
                            }
                            break :inner .{ .record_fields = try record_fields.toOwnedSlice(self.allocator) };
                        },
                    } else null;

                    try variants.append(self.allocator, .{
                        .name = v.name,
                        .fields = fields,
                        .span = v.span,
                    });
                }
                break :blk .{ .sum_type = .{ .variants = try variants.toOwnedSlice(self.allocator) } };
            },
            .product_type => |p| blk: {
                var fields = std.ArrayListUnmanaged(symbol_mod.Symbol.RecordFieldInfo){};
                for (p.fields) |f| {
                    try fields.append(self.allocator, .{
                        .name = f.name,
                        .field_type = f.field_type,
                        .span = f.span,
                    });
                }
                break :blk .{ .product_type = .{ .fields = try fields.toOwnedSlice(self.allocator) } };
            },
            .type_alias => |alias| .{ .alias = alias },
        };

        const type_def_symbol = symbol_mod.Symbol.TypeDefSymbol{
            .generic_params = generic_params,
            .definition = def_kind,
        };

        var sym = symbol_mod.Symbol.typeDef(0, type_decl.name, type_def_symbol, type_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch {};
    }

    /// Add a constant symbol to the current scope
    fn addConstSymbol(
        self: *ModuleLoader,
        const_decl: *const ast.Declaration.ConstDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) !void {
        var sym = symbol_mod.Symbol.variable(0, const_decl.name, const_decl.const_type, false, const_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch {};
    }

    /// Add a let binding symbol to the current scope
    fn addLetSymbol(
        self: *ModuleLoader,
        let_decl: *const ast.Declaration.LetDecl,
        span: Span,
        doc_comment: ?[]const u8,
    ) !void {
        var sym = symbol_mod.Symbol.variable(0, let_decl.name, let_decl.binding_type, false, let_decl.is_public, span);
        sym.doc_comment = doc_comment;

        _ = self.table.define(sym) catch {};
    }

    /// Add a load error to the error list
    fn addLoadError(
        self: *ModuleLoader,
        module_path: []const u8,
        message: []const u8,
        file_path: ?[]const u8,
        span: ?Span,
        searched_paths: ?[]const []const u8,
    ) !void {
        try self.errors.append(self.allocator, .{
            .module_path = try self.allocator.dupe(u8, module_path),
            .message = try self.allocator.dupe(u8, message),
            .file_path = if (file_path) |fp| try self.allocator.dupe(u8, fp) else null,
            .span = span,
            .searched_paths = searched_paths,
        });
    }

    /// Get all load errors
    pub fn getErrors(self: *ModuleLoader) []const LoadErrorInfo {
        return self.errors.items;
    }

    /// Check if there were any errors
    pub fn hasErrors(self: *ModuleLoader) bool {
        return self.errors.items.len > 0;
    }

    /// Get all loaded modules (for interpreter to process)
    pub fn getLoadedModules(self: *ModuleLoader) std.StringHashMapUnmanaged(LoadedModule) {
        return self.loaded_modules;
    }

    /// Iterator over loaded modules
    pub fn loadedModulesIterator(self: *ModuleLoader) std.StringHashMapUnmanaged(LoadedModule).Iterator {
        return self.loaded_modules.iterator();
    }
};

test "module path to file path" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var loader = ModuleLoader.init(allocator, &table);
    defer loader.deinit();

    const path = try loader.modulePathToFilePath("geometry.shapes");
    defer allocator.free(path);

    // Platform-specific path separator
    if (std.fs.path.sep == '/') {
        try std.testing.expectEqualStrings("geometry/shapes.ki", path);
    } else {
        try std.testing.expectEqualStrings("geometry\\shapes.ki", path);
    }
}

test "module loader initialization" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    var loader = ModuleLoader.init(allocator, &table);
    defer loader.deinit();

    try loader.addSearchPath("/test/path");
    try std.testing.expectEqual(@as(usize, 1), loader.search_paths.items.len);
}
