// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! C ABI jádra pro Swift/AppKit UI.
//!
//! Konvence:
//! - Handle `SalVfs` je heap-allocovaný wrapper nad `Box<dyn Vfs>`;
//!   uvolňuje se `sal_vfs_close`.
//! - Návratové kódy odpovídají `SalError::code` (0 = OK, 1 = zrušeno,
//!   záporné = chyba); text chyby se kopíruje do volajícím daného bufferu.
//! - Panika uvnitř jádra je zachycena (catch_unwind), aby nepřešla přes FFI.
//! - Pole jmen (`names`) alokuje volající a jádro je jen čte; výpisy
//!   (`SalItem`) alokuje jádro a uvolňuje je `sal_free_items`.
//! - Všechny funkce přebírající ukazatele jsou `unsafe`: volající ručí za
//!   platnost ukazatelů a NUL-ukončení řetězců (viz microcommander.h).

use std::ffi::{c_char, c_void, CStr, CString};
use std::fs::File;
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use crate::error::{SalError, SalResult};
use crate::find::{find_items, find_items_ex, find_mask_string, ContentMatcher, FindOptions};
use crate::local::LocalFs;
use crate::mask::MaskGroup;
use crate::ops::{copy_items, delete_items, move_items, OverwriteMode, ProgressCallback};
use crate::pack::{pack_zip, PackEncryption};
use crate::sftp::{SftpAuth, SftpFs};
use crate::tarfs::TarFs;
use crate::vfs::{Vfs, VfsItem};
use crate::zipfs::ZipFs;
use crate::ftp::FtpFs;

// ---------------------------------------------------------------------------
// C typy (odpovídají microcommander.h)
// ---------------------------------------------------------------------------

/// Neprůhledný handle (C strana nevidí obsah).
#[repr(C)]
pub struct SalVfs {
    _private: [u8; 0],
}

/// Jedna položka výpisu (odpovídá SalItem v microcommander.h).
#[repr(C)]
pub struct SalItem {
    pub name: *mut c_char,
    pub size: u64,
    pub mtime: i64,
    pub flags: u32,
}

/// Hlášení průběhu (odpovídá SalProgress v microcommander.h).
#[repr(C)]
pub struct SalProgress {
    pub on_progress: Option<extern "C" fn(*mut c_void, u64, u64) -> i32>,
    pub user: *mut c_void,
}

/// Zpětné volání hledání (odpovídá SalFoundFn v microcommander.h).
pub type SalFoundFn = Option<extern "C" fn(*mut c_void, *const c_char, u64, i64, u32)>;
/// Hlášení prohledávaného adresáře (odpovídá SalFindDirFn v microcommander.h).
pub type SalFindDirFn = Option<extern "C" fn(*mut c_void, *const c_char)>;

/// Příznaky sal_find_ex (viz SAL_FIND_* v microcommander.h).
const SAL_FIND_SUBDIRS: u32 = 1;
const SAL_FIND_INCLUDE_DIRS: u32 = 2;
const SAL_FIND_CONTENT: u32 = 4;
const SAL_FIND_CASE: u32 = 8;
const SAL_FIND_WHOLE_WORDS: u32 = 16;
const SAL_FIND_REGEX: u32 = 32;
const SAL_FIND_HEX: u32 = 64;
const SAL_FIND_NAME_CONTAINS: u32 = 128;

/// Režimy přepsání (odpovídají #define SAL_OVERWRITE_* v microcommander.h).
pub const SAL_OVERWRITE_ASK: i32 = 0;
pub const SAL_OVERWRITE_OVERWRITE: i32 = 1;
pub const SAL_OVERWRITE_SKIP: i32 = 2;

/// Wrapper kvůli tenkému ukazateli přes FFI (Box<dyn Vfs> je fat pointer).
struct VfsHandle {
    vfs: Box<dyn Vfs>,
}

/// Statický řetězec verze (NUL-ukončený, neuvolňuje se).
const VERSION_CSTR: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

// ---------------------------------------------------------------------------
// Pomocné funkce (ne FFI)
// ---------------------------------------------------------------------------

