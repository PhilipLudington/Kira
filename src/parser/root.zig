//! Parser module for the Kira programming language.
//!
//! Transforms a stream of tokens into an Abstract Syntax Tree (AST).

const std = @import("std");

pub const parser = @import("parser.zig");

pub const Parser = parser.Parser;
pub const ParseError = parser.ParseError;
pub const ErrorInfo = parser.ErrorInfo;

test {
    _ = parser;
}
