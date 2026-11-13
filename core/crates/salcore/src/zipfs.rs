// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! ZIP archiv jako virtuální souborový systém (jen pro čtení).
//!
//! Podporuje zaheslované archivy: AES-128/192/256 (WinZip AE-1/AE-2)
//! i starší ZipCrypto. Výpis obsahu heslo nepotřebuje (metadata nejsou
//! šifrovaná), heslo se vyžaduje až při čtení obsahu šifrované položky –
//! bez hesla vrací jádro `PasswordRequired`, s chybným `InvalidPassword`.
//!
//! Archiv se otevírá pro každou operaci znovu ze souboru – ZIP je
//! seek-based formát, takže je to levné a umožňuje to číst více souborů
//! bez držení globálního zámku. Streamování obsahu používá self-referenční
//! strukturu (ZipFile půjčuje data z ZipArchive), řešenou bezpečným
//! rozšířením lifetime na heap-allocovaném archivu.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use zip::read::{ZipArchive, ZipFile};
use zip::result::ZipError;

use crate::error::{SalError, SalResult};
use crate::vfs::{
    normalize_vfs_path, Vfs, VfsItem, VfsItemKind, VfsKind, VfsReadStream, VfsWriteStream,
};

// Konverze chyb ZIP archivu na jednotný typ jádra; chybějící položka se
// hlásí jako NotFound (UI podle ní reaguje), zbylé jako text IO chyby.
impl From<ZipError> for SalError {
    fn from(err: ZipError) -> Self {
        match err {
            ZipError::FileNotFound => SalError::NotFound,
            ZipError::InvalidPassword => SalError::InvalidPassword,
            ZipError::UnsupportedArchive(detail) if detail == ZipError::PASSWORD_REQUIRED => {
                SalError::PasswordRequired
            }
            other => SalError::Io(other.to_string()),
        }
    }
}

/// VFS nad ZIP archivem na disku.
pub struct ZipFs {
    /// Cesta k souboru archivu na lokálním disku.
    archive_path: PathBuf,
    /// Heslo pro šifrované položky (zadává UI, platí pro celý archiv).
    password: Mutex<Option<String>>,
    /// Archiv obsahuje alespoň jednu šifrovanou položku.
    any_encrypted: bool,
}

/// Převede cestu VFS na prefix jmen v archivu (kořen = prázdný prefix).
/// Veřejná, protože stejnou konvenci jmen používá i TAR implementace.
pub fn inner_prefix_of(path: &str) -> String {
    let path = normalize_vfs_path(path);
    if path == "/" {
        String::new()
    } else {
        format!("{}/", path.trim_start_matches('/'))
    }
}

impl ZipFs {
    /// Otevře ZIP archiv (bez čtení obsahu – jen ověření hlavičky).
    pub fn open(archive_path: &Path) -> SalResult<ZipFs> {
        // Ověření, že jde o čitelný ZIP; selže u poškozených souborů hned.
        let file = File::open(archive_path)?;
        let mut archive = ZipArchive::new(file)?;
        // Zjištění šifrování z metadat (raw přístup nic nedešifruje).
        let mut any_encrypted = false;
        for index in 0..archive.len() {
            if archive.by_index_raw(index)?.encrypted() {
                any_encrypted = true;
                break;
            }
        }
        Ok(ZipFs {
            archive_path: archive_path.to_path_buf(),
            password: Mutex::new(None),
            any_encrypted,
        })
    }

    /// Aktuální heslo (kopie, aby se zámek nedržel během čtení).
    fn current_password(&self) -> Option<String> {
        self.password.lock().ok().and_then(|guard| guard.clone())
    }

    /// Otevře novou instanci archivu pro sekvenční operaci (list apod.).
    fn open_archive(&self) -> SalResult<ZipArchive<File>> {
        let file = File::open(&self.archive_path)?;
        Ok(ZipArchive::new(file)?)
    }

}

/// Stream pro čtení souboru z ZIP archivu.
///
/// ZipFile půjčuje data z ZipArchive, což Rust nedovolí vyjádřit přímo
/// v jedné struktuře. Proto je archiv heap-allocovaný (adresa se při
/// přesunu struktury nemění) a lifetime reference je rozšířena na 'static.
pub struct ZipReadStream {
    // POZOR na pořadí polí: Rust dropuje v pořadí deklarace, takže `file`
    // (půjčená data) se musí uvolnit dříve než vlastnický archiv.
    file: Option<ZipFile<'static, File>>,
    _archive: Box<ZipArchive<File>>,
}

