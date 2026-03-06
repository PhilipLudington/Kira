//! AST-to-IR lowering pass for the Kira language.
//!
//! Converts a type-checked AST into the IR representation. The lowering
//! proceeds declaration-by-declaration: each function becomes an IR Function
//! with basic blocks. Expressions are lowered into SSA instructions within
//! the current block. Control flow (if/else, match, loops) creates new blocks
//! with appropriate terminators.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const ir = @import("ir.zig");

const log = std.log.scoped(.ir_lower);

const Expression = ast.Expression;
const Statement = ast.Statement;
const Declaration = ast.Declaration;
const Pattern = ast.Pattern;
const Program = ast.Program;
const Type = ast.Type;

const Module = ir.Module;
const Function = ir.Function;
const Instruction = ir.Instruction;
const Terminator = ir.Terminator;
const ValueRef = ir.ValueRef;
const BlockId = ir.BlockId;

pub const LowerError = error{
    OutOfMemory,
    UnsupportedExpression,
    UnsupportedStatement,
    UnsupportedDeclaration,
    UndefinedVariable,
    NoCurrentFunction,
};

/// Lowers a Kira AST Program into an IR Module.
pub const Lowerer = struct {
    allocator: Allocator,
    module: Module,
    /// Name -> ValueRef mapping for the current function scope.
    /// Pushed/popped on scope entry/exit.
    scope_stack: std.ArrayListUnmanaged(Scope),
    /// Index of the current function in module.functions (null when not lowering a function).
    /// Stored as an index rather than a pointer so that module.functions can grow
    /// (e.g. when a nested closure adds a function) without invalidating our handle.
    current_func_idx: ?u32,
    /// Current basic block where instructions are appended.
    current_block: BlockId,
    /// Target block for `break` statements (set by loop lowering).
    break_target: ?BlockId,
    /// ValueRefs known to produce float values (from param/capture type info).
    float_refs: std.AutoArrayHashMapUnmanaged(ValueRef, void),

    const Scope = std.StringArrayHashMapUnmanaged(ValueRef);

    pub fn init(allocator: Allocator) Lowerer {
        return .{
            .allocator = allocator,
            .module = Module.init(allocator),
            .scope_stack = .{},
            .current_func_idx = null,
            .current_block = ir.no_block,
            .break_target = null,
            .float_refs = .{},
        };
    }

    /// Get a mutable pointer to the current function being lowered.
    /// The pointer is derived from the index on each call, so it remains
    /// valid even after the module's function list has been reallocated.
    fn currentFunc(self: *Lowerer) ?*Function {
        const idx = self.current_func_idx orelse return null;
        return &self.module.functions.items[idx];
    }

    pub fn deinit(self: *Lowerer) void {
        for (self.scope_stack.items) |*s| s.deinit(self.allocator);
        self.scope_stack.deinit(self.allocator);
        self.float_refs.deinit(self.allocator);
        self.module.deinit();
    }

    /// Returns the arena allocator for all IR-internal allocations.
    fn irAlloc(self: *Lowerer) Allocator {
        return self.module.arena.allocator();
    }

    /// Lower an entire program. Returns the IR Module (caller owns it).
    pub fn lower(self: *Lowerer, program: *const Program) LowerError!Module {
        for (program.declarations) |*decl| {
            try self.lowerDeclaration(decl);
        }
        // Transfer ownership
        const result = self.module;
        self.module = Module.init(self.allocator);
        return result;
    }

    // ----------------------------------------------------------------
    // Declarations
    // ----------------------------------------------------------------

    fn lowerDeclaration(self: *Lowerer, decl: *const Declaration) LowerError!void {
        switch (decl.kind) {
            .function_decl => |*fd| try self.lowerFunctionDecl(fd),
            .const_decl => |*cd| try self.lowerConstDecl(cd),
            .type_decl => |*td| try self.lowerTypeDecl(td),
            .let_decl => |*ld| try self.lowerLetDecl(ld),
            .test_decl => |*td| try self.lowerTestDecl(td),
            // Traits, impls, modules, imports are compile-time only — nothing to emit
            .trait_decl, .impl_block, .module_decl, .import_decl => {},
        }
    }

    fn lowerFunctionDecl(self: *Lowerer, fd: *const Declaration.FunctionDecl) LowerError!void {
        const body = fd.body orelse return; // Signature-only (trait method) — skip
        const alloc = self.irAlloc();

        var func = Function.init(alloc);
        func.name = fd.name;
        func.is_effect = fd.is_effect;

        // Add to module first; all subsequent mutations go through the stored copy
        // via currentFunc(), which is safe even if the functions list reallocates.
        const func_idx = self.module.addFunction(func) catch return LowerError.OutOfMemory;
        self.current_func_idx = func_idx;
        errdefer self.current_func_idx = null;

        // Clear per-function float tracking (ValueRefs are function-local indices)
        self.float_refs.clearRetainingCapacity();

        // Create entry block (so param instructions can be emitted into it)
        self.current_block = self.currentFunc().?.addBlock(alloc) catch return LowerError.OutOfMemory;

        // Set up params as instructions (C5 fix: params get proper ValueRefs)
        var params = std.ArrayListUnmanaged(Function.Param){};
        try self.pushScope();
        errdefer self.popScope();

        for (fd.parameters, 0..) |param, i| {
            const vref = try self.emit(.{ .param = @intCast(i) });
            if (isAstTypeFloat(param.param_type)) try self.markFloat(vref);
            params.append(alloc, .{
                .name = param.name,
                .value_ref = vref,
            }) catch return LowerError.OutOfMemory;
            try self.defineVar(param.name, vref);
        }
        self.currentFunc().?.params = params.toOwnedSlice(alloc) catch return LowerError.OutOfMemory;

        // Lower body statements
        try self.lowerStatements(body);

        // If block has no terminator yet, add implicit void return
        if (self.currentFunc().?.blocks.items[self.current_block].terminator == .unreachable_term) {
            const void_ref = try self.emit(.{ .const_void = {} });
            self.setTerminator(.{ .ret = void_ref });
        }

        self.popScope();
        self.current_func_idx = null;
    }

    fn lowerConstDecl(self: *Lowerer, cd: *const Declaration.ConstDecl) LowerError!void {
        // Try to evaluate as a compile-time constant
        if (self.tryConstExpr(cd.value)) |cv| {
            _ = self.module.addConstant(.{
                .name = cd.name,
                .value = cv,
            }) catch return LowerError.OutOfMemory;
        }
        // If not a simple constant, it will be lowered as a global init function later
    }

    fn lowerTypeDecl(self: *Lowerer, td: *const Declaration.TypeDecl) LowerError!void {
        const alloc = self.irAlloc();
        const kind: ir.TypeDeclKind = switch (td.definition) {
            .sum_type => |st| blk: {
                var variants = std.ArrayListUnmanaged(ir.VariantDecl){};
                for (st.variants, 0..) |v, i| {
                    const field_count: u32 = if (v.fields) |fields| switch (fields) {
                        .tuple_fields => |tf| @intCast(tf.len),
                        .record_fields => |rf| @intCast(rf.len),
                    } else 0;
                    variants.append(alloc, .{
                        .name = v.name,
                        .tag = @intCast(i),
                        .field_count = field_count,
                    }) catch return LowerError.OutOfMemory;
                }
                break :blk .{ .sum_type = .{
                    .variants = variants.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
                } };
            },
            .product_type => |pt| blk: {
                var fields = std.ArrayListUnmanaged(ir.FieldDecl){};
                for (pt.fields, 0..) |f, i| {
                    fields.append(alloc, .{
                        .name = f.name,
                        .index = @intCast(i),
                    }) catch return LowerError.OutOfMemory;
                }
                break :blk .{ .product_type = .{
                    .fields = fields.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
                } };
            },
            .type_alias => return, // Type aliases are erased in IR
        };

        _ = self.module.addTypeDecl(.{
            .name = td.name,
            .kind = kind,
        }) catch return LowerError.OutOfMemory;
    }

    fn lowerLetDecl(_: *Lowerer, _: *const Declaration.LetDecl) LowerError!void {
        // Top-level let declarations with closures become functions
        // For now, a no-op (lowered as function wrapping in a future pass)
    }

    fn lowerTestDecl(self: *Lowerer, td: *const Declaration.TestDecl) LowerError!void {
        const alloc = self.irAlloc();

        // Lower test blocks as functions named "test:<name>"
        var func = Function.init(alloc);
        // Allocate a combined test name
        var name_buf = std.ArrayListUnmanaged(u8){};
        name_buf.appendSlice(alloc, "test:") catch return LowerError.OutOfMemory;
        name_buf.appendSlice(alloc, td.name) catch return LowerError.OutOfMemory;
        func.name = name_buf.toOwnedSlice(alloc) catch return LowerError.OutOfMemory;
        func.is_effect = true;

        // Add to module first, mutate through index
        const func_idx = self.module.addFunction(func) catch return LowerError.OutOfMemory;
        self.current_func_idx = func_idx;
        errdefer self.current_func_idx = null;

        try self.pushScope();
        errdefer self.popScope();
        self.current_block = self.currentFunc().?.addBlock(alloc) catch return LowerError.OutOfMemory;

        try self.lowerStatements(td.body);

        if (self.currentFunc().?.blocks.items[self.current_block].terminator == .unreachable_term) {
            const void_ref = try self.emit(.{ .const_void = {} });
            self.setTerminator(.{ .ret = void_ref });
        }

        self.popScope();
        self.current_func_idx = null;
    }

    // ----------------------------------------------------------------
    // Statements
    // ----------------------------------------------------------------

    fn lowerStatements(self: *Lowerer, stmts: []const Statement) LowerError!void {
        for (stmts) |*stmt| {
            try self.lowerStatement(stmt);
        }
    }

    fn lowerStatement(self: *Lowerer, stmt: *const Statement) LowerError!void {
        switch (stmt.kind) {
            .let_binding => |*lb| try self.lowerLetBinding(lb),
            .var_binding => |*vb| try self.lowerVarBinding(vb),
            .assignment => |*a| try self.lowerAssignment(a),
            .expression_statement => |expr| {
                _ = try self.lowerExpression(expr);
            },
            .return_statement => |*rs| {
                if (rs.value) |val| {
                    const v = try self.lowerExpression(val);
                    self.setTerminator(.{ .ret = v });
                } else {
                    self.setTerminator(.{ .ret = null });
                }
            },
            .if_statement => |*ifs| try self.lowerIfStatement(ifs),
            .for_loop => |*fl| try self.lowerForLoop(fl),
            .while_loop => |*wl| try self.lowerWhileLoop(wl),
            .loop_statement => |*ls| try self.lowerLoopStatement(ls),
            .match_statement => |*ms| try self.lowerMatchStatement(ms),
            .break_statement => {
                // C3 fix: jump to loop exit block instead of returning
                if (self.break_target) |target| {
                    self.setTerminator(.{ .jump = target });
                } else {
                    self.setTerminator(.{ .ret = null });
                }
            },
            .block => |stmts| {
                try self.pushScope();
                errdefer self.popScope();
                try self.lowerStatements(stmts);
                self.popScope();
            },
        }
    }

    fn lowerLetBinding(self: *Lowerer, lb: *const Statement.LetBinding) LowerError!void {
        const val = try self.lowerExpression(lb.initializer);
        // Simple identifier pattern — just bind the name
        switch (lb.pattern.kind) {
            .identifier => |id| try self.defineVar(id.name, val),
            .wildcard => {}, // Evaluate but don't bind
            else => {
                // Complex pattern — for now, just bind as-is
                // Full pattern lowering is in lowerMatchStatement
                try self.lowerPatternBindings(lb.pattern, val);
            },
        }
    }

    fn lowerVarBinding(self: *Lowerer, vb: *const Statement.VarBinding) LowerError!void {
        const init_val: ?ValueRef = if (vb.initializer) |init_expr| try self.lowerExpression(init_expr) else null;
        const slot = try self.emit(.{ .alloc_var = .{ .name = vb.name, .init_value = init_val } });
        try self.defineVar(vb.name, slot);
    }

    fn lowerAssignment(self: *Lowerer, a: *const Statement.Assignment) LowerError!void {
        const val = try self.lowerExpression(a.value);
        switch (a.target) {
            .identifier => |name| {
                const slot = self.lookupVar(name) orelse return LowerError.UndefinedVariable;
                _ = try self.emit(.{ .store_var = .{ .target = slot, .value = val } });
            },
            .field_access => |ft| {
                const obj = try self.lowerExpression(ft.object);
                _ = try self.emit(.{ .field_set = .{ .object = obj, .field = ft.field, .value = val } });
            },
            .index_access => |it| {
                const obj = try self.lowerExpression(it.object);
                const idx = try self.lowerExpression(it.index);
                _ = try self.emit(.{ .index_set = .{ .object = obj, .index = idx, .value = val } });
            },
        }
    }

    fn lowerIfStatement(self: *Lowerer, ifs: *const Statement.IfStatement) LowerError!void {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const cond = try self.lowerExpression(ifs.condition);

        const then_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const else_blk = if (ifs.else_branch != null)
            func.addBlock(alloc) catch return LowerError.OutOfMemory
        else
            merge_blk;

        self.setTerminator(.{ .branch = .{
            .condition = cond,
            .then_block = then_blk,
            .else_block = else_blk,
        } });

        // Then branch
        self.current_block = then_blk;
        try self.pushScope();
        errdefer self.popScope();
        try self.lowerStatements(ifs.then_branch);
        self.popScope();
        if (func.blocks.items[self.current_block].terminator == .unreachable_term) {
            self.setTerminator(.{ .jump = merge_blk });
        }

        // Else branch
        if (ifs.else_branch) |eb| {
            self.current_block = else_blk;
            try self.pushScope();
            errdefer self.popScope();
            switch (eb) {
                .block => |stmts| try self.lowerStatements(stmts),
                .else_if => |elif_stmt| try self.lowerStatement(elif_stmt),
            }
            self.popScope();
            if (func.blocks.items[self.current_block].terminator == .unreachable_term) {
                self.setTerminator(.{ .jump = merge_blk });
            }
        }

        self.current_block = merge_blk;
    }

    fn lowerWhileLoop(self: *Lowerer, wl: *const Statement.WhileLoop) LowerError!void {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();

        const cond_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const body_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const exit_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

        self.setTerminator(.{ .jump = cond_blk });

        // Condition block
        self.current_block = cond_blk;
        const cond = try self.lowerExpression(wl.condition);
        self.setTerminator(.{ .branch = .{
            .condition = cond,
            .then_block = body_blk,
            .else_block = exit_blk,
        } });

        // Body block (C3 fix: set break_target so break jumps to exit_blk)
        const saved_break = self.break_target;
        self.break_target = exit_blk;

        self.current_block = body_blk;
        try self.pushScope();
        errdefer self.popScope();
        try self.lowerStatements(wl.body);
        self.popScope();
        if (func.blocks.items[self.current_block].terminator == .unreachable_term) {
            self.setTerminator(.{ .jump = cond_blk });
        }

        self.break_target = saved_break;
        self.current_block = exit_blk;
    }

    fn lowerLoopStatement(self: *Lowerer, ls: *const Statement.LoopStatement) LowerError!void {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();

        const body_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const exit_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

        self.setTerminator(.{ .jump = body_blk });

        // C3 fix: set break_target so break jumps to exit_blk
        const saved_break = self.break_target;
        self.break_target = exit_blk;

        self.current_block = body_blk;
        try self.pushScope();
        errdefer self.popScope();
        try self.lowerStatements(ls.body);
        self.popScope();
        if (func.blocks.items[self.current_block].terminator == .unreachable_term) {
            self.setTerminator(.{ .jump = body_blk });
        }

        self.break_target = saved_break;
        self.current_block = exit_blk;
    }

    fn lowerForLoop(self: *Lowerer, fl: *const Statement.ForLoop) LowerError!void {
        // Iterator protocol is not yet implemented in the IR backend.
        _ = self;
        _ = fl;
        log.warn("for-loops are not yet supported in the IR backend", .{});
        return LowerError.UnsupportedStatement;
    }

    fn lowerMatchStatement(self: *Lowerer, ms: *const Statement.MatchStatement) LowerError!void {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const subject = try self.lowerExpression(ms.subject);

        if (ms.arms.len == 0) return;

        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

        // For each arm, create a block
        for (ms.arms) |*arm| {
            const arm_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
            const next_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

            // Generate condition check for this arm's pattern
            const matches = try self.lowerPatternCheck(arm.pattern, subject);

            // Apply guard if present
            const final_cond = if (arm.guard) |guard| blk: {
                const guard_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
                self.setTerminator(.{ .branch = .{
                    .condition = matches,
                    .then_block = guard_blk,
                    .else_block = next_blk,
                } });
                self.current_block = guard_blk;
                const guard_val = try self.lowerExpression(guard);
                break :blk guard_val;
            } else matches;

            self.setTerminator(.{ .branch = .{
                .condition = final_cond,
                .then_block = arm_blk,
                .else_block = next_blk,
            } });

            // Arm body
            self.current_block = arm_blk;
            try self.pushScope();
            errdefer self.popScope();
            try self.lowerPatternBindings(arm.pattern, subject);
            try self.lowerStatements(arm.body);
            self.popScope();
            if (func.blocks.items[self.current_block].terminator == .unreachable_term) {
                self.setTerminator(.{ .jump = merge_blk });
            }

            self.current_block = next_blk;
        }

        // After all arms (default unreachable)
        self.setTerminator(.{ .jump = merge_blk });
        self.current_block = merge_blk;
    }

    // ----------------------------------------------------------------
    // Expressions
    // ----------------------------------------------------------------

    fn lowerExpression(self: *Lowerer, expr: *const Expression) LowerError!ValueRef {
        return switch (expr.kind) {
            .integer_literal => |lit| self.emit(.{ .const_int = .{ .value = lit.value } }),
            .float_literal => |lit| self.emit(.{ .const_float = lit.value }),
            .string_literal => |lit| self.emit(.{ .const_string = lit.value }),
            .char_literal => |lit| self.emit(.{ .const_char = lit.value }),
            .bool_literal => |b| self.emit(.{ .const_bool = b }),
            .identifier => |id| {
                if (self.lookupVar(id.name)) |ref| return ref;
                return LowerError.UndefinedVariable;
            },
            .binary => |*bin| self.lowerBinaryOp(bin),
            .unary => |*un| self.lowerUnaryOp(un),
            .function_call => |*call| self.lowerFunctionCall(call),
            .method_call => |*mc| self.lowerMethodCall(mc),
            .field_access => |*fa| self.lowerFieldAccess(fa),
            .index_access => |*ia| self.lowerIndexAccess(ia),
            .tuple_access => |*ta| self.lowerTupleAccess(ta),
            .tuple_literal => |*tl| self.lowerTupleLiteral(tl),
            .array_literal => |*al| self.lowerArrayLiteral(al),
            .record_literal => |*rl| self.lowerRecordLiteral(rl),
            .variant_constructor => |*vc| self.lowerVariantConstructor(vc),
            .closure => |*cl| self.lowerClosure(cl),
            .if_expr => |*ie| self.lowerIfExpr(ie),
            .match_expr => |*me| self.lowerMatchExpr(me),
            .interpolated_string => |*is| self.lowerInterpolatedString(is),
            .grouped => |inner| self.lowerExpression(inner),
            .try_expr => |inner| self.lowerTryExpr(inner),
            .null_coalesce => |*nc| self.lowerNullCoalesce(nc),
            .type_cast => |*tc| {
                // Type casts are mostly erased in IR; the value passes through
                return self.lowerExpression(tc.expression);
            },
            .range => return LowerError.UnsupportedExpression,
            .self_expr, .self_type_expr => return LowerError.UnsupportedExpression,
        };
    }

    fn lowerBinaryOp(self: *Lowerer, bin: *const Expression.BinaryOp) LowerError!ValueRef {
        // Short-circuit for logical operators
        switch (bin.operator) {
            .logical_and => return self.lowerLogicalAnd(bin),
            .logical_or => return self.lowerLogicalOr(bin),
            else => {},
        }

        const left = try self.lowerExpression(bin.left);
        const right = try self.lowerExpression(bin.right);

        // C1 fix: choose int_binop vs float_binop based on operand types
        const is_float = self.isFloatValue(left) or self.isFloatValue(right);

        return switch (bin.operator) {
            .add => if (is_float)
                self.emit(.{ .float_binop = .{ .op = .add, .left = left, .right = right } })
            else
                self.emit(.{ .int_binop = .{ .op = .add, .left = left, .right = right } }),
            .subtract => if (is_float)
                self.emit(.{ .float_binop = .{ .op = .sub, .left = left, .right = right } })
            else
                self.emit(.{ .int_binop = .{ .op = .sub, .left = left, .right = right } }),
            .multiply => if (is_float)
                self.emit(.{ .float_binop = .{ .op = .mul, .left = left, .right = right } })
            else
                self.emit(.{ .int_binop = .{ .op = .mul, .left = left, .right = right } }),
            .divide => if (is_float)
                self.emit(.{ .float_binop = .{ .op = .div, .left = left, .right = right } })
            else
                self.emit(.{ .int_binop = .{ .op = .div, .left = left, .right = right } }),
            .modulo => if (is_float)
                self.emit(.{ .float_binop = .{ .op = .mod, .left = left, .right = right } })
            else
                self.emit(.{ .int_binop = .{ .op = .mod, .left = left, .right = right } }),
            .equal => self.emit(.{ .cmp = .{ .op = .eq, .left = left, .right = right } }),
            .not_equal => self.emit(.{ .cmp = .{ .op = .ne, .left = left, .right = right } }),
            .less_than => self.emit(.{ .cmp = .{ .op = .lt, .left = left, .right = right } }),
            .greater_than => self.emit(.{ .cmp = .{ .op = .gt, .left = left, .right = right } }),
            .less_equal => self.emit(.{ .cmp = .{ .op = .le, .left = left, .right = right } }),
            .greater_equal => self.emit(.{ .cmp = .{ .op = .ge, .left = left, .right = right } }),
            .logical_and, .logical_or => unreachable,
            .is, .in_op => return LowerError.UnsupportedExpression,
        };
    }

    fn lowerLogicalAnd(self: *Lowerer, bin: *const Expression.BinaryOp) LowerError!ValueRef {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const left = try self.lowerExpression(bin.left);

        const right_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const left_blk = self.current_block;

        self.setTerminator(.{ .branch = .{
            .condition = left,
            .then_block = right_blk,
            .else_block = merge_blk,
        } });

        self.current_block = right_blk;
        const right = try self.lowerExpression(bin.right);
        const right_end_blk = self.current_block;
        self.setTerminator(.{ .jump = merge_blk });

        // L1 fix: removed dead false_val emission
        self.current_block = merge_blk;
        const incoming = try alloc.alloc(Instruction.PhiIncoming, 2);
        incoming[0] = .{ .block = left_blk, .value = left };
        incoming[1] = .{ .block = right_end_blk, .value = right };
        return self.emit(.{ .phi = .{ .incoming = incoming } });
    }

    fn lowerLogicalOr(self: *Lowerer, bin: *const Expression.BinaryOp) LowerError!ValueRef {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const left = try self.lowerExpression(bin.left);

        const right_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const left_blk = self.current_block;

        self.setTerminator(.{ .branch = .{
            .condition = left,
            .then_block = merge_blk,
            .else_block = right_blk,
        } });

        self.current_block = right_blk;
        const right = try self.lowerExpression(bin.right);
        const right_end_blk = self.current_block;
        self.setTerminator(.{ .jump = merge_blk });

        self.current_block = merge_blk;
        const incoming = try alloc.alloc(Instruction.PhiIncoming, 2);
        incoming[0] = .{ .block = left_blk, .value = left };
        incoming[1] = .{ .block = right_end_blk, .value = right };
        return self.emit(.{ .phi = .{ .incoming = incoming } });
    }

    fn lowerUnaryOp(self: *Lowerer, un: *const Expression.UnaryOp) LowerError!ValueRef {
        const operand = try self.lowerExpression(un.operand);
        return switch (un.operator) {
            // C2 fix: choose int_neg vs float_neg based on operand type
            .negate => if (self.isFloatValue(operand))
                self.emit(.{ .float_neg = operand })
            else
                self.emit(.{ .int_neg = operand }),
            .logical_not => self.emit(.{ .log_not = operand }),
        };
    }

    fn lowerFunctionCall(self: *Lowerer, call: *const Expression.FunctionCall) LowerError!ValueRef {
        const alloc = self.irAlloc();
        const callee = try self.lowerExpression(call.callee);
        var args = std.ArrayListUnmanaged(ValueRef){};
        for (call.arguments) |arg| {
            args.append(alloc, try self.lowerExpression(arg)) catch return LowerError.OutOfMemory;
        }
        return self.emit(.{ .call = .{
            .callee = callee,
            .args = args.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
        } });
    }

    fn lowerMethodCall(self: *Lowerer, mc: *const Expression.MethodCall) LowerError!ValueRef {
        // L3 fix: use dedicated method_call instruction instead of call(const_string)
        const alloc = self.irAlloc();
        const obj = try self.lowerExpression(mc.object);
        var args = std.ArrayListUnmanaged(ValueRef){};
        for (mc.arguments) |arg| {
            args.append(alloc, try self.lowerExpression(arg)) catch return LowerError.OutOfMemory;
        }
        return self.emit(.{ .method_call = .{
            .object = obj,
            .method = mc.method,
            .args = args.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
        } });
    }

    fn lowerFieldAccess(self: *Lowerer, fa: *const Expression.FieldAccess) LowerError!ValueRef {
        const obj = try self.lowerExpression(fa.object);
        return self.emit(.{ .field_get = .{ .object = obj, .field = fa.field } });
    }

    fn lowerIndexAccess(self: *Lowerer, ia: *const Expression.IndexAccess) LowerError!ValueRef {
        const obj = try self.lowerExpression(ia.object);
        const idx = try self.lowerExpression(ia.index);
        return self.emit(.{ .index_get = .{ .object = obj, .index = idx } });
    }

    fn lowerTupleAccess(self: *Lowerer, ta: *const Expression.TupleAccess) LowerError!ValueRef {
        const tuple = try self.lowerExpression(ta.tuple);
        return self.emit(.{ .tuple_get = .{ .tuple = tuple, .index = ta.index } });
    }

    fn lowerTupleLiteral(self: *Lowerer, tl: *const Expression.TupleLiteral) LowerError!ValueRef {
        const alloc = self.irAlloc();
        var elems = std.ArrayListUnmanaged(ValueRef){};
        for (tl.elements) |elem| {
            elems.append(alloc, try self.lowerExpression(elem)) catch return LowerError.OutOfMemory;
        }
        return self.emit(.{ .make_tuple = elems.toOwnedSlice(alloc) catch return LowerError.OutOfMemory });
    }

    fn lowerArrayLiteral(self: *Lowerer, al: *const Expression.ArrayLiteral) LowerError!ValueRef {
        const alloc = self.irAlloc();
        var elems = std.ArrayListUnmanaged(ValueRef){};
        for (al.elements) |elem| {
            elems.append(alloc, try self.lowerExpression(elem)) catch return LowerError.OutOfMemory;
        }
        return self.emit(.{ .make_array = elems.toOwnedSlice(alloc) catch return LowerError.OutOfMemory });
    }

    fn lowerRecordLiteral(self: *Lowerer, rl: *const Expression.RecordLiteral) LowerError!ValueRef {
        const alloc = self.irAlloc();
        var names = std.ArrayListUnmanaged([]const u8){};
        var vals = std.ArrayListUnmanaged(ValueRef){};
        for (rl.fields) |field| {
            names.append(alloc, field.name) catch return LowerError.OutOfMemory;
            vals.append(alloc, try self.lowerExpression(field.value)) catch return LowerError.OutOfMemory;
        }
        const type_name: ?[]const u8 = if (rl.type_name) |tn|
            (switch (tn.kind) {
                .identifier => |id| id.name,
                else => null,
            })
        else
            null;
        return self.emit(.{ .make_record = .{
            .type_name = type_name,
            .field_names = names.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
            .field_values = vals.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
        } });
    }

    fn lowerVariantConstructor(self: *Lowerer, vc: *const Expression.VariantConstructor) LowerError!ValueRef {
        const alloc = self.irAlloc();
        const payload: ?[]const ValueRef = if (vc.arguments) |args| blk: {
            var vals = std.ArrayListUnmanaged(ValueRef){};
            for (args) |arg| {
                vals.append(alloc, try self.lowerExpression(arg)) catch return LowerError.OutOfMemory;
            }
            break :blk vals.toOwnedSlice(alloc) catch return LowerError.OutOfMemory;
        } else null;
        return self.emit(.{ .make_variant = .{
            .type_name = null,
            .variant_name = vc.variant_name,
            .payload = payload,
        } });
    }

    fn lowerClosure(self: *Lowerer, cl: *const Expression.Closure) LowerError!ValueRef {
        const alloc = self.irAlloc();

        // Create a new IR function for the closure body
        var func = Function.init(alloc);
        func.is_effect = cl.is_effect;

        // Add to module first, mutate through index. This is safe even if nested
        // closures cause the functions list to reallocate.
        const func_idx = self.module.addFunction(func) catch return LowerError.OutOfMemory;

        const saved_func_idx = self.current_func_idx;
        const saved_block = self.current_block;

        // H8: collect captures BEFORE switching function context, so we can
        // check outer float_refs for capture propagation.
        var capture_names = std.ArrayListUnmanaged([]const u8){};
        defer capture_names.deinit(self.allocator);
        var capture_refs = std.ArrayListUnmanaged(ValueRef){};
        defer capture_refs.deinit(self.allocator);
        try self.collectFreeVariables(cl.body, &capture_names, &capture_refs);

        // Record which captures are float-typed (from outer scope) before clearing
        var capture_is_float = std.ArrayListUnmanaged(bool){};
        defer capture_is_float.deinit(self.allocator);
        for (capture_refs.items) |outer_ref| {
            capture_is_float.append(self.allocator, self.float_refs.contains(outer_ref)) catch return LowerError.OutOfMemory;
        }

        // Switch to closure function context with fresh float tracking.
        // Use a nested block so errdefer cleanup is scoped to closure lowering only.
        const saved_float_refs = self.float_refs;
        self.float_refs = .{};

        self.current_func_idx = func_idx;

        const outer_capture_slice = closure_body: {
            errdefer {
                self.float_refs.deinit(self.allocator);
                self.float_refs = saved_float_refs;
                self.current_func_idx = saved_func_idx;
                self.current_block = saved_block;
            }

            self.current_block = self.currentFunc().?.addBlock(alloc) catch return LowerError.OutOfMemory;

            // C5 fix: use param instructions instead of freshValue
            var params = std.ArrayListUnmanaged(Function.Param){};
            try self.pushScope();
            errdefer self.popScope();

            for (cl.parameters, 0..) |param, i| {
                const vref = try self.emit(.{ .param = @intCast(i) });
                if (isAstTypeFloat(param.param_type)) try self.markFloat(vref);
                params.append(alloc, .{
                    .name = param.name,
                    .value_ref = vref,
                }) catch return LowerError.OutOfMemory;
                try self.defineVar(param.name, vref);
            }
            self.currentFunc().?.params = params.toOwnedSlice(alloc) catch return LowerError.OutOfMemory;

            // Define captures in the closure's scope, propagating float status
            var captures = std.ArrayListUnmanaged(Function.Capture){};
            for (capture_names.items, 0..) |name, i| {
                const cap_ref = try self.emit(.{ .capture = @intCast(i) });
                if (capture_is_float.items[i]) try self.markFloat(cap_ref);
                captures.append(alloc, .{
                    .name = name,
                    .value_ref = cap_ref,
                }) catch return LowerError.OutOfMemory;
                try self.defineVar(name, cap_ref);
            }
            self.currentFunc().?.captures = captures.toOwnedSlice(alloc) catch return LowerError.OutOfMemory;

            try self.lowerStatements(cl.body);

            if (self.currentFunc().?.blocks.items[self.current_block].terminator == .unreachable_term) {
                const void_ref = try self.emit(.{ .const_void = {} });
                self.setTerminator(.{ .ret = void_ref });
            }

            // Copy capture refs into the arena for the IR. The capture_refs list
            // itself is backed by self.allocator (freed by defer above).
            const arena_captures = alloc.dupe(ValueRef, capture_refs.items) catch return LowerError.OutOfMemory;
            break :closure_body arena_captures;
        };

        // Success: restore outer function context (errdefer is out of scope here)
        self.popScope();
        self.float_refs.deinit(self.allocator);
        self.float_refs = saved_float_refs;
        self.current_func_idx = saved_func_idx;
        self.current_block = saved_block;

        // Emit make_closure into the outer function
        return self.emit(.{ .make_closure = .{
            .function_index = func_idx,
            .captures = outer_capture_slice,
        } });
    }

    fn lowerIfExpr(self: *Lowerer, ie: *const Expression.IfExpr) LowerError!ValueRef {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const cond = try self.lowerExpression(ie.condition);

        const then_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const else_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

        self.setTerminator(.{ .branch = .{
            .condition = cond,
            .then_block = then_blk,
            .else_block = else_blk,
        } });

        // Then
        self.current_block = then_blk;
        const then_val = try self.lowerMatchBody(&ie.then_branch);
        const then_end = self.current_block;
        self.setTerminator(.{ .jump = merge_blk });

        // Else
        self.current_block = else_blk;
        const else_val = try self.lowerMatchBody(&ie.else_branch);
        const else_end = self.current_block;
        self.setTerminator(.{ .jump = merge_blk });

        // Merge with phi (arena-allocated so the slice outlives this stack frame)
        self.current_block = merge_blk;
        const incoming = alloc.alloc(Instruction.PhiIncoming, 2) catch return LowerError.OutOfMemory;
        incoming[0] = .{ .block = then_end, .value = then_val };
        incoming[1] = .{ .block = else_end, .value = else_val };
        return self.emit(.{ .phi = .{ .incoming = incoming } });
    }

    fn lowerMatchExpr(self: *Lowerer, me: *const Expression.MatchExpr) LowerError!ValueRef {
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const subject = try self.lowerExpression(me.subject);

        if (me.arms.len == 0) return self.emit(.{ .const_void = {} });

        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        var phi_entries = std.ArrayListUnmanaged(Instruction.PhiIncoming){};

        for (me.arms) |*arm| {
            const arm_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
            const next_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

            const matches = try self.lowerPatternCheck(arm.pattern, subject);

            const final_cond = if (arm.guard) |guard| blk: {
                const guard_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
                self.setTerminator(.{ .branch = .{
                    .condition = matches,
                    .then_block = guard_blk,
                    .else_block = next_blk,
                } });
                self.current_block = guard_blk;
                break :blk try self.lowerExpression(guard);
            } else matches;

            self.setTerminator(.{ .branch = .{
                .condition = final_cond,
                .then_block = arm_blk,
                .else_block = next_blk,
            } });

            self.current_block = arm_blk;
            try self.pushScope();
            errdefer self.popScope();
            try self.lowerPatternBindings(arm.pattern, subject);
            const arm_val = try self.lowerMatchBody(&arm.body);
            const arm_end = self.current_block;
            self.popScope();
            self.setTerminator(.{ .jump = merge_blk });

            phi_entries.append(alloc, .{
                .block = arm_end,
                .value = arm_val,
            }) catch return LowerError.OutOfMemory;

            self.current_block = next_blk;
        }

        // Default: unreachable (exhaustiveness checked by type checker)
        self.setTerminator(.{ .jump = merge_blk });

        self.current_block = merge_blk;
        if (phi_entries.items.len > 0) {
            return self.emit(.{ .phi = .{
                .incoming = phi_entries.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
            } });
        }
        return self.emit(.{ .const_void = {} });
    }

    fn lowerMatchBody(self: *Lowerer, body: *const Expression.MatchBody) LowerError!ValueRef {
        return switch (body.*) {
            .expression => |expr| self.lowerExpression(expr),
            .block => |stmts| {
                // L2 fix: track last expression value in block body
                try self.pushScope();
                errdefer self.popScope();
                if (stmts.len > 0) {
                    try self.lowerStatements(stmts[0 .. stmts.len - 1]);
                    const last = &stmts[stmts.len - 1];
                    switch (last.kind) {
                        .expression_statement => |expr| {
                            const val = try self.lowerExpression(expr);
                            self.popScope();
                            return val;
                        },
                        else => try self.lowerStatement(last),
                    }
                }
                self.popScope();
                return self.emit(.{ .const_void = {} });
            },
        };
    }

    fn lowerInterpolatedString(self: *Lowerer, is: *const Expression.InterpolatedString) LowerError!ValueRef {
        const alloc = self.irAlloc();
        var parts = std.ArrayListUnmanaged(ValueRef){};
        for (is.parts) |part| {
            const ref = switch (part) {
                .literal => |lit| try self.emit(.{ .const_string = lit }),
                .expression => |expr| blk: {
                    const val = try self.lowerExpression(expr);
                    break :blk try self.emit(.{ .to_string = val });
                },
            };
            parts.append(alloc, ref) catch return LowerError.OutOfMemory;
        }
        return self.emit(.{ .str_concat = .{
            .parts = parts.toOwnedSlice(alloc) catch return LowerError.OutOfMemory,
        } });
    }

    fn lowerTryExpr(self: *Lowerer, inner: *const Expression) LowerError!ValueRef {
        const val = try self.lowerExpression(inner);
        return self.emit(.{ .unwrap = val });
    }

    fn lowerNullCoalesce(self: *Lowerer, nc: *const Expression.NullCoalesce) LowerError!ValueRef {
        // Lower as: if (left != None) unwrap(left) else default
        const func = self.currentFunc().?;
        const alloc = self.irAlloc();
        const left = try self.lowerExpression(nc.left);

        // L4 fix: look up Some tag from type declarations, fall back to 0
        const some_tag = self.lookupVariantTag("Some", "Option") orelse 0;
        const tag = try self.emit(.{ .get_tag = left });
        const expected = try self.emit(.{ .const_int = .{ .value = some_tag } });
        const is_some = try self.emit(.{ .cmp = .{ .op = .eq, .left = tag, .right = expected } });

        const some_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const none_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;
        const merge_blk = func.addBlock(alloc) catch return LowerError.OutOfMemory;

        self.setTerminator(.{ .branch = .{
            .condition = is_some,
            .then_block = some_blk,
            .else_block = none_blk,
        } });

        self.current_block = some_blk;
        const unwrapped = try self.emit(.{ .unwrap = left });
        const some_end = self.current_block;
        self.setTerminator(.{ .jump = merge_blk });

        self.current_block = none_blk;
        const default_val = try self.lowerExpression(nc.default);
        const none_end = self.current_block;
        self.setTerminator(.{ .jump = merge_blk });

        self.current_block = merge_blk;
        const incoming = alloc.alloc(Instruction.PhiIncoming, 2) catch return LowerError.OutOfMemory;
        incoming[0] = .{ .block = some_end, .value = unwrapped };
        incoming[1] = .{ .block = none_end, .value = default_val };
        return self.emit(.{ .phi = .{ .incoming = incoming } });
    }

    // ----------------------------------------------------------------
    // Pattern lowering helpers
    // ----------------------------------------------------------------

    /// Generate a boolean ValueRef that is true if the pattern matches the subject.
    fn lowerPatternCheck(self: *Lowerer, pat: *const Pattern, subject: ValueRef) LowerError!ValueRef {
        return switch (pat.kind) {
            .wildcard, .identifier => self.emit(.{ .const_bool = true }),
            .bool_literal => |b| {
                const lit = try self.emit(.{ .const_bool = b });
                return self.emit(.{ .cmp = .{ .op = .eq, .left = subject, .right = lit } });
            },
            .integer_literal => |v| {
                const lit = try self.emit(.{ .const_int = .{ .value = v } });
                return self.emit(.{ .cmp = .{ .op = .eq, .left = subject, .right = lit } });
            },
            .string_literal => |s| {
                const lit = try self.emit(.{ .const_string = s });
                return self.emit(.{ .cmp = .{ .op = .eq, .left = subject, .right = lit } });
            },
            .constructor => |c| {
                // C6 fix: compare tag as integer, not string
                // Use type_path to scope the lookup to the correct sum type
                const type_name: ?[]const u8 = if (c.type_path) |tp| if (tp.len > 0) tp[0] else null else null;
                const tag = try self.emit(.{ .get_tag = subject });
                const tag_value = self.lookupVariantTag(c.variant_name, type_name) orelse 0;
                const expected_tag = try self.emit(.{ .const_int = .{ .value = tag_value } });
                return self.emit(.{ .cmp = .{ .op = .eq, .left = tag, .right = expected_tag } });
            },
            else => self.emit(.{ .const_bool = true }),
        };
    }

    /// Bind pattern variables to values extracted from the subject.
    fn lowerPatternBindings(self: *Lowerer, pat: *const Pattern, subject: ValueRef) LowerError!void {
        switch (pat.kind) {
            .identifier => |id| try self.defineVar(id.name, subject),
            .wildcard => {},
            .tuple => |t| {
                for (t.elements, 0..) |elem, i| {
                    const extracted = try self.emit(.{ .tuple_get = .{ .tuple = subject, .index = @intCast(i) } });
                    try self.lowerPatternBindings(elem, extracted);
                }
            },
            .constructor => |c| {
                if (c.arguments) |args| {
                    for (args, 0..) |arg, i| {
                        const field = try self.emit(.{ .get_payload = .{ .variant = subject, .field_index = @intCast(i) } });
                        const inner_pat = switch (arg) {
                            .positional => |p| p,
                            .named => |n| n.pattern,
                        };
                        try self.lowerPatternBindings(inner_pat, field);
                    }
                }
            },
            .record => |r| {
                for (r.fields) |field| {
                    const val = try self.emit(.{ .field_get = .{ .object = subject, .field = field.name } });
                    if (field.pattern) |inner| {
                        try self.lowerPatternBindings(inner, val);
                    } else {
                        try self.defineVar(field.name, val);
                    }
                }
            },
            .typed => |t| try self.lowerPatternBindings(t.pattern, subject),
            .or_pattern => |o| {
                // Or-patterns: the type checker enforces that all alternatives bind the
                // same names to the same types/positions, so extracting bindings from the
                // first alternative is correct. A more rigorous approach would emit phi
                // nodes for each alternative, but that is unnecessary given the invariant.
                if (o.patterns.len > 0) {
                    try self.lowerPatternBindings(o.patterns[0], subject);
                }
            },
            else => {},
        }
    }

    // ----------------------------------------------------------------
    // Type inspection helpers
    // ----------------------------------------------------------------

    /// Check if a ValueRef produces a float value (C1/C2 fix).
    fn isFloatValue(self: *Lowerer, ref: ValueRef) bool {
        if (self.float_refs.contains(ref)) return true;
        const func = self.currentFunc() orelse return false;
        if (ref >= func.instructions.items.len) return false;
        return switch (func.instructions.items[ref].op) {
            .const_float, .float_binop, .float_neg, .int_to_float => true,
            else => false,
        };
    }

    /// Check if an AST type is a float primitive.
    fn isAstTypeFloat(param_type: *const Type) bool {
        return switch (param_type.kind) {
            .primitive => |p| p.isFloat(),
            else => false,
        };
    }

    /// Register a ValueRef as float-typed (for params/captures with float types).
    fn markFloat(self: *Lowerer, ref: ValueRef) LowerError!void {
        self.float_refs.put(self.allocator, ref, {}) catch return LowerError.OutOfMemory;
    }

    /// Look up a variant's numeric tag from the module's type declarations (C6/L4 fix).
    /// When `type_name` is provided, the lookup is scoped to that specific sum type,
    /// avoiding ambiguity when multiple types define variants with the same name.
    fn lookupVariantTag(self: *Lowerer, variant_name: []const u8, type_name: ?[]const u8) ?i128 {
        for (self.module.type_decls.items) |td| {
            if (type_name) |tn| {
                if (!std.mem.eql(u8, td.name, tn)) continue;
            }
            switch (td.kind) {
                .sum_type => |st| {
                    for (st.variants) |v| {
                        if (std.mem.eql(u8, v.name, variant_name)) {
                            return @intCast(v.tag);
                        }
                    }
                },
                .product_type => {},
            }
        }
        return null;
    }

    /// H8: Collect free variable references in closure body statements.
    /// Walks the statements looking for identifiers that resolve in the current
    /// (outer) scope but are not parameters of the closure being built.
    fn collectFreeVariables(
        self: *Lowerer,
        stmts: []const Statement,
        names: *std.ArrayListUnmanaged([]const u8),
        refs: *std.ArrayListUnmanaged(ValueRef),
    ) LowerError!void {
        // Use the backing allocator (not the arena) because the caller owns
        // these lists and frees them with self.allocator.
        const alloc = self.allocator;
        for (stmts) |*stmt| {
            try self.collectFreeVarsInStmt(stmt, names, refs, alloc);
        }
    }

    fn collectFreeVarsInStmt(
        self: *Lowerer,
        stmt: *const Statement,
        names: *std.ArrayListUnmanaged([]const u8),
        refs: *std.ArrayListUnmanaged(ValueRef),
        alloc: Allocator,
    ) LowerError!void {
        switch (stmt.kind) {
            .expression_statement => |expr| try self.collectFreeVarsInExpr(expr, names, refs, alloc),
            .let_binding => |*lb| try self.collectFreeVarsInExpr(lb.initializer, names, refs, alloc),
            .var_binding => |*vb| {
                if (vb.initializer) |init_expr| try self.collectFreeVarsInExpr(init_expr, names, refs, alloc);
            },
            .return_statement => |*rs| {
                if (rs.value) |val| try self.collectFreeVarsInExpr(val, names, refs, alloc);
            },
            .assignment => |*a| try self.collectFreeVarsInExpr(a.value, names, refs, alloc),
            .block => |stmts| {
                for (stmts) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
            },
            .if_statement => |*ifs| {
                try self.collectFreeVarsInExpr(ifs.condition, names, refs, alloc);
                for (ifs.then_branch) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
                if (ifs.else_branch) |eb| switch (eb) {
                    .block => |stmts| {
                        for (stmts) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
                    },
                    .else_if => |elif| try self.collectFreeVarsInStmt(elif, names, refs, alloc),
                };
            },
            .for_loop => |*fl| {
                try self.collectFreeVarsInExpr(fl.iterable, names, refs, alloc);
                for (fl.body) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
            },
            .while_loop => |*wl| {
                try self.collectFreeVarsInExpr(wl.condition, names, refs, alloc);
                for (wl.body) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
            },
            .loop_statement => |*ls| {
                for (ls.body) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
            },
            .match_statement => |*ms| {
                try self.collectFreeVarsInExpr(ms.subject, names, refs, alloc);
                for (ms.arms) |*arm| {
                    if (arm.guard) |guard| try self.collectFreeVarsInExpr(guard, names, refs, alloc);
                    for (arm.body) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
                }
            },
            .break_statement => {},
        }
    }

    fn collectFreeVarsInExpr(
        self: *Lowerer,
        expr: *const Expression,
        names: *std.ArrayListUnmanaged([]const u8),
        refs: *std.ArrayListUnmanaged(ValueRef),
        alloc: Allocator,
    ) LowerError!void {
        switch (expr.kind) {
            .identifier => |id| {
                // Walk all current (outer) scopes to find captured variables.
                // At the point collectFreeVariables is called, the closure's own
                // scope has NOT been pushed yet, so all scopes on the stack belong
                // to the enclosing function/block.
                var i = self.scope_stack.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.scope_stack.items[i].get(id.name)) |ref| {
                        // Check it's not already captured
                        for (names.items) |n| {
                            if (std.mem.eql(u8, n, id.name)) return;
                        }
                        names.append(alloc, id.name) catch return LowerError.OutOfMemory;
                        refs.append(alloc, ref) catch return LowerError.OutOfMemory;
                        return;
                    }
                }
            },
            .binary => |*bin| {
                try self.collectFreeVarsInExpr(bin.left, names, refs, alloc);
                try self.collectFreeVarsInExpr(bin.right, names, refs, alloc);
            },
            .unary => |*un| try self.collectFreeVarsInExpr(un.operand, names, refs, alloc),
            .function_call => |*call| {
                try self.collectFreeVarsInExpr(call.callee, names, refs, alloc);
                for (call.arguments) |arg| try self.collectFreeVarsInExpr(arg, names, refs, alloc);
            },
            .method_call => |*mc| {
                try self.collectFreeVarsInExpr(mc.object, names, refs, alloc);
                for (mc.arguments) |arg| try self.collectFreeVarsInExpr(arg, names, refs, alloc);
            },
            .if_expr => |*ie| {
                try self.collectFreeVarsInExpr(ie.condition, names, refs, alloc);
                try self.collectFreeVarsInMatchBody(&ie.then_branch, names, refs, alloc);
                try self.collectFreeVarsInMatchBody(&ie.else_branch, names, refs, alloc);
            },
            .match_expr => |*me| {
                try self.collectFreeVarsInExpr(me.subject, names, refs, alloc);
                for (me.arms) |*arm| {
                    if (arm.guard) |guard| try self.collectFreeVarsInExpr(guard, names, refs, alloc);
                    try self.collectFreeVarsInMatchBody(&arm.body, names, refs, alloc);
                }
            },
            .closure => |*cl| {
                // When recursing into a nested closure, any identifier that matches
                // the inner closure's own parameter is locally bound — not a free
                // variable of the outer closure. Record the pre-recurse count so we
                // can filter spurious captures added during the walk.
                const pre_count = names.items.len;
                for (cl.body) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
                // Remove captures that match inner closure parameters (walk backward)
                var j: usize = names.items.len;
                while (j > pre_count) {
                    j -= 1;
                    for (cl.parameters) |p| {
                        if (std.mem.eql(u8, names.items[j], p.name)) {
                            _ = names.orderedRemove(j);
                            _ = refs.orderedRemove(j);
                            break;
                        }
                    }
                }
            },
            .field_access => |*fa| try self.collectFreeVarsInExpr(fa.object, names, refs, alloc),
            .index_access => |*ia| {
                try self.collectFreeVarsInExpr(ia.object, names, refs, alloc);
                try self.collectFreeVarsInExpr(ia.index, names, refs, alloc);
            },
            .tuple_access => |*ta| try self.collectFreeVarsInExpr(ta.tuple, names, refs, alloc),
            .tuple_literal => |*tl| {
                for (tl.elements) |elem| try self.collectFreeVarsInExpr(elem, names, refs, alloc);
            },
            .array_literal => |*al| {
                for (al.elements) |elem| try self.collectFreeVarsInExpr(elem, names, refs, alloc);
            },
            .record_literal => |*rl| {
                if (rl.type_name) |tn| try self.collectFreeVarsInExpr(tn, names, refs, alloc);
                for (rl.fields) |field| try self.collectFreeVarsInExpr(field.value, names, refs, alloc);
            },
            .variant_constructor => |*vc| {
                if (vc.arguments) |args| {
                    for (args) |arg| try self.collectFreeVarsInExpr(arg, names, refs, alloc);
                }
            },
            .type_cast => |*tc| try self.collectFreeVarsInExpr(tc.expression, names, refs, alloc),
            .range => |*r| {
                if (r.start) |start| try self.collectFreeVarsInExpr(start, names, refs, alloc);
                if (r.end) |end| try self.collectFreeVarsInExpr(end, names, refs, alloc);
            },
            .grouped => |inner| try self.collectFreeVarsInExpr(inner, names, refs, alloc),
            .interpolated_string => |*is| {
                for (is.parts) |part| {
                    switch (part) {
                        .expression => |e| try self.collectFreeVarsInExpr(e, names, refs, alloc),
                        .literal => {},
                    }
                }
            },
            .try_expr => |inner| try self.collectFreeVarsInExpr(inner, names, refs, alloc),
            .null_coalesce => |*nc| {
                try self.collectFreeVarsInExpr(nc.left, names, refs, alloc);
                try self.collectFreeVarsInExpr(nc.default, names, refs, alloc);
            },
            // Literals and self have no sub-expressions
            .integer_literal, .float_literal, .string_literal, .char_literal, .bool_literal, .self_expr, .self_type_expr => {},
        }
    }

    fn collectFreeVarsInMatchBody(
        self: *Lowerer,
        body: *const Expression.MatchBody,
        names: *std.ArrayListUnmanaged([]const u8),
        refs: *std.ArrayListUnmanaged(ValueRef),
        alloc: Allocator,
    ) LowerError!void {
        switch (body.*) {
            .expression => |e| try self.collectFreeVarsInExpr(e, names, refs, alloc),
            .block => |stmts| {
                for (stmts) |*s| try self.collectFreeVarsInStmt(s, names, refs, alloc);
            },
        }
    }

    // ----------------------------------------------------------------
    // Scope / variable management
    // ----------------------------------------------------------------

    fn pushScope(self: *Lowerer) LowerError!void {
        self.scope_stack.append(self.allocator, .{}) catch return LowerError.OutOfMemory;
    }

    fn popScope(self: *Lowerer) void {
        if (self.scope_stack.items.len > 0) {
            var scope = self.scope_stack.pop() orelse return;
            scope.deinit(self.allocator);
        }
    }

    fn defineVar(self: *Lowerer, name: []const u8, ref: ValueRef) LowerError!void {
        if (self.scope_stack.items.len == 0) return;
        var scope = &self.scope_stack.items[self.scope_stack.items.len - 1];
        scope.put(self.allocator, name, ref) catch return LowerError.OutOfMemory;
    }

    fn lookupVar(self: *Lowerer, name: []const u8) ?ValueRef {
        // Walk scopes from inner to outer
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].get(name)) |ref| return ref;
        }
        return null;
    }

    // ----------------------------------------------------------------
    // Instruction emission helpers
    // ----------------------------------------------------------------

    fn emit(self: *Lowerer, op: Instruction.Op) LowerError!ValueRef {
        const func = self.currentFunc() orelse return LowerError.NoCurrentFunction;
        return func.addInstruction(self.irAlloc(), self.current_block, .{ .op = op }) catch return LowerError.OutOfMemory;
    }

    fn setTerminator(self: *Lowerer, term: Terminator) void {
        const func = self.currentFunc() orelse return;
        func.setTerminator(self.current_block, term);
    }

    /// Try to evaluate an expression as a compile-time constant.
    fn tryConstExpr(self: *Lowerer, expr: *const Expression) ?ir.ConstValue {
        _ = self;
        return switch (expr.kind) {
            .integer_literal => |lit| .{ .integer = lit.value },
            .float_literal => |lit| .{ .float = lit.value },
            .string_literal => |lit| .{ .string = lit.value },
            .char_literal => |lit| .{ .char = lit.value },
            .bool_literal => |b| .{ .boolean = b },
            else => null,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "lower integer literal" {
    const backing = std.testing.allocator;
    var lowerer = Lowerer.init(backing);
    defer lowerer.deinit();

    const alloc = lowerer.irAlloc();

    // Set up a function context via module (same pattern as production code)
    var func = Function.init(alloc);
    func.name = "test_fn";
    const func_idx = lowerer.module.addFunction(func) catch unreachable;
    lowerer.current_func_idx = func_idx;
    const blk = lowerer.currentFunc().?.addBlock(alloc) catch unreachable;
    lowerer.current_block = blk;
    lowerer.pushScope() catch unreachable;

    // Create a fake integer literal expression
    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 3, .offset = 2 },
    };
    const expr = Expression.init(.{ .integer_literal = .{ .value = 42, .suffix = null } }, span);

    const ref = try lowerer.lowerExpression(&expr);
    try std.testing.expectEqual(@as(ValueRef, 0), ref);

    const inst = lowerer.currentFunc().?.getInstruction(ref);
    try std.testing.expect(inst.op == .const_int);
    try std.testing.expectEqual(@as(i128, 42), inst.op.const_int.value);

    lowerer.popScope();
    // No func.deinit needed — arena handles cleanup via lowerer.deinit()
}

