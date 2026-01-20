const std = @import("std");
const token = @import("token.zig");
const Token = token.Token;
const TokenType = token.TokenType;
const Location = token.Location;
const Span = token.Span;

/// Lexer for the Kira programming language
pub const Lexer = struct {
    source: []const u8,
    current: usize,
    location: Location,

    /// Whether the last non-whitespace token allows a newline to be significant
    /// (i.e., can be followed by a statement terminator)
    allow_newline_terminator: bool,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .current = 0,
            .location = Location.start,
            .allow_newline_terminator = false,
        };
    }

    /// Scan all tokens from the source
    pub fn scanAllTokens(self: *Lexer, allocator: std.mem.Allocator) !std.ArrayList(Token) {
        var tokens: std.ArrayList(Token) = .empty;
        errdefer tokens.deinit(allocator);

        while (true) {
            const tok = self.nextToken();
            try tokens.append(allocator, tok);
            if (tok.type == .eof) break;
        }

        return tokens;
    }

    /// Get the next token from the source
    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespaceAndComments();

        if (self.isAtEnd()) {
            return self.makeToken(.eof, "");
        }

        const start_location = self.location;
        const c = self.advance();

        // Single character tokens
        const single_char_token: ?TokenType = switch (c) {
            '(' => .left_paren,
            ')' => .right_paren,
            '{' => .left_brace,
            '}' => .right_brace,
            '[' => .left_bracket,
            ']' => .right_bracket,
            ',' => .comma,
            ';' => .semicolon,
            '+' => .plus,
            '*' => .star,
            '%' => .percent,
            else => null,
        };

        if (single_char_token) |tok_type| {
            self.updateNewlineState(tok_type);
            return self.makeTokenAt(tok_type, self.source[start_location.offset..self.current], start_location);
        }

        // Multi-character tokens
        switch (c) {
            '-' => {
                if (self.match('>')) {
                    self.updateNewlineState(.arrow);
                    return self.makeTokenAt(.arrow, "->", start_location);
                }
                self.updateNewlineState(.minus);
                return self.makeTokenAt(.minus, "-", start_location);
            },
            '.' => {
                if (self.match('.')) {
                    if (self.match('=')) {
                        self.updateNewlineState(.dot_dot_equal);
                        return self.makeTokenAt(.dot_dot_equal, "..=", start_location);
                    }
                    self.updateNewlineState(.dot_dot);
                    return self.makeTokenAt(.dot_dot, "..", start_location);
                }
                self.updateNewlineState(.dot);
                return self.makeTokenAt(.dot, ".", start_location);
            },
            ':' => {
                if (self.match(':')) {
                    self.updateNewlineState(.colon_colon);
                    return self.makeTokenAt(.colon_colon, "::", start_location);
                }
                self.updateNewlineState(.colon);
                return self.makeTokenAt(.colon, ":", start_location);
            },
            '=' => {
                if (self.match('=')) {
                    self.updateNewlineState(.equal_equal);
                    return self.makeTokenAt(.equal_equal, "==", start_location);
                }
                if (self.match('>')) {
                    self.updateNewlineState(.fat_arrow);
                    return self.makeTokenAt(.fat_arrow, "=>", start_location);
                }
                self.updateNewlineState(.equal);
                return self.makeTokenAt(.equal, "=", start_location);
            },
            '!' => {
                if (self.match('=')) {
                    self.updateNewlineState(.bang_equal);
                    return self.makeTokenAt(.bang_equal, "!=", start_location);
                }
                self.updateNewlineState(.bang);
                return self.makeTokenAt(.bang, "!", start_location);
            },
            '<' => {
                if (self.match('=')) {
                    self.updateNewlineState(.less_equal);
                    return self.makeTokenAt(.less_equal, "<=", start_location);
                }
                self.updateNewlineState(.less);
                return self.makeTokenAt(.less, "<", start_location);
            },
            '>' => {
                if (self.match('=')) {
                    self.updateNewlineState(.greater_equal);
                    return self.makeTokenAt(.greater_equal, ">=", start_location);
                }
                self.updateNewlineState(.greater);
                return self.makeTokenAt(.greater, ">", start_location);
            },
            '?' => {
                if (self.match('?')) {
                    self.updateNewlineState(.question_question);
                    return self.makeTokenAt(.question_question, "??", start_location);
                }
                self.updateNewlineState(.question);
                return self.makeTokenAt(.question, "?", start_location);
            },
            '|' => {
                self.updateNewlineState(.pipe);
                return self.makeTokenAt(.pipe, "|", start_location);
            },
            '/' => {
                // Comments are handled in skipWhitespaceAndComments
                self.updateNewlineState(.slash);
                return self.makeTokenAt(.slash, "/", start_location);
            },
            '"' => return self.scanString(start_location),
            '\'' => return self.scanChar(start_location),
            '\n' => {
                if (self.allow_newline_terminator) {
                    self.allow_newline_terminator = false;
                    return self.makeTokenAt(.newline, "\n", start_location);
                }
                // Non-significant newline, continue scanning
                return self.nextToken();
            },
            else => {
                if (isDigit(c)) {
                    return self.scanNumber(start_location);
                }
                if (isIdentifierStart(c)) {
                    return self.scanIdentifier(start_location);
                }
                return self.makeTokenAt(.invalid, self.source[start_location.offset..self.current], start_location);
            },
        }
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.peek();
            switch (c) {
                ' ', '\t', '\r' => {
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        // Line comment - skip to end of line
                        while (!self.isAtEnd() and self.peek() != '\n') {
                            _ = self.advance();
                        }
                    } else if (self.peekNext() == '*') {
                        // Block comment - skip to */
                        _ = self.advance(); // consume /
                        _ = self.advance(); // consume *
                        var depth: u32 = 1;
                        while (!self.isAtEnd() and depth > 0) {
                            if (self.peek() == '/' and self.peekNext() == '*') {
                                _ = self.advance();
                                _ = self.advance();
                                depth += 1;
                            } else if (self.peek() == '*' and self.peekNext() == '/') {
                                _ = self.advance();
                                _ = self.advance();
                                depth -= 1;
                            } else {
                                _ = self.advance();
                            }
                        }
                    } else {
                        return;
                    }
                },
                '\n' => {
                    // Newlines might be significant, don't skip here
                    return;
                },
                else => return,
            }
        }
    }

    fn scanString(self: *Lexer, start_location: Location) Token {
        while (!self.isAtEnd() and self.peek() != '"' and self.peek() != '\n') {
            if (self.peek() == '\\' and !self.isAtEnd()) {
                _ = self.advance(); // consume backslash
                _ = self.advance(); // consume escaped char
            } else {
                _ = self.advance();
            }
        }

        if (self.isAtEnd() or self.peek() == '\n') {
            return self.makeTokenAt(.invalid, self.source[start_location.offset..self.current], start_location);
        }

        _ = self.advance(); // consume closing quote
        self.updateNewlineState(.string_literal);
        return self.makeTokenAt(.string_literal, self.source[start_location.offset..self.current], start_location);
    }

    fn scanChar(self: *Lexer, start_location: Location) Token {
        if (self.isAtEnd()) {
            return self.makeTokenAt(.invalid, "'", start_location);
        }

        if (self.peek() == '\\') {
            _ = self.advance(); // backslash
            _ = self.advance(); // escaped char
        } else {
            _ = self.advance(); // single char
        }

        if (self.isAtEnd() or self.peek() != '\'') {
            return self.makeTokenAt(.invalid, self.source[start_location.offset..self.current], start_location);
        }

        _ = self.advance(); // closing quote
        self.updateNewlineState(.char_literal);
        return self.makeTokenAt(.char_literal, self.source[start_location.offset..self.current], start_location);
    }

    fn scanNumber(self: *Lexer, start_location: Location) Token {
        var is_float = false;

        // Check for hex or binary
        if (self.source[start_location.offset] == '0' and !self.isAtEnd()) {
            const next = self.peek();
            if (next == 'x' or next == 'X') {
                _ = self.advance();
                while (!self.isAtEnd() and (isHexDigit(self.peek()) or self.peek() == '_')) {
                    _ = self.advance();
                }
                self.updateNewlineState(.integer_literal);
                return self.makeNumericTokenAt(.integer_literal, self.source[start_location.offset..self.current], start_location);
            } else if (next == 'b' or next == 'B') {
                _ = self.advance();
                while (!self.isAtEnd() and (self.peek() == '0' or self.peek() == '1' or self.peek() == '_')) {
                    _ = self.advance();
                }
                self.updateNewlineState(.integer_literal);
                return self.makeNumericTokenAt(.integer_literal, self.source[start_location.offset..self.current], start_location);
            }
        }

        // Decimal digits
        while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
            _ = self.advance();
        }

        // Check for float
        if (!self.isAtEnd() and self.peek() == '.' and self.peekNext() != '.') {
            const next = self.peekNext();
            if (isDigit(next)) {
                is_float = true;
                _ = self.advance(); // consume .
                while (!self.isAtEnd() and (isDigit(self.peek()) or self.peek() == '_')) {
                    _ = self.advance();
                }
            }
        }

        // Check for type suffix (i32, i64, f32, f64, etc.)
        if (!self.isAtEnd() and isIdentifierStart(self.peek())) {
            const suffix_start = self.current;
            while (!self.isAtEnd() and isIdentifierPart(self.peek())) {
                _ = self.advance();
            }
            const suffix = self.source[suffix_start..self.current];
            if (isTypeSuffix(suffix)) {
                if (suffix[0] == 'f') {
                    is_float = true;
                }
            } else {
                // Not a valid suffix, rewind
                self.current = suffix_start;
            }
        }

        const tok_type: TokenType = if (is_float) .float_literal else .integer_literal;
        self.updateNewlineState(tok_type);
        return self.makeNumericTokenAt(tok_type, self.source[start_location.offset..self.current], start_location);
    }

    fn scanIdentifier(self: *Lexer, start_location: Location) Token {
        while (!self.isAtEnd() and isIdentifierPart(self.peek())) {
            _ = self.advance();
        }

        const lexeme = self.source[start_location.offset..self.current];

        // Check if it's a keyword
        if (token.keywords.get(lexeme)) |keyword_type| {
            self.updateNewlineState(keyword_type);
            return self.makeTokenAt(keyword_type, lexeme, start_location);
        }

        self.updateNewlineState(.identifier);
        return self.makeTokenAt(.identifier, lexeme, start_location);
    }

    fn updateNewlineState(self: *Lexer, tok_type: TokenType) void {
        // Tokens that can be followed by a significant newline (statement terminator)
        self.allow_newline_terminator = switch (tok_type) {
            .identifier,
            .integer_literal,
            .float_literal,
            .string_literal,
            .char_literal,
            .true_keyword,
            .false_keyword,
            .self_keyword,
            .self_type,
            .right_paren,
            .right_brace,
            .right_bracket,
            .return_keyword,
            .break_keyword,
            => true,
            else => false,
        };
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.current];
        self.current += 1;
        if (c == '\n') {
            self.location.line += 1;
            self.location.column = 1;
        } else {
            self.location.column += 1;
        }
        self.location.offset = self.current;
        return c;
    }

    fn peek(self: *Lexer) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.current];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.current + 1 >= self.source.len) return 0;
        return self.source[self.current + 1];
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.current] != expected) return false;
        _ = self.advance();
        return true;
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.current >= self.source.len;
    }

    fn makeToken(self: *Lexer, tok_type: TokenType, lexeme: []const u8) Token {
        return self.makeTokenAt(tok_type, lexeme, self.location);
    }

    fn makeTokenAt(_: *Lexer, tok_type: TokenType, lexeme: []const u8, start: Location) Token {
        return Token{
            .type = tok_type,
            .lexeme = lexeme,
            .span = Span{
                .start = start,
                .end = Location{
                    .line = start.line,
                    .column = start.column + @as(u32, @intCast(lexeme.len)),
                    .offset = start.offset + lexeme.len,
                },
            },
        };
    }

    fn makeNumericTokenAt(self: *Lexer, tok_type: TokenType, lexeme: []const u8, start: Location) Token {
        var tok = self.makeTokenAt(tok_type, lexeme, start);
        if (tok_type == .integer_literal) {
            tok.literal_value = .{ .integer = parseIntegerLiteral(lexeme) };
        } else if (tok_type == .float_literal) {
            tok.literal_value = .{ .float = parseFloatLiteral(lexeme) };
        }
        return tok;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentifierPart(c: u8) bool {
    return isIdentifierStart(c) or isDigit(c);
}

fn isTypeSuffix(s: []const u8) bool {
    const suffixes = [_][]const u8{
        "i8",  "i16", "i32", "i64", "i128",
        "u8",  "u16", "u32", "u64", "u128",
        "f32", "f64",
    };
    for (suffixes) |suffix| {
        if (std.mem.eql(u8, s, suffix)) return true;
    }
    return false;
}

/// Parse an integer literal from lexeme, handling hex, binary, underscores, and type suffixes
fn parseIntegerLiteral(lexeme: []const u8) i128 {
    if (lexeme.len == 0) return 0;

    // Strip type suffix (i32, u64, etc.)
    var end = lexeme.len;
    if (end > 2 and (lexeme[end - 1] >= '0' and lexeme[end - 1] <= '9' or lexeme[end - 1] == '8')) {
        // Possible type suffix like i32, u64, i128
        var suffix_start = end;
        while (suffix_start > 0 and ((lexeme[suffix_start - 1] >= '0' and lexeme[suffix_start - 1] <= '9') or
            lexeme[suffix_start - 1] == 'i' or lexeme[suffix_start - 1] == 'u'))
        {
            suffix_start -= 1;
            if (lexeme[suffix_start] == 'i' or lexeme[suffix_start] == 'u') {
                const suffix = lexeme[suffix_start..end];
                if (isTypeSuffix(suffix)) {
                    end = suffix_start;
                }
                break;
            }
        }
    }

    const num_str = lexeme[0..end];
    if (num_str.len == 0) return 0;

    // Check for hex (0x) or binary (0b)
    if (num_str.len > 2 and num_str[0] == '0') {
        if (num_str[1] == 'x' or num_str[1] == 'X') {
            return parseHexInt(num_str[2..]);
        } else if (num_str[1] == 'b' or num_str[1] == 'B') {
            return parseBinaryInt(num_str[2..]);
        }
    }

    // Decimal with possible underscores
    return parseDecimalInt(num_str);
}

fn parseHexInt(s: []const u8) i128 {
    var result: i128 = 0;
    for (s) |c| {
        if (c == '_') continue;
        result *= 16;
        if (c >= '0' and c <= '9') {
            result += c - '0';
        } else if (c >= 'a' and c <= 'f') {
            result += c - 'a' + 10;
        } else if (c >= 'A' and c <= 'F') {
            result += c - 'A' + 10;
        }
    }
    return result;
}

fn parseBinaryInt(s: []const u8) i128 {
    var result: i128 = 0;
    for (s) |c| {
        if (c == '_') continue;
        result *= 2;
        if (c == '1') result += 1;
    }
    return result;
}

fn parseDecimalInt(s: []const u8) i128 {
    var result: i128 = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (c < '0' or c > '9') break; // Stop at non-digit (could be start of suffix)
        result *= 10;
        result += c - '0';
    }
    return result;
}

