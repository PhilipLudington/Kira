const std = @import("std");
const Kira = @import("Kira");
const Allocator = std.mem.Allocator;

const version = "0.11.1";

/// Command-line interface modes
const Mode = enum {
    repl,
    run,
    check,
    fmt,
    build,
    test_cmd,
    lsp,
    help,
    version_info,
};

/// Parsed command-line arguments
const Args = struct {
    mode: Mode,
    file_path: ?[]const u8,
    show_tokens: bool,
    show_ast: bool,
    no_color: bool,
    fmt_check: bool,
    output_path: ?[]const u8,
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

    // Determine if color output should be used
    const use_color = !args.no_color and Kira.diagnostic.isTTY(std.fs.File.stderr());

    switch (args.mode) {
        .help => printHelp(),
        .version_info => printVersion(),
        .run => {
            if (args.file_path) |path| {
                runFile(allocator, path, false, args.user_args, use_color) catch |err| {
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
                checkFile(allocator, path, use_color) catch |err| {
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
        .fmt => {
            if (args.file_path) |path| {
                fmtFile(allocator, path, args.fmt_check) catch |err| {
                    reportError(err);
                    std.process.exit(1);
                };
            } else {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("Error: 'fmt' command requires a file path\n") catch {};
                stderr.writeAll("Usage: kira fmt [--check] <file.ki>\n") catch {};
                std.process.exit(1);
            }
        },
        .build => {
            if (args.file_path) |path| {
                buildFile(allocator, path, args.output_path, use_color) catch |err| {
                    reportError(err);
                    std.process.exit(1);
                };
            } else {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("Error: 'build' command requires a file path\n") catch {};
                stderr.writeAll("Usage: kira build [--output <path>] <file.ki>\n") catch {};
                std.process.exit(1);
            }
        },
        .lsp => runLsp(allocator) catch |err| {
            reportError(err);
            std.process.exit(1);
        },
        .repl => runRepl(allocator) catch |err| {
            reportError(err);
            std.process.exit(1);
        },
        .test_cmd => {
            if (args.file_path) |path| {
                testFile(allocator, path, args.user_args, use_color) catch |err| {
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
        .no_color = false,
        .fmt_check = false,
        .output_path = null,
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
            } else {
                const stderr = std.fs.File.stderr();
                stderr.writeAll("Warning: too many arguments, excess arguments ignored\n") catch {};
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
        } else if (std.mem.eql(u8, arg, "fmt")) {
            result.mode = .fmt;
            // Look for --check flag and file path
            while (args_iter.next()) |fmt_arg| {
                if (std.mem.eql(u8, fmt_arg, "--check")) {
                    result.fmt_check = true;
                } else if (!std.mem.startsWith(u8, fmt_arg, "-")) {
                    result.file_path = fmt_arg;
                    file_path_seen = true;
                    break;
                }
            }
        } else if (std.mem.eql(u8, arg, "build")) {
            result.mode = .build;
            // Look for --output flag and file path
            while (args_iter.next()) |build_arg| {
                if (std.mem.eql(u8, build_arg, "--output") or std.mem.eql(u8, build_arg, "-o")) {
                    if (args_iter.next()) |out_path| {
                        result.output_path = out_path;
                    }
                } else if (!std.mem.startsWith(u8, build_arg, "-")) {
                    result.file_path = build_arg;
                    file_path_seen = true;
                    break;
                }
            }
        } else if (std.mem.eql(u8, arg, "lsp")) {
            result.mode = .lsp;
            return result;
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
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            result.no_color = true;
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
        \\  build <file.ki>   Compile to C (use --output for custom path)
        \\  check <file.ki>   Type-check a program without running
        \\  fmt <file.ki>     Format a Kira source file
        \\  test <file.ki>    Run tests in a file
        \\  lsp               Start the LSP server
        \\  (no command)      Start the interactive REPL
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  -v, --version     Show version information
        \\  --tokens          Show token stream (debug)
        \\  --ast             Show AST (debug)
        \\  --no-color        Disable colored output
        \\  -o, --output      (build) Output file path
        \\  --check           (fmt) Check formatting without modifying
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
        \\  kira build hello.ki   Compile to hello.c
        \\  kira check lib.ki     Type-check without running
        \\  kira fmt hello.ki     Format a source file
        \\  kira fmt --check .    Check formatting
        \\  kira                  Start REPL
        \\
    ) catch {};
}

fn printVersion() void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll("Kira Programming Language v" ++ version ++ "\n") catch {};
}

/// Run a Kira source file
fn runFile(allocator: Allocator, path: []const u8, silent: bool, user_args: []const []const u8, use_color: bool) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // Read the file
    const source = loadFileContent(allocator, stderr, path) orelse return error.ReadError;
    defer allocator.free(source);

    // Parse with detailed error information
    var parse_result = Kira.parseWithErrors(allocator, source);
    const renderer = Kira.diagnostic.DiagnosticRenderer.init(source, path, use_color);

    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        for (parse_result.errors) |err| {
            renderParseError(stderr, renderer, err) catch {};
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
    var resolver = Kira.Resolver.initWithLoader(allocator, &table, &loader);
    defer resolver.deinit();

    resolver.resolve(&program) catch {
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        for (resolver.getDiagnostics()) |diag| {
            renderResolverDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            renderTypeCheckDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.TypeCheckError;
    };

    // Check for warnings even on success
    const diagnostics = checker.getDiagnostics();
    for (diagnostics) |diag| {
        if (diag.kind == .warning or diag.kind == .hint) {
            renderTypeCheckDiagnostic(stderr, renderer, diag) catch {};
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
    interp.registerBuiltinMethods();

    // Set environment arguments for std.env.args()
    if (user_args.len > 0) {
        const env_args = Kira.interpreter_mod.stdlib.env_mod.convertArgsToValues(arena_alloc, user_args) catch null;
        if (env_args) |args_values| {
            interp.setEnvArgs(args_values);
        }
    }

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
fn checkFile(allocator: Allocator, path: []const u8, use_color: bool) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    const source = loadFileContent(allocator, stderr, path) orelse return error.ReadError;
    defer allocator.free(source);

    var parse_result = Kira.parseWithErrors(allocator, source);
    const renderer = Kira.diagnostic.DiagnosticRenderer.init(source, path, use_color);

    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        for (parse_result.errors) |err| {
            renderParseError(stderr, renderer, err) catch {};
        }
        return error.ParseError;
    }

    var program = parse_result.program orelse {
        parse_result.deinit();
        try stderr.writeAll("error[parse]: Unknown parse error\n");
        return error.ParseError;
    };
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
    var resolver = Kira.Resolver.initWithLoader(allocator, &table, &loader);
    defer resolver.deinit();

    resolver.resolve(&program) catch {
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        for (resolver.getDiagnostics()) |diag| {
            renderResolverDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            renderTypeCheckDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.TypeCheckError;
    };

    // Print any warnings
    const diagnostics = checker.getDiagnostics();
    var warning_count: usize = 0;
    for (diagnostics) |diag| {
        if (diag.kind == .warning) {
            renderTypeCheckDiagnostic(stderr, renderer, diag) catch {};
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

/// Build a Kira source file to a native executable via C codegen.
fn buildFile(allocator: Allocator, path: []const u8, output_path: ?[]const u8, use_color: bool) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    const source = loadFileContent(allocator, stderr, path) orelse return error.ReadError;
    defer allocator.free(source);

    // Parse
    var parse_result = Kira.parseWithErrors(allocator, source);
    const renderer = Kira.diagnostic.DiagnosticRenderer.init(source, path, use_color);

    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        for (parse_result.errors) |err| {
            renderParseError(stderr, renderer, err) catch {};
        }
        return error.ParseError;
    }

    var program = parse_result.program orelse {
        parse_result.deinit();
        try stderr.writeAll("error[parse]: Unknown parse error\n");
        return error.ParseError;
    };
    parse_result.program = null;
    if (parse_result.error_arena) |*arena| {
        arena.deinit();
    }
    defer program.deinit();

    // Resolve
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
        if (std.fs.path.dirname(dir)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                loader.addSearchPath(parent) catch {};
            }
        }
        if (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
            loader.addSearchPath(dir) catch {};
        }
    }
    if (project_config.project_root) |root| {
        loader.addSearchPath(root) catch {};
    }

    var resolver = Kira.Resolver.initWithLoader(allocator, &table, &loader);
    defer resolver.deinit();

    resolver.resolve(&program) catch {
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        for (resolver.getDiagnostics()) |diag| {
            renderResolverDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();

    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            renderTypeCheckDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.TypeCheckError;
    };

    // Lower to IR
    var lowerer = Kira.IRLowerer.init(allocator);
    defer lowerer.deinit();

    var ir_module = lowerer.lower(&program) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error[ir]: IR lowering failed: {}\n", .{err}) catch "error[ir]: IR lowering failed\n";
        stderr.writeAll(msg) catch {};
        return error.CompileError;
    };
    defer ir_module.deinit();

    // Generate C code
    var codegen_gen = Kira.codegen.CCodeGen.init(allocator);
    defer codegen_gen.deinit();

    codegen_gen.generateModule(&ir_module) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error[codegen]: Code generation failed: {}\n", .{err}) catch "error[codegen]: Code generation failed\n";
        stderr.writeAll(msg) catch {};
        return error.CompileError;
    };

    // Determine output path
    const c_output = codegen_gen.getOutput();

    // Write C file
    var c_path_buf: [512]u8 = undefined;
    const c_path = output_path orelse blk: {
        // Default: replace .ki with .c
        if (std.mem.endsWith(u8, path, ".ki")) {
            const base = path[0 .. path.len - 3];
            const c_name = std.fmt.bufPrint(&c_path_buf, "{s}.c", .{base}) catch {
                break :blk "output.c";
            };
            break :blk c_name;
        }
        break :blk "output.c";
    };

    const c_file = std.fs.cwd().createFile(c_path, .{}) catch {
        stderr.writeAll("error: could not create output file\n") catch {};
        return error.WriteError;
    };
    defer c_file.close();

    c_file.writeAll(c_output) catch {
        stderr.writeAll("error: could not write output file\n") catch {};
        return error.WriteError;
    };

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Generated: {s}\n", .{c_path}) catch "Generated output\n";
    try stdout.writeAll(msg);
}

/// Run tests in a Kira source file
fn testFile(allocator: Allocator, path: []const u8, user_args: []const []const u8, use_color: bool) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    const source = loadFileContent(allocator, stderr, path) orelse return error.ReadError;
    defer allocator.free(source);

    var parse_result = Kira.parseWithErrors(allocator, source);
    const renderer = Kira.diagnostic.DiagnosticRenderer.init(source, path, use_color);

    if (parse_result.hasErrors()) {
        defer parse_result.deinit();
        for (parse_result.errors) |err| {
            renderParseError(stderr, renderer, err) catch {};
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

    var resolver = Kira.Resolver.initWithLoader(allocator, &table, &loader);
    defer resolver.deinit();

    resolver.resolve(&program) catch {
        for (loader.getErrors()) |load_err| {
            try formatModuleError(stderr, load_err, source, path);
        }
        for (resolver.getDiagnostics()) |diag| {
            renderResolverDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.ResolveError;
    };

    // Type check
    var checker = Kira.TypeChecker.init(allocator, &table);
    defer checker.deinit();
    checker.check(&program) catch {
        for (checker.getDiagnostics()) |diag| {
            renderTypeCheckDiagnostic(stderr, renderer, diag) catch {};
        }
        return error.TypeCheckError;
    };

    // Create interpreter
    var interp = Kira.Interpreter.init(allocator, &table);
    defer interp.deinit();

    const arena_alloc = interp.arenaAlloc();
    try Kira.interpreter_mod.registerBuiltins(arena_alloc, &interp.global_env);
    try Kira.interpreter_mod.registerStdlib(arena_alloc, &interp.global_env);
    interp.registerBuiltinMethods();

    // Set environment arguments for std.env.args()
    if (user_args.len > 0) {
        const env_args = Kira.interpreter_mod.stdlib.env_mod.convertArgsToValues(arena_alloc, user_args) catch null;
        if (env_args) |args_values| {
            interp.setEnvArgs(args_values);
        }
    }

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

/// Start LSP server
fn runLsp(allocator: Allocator) !void {
    var stdin = std.fs.File.stdin();
    var stdout = std.fs.File.stdout();

    var server = Kira.lsp.Server.fromFiles(allocator, &stdin, &stdout);
    defer server.deinit();

    try server.run();
}

/// Interactive REPL
/// Format a Kira source file
fn fmtFile(allocator: Allocator, path: []const u8, check_only: bool) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    const source = loadFileContent(allocator, stderr, path) orelse return error.FileNotFound;
    defer allocator.free(source);

    const formatted = Kira.formatter.format(allocator, source) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error formatting '{s}': {}\n", .{ path, err }) catch "Format error\n";
        stderr.writeAll(msg) catch {};
        return error.FormatError;
    };
    defer allocator.free(formatted);

    if (check_only) {
        if (!std.mem.eql(u8, source, formatted)) {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Would reformat: {s}\n", .{path}) catch "Would reformat\n";
            stderr.writeAll(msg) catch {};
            return error.FormattingRequired;
        }
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Already formatted: {s}\n", .{path}) catch "Already formatted\n";
        stdout.writeAll(msg) catch {};
    } else {
        // Write formatted output back to file
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error writing '{s}': {}\n", .{ path, err }) catch "Write error\n";
            stderr.writeAll(msg) catch {};
            return error.WriteError;
        };
        defer file.close();
        file.writeAll(formatted) catch return error.WriteError;

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Formatted: {s}\n", .{path}) catch "Formatted\n";
        stdout.writeAll(msg) catch {};
    }
}

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
        saveHistory(allocator, history.items);
        for (history.items) |h| {
            allocator.free(h);
        }
        history.deinit(allocator);
    }

    // Load persistent history
    loadHistory(allocator, &history);

    // Buffer for multiline input
    var multiline_buf = std.ArrayListUnmanaged(u8){};
    defer multiline_buf.deinit(allocator);

    while (true) {
        // Show continuation prompt if building multiline input
        if (multiline_buf.items.len > 0) {
            try stdout.writeAll("  ... ");
        } else {
            try stdout.writeAll("kira> ");
        }

        // Read line
        const line = readLine(stdin, &line_buf) catch |err| {
            if (err == error.EndOfStream) {
                try stdout.writeAll("\nGoodbye!\n");
                return;
            }
            return err;
        };

        if (line.len == 0 and multiline_buf.items.len == 0) continue;

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // If building multiline input, append and check completeness
        if (multiline_buf.items.len > 0) {
            try multiline_buf.appendSlice(allocator, "\n");
            try multiline_buf.appendSlice(allocator, trimmed);

            if (!isIncomplete(multiline_buf.items)) {
                // Complete — process the accumulated input
                const full_input = try allocator.dupe(u8, multiline_buf.items);
                defer allocator.free(full_input);
                multiline_buf.clearRetainingCapacity();

                const history_entry = try allocator.dupe(u8, full_input);
                try history.append(allocator, history_entry);

                try processInput(allocator, full_input, show_tokens, &table, &global_env, stdout);
            }
            continue;
        }

        if (trimmed.len == 0) continue;

        // Tab completion: if input contains a tab character, show completions
        if (std.mem.indexOfScalar(u8, trimmed, '\t') != null) {
            const prefix = std.mem.trimRight(u8, trimmed, "\t ");
            try showCompletions(allocator, prefix, &table, stdout);
            continue;
        }

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

        // Check if input is incomplete (unmatched braces)
        if (isIncomplete(trimmed)) {
            try multiline_buf.appendSlice(allocator, trimmed);
            continue;
        }

        try processInput(allocator, trimmed, show_tokens, &table, &global_env, stdout);
    }
}

/// Check if input has unmatched braces/parens/brackets
fn isIncomplete(input: []const u8) bool {
    var brace_depth: i32 = 0;
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var in_string = false;
    var prev_char: u8 = 0;

    for (input) |c| {
        if (in_string) {
            if (c == '"' and prev_char != '\\') {
                in_string = false;
            }
            prev_char = c;
            continue;
        }

        switch (c) {
            '"' => in_string = true,
            '{' => brace_depth += 1,
            '}' => brace_depth -= 1,
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            else => {},
        }
        prev_char = c;
    }

    return brace_depth > 0 or paren_depth > 0 or bracket_depth > 0;
}

/// Process a complete REPL input (single or multiline)
fn processInput(
    allocator: Allocator,
    input: []const u8,
    show_tokens: bool,
    table: *Kira.SymbolTable,
    env: *Kira.Environment,
    writer: anytype,
) !void {
    // Show tokens if enabled
    if (show_tokens) {
        var tokens = Kira.tokenize(allocator, input) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Lexer error: {}\n", .{err}) catch "Lexer error\n";
            try writer.writeAll(msg);
            return;
        };
        defer tokens.deinit(allocator);

        try writer.writeAll("Tokens:\n");
        var print_buf: [512]u8 = undefined;
        for (tokens.items) |tok| {
            const tok_line = std.fmt.bufPrint(&print_buf, "  {s}: \"{s}\" at {d}:{d}\n", .{
                @tagName(tok.type),
                tok.lexeme,
                tok.span.start.line,
                tok.span.start.column,
            }) catch continue;
            try writer.writeAll(tok_line);
        }
    }

    // Evaluate the input
    evalLine(allocator, input, table, env, writer) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: {}\n", .{err}) catch "Error\n";
        try writer.writeAll(msg);
    };
}

/// Show tab completions for a prefix
fn showCompletions(
    allocator: Allocator,
    input: []const u8,
    table: *Kira.SymbolTable,
    writer: anytype,
) !void {
    // Extract the last word as the prefix to complete
    const prefix = blk: {
        var i = input.len;
        while (i > 0) {
            i -= 1;
            const c = input[i];
            if (c == ' ' or c == '(' or c == ',' or c == '.' or c == '{' or c == '[') {
                break :blk input[i + 1 ..];
            }
        }
        break :blk input;
    };

    if (prefix.len == 0) return;

    // Use the LSP features module for completions
    const items = Kira.lsp.features.getCompletions(allocator, table, prefix) catch return;
    defer allocator.free(items);

    if (items.len == 0) {
        try writer.writeAll("No completions found.\n");
        return;
    }

    for (items) |item| {
        try writer.writeAll("  ");
        try writer.writeAll(item.label);
        try writer.writeAll("\n");
    }
}

/// History file path
fn getHistoryPath(allocator: Allocator, buf: *[4096]u8) ?[]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    const path = std.fmt.bufPrint(buf, "{s}/.kira_history", .{home}) catch return null;
    return path;
}

/// Load history from ~/.kira_history
fn loadHistory(allocator: Allocator, history: *std.ArrayListUnmanaged([]const u8)) void {
    var path_buf: [4096]u8 = undefined;
    const path = getHistoryPath(allocator, &path_buf) orelse return;

    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return;
    defer allocator.free(content);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const entry = allocator.dupe(u8, line) catch continue;
        history.append(allocator, entry) catch {
            allocator.free(entry);
            continue;
        };
    }
}

/// Save history to ~/.kira_history
fn saveHistory(allocator: Allocator, history: []const []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const path = getHistoryPath(allocator, &path_buf) orelse return;

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();

    // Save last 1000 entries
    const start = if (history.len > 1000) history.len - 1000 else 0;
    for (history[start..]) |entry| {
        file.writeAll(entry) catch return;
        file.writeAll("\n") catch return;
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
        \\Features:
        \\  - Multiline input: unmatched braces continue on next line
        \\  - Tab completion: type a prefix and press Tab
        \\  - History: persisted to ~/.kira_history
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
    interp.registerBuiltinMethods();

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

    // Extract the expression's type from the AST
    // The program is: fn _type_check_() -> void { let _: auto = <EXPR> }
    // We find the let binding's initializer and type-check it again
    const expr = findExprInProgram(program) orelse {
        try writer.writeAll("Expression is well-typed\n");
        return;
    };

    // Create a fresh checker to evaluate the expression type
    var expr_checker = Kira.TypeChecker.init(allocator, table);
    defer expr_checker.deinit();

    // Enter the function scope so symbol lookup works
    _ = try table.enterScope(.function);
    defer table.leaveScope() catch {};

    const resolved_type = expr_checker.checkExpression(expr) catch {
        try writer.writeAll("Expression is well-typed\n");
        return;
    };

    const type_str = resolved_type.toString(allocator) catch {
        try writer.writeAll("Expression is well-typed\n");
        return;
    };
    defer allocator.free(type_str);

    try writer.writeAll(type_str);
    try writer.writeAll("\n");
}

/// Find the expression inside the type-check wrapper:
/// fn _type_check_() -> void { let _: auto = <EXPR> }
fn findExprInProgram(program: Kira.Program) ?*const Kira.Expression {
    if (program.declarations.len == 0) return null;
    const decl = &program.declarations[0];
    switch (decl.kind) {
        .function_decl => |fd| {
            const body = fd.body orelse return null;
            if (body.len == 0) return null;
            switch (body[0].kind) {
                .let_binding => |lb| return lb.initializer,
                else => return null,
            }
        },
        else => return null,
    }
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
    interp.registerBuiltinMethods();

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

/// Maximum depth for value formatting to prevent stack overflow on deeply nested structures.
/// Conservative limit (50) to avoid excessive stack usage (~200KB worst case).
const max_format_depth: usize = 50;

/// Stream a runtime value to a writer (avoids buffer overflow on large/deep structures)
fn formatValueWriter(val: Kira.Value, writer: anytype, depth: usize) !void {
    if (depth >= max_format_depth) {
        try writer.writeAll("...");
        return;
    }

    switch (val) {
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| try writer.print("\"{s}\"", .{s}),
        .char => |c| try writer.print("'{u}'", .{c}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .void => try writer.writeAll("()"),
        .none => try writer.writeAll("None"),
        .nil => try writer.writeAll("[]"),
        .some => |inner| {
            try writer.writeAll("Some(");
            try formatValueWriter(inner.*, writer, depth + 1);
            try writer.writeAll(")");
        },
        .ok => |inner| {
            try writer.writeAll("Ok(");
            try formatValueWriter(inner.*, writer, depth + 1);
            try writer.writeAll(")");
        },
        .err => |inner| {
            try writer.writeAll("Err(");
            try formatValueWriter(inner.*, writer, depth + 1);
            try writer.writeAll(")");
        },
        .tuple => |items| {
            if (items.len == 0) {
                try writer.writeAll("()");
            } else {
                try writer.writeAll("(");
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try formatValueWriter(item, writer, depth + 1);
                }
                try writer.writeAll(")");
            }
        },
        .array => |items| {
            if (items.len == 0) {
                try writer.writeAll("[]");
            } else {
                try writer.print("[{d} items]", .{items.len});
            }
        },
        .record => try writer.writeAll("<record>"),
        .function => |f| try writer.print("<fn {s}>", .{f.name orelse "anonymous"}),
        .variant => |v| {
            if (v.fields) |fields| {
                switch (fields) {
                    .tuple => |tuple_vals| {
                        if (tuple_vals.len == 1) {
                            try writer.print("{s}(", .{v.name});
                            try formatValueWriter(tuple_vals[0], writer, depth + 1);
                            try writer.writeAll(")");
                        } else {
                            try writer.print("{s}(...)", .{v.name});
                        }
                    },
                    .record => try writer.print("{s}{{...}}", .{v.name}),
                }
            } else {
                try writer.writeAll(v.name);
            }
        },
        .cons => try writer.writeAll("<list>"),
        .io => |inner| {
            try writer.writeAll("IO(");
            try formatValueWriter(inner.*, writer, depth + 1);
            try writer.writeAll(")");
        },
        .reference => |ref| {
            try writer.writeAll("ref ");
            try formatValueWriter(ref.*, writer, depth + 1);
        },
    }
}

/// Format a runtime value to a buffer (wrapper for backward compatibility)
fn formatValue(val: Kira.Value, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    formatValueWriter(val, stream.writer(), 0) catch {
        return "<value>";
    };
    return stream.getWritten();
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
        if (Kira.diagnostic.getSourceLine(source, span.start.line)) |line| {
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

/// Load file content, reporting errors to stderr. Returns null on failure.
fn loadFileContent(allocator: Allocator, stderr: std.fs.File, path: []const u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: Cannot open file '{s}'\n", .{path}) catch "Error opening file\n";
        stderr.writeAll(msg) catch {};
        return null;
    };
    defer file.close();

    return file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        stderr.writeAll("Error reading file\n") catch {};
        return null;
    };
}

/// Render a parse error using the diagnostic renderer
fn renderParseError(writer: anytype, renderer: Kira.diagnostic.DiagnosticRenderer, err: Kira.ParseErrorInfo) !void {
    // Build message with expected/found info
    var msg_buf: [1024]u8 = undefined;
    const message = if (err.expected) |expected|
        std.fmt.bufPrint(&msg_buf, "{s} (expected {s}, found {s})", .{
            err.message,
            expected,
            err.found orelse "unknown",
        }) catch err.message
    else
        err.message;

    try renderer.render(writer, .{
        .message = message,
        .span = .{
            .start = .{ .line = err.line, .column = err.column, .offset = 0 },
            .end = .{ .line = err.line, .column = err.column + 1, .offset = 0 },
        },
        .severity = .err,
    });
}

/// Render a type checker diagnostic using the diagnostic renderer
fn renderTypeCheckDiagnostic(writer: anytype, renderer: Kira.diagnostic.DiagnosticRenderer, diag: Kira.TypeCheckDiagnostic) !void {
    const severity: Kira.diagnostic.Severity = switch (diag.kind) {
        .err => .err,
        .warning => .warning,
        .hint => .hint,
    };

    // Convert related info
    var related_buf: [16]Kira.diagnostic.RelatedInfo = undefined;
    var related: ?[]const Kira.diagnostic.RelatedInfo = null;
    if (diag.related) |diag_related| {
        const count = @min(diag_related.len, related_buf.len);
        for (diag_related[0..count], 0..) |info, i| {
            related_buf[i] = .{ .message = info.message, .span = info.span };
        }
        related = related_buf[0..count];
    }

    try renderer.render(writer, .{
        .message = diag.message,
        .span = diag.span,
        .severity = severity,
        .related = related,
    });
}

/// Render a resolver diagnostic using the diagnostic renderer
fn renderResolverDiagnostic(writer: anytype, renderer: Kira.diagnostic.DiagnosticRenderer, diag: Kira.ResolverDiagnostic) !void {
    const severity: Kira.diagnostic.Severity = switch (diag.kind) {
        .err => .err,
        .warning => .warning,
        .hint => .hint,
    };

    var related_buf: [16]Kira.diagnostic.RelatedInfo = undefined;
    var related: ?[]const Kira.diagnostic.RelatedInfo = null;
    if (diag.related) |diag_related| {
        const count = @min(diag_related.len, related_buf.len);
        for (diag_related[0..count], 0..) |info, i| {
            related_buf[i] = .{ .message = info.message, .span = info.span };
        }
        related = related_buf[0..count];
    }

    try renderer.render(writer, .{
        .message = diag.message,
        .span = diag.span,
        .severity = severity,
        .related = related,
    });
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
        .no_color = false,
        .fmt_check = false,
        .output_path = null,
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

    const line1 = Kira.diagnostic.getSourceLine(source, 1);
    try std.testing.expect(line1 != null);
    try std.testing.expectEqualStrings("line one", line1.?);

    const line2 = Kira.diagnostic.getSourceLine(source, 2);
    try std.testing.expect(line2 != null);
    try std.testing.expectEqualStrings("line two", line2.?);

    const line3 = Kira.diagnostic.getSourceLine(source, 3);
    try std.testing.expect(line3 != null);
    try std.testing.expectEqualStrings("line three", line3.?);

    const line4 = Kira.diagnostic.getSourceLine(source, 4);
    try std.testing.expect(line4 == null);
}

test "runFile supports cross-file aliased imports end-to-end" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "a.ki",
        .data =
        \\module a
        \\
        \\pub type Thing = { x: u64 }
        \\
        \\pub fn mk(x: u64) -> Thing {
        \\    return Thing { x: x }
        \\}
        \\
        \\pub fn get(t: Thing) -> u64 {
        \\    return t.x
        \\}
        ,
    });

    try tmp.dir.writeFile(.{
        .sub_path = "main.ki",
        .data =
        \\module main
        \\import a.{ Thing as T, mk as make, get }
        \\
        \\effect fn main() -> void {
        \\    let t: T = make(7u64)
        \\    let x: u64 = get(t)
        \\    if x == 0u64 {
        \\        std.io.println("unreachable")
        \\    }
        \\}
        ,
    });

    const main_path = try tmp.dir.realpathAlloc(allocator, "main.ki");
    defer allocator.free(main_path);

    try runFile(allocator, main_path, true, &[_][]const u8{}, false);
}
