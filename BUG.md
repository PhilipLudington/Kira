# kira-lpe Bugs

## [x] Bug 1: `load_file` crashes with TypeMismatch when calling `parse_program_string` through transitive import

**Status:** Fixed

**Description:** Calling `parse_program_string` from within `load_file` (in `logic/loader.ki`) caused a runtime `error.TypeMismatch`. The same call worked when made directly from a test file. The issue was triggered when modules with name collisions were loaded — all module declarations were dumped into a single global environment, so a function in one module could silently overwrite a same-named function from another module.

**Root cause:** The interpreter registered ALL module declarations into a single shared `global_env`, and module functions had `captured_env = global_env`. Module imports were never processed at runtime (only the main program's imports were processed). This meant:
1. Name collisions between modules caused silent overwrites
2. Module functions couldn't resolve symbols through their own import chain
3. Transitive imports were effectively broken when name collisions existed

**Fix:** Introduced per-module environments. Each loaded module now gets its own environment (child of `global_env`) where:
- Module declarations are registered (functions get `captured_env = module_env`)
- Module imports are processed (bringing imported symbols into the module's scope)
- Functions resolve symbols through their own module's import chain, not a shared global scope

Changes in `src/interpreter/interpreter.zig`:
- Made `processImport` public so it can process module imports from `main.zig`
- Added `module_env` parameter to `registerModuleExports` for correct `captured_env`

Changes in `src/main.zig` (runFile, testFile, benchFile):
- Two-pass module registration: Pass 1 creates per-module environments and registers declarations/exports. Pass 2 processes each module's imports.
- Backward compat: module bindings are still copied to `global_env` for unqualified access from the main program.

---

## [x] Bug 2: `let x: RecordType = match ... { ... }` causes runtime TypeMismatch

**Status:** Fixed

**Description:** Using `match` as an expression (to assign a value) was previously rejected by the parser as a workaround for runtime TypeMismatch errors. The real fix was to implement proper match expressions as a first-class expression type, alongside the existing match statement.

**Fix:** Added `match_expr` as a new expression kind throughout the compiler pipeline:
- **AST** (`expression.zig`): Added `MatchExpr` and `MatchExprArm` types using existing `MatchBody` union
- **Parser** (`parser.zig`): Replaced the error-on-match-in-expression with `parseMatchExpr()` which parses match arms with `MatchBody` (expression or block) bodies
- **Interpreter** (`interpreter.zig`): Added `evalMatchExpr` that pattern-matches the subject, evaluates the matching arm's body, and returns the value. Block bodies use the last expression_statement as the return value.
- **Type checker** (`checker.zig`): Added `checkMatchExpr` that validates pattern types, guards, and ensures all arms return the same type
- **Resolver** (`resolver.zig`): Added scope management for match expression arms
- **Formatter, pretty printer, IR lower**: Added `match_expr` handling

Match expressions now work for all types including records:
```kira
let pos: Position = match tokens {
    Cons(t, _) => { t.position }
    Nil => { Position { line: 1, column: 1, offset: 0 } }
}
```

---

## [x] Bug 3: `test_repl.ki` triggers REPL infinite loop instead of running tests

**Status:** Fixed

**Description:** `test_repl.ki` had no `main` function. When run, Kira picked the `pub effect fn main()` from the imported `logic.repl` module, launching the interactive REPL. With no stdin, the REPL looped infinitely printing `?- ` prompts, crashing the terminal.

**Fix:** Renamed `logic/repl.ki`'s `pub effect fn main()` to `effect fn repl_main()` and added a `pub effect fn main()` to `test_repl.ki` that calls `run_all_tests()`.
