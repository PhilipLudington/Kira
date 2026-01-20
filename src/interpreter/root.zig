//! Kira Language Interpreter
//!
//! Tree-walking interpreter for the Kira language.
//! Evaluates AST nodes to produce runtime values.

const std = @import("std");

pub const value = @import("value.zig");
pub const interpreter = @import("interpreter.zig");
pub const builtins = @import("builtins.zig");
pub const stdlib = @import("../stdlib/root.zig");
pub const tests = @import("tests.zig");

// Re-exports
pub const Value = value.Value;
pub const Environment = value.Environment;
pub const InterpreterError = value.InterpreterError;
pub const Interpreter = interpreter.Interpreter;
pub const registerBuiltins = builtins.registerBuiltins;
pub const registerStdlib = stdlib.registerStdlib;

test {
    _ = value;
    _ = interpreter;
    _ = builtins;
    _ = stdlib;
    _ = tests;
}
