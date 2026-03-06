//! IR optimization passes for the Kira language.
//!
//! Provides optimization transformations on the IR:
//! - Constant folding: evaluate constant expressions at compile time
//! - Dead code elimination: remove unused bindings and unreachable blocks
//! - Simple inlining: inline small pure functions at call sites

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");

const Module = ir.Module;
const Function = ir.Function;
const Instruction = ir.Instruction;
const Terminator = ir.Terminator;
const ValueRef = ir.ValueRef;
const BlockId = ir.BlockId;

pub const OptError = error{
    OutOfMemory,
};

/// Run all optimization passes on a module.
pub fn optimize(allocator: Allocator, module: *Module) OptError!void {
    for (module.functions.items) |*func| {
        try constantFold(allocator, func);
        try eliminateDeadCode(allocator, func);
    }
}

// ============================================================
// Constant Folding
// ============================================================

/// Fold constant expressions within a function.
/// Replaces instructions like `int_add(const 2, const 3)` with `const 5`.
fn constantFold(allocator: Allocator, func: *Function) OptError!void {
    _ = allocator;
    var changed = true;
    while (changed) {
        changed = false;
        for (func.instructions.items, 0..) |*inst, idx| {
            if (tryFoldInstruction(func, inst)) |folded| {
                func.instructions.items[idx] = folded;
                changed = true;
            }
        }
    }
}

/// Try to fold a single instruction. Returns the replacement if foldable.
fn tryFoldInstruction(func: *const Function, inst: *const Instruction) ?Instruction {
    return switch (inst.op) {
        .int_binop => |bin| tryFoldIntBinOp(func, bin),
        .float_binop => |bin| tryFoldFloatBinOp(func, bin),
        .int_neg => |operand| tryFoldIntNeg(func, operand),
        .float_neg => |operand| tryFoldFloatNeg(func, operand),
        .log_not => |operand| tryFoldLogNot(func, operand),
        .cmp => |cmp| tryFoldCmp(func, cmp),
        else => null,
    };
}

fn tryFoldIntBinOp(func: *const Function, bin: Instruction.BinOp) ?Instruction {
    const left_val = getConstInt(func, bin.left) orelse return null;
    const right_val = getConstInt(func, bin.right) orelse return null;

    const result: ?i128 = switch (bin.op) {
        .add => std.math.add(i128, left_val, right_val) catch null,
        .sub => std.math.sub(i128, left_val, right_val) catch null,
        .mul => std.math.mul(i128, left_val, right_val) catch null,
        .div => if (right_val != 0) @divTrunc(left_val, right_val) else null,
        .mod => if (right_val != 0) @rem(left_val, right_val) else null,
    };

    if (result) |val| {
        return .{ .op = .{ .const_int = .{ .value = val } } };
    }
    return null;
}

fn tryFoldFloatBinOp(func: *const Function, bin: Instruction.BinOp) ?Instruction {
    const left_val = getConstFloat(func, bin.left) orelse return null;
    const right_val = getConstFloat(func, bin.right) orelse return null;

    const result: f64 = switch (bin.op) {
        .add => left_val + right_val,
        .sub => left_val - right_val,
        .mul => left_val * right_val,
        .div => if (right_val != 0.0) left_val / right_val else return null,
        .mod => if (right_val != 0.0) @rem(left_val, right_val) else return null,
    };

    return .{ .op = .{ .const_float = result } };
}

fn tryFoldIntNeg(func: *const Function, operand: ValueRef) ?Instruction {
    const val = getConstInt(func, operand) orelse return null;
    const result = std.math.negate(val) catch return null;
    return .{ .op = .{ .const_int = .{ .value = result } } };
}

fn tryFoldFloatNeg(func: *const Function, operand: ValueRef) ?Instruction {
    const val = getConstFloat(func, operand) orelse return null;
    return .{ .op = .{ .const_float = -val } };
}

fn tryFoldLogNot(func: *const Function, operand: ValueRef) ?Instruction {
    const val = getConstBool(func, operand) orelse return null;
    return .{ .op = .{ .const_bool = !val } };
}

