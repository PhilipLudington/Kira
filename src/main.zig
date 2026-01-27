const std = @import("std");
const Kira = @import("Kira");
const Allocator = std.mem.Allocator;

const version = "0.1.0";

/// Command-line interface modes
const Mode = enum {
    repl,
    run,
    check,
    test_cmd,
    help,
    version_info,
};

/// Parsed command-line arguments
const Args = struct {
    mode: Mode,
    file_path: ?[]const u8,
    show_tokens: bool,
    show_ast: bool,
    /// Arguments passed to the Kira program (after the file path)
    user_args: []const []const u8,
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
                // Set program arguments for std.env.args()
                Kira.interpreter_mod.stdlib.env_mod.setArgs(allocator, args.user_args) catch {};
                defer Kira.interpreter_mod.stdlib.env_mod.clearArgs();

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
        .test_cmd => {
            if (args.file_path) |path| {
                // Set program arguments for std.env.args()
                Kira.interpreter_mod.stdlib.env_mod.setArgs(allocator, args.user_args) catch {};
                defer Kira.interpreter_mod.stdlib.env_mod.clearArgs();

                testFile(allocator, path) catch |err| {
                    reportError(err);
                    std.process.exit(1);
                };
            } else {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("Error: 'test' command requires a file path\n") catch {};
                stderr.writeAll("Usage: kira test <file.ki>\n") catch {};
                std.process.exit(1);
            }
        },
    }
}

fn reportError(err: anyerror) void {
    const stderr = std.fs.File.stderr();
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Error: {}\n", .{err}) catch "Error occurred\n";
    stderr.writeAll(msg) catch {};
}

/// Buffer for storing user arguments (static to preserve lifetime)
var user_args_buffer: [256][]const u8 = undefined;
var user_args_count: usize = 0;

