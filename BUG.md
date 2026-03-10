# Kira Bugs

## [x] Bug 1: Memory leak in config TOML parser during module loading

**Status:** Fixed

**Description:** When loading a project with a `kira.toml`, the GPA (general purpose allocator) reports a leaked memory address originating from `_config.toml.parse`. The leak occurs during module resolution when `ModuleLoader.loadModule` calls `ProjectConfig.loadPackage`.

**Steps to reproduce:**
1. Create a Kira project with a `kira.toml` and module imports
2. Run any `.ki` file that triggers module loading (e.g. `kira run tests/test_json.ki`)
3. Observe the GPA leak warning in stderr after execution completes

**Expected:** No memory leak warnings; all allocations freed on exit.

**Actual:**
```
error(gpa): memory address 0x10a6c0018 leaked:
???:?:?: in _mem.Allocator.dupe__anon_5679 (???)
???:?:?: in _config.toml.parse (???)
???:?:?: in _config.project.ProjectConfig.loadPackage (???)
???:?:?: in _modules.loader.ModuleLoader.loadModule (???)
???:?:?: in _symbols.resolver.Resolver.resolveImportDecl (???)
???:?:?: in _symbols.resolver.Resolver.resolveImports (???)
```

**Notes:** Reproduced consistently across multiple files in the `kira-json` project. The leak is in Kira's own config/module loader, not in user code.
