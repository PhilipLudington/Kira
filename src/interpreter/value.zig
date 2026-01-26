//! Runtime value representation for the Kira language interpreter.
//!
//! Values represent the runtime state of expressions after evaluation.
//! The interpreter evaluates AST nodes to produce these values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast/root.zig");
const Statement = ast.Statement;
const Expression = ast.Expression;
const Declaration = ast.Declaration;

/// Runtime value in the Kira interpreter.
/// All values are immutable except for explicit var bindings.
pub const Value = union(enum) {
    /// Integer value (i128 for maximum range, checked on type boundaries)
    integer: i128,

    /// Floating-point value
    float: f64,

    /// String value
    string: []const u8,

    /// Character value (Unicode codepoint)
    char: u21,

    /// Boolean value
    boolean: bool,

    /// Void value (unit type)
    void: void,

    /// Tuple value (heterogeneous, fixed-size collection)
    tuple: []const Value,

    /// Array value (homogeneous collection)
    array: []const Value,

    /// Record value (named fields)
    record: RecordValue,

    /// Function value (closure with captured environment)
    function: FunctionValue,

    /// Sum type variant (ADT constructor)
    variant: VariantValue,

    /// Option type: Some(value)
    some: *const Value,

    /// Option type: None
    none: void,

    /// Result type: Ok(value)
    ok: *const Value,

    /// Result type: Err(value)
    err: *const Value,

    /// List cons cell
    cons: ConsValue,

    /// Empty list
    nil: void,

    /// IO wrapper (for effect tracking at runtime)
    io: *const Value,

    /// A reference to a mutable variable (for var bindings)
    reference: *Value,

    /// Record fields mapped by name
    pub const RecordValue = struct {
        type_name: ?[]const u8,
        fields: std.StringArrayHashMapUnmanaged(Value),

        pub fn deinit(self: *RecordValue, allocator: Allocator) void {
            // Recursively free nested Values before freeing the hashmap
            for (self.fields.values()) |*val| {
                val.deinit(allocator);
            }
            self.fields.deinit(allocator);
        }
    };

    /// Free all nested allocations in this Value
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .record => |*r| r.deinit(allocator),
            .variant => |*v| {
                if (v.fields) |*fields| {
                    switch (fields.*) {
                        .tuple => |t| {
                            for (t) |*val| {
                                var mval = val.*;
                                mval.deinit(allocator);
                            }
                        },
                        .record => |*r| {
                            for (r.values()) |*val| {
                                val.deinit(allocator);
                            }
                            r.deinit(allocator);
                        },
                    }
                }
            },
            // These types don't have heap allocations that we own
            // (strings point to source, pointers are arena-allocated)
            else => {},
        }
    }

    /// Function value with captured environment
    pub const FunctionValue = struct {
        /// Function name (for named functions), null for closures
        name: ?[]const u8,

        /// Parameter names
        parameters: []const []const u8,

        /// Function body (statements)
        body: FunctionBody,

        /// Captured environment for closures
        captured_env: ?*Environment,

        /// Is this an effect function?
        is_effect: bool,

        pub const FunctionBody = union(enum) {
            /// AST body (statements to execute)
            ast_body: []const Statement,
            /// Builtin function (implemented in Zig)
            /// The context parameter allows builtins to call back into the interpreter
            /// for higher-order functions that need to invoke user-defined closures.
            builtin: *const fn (ctx: BuiltinContext, args: []const Value) InterpreterError!Value,
        };
    };

    /// Context passed to builtin functions, allowing them to call user-defined functions
    pub const BuiltinContext = struct {
        allocator: Allocator,
        /// Opaque pointer to the interpreter - use callFunction to invoke functions
        interpreter: ?*anyopaque,
        /// Function pointer to call a function value with arguments
        call_fn: ?*const fn (interp: *anyopaque, func: FunctionValue, args: []const Value) InterpreterError!Value,

        /// Call a function value (works for both builtins and AST-based functions)
        pub fn callFunction(self: BuiltinContext, func: FunctionValue, args: []const Value) InterpreterError!Value {
            if (self.interpreter) |interp| {
                if (self.call_fn) |call| {
                    return call(interp, func, args);
                }
            }
            // Fallback for builtins that don't need interpreter access
            switch (func.body) {
                .builtin => |builtin| return builtin(self, args),
                .ast_body => return error.InvalidOperation,
            }
        }
    };

    /// Sum type variant value
    pub const VariantValue = struct {
        /// Variant name (e.g., "Some", "None", "Ok", "Err")
        name: []const u8,

        /// Optional field values (tuple-style or record-style)
        fields: ?VariantFields,

        pub const VariantFields = union(enum) {
            tuple: []const Value,
            record: std.StringArrayHashMapUnmanaged(Value),
        };
    };

    /// Cons cell for List type
    pub const ConsValue = struct {
        head: *const Value,
        tail: *const Value,
    };

    /// Check if this value is truthy (for conditions)
    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .none, .nil => false,
            .void => false,
            else => true,
        };
    }

    /// Check if two values are equal
    pub fn eql(self: Value, other: Value) bool {
        const self_tag = std.meta.activeTag(self);
        const other_tag = std.meta.activeTag(other);

        if (self_tag != other_tag) return false;

        return switch (self) {
            .integer => |a| a == other.integer,
            .float => |a| a == other.float,
            .string => |a| std.mem.eql(u8, a, other.string),
            .char => |a| a == other.char,
            .boolean => |a| a == other.boolean,
            .void, .none, .nil => true,
            .tuple => |a| {
                const b = other.tuple;
                if (a.len != b.len) return false;
                for (a, b) |av, bv| {
                    if (!av.eql(bv)) return false;
                }
                return true;
            },
            .array => |a| {
                const b = other.array;
                if (a.len != b.len) return false;
                for (a, b) |av, bv| {
                    if (!av.eql(bv)) return false;
                }
                return true;
            },
            .record => |a| {
                const b = other.record;
                if (a.fields.count() != b.fields.count()) return false;
                for (a.fields.keys(), a.fields.values()) |key, val| {
                    if (b.fields.get(key)) |other_val| {
                        if (!val.eql(other_val)) return false;
                    } else {
                        return false;
                    }
                }
                return true;
            },
            .some => |a| a.eql(other.some.*),
            .ok => |a| a.eql(other.ok.*),
            .err => |a| a.eql(other.err.*),
            .cons => |a| a.head.eql(other.cons.head.*) and a.tail.eql(other.cons.tail.*),
            .variant => |a| {
                const b = other.variant;
                if (!std.mem.eql(u8, a.name, b.name)) return false;
                if (a.fields == null and b.fields == null) return true;
                if (a.fields == null or b.fields == null) return false;
                // Compare fields based on type
                switch (a.fields.?) {
                    .tuple => |at| {
                        if (b.fields.? != .tuple) return false;
                        const bt = b.fields.?.tuple;
                        if (at.len != bt.len) return false;
                        for (at, bt) |av, bv| {
                            if (!av.eql(bv)) return false;
                        }
                        return true;
                    },
                    .record => |ar| {
                        if (b.fields.? != .record) return false;
                        const br = b.fields.?.record;
                        if (ar.count() != br.count()) return false;
                        for (ar.keys(), ar.values()) |key, val| {
                            if (br.get(key)) |other_val| {
                                if (!val.eql(other_val)) return false;
                            } else {
                                return false;
                            }
                        }
                        return true;
                    },
                }
            },
            .function, .reference, .io => false, // Functions and references are compared by identity
        };
    }

    /// Format a value for display
    pub fn format(
        self: Value,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try self.write(writer);
    }

    /// Write value to writer (for user-facing output)
    pub fn write(self: Value, writer: anytype) !void {
        try self.writeImpl(writer, false);
    }

    /// Write value to writer with debug formatting (shows quotes around strings)
    pub fn writeDebug(self: Value, writer: anytype) !void {
        try self.writeImpl(writer, true);
    }

    /// Internal write implementation
    fn writeImpl(self: Value, writer: anytype, debug_mode: bool) !void {
        switch (self) {
            .integer => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |v| {
                if (debug_mode) {
                    try writer.print("\"{s}\"", .{v});
                } else {
                    try writer.writeAll(v);
                }
            },
            .char => |v| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(v, &buf) catch 1;
                if (debug_mode) {
                    try writer.print("'{s}'", .{buf[0..len]});
                } else {
                    try writer.writeAll(buf[0..len]);
                }
            },
            .boolean => |v| try writer.print("{}", .{v}),
            .void => try writer.writeAll("()"),
            .none => try writer.writeAll("None"),
            .nil => try writer.writeAll("[]"),
            .tuple => |t| {
                try writer.writeAll("(");
                for (t, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.writeImpl(writer, debug_mode);
                }
                try writer.writeAll(")");
            },
            .array => |a| {
                try writer.writeAll("[");
                for (a, 0..) |v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try v.writeImpl(writer, debug_mode);
                }
                try writer.writeAll("]");
            },
            .record => |r| {
                if (r.type_name) |name| {
                    try writer.print("{s} {{ ", .{name});
                } else {
                    try writer.writeAll("{ ");
                }
                var first = true;
                for (r.fields.keys(), r.fields.values()) |key, val| {
                    if (!first) try writer.writeAll(", ");
                    try writer.print("{s}: ", .{key});
                    try val.writeImpl(writer, debug_mode);
                    first = false;
                }
                try writer.writeAll(" }");
            },
            .function => |f| {
                if (f.name) |name| {
                    try writer.print("<fn {s}>", .{name});
                } else {
                    try writer.writeAll("<closure>");
                }
            },
            .variant => |v| {
                try writer.print("{s}", .{v.name});
                if (v.fields) |fields| {
                    switch (fields) {
                        .tuple => |t| {
                            try writer.writeAll("(");
                            for (t, 0..) |val, i| {
                                if (i > 0) try writer.writeAll(", ");
                                try val.writeImpl(writer, debug_mode);
                            }
                            try writer.writeAll(")");
                        },
                        .record => |r| {
                            try writer.writeAll(" { ");
                            var first = true;
                            for (r.keys(), r.values()) |key, val| {
                                if (!first) try writer.writeAll(", ");
                                try writer.print("{s}: ", .{key});
                                try val.writeImpl(writer, debug_mode);
                                first = false;
                            }
                            try writer.writeAll(" }");
                        },
                    }
                }
            },
            .some => |v| {
                try writer.writeAll("Some(");
                try v.writeImpl(writer, debug_mode);
                try writer.writeAll(")");
            },
            .ok => |v| {
                try writer.writeAll("Ok(");
                try v.writeImpl(writer, debug_mode);
                try writer.writeAll(")");
            },
            .err => |v| {
                try writer.writeAll("Err(");
                try v.writeImpl(writer, debug_mode);
                try writer.writeAll(")");
            },
            .cons => |c| {
                try writer.writeAll("[");
                try c.head.writeImpl(writer, debug_mode);
                var current: Value = c.tail.*;
                while (current == .cons) {
                    try writer.writeAll(", ");
                    try current.cons.head.writeImpl(writer, debug_mode);
                    current = current.cons.tail.*;
                }
                try writer.writeAll("]");
            },
            .io => |v| {
                try writer.writeAll("IO(");
                try v.writeImpl(writer, debug_mode);
                try writer.writeAll(")");
            },
            .reference => |r| {
                try writer.writeAll("&");
                try r.writeImpl(writer, debug_mode);
            },
        }
    }

    /// Convert value to a string (allocates)
    pub fn toString(self: Value, allocator: Allocator) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8){};
        try self.write(list.writer(allocator));
        return list.toOwnedSlice(allocator);
    }
};

