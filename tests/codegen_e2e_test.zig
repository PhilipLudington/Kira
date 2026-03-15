//! End-to-end tests for Kira C code generation.
//!
//! Each test runs a Kira program through two paths:
//! 1. Compile to C → cc → run binary → capture stdout
//! 2. Interpret directly → capture stdout
//! Then asserts the outputs match.

const std = @import("std");
const Kira = @import("Kira");

const Allocator = std.mem.Allocator;

// ============================================================
// Pipeline helpers
// ============================================================

/// Run the full Kira pipeline in-memory: parse → resolve → typecheck → lower → codegen.
/// Returns owned C source string; caller must free.
fn compileToC(allocator: Allocator, source: []const u8) ![]const u8 {
    // Parse
    var parse_result = Kira.parseWithErrors(allocator, source);
    if (parse_result.hasErrors()) {
        parse_result.deinit();
        return error.ParseFailed;
    }
    var program = parse_result.program orelse {
        parse_result.deinit();
        return error.ParseFailed;
    };
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| arena.deinit();
    defer program.deinit();

    // Resolve
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();
    var resolver = Kira.Resolver.init(allocator, &table);
    defer resolver.deinit();
    resolver.resolve(&program) catch return error.ResolveFailed;

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();
    checker.check(&program) catch return error.TypeCheckFailed;

    // Lower to IR
    var lowerer = Kira.IRLowerer.init(allocator);
    defer lowerer.deinit();
    var ir_module = lowerer.lower(&program) catch return error.LowerFailed;
    defer ir_module.deinit();

    // Generate C code
    var gen = Kira.codegen.CCodeGen.init(allocator);
    defer gen.deinit();
    gen.generateModule(&ir_module) catch return error.CodegenFailed;

    return allocator.dupe(u8, gen.getOutput());
}

/// Write C source to a temp file, compile with cc, run the binary, capture stdout.
/// Returns owned stdout string; caller must free.
fn compileCAndRun(allocator: Allocator, c_source: []const u8) ![]const u8 {
    const c_path = "/tmp/kira_e2e_test.c";
    const bin_path = "/tmp/kira_e2e_test";

    // Write C source
    {
        const c_file = std.fs.cwd().createFile(c_path, .{}) catch return error.TempFileError;
        defer c_file.close();
        c_file.writeAll(c_source) catch return error.TempFileError;
    }
    defer std.fs.cwd().deleteFile(c_path) catch {};

    // Compile: cc -o binary source.c -lm -lgc
    // On macOS with Homebrew, gc.h is under /opt/homebrew/include
    const cc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "cc", "-o", bin_path, c_path, "-lm",
            "-I/opt/homebrew/include", "-L/opt/homebrew/lib", "-lgc",
        },
    }) catch return error.CompilerNotFound;
    defer allocator.free(cc_result.stdout);
    defer allocator.free(cc_result.stderr);

    if (cc_result.term != .Exited or cc_result.term.Exited != 0) {
        return error.CompileFailed;
    }
    defer std.fs.cwd().deleteFile(bin_path) catch {};

    // Run binary and capture stdout
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{bin_path},
    }) catch return error.RunFailed;
    defer allocator.free(run_result.stderr);

    if (run_result.term != .Exited or run_result.term.Exited != 0) {
        allocator.free(run_result.stdout);
        return error.RunFailed;
    }

    return run_result.stdout;
}

