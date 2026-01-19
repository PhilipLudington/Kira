//! Kira Programming Language
//!
//! A functional programming language with explicit types, explicit effects, and no surprises.
const std = @import("std");

pub const lexer = @import("lexer/root.zig");

pub const Token = lexer.Token;
pub const TokenType = lexer.TokenType;
pub const Lexer = lexer.Lexer;
pub const Location = lexer.Location;
pub const Span = lexer.Span;

/// Tokenize Kira source code
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Token) {
    var lex = Lexer.init(source);
    return lex.scanAllTokens(allocator);
}

test {
    _ = lexer;
}

test "tokenize simple expression" {
    var tokens = try tokenize(std.testing.allocator, "let x: i32 = 42");
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), tokens.items.len);
    try std.testing.expectEqual(TokenType.let, tokens.items[0].type);
}
