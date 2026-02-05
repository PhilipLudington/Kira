# Contributing to Kira

Thank you for your interest in contributing to Kira! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- **Zig 0.14+** - The compiler is written in Zig
- **Git** - For version control

### Building from Source

```bash
git clone https://github.com/PhilipLudington/Kira.git
cd Kira
zig build
```

The executable will be at `zig-out/bin/Kira`.

### Running Tests

```bash
./run-tests.sh
```

## How to Contribute

### Reporting Bugs

Before submitting a bug report:

1. Check existing issues to avoid duplicates
2. Use the latest version from `main`
3. Create a minimal reproduction case

When reporting:

- Describe the expected vs actual behavior
- Include the Kira code that triggers the bug
- Provide compiler output/error messages
- List your environment (OS, Zig version)

See [BUG.md](BUG.md) for examples of well-documented bugs and their fixes.

### Suggesting Features

Feature suggestions are welcome! Please:

1. Check [DESIGN.md](DESIGN.md) to see if it aligns with the language design
2. Explain the use case and motivation
3. Consider how it fits Kira's philosophy of explicit types and effects

### Code Contributions

1. **Fork** the repository
2. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes** following the code style below
4. **Test** your changes thoroughly
5. **Submit a pull request** against `main`

### Pull Request Guidelines

- **Never push directly to main** - always use pull requests
- Keep PRs focused on a single change
- Include tests for new functionality
- Update documentation as needed
- Describe your changes in the PR description

## Code Style

### Zig Code

- Follow Zig's official style guide
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions focused and reasonably sized

### Kira Code (examples, tests)

- Follow the patterns in existing examples
- Include explicit type annotations (Kira requires them)
- Mark effect functions with the `effect` keyword
- Add comments explaining what the example demonstrates

### Documentation

- Use Markdown for documentation
- Keep examples simple and focused
- Update the table of contents when adding sections

## Project Structure

```
Kira/
├── src/           # Compiler source code (Zig)
├── examples/      # Example programs
├── docs/          # Documentation
├── editors/       # Editor support (syntax highlighting)
└── carbide/       # Carbide integration
```

## Development Workflow

### Understanding the Codebase

1. Read [DESIGN.md](DESIGN.md) for language philosophy
2. Explore `src/` starting with `main.zig`
3. Read the [docs/tutorial.md](docs/tutorial.md) to understand the language

### Key Concepts

- **Explicit types**: Every variable and parameter must have a type annotation
- **Explicit effects**: Side effects are tracked with the `effect` keyword
- **Pattern matching**: Comprehensive support for algebraic data types
- **Functional style**: Pure functions by default

### Key Source Files

| Directory | Purpose |
|-----------|---------|
| `src/main.zig` | Entry point, CLI handling |
| `src/ast/` | Abstract syntax tree |
| `src/parser/` | Syntax parsing |
| `src/typechecker/` | Type checking |
| `src/symbols/` | Symbol resolution |
| `src/interpreter/` | Tree-walking interpreter |
| `src/modules/` | Module system |

## Documentation Contributions

Documentation improvements are always welcome:

- Fix typos and clarify confusing sections
- Add examples for underdocumented features
- Improve the tutorial and reference docs
- Add docstrings to standard library functions

## Ecosystem

Kira has a growing ecosystem of libraries. Consider contributing to these as well:

- [kira-http](https://github.com/PhilipLudington/kira-http) - HTTP library
- [kira-json](https://github.com/PhilipLudington/kira-json) - JSON library
- [kira-test](https://github.com/PhilipLudington/kira-test) - Testing framework
- [kira-lpe](https://github.com/PhilipLudington/kira-lpe) - Logic programming engine
- [kira-pcl](https://github.com/PhilipLudington/kira-pcl) - Parser combinators

## Questions?

If you have questions about contributing:

1. Check the existing documentation
2. Look at similar PRs for guidance
3. Open an issue for discussion

## Code of Conduct

Be respectful, constructive, and professional. We're all here to build something useful together.

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (see [LICENSE](LICENSE)).
