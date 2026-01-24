//! Tree-walking interpreter for the Kira language.
//!
//! Evaluates AST nodes directly to produce runtime values.
//! Assumes all type checking and effect checking has passed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const symbols = @import("../symbols/root.zig");
const value_mod = @import("value.zig");

const Expression = ast.Expression;
const Statement = ast.Statement;
const Declaration = ast.Declaration;
const Pattern = ast.Pattern;
const Program = ast.Program;
const SymbolTable = symbols.SymbolTable;

pub const Value = value_mod.Value;
pub const Environment = value_mod.Environment;
pub const InterpreterError = value_mod.InterpreterError;

/// Control flow signal for return statements
const ReturnValue = struct {
    value: Value,
};

/// Control flow signal for break statements
const BreakValue = struct {
    label: ?[]const u8,
    value: ?Value,
};

/// The Kira interpreter.
pub const Interpreter = struct {
    allocator: Allocator,
    symbol_table: *SymbolTable,
    global_env: Environment,
    return_value: ?Value,
    break_signal: ?BreakValue,

    /// Arena for temporary allocations during interpretation
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, symbol_table: *SymbolTable) Interpreter {
        return .{
            .allocator = allocator,
            .symbol_table = symbol_table,
            .global_env = Environment.init(allocator),
            .return_value = null,
            .break_signal = null,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.global_env.deinit();
        self.arena.deinit();
    }

    /// Get arena allocator for allocations that live for the interpreter's lifetime.
    /// Used for stdlib and builtin registrations.
    pub fn arenaAlloc(self: *Interpreter) Allocator {
        return self.arena.allocator();
    }

    /// Interpret a complete program
    pub fn interpret(self: *Interpreter, program: *const Program) InterpreterError!?Value {
        // First pass: register all top-level declarations
        for (program.declarations) |*decl| {
            try self.registerDeclaration(decl, &self.global_env);
        }

        // Process import declarations and create aliases
        for (program.imports) |import_decl| {
            try self.processImport(&import_decl, &self.global_env);
        }

        // Look for main function
        if (self.global_env.get("main")) |main_binding| {
            if (main_binding.value == .function) {
                const result = try self.callFunction(main_binding.value.function, &.{}, &self.global_env);
                return result;
            }
        }

        // No main function - return last expression value if any
        return null;
    }

    /// Process an import declaration and create bindings for imported items
    fn processImport(self: *Interpreter, import_decl: *const Declaration.ImportDecl, env: *Environment) InterpreterError!void {
        _ = self;

        // If the import has specific items, create bindings for each
        if (import_decl.items) |items| {
            for (items) |item| {
                // Look up the original name in the environment (from the loaded module)
                if (env.get(item.name)) |original| {
                    // Use alias if provided, otherwise use the original name
                    const binding_name = item.alias orelse item.name;
                    // Create the binding (define handles duplicates)
                    env.define(binding_name, original.value, original.is_mutable) catch {};
                }
                // If not found, the symbol wasn't registered - this is a runtime error
                // but we skip silently here as it should have been caught by the type checker
            }
        }
        // Whole-module imports are handled by registerModuleNamespace in main.zig
    }

    /// Register a module namespace value at the given path.
    /// For example, for path ["src", "json"], this creates:
    /// - A record for "json" containing the module's exports
    /// - A record for "src" containing "json"
    /// - Defines "src" in the environment (or merges with existing)
    pub fn registerModuleNamespace(
        self: *Interpreter,
        path: []const []const u8,
        declarations: []const Declaration,
        env: *Environment,
    ) InterpreterError!void {
        if (path.len == 0) return;

        // Create the innermost module record with all exports
        var module_fields = std.StringArrayHashMapUnmanaged(Value){};

        // Register all public declarations as fields in the module record
        for (declarations) |*decl| {
            switch (decl.kind) {
                .function_decl => |f| {
                    if (f.is_public or true) { // For now, export all
                        const func_value = Value{
                            .function = .{
                                .name = f.name,
                                .parameters = self.extractParamNames(f.parameters) catch continue,
                                .body = if (f.body) |body| .{ .ast_body = body } else continue,
                                .captured_env = null,
                                .is_effect = f.is_effect,
                            },
                        };
                        module_fields.put(self.arenaAlloc(), f.name, func_value) catch continue;
                    }
                },
                .const_decl => |c| {
                    if (c.is_public or true) {
                        const value = self.evalExpression(c.value, env) catch continue;
                        module_fields.put(self.arenaAlloc(), c.name, value) catch continue;
                    }
                },
                .type_decl => |t| {
                    // For sum types, register variant constructors
                    if (t.is_public or true) {
                        switch (t.definition) {
                            .sum_type => |st| {
                                for (st.variants) |variant| {
                                    // Create variant constructor value
                                    const variant_val = Value{
                                        .variant = .{
                                            .name = variant.name,
                                            .fields = null,
                                        },
                                    };
                                    module_fields.put(self.arenaAlloc(), variant.name, variant_val) catch continue;
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        const leaf_module = Value{
            .record = .{
                .type_name = null,
                .fields = module_fields,
            },
        };

        // For a path like ["src", "json"], we need to:
        // 1. Create/update "src" record in the environment
        // 2. Add "json" as a field in "src"
        //
        // We also need to handle cases where "src" already exists and contains other modules.

        if (path.len == 1) {
            // Simple case: single-segment path like "json"
            // Just define it directly
            if (env.get(path[0])) |existing| {
                if (existing.value == .record) {
                    // Merge new exports into existing module
                    var merged = existing.value.record.fields;
                    var field_iter = module_fields.iterator();
                    while (field_iter.next()) |entry| {
                        merged.put(self.arenaAlloc(), entry.key_ptr.*, entry.value_ptr.*) catch continue;
                    }
                    env.assign(path[0], Value{ .record = .{ .type_name = null, .fields = merged } }) catch {};
                    return;
                }
            }
            env.define(path[0], leaf_module, false) catch {};
            return;
        }

        // Multi-segment path: need to create nested structure
        // For ["src", "json"], create src.json

        // Start with the root segment
        const root_name = path[0];
        var current_record: std.StringArrayHashMapUnmanaged(Value) = undefined;

        // Get or create the root record
        if (env.get(root_name)) |existing| {
            if (existing.value == .record) {
                current_record = existing.value.record.fields;
            } else {
                // Root exists but isn't a record - create a new empty record
                current_record = std.StringArrayHashMapUnmanaged(Value){};
            }
        } else {
            current_record = std.StringArrayHashMapUnmanaged(Value){};
        }

        // Navigate/create intermediate segments
        // For ["src", "json", "utils"], we need src -> json -> utils
        var i: usize = 1;
        while (i < path.len - 1) : (i += 1) {
            const segment = path[i];
            if (current_record.get(segment)) |existing| {
                if (existing == .record) {
                    // Use existing intermediate record
                    current_record = existing.record.fields;
                } else {
                    // Overwrite non-record with empty record
                    const new_fields = std.StringArrayHashMapUnmanaged(Value){};
                    current_record.put(self.arenaAlloc(), segment, Value{
                        .record = .{ .type_name = null, .fields = new_fields },
                    }) catch return error.OutOfMemory;
                    current_record = new_fields;
                }
            } else {
                // Create new intermediate record
                const new_fields = std.StringArrayHashMapUnmanaged(Value){};
                current_record.put(self.arenaAlloc(), segment, Value{
                    .record = .{ .type_name = null, .fields = new_fields },
                }) catch return error.OutOfMemory;
                current_record = new_fields;
            }
        }

        // Add the leaf module at the final segment
        const leaf_name = path[path.len - 1];
        if (current_record.get(leaf_name)) |existing| {
            if (existing == .record) {
                // Merge new exports into existing module
                var merged = existing.record.fields;
                var field_iter = module_fields.iterator();
                while (field_iter.next()) |entry| {
                    merged.put(self.arenaAlloc(), entry.key_ptr.*, entry.value_ptr.*) catch continue;
                }
                current_record.put(self.arenaAlloc(), leaf_name, Value{
                    .record = .{ .type_name = null, .fields = merged },
                }) catch return error.OutOfMemory;
            } else {
                current_record.put(self.arenaAlloc(), leaf_name, leaf_module) catch return error.OutOfMemory;
            }
        } else {
            current_record.put(self.arenaAlloc(), leaf_name, leaf_module) catch return error.OutOfMemory;
        }

        // Now rebuild the full tree and define it at the root
        // We need to rebuild from the current_record back up to root
        // This is necessary because we modified the leaf, but the intermediate
        // records need to reflect those changes

        // Simple approach: just rebuild the whole thing by re-evaluating
        // Actually, we can just update the root with the modified structure
        // since all records share the same underlying hashmaps

        // The issue is that when we get existing.value.record.fields, we get a copy
        // of the hashmap, not a reference. So modifications don't propagate.
        // We need to rebuild the entire structure.

        // Rebuild from innermost to outermost
        var module_value = leaf_module;
        var j: usize = path.len - 1;
        while (j > 0) {
            j -= 1;

            var outer_fields: std.StringArrayHashMapUnmanaged(Value) = undefined;

            if (j == 0) {
                // At root level, check for existing record to merge with
                if (env.get(path[0])) |existing| {
                    if (existing.value == .record) {
                        outer_fields = existing.value.record.fields;
                    } else {
                        outer_fields = std.StringArrayHashMapUnmanaged(Value){};
                    }
                } else {
                    outer_fields = std.StringArrayHashMapUnmanaged(Value){};
                }
            } else {
                outer_fields = std.StringArrayHashMapUnmanaged(Value){};
            }

            outer_fields.put(self.arenaAlloc(), path[j + 1], module_value) catch return error.OutOfMemory;
            module_value = Value{
                .record = .{
                    .type_name = null,
                    .fields = outer_fields,
                },
            };
        }

        // Define the root
        env.define(root_name, module_value, false) catch {
            // If already defined, try to update
            env.assign(root_name, module_value) catch {};
        };
    }

    /// Register a top-level declaration in the environment
    pub fn registerDeclaration(self: *Interpreter, decl: *const Declaration, env: *Environment) InterpreterError!void {
        switch (decl.kind) {
            .function_decl => |f| {
                const func_value = Value{
                    .function = .{
                        .name = f.name,
                        .parameters = try self.extractParamNames(f.parameters),
                        .body = if (f.body) |body| .{ .ast_body = body } else return,
                        .captured_env = null,
                        .is_effect = f.is_effect,
                    },
                };
                try env.define(f.name, func_value, false);
            },
            .const_decl => |c| {
                const value = try self.evalExpression(c.value, env);
                try env.define(c.name, value, false);
            },
            .let_decl => |l| {
                const value = try self.evalExpression(l.value, env);
                try env.define(l.name, value, false);
            },
            .type_decl => {
                // Type declarations are handled by the type checker
                // We may need to register constructors for sum types
            },
            .trait_decl, .impl_block, .module_decl, .import_decl => {
                // These are handled elsewhere or don't need runtime representation
            },
        }
    }

    /// Extract parameter names from function parameters
    fn extractParamNames(self: *Interpreter, params: []const Declaration.Parameter) ![]const []const u8 {
        const names = try self.arenaAlloc().alloc([]const u8, params.len);
        for (params, 0..) |param, i| {
            names[i] = param.name;
        }
        return names;
    }

    /// Evaluate an expression and return its value
    pub fn evalExpression(self: *Interpreter, expr: *const Expression, env: *Environment) InterpreterError!Value {
        return switch (expr.kind) {
            // Literals
            .integer_literal => |lit| Value{ .integer = lit.value },
            .float_literal => |lit| Value{ .float = lit.value },
            .string_literal => |lit| Value{ .string = lit.value },
            .char_literal => |lit| Value{ .char = lit.value },
            .bool_literal => |b| Value{ .boolean = b },

            // Identifiers
            .identifier => |id| self.evalIdentifier(id.name, env),
            .self_expr => error.InvalidOperation, // Should be resolved during type checking
            .self_type_expr => error.InvalidOperation,

            // Operators
            .binary => |bin| self.evalBinaryOp(bin, env),
            .unary => |un| self.evalUnaryOp(un, env),

            // Access
            .field_access => |fa| self.evalFieldAccess(fa, env),
            .index_access => |ia| self.evalIndexAccess(ia, env),
            .tuple_access => |ta| self.evalTupleAccess(ta, env),

            // Calls
            .function_call => |call| self.evalFunctionCall(call, env),
            .method_call => |call| self.evalMethodCall(call, env),

            // Closures
            .closure => |c| self.evalClosure(c, env),

            // Match expression
            .match_expr => |m| self.evalMatchExpr(m, env),

            // Composite literals
            .tuple_literal => |t| self.evalTupleLiteral(t, env),
            .array_literal => |a| self.evalArrayLiteral(a, env),
            .record_literal => |r| self.evalRecordLiteral(r, env),

            // Variant constructor
            .variant_constructor => |v| self.evalVariantConstructor(v, env),

            // Type cast
            .type_cast => |tc| self.evalTypeCast(tc, env),

            // Range
            .range => |r| self.evalRange(r, env),

            // Grouped expression
            .grouped => |g| self.evalExpression(g, env),

            // Interpolated string
            .interpolated_string => |is| self.evalInterpolatedString(is, env),

            // Error handling
            .try_expr => |te| self.evalTryExpr(te, env),
            .null_coalesce => |nc| self.evalNullCoalesce(nc, env),
        };
    }

    /// Evaluate an identifier
    fn evalIdentifier(self: *Interpreter, name: []const u8, env: *Environment) InterpreterError!Value {
        _ = self;
        if (env.get(name)) |binding| {
            return binding.value;
        }
        return error.UndefinedVariable;
    }

    /// Evaluate a binary operation
    fn evalBinaryOp(self: *Interpreter, op: Expression.BinaryOp, env: *Environment) InterpreterError!Value {
        // Short-circuit evaluation for logical operators
        if (op.operator == .logical_and) {
            const left = try self.evalExpression(op.left, env);
            if (!left.isTruthy()) return Value{ .boolean = false };
            const right = try self.evalExpression(op.right, env);
            return Value{ .boolean = right.isTruthy() };
        }

        if (op.operator == .logical_or) {
            const left = try self.evalExpression(op.left, env);
            if (left.isTruthy()) return Value{ .boolean = true };
            const right = try self.evalExpression(op.right, env);
            return Value{ .boolean = right.isTruthy() };
        }

        const left = try self.evalExpression(op.left, env);
        const right = try self.evalExpression(op.right, env);

        return switch (op.operator) {
            // Arithmetic
            .add => self.evalAdd(left, right),
            .subtract => self.evalSubtract(left, right),
            .multiply => self.evalMultiply(left, right),
            .divide => self.evalDivide(left, right),
            .modulo => self.evalModulo(left, right),

            // Comparison
            .equal => Value{ .boolean = left.eql(right) },
            .not_equal => Value{ .boolean = !left.eql(right) },
            .less_than => self.evalLessThan(left, right),
            .greater_than => self.evalGreaterThan(left, right),
            .less_equal => self.evalLessEqual(left, right),
            .greater_equal => self.evalGreaterEqual(left, right),

            // Logical (already handled above)
            .logical_and, .logical_or => unreachable,

            // Special
            .is => error.InvalidOperation, // Type checking at runtime not supported
            .in_op => self.evalInOp(left, right),
        };
    }

    // Arithmetic operations
    fn evalAdd(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .integer = std.math.add(i128, a, b) catch return error.Overflow },
                .float => |b| Value{ .float = @as(f64, @floatFromInt(a)) + b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .float = a + @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .float = a + b },
                else => error.TypeMismatch,
            },
            .string => |a| switch (right) {
                .string => |b| blk: {
                    // String concatenation
                    const result = std.fmt.allocPrint(self.arenaAlloc(), "{s}{s}", .{ a, b }) catch return error.OutOfMemory;
                    break :blk Value{ .string = result };
                },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalSubtract(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .integer = std.math.sub(i128, a, b) catch return error.Overflow },
                .float => |b| Value{ .float = @as(f64, @floatFromInt(a)) - b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .float = a - @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .float = a - b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalMultiply(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .integer = std.math.mul(i128, a, b) catch return error.Overflow },
                .float => |b| Value{ .float = @as(f64, @floatFromInt(a)) * b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .float = a * @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .float = a * b },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalDivide(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| {
                    if (b == 0) return error.DivisionByZero;
                    return Value{ .integer = @divTrunc(a, b) };
                },
                .float => |b| {
                    if (b == 0.0) return error.DivisionByZero;
                    return Value{ .float = @as(f64, @floatFromInt(a)) / b };
                },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| {
                    if (b == 0) return error.DivisionByZero;
                    return Value{ .float = a / @as(f64, @floatFromInt(b)) };
                },
                .float => |b| {
                    if (b == 0.0) return error.DivisionByZero;
                    return Value{ .float = a / b };
                },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalModulo(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| {
                    if (b == 0) return error.DivisionByZero;
                    return Value{ .integer = @mod(a, b) };
                },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .float => |b| {
                    if (b == 0.0) return error.DivisionByZero;
                    return Value{ .float = @mod(a, b) };
                },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    // Comparison operations
    fn evalLessThan(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .boolean = a < b },
                .float => |b| Value{ .boolean = @as(f64, @floatFromInt(a)) < b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .boolean = a < @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .boolean = a < b },
                else => error.TypeMismatch,
            },
            .char => |a| switch (right) {
                .char => |b| Value{ .boolean = a < b },
                else => error.TypeMismatch,
            },
            .string => |a| switch (right) {
                .string => |b| Value{ .boolean = std.mem.order(u8, a, b) == .lt },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalGreaterThan(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .boolean = a > b },
                .float => |b| Value{ .boolean = @as(f64, @floatFromInt(a)) > b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .boolean = a > @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .boolean = a > b },
                else => error.TypeMismatch,
            },
            .char => |a| switch (right) {
                .char => |b| Value{ .boolean = a > b },
                else => error.TypeMismatch,
            },
            .string => |a| switch (right) {
                .string => |b| Value{ .boolean = std.mem.order(u8, a, b) == .gt },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalLessEqual(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .boolean = a <= b },
                .float => |b| Value{ .boolean = @as(f64, @floatFromInt(a)) <= b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .boolean = a <= @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .boolean = a <= b },
                else => error.TypeMismatch,
            },
            .char => |a| switch (right) {
                .char => |b| Value{ .boolean = a <= b },
                else => error.TypeMismatch,
            },
            .string => |a| switch (right) {
                .string => |b| Value{ .boolean = std.mem.order(u8, a, b) != .gt },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    fn evalGreaterEqual(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (left) {
            .integer => |a| switch (right) {
                .integer => |b| Value{ .boolean = a >= b },
                .float => |b| Value{ .boolean = @as(f64, @floatFromInt(a)) >= b },
                else => error.TypeMismatch,
            },
            .float => |a| switch (right) {
                .integer => |b| Value{ .boolean = a >= @as(f64, @floatFromInt(b)) },
                .float => |b| Value{ .boolean = a >= b },
                else => error.TypeMismatch,
            },
            .char => |a| switch (right) {
                .char => |b| Value{ .boolean = a >= b },
                else => error.TypeMismatch,
            },
            .string => |a| switch (right) {
                .string => |b| Value{ .boolean = std.mem.order(u8, a, b) != .lt },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    /// Evaluate 'in' operator
    fn evalInOp(self: *Interpreter, left: Value, right: Value) InterpreterError!Value {
        _ = self;
        return switch (right) {
            .array => |arr| {
                for (arr) |elem| {
                    if (left.eql(elem)) return Value{ .boolean = true };
                }
                return Value{ .boolean = false };
            },
            .string => |s| switch (left) {
                .string => |needle| Value{ .boolean = std.mem.indexOf(u8, s, needle) != null },
                .char => |c| {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &buf) catch return error.InvalidOperation;
                    return Value{ .boolean = std.mem.indexOf(u8, s, buf[0..len]) != null };
                },
                else => error.TypeMismatch,
            },
            else => error.TypeMismatch,
        };
    }

    /// Evaluate a unary operation
    fn evalUnaryOp(self: *Interpreter, op: Expression.UnaryOp, env: *Environment) InterpreterError!Value {
        const operand = try self.evalExpression(op.operand, env);

        return switch (op.operator) {
            .negate => switch (operand) {
                .integer => |v| Value{ .integer = std.math.negate(v) catch return error.Overflow },
                .float => |v| Value{ .float = -v },
                else => error.TypeMismatch,
            },
            .logical_not => Value{ .boolean = !operand.isTruthy() },
        };
    }

    /// Evaluate field access
    fn evalFieldAccess(self: *Interpreter, fa: Expression.FieldAccess, env: *Environment) InterpreterError!Value {
        const obj = try self.evalExpression(fa.object, env);

        return switch (obj) {
            .record => |r| {
                if (r.fields.get(fa.field)) |value| {
                    return value;
                }
                return error.FieldNotFound;
            },
            .variant => |v| {
                if (v.fields) |fields| {
                    switch (fields) {
                        .record => |r| {
                            if (r.get(fa.field)) |value| {
                                return value;
                            }
                        },
                        .tuple => return error.FieldNotFound,
                    }
                }
                return error.FieldNotFound;
            },
            else => error.TypeMismatch,
        };
    }

    /// Evaluate index access
    fn evalIndexAccess(self: *Interpreter, ia: Expression.IndexAccess, env: *Environment) InterpreterError!Value {
        const obj = try self.evalExpression(ia.object, env);
        const index = try self.evalExpression(ia.index, env);

        return switch (obj) {
            .array => |arr| {
                const idx = switch (index) {
                    .integer => |i| blk: {
                        if (i < 0) return error.IndexOutOfBounds;
                        break :blk @as(usize, @intCast(i));
                    },
                    else => return error.TypeMismatch,
                };
                if (idx >= arr.len) return error.IndexOutOfBounds;
                return arr[idx];
            },
            .string => |s| {
                const idx = switch (index) {
                    .integer => |i| blk: {
                        if (i < 0) return error.IndexOutOfBounds;
                        break :blk @as(usize, @intCast(i));
                    },
                    else => return error.TypeMismatch,
                };
                if (idx >= s.len) return error.IndexOutOfBounds;
                return Value{ .char = s[idx] };
            },
            else => error.TypeMismatch,
        };
    }

    /// Evaluate tuple access
    fn evalTupleAccess(self: *Interpreter, ta: Expression.TupleAccess, env: *Environment) InterpreterError!Value {
        const tuple = try self.evalExpression(ta.tuple, env);

        return switch (tuple) {
            .tuple => |t| {
                if (ta.index >= t.len) return error.IndexOutOfBounds;
                return t[ta.index];
            },
            else => error.TypeMismatch,
        };
    }

    /// Evaluate a function call
    fn evalFunctionCall(self: *Interpreter, call: Expression.FunctionCall, env: *Environment) InterpreterError!Value {
        const callee = try self.evalExpression(call.callee, env);

        return switch (callee) {
            .function => |f| {
                // Evaluate arguments
                const args = try self.arenaAlloc().alloc(Value, call.arguments.len);
                for (call.arguments, 0..) |arg, i| {
                    args[i] = try self.evalExpression(arg, env);
                }
                return self.callFunction(f, args, env);
            },
            else => error.NotCallable,
        };
    }

    /// Call a function with given arguments
    fn callFunction(self: *Interpreter, func: Value.FunctionValue, args: []const Value, caller_env: *Environment) InterpreterError!Value {
        switch (func.body) {
            .ast_body => |body| {
                // Check arity for AST functions
                if (args.len != func.parameters.len) {
                    return error.ArityMismatch;
                }
                // Create new environment for function call on the heap (arena)
                // This is important because closures may capture this environment,
                // and we need it to outlive the function call.
                const base_env = func.captured_env orelse caller_env;
                const func_env = try self.arenaAlloc().create(Environment);
                func_env.* = Environment.initWithParent(self.arenaAlloc(), base_env);

                // Bind parameters
                for (func.parameters, 0..) |param, i| {
                    try func_env.define(param, args[i], false);
                }

                // Execute body
                for (body) |stmt| {
                    self.evalStatement(&stmt, func_env) catch |err| {
                        if (err == error.ReturnEncountered) {
                            const result = self.return_value orelse Value{ .void = {} };
                            self.return_value = null;
                            return result;
                        }
                        return err;
                    };
                }

                return Value{ .void = {} };
            },
            .builtin => |builtin_fn| {
                const ctx = self.makeBuiltinContext();
                return builtin_fn(ctx, args);
            },
        }
    }

    /// Create a BuiltinContext for calling builtin functions
    fn makeBuiltinContext(self: *Interpreter) Value.BuiltinContext {
        return .{
            .allocator = self.arenaAlloc(),
            .interpreter = self,
            .call_fn = &builtinCallFunction,
        };
    }

    /// Wrapper function that allows builtins to call back into the interpreter
    fn builtinCallFunction(interp_ptr: *anyopaque, func: Value.FunctionValue, args: []const Value) InterpreterError!Value {
        const self: *Interpreter = @ptrCast(@alignCast(interp_ptr));
        return self.callFunction(func, args, &self.global_env);
    }

    /// Evaluate a method call
    fn evalMethodCall(self: *Interpreter, call: Expression.MethodCall, env: *Environment) InterpreterError!Value {
        const obj = try self.evalExpression(call.object, env);

        // Handle built-in methods
        if (std.mem.eql(u8, call.method, "len")) {
            return self.evalMethodLen(obj);
        }
        if (std.mem.eql(u8, call.method, "is_some")) {
            return switch (obj) {
                .some => Value{ .boolean = true },
                .none => Value{ .boolean = false },
                else => error.TypeMismatch,
            };
        }
        if (std.mem.eql(u8, call.method, "is_none")) {
            return switch (obj) {
                .some => Value{ .boolean = false },
                .none => Value{ .boolean = true },
                else => error.TypeMismatch,
            };
        }
        if (std.mem.eql(u8, call.method, "is_ok")) {
            return switch (obj) {
                .ok => Value{ .boolean = true },
                .err => Value{ .boolean = false },
                else => error.TypeMismatch,
            };
        }
        if (std.mem.eql(u8, call.method, "is_err")) {
            return switch (obj) {
                .ok => Value{ .boolean = false },
                .err => Value{ .boolean = true },
                else => error.TypeMismatch,
            };
        }
        if (std.mem.eql(u8, call.method, "unwrap")) {
            return switch (obj) {
                .some => |v| v.*,
                .ok => |v| v.*,
                .none => error.AssertionFailed,
                .err => error.AssertionFailed,
                else => error.TypeMismatch,
            };
        }
        if (std.mem.eql(u8, call.method, "unwrap_or")) {
            if (call.arguments.len != 1) return error.ArityMismatch;
            const default = try self.evalExpression(call.arguments[0], env);
            return switch (obj) {
                .some => |v| v.*,
                .ok => |v| v.*,
                .none, .err => default,
                else => error.TypeMismatch,
            };
        }

        // For records (like std.io), treat method call as field access + function call
        if (obj == .record) {
            if (obj.record.fields.get(call.method)) |field_value| {
                if (field_value == .function) {
                    // Evaluate arguments
                    const args = try self.arenaAlloc().alloc(Value, call.arguments.len);
                    for (call.arguments, 0..) |arg, i| {
                        args[i] = try self.evalExpression(arg, env);
                    }
                    return self.callFunction(field_value.function, args, env);
                }
            }
        }

        // For user-defined methods, we would need trait/impl lookup
        return error.FieldNotFound;
    }

    /// Built-in len method
    fn evalMethodLen(self: *Interpreter, obj: Value) InterpreterError!Value {
        _ = self;
        return switch (obj) {
            .string => |s| Value{ .integer = @intCast(s.len) },
            .array => |a| Value{ .integer = @intCast(a.len) },
            .tuple => |t| Value{ .integer = @intCast(t.len) },
            else => error.TypeMismatch,
        };
    }

    /// Evaluate a closure
    fn evalClosure(self: *Interpreter, closure: Expression.Closure, env: *Environment) InterpreterError!Value {
        const param_names = try self.arenaAlloc().alloc([]const u8, closure.parameters.len);
        for (closure.parameters, 0..) |param, i| {
            param_names[i] = param.name;
        }

        return Value{
            .function = .{
                .name = null,
                .parameters = param_names,
                .body = .{ .ast_body = closure.body },
                .captured_env = env,
                .is_effect = closure.is_effect,
            },
        };
    }

    /// Evaluate a match expression
    fn evalMatchExpr(self: *Interpreter, match: Expression.MatchExpr, env: *Environment) InterpreterError!Value {
        const subject = try self.evalExpression(match.subject, env);

        for (match.arms) |arm| {
            // Heap-allocate arm environment since closures in the arm body
            // may capture it and outlive this scope
            const arm_env = try self.arenaAlloc().create(Environment);
            arm_env.* = Environment.initWithParent(self.arenaAlloc(), env);

            if (try self.matchPattern(arm.pattern, subject, arm_env)) {
                // Check guard if present
                if (arm.guard) |guard| {
                    const guard_val = try self.evalExpression(guard, arm_env);
                    if (!guard_val.isTruthy()) continue;
                }

                // Evaluate body
                return switch (arm.body) {
                    .expression => |expr| self.evalExpression(expr, arm_env),
                    .block => |stmts| {
                        for (stmts) |stmt| {
                            self.evalStatement(&stmt, arm_env) catch |err| {
                                if (err == error.ReturnEncountered) {
                                    return self.return_value orelse Value{ .void = {} };
                                }
                                return err;
                            };
                        }
                        return Value{ .void = {} };
                    },
                };
            }
        }

        return error.MatchFailed;
    }

    /// Evaluate a tuple literal
    fn evalTupleLiteral(self: *Interpreter, tuple: Expression.TupleLiteral, env: *Environment) InterpreterError!Value {
        const elements = try self.arenaAlloc().alloc(Value, tuple.elements.len);
        for (tuple.elements, 0..) |elem, i| {
            elements[i] = try self.evalExpression(elem, env);
        }
        return Value{ .tuple = elements };
    }

    /// Evaluate an array literal
    fn evalArrayLiteral(self: *Interpreter, array: Expression.ArrayLiteral, env: *Environment) InterpreterError!Value {
        const elements = try self.arenaAlloc().alloc(Value, array.elements.len);
        for (array.elements, 0..) |elem, i| {
            elements[i] = try self.evalExpression(elem, env);
        }
        return Value{ .array = elements };
    }

    /// Evaluate a record literal
    fn evalRecordLiteral(self: *Interpreter, record: Expression.RecordLiteral, env: *Environment) InterpreterError!Value {
        var fields = std.StringArrayHashMapUnmanaged(Value){};

        for (record.fields) |field| {
            const value = try self.evalExpression(field.value, env);
            try fields.put(self.arenaAlloc(), field.name, value);
        }

        const type_name: ?[]const u8 = if (record.type_name) |tn| blk: {
            if (tn.kind == .identifier) {
                break :blk tn.kind.identifier.name;
            }
            break :blk null;
        } else null;

        return Value{ .record = .{ .type_name = type_name, .fields = fields } };
    }

    /// Evaluate a variant constructor
    fn evalVariantConstructor(self: *Interpreter, vc: Expression.VariantConstructor, env: *Environment) InterpreterError!Value {
        // Handle built-in Option type
        if (std.mem.eql(u8, vc.variant_name, "Some")) {
            if (vc.arguments) |args| {
                if (args.len != 1) return error.ArityMismatch;
                const inner = try self.arenaAlloc().create(Value);
                inner.* = try self.evalExpression(args[0], env);
                return Value{ .some = inner };
            }
            return error.ArityMismatch;
        }

        if (std.mem.eql(u8, vc.variant_name, "None")) {
            return Value{ .none = {} };
        }

        // Handle built-in Result type
        if (std.mem.eql(u8, vc.variant_name, "Ok")) {
            if (vc.arguments) |args| {
                if (args.len != 1) return error.ArityMismatch;
                const inner = try self.arenaAlloc().create(Value);
                inner.* = try self.evalExpression(args[0], env);
                return Value{ .ok = inner };
            }
            return error.ArityMismatch;
        }

        if (std.mem.eql(u8, vc.variant_name, "Err")) {
            if (vc.arguments) |args| {
                if (args.len != 1) return error.ArityMismatch;
                const inner = try self.arenaAlloc().create(Value);
                inner.* = try self.evalExpression(args[0], env);
                return Value{ .err = inner };
            }
            return error.ArityMismatch;
        }

        // Handle built-in List type
        if (std.mem.eql(u8, vc.variant_name, "Cons")) {
            if (vc.arguments) |args| {
                if (args.len != 2) return error.ArityMismatch;
                const head = try self.arenaAlloc().create(Value);
                const tail = try self.arenaAlloc().create(Value);
                head.* = try self.evalExpression(args[0], env);
                tail.* = try self.evalExpression(args[1], env);
                return Value{ .cons = .{ .head = head, .tail = tail } };
            }
            return error.ArityMismatch;
        }

        if (std.mem.eql(u8, vc.variant_name, "Nil")) {
            return Value{ .nil = {} };
        }

        // Generic variant
        const fields: ?Value.VariantValue.VariantFields = if (vc.arguments) |args| blk: {
            const tuple_fields = try self.arenaAlloc().alloc(Value, args.len);
            for (args, 0..) |arg, i| {
                tuple_fields[i] = try self.evalExpression(arg, env);
            }
            break :blk .{ .tuple = tuple_fields };
        } else null;

        return Value{ .variant = .{ .name = vc.variant_name, .fields = fields } };
    }

    /// Evaluate a type cast
    fn evalTypeCast(self: *Interpreter, tc: Expression.TypeCast, env: *Environment) InterpreterError!Value {
        // Type casts are mostly compile-time in Kira
        // At runtime, we just return the value (type checking already validated)
        return self.evalExpression(tc.expression, env);
    }

    /// Evaluate a range expression
    fn evalRange(self: *Interpreter, range: Expression.Range, env: *Environment) InterpreterError!Value {
        // Ranges are typically used in for loops, not as standalone values
        // We'll create a tuple representation
        const start = if (range.start) |s| try self.evalExpression(s, env) else Value{ .none = {} };
        const end = if (range.end) |e| try self.evalExpression(e, env) else Value{ .none = {} };

        const elements = try self.arenaAlloc().alloc(Value, 3);
        elements[0] = start;
        elements[1] = end;
        elements[2] = Value{ .boolean = range.inclusive };

        return Value{ .tuple = elements };
    }

    /// Evaluate an interpolated string
    fn evalInterpolatedString(self: *Interpreter, is: Expression.InterpolatedString, env: *Environment) InterpreterError!Value {
        var result = std.ArrayListUnmanaged(u8){};

        for (is.parts) |part| {
            switch (part) {
                .literal => |lit| {
                    result.appendSlice(self.arenaAlloc(), lit) catch return error.OutOfMemory;
                },
                .expression => |expr| {
                    const value = try self.evalExpression(expr, env);
                    const str = value.toString(self.arenaAlloc()) catch return error.OutOfMemory;
                    // Remove quotes from string representation for interpolation
                    const clean = if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"')
                        str[1 .. str.len - 1]
                    else
                        str;
                    result.appendSlice(self.arenaAlloc(), clean) catch return error.OutOfMemory;
                },
            }
        }

        return Value{ .string = result.toOwnedSlice(self.arenaAlloc()) catch return error.OutOfMemory };
    }

    /// Evaluate a try expression (?)
    fn evalTryExpr(self: *Interpreter, expr: *const Expression, env: *Environment) InterpreterError!Value {
        const value = try self.evalExpression(expr, env);

        return switch (value) {
            .ok => |v| v.*,
            .some => |v| v.*,
            .err, .none => error.ErrorPropagation,
            else => value,
        };
    }

    /// Evaluate null coalesce (??)
    fn evalNullCoalesce(self: *Interpreter, nc: Expression.NullCoalesce, env: *Environment) InterpreterError!Value {
        const left = try self.evalExpression(nc.left, env);

        return switch (left) {
            .none, .nil => self.evalExpression(nc.default, env),
            .some => |v| v.*,
            else => left,
        };
    }

    /// Evaluate a statement
    pub fn evalStatement(self: *Interpreter, stmt: *const Statement, env: *Environment) InterpreterError!void {
        switch (stmt.kind) {
            .let_binding => |let| try self.evalLetBinding(let, env),
            .var_binding => |vb| try self.evalVarBinding(vb, env),
            .assignment => |a| try self.evalAssignment(a, env),
            .if_statement => |ifs| try self.evalIfStatement(ifs, env),
            .for_loop => |fl| try self.evalForLoop(fl, env),
            .match_statement => |m| try self.evalMatchStatement(m, env),
            .return_statement => |r| try self.evalReturnStatement(r, env),
            .break_statement => |b| try self.evalBreakStatement(b, env),
            .expression_statement => |expr| _ = try self.evalExpression(expr, env),
            .block => |stmts| {
                // Heap-allocate block environment since closures may capture it
                const block_env = try self.arenaAlloc().create(Environment);
                block_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                for (stmts) |s| {
                    try self.evalStatement(&s, block_env);
                }
            },
        }
    }

    /// Evaluate a let binding
    fn evalLetBinding(self: *Interpreter, let: Statement.LetBinding, env: *Environment) InterpreterError!void {
        const value = try self.evalExpression(let.initializer, env);
        try self.bindPattern(let.pattern, value, env, false);
    }

    /// Evaluate a var binding
    fn evalVarBinding(self: *Interpreter, vb: Statement.VarBinding, env: *Environment) InterpreterError!void {
        const value = if (vb.initializer) |initializer|
            try self.evalExpression(initializer, env)
        else
            Value{ .void = {} };

        try env.define(vb.name, value, true);
    }

    /// Evaluate an assignment
    fn evalAssignment(self: *Interpreter, assign: Statement.Assignment, env: *Environment) InterpreterError!void {
        const value = try self.evalExpression(assign.value, env);

        switch (assign.target) {
            .identifier => |name| try env.assign(name, value),
            .field_access => |_| return error.InvalidOperation, // TODO: mutable field access
            .index_access => |_| return error.InvalidOperation, // TODO: mutable index access
        }
    }

    /// Evaluate an if statement
    fn evalIfStatement(self: *Interpreter, ifs: Statement.IfStatement, env: *Environment) InterpreterError!void {
        const condition = try self.evalExpression(ifs.condition, env);

        if (condition.isTruthy()) {
            // Heap-allocate then environment since closures may capture it
            const then_env = try self.arenaAlloc().create(Environment);
            then_env.* = Environment.initWithParent(self.arenaAlloc(), env);
            for (ifs.then_branch) |stmt| {
                try self.evalStatement(&stmt, then_env);
            }
        } else if (ifs.else_branch) |else_b| {
            switch (else_b) {
                .block => |stmts| {
                    // Heap-allocate else environment since closures may capture it
                    const else_env = try self.arenaAlloc().create(Environment);
                    else_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                    for (stmts) |stmt| {
                        try self.evalStatement(&stmt, else_env);
                    }
                },
                .else_if => |else_if| try self.evalStatement(else_if, env),
            }
        }
    }

    /// Evaluate a for loop
    fn evalForLoop(self: *Interpreter, fl: Statement.ForLoop, env: *Environment) InterpreterError!void {
        const iterable = try self.evalExpression(fl.iterable, env);

        switch (iterable) {
            .array => |arr| {
                for (arr) |elem| {
                    // Heap-allocate loop environment since closures may capture it
                    const loop_env = try self.arenaAlloc().create(Environment);
                    loop_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                    try self.bindPattern(fl.pattern, elem, loop_env, false);

                    for (fl.body) |stmt| {
                        self.evalStatement(&stmt, loop_env) catch |err| {
                            if (err == error.BreakEncountered) {
                                return;
                            }
                            return err;
                        };
                    }
                }
            },
            .tuple => |t| {
                // Range iteration
                if (t.len == 3 and t[2] == .boolean) {
                    const start_val = switch (t[0]) {
                        .integer => |i| i,
                        .none => 0,
                        else => return error.TypeMismatch,
                    };
                    const end_val = switch (t[1]) {
                        .integer => |i| i,
                        .none => return error.TypeMismatch,
                        else => return error.TypeMismatch,
                    };
                    const inclusive = t[2].boolean;
                    const actual_end = if (inclusive) end_val + 1 else end_val;

                    var i = start_val;
                    while (i < actual_end) : (i += 1) {
                        // Heap-allocate loop environment since closures may capture it
                        const loop_env = try self.arenaAlloc().create(Environment);
                        loop_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                        try self.bindPattern(fl.pattern, Value{ .integer = i }, loop_env, false);

                        for (fl.body) |stmt| {
                            self.evalStatement(&stmt, loop_env) catch |err| {
                                if (err == error.BreakEncountered) {
                                    return;
                                }
                                return err;
                            };
                        }
                    }
                } else {
                    // Regular tuple iteration
                    for (t) |elem| {
                        // Heap-allocate loop environment since closures may capture it
                        const loop_env = try self.arenaAlloc().create(Environment);
                        loop_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                        try self.bindPattern(fl.pattern, elem, loop_env, false);

                        for (fl.body) |stmt| {
                            self.evalStatement(&stmt, loop_env) catch |err| {
                                if (err == error.BreakEncountered) {
                                    return;
                                }
                                return err;
                            };
                        }
                    }
                }
            },
            .cons => {
                var current = iterable;
                while (current == .cons) {
                    // Heap-allocate loop environment since closures may capture it
                    const loop_env = try self.arenaAlloc().create(Environment);
                    loop_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                    try self.bindPattern(fl.pattern, current.cons.head.*, loop_env, false);

                    for (fl.body) |stmt| {
                        self.evalStatement(&stmt, loop_env) catch |err| {
                            if (err == error.BreakEncountered) {
                                return;
                            }
                            return err;
                        };
                    }

                    current = current.cons.tail.*;
                }
            },
            .string => |s| {
                for (s) |c| {
                    // Heap-allocate loop environment since closures may capture it
                    const loop_env = try self.arenaAlloc().create(Environment);
                    loop_env.* = Environment.initWithParent(self.arenaAlloc(), env);
                    try self.bindPattern(fl.pattern, Value{ .char = c }, loop_env, false);

                    for (fl.body) |stmt| {
                        self.evalStatement(&stmt, loop_env) catch |err| {
                            if (err == error.BreakEncountered) {
                                return;
                            }
                            return err;
                        };
                    }
                }
            },
            else => return error.TypeMismatch,
        }
    }

    /// Evaluate a match statement
    fn evalMatchStatement(self: *Interpreter, match: Statement.MatchStatement, env: *Environment) InterpreterError!void {
        const subject = try self.evalExpression(match.subject, env);

        for (match.arms) |arm| {
            // Heap-allocate arm environment since closures may capture it
            const arm_env = try self.arenaAlloc().create(Environment);
            arm_env.* = Environment.initWithParent(self.arenaAlloc(), env);

            if (try self.matchPattern(arm.pattern, subject, arm_env)) {
                // Check guard if present
                if (arm.guard) |guard| {
                    const guard_val = try self.evalExpression(guard, arm_env);
                    if (!guard_val.isTruthy()) continue;
                }

                // Execute body
                for (arm.body) |stmt| {
                    try self.evalStatement(&stmt, arm_env);
                }
                return;
            }
        }

        return error.MatchFailed;
    }

    /// Evaluate a return statement
    fn evalReturnStatement(self: *Interpreter, ret: Statement.ReturnStatement, env: *Environment) InterpreterError!void {
        self.return_value = if (ret.value) |val|
            try self.evalExpression(val, env)
        else
            Value{ .void = {} };

        return error.ReturnEncountered;
    }

    /// Evaluate a break statement
    fn evalBreakStatement(self: *Interpreter, brk: Statement.BreakStatement, env: *Environment) InterpreterError!void {
        self.break_signal = .{
            .label = brk.label,
            .value = if (brk.value) |val| try self.evalExpression(val, env) else null,
        };

        return error.BreakEncountered;
    }

    /// Try to match a pattern against a value, binding variables if successful
    fn matchPattern(self: *Interpreter, pattern: *const Pattern, value: Value, env: *Environment) InterpreterError!bool {
        switch (pattern.kind) {
            .wildcard => return true,

            .identifier => |id| {
                try env.define(id.name, value, id.is_mutable);
                return true;
            },

            .integer_literal => |i| return switch (value) {
                .integer => |v| v == i,
                else => false,
            },

            .float_literal => |f| return switch (value) {
                .float => |v| v == f,
                else => false,
            },

            .string_literal => |s| return switch (value) {
                .string => |v| std.mem.eql(u8, v, s),
                else => false,
            },

            .char_literal => |c| return switch (value) {
                .char => |v| v == c,
                else => false,
            },

            .bool_literal => |b| return switch (value) {
                .boolean => |v| v == b,
                else => false,
            },

            .constructor => |c| {
                // Handle Option
                if (std.mem.eql(u8, c.variant_name, "Some")) {
                    return switch (value) {
                        .some => |v| {
                            if (c.arguments) |args| {
                                if (args.len != 1) return false;
                                return switch (args[0]) {
                                    .positional => |p| self.matchPattern(p, v.*, env),
                                    .named => |n| self.matchPattern(n.pattern, v.*, env),
                                };
                            }
                            return false;
                        },
                        else => false,
                    };
                }

                if (std.mem.eql(u8, c.variant_name, "None")) {
                    return value == .none;
                }

                // Handle Result
                if (std.mem.eql(u8, c.variant_name, "Ok")) {
                    return switch (value) {
                        .ok => |v| {
                            if (c.arguments) |args| {
                                if (args.len != 1) return false;
                                return switch (args[0]) {
                                    .positional => |p| self.matchPattern(p, v.*, env),
                                    .named => |n| self.matchPattern(n.pattern, v.*, env),
                                };
                            }
                            return false;
                        },
                        else => false,
                    };
                }

                if (std.mem.eql(u8, c.variant_name, "Err")) {
                    return switch (value) {
                        .err => |v| {
                            if (c.arguments) |args| {
                                if (args.len != 1) return false;
                                return switch (args[0]) {
                                    .positional => |p| self.matchPattern(p, v.*, env),
                                    .named => |n| self.matchPattern(n.pattern, v.*, env),
                                };
                            }
                            return false;
                        },
                        else => false,
                    };
                }

                // Handle List
                if (std.mem.eql(u8, c.variant_name, "Cons")) {
                    return switch (value) {
                        .cons => |cons| {
                            if (c.arguments) |args| {
                                if (args.len != 2) return false;
                                const head_pat = switch (args[0]) {
                                    .positional => |p| p,
                                    .named => |n| n.pattern,
                                };
                                const tail_pat = switch (args[1]) {
                                    .positional => |p| p,
                                    .named => |n| n.pattern,
                                };
                                if (!try self.matchPattern(head_pat, cons.head.*, env)) return false;
                                return self.matchPattern(tail_pat, cons.tail.*, env);
                            }
                            return false;
                        },
                        else => false,
                    };
                }

                if (std.mem.eql(u8, c.variant_name, "Nil")) {
                    return value == .nil;
                }

                // Generic variant
                return switch (value) {
                    .variant => |v| {
                        if (!std.mem.eql(u8, v.name, c.variant_name)) return false;

                        if (c.arguments) |pat_args| {
                            if (v.fields) |val_fields| {
                                switch (val_fields) {
                                    .tuple => |tuple| {
                                        if (pat_args.len != tuple.len) return false;
                                        for (pat_args, 0..) |arg, i| {
                                            const pat = switch (arg) {
                                                .positional => |p| p,
                                                .named => |n| n.pattern,
                                            };
                                            if (!try self.matchPattern(pat, tuple[i], env)) return false;
                                        }
                                        return true;
                                    },
                                    .record => |rec| {
                                        for (pat_args) |arg| {
                                            switch (arg) {
                                                .positional => return false,
                                                .named => |n| {
                                                    if (rec.get(n.name)) |field_val| {
                                                        if (!try self.matchPattern(n.pattern, field_val, env)) return false;
                                                    } else {
                                                        return false;
                                                    }
                                                },
                                            }
                                        }
                                        return true;
                                    },
                                }
                            }
                            return pat_args.len == 0;
                        }
                        return v.fields == null;
                    },
                    else => false,
                };
            },

            .record => |r| return switch (value) {
                .record => |rec| {
                    for (r.fields) |field| {
                        if (rec.fields.get(field.name)) |field_val| {
                            if (field.pattern) |pat| {
                                if (!try self.matchPattern(pat, field_val, env)) return false;
                            } else {
                                // Shorthand: { x } binds x
                                try env.define(field.name, field_val, false);
                            }
                        } else if (!r.has_rest) {
                            return false;
                        }
                    }
                    return true;
                },
                else => false,
            },

            .tuple => |t| return switch (value) {
                .tuple => |tuple| {
                    if (t.elements.len != tuple.len) return false;
                    for (t.elements, 0..) |elem, i| {
                        if (!try self.matchPattern(elem, tuple[i], env)) return false;
                    }
                    return true;
                },
                else => false,
            },

            .or_pattern => |o| {
                for (o.patterns) |pat| {
                    if (try self.matchPattern(pat, value, env)) return true;
                }
                return false;
            },

            .guarded => |g| {
                if (!try self.matchPattern(g.pattern, value, env)) return false;
                const guard_val = try self.evalExpression(g.guard, env);
                return guard_val.isTruthy();
            },

            .range => |r| {
                const in_range = switch (value) {
                    .integer => |v| {
                        const start = if (r.start) |s| switch (s) {
                            .integer => |i| i,
                            .char => return false,
                        } else std.math.minInt(i128);

                        const end = if (r.end) |e| switch (e) {
                            .integer => |i| i,
                            .char => return false,
                        } else std.math.maxInt(i128);

                        return if (r.inclusive)
                            v >= start and v <= end
                        else
                            v >= start and v < end;
                    },
                    .char => |v| {
                        const start = if (r.start) |s| switch (s) {
                            .char => |c| c,
                            .integer => return false,
                        } else 0;

                        const end = if (r.end) |e| switch (e) {
                            .char => |c| c,
                            .integer => return false,
                        } else std.math.maxInt(u21);

                        return if (r.inclusive)
                            v >= start and v <= end
                        else
                            v >= start and v < end;
                    },
                    else => false,
                };
                return in_range;
            },

            .rest => return true,

            .typed => |t| return self.matchPattern(t.pattern, value, env),
        }
    }

    /// Bind a pattern to a value (assumes pattern matches)
    fn bindPattern(self: *Interpreter, pattern: *const Pattern, value: Value, env: *Environment, is_mutable: bool) InterpreterError!void {
        switch (pattern.kind) {
            .wildcard, .rest => {},

            .identifier => |id| {
                try env.define(id.name, value, is_mutable or id.is_mutable);
            },

            .integer_literal, .float_literal, .string_literal, .char_literal, .bool_literal => {},

            .constructor => |c| {
                // Extract and bind arguments
                if (c.arguments) |args| {
                    const fields = switch (value) {
                        .some => |v| &[_]Value{v.*},
                        .ok => |v| &[_]Value{v.*},
                        .err => |v| &[_]Value{v.*},
                        .cons => |cons| &[_]Value{ cons.head.*, cons.tail.* },
                        .variant => |v| if (v.fields) |f| switch (f) {
                            .tuple => |t| t,
                            .record => return error.TypeMismatch, // TODO: handle record fields
                        } else return,
                        else => return,
                    };

                    for (args, 0..) |arg, i| {
                        const pat = switch (arg) {
                            .positional => |p| p,
                            .named => |n| n.pattern,
                        };
                        if (i < fields.len) {
                            try self.bindPattern(pat, fields[i], env, is_mutable);
                        }
                    }
                }
            },

            .record => |r| {
                const rec = switch (value) {
                    .record => |rec| rec,
                    else => return error.TypeMismatch,
                };

                for (r.fields) |field| {
                    if (rec.fields.get(field.name)) |field_val| {
                        if (field.pattern) |pat| {
                            try self.bindPattern(pat, field_val, env, is_mutable);
                        } else {
                            try env.define(field.name, field_val, is_mutable);
                        }
                    }
                }
            },

            .tuple => |t| {
                const tuple = switch (value) {
                    .tuple => |tup| tup,
                    else => return error.TypeMismatch,
                };

                for (t.elements, 0..) |elem, i| {
                    if (i < tuple.len) {
                        try self.bindPattern(elem, tuple[i], env, is_mutable);
                    }
                }
            },

            .or_pattern => |o| {
                // Bind using first pattern (all should bind same names)
                if (o.patterns.len > 0) {
                    try self.bindPattern(o.patterns[0], value, env, is_mutable);
                }
            },

            .guarded => |g| try self.bindPattern(g.pattern, value, env, is_mutable),

            .range => {},

            .typed => |t| try self.bindPattern(t.pattern, value, env, is_mutable),
        }
    }
};

test "interpreter basic arithmetic" {
    const allocator = std.testing.allocator;

    var table = symbols.SymbolTable.init(allocator);
    defer table.deinit();

    var interp = Interpreter.init(allocator, &table);
    defer interp.deinit();

    // Test integer operations through values directly
    const left = Value{ .integer = 10 };
    const right = Value{ .integer = 3 };

    const add_result = try interp.evalAdd(left, right);
    try std.testing.expectEqual(@as(i128, 13), add_result.integer);

    const sub_result = try interp.evalSubtract(left, right);
    try std.testing.expectEqual(@as(i128, 7), sub_result.integer);

    const mul_result = try interp.evalMultiply(left, right);
    try std.testing.expectEqual(@as(i128, 30), mul_result.integer);

    const div_result = try interp.evalDivide(left, right);
    try std.testing.expectEqual(@as(i128, 3), div_result.integer);

    const mod_result = try interp.evalModulo(left, right);
    try std.testing.expectEqual(@as(i128, 1), mod_result.integer);
}

test "interpreter comparison" {
    const allocator = std.testing.allocator;

    var table = symbols.SymbolTable.init(allocator);
    defer table.deinit();

    var interp = Interpreter.init(allocator, &table);
    defer interp.deinit();

    const a = Value{ .integer = 5 };
    const b = Value{ .integer = 10 };

    try std.testing.expect((try interp.evalLessThan(a, b)).boolean);
    try std.testing.expect(!(try interp.evalLessThan(b, a)).boolean);
    try std.testing.expect((try interp.evalGreaterThan(b, a)).boolean);
    try std.testing.expect((try interp.evalLessEqual(a, a)).boolean);
    try std.testing.expect((try interp.evalGreaterEqual(b, b)).boolean);
}

test "interpreter division by zero" {
    const allocator = std.testing.allocator;

    var table = symbols.SymbolTable.init(allocator);
    defer table.deinit();

    var interp = Interpreter.init(allocator, &table);
    defer interp.deinit();

    const a = Value{ .integer = 10 };
    const zero = Value{ .integer = 0 };

    try std.testing.expectError(error.DivisionByZero, interp.evalDivide(a, zero));
}
