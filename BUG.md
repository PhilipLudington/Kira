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

## [ ] Bug 2: `let x: RecordType = match ... { ... }` causes runtime TypeMismatch

**Status:** Blocked (Kira v0.12.0 runtime bug)

**Description:** Using a `match` expression (not statement) to assign a record type value causes a runtime `error.TypeMismatch`. This only affects record types — `string`, `bool`, `i64` work fine as match expression results.

**Steps to reproduce:**
1. Create a file with a match expression assigning to a record type:
```kira
module tests.test_match_record
import logic.parser.lexer

pub effect fn main() -> IO[void] {
    let tokens: List[LocatedToken] = tokenize("foo.") |> unwrap
    let pos: Position = match tokens {
        Cons(t, _) => { t.position }
        Nil => { Position { line: 1_i64, column: 1_i64, offset: 0_i64 } }
    }
    std.io.println("line: " + std.string.from_int(pos.line))
}
```
2. Run it: `kira run tests/test_match_record.ki`
3. Observe `Runtime error: error.TypeMismatch`

**Expected:** `pos` is assigned the `Position` from the first token.

**Actual:** Runtime `error.TypeMismatch` at the match expression.

**Workaround:** Use `var` with a match statement instead:
```kira
var pos: Position = Position { line: 1_i64, column: 1_i64, offset: 0_i64 }
match tokens {
    Cons(t, _) => { pos = t.position }
    Nil => { }
}
```

---

## [x] Bug 3: `test_repl.ki` triggers REPL infinite loop instead of running tests

**Status:** Fixed

**Description:** `test_repl.ki` had no `main` function. When run, Kira picked the `pub effect fn main()` from the imported `logic.repl` module, launching the interactive REPL. With no stdin, the REPL looped infinitely printing `?- ` prompts, crashing the terminal.

**Fix:** Renamed `logic/repl.ki`'s `pub effect fn main()` to `effect fn repl_main()` and added a `pub effect fn main()` to `test_repl.ki` that calls `run_all_tests()`.
