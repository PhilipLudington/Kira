//! IR module for the Kira language.
//!
//! Provides the intermediate representation used between the AST (after type checking)
//! and code generation. The IR uses SSA-style values, basic blocks, and explicit
//! terminators to make analysis and optimization straightforward.

pub const ir = @import("ir.zig");
pub const lower = @import("lower.zig");
pub const ir_opt = @import("ir_opt.zig");

pub const Lowerer = lower.Lowerer;
pub const LowerError = lower.LowerError;
pub const optimizeIR = ir_opt.optimize;
pub const OptError = ir_opt.OptError;
// H9 fix: constantFold and eliminateDeadCode are implementation details;
// only optimizeIR is the public API.
pub const Module = ir.Module;
pub const Function = ir.Function;
pub const BasicBlock = ir.BasicBlock;
pub const Instruction = ir.Instruction;
pub const Terminator = ir.Terminator;
pub const ValueRef = ir.ValueRef;
pub const BlockId = ir.BlockId;
pub const Constant = ir.Constant;
pub const ConstValue = ir.ConstValue;
pub const TypeDecl = ir.TypeDecl;
pub const TypeDeclKind = ir.TypeDeclKind;
pub const SumTypeDecl = ir.SumTypeDecl;
pub const VariantDecl = ir.VariantDecl;
pub const ProductTypeDecl = ir.ProductTypeDecl;
pub const FieldDecl = ir.FieldDecl;

pub const no_value = ir.no_value;
pub const no_block = ir.no_block;

test {
    _ = ir;
    _ = lower;
    _ = ir_opt;
}