/// Parse a float literal from lexeme, handling underscores and type suffixes
fn parseFloatLiteral(lexeme: []const u8) f64 {
    if (lexeme.len == 0) return 0.0;

    // Strip type suffix (f32, f64)
    var end = lexeme.len;
    if (end > 3 and lexeme[end - 2] == '3' and lexeme[end - 1] == '2' and lexeme[end - 3] == 'f') {
        end -= 3;
    } else if (end > 3 and lexeme[end - 2] == '6' and lexeme[end - 1] == '4' and lexeme[end - 3] == 'f') {
        end -= 3;
    }

    // Build string without underscores
    var buf: [64]u8 = undefined;
    var buf_idx: usize = 0;
    for (lexeme[0..end]) |c| {
        if (c == '_') continue;
        if (buf_idx >= buf.len - 1) break;
        buf[buf_idx] = c;
        buf_idx += 1;
    }

    return std.fmt.parseFloat(f64, buf[0..buf_idx]) catch 0.0;
}

test "lexer basics" {
    var lexer = Lexer.init("let x: i32 = 42");
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), tokens.items.len);
    try std.testing.expectEqual(TokenType.let, tokens.items[0].type);
    try std.testing.expectEqual(TokenType.identifier, tokens.items[1].type);
    try std.testing.expectEqual(TokenType.colon, tokens.items[2].type);
    try std.testing.expectEqual(TokenType.identifier, tokens.items[3].type);
    try std.testing.expectEqual(TokenType.equal, tokens.items[4].type);
    try std.testing.expectEqual(TokenType.integer_literal, tokens.items[5].type);
    try std.testing.expectEqual(TokenType.eof, tokens.items[6].type);
}

