# Kira Bugs

## [x] Bug 1: Doc comments before `import` cause parse error

**Status:** Fixed

**Description:** The parser treats `///` doc comments as requiring a "documentable" declaration to follow (e.g., `fn`, `type`, `let`). When a doc comment appears before an `import` statement, the parser emits "expected declaration" at the `import` keyword. This is the same class of bug that was previously fixed for `module` declarations in commit `cda3710`.

**Steps to reproduce:**

1. Create a file with a doc comment before an import:
```kira
module example

/// This is a module-level doc comment
import std.list.{ map, filter }

pub fn dummy() -> i32 { return 1 }
```
2. Run `kira check <file.ki>`

**Expected:** The file parses and type-checks successfully (or fails at module resolution if the import target isn't available).

**Actual:**
```
error: expected declaration
  --> file.ki:4:1
  |
 4| import std.list.{ map, filter }
  | ^

Error: error.ParseError
```

**Notes:**
- Without doc comments before `import`, parsing succeeds (fails at resolution only if module not found)
- Both `import foo.bar` and `import foo.bar.{ X, Y }` syntax work when no doc comment precedes them
- Brace spacing (`{X}` vs `{ X }`) does not matter
- `kira test` is unaffected because the test runner handles module loading differently
- Affects all source files in kira-http that have module-level doc comments followed by imports

**Workaround:** Use regular comments (`//`) instead of doc comments (`///`) between `module` and `import` declarations.

**Suggested fix:** In the parser, either:
1. Allow doc comments to be discarded when followed by `import` (consistent with the `module` fix in `cda3710`)
2. Treat `import` as a valid doc-comment target

**Affected version:** v0.11.1
