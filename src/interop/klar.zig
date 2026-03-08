//! Klar interop for Kira.
//!
//! Generates C header files from Kira modules that Klar can import
//! via its FFI `extern` blocks. Both languages use standard C calling
//! conventions, so the interop boundary is a C ABI.
//!
//! Usage:
//!   kira build mylib.ki            -> produces mylib.c
//!   cc -c mylib.c -o mylib.o       -> compile to object file
//!   (Klar imports via extern block pointing to mylib.o)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir/ir.zig");

/// Map a Kira IR type to a C type string for header generation.
/// Primitive types map to stdint types; user-defined types map to "kira_{Name}".
pub fn kiraToCType(kira_type: []const u8) []const u8 {
    if (std.mem.eql(u8, kira_type, "i8")) return "int8_t";
    if (std.mem.eql(u8, kira_type, "i16")) return "int16_t";
    if (std.mem.eql(u8, kira_type, "i32") or std.mem.eql(u8, kira_type, "int")) return "int32_t";
    if (std.mem.eql(u8, kira_type, "i64")) return "int64_t";
    if (std.mem.eql(u8, kira_type, "i128")) return "__int128";
    if (std.mem.eql(u8, kira_type, "u8")) return "uint8_t";
    if (std.mem.eql(u8, kira_type, "u16")) return "uint16_t";
    if (std.mem.eql(u8, kira_type, "u32")) return "uint32_t";
    if (std.mem.eql(u8, kira_type, "u64")) return "uint64_t";
    if (std.mem.eql(u8, kira_type, "u128")) return "unsigned __int128";
    if (std.mem.eql(u8, kira_type, "f32")) return "float";
    if (std.mem.eql(u8, kira_type, "f64") or std.mem.eql(u8, kira_type, "float")) return "double";
    if (std.mem.eql(u8, kira_type, "bool")) return "bool";
    if (std.mem.eql(u8, kira_type, "char")) return "uint32_t";
    if (std.mem.eql(u8, kira_type, "string")) return "const char*";
    if (std.mem.eql(u8, kira_type, "void")) return "void";
    return "int64_t"; // Default for unknown types
}

/// Allocating version of kiraToCType that handles user-defined type names.
/// For primitives, returns a static string (allocated = false).
/// For user types, allocates "kira_{Name}" (allocated = true).
fn kiraToCTypeAlloc(allocator: Allocator, kira_type: []const u8, module: *const ir.Module) !CTypeResult {
    // Check if it's a known type decl name
    for (module.type_decls.items) |td| {
        if (std.mem.eql(u8, td.name, kira_type)) {
            return .{
                .c_type = try std.fmt.allocPrint(allocator, "kira_{s}", .{kira_type}),
                .allocated = true,
            };
        }
    }
    return .{ .c_type = kiraToCType(kira_type), .allocated = false };
}

const CTypeResult = struct {
    c_type: []const u8,
    allocated: bool,
};

/// Map a Kira type name to the corresponding Klar FFI type.
/// Primitive types map to Klar builtins; user-defined types pass through unchanged
/// (they'll be declared as extern structs in the Klar block).
pub fn kiraToKlarType(kira_type: []const u8) []const u8 {
    if (std.mem.eql(u8, kira_type, "i8")) return "i8";
    if (std.mem.eql(u8, kira_type, "i16")) return "i16";
    if (std.mem.eql(u8, kira_type, "i32")) return "i32";
    if (std.mem.eql(u8, kira_type, "i64")) return "i64";
    if (std.mem.eql(u8, kira_type, "i128")) return "i128";
    if (std.mem.eql(u8, kira_type, "u8")) return "u8";
    if (std.mem.eql(u8, kira_type, "u16")) return "u16";
    if (std.mem.eql(u8, kira_type, "u32")) return "u32";
    if (std.mem.eql(u8, kira_type, "u64")) return "u64";
    if (std.mem.eql(u8, kira_type, "u128")) return "u128";
    if (std.mem.eql(u8, kira_type, "f32")) return "f32";
    if (std.mem.eql(u8, kira_type, "f64")) return "f64";
    if (std.mem.eql(u8, kira_type, "bool")) return "Bool";
    if (std.mem.eql(u8, kira_type, "char")) return "Char";
    if (std.mem.eql(u8, kira_type, "string")) return "CStr";
    if (std.mem.eql(u8, kira_type, "void")) return "Void";
    // User-defined types: check if it looks like an ADT name (starts with uppercase)
    if (kira_type.len > 0 and std.ascii.isUpper(kira_type[0])) return kira_type;
    return "i64";
}