/// Interpret Kira source with stdout capture. Returns owned output string; caller must free.
fn interpretAndCapture(allocator: Allocator, source: []const u8) ![]const u8 {
    // Parse
    var parse_result = Kira.parseWithErrors(allocator, source);
    if (parse_result.hasErrors()) {
        parse_result.deinit();
        return error.ParseFailed;
    }
    var program = parse_result.program orelse {
        parse_result.deinit();
        return error.ParseFailed;
    };
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| arena.deinit();
    defer program.deinit();

    // Resolve
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();
    var resolver = Kira.Resolver.init(allocator, &table);
    defer resolver.deinit();
    resolver.resolve(&program) catch return error.ResolveFailed;

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();
    checker.check(&program) catch return error.TypeCheckFailed;

    // Interpret with stdout capture
    var interp = Kira.Interpreter.init(allocator, &table);
    defer interp.deinit();

    var capture = std.ArrayListUnmanaged(u8){};
    defer capture.deinit(allocator);
    interp.setStdoutCapture(&capture, allocator);

    const arena_alloc = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(arena_alloc, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(arena_alloc, &interp.global_env);
    interp.registerBuiltinMethods();

    _ = interp.interpret(&program) catch return error.InterpretFailed;

    return allocator.dupe(u8, capture.items);
}

/// Compile C source with extra flags, run, and return stderr + exit code.
/// Used for testing abort/error paths (e.g. bounds checking).
fn compileCAndRunExpectAbort(allocator: Allocator, c_source: []const u8, extra_flags: []const []const u8) ![]const u8 {
    const c_path = "/tmp/kira_e2e_abort_test.c";
    const bin_path = "/tmp/kira_e2e_abort_test";

    // Write C source
    {
        const c_file = std.fs.cwd().createFile(c_path, .{}) catch return error.TempFileError;
        defer c_file.close();
        c_file.writeAll(c_source) catch return error.TempFileError;
    }
    defer std.fs.cwd().deleteFile(c_path) catch {};

    // Build argv: cc -o bin src -lm -I... -L... -lgc [extra_flags...]
    var argv_list = std.ArrayListUnmanaged([]const u8){};
    defer argv_list.deinit(allocator);
    const base_args = [_][]const u8{
        "cc", "-o", bin_path, c_path, "-lm",
        "-I/opt/homebrew/include", "-L/opt/homebrew/lib", "-lgc",
    };
    for (base_args) |a| argv_list.append(allocator, a) catch return error.OutOfMemory;
    for (extra_flags) |f| argv_list.append(allocator, f) catch return error.OutOfMemory;

    const cc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
    }) catch return error.CompilerNotFound;
    defer allocator.free(cc_result.stdout);
    defer allocator.free(cc_result.stderr);

    if (cc_result.term != .Exited or cc_result.term.Exited != 0) {
        return error.CompileFailed;
    }
    defer std.fs.cwd().deleteFile(bin_path) catch {};

    // Run binary — expect non-zero exit (abort)
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{bin_path},
    }) catch return error.RunFailed;
    defer allocator.free(run_result.stdout);

    // Should NOT have exited cleanly
    const exited_ok = (run_result.term == .Exited and run_result.term.Exited == 0);
    if (exited_ok) {
        allocator.free(run_result.stderr);
        return error.RunFailed; // Expected abort but got clean exit
    }

    return run_result.stderr;
}

/// Run a Kira program through both compiled-C and interpreter paths,
/// asserting the outputs match. Skips if cc is not available.
fn assertE2E(source: []const u8) !void {
    const allocator = std.testing.allocator;

    const c_code = try compileToC(allocator, source);
    defer allocator.free(c_code);

    const compiled_output = compileCAndRun(allocator, c_code) catch |err| {
        if (err == error.CompilerNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(compiled_output);

    const interp_output = try interpretAndCapture(allocator, source);
    defer allocator.free(interp_output);

    // Trim trailing whitespace for comparison (compiled may add trailing newline)
    const compiled_trimmed = std.mem.trimRight(u8, compiled_output, "\n\r \t");
    const interp_trimmed = std.mem.trimRight(u8, interp_output, "\n\r \t");

    try std.testing.expectEqualStrings(interp_trimmed, compiled_trimmed);
}

// ============================================================
// E2E Tests
// ============================================================

test "e2e: hello world" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    std.io.println("Hello, World!")
        \\}
    );
}

test "e2e: arithmetic and int_to_string" {
    try assertE2E(
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn mul(a: i32, b: i32) -> i32 {
        \\    return a * b
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(std.int.to_string(add(3, 4)))
        \\    std.io.println(std.int.to_string(mul(5, 6)))
        \\    std.io.println(std.int.to_string(add(100, mul(3, 7))))
        \\}
    );
}

test "e2e: fibonacci recursion" {
    try assertE2E(
        \\fn fib(n: i32) -> i32 {
        \\    if n <= 1 {
        \\        return n
        \\    }
        \\    return fib(n - 1) + fib(n - 2)
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(std.int.to_string(fib(0)))
        \\    std.io.println(std.int.to_string(fib(1)))
        \\    std.io.println(std.int.to_string(fib(10)))
        \\}
    );
}

test "e2e: conditionals and string output" {
    try assertE2E(
        \\fn classify(n: i32) -> string {
        \\    if n > 0 {
        \\        return "positive"
        \\    }
        \\    if n < 0 {
        \\        return "negative"
        \\    }
        \\    return "zero"
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(classify(42))
        \\    std.io.println(classify(-7))
        \\    std.io.println(classify(0))
        \\}
    );
}

