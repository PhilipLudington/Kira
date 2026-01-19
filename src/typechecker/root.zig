//! Type Checker for the Kira language.
//!
//! The type checker verifies that all type annotations are consistent,
//! checks type compatibility in expressions and statements, and produces
//! clear error messages. It operates on a resolved AST with populated
//! symbol table.

pub const types = @import("types.zig");
pub const errors = @import("errors.zig");
pub const checker = @import("checker.zig");
pub const unify = @import("unify.zig");
pub const instantiate = @import("instantiate.zig");

// Re-export main types
pub const ResolvedType = types.ResolvedType;
pub const TypeChecker = checker.TypeChecker;
pub const TypeCheckError = checker.TypeCheckError;
pub const Diagnostic = errors.Diagnostic;
pub const DiagnosticKind = errors.DiagnosticKind;

test {
    _ = types;
    _ = errors;
    _ = checker;
    _ = unify;
    _ = instantiate;
}
