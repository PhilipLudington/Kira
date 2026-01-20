const std = @import("std");
const Kira = @import("Kira");
const Allocator = std.mem.Allocator;

const version = "0.1.0";

/// Command-line interface modes
const Mode = enum {
    repl,
    run,
    check,
    help,
    version_info,
};

/// Parsed command-line arguments
const Args = struct {
    mode: Mode,
    file_path: ?[]const u8,
    show_tokens: bool,
    show_ast: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs() catch |err| {
        const stderr = std.fs.File.stderr();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: {}\n", .{err}) catch "Error parsing arguments\n";
        stderr.writeAll(msg) catch {};
        stderr.writeAll("Usage: kira [command] [options] [file]\n") catch {};
        stderr.writeAll("Run 'kira --help' for more information.\n") catch {};
        std.process.exit(1);
    };

    switch (args.mode) {
        .help => printHelp(),
        .version_info => printVersion(),
        .run => {
            if (args.file_path) |path| {
                runFile(allocator, path, false) catch |err| {
                    reportError(err);
                    std.process.exit(1);
                };
            } else {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("Error: 'run' command requires a file path\n") catch {};
                stderr.writeAll("Usage: kira run <file.ki>\n") catch {};
                std.process.exit(1);
            }
        },
        .check => {
            if (args.file_path) |path| {
                checkFile(allocator, path) catch |err| {
                    reportError(err);
                    std.process.exit(1);
                };
            } else {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("Error: 'check' command requires a file path\n") catch {};
                stderr.writeAll("Usage: kira check <file.ki>\n") catch {};
                std.process.exit(1);
            }
        },
        .repl => runRepl(allocator) catch |err| {
            reportError(err);
            std.process.exit(1);
        },
    }
}

fn reportError(err: anyerror) void {
    const stderr = std.fs.File.stderr();
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {}\n", .{err}) catch "Error occurred\n";
    stderr.writeAll(msg) catch {};
}

fn parseArgs() !Args {
    var args_iter = std.process.args();
    _ = args_iter.skip(); // Skip program name

    var result = Args{
        .mode = .repl,
        .file_path = null,
        .show_tokens = false,
        .show_ast = false,
    };

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.mode = .help;
            return result;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            result.mode = .version_info;
            return result;
        } else if (std.mem.eql(u8, arg, "run")) {
            result.mode = .run;
            if (args_iter.next()) |path| {
                result.file_path = path;
            }
        } else if (std.mem.eql(u8, arg, "check")) {
            result.mode = .check;
            if (args_iter.next()) |path| {
                result.file_path = path;
            }
        } else if (std.mem.eql(u8, arg, "--tokens")) {
            result.show_tokens = true;
        } else if (std.mem.eql(u8, arg, "--ast")) {
            result.show_ast = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Bare file path - treat as run
            result.mode = .run;
            result.file_path = arg;
        } else {
            return error.UnknownOption;
        }
    }

    return result;
}

fn printHelp() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(
        \\Kira Programming Language v
    ++ version ++
        \\
        \\
        \\A functional programming language with explicit types, explicit effects, and no surprises.
        \\
        \\Usage: kira [command] [options] [file]
        \\
        \\Commands:
        \\  run <file.ki>     Run a Kira program
        \\  check <file.ki>   Type-check a program without running
        \\  (no command)      Start the interactive REPL
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  -v, --version     Show version information
        \\  --tokens          Show token stream (debug)
        \\  --ast             Show AST (debug)
        \\
        \\REPL Commands:
        \\  :help, :h         Show REPL help
        \\  :quit, :q         Exit the REPL
        \\  :type <expr>      Show the type of an expression
        \\  :load <file>      Load a .ki file
        \\  :clear            Clear the REPL environment
        \\  :tokens           Toggle token display mode
        \\
        \\Examples:
        \\  kira run hello.ki     Run a program
        \\  kira check lib.ki     Type-check without running
        \\  kira                  Start REPL
        \\
    ) catch {};
}

fn printVersion() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll("Kira Programming Language v" ++ version ++ "\n") catch {};
}

