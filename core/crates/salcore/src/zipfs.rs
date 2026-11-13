// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! ZIP archiv jako virtuální souborový systém (jen pro čtení).
//!
//! Podporuje zaheslované archivy: AES-128/192/256 (WinZip AE-1/AE-2)
//! i starší ZipCrypto. Výpis obsahu heslo nepotřebuje (metadata nejsou
//! šifrovaná), heslo se vyžaduje až při čtení obsahu šifrované položky –
//! bez hesla vrací jádro `PasswordRequired`, s chybným `InvalidPassword`.
//!
//! Archiv (centrální adresář) se čte jednou při otevření: metadata položek
//! (jméno, velikost, čas, šifrování) jdou do indexu – výpis adresáře ani
//! test existence pak archiv nečtou – a naparsovaný archiv si VFS drží.
//! Pro čtení obsahu dostane každý stream jeho levný klon (sdílená metadata,
//! vlastní pozice v souboru, viz `SharedFile`), takže víc souborů lze číst
//! zároveň bez zámku a bez opakovaného čtení centrálního adresáře.
//! Streamování obsahu používá self-referenční strukturu (ZipFile půjčuje
//! data z ZipArchive), řešenou rozšířením lifetime na heap-allocovaném archivu.

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use zip::read::{ZipArchive, ZipFile};
use zip::result::ZipError;

use crate::archive::{self, canonical_entry_name};
use crate::error::{SalError, SalResult};
use crate::vfs::{civil_to_unix, Vfs, VfsItem, VfsItemKind, VfsKind, VfsReadStream, VfsWriteStream};

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

/// Čtenář nad sdíleným souborem archivu s vlastní pozicí. Čte přes `pread`
/// (bez sdíleného ukazatele v souboru), takže klony – jeden na každý čtecí
/// stream – se navzájem neovlivňují ani při čtení z více vláken.
#[derive(Clone)]
struct SharedFile {
    file: Arc<File>,
    pos: u64,
}

impl Read for SharedFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = self.file.read_at(buf, self.pos)?;
        self.pos += read as u64;
        Ok(read)
    }
}

impl Seek for SharedFile {
    fn seek(&mut self, target: SeekFrom) -> io::Result<u64> {
        // Posun od začátku, od aktuální pozice, nebo od konce souboru.
        let new_pos = match target {
            SeekFrom::Start(offset) => Some(offset),
            SeekFrom::Current(delta) => self.pos.checked_add_signed(delta),
            SeekFrom::End(delta) => self.file.metadata()?.len().checked_add_signed(delta),
        };
        self.pos = new_pos
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Neplatná pozice v souboru archivu."))?;
        Ok(self.pos)
    }
}

/// Jedna položka indexu archivu (metadata z centrálního adresáře).
struct ZipIndexEntry {
    /// Pořadové číslo položky v archivu – podle něj se otevírá obsah
    /// (nezávisle na tom, jak je jméno v archivu zapsané).
    archive_index: usize,
    size: u64,
    mtime: i64,
    kind: VfsItemKind,
    /// Položka je zašifrovaná (ZipCrypto nebo AES).
    encrypted: bool,
}

/// VFS nad ZIP archivem na disku.
pub struct ZipFs {
    /// Cesta k souboru archivu na lokálním disku.
    archive_path: PathBuf,
    /// Naparsovaný archiv; čtecí streamy si berou jeho klon.
    archive: ZipArchive<SharedFile>,
    /// Index položek podle kanonického jména (sestavený při otevření).
    index: BTreeMap<String, ZipIndexEntry>,
    /// Heslo pro šifrované položky (zadává UI, platí pro celý archiv).
    password: Mutex<Option<String>>,
    /// Archiv obsahuje alespoň jednu šifrovanou položku.
    any_encrypted: bool,
}

impl ZipFs {
    /// Otevře ZIP archiv a sestaví index položek (obsah souborů se nečte).
    pub fn open(archive_path: &Path) -> SalResult<ZipFs> {
        // Ověření, že jde o čitelný ZIP; selže u poškozených souborů hned.
        let file = SharedFile { file: Arc::new(File::open(archive_path)?), pos: 0 };
        let mut archive = ZipArchive::new(file)?;
        let mut index = BTreeMap::new();
        let mut any_encrypted = false;
        for archive_index in 0..archive.len() {
            // Raw přístup čte jen metadata – funguje i u šifrovaných položek bez hesla.
            let file = archive.by_index_raw(archive_index)?;
            let name = canonical_entry_name(file.name());
            if name.is_empty() {
                // Záznam samotného kořene archivu („./“) není položka výpisu.
                continue;
            }
            // Adresář má v archivu jméno zakončené lomítkem a nenese data.
            let is_dir = file.is_dir();
            let encrypted = file.encrypted() && !is_dir;
            any_encrypted |= encrypted;
            let entry = ZipIndexEntry {
                archive_index,
                size: if is_dir { 0 } else { file.size() },
                mtime: zip_time_to_unix(file.last_modified().unwrap_or_default()),
                kind: if is_dir { VfsItemKind::Dir } else { VfsItemKind::File },
                encrypted,
            };
            // U duplicitních jmen platí poslední záznam (jako při rozbalování).
            index.insert(name, entry);
        }
        Ok(ZipFs {
            archive_path: archive_path.to_path_buf(),
            archive,
            index,
            password: Mutex::new(None),
            any_encrypted,
        })
    }

