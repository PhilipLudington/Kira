//! Kira Programming Language
//!
//! A functional programming language with explicit types, explicit effects, and no surprises.
const std = @import("std");

pub const lexer = @import("lexer/root.zig");
pub const ast = @import("ast/root.zig");
pub const parser_mod = @import("parser/root.zig");
pub const symbols = @import("symbols/root.zig");
pub const typechecker = @import("typechecker/root.zig");

// Lexer exports
pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;
pub const Lexer = lexer.Lexer;
pub const Location = lexer.Location;
pub const Span = lexer.Span;

// AST exports
pub const Expression = ast.Expression;
pub const Statement = ast.Statement;
pub const Type = ast.Type;
pub const Declaration = ast.Declaration;
pub const Pattern = ast.Pattern;
pub const Program = ast.Program;
pub const PrettyPrinter = ast.PrettyPrinter;

// Parser exports
pub const Parser = parser_mod.Parser;
pub const ParseError = parser_mod.ParseError;

// Symbol table exports
pub const Symbol = symbols.Symbol;
pub const SymbolId = symbols.SymbolId;
pub const ScopeId = symbols.ScopeId;
pub const Scope = symbols.Scope;
pub const ScopeKind = symbols.ScopeKind;
pub const SymbolTable = symbols.SymbolTable;
pub const Resolver = symbols.Resolver;
pub const ResolveError = symbols.ResolveError;

// Type checker exports
pub const ResolvedType = typechecker.ResolvedType;
pub const TypeChecker = typechecker.TypeChecker;
pub const TypeCheckError = typechecker.TypeCheckError;
pub const TypeCheckDiagnostic = typechecker.Diagnostic;

/// Tokenize Kira source code
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Token) {
    var lex = Lexer.init(source);
    return lex.scanAllTokens(allocator);
}

/// Parse Kira source code into an AST
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Program {
    var tokens = try tokenize(allocator, source);
    defer tokens.deinit(allocator);

    var p = Parser.init(allocator, tokens.items);
    defer p.deinit();

    return p.parseProgram();
}

/// Resolve a parsed program, populating the symbol table
pub fn resolve(allocator: std.mem.Allocator, program: *const Program, table: *SymbolTable) ResolveError!void {
    var resolver = Resolver.init(allocator, table);
    defer resolver.deinit();

    return resolver.resolve(program);
}

/// Type check a resolved program
pub fn typecheck(allocator: std.mem.Allocator, program: *const Program, table: *SymbolTable) TypeCheckError!void {
    var checker = TypeChecker.init(allocator, table);
    defer checker.deinit();

    return checker.check(program);
}

test {
    _ = lexer;
    _ = ast;
    _ = parser_mod;
    _ = symbols;
    _ = typechecker;
}

test "tokenize simple expression" {
    var tokens = try tokenize(std.testing.allocator, "let x: i32 = 42");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), tokens.items.len);
    try std.testing.expectEqual(TokenType.let, tokens.items[0].type);
}
