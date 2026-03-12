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

        /// Is this function memoized?
        is_memoized: bool,

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
        /// Environment arguments (command-line args passed to the program)
        env_args: ?[]const Value,
        /// Optional buffer for capturing stdout output (used in E2E tests).
        /// When set, print/println write here instead of real stdout.
        stdout_capture: ?*std.ArrayListUnmanaged(u8) = null,
        /// Allocator for stdout_capture append operations.
        stdout_capture_alloc: ?Allocator = null,

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

    /// Check if this value type is eligible for memoization cache keys.
    /// Only deterministic, immutable value types can be used as cache keys.
    pub fn isCacheable(self: Value) bool {
        return switch (self) {
            .integer, .string, .char, .boolean, .void, .none, .nil => true,
            // NaN != NaN breaks cache lookup invariant, so exclude NaN floats
            .float => |v| !std.math.isNan(v),
            .tuple => |t| {
                for (t) |v| {
                    if (!v.isCacheable()) return false;
                }
                return true;
            },
            .record => |r| {
                for (r.fields.values()) |v| {
                    if (!v.isCacheable()) return false;
                }
                return true;
            },
            .variant => |v| {
                if (v.fields) |fields| {
                    switch (fields) {
                        .tuple => |t| {
                            for (t) |val| {
                                if (!val.isCacheable()) return false;
                            }
                        },
                        .record => |r| {
                            for (r.values()) |val| {
                                if (!val.isCacheable()) return false;
                            }
                        },
                    }
                }
                return true;
            },
            .some => |v| v.isCacheable(),
            .ok => |v| v.isCacheable(),
            .err => |v| v.isCacheable(),
            .cons => |c| c.head.isCacheable() and c.tail.isCacheable(),
            // Functions, references, IO are not cacheable
            .function, .reference, .io, .array => false,
        };
    }

    /// Compute a hash for this value (for use as memoization cache key).
    /// Only valid for cacheable value types.
    pub fn hash(self: Value) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hashInto(&hasher);
        return hasher.final();
    }

    pub fn hashInto(self: Value, hasher: *std.hash.Wyhash) void {
        // Mix in the tag to distinguish types
        const tag = @intFromEnum(std.meta.activeTag(self));
        hasher.update(std.mem.asBytes(&tag));

        switch (self) {
            .integer => |v| hasher.update(std.mem.asBytes(&v)),
            .float => |v| hasher.update(std.mem.asBytes(&v)),
            .string => |v| hasher.update(v),
            .char => |v| hasher.update(std.mem.asBytes(&v)),
            .boolean => |v| hasher.update(std.mem.asBytes(&v)),
            .void, .none, .nil => {},
            .tuple => |t| {
                for (t) |v| v.hashInto(hasher);
            },
            .array => |a| {
                for (a) |v| v.hashInto(hasher);
            },
            .record => |r| {
                for (r.fields.keys(), r.fields.values()) |key, val| {
                    hasher.update(key);
                    val.hashInto(hasher);
                }
            },
            .variant => |v| {
                hasher.update(v.name);
                if (v.fields) |fields| {
                    switch (fields) {
                        .tuple => |t| {
                            for (t) |val| val.hashInto(hasher);
                        },
                        .record => |r| {
                            for (r.keys(), r.values()) |key, val| {
                                hasher.update(key);
                                val.hashInto(hasher);
                            }
                        },
                    }
                }
            },
            .some => |v| v.hashInto(hasher),
            .ok => |v| v.hashInto(hasher),
            .err => |v| v.hashInto(hasher),
            .cons => |c| {
                c.head.hashInto(hasher);
                c.tail.hashInto(hasher);
            },
            // Non-cacheable types: no meaningful hash, but handle for completeness
            .function, .reference, .io => {},
        }
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
    /// Tail call encountered (used for TCO)
    TailCallEncountered,
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

test "value cacheability" {
    // Primitives are cacheable
    try std.testing.expect((Value{ .integer = 42 }).isCacheable());
    try std.testing.expect((Value{ .float = 3.14 }).isCacheable());
    try std.testing.expect((Value{ .string = "hello" }).isCacheable());
    try std.testing.expect((Value{ .char = 'a' }).isCacheable());
    try std.testing.expect((Value{ .boolean = true }).isCacheable());
    try std.testing.expect((Value{ .void = {} }).isCacheable());
    try std.testing.expect((Value{ .none = {} }).isCacheable());
    try std.testing.expect((Value{ .nil = {} }).isCacheable());

    // Tuples of cacheable values are cacheable
    const tuple_vals = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    try std.testing.expect((Value{ .tuple = &tuple_vals }).isCacheable());

    // Non-cacheable types
    try std.testing.expect(!(Value{ .function = .{
        .name = null,
        .parameters = &.{},
        .body = .{ .ast_body = &.{} },
        .captured_env = null,
        .is_effect = false,
        .is_memoized = false,
    } }).isCacheable());

    const arr = [_]Value{.{ .integer = 1 }};
    try std.testing.expect(!(Value{ .array = &arr }).isCacheable());

    // NaN floats are not cacheable (NaN != NaN breaks cache invariant)
    try std.testing.expect(!(Value{ .float = std.math.nan(f64) }).isCacheable());

    // Tuple containing non-cacheable element is not cacheable
    const mixed_tuple = [_]Value{ .{ .integer = 1 }, .{ .array = &arr } };
    try std.testing.expect(!(Value{ .tuple = &mixed_tuple }).isCacheable());
}

test "value hashing" {
    // Same values produce same hash
    const a = Value{ .integer = 42 };
    const b = Value{ .integer = 42 };
    try std.testing.expectEqual(a.hash(), b.hash());

    // Different values produce different hash
    const c = Value{ .integer = 43 };
    try std.testing.expect(a.hash() != c.hash());

    // Different types produce different hash
    const d = Value{ .string = "42" };
    try std.testing.expect(a.hash() != d.hash());

    // Bool hashing works
    const t = Value{ .boolean = true };
    const f = Value{ .boolean = false };
    try std.testing.expect(t.hash() != f.hash());

    // Float hashing
    const f1 = Value{ .float = 1.5 };
    const f2 = Value{ .float = 1.5 };
    const f3 = Value{ .float = 2.5 };
    try std.testing.expectEqual(f1.hash(), f2.hash());
    try std.testing.expect(f1.hash() != f3.hash());

    // Char hashing
    const ch1 = Value{ .char = 'a' };
    const ch2 = Value{ .char = 'b' };
    try std.testing.expect(ch1.hash() != ch2.hash());

    // Void/None/Nil have distinct hashes (different tags)
    const void_v = Value{ .void = {} };
    const none_v = Value{ .none = {} };
    const nil_v = Value{ .nil = {} };
    try std.testing.expect(void_v.hash() != none_v.hash());
    try std.testing.expect(none_v.hash() != nil_v.hash());

    // Tuple hashing
    const t1 = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const t2 = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 } };
    const t3 = [_]Value{ .{ .integer = 2 }, .{ .integer = 1 } };
    try std.testing.expectEqual((Value{ .tuple = &t1 }).hash(), (Value{ .tuple = &t2 }).hash());
    try std.testing.expect((Value{ .tuple = &t1 }).hash() != (Value{ .tuple = &t3 }).hash());
}