/// Zapíše text (chybovou zprávu, popisek) do volajícím daného bufferu –
/// vždy NUL-ukončený; delší text se zkrátí na hranici znaku UTF-8.
fn write_err(err: *mut c_char, err_len: usize, msg: &str) {
    if err.is_null() || err_len == 0 {
        return;
    }
    // Zkrácení uprostřed vícebajtového znaku by dalo neplatné UTF-8.
    let mut copy_len = msg.len().min(err_len - 1);
    while !msg.is_char_boundary(copy_len) {
        copy_len -= 1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(msg.as_ptr() as *const c_char, err, copy_len);
        *err.add(copy_len) = 0;
    }
}

/// Převede výsledek otevření/připojení VFS na handle pro C stranu (uvolňuje
/// ho `sal_vfs_close`); při chybě zapíše její text do bufferu `err` (smí být
/// NULL) a vrátí NULL.
fn handle_or_null(result: SalResult<impl Vfs + 'static>, err: *mut c_char, err_len: usize) -> *mut SalVfs {
    match result {
        Ok(vfs) => Box::into_raw(Box::new(VfsHandle { vfs: Box::new(vfs) })) as *mut SalVfs,
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// Časový limit připojení ze sekund (nula nebo záporná hodnota = výchozích 15 s).
fn connect_timeout(timeout_sec: f64) -> Duration {
    if timeout_sec > 0.0 {
        Duration::from_secs_f64(timeout_sec)
    } else {
        Duration::from_secs(15)
    }
}

/// Spustí closures v catch_unwind – panika nesmí přejít přes C ABI.
fn catch<T>(f: impl FnOnce() -> SalResult<T>) -> SalResult<T> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or_else(|_| {
        Err(SalError::Io(
            "Interní chyba jádra (neošetřená panika).".to_string(),
        ))
    })
}

/// Převede výsledek jádra na FFI kód a případně zapíše chybu.
fn result_to_code<T>(
    result: SalResult<T>,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    match result {
        Ok(_) => crate::error::SAL_OK,
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            e.code()
        }
    }
}

/// Přečte pole C řetězců na Vec<String> (null prvky → prázdné jméno).
unsafe fn names_from_c(names: *const *const c_char, count: usize) -> Vec<String> {
    if names.is_null() {
        return Vec::new();
    }
    std::slice::from_raw_parts(names, count)
        .iter()
        .map(|&ptr| {
            if ptr.is_null() {
                String::new()
            } else {
                CStr::from_ptr(ptr).to_string_lossy().into_owned()
            }
        })
        .collect()
}

/// Přečte volitelný C řetězec na Option<String> (NULL → None).
unsafe fn opt_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        None
    } else {
        Some(CStr::from_ptr(ptr).to_string_lossy().into_owned())
    }
}

/// Adaptér C progress callbacku na jádrový trait.
struct CProgress {
    callback: Option<extern "C" fn(*mut c_void, u64, u64) -> i32>,
    user: *mut c_void,
}

// SAFETY: user je jen neprůhledný ukazatel spravovaný volajícím (UI);
// jádro ho nepřistupuje a jen ho předává zpět callbacku.
unsafe impl Send for CProgress {}

impl ProgressCallback for CProgress {
    fn on_progress(&mut self, done: u64, total: u64) -> bool {
        match self.callback {
            Some(callback) => callback(self.user, done, total) != 0,
            None => true,
        }
    }
}

/// Vytvoří progress adaptér z volitelného ukazatele na SalProgress.
/// # Safety
/// `progress` musí ukazovat na platnou strukturu (nebo být NULL).
unsafe fn progress_from_c(progress: *const SalProgress) -> CProgress {
    if progress.is_null() {
        CProgress {
            callback: None,
            user: std::ptr::null_mut(),
        }
    } else {
        let raw = &*progress;
        CProgress {
            callback: raw.on_progress,
            user: raw.user,
        }
    }
}

/// Převede seznam položek na FFI pole (jména jako CString na hromadě).
fn items_to_ffi(items: Vec<VfsItem>) -> (*mut SalItem, usize) {
    let mut converted: Vec<SalItem> = Vec::with_capacity(items.len());
    for item in items {
        // Jméno s vnitřním NUL by rozbilo C řetězec – nahradíme podtržítkem.
        let name = CString::new(item.name.replace('\0', "_")).unwrap_or_default();
        converted.push(SalItem {
            name: name.into_raw(),
            size: item.size,
            mtime: item.mtime,
            flags: item.flags(),
        });
    }
    let mut boxed = converted.into_boxed_slice();
    let ptr = boxed.as_mut_ptr();
    let len = boxed.len();
    std::mem::forget(boxed);
    (ptr, len)
}

