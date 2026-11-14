// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Lokální souborový systém nad std::fs.
//!
//! Cesty VFS jsou absolutní s lomítky od kořene (`/Users/x/…`), kořen
//! lze při vytvoření omezit (např. na domovský adresář sandboxované aplikace).

use std::ffi::CString;
use std::fs::{self, File, Metadata};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::error::{SalError, SalResult};
use crate::vfs::{
    join_path, normalize_vfs_path, Vfs, VfsItem, VfsItemKind, VfsKind, VfsReadStream,
    VfsWriteStream,
};

/// Implementace VFS nad lokálním diskem.
pub struct LocalFs {
    /// Kořenový adresář tohoto VFS (absolutní cesta na disku).
    root: PathBuf,
}

impl LocalFs {
    /// Vytvoří lokální VFS s daným kořenem; `None` znamená kořen celého disku.
    pub fn new(root: Option<&str>) -> SalResult<LocalFs> {
        let root = match root {
            Some(root_str) if !root_str.is_empty() => {
                let path = PathBuf::from(root_str);
                if !path.is_absolute() {
                    return Err(SalError::Io(
                        "Kořen lokálního souborového systému musí být absolutní cesta."
                            .to_string(),
                    ));
                }
                path
            }
            _ => PathBuf::from("/"),
        };
        Ok(LocalFs { root })
    }

    /// Převede cestu VFS na cestu na disku (spojení s kořenem).
    pub(crate) fn disk_path(&self, vfs_path: &str) -> PathBuf {
        let path = normalize_vfs_path(vfs_path);
        // Odstranění úvodního lomítka a napojení za kořen.
        let relative = path.trim_start_matches('/');
        if relative.is_empty() {
            self.root.clone()
        } else {
            self.root.join(relative)
        }
    }

    /// Převede cestu na disku zpět na cestu VFS (pro zobrazení).
    pub fn vfs_path_from_disk(&self, disk_path: &Path) -> String {
        match disk_path.strip_prefix(&self.root) {
            Ok(relative) if !relative.as_os_str().is_empty() => {
                format!("/{}", relative.to_string_lossy().replace('\\', "/"))
            }
            _ => "/".to_string(),
        }
    }

    /// Leží adresář `dir` na stejném svazku jako adresář `other_dir` druhého
    /// lokálního VFS? (Podmínka přesunu přejmenováním; nečitelný adresář = ne.)
    pub fn same_device(&self, dir: &str, other: &LocalFs, other_dir: &str) -> bool {
        use std::os::unix::fs::MetadataExt;
        match (fs::metadata(self.disk_path(dir)), fs::metadata(other.disk_path(other_dir))) {
            (Ok(first), Ok(second)) => first.dev() == second.dev(),
            _ => false,
        }
    }

    /// Přesune položku `path` přejmenováním na cestu `new_path` v lokálním VFS
    /// `other` (i do jiného adresáře). Existující cílový soubor se nahradí;
    /// mezi svazky selže chybou EXDEV.
    pub fn rename_to(&self, path: &str, other: &LocalFs, new_path: &str) -> io::Result<()> {
        fs::rename(self.disk_path(path), other.disk_path(new_path))
    }
}

/// Převede systémový čas modifikace na unixové sekundy UTC (neznámý čas = 0).
fn mtime_to_unix(metadata: &Metadata) -> i64 {
    metadata.modified().map(crate::vfs::system_time_to_unix).unwrap_or(0)
}

/// Převede metadata na položku výpisu. Používá symlink_metadata, takže
/// symbolické odkazy se zobrazují jako odkazy, nikoliv jako jejich cíl.
fn metadata_to_item(name: &str, metadata: &Metadata) -> VfsItem {
    let is_symlink = metadata.file_type().is_symlink();
    let is_dir = metadata.is_dir();
    // Skrytá položka: úvodní tečka názvu (unix) nebo příznak UF_HIDDEN (macOS,
    // např. ~/Library nebo soubory skryté přes `chflags hidden`).
    let hidden = name.starts_with('.') || has_hidden_flag(metadata);
    // Adresáře v Unixu nemají smysluplnou „velikost“ – zobrazujeme 0.
    let size = if is_dir { 0 } else { metadata.len() };
    VfsItem {
        name: name.to_string(),
        size,
        mtime: mtime_to_unix(metadata),
        kind: if is_symlink {
            VfsItemKind::Link
        } else if is_dir {
            VfsItemKind::Dir
        } else {
            VfsItemKind::File
        },
        hidden,
        readonly: metadata.permissions().readonly(),
        encrypted: false,
        link_to_dir: false,
    }
}