test "MemoCache lookup and store" {
    const allocator = std.testing.allocator;

    // Use an arena so we don't need to manually free cache internals
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var cache = @import("interpreter.zig").Interpreter.MemoCache{};

    // Empty cache returns null
    const args1 = [_]Value{.{ .integer = 5 }};
    try std.testing.expect(cache.lookup("fib", &args1) == null);

    // Store and retrieve
    cache.store(arena_alloc, "fib", &args1, .{ .integer = 5 });
    const result = cache.lookup("fib", &args1);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i128, 5), result.?.integer);

    // Different args return null
    const args2 = [_]Value{.{ .integer = 6 }};
    try std.testing.expect(cache.lookup("fib", &args2) == null);

    // Different function name returns null
    try std.testing.expect(cache.lookup("other", &args1) == null);

    // Store another entry for same function
    cache.store(arena_alloc, "fib", &args2, .{ .integer = 8 });
    const result2 = cache.lookup("fib", &args2);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(i128, 8), result2.?.integer);

    // Original entry still works
    const result3 = cache.lookup("fib", &args1);
    try std.testing.expect(result3 != null);
    try std.testing.expectEqual(@as(i128, 5), result3.?.integer);

    // Zero-arg function
    cache.store(arena_alloc, "zero", &.{}, .{ .integer = 0 });
    const result4 = cache.lookup("zero", &.{});
    try std.testing.expect(result4 != null);
    try std.testing.expectEqual(@as(i128, 0), result4.?.integer);

    // Multi-arg function
    const multi_args = [_]Value{ .{ .integer = 1 }, .{ .string = "hello" } };
    cache.store(arena_alloc, "multi", &multi_args, .{ .boolean = true });
    const result5 = cache.lookup("multi", &multi_args);
    try std.testing.expect(result5 != null);
    try std.testing.expect(result5.?.boolean);
}
