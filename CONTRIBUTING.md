# Contributing to Kira

Thank you for your interest in contributing to Kira! This document provides guidelines and information for contributors.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Making Changes](#making-changes)
- [Pull Request Process](#pull-request-process)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
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
git clone https://github.com/PhilipLudington/Kira
cd Kira
./build.sh
```

The executable will be at `zig-out/bin/Kira`.

### Running the REPL

```bash
./zig-out/bin/Kira
```

## Development Setup

### Project Structure

```
Kira/
├── src/                    # Compiler source code
│   ├── ast/               # Abstract Syntax Tree definitions
│   ├── lexer/             # Tokenizer
│   ├── parser/            # Parser
│   ├── typechecker/       # Type checking and inference
│   ├── interpreter/       # Runtime interpreter
│   ├── symbols/           # Symbol table and resolution
│   ├── modules/           # Module loader
│   ├── stdlib/            # Standard library implementations
│   └── main.zig           # Entry point
├── examples/              # Example Kira programs
├── docs/                  # Documentation
├── editors/               # Editor syntax highlighting
├── carbide/               # Zig development standards
├── build.zig              # Build configuration
└── DESIGN.md              # Language specification
```

### Building and Testing

Always use the wrapper scripts to preserve GitStat integration:

```bash
# Build the compiler
./build.sh

# Run all tests
./run-tests.sh
```

Do **not** run `zig build` or `zig build test` directly.

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

- `fix/type-checker-crash`
- `feature/pattern-guards`
- `docs/improve-tutorial`
- `editor/helix-support`

## Pull Request Process

### Before Submitting

1. **Run tests**: `./run-tests.sh`
2. **Test your changes**: Try your changes with example programs
3. **Update documentation**: If you changed behavior, update relevant docs
4. **Add tests**: If you added features or fixed bugs

### PR Guidelines

- **Clear title**: Describe what the PR does
- **Description**: Explain why and how
- **Small PRs**: Easier to review and merge
- **Link issues**: Reference related issues with `Fixes #123`

### Review Process

1. Submit your PR against `main`
2. Wait for review (usually within a few days)
3. Address feedback with additional commits
4. Once approved, a maintainer will merge

## Coding Standards

### Zig Code

Follow the standards in `carbide/STANDARDS.md`:

- Use descriptive variable names
- Add comments for complex logic
- Keep functions small and focused
- Handle all error cases explicitly
- Use `comptime` for compile-time computation

### Kira Code (Examples/Tests)

- Use 4-space indentation
- Always use explicit types
- Always use explicit `return`
- Prefer pure functions when possible
- Document with `///` comments

### Commit Messages

Use clear, descriptive commit messages:

```
Fix type checker crash on generic pattern match

The type checker was failing to instantiate generic type parameters
when matching against constructor patterns. Added proper type
substitution during pattern compilation.

Fixes #42
```

Format:
- First line: Brief summary (50 chars or less)
- Blank line
- Body: Detailed explanation if needed
- Reference issues if applicable

## Testing

### Running Tests

```bash
./run-tests.sh
```

### Adding Tests

1. **Unit tests**: Add to appropriate `*_test.zig` file in `src/`
2. **Integration tests**: Add `.ki` files to `examples/` with expected output
3. **Regression tests**: When fixing bugs, add a test case

### Test File Naming

- `test_feature_name.ki` — Feature tests
- `bug123_description.ki` — Regression tests

## Documentation

### Updating Docs

- **tutorial.md**: Step-by-step learning guide
- **reference.md**: Complete language reference
- **stdlib.md**: Standard library API
- **quickref.md**: Cheat sheet
- **DESIGN.md**: Language specification

### Documentation Style

- Use clear, simple language
- Include code examples
- Keep formatting consistent
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

## Recognition

Contributors are valued! Significant contributions will be recognized in release notes.

---

Thank you for contributing to Kira! 🎉
