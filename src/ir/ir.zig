//! Intermediate Representation for the Kira language.
//!
//! The IR sits between the AST and code generation. It uses SSA-style values
//! within basic blocks, making it suitable for analysis and optimization.
//! Key features:
//! - SSA-form values referenced by ValueRef
//! - Basic blocks with explicit terminators (branch, jump, return)
//! - Explicit closure capture lists
//! - Effect annotations preserved from the type checker
//! - ADT construction/matching lowered to tags and field access

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_types = @import("../ast/types.zig");
const tc_types = @import("../typechecker/types.zig");

// Note: PrimitiveType, EffectAnnotation, ResolvedType intentionally not re-exported
// (they belong to the AST/typechecker layer, not IR)

/// Unique identifier for an IR value (SSA name).
pub const ValueRef = u32;

/// Unique identifier for a basic block within a function.
pub const BlockId = u32;

/// Sentinel for "no value".
pub const no_value: ValueRef = std.math.maxInt(ValueRef);

/// Sentinel for "no block".
pub const no_block: BlockId = std.math.maxInt(BlockId);

/// A complete IR module — the unit of compilation.
/// All IR-internal allocations go through the arena, which is freed in bulk by deinit.
pub const Module = struct {
    /// Arena owns all IR-internal memory (instruction slices, params, type decl fields, etc.).
    arena: std.heap.ArenaAllocator,
    /// All functions in the module, indexed by FunctionId.
    functions: std.ArrayListUnmanaged(Function),
    /// Top-level constants (const declarations).
    constants: std.ArrayListUnmanaged(Constant),
    /// Type declarations (ADTs, records, aliases) for layout info.
    type_decls: std.ArrayListUnmanaged(TypeDecl),
    /// Name -> function index for lookup.
    function_map: std.StringArrayHashMapUnmanaged(u32),

    pub fn init(backing_allocator: Allocator) Module {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .functions = .{},
            .constants = .{},
            .type_decls = .{},
            .function_map = .{},
        };
    }

    /// Returns the arena allocator for all IR-internal allocations.
    pub fn allocator(self: *Module) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Module) void {
        // Arena frees everything in one shot: function internals, type decl slices,
        // instruction-internal slices (call.args, phi.incoming, etc.), params, captures.
        self.arena.deinit();
    }

    /// Add a function to the module. Returns its index.
    pub fn addFunction(self: *Module, func: Function) !u32 {
        const alloc = self.arena.allocator();
        const idx: u32 = @intCast(self.functions.items.len);
        try self.functions.append(alloc, func);
        if (func.name) |name| {
            try self.function_map.put(alloc, name, idx);
        }
        return idx;
    }

    /// Add a type declaration to the module. Returns its index.
    pub fn addTypeDecl(self: *Module, decl: TypeDecl) !u32 {
        const alloc = self.arena.allocator();
        const idx: u32 = @intCast(self.type_decls.items.len);
        try self.type_decls.append(alloc, decl);
        return idx;
    }

    /// Add a top-level constant. Returns its index.
    pub fn addConstant(self: *Module, constant: Constant) !u32 {
        const alloc = self.arena.allocator();
        const idx: u32 = @intCast(self.constants.items.len);
        try self.constants.append(alloc, constant);
        return idx;
    }

    /// Look up a function by name.
    pub fn getFunction(self: *const Module, name: []const u8) ?*const Function {
        const idx = self.function_map.get(name) orelse return null;
        return &self.functions.items[idx];
    }

    /// Format the entire module for debugging/display.
    pub fn dump(self: *const Module, writer: anytype) !void {
        for (self.type_decls.items, 0..) |td, i| {
            try writer.print("; type {d}: {s}\n", .{ i, td.name });
        }
        if (self.type_decls.items.len > 0) try writer.writeAll("\n");

        for (self.constants.items, 0..) |c, i| {
            try writer.print("const {d} ({s}) = ", .{ i, c.name });
            try c.value.dump(writer);
            try writer.writeAll("\n");
        }
        if (self.constants.items.len > 0) try writer.writeAll("\n");

        for (self.functions.items, 0..) |*f, i| {
            if (i > 0) try writer.writeAll("\n");
            try f.dump(writer);
        }
    }
};