// ---------------------------------------------------------------------------
// FFI exporty
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn sal_version() -> *const c_char {
    VERSION_CSTR.as_ptr() as *const c_char
}

/// # Safety
/// `root` je NULL nebo platný C řetězec.
#[no_mangle]
pub unsafe extern "C" fn sal_open_local(root: *const c_char) -> *mut SalVfs {
    let root = opt_string(root);
    handle_or_null(catch(|| LocalFs::new(root.as_deref())), std::ptr::null_mut(), 0)
}

/// # Safety
/// `archive_path` je NULL nebo platný C řetězec.
#[no_mangle]
pub unsafe extern "C" fn sal_open_zip(archive_path: *const c_char) -> *mut SalVfs {
    let Some(path) = opt_string(archive_path) else {
        return std::ptr::null_mut();
    };
    handle_or_null(catch(|| ZipFs::open(Path::new(&path))), std::ptr::null_mut(), 0)
}

/// # Safety
/// `archive_path` je NULL nebo platný C řetězec.
#[no_mangle]
pub unsafe extern "C" fn sal_open_tar(archive_path: *const c_char) -> *mut SalVfs {
    let Some(path) = opt_string(archive_path) else {
        return std::ptr::null_mut();
    };
    handle_or_null(catch(|| TarFs::open(Path::new(&path))), std::ptr::null_mut(), 0)
}

/// # Safety
/// Řetězce jsou NULL nebo platné C řetězce, `err` je buffer délky `err_len`.
#[no_mangle]
pub unsafe extern "C" fn sal_connect_ftp(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    password: *const c_char,
    timeout_sec: f64,
    err: *mut c_char,
    err_len: usize,
) -> *mut SalVfs {
    let Some(host) = opt_string(host) else {
        write_err(err, err_len, "Chybí adresa serveru.");
        return std::ptr::null_mut();
    };
    let user = opt_string(user).unwrap_or_else(|| "anonymous".to_string());
    let password = opt_string(password).unwrap_or_default();
    let timeout = connect_timeout(timeout_sec);
    handle_or_null(catch(|| FtpFs::connect(&host, port, &user, &password, timeout)), err, err_len)
}

/// # Safety
/// Řetězce jsou NULL nebo platné C řetězce, `err` je buffer délky `err_len`.
#[no_mangle]
pub unsafe extern "C" fn sal_connect_sftp(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    password: *const c_char,
    timeout_sec: f64,
    err: *mut c_char,
    err_len: usize,
) -> *mut SalVfs {
    let password = opt_string(password).unwrap_or_default();
    connect_sftp_handle(host, port, user, SftpAuth::Password(password), timeout_sec, err, err_len)
}

/// # Safety
/// `vfs` musí být platný handle z sal_open_* / sal_connect_*.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_kind(vfs: *mut SalVfs) -> i32 {
    if vfs.is_null() {
        return 0;
    }
    let handle = &*(vfs as *const VfsHandle);
    handle.vfs.kind().as_i32()
}

/// # Safety
/// `vfs` musí být platný handle; `out` buffer délky `out_len`.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_label(vfs: *mut SalVfs, out: *mut c_char, out_len: usize) -> i32 {
    if vfs.is_null() || out.is_null() || out_len == 0 {
        return crate::error::SAL_ERR_GENERIC;
    }
    let handle = &*(vfs as *const VfsHandle);
    let label = handle.vfs.label();
    write_err(out, out_len, &label);
    crate::error::SAL_OK
}

/// # Safety
/// `vfs` musí být platný handle.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_writable(vfs: *mut SalVfs) -> i32 {
    if vfs.is_null() {
        return 0;
    }
    let handle = &*(vfs as *const VfsHandle);
    i32::from(handle.vfs.writable())
}