    /// Aktuální heslo (kopie, aby se zámek nedržel během čtení).
    fn current_password(&self) -> Option<String> {
        self.password.lock().ok().and_then(|guard| guard.clone())
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
    file: Option<ZipFile<'static, SharedFile>>,
    _archive: Box<ZipArchive<SharedFile>>,
}

impl ZipReadStream {
    /// Otevře položku číslo `index` pro streamované čtení nad vlastním klonem
    /// archivu. Šifrovaná položka (`encrypted`, známo z indexu) se dešifruje
    /// zadaným heslem; bez hesla → PasswordRequired.
    fn open(archive: ZipArchive<SharedFile>, index: usize, encrypted: bool, password: Option<&str>) -> SalResult<ZipReadStream> {
        let mut archive = Box::new(archive);

        // SAFETY: Rozšíření lifetime je bezpečné, protože:
        // 1) archiv je vlastněn touto strukturou (Box) a jeho adresa na hromadě
        //    se při přesunu struktury nemění,
        // 2) ZipFile je uvolněn (drop) dříve než archiv – viz pořadí polí,
        // 3) nikdo jiný nemá k archivu přístup, dokud stream žije.
        let zip_file = unsafe {
            let archive_ref: &'static mut ZipArchive<SharedFile> =
                &mut *(&mut *archive as *mut ZipArchive<SharedFile>);
            // Heslo předáme jen šifrované položce; nešifrovanou čteme normálně.
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
pub fn zip_time_to_unix(date_time: zip::DateTime) -> i64 {
    civil_to_unix(
        i64::from(date_time.year()),
        i64::from(date_time.month()),
        i64::from(date_time.day()),
        i64::from(date_time.hour()),
        i64::from(date_time.minute()),
        i64::from(date_time.second()),
    )
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
        Ok(archive::list_dir(&self.index, path, |name, entry| VfsItem {
            name: name.to_string(),
            size: entry.size,
            mtime: entry.mtime,
            kind: entry.kind,
            hidden: name.starts_with('.'),
            readonly: true,
            encrypted: entry.encrypted,
            link_to_dir: false,
        }))
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        // Číst lze jen soubor; adresář (i implikovaný) obsah nemá.
        let entry = archive::find_entry(&self.index, path)
            .filter(|entry| entry.kind == VfsItemKind::File)
            .ok_or(SalError::NotFound)?;
        let password = self.current_password();
        Ok(Box::new(ZipReadStream::open(
            self.archive.clone(),
            entry.archive_index,
            entry.encrypted,
            password.as_deref(),
        )?))
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
        Ok(archive::exists(&self.index, path))
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        Ok(archive::is_dir(&self.index, path, |entry| entry.kind == VfsItemKind::Dir))
    }

    fn writable(&self) -> bool {
        false
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

    /// Archiv s vlastními záznamy adresářů (tak je píše většina programů
    /// i `pack_zip`): adresář musí být ve výpisu adresářem, i prázdný,
    /// a jména zapsaná s „./“ nebo zpětnými lomítky se čtou.
    #[test]
    fn test_zip_directory_entries() {
        let base = std::env::temp_dir().join(format!("salcore-zipdirs-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let zip_path = base.join("dirs.zip");
        let mut writer = zip::ZipWriter::new(File::create(&zip_path).unwrap());
        let options: zip::write::SimpleFileOptions = Default::default();
        writer.add_directory("pod", options).unwrap();
        writer.start_file("pod/b.txt", options).unwrap();
        writer.write_all(b"obsah b").unwrap();
        writer.add_directory("prazdny", options).unwrap();
        writer.start_file("./tecka/c.txt", options).unwrap();
        writer.write_all(b"obsah c").unwrap();
        writer.start_file("win\\d.txt", options).unwrap();
        writer.write_all(b"obsah d").unwrap();
        writer.finish().unwrap();

        let vfs = ZipFs::open(&zip_path).unwrap();
        let root: Vec<(String, VfsItemKind)> =
            vfs.list("/").unwrap().into_iter().map(|item| (item.name, item.kind)).collect();
        let dir = |name: &str| (name.to_string(), VfsItemKind::Dir);
        assert_eq!(root, vec![dir("pod"), dir("prazdny"), dir("tecka"), dir("win")]);
        assert!(vfs.is_dir("/prazdny").unwrap());
        assert!(vfs.list("/prazdny").unwrap().is_empty());
        assert!(vfs.exists("/tecka/c.txt").unwrap());
        assert!(!vfs.exists("/neni").unwrap());
        // Adresář nelze číst jako soubor.
        assert!(vfs.open_read("/pod").is_err());
        for (path, expected) in [("/pod/b.txt", "obsah b"), ("/tecka/c.txt", "obsah c"), ("/win/d.txt", "obsah d")] {
            let mut content = String::new();
            vfs.open_read(path).unwrap().read_to_string(&mut content).unwrap();
            assert_eq!(content, expected);
        }
        fs::remove_dir_all(&base).unwrap();
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

        fs::remove_dir_all(&base).unwrap();
    }
}
