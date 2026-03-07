# Doc Generation Example

Demonstrates `kira doc` on a multi-module project.

## Project Structure

```
doc_gen/
  kira.toml          # Declares package "mathlib" with two modules
  math.ki            # Constants and arithmetic helpers
  collections.ki     # List utilities and a key-value pair type
```

## Usage

Generate docs into the default `docs/api/` directory:

```bash
kira doc examples/doc_gen
```

Or specify a custom output directory:

```bash
kira doc examples/doc_gen -o /tmp/mathlib-docs
```

Generate docs for a single file (no kira.toml needed):

```bash
kira doc examples/doc_gen/math.ki
```

## Output

Project-level generation produces:

| File | Contents |
|------|----------|
| `index.md` | Top-level index linking to each module page |
| `mathlib_math.md` | API reference for the math module |
| `mathlib_collections.md` | API reference for the collections module |
| `search-index.json` | Machine-readable symbol index |

## Doc Comment Syntax

```kira
//! Module-level documentation (at top of file).

/// Declaration-level doc comment.
pub fn example() -> i64 { return 0 }
```

Only `pub` declarations appear in the generated output.
Private helpers (without `pub`) are excluded.
