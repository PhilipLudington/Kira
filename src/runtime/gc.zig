//! Runtime memory management for compiled Kira code.
//!
//! Uses reference counting for deterministic cleanup of heap-allocated values
//! (ADTs, closures, arrays). Each managed object has a reference count header.
//! When the count drops to zero, the object and its owned memory are freed.
//!
//! This is a simple scheme suitable for Kira's functional style, where most
//! values are immutable and cycles are rare. A tracing GC can replace this
//! later if cyclic reference handling becomes necessary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const adt_mod = @import("adt.zig");
const KiraValue = adt_mod.KiraValue;
const AdtValue = adt_mod.AdtValue;

/// Header prepended to every managed heap allocation.
/// Tracks the reference count and object kind for cleanup dispatch.
pub const GcHeader = struct {
    ref_count: u32,
    kind: ObjectKind,

    pub const ObjectKind = enum(u8) {
        adt,
        array,
        closure,
        string,
    };
};

/// A managed heap object: GcHeader followed by the actual value.
pub const ManagedObject = struct {
    header: GcHeader,
    /// The managed value (tagged so the GC knows how to walk/free it).
    value: ManagedValue,

    pub const ManagedValue = union(enum) {
        adt: ManagedAdt,
        array: ManagedArray,
        closure: ManagedClosure,
        string: ManagedString,
    };
};

/// Managed ADT: tag + fields that may themselves be managed.
pub const ManagedAdt = struct {
    tag: u32,
    type_id: u32,
    fields: []KiraValue,
};

/// Managed array: elements that may themselves be managed.
pub const ManagedArray = struct {
    elements: []KiraValue,
};

/// Managed closure: function pointer + captures.
pub const ManagedClosure = struct {
    function_ptr: *const anyopaque,
    function_index: u32,
    arity: u32,
    captures: []KiraValue,
};

/// Managed string: owned byte buffer.
pub const ManagedString = struct {
    data: []u8,
};