/// # Safety
/// `vfs` musí být platný handle nebo NULL.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_close(vfs: *mut SalVfs) {
    if vfs.is_null() {
        return;
    }
    drop(Box::from_raw(vfs as *mut VfsHandle));
}

/// # Safety
/// `vfs` platný handle, `path` platný C řetězec, `out_items`/`out_count` výstupní
/// ukazatele, `err` buffer.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_list(
    vfs: *mut SalVfs,
    path: *const c_char,
    out_items: *mut *mut SalItem,
    out_count: *mut usize,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || path.is_null() || out_items.is_null() || out_count.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_vfs_list.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let path_str = CStr::from_ptr(path).to_string_lossy().into_owned();
    let handle = &*(vfs as *const VfsHandle);
    // Výpis pro panel: u odkazů včetně informace, zda míří na adresář.
    let result = catch(|| handle.vfs.list_for_panel(&path_str));
    match result {
        Ok(items) => {
            let (ptr, count) = items_to_ffi(items);
            *out_items = ptr;
            *out_count = count;
            crate::error::SAL_OK
        }
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            e.code()
        }
    }
}

/// # Safety
/// `items` musí být pole vrácené sal_vfs_list (nebo NULL).
#[no_mangle]
pub unsafe extern "C" fn sal_free_items(items: *mut SalItem, count: usize) {
    if items.is_null() || count == 0 {
        return;
    }
    let slice = std::slice::from_raw_parts_mut(items, count);
    for item in slice.iter_mut() {
        if !item.name.is_null() {
            drop(CString::from_raw(item.name));
        }
    }
    drop(Box::from_raw(slice as *mut [SalItem]));
}

/// # Safety
/// `vfs` platný handle, `path` C řetězec, `out` výstup (0/1).
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_is_dir(
    vfs: *mut SalVfs,
    path: *const c_char,
    out: *mut i32,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || path.is_null() || out.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_vfs_is_dir.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let path_str = CStr::from_ptr(path).to_string_lossy().into_owned();
    let handle = &*(vfs as *const VfsHandle);
    let result = catch(|| handle.vfs.is_dir(&path_str));
    match result {
        Ok(is_dir) => {
            *out = if is_dir { 1 } else { 0 };
            crate::error::SAL_OK
        }
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            e.code()
        }
    }
}

/// # Safety
/// `vfs` platný handle, `path` C řetězec, `out` výstup (0/1).
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_exists(
    vfs: *mut SalVfs,
    path: *const c_char,
    out: *mut i32,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || path.is_null() || out.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_vfs_exists.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let path_str = CStr::from_ptr(path).to_string_lossy().into_owned();
    let handle = &*(vfs as *const VfsHandle);
    let result = catch(|| handle.vfs.exists(&path_str));
    match result {
        Ok(exists) => {
            *out = if exists { 1 } else { 0 };
            crate::error::SAL_OK
        }
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            e.code()
        }
    }
}

/// # Safety
/// `vfs` platný handle.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_free_space(vfs: *mut SalVfs, path: *const c_char) -> i64 {
    if vfs.is_null() || path.is_null() {
        return -1;
    }
    let path_str = CStr::from_ptr(path).to_string_lossy().into_owned();
    let handle = &*(vfs as *const VfsHandle);
    match catch(|| handle.vfs.free_space(&path_str)) {
        Ok(Some(free)) => free as i64,
        _ => -1,
    }
}

/// Signatura přenosové operace jádra (copy_items / move_items).
type TransferFn = fn(&dyn Vfs, &str, &[&str], &dyn Vfs, &str, OverwriteMode, &mut dyn ProgressCallback)
    -> SalResult<crate::ops::TransferStats>;

/// Převod režimu přepsání z C konstanty (neznámá hodnota = Ask).
fn overwrite_mode(overwrite: i32) -> OverwriteMode {
    match overwrite {
        SAL_OVERWRITE_OVERWRITE => OverwriteMode::Overwrite,
        SAL_OVERWRITE_SKIP => OverwriteMode::Skip,
        _ => OverwriteMode::Ask,
    }
}

