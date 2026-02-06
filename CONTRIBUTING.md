# Contributing to Kira

Thank you for your interest in contributing to Kira! This document provides guidelines and information for contributors.

## Table of Contents

- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Code Style](#code-style)
- [Making Changes](#making-changes)
- [Testing](#testing)
- [Pull Requests](#pull-requests)
- [Documentation](#documentation)
- [Community Guidelines](#community-guidelines)

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
└── build.zig               # Build configuration
```

### Coding Standards

This project uses CarbideZig for Zig development standards. See:
- `carbide/CARBIDE.md` - Overview of standards
- `carbide/STANDARDS.md` - Detailed coding guidelines

## Code Style

### Zig Code

Follow the conventions in `carbide/STANDARDS.md`:

- Use `snake_case` for functions and variables
- Use `PascalCase` for types
- Keep functions focused and single-purpose
- Document public APIs with doc comments
- Handle all error cases explicitly

### Kira Code (Examples/Tests)

- Use 4-space indentation
- One statement per line
- Explicit types on all bindings
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
2. **Update documentation** - If adding features, update relevant docs
3. **Add examples** - For new features, add usage examples
4. **Check for breaking changes** - Note any API changes

### PR Description Template

```markdown
## Summary
Brief description of what this PR does.

## Changes
- List of specific changes
- Another change

## Testing
How was this tested?

## Documentation
- [ ] Updated relevant documentation
- [ ] Added/updated examples
- [ ] Updated CHANGELOG (if applicable)

## Related Issues
Fixes #123
```

### Review Process

1. Submit PR against `main` branch
2. Automated tests will run
3. Maintainers will review code and provide feedback
4. Address feedback and update PR
5. PR will be merged once approved

## Documentation

### Types of Documentation

1. **Code comments** - Inline explanation of complex logic
2. **Doc comments** - API documentation for public functions
3. **Markdown docs** - Guides and references in `docs/`
4. **Examples** - Working code in `examples/`

### Updating Documentation

When making changes:

- Update `docs/reference.md` for language changes
- Update `docs/stdlib.md` for standard library changes
- Update `docs/tutorial.md` if beginner-facing
- Add examples for new features

### Documentation Style

- Use clear, concise language
- Include code examples
- Link to related documentation
- Keep formatting consistent with existing docs

## Community Guidelines

### Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help newcomers get started
- Keep discussions focused and on-topic

### Getting Help

- Open an issue for bugs or feature requests
- Check existing issues before opening new ones
- Provide reproduction steps for bugs
- Be patient - maintainers are volunteers

### Recognition

Contributors are recognized in:
- Git history (commits)
- PR acknowledgments
- Release notes (for significant contributions)

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