fn parseArgs() !Args {
    var args_iter = std.process.args();
    _ = args_iter.skip(); // Skip program name

    var result = Args{
        .mode = .repl,
        .file_path = null,
        .show_tokens = false,
        .show_ast = false,
        .user_args = &.{},
    };

    user_args_count = 0;
    var file_path_seen = false;

    while (args_iter.next()) |arg| {
        // If we've seen the file path, collect remaining as user args
        if (file_path_seen) {
            if (user_args_count < user_args_buffer.len) {
                user_args_buffer[user_args_count] = arg;
                user_args_count += 1;
            }
            continue;
        }

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
                file_path_seen = true;
            }
        } else if (std.mem.eql(u8, arg, "check")) {
            result.mode = .check;
            if (args_iter.next()) |path| {
                result.file_path = path;
                file_path_seen = true;
            }
        } else if (std.mem.eql(u8, arg, "test")) {
            result.mode = .test_cmd;
            if (args_iter.next()) |path| {
                result.file_path = path;
                file_path_seen = true;
            }
        } else if (std.mem.eql(u8, arg, "--tokens")) {
            result.show_tokens = true;
        } else if (std.mem.eql(u8, arg, "--ast")) {
            result.show_ast = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Bare file path - treat as run
            result.mode = .run;
            result.file_path = arg;
            file_path_seen = true;
        } else {
            return error.UnknownOption;
        }
    }

    // Set user_args slice to the collected args
    result.user_args = user_args_buffer[0..user_args_count];

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
        \\  test <file.ki>    Run tests in a file
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

    // Parse with detailed error information
    var parse_result = Kira.parseWithErrors(allocator, source);

    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        // Format and print detailed parse errors with line/column info
        for (parse_result.errors) |err| {
            var buf: [1024]u8 = undefined;
            if (err.expected) |expected| {
                const msg = std.fmt.bufPrint(&buf, "error[parse]: {s}:{d}:{d}: {s} (expected {s}, found {s})\n", .{
                    path,
                    err.line,
                    err.column,
                    err.message,
                    expected,
                    err.found orelse "unknown",
                }) catch "Parse error\n";
                stderr.writeAll(msg) catch {};
            } else {
                const msg = std.fmt.bufPrint(&buf, "error[parse]: {s}:{d}:{d}: {s}\n", .{
                    path,
                    err.line,
                    err.column,
                    err.message,
                }) catch "Parse error\n";
                stderr.writeAll(msg) catch {};
            }

            // Print the source line for context
            if (err.line > 0) {
                var line_num: u32 = 1;
                var line_start: usize = 0;
                var line_end: usize = 0;

                // Find the line in source
                for (source, 0..) |c, i| {
                    if (c == '\n') {
                        if (line_num == err.line) {
                            line_end = i;
                            break;
                        }
                        line_num += 1;
                        line_start = i + 1;
                    }
                }
                if (line_end == 0 and line_num == err.line) {
                    line_end = source.len;
                }

                if (line_end > line_start) {
                    const line_content = source[line_start..line_end];
                    var line_buf: [512]u8 = undefined;
                    const line_msg = std.fmt.bufPrint(&line_buf, "  {s}\n", .{line_content}) catch "";
                    stderr.writeAll(line_msg) catch {};

                    // Print caret pointing to the column
                    if (err.column > 0 and err.column <= line_content.len + 1) {
                        var caret_buf: [512]u8 = undefined;
                        @memset(caret_buf[0..err.column + 1], ' ');
                        caret_buf[err.column + 1] = '^';
                        caret_buf[err.column + 2] = '\n';
                        stderr.writeAll(caret_buf[0 .. err.column + 3]) catch {};
                    }
                }
            }
        }
        return error.ParseError;
    }

    var program = parse_result.program orelse {
        parse_result.deinit();
        try stderr.writeAll("error[parse]: Unknown parse error\n");
        return error.ParseError;
    };
    // Transfer ownership - clear from result so it won't be deinited
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| {
        arena.deinit();
    }
    defer program.deinit();

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Load project configuration (kira.toml)
    var project_config = Kira.ProjectConfig.init();
    defer project_config.deinit(allocator);

    if (std.fs.path.dirname(path)) |dir| {
        _ = project_config.loadFromDirectory(allocator, dir) catch {};
    }

    // Create module loader for cross-file imports with config
    var loader = Kira.ModuleLoader.initWithConfig(allocator, &table, if (project_config.isLoaded()) &project_config else null);
    defer loader.deinit();

    // Add search paths: current directory, parent directory, and directory containing the main file
    // Always add current directory for relative module paths
    loader.addSearchPath(".") catch {};

    if (std.fs.path.dirname(path)) |dir| {
        // Add parent directory as the package root (for nested module paths)
        if (std.fs.path.dirname(dir)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                loader.addSearchPath(parent) catch {};
            }
        }
        // Also add the directory containing the file as a fallback
        if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
            loader.addSearchPath(dir) catch {};
        }
    }

    // If we have a project config, also add project root as a search path
    if (project_config.project_root) |root| {
        loader.addSearchPath(root) catch {};
    }

    // Resolve symbols (using loader for cross-file imports)
    Kira.resolveWithLoader(allocator, &program, &table, &loader) catch |err| {
        // Check for loader errors first and format them nicely
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        if (!loader.hasErrors()) {
            try formatResolveError(stderr, path, source, err);
        }
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

    // Create interpreter
    var interp = Kira.Interpreter.init(allocator, &table);
    defer interp.deinit();

    // Register built-in functions and standard library
    // Use arena allocator so Value allocations are freed with the interpreter
    const arena_alloc = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(arena_alloc, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(arena_alloc, &interp.global_env);

    // Register declarations from loaded modules first
    // Create module namespace structures so qualified names like `src.json.X` work
    var modules_iter = loader.loadedModulesIterator();
    while (modules_iter.next()) |entry| {
        if (entry.value_ptr.program) |mod_program| {
            const module_key = entry.key_ptr.*;

            // Register module exports for import resolution
            // This allows `import module.{ item }` to find the item
            interp.registerModuleExports(
                module_key,
                mod_program.declarations,
            ) catch |err| {
                var buf: [512]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Warning: Failed to register exports for module '{s}': {}\n", .{ module_key, err }) catch "Warning: Module export registration failed\n";
                stderr.writeAll(msg) catch {};
            };

            // Parse module path from the key (e.g., "src.json" -> ["src", "json"])
            var path_segments = std.ArrayListUnmanaged([]const u8){};
            defer path_segments.deinit(allocator);

            var path_iter = std.mem.splitScalar(u8, module_key, '.');
            while (path_iter.next()) |segment| {
                path_segments.append(allocator, segment) catch {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Warning: Out of memory parsing module path '{s}'\n", .{module_key}) catch "Warning: Module path parsing failed\n";
                    stderr.writeAll(msg) catch {};
                    break;
                };
            }

            // Register the module namespace with its proper path
            if (path_segments.items.len > 0) {
                interp.registerModuleNamespace(
                    path_segments.items,
                    mod_program.declarations,
                    &interp.global_env,
                ) catch |err| {
                    var buf: [512]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Warning: Failed to register namespace for module '{s}': {}\n", .{ module_key, err }) catch "Warning: Module namespace registration failed\n";
                    stderr.writeAll(msg) catch {};
                };
            }

            // Also register declarations directly for backward compatibility
            // (allows using imported items without qualification if explicitly imported)
            for (mod_program.declarations) |*mod_decl| {
                // Skip module declarations, only register functions/types/etc
                if (mod_decl.kind != .module_decl and mod_decl.kind != .import_decl) {
                    interp.registerDeclaration(mod_decl, &interp.global_env) catch |err| {
                        var buf: [512]u8 = undefined;
                        const decl_name = switch (mod_decl.kind) {
                            .function_decl => |f| f.name,
                            .const_decl => |c| c.name,
                            .type_decl => |t| t.name,
                            else => "<unknown>",
                        };
                        const msg = std.fmt.bufPrint(&buf, "Warning: Failed to register declaration '{s}' from module '{s}': {}\n", .{ decl_name, module_key, err }) catch "Warning: Declaration registration failed\n";
                        stderr.writeAll(msg) catch {};
                    };
                }
            }
        }
    }


    // Interpret the main program
    const result = interp.interpret(&program) catch |err| {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Runtime error: {}\n", .{err}) catch "Runtime error\n";
        try stderr.writeAll(msg);
        // Print error context if available
        if (interp.getErrorContext()) |context| {
            var ctx_buf: [512]u8 = undefined;
            const ctx_msg = std.fmt.bufPrint(&ctx_buf, "  {s}\n", .{context}) catch "";
            try stderr.writeAll(ctx_msg);
        }
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

    // Parse with detailed error information
    var parse_result = Kira.parseWithErrors(allocator, source);

    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        // Format and print detailed parse errors with line/column info
        for (parse_result.errors) |err| {
            var buf: [1024]u8 = undefined;
            if (err.expected) |expected| {
                const msg = std.fmt.bufPrint(&buf, "error[parse]: {s}:{d}:{d}: {s} (expected {s}, found {s})\n", .{
                    path,
                    err.line,
                    err.column,
                    err.message,
                    expected,
                    err.found orelse "unknown",
                }) catch "Parse error\n";
                stderr.writeAll(msg) catch {};
            } else {
                const msg = std.fmt.bufPrint(&buf, "error[parse]: {s}:{d}:{d}: {s}\n", .{
                    path,
                    err.line,
                    err.column,
                    err.message,
                }) catch "Parse error\n";
                stderr.writeAll(msg) catch {};
            }

            // Print the source line for context
            if (err.line > 0) {
                var line_num: u32 = 1;
                var line_start: usize = 0;
                var line_end: usize = 0;

                // Find the line in source
                for (source, 0..) |c, i| {
                    if (c == '\n') {
                        if (line_num == err.line) {
                            line_end = i;
                            break;
                        }
                        line_num += 1;
                        line_start = i + 1;
                    }
                }
                if (line_end == 0 and line_num == err.line) {
                    line_end = source.len;
                }

                if (line_end > line_start) {
                    const line_content = source[line_start..line_end];
                    var line_buf: [512]u8 = undefined;
                    const line_msg = std.fmt.bufPrint(&line_buf, "  {s}\n", .{line_content}) catch "";
                    stderr.writeAll(line_msg) catch {};

                    // Print caret pointing to the column
                    if (err.column > 0 and err.column <= line_content.len + 1) {
                        var caret_buf: [512]u8 = undefined;
                        @memset(caret_buf[0..err.column + 1], ' ');
                        caret_buf[err.column + 1] = '^';
                        caret_buf[err.column + 2] = '\n';
                        stderr.writeAll(caret_buf[0 .. err.column + 3]) catch {};
                    }
                }
            }
        }
        return error.ParseError;
    }

    var program = parse_result.program orelse {
        parse_result.deinit();
        try stderr.writeAll("error[parse]: Unknown parse error\n");
        return error.ParseError;
    };
    // Transfer ownership - clear from result so it won't be deinited
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| {
        arena.deinit();
    }
    defer program.deinit();

    // Create symbol table
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    // Load project configuration (kira.toml)
    var project_config = Kira.ProjectConfig.init();
    defer project_config.deinit(allocator);

    if (std.fs.path.dirname(path)) |dir| {
        _ = project_config.loadFromDirectory(allocator, dir) catch {};
    }

    // Create module loader for cross-file imports with config
    var loader = Kira.ModuleLoader.initWithConfig(allocator, &table, if (project_config.isLoaded()) &project_config else null);
    defer loader.deinit();

    // Add search paths: current directory, parent directory, and directory containing the main file
    // Always add current directory for relative module paths
    loader.addSearchPath(".") catch {};

    if (std.fs.path.dirname(path)) |dir| {
        // Add parent directory as the package root (for nested module paths)
        if (std.fs.path.dirname(dir)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                loader.addSearchPath(parent) catch {};
            }
        }
        // Also add the directory containing the file as a fallback
        if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
            loader.addSearchPath(dir) catch {};
        }
    }

    // If we have a project config, also add project root as a search path
    if (project_config.project_root) |root| {
        loader.addSearchPath(root) catch {};
    }

    // Resolve symbols (using loader for cross-file imports)
    Kira.resolveWithLoader(allocator, &program, &table, &loader) catch |err| {
        // Check for loader errors first and format them nicely
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        if (!loader.hasErrors()) {
            try formatResolveError(stderr, path, source, err);
        }
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

/// Run tests in a Kira source file
fn testFile(allocator: Allocator, path: []const u8) !void {
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
    var parse_result = Kira.parseWithErrors(allocator, source);
    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        for (parse_result.errors) |err| {
            var buf: [1024]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error[parse]: {s}:{d}:{d}: {s}\n", .{
                path, err.line, err.column, err.message,
            }) catch "Parse error\n";
            stderr.writeAll(msg) catch {};
        }
        return error.ParseError;
    }

    var program = parse_result.program orelse {
        parse_result.deinit();
        return error.ParseError;
    };
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| {
        arena.deinit();
    }
    defer program.deinit();

    // Create symbol table and resolve
    var table = Kira.SymbolTable.init(allocator);
    defer table.deinit();

    var project_config = Kira.ProjectConfig.init();
    defer project_config.deinit(allocator);
    if (std.fs.path.dirname(path)) |dir| {
        _ = project_config.loadFromDirectory(allocator, dir) catch {};
    }

    var loader = Kira.ModuleLoader.initWithConfig(allocator, &table, if (project_config.isLoaded()) &project_config else null);
    defer loader.deinit();
    loader.addSearchPath(".") catch {};
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
            loader.addSearchPath(dir) catch {};
        }
    }
    if (project_config.project_root) |root| {
        loader.addSearchPath(root) catch {};
    }

    Kira.resolveWithLoader(allocator, &program, &table, &loader) catch |err| {
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        if (!loader.hasErrors()) {
            try formatResolveError(stderr, path, source, err);
        }
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

    // Create interpreter
    var interp = Kira.Interpreter.init(allocator, &table);
    defer interp.deinit();

    const arena_alloc = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(arena_alloc, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(arena_alloc, &interp.global_env);

    // Register declarations from loaded modules
    var modules_iter = loader.loadedModulesIterator();
    while (modules_iter.next()) |entry| {
        if (entry.value_ptr.program) |mod_program| {
            var path_segments = std.ArrayListUnmanaged([]const u8){};
            defer path_segments.deinit(allocator);
            var path_iter = std.mem.splitScalar(u8, entry.key_ptr.*, '.');
            while (path_iter.next()) |segment| {
                path_segments.append(allocator, segment) catch continue;
            }
            if (path_segments.items.len > 0) {
                interp.registerModuleNamespace(path_segments.items, mod_program.declarations, &interp.global_env) catch {};
            }
            for (mod_program.declarations) |*mod_decl| {
                if (mod_decl.kind != .module_decl and mod_decl.kind != .import_decl) {
                    interp.registerDeclaration(mod_decl, &interp.global_env) catch {};
                }
            }
        }
    }

    // Register non-test declarations
    for (program.declarations) |*decl| {
        if (decl.kind != .test_decl) {
            interp.registerDeclaration(decl, &interp.global_env) catch {};
        }
    }

    // Collect and run tests
    var test_count: u32 = 0;
    var pass_count: u32 = 0;
    var fail_count: u32 = 0;

    try stdout.writeAll("\nRunning tests...\n\n");

    for (program.declarations) |*decl| {
        if (decl.kind == .test_decl) {
            const test_decl = decl.kind.test_decl;
            test_count += 1;

            var name_buf: [256]u8 = undefined;
            const test_name = std.fmt.bufPrint(&name_buf, "test \"{s}\"", .{test_decl.name}) catch test_decl.name;

            // Run the test body
            var test_passed = true;
            for (test_decl.body) |*stmt| {
                _ = interp.evalStatement(stmt, &interp.global_env) catch |err| {
                    test_passed = false;
                    var err_buf: [512]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  FAIL: {s} - {}\n", .{ test_name, err }) catch "  FAIL\n";
                    try stderr.writeAll(err_msg);
                    break;
                };
            }

            if (test_passed) {
                pass_count += 1;
                var pass_buf: [256]u8 = undefined;
                const pass_msg = std.fmt.bufPrint(&pass_buf, "  PASS: {s}\n", .{test_name}) catch "  PASS\n";
                try stdout.writeAll(pass_msg);
            } else {
                fail_count += 1;
            }
        }
    }

    // Summary
    try stdout.writeAll("\n");
    var summary_buf: [256]u8 = undefined;
    if (fail_count == 0) {
        const summary = std.fmt.bufPrint(&summary_buf, "All {d} tests passed.\n", .{test_count}) catch "All tests passed.\n";
        try stdout.writeAll(summary);
    } else {
        const summary = std.fmt.bufPrint(&summary_buf, "{d} passed, {d} failed out of {d} tests.\n", .{ pass_count, fail_count, test_count }) catch "Some tests failed.\n";
        try stderr.writeAll(summary);
        return error.TestsFailed;
    }

    if (test_count == 0) {
        try stdout.writeAll("No tests found.\n");
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

    // Arena for Value allocations (freed when REPL exits)
    var value_arena = std.heap.ArenaAllocator.init(allocator);
    defer value_arena.deinit();
    const arena_alloc = value_arena.allocator();

    var global_env = Kira.Environment.init(allocator);
    defer global_env.deinit();

    // Register builtins and stdlib using arena allocator
    try Kira.interpreter_mod.registerBuiltins(arena_alloc, &global_env);
    try Kira.interpreter_mod.registerStdlib(arena_alloc, &global_env);

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
                // Reset environment and arena - use _ to explicitly discard the result
                global_env.deinit();
                _ = value_arena.reset(.retain_capacity);
                global_env = Kira.Environment.init(allocator);
                try Kira.interpreter_mod.registerBuiltins(arena_alloc, &global_env);
                try Kira.interpreter_mod.registerStdlib(arena_alloc, &global_env);
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
    defer program.deinit();

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
    // Use arena allocator so Value allocations are freed with the interpreter
    const interp_arena = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(interp_arena, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(interp_arena, &interp.global_env);

    // Copy user-defined bindings
    var binding_iter = env.bindings.iterator();
    while (binding_iter.next()) |entry| {
        interp.global_env.define(entry.key_ptr.*, entry.value_ptr.value, entry.value_ptr.is_mutable) catch {};
    }

    const result = interp.interpret(&program) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Runtime error: {}\n", .{err}) catch "Runtime error\n";
        try writer.writeAll(msg);
        // Print error context if available
        if (interp.getErrorContext()) |context| {
            var ctx_buf: [512]u8 = undefined;
            const ctx_msg = std.fmt.bufPrint(&ctx_buf, "  {s}\n", .{context}) catch "";
            try writer.writeAll(ctx_msg);
        }
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
    defer program.deinit();

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
    defer program.deinit();

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

    // Use arena allocator so Value allocations are freed with the interpreter
    const interp_arena = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(interp_arena, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(interp_arena, &interp.global_env);

    _ = interp.interpret(&program) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Runtime error: {}\n", .{err}) catch "Runtime error\n";
        try writer.writeAll(msg);
        // Print error context if available
        if (interp.getErrorContext()) |context| {
            var ctx_buf: [512]u8 = undefined;
            const ctx_msg = std.fmt.bufPrint(&ctx_buf, "  {s}\n", .{context}) catch "";
            try writer.writeAll(ctx_msg);
        }
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

/// Format a module load error with searched paths and hints
fn formatModuleError(writer: anytype, err_info: Kira.ModuleLoader.LoadErrorInfo, source: []const u8, file_path: []const u8) !void {
    var buf: [1024]u8 = undefined;

    // Header line
    const header = std.fmt.bufPrint(&buf, "error[module]: Module '{s}' not found\n", .{err_info.module_path}) catch "error[module]: Module not found\n";
    try writer.writeAll(header);

    // Location (if span is available)
    if (err_info.span) |span| {
        const loc = std.fmt.bufPrint(&buf, "  --> {s}:{d}:{d}\n", .{
            file_path,
            span.start.line,
            span.start.column,
        }) catch "";
        try writer.writeAll(loc);

        // Source line (if available)
        if (getSourceLine(source, span.start.line)) |line| {
            const gutter = std.fmt.bufPrint(&buf, "   {d} | ", .{span.start.line}) catch "     | ";
            try writer.writeAll(gutter);
            try writer.writeAll(line);
            try writer.writeAll("\n");

            // Pointer line
            try writer.writeAll("     | ");
            var i: usize = 1;
            while (i < span.start.column) : (i += 1) {
                try writer.writeAll(" ");
            }
            // Underline the module name
            var j: usize = 0;
            while (j < err_info.module_path.len) : (j += 1) {
                try writer.writeAll("^");
            }
            try writer.writeAll("\n");
        }
    } else {
        // Just show the file path
        const loc = std.fmt.bufPrint(&buf, "  --> {s}\n", .{file_path}) catch "";
        try writer.writeAll(loc);
    }

    // Show searched paths
    if (err_info.searched_paths) |paths| {
        if (paths.len > 0) {
            try writer.writeAll("\nSearched in:\n");
            for (paths) |p| {
                const path_line = std.fmt.bufPrint(&buf, "  - {s}\n", .{p}) catch "";
                try writer.writeAll(path_line);
            }
        }
    }

    // Hint about kira.toml
    try writer.writeAll("\nhint: Add module path to kira.toml:\n");
    try writer.writeAll("  [modules]\n");

    // Extract the root module name for the hint
    const root_name = blk: {
        if (std.mem.indexOfScalar(u8, err_info.module_path, '.')) |dot_pos| {
            break :blk err_info.module_path[0..dot_pos];
        }
        break :blk err_info.module_path;
    };

    const hint = std.fmt.bufPrint(&buf, "  {s} = \"path/to/module.ki\"\n\n", .{root_name}) catch "  module = \"path/to/module.ki\"\n\n";
    try writer.writeAll(hint);
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
        .user_args = &.{},
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
