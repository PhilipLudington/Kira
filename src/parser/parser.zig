//! Parser for the Kira programming language.
//!
//! Implements a recursive descent parser that transforms a stream of tokens
//! into an Abstract Syntax Tree (AST).

const std = @import("std");
const Allocator = std.mem.Allocator;

const lexer = @import("../lexer/root.zig");
const Token = lexer.Token;
const TokenType = lexer.TokenType;
const Span = lexer.Span;
const Location = lexer.Location;

const ast = @import("../ast/root.zig");
const Expression = ast.Expression;
const Statement = ast.Statement;
const Type = ast.Type;
const Declaration = ast.Declaration;
const Pattern = ast.Pattern;
const Program = ast.Program;

/// Parser error types
pub const ParseError = error{
    UnexpectedToken,
    ExpectedExpression,
    ExpectedType,
    ExpectedPattern,
    ExpectedIdentifier,
    ExpectedDeclaration,
    InvalidAssignmentTarget,
    InvalidPattern,
    OutOfMemory,
    Overflow,
};

/// Detailed error information for reporting
pub const ErrorInfo = struct {
    message: []const u8,
    span: Span,
    expected: ?[]const u8,
    found: ?[]const u8,
};

/// Parser for Kira source code
pub const Parser = struct {
    allocator: Allocator,
    tokens: []const Token,
    current: usize,
    errors: std.ArrayListUnmanaged(ErrorInfo),

    /// Initialize a new parser with the given tokens
    pub fn init(allocator: Allocator, tokens: []const Token) Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .current = 0,
            .errors = .{},
        };
    }

    /// Clean up parser resources
    pub fn deinit(self: *Parser) void {
        self.errors.deinit(self.allocator);
    }

    /// Parse a complete program
    pub fn parseProgram(self: *Parser) ParseError!Program {
        var module_decl: ?Declaration.ModuleDecl = null;
        var imports = std.ArrayListUnmanaged(Declaration.ImportDecl){};
        errdefer imports.deinit(self.allocator);
        var declarations = std.ArrayListUnmanaged(Declaration){};
        errdefer declarations.deinit(self.allocator);
        var module_doc: ?[]const u8 = null;

        // Skip leading newlines
        self.skipNewlines();

        // Check for module doc comment
        if (self.check(.module_doc_comment)) {
            module_doc = self.advance().lexeme;
            self.skipNewlines();
        }

        // Parse module declaration if present
        if (self.check(.module)) {
            module_decl = try self.parseModuleDecl();
            self.skipNewlines();
        }

        // Parse imports
        while (self.check(.import)) {
            const import_decl = try self.parseImportDecl();
            try imports.append(self.allocator, import_decl);
            self.skipNewlines();
        }

        // Parse declarations
        while (!self.isAtEnd()) {
            self.skipNewlines();
            if (self.isAtEnd()) break;

            const decl = try self.parseDeclaration();
            try declarations.append(self.allocator, decl);
            self.skipNewlines();
        }

        return Program{
            .module_decl = module_decl,
            .imports = try imports.toOwnedSlice(self.allocator),
            .declarations = try declarations.toOwnedSlice(self.allocator),
            .module_doc = module_doc,
            .source_path = null,
            .arena = null, // Arena is set by caller (Kira.parse)
        };
    }

    // =========================================================================
    // Declaration Parsing
    // =========================================================================

    fn parseDeclaration(self: *Parser) ParseError!Declaration {
        var doc_comment: ?[]const u8 = null;

        // Check for doc comment
        if (self.check(.doc_comment)) {
            doc_comment = self.advance().lexeme;
            self.skipNewlines();
        }

        const is_public = self.match(.pub_keyword);
        const start_span = self.peek().span;

        const kind: Declaration.DeclarationKind = if (self.check(.fn_keyword)) blk: {
            break :blk .{ .function_decl = try self.parseFunctionDecl(is_public) };
        } else if (self.match(.effect)) blk: {
            // effect fn name(...)
            try self.consume(.fn_keyword, "expected 'fn' after 'effect'");
            break :blk .{ .function_decl = try self.parseEffectFunctionDecl(is_public) };
        } else if (self.check(.type_keyword)) blk: {
            break :blk .{ .type_decl = try self.parseTypeDecl(is_public) };
        } else if (self.check(.trait)) blk: {
            break :blk .{ .trait_decl = try self.parseTraitDecl(is_public) };
        } else if (self.check(.impl)) blk: {
            break :blk .{ .impl_block = try self.parseImplBlock() };
        } else if (self.check(.const_keyword)) blk: {
            break :blk .{ .const_decl = try self.parseConstDecl(is_public) };
        } else if (self.check(.let)) blk: {
            break :blk .{ .let_decl = try self.parseLetDecl(is_public) };
        } else {
            return self.reportError("expected declaration", null);
        };

        var decl = Declaration.init(kind, self.makeSpan(start_span.start));
        decl.doc_comment = doc_comment;
        return decl;
    }

    fn parseModuleDecl(self: *Parser) ParseError!Declaration.ModuleDecl {
        _ = self.advance(); // consume 'module'

        var path = std.ArrayListUnmanaged([]const u8){};
        errdefer path.deinit(self.allocator);

        // Parse first segment
        const first = try self.consumeIdentifier("expected module name");
        try path.append(self.allocator, first);

        // Parse remaining path segments
        while (self.match(.dot)) {
            const segment = try self.consumeIdentifier("expected module name after '.'");
            try path.append(self.allocator, segment);
        }

        return Declaration.ModuleDecl{
            .path = try path.toOwnedSlice(self.allocator),
        };
    }

    fn parseImportDecl(self: *Parser) ParseError!Declaration.ImportDecl {
        _ = self.advance(); // consume 'import'

        var path = std.ArrayListUnmanaged([]const u8){};
        errdefer path.deinit(self.allocator);

        // Parse path
        const first = try self.consumeIdentifier("expected module path");
        try path.append(self.allocator, first);

        while (self.match(.dot)) {
            // Check for item list: import path.{ item1, item2 }
            if (self.check(.left_brace)) break;

            const segment = try self.consumeIdentifier("expected module name after '.'");
            try path.append(self.allocator, segment);
        }

        // Parse optional import items
        var items: ?[]Declaration.ImportItem = null;
        if (self.match(.left_brace)) {
            var item_list = std.ArrayListUnmanaged(Declaration.ImportItem){};
            errdefer item_list.deinit(self.allocator);

            if (!self.check(.right_brace)) {
                // Parse first item
                try item_list.append(self.allocator, try self.parseImportItem());

                while (self.match(.comma)) {
                    if (self.check(.right_brace)) break;
                    try item_list.append(self.allocator, try self.parseImportItem());
                }
            }

            try self.consume(.right_brace, "expected '}' after import items");
            items = try item_list.toOwnedSlice(self.allocator);
        }

        return Declaration.ImportDecl{
            .path = try path.toOwnedSlice(self.allocator),
            .items = items,
        };
    }

    fn parseImportItem(self: *Parser) ParseError!Declaration.ImportItem {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected import item name");

        var alias: ?[]const u8 = null;
        if (self.match(.as_keyword)) {
            alias = try self.consumeIdentifier("expected alias after 'as'");
        }

        return Declaration.ImportItem{
            .name = name,
            .alias = alias,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseFunctionDecl(self: *Parser, is_public: bool) ParseError!Declaration.FunctionDecl {
        _ = self.advance(); // consume 'fn'
        return self.parseFunctionDeclBody(is_public, false);
    }

    fn parseEffectFunctionDecl(self: *Parser, is_public: bool) ParseError!Declaration.FunctionDecl {
        return self.parseFunctionDeclBody(is_public, true);
    }

    fn parseFunctionDeclBody(self: *Parser, is_public: bool, is_effect: bool) ParseError!Declaration.FunctionDecl {
        const name = try self.consumeIdentifier("expected function name");

        // Parse optional generic parameters
        const generic_params = try self.parseOptionalGenericParams();

        // Parse parameters
        try self.consume(.left_paren, "expected '(' after function name");
        const parameters = try self.parseParameters();
        try self.consume(.right_paren, "expected ')' after parameters");

        // Parse return type
        try self.consume(.arrow, "expected '->' before return type");
        const return_type = try self.allocType(try self.parseType());

        // Parse optional where clause
        const where_clause = try self.parseOptionalWhereClause();

        // Parse body
        var body: ?[]Statement = null;
        if (self.check(.left_brace)) {
            body = try self.parseBlock();
        }

        return Declaration.FunctionDecl{
            .name = name,
            .generic_params = generic_params,
            .parameters = parameters,
            .return_type = return_type,
            .is_effect = is_effect,
            .is_public = is_public,
            .body = body,
            .where_clause = where_clause,
        };
    }

    fn parseOptionalGenericParams(self: *Parser) ParseError!?[]Declaration.GenericParam {
        if (!self.match(.left_bracket)) return null;

        var params = std.ArrayListUnmanaged(Declaration.GenericParam){};
        errdefer params.deinit(self.allocator);

        if (!self.check(.right_bracket)) {
            try params.append(self.allocator, try self.parseGenericParam());

            while (self.match(.comma)) {
                if (self.check(.right_bracket)) break;
                try params.append(self.allocator, try self.parseGenericParam());
            }
        }

        try self.consume(.right_bracket, "expected ']' after generic parameters");
        return try params.toOwnedSlice(self.allocator);
    }

    fn parseGenericParam(self: *Parser) ParseError!Declaration.GenericParam {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected type parameter name");

        var constraints: ?[][]const u8 = null;
        if (self.match(.colon)) {
            var bounds = std.ArrayListUnmanaged([]const u8){};
            errdefer bounds.deinit(self.allocator);

            try bounds.append(self.allocator, try self.consumeIdentifier("expected trait bound"));

            while (self.match(.plus)) {
                try bounds.append(self.allocator, try self.consumeIdentifier("expected trait bound after '+'"));
            }

            constraints = try bounds.toOwnedSlice(self.allocator);
        }

        return Declaration.GenericParam{
            .name = name,
            .constraints = constraints,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseParameters(self: *Parser) ParseError![]Declaration.Parameter {
        var params = std.ArrayListUnmanaged(Declaration.Parameter){};
        errdefer params.deinit(self.allocator);

        if (!self.check(.right_paren)) {
            try params.append(self.allocator, try self.parseParameter());

            while (self.match(.comma)) {
                if (self.check(.right_paren)) break;
                try params.append(self.allocator, try self.parseParameter());
            }
        }

        return try params.toOwnedSlice(self.allocator);
    }

    fn parseParameter(self: *Parser) ParseError!Declaration.Parameter {
        const start = self.peek().span;

        // Handle 'self' as special parameter name
        const name = if (self.match(.self_keyword))
            "self"
        else
            try self.consumeIdentifier("expected parameter name");

        try self.consume(.colon, "expected ':' after parameter name");
        const param_type = try self.allocType(try self.parseType());

        return Declaration.Parameter{
            .name = name,
            .param_type = param_type,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseOptionalWhereClause(self: *Parser) ParseError!?[]Declaration.WhereConstraint {
        if (!self.match(.where)) return null;

        var constraints = std.ArrayListUnmanaged(Declaration.WhereConstraint){};
        errdefer constraints.deinit(self.allocator);

        try constraints.append(self.allocator, try self.parseWhereConstraint());

        while (self.match(.comma)) {
            try constraints.append(self.allocator, try self.parseWhereConstraint());
        }

        return try constraints.toOwnedSlice(self.allocator);
    }

    fn parseWhereConstraint(self: *Parser) ParseError!Declaration.WhereConstraint {
        const start = self.peek().span;
        const type_param = try self.consumeIdentifier("expected type parameter name");

        try self.consume(.colon, "expected ':' after type parameter");

        var bounds = std.ArrayListUnmanaged([]const u8){};
        errdefer bounds.deinit(self.allocator);

        try bounds.append(self.allocator, try self.consumeIdentifier("expected trait bound"));

        while (self.match(.plus)) {
            try bounds.append(self.allocator, try self.consumeIdentifier("expected trait bound after '+'"));
        }

        return Declaration.WhereConstraint{
            .type_param = type_param,
            .bounds = try bounds.toOwnedSlice(self.allocator),
            .span = self.makeSpan(start.start),
        };
    }

    fn parseTypeDecl(self: *Parser, is_public: bool) ParseError!Declaration.TypeDecl {
        _ = self.advance(); // consume 'type'
        const name = try self.consumeIdentifier("expected type name");

        const generic_params = try self.parseOptionalGenericParams();

        try self.consume(.equal, "expected '=' after type name");
        self.skipNewlines();

        const definition = try self.parseTypeDefinition();

        return Declaration.TypeDecl{
            .name = name,
            .generic_params = generic_params,
            .definition = definition,
            .is_public = is_public,
        };
    }

    fn parseTypeDefinition(self: *Parser) ParseError!Declaration.TypeDefinition {
        // Sum type: | Variant1 | Variant2
        if (self.check(.pipe)) {
            return .{ .sum_type = try self.parseSumType() };
        }

        // Product type: { field: Type }
        if (self.check(.left_brace)) {
            return .{ .product_type = try self.parseProductType() };
        }

        // Type alias
        return .{ .type_alias = try self.allocType(try self.parseType()) };
    }

    fn parseSumType(self: *Parser) ParseError!Declaration.SumType {
        var variants = std.ArrayListUnmanaged(Declaration.Variant){};
        errdefer variants.deinit(self.allocator);

        while (self.match(.pipe)) {
            self.skipNewlines();
            try variants.append(self.allocator, try self.parseVariant());
            self.skipNewlines(); // Skip newlines before checking for next pipe
        }

        return Declaration.SumType{
            .variants = try variants.toOwnedSlice(self.allocator),
        };
    }

    fn parseVariant(self: *Parser) ParseError!Declaration.Variant {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected variant name");

        var fields: ?Declaration.VariantFields = null;

        if (self.match(.left_paren)) {
            // Tuple-style variant: Variant(Type1, Type2)
            var tuple_fields = std.ArrayListUnmanaged(*Type){};
            errdefer tuple_fields.deinit(self.allocator);

            if (!self.check(.right_paren)) {
                try tuple_fields.append(self.allocator, try self.allocType(try self.parseType()));

                while (self.match(.comma)) {
                    if (self.check(.right_paren)) break;
                    try tuple_fields.append(self.allocator, try self.allocType(try self.parseType()));
                }
            }

            try self.consume(.right_paren, "expected ')' after variant fields");
            fields = .{ .tuple_fields = try tuple_fields.toOwnedSlice(self.allocator) };
        } else if (self.check(.left_brace)) {
            // Record-style variant: Variant { field: Type }
            fields = .{ .record_fields = try self.parseRecordFields() };
        }

        return Declaration.Variant{
            .name = name,
            .fields = fields,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseProductType(self: *Parser) ParseError!Declaration.ProductType {
        const fields = try self.parseRecordFields();
        return Declaration.ProductType{ .fields = fields };
    }

    fn parseRecordFields(self: *Parser) ParseError![]Declaration.RecordField {
        try self.consume(.left_brace, "expected '{'");

        var fields = std.ArrayListUnmanaged(Declaration.RecordField){};
        errdefer fields.deinit(self.allocator);

        self.skipNewlines();

        if (!self.check(.right_brace)) {
            try fields.append(self.allocator, try self.parseRecordField());
            self.skipNewlines();

            while (self.match(.comma)) {
                self.skipNewlines();
                if (self.check(.right_brace)) break;
                try fields.append(self.allocator, try self.parseRecordField());
                self.skipNewlines();
            }
        }

        try self.consume(.right_brace, "expected '}'");
        return try fields.toOwnedSlice(self.allocator);
    }

    fn parseRecordField(self: *Parser) ParseError!Declaration.RecordField {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected field name");

        try self.consume(.colon, "expected ':' after field name");
        const field_type = try self.allocType(try self.parseType());

        return Declaration.RecordField{
            .name = name,
            .field_type = field_type,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseTraitDecl(self: *Parser, is_public: bool) ParseError!Declaration.TraitDecl {
        _ = self.advance(); // consume 'trait'
        const name = try self.consumeIdentifier("expected trait name");

        const generic_params = try self.parseOptionalGenericParams();

        // Parse optional super traits: trait Ord: Eq
        var super_traits: ?[][]const u8 = null;
        if (self.match(.colon)) {
            var supers = std.ArrayListUnmanaged([]const u8){};
            errdefer supers.deinit(self.allocator);

            try supers.append(self.allocator, try self.consumeIdentifier("expected trait name"));

            while (self.match(.plus)) {
                try supers.append(self.allocator, try self.consumeIdentifier("expected trait name after '+'"));
            }

            super_traits = try supers.toOwnedSlice(self.allocator);
        }

        // Parse trait body
        try self.consume(.left_brace, "expected '{' before trait body");
        self.skipNewlines();

        var methods = std.ArrayListUnmanaged(Declaration.TraitMethod){};
        errdefer methods.deinit(self.allocator);

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            try methods.append(self.allocator, try self.parseTraitMethod());
            self.skipNewlines();
        }

        try self.consume(.right_brace, "expected '}' after trait body");

        return Declaration.TraitDecl{
            .name = name,
            .generic_params = generic_params,
            .super_traits = super_traits,
            .methods = try methods.toOwnedSlice(self.allocator),
            .is_public = is_public,
        };
    }

    fn parseTraitMethod(self: *Parser) ParseError!Declaration.TraitMethod {
        const start = self.peek().span;

        const is_effect = self.match(.effect);
        try self.consume(.fn_keyword, "expected 'fn' for trait method");

        const name = try self.consumeIdentifier("expected method name");
        const generic_params = try self.parseOptionalGenericParams();

        try self.consume(.left_paren, "expected '(' after method name");
        const parameters = try self.parseParameters();
        try self.consume(.right_paren, "expected ')' after parameters");

        try self.consume(.arrow, "expected '->' before return type");
        const return_type = try self.allocType(try self.parseType());

        // Parse optional default body
        var default_body: ?[]Statement = null;
        if (self.check(.left_brace)) {
            default_body = try self.parseBlock();
        }

        return Declaration.TraitMethod{
            .name = name,
            .generic_params = generic_params,
            .parameters = parameters,
            .return_type = return_type,
            .is_effect = is_effect,
            .default_body = default_body,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseImplBlock(self: *Parser) ParseError!Declaration.ImplBlock {
        _ = self.advance(); // consume 'impl'

        const generic_params = try self.parseOptionalGenericParams();

        // Parse trait name or target type
        const first_type = try self.parseType();

        var trait_name: ?[]const u8 = null;
        var target_type: *Type = undefined;

        if (self.match(.for_keyword)) {
            // impl Trait for Type
            switch (first_type.kind) {
                .named => |n| trait_name = n.name,
                else => return self.reportError("expected trait name before 'for'", null),
            }
            target_type = try self.allocType(try self.parseType());
        } else {
            // impl Type (inherent impl)
            target_type = try self.allocType(first_type);
        }

        const where_clause = try self.parseOptionalWhereClause();

        // Parse impl body
        try self.consume(.left_brace, "expected '{' before impl body");
        self.skipNewlines();

        var methods = std.ArrayListUnmanaged(Declaration.FunctionDecl){};
        errdefer methods.deinit(self.allocator);

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            // Parse pub modifier if present
            const method_public = self.match(.pub_keyword);

            const is_effect = self.match(.effect);
            try self.consume(.fn_keyword, "expected 'fn' for impl method");

            const method = if (is_effect)
                try self.parseFunctionDeclBody(method_public, true)
            else
                try self.parseFunctionDeclBody(method_public, false);

            try methods.append(self.allocator, method);
            self.skipNewlines();
        }

        try self.consume(.right_brace, "expected '}' after impl body");

        return Declaration.ImplBlock{
            .trait_name = trait_name,
            .generic_params = generic_params,
            .target_type = target_type,
            .methods = try methods.toOwnedSlice(self.allocator),
            .where_clause = where_clause,
        };
    }

    fn parseConstDecl(self: *Parser, is_public: bool) ParseError!Declaration.ConstDecl {
        _ = self.advance(); // consume 'const'
        const name = try self.consumeIdentifier("expected constant name");

        try self.consume(.colon, "expected ':' after constant name");
        const const_type = try self.allocType(try self.parseType());

        try self.consume(.equal, "expected '=' after type annotation");
        const value = try self.allocExpr(try self.parseExpression());

        return Declaration.ConstDecl{
            .name = name,
            .const_type = const_type,
            .value = value,
            .is_public = is_public,
        };
    }

    fn parseLetDecl(self: *Parser, is_public: bool) ParseError!Declaration.LetDecl {
        _ = self.advance(); // consume 'let'
        const name = try self.consumeIdentifier("expected binding name");

        const generic_params = try self.parseOptionalGenericParams();

        try self.consume(.colon, "expected ':' after binding name");
        const binding_type = try self.allocType(try self.parseType());

        try self.consume(.equal, "expected '=' after type annotation");
        const value = try self.allocExpr(try self.parseExpression());

        return Declaration.LetDecl{
            .name = name,
            .generic_params = generic_params,
            .binding_type = binding_type,
            .value = value,
            .is_public = is_public,
        };
    }

    // =========================================================================
    // Type Parsing
    // =========================================================================

    fn parseType(self: *Parser) ParseError!Type {
        const start = self.peek().span;

        // Function type: fn(A, B) -> C
        if (self.check(.fn_keyword) or self.check(.effect)) {
            return self.parseFunctionType();
        }

        // Tuple type: (A, B, C)
        if (self.check(.left_paren)) {
            return self.parseTupleType();
        }

        // Array type: [T; N] or [T]
        if (self.check(.left_bracket)) {
            return self.parseArrayType();
        }

        // Self type
        if (self.match(.self_type)) {
            return Type.init(.self_type, self.makeSpan(start.start));
        }

        // Named type or primitive or generic
        const name = try self.consumeIdentifier("expected type name");

        // Check for primitive type
        if (Type.PrimitiveType.fromString(name)) |prim| {
            return Type.primitive(prim, self.makeSpan(start.start));
        }

        // Check for generic arguments: Type[A, B]
        if (self.match(.left_bracket)) {
            var args = std.ArrayListUnmanaged(*Type){};
            errdefer args.deinit(self.allocator);

            if (!self.check(.right_bracket)) {
                try args.append(self.allocator, try self.allocType(try self.parseType()));

                while (self.match(.comma)) {
                    if (self.check(.right_bracket)) break;
                    try args.append(self.allocator, try self.allocType(try self.parseType()));
                }
            }

            try self.consume(.right_bracket, "expected ']' after generic arguments");

            // Check for special effect types
            if (std.mem.eql(u8, name, "IO")) {
                if (args.items.len != 1) {
                    return self.reportError("IO type requires exactly one type argument", null);
                }
                return Type.init(.{ .io_type = args.items[0] }, self.makeSpan(start.start));
            }
            if (std.mem.eql(u8, name, "Result")) {
                if (args.items.len != 2) {
                    return self.reportError("Result type requires exactly two type arguments", null);
                }
                return Type.init(.{ .result_type = .{
                    .ok_type = args.items[0],
                    .err_type = args.items[1],
                } }, self.makeSpan(start.start));
            }
            if (std.mem.eql(u8, name, "Option")) {
                if (args.items.len != 1) {
                    return self.reportError("Option type requires exactly one type argument", null);
                }
                return Type.init(.{ .option_type = args.items[0] }, self.makeSpan(start.start));
            }

            return Type.init(.{ .generic = .{
                .base = name,
                .type_arguments = try args.toOwnedSlice(self.allocator),
            } }, self.makeSpan(start.start));
        }

        // Path type: std.list.List
        if (self.check(.dot)) {
            var segments = std.ArrayListUnmanaged([]const u8){};
            errdefer segments.deinit(self.allocator);
            try segments.append(self.allocator, name);

            while (self.match(.dot)) {
                const segment = try self.consumeIdentifier("expected type name after '.'");
                try segments.append(self.allocator, segment);
            }

            // Check for generic arguments on path type
            var generic_args: ?[]*Type = null;
            if (self.match(.left_bracket)) {
                var args = std.ArrayListUnmanaged(*Type){};
                errdefer args.deinit(self.allocator);

                if (!self.check(.right_bracket)) {
                    try args.append(self.allocator, try self.allocType(try self.parseType()));

                    while (self.match(.comma)) {
                        if (self.check(.right_bracket)) break;
                        try args.append(self.allocator, try self.allocType(try self.parseType()));
                    }
                }

                try self.consume(.right_bracket, "expected ']' after generic arguments");
                generic_args = try args.toOwnedSlice(self.allocator);
            }

            return Type.init(.{ .path = .{
                .segments = try segments.toOwnedSlice(self.allocator),
                .generic_args = generic_args,
            } }, self.makeSpan(start.start));
        }

        // Simple named type
        return Type.named(name, self.makeSpan(start.start));
    }

    fn parseFunctionType(self: *Parser) ParseError!Type {
        const start = self.peek().span;

        var effect: ?Type.EffectAnnotation = null;
        if (self.match(.effect)) {
            effect = .io;
        }

        try self.consume(.fn_keyword, "expected 'fn'");
        try self.consume(.left_paren, "expected '(' after 'fn'");

        var param_types = std.ArrayListUnmanaged(*Type){};
        errdefer param_types.deinit(self.allocator);

        if (!self.check(.right_paren)) {
            try param_types.append(self.allocator, try self.allocType(try self.parseType()));

            while (self.match(.comma)) {
                if (self.check(.right_paren)) break;
                try param_types.append(self.allocator, try self.allocType(try self.parseType()));
            }
        }

        try self.consume(.right_paren, "expected ')' after function parameters");
        try self.consume(.arrow, "expected '->' after function parameters");

        const return_type = try self.allocType(try self.parseType());

        return Type.init(.{ .function = .{
            .parameter_types = try param_types.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .effect_type = effect,
        } }, self.makeSpan(start.start));
    }

    fn parseTupleType(self: *Parser) ParseError!Type {
        const start = self.peek().span;
        try self.consume(.left_paren, "expected '('");

        var types = std.ArrayListUnmanaged(*Type){};
        errdefer types.deinit(self.allocator);

        if (!self.check(.right_paren)) {
            try types.append(self.allocator, try self.allocType(try self.parseType()));

            while (self.match(.comma)) {
                if (self.check(.right_paren)) break;
                try types.append(self.allocator, try self.allocType(try self.parseType()));
            }
        }

        try self.consume(.right_paren, "expected ')' after tuple types");

        return Type.init(.{ .tuple = .{
            .element_types = try types.toOwnedSlice(self.allocator),
        } }, self.makeSpan(start.start));
    }

    fn parseArrayType(self: *Parser) ParseError!Type {
        const start = self.peek().span;
        try self.consume(.left_bracket, "expected '['");

        const element_type = try self.allocType(try self.parseType());

        var size: ?u64 = null;
        if (self.match(.semicolon)) {
            // Fixed-size array: [T; N]
            if (!self.check(.integer_literal)) {
                return self.reportError("expected array size", null);
            }
            const size_tok = self.advance();
            size = @intCast(size_tok.literal_value.integer);
        }

        try self.consume(.right_bracket, "expected ']' after array type");

        return Type.init(.{ .array = .{
            .element_type = element_type,
            .size = size,
        } }, self.makeSpan(start.start));
    }

    // =========================================================================
    // Statement Parsing
    // =========================================================================

    fn parseStatement(self: *Parser) ParseError!Statement {
        const start = self.peek().span;

        // Let binding
        if (self.check(.let)) {
            return self.parseLetBinding();
        }

        // Var binding
        if (self.check(.var_keyword)) {
            return self.parseVarBinding();
        }

        // If statement
        if (self.check(.if_keyword)) {
            return self.parseIfStatement();
        }

        // For loop
        if (self.check(.for_keyword)) {
            return self.parseForLoop();
        }

        // Match statement
        if (self.check(.match)) {
            return self.parseMatchStatement();
        }

        // Return statement
        if (self.check(.return_keyword)) {
            return self.parseReturnStatement();
        }

        // Break statement
        if (self.check(.break_keyword)) {
            return self.parseBreakStatement();
        }

        // Block
        if (self.check(.left_brace)) {
            const block = try self.parseBlock();
            return Statement.init(.{ .block = block }, self.makeSpan(start.start));
        }

        // Expression statement or assignment
        const expr = try self.parseExpression();

        // Check for assignment
        if (self.match(.equal)) {
            const target = try self.exprToAssignmentTarget(expr);
            const value = try self.allocExpr(try self.parseExpression());
            return Statement.init(.{ .assignment = .{
                .target = target,
                .value = value,
            } }, self.makeSpan(start.start));
        }

        return Statement.init(.{ .expression_statement = try self.allocExpr(expr) }, self.makeSpan(start.start));
    }

    fn exprToAssignmentTarget(self: *Parser, expr: Expression) ParseError!Statement.AssignmentTarget {
        return switch (expr.kind) {
            .identifier => |id| .{ .identifier = id.name },
            .field_access => |fa| .{ .field_access = .{
                .object = fa.object,
                .field = fa.field,
            } },
            .index_access => |ia| .{ .index_access = .{
                .object = ia.object,
                .index = ia.index,
            } },
            else => self.reportError("invalid assignment target", null),
        };
    }

    fn parseLetBinding(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'let'

        const is_public = self.match(.pub_keyword);
        const pattern = try self.allocPattern(try self.parsePattern());

        try self.consume(.colon, "expected ':' after pattern");
        const explicit_type = try self.allocType(try self.parseType());

        try self.consume(.equal, "expected '=' after type");
        const initializer = try self.allocExpr(try self.parseExpression());

        return Statement.init(.{ .let_binding = .{
            .pattern = pattern,
            .explicit_type = explicit_type,
            .initializer = initializer,
            .is_public = is_public,
        } }, self.makeSpan(start.start));
    }

    fn parseVarBinding(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'var'

        const name = try self.consumeIdentifier("expected variable name");

        try self.consume(.colon, "expected ':' after variable name");
        const explicit_type = try self.allocType(try self.parseType());

        var initializer: ?*Expression = null;
        if (self.match(.equal)) {
            initializer = try self.allocExpr(try self.parseExpression());
        }

        return Statement.init(.{ .var_binding = .{
            .name = name,
            .explicit_type = explicit_type,
            .initializer = initializer,
        } }, self.makeSpan(start.start));
    }

    fn parseIfStatement(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'if'

        const condition = try self.allocExpr(try self.parseExpression());
        const then_branch = try self.parseBlock();

        var else_branch: ?Statement.ElseBranch = null;
        if (self.match(.else_keyword)) {
            if (self.check(.if_keyword)) {
                // else if
                const else_if_stmt = try self.allocStatement(try self.parseIfStatement());
                else_branch = .{ .else_if = else_if_stmt };
            } else {
                // else block
                else_branch = .{ .block = try self.parseBlock() };
            }
        }

        return Statement.init(.{ .if_statement = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } }, self.makeSpan(start.start));
    }

    fn parseForLoop(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'for'

        const pattern = try self.allocPattern(try self.parsePattern());

        try self.consume(.in_keyword, "expected 'in' after pattern");
        const iterable = try self.allocExpr(try self.parseExpression());
        const body = try self.parseBlock();

        return Statement.init(.{ .for_loop = .{
            .pattern = pattern,
            .iterable = iterable,
            .body = body,
        } }, self.makeSpan(start.start));
    }

    fn parseMatchStatement(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'match'

        const subject = try self.allocExpr(try self.parseExpression());

        try self.consume(.left_brace, "expected '{' after match subject");
        self.skipNewlines();

        var arms = std.ArrayListUnmanaged(Statement.MatchArm){};
        errdefer arms.deinit(self.allocator);

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            try arms.append(self.allocator, try self.parseStatementMatchArm());
            self.skipNewlines();
        }

        try self.consume(.right_brace, "expected '}' after match arms");

        return Statement.init(.{ .match_statement = .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.allocator),
        } }, self.makeSpan(start.start));
    }

    fn parseStatementMatchArm(self: *Parser) ParseError!Statement.MatchArm {
        const start = self.peek().span;
        const pattern = try self.allocPattern(try self.parsePattern());

        var guard: ?*Expression = null;
        if (self.match(.if_keyword)) {
            guard = try self.allocExpr(try self.parseExpression());
        }

        try self.consume(.fat_arrow, "expected '=>' after pattern");

        const body = try self.parseBlock();

        return Statement.MatchArm{
            .pattern = pattern,
            .guard = guard,
            .body = body,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseReturnStatement(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'return'

        var value: ?*Expression = null;

        // Check if there's a return value (not followed by newline/}/)
        if (!self.check(.newline) and !self.check(.right_brace) and !self.isAtEnd()) {
            value = try self.allocExpr(try self.parseExpression());
        }

        return Statement.init(.{ .return_statement = .{
            .value = value,
        } }, self.makeSpan(start.start));
    }

    fn parseBreakStatement(self: *Parser) ParseError!Statement {
        const start = self.peek().span;
        _ = self.advance(); // consume 'break'

        var label: ?[]const u8 = null;
        var value: ?*Expression = null;

        // Check for label
        if (self.check(.identifier)) {
            label = self.advance().lexeme;
        }

        // Check for value
        if (!self.check(.newline) and !self.check(.right_brace) and !self.isAtEnd()) {
            value = try self.allocExpr(try self.parseExpression());
        }

        return Statement.init(.{ .break_statement = .{
            .label = label,
            .value = value,
        } }, self.makeSpan(start.start));
    }

    fn parseBlock(self: *Parser) ParseError![]Statement {
        try self.consume(.left_brace, "expected '{'");
        self.skipNewlines();

        var statements = std.ArrayListUnmanaged(Statement){};
        errdefer statements.deinit(self.allocator);

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            try statements.append(self.allocator, try self.parseStatement());
            self.skipNewlines();
        }

        try self.consume(.right_brace, "expected '}'");

        return try statements.toOwnedSlice(self.allocator);
    }

    // =========================================================================
    // Expression Parsing
    // =========================================================================

    fn parseExpression(self: *Parser) ParseError!Expression {
        return self.parseOrExpr();
    }

    fn parseOrExpr(self: *Parser) ParseError!Expression {
        var left = try self.parseAndExpr();

        while (self.match(.or_keyword)) {
            const right = try self.allocExpr(try self.parseAndExpr());
            const left_ptr = try self.allocExpr(left);
            left = Expression.init(.{ .binary = .{
                .left = left_ptr,
                .operator = .logical_or,
                .right = right,
            } }, self.makeSpan(left.span.start));
        }

        return left;
    }

    fn parseAndExpr(self: *Parser) ParseError!Expression {
        var left = try self.parseEqualityExpr();

        while (self.match(.and_keyword)) {
            const right = try self.allocExpr(try self.parseEqualityExpr());
            const left_ptr = try self.allocExpr(left);
            left = Expression.init(.{ .binary = .{
                .left = left_ptr,
                .operator = .logical_and,
                .right = right,
            } }, self.makeSpan(left.span.start));
        }

        return left;
    }

    fn parseEqualityExpr(self: *Parser) ParseError!Expression {
        var left = try self.parseComparisonExpr();

        while (true) {
            const op: ?Expression.BinaryOperator = if (self.match(.equal_equal))
                .equal
            else if (self.match(.bang_equal))
                .not_equal
            else
                null;

            if (op) |operator| {
                const right = try self.allocExpr(try self.parseComparisonExpr());
                const left_ptr = try self.allocExpr(left);
                left = Expression.init(.{ .binary = .{
                    .left = left_ptr,
                    .operator = operator,
                    .right = right,
                } }, self.makeSpan(left.span.start));
            } else {
                break;
            }
        }

        return left;
    }

    fn parseComparisonExpr(self: *Parser) ParseError!Expression {
        var left = try self.parseAdditiveExpr();

        while (true) {
            const op: ?Expression.BinaryOperator = if (self.match(.less))
                .less_than
            else if (self.match(.greater))
                .greater_than
            else if (self.match(.less_equal))
                .less_equal
            else if (self.match(.greater_equal))
                .greater_equal
            else if (self.match(.is_keyword))
                .is
            else if (self.match(.in_keyword))
                .in_op
            else
                null;

            if (op) |operator| {
                const right = try self.allocExpr(try self.parseAdditiveExpr());
                const left_ptr = try self.allocExpr(left);
                left = Expression.init(.{ .binary = .{
                    .left = left_ptr,
                    .operator = operator,
                    .right = right,
                } }, self.makeSpan(left.span.start));
            } else {
                break;
            }
        }

        return left;
    }

    fn parseAdditiveExpr(self: *Parser) ParseError!Expression {
        var left = try self.parseMultiplicativeExpr();

        while (true) {
            const op: ?Expression.BinaryOperator = if (self.match(.plus))
                .add
            else if (self.match(.minus))
                .subtract
            else
                null;

            if (op) |operator| {
                const right = try self.allocExpr(try self.parseMultiplicativeExpr());
                const left_ptr = try self.allocExpr(left);
                left = Expression.init(.{ .binary = .{
                    .left = left_ptr,
                    .operator = operator,
                    .right = right,
                } }, self.makeSpan(left.span.start));
            } else {
                break;
            }
        }

        return left;
    }

    fn parseMultiplicativeExpr(self: *Parser) ParseError!Expression {
        var left = try self.parseUnaryExpr();

        while (true) {
            const op: ?Expression.BinaryOperator = if (self.match(.star))
                .multiply
            else if (self.match(.slash))
                .divide
            else if (self.match(.percent))
                .modulo
            else
                null;

            if (op) |operator| {
                const right = try self.allocExpr(try self.parseUnaryExpr());
                const left_ptr = try self.allocExpr(left);
                left = Expression.init(.{ .binary = .{
                    .left = left_ptr,
                    .operator = operator,
                    .right = right,
                } }, self.makeSpan(left.span.start));
            } else {
                break;
            }
        }

        return left;
    }

    fn parseUnaryExpr(self: *Parser) ParseError!Expression {
        const start = self.peek().span;

        if (self.match(.minus)) {
            const operand = try self.allocExpr(try self.parseUnaryExpr());
            return Expression.init(.{ .unary = .{
                .operator = .negate,
                .operand = operand,
            } }, self.makeSpan(start.start));
        }

        if (self.match(.not_keyword)) {
            const operand = try self.allocExpr(try self.parseUnaryExpr());
            return Expression.init(.{ .unary = .{
                .operator = .logical_not,
                .operand = operand,
            } }, self.makeSpan(start.start));
        }

        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) ParseError!Expression {
        var expr = try self.parsePrimaryExpr();

        while (true) {
            if (self.match(.dot)) {
                // Field access or method call or tuple access
                if (self.check(.integer_literal)) {
                    // Tuple access: expr.0
                    const idx_tok = self.advance();
                    const index: u32 = @intCast(idx_tok.literal_value.integer);
                    expr = Expression.init(.{ .tuple_access = .{
                        .tuple = try self.allocExpr(expr),
                        .index = index,
                    } }, self.makeSpan(expr.span.start));
                } else {
                    const field = try self.consumeIdentifier("expected field name");

                    // Check for method call with generic args
                    var generic_args: ?[]*Type = null;
                    if (self.match(.left_bracket)) {
                        generic_args = try self.parseTypeArguments();
                    }

                    if (self.check(.left_paren)) {
                        // Method call
                        _ = self.advance(); // consume '('
                        const args = try self.parseArguments();
                        try self.consume(.right_paren, "expected ')' after arguments");

                        expr = Expression.init(.{ .method_call = .{
                            .object = try self.allocExpr(expr),
                            .method = field,
                            .generic_args = generic_args,
                            .arguments = args,
                        } }, self.makeSpan(expr.span.start));
                    } else if (std.mem.eql(u8, field, "as") and self.match(.left_bracket)) {
                        // Type cast: expr.as[T]
                        const target_type = try self.allocType(try self.parseType());
                        try self.consume(.right_bracket, "expected ']' after type");

                        expr = Expression.init(.{ .type_cast = .{
                            .expression = try self.allocExpr(expr),
                            .target_type = target_type,
                        } }, self.makeSpan(expr.span.start));
                    } else {
                        // Field access
                        expr = Expression.init(.{ .field_access = .{
                            .object = try self.allocExpr(expr),
                            .field = field,
                        } }, self.makeSpan(expr.span.start));
                    }
                }
            } else if (self.match(.left_bracket)) {
                // Index access or generic arguments on call
                if (self.isTypeStart()) {
                    // Generic arguments followed by call
                    const type_args = try self.parseTypeArgumentsInner();
                    try self.consume(.right_bracket, "expected ']' after type arguments");

                    if (self.match(.left_paren)) {
                        const args = try self.parseArguments();
                        try self.consume(.right_paren, "expected ')' after arguments");

                        expr = Expression.init(.{ .function_call = .{
                            .callee = try self.allocExpr(expr),
                            .generic_args = type_args,
                            .arguments = args,
                        } }, self.makeSpan(expr.span.start));
                    } else {
                        // Identifier with generic args
                        switch (expr.kind) {
                            .identifier => |id| {
                                expr = Expression.init(.{ .identifier = .{
                                    .name = id.name,
                                    .generic_args = type_args,
                                } }, expr.span);
                            },
                            else => {
                                return self.reportError("unexpected type arguments", null);
                            },
                        }
                    }
                } else {
                    // Index access
                    const index = try self.allocExpr(try self.parseExpression());
                    try self.consume(.right_bracket, "expected ']' after index");

                    expr = Expression.init(.{ .index_access = .{
                        .object = try self.allocExpr(expr),
                        .index = index,
                    } }, self.makeSpan(expr.span.start));
                }
            } else if (self.match(.left_paren)) {
                // Function call
                const args = try self.parseArguments();
                try self.consume(.right_paren, "expected ')' after arguments");

                expr = Expression.init(.{ .function_call = .{
                    .callee = try self.allocExpr(expr),
                    .generic_args = null,
                    .arguments = args,
                } }, self.makeSpan(expr.span.start));
            } else if (self.match(.question)) {
                // Try expression: expr?
                expr = Expression.init(.{ .try_expr = try self.allocExpr(expr) }, self.makeSpan(expr.span.start));
            } else if (self.match(.question_question)) {
                // Null coalesce: expr ?? default
                const default = try self.allocExpr(try self.parseUnaryExpr());
                expr = Expression.init(.{ .null_coalesce = .{
                    .left = try self.allocExpr(expr),
                    .default = default,
                } }, self.makeSpan(expr.span.start));
            } else {
                break;
            }
        }

        return expr;
    }

    fn isTypeStart(self: *Parser) bool {
        // Check if current token could start a type
        const tok = self.peek();
        return tok.type == .identifier or
            tok.type == .fn_keyword or
            tok.type == .effect or
            tok.type == .left_paren or
            tok.type == .self_type;
    }

    fn parseTypeArguments(self: *Parser) ParseError!?[]*Type {
        const args = try self.parseTypeArgumentsInner();
        try self.consume(.right_bracket, "expected ']' after type arguments");
        return args;
    }

    fn parseTypeArgumentsInner(self: *Parser) ParseError!?[]*Type {
        var args = std.ArrayListUnmanaged(*Type){};
        errdefer args.deinit(self.allocator);

        if (!self.check(.right_bracket)) {
            try args.append(self.allocator, try self.allocType(try self.parseType()));

            while (self.match(.comma)) {
                if (self.check(.right_bracket)) break;
                try args.append(self.allocator, try self.allocType(try self.parseType()));
            }
        }

        return try args.toOwnedSlice(self.allocator);
    }

    fn parseArguments(self: *Parser) ParseError![]*Expression {
        var args = std.ArrayListUnmanaged(*Expression){};
        errdefer args.deinit(self.allocator);

        if (!self.check(.right_paren)) {
            try args.append(self.allocator, try self.allocExpr(try self.parseExpression()));

            while (self.match(.comma)) {
                if (self.check(.right_paren)) break;
                try args.append(self.allocator, try self.allocExpr(try self.parseExpression()));
            }
        }

        return try args.toOwnedSlice(self.allocator);
    }

    fn parsePrimaryExpr(self: *Parser) ParseError!Expression {
        const start = self.peek().span;

        // Integer literal
        if (self.check(.integer_literal)) {
            const tok = self.advance();
            const parsed = self.parseIntegerLiteral(tok.lexeme);
            return Expression.init(.{ .integer_literal = .{
                .value = parsed.value,
                .suffix = parsed.suffix,
            } }, tok.span);
        }

        // Float literal
        if (self.check(.float_literal)) {
            const tok = self.advance();
            const parsed = self.parseFloatLiteral(tok.lexeme);
            return Expression.init(.{ .float_literal = .{
                .value = parsed.value,
                .suffix = parsed.suffix,
            } }, tok.span);
        }

        // String literal
        if (self.check(.string_literal)) {
            const tok = self.advance();
            // TODO: Check for interpolated string
            return Expression.init(.{ .string_literal = .{
                .value = tok.lexeme,
            } }, tok.span);
        }

        // Char literal
        if (self.check(.char_literal)) {
            const tok = self.advance();
            return Expression.init(.{ .char_literal = .{
                .value = self.parseCharValue(tok.lexeme),
            } }, tok.span);
        }

        // Boolean literals
        if (self.match(.true_keyword)) {
            return Expression.init(.{ .bool_literal = true }, self.makeSpan(start.start));
        }
        if (self.match(.false_keyword)) {
            return Expression.init(.{ .bool_literal = false }, self.makeSpan(start.start));
        }

        // Self
        if (self.match(.self_keyword)) {
            return Expression.init(.self_expr, self.makeSpan(start.start));
        }

        // Self type as expression
        if (self.match(.self_type)) {
            return Expression.init(.self_type_expr, self.makeSpan(start.start));
        }

        // Closure: fn(params) -> ReturnType { body }
        if (self.check(.fn_keyword) or self.check(.effect)) {
            return self.parseClosure();
        }

        // Match expression
        if (self.check(.match)) {
            return self.parseMatchExpr();
        }

        // Tuple or grouped expression
        if (self.match(.left_paren)) {
            // Empty tuple
            if (self.match(.right_paren)) {
                return Expression.init(.{ .tuple_literal = .{
                    .elements = &[_]*Expression{},
                } }, self.makeSpan(start.start));
            }

            const first = try self.allocExpr(try self.parseExpression());

            // Check for tuple vs grouped
            if (self.match(.comma)) {
                // Tuple
                var elements = std.ArrayListUnmanaged(*Expression){};
                errdefer elements.deinit(self.allocator);
                try elements.append(self.allocator, first);

                if (!self.check(.right_paren)) {
                    try elements.append(self.allocator, try self.allocExpr(try self.parseExpression()));

                    while (self.match(.comma)) {
                        if (self.check(.right_paren)) break;
                        try elements.append(self.allocator, try self.allocExpr(try self.parseExpression()));
                    }
                }

                try self.consume(.right_paren, "expected ')' after tuple elements");
                return Expression.init(.{ .tuple_literal = .{
                    .elements = try elements.toOwnedSlice(self.allocator),
                } }, self.makeSpan(start.start));
            } else {
                // Grouped expression
                try self.consume(.right_paren, "expected ')'");
                return Expression.init(.{ .grouped = first }, self.makeSpan(start.start));
            }
        }

        // Array literal
        if (self.match(.left_bracket)) {
            var elements = std.ArrayListUnmanaged(*Expression){};
            errdefer elements.deinit(self.allocator);

            if (!self.check(.right_bracket)) {
                try elements.append(self.allocator, try self.allocExpr(try self.parseExpression()));

                while (self.match(.comma)) {
                    if (self.check(.right_bracket)) break;
                    try elements.append(self.allocator, try self.allocExpr(try self.parseExpression()));
                }
            }

            try self.consume(.right_bracket, "expected ']' after array elements");
            return Expression.init(.{ .array_literal = .{
                .elements = try elements.toOwnedSlice(self.allocator),
            } }, self.makeSpan(start.start));
        }

        // Record literal (anonymous): { field: value }
        if (self.check(.left_brace)) {
            return self.parseRecordLiteral(null);
        }

        // Range with no start: ..end or ..=end
        if (self.check(.dot_dot) or self.check(.dot_dot_equal)) {
            const inclusive = self.advance().type == .dot_dot_equal;
            const end_expr = try self.allocExpr(try self.parseAdditiveExpr());

            return Expression.init(.{ .range = .{
                .start = null,
                .end = end_expr,
                .inclusive = inclusive,
            } }, self.makeSpan(start.start));
        }

        // Identifier or variant constructor or record literal with type
        if (self.check(.identifier)) {
            const name = self.advance().lexeme;

            // Check for variant constructor: Some(x) or None
            if (isUpperCase(name[0])) {
                if (self.match(.left_paren)) {
                    // Variant with arguments
                    var args = std.ArrayListUnmanaged(*Expression){};
                    errdefer args.deinit(self.allocator);

                    if (!self.check(.right_paren)) {
                        try args.append(self.allocator, try self.allocExpr(try self.parseExpression()));

                        while (self.match(.comma)) {
                            if (self.check(.right_paren)) break;
                            try args.append(self.allocator, try self.allocExpr(try self.parseExpression()));
                        }
                    }

                    try self.consume(.right_paren, "expected ')' after variant arguments");
                    return Expression.init(.{ .variant_constructor = .{
                        .variant_name = name,
                        .arguments = try args.toOwnedSlice(self.allocator),
                    } }, self.makeSpan(start.start));
                } else if (self.check(.left_brace)) {
                    // Could be record literal OR variant without args followed by block.
                    // Check if { is followed by identifier: - if so, it's a record literal.
                    // Otherwise treat as variant constructor without args.
                    // For now, assume { after uppercase name is record literal (Point { x: 1 })
                    const type_expr = try self.allocExpr(Expression.init(.{ .identifier = .{
                        .name = name,
                        .generic_args = null,
                    } }, self.makeSpan(start.start)));
                    return self.parseRecordLiteral(type_expr);
                } else {
                    // Variant without arguments (like None)
                    return Expression.init(.{ .variant_constructor = .{
                        .variant_name = name,
                        .arguments = null,
                    } }, self.makeSpan(start.start));
                }
            }

            // Note: We do NOT parse lowercase identifier followed by { as record literal
            // because that would conflict with `match x { ... }` and similar constructs.
            // Record literals with type names should use uppercase: `Point { x: 1 }`
            // Anonymous record literals use just `{ x: 1 }`

            // Check for range: name..end or name..=end
            if (self.check(.dot_dot) or self.check(.dot_dot_equal)) {
                const inclusive = self.advance().type == .dot_dot_equal;

                var end_expr: ?*Expression = null;
                if (!self.check(.right_bracket) and !self.check(.right_paren) and
                    !self.check(.right_brace) and !self.check(.comma) and
                    !self.check(.newline) and !self.isAtEnd())
                {
                    end_expr = try self.allocExpr(try self.parseAdditiveExpr());
                }

                const start_expr = try self.allocExpr(Expression.init(.{ .identifier = .{
                    .name = name,
                    .generic_args = null,
                } }, self.makeSpan(start.start)));

                return Expression.init(.{ .range = .{
                    .start = start_expr,
                    .end = end_expr,
                    .inclusive = inclusive,
                } }, self.makeSpan(start.start));
            }

            // Plain identifier
            return Expression.init(.{ .identifier = .{
                .name = name,
                .generic_args = null,
            } }, self.makeSpan(start.start));
        }

        return self.reportError("expected expression", null);
    }

    fn parseClosure(self: *Parser) ParseError!Expression {
        const start = self.peek().span;

        const is_effect = self.match(.effect);
        try self.consume(.fn_keyword, "expected 'fn'");
        try self.consume(.left_paren, "expected '(' after 'fn'");

        var parameters = std.ArrayListUnmanaged(Expression.Parameter){};
        errdefer parameters.deinit(self.allocator);

        if (!self.check(.right_paren)) {
            try parameters.append(self.allocator, try self.parseClosureParam());

            while (self.match(.comma)) {
                if (self.check(.right_paren)) break;
                try parameters.append(self.allocator, try self.parseClosureParam());
            }
        }

        try self.consume(.right_paren, "expected ')' after closure parameters");
        try self.consume(.arrow, "expected '->' before return type");

        const return_type = try self.allocType(try self.parseType());
        const body = try self.parseBlock();

        return Expression.init(.{ .closure = .{
            .parameters = try parameters.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .is_effect = is_effect,
            .body = body,
        } }, self.makeSpan(start.start));
    }

    fn parseClosureParam(self: *Parser) ParseError!Expression.Parameter {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected parameter name");

        try self.consume(.colon, "expected ':' after parameter name");
        const param_type = try self.allocType(try self.parseType());

        return Expression.Parameter{
            .name = name,
            .param_type = param_type,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseMatchExpr(self: *Parser) ParseError!Expression {
        const start = self.peek().span;
        _ = self.advance(); // consume 'match'

        const subject = try self.allocExpr(try self.parseExpression());

        try self.consume(.left_brace, "expected '{' after match subject");
        self.skipNewlines();

        var arms = std.ArrayListUnmanaged(Expression.MatchArm){};
        errdefer arms.deinit(self.allocator);

        while (!self.check(.right_brace) and !self.isAtEnd()) {
            try arms.append(self.allocator, try self.parseExprMatchArm());
            self.skipNewlines();
        }

        try self.consume(.right_brace, "expected '}' after match arms");

        return Expression.init(.{ .match_expr = .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(self.allocator),
        } }, self.makeSpan(start.start));
    }

    fn parseExprMatchArm(self: *Parser) ParseError!Expression.MatchArm {
        const start = self.peek().span;
        const pattern = try self.allocPattern(try self.parsePattern());

        var guard: ?*Expression = null;
        if (self.match(.if_keyword)) {
            guard = try self.allocExpr(try self.parseExpression());
        }

        try self.consume(.fat_arrow, "expected '=>' after pattern");

        // Check if body is block or expression
        const body: Expression.MatchBody = if (self.check(.left_brace)) blk: {
            break :blk .{ .block = try self.parseBlock() };
        } else blk: {
            break :blk .{ .expression = try self.allocExpr(try self.parseExpression()) };
        };

        return Expression.MatchArm{
            .pattern = pattern,
            .guard = guard,
            .body = body,
            .span = self.makeSpan(start.start),
        };
    }

    fn parseRecordLiteral(self: *Parser, type_name: ?*Expression) ParseError!Expression {
        const start = if (type_name) |t| t.span.start else self.peek().span.start;

        try self.consume(.left_brace, "expected '{'");
        self.skipNewlines();

        var fields = std.ArrayListUnmanaged(Expression.FieldInit){};
        errdefer fields.deinit(self.allocator);

        if (!self.check(.right_brace)) {
            try fields.append(self.allocator, try self.parseFieldInit());
            self.skipNewlines();

            while (self.match(.comma)) {
                self.skipNewlines();
                if (self.check(.right_brace)) break;
                try fields.append(self.allocator, try self.parseFieldInit());
                self.skipNewlines();
            }
        }

        try self.consume(.right_brace, "expected '}'");

        return Expression.init(.{ .record_literal = .{
            .type_name = type_name,
            .fields = try fields.toOwnedSlice(self.allocator),
        } }, self.makeSpan(start));
    }

    fn parseFieldInit(self: *Parser) ParseError!Expression.FieldInit {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected field name");

        try self.consume(.colon, "expected ':' after field name");
        const value = try self.allocExpr(try self.parseExpression());

        return Expression.FieldInit{
            .name = name,
            .value = value,
            .span = self.makeSpan(start.start),
        };
    }

    // =========================================================================
    // Pattern Parsing
    // =========================================================================

    fn parsePattern(self: *Parser) ParseError!Pattern {
        return self.parseOrPattern();
    }

    fn parseOrPattern(self: *Parser) ParseError!Pattern {
        var left = try self.parsePrimaryPattern();

        while (self.match(.pipe)) {
            var patterns = std.ArrayListUnmanaged(*Pattern){};
            errdefer patterns.deinit(self.allocator);
            try patterns.append(self.allocator, try self.allocPattern(left));

            try patterns.append(self.allocator, try self.allocPattern(try self.parsePrimaryPattern()));

            while (self.match(.pipe)) {
                try patterns.append(self.allocator, try self.allocPattern(try self.parsePrimaryPattern()));
            }

            left = Pattern.init(.{ .or_pattern = .{
                .patterns = try patterns.toOwnedSlice(self.allocator),
            } }, left.span);
        }

        return left;
    }

    fn parsePrimaryPattern(self: *Parser) ParseError!Pattern {
        const start = self.peek().span;

        // Wildcard
        if (self.check(.identifier) and std.mem.eql(u8, self.peek().lexeme, "_")) {
            _ = self.advance();
            return Pattern.wildcard(self.makeSpan(start.start));
        }

        // Rest pattern (..)
        if (self.match(.dot_dot)) {
            return Pattern.init(.rest, self.makeSpan(start.start));
        }

        // Integer literal
        if (self.check(.integer_literal)) {
            const tok = self.advance();
            const value = tok.literal_value.integer;

            // Check for range pattern
            if (self.check(.dot_dot) or self.check(.dot_dot_equal)) {
                const inclusive = self.advance().type == .dot_dot_equal;

                var end: ?Pattern.RangeBound = null;
                if (self.check(.integer_literal)) {
                    end = .{ .integer = self.advance().literal_value.integer };
                }

                return Pattern.init(.{ .range = .{
                    .start = .{ .integer = value },
                    .end = end,
                    .inclusive = inclusive,
                } }, self.makeSpan(start.start));
            }

            return Pattern.init(.{ .integer_literal = value }, tok.span);
        }

        // Float literal
        if (self.check(.float_literal)) {
            const tok = self.advance();
            return Pattern.init(.{ .float_literal = tok.literal_value.float }, tok.span);
        }

        // String literal
        if (self.check(.string_literal)) {
            const tok = self.advance();
            return Pattern.init(.{ .string_literal = tok.lexeme }, tok.span);
        }

        // Char literal
        if (self.check(.char_literal)) {
            const tok = self.advance();
            const value = self.parseCharValue(tok.lexeme);

            // Check for range pattern
            if (self.check(.dot_dot) or self.check(.dot_dot_equal)) {
                const inclusive = self.advance().type == .dot_dot_equal;

                var end: ?Pattern.RangeBound = null;
                if (self.check(.char_literal)) {
                    end = .{ .char = self.parseCharValue(self.advance().lexeme) };
                }

                return Pattern.init(.{ .range = .{
                    .start = .{ .char = value },
                    .end = end,
                    .inclusive = inclusive,
                } }, self.makeSpan(start.start));
            }

            return Pattern.init(.{ .char_literal = value }, tok.span);
        }

        // Boolean literals
        if (self.match(.true_keyword)) {
            return Pattern.init(.{ .bool_literal = true }, self.makeSpan(start.start));
        }
        if (self.match(.false_keyword)) {
            return Pattern.init(.{ .bool_literal = false }, self.makeSpan(start.start));
        }

        // Tuple pattern: (a, b, c)
        if (self.match(.left_paren)) {
            var elements = std.ArrayListUnmanaged(*Pattern){};
            errdefer elements.deinit(self.allocator);

            if (!self.check(.right_paren)) {
                try elements.append(self.allocator, try self.allocPattern(try self.parsePattern()));

                while (self.match(.comma)) {
                    if (self.check(.right_paren)) break;
                    try elements.append(self.allocator, try self.allocPattern(try self.parsePattern()));
                }
            }

            try self.consume(.right_paren, "expected ')' after tuple pattern");
            return Pattern.init(.{ .tuple = .{
                .elements = try elements.toOwnedSlice(self.allocator),
            } }, self.makeSpan(start.start));
        }

        // Record pattern: { field: pattern } or Type { field: pattern }
        if (self.check(.left_brace)) {
            return self.parseRecordPattern(null);
        }

        // Identifier, constructor pattern, or mutable pattern
        if (self.check(.var_keyword)) {
            _ = self.advance(); // consume 'var'
            const name = try self.consumeIdentifier("expected identifier after 'var'");
            return Pattern.mutableIdentifier(name, self.makeSpan(start.start));
        }

        if (self.check(.identifier)) {
            const name = self.advance().lexeme;

            // Constructor pattern with arguments: Some(x)
            if (isUpperCase(name[0]) and self.match(.left_paren)) {
                var args = std.ArrayListUnmanaged(Pattern.PatternArg){};
                errdefer args.deinit(self.allocator);

                if (!self.check(.right_paren)) {
                    try args.append(self.allocator, .{ .positional = try self.allocPattern(try self.parsePattern()) });

                    while (self.match(.comma)) {
                        if (self.check(.right_paren)) break;
                        try args.append(self.allocator, .{ .positional = try self.allocPattern(try self.parsePattern()) });
                    }
                }

                try self.consume(.right_paren, "expected ')' after constructor arguments");
                return Pattern.init(.{ .constructor = .{
                    .type_path = null,
                    .variant_name = name,
                    .arguments = try args.toOwnedSlice(self.allocator),
                } }, self.makeSpan(start.start));
            }

            // Record pattern with type name: Point { x, y }
            if (isUpperCase(name[0]) and self.check(.left_brace)) {
                return self.parseRecordPattern(name);
            }

            // Constructor without arguments (like None)
            if (isUpperCase(name[0])) {
                return Pattern.init(.{ .constructor = .{
                    .type_path = null,
                    .variant_name = name,
                    .arguments = null,
                } }, self.makeSpan(start.start));
            }

            // Simple identifier pattern
            // Note: Typed patterns (x: Type) are NOT parsed here - the colon after a pattern
            // in let bindings is handled by the let binding parser, not the pattern parser
            return Pattern.identifier(name, self.makeSpan(start.start));
        }

        return self.reportError("expected pattern", null);
    }

    fn parseRecordPattern(self: *Parser, type_name: ?[]const u8) ParseError!Pattern {
        const start = self.peek().span;

        try self.consume(.left_brace, "expected '{'");
        self.skipNewlines();

        var fields = std.ArrayListUnmanaged(Pattern.RecordFieldPattern){};
        errdefer fields.deinit(self.allocator);
        var has_rest = false;

        if (!self.check(.right_brace)) {
            // Check for rest pattern
            if (self.check(.dot_dot)) {
                _ = self.advance();
                has_rest = true;
            } else {
                try fields.append(self.allocator, try self.parseRecordFieldPattern());
            }
            self.skipNewlines();

            while (self.match(.comma) and !has_rest) {
                self.skipNewlines();
                if (self.check(.right_brace)) break;

                // Check for rest pattern
                if (self.check(.dot_dot)) {
                    _ = self.advance();
                    has_rest = true;
                    break;
                }

                try fields.append(self.allocator, try self.parseRecordFieldPattern());
                self.skipNewlines();
            }
        }

        try self.consume(.right_brace, "expected '}'");

        return Pattern.init(.{ .record = .{
            .type_name = type_name,
            .fields = try fields.toOwnedSlice(self.allocator),
            .has_rest = has_rest,
        } }, self.makeSpan(start.start));
    }

    fn parseRecordFieldPattern(self: *Parser) ParseError!Pattern.RecordFieldPattern {
        const start = self.peek().span;
        const name = try self.consumeIdentifier("expected field name");

        var pattern: ?*Pattern = null;
        if (self.match(.colon)) {
            pattern = try self.allocPattern(try self.parsePattern());
        }

        return Pattern.RecordFieldPattern{
            .name = name,
            .pattern = pattern,
            .span = self.makeSpan(start.start),
        };
    }

    // =========================================================================
    // Helper Functions
    // =========================================================================

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) {
            self.current += 1;
        }
        return self.previous();
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }

    fn previous(self: *Parser) Token {
        return self.tokens[self.current - 1];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek().type == .eof;
    }

    fn check(self: *Parser, token_type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek().type == token_type;
    }

    fn match(self: *Parser, token_type: TokenType) bool {
        if (self.check(token_type)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn consume(self: *Parser, token_type: TokenType, message: []const u8) ParseError!void {
        if (self.check(token_type)) {
            _ = self.advance();
            return;
        }
        return self.reportError(message, token_type.toString());
    }

    fn consumeIdentifier(self: *Parser, message: []const u8) ParseError![]const u8 {
        if (self.check(.identifier)) {
            return self.advance().lexeme;
        }
        return self.reportError(message, "identifier");
    }

    fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) {
            _ = self.advance();
        }
    }

    fn makeSpan(self: *Parser, start: Location) Span {
        const end = if (self.current > 0) self.previous().span.end else self.peek().span.end;
        return Span{ .start = start, .end = end };
    }

    fn reportError(self: *Parser, message: []const u8, expected: ?[]const u8) ParseError {
        const tok = self.peek();
        try self.errors.append(self.allocator, ErrorInfo{
            .message = message,
            .span = tok.span,
            .expected = expected,
            .found = tok.type.toString(),
        });
        return ParseError.UnexpectedToken;
    }

    fn allocExpr(self: *Parser, expr: Expression) ParseError!*Expression {
        const ptr = self.allocator.create(Expression) catch return ParseError.OutOfMemory;
        ptr.* = expr;
        return ptr;
    }

    fn allocType(self: *Parser, t: Type) ParseError!*Type {
        const ptr = self.allocator.create(Type) catch return ParseError.OutOfMemory;
        ptr.* = t;
        return ptr;
    }

    fn allocPattern(self: *Parser, p: Pattern) ParseError!*Pattern {
        const ptr = self.allocator.create(Pattern) catch return ParseError.OutOfMemory;
        ptr.* = p;
        return ptr;
    }

    fn allocStatement(self: *Parser, s: Statement) ParseError!*Statement {
        const ptr = self.allocator.create(Statement) catch return ParseError.OutOfMemory;
        ptr.* = s;
        return ptr;
    }

    const ParsedInt = struct {
        value: i128,
        suffix: ?[]const u8,
    };

    fn parseIntegerLiteral(self: *Parser, lexeme: []const u8) ParsedInt {
        _ = self;
        var i: usize = 0;
        var base: u8 = 10;
        var value: i128 = 0;

        // Check for hex or binary prefix
        if (lexeme.len > 2 and lexeme[0] == '0') {
            if (lexeme[1] == 'x' or lexeme[1] == 'X') {
                base = 16;
                i = 2;
            } else if (lexeme[1] == 'b' or lexeme[1] == 'B') {
                base = 2;
                i = 2;
            }
        }

        // Parse digits
        while (i < lexeme.len) {
            const c = lexeme[i];
            if (c == '_') {
                i += 1;
                continue;
            }

            // Check for suffix start
            if (c == 'i' or c == 'u' or c == 'f') {
                break;
            }

            const digit: i128 = if (c >= '0' and c <= '9')
                c - '0'
            else if (c >= 'a' and c <= 'f')
                c - 'a' + 10
            else if (c >= 'A' and c <= 'F')
                c - 'A' + 10
            else
                break;

            value = value * base + digit;
            i += 1;
        }

        // Extract suffix
        const suffix: ?[]const u8 = if (i < lexeme.len) lexeme[i..] else null;

        return ParsedInt{ .value = value, .suffix = suffix };
    }

    const ParsedFloat = struct {
        value: f64,
        suffix: ?[]const u8,
    };

    fn parseFloatLiteral(self: *Parser, lexeme: []const u8) ParsedFloat {
        _ = self;
        // Find where the numeric part ends
        var end: usize = lexeme.len;
        for (lexeme, 0..) |c, j| {
            if (c == 'f') {
                end = j;
                break;
            }
        }

        // Remove underscores for parsing
        var buf: [64]u8 = undefined;
        var buf_len: usize = 0;
        for (lexeme[0..end]) |c| {
            if (c != '_') {
                if (buf_len < buf.len) {
                    buf[buf_len] = c;
                    buf_len += 1;
                }
            }
        }

        const value = std.fmt.parseFloat(f64, buf[0..buf_len]) catch 0.0;
        const suffix: ?[]const u8 = if (end < lexeme.len) lexeme[end..] else null;

        return ParsedFloat{ .value = value, .suffix = suffix };
    }

    fn parseCharValue(self: *Parser, lexeme: []const u8) u21 {
        _ = self;
        // Skip opening quote
        if (lexeme.len < 3) return 0;

        if (lexeme[1] == '\\' and lexeme.len >= 4) {
            // Escape sequence
            return switch (lexeme[2]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                '0' => 0,
                else => lexeme[2],
            };
        }

        return lexeme[1];
    }
};

fn isUpperCase(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

// =========================================================================
// Tests
// =========================================================================

test "parse simple let binding" {
    const source = "let x: i32 = 42";
    var lex = lexer.Lexer.init(source);

    // Use an arena allocator for AST nodes to avoid leak warnings
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const stmt = try parser.parseStatement();
    try std.testing.expect(stmt.kind == .let_binding);
}

test "parse function declaration" {
    const source = "fn add(a: i32, b: i32) -> i32 { return a + b }";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const decl = try parser.parseDeclaration();
    try std.testing.expect(decl.kind == .function_decl);
    try std.testing.expectEqualStrings("add", decl.kind.function_decl.name);
}

test "parse type declaration" {
    const source = "type Option[T] = | Some(T) | None";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const decl = try parser.parseDeclaration();
    try std.testing.expect(decl.kind == .type_decl);
    try std.testing.expectEqualStrings("Option", decl.kind.type_decl.name);
}

test "parse binary expression" {
    const source = "1 + 2 * 3";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    // Should be (1 + (2 * 3)) due to precedence
    try std.testing.expect(expr.kind == .binary);
    try std.testing.expect(expr.kind.binary.operator == .add);
}

test "parse match expression" {
    const source =
        \\match x {
        \\    Some(v) => v
        \\    None => 0
        \\}
    ;
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    try std.testing.expect(expr.kind == .match_expr);
    try std.testing.expectEqual(@as(usize, 2), expr.kind.match_expr.arms.len);
}

test "parse program" {
    const source =
        \\module example
        \\
        \\import std.io
        \\
        \\pub fn main() -> IO[void] {
        \\    println("Hello, World!")
        \\}
    ;
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expect(program.module_decl != null);
    try std.testing.expectEqual(@as(usize, 1), program.imports.len);
    try std.testing.expectEqual(@as(usize, 1), program.declarations.len);
}

test "parse if statement" {
    const source =
        \\if x > 0 {
        \\    return x
        \\} else {
        \\    return 0
        \\}
    ;
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const stmt = try parser.parseStatement();
    try std.testing.expect(stmt.kind == .if_statement);
    try std.testing.expect(stmt.kind.if_statement.else_branch != null);
}

test "parse for loop" {
    const source = "for x in items { println(x) }";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const stmt = try parser.parseStatement();
    try std.testing.expect(stmt.kind == .for_loop);
}

test "parse generic function" {
    const source = "fn identity[T](x: T) -> T { return x }";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const decl = try parser.parseDeclaration();
    try std.testing.expect(decl.kind == .function_decl);
    try std.testing.expect(decl.kind.function_decl.generic_params != null);
    try std.testing.expectEqual(@as(usize, 1), decl.kind.function_decl.generic_params.?.len);
}

test "parse trait declaration" {
    const source =
        \\trait Eq {
        \\    fn eq(self: Self, other: Self) -> bool
        \\}
    ;
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const decl = try parser.parseDeclaration();
    try std.testing.expect(decl.kind == .trait_decl);
    try std.testing.expectEqualStrings("Eq", decl.kind.trait_decl.name);
    try std.testing.expectEqual(@as(usize, 1), decl.kind.trait_decl.methods.len);
}

test "parse impl block" {
    const source =
        \\impl Eq for Point {
        \\    fn eq(self: Self, other: Self) -> bool {
        \\        return self.x == other.x and self.y == other.y
        \\    }
        \\}
    ;
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const decl = try parser.parseDeclaration();
    try std.testing.expect(decl.kind == .impl_block);
    try std.testing.expectEqualStrings("Eq", decl.kind.impl_block.trait_name.?);
}

test "parse product type" {
    const source = "type Point = { x: f64, y: f64 }";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const decl = try parser.parseDeclaration();
    try std.testing.expect(decl.kind == .type_decl);
    try std.testing.expect(decl.kind.type_decl.definition == .product_type);
    try std.testing.expectEqual(@as(usize, 2), decl.kind.type_decl.definition.product_type.fields.len);
}

test "parse closure" {
    const source = "fn(x: i32, y: i32) -> i32 { return x + y }";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    try std.testing.expect(expr.kind == .closure);
    try std.testing.expectEqual(@as(usize, 2), expr.kind.closure.parameters.len);
}

test "parse method call" {
    const source = "list.map(f)";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    try std.testing.expect(expr.kind == .method_call);
    try std.testing.expectEqualStrings("map", expr.kind.method_call.method);
}

test "parse variant constructor" {
    const source = "Some(42)";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    try std.testing.expect(expr.kind == .variant_constructor);
    try std.testing.expectEqualStrings("Some", expr.kind.variant_constructor.variant_name);
}

test "parse tuple literal" {
    const source = "(1, 2, 3)";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    try std.testing.expect(expr.kind == .tuple_literal);
    try std.testing.expectEqual(@as(usize, 3), expr.kind.tuple_literal.elements.len);
}

test "parse array literal" {
    const source = "[1, 2, 3, 4]";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const expr = try parser.parseExpression();
    try std.testing.expect(expr.kind == .array_literal);
    try std.testing.expectEqual(@as(usize, 4), expr.kind.array_literal.elements.len);
}

test "parse function type" {
    const source = "fn(i32, i32) -> bool";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const typ = try parser.parseType();
    try std.testing.expect(typ.kind == .function);
    try std.testing.expectEqual(@as(usize, 2), typ.kind.function.parameter_types.len);
}

test "parse generic type" {
    const source = "List[i32]";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const typ = try parser.parseType();
    try std.testing.expect(typ.kind == .generic);
    try std.testing.expectEqualStrings("List", typ.kind.generic.base);
}

test "parse import with items" {
    const source = "import std.io.{ print, println as log }";
    var lex = lexer.Lexer.init(source);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tokens = try lex.scanAllTokens(alloc);
    var parser = Parser.init(alloc, tokens.items);
    defer parser.deinit();

    const import_decl = try parser.parseImportDecl();
    try std.testing.expect(import_decl.items != null);
    try std.testing.expectEqual(@as(usize, 2), import_decl.items.?.len);
    try std.testing.expectEqualStrings("println", import_decl.items.?[1].name);
    try std.testing.expectEqualStrings("log", import_decl.items.?[1].alias.?);
}
