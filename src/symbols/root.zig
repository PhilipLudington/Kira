//! Symbol table and scope management for the Kira language.
//!
//! This module provides:
//! - Symbol definitions (variables, functions, types, traits, modules)
//! - Nested scope management with proper shadowing
//! - Module namespace tracking
//! - Trait implementation registry
//! - Visibility checking (pub vs private)
//! - AST resolution (populating symbol table from parsed AST)

const std = @import("std");

pub const symbol = @import("symbol.zig");
pub const scope = @import("scope.zig");
pub const table = @import("table.zig");
pub const resolver = @import("resolver.zig");

// Re-export main types
pub const Symbol = symbol.Symbol;
pub const SymbolId = symbol.SymbolId;
pub const ScopeId = symbol.ScopeId;
pub const Scope = scope.Scope;
pub const ScopeKind = scope.ScopeKind;
pub const SymbolTable = table.SymbolTable;
pub const SymbolError = table.SymbolError;
pub const Resolver = resolver.Resolver;
pub const ResolveError = resolver.ResolveError;
pub const Diagnostic = resolver.Diagnostic;

test {
    _ = @import("symbol.zig");
    _ = @import("scope.zig");
    _ = @import("table.zig");
    _ = @import("resolver.zig");
}
