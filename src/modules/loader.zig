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

    /// Information about a load error
    pub const LoadErrorInfo = struct {
        module_path: []const u8,
        message: []const u8,
        file_path: ?[]const u8,
        span: ?Span,
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
        // Check if already loaded
        if (self.loaded_modules.get(module_path)) |loaded| {
            return loaded.scope_id;
        }

        // Check if we're already loading this module (cycle detection)
        if (self.loading_modules.contains(module_path)) {
            try self.addLoadError(module_path, "Circular dependency detected", null, null);
            return error.CircularDependency;
        }

        // Convert module path to file path
        const relative_path = try self.modulePathToFilePath(module_path);
        defer self.allocator.free(relative_path);

        // Search for the file in search paths
        const file_path = self.findModuleFile(relative_path) orelse {
            try self.addLoadError(module_path, "Module file not found", null, null);
            return error.ModuleNotFound;
        };
        defer self.allocator.free(file_path);

        // Mark as loading (for cycle detection)
        const module_path_copy = try self.allocator.dupe(u8, module_path);
        try self.loading_modules.put(self.allocator, module_path_copy, {});

        // Load and resolve the file
        const result = self.loadAndResolveFile(file_path, module_path) catch |err| {
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
        const cached_file = try self.allocator.dupe(u8, file_path);
        try self.loaded_modules.put(self.allocator, cached_path, .{
            .scope_id = result.scope_id,
            .file_path = cached_file,
            .program = result.program,
            .source = result.source,
        });

        return result.scope_id;
    }

    /// Convert a module path like "geometry.shapes" to a file path like "geometry/shapes.ki"
    pub fn modulePathToFilePath(self: *ModuleLoader, module_path: []const u8) ![]u8 {
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
            try self.addLoadError(expected_module, "Cannot open file", file_path, null);
            return error.FileReadError;
        };
        defer file.close();

        const source = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch {
            try self.addLoadError(expected_module, "Cannot read file", file_path, null);
            return error.FileReadError;
        };
        errdefer self.allocator.free(source);

        // Create arena for AST allocations
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        // Tokenize
        var lex = Lexer.init(source);
        var tokens = lex.scanAllTokens(self.allocator) catch {
            try self.addLoadError(expected_module, "Lexer error", file_path, null);
            return error.ParseError;
        };
        defer tokens.deinit(self.allocator);

        // Parse using arena for AST nodes
        var parser = Parser.init(arena.allocator(), tokens.items);
        defer parser.deinit();

        var program = parser.parseProgram() catch {
            try self.addLoadError(expected_module, "Parse error", file_path, null);
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
        try self.addLoadError(expected_module, "No module declaration found in file", file_path, null);
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
    ) !void {
        try self.errors.append(self.allocator, .{
            .module_path = try self.allocator.dupe(u8, module_path),
            .message = try self.allocator.dupe(u8, message),
            .file_path = if (file_path) |fp| try self.allocator.dupe(u8, fp) else null,
            .span = span,
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
