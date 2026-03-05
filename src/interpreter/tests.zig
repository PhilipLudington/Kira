//! Integration tests for the Kira interpreter.
//!
//! These tests parse Kira source code and interpret it to verify
//! correct evaluation of various language constructs.

const std = @import("std");
const testing = std.testing;
const Kira = @import("../root.zig");

const Value = Kira.Value;

/// Result that keeps the interpreter alive so arena-allocated values remain valid.
const EvalResult = struct {
    value: ?Value,
    interp: Kira.Interpreter,
    program: Kira.Program,
    table: Kira.SymbolTable,

    pub fn deinit(self: *EvalResult) void {
        self.interp.deinit();
        self.table.deinit();
        self.program.deinit();
    }
};

/// Helper to parse, resolve, type check, and interpret Kira source code.
/// Returns an EvalResult that keeps the interpreter alive for arena-allocated values.
fn evalSourceFull(allocator: std.mem.Allocator, source: []const u8) !EvalResult {
    var program = try Kira.parse(allocator, source);
    errdefer program.deinit();

    var table = Kira.SymbolTable.init(allocator);
    errdefer table.deinit();

    Kira.resolve(allocator, &program, &table) catch |err| {
        std.debug.print("Resolve error: {}\n", .{err});
        return err;
    };

    var interp = Kira.Interpreter.init(allocator, &table);
    errdefer interp.deinit();

    const arena_alloc = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(arena_alloc, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(arena_alloc, &interp.global_env);
    interp.registerBuiltinMethods();

    const value = try interp.interpret(&program);
    return EvalResult{
        .value = value,
        .interp = interp,
        .program = program,
        .table = table,
    };
}

/// Helper to parse, resolve, type check, and interpret Kira source code.
fn evalSource(allocator: std.mem.Allocator, source: []const u8) !?Value {
    // Parse
    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Resolve
    Kira.resolve(allocator, &program, &table) catch |err| {
        std.debug.print("Resolve error: {}\n", .{err});
        return err;
    };

    // Type check (skip for now - we're testing interpreter behavior)
    // Kira.typecheck(allocator, &program, &table) catch |err| {
    //     std.debug.print("Type check error: {}\n", .{err});
    //     return err;
    // };

    // Interpret
    return Kira.interpret(allocator, &program, &table);
}

/// Helper to parse, resolve, and type-check source. Returns true if type checking succeeds.
/// Used to test compile-time error detection.
fn typecheckSource(allocator: std.mem.Allocator, source: []const u8) !bool {
    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    Kira.resolve(allocator, &program, &table) catch return false;

    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();

    checker.check(&program) catch return false;
    return true;
}

// ============================================================================
// Literal Tests
// ============================================================================

test "interpreter: integer literal" {
    const allocator = testing.allocator;

    // Simple function returning an integer
    const source =
        \\fn main() -> i32 {
        \\    return 42
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: boolean literals" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return true
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

test "interpreter: string literal" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    return "hello"
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqualStrings("hello", result.?.string);
}

// ============================================================================
// Arithmetic Tests
// ============================================================================

test "interpreter: addition" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return 10 + 32
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: subtraction" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return 50 - 8
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: multiplication" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return 6 * 7
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: division" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return 84 / 2
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: modulo" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return 47 % 5
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 2), result.?.integer);
}

test "interpreter: complex expression" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return (10 + 5) * 2 - 3
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 27), result.?.integer);
}

// ============================================================================
// Comparison Tests
// ============================================================================

test "interpreter: less than" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return 5 < 10
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

test "interpreter: greater than" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return 10 > 5
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

test "interpreter: equality" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return 42 == 42
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

test "interpreter: inequality" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return 42 != 43
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

// ============================================================================
// Logical Tests
// ============================================================================

test "interpreter: logical and" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return true and true
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

test "interpreter: logical or" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return false or true
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

test "interpreter: logical not" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> bool {
        \\    return not false
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

// ============================================================================
// Variable Binding Tests
// ============================================================================

test "interpreter: let binding" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 42
        \\    return x
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: multiple let bindings" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 10
        \\    let y: i32 = 32
        \\    return x + y
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

// ============================================================================
// If Statement Tests
// ============================================================================

test "interpreter: if true branch" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    if true {
        \\        return 42
        \\    }
        \\    return 0
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: if else branch" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    if false {
        \\        return 0
        \\    } else {
        \\        return 42
        \\    }
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: if with condition expression" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 10
        \\    if x > 5 {
        \\        return 42
        \\    } else {
        \\        return 0
        \\    }
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

