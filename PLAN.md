# Kira — `std.net` TCP Networking Module Implementation Plan

## Overview

Add a `std.net` module to the Kira standard library providing TCP networking primitives. This is the blocking dependency for kira-http — the HTTP library's logic is complete (281 tests pass) but `kira run examples/hello_server.ki` fails at runtime with `field 'net' not found in record 'std'`.

Reference: kira-http DESIGN.md, kira-http PLAN.md (Phase 2)

Current status: Phase 1 complete. Phase 2 next.

## Phase 0: Minimal TCP Server Primitives

**Goal:** Implement the core TCP functions needed for kira-http's `server.ki` to accept connections
**Estimated Effort:** 3–5 days

### Deliverables
- `src/stdlib/net.zig` with `tcp_listen`, `accept`, `read`, `write`, `close`
- Module registered in `src/stdlib/root.zig`
- kira-http's hello_server example starts and serves requests

### Tasks
- [x] Create `src/stdlib/net.zig` following the `fs.zig` pattern (completed 2026-03-15)
- [x] Implement `createModule()` registering all functions as effect builtins (completed 2026-03-15)
- [x] Implement `tcp_listen(port: i32) -> Result[TcpListener, string]` — bind a `std.net.Server` on `0.0.0.0:port`, return a record `{ port: i32, _handle: opaque }` wrapped in `Ok`, or `Err(string)` on failure (completed 2026-03-15)
- [x] Implement `accept(listener) -> Result[TcpConnection, string]` — call `server.accept()`, return a record `{ id: i32, _handle: opaque }` wrapped in `Ok` (completed 2026-03-15)
- [x] Implement `read(conn) -> Result[string, string]` — read from the connection's stream into a buffer, return `Ok(string)` or `Err(string)` (completed 2026-03-15)
- [x] Implement `write(conn, data: string) -> Result[bool, string]` — write string bytes to the stream, return `Ok(true)` or `Err(string)` (completed 2026-03-15)
- [x] Implement `close(conn) -> Result[bool, string]` — close the stream, return `Ok(true)` or `Err(string)` (completed 2026-03-15)
- [x] Register module: add `pub const net = @import("net.zig")` import and `try std_fields.put(allocator, "net", try net.createModule(allocator))` in `root.zig` (completed 2026-03-15)
- [x] Add `_ = net;` to the root.zig test block (completed 2026-03-15)
- [x] Write Zig unit tests: module creation, arity/type mismatch errors, invalid port rejection (completed 2026-03-15)

### Implementation Notes

**Returning records to Kira:** `TcpListener` and `TcpConnection` are Kira record types. The Zig side must return `Value{ .record = ... }` with the fields kira-http expects. The Zig `std.net.Server` / `std.net.Stream` handles can be stored as integer handles in a module-level lookup table (since `Value` cannot hold arbitrary Zig pointers).

**Handle table pattern:**
```zig
var next_handle: i128 = 1;
var listeners: std.AutoHashMapUnmanaged(i128, std.net.Server) = .{};
var connections: std.AutoHashMapUnmanaged(i128, std.net.Stream) = .{};
```

Each `tcp_listen` inserts into `listeners` and returns a record with `{ port, _handle }`. Each `accept`/`read`/`write`/`close` looks up the handle. This avoids storing raw pointers in `Value`.

**Result return pattern** (from `fs.zig`):
```zig
// Ok
const result = ctx.allocator.create(Value) catch return error.OutOfMemory;
result.* = Value{ .record = ... };
return Value{ .ok = result };

// Err
const err_val = ctx.allocator.create(Value) catch return error.OutOfMemory;
err_val.* = Value{ .string = error_message };
return Value{ .err = err_val };
```

### Testing Strategy
1. `./run-build.sh` succeeds
2. `./run-tests.sh` passes (including new net.zig unit tests)
3. `kira run examples/hello_server.ki` in kira-http starts listening and `curl http://localhost:8080/` returns "Hello, World! Welcome to kira-http."

---

## Phase 1: Read Buffering and HTTP Framing

**Goal:** Handle real HTTP request/response framing over TCP
**Estimated Effort:** 2–3 days

### Deliverables
- `read` handles partial reads and returns complete HTTP requests
- Server handles multiple sequential requests

### Tasks
- [x] Implement buffered read that accumulates until `\r\n\r\n` (end of HTTP headers) is found, then reads Content-Length bytes for the body (completed 2026-03-15)
- [x] Handle connection timeouts — 30s SO_RCVTIMEO on socket (completed 2026-03-15)
- [x] Handle client disconnect gracefully — return `Err("connection_closed")` instead of crashing (completed 2026-03-15)
- [x] Test with `curl` — GET, POST with JSON body, 404, multiple sequential requests all pass (completed 2026-03-15)

### Testing Strategy
`curl -X POST -d '{"key":"value"}' -H 'Content-Type: application/json' http://localhost:8080/echo` returns the posted body.

### Phase 1 Readiness Gate
Before Phase 2, these must be true:
- [x] Phase 0 complete (basic TCP works) (completed 2026-03-15)
- [x] POST requests with bodies are handled correctly (completed 2026-03-15)
- [x] Connection errors don't crash the server (completed 2026-03-15)

---

## Phase 2: HTTP Client Request

