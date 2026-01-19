//! Expression AST nodes for the Kira language.
//!
//! Expressions evaluate to values. In Kira, expressions include literals,
//! identifiers, binary/unary operations, function calls, field access,
//! closures, and more.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;
pub const Type = @import("types.zig").Type;
pub const Statement = @import("statement.zig").Statement;
pub const Pattern = @import("pattern.zig").Pattern;

/// Represents an expression in the Kira language.
pub const Expression = struct {
    kind: ExpressionKind,
    span: Span,

    pub const ExpressionKind = union(enum) {
        // Literals
        integer_literal: IntegerLiteral,
        float_literal: FloatLiteral,
        string_literal: StringLiteral,
        char_literal: CharLiteral,
        bool_literal: bool,

        // Identifiers and paths
        identifier: Identifier,
        self_expr: void, // `self`
        self_type_expr: void, // `Self`

        // Operators
        binary: BinaryOp,
        unary: UnaryOp,

        // Access expressions
        field_access: FieldAccess,
        index_access: IndexAccess,
        tuple_access: TupleAccess,

        // Calls
        function_call: FunctionCall,
        method_call: MethodCall,

        // Closures
        closure: Closure,

        // Match expression (match can be used as expression in some contexts)
        match_expr: MatchExpr,

        // Composite literals
        tuple_literal: TupleLiteral,
        array_literal: ArrayLiteral,
        record_literal: RecordLiteral,

        // Variant constructor (e.g., Some(x), None, Ok(v), Err(e))
        variant_constructor: VariantConstructor,

        // Type cast (explicit conversion)
        type_cast: TypeCast,

        // Range expressions
        range: Range,

        // Grouped expression (parenthesized)
        grouped: *Expression,

        // Interpolated string
        interpolated_string: InterpolatedString,

        // Error propagation
        try_expr: *Expression, // expr?
        null_coalesce: NullCoalesce, // expr ?? default
    };

    /// Integer literal with value and optional type suffix
    pub const IntegerLiteral = struct {
        value: i128,
        suffix: ?[]const u8, // e.g., "i64", "u32"
    };

    /// Float literal with value and optional type suffix
    pub const FloatLiteral = struct {
        value: f64,
        suffix: ?[]const u8, // e.g., "f32", "f64"
    };

    /// String literal (regular, not interpolated)
    pub const StringLiteral = struct {
        value: []const u8,
    };

    /// Character literal
    pub const CharLiteral = struct {
        value: u21, // Unicode codepoint
    };

    /// Identifier (variable or type name)
    pub const Identifier = struct {
        name: []const u8,
        /// Optional generic type arguments: `identity[i32]`
        generic_args: ?[]*Type,
    };

    /// Binary operation
    pub const BinaryOp = struct {
        left: *Expression,
        operator: BinaryOperator,
        right: *Expression,
    };

    /// Binary operators
    pub const BinaryOperator = enum {
        // Arithmetic
        add, // +
        subtract, // -
        multiply, // *
        divide, // /
        modulo, // %

        // Comparison
        equal, // ==
        not_equal, // !=
        less_than, // <
        greater_than, // >
        less_equal, // <=
        greater_equal, // >=

        // Logical
        logical_and, // and
        logical_or, // or

        // Special
        is, // is (type check)
        in_op, // in (membership)

        pub fn toString(self: BinaryOperator) []const u8 {
            return switch (self) {
                .add => "+",
                .subtract => "-",
                .multiply => "*",
                .divide => "/",
                .modulo => "%",
                .equal => "==",
                .not_equal => "!=",
                .less_than => "<",
                .greater_than => ">",
                .less_equal => "<=",
                .greater_equal => ">=",
                .logical_and => "and",
                .logical_or => "or",
                .is => "is",
                .in_op => "in",
            };
        }

        pub fn precedence(self: BinaryOperator) u8 {
            return switch (self) {
                .logical_or => 1,
                .logical_and => 2,
                .equal, .not_equal => 3,
                .less_than, .greater_than, .less_equal, .greater_equal, .is, .in_op => 4,
                .add, .subtract => 5,
                .multiply, .divide, .modulo => 6,
            };
        }
    };

    /// Unary operation
    pub const UnaryOp = struct {
        operator: UnaryOperator,
        operand: *Expression,
    };

    /// Unary operators
    pub const UnaryOperator = enum {
        negate, // -
        logical_not, // not

        pub fn toString(self: UnaryOperator) []const u8 {
            return switch (self) {
                .negate => "-",
                .logical_not => "not",
            };
        }
    };

    /// Field access (e.g., `point.x`)
    pub const FieldAccess = struct {
        object: *Expression,
        field: []const u8,
    };

    /// Index access (e.g., `array[i]`)
    pub const IndexAccess = struct {
        object: *Expression,
        index: *Expression,
    };

    /// Tuple access (e.g., `pair.0`)
    pub const TupleAccess = struct {
        tuple: *Expression,
        index: u32,
    };

    /// Function call
    pub const FunctionCall = struct {
        callee: *Expression,
        /// Explicit generic arguments: `func[T, U](args)`
        generic_args: ?[]*Type,
        arguments: []*Expression,
    };

    /// Method call (e.g., `obj.method(args)`)
    pub const MethodCall = struct {
        object: *Expression,
        method: []const u8,
        generic_args: ?[]*Type,
        arguments: []*Expression,
    };

    /// Closure definition
    /// `fn(params) -> ReturnType { body }`
    pub const Closure = struct {
        parameters: []Parameter,
        return_type: *Type,
        is_effect: bool, // `effect fn` vs `fn`
        body: []Statement,
    };

    /// Function/closure parameter
    pub const Parameter = struct {
        name: []const u8,
        param_type: *Type,
        span: Span,
    };

    /// Match expression
    pub const MatchExpr = struct {
        subject: *Expression,
        arms: []MatchArm,
    };

    /// Match arm (pattern => expression or block)
    pub const MatchArm = struct {
        pattern: *Pattern,
        guard: ?*Expression, // Optional `if condition`
        body: MatchBody,
        span: Span,
    };

    /// Match arm body can be an expression or statement block
    pub const MatchBody = union(enum) {
        expression: *Expression,
        block: []Statement,
    };

    /// Tuple literal (e.g., `(1, "hello", true)`)
    pub const TupleLiteral = struct {
        elements: []*Expression,
    };

    /// Array literal (e.g., `[1, 2, 3, 4, 5]`)
    pub const ArrayLiteral = struct {
        elements: []*Expression,
    };

    /// Record literal (e.g., `Point { x: 1.0, y: 2.0 }`)
    pub const RecordLiteral = struct {
        type_name: ?*Expression, // Optional: Point { ... } vs { ... }
        fields: []FieldInit,
    };

    /// Field initializer in record literal
    pub const FieldInit = struct {
        name: []const u8,
        value: *Expression,
        span: Span,
    };

    /// Variant constructor (e.g., `Some(42)`, `None`, `Cons(1, Nil)`)
    pub const VariantConstructor = struct {
        variant_name: []const u8,
        arguments: ?[]*Expression, // None has no args, Some(x) has one
    };

    /// Explicit type cast (e.g., `x.as[i64]`)
    pub const TypeCast = struct {
        expression: *Expression,
        target_type: *Type,
    };

    /// Range expression
    pub const Range = struct {
        start: ?*Expression, // Optional for `..end`
        end: ?*Expression, // Optional for `start..`
        inclusive: bool, // `..` vs `..=`
    };

    /// Interpolated string (e.g., `"Hello {name}!"`)
    pub const InterpolatedString = struct {
        parts: []InterpolatedPart,
    };

    /// Part of an interpolated string
    pub const InterpolatedPart = union(enum) {
        literal: []const u8,
        expression: *Expression,
    };

    /// Null coalesce expression (e.g., `value ?? default`)
    pub const NullCoalesce = struct {
        left: *Expression,
        default: *Expression,
    };

    /// Create a new expression with the given kind and span
    pub fn init(kind: ExpressionKind, span: Span) Expression {
        return .{ .kind = kind, .span = span };
    }

    /// Check if this expression is a simple literal
    pub fn isLiteral(self: Expression) bool {
        return switch (self.kind) {
            .integer_literal, .float_literal, .string_literal, .char_literal, .bool_literal => true,
            else => false,
        };
    }

    /// Check if this expression is a simple identifier
    pub fn isIdentifier(self: Expression) bool {
        return self.kind == .identifier;
    }
};

test "expression kinds" {
    const span = Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    // Test integer literal
    const int_expr = Expression.init(.{ .integer_literal = .{ .value = 42, .suffix = null } }, span);
    try std.testing.expect(int_expr.isLiteral());
    try std.testing.expect(!int_expr.isIdentifier());

    // Test boolean literal
    const bool_expr = Expression.init(.{ .bool_literal = true }, span);
    try std.testing.expect(bool_expr.isLiteral());
}

test "binary operator precedence" {
    // Multiplication has higher precedence than addition
    try std.testing.expect(Expression.BinaryOperator.multiply.precedence() > Expression.BinaryOperator.add.precedence());
    // Logical and has higher precedence than logical or
    try std.testing.expect(Expression.BinaryOperator.logical_and.precedence() > Expression.BinaryOperator.logical_or.precedence());
}
