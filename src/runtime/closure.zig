//! Runtime representation for closures in compiled Kira code.
//!
//! A closure is a function pointer paired with a captured environment.
//! The environment stores values from the enclosing scope that the function
//! body references. At call time, the captured values are restored so the
//! function body can access them as if they were local variables.
//!
//! Layout: [function_ptr][capture_count][capture_0]...[capture_n]

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const adt = @import("adt.zig");
const KiraValue = adt.KiraValue;

/// Runtime representation of a closure.
/// Combines a function pointer with captured environment values.
pub const Closure = struct {
    /// Pointer to the function's native code entry point.
    /// Cast to the appropriate function type at call sites.
    function_ptr: *const anyopaque,
    /// Index of this closure's function in the module (for debugging/reflection).
    function_index: u32,
    /// Captured values from the enclosing scope.
    captures: []KiraValue,
    /// Arity (number of parameters, excluding captures).
    arity: u32,

    /// Allocate a new closure with the given captures.
    pub fn create(
        allocator: Allocator,
        function_ptr: *const anyopaque,
        function_index: u32,
        arity: u32,
        capture_values: []const KiraValue,
    ) !*Closure {
        const captures = try allocator.alloc(KiraValue, capture_values.len);
        @memcpy(captures, capture_values);

        const closure = try allocator.create(Closure);
        closure.* = .{
            .function_ptr = function_ptr,
            .function_index = function_index,
            .captures = captures,
            .arity = arity,
        };
        return closure;
    }

    /// Create a closure with no captures (thin wrapper around function pointer).
    pub fn createNonCapturing(
        allocator: Allocator,
        function_ptr: *const anyopaque,
        function_index: u32,
        arity: u32,
    ) !*Closure {
        return create(allocator, function_ptr, function_index, arity, &.{});
    }

    /// Free this closure and its capture array.
    pub fn destroy(self: *Closure, allocator: Allocator) void {
        allocator.free(self.captures);
        allocator.destroy(self);
    }

    /// Get a captured value by index.
    pub fn getCapture(self: *const Closure, index: u32) ?KiraValue {
        if (index >= self.captures.len) return null;
        return self.captures[index];
    }

    /// Get the number of captured values.
    pub fn captureCount(self: *const Closure) u32 {
        return @intCast(self.captures.len);
    }

    /// Check if this closure captures any values.
    pub fn hasCaptures(self: *const Closure) bool {
        return self.captures.len > 0;
    }

    /// Create a new closure that extends this one with additional captures.
    /// Used for nested closures that capture from multiple scopes.
    pub fn extend(self: *const Closure, allocator: Allocator, extra_captures: []const KiraValue) !*Closure {
        const total = self.captures.len + extra_captures.len;
        const captures = try allocator.alloc(KiraValue, total);
        @memcpy(captures[0..self.captures.len], self.captures);
        @memcpy(captures[self.captures.len..], extra_captures);

        const closure = try allocator.create(Closure);
        closure.* = .{
            .function_ptr = self.function_ptr,
            .function_index = self.function_index,
            .captures = captures,
            .arity = self.arity,
        };
        return closure;
    }
};

/// Partial application: a closure with some arguments pre-filled.
/// Created when a function is called with fewer arguments than its arity.
pub const PartialApplication = struct {
    /// The underlying closure being partially applied.
    base: *Closure,
    /// Arguments supplied so far.
    applied_args: []KiraValue,

    pub fn create(
        allocator: Allocator,
        base: *Closure,
        args: []const KiraValue,
    ) !*PartialApplication {
        const applied = try allocator.alloc(KiraValue, args.len);
        @memcpy(applied, args);

        const pa = try allocator.create(PartialApplication);
        pa.* = .{
            .base = base,
            .applied_args = applied,
        };
        return pa;
    }

    pub fn destroy(self: *PartialApplication, allocator: Allocator) void {
        allocator.free(self.applied_args);
        allocator.destroy(self);
    }

    /// Number of remaining arguments needed to fully apply.
    pub fn remainingArity(self: *const PartialApplication) u32 {
        return self.base.arity - @as(u32, @intCast(self.applied_args.len));
    }

    /// Check if fully applied (ready to call).
    pub fn isComplete(self: *const PartialApplication) bool {
        return self.applied_args.len >= self.base.arity;
    }
};

// ============================================================
// Tests
// ============================================================

fn dummyFunction() void {}