/// Run a Kira source file
fn runFile(allocator: Allocator, path: []const u8, silent: bool) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Read the file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: Cannot open file '{s}': {}\n", .{ path, err }) catch "Error opening file\n";
        try stderr.writeAll(msg);
        return error.FileNotFound;
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error reading file: {}\n", .{err}) catch "Error reading file\n";
        try stderr.writeAll(msg);
        return error.ReadError;
    };
    defer allocator.free(source);

    // Parse
    var program = Kira.parse(allocator, source) catch |err| {
        try formatParseError(stderr, path, source, err);
        return error.ParseError;
    };
    defer program.deinit(allocator);

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Resolve symbols
    Kira.resolve(allocator, &program, &table) catch |err| {
        try formatResolveError(stderr, path, source, err);
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();

    checker.check(&program) catch {
        // Print all diagnostics
        for (checker.getDiagnostics()) |diag| {
            try formatDiagnostic(stderr, path, source, diag);
        }
        return error.TypeCheckError;
    };

    // Check for warnings even on success
    const diagnostics = checker.getDiagnostics();
    for (diagnostics) |diag| {
        if (diag.kind == .warning or diag.kind == .hint) {
            try formatDiagnostic(stderr, path, source, diag);
        }
    }

    // Interpret
    const result = Kira.interpret(allocator, &program, &table) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Runtime error: {}\n", .{err}) catch "Runtime error\n";
        try stderr.writeAll(msg);
        return error.RuntimeError;
    };

    // Print result if not silent and there's a value
    if (!silent) {
        if (result) |val| {
            if (val != .void) {
                var buf: [1024]u8 = undefined;
                const output = formatValue(val, &buf);
                try stdout.writeAll(output);
                try stdout.writeAll("\n");
            }
        }
    }
}

/// Check (type-check) a file without running it
fn checkFile(allocator: Allocator, path: []const u8) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Read the file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: Cannot open file '{s}': {}\n", .{ path, err }) catch "Error opening file\n";
        try stderr.writeAll(msg);
        return error.FileNotFound;
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error reading file: {}\n", .{err}) catch "Error reading file\n";
        try stderr.writeAll(msg);
        return error.ReadError;
    };
    defer allocator.free(source);

    // Parse
    var program = Kira.parse(allocator, source) catch |err| {
        try formatParseError(stderr, path, source, err);
        return error.ParseError;
    };
    defer program.deinit(allocator);

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Resolve symbols
    Kira.resolve(allocator, &program, &table) catch |err| {
        try formatResolveError(stderr, path, source, err);
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            try formatDiagnostic(stderr, path, source, diag);
        }
        return error.TypeCheckError;
    };

    // Print any warnings
    const diagnostics = checker.getDiagnostics();
    var warning_count: usize = 0;
    for (diagnostics) |diag| {
        if (diag.kind == .warning) {
            try formatDiagnostic(stderr, path, source, diag);
            warning_count += 1;
        }
    }

    // Success message
    var buf: [256]u8 = undefined;
    if (warning_count > 0) {
        const msg = std.fmt.bufPrint(&buf, "Check passed with {d} warning(s): {s}\n", .{ warning_count, path }) catch "Check passed with warnings\n";
        try stdout.writeAll(msg);
    } else {
        const msg = std.fmt.bufPrint(&buf, "Check passed: {s}\n", .{path}) catch "Check passed\n";
        try stdout.writeAll(msg);
    }
}