/// Simple reference-counting memory manager for Kira runtime values.
pub const GcAllocator = struct {
    backing: Allocator,
    /// Total number of live managed objects (for debugging/metrics).
    live_count: usize,
    /// Total bytes currently allocated via this manager.
    allocated_bytes: usize,
    /// Collection threshold: trigger collection when allocated_bytes exceeds this.
    threshold: usize,

    pub fn init(backing: Allocator) GcAllocator {
        return .{
            .backing = backing,
            .live_count = 0,
            .allocated_bytes = 0,
            .threshold = 1024 * 1024, // 1 MB default
        };
    }

    /// Allocate a new managed ADT value. Starts with ref_count = 1.
    pub fn allocAdt(self: *GcAllocator, type_id: u32, tag: u32, field_count: u32) !*ManagedObject {
        const fields = try self.backing.alloc(KiraValue, field_count);
        @memset(fields, .{ .none = {} });

        const obj = try self.backing.create(ManagedObject);
        obj.* = .{
            .header = .{ .ref_count = 1, .kind = .adt },
            .value = .{ .adt = .{
                .tag = tag,
                .type_id = type_id,
                .fields = fields,
            } },
        };

        self.live_count += 1;
        self.allocated_bytes += @sizeOf(ManagedObject) + field_count * @sizeOf(KiraValue);
        return obj;
    }

    /// Allocate a managed ADT with pre-filled fields.
    pub fn allocAdtWithFields(self: *GcAllocator, type_id: u32, tag: u32, source_fields: []const KiraValue) !*ManagedObject {
        const obj = try self.allocAdt(type_id, tag, @intCast(source_fields.len));
        @memcpy(obj.value.adt.fields, source_fields);
        return obj;
    }

    /// Allocate a managed array.
    pub fn allocArray(self: *GcAllocator, elements: []const KiraValue) !*ManagedObject {
        const elems = try self.backing.alloc(KiraValue, elements.len);
        @memcpy(elems, elements);

        const obj = try self.backing.create(ManagedObject);
        obj.* = .{
            .header = .{ .ref_count = 1, .kind = .array },
            .value = .{ .array = .{ .elements = elems } },
        };

        self.live_count += 1;
        self.allocated_bytes += @sizeOf(ManagedObject) + elements.len * @sizeOf(KiraValue);
        return obj;
    }

    /// Allocate a managed closure.
    pub fn allocClosure(
        self: *GcAllocator,
        function_ptr: *const anyopaque,
        function_index: u32,
        arity: u32,
        captures: []const KiraValue,
    ) !*ManagedObject {
        const caps = try self.backing.alloc(KiraValue, captures.len);
        @memcpy(caps, captures);

        const obj = try self.backing.create(ManagedObject);
        obj.* = .{
            .header = .{ .ref_count = 1, .kind = .closure },
            .value = .{ .closure = .{
                .function_ptr = function_ptr,
                .function_index = function_index,
                .arity = arity,
                .captures = caps,
            } },
        };

        self.live_count += 1;
        self.allocated_bytes += @sizeOf(ManagedObject) + captures.len * @sizeOf(KiraValue);
        return obj;
    }

    /// Allocate a managed string (copies the data).
    pub fn allocString(self: *GcAllocator, data: []const u8) !*ManagedObject {
        const owned = try self.backing.alloc(u8, data.len);
        @memcpy(owned, data);

        const obj = try self.backing.create(ManagedObject);
        obj.* = .{
            .header = .{ .ref_count = 1, .kind = .string },
            .value = .{ .string = .{ .data = owned } },
        };

        self.live_count += 1;
        self.allocated_bytes += @sizeOf(ManagedObject) + data.len;
        return obj;
    }

    /// Increment the reference count.
    pub fn retain(self: *GcAllocator, obj: *ManagedObject) void {
        _ = self;
        obj.header.ref_count += 1;
    }

    /// Decrement the reference count. Frees the object if it reaches zero.
    pub fn release(self: *GcAllocator, obj: *ManagedObject) void {
        std.debug.assert(obj.header.ref_count > 0);
        obj.header.ref_count -= 1;
        if (obj.header.ref_count == 0) {
            self.freeObject(obj);
        }
    }

    /// Free a managed object and its owned memory.
    fn freeObject(self: *GcAllocator, obj: *ManagedObject) void {
        const payload_bytes: usize = switch (obj.value) {
            .adt => |a| blk: {
                self.backing.free(a.fields);
                break :blk a.fields.len * @sizeOf(KiraValue);
            },
            .array => |a| blk: {
                self.backing.free(a.elements);
                break :blk a.elements.len * @sizeOf(KiraValue);
            },
            .closure => |c| blk: {
                self.backing.free(c.captures);
                break :blk c.captures.len * @sizeOf(KiraValue);
            },
            .string => |s| blk: {
                self.backing.free(s.data);
                break :blk s.data.len;
            },
        };
        self.backing.destroy(obj);
        self.live_count -= 1;
        self.allocated_bytes -= @sizeOf(ManagedObject) + payload_bytes;
    }

    /// Check if memory pressure suggests collection.
    pub fn shouldCollect(self: *const GcAllocator) bool {
        return self.allocated_bytes >= self.threshold;
    }

    /// Get statistics for debugging.
    pub fn stats(self: *const GcAllocator) Stats {
        return .{
            .live_count = self.live_count,
            .allocated_bytes = self.allocated_bytes,
            .threshold = self.threshold,
        };
    }

    pub const Stats = struct {
        live_count: usize,
        allocated_bytes: usize,
        threshold: usize,
    };
};

// ============================================================
// Tests
// ============================================================

test "GcAllocator allocate and collect ADT" {
    var gc = GcAllocator.init(testing.allocator);

    // Allocate Option.Some(42)
    const fields = [_]KiraValue{.{ .integer = 42 }};
    const obj = try gc.allocAdtWithFields(0, 0, &fields);

    try testing.expectEqual(@as(u32, 1), obj.header.ref_count);
    try testing.expectEqual(@as(usize, 1), gc.live_count);

    // Release -> should free
    gc.release(obj);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
    try testing.expectEqual(@as(usize, 0), gc.allocated_bytes);
}

