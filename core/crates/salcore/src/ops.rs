// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Souborové operace (kopírování, přesun, mazání) mezi libovolnými VFS.
//!
//! Všechny operace podporují hlášení průběhu a zrušení uživatelem.
//! Kopírování probíhá streamováním po 256 KiB blocích, takže funguje
//! mezi všemi kombinacemi zdroje a cíle (disk, archiv, FTP, SFTP)
//! bez nutnosti vejít se do paměti.

use std::io::{self, Read, Write};

use crate::error::{SalError, SalResult};
use crate::local::LocalFs;
use crate::vfs::{join_path, Vfs, VfsItemKind};

/// Velikost přenosového bufferu pro streamované kopírování.
const COPY_BUFFER_SIZE: usize = 256 * 1024;

/// Rozhodnutí při existenci cílového souboru/adresáře.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverwriteMode {
    /// Přeruší operaci chybou AlreadyExists; UI se zeptá a spustí znovu.
    Ask,
    /// Existující cíle přepíše.
    Overwrite,
    /// Existující cíle přeskočí.
    Skip,
}

/// Rozhraní pro hlášení průběhu operace.
/// Návratová hodnota `false` operaci zruší (vrátí SalError::Cancelled).
pub trait ProgressCallback: Send {
    fn on_progress(&mut self, done: u64, total: u64) -> bool;
}

/// Prázdný progress – operace bez sledování průběhu.
pub struct NoProgress;
impl ProgressCallback for NoProgress {
    fn on_progress(&mut self, _done: u64, _total: u64) -> bool {
        true
    }
}

/// Statistika provedené operace (počty přenesených položek).
#[derive(Debug, Default, Clone, Copy)]
pub struct TransferStats {
    pub files: u64,
    pub dirs: u64,
    pub bytes: u64,
    pub skipped: u64,
}

pub(crate) fn measure_total(src: &dyn Vfs, src_dir: &str, names: &[&str]) -> u64 {
    let mut total = 0u64;
    // Výpis zdrojového adresáře potřebujeme jednou pro metadata položek.
    let items = match src.list(src_dir) {
        Ok(items) => items,
        Err(_) => return 0,
    };
    for name in names {
        if let Some(item) = items.iter().find(|item| item.name == *name) {
            match item.kind {
                VfsItemKind::Dir => total += measure_dir(src, &join_path(src_dir, name)),
                _ => total += item.size,
            }
        }
    }
    total
}

/// Rekurzivní součet velikostí obsahu adresáře.
fn measure_dir(src: &dyn Vfs, dir: &str) -> u64 {
    let mut total = 0u64;
    if let Ok(children) = src.list(dir) {
        for child in children {
            match child.kind {
                VfsItemKind::Dir => total += measure_dir(src, &join_path(dir, &child.name)),
                _ => total += child.size,
            }
        }
    }
    total
}

/// Zkopíruje jeden soubor mezi VFS streamovaným přenosem.
/// Vrací počet přenesených bajtů.
fn copy_file(
    src: &dyn Vfs,
    src_path: &str,
    dst: &dyn Vfs,
    dst_path: &str,
    size: u64,
    total_bytes: u64,
    transferred: &mut u64,
    progress: &mut dyn ProgressCallback,
) -> SalResult<()> {
    let mut reader = src.open_read(src_path)?;
    let mut writer = dst.open_write(dst_path, Some(size))?;
    let mut buffer = vec![0u8; COPY_BUFFER_SIZE];
    loop {
        // Kontrola zrušení probíhá v hlášení průběhu po každém bloku.
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        writer.write_all(&buffer[..read]).map_err(map_write_err)?;
        *transferred += read as u64;
        if !progress.on_progress(*transferred, total_bytes) {
            return Err(SalError::Cancelled);
        }
    }
    // Dokončení zápisu (u FTP/SFTP se teprve teď provede vlastní upload).
    writer.flush().map_err(map_write_err)?;
    drop(writer);
    Ok(())
}

/// Přemapuje chyby zápisu – často jde o chybu vzdáleného protokolu,
/// kterou chceme vidět s textem, ne jen jako generickou IO chybu.
fn map_write_err(err: io::Error) -> SalError {
    SalError::from(err)
}

