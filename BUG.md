# Project Bugs

## [x] Bug 1: Sum type variant names not registered by module loader

**Status:** Fixed (2026-03-09)

**Description:** When a sum type is defined in a module loaded via the cross-file module system, its variant constructor names are not registered in the module scope. This makes variants completely unusable from importing modules — both for construction and pattern matching.

Tuple-style variants (e.g., `Circle(f64)`) happen to work because the type checker resolves them via a different code path (variant constructor calls). Named-field variants (e.g., `NotFound { path: string, line: i32 }`) fail entirely.

**Root cause:** `src/modules/loader.zig:addTypeSymbol` (line ~753) calls `self.table.define(sym)` to register the type but does NOT register variant names in the module scope afterward. Compare with `src/symbols/resolver.zig` lines 358-393, which correctly registers each variant as an `import_alias` symbol after defining a sum type. The loader is missing this equivalent step.

**Affected code:**

`src/modules/loader.zig:addTypeSymbol` ends at line ~753 with:
```zig
_ = self.table.define(sym) catch {};
```

It should also iterate the sum type variants and register them, matching what the resolver does:
```zig
// resolver.zig lines 358-393 (this logic is missing from loader.zig)
switch (def_kind) {
    .sum_type => |st| {
        for (st.variants) |v| {
            const variant_alias = Symbol{
                .id = 0,
                .name = v.name,
                .kind = .{ .import_alias = .{
                    .source_path = &.{},
                    .resolved_id = defined_id,
                } },
                .span = v.span,
                .is_public = type_decl.is_public,
                .doc_comment = null,
            };
            _ = self.table.define(variant_alias) catch { ... };
        }
    },
    else => {},
}
```

**Steps to reproduce:**

1. Create a package with a sum type using named-field variants:

```
mylib/kira.toml:
  [package]
  name = "mylib"
  version = "0.1.0"
  [modules]
  types = "types.ki"

mylib/types.ki:
  module mylib.types
  pub type Error =
      | NotFound { path: string, line: i32 }
      | InvalidFormat { reason: string }
```

2. Import and use the variants from another file:

```
kira.toml:
  [package]
  name = "test"
  version = "0.1.0"
  [modules]
  mylib = "mylib"

main.ki:
  import mylib.types.{ Error }
  fn main() -> string {
      let e: Error = NotFound { path: "x", line: 1 }
      match e {
          NotFound { path: p, line: l } => { return p }
          InvalidFormat { reason: r } => { return r }
      }
  }
```

3. Run `kira check main.ki`

**Expected:** Check passes. Variant constructors are available after importing the parent sum type.

**Actual:** Two classes of errors:
- Construction: `Undefined identifier 'NotFound'`
- Pattern matching: `Unknown type 'NotFound'`

Explicit import also fails: `import mylib.types.{ Error, NotFound }` produces `'NotFound' not found in module`.

**Workaround:** Keep sum types and all code that constructs/matches their variants in the same file. Cross-module usage of named-field sum types is not currently possible.

**Impact:** Any modularized Kira project using named-field sum type variants across module boundaries is blocked. The kira-json library hit this after modularization (commit `cb3a592` in the kira-json repo).

**Discovered:** 2026-03-09

---

## [x] Bug 2: Several `std.string` functions missing from type checker

**Status:** Fixed (2026-03-09)

**Description:** The type checker has hardcoded signatures for some `std.string` functions but is missing others. Functions that exist at runtime but have no type checker entry cause `kira check` to fail with type errors, even though the code runs correctly.

**Missing functions** (exist in `src/stdlib/string.zig` but not in `src/typechecker/checker.zig`):

| Function | Runtime return type |
|----------|-------------------|
| `std.string.equals(a, b)` | `bool` |
| `std.string.byte_length(s)` | `i64` |
| `std.string.concat(a, b)` | `string` |
| `std.string.replace(s, old, new)` | `string` |
| `std.string.to_upper(s)` | `string` |
| `std.string.to_lower(s)` | `string` |
| `std.string.from_i32(n)` | `string` |
| `std.string.from_i64(n)` | `string` |
| `std.string.from_int(n)` | `string` |
| `std.string.from_f32(n)` | `string` |
| `std.string.from_f64(n)` | `string` |
| `std.string.from_float(n)` | `string` |
| `std.string.from_bool(b)` | `string` |
| `std.string.to_string(v)` | `string` |
| `std.string.is_valid_utf8(s)` | `bool` |

**Steps to reproduce:**
```kira
fn test() -> bool {
    return std.string.equals("a", "b")
}
```
Run `kira check` — fails with type error because the checker doesn't know the return type.

**Expected:** `kira check` passes; the function is recognized with its correct return type.

**Actual:** Type error (the specific error depends on context — e.g., "if condition must be a boolean expression" when used in an `if`).

**Workaround:** Use `==` for string equality instead of `std.string.equals`. For `byte_length`, use `std.string.length` (which IS typed, but counts codepoints not bytes). Other missing functions have no workaround for `kira check`.

**Discovered:** 2026-03-09

---

## [x] Bug 3: Built-in `to_int` missing from type checker

**Status:** Fixed (2026-03-09)

**Description:** The built-in `to_int` function is registered in the interpreter (`src/interpreter/builtins.zig:26`) but has no corresponding entry in the type checker. Code using `to_int()` fails `kira check` with `Undefined identifier 'to_int'` even though it runs correctly.

Same issue likely applies to other builtins: `to_float`, `abs`, `min`, `max`, `len`, `push`, `pop`, `head`, `tail`, `empty`, `reverse`.

**Workaround:** None for `kira check`. The code runs fine with `kira run`.

**Discovered:** 2026-03-09
