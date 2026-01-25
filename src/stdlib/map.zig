//! std.map - Hash map operations for the Kira standard library.
//!
//! Provides O(1) key-value storage operations:
//!   - new: Create a new empty map
//!   - put: Insert or update a key-value pair (returns new map)
//!   - get: Get value by key (returns Option)
//!   - contains: Check if key exists
//!   - remove: Remove a key (returns new map)
//!   - keys: Get list of all keys
//!   - values: Get list of all values
//!   - entries: Get list of (key, value) tuples
//!   - size: Get number of entries
//!   - is_empty: Check if map is empty

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../interpreter/value.zig");
const root = @import("root.zig");

const Value = value_mod.Value;
const InterpreterError = value_mod.InterpreterError;
const BuiltinContext = root.BuiltinContext;

/// Create the std.map module as a record value
pub fn createModule(allocator: Allocator) !Value {
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    errdefer fields.deinit(allocator);

    try fields.put(allocator, "new", root.makeBuiltin("new", &mapNew));
    try fields.put(allocator, "put", root.makeBuiltin("put", &mapPut));
    try fields.put(allocator, "get", root.makeBuiltin("get", &mapGet));
    try fields.put(allocator, "contains", root.makeBuiltin("contains", &mapContains));
    try fields.put(allocator, "remove", root.makeBuiltin("remove", &mapRemove));
    try fields.put(allocator, "keys", root.makeBuiltin("keys", &mapKeys));
    try fields.put(allocator, "values", root.makeBuiltin("values", &mapValues));
    try fields.put(allocator, "entries", root.makeBuiltin("entries", &mapEntries));
    try fields.put(allocator, "size", root.makeBuiltin("size", &mapSize));
    try fields.put(allocator, "is_empty", root.makeBuiltin("is_empty", &mapIsEmpty));

    return Value{
        .record = .{
            .type_name = "std.map",
            .fields = fields,
        },
    };
}

/// Map is represented as a record with:
///   - _data: A record containing the actual key-value pairs (string keys only)
///   - _type: "HashMap" marker
const map_type_name = "HashMap";

/// Create a new empty map: new() -> HashMap
fn mapNew(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 0) return error.ArityMismatch;

    // Create empty data record
    const data_fields = std.StringArrayHashMapUnmanaged(Value){};

    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_data", Value{
        .record = .{
            .type_name = null,
            .fields = data_fields,
        },
    }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = map_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = map_type_name,
            .fields = fields,
        },
    };
}

/// Check if a value is a HashMap
fn isMap(val: Value) bool {
    return switch (val) {
        .record => |r| if (r.type_name) |name| std.mem.eql(u8, name, map_type_name) else false,
        else => false,
    };
}

/// Get the data record from a HashMap
fn getData(map: Value) ?std.StringArrayHashMapUnmanaged(Value) {
    const record = switch (map) {
        .record => |r| r,
        else => return null,
    };
    const data_val = record.fields.get("_data") orelse return null;
    return switch (data_val) {
        .record => |r| r.fields,
        else => null,
    };
}

/// Put a key-value pair: put(map, key, value) -> HashMap
/// Key must be a string. Returns a new map with the updated entry.
fn mapPut(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 3) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    var data = getData(args[0]) orelse return error.TypeMismatch;

    const key = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Clone the data map and add/update the entry
    var new_data = std.StringArrayHashMapUnmanaged(Value){};
    errdefer new_data.deinit(ctx.allocator);

    // Copy existing entries
    var iter = data.iterator();
    while (iter.next()) |entry| {
        new_data.put(ctx.allocator, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    }

    // Add/update the new entry
    new_data.put(ctx.allocator, key, args[2]) catch return error.OutOfMemory;

    // Create new map with updated data
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_data", Value{
        .record = .{
            .type_name = null,
            .fields = new_data,
        },
    }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = map_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = map_type_name,
            .fields = fields,
        },
    };
}

/// Get a value by key: get(map, key) -> Option[Value]
fn mapGet(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    const key = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    if (data.get(key)) |value| {
        const inner = ctx.allocator.create(Value) catch return error.OutOfMemory;
        inner.* = value;
        return Value{ .some = inner };
    }

    return Value{ .none = {} };
}