/// Generate a C header file from an IR module.
/// The header declares all public functions with C-compatible signatures.
/// `module_name` is used for the include guard (e.g., "mylib" -> KIRA_MYLIB_H).
/// Caller owns the returned slice.
pub fn generateHeader(allocator: Allocator, module: *const ir.Module, module_name: []const u8) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    // Build unique header guard from module name
    var guard_buf: [128]u8 = undefined;
    var guard_len: usize = 0;
    const prefix = "KIRA_";
    @memcpy(guard_buf[0..prefix.len], prefix);
    guard_len = prefix.len;
    for (module_name) |c| {
        if (guard_len >= guard_buf.len - 2) break;
        guard_buf[guard_len] = if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_';
        guard_len += 1;
    }
    @memcpy(guard_buf[guard_len .. guard_len + 2], "_H");
    guard_len += 2;
    const guard = guard_buf[0..guard_len];

    // Header guard
    try appendSlice(allocator, &output, "/* Generated by Kira compiler — C header for FFI */\n");
    try appendFmt(allocator, &output, "#ifndef {s}\n", .{guard});
    try appendFmt(allocator, &output, "#define {s}\n\n", .{guard});
    try appendSlice(allocator, &output, "#include <stdint.h>\n");
    try appendSlice(allocator, &output, "#include <stdbool.h>\n\n");
    try appendSlice(allocator, &output, "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n");

    // Emit ADT type declarations
    try emitHeaderTypeDecls(allocator, &output, module);

    // Declare all non-main functions
    for (module.functions.items) |func| {
        const name = func.name orelse continue;
        if (std.mem.eql(u8, name, "main")) continue;

        // Return type
        const ret_c = try kiraToCTypeAlloc(allocator, func.return_type_name, module);
        defer if (ret_c.allocated) allocator.free(ret_c.c_type);
        try appendFmt(allocator, &output, "{s} ", .{ret_c.c_type});
        try appendFmt(allocator, &output, "{s}(", .{name});

        // Parameters
        if (func.params.len == 0) {
            try appendSlice(allocator, &output, "void");
        } else {
            for (func.params, 0..) |param, i| {
                if (i > 0) try appendSlice(allocator, &output, ", ");
                const param_c = try kiraToCTypeAlloc(allocator, param.type_name, module);
                defer if (param_c.allocated) allocator.free(param_c.c_type);
                try appendFmt(allocator, &output, "{s} {s}", .{ param_c.c_type, param.name });
            }
        }

        try appendSlice(allocator, &output, ");\n");
    }

    // kira_free for library cleanup
    try appendSlice(allocator, &output, "\n/* Memory management */\n");
    try appendSlice(allocator, &output, "void kira_free(void* ptr);\n");

    try appendSlice(allocator, &output, "\n#ifdef __cplusplus\n}\n#endif\n\n");
    try appendFmt(allocator, &output, "#endif /* {s} */\n", .{guard});

    return output.toOwnedSlice(allocator);
}

/// Generate a Klar extern block that can import functions from a Kira module.
/// Caller owns the returned slice.
pub fn generateKlarExternBlock(allocator: Allocator, module: *const ir.Module) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try appendSlice(allocator, &output, "// Generated Klar extern block for Kira module\n\n");

    // Emit ADT type declarations
    try emitKlarTypeDecls(allocator, &output, module);

    try appendSlice(allocator, &output, "extern {\n");

    for (module.functions.items) |func| {
        const name = func.name orelse continue;
        if (std.mem.eql(u8, name, "main")) continue;

        try appendFmt(allocator, &output, "    fn {s}(", .{name});

        for (func.params, 0..) |param, i| {
            if (i > 0) try appendSlice(allocator, &output, ", ");
            try appendFmt(allocator, &output, "{s}: {s}", .{ param.name, kiraToKlarType(param.type_name) });
        }

        try appendFmt(allocator, &output, ") -> {s}\n", .{kiraToKlarType(func.return_type_name)});
    }

    // kira_free declaration
    try appendSlice(allocator, &output, "    fn kira_free(ptr: Ptr) -> Void\n");

    try appendSlice(allocator, &output, "}\n");

    // String convenience wrappers
    try emitKlarStringWrappers(allocator, &output, module);

    return output.toOwnedSlice(allocator);
}

/// Emit C type declarations for ADTs into the header.
fn emitHeaderTypeDecls(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), module: *const ir.Module) !void {
    if (module.type_decls.items.len == 0) return;

    try appendSlice(allocator, output, "/* Type declarations */\n\n");

    for (module.type_decls.items) |td| {
        switch (td.kind) {
            .sum_type => |st| {
                // Tag enum
                try appendFmt(allocator, output, "typedef enum {{\n", .{});
                for (st.variants, 0..) |v, i| {
                    if (i > 0) try appendSlice(allocator, output, ",\n");
                    try appendFmt(allocator, output, "    KIRA_{s}_{s} = {d}", .{ td.name, v.name, v.tag });
                }
                try appendSlice(allocator, output, "\n");
                try appendFmt(allocator, output, "}} kira_{s}_Tag;\n\n", .{td.name});

                // Variant payload structs (only for variants with fields)
                for (st.variants) |v| {
                    if (v.field_count == 0) continue;
                    try appendFmt(allocator, output, "typedef struct {{ ", .{});
                    for (v.field_types, 0..) |ft, fi| {
                        if (fi > 0) try appendSlice(allocator, output, " ");
                        const c_type = try kiraToCTypeAlloc(allocator, ft.type_name, module);
                        defer if (c_type.allocated) allocator.free(c_type.c_type);
                        try appendFmt(allocator, output, "{s} {s};", .{ c_type.c_type, ft.name });
                    }
                    try appendFmt(allocator, output, " }} kira_{s}_{s};\n", .{ td.name, v.name });
                }

                // Tagged union struct
                try appendFmt(allocator, output, "\ntypedef struct {{\n", .{});
                try appendFmt(allocator, output, "    kira_{s}_Tag tag;\n", .{td.name});

                // Check if any variant has a payload
                var has_payload = false;
                for (st.variants) |v| {
                    if (v.field_count > 0) {
                        has_payload = true;
                        break;
                    }
                }

                if (has_payload) {
                    try appendSlice(allocator, output, "    union {\n");
                    for (st.variants) |v| {
                        if (v.field_count == 0) continue;
                        try appendFmt(allocator, output, "        kira_{s}_{s} {s};\n", .{ td.name, v.name, v.name });
                    }
                    try appendSlice(allocator, output, "    } data;\n");
                }

                try appendFmt(allocator, output, "}} kira_{s};\n\n", .{td.name});
            },
            .product_type => |pt| {
                try appendFmt(allocator, output, "typedef struct {{\n", .{});
                for (pt.fields) |f| {
                    const c_type = try kiraToCTypeAlloc(allocator, f.type_name, module);
                    defer if (c_type.allocated) allocator.free(c_type.c_type);
                    try appendFmt(allocator, output, "    {s} {s};\n", .{ c_type.c_type, f.name });
                }
                try appendFmt(allocator, output, "}} kira_{s};\n\n", .{td.name});
            },
        }
    }
}