/// Příznak UF_HIDDEN ze `st_flags` (jen macOS/BSD; jinde vždy false).
#[cfg(target_os = "macos")]
fn has_hidden_flag(metadata: &Metadata) -> bool {
    use std::os::macos::fs::MetadataExt;
    // UF_HIDDEN = 0x8000 (sys/stat.h) – Finder takové položky nezobrazuje.
    const UF_HIDDEN: u32 = 0x0000_8000;
    metadata.st_flags() & UF_HIDDEN != 0
}

#[cfg(not(target_os = "macos"))]
fn has_hidden_flag(_metadata: &Metadata) -> bool {
    false
}

// Čtecí stream nad lokálním souborem.
impl Read for LocalRead {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.file.read(buf)
    }
}

/// Čtecí stream – obálka nad std::fs::File.
pub struct LocalRead {
    file: File,
}
impl VfsReadStream for LocalRead {}

// Zapisovací stream nad lokálním souborem.
impl Write for LocalWrite {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.file.write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

/// Zapisovací stream – obálka nad std::fs::File.
pub struct LocalWrite {
    file: File,
}
impl VfsWriteStream for LocalWrite {}

impl Vfs for LocalFs {
    fn kind(&self) -> VfsKind {
        VfsKind::Local
    }

    fn label(&self) -> String {
        // Popisem panelu je kořen (celý disk se zobrazí jako lomítko).
        let label = self.root.to_string_lossy().to_string();
        if label.is_empty() {
            "/".to_string()
        } else {
            label
        }
    }

    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        let disk_path = self.disk_path(path);
        let mut items = Vec::new();
        // read_dir vrací iterátor s výsledky pro jednotlivé položky;
        // chybu jedné položky přeskočíme, aby výpis nezhavaroval celý.
        for entry in fs::read_dir(&disk_path)? {
            let entry = match entry {
                Ok(entry) => entry,
                Err(_) => continue,
            };
            let file_name = entry.file_name().to_string_lossy().to_string();
            match fs::symlink_metadata(entry.path()) {
                Ok(metadata) => items.push(metadata_to_item(&file_name, &metadata)),
                Err(_) => continue,
            }
        }
        Ok(items)
    }

    fn list_for_panel(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        let disk_path = self.disk_path(path);
        let mut items = self.list(path)?;
        // U odkazů zjistíme i typ cíle (is_dir odkaz sleduje): odkaz na adresář
        // se v panelu chová jako adresář. Odkaz vedoucí nikam nebo na soubor
        // zůstává obyčejným odkazem.
        for item in items.iter_mut().filter(|item| item.kind == VfsItemKind::Link) {
            item.link_to_dir = disk_path.join(&item.name).is_dir();
        }
        Ok(items)
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        Ok(Box::new(LocalRead {
            file: File::open(self.disk_path(path))?,
        }))
    }

    fn open_write(&self, path: &str, _size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
        // Vytvoření nového souboru; existenci cíle kontroluje vrstva operací.
        Ok(Box::new(LocalWrite {
            file: File::create(self.disk_path(path))?,
        }))
    }

    fn mkdir(&self, path: &str) -> SalResult<()> {
        fs::create_dir(self.disk_path(path))?;
        Ok(())
    }

    fn delete(&self, path: &str, recursive: bool) -> SalResult<()> {
        let disk_path = self.disk_path(path);
        let metadata = fs::symlink_metadata(&disk_path)?;
        if metadata.is_dir() {
            if recursive {
                fs::remove_dir_all(&disk_path)?;
            } else {
                fs::remove_dir(&disk_path)?;
            }
        } else {
            fs::remove_file(&disk_path)?;
        }
        Ok(())
    }

