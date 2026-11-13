// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! MicroCommander jádro (salcore) – přepis jádra Altap/Open Salamanderu do Rustu.
//!
//! Architektura podle zadání:
//! - **Jádro** (tento crate): souborové operace, virtuální souborové systémy,
//!   archivy, FTP/SFTP a hledání – jediné místo s veškerou logikou.
//! - **Tenké UI** (Swift/AppKit na macOS): volá jádro přes C ABI (`ffi` modul).
//!
//! Původní C++ zdrojáky Windows verze jsou v adresáři `samandarin/` a slouží
//! jako reference chování (masky, VFS koncept, operace); nejsou portovány 1:1.

pub mod error;
pub mod ffi;
pub mod find;
pub mod ftp;
pub mod local;
pub mod mask;
pub mod ops;
pub mod pack;
pub mod sftp;
pub mod tarfs;
pub mod vfs;
pub mod zipfs;

pub use error::{SalError, SalResult};
pub use local::LocalFs;
pub use vfs::{Vfs, VfsItem, VfsItemKind, VfsKind};

/// Verze jádra – vrací se přes FFI do UI (About dialog).
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