/// Environment for variable bindings with lexical scoping.
pub const Environment = struct {
    allocator: Allocator,
    parent: ?*Environment,
    bindings: std.StringArrayHashMapUnmanaged(Binding),

    /// A binding in the environment (value + mutability)
    pub const Binding = struct {
        value: Value,
        is_mutable: bool,
    };

    /// Create a new environment
    pub fn init(allocator: Allocator) Environment {
        return .{
            .allocator = allocator,
            .parent = null,
            .bindings = .{},
        };
    }

    /// Create a new environment with a parent (for nested scopes)
    pub fn initWithParent(allocator: Allocator, parent: *Environment) Environment {
        return .{
            .allocator = allocator,
            .parent = parent,
            .bindings = .{},
        };
    }

    /// Clean up the environment
    /// Note: Values inside bindings are expected to be allocated with an arena allocator
    /// that outlives the environment, so we only free the bindings hashmap itself.
    pub fn deinit(self: *Environment) void {
        self.bindings.deinit(self.allocator);
    }

    /// Define a new binding in the current scope
    pub fn define(self: *Environment, name: []const u8, value: Value, is_mutable: bool) !void {
        try self.bindings.put(self.allocator, name, .{ .value = value, .is_mutable = is_mutable });
    }

    /// Get a binding from this scope or parent scopes
    pub fn get(self: *const Environment, name: []const u8) ?*const Binding {
        if (self.bindings.getPtr(name)) |binding| {
            return binding;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }

    /// Get a mutable binding for assignment
    pub fn getMutable(self: *Environment, name: []const u8) ?*Binding {
        if (self.bindings.getPtr(name)) |binding| {
            return binding;
        }
        if (self.parent) |parent| {
            return parent.getMutable(name);
        }
        return null;
    }

    /// Assign to an existing mutable binding
    pub fn assign(self: *Environment, name: []const u8, value: Value) InterpreterError!void {
        if (self.getMutable(name)) |binding| {
            if (!binding.is_mutable) {
                return error.ImmutableAssignment;
            }
            binding.value = value;
        } else {
            return error.UndefinedVariable;
        }
    }
};

/// Errors that can occur during interpretation.
pub const InterpreterError = error{
    /// Variable not found in scope
    UndefinedVariable,
    /// Attempted to assign to immutable binding
    ImmutableAssignment,
    /// Type mismatch at runtime (shouldn't happen after type checking)
    TypeMismatch,
    /// Division by zero
    DivisionByZero,
    /// Index out of bounds for array/tuple access
    IndexOutOfBounds,
    /// Field not found in record
    FieldNotFound,
    /// Not callable (attempted to call non-function)
    NotCallable,
    /// Wrong number of arguments
    ArityMismatch,
    /// Pattern match failed (non-exhaustive - shouldn't happen after type checking)
    MatchFailed,
    /// Break encountered (used for control flow)
    BreakEncountered,
    /// Return encountered (used for control flow)
    ReturnEncountered,
    /// Error propagation with ? operator
    ErrorPropagation,
    /// Overflow in arithmetic operation
    Overflow,
    /// Out of memory
    OutOfMemory,
    /// Invalid operation
    InvalidOperation,
    /// Assertion failed
    AssertionFailed,
    /// Stack overflow (recursion depth exceeded)
    StackOverflow,
};

test "value equality" {
    // Integer equality
    const int1 = Value{ .integer = 42 };
    const int2 = Value{ .integer = 42 };
    const int3 = Value{ .integer = 43 };
    try std.testing.expect(int1.eql(int2));
    try std.testing.expect(!int1.eql(int3));

    // Boolean equality
    const bool1 = Value{ .boolean = true };
    const bool2 = Value{ .boolean = true };
    const bool3 = Value{ .boolean = false };
    try std.testing.expect(bool1.eql(bool2));
    try std.testing.expect(!bool1.eql(bool3));

    // String equality
    const str1 = Value{ .string = "hello" };
    const str2 = Value{ .string = "hello" };
    const str3 = Value{ .string = "world" };
    try std.testing.expect(str1.eql(str2));
    try std.testing.expect(!str1.eql(str3));

    // None equality
    const none1 = Value{ .none = {} };
    const none2 = Value{ .none = {} };
    try std.testing.expect(none1.eql(none2));
}

test "value truthiness" {
    try std.testing.expect((Value{ .boolean = true }).isTruthy());
    try std.testing.expect(!(Value{ .boolean = false }).isTruthy());
    try std.testing.expect((Value{ .integer = 42 }).isTruthy());
    try std.testing.expect(!(Value{ .none = {} }).isTruthy());
    try std.testing.expect(!(Value{ .nil = {} }).isTruthy());
    try std.testing.expect(!(Value{ .void = {} }).isTruthy());
}

test "environment basic operations" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    // Define and get
    try env.define("x", .{ .integer = 42 }, false);
    const binding = env.get("x");
    try std.testing.expect(binding != null);
    try std.testing.expectEqual(@as(i128, 42), binding.?.value.integer);
    try std.testing.expect(!binding.?.is_mutable);

    // Undefined variable
    try std.testing.expect(env.get("y") == null);
}