    fn rename(&self, path: &str, new_name: &str) -> SalResult<()> {
        use std::os::unix::fs::MetadataExt;
        // Přejmenování jen změní jméno, adresář zůstává stejný.
        let (dir, _) = crate::vfs::split_path(path);
        let old_path = self.disk_path(path);
        let new_path = self.disk_path(&join_path(&dir, new_name));
        // fs::rename by existující cíl tiše nahradilo. Výjimkou je tatáž
        // položka pod novým jménem (změna velikosti písmen na disku, který
        // ji nerozlišuje) – pozná se podle shodného zařízení a inode.
        if let Ok(target) = fs::symlink_metadata(&new_path) {
            let source = fs::symlink_metadata(&old_path)?;
            if (source.dev(), source.ino()) != (target.dev(), target.ino()) {
                return Err(SalError::AlreadyExists);
            }
        }
        fs::rename(old_path, new_path)?;
        Ok(())
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        // Položka sama, ne cíl odkazu: i odkaz vedoucí nikam ve výpisu je
        // a při kopírování znamená konflikt.
        Ok(fs::symlink_metadata(self.disk_path(path)).is_ok())
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        // Sledujeme cíl odkazu – kvůli navigaci je důležitý cíl, ne odkaz.
        Ok(self.disk_path(path).is_dir())
    }

    fn free_space(&self, path: &str) -> SalResult<Option<u64>> {
        // statfs na macOS/Linux; volné místo = bloky dostupné běžnému uživateli.
        // Cesta musí být C řetězec ukončený NUL (cesta s vnitřním NUL neexistuje).
        let Ok(disk_path) = CString::new(self.disk_path(path).as_os_str().as_encoded_bytes()) else {
            return Ok(None);
        };
        let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
        let result = unsafe { libc::statfs(disk_path.as_ptr(), &mut stats) };
        if result != 0 {
            return Ok(None);
        }
        let free = (stats.f_bavail as u64) * (stats.f_bsize as u64);
        Ok(Some(free))
    }

    fn as_local(&self) -> Option<&LocalFs> {
        Some(self)
    }

    fn read_link(&self, path: &str) -> SalResult<Option<String>> {
        let disk_path = self.disk_path(path);
        // Cíl se čte jen u odkazu (read_link nad běžným souborem je chyba).
        if !fs::symlink_metadata(&disk_path)?.file_type().is_symlink() {
            return Ok(None);
        }
        Ok(Some(fs::read_link(disk_path)?.to_string_lossy().into_owned()))
    }

    fn supports_symlinks(&self) -> bool {
        true
    }

    fn create_symlink(&self, path: &str, target: &str) -> SalResult<()> {
        std::os::unix::fs::symlink(target, self.disk_path(path))?;
        Ok(())
    }

    fn item(&self, path: &str) -> SalResult<Option<VfsItem>> {
        // Stejná metadata jako ve výpisu (odkaz zůstává odkazem), jméno z cesty.
        let (_, name) = crate::vfs::split_path(path);
        let metadata = fs::symlink_metadata(self.disk_path(path))?;
        Ok(Some(metadata_to_item(&name, &metadata)))
    }

    fn dir_identity(&self, dir: &str) -> Option<String> {
        // Skutečná cesta s rozvinutými odkazy: tentýž adresář může být dosažitelný
        // víc cestami (např. `/tmp` a `/private/tmp`) i přes VFS s jiným kořenem.
        // Neexistující adresář rozvinout nejde – zůstane zadaná cesta.
        let disk_path = self.disk_path(dir);
        Some(fs::canonicalize(&disk_path).unwrap_or(disk_path).to_string_lossy().into_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // Testovací adresář s několika soubory pro ověření výpisu a operací.
    fn prepare_test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("salcore-test-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub")).unwrap();
        fs::write(dir.join("a.txt"), "obsah a").unwrap();
        fs::write(dir.join("sub").join("b.txt"), "obsah b").unwrap();
        dir
    }

