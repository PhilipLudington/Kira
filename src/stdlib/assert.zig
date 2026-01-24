//! std.assert - Assertion functions for the Kira standard library.
//!
//! Provides assertion functions for testing:
//!   - assert, assert_true, assert_false: Boolean assertions
//!   - assert_eq, assert_not_eq: Equality assertions
//!   - assert_greater, assert_less, etc.: Comparison assertions
//!   - assert_in_range: Range assertions
//!   - assert_approx_eq: Floating-point approximate equality
//!   - assert_some, assert_none, assert_some_eq: Option assertions
//!   - assert_ok, assert_err, assert_ok_eq, assert_err_contains: Result assertions
//!   - assert_contains, assert_starts_with, assert_ends_with: String assertions
//!   - assert_empty, assert_not_empty, assert_length: Collection assertions

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.assert module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    // Boolean assertions
    try fields.put(allocator, "assert", root.makeBuiltin("assert", &assertFn));
    try fields.put(allocator, "assert_true", root.makeBuiltin("assert_true", &assertTrue));
    try fields.put(allocator, "assert_false", root.makeBuiltin("assert_false", &assertFalse));

    // Equality assertions
    try fields.put(allocator, "assert_eq", root.makeBuiltin("assert_eq", &assertEq));
    try fields.put(allocator, "assert_not_eq", root.makeBuiltin("assert_not_eq", &assertNotEq));

    // Comparison assertions
    try fields.put(allocator, "assert_greater", root.makeBuiltin("assert_greater", &assertGreater));
    try fields.put(allocator, "assert_less", root.makeBuiltin("assert_less", &assertLess));
    try fields.put(allocator, "assert_greater_or_eq", root.makeBuiltin("assert_greater_or_eq", &assertGreaterOrEq));
    try fields.put(allocator, "assert_less_or_eq", root.makeBuiltin("assert_less_or_eq", &assertLessOrEq));

    // Range assertions
    try fields.put(allocator, "assert_in_range", root.makeBuiltin("assert_in_range", &assertInRange));

    // Float assertions
    try fields.put(allocator, "assert_approx_eq", root.makeBuiltin("assert_approx_eq", &assertApproxEq));

    // Option assertions
    try fields.put(allocator, "assert_some", root.makeBuiltin("assert_some", &assertSome));
    try fields.put(allocator, "assert_none", root.makeBuiltin("assert_none", &assertNone));
    try fields.put(allocator, "assert_some_eq", root.makeBuiltin("assert_some_eq", &assertSomeEq));

    // Result assertions
    try fields.put(allocator, "assert_ok", root.makeBuiltin("assert_ok", &assertOk));
    try fields.put(allocator, "assert_err", root.makeBuiltin("assert_err", &assertErr));
    try fields.put(allocator, "assert_ok_eq", root.makeBuiltin("assert_ok_eq", &assertOkEq));
    try fields.put(allocator, "assert_err_contains", root.makeBuiltin("assert_err_contains", &assertErrContains));

    // String content assertions
    try fields.put(allocator, "assert_contains", root.makeBuiltin("assert_contains", &assertContains));
    try fields.put(allocator, "assert_not_contains", root.makeBuiltin("assert_not_contains", &assertNotContains));
    try fields.put(allocator, "assert_starts_with", root.makeBuiltin("assert_starts_with", &assertStartsWith));
    try fields.put(allocator, "assert_not_starts_with", root.makeBuiltin("assert_not_starts_with", &assertNotStartsWith));
    try fields.put(allocator, "assert_ends_with", root.makeBuiltin("assert_ends_with", &assertEndsWith));
    try fields.put(allocator, "assert_not_ends_with", root.makeBuiltin("assert_not_ends_with", &assertNotEndsWith));

    // String value assertions
    try fields.put(allocator, "assert_empty_string", root.makeBuiltin("assert_empty_string", &assertEmptyString));
    try fields.put(allocator, "assert_not_empty_string", root.makeBuiltin("assert_not_empty_string", &assertNotEmptyString));
    try fields.put(allocator, "assert_str_length", root.makeBuiltin("assert_str_length", &assertStrLength));

    // Collection assertions
    try fields.put(allocator, "assert_empty", root.makeBuiltin("assert_empty", &assertEmpty));
    try fields.put(allocator, "assert_not_empty", root.makeBuiltin("assert_not_empty", &assertNotEmpty));
    try fields.put(allocator, "assert_length", root.makeBuiltin("assert_length", &assertLength));
    try fields.put(allocator, "assert_array_contains", root.makeBuiltin("assert_array_contains", &assertArrayContains));
    try fields.put(allocator, "assert_array_not_contains", root.makeBuiltin("assert_array_not_contains", &assertArrayNotContains));
    try fields.put(allocator, "assert_array_eq", root.makeBuiltin("assert_array_eq", &assertArrayEq));

    // List assertions (for Cons/Nil lists)
    try fields.put(allocator, "assert_list_empty", root.makeBuiltin("assert_list_empty", &assertListEmpty));
    try fields.put(allocator, "assert_list_not_empty", root.makeBuiltin("assert_list_not_empty", &assertListNotEmpty));
    try fields.put(allocator, "assert_list_length", root.makeBuiltin("assert_list_length", &assertListLength));
    try fields.put(allocator, "assert_list_contains", root.makeBuiltin("assert_list_contains", &assertListContains));
    try fields.put(allocator, "assert_list_eq", root.makeBuiltin("assert_list_eq", &assertListEq));

    // Fail helper
    try fields.put(allocator, "fail", root.makeBuiltin("fail", &failFn));

    return Value{
        .record = .{
            .type_name = "std.assert",
            .fields = fields,
        },
    };
}