// ============================================================================
// Function Tests
// ============================================================================

test "interpreter: function call" {
    const allocator = testing.allocator;

    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn main() -> i32 {
        \\    return add(10, 32)
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: recursive function" {
    const allocator = testing.allocator;

    const source =
        \\fn factorial(n: i32) -> i32 {
        \\    if n <= 1 {
        \\        return 1
        \\    }
        \\    return n * factorial(n - 1)
        \\}
        \\
        \\fn main() -> i32 {
        \\    return factorial(5)
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 120), result.?.integer);
}

test "interpreter: fibonacci" {
    const allocator = testing.allocator;

    const source =
        \\fn fib(n: i32) -> i32 {
        \\    if n <= 1 {
        \\        return n
        \\    }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\
        \\fn main() -> i32 {
        \\    return fib(10)
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 55), result.?.integer);
}

test "interpreter: tail call optimization" {
    const allocator = testing.allocator;

    // This would fail with StackOverflow (limit 1000) without TCO
    const source =
        \\fn countdown(n: i64) -> i64 {
        \\    if n <= 0 {
        \\        return 0
        \\    }
        \\    return countdown(n - 1)
        \\}
        \\
        \\fn main() -> i64 {
        \\    return countdown(2000)
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 0), result.?.integer);
}

test "interpreter: mutual tail recursion" {
    const allocator = testing.allocator;

    // Mutual recursion with TCO
    const source =
        \\fn is_even(n: i64) -> bool {
        \\    if n == 0 { return true }
        \\    return is_odd(n - 1)
        \\}
        \\
        \\fn is_odd(n: i64) -> bool {
        \\    if n == 0 { return false }
        \\    return is_even(n - 1)
        \\}
        \\
        \\fn main() -> bool {
        \\    return is_even(2000)
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

// ============================================================================
// Tuple Tests
// ============================================================================

test "interpreter: tuple access returns correct value" {
    const allocator = testing.allocator;

    // Test tuple through accessing its first element
    const source =
        \\fn main() -> i32 {
        \\    let t: (i32, i32) = (1, 2)
        \\    return t.0
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 1), result.?.integer);
}

// ============================================================================
// Array Tests
// ============================================================================

test "interpreter: array access returns correct value" {
    const allocator = testing.allocator;

    // Test array through accessing its element
    const source =
        \\fn main() -> i32 {
        \\    let arr: [i32] = [1, 2, 3]
        \\    return arr[0]
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 1), result.?.integer);
}

test "interpreter: array index" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    let arr: [i32] = [10, 20, 30]
        \\    return arr[1]
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 20), result.?.integer);
}

// ============================================================================
// Option Tests
// ============================================================================

test "interpreter: Option Some unwrap" {
    const allocator = testing.allocator;

    // Test Option by unwrapping it
    const source =
        \\fn main() -> i32 {
        \\    let opt: Option[i32] = Some(42)
        \\    return opt.unwrap()
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: Option None is_none" {
    const allocator = testing.allocator;

    // Test Option None through is_none method
    const source =
        \\fn main() -> bool {
        \\    let opt: Option[i32] = None
        \\    return opt.is_none()
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

// ============================================================================
// Result Tests
// ============================================================================

test "interpreter: Result Ok unwrap" {
    const allocator = testing.allocator;

    // Test Result Ok through unwrap
    const source =
        \\fn main() -> i32 {
        \\    let res: Result[i32, string] = Ok(42)
        \\    return res.unwrap()
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 42), result.?.integer);
}

test "interpreter: Result is_err" {
    const allocator = testing.allocator;

    // Test Result Err through is_err
    const source =
        \\fn main() -> bool {
        \\    let res: Result[i32, string] = Err("error")
        \\    return res.is_err()
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.?.boolean);
}

// ============================================================================
// Unary Operator Tests
// ============================================================================

test "interpreter: unary negate" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    return -42
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, -42), result.?.integer);
}

// ============================================================================
// Float Tests
// ============================================================================

test "interpreter: float arithmetic" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> f64 {
        \\    return 3.14 * 2.0
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expect(result.? == .float);
    try testing.expect(@abs(result.?.float - 6.28) < 0.0001);
}

// ============================================================================
// Test Declaration Tests
// ============================================================================