test "lower binary operation" {
    const backing = std.testing.allocator;
    var lowerer = Lowerer.init(backing);
    defer lowerer.deinit();

    const alloc = lowerer.irAlloc();

    var func = Function.init(alloc);
    func.name = "test_add";
    const func_idx = lowerer.module.addFunction(func) catch unreachable;
    lowerer.current_func_idx = func_idx;
    const blk = lowerer.currentFunc().?.addBlock(alloc) catch unreachable;
    lowerer.current_block = blk;
    lowerer.pushScope() catch unreachable;

    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    // Build: 10 + 20
    var left = Expression.init(.{ .integer_literal = .{ .value = 10, .suffix = null } }, span);
    var right = Expression.init(.{ .integer_literal = .{ .value = 20, .suffix = null } }, span);
    const add_expr = Expression.init(.{
        .binary = .{
            .left = &left,
            .operator = .add,
            .right = &right,
        },
    }, span);

    const ref = try lowerer.lowerExpression(&add_expr);
    // %0 = const_int 10, %1 = const_int 20, %2 = int_add %0 %1
    try std.testing.expectEqual(@as(ValueRef, 2), ref);

    const inst = lowerer.currentFunc().?.getInstruction(ref);
    try std.testing.expect(inst.op == .int_binop);
    try std.testing.expect(inst.op.int_binop.op == .add);

    lowerer.popScope();
}

