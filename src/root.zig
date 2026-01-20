//! Kira Programming Language
//!
//! A functional programming language with explicit types, explicit effects, and no surprises.
const std = @import("std");

pub const lexer = @import("lexer/root.zig");
pub const ast = @import("ast/root.zig");
pub const parser_mod = @import("parser/root.zig");
pub const symbols = @import("symbols/root.zig");
pub const typechecker = @import("typechecker/root.zig");
pub const interpreter_mod = @import("interpreter/root.zig");
pub const modules = @import("modules/root.zig");

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

// Module system exports
pub const ModuleLoader = modules.ModuleLoader;
pub const LoadError = modules.LoadError;

// Type checker exports
pub const ResolvedType = typechecker.ResolvedType;
pub const TypeChecker = typechecker.TypeChecker;
pub const TypeCheckError = typechecker.TypeCheckError;
pub const TypeCheckDiagnostic = typechecker.Diagnostic;

// Interpreter exports
pub const Value = interpreter_mod.Value;
pub const Environment = interpreter_mod.Environment;
pub const Interpreter = interpreter_mod.Interpreter;
pub const InterpreterError = interpreter_mod.InterpreterError;

/// Tokenize Kira source code
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Token) {
    var lex = Lexer.init(source);
    return lex.scanAllTokens(allocator);
}

/// Parse Kira source code into an AST.
/// The returned Program owns an arena allocator that holds all AST nodes.
/// Call program.deinit() when done to free all memory.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Program {
    // Create arena for AST allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // Tokenize using the backing allocator (tokens are freed after parsing)
    var tokens = try tokenize(allocator, source);
    defer tokens.deinit(allocator);

    // Parse using the arena allocator for AST nodes
    var p = Parser.init(arena.allocator(), tokens.items);
    defer p.deinit();

    var program = try p.parseProgram();
    program.arena = arena;
    return program;
}

/// Resolve a parsed program, populating the symbol table
pub fn resolve(allocator: std.mem.Allocator, program: *const Program, table: *SymbolTable) ResolveError!void {
    var resolver = Resolver.init(allocator, table);
    defer resolver.deinit();

    return resolver.resolve(program);
}

/// Resolve a parsed program with a module loader for cross-file imports
pub fn resolveWithLoader(
    allocator: std.mem.Allocator,
    program: *const Program,
    table: *SymbolTable,
    loader: *ModuleLoader,
) ResolveError!void {
    var resolver = Resolver.initWithLoader(allocator, table, loader);
    defer resolver.deinit();

    return resolver.resolve(program);
}

/// Type check a resolved program
pub fn typecheck(allocator: std.mem.Allocator, program: *const Program, table: *SymbolTable) TypeCheckError!void {
    var checker = TypeChecker.init(allocator, table);
    defer checker.deinit();

    return checker.check(program);
}

/// Interpret a type-checked program
pub fn interpret(allocator: std.mem.Allocator, program: *const Program, table: *SymbolTable) InterpreterError!?Value {
    var interp = Interpreter.init(allocator, table);
    defer interp.deinit();

    // Use arena allocator for stdlib/builtins (freed with interpreter)
    const arena_alloc = interp.arenaAlloc();

    // Register built-in functions
    try interpreter_mod.registerBuiltins(arena_alloc, &interp.global_env);

    // Register standard library
    try interpreter_mod.registerStdlib(arena_alloc, &interp.global_env);

    return interp.interpret(program);
}

test {
    _ = lexer;
    _ = ast;
    _ = parser_mod;
    _ = symbols;
    _ = typechecker;
    _ = interpreter_mod;
    _ = modules;
}

test "tokenize simple expression" {
    var tokens = try tokenize(std.testing.allocator, "let x: i32 = 42");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), tokens.items.len);
    try std.testing.expectEqual(TokenType.let, tokens.items[0].type);
}