impl ZipReadStream {
    /// Otevře soubor `inner_path` z archivu na disku pro streamované čtení.
    /// Šifrovaná položka se dešifruje zadaným heslem (bez hesla → PasswordRequired).
    fn open(archive_path: &Path, inner_path: &str, password: Option<&str>) -> SalResult<ZipReadStream> {
        let file = File::open(archive_path)?;
        let mut archive = Box::new(ZipArchive::new(file)?);
        let index = archive
            .index_for_name(inner_path)
            .ok_or_else(|| SalError::NotFound)?;

        // SAFETY: Rozšíření lifetime je bezpečné, protože:
        // 1) archiv je vlastněn touto strukturou (Box) a jeho adresa na hromadě
        //    se při přesunu struktury nemění,
        // 2) ZipFile je uvolněn (drop) dříve než archiv – viz pořadí polí,
        // 3) nikdo jiný nemá k archivu přístup, dokud stream žije.
        let zip_file = unsafe {
            let archive_ref: &'static mut ZipArchive<File> =
                &mut *(&mut *archive as *mut ZipArchive<File>);
            // Heslo předáme jen šifrované položce; nešifrovanou čteme normálně.
            let encrypted = archive_ref.by_index_raw(index)?.encrypted();
            match (encrypted, password) {
                (true, Some(password)) => archive_ref.by_index_decrypt(index, password.as_bytes())?,
                (true, None) => return Err(SalError::PasswordRequired),
                (false, _) => archive_ref.by_index(index)?,
            }
        };
        Ok(ZipReadStream {
            file: Some(zip_file),
            _archive: archive,
        })
    }
}

impl Read for ZipReadStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        // čtení delegujeme na vnitřní ZipFile
        match self.file.as_mut() {
            Some(file) => file.read(buf),
            None => Ok(0),
        }
    }
}
impl VfsReadStream for ZipReadStream {}

/// Převede datum/čas z metadat ZIP na unixový čas UTC (sekundy).
/// Používá algoritmus „days from civil“ (Howard Hinnant) bez závislosti
/// na externí knihovně pro práci s časem.
pub fn zip_time_to_unix(date_time: zip::DateTime) -> i64 {
    let (year, month, day) = (date_time.year() as i64, date_time.month() as i64, date_time.day() as i64);
    let (hour, minute, second) = (
        date_time.hour() as i64,
        date_time.minute() as i64,
        date_time.second() as i64,
    );
    // Dny od 1. 1. 1970; měsíc únor a leden patří do předchozího „císařského“ roku.
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    days * 86400 + hour * 3600 + minute * 60 + second
}

impl Vfs for ZipFs {
    fn kind(&self) -> VfsKind {
        VfsKind::Zip
    }