/// Interactive REPL
fn runRepl(allocator: Allocator) !void {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();

    try stdout.writeAll("Kira Programming Language v" ++ version ++ "\n");
    try stdout.writeAll("Type :help for help, :quit to exit\n\n");

    // Persistent state across REPL sessions
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    var global_env = Kira.Environment.init(allocator);
    defer global_env.deinit();

    // Register builtins and stdlib
    try Kira.interpreter_mod.registerBuiltins(allocator, &global_env);
    try Kira.interpreter_mod.registerStdlib(allocator, &global_env);

    var show_tokens = false;
    var line_buf: [8192]u8 = undefined;
    var history = std.ArrayListUnmanaged([]const u8){};
    defer {
        for (history.items) |h| {
            allocator.free(h);
        }
        history.deinit(allocator);
    }

    while (true) {
        try stdout.writeAll("kira> ");

        // Read line
        const line = readLine(stdin, &line_buf) catch |err| {
            if (err == error.EndOfStream) {
                try stdout.writeAll("\nGoodbye!\n");
                return;
            }
            return err;
        };

        if (line.len == 0) continue;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Add to history
        const history_entry = try allocator.dupe(u8, trimmed);
        try history.append(allocator, history_entry);

        // Handle REPL commands
        if (std.mem.startsWith(u8, trimmed, ":")) {
            if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":q")) {
                try stdout.writeAll("Goodbye!\n");
                return;
            } else if (std.mem.eql(u8, trimmed, ":help") or std.mem.eql(u8, trimmed, ":h")) {
                try printReplHelp(stdout);
            } else if (std.mem.eql(u8, trimmed, ":tokens")) {
                show_tokens = !show_tokens;
                if (show_tokens) {
                    try stdout.writeAll("Token display enabled\n");
                } else {
                    try stdout.writeAll("Token display disabled\n");
                }
            } else if (std.mem.eql(u8, trimmed, ":clear")) {
                // Reset environment
                global_env.deinit();
                global_env = Kira.Environment.init(allocator);
                try Kira.interpreter_mod.registerBuiltins(allocator, &global_env);
                try Kira.interpreter_mod.registerStdlib(allocator, &global_env);
                try stdout.writeAll("Environment cleared\n");
            } else if (std.mem.startsWith(u8, trimmed, ":type ")) {
                const expr_text = trimmed[6..];
                try evalType(allocator, expr_text, stdout, &table);
            } else if (std.mem.startsWith(u8, trimmed, ":load ")) {
                const file_path = std.mem.trim(u8, trimmed[6..], " \t");
                loadFile(allocator, file_path, &table, &global_env, stdout) catch |err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Error loading file: {}\n", .{err}) catch "Error loading file\n";
                    try stdout.writeAll(msg);
                };
            } else {
                try stdout.writeAll("Unknown command. Type :help for available commands.\n");
            }
            continue;
        }

        // Show tokens if enabled
        if (show_tokens) {
            var tokens = Kira.tokenize(allocator, trimmed) catch |err| {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Lexer error: {}\n", .{err}) catch "Lexer error\n";
                try stdout.writeAll(msg);
                continue;
            };
            defer tokens.deinit(allocator);

            try stdout.writeAll("Tokens:\n");
            var print_buf: [512]u8 = undefined;
            for (tokens.items) |tok| {
                const tok_line = std.fmt.bufPrint(&print_buf, "  {s}: \"{s}\" at {d}:{d}\n", .{
                    @tagName(tok.type),
                    tok.lexeme,
                    tok.span.start.line,
                    tok.span.start.column,
                }) catch continue;
                try stdout.writeAll(tok_line);
            }
        }

        // Evaluate the input
        evalLine(allocator, trimmed, &table, &global_env, stdout) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: {}\n", .{err}) catch "Error\n";
            try stdout.writeAll(msg);
        };
    }
}

fn readLine(stdin: std.fs.File, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        var byte: [1]u8 = undefined;
        const n = try stdin.read(&byte);
        if (n == 0) {
            if (len == 0) return error.EndOfStream;
            break;
        }
        if (byte[0] == '\n') break;
        buf[len] = byte[0];
        len += 1;
    }
    return buf[0..len];
}

fn printReplHelp(writer: anytype) !void {
    try writer.writeAll(
        \\REPL Commands:
        \\  :help, :h         Show this help message
        \\  :quit, :q         Exit the REPL
        \\  :type <expr>      Show the type of an expression
        \\  :load <file>      Load a .ki file into the environment
        \\  :clear            Clear the REPL environment
        \\  :tokens           Toggle token display mode
        \\
        \\Enter Kira expressions, statements, or declarations to evaluate.
        \\
        \\Examples:
        \\  let x: i32 = 42
        \\  x + 1
        \\  fn add(a: i32, b: i32) -> i32 { a + b }
        \\  std.io.println("Hello!")
        \\
    );
}