/// An IR function definition.
pub const Function = struct {
    /// Function name (null for anonymous closures).
    name: ?[]const u8,
    /// Parameter names and types.
    params: []const Param,
    /// Captured variables for closures (empty for top-level functions).
    captures: []const Capture,
    /// Whether this is an effect function.
    is_effect: bool,
    /// Basic blocks that make up the function body.
    blocks: std.ArrayListUnmanaged(BasicBlock),
    /// All instructions across all blocks, referenced by index.
    instructions: std.ArrayListUnmanaged(Instruction),
    /// Entry block (always 0 for well-formed functions).
    entry_block: BlockId,

    pub const Param = struct {
        name: []const u8,
        /// The ValueRef assigned to this parameter.
        value_ref: ValueRef,
    };

    pub const Capture = struct {
        name: []const u8,
        /// The ValueRef assigned to the captured value inside this function.
        value_ref: ValueRef,
    };

    pub fn init(allocator: Allocator) Function {
        _ = allocator;
        return .{
            .name = null,
            .params = &.{},
            .captures = &.{},
            .is_effect = false,
            .blocks = .{},
            .instructions = .{},
            .entry_block = 0,
        };
    }

    pub fn deinit(self: *Function, allocator: Allocator) void {
        for (self.blocks.items) |*blk| {
            blk.instructions.deinit(allocator);
        }
        self.blocks.deinit(allocator);
        self.instructions.deinit(allocator);
    }

    /// Create a new basic block. Returns its BlockId.
    pub fn addBlock(self: *Function, allocator: Allocator) !BlockId {
        const id: BlockId = @intCast(self.blocks.items.len);
        try self.blocks.append(allocator, BasicBlock{
            .id = id,
            .instructions = .{},
            .terminator = .{ .unreachable_term = {} },
        });
        return id;
    }

    /// Append an instruction to the given block. Returns the ValueRef it produces.
    pub fn addInstruction(self: *Function, allocator: Allocator, block: BlockId, inst: Instruction) !ValueRef {
        const ref: ValueRef = @intCast(self.instructions.items.len);
        try self.instructions.append(allocator, inst);
        try self.blocks.items[block].instructions.append(allocator, ref);
        return ref;
    }

    /// Set the terminator for a block.
    pub fn setTerminator(self: *Function, block: BlockId, term: Terminator) void {
        self.blocks.items[block].terminator = term;
    }

    /// Get an instruction by ValueRef.
    pub fn getInstruction(self: *const Function, ref: ValueRef) *const Instruction {
        return &self.instructions.items[ref];
    }

    /// Format the function for debugging/display.
    pub fn dump(self: *const Function, writer: anytype) !void {
        if (self.is_effect) try writer.writeAll("effect ");
        try writer.writeAll("fn ");
        if (self.name) |n| try writer.writeAll(n) else try writer.writeAll("<anon>");
        try writer.writeAll("(");
        for (self.params, 0..) |p, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("%{d}: {s}", .{ p.value_ref, p.name });
        }
        try writer.writeAll(")");
        if (self.captures.len > 0) {
            try writer.writeAll(" captures [");
            for (self.captures, 0..) |c, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("%{d}: {s}", .{ c.value_ref, c.name });
            }
            try writer.writeAll("]");
        }
        try writer.writeAll(" {\n");
        for (self.blocks.items) |*blk| {
            try blk.dump(self, writer);
        }
        try writer.writeAll("}\n");
    }
};