/// Společná implementace sal_copy / sal_move (liší se jen operací a jménem v chybě).
#[allow(clippy::too_many_arguments)]
unsafe fn transfer_ffi(
    operation: TransferFn,
    function_name: &str,
    src: *mut SalVfs,
    src_dir: *const c_char,
    names: *const *const c_char,
    count: usize,
    dst: *mut SalVfs,
    dst_dir: *const c_char,
    overwrite: i32,
    progress: *const SalProgress,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if src.is_null() || dst.is_null() || src_dir.is_null() || dst_dir.is_null() {
        write_err(err, err_len, &format!("Neplatné argumenty {}.", function_name));
        return crate::error::SAL_ERR_GENERIC;
    }
    let src_dir_str = CStr::from_ptr(src_dir).to_string_lossy().into_owned();
    let dst_dir_str = CStr::from_ptr(dst_dir).to_string_lossy().into_owned();
    let name_list = names_from_c(names, count);
    let name_refs: Vec<&str> = name_list.iter().map(String::as_str).collect();
    let mut progress_cb = progress_from_c(progress);
    let src_handle = &*(src as *const VfsHandle);
    let dst_handle = &*(dst as *const VfsHandle);
    let result = catch(|| {
        operation(
            src_handle.vfs.as_ref(),
            &src_dir_str,
            &name_refs,
            dst_handle.vfs.as_ref(),
            &dst_dir_str,
            overwrite_mode(overwrite),
            &mut progress_cb,
        )
    });
    result_to_code(result.map(|_| ()), err, err_len)
}

/// # Safety
/// Viz microcommander.h.
#[no_mangle]
pub unsafe extern "C" fn sal_copy(
    src: *mut SalVfs,
    src_dir: *const c_char,
    names: *const *const c_char,
    count: usize,
    dst: *mut SalVfs,
    dst_dir: *const c_char,
    overwrite: i32,
    progress: *const SalProgress,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    transfer_ffi(copy_items, "sal_copy", src, src_dir, names, count, dst, dst_dir, overwrite, progress, err, err_len)
}

/// # Safety
/// Viz microcommander.h.
#[no_mangle]
pub unsafe extern "C" fn sal_move(
    src: *mut SalVfs,
    src_dir: *const c_char,
    names: *const *const c_char,
    count: usize,
    dst: *mut SalVfs,
    dst_dir: *const c_char,
    overwrite: i32,
    progress: *const SalProgress,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    transfer_ffi(move_items, "sal_move", src, src_dir, names, count, dst, dst_dir, overwrite, progress, err, err_len)
}

/// # Safety
/// Viz microcommander.h.
#[no_mangle]
pub unsafe extern "C" fn sal_delete(
    vfs: *mut SalVfs,
    dir: *const c_char,
    names: *const *const c_char,
    count: usize,
    progress: *const SalProgress,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || dir.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_delete.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let dir_str = CStr::from_ptr(dir).to_string_lossy().into_owned();
    let name_list = names_from_c(names, count);
    let name_refs: Vec<&str> = name_list.iter().map(String::as_str).collect();
    let mut progress_cb = progress_from_c(progress);
    let handle = &*(vfs as *const VfsHandle);
    let result = catch(|| delete_items(handle.vfs.as_ref(), &dir_str, &name_refs, &mut progress_cb));
    result_to_code(result.map(|_| ()), err, err_len)
}

/// # Safety
/// Viz microcommander.h.
#[no_mangle]
pub unsafe extern "C" fn sal_mkdir(
    vfs: *mut SalVfs,
    path: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || path.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_mkdir.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let path_str = CStr::from_ptr(path).to_string_lossy().into_owned();
    let handle = &*(vfs as *const VfsHandle);
    let result = catch(|| handle.vfs.mkdir(&path_str));
    result_to_code(result, err, err_len)
}

/// # Safety
/// Viz microcommander.h.
#[no_mangle]
pub unsafe extern "C" fn sal_rename(
    vfs: *mut SalVfs,
    dir: *const c_char,
    old_name: *const c_char,
    new_name: *const c_char,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || dir.is_null() || old_name.is_null() || new_name.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_rename.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let dir_str = CStr::from_ptr(dir).to_string_lossy().into_owned();
    let old_str = CStr::from_ptr(old_name).to_string_lossy().into_owned();
    let new_str = CStr::from_ptr(new_name).to_string_lossy().into_owned();
    let handle = &*(vfs as *const VfsHandle);
    let path = crate::vfs::join_path(&dir_str, &old_str);
    let result = catch(|| handle.vfs.rename(&path, &new_str));
    result_to_code(result, err, err_len)
}

