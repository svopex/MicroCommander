// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Lokální souborový systém nad std::fs.
//!
//! Cesty VFS jsou absolutní s lomítky od kořene (`/Users/x/…`), kořen
//! lze při vytvoření omezit (např. na domovský adresář sandboxované aplikace).

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
    fn disk_path(&self, vfs_path: &str) -> PathBuf {
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

    /// Mají oba lokální VFS stejný kořen? (Podmínka pro rychlý přesun rename.)
    pub fn same_root(&self, other: &LocalFs) -> bool {
        self.root == other.root
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
            match std::fs::symlink_metadata(entry.path()) {
                Ok(metadata) => items.push(metadata_to_item(&file_name, &metadata)),
                Err(_) => continue,
            }
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
        // Přejmenování jen změní jméno, adresář zůstává stejný.
        let (dir, _) = crate::vfs::split_path(path);
        let old_path = self.disk_path(path);
        let new_path = self.disk_path(&join_path(&dir, new_name));
        fs::rename(old_path, new_path)?;
        Ok(())
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        Ok(self.disk_path(path).exists())
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        // Sledujeme cíl odkazu – kvůli navigaci je důležitý cíl, ne odkaz.
        Ok(self.disk_path(path).is_dir())
    }

    fn free_space(&self, path: &str) -> SalResult<Option<u64>> {
        // statfs na macOS/Linux; volné místo = bloky dostupné běžnému uživateli.
        let path_bytes = self.disk_path(path);
        let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::statfs(
                path_bytes.as_os_str().as_encoded_bytes().as_ptr() as *const libc::c_char,
                &mut stats,
            )
        };
        if result != 0 {
            return Ok(None);
        }
        let free = (stats.f_bavail as u64) * (stats.f_bsize as u64);
        Ok(Some(free))
    }

    fn as_local(&self) -> Option<&LocalFs> {
        Some(self)
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
        fs_impl.delete("/prejmenovany.txt", false).unwrap();
        fs_impl.delete("/sub", true).unwrap();
        let items = fs_impl.list("/").unwrap();
        assert!(items.iter().all(|item| item.name != "sub"));
        fs::remove_dir_all(&dir).unwrap();
    }
}