/// Evaluate a line in the REPL
fn evalLine(
    allocator: Allocator,
    input: []const u8,
    table: *Kira.SymbolTable,
    env: *Kira.Environment,
    writer: anytype,
) !void {
    // Wrap input to make it a valid program
    // Try as expression first, then as statement/declaration
    const wrapped = try wrapInput(allocator, input);
    defer allocator.free(wrapped);

    // Parse
    var program = Kira.parse(allocator, wrapped) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Parse error: {}\n", .{err}) catch "Parse error\n";
        try writer.writeAll(msg);
        return;
    };
    defer program.deinit(allocator);

    // Resolve
    Kira.resolve(allocator, &program, table) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Resolution error: {}\n", .{err}) catch "Resolution error\n";
        try writer.writeAll(msg);
        return;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: {s} at {d}:{d}\n", .{
                diag.kind.toString(),
                diag.message,
                diag.span.start.line,
                diag.span.start.column,
            }) catch "Type error\n";
            try writer.writeAll(msg);
        }
        return;
    };

    // Interpret
    var interp = Kira.Interpreter.init(allocator, table);
    defer interp.deinit();

    // Copy existing bindings to interpreter's global env
    // (This is a simplified approach - a full implementation would share the environment)
    try Kira.interpreter_mod.registerBuiltins(allocator, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(allocator, &interp.global_env);

    // Copy user-defined bindings
    var binding_iter = env.bindings.iterator();
    while (binding_iter.next()) |entry| {
        interp.global_env.define(entry.key_ptr.*, entry.value_ptr.value, entry.value_ptr.is_mutable) catch {};
    }

    const result = interp.interpret(&program) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Runtime error: {}\n", .{err}) catch "Runtime error\n";
        try writer.writeAll(msg);
        return;
    };

    // Copy new bindings back to persistent environment
    var new_iter = interp.global_env.bindings.iterator();
    while (new_iter.next()) |entry| {
        env.define(entry.key_ptr.*, entry.value_ptr.value, entry.value_ptr.is_mutable) catch {};
    }

    // Print result
    if (result) |val| {
        if (val != .void) {
            var buf: [1024]u8 = undefined;
            const output = formatValue(val, &buf);
            try writer.writeAll(output);
            try writer.writeAll("\n");
        }
    }
}

/// Wrap REPL input to make it a valid program
fn wrapInput(allocator: Allocator, input: []const u8) ![]const u8 {
    // Check if it looks like a declaration (fn, let, type, etc.)
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "fn ") or
        std.mem.startsWith(u8, trimmed, "let ") or
        std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "type ") or
        std.mem.startsWith(u8, trimmed, "effect ") or
        std.mem.startsWith(u8, trimmed, "pub ") or
        std.mem.startsWith(u8, trimmed, "import ") or
        std.mem.startsWith(u8, trimmed, "module "))
    {
        // It's a declaration, return as-is
        return try allocator.dupe(u8, input);
    }

    // Wrap expression in effect main to handle IO
    var result = std.ArrayListUnmanaged(u8){};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "effect fn main() -> void { std.io.println(std.string.to_string(");
    try result.appendSlice(allocator, input);
    try result.appendSlice(allocator, ")) }");

    return try result.toOwnedSlice(allocator);
}

/// Show the type of an expression
fn evalType(
    allocator: Allocator,
    input: []const u8,
    writer: anytype,
    table: *Kira.SymbolTable,
) !void {
    // Create a temporary declaration to type-check the expression
    var buf_storage: [8192]u8 = undefined;
    const wrapped = std.fmt.bufPrint(&buf_storage, "fn _type_check_() -> void {{ let _: auto = {s} }}", .{input}) catch {
        try writer.writeAll("Expression too long\n");
        return;
    };

    // Parse
    var program = Kira.parse(allocator, wrapped) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Parse error: {}\n", .{err}) catch "Parse error\n";
        try writer.writeAll(msg);
        return;
    };
    defer program.deinit(allocator);

    // Resolve
    Kira.resolve(allocator, &program, table) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Resolution error: {}\n", .{err}) catch "Resolution error\n";
        try writer.writeAll(msg);
        return;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}\n", .{diag.message}) catch "Type error\n";
            try writer.writeAll(msg);
        }
        return;
    };

    // TODO: Extract and print the inferred type
    // For now, just confirm it type-checks
    try writer.writeAll("Expression is well-typed\n");
}