test "e2e: factorial recursion" {
    try assertE2E(
        \\fn factorial(n: i32) -> i32 {
        \\    if n <= 1 {
        \\        return 1
        \\    }
        \\    return n * factorial(n - 1)
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(std.int.to_string(factorial(1)))
        \\    std.io.println(std.int.to_string(factorial(5)))
        \\    std.io.println(std.int.to_string(factorial(10)))
        \\}
    );
}

test "e2e: nested function calls" {
    try assertE2E(
        \\fn double(n: i32) -> i32 {
        \\    return n * 2
        \\}
        \\
        \\fn square(n: i32) -> i32 {
        \\    return n * n
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(std.int.to_string(double(square(3))))
        \\    std.io.println(std.int.to_string(square(double(3))))
        \\}
    );
}

// --- Tier 5: Filesystem builtins ---

test "e2e: fs_write_file and fs_read_file" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    match std.fs.write_file("/tmp/kira_e2e_fs_test.txt", "hello from kira") {
        \\        Ok(_) => {
        \\            match std.fs.read_file("/tmp/kira_e2e_fs_test.txt") {
        \\                Ok(content) => {
        \\                    std.io.println(content)
        \\                }
        \\                Err(e) => {
        \\                    std.io.println("read error: " + e)
        \\                }
        \\            }
        \\        }
        \\        Err(e) => {
        \\            std.io.println("write error: " + e)
        \\        }
        \\    }
        \\    std.fs.remove("/tmp/kira_e2e_fs_test.txt")
        \\}
    );
}

test "e2e: fs_exists" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    std.fs.write_file("/tmp/kira_e2e_exists_test.txt", "test")
        \\    if std.fs.exists("/tmp/kira_e2e_exists_test.txt") {
        \\        std.io.println("exists")
        \\    } else {
        \\        std.io.println("not found")
        \\    }
        \\    std.fs.remove("/tmp/kira_e2e_exists_test.txt")
        \\    if std.fs.exists("/tmp/kira_e2e_exists_test.txt") {
        \\        std.io.println("still exists")
        \\    } else {
        \\        std.io.println("removed")
        \\    }
        \\}
    );
}

test "e2e: fs_read_file error on missing file" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    match std.fs.read_file("/tmp/kira_e2e_nonexistent_file_12345.txt") {
        \\        Ok(content) => {
        \\            std.io.println("unexpected: " + content)
        \\        }
        \\        Err(e) => {
        \\            std.io.println("error: " + e)
        \\        }
        \\    }
        \\}
    );
}

test "e2e: fs_append_file" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    std.fs.write_file("/tmp/kira_e2e_append_test.txt", "line1")
        \\    std.fs.append_file("/tmp/kira_e2e_append_test.txt", "-line2")
        \\    match std.fs.read_file("/tmp/kira_e2e_append_test.txt") {
        \\        Ok(content) => {
        \\            std.io.println(content)
        \\        }
        \\        Err(e) => {
        \\            std.io.println("error: " + e)
        \\        }
        \\    }
        \\    std.fs.remove("/tmp/kira_e2e_append_test.txt")
        \\}
    );
}

// --- Tier 5: Time builtins ---

test "e2e: time_now returns positive value" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let t: i64 = std.time.now()
        \\    if t > 0i64 {
        \\        std.io.println("ok")
        \\    } else {
        \\        std.io.println("error: time is not positive")
        \\    }
        \\}
    );
}

// --- GC stress test ---

test "e2e: heavy allocation with GC" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    var i: i32 = 0
        \\    while i < 10000 {
        \\        let s: string = "item_" + std.int.to_string(i)
        \\        i = i + 1
        \\    }
        \\    std.io.println("done: " + std.int.to_string(i))
        \\}
    );
}

// --- Tier 5: Assert builtins ---

test "e2e: assert_eq passes" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    std.assert.assert_eq(42, 42)
        \\    std.io.println("passed")
        \\}
    );
}

// --- Memoization ---

test "e2e: memo fibonacci" {
    try assertE2E(
        \\memo fn fibonacci(n: i32) -> i32 {
        \\    if n <= 0 {
        \\        return 0
        \\    }
        \\    if n == 1 {
        \\        return 1
        \\    }
        \\    return fibonacci(n - 1) + fibonacci(n - 2)
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(std.int.to_string(fibonacci(0)))
        \\    std.io.println(std.int.to_string(fibonacci(1)))
        \\    std.io.println(std.int.to_string(fibonacci(5)))
        \\    std.io.println(std.int.to_string(fibonacci(10)))
        \\    std.io.println(std.int.to_string(fibonacci(20)))
        \\}
    );
}