test "parser: test declaration is parsed" {
    const allocator = testing.allocator;

    const source =
        \\test "simple test" {
        \\    let x: i32 = 42
        \\}
    ;

    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    // Should have one declaration (the test)
    try testing.expectEqual(@as(usize, 1), program.declarations.len);

    // Should be a test_decl
    const decl = program.declarations[0];
    try testing.expect(decl.kind == .test_decl);

    // Check test name
    const test_decl = decl.kind.test_decl;
    try testing.expectEqualStrings("simple test", test_decl.name);

    // Check body has one statement
    try testing.expectEqual(@as(usize, 1), test_decl.body.len);
}

test "parser: test declaration with multiple statements" {
    const allocator = testing.allocator;

    const source =
        \\test "multi statement test" {
        \\    let a: i32 = 1
        \\    let b: i32 = 2
        \\    let c: i32 = a + b
        \\}
    ;

    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    try testing.expectEqual(@as(usize, 1), program.declarations.len);
    const test_decl = program.declarations[0].kind.test_decl;
    try testing.expectEqualStrings("multi statement test", test_decl.name);
    try testing.expectEqual(@as(usize, 3), test_decl.body.len);
}

test "parser: test declaration cannot be public" {
    const allocator = testing.allocator;

    const source =
        \\pub test "should fail" {
        \\    let x: i32 = 1
        \\}
    ;

    // This should fail to parse
    const result = Kira.parse(allocator, source);
    try testing.expectError(error.UnexpectedToken, result);
}

test "parser: file with function and test" {
    const allocator = testing.allocator;

    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    a + b
        \\}
        \\
        \\test "addition" {
        \\    let result: i32 = add(2, 3)
        \\}
    ;

    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    // Should have two declarations
    try testing.expectEqual(@as(usize, 2), program.declarations.len);

    // First should be function
    try testing.expect(program.declarations[0].kind == .function_decl);
    try testing.expectEqualStrings("add", program.declarations[0].kind.function_decl.name);

    // Second should be test
    try testing.expect(program.declarations[1].kind == .test_decl);
    try testing.expectEqualStrings("addition", program.declarations[1].kind.test_decl.name);
}

// ============================================================================
// Bug Reproduction: Tuple field access on Cons-bound values
// ============================================================================

test "interpreter: tuple field access on cons-bound value" {
    const allocator = testing.allocator;

    // Reproduce the bug: tuple field access (.0, .1) on a tuple bound via Cons pattern
    const source =
        \\fn main() -> i32 {
        \\    let entries: List[(i32, i32)] = Cons((1, 10), Cons((2, 20), Nil))
        \\    match entries {
        \\        Cons(entry, rest) => { return entry.0 }
        \\        Nil => { return 0 }
        \\    }
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 1), result.?.integer);
}

test "interpreter: tuple field access with let binding after cons match" {
    const allocator = testing.allocator;

    // Test the pattern from BUG.md: binding entry, then accessing .0 and .1 with let
    const source =
        \\fn main() -> i32 {
        \\    let entries: List[(i32, i32)] = Cons((42, 100), Nil)
        \\    match entries {
        \\        Cons(entry, rest) => {
        \\            let first: i32 = entry.0
        \\            let second: i32 = entry.1
        \\            return first + second
        \\        }
        \\        Nil => { return 0 }
        \\    }
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 142), result.?.integer);
}

test "interpreter: tuple field access on std.map.entries result" {
    const allocator = testing.allocator;

    // Test std.map.entries which returns List[(string, T)] - similar to kira-json usage
    const source =
        \\fn main() -> string {
        \\    let m: Map[string, i32] = std.map.put(std.map.new(), "hello", 42)
        \\    let entries: List[(string, i32)] = std.map.entries(m)
        \\    match entries {
        \\        Cons(entry, rest) => {
        \\            let key: string = entry.0
        \\            return key
        \\        }
        \\        Nil => { return "empty" }
        \\    }
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqualStrings("hello", result.?.string);
}

test "interpreter: tuple access in recursive function processing list" {
    const allocator = testing.allocator;

    // Test recursive list processing with tuple access - closer to kira-json patterns
    const source =
        \\fn sum_first(entries: List[(i32, i32)]) -> i32 {
        \\    match entries {
        \\        Cons(entry, rest) => {
        \\            let first: i32 = entry.0
        \\            return first + sum_first(rest)
        \\        }
        \\        Nil => { return 0 }
        \\    }
        \\}
        \\
        \\fn main() -> i32 {
        \\    let list: List[(i32, i32)] = Cons((10, 1), Cons((20, 2), Cons((30, 3), Nil)))
        \\    return sum_first(list)
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, 60), result.?.integer);
}