/// Emit Klar extern declarations for ADT types.
fn emitKlarTypeDecls(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), module: *const ir.Module) !void {
    if (module.type_decls.items.len == 0) return;

    for (module.type_decls.items) |td| {
        switch (td.kind) {
            .sum_type => |st| {
                // Tag enum
                try appendFmt(allocator, output, "extern enum kira_{s}_Tag {{\n", .{td.name});
                for (st.variants) |v| {
                    try appendFmt(allocator, output, "    {s} = {d}\n", .{ v.name, v.tag });
                }
                try appendSlice(allocator, output, "}\n\n");

                // Variant payload structs
                for (st.variants) |v| {
                    if (v.field_count == 0) continue;
                    try appendFmt(allocator, output, "extern struct kira_{s}_{s} {{\n", .{ td.name, v.name });
                    for (v.field_types) |ft| {
                        try appendFmt(allocator, output, "    {s}: {s}\n", .{ ft.name, kiraToKlarType(ft.type_name) });
                    }
                    try appendSlice(allocator, output, "}\n\n");
                }

                // Main tagged union struct
                try appendFmt(allocator, output, "extern struct kira_{s} {{\n", .{td.name});
                try appendFmt(allocator, output, "    tag: kira_{s}_Tag\n", .{td.name});

                // Emit data field typed as the largest variant payload struct.
                // This ensures the Klar struct matches the C struct's ABI size.
                // Access other variants via unsafe ptr_cast.
                var largest_variant: ?[]const u8 = null;
                var largest_field_count: u32 = 0;
                for (st.variants) |v| {
                    if (v.field_count > largest_field_count) {
                        largest_field_count = v.field_count;
                        largest_variant = v.name;
                    }
                }
                if (largest_variant) |lv| {
                    try appendFmt(allocator, output, "    data: kira_{s}_{s}\n", .{ td.name, lv });
                }

                try appendSlice(allocator, output, "}\n\n");
            },
            .product_type => |pt| {
                try appendFmt(allocator, output, "extern struct kira_{s} {{\n", .{td.name});
                for (pt.fields) |f| {
                    try appendFmt(allocator, output, "    {s}: {s}\n", .{ f.name, kiraToKlarType(f.type_name) });
                }
                try appendSlice(allocator, output, "}\n\n");
            },
        }
    }
}

/// Check if a Kira type name is a floating-point type.
fn isFloatType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "f32") or
        std.mem.eql(u8, type_name, "f64") or
        std.mem.eql(u8, type_name, "float");
}

/// Check if a Kira type name is the string type.
fn isStringType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "string");
}

/// Generate C library wrapper functions that bridge between the typed C API
/// and the internal kira_int representation. Also emits kira_free().
/// Caller owns the returned slice.
pub fn generateLibraryWrappers(allocator: Allocator, module: *const ir.Module) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try appendSlice(allocator, &output, "\n/* Library API wrappers */\n\n");
    try appendSlice(allocator, &output, "void kira_free(void* ptr) { free(ptr); }\n\n");

    for (module.functions.items) |func| {
        const name = func.name orelse continue;
        if (std.mem.eql(u8, name, "main")) continue;
        try emitLibraryWrapper(allocator, &output, &func, module);
    }

    return output.toOwnedSlice(allocator);
}

/// Emit a single C wrapper function for a library-exported Kira function.
fn emitLibraryWrapper(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), func: *const ir.Function, module: *const ir.Module) !void {
    const name = func.name orelse return;
    const is_void_return = std.mem.eql(u8, func.return_type_name, "void");

    // Return type
    const ret_c = try kiraToCTypeAlloc(allocator, func.return_type_name, module);
    defer if (ret_c.allocated) allocator.free(ret_c.c_type);

    // Signature
    try appendFmt(allocator, output, "{s} {s}(", .{ ret_c.c_type, name });
    if (func.params.len == 0) {
        try appendSlice(allocator, output, "void");
    } else {
        for (func.params, 0..) |param, i| {
            if (i > 0) try appendSlice(allocator, output, ", ");
            const param_c = try kiraToCTypeAlloc(allocator, param.type_name, module);
            defer if (param_c.allocated) allocator.free(param_c.c_type);
            try appendFmt(allocator, output, "{s} {s}", .{ param_c.c_type, param.name });
        }
    }
    try appendSlice(allocator, output, ") {\n");

    // Convert float params to kira_int temps (widen f32 to double first)
    for (func.params, 0..) |param, i| {
        if (isFloatType(param.type_name)) {
            if (std.mem.eql(u8, param.type_name, "f32")) {
                try appendFmt(allocator, output, "    double _d{d} = (double){s}; kira_int _a{d}; memcpy(&_a{d}, &_d{d}, sizeof(double));\n", .{ i, param.name, i, i, i });
            } else {
                try appendFmt(allocator, output, "    kira_int _a{d}; memcpy(&_a{d}, &{s}, sizeof(double));\n", .{ i, i, param.name });
            }
        }
    }

    // Call internal function
    if (is_void_return) {
        try appendFmt(allocator, output, "    kira_{s}(", .{name});
    } else {
        try appendFmt(allocator, output, "    kira_int _r = kira_{s}(", .{name});
    }

    // Arguments with type conversions
    for (func.params, 0..) |param, i| {
        if (i > 0) try appendSlice(allocator, output, ", ");
        if (isFloatType(param.type_name)) {
            try appendFmt(allocator, output, "_a{d}", .{i});
        } else if (isStringType(param.type_name)) {
            try appendFmt(allocator, output, "(kira_int)(intptr_t){s}", .{param.name});
        } else {
            try appendFmt(allocator, output, "(kira_int){s}", .{param.name});
        }
    }
    try appendSlice(allocator, output, ");\n");

    // Convert return value (for f32, memcpy to double then narrow)
    if (!is_void_return) {
        if (isFloatType(func.return_type_name)) {
            if (std.mem.eql(u8, func.return_type_name, "f32")) {
                try appendSlice(allocator, output, "    double _ret_d; memcpy(&_ret_d, &_r, sizeof(double));\n    return (float)_ret_d;\n");
            } else {
                try appendFmt(allocator, output, "    {s} _ret; memcpy(&_ret, &_r, sizeof(double));\n    return _ret;\n", .{ret_c.c_type});
            }
        } else if (isStringType(func.return_type_name)) {
            try appendSlice(allocator, output, "    return (const char*)(intptr_t)_r;\n");
        } else {
            try appendFmt(allocator, output, "    return ({s})_r;\n", .{ret_c.c_type});
        }
    }

    try appendSlice(allocator, output, "}\n\n");
}

