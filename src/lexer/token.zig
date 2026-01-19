const std = @import("std");

/// Source location for error reporting
pub const Location = struct {
    line: u32,
    column: u32,
    offset: usize,

    pub const start = Location{ .line = 1, .column = 1, .offset = 0 };

    pub fn format(self: Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}", .{ self.line, self.column });
    }
};

/// A span of source code
pub const Span = struct {
    start: Location,
    end: Location,

    pub fn format(self: Span, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}-{}", .{ self.start, self.end });
    }
};

/// Token type enumeration for Kira language
pub const TokenType = enum {
    // Declarations
    fn_keyword,
    let,
    type_keyword,
    module,
    import,
    pub_keyword,
    effect,
    trait,
    impl,
    const_keyword,
    var_keyword,

    // Control flow
    if_keyword,
    else_keyword,
    match,
    for_keyword,
    return_keyword,
    break_keyword,

    // Literals
    true_keyword,
    false_keyword,
    self_keyword,
    self_type, // Self

    // Logical operators (word form)
    and_keyword,
    or_keyword,
    not_keyword,
    is_keyword,
    in_keyword,
    as_keyword,

    // Special keywords
    where,

    // Arithmetic operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %

    // Comparison operators
    equal_equal, // ==
    bang_equal, // !=
    less, // <
    greater, // >
    less_equal, // <=
    greater_equal, // >=

    // Special operators
    question, // ?
    question_question, // ??
    dot_dot, // ..
    dot_dot_equal, // ..=
    arrow, // ->
    fat_arrow, // =>
    colon, // :
    colon_colon, // ::
    pipe, // |

    // Punctuation
    left_paren, // (
    right_paren, // )
    left_brace, // {
    right_brace, // }
    left_bracket, // [
    right_bracket, // ]
    comma, // ,
    dot, // .
    semicolon, // ;
    equal, // =
    bang, // !

    // Literals
    integer_literal,
    float_literal,
    string_literal,
    char_literal,

    // Identifier
    identifier,

    // Comments (preserved for doc generation)
    line_comment,
    block_comment,
    doc_comment,
    module_doc_comment,

    // Special tokens
    newline, // Significant newlines
    eof,
    invalid,

    pub fn isKeyword(self: TokenType) bool {
        return switch (self) {
            .fn_keyword,
            .let,
            .type_keyword,
            .module,
            .import,
            .pub_keyword,
            .effect,
            .trait,
            .impl,
            .const_keyword,
            .var_keyword,
            .if_keyword,
            .else_keyword,
            .match,
            .for_keyword,
            .return_keyword,
            .break_keyword,
            .true_keyword,
            .false_keyword,
            .self_keyword,
            .self_type,
            .and_keyword,
            .or_keyword,
            .not_keyword,
            .is_keyword,
            .in_keyword,
            .as_keyword,
            .where,
            => true,
            else => false,
        };
    }

    pub fn isOperator(self: TokenType) bool {
        return switch (self) {
            .plus,
            .minus,
            .star,
            .slash,
            .percent,
            .equal_equal,
            .bang_equal,
            .less,
            .greater,
            .less_equal,
            .greater_equal,
            .question,
            .question_question,
            .dot_dot,
            .dot_dot_equal,
            .arrow,
            .fat_arrow,
            .colon,
            .colon_colon,
            .pipe,
            .and_keyword,
            .or_keyword,
            .not_keyword,
            => true,
            else => false,
        };
    }

    pub fn toString(self: TokenType) []const u8 {
        return switch (self) {
            .fn_keyword => "fn",
            .let => "let",
            .type_keyword => "type",
            .module => "module",
            .import => "import",
            .pub_keyword => "pub",
            .effect => "effect",
            .trait => "trait",
            .impl => "impl",
            .const_keyword => "const",
            .var_keyword => "var",
            .if_keyword => "if",
            .else_keyword => "else",
            .match => "match",
            .for_keyword => "for",
            .return_keyword => "return",
            .break_keyword => "break",
            .true_keyword => "true",
            .false_keyword => "false",
            .self_keyword => "self",
            .self_type => "Self",
            .and_keyword => "and",
            .or_keyword => "or",
            .not_keyword => "not",
            .is_keyword => "is",
            .in_keyword => "in",
            .as_keyword => "as",
            .where => "where",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .equal_equal => "==",
            .bang_equal => "!=",
            .less => "<",
            .greater => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            .question => "?",
            .question_question => "??",
            .dot_dot => "..",
            .dot_dot_equal => "..=",
            .arrow => "->",
            .fat_arrow => "=>",
            .colon => ":",
            .colon_colon => "::",
            .pipe => "|",
            .left_paren => "(",
            .right_paren => ")",
            .left_brace => "{",
            .right_brace => "}",
            .left_bracket => "[",
            .right_bracket => "]",
            .comma => ",",
            .dot => ".",
            .semicolon => ";",
            .equal => "=",
            .bang => "!",
            .integer_literal => "integer",
            .float_literal => "float",
            .string_literal => "string",
            .char_literal => "char",
            .identifier => "identifier",
            .line_comment => "// comment",
            .block_comment => "/* comment */",
            .doc_comment => "/// doc",
            .module_doc_comment => "//! doc",
            .newline => "newline",
            .eof => "end of file",
            .invalid => "invalid",
        };
    }
};

/// A token in the Kira language
pub const Token = struct {
    type: TokenType,
    lexeme: []const u8,
    span: Span,

    /// For numeric literals, the parsed value
    literal_value: union {
        integer: i128,
        float: f64,
        none: void,
    } = .{ .none = {} },

    pub fn format(self: Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}'{s}'@{}", .{ @tagName(self.type), self.lexeme, self.span.start });
    }
};

/// Keyword lookup table
pub const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "fn", .fn_keyword },
    .{ "let", .let },
    .{ "type", .type_keyword },
    .{ "module", .module },
    .{ "import", .import },
    .{ "pub", .pub_keyword },
    .{ "effect", .effect },
    .{ "trait", .trait },
    .{ "impl", .impl },
    .{ "const", .const_keyword },
    .{ "var", .var_keyword },
    .{ "if", .if_keyword },
    .{ "else", .else_keyword },
    .{ "match", .match },
    .{ "for", .for_keyword },
    .{ "return", .return_keyword },
    .{ "break", .break_keyword },
    .{ "true", .true_keyword },
    .{ "false", .false_keyword },
    .{ "self", .self_keyword },
    .{ "Self", .self_type },
    .{ "and", .and_keyword },
    .{ "or", .or_keyword },
    .{ "not", .not_keyword },
    .{ "is", .is_keyword },
    .{ "in", .in_keyword },
    .{ "as", .as_keyword },
    .{ "where", .where },
});

test "keyword lookup" {
    try std.testing.expectEqual(TokenType.fn_keyword, keywords.get("fn").?);
    try std.testing.expectEqual(TokenType.let, keywords.get("let").?);
    try std.testing.expectEqual(TokenType.self_type, keywords.get("Self").?);
    try std.testing.expect(keywords.get("notakeyword") == null);
}

test "token type properties" {
    try std.testing.expect(TokenType.fn_keyword.isKeyword());
    try std.testing.expect(TokenType.plus.isOperator());
    try std.testing.expect(!TokenType.identifier.isKeyword());
    try std.testing.expect(!TokenType.identifier.isOperator());
}
