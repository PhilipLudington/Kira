//! Program AST node for the Kira language.
//!
//! A Program represents a complete Kira source file.

const std = @import("std");
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;
pub const Declaration = @import("declaration.zig").Declaration;

/// Represents a complete Kira program (source file).
pub const Program = struct {
    /// Module declaration (optional, at top of file)
    module_decl: ?Declaration.ModuleDecl,

    /// Import declarations
    imports: []Declaration.ImportDecl,

    /// Top-level declarations
    declarations: []Declaration,

    /// Module-level documentation comment
    module_doc: ?[]const u8,

    /// Source file path (for error reporting)
    source_path: ?[]const u8,

    /// Create an empty program
    pub fn empty() Program {
        return .{
            .module_decl = null,
            .imports = &[_]Declaration.ImportDecl{},
            .declarations = &[_]Declaration{},
            .module_doc = null,
            .source_path = null,
        };
    }

    /// Free memory allocated for this program's top-level structures.
    /// Note: This frees the slices allocated during parsing (imports, declarations).
    /// A full recursive cleanup of all AST nodes would be more complex.
    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        // Free imports slice if it was heap-allocated (not empty literal)
        if (self.imports.len > 0) {
            allocator.free(self.imports);
        }
        // Free declarations slice if it was heap-allocated (not empty literal)
        if (self.declarations.len > 0) {
            allocator.free(self.declarations);
        }
        self.* = undefined;
    }

    /// Get the module path if declared
    pub fn modulePath(self: Program) ?[][]const u8 {
        if (self.module_decl) |mod| {
            return mod.path;
        }
        return null;
    }

    /// Get all public declarations
    pub fn publicDeclarations(self: Program, allocator: std.mem.Allocator) ![]Declaration {
        var result = std.ArrayListUnmanaged(Declaration){};
        errdefer result.deinit(allocator);

        for (self.declarations) |decl| {
            if (decl.isPublic()) {
                try result.append(allocator, decl);
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Find a declaration by name
    pub fn findDeclaration(self: Program, name: []const u8) ?*const Declaration {
        for (self.declarations) |*decl| {
            if (decl.name()) |decl_name| {
                if (std.mem.eql(u8, decl_name, name)) {
                    return decl;
                }
            }
        }
        return null;
    }

    /// Check if this program has a main function
    pub fn hasMain(self: Program) bool {
        return self.findDeclaration("main") != null;
    }
};

test "empty program" {
    const prog = Program.empty();
    try std.testing.expect(prog.module_decl == null);
    try std.testing.expectEqual(@as(usize, 0), prog.imports.len);
    try std.testing.expectEqual(@as(usize, 0), prog.declarations.len);
    try std.testing.expect(!prog.hasMain());
}