// ============================================================================
// Boolean Assertions
// ============================================================================

/// Assert that a condition is true: assert(cond) -> void
fn assertFn(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const cond = switch (args[0]) {
        .boolean => |b| b,
        else => return error.TypeMismatch,
    };

    if (!cond) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that a value is true: assert_true(value) -> void
fn assertTrue(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const value = switch (args[0]) {
        .boolean => |b| b,
        else => return error.TypeMismatch,
    };

    if (!value) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that a value is false: assert_false(value) -> void
fn assertFalse(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const value = switch (args[0]) {
        .boolean => |b| b,
        else => return error.TypeMismatch,
    };

    if (value) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// Equality Assertions
// ============================================================================

/// Assert that two values are equal: assert_eq(expected, actual) -> void
fn assertEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    if (!args[0].eql(args[1])) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that two values are not equal: assert_not_eq(unexpected, actual) -> void
fn assertNotEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    if (args[0].eql(args[1])) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// Comparison Assertions
// ============================================================================

/// Assert that actual > threshold: assert_greater(threshold, actual) -> void
fn assertGreater(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const result = compareValues(args[0], args[1]) orelse return error.TypeMismatch;
    if (result != .gt) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that actual < threshold: assert_less(threshold, actual) -> void
fn assertLess(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const result = compareValues(args[0], args[1]) orelse return error.TypeMismatch;
    if (result != .lt) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that actual >= threshold: assert_greater_or_eq(threshold, actual) -> void
fn assertGreaterOrEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const result = compareValues(args[0], args[1]) orelse return error.TypeMismatch;
    if (result == .lt) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that actual <= threshold: assert_less_or_eq(threshold, actual) -> void
fn assertLessOrEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const result = compareValues(args[0], args[1]) orelse return error.TypeMismatch;
    if (result == .gt) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Compare two values, returns ordering relative to args[1] vs args[0]
/// i.e., returns .gt if args[1] > args[0]
fn compareValues(threshold: Value, actual: Value) ?std.math.Order {
    // Compare integers
    if (threshold == .integer and actual == .integer) {
        return std.math.order(actual.integer, threshold.integer);
    }

    // Compare floats
    if (threshold == .float and actual == .float) {
        return std.math.order(actual.float, threshold.float);
    }

    // Mixed int/float comparison
    if (threshold == .integer and actual == .float) {
        const threshold_f: f64 = @floatFromInt(threshold.integer);
        return std.math.order(actual.float, threshold_f);
    }
    if (threshold == .float and actual == .integer) {
        const actual_f: f64 = @floatFromInt(actual.integer);
        return std.math.order(actual_f, threshold.float);
    }

    return null;
}

// ============================================================================
// Range Assertions
// ============================================================================

/// Assert that actual is in range [min, max]: assert_in_range(min, max, actual) -> void
fn assertInRange(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 3) return error.ArityMismatch;

    const min_cmp = compareValues(args[0], args[2]) orelse return error.TypeMismatch;
    const max_cmp = compareValues(args[1], args[2]) orelse return error.TypeMismatch;

    // actual >= min AND actual <= max
    if (min_cmp == .lt or max_cmp == .gt) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// Float Assertions
// ============================================================================

/// Assert approximate equality: assert_approx_eq(expected, actual, epsilon) -> void
fn assertApproxEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 3) return error.ArityMismatch;

    const expected = getFloat(args[0]) orelse return error.TypeMismatch;
    const actual = getFloat(args[1]) orelse return error.TypeMismatch;
    const epsilon = getFloat(args[2]) orelse return error.TypeMismatch;

    const diff = @abs(expected - actual);
    if (diff > epsilon) return error.AssertionFailed;

    return Value{ .void = {} };
}

fn getFloat(val: Value) ?f64 {
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ============================================================================
// Option Assertions
// ============================================================================

/// Assert that an Option is Some: assert_some(opt) -> void
fn assertSome(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .some => Value{ .void = {} },
        .none => error.AssertionFailed,
        else => error.TypeMismatch,
    };
}

/// Assert that an Option is None: assert_none(opt) -> void
fn assertNone(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .none => Value{ .void = {} },
        .some => error.AssertionFailed,
        else => error.TypeMismatch,
    };
}

/// Assert that an Option is Some with expected value: assert_some_eq(expected, opt) -> void
fn assertSomeEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const inner = switch (args[1]) {
        .some => |ptr| ptr.*,
        .none => return error.AssertionFailed,
        else => return error.TypeMismatch,
    };

    if (!args[0].eql(inner)) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// Result Assertions
// ============================================================================

/// Assert that a Result is Ok: assert_ok(result) -> void
fn assertOk(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .ok => Value{ .void = {} },
        .err => error.AssertionFailed,
        else => error.TypeMismatch,
    };
}

/// Assert that a Result is Err: assert_err(result) -> void
fn assertErr(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    return switch (args[0]) {
        .err => Value{ .void = {} },
        .ok => error.AssertionFailed,
        else => error.TypeMismatch,
    };
}

/// Assert that a Result is Ok with expected value: assert_ok_eq(expected, result) -> void
fn assertOkEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const inner = switch (args[1]) {
        .ok => |ptr| ptr.*,
        .err => return error.AssertionFailed,
        else => return error.TypeMismatch,
    };

    if (!args[0].eql(inner)) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that a Result is Err and contains substring: assert_err_contains(result, expected_msg) -> void
fn assertErrContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const err_value = switch (args[0]) {
        .err => |ptr| ptr.*,
        .ok => return error.AssertionFailed,
        else => return error.TypeMismatch,
    };

    const err_msg = switch (err_value) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    const expected = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (std.mem.indexOf(u8, err_msg, expected) == null) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// String Content Assertions
// ============================================================================

/// Assert that haystack contains needle: assert_contains(haystack, needle) -> void
fn assertContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const haystack = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const needle = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (std.mem.indexOf(u8, haystack, needle) == null) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that haystack does not contain needle: assert_not_contains(haystack, needle) -> void
fn assertNotContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const haystack = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const needle = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (std.mem.indexOf(u8, haystack, needle) != null) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that string starts with prefix: assert_starts_with(str, prefix) -> void
fn assertStartsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const prefix = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (!std.mem.startsWith(u8, str, prefix)) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that string does not start with prefix: assert_not_starts_with(str, prefix) -> void
fn assertNotStartsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const prefix = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (std.mem.startsWith(u8, str, prefix)) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that string ends with suffix: assert_ends_with(str, suffix) -> void
fn assertEndsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const suffix = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (!std.mem.endsWith(u8, str, suffix)) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that string does not end with suffix: assert_not_ends_with(str, suffix) -> void
fn assertNotEndsWith(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };
    const suffix = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (std.mem.endsWith(u8, str, suffix)) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// String Value Assertions
// ============================================================================

/// Assert that string is empty: assert_empty_string(str) -> void
fn assertEmptyString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (str.len != 0) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that string is not empty: assert_not_empty_string(str) -> void
fn assertNotEmptyString(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const str = switch (args[0]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (str.len == 0) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that string has expected length: assert_str_length(expected_len, str) -> void
fn assertStrLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const expected_len = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const str = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (@as(i128, @intCast(str.len)) != expected_len) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// Collection Assertions (Arrays)
// ============================================================================

/// Assert that array is empty: assert_empty(arr) -> void
fn assertEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const arr = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    if (arr.len != 0) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that array is not empty: assert_not_empty(arr) -> void
fn assertNotEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const arr = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    if (arr.len == 0) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that array has expected length: assert_length(expected_len, arr) -> void
fn assertLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const expected_len = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const arr = switch (args[1]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    if (@as(i128, @intCast(arr.len)) != expected_len) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that array contains element: assert_array_contains(arr, element) -> void
fn assertArrayContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const arr = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    for (arr) |item| {
        if (item.eql(args[1])) return Value{ .void = {} };
    }
    return error.AssertionFailed;
}

/// Assert that array does not contain element: assert_array_not_contains(arr, element) -> void
fn assertArrayNotContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const arr = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    for (arr) |item| {
        if (item.eql(args[1])) return error.AssertionFailed;
    }
    return Value{ .void = {} };
}

/// Assert that two arrays are equal: assert_array_eq(expected, actual) -> void
fn assertArrayEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const expected = switch (args[0]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    const actual = switch (args[1]) {
        .array => |a| a,
        else => return error.TypeMismatch,
    };

    if (expected.len != actual.len) return error.AssertionFailed;

    for (expected, actual) |e, a| {
        if (!e.eql(a)) return error.AssertionFailed;
    }

    return Value{ .void = {} };
}

// ============================================================================
// List Assertions (Cons/Nil)
// ============================================================================

/// Get list length
fn getListLength(val: Value) ?usize {
    var len: usize = 0;
    var current = val;
    while (true) {
        switch (current) {
            .nil => return len,
            .cons => |c| {
                len += 1;
                current = c.tail.*;
            },
            else => return null,
        }
    }
}

/// Check if list contains element
fn listContainsElement(val: Value, element: Value) ?bool {
    var current = val;
    while (true) {
        switch (current) {
            .nil => return false,
            .cons => |c| {
                if (c.head.eql(element)) return true;
                current = c.tail.*;
            },
            else => return null,
        }
    }
}

/// Check if two lists are equal
fn listsEqual(a: Value, b: Value) ?bool {
    var cur_a = a;
    var cur_b = b;

    while (true) {
        const tag_a = std.meta.activeTag(cur_a);
        const tag_b = std.meta.activeTag(cur_b);

        if (tag_a == .nil and tag_b == .nil) return true;
        if (tag_a == .nil or tag_b == .nil) return false;
        if (tag_a != .cons or tag_b != .cons) return null;

        if (!cur_a.cons.head.eql(cur_b.cons.head.*)) return false;

        cur_a = cur_a.cons.tail.*;
        cur_b = cur_b.cons.tail.*;
    }
}

/// Assert that list is empty: assert_list_empty(list) -> void
fn assertListEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const len = getListLength(args[0]) orelse return error.TypeMismatch;
    if (len != 0) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that list is not empty: assert_list_not_empty(list) -> void
fn assertListNotEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    const len = getListLength(args[0]) orelse return error.TypeMismatch;
    if (len == 0) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that list has expected length: assert_list_length(expected_len, list) -> void
fn assertListLength(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const expected_len = switch (args[0]) {
        .integer => |i| i,
        else => return error.TypeMismatch,
    };

    const actual_len = getListLength(args[1]) orelse return error.TypeMismatch;

    if (@as(i128, @intCast(actual_len)) != expected_len) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that list contains element: assert_list_contains(list, element) -> void
fn assertListContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const contains = listContainsElement(args[0], args[1]) orelse return error.TypeMismatch;
    if (!contains) return error.AssertionFailed;
    return Value{ .void = {} };
}

/// Assert that two lists are equal: assert_list_eq(expected, actual) -> void
fn assertListEq(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    const equal = listsEqual(args[0], args[1]) orelse return error.TypeMismatch;
    if (!equal) return error.AssertionFailed;
    return Value{ .void = {} };
}

// ============================================================================
// Fail Helper
// ============================================================================

/// Always fail: fail() -> void
fn failFn(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    _ = args;
    return error.AssertionFailed;
}

// ============================================================================
// Tests
// ============================================================================

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };
}

