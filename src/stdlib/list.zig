//! std.list - List operations for the Kira standard library.
//!
//! Provides functional operations on linked lists (cons cells):
//!   - empty, singleton, cons: Construction
//!   - map, filter, fold, fold_right, foreach: Higher-order functions
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
const BuiltinContext = root.BuiltinContext;

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
    try fields.put(allocator, "foreach", root.makeBuiltin("foreach", &listForeach));

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
fn listEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 0) return error.ArityMismatch;
    return Value{ .nil = {} };
}

/// Creates a single-element list
fn listSingleton(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    const head = ctx.allocator.create(Value) catch return error.OutOfMemory;
    const tail = ctx.allocator.create(Value) catch return error.OutOfMemory;
    head.* = args[0];
    tail.* = Value{ .nil = {} };

    return Value{ .cons = .{ .head = head, .tail = tail } };
}

/// Prepend an element to a list: cons(x, xs) -> [x, ...xs]
fn listCons(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // Validate second arg is a list
    switch (args[1]) {
        .cons, .nil => {},
        else => return error.TypeMismatch,
    }

    const head = ctx.allocator.create(Value) catch return error.OutOfMemory;
    const tail = ctx.allocator.create(Value) catch return error.OutOfMemory;
    head.* = args[0];
    tail.* = args[1];

    return Value{ .cons = .{ .head = head, .tail = tail } };
}

// ============================================================================
// Higher-Order Functions
// ============================================================================