/// Load a file into the REPL environment
fn loadFile(
    allocator: Allocator,
    path: []const u8,
    table: *Kira.SymbolTable,
    env: *Kira.Environment,
    writer: anytype,
) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cannot open file '{s}': {}\n", .{ path, err }) catch "Cannot open file\n";
        try writer.writeAll(msg);
        return error.FileNotFound;
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(source);

    // Parse
    var program = Kira.parse(allocator, source) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Parse error: {}\n", .{err}) catch "Parse error\n";
        try writer.writeAll(msg);
        return error.ParseError;
    };
    defer program.deinit(allocator);

    // Resolve
    Kira.resolve(allocator, &program, table) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Resolution error: {}\n", .{err}) catch "Resolution error\n";
        try writer.writeAll(msg);
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ diag.kind.toString(), diag.message }) catch "Type error\n";
            try writer.writeAll(msg);
        }
        return error.TypeCheckError;
    };

    // Register declarations in environment
    var interp = Kira.Interpreter.init(allocator, table);
    defer interp.deinit();

    try Kira.interpreter_mod.registerBuiltins(allocator, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(allocator, &interp.global_env);

    _ = interp.interpret(&program) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Runtime error: {}\n", .{err}) catch "Runtime error\n";
        try writer.writeAll(msg);
        return error.RuntimeError;
    };

    // Copy bindings to persistent environment
    var iter = interp.global_env.bindings.iterator();
    while (iter.next()) |entry| {
        env.define(entry.key_ptr.*, entry.value_ptr.value, entry.value_ptr.is_mutable) catch {};
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Loaded: {s}\n", .{path}) catch "File loaded\n";
    try writer.writeAll(msg);
}

/// Format a runtime value for display
fn formatValue(val: Kira.Value, buf: []u8) []const u8 {
    return switch (val) {
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "<integer>",
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch "<float>",
        .string => |s| std.fmt.bufPrint(buf, "\"{s}\"", .{s}) catch "<string>",
        .char => |c| std.fmt.bufPrint(buf, "'{u}'", .{c}) catch "<char>",
        .boolean => |b| if (b) "true" else "false",
        .void => "()",
        .none => "None",
        .nil => "[]",
        .some => |inner| blk: {
            var inner_buf: [256]u8 = undefined;
            const inner_str = formatValue(inner.*, &inner_buf);
            break :blk std.fmt.bufPrint(buf, "Some({s})", .{inner_str}) catch "Some(...)";
        },
        .ok => |inner| blk: {
            var inner_buf: [256]u8 = undefined;
            const inner_str = formatValue(inner.*, &inner_buf);
            break :blk std.fmt.bufPrint(buf, "Ok({s})", .{inner_str}) catch "Ok(...)";
        },
        .err => |inner| blk: {
            var inner_buf: [256]u8 = undefined;
            const inner_str = formatValue(inner.*, &inner_buf);
            break :blk std.fmt.bufPrint(buf, "Err({s})", .{inner_str}) catch "Err(...)";
        },
        .tuple => |items| blk: {
            if (items.len == 0) break :blk "()";
            var result: []const u8 = "(";
            for (items, 0..) |item, i| {
                var item_buf: [128]u8 = undefined;
                const item_str = formatValue(item, &item_buf);
                if (i > 0) {
                    result = std.fmt.bufPrint(buf, "{s}, {s}", .{ result, item_str }) catch "...";
                } else {
                    result = std.fmt.bufPrint(buf, "{s}{s}", .{ result, item_str }) catch "...";
                }
            }
            break :blk std.fmt.bufPrint(buf, "{s})", .{result}) catch "(...)";
        },
        .array => |items| blk: {
            if (items.len == 0) break :blk "[]";
            break :blk std.fmt.bufPrint(buf, "[{d} items]", .{items.len}) catch "[...]";
        },
        .record => "<record>",
        .function => |f| std.fmt.bufPrint(buf, "<fn {s}>", .{f.name orelse "anonymous"}) catch "<function>",
        .variant => |v| blk: {
            if (v.fields) |fields| {
                switch (fields) {
                    .tuple => |tuple_vals| {
                        if (tuple_vals.len == 1) {
                            var payload_buf: [256]u8 = undefined;
                            const payload_str = formatValue(tuple_vals[0], &payload_buf);
                            break :blk std.fmt.bufPrint(buf, "{s}({s})", .{ v.name, payload_str }) catch v.name;
                        } else {
                            break :blk std.fmt.bufPrint(buf, "{s}(...)", .{v.name}) catch v.name;
                        }
                    },
                    .record => break :blk std.fmt.bufPrint(buf, "{s}{{...}}", .{v.name}) catch v.name,
                }
            } else {
                break :blk v.name;
            }
        },
        .cons => "<list>",
        .io => |inner| blk: {
            var inner_buf: [256]u8 = undefined;
            const inner_str = formatValue(inner.*, &inner_buf);
            break :blk std.fmt.bufPrint(buf, "IO({s})", .{inner_str}) catch "IO(...)";
        },
        .reference => |ref| blk: {
            var inner_buf: [256]u8 = undefined;
            const inner_str = formatValue(ref.*, &inner_buf);
            break :blk std.fmt.bufPrint(buf, "ref {s}", .{inner_str}) catch "<ref>";
        },
    };
}

