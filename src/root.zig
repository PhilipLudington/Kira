//! Kira Programming Language
//!
//! A functional programming language with explicit types, explicit effects, and no surprises.
const std = @import("std");

pub const lexer = @import("lexer/root.zig");
pub const ast = @import("ast/root.zig");
pub const parser_mod = @import("parser/root.zig");

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

test {
    _ = lexer;
    _ = ast;
    _ = parser_mod;
}

test "tokenize simple expression" {
    var tokens = try tokenize(std.testing.allocator, "let x: i32 = 42");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), tokens.items.len);
    try std.testing.expectEqual(TokenType.let, tokens.items[0].type);
}