test "lower float binary operation" {
    const backing = std.testing.allocator;
    var lowerer = Lowerer.init(backing);
    defer lowerer.deinit();

    const alloc = lowerer.irAlloc();

    var func = Function.init(alloc);
    func.name = "test_float_add";
    const func_idx = lowerer.module.addFunction(func) catch unreachable;
    lowerer.current_func_idx = func_idx;
    const blk = lowerer.currentFunc().?.addBlock(alloc) catch unreachable;
    lowerer.current_block = blk;
    lowerer.pushScope() catch unreachable;

    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    // Build: 1.5 + 2.5
    var left = Expression.init(.{ .float_literal = .{ .value = 1.5, .suffix = null } }, span);
    var right = Expression.init(.{ .float_literal = .{ .value = 2.5, .suffix = null } }, span);
    const add_expr = Expression.init(.{
        .binary = .{
            .left = &left,
            .operator = .add,
            .right = &right,
        },
    }, span);

    const ref = try lowerer.lowerExpression(&add_expr);
    const inst = lowerer.currentFunc().?.getInstruction(ref);
    // C1 fix: should produce float_binop, not int_binop
    try std.testing.expect(inst.op == .float_binop);
    try std.testing.expect(inst.op.float_binop.op == .add);

    lowerer.popScope();
}