/// Emit Klar convenience wrappers for functions that use string types.
fn emitKlarStringWrappers(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), module: *const ir.Module) !void {
    var has_string_func = false;
    for (module.functions.items) |func| {
        const name = func.name orelse continue;
        if (std.mem.eql(u8, name, "main")) continue;

        var uses_string = isStringType(func.return_type_name);
        if (!uses_string) {
            for (func.params) |param| {
                if (isStringType(param.type_name)) {
                    uses_string = true;
                    break;
                }
            }
        }
        if (!uses_string) continue;

        if (!has_string_func) {
            try appendSlice(allocator, output, "\n// String convenience wrappers\n");
            has_string_func = true;
        }

        // Emit wrapper: fn name_str(params with string types) -> return_type
        try appendFmt(allocator, output, "fn {s}_str(", .{name});
        for (func.params, 0..) |param, i| {
            if (i > 0) try appendSlice(allocator, output, ", ");
            if (isStringType(param.type_name)) {
                try appendFmt(allocator, output, "{s}: string", .{param.name});
            } else {
                try appendFmt(allocator, output, "{s}: {s}", .{ param.name, kiraToKlarType(param.type_name) });
            }
        }
        if (isStringType(func.return_type_name)) {
            try appendSlice(allocator, output, ") -> string =\n");
        } else {
            try appendFmt(allocator, output, ") -> {s} =\n", .{kiraToKlarType(func.return_type_name)});
        }

        // Body: wrap call with string conversions
        try appendSlice(allocator, output, "    ");
        if (isStringType(func.return_type_name)) {
            try appendSlice(allocator, output, "String.from_cstr(");
        }
        try appendFmt(allocator, output, "{s}(", .{name});
        for (func.params, 0..) |param, i| {
            if (i > 0) try appendSlice(allocator, output, ", ");
            if (isStringType(param.type_name)) {
                try appendFmt(allocator, output, "String.to_cstr({s})", .{param.name});
            } else {
                try appendFmt(allocator, output, "{s}", .{param.name});
            }
        }
        try appendSlice(allocator, output, ")");
        if (isStringType(func.return_type_name)) {
            try appendSlice(allocator, output, ")");
        }
        try appendSlice(allocator, output, "\n\n");
    }
}

/// Generate a JSON type manifest describing all exported functions and types.
/// The manifest is machine-readable for tooling and AI agents.
/// Caller owns the returned slice.
pub fn generateManifestJSON(allocator: Allocator, module: *const ir.Module, module_name: []const u8) ![]u8 {
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);

    try appendSlice(allocator, &output, "{\n  \"module\": ");
    try appendJsonStringQuoted(allocator, &output, module_name);
    try appendSlice(allocator, &output, ",\n");

    // Functions
    try appendSlice(allocator, &output, "  \"functions\": [\n");
    var func_count: usize = 0;
    for (module.functions.items) |func| {
        const name = func.name orelse continue;
        if (std.mem.eql(u8, name, "main")) continue;

        if (func_count > 0) try appendSlice(allocator, &output, ",\n");
        try appendSlice(allocator, &output, "    {\n      \"name\": ");
        try appendJsonStringQuoted(allocator, &output, name);
        try appendSlice(allocator, &output, ",\n");

        // Parameters
        try appendSlice(allocator, &output, "      \"params\": [");
        for (func.params, 0..) |param, i| {
            if (i > 0) try appendSlice(allocator, &output, ", ");
            try appendSlice(allocator, &output, "{\"name\": ");
            try appendJsonStringQuoted(allocator, &output, param.name);
            try appendSlice(allocator, &output, ", \"type\": ");
            try appendJsonStringQuoted(allocator, &output, param.type_name);
            try output.append(allocator, '}');
        }
        try appendSlice(allocator, &output, "],\n");

        // Return type
        try appendSlice(allocator, &output, "      \"return_type\": ");
        try appendJsonStringQuoted(allocator, &output, func.return_type_name);
        try appendSlice(allocator, &output, "\n    }");
        func_count += 1;
    }
    try appendSlice(allocator, &output, "\n  ],\n");

    // Types
    try appendSlice(allocator, &output, "  \"types\": [\n");
    for (module.type_decls.items, 0..) |td, ti| {
        if (ti > 0) try appendSlice(allocator, &output, ",\n");
        try appendSlice(allocator, &output, "    {\n      \"name\": ");
        try appendJsonStringQuoted(allocator, &output, td.name);
        try appendSlice(allocator, &output, ",\n");

        switch (td.kind) {
            .sum_type => |st| {
                try appendSlice(allocator, &output, "      \"kind\": \"sum\",\n");
                try appendSlice(allocator, &output, "      \"variants\": [\n");
                for (st.variants, 0..) |v, vi| {
                    if (vi > 0) try appendSlice(allocator, &output, ",\n");
                    try appendSlice(allocator, &output, "        {\n          \"name\": ");
                    try appendJsonStringQuoted(allocator, &output, v.name);
                    try appendSlice(allocator, &output, ",\n");
                    try appendFmt(allocator, &output, "          \"tag\": {d},\n", .{v.tag});
                    try appendSlice(allocator, &output, "          \"fields\": [");
                    for (v.field_types, 0..) |ft, fi| {
                        if (fi > 0) try appendSlice(allocator, &output, ", ");
                        try appendSlice(allocator, &output, "{\"name\": ");
                        try appendJsonStringQuoted(allocator, &output, ft.name);
                        try appendSlice(allocator, &output, ", \"type\": ");
                        try appendJsonStringQuoted(allocator, &output, ft.type_name);
                        try output.append(allocator, '}');
                    }
                    try appendSlice(allocator, &output, "]\n        }");
                }
                try appendSlice(allocator, &output, "\n      ]\n");
            },
            .product_type => |pt| {
                try appendSlice(allocator, &output, "      \"kind\": \"product\",\n");
                try appendSlice(allocator, &output, "      \"fields\": [");
                for (pt.fields, 0..) |f, fi| {
                    if (fi > 0) try appendSlice(allocator, &output, ", ");
                    try appendSlice(allocator, &output, "{\"name\": ");
                    try appendJsonStringQuoted(allocator, &output, f.name);
                    try appendSlice(allocator, &output, ", \"type\": ");
                    try appendJsonStringQuoted(allocator, &output, f.type_name);
                    try output.append(allocator, '}');
                }
                try appendSlice(allocator, &output, "]\n");
            },
        }

        try appendSlice(allocator, &output, "    }");
    }
    try appendSlice(allocator, &output, "\n  ]\n");

    try appendSlice(allocator, &output, "}\n");

    return output.toOwnedSlice(allocator);
}