    fn label(&self) -> String {
        self.archive_path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| self.archive_path.to_string_lossy().to_string())
    }

    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        let prefix = inner_prefix_of(path);
        let mut archive = self.open_archive()?;
        // Mapa podle jména řeší duplikátní záznamy adresářů v archivu
        // (adresář může být zapsán jako položka i jen implikovaný cestou).
        let mut items: BTreeMap<String, VfsItem> = BTreeMap::new();

        for index in 0..archive.len() {
            // Raw přístup čte jen metadata – funguje i u šifrovaných položek bez hesla.
            let file = archive.by_index_raw(index)?;
            // mangled_name vrací bezpečné jméno (ochrana před ../ útoky).
            let raw_name = file.mangled_name().to_string_lossy().replace('\\', "/");
            let Some(rest) = raw_name.strip_prefix(&prefix) else {
                continue;
            };
            if rest.is_empty() {
                // Položka odpovídá přímo prohledávanému adresáři.
                continue;
            }
            match rest.find('/') {
                Some(slash_index) => {
                    // Cesta vede hlouběji – přímý potomek je adresář.
                    let dir_name = &rest[..slash_index];
                    items.entry(dir_name.to_string()).or_insert_with(|| VfsItem {
                        name: dir_name.to_string(),
                        size: 0,
                        mtime: 0,
                        kind: VfsItemKind::Dir,
                        hidden: dir_name.starts_with('.'),
                        readonly: true,
                        encrypted: false,
                    });
                }
                None => {
                    let name = rest.to_string();
                    let hidden = name.starts_with('.');
                    let encrypted = file.encrypted();
                    items.insert(
                        name.clone(),
                        VfsItem {
                            name,
                            size: file.size(),
                            mtime: zip_time_to_unix(
                                file.last_modified().unwrap_or_default(),
                            ),
                            kind: VfsItemKind::File,
                            hidden,
                            readonly: true,
                            encrypted,
                        },
                    );
                }
            }
        }
        Ok(items.into_values().collect())
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        let inner = normalize_vfs_path(path);
        let inner = inner.trim_start_matches('/');
        let password = self.current_password();
        Ok(Box::new(ZipReadStream::open(&self.archive_path, inner, password.as_deref())?))
    }

    fn open_write(&self, _path: &str, _size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
        Err(SalError::Io(
            "Do otevřeného ZIP archivu nelze zapisovat (jen pro čtení).".to_string(),
        ))
    }

    fn mkdir(&self, _path: &str) -> SalResult<()> {
        Err(SalError::Io(
            "Do otevřeného ZIP archivu nelze zapisovat (jen pro čtení).".to_string(),
        ))
    }

    fn delete(&self, _path: &str, _recursive: bool) -> SalResult<()> {
        Err(SalError::Io(
            "Z otevřeného ZIP archivu nelze mazat (jen pro čtení).".to_string(),
        ))
    }

    fn rename(&self, _path: &str, _new_name: &str) -> SalResult<()> {
        Err(SalError::Io(
            "V otevřeném ZIP archivu nelze přejmenovávat (jen pro čtení).".to_string(),
        ))
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        // Existenci řešíme výpisem nadřazeného adresáře – bez potřeby
        // dalšího API nad archivem.
        let (parent, name) = crate::vfs::split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let items = self.list(&parent)?;
        Ok(items.iter().any(|item| item.name == name))
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = crate::vfs::split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let items = self.list(&parent)?;
        Ok(items
            .iter()
            .any(|item| item.name == name && item.kind == VfsItemKind::Dir))
    }

    fn writable(&self) -> bool {
        false
    }

    fn supports_size_scan(&self) -> bool {
        // Velikosti máme z centrálního adresáře, scan je levný.
        true
    }

    fn set_password(&self, password: Option<&str>) -> bool {
        if let Ok(mut guard) = self.password.lock() {
            *guard = password.map(str::to_string);
        }
        true
    }

    fn has_encrypted(&self) -> bool {
        self.any_encrypted
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vfs::join_path;
    use std::fs;
    use std::io::Write;

    /// Vytvoří testovací ZIP archiv: a.txt, pod/b.txt
    fn prepare_zip() -> (PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("salcore-zip-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let zip_path = base.join("test.zip");
        let file = File::create(&zip_path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options: zip::write::SimpleFileOptions = Default::default();
        writer.start_file("a.txt", options).unwrap();
        writer.write_all(b"obsah a").unwrap();
        writer.start_file("pod/b.txt", options).unwrap();
        writer.write_all(b"obsah b").unwrap();
        writer.finish().unwrap();
        (base, zip_path)
    }

    #[test]
    fn test_zip_list_and_read() {
        let (base, zip_path) = prepare_zip();
        let vfs = ZipFs::open(&zip_path).unwrap();
        let items = vfs.list("/").unwrap();
        let names: Vec<&str> = items.iter().map(|item| item.name.as_str()).collect();
        assert!(names.contains(&"a.txt"));
        assert!(names.contains(&"pod"));

        let sub = vfs.list("/pod").unwrap();
        assert_eq!(sub.len(), 1);
        assert_eq!(sub[0].name, "b.txt");
        assert_eq!(sub[0].size, 7);

        // Streamované přečtení obsahu.
        let mut reader = vfs.open_read("/pod/b.txt").unwrap();
        let mut content = String::new();
        reader.read_to_string(&mut content).unwrap();
        assert_eq!(content, "obsah b");

        // Existence a adresářový test.
        assert!(vfs.exists("/a.txt").unwrap());
        assert!(vfs.is_dir("/pod").unwrap());
        assert!(!vfs.is_dir("/a.txt").unwrap());

        // Operace zápisu selžou – archiv je jen pro čtení.
        assert!(!vfs.writable());
        assert!(vfs.mkdir("/novy").is_err());

        let _ = join_path("/", "x");
        fs::remove_dir_all(&base).unwrap();
    }
}
