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

// --- Tier 5: Assert builtins ---

test "e2e: assert_eq passes" {
    try assertE2E(
        \\effect fn main() -> void {
        \\    std.assert.assert_eq(42, 42)
        \\    std.io.println("passed")
        \\}
    );
}