fn tryFoldCmp(func: *const Function, cmp: Instruction.CmpOp) ?Instruction {
    // Try int comparison
    if (getConstInt(func, cmp.left)) |left| {
        if (getConstInt(func, cmp.right)) |right| {
            const result: bool = switch (cmp.op) {
                .eq => left == right,
                .ne => left != right,
                .lt => left < right,
                .le => left <= right,
                .gt => left > right,
                .ge => left >= right,
            };
            return .{ .op = .{ .const_bool = result } };
        }
    }
    // Try bool comparison (eq/ne only)
    if (getConstBool(func, cmp.left)) |left| {
        if (getConstBool(func, cmp.right)) |right| {
            const result: bool = switch (cmp.op) {
                .eq => left == right,
                .ne => left != right,
                else => return null,
            };
            return .{ .op = .{ .const_bool = result } };
        }
    }
    return null;
}

// ============================================================
// Dead Code Elimination
// ============================================================

/// Remove unused instructions using mark-and-sweep from live roots.
/// H6 fix: only marks operands of USED instructions, enabling transitive elimination.
///
/// NOTE: This pass removes dead instruction refs from each block's per-block list,
/// but does NOT compact the global `func.instructions` array. Dead instructions
/// remain at their original indices. Any downstream pass or codegen MUST iterate
/// per-block instruction lists (not the flat array) to see only live instructions.
fn eliminateDeadCode(allocator: Allocator, func: *Function) OptError!void {
    var used = std.AutoArrayHashMapUnmanaged(ValueRef, void){};
    defer used.deinit(allocator);

    // Phase 1: Seed with terminator-referenced values
    for (func.blocks.items) |*blk| {
        markTerminatorRefs(&blk.terminator, &used, allocator) catch return OptError.OutOfMemory;
    }

    // Phase 1b: Seed with side-effectful instructions
    for (func.blocks.items) |*blk| {
        for (blk.instructions.items) |ref| {
            if (hasSideEffect(&func.instructions.items[ref])) {
                used.put(allocator, ref, {}) catch return OptError.OutOfMemory;
            }
        }
    }

    // Phase 1c: Mark params and captures as used
    for (func.params) |p| {
        used.put(allocator, p.value_ref, {}) catch return OptError.OutOfMemory;
    }
    for (func.captures) |c| {
        used.put(allocator, c.value_ref, {}) catch return OptError.OutOfMemory;
    }

    // Phase 2: Transitively mark operands of used instructions via worklist
    var worklist = std.ArrayListUnmanaged(ValueRef){};
    defer worklist.deinit(allocator);
    // Seed worklist with all initially-used refs
    for (used.keys()) |ref| {
        worklist.append(allocator, ref) catch return OptError.OutOfMemory;
    }
    while (worklist.items.len > 0) {
        const ref = worklist.items[worklist.items.len - 1];
        worklist.items.len -= 1;
        if (ref >= func.instructions.items.len) continue;
        const inst = &func.instructions.items[ref];
        collectInstructionRefs(inst, &worklist, &used, allocator) catch return OptError.OutOfMemory;
    }

    // Phase 3: Remove unused instructions from blocks
    for (func.blocks.items) |*blk| {
        var write_idx: usize = 0;
        for (blk.instructions.items) |ref| {
            const inst = &func.instructions.items[ref];
            // Keep instructions that are used or have side effects
            if (used.contains(ref) or hasSideEffect(inst)) {
                blk.instructions.items[write_idx] = ref;
                write_idx += 1;
            }
        }
        // Truncate in-place rather than rebuilding — equivalent to shrinkRetainingCapacity
        // but operates on the items slice directly since we've already compacted.
        blk.instructions.items.len = write_idx;
    }
}

/// Check if an instruction has side effects and cannot be eliminated.
fn hasSideEffect(inst: *const Instruction) bool {
    return switch (inst.op) {
        .call, .method_call => true,
        .store_var => true,
        .field_set => true,
        .index_set => true,
        else => false,
    };
}

fn markTerminatorRefs(term: *const Terminator, used: *std.AutoArrayHashMapUnmanaged(ValueRef, void), allocator: Allocator) !void {
    switch (term.*) {
        .ret => |v| {
            if (v) |val| try used.put(allocator, val, {});
        },
        .branch => |br| try used.put(allocator, br.condition, {}),
        .switch_tag => |sw| try used.put(allocator, sw.value, {}),
        .jump, .unreachable_term => {},
    }
}