/// A basic block — a straight-line sequence of instructions ending with a terminator.
pub const BasicBlock = struct {
    id: BlockId,
    /// Indices into the parent Function's instruction list.
    instructions: std.ArrayListUnmanaged(ValueRef),
    /// How control leaves this block.
    terminator: Terminator,

    pub fn dump(self: *const BasicBlock, func: *const Function, writer: anytype) !void {
        try writer.print("  bb{d}:\n", .{self.id});
        for (self.instructions.items) |ref| {
            const inst = func.getInstruction(ref);
            try writer.print("    %{d} = ", .{ref});
            try inst.dump(writer);
            try writer.writeAll("\n");
        }
        try writer.writeAll("    ");
        try self.terminator.dump(writer);
        try writer.writeAll("\n");
    }
};

/// An SSA instruction that produces a value.
pub const Instruction = struct {
    op: Op,

    pub const Op = union(enum) {
        // -- Literals / Constants --
        /// Integer constant.
        const_int: ConstInt,
        /// Float constant.
        const_float: f64,
        /// String constant.
        const_string: []const u8,
        /// Character constant.
        const_char: u21,
        /// Boolean constant.
        const_bool: bool,
        /// Void / unit value.
        const_void: void,

        // -- Arithmetic --
        /// Integer binary operation.
        int_binop: BinOp,
        /// Float binary operation.
        float_binop: BinOp,
        /// Integer negation.
        int_neg: ValueRef,
        /// Float negation.
        float_neg: ValueRef,

        // -- Comparison --
        /// Compare two values.
        cmp: CmpOp,

        // -- Logic --
        /// Logical not.
        log_not: ValueRef,

        // -- Conversions --
        /// Integer-to-float conversion.
        int_to_float: ValueRef,
        /// Float-to-integer conversion.
        float_to_int: ValueRef,
        /// Value to string (for interpolation / Show).
        to_string: ValueRef,

        // -- Variables / Memory --
        /// Create a mutable variable slot (for `var` bindings).
        alloc_var: AllocVar,
        /// Load from a mutable variable.
        load_var: ValueRef,
        /// Store to a mutable variable. Produces void.
        store_var: StoreVar,

        // -- Aggregates --
        /// Construct a tuple.
        make_tuple: []const ValueRef,
        /// Construct an array.
        make_array: []const ValueRef,
        /// Construct a record.
        make_record: MakeRecord,
        /// Construct an ADT variant.
        make_variant: MakeVariant,
        /// Access a tuple element by index.
        tuple_get: TupleGet,
        /// Access a record field by name.
        field_get: FieldGet,
        /// Access an array element by index value.
        index_get: IndexGet,
        /// Set a record field (produces new record or mutates in-place for var).
        field_set: FieldSet,
        /// Set an array element by index.
        index_set: IndexSet,
        /// Get the tag of an ADT variant (for match lowering).
        get_tag: ValueRef,
        /// Extract the payload of an ADT variant.
        get_payload: GetPayload,

        // -- Functions / Calls --
        /// Call a function value with arguments.
        call: Call,
        /// Create a closure (function + captured values).
        make_closure: MakeClosure,

        // -- Option / Result wrappers --
        /// Wrap value in Some.
        wrap_some: ValueRef,
        /// Create None.
        wrap_none: void,
        /// Wrap value in Ok.
        wrap_ok: ValueRef,
        /// Wrap value in Err.
        wrap_err: ValueRef,
        /// Unwrap Option/Result (panics on None/Err — used after guard checks).
        unwrap: ValueRef,

        // -- String operations --
        /// Concatenate strings.
        str_concat: StrConcat,

        // -- Parameters / Captures --
        /// Function parameter (reserves ValueRef slot in instruction list).
        param: u32,
        /// Captured variable (reserves ValueRef slot in instruction list).
        capture: u32,

        // -- Method dispatch --
        /// Method call on an object (unresolved dispatch).
        method_call: MethodCall,

        // -- Phi node (SSA) --
        /// Phi function: merges values from different predecessor blocks.
        phi: Phi,
    };

    pub const ConstInt = struct {
        value: i128,
    };

    pub const BinOp = struct {
        op: BinaryOp,
        left: ValueRef,
        right: ValueRef,
    };

    pub const BinaryOp = enum {
        add,
        sub,
        mul,
        div,
        mod,
    };

    pub const CmpOp = struct {
        op: CmpKind,
        left: ValueRef,
        right: ValueRef,
    };

    pub const CmpKind = enum {
        eq,
        ne,
        lt,
        le,
        gt,
        ge,
    };

    pub const AllocVar = struct {
        name: []const u8,
        init_value: ?ValueRef,
    };

    pub const StoreVar = struct {
        target: ValueRef,
        value: ValueRef,
    };

    pub const MakeRecord = struct {
        type_name: ?[]const u8,
        field_names: []const []const u8,
        field_values: []const ValueRef,
    };

    pub const MakeVariant = struct {
        type_name: ?[]const u8,
        variant_name: []const u8,
        payload: ?[]const ValueRef,
    };

    pub const TupleGet = struct {
        tuple: ValueRef,
        index: u32,
    };

    pub const FieldGet = struct {
        object: ValueRef,
        field: []const u8,
    };

    pub const IndexGet = struct {
        object: ValueRef,
        index: ValueRef,
    };

    pub const FieldSet = struct {
        object: ValueRef,
        field: []const u8,
        value: ValueRef,
    };

    pub const IndexSet = struct {
        object: ValueRef,
        index: ValueRef,
        value: ValueRef,
    };

    pub const GetPayload = struct {
        variant: ValueRef,
        field_index: u32,
    };

    pub const Call = struct {
        callee: ValueRef,
        args: []const ValueRef,
    };

    pub const MakeClosure = struct {
        /// Index into the module's function list.
        function_index: u32,
        captures: []const ValueRef,
    };

    pub const MethodCall = struct {
        object: ValueRef,
        method: []const u8,
        args: []const ValueRef,
    };

    pub const StrConcat = struct {
        parts: []const ValueRef,
    };

    pub const Phi = struct {
        incoming: []const PhiIncoming,
    };

    pub const PhiIncoming = struct {
        block: BlockId,
        value: ValueRef,
    };

    /// Format an instruction for debugging/display.
    pub fn dump(self: *const Instruction, writer: anytype) !void {
        switch (self.op) {
            .const_int => |c| try writer.print("const_int {d}", .{c.value}),
            .const_float => |f| try writer.print("const_float {d}", .{f}),
            .const_string => |s| try writer.print("const_string \"{s}\"", .{s}),
            .const_char => |c| try writer.print("const_char {d}", .{c}),
            .const_bool => |b| try writer.print("const_bool {}", .{b}),
            .const_void => try writer.writeAll("const_void"),
            .int_binop => |b| try writer.print("int_{s} %{d}, %{d}", .{ @tagName(b.op), b.left, b.right }),
            .float_binop => |b| try writer.print("float_{s} %{d}, %{d}", .{ @tagName(b.op), b.left, b.right }),
            .int_neg => |v| try writer.print("int_neg %{d}", .{v}),
            .float_neg => |v| try writer.print("float_neg %{d}", .{v}),
            .cmp => |c| try writer.print("cmp_{s} %{d}, %{d}", .{ @tagName(c.op), c.left, c.right }),
            .log_not => |v| try writer.print("log_not %{d}", .{v}),
            .int_to_float => |v| try writer.print("int_to_float %{d}", .{v}),
            .float_to_int => |v| try writer.print("float_to_int %{d}", .{v}),
            .to_string => |v| try writer.print("to_string %{d}", .{v}),
            .alloc_var => |a| {
                try writer.print("alloc_var \"{s}\"", .{a.name});
                if (a.init_value) |iv| try writer.print(" = %{d}", .{iv});
            },
            .load_var => |v| try writer.print("load_var %{d}", .{v}),
            .store_var => |s| try writer.print("store_var %{d}, %{d}", .{ s.target, s.value }),
            .make_tuple => |elems| {
                try writer.writeAll("make_tuple (");
                for (elems, 0..) |e, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("%{d}", .{e});
                }
                try writer.writeAll(")");
            },
            .make_array => |elems| {
                try writer.writeAll("make_array [");
                for (elems, 0..) |e, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("%{d}", .{e});
                }
                try writer.writeAll("]");
            },
            .make_record => |r| {
                try writer.writeAll("make_record ");
                if (r.type_name) |tn| try writer.print("{s} ", .{tn});
                try writer.writeAll("{ ");
                for (r.field_names, r.field_values, 0..) |name, val, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{s}: %{d}", .{ name, val });
                }
                try writer.writeAll(" }");
            },
            .make_variant => |v| {
                try writer.print("make_variant {s}", .{v.variant_name});
                if (v.payload) |p| {
                    try writer.writeAll("(");
                    for (p, 0..) |val, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.print("%{d}", .{val});
                    }
                    try writer.writeAll(")");
                }
            },
            .tuple_get => |t| try writer.print("tuple_get %{d}.{d}", .{ t.tuple, t.index }),
            .field_get => |f| try writer.print("field_get %{d}.{s}", .{ f.object, f.field }),
            .index_get => |idx| try writer.print("index_get %{d}[%{d}]", .{ idx.object, idx.index }),
            .field_set => |f| try writer.print("field_set %{d}.{s} = %{d}", .{ f.object, f.field, f.value }),
            .index_set => |idx| try writer.print("index_set %{d}[%{d}] = %{d}", .{ idx.object, idx.index, idx.value }),
            .get_tag => |v| try writer.print("get_tag %{d}", .{v}),
            .get_payload => |p| try writer.print("get_payload %{d}.{d}", .{ p.variant, p.field_index }),
            .call => |c| {
                try writer.print("call %{d}(", .{c.callee});
                for (c.args, 0..) |a, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("%{d}", .{a});
                }
                try writer.writeAll(")");
            },
            .make_closure => |c| {
                try writer.print("make_closure func#{d} [", .{c.function_index});
                for (c.captures, 0..) |cap, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("%{d}", .{cap});
                }
                try writer.writeAll("]");
            },
            .wrap_some => |v| try writer.print("wrap_some %{d}", .{v}),
            .wrap_none => try writer.writeAll("wrap_none"),
            .wrap_ok => |v| try writer.print("wrap_ok %{d}", .{v}),
            .wrap_err => |v| try writer.print("wrap_err %{d}", .{v}),
            .unwrap => |v| try writer.print("unwrap %{d}", .{v}),
            .str_concat => |s| {
                try writer.writeAll("str_concat [");
                for (s.parts, 0..) |p, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("%{d}", .{p});
                }
                try writer.writeAll("]");
            },
            .param => |idx| try writer.print("param {d}", .{idx}),
            .capture => |idx| try writer.print("capture {d}", .{idx}),
            .method_call => |mc| {
                try writer.print("method_call %{d}.{s}(", .{ mc.object, mc.method });
                for (mc.args, 0..) |a, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("%{d}", .{a});
                }
                try writer.writeAll(")");
            },
            .phi => |p| {
                try writer.writeAll("phi ");
                for (p.incoming, 0..) |inc, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("[bb{d}: %{d}]", .{ inc.block, inc.value });
                }
            },
        }
    }
};