/// Zkopíruje položku (soubor nebo celý adresář) z `src_path` do `dst_path`.
/// U existujících cílů se řídí `overwrite`; adresáře se slučují (merge).
fn copy_item(
    src: &dyn Vfs,
    src_path: &str,
    dst: &dyn Vfs,
    dst_path: &str,
    overwrite: OverwriteMode,
    total_bytes: u64,
    stats: &mut TransferStats,
    transferred: &mut u64,
    progress: &mut dyn ProgressCallback,
) -> SalResult<()> {
    let (parent, name) = crate::vfs::split_path(src_path);
    let items = src.list(&parent)?;
    let item = items
        .iter()
        .find(|item| item.name == name)
        .ok_or_else(|| SalError::NotFound)?;

    match item.kind {
        VfsItemKind::Dir => {
            // Cílový adresář: pokud existuje, slučujeme obsah; jinak vytvoříme.
            if !dst.exists(dst_path).unwrap_or(false) {
                dst.mkdir(dst_path)?;
                stats.dirs += 1;
            }
            let children = src.list(src_path)?;
            for child in children {
                let child_src = join_path(src_path, &child.name);
                let child_dst = join_path(dst_path, &child.name);
                copy_item(src, &child_src, dst, &child_dst, overwrite, total_bytes, stats, transferred, progress)?;
            }
            Ok(())
        }
        _ => {
            // Existující cílový soubor řeší režim přepsání.
            if dst.exists(dst_path).unwrap_or(false) {
                match overwrite {
                    OverwriteMode::Skip => {
                        stats.skipped += 1;
                        return Ok(());
                    }
                    OverwriteMode::Ask => {
                        return Err(SalError::AlreadyExists);
                    }
                    OverwriteMode::Overwrite => {
                        // Smažeme cíl, aby open_write nehlásil konflikt
                        // a nezůstaly staré datové bloky.
                        let _ = dst.delete(dst_path, false);
                    }
                }
            }
            copy_file(src, src_path, dst, dst_path, item.size, total_bytes, transferred, progress)?;
            stats.files += 1;
            stats.bytes += item.size;
            Ok(())
        }
    }
}

/// Zkopíruje sadu položek z adresáře `src_dir` ve zdrojovém VFS do
/// adresáře `dst_dir` v cílovém VFS (rekurzivně).
pub fn copy_items(
    src: &dyn Vfs,
    src_dir: &str,
    names: &[&str],
    dst: &dyn Vfs,
    dst_dir: &str,
    overwrite: OverwriteMode,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    let mut stats = TransferStats::default();
    let mut transferred = 0u64;
    // Nejprve spočítáme celkovou velikost pro percentuální progress.
    // U vzdálených protokolů přeskočíme (dvojitý výpis by operaci zbytečně
    // prodlužoval) – total 0 znamená „neznámý celek“.
    let total_bytes = if src.supports_size_scan() {
        measure_total(src, src_dir, names)
    } else {
        0
    };
    if !progress.on_progress(0, total_bytes) {
        return Err(SalError::Cancelled);
    }

    for name in names {
        let src_path = join_path(src_dir, name);
        let dst_path = join_path(dst_dir, name);
        copy_item(
            src,
            &src_path,
            dst,
            &dst_path,
            overwrite,
            total_bytes,
            &mut stats,
            &mut transferred,
            &mut *progress,
        )?;
    }
    progress.on_progress(total_bytes, total_bytes);
    Ok(stats)
}

/// Přesune sadu položek: zkopíruje je a poté smaže zdroje.
/// U lokálního disku se stejným kořenem se použije přímé přejmenování.
pub fn move_items(
    src: &dyn Vfs,
    src_dir: &str,
    names: &[&str],
    dst: &dyn Vfs,
    dst_dir: &str,
    overwrite: OverwriteMode,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    // Rychlá cesta pro přesun v rámci lokálního souborového systému:
    // obě strany jsou LocalFs a mají stejný kořen -> použijeme rename.
    if let (Some(src_local), Some(dst_local)) = (src.as_local(), dst.as_local()) {
        if src_local.same_root(dst_local) {
            return move_local_rename(src_local, src_dir, names, dst_dir, overwrite, progress);
        }
    }

    // Obecná cesta: kopírování + mazání zdroje.
    let stats = copy_items(src, src_dir, names, dst, dst_dir, overwrite, progress)?;
    for name in names {
        let src_path = join_path(src_dir, name);
        src.delete(&src_path, true)?;
    }
    Ok(stats)
}