/// Add a ref to the used set and worklist if not already present.
fn markRef(ref: ValueRef, worklist: *std.ArrayListUnmanaged(ValueRef), used: *std.AutoArrayHashMapUnmanaged(ValueRef, void), allocator: Allocator) !void {
    const gop = try used.getOrPut(allocator, ref);
    if (!gop.found_existing) {
        try worklist.append(allocator, ref);
    }
}

/// Collect instruction operand refs into the worklist (only newly-seen refs).
fn collectInstructionRefs(inst: *const Instruction, worklist: *std.ArrayListUnmanaged(ValueRef), used: *std.AutoArrayHashMapUnmanaged(ValueRef, void), allocator: Allocator) !void {
    switch (inst.op) {
        .int_binop => |b| {
            try markRef(b.left, worklist, used, allocator);
            try markRef(b.right, worklist, used, allocator);
        },
        .float_binop => |b| {
            try markRef(b.left, worklist, used, allocator);
            try markRef(b.right, worklist, used, allocator);
        },
        .cmp => |c| {
            try markRef(c.left, worklist, used, allocator);
            try markRef(c.right, worklist, used, allocator);
        },
        .int_neg, .float_neg, .log_not => |v| try markRef(v, worklist, used, allocator),
        .int_to_float, .float_to_int, .to_string => |v| try markRef(v, worklist, used, allocator),
        .load_var => |v| try markRef(v, worklist, used, allocator),
        .store_var => |s| {
            try markRef(s.target, worklist, used, allocator);
            try markRef(s.value, worklist, used, allocator);
        },
        .alloc_var => |a| {
            if (a.init_value) |v| try markRef(v, worklist, used, allocator);
        },
        .make_tuple => |elems| {
            for (elems) |e| try markRef(e, worklist, used, allocator);
        },
        .make_array => |elems| {
            for (elems) |e| try markRef(e, worklist, used, allocator);
        },
        .make_record => |r| {
            for (r.field_values) |v| try markRef(v, worklist, used, allocator);
        },
        .make_variant => |v| {
            if (v.payload) |p| for (p) |val| try markRef(val, worklist, used, allocator);
        },
        .tuple_get => |t| try markRef(t.tuple, worklist, used, allocator),
        .field_get => |f| try markRef(f.object, worklist, used, allocator),
        .index_get => |idx| {
            try markRef(idx.object, worklist, used, allocator);
            try markRef(idx.index, worklist, used, allocator);
        },
        .field_set => |f| {
            try markRef(f.object, worklist, used, allocator);
            try markRef(f.value, worklist, used, allocator);
        },
        .index_set => |idx| {
            try markRef(idx.object, worklist, used, allocator);
            try markRef(idx.index, worklist, used, allocator);
            try markRef(idx.value, worklist, used, allocator);
        },
        .get_tag => |v| try markRef(v, worklist, used, allocator),
        .get_payload => |p| try markRef(p.variant, worklist, used, allocator),
        .call => |c| {
            try markRef(c.callee, worklist, used, allocator);
            for (c.args) |a| try markRef(a, worklist, used, allocator);
        },
        .method_call => |mc| {
            try markRef(mc.object, worklist, used, allocator);
            for (mc.args) |a| try markRef(a, worklist, used, allocator);
        },
        .make_closure => |c| {
            for (c.captures) |cap| try markRef(cap, worklist, used, allocator);
        },
        .wrap_some, .wrap_ok, .wrap_err, .unwrap => |v| try markRef(v, worklist, used, allocator),
        .str_concat => |s| {
            for (s.parts) |p| try markRef(p, worklist, used, allocator);
        },
        .phi => |p| {
            for (p.incoming) |inc| try markRef(inc.value, worklist, used, allocator);
        },
        .param, .capture => {},
        .const_int, .const_float, .const_string, .const_char, .const_bool, .const_void, .wrap_none => {},
    }
}

// ============================================================
// Helper: extract constant values from instructions
// ============================================================