test "assert true/false" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // assert_true with true value
    _ = try assertTrue(ctx, &.{Value{ .boolean = true }});

    // assert_true with false value should fail
    try std.testing.expectError(error.AssertionFailed, assertTrue(ctx, &.{Value{ .boolean = false }}));

    // assert_false with false value
    _ = try assertFalse(ctx, &.{Value{ .boolean = false }});

    // assert_false with true value should fail
    try std.testing.expectError(error.AssertionFailed, assertFalse(ctx, &.{Value{ .boolean = true }}));
}

test "assert_eq and assert_not_eq" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Equal integers
    _ = try assertEq(ctx, &.{ Value{ .integer = 42 }, Value{ .integer = 42 } });

    // Unequal integers should fail
    try std.testing.expectError(error.AssertionFailed, assertEq(ctx, &.{ Value{ .integer = 42 }, Value{ .integer = 43 } }));

    // Equal strings
    _ = try assertEq(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "hello" } });

    // assert_not_eq with different values
    _ = try assertNotEq(ctx, &.{ Value{ .integer = 42 }, Value{ .integer = 43 } });

    // assert_not_eq with same values should fail
    try std.testing.expectError(error.AssertionFailed, assertNotEq(ctx, &.{ Value{ .integer = 42 }, Value{ .integer = 42 } }));
}

