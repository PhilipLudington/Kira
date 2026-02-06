# Kira Project Instructions

CarbideZig is used in this project for Zig development standards. See `carbide/CARBIDE.md` and `carbide/STANDARDS.md`.

## Running Tests

Always use the AirTower wrapper script to run tests:
```bash
./run-tests.sh
```
Do NOT run `zig build test` directly - use the wrapper script to preserve AirTower integration and result tracking.

## Building

Always use the AirTower wrapper script to build:
```bash
./run-build.sh
```
Do NOT run `zig build` directly - use the wrapper script to preserve AirTower integration.