/// Apply a function to each element: map(list, fn) -> list
fn listMap(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = list, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    // Convert list to array, apply function, convert back
    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var current = args[0];
    while (current == .cons) {
        const result = try ctx.callFunction(func, &.{current.cons.head.*});
        elements.append(ctx.allocator, result) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    // Build result list in reverse order
    return buildList(ctx.allocator, elements.items);
}

/// Keep elements matching predicate: filter(list, fn) -> list
fn listFilter(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = list, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var current = args[0];
    while (current == .cons) {
        const elem = current.cons.head.*;
        const result = try ctx.callFunction(func, &.{elem});
        if (result.isTruthy()) {
            elements.append(ctx.allocator, elem) catch return error.OutOfMemory;
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return buildList(ctx.allocator, elements.items);
}

/// Left fold: fold(list, init, fn) -> value
/// fold([a,b,c], z, f) = f(f(f(z, a), b), c)
fn listFold(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    // args[0] = list, args[1] = init, args[2] = function
    const func = switch (args[2]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    var acc = args[1];
    var current = args[0];

    while (current == .cons) {
        acc = try ctx.callFunction(func, &.{ acc, current.cons.head.* });
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return acc;
}

/// Right fold: fold_right(list, init, fn) -> value
/// fold_right([a,b,c], z, f) = f(a, f(b, f(c, z)))
fn listFoldRight(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    // args[0] = list, args[1] = init, args[2] = function
    const func = switch (args[2]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    // Collect elements first (need to traverse right-to-left)
    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var current = args[0];
    while (current == .cons) {
        elements.append(ctx.allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    // Fold from right
    var acc = args[1];
    var i = elements.items.len;
    while (i > 0) {
        i -= 1;
        acc = try ctx.callFunction(func, &.{ elements.items[i], acc });
    }

    return acc;
}

/// Apply a function to each element for side effects: foreach(list, fn) -> void
fn listForeach(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = list, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    var current = args[0];
    while (current == .cons) {
        _ = try ctx.callFunction(func, &.{current.cons.head.*});
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .void = {} };
}

// ============================================================================
// Searching and Predicates
// ============================================================================

/// Find first element matching predicate: find(list, fn) -> Option[T]
fn listFind(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = list, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    var current = args[0];
    while (current == .cons) {
        const elem = current.cons.head.*;
        const result = try ctx.callFunction(func, &.{elem});
        if (result.isTruthy()) {
            const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
            inner.* = elem;
            return Value{ .some = inner };
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .none = {} };
}

/// Check if any element matches predicate: any(list, fn) -> bool
fn listAny(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = list, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    var current = args[0];
    while (current == .cons) {
        const result = try ctx.callFunction(func, &.{current.cons.head.*});
        if (result.isTruthy()) {
            return Value{ .boolean = true };
        }
        current = current.cons.tail.*;
    }

    if (current != .nil) return error.TypeMismatch;

    return Value{ .boolean = false };
}

/// Check if all elements match predicate: all(list, fn) -> bool
fn listAll(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // args[0] = list, args[1] = function
    const func = switch (args[1]) {
        .function => |f| f,
        else => return error.TypeMismatch,
    };

    var current = args[0];
    while (current == .cons) {
        const result = try ctx.callFunction(func, &.{current.cons.head.*});
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
fn listLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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
fn listReverse(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    var result: Value = Value{ .nil = {} };
    var current = args[0];

    while (current == .cons) {
        const head = ctx.allocator.create(Value) catch return error.OutOfMemory;
        const tail = ctx.allocator.create(Value) catch return error.OutOfMemory;
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
fn listConcat(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    // Collect first list elements
    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var current = args[0];
    while (current == .cons) {
        elements.append(ctx.allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }
    if (current != .nil) return error.TypeMismatch;

    // Collect second list elements
    current = args[1];
    while (current == .cons) {
        elements.append(ctx.allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
    }
    if (current != .nil) return error.TypeMismatch;

    return buildList(ctx.allocator, elements.items);
}

/// Flatten a list of lists: flatten(list_of_lists) -> list
fn listFlatten(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var outer = args[0];
    while (outer == .cons) {
        var inner = outer.cons.head.*;
        while (inner == .cons) {
            elements.append(ctx.allocator, inner.cons.head.*) catch return error.OutOfMemory;
            inner = inner.cons.tail.*;
        }
        if (inner != .nil) return error.TypeMismatch;
        outer = outer.cons.tail.*;
    }
    if (outer != .nil) return error.TypeMismatch;

    return buildList(ctx.allocator, elements.items);
}

// ============================================================================
// Slicing
// ============================================================================

/// Take first n elements: take(n, list) -> list
fn listTake(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    const n = switch (args[0]) {
        .integer => |i| if (i < 0) return error.InvalidOperation else @as(usize, @intCast(i)),
        else => return error.TypeMismatch,
    };

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var current = args[1];
    var count: usize = 0;

    while (current == .cons and count < n) {
        elements.append(ctx.allocator, current.cons.head.*) catch return error.OutOfMemory;
        current = current.cons.tail.*;
        count += 1;
    }

    return buildList(ctx.allocator, elements.items);
}

/// Drop first n elements: drop(n, list) -> list
fn listDrop(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
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
fn listZip(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    var elements = std.ArrayListUnmanaged(Value){};
    defer elements.deinit(ctx.allocator);

    var list1 = args[0];
    var list2 = args[1];

    while (list1 == .cons and list2 == .cons) {
        // Create tuple of (head1, head2)
        const tuple = ctx.allocator.alloc(Value, 2) catch return error.OutOfMemory;
        tuple[0] = list1.cons.head.*;
        tuple[1] = list2.cons.head.*;
        elements.append(ctx.allocator, Value{ .tuple = tuple }) catch return error.OutOfMemory;

        list1 = list1.cons.tail.*;
        list2 = list2.cons.tail.*;
    }

    return buildList(ctx.allocator, elements.items);
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

// ============================================================================
// Tests
// ============================================================================

/// Helper to free a list and all its cons cells (for testing only)
fn freeList(allocator: std.mem.Allocator, val: Value) void {
    switch (val) {
        .cons => |c| {
            // Recursively free tail first
            freeList(allocator, c.tail.*);
            // Then free head and tail pointers
            allocator.destroy(c.head);
            allocator.destroy(c.tail);
        },
        .nil => {},
        else => {},
    }
}

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };
}

test "list construction" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Empty list
    const empty = try listEmpty(ctx, &.{});
    try std.testing.expect(empty == .nil);

    // Singleton - test then free
    {
        const single = try listSingleton(ctx, &.{Value{ .integer = 42 }});
        defer freeList(allocator, single);
        try std.testing.expect(single == .cons);
        try std.testing.expectEqual(@as(i128, 42), single.cons.head.integer);
        try std.testing.expect(single.cons.tail.* == .nil);
    }

    // Cons - create fresh list, listCons creates copies of inner pointers
    // so we only need to free the outermost cons cells
    {
        const base = try listSingleton(ctx, &.{Value{ .integer = 2 }});
        const list = try listCons(ctx, &.{ Value{ .integer = 1 }, base });
        defer {
            // Free the outer cons cell (list) head/tail
            allocator.destroy(list.cons.head);
            allocator.destroy(list.cons.tail);
            // Free the inner cons cell (base) head/tail
            allocator.destroy(base.cons.head);
            allocator.destroy(base.cons.tail);
        }
        try std.testing.expect(list == .cons);
        try std.testing.expectEqual(@as(i128, 1), list.cons.head.integer);
    }
}

test "list length" {
    // Use arena for tests with multiple allocations
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Empty list
    const empty_len = try listLength(ctx, &.{Value{ .nil = {} }});
    try std.testing.expectEqual(@as(i128, 0), empty_len.integer);

    // Build [1, 2, 3]
    const list = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    });
    const len = try listLength(ctx, &.{list});
    try std.testing.expectEqual(@as(i128, 3), len.integer);
}

test "list reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Build [1, 2, 3]
    const list = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    });

    const reversed = try listReverse(ctx, &.{list});

    // Should be [3, 2, 1]
    try std.testing.expect(reversed == .cons);
    try std.testing.expectEqual(@as(i128, 3), reversed.cons.head.integer);
    try std.testing.expectEqual(@as(i128, 2), reversed.cons.tail.cons.head.integer);
    try std.testing.expectEqual(@as(i128, 1), reversed.cons.tail.cons.tail.cons.head.integer);
}

test "list take and drop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    // Build [1, 2, 3, 4, 5]
    const list = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
        Value{ .integer = 4 },
        Value{ .integer = 5 },
    });

    // Take 2 -> [1, 2]
    const taken = try listTake(ctx, &.{ Value{ .integer = 2 }, list });
    const taken_len = try listLength(ctx, &.{taken});
    try std.testing.expectEqual(@as(i128, 2), taken_len.integer);

    // Drop 2 -> [3, 4, 5]
    const dropped = try listDrop(ctx, &.{ Value{ .integer = 2 }, list });
    const dropped_len = try listLength(ctx, &.{dropped});
    try std.testing.expectEqual(@as(i128, 3), dropped_len.integer);
    try std.testing.expectEqual(@as(i128, 3), dropped.cons.head.integer);
}

test "list concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const list1 = try buildList(allocator, &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    });
    const list2 = try buildList(allocator, &.{
        Value{ .integer = 3 },
        Value{ .integer = 4 },
    });

    const combined = try listConcat(ctx, &.{ list1, list2 });
    const len = try listLength(ctx, &.{combined});
    try std.testing.expectEqual(@as(i128, 4), len.integer);
}