test "comparison assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // assert_greater
    _ = try assertGreater(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 10 } }); // 10 > 5
    try std.testing.expectError(error.AssertionFailed, assertGreater(ctx, &.{ Value{ .integer = 10 }, Value{ .integer = 5 } }));

    // assert_less
    _ = try assertLess(ctx, &.{ Value{ .integer = 10 }, Value{ .integer = 5 } }); // 5 < 10
    try std.testing.expectError(error.AssertionFailed, assertLess(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 10 } }));

    // assert_greater_or_eq
    _ = try assertGreaterOrEq(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 10 } }); // 10 >= 5
    _ = try assertGreaterOrEq(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 5 } }); // 5 >= 5

    // assert_less_or_eq
    _ = try assertLessOrEq(ctx, &.{ Value{ .integer = 10 }, Value{ .integer = 5 } }); // 5 <= 10
    _ = try assertLessOrEq(ctx, &.{ Value{ .integer = 5 }, Value{ .integer = 5 } }); // 5 <= 5

    // Float comparisons
    _ = try assertGreater(ctx, &.{ Value{ .float = 1.5 }, Value{ .float = 2.5 } });
    _ = try assertLess(ctx, &.{ Value{ .float = 2.5 }, Value{ .float = 1.5 } });
}

test "assert_in_range" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Value in range
    _ = try assertInRange(ctx, &.{ Value{ .integer = 1 }, Value{ .integer = 10 }, Value{ .integer = 5 } });

    // Value at bounds
    _ = try assertInRange(ctx, &.{ Value{ .integer = 1 }, Value{ .integer = 10 }, Value{ .integer = 1 } });
    _ = try assertInRange(ctx, &.{ Value{ .integer = 1 }, Value{ .integer = 10 }, Value{ .integer = 10 } });

    // Value out of range
    try std.testing.expectError(error.AssertionFailed, assertInRange(ctx, &.{ Value{ .integer = 1 }, Value{ .integer = 10 }, Value{ .integer = 0 } }));
    try std.testing.expectError(error.AssertionFailed, assertInRange(ctx, &.{ Value{ .integer = 1 }, Value{ .integer = 10 }, Value{ .integer = 11 } }));
}