test "GcAllocator retain/release counting" {
    var gc = GcAllocator.init(testing.allocator);

    const obj = try gc.allocAdt(0, 0, 0);

    // Retain twice
    gc.retain(obj);
    gc.retain(obj);
    try testing.expectEqual(@as(u32, 3), obj.header.ref_count);

    // Release twice (still alive)
    gc.release(obj);
    gc.release(obj);
    try testing.expectEqual(@as(u32, 1), obj.header.ref_count);
    try testing.expectEqual(@as(usize, 1), gc.live_count);

    // Final release frees
    gc.release(obj);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
}

test "GcAllocator no premature collection of live objects" {
    var gc = GcAllocator.init(testing.allocator);

    const obj1 = try gc.allocAdt(0, 0, 0);
    const obj2 = try gc.allocAdt(0, 1, 0);
    try testing.expectEqual(@as(usize, 2), gc.live_count);

    // Release obj1 — obj2 should still be alive
    gc.release(obj1);
    try testing.expectEqual(@as(usize, 1), gc.live_count);
    try testing.expectEqual(@as(u32, 1), obj2.header.ref_count);

    gc.release(obj2);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
}

test "GcAllocator allocate and collect array" {
    var gc = GcAllocator.init(testing.allocator);

    const elements = [_]KiraValue{
        .{ .integer = 1 },
        .{ .integer = 2 },
        .{ .integer = 3 },
    };
    const obj = try gc.allocArray(&elements);
    try testing.expectEqual(@as(usize, 3), obj.value.array.elements.len);

    gc.release(obj);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
}

test "GcAllocator allocate and collect closure" {
    var gc = GcAllocator.init(testing.allocator);

    const dummy_fn: *const anyopaque = @ptrCast(&struct {
        fn f() void {}
    }.f);
    const captures = [_]KiraValue{.{ .integer = 42 }};
    const obj = try gc.allocClosure(dummy_fn, 0, 1, &captures);

    try testing.expectEqual(@as(u32, 1), obj.value.closure.arity);
    try testing.expectEqual(@as(usize, 1), obj.value.closure.captures.len);

    gc.release(obj);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
}

test "GcAllocator allocate and collect string" {
    var gc = GcAllocator.init(testing.allocator);

    const obj = try gc.allocString("hello world");
    try testing.expectEqualStrings("hello world", obj.value.string.data);

    gc.release(obj);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
}

test "GcAllocator memory pressure triggers collection" {
    var gc = GcAllocator.init(testing.allocator);
    gc.threshold = 100; // Low threshold for testing

    try testing.expect(!gc.shouldCollect());

    // Allocate enough to exceed threshold
    var objects: [10]*ManagedObject = undefined;
    for (&objects) |*slot| {
        const fields = [_]KiraValue{.{ .integer = 0 }} ** 8;
        slot.* = try gc.allocAdtWithFields(0, 0, &fields);
    }

    try testing.expect(gc.shouldCollect());

    // Clean up
    for (objects) |obj| gc.release(obj);
    try testing.expectEqual(@as(usize, 0), gc.live_count);
}

test "GcAllocator stats tracking" {
    var gc = GcAllocator.init(testing.allocator);

    const initial = gc.stats();
    try testing.expectEqual(@as(usize, 0), initial.live_count);
    try testing.expectEqual(@as(usize, 0), initial.allocated_bytes);

    const obj = try gc.allocAdt(0, 0, 2);
    const after_alloc = gc.stats();
    try testing.expect(after_alloc.live_count == 1);
    try testing.expect(after_alloc.allocated_bytes > 0);

    gc.release(obj);
    const after_free = gc.stats();
    try testing.expectEqual(@as(usize, 0), after_free.live_count);
    try testing.expectEqual(@as(usize, 0), after_free.allocated_bytes);
}