/// Check if a key exists: contains(map, key) -> Bool
fn mapContains(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 2) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    const key = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    return Value{ .boolean = data.contains(key) };
}

/// Remove a key: remove(map, key) -> HashMap
/// Returns a new map without the specified key.
fn mapRemove(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 2) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    var data = getData(args[0]) orelse return error.TypeMismatch;

    const key = switch (args[1]) {
        .string => |s| s,
        else => return error.TypeMismatch,
    };

    // Clone the data map without the removed key
    var new_data = std.StringArrayHashMapUnmanaged(Value){};
    errdefer new_data.deinit(ctx.allocator);

    var iter = data.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, key)) {
            new_data.put(ctx.allocator, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
        }
    }

    // Create new map with updated data
    var fields = std.StringArrayHashMapUnmanaged(Value){};
    fields.put(ctx.allocator, "_data", Value{
        .record = .{
            .type_name = null,
            .fields = new_data,
        },
    }) catch return error.OutOfMemory;
    fields.put(ctx.allocator, "_type", Value{ .string = map_type_name }) catch return error.OutOfMemory;

    return Value{
        .record = .{
            .type_name = map_type_name,
            .fields = fields,
        },
    };
}

/// Get all keys: keys(map) -> List[String]
fn mapKeys(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    var data = getData(args[0]) orelse return error.TypeMismatch;

    // Collect keys into an array
    var keys_list = std.ArrayListUnmanaged(Value){};
    defer keys_list.deinit(ctx.allocator);

    var iter = data.iterator();
    while (iter.next()) |entry| {
        keys_list.append(ctx.allocator, Value{ .string = entry.key_ptr.* }) catch return error.OutOfMemory;
    }

    // Build list from array
    return buildList(ctx.allocator, keys_list.items);
}

/// Get all values: values(map) -> List[Value]
fn mapValues(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    var data = getData(args[0]) orelse return error.TypeMismatch;

    // Collect values into an array
    var values_list = std.ArrayListUnmanaged(Value){};
    defer values_list.deinit(ctx.allocator);

    var iter = data.iterator();
    while (iter.next()) |entry| {
        values_list.append(ctx.allocator, entry.value_ptr.*) catch return error.OutOfMemory;
    }

    // Build list from array
    return buildList(ctx.allocator, values_list.items);
}

/// Get all entries as (key, value) tuples: entries(map) -> List[(String, Value)]
fn mapEntries(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    if (args.len != 1) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    var data = getData(args[0]) orelse return error.TypeMismatch;

    // Collect entries into an array of tuples
    var entries_list = std.ArrayListUnmanaged(Value){};
    defer entries_list.deinit(ctx.allocator);

    var iter = data.iterator();
    while (iter.next()) |entry| {
        const tuple = ctx.allocator.alloc(Value, 2) catch return error.OutOfMemory;
        tuple[0] = Value{ .string = entry.key_ptr.* };
        tuple[1] = entry.value_ptr.*;
        entries_list.append(ctx.allocator, Value{ .tuple = tuple }) catch return error.OutOfMemory;
    }

    // Build list from array
    return buildList(ctx.allocator, entries_list.items);
}

/// Get the number of entries: size(map) -> Int
fn mapSize(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    return Value{ .integer = @intCast(data.count()) };
}

/// Check if map is empty: is_empty(map) -> Bool
fn mapIsEmpty(ctx: BuiltinContext, args: []const Value) InterpreterError!Value {
    _ = ctx;
    if (args.len != 1) return error.ArityMismatch;

    if (!isMap(args[0])) return error.TypeMismatch;
    const data = getData(args[0]) orelse return error.TypeMismatch;

    return Value{ .boolean = data.count() == 0 };
}

// ============================================================================
// Helpers
// ============================================================================

/// Build a list from a slice of values
fn buildList(allocator: Allocator, items: []const Value) InterpreterError!Value {
    var result: Value = Value{ .nil = {} };

    // Build in reverse to get correct order
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const head = allocator.create(Value) catch return error.OutOfMemory;
        const tail = allocator.create(Value) catch return error.OutOfMemory;
        head.* = items[i];
        tail.* = result;
        result = Value{ .cons = .{ .head = head, .tail = tail } };
    }

    return result;
}

