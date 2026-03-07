//! Runtime support library for compiled Kira code.
//!
//! Provides the memory representations and operations needed by native code:
//! - ADT values (tagged unions with payload fields)
//! - Closures (function pointer + captured environment)
//! - Memory management (allocation, garbage collection)

pub const adt = @import("adt.zig");
pub const closure = @import("closure.zig");
pub const gc = @import("gc.zig");

pub const AdtValue = adt.AdtValue;
pub const KiraValue = adt.KiraValue;
pub const AdtTypeDescriptor = adt.AdtTypeDescriptor;
pub const VariantDescriptor = adt.VariantDescriptor;
pub const TypeRegistry = adt.TypeRegistry;
pub const ArrayValue = adt.ArrayValue;
pub const Closure = closure.Closure;
pub const PartialApplication = closure.PartialApplication;
pub const GcAllocator = gc.GcAllocator;
pub const ManagedObject = gc.ManagedObject;
pub const GcHeader = gc.GcHeader;

test {
    _ = adt;
    _ = closure;
    _ = gc;
}
