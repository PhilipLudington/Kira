# Project Bugs

## [x] Bug 1: registerModuleNamespace crashes when 8+ modules share a namespace root

**Status:** Fixed (2026-03-15)

**Description:** The interpreter panics with an index-out-of-bounds error in `registerModuleNamespace` when a project imports 8 or more modules that share the same root namespace (e.g., `logic.*`). The crash occurs inside `StringArrayHashMapUnmanaged.put` when the hashmap copied from an existing record's fields cannot properly grow via the arena allocator — `getOrPutAssumeCapacityAdapted` is called after an insufficient resize, causing it to probe past the end of the backing array.

**Location:** `src/interpreter/interpreter.zig:487` — `registerModuleNamespace`

**Stack trace:**
```
thread panic: index out of bounds: index 9, len 9
  in ArrayHashMapUnmanaged.getOrPutInternal
  in ArrayHashMapUnmanaged.getOrPutAssumeCapacityAdapted
  in ArrayHashMapUnmanaged.getOrPutContextAdapted
  in ArrayHashMapUnmanaged.getOrPutContext
  in ArrayHashMapUnmanaged.putContext
  in ArrayHashMapUnmanaged.put
  in Interpreter.registerModuleNamespace
  in main.runFile
```

**Root cause analysis:** In the rebuild loop (lines 664–693), when `j == 0` (root level), `outer_fields` is set to a copy of the existing root record's `fields` hashmap. This is a struct copy — both the copy and the original share the same underlying `entries`/`metadata` arrays. When `put` is called on the copy with `self.arenaAlloc()`, the resize/realloc may fail or produce incorrect results because:

1. The arena allocator instance returned by `arenaAlloc()` may differ from the one that originally allocated the hashmap's backing storage, causing `realloc` to fail or no-op.
2. `getOrPutContextAdapted` calls `growIfNeeded` which may succeed according to its return value, but the actual capacity is not increased, so the subsequent `getOrPutAssumeCapacityAdapted` panics when probing overflows.

There is also a secondary logic bug in the same rebuild loop: for multi-segment paths (e.g., `logic.builtins.control`), the intermediate segments (j > 0) always create a fresh empty hashmap (line 683), which means registering `logic.builtins.arithmetic` after `logic.builtins.control` will overwrite the `builtins` record, losing the `control` entry.

**Steps to reproduce:**
1. Create a Kira project with 8+ modules under the same namespace root
2. Have a file that transitively imports all of them
3. Run the file with `kira run`

Minimal example — any file that does:
```kira
import logic.term
import logic.substitution
import logic.unify
import logic.clause
import logic.program
import logic.resolve
import logic.printer
import logic.loader        // 8th module under "logic" — triggers crash
```

**Expected:** All modules load and their exports are accessible via qualified names.

**Actual:** Interpreter panics with `index out of bounds: index N, len N` where N equals the number of modules registered under the root namespace.

**Impact:** Any non-trivial project with a shared module namespace (the standard pattern) cannot run. In the kira-lpe project, 11 of 19 test files crash, and the REPL cannot start.

**Kira version:** v0.12.0
