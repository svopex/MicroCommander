// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Abstrakce virtuálního souborového systému (VFS).
//!
//! Všechna podporovaná úložiště (lokální disk, archivy ZIP/TAR, FTP, SFTP)
//! implementují společný trait `Vfs`. Souborové operace a hledání tak pracují
//! nad libovolnou dvojicí zdroj/cíl – kopírování disk→archiv, FTP→disk atd.
//! je stejný kód, jen s jinými implementacemi streamů.

use std::io::{Read, Write};

use crate::error::{SalError, SalResult};

/// Druh souborového systému; přenáší se přes FFI do UI
/// (např. pro ikonu panelu nebo zakázání zápisu do archivu).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VfsKind {
    Local,
    Zip,
    Tar,
    Ftp,
    Sftp,
}

impl VfsKind {
    /// Číselná reprezentace pro FFI (konstanty SAL_VFS_* v microcommander.h).
    pub fn as_i32(self) -> i32 {
        match self {
            VfsKind::Local => 1,
            VfsKind::Zip => 2,
            VfsKind::Tar => 3,
            VfsKind::Ftp => 4,
            VfsKind::Sftp => 5,
        }
    }
}

/// Druh položky ve výpisu adresáře.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VfsItemKind {
    File,
    Dir,
    Link,
}

/// Příznaky položky (bitová maska pro FFI).
pub const ITEM_FLAG_DIR: u32 = 1;
pub const ITEM_FLAG_LINK: u32 = 2;
pub const ITEM_FLAG_HIDDEN: u32 = 4;
pub const ITEM_FLAG_READONLY: u32 = 8;
/// Položka archivu je zašifrovaná (ZipCrypto nebo AES).
pub const ITEM_FLAG_ENCRYPTED: u32 = 16;

/// Jedna položka výpisu adresáře – obdoba CFileData z původního
/// Salamandera, zjednodušená na data dostupná ze všech VFS.
#[derive(Debug, Clone)]
pub struct VfsItem {
    /// Jméno bez cesty (UTF-8).
    pub name: String,
    /// Velikost souboru v bajtech; u adresářů 0.
    pub size: u64,
    /// Čas poslední změny jako unixový čas UTC (sekundy).
    pub mtime: i64,
    /// Druh položky (soubor/adresář/odkaz).
    pub kind: VfsItemKind,
    /// Skrytá položka (název začíná tečkou na unixových systémech).
    pub hidden: bool,
    /// Položka jen pro čtení.
    pub readonly: bool,
    /// Zašifrovaná položka archivu (čtení vyžaduje heslo).
    pub encrypted: bool,
}

impl VfsItem {
    /// Příznaky položky jako bitová maska (pro FFI i pro řazení v UI).
    pub fn flags(&self) -> u32 {
        let mut flags = 0u32;
        if self.kind == VfsItemKind::Dir {
            flags |= ITEM_FLAG_DIR;
        }
        if self.kind == VfsItemKind::Link {
            flags |= ITEM_FLAG_LINK;
        }
        if self.hidden {
            flags |= ITEM_FLAG_HIDDEN;
        }
        if self.readonly {
            flags |= ITEM_FLAG_READONLY;
        }
        if self.encrypted {
            flags |= ITEM_FLAG_ENCRYPTED;
        }
        flags
    }
}

/// Stream pro čtení obsahu souboru z libovolného VFS.
pub trait VfsReadStream: Read + Send {}
/// Stream pro zápis obsahu souboru do libovolného VFS.
pub trait VfsWriteStream: Write + Send {
    /// Dokončí zápis a potvrdí, že cíl data přijal (u FTP závěrečná odpověď
    /// serveru, u SFTP zavření souboru). Volá se po zapsání celého obsahu;
    /// stream zahozený bez `finish` (chyba, zrušení) se jen uzavře.
    fn finish(&mut self) -> std::io::Result<()> {
        self.flush()
    }
}

/// Společné rozhraní všech souborových systémů.
///
/// Cesty používají vždy lomítka `/` jako oddělovač a absolutní tvar
/// od kořene daného VFS (`/`, `/sub/adresar/soubor.txt`).
/// Jeden VFS používá UI z více vláken zároveň (výpis panelu na pozadí během
/// běžící operace), proto vyžadujeme `Send + Sync`; implementace si přístup
/// ke sdílenému stavu (spojení, heslo, dekompresní kurzor) zamykají samy.
pub trait Vfs: Send + Sync {
    /// Druh souborového systému.
    fn kind(&self) -> VfsKind;