/// Block terminators — how control leaves a basic block.
pub const Terminator = union(enum) {
    /// Return from the function (with optional value).
    ret: ?ValueRef,
    /// Unconditional jump to another block.
    jump: BlockId,
    /// Conditional branch.
    branch: Branch,
    /// Multi-way branch on an integer tag (for match lowering).
    switch_tag: SwitchTag,
    /// Block not yet terminated (error if still present after lowering).
    unreachable_term: void,

    pub const Branch = struct {
        condition: ValueRef,
        then_block: BlockId,
        else_block: BlockId,
    };

    pub const SwitchTag = struct {
        value: ValueRef,
        /// Tag value -> target block.
        cases: []const SwitchCase,
        /// Default block if no case matches.
        default: BlockId,
    };

    pub const SwitchCase = struct {
        tag: i128,
        block: BlockId,
    };

    /// Format a terminator for debugging/display.
    pub fn dump(self: *const Terminator, writer: anytype) !void {
        switch (self.*) {
            .ret => |v| {
                try writer.writeAll("ret");
                if (v) |val| try writer.print(" %{d}", .{val});
            },
            .jump => |b| try writer.print("jump bb{d}", .{b}),
            .branch => |br| try writer.print("branch %{d}, bb{d}, bb{d}", .{ br.condition, br.then_block, br.else_block }),
            .switch_tag => |sw| {
                try writer.print("switch %{d} [", .{sw.value});
                for (sw.cases, 0..) |c, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d} -> bb{d}", .{ c.tag, c.block });
                }
                try writer.print("] default bb{d}", .{sw.default});
            },
            .unreachable_term => try writer.writeAll("unreachable"),
        }
    }
};

