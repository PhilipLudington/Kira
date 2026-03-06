//! Interoperability modules for Kira.
//!
//! Provides C FFI support and Klar language interop via C ABI.

pub const klar = @import("klar.zig");
pub const c_ffi = @import("c_ffi.zig");

pub const ExternFunction = c_ffi.ExternFunction;

test {
    _ = klar;
    _ = c_ffi;
}