/// Format a parse error with source context
fn formatParseError(writer: anytype, path: []const u8, source: []const u8, err: anyerror) !void {
    _ = source;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error[parse]: {s}: {}\n", .{ path, err }) catch "Parse error\n";
    try writer.writeAll(msg);
}

/// Format a resolve error with source context
fn formatResolveError(writer: anytype, path: []const u8, source: []const u8, err: anyerror) !void {
    _ = source;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error[resolve]: {s}: {}\n", .{ path, err }) catch "Resolve error\n";
    try writer.writeAll(msg);
}

/// Format a diagnostic with source context
fn formatDiagnostic(writer: anytype, path: []const u8, source: []const u8, diag: Kira.TypeCheckDiagnostic) !void {
    var buf: [1024]u8 = undefined;

    // Header line
    const header = std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ diag.kind.toString(), diag.message }) catch "error\n";
    try writer.writeAll(header);

    // Location
    const loc = std.fmt.bufPrint(&buf, "  --> {s}:{d}:{d}\n", .{
        path,
        diag.span.start.line,
        diag.span.start.column,
    }) catch "";
    try writer.writeAll(loc);

    // Source line (if available)
    if (getSourceLine(source, diag.span.start.line)) |line| {
        // Line number gutter
        const gutter = std.fmt.bufPrint(&buf, "   {d} | ", .{diag.span.start.line}) catch "     | ";
        try writer.writeAll(gutter);
        try writer.writeAll(line);
        try writer.writeAll("\n");

        // Pointer line
        const pointer_offset = diag.span.start.column;
        try writer.writeAll("     | ");
        var i: usize = 1;
        while (i < pointer_offset) : (i += 1) {
            try writer.writeAll(" ");
        }
        try writer.writeAll("^\n");
    }

    // Related info
    if (diag.related) |related| {
        for (related) |info| {
            const rel = std.fmt.bufPrint(&buf, "  note: {s} at {d}:{d}\n", .{
                info.message,
                info.span.start.line,
                info.span.start.column,
            }) catch "";
            try writer.writeAll(rel);
        }
    }

    try writer.writeAll("\n");
}

/// Get a specific line from source code
fn getSourceLine(source: []const u8, line_num: usize) ?[]const u8 {
    if (line_num == 0) return null;

    var current_line: usize = 1;
    var start: usize = 0;

    for (source, 0..) |c, i| {
        if (current_line == line_num) {
            // Find end of line
            var end = i;
            while (end < source.len and source[end] != '\n') {
                end += 1;
            }
            return source[start..end];
        }
        if (c == '\n') {
            current_line += 1;
            start = i + 1;
        }
    }

    // Last line without newline
    if (current_line == line_num and start < source.len) {
        return source[start..];
    }

    return null;
}

test "Kira tokenize works" {
    var tokens = try Kira.tokenize(std.testing.allocator, "let x: i32 = 1");
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expect(tokens.items.len > 0);
}

test "parse args help" {
    // This is just a smoke test since we can't easily mock args
    _ = parseArgs() catch Args{
        .mode = .repl,
        .file_path = null,
        .show_tokens = false,
        .show_ast = false,
    };
}

test "format value" {
    var buf: [256]u8 = undefined;

    const int_val = Kira.Value{ .integer = 42 };
    const int_str = formatValue(int_val, &buf);
    try std.testing.expectEqualStrings("42", int_str);

    const bool_val = Kira.Value{ .boolean = true };
    const bool_str = formatValue(bool_val, &buf);
    try std.testing.expectEqualStrings("true", bool_str);

    const void_val = Kira.Value{ .void = {} };
    const void_str = formatValue(void_val, &buf);
    try std.testing.expectEqualStrings("()", void_str);
}

test "get source line" {
    const source = "line one\nline two\nline three";

    const line1 = getSourceLine(source, 1);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("line one", line1.?);

    const line2 = getSourceLine(source, 2);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("line two", line2.?);

    const line3 = getSourceLine(source, 3);
    try std.testing.expect(line3 != null);
    try std.testing.expectEqualStrings("line three", line3.?);

    const line4 = getSourceLine(source, 4);
    try std.testing.expect(line4 == null);
}