/// A top-level constant value.
pub const Constant = struct {
    name: []const u8,
    value: ConstValue,
};

/// Compile-time constant values (a subset of what Instruction can produce).
pub const ConstValue = union(enum) {
    integer: i128,
    float: f64,
    string: []const u8,
    char: u21,
    boolean: bool,
    void_val: void,

    pub fn dump(self: *const ConstValue, writer: anytype) !void {
        switch (self.*) {
            .integer => |v| try writer.print("{d}", .{v}),
            .float => |v| try writer.print("{d}", .{v}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .char => |c| try writer.print("'{d}'", .{c}),
            .boolean => |b| try writer.print("{}", .{b}),
            .void_val => try writer.writeAll("void"),
        }
    }
};

/// IR-level type declaration (layout information for ADTs and records).
pub const TypeDecl = struct {
    name: []const u8,
    kind: TypeDeclKind,
};

pub const TypeDeclKind = union(enum) {
    /// Sum type with named variants. Each variant has an implicit tag.
    sum_type: SumTypeDecl,
    /// Product type (record) with named fields.
    product_type: ProductTypeDecl,
};

pub const SumTypeDecl = struct {
    variants: []const VariantDecl,
};

pub const VariantDecl = struct {
    name: []const u8,
    /// Implicit tag value for this variant.
    tag: u32,
    /// Number of payload fields (0 for unit variants like None).
    field_count: u32,
};

pub const ProductTypeDecl = struct {
    fields: []const FieldDecl,
};

pub const FieldDecl = struct {
    name: []const u8,
    index: u32,
};

// ============================================================
// Tests
// ============================================================

test "Module create and add function" {
    const backing = std.testing.allocator;
    var module = Module.init(backing);
    defer module.deinit();

    const alloc = module.allocator();
    var func = Function.init(alloc);
    func.name = "main";
    func.is_effect = true;

    const entry = try func.addBlock(alloc);
    try std.testing.expectEqual(@as(BlockId, 0), entry);

    // Add a constant instruction
    const ref = try func.addInstruction(alloc, entry, .{
        .op = .{ .const_int = .{ .value = 42 } },
    });
    try std.testing.expectEqual(@as(ValueRef, 0), ref);

    // Set terminator
    func.setTerminator(entry, .{ .ret = ref });

    const idx = try module.addFunction(func);
    try std.testing.expectEqual(@as(u32, 0), idx);

    // Look up by name
    const found = module.getFunction("main");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("main", found.?.name.?);
}

test "Instruction dump produces readable output" {
    const backing = std.testing.allocator;
    var module = Module.init(backing);
    defer module.deinit();

    const alloc = module.allocator();
    var func = Function.init(alloc);
    func.name = "add";
    const blk = try func.addBlock(alloc);

    // %0 = const_int 10
    const a = try func.addInstruction(alloc, blk, .{
        .op = .{ .const_int = .{ .value = 10 } },
    });
    // %1 = const_int 20
    const b = try func.addInstruction(alloc, blk, .{
        .op = .{ .const_int = .{ .value = 20 } },
    });
    // %2 = int_add %0, %1
    const c = try func.addInstruction(alloc, blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = a, .right = b } },
    });
    func.setTerminator(blk, .{ .ret = c });

    _ = try module.addFunction(func);

    // Dump to buffer and verify it contains expected strings
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(backing);
    try module.dump(buf.writer(backing));

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "const_int 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "const_int 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "int_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ret %2") != null);
}