test "lexer operators" {
    var lexer = Lexer.init("+ - * / % == != < > <= >= -> => :: ?? .. ..=");
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    const expected = [_]TokenType{
        .plus,          .minus,       .star,              .slash,
        .percent,       .equal_equal, .bang_equal,        .less,
        .greater,       .less_equal,  .greater_equal,     .arrow,
        .fat_arrow,     .colon_colon, .question_question, .dot_dot,
        .dot_dot_equal, .eof,
    };

    try std.testing.expectEqual(expected.len, tokens.items.len);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp, tokens.items[i].type);
    }
}

test "lexer string literals" {
    var lexer = Lexer.init("\"hello world\" \"with\\nescapes\"");
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqual(TokenType.string_literal, tokens.items[0].type);
    try std.testing.expectEqualStrings("\"hello world\"", tokens.items[0].lexeme);
    try std.testing.expectEqual(TokenType.string_literal, tokens.items[1].type);
}

test "lexer number literals" {
    var lexer = Lexer.init("42 3.14 0xff 0b1010 42_000 3.14f32");
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 7), tokens.items.len);
    try std.testing.expectEqual(TokenType.integer_literal, tokens.items[0].type);
    try std.testing.expectEqual(TokenType.float_literal, tokens.items[1].type);
    try std.testing.expectEqual(TokenType.integer_literal, tokens.items[2].type);
    try std.testing.expectEqual(TokenType.integer_literal, tokens.items[3].type);
    try std.testing.expectEqual(TokenType.integer_literal, tokens.items[4].type);
    try std.testing.expectEqual(TokenType.float_literal, tokens.items[5].type);
}

