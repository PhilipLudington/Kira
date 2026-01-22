//! Project configuration module for Kira.
//!
//! Provides TOML parsing and project configuration loading.

pub const toml = @import("toml.zig");
pub const project = @import("project.zig");

pub const ProjectConfig = project.ProjectConfig;
pub const TomlTable = toml.TomlTable;
pub const TomlParseError = toml.ParseError;

test {
    _ = toml;
    _ = project;
}