test "BasicBlock with branch terminator" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const entry = try func.addBlock(allocator);
    const then_blk = try func.addBlock(allocator);
    const else_blk = try func.addBlock(allocator);

    const cond = try func.addInstruction(allocator, entry, .{
        .op = .{ .const_bool = true },
    });

    func.setTerminator(entry, .{
        .branch = .{
            .condition = cond,
            .then_block = then_blk,
            .else_block = else_blk,
        },
    });

    const term = func.blocks.items[entry].terminator;
    try std.testing.expect(term == .branch);
    try std.testing.expectEqual(then_blk, term.branch.then_block);
    try std.testing.expectEqual(else_blk, term.branch.else_block);
}

test "Phi node construction" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const bb0 = try func.addBlock(allocator);
    const bb1 = try func.addBlock(allocator);
    const bb2 = try func.addBlock(allocator);

    const val_a = try func.addInstruction(allocator, bb0, .{
        .op = .{ .const_int = .{ .value = 1 } },
    });
    const val_b = try func.addInstruction(allocator, bb1, .{
        .op = .{ .const_int = .{ .value = 2 } },
    });

    const incoming = [_]Instruction.PhiIncoming{
        .{ .block = bb0, .value = val_a },
        .{ .block = bb1, .value = val_b },
    };
    const phi_ref = try func.addInstruction(allocator, bb2, .{
        .op = .{ .phi = .{ .incoming = &incoming } },
    });

    const inst = func.getInstruction(phi_ref);
    try std.testing.expect(inst.op == .phi);
    try std.testing.expectEqual(@as(usize, 2), inst.op.phi.incoming.len);
}