fn appendSlice(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try output.appendSlice(allocator, s);
}

fn appendFmt(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try output.appendSlice(allocator, formatted);
}

/// Append a JSON-escaped string value (the content between quotes).
/// Escapes `"` as `\"` and `\` as `\\`.
fn appendJsonString(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try output.appendSlice(allocator, "\\\""),
            '\\' => try output.appendSlice(allocator, "\\\\"),
            else => try output.append(allocator, c),
        }
    }
}

/// Append `"<escaped_value>"` to the output (quotes included).
fn appendJsonStringQuoted(allocator: Allocator, output: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try output.append(allocator, '"');
    try appendJsonString(allocator, output, s);
    try output.append(allocator, '"');
}

// --- Tests ---

test "kiraToCType mappings" {
    try std.testing.expectEqualStrings("int32_t", kiraToCType("i32"));
    try std.testing.expectEqualStrings("int64_t", kiraToCType("i64"));
    try std.testing.expectEqualStrings("double", kiraToCType("f64"));
    try std.testing.expectEqualStrings("bool", kiraToCType("bool"));
    try std.testing.expectEqualStrings("const char*", kiraToCType("string"));
    try std.testing.expectEqualStrings("void", kiraToCType("void"));
    try std.testing.expectEqualStrings("int64_t", kiraToCType("unknown"));
}

test "kiraToKlarType mappings" {
    try std.testing.expectEqualStrings("i32", kiraToKlarType("i32"));
    try std.testing.expectEqualStrings("f64", kiraToKlarType("f64"));
    try std.testing.expectEqualStrings("CStr", kiraToKlarType("string"));
}

test "generateHeader empty module" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const header = try generateHeader(allocator, &module, "mylib");
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "#ifndef KIRA_MYLIB_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "#define KIRA_MYLIB_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "#endif") != null);
}

test "generateHeader with function" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();
    var func = ir.Function.init(arena);
    func.name = "add";
    const params = try arena.alloc(ir.Function.Param, 2);
    params[0] = .{ .name = "a", .value_ref = 0 };
    params[1] = .{ .name = "b", .value_ref = 1 };
    func.params = params;
    try module.functions.append(arena, func);

    const header = try generateHeader(allocator, &module, "mathlib");
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "#ifndef KIRA_MATHLIB_H") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "int64_t add(int64_t a, int64_t b)") != null);
}

test "generateKlarExternBlock" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();
    var func = ir.Function.init(arena);
    func.name = "multiply";
    const params = try arena.alloc(ir.Function.Param, 2);
    params[0] = .{ .name = "x", .value_ref = 0 };
    params[1] = .{ .name = "y", .value_ref = 1 };
    func.params = params;
    try module.functions.append(arena, func);

    const block = try generateKlarExternBlock(allocator, &module);
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "extern {") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn multiply(x: i64, y: i64) -> i64") != null);
}

test "generateHeader with typed params (i32, f64, bool, string, void)" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // fn add(a: i32, b: i32) -> i32
    var func1 = ir.Function.init(arena);
    func1.name = "add";
    func1.return_type_name = "i32";
    const p1 = try arena.alloc(ir.Function.Param, 2);
    p1[0] = .{ .name = "a", .value_ref = 0, .type_name = "i32" };
    p1[1] = .{ .name = "b", .value_ref = 1, .type_name = "i32" };
    func1.params = p1;
    try module.functions.append(arena, func1);

    // fn scale(x: f64) -> f64
    var func2 = ir.Function.init(arena);
    func2.name = "scale";
    func2.return_type_name = "f64";
    const p2 = try arena.alloc(ir.Function.Param, 1);
    p2[0] = .{ .name = "x", .value_ref = 0, .type_name = "f64" };
    func2.params = p2;
    try module.functions.append(arena, func2);

    // fn greet(name: string) -> string
    var func3 = ir.Function.init(arena);
    func3.name = "greet";
    func3.return_type_name = "string";
    const p3 = try arena.alloc(ir.Function.Param, 1);
    p3[0] = .{ .name = "name", .value_ref = 0, .type_name = "string" };
    func3.params = p3;
    try module.functions.append(arena, func3);

    // fn is_valid(flag: bool) -> bool
    var func4 = ir.Function.init(arena);
    func4.name = "is_valid";
    func4.return_type_name = "bool";
    const p4 = try arena.alloc(ir.Function.Param, 1);
    p4[0] = .{ .name = "flag", .value_ref = 0, .type_name = "bool" };
    func4.params = p4;
    try module.functions.append(arena, func4);

    // fn reset() -> void
    var func5 = ir.Function.init(arena);
    func5.name = "reset";
    func5.return_type_name = "void";
    func5.params = &.{};
    try module.functions.append(arena, func5);

    const header = try generateHeader(allocator, &module, "typed");
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "int32_t add(int32_t a, int32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "double scale(double x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "const char* greet(const char* name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "bool is_valid(bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "void reset(void)") != null);
}

