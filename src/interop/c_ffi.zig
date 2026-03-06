//! C FFI support for Kira.
//!
//! Allows Kira to declare and call external C functions with explicit
//! type mappings. The generated C code includes proper forward declarations
//! and the linker resolves the symbols at link time.
//!
//! Kira syntax:
//!   extern fn puts(s: string) -> i32
//!   extern fn sqrt(x: f64) -> f64

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An external C function declaration.
pub const ExternFunction = struct {
    /// Function name as declared in C.
    name: []const u8,
    /// Parameter types (Kira type names).
    param_types: []const []const u8,
    /// Return type (Kira type name).
    return_type: []const u8,
    /// Optional library to link (e.g., "m" for libm).
    link_lib: ?[]const u8,

    pub fn deinit(self: *ExternFunction, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.param_types) |pt| allocator.free(pt);
        allocator.free(self.param_types);
        allocator.free(self.return_type);
        if (self.link_lib) |lib| allocator.free(lib);
    }
};

/// Map a Kira type name to a C type for FFI declarations.
pub fn toCType(kira_type: []const u8) []const u8 {
    if (std.mem.eql(u8, kira_type, "i8")) return "int8_t";
    if (std.mem.eql(u8, kira_type, "i16")) return "int16_t";
    if (std.mem.eql(u8, kira_type, "i32")) return "int32_t";
    if (std.mem.eql(u8, kira_type, "i64")) return "int64_t";
    if (std.mem.eql(u8, kira_type, "u8")) return "uint8_t";
    if (std.mem.eql(u8, kira_type, "u16")) return "uint16_t";
    if (std.mem.eql(u8, kira_type, "u32")) return "uint32_t";
    if (std.mem.eql(u8, kira_type, "u64")) return "uint64_t";
    if (std.mem.eql(u8, kira_type, "f32")) return "float";
    if (std.mem.eql(u8, kira_type, "f64")) return "double";
    if (std.mem.eql(u8, kira_type, "bool")) return "bool";
    if (std.mem.eql(u8, kira_type, "string")) return "const char*";
    if (std.mem.eql(u8, kira_type, "void")) return "void";
    // Pointer types
    if (std.mem.startsWith(u8, kira_type, "*")) return "void*";
    return "int64_t";
}

/// Generate C forward declarations for a list of extern functions.
/// These are emitted into the generated C source before any Kira functions.
/// Caller owns the returned slice.
pub fn generateExternDecls(allocator: Allocator, externs: []const ExternFunction) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    if (externs.len == 0) return output.toOwnedSlice(allocator);

    try appendSlice(allocator, &output, "/* External C function declarations */\n");

    for (externs) |ext| {
        try appendFmt(allocator, &output, "{s} {s}(", .{ toCType(ext.return_type), ext.name });

        if (ext.param_types.len == 0) {
            try appendSlice(allocator, &output, "void");
        } else {
            for (ext.param_types, 0..) |pt, i| {
                if (i > 0) try appendSlice(allocator, &output, ", ");
                try appendFmt(allocator, &output, "{s}", .{toCType(pt)});
            }
        }

        try appendSlice(allocator, &output, ");\n");
    }

    try appendSlice(allocator, &output, "\n");

    return output.toOwnedSlice(allocator);
}

/// Generate linker flags for external libraries.
/// Returns a list of "-l<lib>" flags. Caller owns the returned slice.
pub fn generateLinkFlags(allocator: Allocator, externs: []const ExternFunction) ![][]const u8 {
    var libs = std.StringHashMapUnmanaged(void){};
    defer libs.deinit(allocator);

    for (externs) |ext| {
        if (ext.link_lib) |lib| {
            libs.put(allocator, lib, {}) catch continue;
        }
    }

    var flags = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (flags.items) |f| allocator.free(f);
        flags.deinit(allocator);
    }

    var iter = libs.iterator();
    while (iter.next()) |entry| {
        const flag = try std.fmt.allocPrint(allocator, "-l{s}", .{entry.key_ptr.*});
        try flags.append(allocator, flag);
    }

    return flags.toOwnedSlice(allocator);
}

fn appendSlice(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try output.appendSlice(allocator, s);
}

fn appendFmt(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try output.appendSlice(allocator, formatted);
}

// --- Tests ---

test "toCType mappings" {
    try std.testing.expectEqualStrings("int32_t", toCType("i32"));
    try std.testing.expectEqualStrings("int64_t", toCType("i64"));
    try std.testing.expectEqualStrings("float", toCType("f32"));
    try std.testing.expectEqualStrings("double", toCType("f64"));
    try std.testing.expectEqualStrings("bool", toCType("bool"));
    try std.testing.expectEqualStrings("const char*", toCType("string"));
    try std.testing.expectEqualStrings("void", toCType("void"));
    try std.testing.expectEqualStrings("void*", toCType("*i32"));
    try std.testing.expectEqualStrings("uint8_t", toCType("u8"));
}

test "generateExternDecls empty" {
    const allocator = std.testing.allocator;
    const result = try generateExternDecls(allocator, &.{});
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "generateExternDecls with functions" {
    const allocator = std.testing.allocator;

    const externs = [_]ExternFunction{
        .{
            .name = "puts",
            .param_types = &.{"string"},
            .return_type = "i32",
            .link_lib = null,
        },
        .{
            .name = "sqrt",
            .param_types = &.{"f64"},
            .return_type = "f64",
            .link_lib = "m",
        },
    };

    const result = try generateExternDecls(allocator, &externs);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "int32_t puts(const char*)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "double sqrt(double)") != null);
}

test "generateExternDecls void params" {
    const allocator = std.testing.allocator;

    const externs = [_]ExternFunction{
        .{
            .name = "getpid",
            .param_types = &.{},
            .return_type = "i32",
            .link_lib = null,
        },
    };

    const result = try generateExternDecls(allocator, &externs);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "int32_t getpid(void)") != null);
}

test "generateLinkFlags" {
    const allocator = std.testing.allocator;

    const externs = [_]ExternFunction{
        .{
            .name = "sqrt",
            .param_types = &.{"f64"},
            .return_type = "f64",
            .link_lib = "m",
        },
        .{
            .name = "puts",
            .param_types = &.{"string"},
            .return_type = "i32",
            .link_lib = null,
        },
    };

    const flags = try generateLinkFlags(allocator, &externs);
    defer {
        for (flags) |f| allocator.free(f);
        allocator.free(flags);
    }

    try std.testing.expectEqual(@as(usize, 1), flags.len);
    try std.testing.expectEqualStrings("-lm", flags[0]);
}

test "ExternFunction type mismatch detection" {
    // Verify that pointer types map correctly
    try std.testing.expectEqualStrings("void*", toCType("*u8"));
    try std.testing.expectEqualStrings("void*", toCType("*i32"));
}
