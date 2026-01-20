//! Module system for the Kira language.
//!
//! This module provides cross-file module loading capabilities:
//! - ModuleLoader: Loads modules from separate .ki files
//! - LoadError: Error types for module loading
//! - LoadedModule: Information about loaded modules

const std = @import("std");

pub const loader = @import("loader.zig");

// Re-export main types
pub const ModuleLoader = loader.ModuleLoader;
pub const LoadError = loader.LoadError;
pub const LoadedModule = loader.LoadedModule;

test {
    _ = @import("loader.zig");
}