test "generateKlarExternBlock with typed params" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // fn add(a: i32, b: i32) -> i32
    var func1 = ir.Function.init(arena);
    func1.name = "add";
    func1.return_type_name = "i32";
    const p1 = try arena.alloc(ir.Function.Param, 2);
    p1[0] = .{ .name = "a", .value_ref = 0, .type_name = "i32" };
    p1[1] = .{ .name = "b", .value_ref = 1, .type_name = "i32" };
    func1.params = p1;
    try module.functions.append(arena, func1);

    // fn scale(x: f64) -> f64
    var func2 = ir.Function.init(arena);
    func2.name = "scale";
    func2.return_type_name = "f64";
    const p2 = try arena.alloc(ir.Function.Param, 1);
    p2[0] = .{ .name = "x", .value_ref = 0, .type_name = "f64" };
    func2.params = p2;
    try module.functions.append(arena, func2);

    // fn greet(name: string) -> string
    var func3 = ir.Function.init(arena);
    func3.name = "greet";
    func3.return_type_name = "string";
    const p3 = try arena.alloc(ir.Function.Param, 1);
    p3[0] = .{ .name = "name", .value_ref = 0, .type_name = "string" };
    func3.params = p3;
    try module.functions.append(arena, func3);

    // fn is_valid(flag: bool) -> bool
    var func4 = ir.Function.init(arena);
    func4.name = "is_valid";
    func4.return_type_name = "bool";
    const p4 = try arena.alloc(ir.Function.Param, 1);
    p4[0] = .{ .name = "flag", .value_ref = 0, .type_name = "bool" };
    func4.params = p4;
    try module.functions.append(arena, func4);

    // fn reset() -> void
    var func5 = ir.Function.init(arena);
    func5.name = "reset";
    func5.return_type_name = "void";
    func5.params = &.{};
    try module.functions.append(arena, func5);

    const block = try generateKlarExternBlock(allocator, &module);
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "fn add(a: i32, b: i32) -> i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn scale(x: f64) -> f64") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn greet(name: CStr) -> CStr") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn is_valid(flag: Bool) -> Bool") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn reset() -> Void") != null);
}

test "generateHeader with sum type Shape" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // type Shape = Circle(f64) | Rectangle(f64, f64) | Point
    _ = try module.addTypeDecl(.{
        .name = "Shape",
        .kind = .{ .sum_type = .{
            .variants = &[_]ir.VariantDecl{
                .{
                    .name = "Circle",
                    .tag = 0,
                    .field_count = 1,
                    .field_types = &[_]ir.FieldDecl{
                        .{ .name = "_0", .index = 0, .type_name = "f64" },
                    },
                },
                .{
                    .name = "Rectangle",
                    .tag = 1,
                    .field_count = 2,
                    .field_types = &[_]ir.FieldDecl{
                        .{ .name = "_0", .index = 0, .type_name = "f64" },
                        .{ .name = "_1", .index = 1, .type_name = "f64" },
                    },
                },
                .{ .name = "Point", .tag = 2, .field_count = 0 },
            },
        } },
    });

    // fn area(s: Shape) -> f64
    var func = ir.Function.init(arena);
    func.name = "area";
    func.return_type_name = "f64";
    const p = try arena.alloc(ir.Function.Param, 1);
    p[0] = .{ .name = "s", .value_ref = 0, .type_name = "Shape" };
    func.params = p;
    try module.functions.append(arena, func);

    const header = try generateHeader(allocator, &module, "shapes");
    defer allocator.free(header);

    // Tag enum
    try std.testing.expect(std.mem.indexOf(u8, header, "KIRA_Shape_Circle = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "KIRA_Shape_Rectangle = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "KIRA_Shape_Point = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Shape_Tag") != null);

    // Variant payload structs
    try std.testing.expect(std.mem.indexOf(u8, header, "double _0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Shape_Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Shape_Rectangle") != null);

    // Main tagged union
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Shape_Tag tag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "} kira_Shape;") != null);

    // Function using Shape type
    try std.testing.expect(std.mem.indexOf(u8, header, "double area(kira_Shape s)") != null);
}

test "generateHeader with product type Point" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    // type Point = { x: f64, y: f64 }
    _ = try module.addTypeDecl(.{
        .name = "Point",
        .kind = .{ .product_type = .{
            .fields = &[_]ir.FieldDecl{
                .{ .name = "x", .index = 0, .type_name = "f64" },
                .{ .name = "y", .index = 1, .type_name = "f64" },
            },
        } },
    });

    const header = try generateHeader(allocator, &module, "geo");
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "double x;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "double y;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "} kira_Point;") != null);
}

