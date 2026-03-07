//! Runtime representation for Algebraic Data Types (ADTs).
//!
//! Provides the memory layout and operations for sum types in compiled Kira code.
//! Each ADT value is a tagged union: a u32 tag followed by a flat array of payload
//! fields. This layout is compatible with C calling conventions and allows efficient
//! pattern match dispatch via tag comparison.
//!
//! Layout: [tag: u32][field_0][field_1]...[field_n]
//! Each field is a KiraValue (pointer-sized, tagged union of runtime values).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A runtime value in compiled Kira code.
/// Pointer-sized tagged union for uniform representation.
pub const KiraValue = union(enum) {
    integer: i64,
    float: f64,
    boolean: bool,
    char: u21,
    string: [*]const u8,
    adt: *AdtValue,
    array: *ArrayValue,
    closure: *ClosureValue,
    none: void,

    pub fn isNone(self: KiraValue) bool {
        return self == .none;
    }
};

/// Runtime representation of an ADT value (sum type instance).
/// Heap-allocated: tag + variable-length payload fields.
pub const AdtValue = struct {
    /// Discriminant tag identifying which variant this is.
    tag: u32,
    /// Type identifier for runtime type checks (index into type table).
    type_id: u32,
    /// Payload fields (variable length, determined by variant).
    fields: []KiraValue,

    /// Allocate a new ADT value with the given tag and field count.
    pub fn create(allocator: Allocator, type_id: u32, tag: u32, field_count: u32) !*AdtValue {
        const fields = try allocator.alloc(KiraValue, field_count);
        @memset(fields, .{ .none = {} });

        const adt = try allocator.create(AdtValue);
        adt.* = .{
            .tag = tag,
            .type_id = type_id,
            .fields = fields,
        };
        return adt;
    }

    /// Allocate a new ADT value with pre-filled fields.
    pub fn createWithFields(allocator: Allocator, type_id: u32, tag: u32, source_fields: []const KiraValue) !*AdtValue {
        const fields = try allocator.alloc(KiraValue, source_fields.len);
        @memcpy(fields, source_fields);

        const adt = try allocator.create(AdtValue);
        adt.* = .{
            .tag = tag,
            .type_id = type_id,
            .fields = fields,
        };
        return adt;
    }

    /// Create a unit variant (no payload fields).
    pub fn createUnit(allocator: Allocator, type_id: u32, tag: u32) !*AdtValue {
        return create(allocator, type_id, tag, 0);
    }

    /// Free this ADT value and its payload.
    pub fn destroy(self: *AdtValue, allocator: Allocator) void {
        allocator.free(self.fields);
        allocator.destroy(self);
    }

    /// Get the tag (discriminant) of this variant.
    pub fn getTag(self: *const AdtValue) u32 {
        return self.tag;
    }

    /// Get a payload field by index.
    /// Returns null if index is out of bounds.
    pub fn getField(self: *const AdtValue, index: u32) ?KiraValue {
        if (index >= self.fields.len) return null;
        return self.fields[index];
    }

    /// Set a payload field by index.
    /// Returns false if index is out of bounds.
    pub fn setField(self: *AdtValue, index: u32, value: KiraValue) bool {
        if (index >= self.fields.len) return false;
        self.fields[index] = value;
        return true;
    }

    /// Get the number of payload fields.
    pub fn fieldCount(self: *const AdtValue) u32 {
        return @intCast(self.fields.len);
    }
};

/// Runtime type descriptor for ADT types.
/// Used by the runtime to validate operations and provide type names for debugging.
pub const AdtTypeDescriptor = struct {
    name: []const u8,
    type_id: u32,
    variants: []const VariantDescriptor,

    /// Look up a variant by tag.
    pub fn getVariant(self: *const AdtTypeDescriptor, tag: u32) ?*const VariantDescriptor {
        for (self.variants) |*v| {
            if (v.tag == tag) return v;
        }
        return null;
    }

    /// Look up a variant by name.
    pub fn getVariantByName(self: *const AdtTypeDescriptor, name: []const u8) ?*const VariantDescriptor {
        for (self.variants) |*v| {
            if (std.mem.eql(u8, v.name, name)) return v;
        }
        return null;
    }
};