test "environment nested scopes" {
    var parent = Environment.init(std.testing.allocator);
    defer parent.deinit();

    try parent.define("x", .{ .integer = 1 }, false);

    var child = Environment.initWithParent(std.testing.allocator, &parent);
    defer child.deinit();

    try child.define("y", .{ .integer = 2 }, false);

    // Child can see parent's bindings
    const x = child.get("x");
    try std.testing.expect(x != null);
    try std.testing.expectEqual(@as(i128, 1), x.?.value.integer);

    // Child has its own bindings
    const y = child.get("y");
    try std.testing.expect(y != null);
    try std.testing.expectEqual(@as(i128, 2), y.?.value.integer);

    // Parent cannot see child's bindings
    try std.testing.expect(parent.get("y") == null);
}

test "environment mutable assignment" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();

    // Mutable binding
    try env.define("x", .{ .integer = 1 }, true);
    try env.assign("x", .{ .integer = 2 });
    const binding = env.get("x");
    try std.testing.expectEqual(@as(i128, 2), binding.?.value.integer);

    // Immutable binding cannot be assigned
    try env.define("y", .{ .integer = 1 }, false);
    try std.testing.expectError(error.ImmutableAssignment, env.assign("y", .{ .integer = 2 }));

    // Undefined variable cannot be assigned
    try std.testing.expectError(error.UndefinedVariable, env.assign("z", .{ .integer = 1 }));
}