test "generateKlarExternBlock with sum type Shape" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // type Shape = Circle(f64) | Rectangle(f64, f64) | Point
    _ = try module.addTypeDecl(.{
        .name = "Shape",
        .kind = .{ .sum_type = .{
            .variants = &[_]ir.VariantDecl{
                .{
                    .name = "Circle",
                    .tag = 0,
                    .field_count = 1,
                    .field_types = &[_]ir.FieldDecl{
                        .{ .name = "_0", .index = 0, .type_name = "f64" },
                    },
                },
                .{
                    .name = "Rectangle",
                    .tag = 1,
                    .field_count = 2,
                    .field_types = &[_]ir.FieldDecl{
                        .{ .name = "_0", .index = 0, .type_name = "f64" },
                        .{ .name = "_1", .index = 1, .type_name = "f64" },
                    },
                },
                .{ .name = "Point", .tag = 2, .field_count = 0 },
            },
        } },
    });

    // fn make_circle(r: f64) -> Shape
    var func = ir.Function.init(arena);
    func.name = "make_circle";
    func.return_type_name = "Shape";
    const p = try arena.alloc(ir.Function.Param, 1);
    p[0] = .{ .name = "r", .value_ref = 0, .type_name = "f64" };
    func.params = p;
    try module.functions.append(arena, func);

    const block = try generateKlarExternBlock(allocator, &module);
    defer allocator.free(block);

    // Tag enum
    try std.testing.expect(std.mem.indexOf(u8, block, "extern enum kira_Shape_Tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Circle = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Rectangle = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "Point = 2") != null);

    // Variant payload structs
    try std.testing.expect(std.mem.indexOf(u8, block, "extern struct kira_Shape_Circle") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "_0: f64") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "extern struct kira_Shape_Rectangle") != null);

    // Main tagged union struct (data field uses largest variant for ABI size)
    try std.testing.expect(std.mem.indexOf(u8, block, "extern struct kira_Shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "tag: kira_Shape_Tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "data: kira_Shape_Rectangle") != null);

    // Function using Shape as return type
    try std.testing.expect(std.mem.indexOf(u8, block, "fn make_circle(r: f64) -> Shape") != null);
}

test "generateKlarExternBlock with product type" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    // type Point = { x: f64, y: f64 }
    _ = try module.addTypeDecl(.{
        .name = "Point",
        .kind = .{ .product_type = .{
            .fields = &[_]ir.FieldDecl{
                .{ .name = "x", .index = 0, .type_name = "f64" },
                .{ .name = "y", .index = 1, .type_name = "f64" },
            },
        } },
    });

    const block = try generateKlarExternBlock(allocator, &module);
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "extern struct kira_Point") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "x: f64") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "y: f64") != null);
}

test "kiraToKlarType maps user-defined types" {
    try std.testing.expectEqualStrings("Shape", kiraToKlarType("Shape"));
    try std.testing.expectEqualStrings("Point", kiraToKlarType("Point"));
    try std.testing.expectEqualStrings("Option", kiraToKlarType("Option"));
    // Primitives still work
    try std.testing.expectEqualStrings("i32", kiraToKlarType("i32"));
    try std.testing.expectEqualStrings("Bool", kiraToKlarType("bool"));
}

test "generateHeader sum type with unit-only variants (simple enum)" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    // type Color = Red | Green | Blue
    _ = try module.addTypeDecl(.{
        .name = "Color",
        .kind = .{ .sum_type = .{
            .variants = &[_]ir.VariantDecl{
                .{ .name = "Red", .tag = 0, .field_count = 0 },
                .{ .name = "Green", .tag = 1, .field_count = 0 },
                .{ .name = "Blue", .tag = 2, .field_count = 0 },
            },
        } },
    });

    const header = try generateHeader(allocator, &module, "colors");
    defer allocator.free(header);

    // Tag enum
    try std.testing.expect(std.mem.indexOf(u8, header, "KIRA_Color_Red = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "KIRA_Color_Green = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "KIRA_Color_Blue = 2") != null);

    // Should have tag but no union (all unit variants)
    try std.testing.expect(std.mem.indexOf(u8, header, "kira_Color_Tag tag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "union") == null);
    try std.testing.expect(std.mem.indexOf(u8, header, "} kira_Color;") != null);
}

test "generateHeader includes kira_free declaration" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const header = try generateHeader(allocator, &module, "mylib");
    defer allocator.free(header);

    try std.testing.expect(std.mem.indexOf(u8, header, "void kira_free(void* ptr);") != null);
}

test "generateKlarExternBlock includes kira_free" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const block = try generateKlarExternBlock(allocator, &module);
    defer allocator.free(block);

    try std.testing.expect(std.mem.indexOf(u8, block, "fn kira_free(ptr: Ptr) -> Void") != null);
}

test "generateLibraryWrappers with mixed types" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // fn add(a: i32, b: i32) -> i32
    var func1 = ir.Function.init(arena);
    func1.name = "add";
    func1.return_type_name = "i32";
    const p1 = try arena.alloc(ir.Function.Param, 2);
    p1[0] = .{ .name = "a", .value_ref = 0, .type_name = "i32" };
    p1[1] = .{ .name = "b", .value_ref = 1, .type_name = "i32" };
    func1.params = p1;
    try module.functions.append(arena, func1);

    // fn scale(x: f64) -> f64
    var func2 = ir.Function.init(arena);
    func2.name = "scale";
    func2.return_type_name = "f64";
    const p2 = try arena.alloc(ir.Function.Param, 1);
    p2[0] = .{ .name = "x", .value_ref = 0, .type_name = "f64" };
    func2.params = p2;
    try module.functions.append(arena, func2);

    // fn greet(name: string) -> string
    var func3 = ir.Function.init(arena);
    func3.name = "greet";
    func3.return_type_name = "string";
    const p3 = try arena.alloc(ir.Function.Param, 1);
    p3[0] = .{ .name = "name", .value_ref = 0, .type_name = "string" };
    func3.params = p3;
    try module.functions.append(arena, func3);

    // fn reset() -> void
    var func4 = ir.Function.init(arena);
    func4.name = "reset";
    func4.return_type_name = "void";
    func4.params = &.{};
    try module.functions.append(arena, func4);

    const wrappers = try generateLibraryWrappers(allocator, &module);
    defer allocator.free(wrappers);

    // kira_free
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "void kira_free(void* ptr) { free(ptr); }") != null);

    // Integer wrapper: simple cast
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "int32_t add(int32_t a, int32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "kira_add((kira_int)a, (kira_int)b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "return (int32_t)_r;") != null);

    // Float wrapper: memcpy conversion
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "double scale(double x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "memcpy(&_a0, &x, sizeof(double))") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "kira_scale(_a0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "memcpy(&_ret, &_r, sizeof(double))") != null);

    // String wrapper: intptr_t cast
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "const char* greet(const char* name)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "(kira_int)(intptr_t)name") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "return (const char*)(intptr_t)_r;") != null);

    // Void wrapper: no return
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "void reset(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "kira_reset()") != null);
}