test "Closure create with captures" {
    const allocator = testing.allocator;

    const captures = [_]KiraValue{
        .{ .integer = 10 },
        .{ .boolean = true },
    };
    const closure = try Closure.create(
        allocator,
        @ptrCast(&dummyFunction),
        0,
        1,
        &captures,
    );
    defer closure.destroy(allocator);

    try testing.expectEqual(@as(u32, 1), closure.arity);
    try testing.expectEqual(@as(u32, 2), closure.captureCount());
    try testing.expect(closure.hasCaptures());

    const cap0 = closure.getCapture(0);
    try testing.expect(cap0 != null);
    try testing.expectEqual(@as(i64, 10), cap0.?.integer);

    const cap1 = closure.getCapture(1);
    try testing.expect(cap1 != null);
    try testing.expectEqual(true, cap1.?.boolean);

    try testing.expect(closure.getCapture(2) == null);
}

test "Closure create non-capturing" {
    const allocator = testing.allocator;

    const closure = try Closure.createNonCapturing(
        allocator,
        @ptrCast(&dummyFunction),
        0,
        2,
    );
    defer closure.destroy(allocator);

    try testing.expectEqual(@as(u32, 2), closure.arity);
    try testing.expectEqual(@as(u32, 0), closure.captureCount());
    try testing.expect(!closure.hasCaptures());
}

test "Closure extend with additional captures" {
    const allocator = testing.allocator;

    const initial = [_]KiraValue{.{ .integer = 1 }};
    const base = try Closure.create(
        allocator,
        @ptrCast(&dummyFunction),
        0,
        1,
        &initial,
    );
    defer base.destroy(allocator);

    const extra = [_]KiraValue{
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    const extended = try base.extend(allocator, &extra);
    defer extended.destroy(allocator);

    try testing.expectEqual(@as(u32, 3), extended.captureCount());
    try testing.expectEqual(@as(i64, 1), extended.getCapture(0).?.integer);
    try testing.expectEqual(@as(i64, 2), extended.getCapture(1).?.integer);
    try testing.expectEqual(@as(i64, 3), extended.getCapture(2).?.integer);
}

test "Closure outlives creating scope" {
    const allocator = testing.allocator;

    // Simulate: fn make_adder(x) { fn(y) { x + y } }
    // The closure captures x=10 and survives after make_adder returns.
    var closure: *Closure = undefined;
    {
        const captures = [_]KiraValue{.{ .integer = 10 }};
        closure = try Closure.create(
            allocator,
            @ptrCast(&dummyFunction),
            1,
            1,
            &captures,
        );
        // Creating scope ends here, but closure survives.
    }
    defer closure.destroy(allocator);

    // Captured x is still accessible
    try testing.expectEqual(@as(i64, 10), closure.getCapture(0).?.integer);
}

test "PartialApplication tracks remaining arity" {
    const allocator = testing.allocator;

    const closure = try Closure.createNonCapturing(
        allocator,
        @ptrCast(&dummyFunction),
        0,
        3,
    );
    defer closure.destroy(allocator);

    const args = [_]KiraValue{.{ .integer = 1 }};
    const partial = try PartialApplication.create(allocator, closure, &args);
    defer partial.destroy(allocator);

    try testing.expectEqual(@as(u32, 2), partial.remainingArity());
    try testing.expect(!partial.isComplete());
}

test "nested closures capture chain" {
    const allocator = testing.allocator;

    // Simulate:
    //   fn outer(a) {
    //     fn middle(b) {
    //       fn inner(c) { a + b + c }
    //     }
    //   }
    // inner captures both a and b

    // outer creates middle closure capturing a=1
    const a_captures = [_]KiraValue{.{ .integer = 1 }};
    const middle = try Closure.create(
        allocator,
        @ptrCast(&dummyFunction),
        0,
        1,
        &a_captures,
    );
    defer middle.destroy(allocator);

    // middle creates inner closure extending with b=2
    const b_extra = [_]KiraValue{.{ .integer = 2 }};
    const inner = try middle.extend(allocator, &b_extra);
    defer inner.destroy(allocator);

    // inner has [a=1, b=2]
    try testing.expectEqual(@as(u32, 2), inner.captureCount());
    try testing.expectEqual(@as(i64, 1), inner.getCapture(0).?.integer);
    try testing.expectEqual(@as(i64, 2), inner.getCapture(1).?.integer);
}
