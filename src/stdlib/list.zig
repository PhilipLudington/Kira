//! std.list - List operations for the Kira standard library.
//!
//! Provides functional operations on linked lists (cons cells):
//!   - empty, singleton, cons: Construction
//!   - map, filter, fold, fold_right: Higher-order functions
//!   - find, any, all: Searching and predicates
//!   - length, reverse: Basic operations
//!   - concat, flatten: Combining lists
//!   - take, drop, zip: Slicing and combining

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;

/// Create the std.list module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    // Construction
    try fields.put(allocator, "empty", root.makeBuiltin("empty", &listEmpty));
    try fields.put(allocator, "singleton", root.makeBuiltin("singleton", &listSingleton));
    try fields.put(allocator, "cons", root.makeBuiltin("cons", &listCons));

    // Higher-order functions
    try fields.put(allocator, "map", root.makeBuiltin("map", &listMap));
    try fields.put(allocator, "filter", root.makeBuiltin("filter", &listFilter));
    try fields.put(allocator, "fold", root.makeBuiltin("fold", &listFold));
    try fields.put(allocator, "fold_right", root.makeBuiltin("fold_right", &listFoldRight));

    // Searching and predicates
    try fields.put(allocator, "find", root.makeBuiltin("find", &listFind));
    try fields.put(allocator, "any", root.makeBuiltin("any", &listAny));
    try fields.put(allocator, "all", root.makeBuiltin("all", &listAll));

    // Basic operations
    try fields.put(allocator, "length", root.makeBuiltin("length", &listLength));
    try fields.put(allocator, "reverse", root.makeBuiltin("reverse", &listReverse));

    // Combining lists
    try fields.put(allocator, "concat", root.makeBuiltin("concat", &listConcat));
    try fields.put(allocator, "flatten", root.makeBuiltin("flatten", &listFlatten));

    // Slicing
    try fields.put(allocator, "take", root.makeBuiltin("take", &listTake));
    try fields.put(allocator, "drop", root.makeBuiltin("drop", &listDrop));
    try fields.put(allocator, "zip", root.makeBuiltin("zip", &listZip));

    return Value{
        .record = .{
            .type_name = "std.list",
            .fields = fields,
        },
    };
}

// ============================================================================
// Construction
// ============================================================================

/// Returns an empty list (Nil)
fn listEmpty(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;
    return Value{ .nil = {} };
}

/// Creates a single-element list
fn listSingleton(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const head = allocator.create(Value) catch return error.OutOfMemory;
    const tail = allocator.create(Value) catch return error.OutOfMemory;
    head.* = args[0];
    tail.* = Value{ .nil = {} };

    return Value{ .cons = .{ .head = head, .tail = tail } };
}

/// Prepend an element to a list: cons(x, xs) -> [x, ...xs]
fn listCons(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // Validate second arg is a list
    switch (args[1]) {
        .cons, .nil => {},
        else => return error.TypeMismatch,
    }

    const head = allocator.create(Value) catch return error.OutOfMemory;
    const tail = allocator.create(Value) catch return error.OutOfMemory;
    head.* = args[0];
    tail.* = args[1];

    return Value{ .cons = .{ .head = head, .tail = tail } };
}

// ============================================================================
// Higher-Order Functions
// ============================================================================

