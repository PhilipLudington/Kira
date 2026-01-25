# RESOLVED: Directory Listing in std.fs

**Status:** ✅ Already implemented as `read_dir`

## Summary

The feature requested as `list_dir` already exists as `std.fs.read_dir`.

## Available Functions

The following functions are implemented in `std.fs`:

```kira
// File operations
pub effect fn read_file(path: string) -> IO[Result[string, string]]
pub effect fn write_file(path: string, content: string) -> IO[Result[void, string]]
pub effect fn append_file(path: string, content: string) -> IO[Result[void, string]]
pub effect fn exists(path: string) -> IO[bool]
pub effect fn remove(path: string) -> IO[Result[void, string]]

// Directory operations
pub effect fn read_dir(path: string) -> IO[Result[List[string], string]]
pub effect fn is_file(path: string) -> IO[bool]
pub effect fn is_dir(path: string) -> IO[bool]
pub effect fn create_dir(path: string) -> IO[Result[void, string]]
```

## Usage Example

```kira
effect fn run_json_test_suite(dir: string) -> IO[void] {
    match std.fs.read_dir(dir) {
        Ok(files) => {
            let json_files: List[string] = std.list.filter[string](
                files,
                fn(f: string) -> bool { return std.string.ends_with(f, ".json") }
            )
            // Process each file...
        }
        Err(e) => {
            std.io.eprintln("Failed to list directory: " + e)
        }
    }
    return
}
```

## Resolution

- Implementation exists in `src/stdlib/fs.zig`
- Documentation added to `docs/stdlib.md`