test "resolver should catch undefined identifier in parsed code" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i64 {
        \\    let x: i64 = undefined_var
        \\    return x
        \\}
    ;

    // Parse
    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Resolve - should fail with undefined identifier
    const result = Kira.resolve(allocator, &program, &table);
    try testing.expectError(error.ResolutionFailed, result);
}

test "resolver should catch undefined identifier with module declaration" {
    const allocator = testing.allocator;

    const source =
        \\module testmod
        \\
        \\fn main() -> i64 {
        \\    let x: i64 = undefined_var
        \\    return x
        \\}
    ;

    // Parse
    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Resolve - should fail with undefined identifier
    const result = Kira.resolve(allocator, &program, &table);
    try testing.expectError(error.ResolutionFailed, result);
}

test "resolver with module loader should catch undefined identifier" {
    const allocator = testing.allocator;

    const source =
        \\module testmod
        \\
        \\fn main() -> i64 {
        \\    let x: i64 = undefined_var
        \\    return x
        \\}
    ;

    // Parse
    var program = try Kira.parse(allocator, source);
    defer program.deinit();

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Create module loader like checkFile does
    var loader = Kira.ModuleLoader.init(allocator, &table);
    defer loader.deinit();

    // Create resolver with loader like checkFile does
    var resolver = Kira.Resolver.initWithLoader(allocator, &table, &loader);
    defer resolver.deinit();

    // Resolve - should fail with undefined identifier
    const result = resolver.resolve(&program);
    try testing.expectError(error.ResolutionFailed, result);
}

// ============================================================================
// Interpolated String Tests
// ============================================================================

test "interpreter: basic string interpolation" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    let name: string = "world"
        \\    return "hello {name}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("hello world", r.value.?.string);
}

test "interpreter: interpolation with multiple expressions" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    let a: string = "foo"
        \\    let b: string = "bar"
        \\    return "{a} and {b}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("foo and bar", r.value.?.string);
}

test "interpreter: interpolation with arithmetic expression" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    let x: i32 = 6
        \\    let y: i32 = 7
        \\    return "result is {x * y}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("result is 42", r.value.?.string);
}

test "interpreter: interpolation equivalent to string concatenation" {
    const allocator = testing.allocator;

    // An interpolation with just a string variable should produce
    // the same result as the variable itself
    const source =
        \\fn main() -> string {
        \\    let greeting: string = "hello"
        \\    return "{greeting}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("hello", r.value.?.string);
}

test "interpreter: interpolation with integer value" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    let n: i32 = 42
        \\    return "the answer is {n}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("the answer is 42", r.value.?.string);
}

test "interpreter: interpolation with boolean value" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    let flag: bool = true
        \\    return "value is {flag}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("value is true", r.value.?.string);
}

test "interpreter: plain string without interpolation unchanged" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    return "no interpolation here"
        \\}
    ;

    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqualStrings("no interpolation here", result.?.string);
}

// ============================================================================
// Built-in Trait Method Tests (Eq, Ord, Show)
// ============================================================================

test "interpreter: Eq.eq on integers" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let x: i32 = 42
        \\    return x.eq(42)
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

test "interpreter: Eq.eq on integers returns false" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let x: i32 = 42
        \\    return x.eq(99)
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(false, result.?.boolean);
}

test "interpreter: Eq.eq on strings" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let s: string = "hello"
        \\    return s.eq("hello")
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

test "interpreter: Eq.eq on booleans" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let b: bool = true
        \\    return b.eq(true)
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

test "interpreter: Show.show on integer" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> string {
        \\    let x: i32 = 42
        \\    return x.show()
        \\}
    ;
    var result = try evalSourceFull(allocator, source);
    defer result.deinit();
    try testing.expect(result.value != null);
    try testing.expectEqualStrings("42", result.value.?.string);
}

test "interpreter: Show.show on string" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> string {
        \\    let s: string = "hello"
        \\    return s.show()
        \\}
    ;
    var result = try evalSourceFull(allocator, source);
    defer result.deinit();
    try testing.expect(result.value != null);
    try testing.expectEqualStrings("hello", result.value.?.string);
}

test "interpreter: Ord.lt on integers" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let x: i32 = 10
        \\    return x.lt(20)
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