test "lower let binding" {
    const backing = std.testing.allocator;
    var lowerer = Lowerer.init(backing);
    defer lowerer.deinit();

    const alloc = lowerer.irAlloc();

    var func = Function.init(alloc);
    func.name = "test_let";
    const func_idx = lowerer.module.addFunction(func) catch unreachable;
    lowerer.current_func_idx = func_idx;
    const blk = lowerer.currentFunc().?.addBlock(alloc) catch unreachable;
    lowerer.current_block = blk;
    lowerer.pushScope() catch unreachable;

    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 5, .offset = 4 },
    };

    // let x: i32 = 42
    var initializer = Expression.init(.{ .integer_literal = .{ .value = 42, .suffix = null } }, span);
    var pattern = Pattern.identifier("x", span);
    var type_node = ast.Type.primitive(.i32, span);
    const let_binding = Statement.LetBinding{
        .pattern = &pattern,
        .explicit_type = &type_node,
        .initializer = &initializer,
        .is_public = false,
    };

    try lowerer.lowerLetBinding(&let_binding);

    // Check that "x" is now bound
    const x_ref = lowerer.lookupVar("x");
    try std.testing.expect(x_ref != null);
    try std.testing.expectEqual(@as(ValueRef, 0), x_ref.?);

    lowerer.popScope();
}

