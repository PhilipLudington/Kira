# Interop Memory & String Convention

## Overview

This document defines ownership rules and marshaling conventions for values
crossing the Kira-Klar FFI boundary. The focus is on strings (the most common
non-numeric type passed across FFI) and heap-allocated ADT values.

Reference: [PLAN.md](../../PLAN.md) Phase 3, [adt-interop.md](adt-interop.md).

---

## Ownership Rules

### Rule 1: Kira to Klar strings are borrowed

When a Kira library function returns `string`, the C API returns
`const char*`. The pointer is **borrowed** — valid for the duration of the
calling scope but must not be freed by Klar.

- **String literals:** static lifetime (always valid).
- **Dynamically constructed strings:** valid until the next call into the
  same Kira function or until `kira_free()` is called on them.

Klar code that needs to keep a returned string beyond the call scope should
copy it to a Klar-managed `string`.

### Rule 2: Klar to Kira strings are borrowed

When Klar passes a `string` (as `CStr` / `const char*`) into a Kira
function, Kira **borrows** the pointer for the duration of the call. If the
Kira function needs to store the string beyond the call, it copies internally.

In the current implementation, Kira's C backend casts `const char*` to
`kira_int` (i64) via `intptr_t` and uses the pointer directly. String
literals passed from Klar have static lifetime, so no copy is needed for
the common case.

### Rule 3: Returned ADTs are caller-owned (by value)

ADTs returned by value across the FFI boundary are owned by the caller.
No deallocation is needed — they live on the caller's stack.

### Rule 4: Heap-allocated values require `kira_free()`

When a Kira function returns a pointer to heap-allocated memory (e.g., a
boxed ADT or a dynamically constructed string), the caller must free it
via `kira_free()`.

---

## C API Surface

### `kira_free`

```c
void kira_free(void* ptr);
```

Exported in every library build. Frees memory allocated by the Kira runtime.
Klar calls this to release heap values returned by Kira functions.

Implementation: wraps `free()` in the generated C code.

### String function signatures

A Kira function like:

```kira
fn greet(name: string) -> string
```

generates the C declaration:

```c
const char* greet(const char* name);
```

Internally, the generated C code contains:
1. The core function using `kira_int` representation: `kira_int kira_greet(kira_int name)`
2. A thin wrapper with proper C types that converts between representations

### Wrapper generation

In library mode, for each exported function whose signature includes
`string` parameters or return types, the codegen emits a C wrapper:

```c
/* Internal implementation */
kira_int kira_greet(kira_int name) { ... }

/* Exported C API wrapper */
const char* greet(const char* name) {
    return (const char*)(intptr_t)kira_greet((kira_int)(intptr_t)name);
}
```

For functions with only numeric/bool types, the wrapper simply forwards:

```c
kira_int kira_add(kira_int a, kira_int b) { ... }

int32_t add(int32_t a, int32_t b) {
    return (int32_t)kira_add((kira_int)a, (kira_int)b);
}
```

---

## Klar Extern Block

### String wrapper functions

The generated `.kl` file includes the raw extern declaration plus a
convenience wrapper that converts `CStr` to Klar `string`:

```klar
extern {
    fn greet(name: CStr) -> CStr
}

// Safe wrapper: converts CStr result to Klar string
fn greet_safe(name: string) -> string {
    greet(name.to_cstr()).to_string()
}
```

This is generated only for functions that accept or return `string` types.

### `kira_free` declaration

```klar
extern {
    fn kira_free(ptr: Ptr) -> Void
}
```

Declared in every generated `.kl` file for library builds.

---

## Float Marshaling

Kira represents floats as bit-punned `kira_int` (i64) values internally.
Library wrappers unpack them:

```c
double scale(double x) {
    kira_int arg;
    memcpy(&arg, &x, sizeof(double));
    kira_int result = kira_scale(arg);
    double ret;
    memcpy(&ret, &result, sizeof(double));
    return ret;
}
```

---

## Future Work

- **Arena allocator for returned strings:** Instead of individual `malloc`/`free`,
  batch-allocate returned strings in a per-call arena that Klar frees once.
- **Reference counting:** For strings shared across multiple FFI calls.
- **Indirect recursive ADTs:** Heap-allocated recursive fields with automatic
  `kira_free` integration.