/// # Safety
/// Viz microcommander.h.
#[no_mangle]
pub unsafe extern "C" fn sal_find(
    vfs: *mut SalVfs,
    root: *const c_char,
    mask: *const c_char,
    include_dirs: i32,
    progress: *const SalProgress,
    found: SalFoundFn,
    found_user: *mut c_void,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || root.is_null() || mask.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_find.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let root_str = CStr::from_ptr(root).to_string_lossy().into_owned();
    let mask_str = CStr::from_ptr(mask).to_string_lossy().into_owned();
    let mask_group = match MaskGroup::new(&mask_str, true) {
        Ok(group) => group,
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            return e.code();
        }
    };
    let mut progress_cb = progress_from_c(progress);
    let handle = &*(vfs as *const VfsHandle);
    let result = catch(|| {
        find_items(
            handle.vfs.as_ref(),
            &root_str,
            &mask_group,
            include_dirs != 0,
            &mut progress_cb,
            &mut |path, item| {
                if let Some(callback) = found {
                    let cpath = CString::new(path.replace('\0', "_")).unwrap_or_default();
                    callback(found_user, cpath.as_ptr(), item.size, item.mtime, item.flags());
                }
                true
            },
        )
    });
    result_to_code(result.map(|_| ()), err, err_len)
}

