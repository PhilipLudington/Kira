# ADT Interop Convention

## Overview

This document defines the C-compatible memory layout for Kira algebraic data
types (ADTs) crossing the FFI boundary to Klar. The goal: a Kira library
exporting functions that accept or return ADTs should produce C header structs
and Klar extern declarations that allow Klar to construct, destructure, and
pattern-match on those values.

Reference: [PLAN.md](../../PLAN.md) Phase 2, [DESIGN.md](../../DESIGN.md).

---

## Sum Types (Tagged Unions)

A Kira sum type like:

```kira
type Shape = Circle(f64) | Rectangle(f64, f64) | Point
```

maps to a C tagged union:

```c
/* Tag enum */
typedef enum {
    KIRA_Shape_Circle = 0,
    KIRA_Shape_Rectangle = 1,
    KIRA_Shape_Point = 2,
} kira_Shape_Tag;

/* Variant payloads */
typedef struct { double _0; } kira_Shape_Circle;
typedef struct { double _0; double _1; } kira_Shape_Rectangle;

/* Tagged union */
typedef struct {
    kira_Shape_Tag tag;
    union {
        kira_Shape_Circle Circle;
        kira_Shape_Rectangle Rectangle;
    } data;
} kira_Shape;
```

### Rules

1. **Tag type:** `int32_t` (via a `typedef enum`). Tags are 0-indexed by
   declaration order.
2. **Unit variants** (no payload, e.g. `Point`): no entry in the union.
3. **Tuple-field variants** (e.g. `Circle(f64)`): payload struct with fields
   named `_0`, `_1`, etc.
4. **Record-field variants** (e.g. `Named { x: f64 }`): payload struct with
   named fields.
5. **Tag constants** follow the pattern `KIRA_{TypeName}_{VariantName}`.
6. **Struct names** follow `kira_{TypeName}` for the outer tagged union and
   `kira_{TypeName}_{VariantName}` for payload structs.

### Field Types

Payload field types map through the existing `kiraToCType` table:

| Kira type | C type |
|-----------|--------|
| i32 | int32_t |
| i64 | int64_t |
| f64 | double |
| bool | bool |
| string | const char* |
| char | uint32_t |
| SomeADT | kira_SomeADT |

Named types (user-defined ADTs) are referenced by their `kira_` prefixed
struct name, enabling nested ADT composition.

---

## Product Types (Records)

A Kira product type like:

```kira
type Point = { x: f64, y: f64 }
```

maps to a plain C struct:

```c
typedef struct {
    double x;
    double y;
} kira_Point;
```

### Rules

1. Fields appear in declaration order.
2. Field types use the same type mapping as sum type payloads.
3. Struct name follows `kira_{TypeName}`.

---

## Klar Extern Block

The corresponding Klar extern declarations mirror the C layout:

```klar
// For sum type Shape
extern enum kira_Shape_Tag {
    Circle = 0
    Rectangle = 1
    Point = 2
}

extern struct kira_Shape_Circle {
    _0: f64
}

extern struct kira_Shape_Rectangle {
    _0: f64
    _1: f64
}

extern struct kira_Shape {
    tag: kira_Shape_Tag
    data: kira_Shape_Rectangle  // largest variant; access others via ptr_cast
}

// For product type Point
extern struct kira_Point {
    x: f64
    y: f64
}
```

---

## Recursive Types

Recursive types (e.g. `type List = Cons(i64, List) | Nil`) use pointer
indirection for the self-referential field:

```c
typedef struct kira_List kira_List;

typedef struct { int64_t _0; kira_List* _1; } kira_List_Cons;

struct kira_List {
    kira_List_Tag tag;
    union {
        kira_List_Cons Cons;
    } data;
};
```

### Detection

A type is recursive if any variant payload field references the type being
defined (direct self-reference). Indirect cycles (A -> B -> A) are deferred
to a future phase.

---

## Size Threshold

Types whose C representation exceeds 64 bytes should be passed by pointer
across the FFI boundary. This is a future optimization — Phase 2 passes
everything by value.

---

## Naming Conventions Summary

| Entity | C name | Klar name |
|--------|--------|-----------|
| Sum type struct | `kira_{Type}` | `kira_{Type}` |
| Tag enum | `kira_{Type}_Tag` | `kira_{Type}_Tag` |
| Tag constant | `KIRA_{Type}_{Variant}` | (enum value) |
| Variant payload | `kira_{Type}_{Variant}` | `kira_{Type}_{Variant}` |
| Product type | `kira_{Type}` | `kira_{Type}` |
