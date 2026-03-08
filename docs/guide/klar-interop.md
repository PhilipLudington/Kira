# Calling Kira from Klar — Step-by-Step Guide

This guide walks through building a Kira library and calling it from a Klar
project. Kira and Klar interoperate via the C ABI, so the workflow is:

1. Write a Kira module
2. Build it as a library (`--lib`)
3. Import the generated Klar extern block in your Klar project
4. Link against the compiled object file

## Prerequisites

- `kira` compiler installed (`kira --version`)
- `klar` compiler installed (`klar --version`)
- A C compiler (`cc` or `gcc`)

## Step 1: Write a Kira Library Module

Create `mathlib.ki`:

```kira
module mathlib

pub fn add(a: i32, b: i32) -> i32 = a + b

pub fn scale(x: f64, factor: f64) -> f64 = x * factor

pub fn greet(name: string) -> string = "Hello, " ++ name
```

No `main` function is needed — library modules export their public functions.

## Step 2: Build with `--lib`

```bash
kira build --lib mathlib.ki
```

This produces four files:

| File | Purpose |
|------|---------|
| `mathlib.c` | C implementation with typed wrapper functions |
| `mathlib.h` | C header declaring the public API |
| `mathlib.kl` | Klar `extern` block ready for import |
| `mathlib.json` | JSON type manifest for tooling |

### Type Mapping

| Kira | C Header | Klar Extern |
|------|----------|-------------|
| `i32` | `int32_t` | `i32` |
| `i64` | `int64_t` | `i64` |
| `f64` | `double` | `f64` |
| `bool` | `bool` | `Bool` |
| `string` | `const char*` | `CStr` |
| `void` | `void` | `Void` |

User-defined ADTs are mapped to C tagged unions (sum types) or plain structs
(product types). See `docs/design/adt-interop.md` for the full layout.

## Step 3: Compile to Object File

```bash
cc -c mathlib.c -o mathlib.o
```

## Step 4: Import in Klar

Copy `mathlib.kl` into your Klar project (or include it directly). The
generated file looks like:

```klar
// Generated Klar extern block for Kira module

extern {
    fn add(a: i32, b: i32) -> i32
    fn scale(x: f64, factor: f64) -> f64
    fn greet(name: CStr) -> CStr
    fn kira_free(ptr: Ptr) -> Void
}

// String convenience wrappers
fn greet_str(name: string) -> string =
    String.from_cstr(greet(String.to_cstr(name)))
```

Use these in your Klar code:

```klar
import mathlib.{ add, scale, greet_str }

let sum = add(1, 2)         // 3
let val = scale(2.5, 3.0)   // 7.5
let msg = greet_str("World") // "Hello, World"
```

## Step 5: Build and Link

```bash
klar build myapp.kl -l mathlib.o
```

## String Ownership

- **Kira → Klar**: Strings returned by Kira are borrowed `const char*` pointers
  valid for the duration of the call. The `_str` wrapper functions convert them
  to Klar `string` values via `String.from_cstr()`.
- **Klar → Kira**: String arguments are passed as `CStr` (borrowed pointer).
  The `_str` wrappers convert from Klar `string` via `String.to_cstr()`.
- **Heap values**: If Kira returns a heap-allocated value, call `kira_free()`
  when done.

See `docs/design/interop-memory.md` for the full ownership model.

## Tooling: `--emit-header` and `--manifest`

For tooling and AI agent workflows, two lighter-weight flags are available:

```bash
# Generate only .h and .kl (no C codegen)
kira build --emit-header mathlib.ki

# Generate only .json manifest (no codegen)
kira build --manifest mathlib.ki
```

The JSON manifest (`mathlib.json`) is machine-readable:

```json
{
  "module": "mathlib",
  "functions": [
    {
      "name": "add",
      "params": [{"name": "a", "type": "i32"}, {"name": "b", "type": "i32"}],
      "return_type": "i32"
    }
  ],
  "types": []
}
```

## Project Configuration: `[exports]`

For projects using `kira.toml`, you can declare which modules are exported:

```toml
[package]
name = "myproject"
version = "1.0.0"

[exports]
modules = ["mathlib", "utils"]

[modules]
mathlib = "src/mathlib.ki"
utils = "src/utils.ki"
```

When `[exports]` is configured, only listed modules produce interop files
(`.h`, `.kl`, `.json`) during `--lib` or `--emit-header` builds. Modules not
in the list are compiled normally but skip interop file generation. If no
`[exports]` section is present, all modules produce interop files by default.
