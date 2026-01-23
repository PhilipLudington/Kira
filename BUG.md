# kira-http Bug Tracker

Known bugs, limitations, and missing features.

## Fixed Bugs

### CORS Preflight Not Handled (Fixed)
- **File:** `src/middleware.ki`
- **Issue:** CORS middleware documented "handles preflight OPTIONS requests automatically" but always passed requests through to handlers
- **Fix:** Added OPTIONS method detection, returns 204 No Content with CORS headers without calling underlying handler

### Empty Origins List Sets Invalid Header (Fixed)
- **File:** `src/middleware.ki`
- **Issue:** `cors(Nil)` would set `Access-Control-Allow-Origin: ""` (empty string)
- **Fix:** Empty origins list now skips adding CORS headers entirely

### URL-Encoded Query Parameters Not Decoded (Fixed)
- **File:** `src/url.ki`
- **Issue:** Query string parsing returned raw encoded values (e.g., `hello%20world` instead of `hello world`)
- **Fix:** Added `url_decode()` function, applied to query keys and values during parsing

### URL-Encoded Path Parameters Not Decoded (Fixed)
- **Files:** `src/url.ki`, `src/router.ki`
- **Issue:** Path parameters like `/users/hello%20world` returned encoded value
- **Fix:** Path parameter extraction now decodes values using `url_decode()`

### Multi-Line Imports Not Parsed (Fixed)
- **File:** `src/parser/parser.zig`
- **Issue:** Import statements with items on multiple lines failed to parse
- **Fix:** Added `skipNewlines()` calls in `parseImportDecl()` after `{`, after `,`, and before `}`

## Known Limitations

### IPv6 Address Support
- **Status:** Not Supported
- **Issue:** URLs with IPv6 addresses like `http://[::1]:8080/path` will fail to parse
- **Reason:** The URL parser looks for `:` to find the port, which conflicts with IPv6 colons inside brackets
- **Workaround:** Use IPv4 addresses or hostnames

### No URL Encoding Function
- **Status:** Missing Feature
- **Issue:** Only `url_decode()` is provided, no `url_encode()` for building URLs with special characters
- **Workaround:** Manually encode special characters when constructing URLs

### Static Routes Don't Take Priority Over Parameter Routes
- **Status:** By Design (Order-Dependent)
- **Issue:** Route matching uses first-match semantics based on registration order
- **Example:** If `/users/:id` is registered before `/users/me`, then `/users/me` matches the parameter route
- **Workaround:** Register more specific static routes before parameter routes

### No Wildcard/Catch-All Routes
- **Status:** Not Implemented
- **Issue:** Cannot define routes like `/files/*path` to match arbitrary depth
- **Workaround:** Use specific parameter patterns or handle in not-found handler

### No Query String in Route Matching
- **Status:** By Design
- **Issue:** Routes match on path only, query strings are not part of route patterns
- **Note:** This follows standard HTTP routing conventions

### CORS Middleware Doesn't Check Origin Header
- **Status:** Limitation
- **Issue:** CORS middleware adds configured origins to response without checking the request's `Origin` header
- **Impact:** All configured origins are sent regardless of request origin
- **Workaround:** Implement custom middleware for strict origin checking

### Timeout Middleware Is Informational Only
- **Status:** Limitation
- **Issue:** `timeout()` middleware only sets `X-Timeout-Ms` header; actual timeout enforcement requires server implementation
- **Note:** Documented in code comments

## Design Decisions

### No Re-Export Syntax (`pub use`)
- **Status:** By Design
- **Rationale:** Kira favors explicit imports that reveal where symbols originate
- **Impact:** Consumers import directly from source modules, not facade modules
- **Benefit:** Clear dependency graphs, simpler tooling, unambiguous "go to definition"

## Feature Requests

### Request Body Parsing
- Automatic JSON body parsing with type validation
- Form data parsing (`application/x-www-form-urlencoded`)
- Multipart form data support

### Response Compression
- Gzip/deflate compression middleware
- Content-Encoding header handling

### Cookie Support
- Cookie parsing from request headers
- Set-Cookie response helper
- Cookie middleware for sessions

### WebSocket Support
- WebSocket upgrade handling
- WebSocket frame parsing/serialization

### TLS/HTTPS
- HTTPS server support
- Certificate configuration

### Connection Pooling (Client)
- Reuse connections for multiple requests
- Connection keep-alive

### Streaming Bodies
- Chunked transfer encoding
- Large file uploads/downloads without buffering

## Test Coverage Gaps

### Integration Tests
- End-to-end client-server tests
- Real network request tests (requires effectful test runner)

### Property-Based Tests
- URL parse/build round-trip properties
- Header manipulation invariants

### Error Path Coverage
- Network timeout simulation
- Connection failure handling
- Malformed HTTP response handling