test "lower function call" {
    const backing = std.testing.allocator;
    var lowerer = Lowerer.init(backing);
    defer lowerer.deinit();

    const alloc = lowerer.irAlloc();

    var func = Function.init(alloc);
    func.name = "test_call";
    const func_idx = lowerer.module.addFunction(func) catch unreachable;
    lowerer.current_func_idx = func_idx;
    const blk = lowerer.currentFunc().?.addBlock(alloc) catch unreachable;
    lowerer.current_block = blk;
    lowerer.pushScope() catch unreachable;

    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    // Define "f" in scope
    const f_ref = lowerer.currentFunc().?.addInstruction(alloc, blk, .{
        .op = .{ .const_int = .{ .value = 0 } },
    }) catch unreachable;
    lowerer.defineVar("f", f_ref) catch unreachable;

    // f(42)
    var callee = Expression.init(.{ .identifier = .{ .name = "f", .generic_args = null } }, span);
    var arg = Expression.init(.{ .integer_literal = .{ .value = 42, .suffix = null } }, span);
    var args_arr = [_]*Expression{&arg};
    const call_expr = Expression.init(.{
        .function_call = .{
            .callee = &callee,
            .generic_args = null,
            .arguments = &args_arr,
        },
    }, span);

    const ref = try lowerer.lowerExpression(&call_expr);
    const inst = lowerer.currentFunc().?.getInstruction(ref);
    try std.testing.expect(inst.op == .call);
    try std.testing.expectEqual(@as(usize, 1), inst.op.call.args.len);

    // No manual free needed — arena handles cleanup via lowerer.deinit()

    lowerer.popScope();
}