/// Descriptor for a single variant within an ADT type.
pub const VariantDescriptor = struct {
    name: []const u8,
    tag: u32,
    field_count: u32,
};

/// Runtime array value (heap-allocated, growable).
pub const ArrayValue = struct {
    elements: []KiraValue,
    capacity: usize,

    pub fn create(allocator: Allocator, elements: []const KiraValue) !*ArrayValue {
        const elems = try allocator.alloc(KiraValue, elements.len);
        @memcpy(elems, elements);

        const arr = try allocator.create(ArrayValue);
        arr.* = .{
            .elements = elems,
            .capacity = elements.len,
        };
        return arr;
    }

    pub fn destroy(self: *ArrayValue, allocator: Allocator) void {
        allocator.free(self.elements);
        allocator.destroy(self);
    }

    pub fn len(self: *const ArrayValue) usize {
        return self.elements.len;
    }

    pub fn get(self: *const ArrayValue, index: usize) ?KiraValue {
        if (index >= self.elements.len) return null;
        return self.elements[index];
    }
};

/// Placeholder for closure values (implemented in closure.zig).
pub const ClosureValue = struct {
    function_ptr: *const anyopaque,
    captures: []KiraValue,
};

/// Registry of ADT type descriptors for runtime type checking.
pub const TypeRegistry = struct {
    descriptors: std.ArrayListUnmanaged(AdtTypeDescriptor),
    name_map: std.StringArrayHashMapUnmanaged(u32),

    pub fn init() TypeRegistry {
        return .{
            .descriptors = .{},
            .name_map = .{},
        };
    }

    pub fn deinit(self: *TypeRegistry, allocator: Allocator) void {
        self.descriptors.deinit(allocator);
        self.name_map.deinit(allocator);
    }

    /// Register a new ADT type. Returns its type_id.
    pub fn register(self: *TypeRegistry, allocator: Allocator, desc: AdtTypeDescriptor) !u32 {
        const id: u32 = @intCast(self.descriptors.items.len);
        var d = desc;
        d.type_id = id;
        try self.descriptors.append(allocator, d);
        try self.name_map.put(allocator, desc.name, id);
        return id;
    }

    /// Look up a type descriptor by id.
    pub fn get(self: *const TypeRegistry, type_id: u32) ?*const AdtTypeDescriptor {
        if (type_id >= self.descriptors.items.len) return null;
        return &self.descriptors.items[type_id];
    }

    /// Look up a type descriptor by name.
    pub fn getByName(self: *const TypeRegistry, name: []const u8) ?*const AdtTypeDescriptor {
        const id = self.name_map.get(name) orelse return null;
        return self.get(id);
    }
};

// ============================================================
// Tests
// ============================================================

test "AdtValue create unit variant" {
    const allocator = testing.allocator;

    // Create Option.None (tag=1, no fields)
    const none = try AdtValue.createUnit(allocator, 0, 1);
    defer none.destroy(allocator);

    try testing.expectEqual(@as(u32, 1), none.getTag());
    try testing.expectEqual(@as(u32, 0), none.fieldCount());
    try testing.expect(none.getField(0) == null);
}

test "AdtValue create with payload" {
    const allocator = testing.allocator;

    // Create Option.Some(42)
    const fields = [_]KiraValue{.{ .integer = 42 }};
    const some = try AdtValue.createWithFields(allocator, 0, 0, &fields);
    defer some.destroy(allocator);

    try testing.expectEqual(@as(u32, 0), some.getTag());
    try testing.expectEqual(@as(u32, 1), some.fieldCount());

    const field = some.getField(0);
    try testing.expect(field != null);
    try testing.expectEqual(@as(i64, 42), field.?.integer);
}

test "AdtValue set field" {
    const allocator = testing.allocator;

    const adt = try AdtValue.create(allocator, 0, 0, 2);
    defer adt.destroy(allocator);

    try testing.expect(adt.setField(0, .{ .integer = 10 }));
    try testing.expect(adt.setField(1, .{ .boolean = true }));
    try testing.expect(!adt.setField(2, .{ .none = {} })); // out of bounds

    try testing.expectEqual(@as(i64, 10), adt.getField(0).?.integer);
    try testing.expectEqual(true, adt.getField(1).?.boolean);
}

