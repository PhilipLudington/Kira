# Known Bugs and Compiler Limitations

## Design Notes

### `use` and `pub use` Not Supported

Kira uses `import` for bringing items into scope. The `use` and `pub use` statements are not supported and will not be implemented.

**Correct syntax:**
```kira
import http.types.{Method, Status, Header}
import http.response.{Response, ok, not_found}
```

For libraries, users must import directly from submodules rather than a single entry point.