test "lower nested expressions" {
    const backing = std.testing.allocator;
    var lowerer = Lowerer.init(backing);
    defer lowerer.deinit();

    const alloc = lowerer.irAlloc();

    var func = Function.init(alloc);
    func.name = "test_nested";
    const func_idx = lowerer.module.addFunction(func) catch unreachable;
    lowerer.current_func_idx = func_idx;
    const blk = lowerer.currentFunc().?.addBlock(alloc) catch unreachable;
    lowerer.current_block = blk;
    lowerer.pushScope() catch unreachable;

    const span = ast.Span{
        .start = .{ .line = 1, .column = 1, .offset = 0 },
        .end = .{ .line = 1, .column = 10, .offset = 9 },
    };

    // (1 + 2) * 3
    var one = Expression.init(.{ .integer_literal = .{ .value = 1, .suffix = null } }, span);
    var two = Expression.init(.{ .integer_literal = .{ .value = 2, .suffix = null } }, span);
    var three = Expression.init(.{ .integer_literal = .{ .value = 3, .suffix = null } }, span);
    var add = Expression.init(.{ .binary = .{ .left = &one, .operator = .add, .right = &two } }, span);
    const mul = Expression.init(.{ .binary = .{ .left = &add, .operator = .multiply, .right = &three } }, span);

    const ref = try lowerer.lowerExpression(&mul);
    // %0=1, %1=2, %2=add, %3=3, %4=mul
    try std.testing.expectEqual(@as(ValueRef, 4), ref);

    const inst = lowerer.currentFunc().?.getInstruction(ref);
    try std.testing.expect(inst.op == .int_binop);
    try std.testing.expect(inst.op.int_binop.op == .mul);

    lowerer.popScope();
}