// ============================================================================
// Tests
// ============================================================================

fn testCtx(allocator: Allocator) BuiltinContext {
    return .{
        .allocator = allocator,
        .interpreter = null,
        .call_fn = null,
    };
}

test "map new and is_empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    const map = try mapNew(ctx, &.{});
    try std.testing.expect(isMap(map));

    const empty = try mapIsEmpty(ctx, &.{map});
    try std.testing.expect(empty.boolean);

    const size = try mapSize(ctx, &.{map});
    try std.testing.expectEqual(@as(i128, 0), size.integer);
}

test "map put and get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var map = try mapNew(ctx, &.{});
    map = try mapPut(ctx, &.{ map, Value{ .string = "name" }, Value{ .string = "Alice" } });
    map = try mapPut(ctx, &.{ map, Value{ .string = "age" }, Value{ .integer = 30 } });

    const name_result = try mapGet(ctx, &.{ map, Value{ .string = "name" } });
    try std.testing.expect(name_result == .some);
    try std.testing.expectEqualStrings("Alice", name_result.some.string);

    const age_result = try mapGet(ctx, &.{ map, Value{ .string = "age" } });
    try std.testing.expect(age_result == .some);
    try std.testing.expectEqual(@as(i128, 30), age_result.some.integer);

    const missing = try mapGet(ctx, &.{ map, Value{ .string = "unknown" } });
    try std.testing.expect(missing == .none);
}

test "map contains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var map = try mapNew(ctx, &.{});
    map = try mapPut(ctx, &.{ map, Value{ .string = "key" }, Value{ .integer = 42 } });

    const has_key = try mapContains(ctx, &.{ map, Value{ .string = "key" } });
    try std.testing.expect(has_key.boolean);

    const no_key = try mapContains(ctx, &.{ map, Value{ .string = "missing" } });
    try std.testing.expect(!no_key.boolean);
}

test "map remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var map = try mapNew(ctx, &.{});
    map = try mapPut(ctx, &.{ map, Value{ .string = "a" }, Value{ .integer = 1 } });
    map = try mapPut(ctx, &.{ map, Value{ .string = "b" }, Value{ .integer = 2 } });

    const size_before = try mapSize(ctx, &.{map});
    try std.testing.expectEqual(@as(i128, 2), size_before.integer);

    map = try mapRemove(ctx, &.{ map, Value{ .string = "a" } });

    const size_after = try mapSize(ctx, &.{map});
    try std.testing.expectEqual(@as(i128, 1), size_after.integer);

    const removed = try mapContains(ctx, &.{ map, Value{ .string = "a" } });
    try std.testing.expect(!removed.boolean);

    const kept = try mapContains(ctx, &.{ map, Value{ .string = "b" } });
    try std.testing.expect(kept.boolean);
}

test "map keys and values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var map = try mapNew(ctx, &.{});
    map = try mapPut(ctx, &.{ map, Value{ .string = "x" }, Value{ .integer = 10 } });
    map = try mapPut(ctx, &.{ map, Value{ .string = "y" }, Value{ .integer = 20 } });

    const keys_result = try mapKeys(ctx, &.{map});
    // Keys should be a list with 2 elements
    try std.testing.expect(keys_result == .cons);

    const values_result = try mapValues(ctx, &.{map});
    // Values should be a list with 2 elements
    try std.testing.expect(values_result == .cons);
}

test "map entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const ctx = testCtx(allocator);

    var map = try mapNew(ctx, &.{});
    map = try mapPut(ctx, &.{ map, Value{ .string = "key" }, Value{ .integer = 42 } });

    const entries_result = try mapEntries(ctx, &.{map});
    try std.testing.expect(entries_result == .cons);

    // First entry should be a tuple
    const entry = entries_result.cons.head.*;
    try std.testing.expect(entry == .tuple);
    try std.testing.expectEqualStrings("key", entry.tuple[0].string);
    try std.testing.expectEqual(@as(i128, 42), entry.tuple[1].integer);
}
