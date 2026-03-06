//! Project configuration module for Kira.
//!
//! Provides TOML parsing and project configuration loading.

pub const toml = @import("toml.zig");
pub const project = @import("project.zig");

pub const ProjectConfig = project.ProjectConfig;
pub const ValidationError = project.ValidationError;
pub const TomlTable = toml.TomlTable;
pub const TomlParseError = toml.ParseError;
pub const Dependency = toml.Dependency;
pub const VersionConstraint = toml.VersionConstraint;

test {
    _ = toml;
    _ = project;
}