test "lexer keywords" {
    var lexer = Lexer.init("fn let type module import pub effect trait impl const var if else match for return break true false self Self and or not is in as where");
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    const expected = [_]TokenType{
        .fn_keyword,    .let,           .type_keyword,  .module,
        .import,        .pub_keyword,   .effect,        .trait,
        .impl,          .const_keyword, .var_keyword,   .if_keyword,
        .else_keyword,  .match,         .for_keyword,   .return_keyword,
        .break_keyword, .true_keyword,  .false_keyword, .self_keyword,
        .self_type,     .and_keyword,   .or_keyword,    .not_keyword,
        .is_keyword,    .in_keyword,    .as_keyword,    .where,
        .eof,
    };

    try std.testing.expectEqual(expected.len, tokens.items.len);
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp, tokens.items[i].type);
    }
}

test "lexer comments" {
    var lexer = Lexer.init(
        \\let x = 1 // comment
        \\let y = /* block */ 2
    );
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    // Comments are skipped, so we should only see tokens
    try std.testing.expectEqual(TokenType.let, tokens.items[0].type);
    try std.testing.expectEqual(TokenType.identifier, tokens.items[1].type);
    try std.testing.expectEqual(TokenType.equal, tokens.items[2].type);
    try std.testing.expectEqual(TokenType.integer_literal, tokens.items[3].type);
}

test "lexer significant newlines" {
    var lexer = Lexer.init(
        \\let x = 42
        \\let y = 3
    );
    var tokens = try lexer.scanAllTokens(std.testing.allocator);
    defer tokens.deinit(std.testing.allocator);

    // After identifier/literal, newline should be significant
    var found_newline = false;
    for (tokens.items) |tok| {
        if (tok.type == .newline) {
            found_newline = true;
            break;
        }
    }
    try std.testing.expect(found_newline);
}
