//! AST (Abstract Syntax Tree) definitions for the Kira language.
//!
//! The AST represents the syntactic structure of Kira source code after parsing.
//! All nodes include source location information for error reporting.

const std = @import("std");
const lexer = @import("../lexer/root.zig");

pub const Span = lexer.Span;
pub const Location = lexer.Location;

// Re-export all node types
pub const Expression = @import("expression.zig").Expression;
pub const Statement = @import("statement.zig").Statement;
pub const Type = @import("types.zig").Type;
pub const Declaration = @import("declaration.zig").Declaration;
pub const Pattern = @import("pattern.zig").Pattern;
pub const Program = @import("program.zig").Program;

// Re-export the pretty printer
pub const PrettyPrinter = @import("pretty_printer.zig").PrettyPrinter;

test {
    _ = @import("expression.zig");
    _ = @import("statement.zig");
    _ = @import("types.zig");
    _ = @import("declaration.zig");
    _ = @import("pattern.zig");
    _ = @import("program.zig");
    _ = @import("pretty_printer.zig");
}