test "interpreter: Ord.gt on integers" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let x: i32 = 20
        \\    return x.gt(10)
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

test "interpreter: Ord.compare on integers" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 5
        \\    return x.compare(10)
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(@as(i128, -1), result.?.integer);
}

test "interpreter: Ord.lt on strings" {
    const allocator = testing.allocator;
    const source =
        \\fn main() -> bool {
        \\    let a: string = "apple"
        \\    return a.lt("banana")
        \\}
    ;
    const result = try evalSource(allocator, source);
    try testing.expect(result != null);
    try testing.expectEqual(true, result.?.boolean);
}

test "interpreter: escaped brace in string is literal" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> string {
        \\    return "hello \{world}"
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqualStrings("hello {world}", r.value.?.string);
}

test "interpreter: mutable field assignment on record" {
    const allocator = testing.allocator;

    const source =
        \\type Point = { x: i32, y: i32 }
        \\
        \\effect fn main() -> i32 {
        \\    var p: Point = Point { x: 1, y: 2 }
        \\    p.x = 10
        \\    return p.x
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqual(@as(i128, 10), r.value.?.integer);
}

test "interpreter: mutable index assignment on array" {
    const allocator = testing.allocator;

    const source =
        \\effect fn main() -> i32 {
        \\    var arr: [i32] = [1, 2, 3]
        \\    arr[1] = 20
        \\    return arr[1]
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqual(@as(i128, 20), r.value.?.integer);
}

test "interpreter: nested field assignment" {
    const allocator = testing.allocator;

    const source =
        \\type Inner = { value: i32 }
        \\type Outer = { inner: Inner }
        \\
        \\effect fn main() -> i32 {
        \\    var o: Outer = Outer { inner: Inner { value: 5 } }
        \\    o.inner.value = 42
        \\    return o.inner.value
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqual(@as(i128, 42), r.value.?.integer);
}

test "interpreter: field mutation visible after assignment" {
    const allocator = testing.allocator;

    const source =
        \\type Counter = { count: i32 }
        \\
        \\effect fn main() -> i32 {
        \\    var c: Counter = Counter { count: 0 }
        \\    c.count = c.count + 1
        \\    c.count = c.count + 1
        \\    c.count = c.count + 1
        \\    return c.count
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    try testing.expectEqual(@as(i128, 3), r.value.?.integer);
}

test "interpreter: field mutation in pure function rejected by type checker" {
    const allocator = testing.allocator;

    const source =
        \\type Point = { x: i32, y: i32 }
        \\
        \\fn main() -> i32 {
        \\    var p: Point = Point { x: 1, y: 2 }
        \\    p.x = 10
        \\    return p.x
        \\}
    ;

    const ok = try typecheckSource(allocator, source);
    try testing.expect(!ok);
}

test "interpreter: index mutation in pure function rejected by type checker" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    var arr: [i32] = [1, 2, 3]
        \\    arr[0] = 99
        \\    return arr[0]
        \\}
    ;

    const ok = try typecheckSource(allocator, source);
    try testing.expect(!ok);
}

test "interpreter: assignment to let binding rejected by type checker" {
    const allocator = testing.allocator;

    const source =
        \\fn main() -> i32 {
        \\    let x: i32 = 5
        \\    x = 10
        \\    return x
        \\}
    ;

    const ok = try typecheckSource(allocator, source);
    try testing.expect(!ok);
}

test "interpreter: field mutation on immutable let binding fails" {
    const allocator = testing.allocator;

    const source =
        \\type Point = { x: i32, y: i32 }
        \\
        \\effect fn main() -> i32 {
        \\    let p: Point = Point { x: 1, y: 2 }
        \\    p.x = 10
        \\    return p.x
        \\}
    ;

    // Even in effect function, let binding field mutation should fail at runtime
    const result = evalSourceFull(allocator, source);
    try testing.expectError(error.ImmutableAssignment, result);
}

test "interpreter: array mutation does not alias" {
    const allocator = testing.allocator;

    const source =
        \\effect fn main() -> i32 {
        \\    var a: [i32] = [1, 2, 3]
        \\    var b: [i32] = a
        \\    b[0] = 99
        \\    return a[0]
        \\}
    ;

    var r = try evalSourceFull(allocator, source);
    defer r.deinit();
    try testing.expect(r.value != null);
    // a[0] should still be 1, not 99
    try testing.expectEqual(@as(i128, 1), r.value.?.integer);
}