    /// Krátký popis pro titulek panelu (např. cesta archivu nebo "FTP: host").
    fn label(&self) -> String;

    /// Vrátí výpis adresáře (bez `.` a `..`), nesetříděný – řazení dělá UI.
    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>>;

    /// Otevře soubor pro čtení (streamování).
    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>>;

    /// Otevře soubor pro zápis; `size_hint` může pomoci vzdáleným protokolům.
    /// Selže, pokud cíl existuje (konflikt řeší volající).
    fn open_write(&self, path: &str, size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>>;

    /// Vytvoří adresář (nevnořený; rodič už musí existovat).
    fn mkdir(&self, path: &str) -> SalResult<()>;

    /// Smaže soubor nebo (při `recursive`) neprázdný adresář.
    fn delete(&self, path: &str, recursive: bool) -> SalResult<()>;

    /// Smaže položku, jejíž druh volající už zná (z výpisu rodiče). Výchozí
    /// implementace volá `delete`; vzdálené VFS ji přepisují, aby se kvůli
    /// druhu položky znovu neptaly serveru.
    fn delete_known(&self, path: &str, _is_dir: bool, recursive: bool) -> SalResult<()> {
        self.delete(path, recursive)
    }

    /// Přejmenuje položku `path` na `new_name` (jen jméno, bez cesty).
    /// Existující jinou položku téhož jména nenahradí – vrátí AlreadyExists.
    fn rename(&self, path: &str, new_name: &str) -> SalResult<()>;

    /// Existuje položka na dané cestě?
    fn exists(&self, path: &str) -> SalResult<bool>;

    /// Je položka adresářem?
    fn is_dir(&self, path: &str) -> SalResult<bool>;

    /// Volné místo na úložišti v bajtech; `None` pokud nelze zjistit
    /// (archivy, vzdálené systémy bez podpory QUOTA).
    fn free_space(&self, _path: &str) -> SalResult<Option<u64>> {
        Ok(None)
    }

    /// Podporuje tento VFS zápis? (Archivy jsou v první verzi jen pro čtení.)
    fn writable(&self) -> bool {
        true
    }

    /// Přímý přístup k lokální implementaci, pokud jím VFS je.
    /// Slouží k optimalizaci přesunu v rámci jednoho disku (rename).
    fn as_local(&self) -> Option<&crate::local::LocalFs> {
        None
    }

    /// Cíl symbolického odkazu `path` (text, jak je v odkazu uložen).
    /// `None` = položka není odkaz, nebo VFS cíle odkazů číst neumí.
    fn read_link(&self, _path: &str) -> SalResult<Option<String>> {
        Ok(None)
    }

    /// Umí VFS vytvářet symbolické odkazy (`create_symlink`)?
    fn supports_symlinks(&self) -> bool {
        false
    }

    /// Vytvoří symbolický odkaz `path` ukazující na `target`.
    fn create_symlink(&self, _path: &str, _target: &str) -> SalResult<()> {
        Err(SalError::Io("Souborový systém nepodporuje symbolické odkazy.".to_string()))
    }

    /// Identita adresáře `dir` napříč instancemi VFS nad stejným úložištěm
    /// (dva lokální VFS, dvě připojení k témuž serveru): stejný řetězec =
    /// tentýž adresář. Podle ní se odmítá přenos do zdrojového adresáře.
    /// `None` = VFS identitu neumí (archivy); porovnává se pak jen instance.
    fn dir_identity(&self, _dir: &str) -> Option<String> {
        None
    }

    /// Může jádro před přenosem rekurzivně projít zdroj a spočítat celkovou
    /// velikost? U vzdálených protokolů (FTP/SFTP) by dvojitý výpis zbytečně
    /// prodlužoval operaci – vracíme false a progress běží bez celku.
    fn supports_size_scan(&self) -> bool {
        true
    }

    /// Nastaví heslo pro čtení šifrovaných položek (None = zapomenout).
    /// Vrací false, pokud VFS hesla nepodporuje.
    fn set_password(&self, _password: Option<&str>) -> bool {
        false
    }

    /// Obsahuje VFS šifrované položky (archiv s heslem)?
    fn has_encrypted(&self) -> bool {
        false
    }
}

/// Spojí adresář a jméno na cestu ve stylu VFS (vždy s lomítky).
pub fn join_path(dir: &str, name: &str) -> String {
    // Kořen nesmí dostat dvojité lomítko; prázdný adresář bereme jako kořen.
    if dir.is_empty() || dir == "/" {
        format!("/{}", name)
    } else {
        format!("{}/{}", dir, name)
    }
}

/// Sjednotí oddělovače na `/`, odstraní koncové lomítko (kromě kořene).
/// Používá se po naparsování cest z UI, které může pracovat s OS cestami.
pub fn normalize_vfs_path(path: &str) -> String {
    let mut normalized = path.replace('\\', "/");
    // Odstranění koncových lomítek (kořen "/" zůstane).
    while normalized.len() > 1 && normalized.ends_with('/') {
        normalized.pop();
    }
    if normalized.is_empty() {
        normalized.push('/');
    }
    normalized
}

/// Rozdělí cestu na (adresář, jméno). Kořen vrací ("/", "").
pub fn split_path(path: &str) -> (String, String) {
    let path = normalize_vfs_path(path);
    match path.rfind('/') {
        Some(0) => ("/".to_string(), path[1..].to_string()),
        Some(idx) => (path[..idx].to_string(), path[idx + 1..].to_string()),
        None => (String::new(), path),
    }
}

/// Nadřazený adresář cesty; kořen vrátí sám sebe.
pub fn parent_path(path: &str) -> String {
    let (dir, _) = split_path(path);
    if dir.is_empty() {
        "/".to_string()
    } else {
        dir
    }
}

/// Převede cestu VFS na absolutní cestu na vzdáleném serveru (FTP/SFTP),
/// kde kořen VFS odpovídá domovskému adresáři `home` (bez koncového lomítka;
/// domov v kořeni serveru je tedy prázdný řetězec).
pub fn remote_path(home: &str, vfs_path: &str) -> String {
    let path = normalize_vfs_path(vfs_path);
    if path != "/" {
        format!("{}{}", home, path)
    } else if home.is_empty() {
        // Kořen serveru (typicky chroot): prázdnou cestu servery odmítají.
        "/".to_string()
    } else {
        home.to_string()
    }
}

/// Převede občanské datum a čas v UTC na unixové sekundy. Používá algoritmus
/// „days from civil“ (Howard Hinnant) bez závislosti na knihovně pro práci
/// s časem; měsíc 1–12, den 1–31.
pub fn civil_to_unix(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) -> i64 {
    // Leden a únor patří do předchozího „březnového“ roku (přestupný den je
    // pak na jeho konci).
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    days * 86400 + hour * 3600 + minute * 60 + second
}

/// Převede SystemTime na unixové sekundy (čas před rokem 1970 / neznámý = 0).
pub fn system_time_to_unix(time: std::time::SystemTime) -> i64 {
    time.duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_join_and_normalize() {
        assert_eq!(join_path("/", "a"), "/a");
        assert_eq!(join_path("", "a"), "/a");
        assert_eq!(join_path("/x", "a"), "/x/a");
        assert_eq!(normalize_vfs_path("/x/"), "/x");
        assert_eq!(normalize_vfs_path("/x//"), "/x");
        assert_eq!(normalize_vfs_path("x\\y"), "x/y");
    }

    #[test]
    fn test_split_and_parent() {
        assert_eq!(
            split_path("/a/b/c.txt"),
            ("/a/b".to_string(), "c.txt".to_string())
        );
        assert_eq!(split_path("/c.txt"), ("/".to_string(), "c.txt".to_string()));
        assert_eq!(split_path("/"), ("/".to_string(), String::new()));
        assert_eq!(parent_path("/a/b"), "/a");
        assert_eq!(parent_path("/"), "/");
    }

    #[test]
    fn test_remote_path() {
        assert_eq!(remote_path("/home/user", "/"), "/home/user");
        assert_eq!(remote_path("/home/user", "/data/x.txt"), "/home/user/data/x.txt");
        // Domov v kořeni serveru (home je po oříznutí lomítka prázdný).
        assert_eq!(remote_path("", "/data"), "/data");
        assert_eq!(remote_path("", "/"), "/");
    }

    #[test]
    fn test_civil_to_unix() {
        assert_eq!(civil_to_unix(1970, 1, 1, 0, 0, 0), 0);
        assert_eq!(civil_to_unix(2024, 1, 2, 3, 4, 5), 1_704_164_645);
        // Přestupný den a den po něm.
        assert_eq!(civil_to_unix(2024, 3, 1, 0, 0, 0) - civil_to_unix(2024, 2, 29, 0, 0, 0), 86400);
        assert_eq!(civil_to_unix(1969, 12, 31, 23, 59, 59), -1);
    }
}