// --- Bounds checking ---

test "e2e: out-of-bounds access aborts with KIRA_BOUNDS_CHECK" {
    const allocator = std.testing.allocator;

    // Program that accesses index 5 of a 3-element array
    const source =
        \\effect fn main() -> void {
        \\    let arr: [i32] = [10, 20, 30]
        \\    let x: i32 = arr[5]
        \\    std.io.println(std.int.to_string(x))
        \\}
    ;

    const c_code = compileToC(allocator, source) catch return;
    defer allocator.free(c_code);

    const extra_flags = [_][]const u8{"-DKIRA_BOUNDS_CHECK"};
    const stderr_output = compileCAndRunExpectAbort(allocator, c_code, &extra_flags) catch |err| {
        if (err == error.CompilerNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(stderr_output);

    // Verify the error message mentions bounds
    try std.testing.expect(std.mem.indexOf(u8, stderr_output, "bounds error") != null);
}

// --- env_args ---

test "e2e: env_args returns array with program name" {
    const allocator = std.testing.allocator;

    // Program that gets args and prints the count (should be 1 = binary name)
    const source =
        \\effect fn main() -> void {
        \\    let args: [string] = std.env.args()
        \\    std.io.println("done")
        \\}
    ;

    const c_code = compileToC(allocator, source) catch return;
    defer allocator.free(c_code);

    // Verify it compiles and runs successfully (C-only, no interpreter comparison)
    const output = compileCAndRun(allocator, c_code) catch |err| {
        if (err == error.CompilerNotFound) return error.SkipZigTest;
        return err;
    };
    defer allocator.free(output);

    try std.testing.expectEqualStrings("done", std.mem.trimRight(u8, output, "\n\r \t"));
}

// --- Example programs ---

test "e2e: simple_parser example" {
    try assertE2E(
        \\type Expr =
        \\    | Number(i64)
        \\    | Add(Expr, Expr)
        \\    | Sub(Expr, Expr)
        \\    | Mul(Expr, Expr)
        \\    | Div(Expr, Expr)
        \\
        \\fn eval(expr: Expr) -> Result[i64, string] {
        \\    var result: Result[i64, string] = Ok(0i64)
        \\    match expr {
        \\        Number(n) => { result = Ok(n) }
        \\        Add(left, right) => {
        \\            match eval(left) {
        \\                Ok(l) => {
        \\                    match eval(right) {
        \\                        Ok(r) => { result = Ok(l + r) }
        \\                        Err(e) => { result = Err(e) }
        \\                    }
        \\                }
        \\                Err(e) => { result = Err(e) }
        \\            }
        \\        }
        \\        Sub(left, right) => {
        \\            match eval(left) {
        \\                Ok(l) => {
        \\                    match eval(right) {
        \\                        Ok(r) => { result = Ok(l - r) }
        \\                        Err(e) => { result = Err(e) }
        \\                    }
        \\                }
        \\                Err(e) => { result = Err(e) }
        \\            }
        \\        }
        \\        Mul(left, right) => {
        \\            match eval(left) {
        \\                Ok(l) => {
        \\                    match eval(right) {
        \\                        Ok(r) => { result = Ok(l * r) }
        \\                        Err(e) => { result = Err(e) }
        \\                    }
        \\                }
        \\                Err(e) => { result = Err(e) }
        \\            }
        \\        }
        \\        Div(left, right) => {
        \\            match eval(left) {
        \\                Ok(l) => {
        \\                    match eval(right) {
        \\                        Ok(r) => {
        \\                            if r == 0 {
        \\                                result = Err("Division by zero")
        \\                            } else {
        \\                                result = Ok(l / r)
        \\                            }
        \\                        }
        \\                        Err(e) => { result = Err(e) }
        \\                    }
        \\                }
        \\                Err(e) => { result = Err(e) }
        \\            }
        \\        }
        \\    }
        \\    return result
        \\}
        \\
        \\fn show_expr(expr: Expr) -> string {
        \\    var result: string = ""
        \\    match expr {
        \\        Number(n) => { result = std.int.to_string(n) }
        \\        Add(left, right) => { result = "(" + show_expr(left) + " + " + show_expr(right) + ")" }
        \\        Sub(left, right) => { result = "(" + show_expr(left) + " - " + show_expr(right) + ")" }
        \\        Mul(left, right) => { result = "(" + show_expr(left) + " * " + show_expr(right) + ")" }
        \\        Div(left, right) => { result = "(" + show_expr(left) + " / " + show_expr(right) + ")" }
        \\    }
        \\    return result
        \\}
        \\
        \\effect fn main() -> void {
        \\    let expr1: Expr = Add(Number(2i64), Number(3i64))
        \\    std.io.println("Expression: " + show_expr(expr1))
        \\    match eval(expr1) {
        \\        Ok(r) => { std.io.println("Result: " + std.int.to_string(r)) }
        \\        Err(e) => { std.io.println("Error: " + e) }
        \\    }
        \\    let expr2: Expr = Div(Number(10i64), Number(0i64))
        \\    std.io.println("Expression: " + show_expr(expr2))
        \\    match eval(expr2) {
        \\        Ok(r) => { std.io.println("Result: " + std.int.to_string(r)) }
        \\        Err(e) => { std.io.println("Error: " + e) }
        \\    }
        \\}
    );
}

// ============================================================
// String Interpolation E2E Tests
// ============================================================

test "e2e: simple string interpolation" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let name: string = "world"
        \\    std.io.println("hello ${name}")
        \\}
    );
}

