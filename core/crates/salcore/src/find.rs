// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Rekurzivní hledání souborů a adresářů nad libovolným VFS.
//!
//! Odpovídá funkci Find ze Salamandera: prochází adresářovou strukturu
//! od zadaného kořene a hledá položky odpovídající masce (viz `mask`).
//! Nalezené položky hlásí zpětným voláním, průběh a zrušení řeší
//! stejný progress jako souborové operace.

use crate::error::{SalError, SalResult};
use crate::mask::MaskGroup;
use crate::ops::ProgressCallback;
use crate::vfs::{join_path, Vfs, VfsItem, VfsItemKind};

/// Výsledek hledání: počet prohledaných a nalezených položek.
#[derive(Debug, Default, Clone, Copy)]
pub struct FindStats {
    pub scanned: u64,
    pub found: u64,
}

/// Spustí rekurzivní hledání.
///
/// Parametry:
/// - `vfs` – prohledávaný souborový systém,
/// - `root` – výchozí adresář (VFS cesta),
/// - `mask` – skupina masek pro porovnávání jmen,
/// - `include_dirs` – zda maska platí i pro adresáře (jinak se procházejí,
///   ale nehlásí se),
/// - `progress` – hlášení průběhu (done = prohledané položky, total = 0,
///   protože celkový počet předem neznáme) i zrušení,
/// - `on_found` – zpětné volání pro každou nalezenou položku; návrat
///   `false` hledání ukončí jako zrušené.
pub fn find_items(
    vfs: &dyn Vfs,
    root: &str,
    mask: &MaskGroup,
    include_dirs: bool,
    progress: &mut dyn ProgressCallback,
    on_found: &mut dyn FnMut(&str, &VfsItem) -> bool,
) -> SalResult<FindStats> {
    let mut stats = FindStats::default();
    if !find_dir(vfs, root, mask, include_dirs, progress, on_found, &mut stats)? {
        return Err(SalError::Cancelled);
    }
    Ok(stats)
}

/// Rekurzivní průchod jedním adresářem. Vrací `false`, pokud bylo hledání
/// zrušeno (progresem nebo zpětným voláním).
fn find_dir(
    vfs: &dyn Vfs,
    dir: &str,
    mask: &MaskGroup,
    include_dirs: bool,
    progress: &mut dyn ProgressCallback,
    on_found: &mut dyn FnMut(&str, &VfsItem) -> bool,
    stats: &mut FindStats,
) -> SalResult<bool> {
    let children = vfs.list(dir)?;
    for child in &children {
        // Průběh hlásíme po položkách; total=0 = neznámý celek.
        stats.scanned += 1;
        if !progress.on_progress(stats.scanned, 0) {
            return Ok(false);
        }

        let is_dir = child.kind == VfsItemKind::Dir;
        // Adresáře se hlásí jen pokud to uživatel povolil; soubory podle masky.
        let matches = if is_dir {
            include_dirs && mask.matches(&child.name)
        } else {
            mask.matches(&child.name)
        };
        if matches {
            stats.found += 1;
            if !on_found(&join_path(dir, &child.name), child) {
                return Ok(false);
            }
        }

        // Rekurzivně do podadresářů (odkazy následovat nechceme, aby
        // hledání nezacyklilo).
        if is_dir {
            let sub_dir = join_path(dir, &child.name);
            if !find_dir(vfs, &sub_dir, mask, include_dirs, progress, on_found, stats)? {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local::LocalFs;
    use crate::ops::NoProgress;
    use std::fs;
    use std::path::PathBuf;

    /// Adresář: data/pod/x.txt, data/y.log, data/pod/pod2/z.txt
    fn prepare() -> PathBuf {
        let base = std::env::temp_dir().join(format!("salcore-find-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("pod").join("pod2")).unwrap();
        fs::write(base.join("pod").join("x.txt"), b"x").unwrap();
        fs::write(base.join("y.log"), b"y").unwrap();
        fs::write(base.join("pod").join("pod2").join("z.txt"), b"z").unwrap();
        base
    }

    #[test]
    fn test_find_by_mask() {
        let base = prepare();
        let vfs = LocalFs::new(base.to_str()).unwrap();
        let mask = MaskGroup::new("*.txt", true).unwrap();
        let mut found: Vec<String> = Vec::new();
        let stats = find_items(
            &vfs,
            "/",
            &mask,
            false,
            &mut NoProgress,
            &mut |path, _item| {
                found.push(path.to_string());
                true
            },
        )
        .unwrap();
        assert_eq!(stats.found, 2);
        assert!(found.iter().any(|path| path == "/pod/x.txt"));
        assert!(found.iter().any(|path| path == "/pod/pod2/z.txt"));

        // Vyloučení přes | – najde jen .txt, ale ne soubory začínající na z.
        // (Maska se aplikuje na jméno, ne na celou cestu – jako v Salamanderu.)
        let mask = MaskGroup::new("*.txt|z*", true).unwrap();
        let mut count = 0;
        find_items(&vfs, "/", &mask, false, &mut NoProgress, &mut |_, _| {
            count += 1;
            true
        })
        .unwrap();
        assert_eq!(count, 1);

        // Adresáře v výsledcích, pokud jsou zahrnuty.
        let mask = MaskGroup::new("pod*", true).unwrap();
        let mut dirs = 0;
        find_items(&vfs, "/", &mask, true, &mut NoProgress, &mut |_, item| {
            if item.kind == VfsItemKind::Dir {
                dirs += 1;
            }
            true
        })
        .unwrap();
        assert_eq!(dirs, 2);

        fs::remove_dir_all(&base).unwrap();
    }
}