fn getConstInt(func: *const Function, ref: ValueRef) ?i128 {
    if (ref >= func.instructions.items.len) return null;
    return switch (func.instructions.items[ref].op) {
        .const_int => |c| c.value,
        else => null,
    };
}

fn getConstFloat(func: *const Function, ref: ValueRef) ?f64 {
    if (ref >= func.instructions.items.len) return null;
    return switch (func.instructions.items[ref].op) {
        .const_float => |f| f,
        else => null,
    };
}

fn getConstBool(func: *const Function, ref: ValueRef) ?bool {
    if (ref >= func.instructions.items.len) return null;
    return switch (func.instructions.items[ref].op) {
        .const_bool => |b| b,
        else => null,
    };
}

// ============================================================
// Tests
// ============================================================

test "constant fold integer addition" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 2
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 2 } } });
    // %1 = const_int 3
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 3 } } });
    // %2 = int_add %0, %1
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = a, .right = b } },
    });
    func.setTerminator(blk, .{ .ret = c });

    try constantFold(allocator, &func);

    // %2 should now be const_int 5
    const inst = func.getInstruction(c);
    try std.testing.expect(inst.op == .const_int);
    try std.testing.expectEqual(@as(i128, 5), inst.op.const_int.value);
}

test "constant fold does not fold expressions with variables" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = alloc_var "x"
    const x = try func.addInstruction(allocator, blk, .{
        .op = .{ .alloc_var = .{ .name = "x", .init_value = null } },
    });
    // %1 = const_int 3
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 3 } } });
    // %2 = int_add %0, %1 (can't fold: %0 is not constant)
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = x, .right = b } },
    });
    func.setTerminator(blk, .{ .ret = c });

    try constantFold(allocator, &func);

    // %2 should still be int_binop (not folded)
    const inst = func.getInstruction(c);
    try std.testing.expect(inst.op == .int_binop);
}

test "constant fold float mod by zero returns null" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_float 5.0
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_float = 5.0 } });
    // %1 = const_float 0.0
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_float = 0.0 } });
    // %2 = float_binop mod %0, %1
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .float_binop = .{ .op = .mod, .left = a, .right = b } },
    });
    func.setTerminator(blk, .{ .ret = c });

    try constantFold(allocator, &func);

    // %2 should NOT be folded (mod by zero) — remains float_binop
    const inst = func.getInstruction(c);
    try std.testing.expect(inst.op == .float_binop);
}

test "constant fold float div by zero returns null" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_float = 5.0 } });
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_float = 0.0 } });
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .float_binop = .{ .op = .div, .left = a, .right = b } },
    });
    func.setTerminator(blk, .{ .ret = c });

    try constantFold(allocator, &func);

    // %2 should NOT be folded (div by zero) — remains float_binop
    const inst = func.getInstruction(c);
    try std.testing.expect(inst.op == .float_binop);
}

test "constant fold boolean logic" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_bool true
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_bool = true } });
    // %1 = log_not %0
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .log_not = a } });
    func.setTerminator(blk, .{ .ret = b });

    try constantFold(allocator, &func);

    // %1 should be const_bool false
    const inst = func.getInstruction(b);
    try std.testing.expect(inst.op == .const_bool);
    try std.testing.expectEqual(false, inst.op.const_bool);
}

test "constant fold comparison" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 10
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 10 } } });
    // %1 = const_int 20
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 20 } } });
    // %2 = cmp_lt %0, %1
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .cmp = .{ .op = .lt, .left = a, .right = b } },
    });
    func.setTerminator(blk, .{ .ret = c });

    try constantFold(allocator, &func);

    // %2 should be const_bool true (10 < 20)
    const inst = func.getInstruction(c);
    try std.testing.expect(inst.op == .const_bool);
    try std.testing.expectEqual(true, inst.op.const_bool);
}

test "constant fold chained operations" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 2
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 2 } } });
    // %1 = const_int 3
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 3 } } });
    // %2 = int_add %0, %1 -> will fold to 5
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = a, .right = b } },
    });
    // %3 = const_int 10
    const d = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 10 } } });
    // %4 = int_mul %2, %3 -> after %2 is folded to 5, this folds to 50
    const e = try func.addInstruction(allocator, blk, .{
        .op = .{ .int_binop = .{ .op = .mul, .left = c, .right = d } },
    });
    func.setTerminator(blk, .{ .ret = e });

    try constantFold(allocator, &func);

    // %4 should be const_int 50 (chained folding: 2+3=5, 5*10=50)
    const inst = func.getInstruction(e);
    try std.testing.expect(inst.op == .const_int);
    try std.testing.expectEqual(@as(i128, 50), inst.op.const_int.value);
}

