// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Jednotné chyby jádra MicroCommanderu.
//!
//! Jádro vrací `SalError` ze všech operací; FFI vrstva je převádí na
//! numerické kódy a texty, UI podle nich rozhoduje (např. zda se zeptat
//! na přepsání existujícího souboru).

use std::fmt;
use std::io;

/// Kód chyby předávaný přes FFI. Kladná hodnota 1 znamená zrušení
/// operace uživatelem, záporné hodnoty jsou běžné chyby.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SalError {
    /// Operaci zrušil uživatel (není to selhání).
    Cancelled,
    /// Cesta nebo soubor neexistuje.
    NotFound,
    /// Cílový soubor/adresář už existuje.
    AlreadyExists,
    /// Adresář není prázdný (např. při mazání bez rekurze).
    NotEmpty,
    /// Přístup odepřen / nedostatečná práva.
    PermissionDenied,
    /// Adresář se nepodařilo vytvořit.
    CreateDirFailed,
    /// Šifrovaná položka archivu – je potřeba zadat heslo.
    PasswordRequired,
    /// Zadané heslo k archivu je chybné.
    InvalidPassword,
    /// Obecná vstupně-výstupní nebo síťová chyba.
    Io(String),
}

/// Numerické kódy chyb pro FFI (musí odpovídat konstantám v microcommander.h).
pub const SAL_ERR_CANCELLED: i32 = 1;
/// Úspěch (nula) – používá FFI vrstva.
pub const SAL_OK: i32 = 0;
pub const SAL_ERR_GENERIC: i32 = -1;
pub const SAL_ERR_NOT_FOUND: i32 = -2;
pub const SAL_ERR_EXISTS: i32 = -3;
pub const SAL_ERR_NOT_EMPTY: i32 = -4;
pub const SAL_ERR_PERMISSION: i32 = -5;
pub const SAL_ERR_CREATE_DIR: i32 = -6;
pub const SAL_ERR_PASSWORD_REQUIRED: i32 = -7;
pub const SAL_ERR_BAD_PASSWORD: i32 = -8;

impl SalError {
    /// Převede chybu na číselný kód pro FFI vrstvu.
    pub fn code(&self) -> i32 {
        match self {
            SalError::Cancelled => SAL_ERR_CANCELLED,
            SalError::NotFound => SAL_ERR_NOT_FOUND,
            SalError::AlreadyExists => SAL_ERR_EXISTS,
            SalError::NotEmpty => SAL_ERR_NOT_EMPTY,
            SalError::PermissionDenied => SAL_ERR_PERMISSION,
            SalError::CreateDirFailed => SAL_ERR_CREATE_DIR,
            SalError::PasswordRequired => SAL_ERR_PASSWORD_REQUIRED,
            SalError::InvalidPassword => SAL_ERR_BAD_PASSWORD,
            SalError::Io(_) => SAL_ERR_GENERIC,
        }
    }
}

impl fmt::Display for SalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SalError::Cancelled => write!(f, "Operace byla zrušena."),
            SalError::NotFound => write!(f, "Soubor nebo adresář nebyl nalezen."),
            SalError::AlreadyExists => write!(f, "Cíl už existuje."),
            SalError::NotEmpty => write!(f, "Adresář není prázdný."),
            SalError::PermissionDenied => write!(f, "Přístup odepřen."),
            SalError::CreateDirFailed => write!(f, "Adresář se nepodařilo vytvořit."),
            SalError::PasswordRequired => write!(f, "Soubor v archivu je zaheslovaný – zadejte heslo."),
            SalError::InvalidPassword => write!(f, "Chybné heslo k archivu."),
            SalError::Io(msg) => write!(f, "{}", msg),
        }
    }
}

impl std::error::Error for SalError {}

impl From<io::Error> for SalError {
    /// Mapuje systémové IO chyby na sémantické kódy jádra,
    /// aby UI mohlo reagovat podle druhu chyby.
    fn from(err: io::Error) -> Self {
        match err.kind() {
            io::ErrorKind::NotFound => SalError::NotFound,
            io::ErrorKind::AlreadyExists => SalError::AlreadyExists,
            io::ErrorKind::PermissionDenied => SalError::PermissionDenied,
            io::ErrorKind::DirectoryNotEmpty => SalError::NotEmpty,
            _ => SalError::Io(err.to_string()),
        }
    }
}

pub type SalResult<T> = Result<T, SalError>;