**Goal:** Implement `std.net.http_request` for outbound HTTP requests (used by kira-http's `client.ki`)
**Estimated Effort:** 3–5 days

### Deliverables
- `http_request` function that makes outbound HTTP/1.1 requests
- kira-http's `simple_get.ki` example works

### Tasks
- [ ] Implement `http_request(request_record) -> Result[response_record, string]` — takes a record with `{ method, url, headers, body }`, makes an HTTP request, returns `{ status, headers, body }`
- [ ] Parse URL to extract host, port, path
- [ ] Open TCP connection to remote host using `std.net.tcpConnectToHost`
- [ ] Send HTTP/1.1 request line, headers, and body
- [ ] Read response: status line, headers, body (using Content-Length or chunked transfer)
- [ ] Handle TLS/HTTPS (Zig's `std.crypto.tls` or shell out to system — decide approach)
- [ ] Handle redirects (optional, can defer to kira-http layer)

### Testing Strategy
`kira run examples/simple_get.ki` in kira-http fetches from httpbin.org and prints the response.

---

## Phase 3: Resource Cleanup and Robustness

**Goal:** Prevent resource leaks and handle edge cases
**Estimated Effort:** 2–3 days

### Deliverables
- Listener/connection handles are cleaned up properly
- Server survives malformed requests and slow clients

### Tasks
- [ ] Implement `close_listener(listener) -> Result[bool, string]` to shut down the server socket
- [ ] Add cleanup on interpreter shutdown — close all open handles in the lookup tables
- [ ] Set read/write timeouts on connections to prevent blocking on slow clients
- [ ] Limit maximum request size to prevent memory exhaustion
- [ ] Test with concurrent connections (multiple curl requests in parallel)

### Testing Strategy
Start server, make 100 sequential requests with `ab` or a shell loop, verify no handle leaks and all responses are correct.

---

## Phase 4: String Interpolation (`${}` Syntax) ✅

**Status:** Complete (2026-03-14)

**Goal:** Add string interpolation to Kira using `"text ${expr}"` syntax, similar to Klar's `{expr}` interpolation
**Estimated Effort:** 3–4 days

### Deliverables
- `${expr}` interpolation inside string literals, with automatic `toString` conversion
- Escape `\$` for literal dollar signs
- Full pipeline support: parser → type checker → IR → interpreter → C codegen
- E2E tests verifying interpreter/compiler output parity

### Tasks
- [x] Parser: `containsInterpolation()` detection + `parseInterpolatedString()` splitting into literal/expression parts (completed 2026-03-14)
- [x] Parser: brace-depth matching for nested expressions inside `${}` (completed 2026-03-14)
- [x] Parser: `\$` escape for literal dollar signs (completed 2026-03-14)
- [x] AST: `Expression.InterpolatedString` variant with `[]InterpolatedPart` (union of `.literal` and `.expression`) (completed 2026-03-14)
- [x] Type checker: interpolated string expressions resolve to `string` type (completed 2026-03-14)
- [x] IR lowering: `lowerInterpolatedString()` — emit `const_string`, `to_string`, and `str_concat` instructions (completed 2026-03-14)
- [x] Interpreter: `evalInterpolatedString()` — evaluate parts, call `.toString()`, concatenate (completed 2026-03-14)
- [x] C codegen: type-aware `to_string` — pass-through for strings, `"true"`/`"false"` for bools, `snprintf` for integers (completed 2026-03-14)
- [x] E2E tests: simple vars, multiple expressions, escaped `\$`, adjacent interpolations, expression-only strings, booleans, mixed types (completed 2026-03-14)
- [ ] Language documentation: dedicated spec section on interpolation syntax and semantics
- [ ] Format specifiers (future): support `${x:03d}`-style formatting

### Syntax Reference

```kira
let name = "Alice"
let age = 30
let greeting = "Hello, ${name}! You are ${age} years old."
let escaped = "Price: \$${price}"      // literal $ followed by interpolation
let adjacent = "${first}${last}"        // no separator
let expr = "sum is ${a + b}"           // expressions allowed
let flag_str = "enabled: ${is_active}" // bools → "true"/"false"
```

### Testing Strategy
1. `./run-tests.sh` passes all 7 interpolation E2E tests
2. Interpreter and compiled output match for all test cases
3. Boolean stringification produces `"true"`/`"false"` (not `"1"`/`"0"`)

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Zig `std.net.Server` API differs across Zig versions | Medium | Medium | Pin to the Zig version in build.zig.zon; check API before starting |
| Handle table grows unbounded if connections aren't closed | Medium | High | Remove handles on close; add cleanup on interpreter exit |
| Blocking `accept`/`read` freezes the interpreter | High | High | Phase 0 is single-threaded blocking (acceptable for MVP); concurrent handling is future work |
| HTTPS requires TLS, which is complex in Zig | Medium | High | Phase 2 can start with HTTP-only; add TLS as a follow-up |
| `Value` record fields must exactly match what kira-http expects | Medium | Medium | Verify field names (`port`, `id`) against kira-http's `server.ki` type definitions |

## Timeline

Phase 0 → Phase 1 → Phase 2 → Phase 3.

Phase 0 is the MVP — once it lands, kira-http's hello_server runs. Phase 1 makes it robust for real HTTP. Phase 2 adds the client side. Phase 3 hardens for production-like use.