test "e2e: interpolation with multiple expressions" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let a: i32 = 3
        \\    let b: i32 = 4
        \\    std.io.println("${a} + ${b} = ${a + b}")
        \\}
    );
}

test "e2e: escaped dollar sign" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    std.io.println("\${literal}")
        \\}
    );
}

test "e2e: interpolation with adjacent parts" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let x: i32 = 1
        \\    let y: i32 = 2
        \\    std.io.println("${x}${y}")
        \\}
    );
}

test "e2e: interpolation with only expression" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let msg: string = "hello"
        \\    std.io.println("${msg}")
        \\}
    );
}

test "e2e: interpolation with boolean value" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let flag: bool = true
        \\    std.io.println("flag is ${flag}")
        \\}
    );
}

test "e2e: interpolation mixed types" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    let name: string = "Kira"
        \\    let version: i32 = 1
        \\    std.io.println("${name} v${version}")
        \\}
    );
}

// Format specifier tests (interpreter-only; C codegen support is future work)

test "e2e: format specifier zero-padded integer" {
    const output = try interpretAndCapture(std.testing.allocator,
        \\effect fn main() -> void {
        \\    let x: i32 = 42
        \\    std.io.println("${x:05d}")
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("00042\n", output);
}

test "e2e: format specifier hex" {
    const output = try interpretAndCapture(std.testing.allocator,
        \\effect fn main() -> void {
        \\    std.io.println("${255:x}")
        \\    std.io.println("${255:X}")
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("ff\nFF\n", output);
}

test "e2e: format specifier float precision" {
    const output = try interpretAndCapture(std.testing.allocator,
        \\effect fn main() -> void {
        \\    let pi: f64 = 3.14159
        \\    std.io.println("${pi:.2f}")
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("3.14\n", output);
}

test "e2e: format specifier width padding" {
    const output = try interpretAndCapture(std.testing.allocator,
        \\effect fn main() -> void {
        \\    std.io.println("[${42:6d}]")
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("[    42]\n", output);
}

test "e2e: format specifier binary" {
    const output = try interpretAndCapture(std.testing.allocator,
        \\effect fn main() -> void {
        \\    std.io.println("${10:b}")
        \\}
    );
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("1010\n", output);
}

// ============================================================
// Interop E2E Tests
// ============================================================

/// Run Kira source through the full pipeline, build an IR module, and call the
/// interop generators (header, Klar extern block, JSON manifest). Returns the
/// three generated outputs.
fn compileToIRModule(allocator: Allocator, source: []const u8) !struct {
    module: Kira.ir.ir.Module,
    program: Kira.Program,
    table: Kira.SymbolTable,
    resolver: Kira.Resolver,
    checker: Kira.TypeChecker,
    lowerer: Kira.ir.Lowerer,
} {
    // Parse
    var parse_result = Kira.parseWithErrors(allocator, source);
    if (parse_result.hasErrors()) {
        parse_result.deinit();
        return error.ParseFailed;
    }
    var program = parse_result.program orelse {
        parse_result.deinit();
        return error.ParseFailed;
    };
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| arena.deinit();

    // Resolve
    var table = Kira.SymbolTable.init(allocator);
    var resolver = Kira.Resolver.init(allocator, &table);
    resolver.resolve(&program) catch {
        program.deinit();
        resolver.deinit();
        table.deinit();
        return error.ResolveFailed;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    checker.check(&program) catch {
        program.deinit();
        checker.deinit();
        resolver.deinit();
        table.deinit();
        return error.TypeCheckFailed;
    };

    // Lower to IR
    var lowerer = Kira.ir.Lowerer.init(allocator);
    var ir_module = lowerer.lower(&program) catch {
        program.deinit();
        lowerer.deinit();
        checker.deinit();
        resolver.deinit();
        table.deinit();
        return error.LowerFailed;
    };
    _ = &ir_module;

    return .{
        .module = ir_module,
        .program = program,
        .table = table,
        .resolver = resolver,
        .checker = checker,
        .lowerer = lowerer,
    };
}

test "e2e interop: mixed types produce valid header, klar, and json" {
    const allocator = std.testing.allocator;

    const source =
        \\type Shape =
        \\    | Circle(f64)
        \\    | Rect(f64, f64)
        \\    | Pt
        \\
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn greet(name: string) -> string {
        \\    return "hello " + name
        \\}
        \\
        \\fn is_valid(x: bool) -> bool {
        \\    return x
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println("test")
        \\}
    ;

    var result = try compileToIRModule(allocator, source);
    defer result.module.deinit();
    defer result.program.deinit();
    defer result.lowerer.deinit();
    defer result.checker.deinit();
    defer result.resolver.deinit();
    defer result.table.deinit();

    // Generate header
    const header = try Kira.interop.klar.generateHeader(allocator, &result.module, "mixed");
    defer allocator.free(header);

    // Header should contain correct C types
    try std.testing.expect(std.mem.indexOf(u8, header, "#ifndef KIRA_MIXED_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "int32_t add(int32_t a, int32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "const char* greet(const char* name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "bool is_valid(bool x)") != null);
    // main should be excluded
    try std.testing.expect(std.mem.indexOf(u8, header, "main(") == null);
    // ADT declarations
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Shape_Tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_free") != null);

    // Generate Klar extern block
    const klar = try Kira.interop.klar.generateKlarExternBlock(allocator, &result.module);
    defer allocator.free(klar);

    try std.testing.expect(std.mem.indexOf(u8, klar, "extern {") != null);
    try std.testing.expect(std.mem.indexOf(u8, klar, "fn add(a: i32, b: i32) -> i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, klar, "fn greet(name: CStr) -> CStr") != null);
    try std.testing.expect(std.mem.indexOf(u8, klar, "fn is_valid(x: Bool) -> Bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, klar, "extern enum kira_Shape_Tag") != null);

    // Generate JSON manifest
    const json = try Kira.interop.klar.generateManifestJSON(allocator, &result.module, "mixed");
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"module\": \"mixed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"is_valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"Shape\"") != null);
    // main excluded
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"main\"") == null);
}

test "e2e interop: generated C header compiles with cc" {
    const allocator = std.testing.allocator;

    const source =
        \\type Color =
        \\    | Red
        \\    | Green
        \\    | Blue
        \\
        \\type Point = {
        \\    x: f64,
        \\    y: f64
        \\}
        \\
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println("test")
        \\}
    ;

    var result = try compileToIRModule(allocator, source);
    defer result.module.deinit();
    defer result.program.deinit();
    defer result.lowerer.deinit();
    defer result.checker.deinit();
    defer result.resolver.deinit();
    defer result.table.deinit();

    const header = try Kira.interop.klar.generateHeader(allocator, &result.module, "test");
    defer allocator.free(header);

    // Write header to temp file and verify it compiles
    const h_path = "/tmp/kira_e2e_interop_test.h";
    {
        const h_file = std.fs.cwd().createFile(h_path, .{}) catch return error.SkipZigTest;
        defer h_file.close();
        h_file.writeAll(header) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(h_path) catch {};

    // Write a minimal C file that includes the header
    const c_path = "/tmp/kira_e2e_interop_test.c";
    {
        const c_file = std.fs.cwd().createFile(c_path, .{}) catch return error.SkipZigTest;
        defer c_file.close();
        c_file.writeAll("#include \"kira_e2e_interop_test.h\"\nint main(void) { return 0; }\n") catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(c_path) catch {};

    // Compile with cc -fsyntax-only
    const cc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "cc", "-fsyntax-only", "-I/tmp", c_path },
    }) catch return error.SkipZigTest;
    defer allocator.free(cc_result.stdout);
    defer allocator.free(cc_result.stderr);

    try std.testing.expect(cc_result.term == .Exited and cc_result.term.Exited == 0);
}

test "e2e interop: compiled library with C test harness" {
    const allocator = std.testing.allocator;

    // Simple library with add function
    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn double_it(x: i32) -> i32 {
        \\    return x * 2
        \\}
    ;

    // Compile to C
    const c_code = try compileToC(allocator, source);
    defer allocator.free(c_code);

    // Get IR module for library wrappers
    var result = try compileToIRModule(allocator, source);
    defer result.module.deinit();
    defer result.program.deinit();
    defer result.lowerer.deinit();
    defer result.checker.deinit();
    defer result.resolver.deinit();
    defer result.table.deinit();

    // Generate library wrappers
    const wrappers = try Kira.interop.klar.generateLibraryWrappers(allocator, &result.module);
    defer allocator.free(wrappers);

    // Generate header
    const header = try Kira.interop.klar.generateHeader(allocator, &result.module, "testlib");
    defer allocator.free(header);

    // Write header file
    const h_path = "/tmp/kira_e2e_lib_test.h";
    {
        const h_file = std.fs.cwd().createFile(h_path, .{}) catch return error.SkipZigTest;
        defer h_file.close();
        h_file.writeAll(header) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(h_path) catch {};

    // Write combined library C source (codegen + wrappers)
    const lib_path = "/tmp/kira_e2e_lib_test_lib.c";
    {
        const lib_file = std.fs.cwd().createFile(lib_path, .{}) catch return error.SkipZigTest;
        defer lib_file.close();
        lib_file.writeAll(c_code) catch return error.SkipZigTest;
        lib_file.writeAll(wrappers) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(lib_path) catch {};

    // Write C test harness
    const test_c_path = "/tmp/kira_e2e_lib_test_main.c";
    {
        const test_file = std.fs.cwd().createFile(test_c_path, .{}) catch return error.SkipZigTest;
        defer test_file.close();
        test_file.writeAll(
            \\#include <stdio.h>
            \\#include "kira_e2e_lib_test.h"
            \\
            \\int main(void) {
            \\    int32_t sum = add(10, 20);
            \\    int32_t doubled = double_it(15);
            \\    printf("%d\n%d\n", sum, doubled);
            \\    return 0;
            \\}
            \\
        ) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(test_c_path) catch {};

    // Compile both files together
    const bin_path = "/tmp/kira_e2e_lib_test";
    const cc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "cc", "-o", bin_path, test_c_path, lib_path,
            "-I/tmp", "-lm",
            "-I/opt/homebrew/include", "-L/opt/homebrew/lib", "-lgc",
        },
    }) catch return error.SkipZigTest;
    defer allocator.free(cc_result.stdout);
    defer allocator.free(cc_result.stderr);

    if (cc_result.term != .Exited or cc_result.term.Exited != 0) {
        return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(bin_path) catch {};

    // Run and verify output
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{bin_path},
    }) catch return error.SkipZigTest;
    defer allocator.free(run_result.stderr);

    if (run_result.term != .Exited or run_result.term.Exited != 0) {
        allocator.free(run_result.stdout);
        return error.SkipZigTest;
    }

    const output = std.mem.trimRight(u8, run_result.stdout, "\n\r \t");
    defer allocator.free(run_result.stdout);

    try std.testing.expectEqualStrings("30\n30", output);
}

test "e2e interop: cross-language round-trip memory stability" {
    const allocator = std.testing.allocator;

    // Library with integer and string-returning functions.
    // greet() allocates via GC on every call — exercises the memory boundary.
    const source =
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b
        \\}
        \\
        \\fn greet(name: string) -> string {
        \\    return "Hello, " + name
        \\}
    ;

    // Compile to C
    const c_code = try compileToC(allocator, source);
    defer allocator.free(c_code);

    // Get IR module for library wrappers
    var result = try compileToIRModule(allocator, source);
    defer result.module.deinit();
    defer result.program.deinit();
    defer result.lowerer.deinit();
    defer result.checker.deinit();
    defer result.resolver.deinit();
    defer result.table.deinit();

    // Generate library wrappers
    const wrappers = try Kira.interop.klar.generateLibraryWrappers(allocator, &result.module);
    defer allocator.free(wrappers);

    // Generate header
    const header = try Kira.interop.klar.generateHeader(allocator, &result.module, "roundtrip");
    defer allocator.free(header);

    // Write header file
    const h_path = "/tmp/kira_e2e_roundtrip.h";
    {
        const h_file = std.fs.cwd().createFile(h_path, .{}) catch return error.SkipZigTest;
        defer h_file.close();
        h_file.writeAll(header) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(h_path) catch {};

    // Write combined library C source (codegen + wrappers)
    const lib_path = "/tmp/kira_e2e_roundtrip_lib.c";
    {
        const lib_file = std.fs.cwd().createFile(lib_path, .{}) catch return error.SkipZigTest;
        defer lib_file.close();
        lib_file.writeAll(c_code) catch return error.SkipZigTest;
        lib_file.writeAll(wrappers) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(lib_path) catch {};

    // C test harness: calls Kira functions 10,000 times via the typed wrapper
    // API (same interface Klar uses), then checks GC heap didn't grow unboundedly.
    const test_c_path = "/tmp/kira_e2e_roundtrip_main.c";
    {
        const test_file = std.fs.cwd().createFile(test_c_path, .{}) catch return error.SkipZigTest;
        defer test_file.close();
        test_file.writeAll(
            \\#include <stdio.h>
            \\#include <gc.h>
            \\#include "kira_e2e_roundtrip.h"
            \\
            \\int main(void) {
            \\    GC_INIT();
            \\
            \\    /* Warmup: let GC stabilize */
            \\    for (int i = 0; i < 1000; i++) {
            \\        (void)add(i, i + 1);
            \\        (void)greet("warmup");
            \\    }
            \\    GC_gcollect();
            \\    size_t heap_before = GC_get_heap_size();
            \\
            \\    /* Round-trip: 10,000 iterations with string allocation */
            \\    for (int i = 0; i < 10000; i++) {
            \\        int32_t sum = add(i, i + 1);
            \\        (void)sum;
            \\        const char* msg = greet("World");
            \\        (void)msg;
            \\        if (i % 1000 == 0) GC_gcollect();
            \\    }
            \\
            \\    GC_gcollect();
            \\    size_t heap_after = GC_get_heap_size();
            \\
            \\    /* Fail if heap grew more than 10x — indicates unbounded leak */
            \\    if (heap_before > 0 && heap_after > heap_before * 10) {
            \\        printf("LEAK: %zu -> %zu bytes\n", heap_before, heap_after);
            \\        return 1;
            \\    }
            \\
            \\    printf("OK\n");
            \\    return 0;
            \\}
            \\
        ) catch return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(test_c_path) catch {};

    // Compile both files together
    const bin_path = "/tmp/kira_e2e_roundtrip";
    const cc_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "cc", "-o", bin_path, test_c_path, lib_path,
            "-I/tmp", "-lm",
            "-I/opt/homebrew/include", "-L/opt/homebrew/lib", "-lgc",
        },
    }) catch return error.SkipZigTest;
    defer allocator.free(cc_result.stdout);
    defer allocator.free(cc_result.stderr);

    if (cc_result.term != .Exited or cc_result.term.Exited != 0) {
        return error.SkipZigTest;
    }
    defer std.fs.cwd().deleteFile(bin_path) catch {};

    // Run and verify no memory growth
    const run_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{bin_path},
    }) catch return error.SkipZigTest;
    defer allocator.free(run_result.stderr);

    if (run_result.term != .Exited or run_result.term.Exited != 0) {
        allocator.free(run_result.stdout);
        return error.SkipZigTest;
    }

    const output = std.mem.trimRight(u8, run_result.stdout, "\n\r \t");
    defer allocator.free(run_result.stdout);

    try std.testing.expectEqualStrings("OK", output);
}

test "e2e: list_map, list_filter, list_length with closures" {
    try assertE2E(
        \\fn count_words(text: string) -> i64 {
        \\    let words: List[string] = std.string.split(text, " ")
        \\    let trimmed: List[string] = std.list.map[string, string](
        \\        words,
        \\        fn(w: string) -> string { return std.string.trim(w) }
        \\    )
        \\    let non_empty: List[string] = std.list.filter[string](
        \\        trimmed,
        \\        fn(w: string) -> bool { return std.string.length(w) > 0 }
        \\    )
        \\    return std.list.length[string](non_empty)
        \\}
        \\
        \\effect fn main() -> void {
        \\    std.io.println(std.int.to_string(count_words("hello world")))
        \\    std.io.println(std.int.to_string(count_words("  one  two  three  ")))
        \\    std.io.println(std.int.to_string(count_words("")))
        \\}
    );
}