test "assert_approx_eq" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Equal within epsilon
    _ = try assertApproxEq(ctx, &.{ Value{ .float = 1.0 }, Value{ .float = 1.001 }, Value{ .float = 0.01 } });

    // Not equal within epsilon
    try std.testing.expectError(error.AssertionFailed, assertApproxEq(ctx, &.{ Value{ .float = 1.0 }, Value{ .float = 1.1 }, Value{ .float = 0.01 } }));
}

test "option assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Create Some value
    const inner = try allocator.create(Value);
    defer allocator.destroy(inner);
    inner.* = Value{ .integer = 42 };
    const some_val = Value{ .some = inner };

    const none_val = Value{ .none = {} };

    // assert_some
    _ = try assertSome(ctx, &.{some_val});
    try std.testing.expectError(error.AssertionFailed, assertSome(ctx, &.{none_val}));

    // assert_none
    _ = try assertNone(ctx, &.{none_val});
    try std.testing.expectError(error.AssertionFailed, assertNone(ctx, &.{some_val}));

    // assert_some_eq
    _ = try assertSomeEq(ctx, &.{ Value{ .integer = 42 }, some_val });
    try std.testing.expectError(error.AssertionFailed, assertSomeEq(ctx, &.{ Value{ .integer = 99 }, some_val }));
    try std.testing.expectError(error.AssertionFailed, assertSomeEq(ctx, &.{ Value{ .integer = 42 }, none_val }));
}