/// Apply a function to each element: map(fn, list) -> list
fn listMap(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    // Convert list to array, apply function, convert back
    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var current = args[1];
    while (current == .cons) {
        const result = try applyFunction(allocator, func, &.{current.cons.head.*});
        elements.append(allocator, result) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    // Build result list in reverse order
    return buildList(allocator, elements.items);
}

/// Keep elements matching predicate: filter(fn, list) -> list
fn listFilter(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var current = args[1];
    while (current == .cons) {
        const elem = current.cons.head.*;
        const result = try applyFunction(allocator, func, &.{elem});
        if (result.isTruthy()) {
            elements.append(allocator, elem) catch return error.OutOfMemory;
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return buildList(allocator, elements.items);
}

/// Left fold: fold(fn, init, list) -> value
/// fold(f, z, [a,b,c]) = f(f(f(z, a), b), c)
fn listFold(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    var acc = args[1];
    var current = args[2];

    while (current == .cons) {
        acc = try applyFunction(allocator, func, &.{ acc, current.cons.head.* });
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return acc;
}

/// Right fold: fold_right(fn, list, init) -> value
/// fold_right(f, [a,b,c], z) = f(a, f(b, f(c, z)))
fn listFoldRight(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    // Collect elements first (need to traverse right-to-left)
    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var current = args[1];
    while (current == .cons) {
        elements.append(allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    // Fold from right
    var acc = args[2];
    var i = elements.items.len;
    while (i > 0) {
        i -= 1;
        acc = try applyFunction(allocator, func, &.{ elements.items[i], acc });
    }

    return acc;
}

// ============================================================================
// Searching and Predicates
// ============================================================================

/// Find first element matching predicate: find(fn, list) -> Option[T]
fn listFind(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    var current = args[1];
    while (current == .cons) {
        const elem = current.cons.head.*;
        const result = try applyFunction(allocator, func, &.{elem});
        if (result.isTruthy()) {
            const inner = allocator.create(Value) catch return error.OutOfMemory;
            inner.* = elem;
            return Value{ .some = inner };
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .none = {} };
}

/// Check if any element matches predicate: any(fn, list) -> bool
fn listAny(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    var current = args[1];
    while (current == .cons) {
        const result = try applyFunction(allocator, func, &.{current.cons.head.*});
        if (result.isTruthy()) {
            return Value{ .boolean = true };
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .boolean = false };
}

/// Check if all elements match predicate: all(fn, list) -> bool
fn listAll(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const func = switch (args[0]) {
        .function => args[0],
        else => return error.TypeMismatch,
    };

    var current = args[1];
    while (current == .cons) {
        const result = try applyFunction(allocator, func, &.{current.cons.head.*});
        if (!result.isTruthy()) {
            return Value{ .boolean = false };
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .boolean = true };
}

// ============================================================================
// Basic Operations
// ============================================================================

/// Get list length: length(list) -> int
fn listLength(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    var count: i128 = 0;
    var current = args[0];

    while (current == .cons) {
        count += 1;
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .integer = count };
}

/// Reverse a list: reverse(list) -> list
fn listReverse(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    var result: Value = Value{ .nil = {} };
    var current = args[0];

    while (current == .cons) {
        const head = allocator.create(Value) catch return error.OutOfMemory;
        const tail = allocator.create(Value) catch return error.OutOfMemory;
        head.* = current.cons.head.*;
        tail.* = result;
        result = Value{ .cons = .{ .head = head, .tail = tail } };
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return result;
}

// ============================================================================
// Combining Lists
// ============================================================================

/// Concatenate two lists: concat(list1, list2) -> list
fn listConcat(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // Collect first list elements
    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var current = args[0];
    while (current == .cons) {
        elements.append(allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }
    if (current != .nil) return error.TypeMismatch;

    // Collect second list elements
    current = args[1];
    while (current == .cons) {
        elements.append(allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }
    if (current != .nil) return error.TypeMismatch;

    return buildList(allocator, elements.items);
}

/// Flatten a list of lists: flatten(list_of_lists) -> list
fn listFlatten(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var outer = args[0];
    while (outer == .cons) {
        var inner = outer.cons.head.*;
        while (inner == .cons) {
            elements.append(allocator, inner.cons.head.*) catch return error.OutOfMemory;
            inner = inner.cons.tail.*;
        }
        if (inner != .nil) return error.TypeMismatch;
        outer = outer.cons.tail.*;
    }
    if (outer != .nil) return error.TypeMismatch;

    return buildList(allocator, elements.items);
}

// ============================================================================
// Slicing
// ============================================================================

/// Take first n elements: take(n, list) -> list
fn listTake(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const n = switch (args[0]) {
        .integer => |i| if (i < 0) return error.InvalidOperation else @as(usize, @intCast(i)),
        else => return error.TypeMismatch,
    };

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var current = args[1];
    var count: usize = 0;

    while (current == .cons and count < n) {
        elements.append(allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
        count += 1;
    }

    return buildList(allocator, elements.items);
}

/// Drop first n elements: drop(n, list) -> list
fn listDrop(_: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const n = switch (args[0]) {
        .integer => |i| if (i < 0) return error.InvalidOperation else @as(usize, @intCast(i)),
        else => return error.TypeMismatch,
    };

    var current = args[1];
    var count: usize = 0;

    while (current == .cons and count < n) {
        current = current.cons.tail.*;
        count += 1;
    }

    return current;
}

/// Zip two lists into a list of tuples: zip(list1, list2) -> list of (a, b)
fn listZip(allocator: Allocator, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(allocator);

    var list1 = args[0];
    var list2 = args[1];

    while (list1 == .cons and list2 == .cons) {
        // Create tuple of (head1, head2)
        const tuple = allocator.alloc(Value, 2) catch return error.OutOfMemory;
        tuple[0] = list1.cons.head.*;
        tuple[1] = list2.cons.head.*;
        elements.append(allocator, Value{ .tuple = tuple }) catch return error.OutOfMemory;

        list1 = list1.cons.tail.*;
        list2 = list2.cons.tail.*;
    }

    return buildList(allocator, elements.items);
}

// ============================================================================
// Helpers
// ============================================================================

/// Build a list from a slice of values
fn buildList(allocator: Allocator, items: []const Value) InterpreterError!Value {
    var result: Value = Value{ .nil = {} };

    // Build in reverse to get correct order
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const head = allocator.create(Value) catch return error.OutOfMemory;
        const tail = allocator.create(Value) catch return error.OutOfMemory;
        head.* = items[i];
        tail.* = result;
        result = Value{ .cons = .{ .head = head, .tail = tail } };
    }

    return result;
}

/// Apply a function to arguments (simplified - doesn't handle closures with AST bodies)
/// For higher-order functions, we need to call through the interpreter.
/// This is a placeholder that works for builtin functions only.
fn applyFunction(allocator: Allocator, func: Value, args: []const Value) InterpreterError!Value {
    const f = func.function;
    switch (f.body) {
        .builtin => |builtin| return builtin(allocator, args),
        .ast_body => {
            // For user-defined functions, we would need access to the interpreter
            // This is a limitation of the current design - higher-order functions
            // with user-defined function arguments would need interpreter integration
            return error.InvalidOperation;
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "list construction" {
    const allocator = std.testing.allocator;

    // Empty list
    const empty = try listEmpty(allocator, &.{});
    try std.testing.expect(empty == .nil);

    // Singleton
    const single = try listSingleton(allocator, &.{Value{ .integer = 42 }});
    try std.testing.expect(single == .cons);
    try std.testing.expectEqual(@as(i128, 42), single.cons.head.integer);
    try std.testing.expect(single.cons.tail.* == .nil);

    // Cons
    const list = try listCons(allocator, &.{ Value{ .integer = 1 }, single });
    try std.testing.expect(list == .cons);
    try std.testing.expectEqual(@as(i128, 1), list.cons.head.integer);
}

test "list length" {
    const allocator = std.testing.allocator;

    // Empty list
    const empty_len = try listLength(allocator, &.{Value{ .nil = {} }});
    try std.testing.expectEqual(@as(i128, 0), empty_len.integer);

    // Build [1, 2, 3]
    const list = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    });
    const len = try listLength(allocator, &.{list});
    try std.testing.expectEqual(@as(i128, 3), len.integer);
}

test "list reverse" {
    const allocator = std.testing.allocator;

    // Build [1, 2, 3]
    const list = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    });

    const reversed = try listReverse(allocator, &.{list});

    // Should be [3, 2, 1]
    try std.testing.expect(reversed == .cons);
    try std.testing.expectEqual(@as(i128, 3), reversed.cons.head.integer);
    try std.testing.expectEqual(@as(i128, 2), reversed.cons.tail.cons.head.integer);
    try std.testing.expectEqual(@as(i128, 1), reversed.cons.tail.cons.tail.cons.head.integer);
}

test "list take and drop" {
    const allocator = std.testing.allocator;

    // Build [1, 2, 3, 4, 5]
    const list = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
        Value{ .integer = 4 },
        Value{ .integer = 5 },
    });

    // Take 2 -> [1, 2]
    const taken = try listTake(allocator, &.{ Value{ .integer = 2 }, list });
    const taken_len = try listLength(allocator, &.{taken});
    try std.testing.expectEqual(@as(i128, 2), taken_len.integer);

    // Drop 2 -> [3, 4, 5]
    const dropped = try listDrop(allocator, &.{ Value{ .integer = 2 }, list });
    const dropped_len = try listLength(allocator, &.{dropped});
    try std.testing.expectEqual(@as(i128, 3), dropped_len.integer);
    try std.testing.expectEqual(@as(i128, 3), dropped.cons.head.integer);
}

test "list concat" {
    const allocator = std.testing.allocator;

    const list1 = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    });
    const list2 = try buildList(allocator, &.{
        Value{ .integer = 3 },
        Value{ .integer = 4 },
    });

    const combined = try listConcat(allocator, &.{ list1, list2 });
    const len = try listLength(allocator, &.{combined});
    try std.testing.expectEqual(@as(i128, 4), len.integer);
}