test "generateKlarExternBlock with string wrappers" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // fn greet(name: string) -> string
    var func1 = ir.Function.init(arena);
    func1.name = "greet";
    func1.return_type_name = "string";
    const p1 = try arena.alloc(ir.Function.Param, 1);
    p1[0] = .{ .name = "name", .value_ref = 0, .type_name = "string" };
    func1.params = p1;
    try module.functions.append(arena, func1);

    // fn add(a: i32, b: i32) -> i32 (no string, no wrapper)
    var func2 = ir.Function.init(arena);
    func2.name = "add";
    func2.return_type_name = "i32";
    const p2 = try arena.alloc(ir.Function.Param, 2);
    p2[0] = .{ .name = "a", .value_ref = 0, .type_name = "i32" };
    p2[1] = .{ .name = "b", .value_ref = 1, .type_name = "i32" };
    func2.params = p2;
    try module.functions.append(arena, func2);

    const block = try generateKlarExternBlock(allocator, &module);
    defer allocator.free(block);

    // Extern declarations
    try std.testing.expect(std.mem.indexOf(u8, block, "fn greet(name: CStr) -> CStr") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn add(a: i32, b: i32) -> i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "fn kira_free(ptr: Ptr) -> Void") != null);

    // String wrapper generated for greet
    try std.testing.expect(std.mem.indexOf(u8, block, "fn greet_str(") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "name: string") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "String.from_cstr(") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "String.to_cstr(name)") != null);

    // No wrapper for add (no string types)
    try std.testing.expect(std.mem.indexOf(u8, block, "fn add_str(") == null);
}

test "generateManifestJSON with functions and types" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // fn add(a: i32, b: i32) -> i32
    var func = ir.Function.init(arena);
    func.name = "add";
    func.return_type_name = "i32";
    const params = try arena.alloc(ir.Function.Param, 2);
    params[0] = .{ .name = "a", .value_ref = 0, .type_name = "i32" };
    params[1] = .{ .name = "b", .value_ref = 1, .type_name = "i32" };
    func.params = params;
    try module.functions.append(arena, func);

    // fn greet(name: string) -> string
    var func2 = ir.Function.init(arena);
    func2.name = "greet";
    func2.return_type_name = "string";
    const p2 = try arena.alloc(ir.Function.Param, 1);
    p2[0] = .{ .name = "name", .value_ref = 0, .type_name = "string" };
    func2.params = p2;
    try module.functions.append(arena, func2);

    // type Shape = Circle(f64) | Point
    const variants = try arena.alloc(ir.VariantDecl, 2);
    const circle_fields = try arena.alloc(ir.FieldDecl, 1);
    circle_fields[0] = .{ .name = "radius", .index = 0, .type_name = "f64" };
    variants[0] = .{ .name = "Circle", .tag = 0, .field_count = 1, .field_types = circle_fields };
    variants[1] = .{ .name = "Point", .tag = 1, .field_count = 0 };
    try module.type_decls.append(arena, .{
        .name = "Shape",
        .kind = .{ .sum_type = .{ .variants = variants } },
    });

    const json = try generateManifestJSON(allocator, &module, "mylib");
    defer allocator.free(json);

    // Check module name
    try std.testing.expect(std.mem.indexOf(u8, json, "\"module\": \"mylib\"") != null);

    // Check functions
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"return_type\": \"i32\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"greet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"return_type\": \"string\"") != null);

    // Check types
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"Shape\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\": \"sum\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"Circle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"Point\"") != null);

    // main should be excluded
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\": \"main\"") == null);
}

test "generateManifestJSON escapes special characters" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    // Function with a name that contains JSON-special characters
    var func = ir.Function.init(arena);
    func.name = "say\"hello";
    func.return_type_name = "string";
    const params = try arena.alloc(ir.Function.Param, 1);
    params[0] = .{ .name = "x\\y", .value_ref = 0, .type_name = "i32" };
    func.params = params;
    try module.functions.append(arena, func);

    const json = try generateManifestJSON(allocator, &module, "test\\mod");
    defer allocator.free(json);

    // Backslash in module name is escaped
    try std.testing.expect(std.mem.indexOf(u8, json, "\"test\\\\mod\"") != null);
    // Quote in function name is escaped
    try std.testing.expect(std.mem.indexOf(u8, json, "\"say\\\"hello\"") != null);
    // Backslash in param name is escaped
    try std.testing.expect(std.mem.indexOf(u8, json, "\"x\\\\y\"") != null);
}

test "generateLibraryWrappers skips main function" {
    const allocator = std.testing.allocator;
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const arena = module.arena.allocator();

    var func = ir.Function.init(arena);
    func.name = "main";
    func.params = &.{};
    try module.functions.append(arena, func);

    const wrappers = try generateLibraryWrappers(allocator, &module);
    defer allocator.free(wrappers);

    // Should have kira_free but no main wrapper
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "kira_free") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrappers, "int64_t main(") == null);
}
