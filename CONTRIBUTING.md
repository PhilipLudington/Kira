# Contributing to Kira

Thank you for your interest in contributing to Kira! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Style](#code-style)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Pull Requests](#pull-requests)
- [Documentation](#documentation)
- [Getting Help](#getting-help)

## Code of Conduct

Be respectful, inclusive, and constructive. We're all here to build something great together.

## Getting Started

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.14.0 or later
- Git
- A text editor with Kira syntax support (see `editors/`)

### Building from Source

```bash
git clone https://github.com/PhilipLudington/Kira.git
cd Kira
./run-build.sh
```

The executable will be at `zig-out/bin/Kira`.

### Running the REPL

```bash
./zig-out/bin/Kira
```

### Running Tests

Always use the wrapper script to run tests:

```bash
./run-tests.sh
```

> **Important:** Do not run `zig build test` directly. The wrapper script ensures proper AirTower integration and result tracking.

## Development Setup

### Project Structure

```
Kira/
├── src/                    # Compiler source code
│   ├── ast/               # Abstract Syntax Tree definitions
│   ├── lexer/             # Tokenizer
│   ├── parser/            # Parser
│   ├── typechecker/       # Type checking and inference
│   ├── interpreter/       # Tree-walking interpreter
│   ├── symbols/           # Symbol resolution
│   ├── modules/           # Module loading
│   ├── stdlib/            # Standard library implementations
│   └── main.zig           # Entry point
├── docs/                   # Documentation
├── examples/               # Example programs
├── editors/                # Editor syntax support
├── carbide/                # Zig development standards
├── build.zig               # Build configuration
└── DESIGN.md               # Language specification
```

### Coding Standards

This project uses CarbideZig for Zig development standards. See:
- `carbide/CARBIDE.md` - Overview of standards
- `carbide/STANDARDS.md` - Detailed coding guidelines

### Running Examples

```bash
# Run an example
./zig-out/bin/Kira run examples/hello.ki

# Type check without running
./zig-out/bin/Kira check examples/factorial.ki

# Show tokens (debugging)
./zig-out/bin/Kira --tokens examples/hello.ki

# Show AST (debugging)
./zig-out/bin/Kira --ast examples/hello.ki
```

## Code Style

### Zig Code

Follow the conventions in `carbide/STANDARDS.md`:

- Use `snake_case` for functions and variables
- Use `PascalCase` for types
- Keep functions focused and single-purpose
- Document public APIs with doc comments
- Handle all error cases explicitly
- Use `comptime` for compile-time computation

### Kira Code (Examples/Tests)

- Use 4-space indentation
- One statement per line
- Explicit types on all bindings
- Always use explicit `return`
- Prefer pure functions when possible
- Meaningful variable and function names
- Comments for non-obvious logic

Example:

```kira
// GOOD: Clear, well-documented
fn calculate_distance(p1: Point, p2: Point) -> f64 {
    let dx: f64 = p2.x - p1.x
    let dy: f64 = p2.y - p1.y
    return std.math.sqrt(dx * dx + dy * dy)
}

// AVOID: Unclear names, no documentation
fn f(a: Point, b: Point) -> f64 {
    return std.math.sqrt((b.x-a.x)*(b.x-a.x)+(b.y-a.y)*(b.y-a.y))
}
```

## Making Changes

### Types of Contributions

We welcome:

- **Bug fixes** — Fix issues in the compiler or runtime
- **Features** — New language features or stdlib additions
- **Documentation** — Improve docs, add examples, fix typos
- **Editor support** — Syntax highlighting for new editors
- **Tests** — Increase test coverage
- **Examples** — Add example programs demonstrating features

### Before You Start

1. **Check existing issues** — Your idea may already be discussed
2. **Open an issue first** — For significant changes, discuss before coding
3. **One change per PR** — Keep pull requests focused

### Branch Naming

Use descriptive branch names:

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation changes
- `refactor/description` - Code refactoring
- `test/description` - Test additions/improvements

### Commit Messages

Write clear, descriptive commit messages:

```
<type>: <short summary>

<longer description if needed>

<reference to issue if applicable>
```

Types:
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation
- `refactor` - Code refactoring
- `test` - Test changes
- `chore` - Maintenance tasks

Example:

```
feat: Add std.string.pad_left and pad_right functions

Implements string padding functions that pad a string to a
minimum length with a specified character.

Closes #42
```

## Testing

### Running Tests

```bash
# Run all tests
./run-tests.sh

# Run a specific example
./zig-out/bin/Kira run examples/hello.ki
```

### Writing Tests

1. **Unit tests** - Add test blocks to the relevant source file, or to dedicated test files like `src/interpreter/tests.zig`
2. **Integration tests** - Add example programs to `examples/`
3. **Regression tests** - Reference the bug being fixed

For bug fixes, add a test case that reproduces the bug:

```zig
test "regression: issue #42 - string padding with empty string" {
    const result = try padLeft("", 5, ' ');
    try std.testing.expectEqualStrings("     ", result);
}
```

## Pull Requests

### Before Submitting

1. **Ensure tests pass** - Run `./run-tests.sh`
2. **Test your changes** - Try your changes with example programs
3. **Update documentation** - If adding features, update relevant docs
4. **Add examples** - For new features, add usage examples
5. **Check for breaking changes** - Note any API changes

### PR Guidelines

- **Clear title**: Describe what the PR does
- **Description**: Explain why and how
- **Small PRs**: Easier to review and merge
- **Link issues**: Reference related issues with `Fixes #123`

### Review Process

1. Submit PR against `main` branch
2. Wait for review (usually within a few days)
3. Address feedback with additional commits
4. Once approved, a maintainer will merge

## Documentation

### Updating Docs

When making changes:

- **tutorial.md**: Step-by-step learning guide
- **reference.md**: Complete language reference
- **stdlib.md**: Standard library API
- **quickref.md**: Cheat sheet
- **DESIGN.md**: Language specification

### Documentation Style

- Use clear, concise language
- Include code examples
- Link to related documentation
- Keep formatting consistent with existing docs
- Test all code examples

## Getting Help

### Resources

- **Documentation**: `docs/` directory and `DESIGN.md`
- **Examples**: `examples/` directory
- **Issues**: [GitHub Issues](https://github.com/PhilipLudington/Kira/issues)

### Questions

If you're stuck:

1. Check the documentation
2. Look at similar code in the codebase
3. Open an issue with the `question` label

## Quick Reference

| Task | Command |
|------|---------|
| Build | `./run-build.sh` |
| Test | `./run-tests.sh` |
| Run example | `./zig-out/bin/Kira run examples/hello.ki` |
| Check types | `./zig-out/bin/Kira check examples/hello.ki` |
| Start REPL | `./zig-out/bin/Kira` |

---

Thank you for contributing to Kira! Your efforts help make the language better for everyone.
