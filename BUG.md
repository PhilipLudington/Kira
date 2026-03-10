# Project Bugs

## [x] Bug 1: Compiler segfault on files with ~300+ function definitions

**Status:** Fixed

**Description:** The compiler crashes with a segfault in `resolveImportDecl` when a single file contains approximately 300 or more top-level function definitions.

**Steps to reproduce:**
1. Create a `.ki` file with ~300+ `let` function definitions (e.g., a large test file)
2. Run `kira check <file>`
3. Compiler segfaults

**Expected:** File compiles successfully.

**Actual:** Segfault in `resolveImportDecl`.

**Workaround:** Split large files so each has fewer than ~250 function definitions.

**Found in:** kira-json `tests/test_json.ki` (5500 lines, ~300 functions). Splitting into two files (~3300 and ~2400 lines) compiles fine.

---

## [x] Bug 2: Phantom "undefined type" error pointing at wrong line

**Status:** Fixed

**Description:** When a file imports a sum type (e.g., `Schema`) but not a record type referenced in its fields (e.g., `SchemaProperty`), the compiler reports "undefined type 'SchemaProperty'" but points at an unrelated line like `Option[i64]`. The error only appears when a function returning that record type is actually called.

**Steps to reproduce:**
1. Import `Schema` and `SchemaError` from a types module (but not `SchemaProperty`)
2. Import a function `schema_property` that returns `SchemaProperty` from another module
3. Call `schema_property(...)` in the file
4. Run `kira check`

**Expected:** Auto-import resolves `SchemaProperty` (as it does for sum type variant constructors), or the error points at the actual usage site.

**Actual:**
```
error: undefined type 'SchemaProperty'
  --> file.ki:125:61
    |
 125| let assert_none_i64: fn(Option[i64], string) -> void = ...
    |                                 ^^^^^^^^^^^^^^
```

**Workaround:** Explicitly import `SchemaProperty` alongside `Schema`.

**Note:** The identical import set works in a file that does not call `schema_property()`. Auto-importing works for sum type variant constructors but not for record types referenced by struct fields.

---

## [x] Bug 3: Memory leak in TOML config parser

**Status:** Fixed

**Description:** Every `kira check` and `kira run` invocation prints a memory leak warning from the TOML config parser, even on successful compilation.

**Steps to reproduce:**
1. Create any valid `.ki` file with a `kira.toml`
2. Run `kira check <file>`

**Expected:** Clean output on success.

**Actual:**
```
Check passed: file.ki
error(gpa): memory address 0x... leaked:
  ... in _config.toml.parse (???)
  ... in _config.project.ProjectConfig.loadPackage (???)
  ... in _modules.loader.ModuleLoader.loadModule (???)
  ... in _symbols.resolver.Resolver.resolveImportDecl (???)
```

**Workaround:** None needed — cosmetic only. Compilation and execution succeed.