test "MakeVariant and GetPayload instructions" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const blk = try func.addBlock(allocator);

    // %0 = const_int 42
    const payload_val = try func.addInstruction(allocator, blk, .{
        .op = .{ .const_int = .{ .value = 42 } },
    });

    // %1 = make_variant Some(42)
    const payload_refs = [_]ValueRef{payload_val};
    const variant = try func.addInstruction(allocator, blk, .{
        .op = .{ .make_variant = .{
            .type_name = "Option",
            .variant_name = "Some",
            .payload = &payload_refs,
        } },
    });

    // %2 = get_tag %1
    const tag = try func.addInstruction(allocator, blk, .{
        .op = .{ .get_tag = variant },
    });

    // %3 = get_payload %1.0
    const extracted = try func.addInstruction(allocator, blk, .{
        .op = .{ .get_payload = .{ .variant = variant, .field_index = 0 } },
    });

    try std.testing.expectEqual(@as(ValueRef, 2), tag);
    try std.testing.expectEqual(@as(ValueRef, 3), extracted);
}

test "Closure with captures" {
    const backing = std.testing.allocator;
    var module = Module.init(backing);
    defer module.deinit();

    const alloc = module.allocator();

    // Inner function (the closure body)
    var inner = Function.init(alloc);
    inner.name = "adder_closure";
    const inner_params = [_]Function.Param{.{ .name = "y", .value_ref = 0 }};
    const inner_captures = [_]Function.Capture{.{ .name = "x", .value_ref = 1 }};
    inner.params = &inner_params;
    inner.captures = &inner_captures;
    const inner_blk = try inner.addBlock(alloc);
    const p_y = try inner.addInstruction(alloc, inner_blk, .{
        .op = .{ .const_int = .{ .value = 0 } }, // placeholder
    });
    const c_x = try inner.addInstruction(alloc, inner_blk, .{
        .op = .{ .const_int = .{ .value = 0 } }, // placeholder
    });
    const sum = try inner.addInstruction(alloc, inner_blk, .{
        .op = .{ .int_binop = .{ .op = .add, .left = c_x, .right = p_y } },
    });
    inner.setTerminator(inner_blk, .{ .ret = sum });
    const inner_idx = try module.addFunction(inner);

    // Outer function
    var outer = Function.init(alloc);
    outer.name = "make_adder";
    const outer_blk = try outer.addBlock(alloc);
    const x_val = try outer.addInstruction(alloc, outer_blk, .{
        .op = .{ .const_int = .{ .value = 10 } },
    });
    const capture_refs = [_]ValueRef{x_val};
    const closure = try outer.addInstruction(alloc, outer_blk, .{
        .op = .{ .make_closure = .{
            .function_index = inner_idx,
            .captures = &capture_refs,
        } },
    });
    outer.setTerminator(outer_blk, .{ .ret = closure });
    _ = try module.addFunction(outer);

    try std.testing.expectEqual(@as(usize, 2), module.functions.items.len);
}