test "result assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Create Ok value
    const ok_inner = try allocator.create(Value);
    defer allocator.destroy(ok_inner);
    ok_inner.* = Value{ .integer = 42 };
    const ok_val = Value{ .ok = ok_inner };

    // Create Err value
    const err_inner = try allocator.create(Value);
    defer allocator.destroy(err_inner);
    err_inner.* = Value{ .string = "something went wrong" };
    const err_val = Value{ .err = err_inner };

    // assert_ok
    _ = try assertOk(ctx, &.{ok_val});
    try std.testing.expectError(error.AssertionFailed, assertOk(ctx, &.{err_val}));

    // assert_err
    _ = try assertErr(ctx, &.{err_val});
    try std.testing.expectError(error.AssertionFailed, assertErr(ctx, &.{ok_val}));

    // assert_ok_eq
    _ = try assertOkEq(ctx, &.{ Value{ .integer = 42 }, ok_val });
    try std.testing.expectError(error.AssertionFailed, assertOkEq(ctx, &.{ Value{ .integer = 99 }, ok_val }));

    // assert_err_contains
    _ = try assertErrContains(ctx, &.{ err_val, Value{ .string = "wrong" } });
    try std.testing.expectError(error.AssertionFailed, assertErrContains(ctx, &.{ err_val, Value{ .string = "foo" } }));
}

test "string content assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // assert_contains
    _ = try assertContains(ctx, &.{ Value{ .string = "hello world" }, Value{ .string = "world" } });
    try std.testing.expectError(error.AssertionFailed, assertContains(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "world" } }));

    // assert_not_contains
    _ = try assertNotContains(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "world" } });
    try std.testing.expectError(error.AssertionFailed, assertNotContains(ctx, &.{ Value{ .string = "hello world" }, Value{ .string = "world" } }));

    // assert_starts_with
    _ = try assertStartsWith(ctx, &.{ Value{ .string = "hello world" }, Value{ .string = "hello" } });
    try std.testing.expectError(error.AssertionFailed, assertStartsWith(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "world" } }));

    // assert_ends_with
    _ = try assertEndsWith(ctx, &.{ Value{ .string = "hello world" }, Value{ .string = "world" } });
    try std.testing.expectError(error.AssertionFailed, assertEndsWith(ctx, &.{ Value{ .string = "hello" }, Value{ .string = "world" } }));
}

test "string value assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // assert_empty_string
    _ = try assertEmptyString(ctx, &.{Value{ .string = "" }});
    try std.testing.expectError(error.AssertionFailed, assertEmptyString(ctx, &.{Value{ .string = "hello" }}));

    // assert_not_empty_string
    _ = try assertNotEmptyString(ctx, &.{Value{ .string = "hello" }});
    try std.testing.expectError(error.AssertionFailed, assertNotEmptyString(ctx, &.{Value{ .string = "" }}));

    // assert_str_length
    _ = try assertStrLength(ctx, &.{ Value{ .integer = 5 }, Value{ .string = "hello" } });
    try std.testing.expectError(error.AssertionFailed, assertStrLength(ctx, &.{ Value{ .integer = 10 }, Value{ .string = "hello" } }));
}