test "AdtValue nested ADT construction" {
    const allocator = testing.allocator;

    // Build: Some(Some(42))
    const inner_fields = [_]KiraValue{.{ .integer = 42 }};
    const inner = try AdtValue.createWithFields(allocator, 0, 0, &inner_fields);
    defer inner.destroy(allocator);

    const outer_fields = [_]KiraValue{.{ .adt = inner }};
    const outer = try AdtValue.createWithFields(allocator, 0, 0, &outer_fields);
    defer outer.destroy(allocator);

    // outer.getField(0) -> inner ADT
    const inner_ref = outer.getField(0).?.adt;
    try testing.expectEqual(@as(u32, 0), inner_ref.getTag());
    try testing.expectEqual(@as(i64, 42), inner_ref.getField(0).?.integer);
}

test "AdtTypeDescriptor variant lookup" {
    const variants = [_]VariantDescriptor{
        .{ .name = "Some", .tag = 0, .field_count = 1 },
        .{ .name = "None", .tag = 1, .field_count = 0 },
    };
    const desc = AdtTypeDescriptor{
        .name = "Option",
        .type_id = 0,
        .variants = &variants,
    };

    const some = desc.getVariant(0);
    try testing.expect(some != null);
    try testing.expectEqualStrings("Some", some.?.name);
    try testing.expectEqual(@as(u32, 1), some.?.field_count);

    const none = desc.getVariantByName("None");
    try testing.expect(none != null);
    try testing.expectEqual(@as(u32, 1), none.?.tag);

    try testing.expect(desc.getVariant(99) == null);
    try testing.expect(desc.getVariantByName("Missing") == null);
}

test "TypeRegistry register and lookup" {
    const allocator = testing.allocator;
    var registry = TypeRegistry.init();
    defer registry.deinit(allocator);

    const option_variants = [_]VariantDescriptor{
        .{ .name = "Some", .tag = 0, .field_count = 1 },
        .{ .name = "None", .tag = 1, .field_count = 0 },
    };
    const option_id = try registry.register(allocator, .{
        .name = "Option",
        .type_id = 0,
        .variants = &option_variants,
    });
    try testing.expectEqual(@as(u32, 0), option_id);

    const result_variants = [_]VariantDescriptor{
        .{ .name = "Ok", .tag = 0, .field_count = 1 },
        .{ .name = "Err", .tag = 1, .field_count = 1 },
    };
    const result_id = try registry.register(allocator, .{
        .name = "Result",
        .type_id = 0,
        .variants = &result_variants,
    });
    try testing.expectEqual(@as(u32, 1), result_id);

    // Lookup by id
    const option_desc = registry.get(option_id);
    try testing.expect(option_desc != null);
    try testing.expectEqualStrings("Option", option_desc.?.name);

    // Lookup by name
    const result_desc = registry.getByName("Result");
    try testing.expect(result_desc != null);
    try testing.expectEqual(@as(u32, 2), result_desc.?.variants.len);

    // Not found
    try testing.expect(registry.getByName("Unknown") == null);
    try testing.expect(registry.get(99) == null);
}

test "pattern match dispatch via tag" {
    const allocator = testing.allocator;

    // Simulate: match value { Some(x) => x, None => 0 }
    const fields = [_]KiraValue{.{ .integer = 42 }};
    const value = try AdtValue.createWithFields(allocator, 0, 0, &fields);
    defer value.destroy(allocator);

    // Dispatch based on tag
    const result: i64 = switch (value.getTag()) {
        0 => value.getField(0).?.integer, // Some(x) => x
        1 => 0, // None => 0
        else => -1,
    };

    try testing.expectEqual(@as(i64, 42), result);
}

test "memory layout correctness" {
    const allocator = testing.allocator;

    // Verify ADT struct size is reasonable
    try testing.expect(@sizeOf(AdtValue) <= 32);

    // Create and verify memory doesn't leak
    const adt = try AdtValue.create(allocator, 0, 0, 5);
    defer adt.destroy(allocator);

    try testing.expectEqual(@as(u32, 5), adt.fieldCount());
    // All fields should be initialized to none
    for (0..5) |i| {
        const f = adt.getField(@intCast(i));
        try testing.expect(f != null);
        try testing.expect(f.?.isNone());
    }
}