    #[test]
    fn test_list_and_items() {
        let dir = prepare_test_dir("list");
        let fs_impl = LocalFs::new(dir.to_str()).unwrap();
        let items = fs_impl.list("/").unwrap();
        let names: Vec<&str> = items.iter().map(|item| item.name.as_str()).collect();
        assert!(names.contains(&"a.txt"));
        assert!(names.contains(&"sub"));
        let sub = items.iter().find(|item| item.name == "sub").unwrap();
        assert_eq!(sub.kind, VfsItemKind::Dir);
        let file = items.iter().find(|item| item.name == "a.txt").unwrap();
        assert_eq!(file.size, 7);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_list_marks_link_to_dir() {
        use crate::vfs::{ITEM_FLAG_DIR, ITEM_FLAG_LINK};
        let dir = prepare_test_dir("linkdir");
        // Odkaz na adresář, na soubor a odkaz vedoucí nikam.
        std::os::unix::fs::symlink(dir.join("sub"), dir.join("odkaz-dir")).unwrap();
        std::os::unix::fs::symlink(dir.join("a.txt"), dir.join("odkaz-soubor")).unwrap();
        std::os::unix::fs::symlink(dir.join("neexistuje"), dir.join("odkaz-nikam")).unwrap();
        let fs_impl = LocalFs::new(dir.to_str()).unwrap();
        // Rekurzivní průchody (list) cíl odkazu nezjišťují, výpis panelu ano.
        assert!(fs_impl.list("/").unwrap().iter().all(|item| !item.link_to_dir));
        let items = fs_impl.list_for_panel("/").unwrap();
        let find = |name: &str| items.iter().find(|item| item.name == name).unwrap();
        // Odkaz na adresář zůstává druhem Link (operace pracují s odkazem),
        // ale nese příznaky DIR i LINK; ostatní odkazy příznak DIR nemají.
        let dir_link = find("odkaz-dir");
        assert_eq!(dir_link.kind, VfsItemKind::Link);
        assert_eq!(dir_link.flags() & (ITEM_FLAG_DIR | ITEM_FLAG_LINK), ITEM_FLAG_DIR | ITEM_FLAG_LINK);
        for name in ["odkaz-soubor", "odkaz-nikam"] {
            let link = find(name);
            assert_eq!(link.kind, VfsItemKind::Link);
            assert_eq!(link.flags() & (ITEM_FLAG_DIR | ITEM_FLAG_LINK), ITEM_FLAG_LINK);
        }
        // Smazání odkazu na adresář nesmí sáhnout na jeho cíl.
        fs_impl.delete("/odkaz-dir", true).unwrap();
        assert!(dir.join("sub").is_dir());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn test_read_write_and_delete() {
        let dir = prepare_test_dir("rw");
        let fs_impl = LocalFs::new(dir.to_str()).unwrap();
        // Zápis nového souboru a jeho přečtení.
        {
            let mut writer = fs_impl.open_write("/novy.txt", None).unwrap();
            writer.write_all(b"hello").unwrap();
        }
        {
            let mut reader = fs_impl.open_read("/novy.txt").unwrap();
            let mut buffer = String::new();
            reader.read_to_string(&mut buffer).unwrap();
            assert_eq!(buffer, "hello");
        }
        assert!(fs_impl.exists("/novy.txt").unwrap());
        // Adresář, přejmenování, mazání.
        fs_impl.mkdir("/dir2").unwrap();
        assert!(fs_impl.is_dir("/dir2").unwrap());
        fs_impl.rename("/novy.txt", "prejmenovany.txt").unwrap();
        assert!(!fs_impl.exists("/novy.txt").unwrap());
        // Přejmenování na jméno jiné existující položky ji nesmí nahradit;
        // změna jen velikosti písmen téže položky projde.
        assert_eq!(fs_impl.rename("/prejmenovany.txt", "a.txt").unwrap_err(), SalError::AlreadyExists);
        assert_eq!(fs::read(dir.join("a.txt")).unwrap(), b"obsah a");
        fs_impl.rename("/prejmenovany.txt", "PREJMENOVANY.txt").unwrap();
        fs_impl.rename("/PREJMENOVANY.txt", "prejmenovany.txt").unwrap();
        fs_impl.delete("/prejmenovany.txt", false).unwrap();
        fs_impl.delete("/sub", true).unwrap();
        let items = fs_impl.list("/").unwrap();
        assert!(items.iter().all(|item| item.name != "sub"));
        fs::remove_dir_all(&dir).unwrap();
    }
}