test "array assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    const empty_arr = Value{ .array = &.{} };
    const arr = Value{ .array = &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    } };

    // assert_empty
    _ = try assertEmpty(ctx, &.{empty_arr});
    try std.testing.expectError(error.AssertionFailed, assertEmpty(ctx, &.{arr}));

    // assert_not_empty
    _ = try assertNotEmpty(ctx, &.{arr});
    try std.testing.expectError(error.AssertionFailed, assertNotEmpty(ctx, &.{empty_arr}));

    // assert_length
    _ = try assertLength(ctx, &.{ Value{ .integer = 3 }, arr });
    try std.testing.expectError(error.AssertionFailed, assertLength(ctx, &.{ Value{ .integer = 5 }, arr }));

    // assert_array_contains
    _ = try assertArrayContains(ctx, &.{ arr, Value{ .integer = 2 } });
    try std.testing.expectError(error.AssertionFailed, assertArrayContains(ctx, &.{ arr, Value{ .integer = 99 } }));

    // assert_array_not_contains
    _ = try assertArrayNotContains(ctx, &.{ arr, Value{ .integer = 99 } });
    try std.testing.expectError(error.AssertionFailed, assertArrayNotContains(ctx, &.{ arr, Value{ .integer = 2 } }));

    // assert_array_eq
    const arr2 = Value{ .array = &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
        Value{ .integer = 3 },
    } };
    _ = try assertArrayEq(ctx, &.{ arr, arr2 });

    const arr3 = Value{ .array = &.{
        Value{ .integer = 1 },
        Value{ .integer = 2 },
    } };
    try std.testing.expectError(error.AssertionFailed, assertArrayEq(ctx, &.{ arr, arr3 }));
}

test "list assertions" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    // Create Cons list: [1, 2, 3]
    const val3 = try allocator.create(Value);
    defer allocator.destroy(val3);
    val3.* = Value{ .integer = 3 };

    const nil_val = try allocator.create(Value);
    defer allocator.destroy(nil_val);
    nil_val.* = Value{ .nil = {} };

    const cons3 = try allocator.create(Value);
    defer allocator.destroy(cons3);
    cons3.* = Value{ .cons = .{ .head = val3, .tail = nil_val } };

    const val2 = try allocator.create(Value);
    defer allocator.destroy(val2);
    val2.* = Value{ .integer = 2 };

    const cons2 = try allocator.create(Value);
    defer allocator.destroy(cons2);
    cons2.* = Value{ .cons = .{ .head = val2, .tail = cons3 } };

    const val1 = try allocator.create(Value);
    defer allocator.destroy(val1);
    val1.* = Value{ .integer = 1 };

    const list = Value{ .cons = .{ .head = val1, .tail = cons2 } };
    const empty_list = Value{ .nil = {} };

    // assert_list_empty
    _ = try assertListEmpty(ctx, &.{empty_list});
    try std.testing.expectError(error.AssertionFailed, assertListEmpty(ctx, &.{list}));

    // assert_list_not_empty
    _ = try assertListNotEmpty(ctx, &.{list});
    try std.testing.expectError(error.AssertionFailed, assertListNotEmpty(ctx, &.{empty_list}));

    // assert_list_length
    _ = try assertListLength(ctx, &.{ Value{ .integer = 3 }, list });
    try std.testing.expectError(error.AssertionFailed, assertListLength(ctx, &.{ Value{ .integer = 5 }, list }));

    // assert_list_contains
    _ = try assertListContains(ctx, &.{ list, Value{ .integer = 2 } });
    try std.testing.expectError(error.AssertionFailed, assertListContains(ctx, &.{ list, Value{ .integer = 99 } }));
}

test "fail always fails" {
    const allocator = std.testing.allocator;
    const ctx = testCtx(allocator);

    try std.testing.expectError(error.AssertionFailed, failFn(ctx, &.{}));
}