/// Hledání s volbami dialogu Find (podadresáře, obsah souborů, pravidlo
/// „maska bez * ? . = obsahuje“). Počet přeskočených chyb vrací v `errors`.
///
/// # Safety
/// Viz microcommander.h; `content` ukazuje na `content_len` bajtů (smí být NULL
/// při nulové délce), `errors` smí být NULL.
#[no_mangle]
pub unsafe extern "C" fn sal_find_ex(
    vfs: *mut SalVfs,
    root: *const c_char,
    mask: *const c_char,
    flags: u32,
    content: *const u8,
    content_len: usize,
    progress: *const SalProgress,
    found: SalFoundFn,
    dir_cb: SalFindDirFn,
    user: *mut c_void,
    errors: *mut u64,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if vfs.is_null() || root.is_null() || mask.is_null() || (content.is_null() && content_len > 0) {
        write_err(err, err_len, "Neplatné argumenty sal_find_ex.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let root_str = CStr::from_ptr(root).to_string_lossy().into_owned();
    let mut mask_str = CStr::from_ptr(mask).to_string_lossy().into_owned();
    if flags & SAL_FIND_NAME_CONTAINS != 0 {
        mask_str = find_mask_string(&mask_str);
    }
    let mask_group = match MaskGroup::new(&mask_str, true) {
        Ok(group) => group,
        Err(e) => {
            write_err(err, err_len, &e.to_string());
            return e.code();
        }
    };
    // Hledání v obsahu jen se zapnutým příznakem a neprázdným vzorem (jako v Salamanderu).
    let matcher = if flags & SAL_FIND_CONTENT != 0 && content_len > 0 {
        let pattern = std::slice::from_raw_parts(content, content_len);
        match ContentMatcher::new(
            pattern,
            flags & SAL_FIND_CASE != 0,
            flags & SAL_FIND_WHOLE_WORDS != 0,
            flags & SAL_FIND_REGEX != 0,
            flags & SAL_FIND_HEX != 0,
        ) {
            Ok(matcher) => Some(matcher),
            Err(e) => {
                write_err(err, err_len, &e.to_string());
                return e.code();
            }
        }
    } else {
        None
    };
    let options = FindOptions {
        subdirs: flags & SAL_FIND_SUBDIRS != 0,
        include_dirs: flags & SAL_FIND_INCLUDE_DIRS != 0,
        content: matcher,
    };
    let mut progress_cb = progress_from_c(progress);
    let handle = &*(vfs as *const VfsHandle);
    let result = catch(|| {
        find_items_ex(
            handle.vfs.as_ref(),
            &root_str,
            &mask_group,
            &options,
            &mut progress_cb,
            &mut |dir| {
                if let Some(callback) = dir_cb {
                    let cdir = CString::new(dir.replace('\0', "_")).unwrap_or_default();
                    callback(user, cdir.as_ptr());
                }
            },
            &mut |path, item| {
                if let Some(callback) = found {
                    let cpath = CString::new(path.replace('\0', "_")).unwrap_or_default();
                    callback(user, cpath.as_ptr(), item.size, item.mtime, item.flags());
                }
                true
            },
        )
    });
    if let Ok(stats) = &result {
        if !errors.is_null() {
            *errors = stats.errors;
        }
    }
    result_to_code(result.map(|_| ()), err, err_len)
}

/// Vyhodnotí skupinu masek (stejná pravidla jako hledání: `*`, `?`, `#`,
/// skupiny `;`, vyloučení `|`) nad polem jmen; do `out_matches[i]` zapíše
/// 1, pokud jméno `names[i]` masce vyhovuje, jinak 0.
///
/// # Safety
/// `mask` platný C řetězec, `names` pole `count` C řetězců, `out_matches`
/// pole `count` bajtů, `err` buffer délky `err_len`.
#[no_mangle]
pub unsafe extern "C" fn sal_mask_select(
    mask: *const c_char,
    names: *const *const c_char,
    count: usize,
    out_matches: *mut u8,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if mask.is_null() || (count > 0 && (names.is_null() || out_matches.is_null())) {
        write_err(err, err_len, "Neplatné argumenty sal_mask_select.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let mask_str = CStr::from_ptr(mask).to_string_lossy().into_owned();
    let result = catch(|| MaskGroup::new(&mask_str, true));
    if let Ok(group) = &result {
        // Maska se parsuje jednou, jména se jen porovnávají.
        let name_list = names_from_c(names, count);
        let matches = std::slice::from_raw_parts_mut(out_matches, count);
        for (matched, name) in matches.iter_mut().zip(&name_list) {
            *matched = u8::from(group.matches(name));
        }
    }
    result_to_code(result, err, err_len)
}

/// # Safety
/// `path` platný C řetězec.
#[no_mangle]
pub unsafe extern "C" fn sal_probe_archive(path: *const c_char) -> i32 {
    let Some(path_str) = opt_string(path) else {
        return 0;
    };
    let path = Path::new(&path_str);
    // ZIP magické bajty PK\x03\x04.
    if let Ok(mut file) = File::open(path) {
        let mut head = [0u8; 4];
        if file.read_exact(&mut head).is_ok() && head == [0x50, 0x4B, 0x03, 0x04] {
            return crate::vfs::VfsKind::Zip.as_i32();
        }
    }
    match crate::tarfs::probe_tar_format(path) {
        Ok(Some(_)) => crate::vfs::VfsKind::Tar.as_i32(),
        _ => 0,
    }
}

/// # Safety
/// Viz microcommander.h – vytvoření ZIP, volitelně se šifrováním (AES-256 / ZipCrypto).
#[no_mangle]
pub unsafe extern "C" fn sal_pack_zip(
    src: *mut SalVfs,
    src_dir: *const c_char,
    names: *const *const c_char,
    count: usize,
    dest_zip: *const c_char,
    encryption: i32,
    password: *const c_char,
    progress: *const SalProgress,
    err: *mut c_char,
    err_len: usize,
) -> i32 {
    if src.is_null() || src_dir.is_null() || dest_zip.is_null() {
        write_err(err, err_len, "Neplatné argumenty sal_pack_zip.");
        return crate::error::SAL_ERR_GENERIC;
    }
    let password_str = opt_string(password).unwrap_or_default();
    // Kód šifrování z hlavičky → varianta jádra (neznámý kód je chyba).
    let mode = match encryption {
        0 => PackEncryption::None,
        1 => PackEncryption::Aes256(password_str),
        2 => PackEncryption::ZipCrypto(password_str),
        _ => {
            write_err(err, err_len, "Neznámý režim šifrování ZIP.");
            return crate::error::SAL_ERR_GENERIC;
        }
    };
    let src_dir_str = CStr::from_ptr(src_dir).to_string_lossy().into_owned();
    let dest_str = CStr::from_ptr(dest_zip).to_string_lossy().into_owned();
    let name_list = names_from_c(names, count);
    let name_refs: Vec<&str> = name_list.iter().map(String::as_str).collect();
    let mut progress_cb = progress_from_c(progress);
    let src_handle = &*(src as *const VfsHandle);
    let result = catch(|| {
        pack_zip(
            src_handle.vfs.as_ref(),
            &src_dir_str,
            &name_refs,
            Path::new(&dest_str),
            &mode,
            &mut progress_cb,
        )
    });
    result_to_code(result.map(|_| ()), err, err_len)
}

/// # Safety
/// `vfs` musí být platný handle; `password` NULL nebo NUL-ukončený řetězec.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_set_password(vfs: *mut SalVfs, password: *const c_char) -> i32 {
    if vfs.is_null() {
        return 0;
    }
    let handle = &*(vfs as *const VfsHandle);
    // NULL heslo = zapomenout dříve zadané.
    let password_str = opt_string(password);
    i32::from(handle.vfs.set_password(password_str.as_deref()))
}

/// # Safety
/// `vfs` musí být platný handle.
#[no_mangle]
pub unsafe extern "C" fn sal_vfs_has_encrypted(vfs: *mut SalVfs) -> i32 {
    if vfs.is_null() {
        return 0;
    }
    let handle = &*(vfs as *const VfsHandle);
    i32::from(handle.vfs.has_encrypted())
}

/// Společné připojení SFTP se zvoleným ověřením (převod výsledku na handle / chybu).
/// # Safety
/// `host` a `user` jsou NULL nebo platné C řetězce, `err` je buffer délky `err_len`.
unsafe fn connect_sftp_handle(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    auth: SftpAuth,
    timeout_sec: f64,
    err: *mut c_char,
    err_len: usize,
) -> *mut SalVfs {
    let Some(host) = opt_string(host) else {
        write_err(err, err_len, "Chybí adresa serveru.");
        return std::ptr::null_mut();
    };
    let user = opt_string(user).unwrap_or_else(|| "root".to_string());
    let timeout = connect_timeout(timeout_sec);
    handle_or_null(catch(|| SftpFs::connect_with(&host, port, &user, &auth, timeout)), err, err_len)
}

/// Připojení SFTP soukromým klíčem ze souboru; passphrase NULL/"" = klíč bez hesla.
/// # Safety
/// Řetězce jsou NULL nebo platné C řetězce, `err` je buffer délky `err_len`.
#[no_mangle]
pub unsafe extern "C" fn sal_connect_sftp_key(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    private_key_path: *const c_char,
    passphrase: *const c_char,
    timeout_sec: f64,
    err: *mut c_char,
    err_len: usize,
) -> *mut SalVfs {
    let Some(key) = opt_string(private_key_path) else {
        write_err(err, err_len, "Chybí cesta k souboru s klíčem.");
        return std::ptr::null_mut();
    };
    let passphrase = opt_string(passphrase).filter(|value| !value.is_empty());
    let auth = SftpAuth::KeyFile { private_key: std::path::PathBuf::from(key), passphrase };
    connect_sftp_handle(host, port, user, auth, timeout_sec, err, err_len)
}

/// Připojení SFTP klíči ze ssh-agenta (SSH_AUTH_SOCK).
/// # Safety
/// Řetězce jsou NULL nebo platné C řetězce, `err` je buffer délky `err_len`.
#[no_mangle]
pub unsafe extern "C" fn sal_connect_sftp_agent(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    timeout_sec: f64,
    err: *mut c_char,
    err_len: usize,
) -> *mut SalVfs {
    connect_sftp_handle(host, port, user, SftpAuth::Agent, timeout_sec, err, err_len)
}

/// Je soubor se soukromým klíčem chráněný heslem? 1 = ano, 0 = ne, -1 = nelze přečíst.
/// # Safety
/// `private_key_path` je NULL nebo platný C řetězec.
#[no_mangle]
pub unsafe extern "C" fn sal_ssh_key_encrypted(private_key_path: *const c_char) -> i32 {
    let Some(path) = opt_string(private_key_path) else {
        return -1;
    };
    match crate::sftp::key_file_encrypted(Path::new(&path)) {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => -1,
    }
}