test "SwitchTag terminator for match lowering" {
    const allocator = std.testing.allocator;

    var func = Function.init(allocator);
    defer func.deinit(allocator);

    const entry = try func.addBlock(allocator);
    const case_some = try func.addBlock(allocator);
    const case_none = try func.addBlock(allocator);
    const default_blk = try func.addBlock(allocator);

    const tag_val = try func.addInstruction(allocator, entry, .{
        .op = .{ .const_int = .{ .value = 0 } },
    });

    const cases = [_]Terminator.SwitchCase{
        .{ .tag = 0, .block = case_some },
        .{ .tag = 1, .block = case_none },
    };
    func.setTerminator(entry, .{
        .switch_tag = .{
            .value = tag_val,
            .cases = &cases,
            .default = default_blk,
        },
    });

    const term = func.blocks.items[entry].terminator;
    try std.testing.expect(term == .switch_tag);
    try std.testing.expectEqual(@as(usize, 2), term.switch_tag.cases.len);
}

test "Module dump round-trip" {
    const backing = std.testing.allocator;
    var module = Module.init(backing);
    defer module.deinit();

    const alloc = module.allocator();

    // Add a type decl
    _ = try module.addTypeDecl(.{
        .name = "Option",
        .kind = .{ .sum_type = .{
            .variants = &[_]VariantDecl{
                .{ .name = "Some", .tag = 0, .field_count = 1 },
                .{ .name = "None", .tag = 1, .field_count = 0 },
            },
        } },
    });

    // Add a constant
    _ = try module.addConstant(.{
        .name = "MAX",
        .value = .{ .integer = 100 },
    });

    // Add a function
    var func = Function.init(alloc);
    func.name = "identity";
    const blk = try func.addBlock(alloc);
    const val = try func.addInstruction(alloc, blk, .{
        .op = .{ .const_int = .{ .value = 7 } },
    });
    func.setTerminator(blk, .{ .ret = val });
    _ = try module.addFunction(func);

    // Dump and check it doesn't crash / produces output
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(backing);
    try module.dump(buf.writer(backing));
    try std.testing.expect(buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Option") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "MAX") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "identity") != null);
}