/// Přesun přejmenováním v rámci jednoho lokálního disku.
fn move_local_rename(
    src: &LocalFs,
    src_dir: &str,
    names: &[&str],
    dst_dir: &str,
    overwrite: OverwriteMode,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    let mut stats = TransferStats::default();
    for (index, name) in names.iter().enumerate() {
        if !progress.on_progress(index as u64, names.len() as u64) {
            return Err(SalError::Cancelled);
        }
        let src_path = join_path(src_dir, name);
        let dst_path = join_path(dst_dir, name);
        if src.exists(&dst_path).unwrap_or(false) {
            match overwrite {
                OverwriteMode::Skip => {
                    stats.skipped += 1;
                    continue;
                }
                OverwriteMode::Ask => return Err(SalError::AlreadyExists),
                OverwriteMode::Overwrite => {
                    let _ = src.delete(&dst_path, true);
                }
            }
        }
        src.rename(&src_path, name)?;
        stats.files += 1;
    }
    progress.on_progress(names.len() as u64, names.len() as u64);
    Ok(stats)
}

/// Smaže sadu položek v adresáři `dir` daného VFS (rekurzivně).
pub fn delete_items(
    vfs: &dyn Vfs,
    dir: &str,
    names: &[&str],
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    let mut stats = TransferStats::default();
    for (index, name) in names.iter().enumerate() {
        if !progress.on_progress(index as u64, names.len() as u64) {
            return Err(SalError::Cancelled);
        }
        vfs.delete(&join_path(dir, name), true)?;
        stats.files += 1;
    }
    progress.on_progress(names.len() as u64, names.len() as u64);
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local::LocalFs;
    use std::fs;
    use std::path::PathBuf;

    /// Vytvoří dva lokální VFS (zdroj a cíl) s testovacími daty.
    /// Tag odděluje adresáře jednotlivých testů (běží paralelně).
    fn prepare(tag: &str) -> (LocalFs, LocalFs, PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("salcore-ops-{}-{}", tag, std::process::id()));
        let src_dir = base.join("src");
        let dst_dir = base.join("dst");
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(src_dir.join("pod")).unwrap();
        fs::create_dir_all(&dst_dir).unwrap();
        fs::write(src_dir.join("a.txt"), b"aaa").unwrap();
        fs::write(src_dir.join("pod").join("b.txt"), b"bbb").unwrap();
        let src = LocalFs::new(src_dir.to_str()).unwrap();
        let dst = LocalFs::new(dst_dir.to_str()).unwrap();
        (src, dst, src_dir, dst_dir)
    }

    #[test]
    fn test_copy_items_recursive() {
        let (src, dst, src_path, dst_path) = prepare("copy");
        let stats = copy_items(
            &src,
            "/",
            &["a.txt", "pod"],
            &dst,
            "/",
            OverwriteMode::Ask,
            &mut NoProgress,
        )
        .unwrap();
        assert_eq!(stats.files, 2);
        assert_eq!(stats.dirs, 1);
        assert!(dst.exists("/a.txt").unwrap());
        assert!(dst.exists("/pod/b.txt").unwrap());

        // Konflikt v režimu Ask skončí chybou AlreadyExists.
        let result = copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Ask,
            &mut NoProgress,
        );
        assert_eq!(result.unwrap_err(), SalError::AlreadyExists);
        // Režim Overwrite projde, režim Skip položku přeskočí.
        copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Overwrite,
            &mut NoProgress,
        )
        .unwrap();
        let stats = copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Skip,
            &mut NoProgress,
        )
        .unwrap();
        assert_eq!(stats.skipped, 1);

        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
        let _ = dst_path;
    }

    #[test]
    fn test_move_local_rename() {
        let (src, dst, src_path, dst_path) = prepare("move");
        move_items(&src, "/", &["pod"], &dst, "/", OverwriteMode::Ask, &mut NoProgress).unwrap();
        assert!(!src.exists("/pod").unwrap());
        assert!(dst.exists("/pod/b.txt").unwrap());
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
        let _ = dst_path;
    }

    #[test]
    fn test_delete_items() {
        let (src, _dst, src_path, _dst_path) = prepare("delete");
        delete_items(&src, "/", &["a.txt", "pod"], &mut NoProgress).unwrap();
        let items = src.list("/").unwrap();
        assert!(items.is_empty());
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    /// Progress, který operaci zruší hned na začátku.
    struct CancelNow;
    impl ProgressCallback for CancelNow {
        fn on_progress(&mut self, _done: u64, _total: u64) -> bool {
            false
        }
    }

    #[test]
    fn test_cancellation() {
        let (src, dst, src_path, _dst_path) = prepare("cancel");
        let result = copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Ask,
            &mut CancelNow,
        );
        assert_eq!(result.unwrap_err(), SalError::Cancelled);
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }
}