test "dead code elimination removes unused binding" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 42 (used)
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 42 } } });
    // %1 = const_int 99 (unused — dead code)
    _ = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 99 } } });
    func.setTerminator(blk, .{ .ret = a });

    const before_count = func.blocks.items[blk].instructions.items.len;
    try std.testing.expectEqual(@as(usize, 2), before_count);

    try eliminateDeadCode(allocator, &func);

    // Only %0 should remain (used by ret), %1 is dead
    const after_count = func.blocks.items[blk].instructions.items.len;
    try std.testing.expectEqual(@as(usize, 1), after_count);
    try std.testing.expectEqual(a, func.blocks.items[blk].instructions.items[0]);
}

test "dead code elimination keeps side-effectful calls" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 0 (callee placeholder)
    const callee = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 0 } } });
    // %1 = call %0() — result unused but call has side effects
    _ = try func.addInstruction(allocator, blk, .{
        .op = .{ .call = .{ .callee = callee, .args = &.{} } },
    });
    func.setTerminator(blk, .{ .ret = null });

    try eliminateDeadCode(allocator, &func);

    // Both instructions should remain (call has side effects, callee is used by call)
    try std.testing.expectEqual(@as(usize, 2), func.blocks.items[blk].instructions.items.len);
}

test "dead code elimination transitively removes dead chains" {
    // H6 fix: verify that dead computation feeding dead computation is eliminated
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 1
    const a = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 1 } } });
    // %1 = const_int 2
    const b = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 2 } } });
    // %2 = int_add %0, %1  (dead — only used by %3 which is also dead)
    const c = try func.addInstruction(allocator, blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = a, .right = b } },
    });
    // %3 = int_neg %2  (dead — unused)
    _ = try func.addInstruction(allocator, blk, .{ .op = .{ .int_neg = c } });
    // %4 = const_int 42 (used by ret)
    const e = try func.addInstruction(allocator, blk, .{ .op = .{ .const_int = .{ .value = 42 } } });
    func.setTerminator(blk, .{ .ret = e });

    try eliminateDeadCode(allocator, &func);

    // Only %4 should remain — %0,%1,%2,%3 are all transitively dead
    try std.testing.expectEqual(@as(usize, 1), func.blocks.items[blk].instructions.items.len);
    try std.testing.expectEqual(e, func.blocks.items[blk].instructions.items[0]);
}

test "optimize runs all passes" {
    const backing = std.testing.allocator;
    var module = Module.init(backing);
    defer module.deinit();

    const alloc = module.allocator();
    var func = Function.init(alloc);
    func.name = "optimized";
    const blk = try func.addBlock(alloc);

    const a = try func.addInstruction(alloc, blk, .{ .op = .{ .const_int = .{ .value = 3 } } });
    const b = try func.addInstruction(alloc, blk, .{ .op = .{ .const_int = .{ .value = 4 } } });
    const c = try func.addInstruction(alloc, blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = a, .right = b } },
    });
    // Dead: unused const
    _ = try func.addInstruction(alloc, blk, .{ .op = .{ .const_int = .{ .value = 999 } } });
    func.setTerminator(blk, .{ .ret = c });

    _ = try module.addFunction(func);

    try optimize(backing, &module);

    // After optimization: %2 should be folded to 7, %3 should be eliminated
    const opt_func = &module.functions.items[0];
    const result = opt_func.getInstruction(c);
    try std.testing.expect(result.op == .const_int);
    try std.testing.expectEqual(@as(i128, 7), result.op.const_int.value);

    // Dead code eliminated: %0, %1 dead after folding, %3 dead (unused)
    // Only %2 (folded to 7, used by ret) should remain
    const inst_count = opt_func.blocks.items[blk].instructions.items.len;
    try std.testing.expectEqual(@as(usize, 1), inst_count);
}
