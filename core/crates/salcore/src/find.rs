// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Rekurzivní hledání souborů a adresářů nad libovolným VFS.
//!
//! Odpovídá funkci Find ze Salamandera: prochází adresářovou strukturu
//! od zadaného kořene a hledá položky odpovídající masce (viz `mask`).
//! Nalezené položky hlásí zpětným voláním, průběh a zrušení řeší
//! stejný progress jako souborové operace.
//!
//! Volitelně prohledává i archivy na lokálním disku (ZIP, TAR, TAR.GZ):
//! soubor s příponou archivu se otevře jako VFS a projde stejnou maskou
//! i hledáním v obsahu; nález pak nese cestu archivu a cestu uvnitř něj.

use std::path::Path;

use crate::archive::{is_archive_name, open_archive};
use crate::error::{SalError, SalResult};
use crate::mask::MaskGroup;
use crate::ops::ProgressCallback;
use crate::vfs::{join_path, Vfs, VfsItem, VfsItemKind};
use regex::bytes::{Regex, RegexBuilder};
use std::io::Read;

/// Výsledek hledání: počet prohledaných a nalezených položek a chyb
/// (nečitelné adresáře či soubory se přeskočí, jako ve Find logu Salamandera).
#[derive(Debug, Default, Clone, Copy)]
pub struct FindStats {
    pub scanned: u64,
    pub found: u64,
    pub errors: u64,
}

/// Volby hledání odpovídající dialogu Find Salamandera.
pub struct FindOptions {
    /// Procházet i podadresáře (Search subdirectories).
    pub subdirs: bool,
    /// Hlásit i adresáře odpovídající masce (při hledání v obsahu se ignoruje).
    pub include_dirs: bool,
    /// Hledání v obsahu souborů (Search file content + Containing).
    pub content: Option<ContentMatcher>,
    /// Prohledat i obsah archivů na lokálním disku (soubory s příponou archivu,
    /// viz `archive::is_archive_name`); podadresáře archivu se řídí volbou `subdirs`.
    pub archives: bool,
}

/// Hledaný obsah souboru – vše se převádí na regulární výraz nad bajty.
pub struct ContentMatcher {
    regex: Regex,
    /// Regulární výraz se v Salamanderu vyhodnocuje po řádcích; prostý text
    /// a HEX vzor mohou přesahovat konec řádku (čte se s překryvem).
    line_based: bool,
    /// Délka prostého vzoru v bajtech (určuje překryv bloků).
    literal_len: usize,
}

/// Velikost bloku při čtení obsahu souboru.
const CONTENT_CHUNK: usize = 256 * 1024;
/// Nejdelší řádek, který se drží celý při hledání regulárním výrazem;
/// delší se zkrátí (ochrana paměti u binárních souborů bez konců řádků).
const MAX_LINE_CARRY: usize = 64 * 1024;

impl ContentMatcher {
    /// Sestaví hledání obsahu.
    ///
    /// Parametry:
    /// - `pattern` – hledané bajty (u HEX režimu už převedené z textu na bajty)
    ///   nebo text regulárního výrazu,
    /// - `case_sensitive` – rozlišovat velikost písmen,
    /// - `whole_words` – shoda jen celých slov (před i za vzorem oddělovač nebo
    ///   začátek/konec řádku),
    /// - `regex` – `pattern` je regulární výraz (jinak prostý text),
    /// - `hex` – `pattern` jsou syrové bajty (porovnávají se přesně).
    pub fn new(pattern: &[u8], case_sensitive: bool, whole_words: bool, regex: bool, hex: bool) -> SalResult<Self> {
        if pattern.is_empty() {
            return Err(SalError::Io("Prázdný řetězec zde není povolen.".to_string()));
        }
        // Prostý text i HEX vzor se escapují na bajtové literály \xHH (bez Unicode,
        // aby šly hledat i bajty mimo UTF-8); regulární výraz se bere tak, jak je.
        let core = if regex && !hex {
            String::from_utf8_lossy(pattern).into_owned()
        } else if hex {
            pattern.iter().map(|byte| format!("\\x{:02X}", byte)).collect::<String>()
        } else {
            regex::escape(&String::from_utf8_lossy(pattern))
        };
        // Celá slova: před a za vzorem nesmí být písmeno, číslice ani podtržítko.
        let body = if whole_words {
            format!("(?:^|[^\\w])(?:{})(?:$|[^\\w])", core)
        } else {
            core
        };
        // HEX režim porovnává bajty přesně (bez Unicode a bez ignorování velikosti).
        // CRLF režim: `$` a `^` berou jako konec řádku i „\r\n“ (soubory
        // z Windows), jinak by `$` před „\r“ nikdy neseděl.
        let compiled = RegexBuilder::new(&body)
            .case_insensitive(!case_sensitive && !hex)
            .multi_line(true)
            .crlf(true)
            .unicode(!hex)
            .build()
            .map_err(|e| SalError::Io(format!("Chybný regulární výraz: {}", e)))?;
        Ok(ContentMatcher {
            regex: compiled,
            line_based: regex && !hex,
            literal_len: pattern.len() + 2,
        })
    }

    /// Prohledá obsah streamu; vrací `true` při první shodě.
    /// `cancelled` se volá mezi bloky a umožní čtení velkého souboru přerušit.
    pub fn matches_stream(&self, reader: &mut dyn Read, cancelled: &mut dyn FnMut() -> bool) -> SalResult<bool> {
        self.matches_stream_with(reader, &mut Vec::new(), cancelled)
    }

    /// Jako `matches_stream`, ale s pracovním bufferem volajícího – při hledání
    /// se jeden buffer použije pro všechny soubory (bez alokace na soubor).
    fn matches_stream_with(
        &self,
        reader: &mut dyn Read,
        buffer: &mut Vec<u8>,
        cancelled: &mut dyn FnMut() -> bool,
    ) -> SalResult<bool> {
        buffer.clear();
        loop {
            if cancelled() {
                return Err(SalError::Cancelled);
            }
            // Čtení rovnou na konec bufferu (bez mezibufferu a kopie bloku).
            let filled = buffer.len();
            buffer.resize(filled + CONTENT_CHUNK, 0);
            let read = reader.read(&mut buffer[filled..]).map_err(SalError::from)?;
            buffer.truncate(filled + read);
            if read == 0 {
                // Konec souboru: dohledat zbytek bufferu.
                return Ok(!buffer.is_empty() && self.regex.is_match(buffer));
            }
            if self.line_based {
                // Po řádcích: prohledat vše do posledního konce řádku, zbytek
                // (rozpracovaný řádek) přenést do dalšího bloku.
                if let Some(last_newline) = buffer.iter().rposition(|&byte| byte == b'\n') {
                    if self.regex.is_match(&buffer[..=last_newline]) {
                        return Ok(true);
                    }
                    buffer.drain(..=last_newline);
                } else if buffer.len() > MAX_LINE_CARRY {
                    if self.regex.is_match(buffer) {
                        return Ok(true);
                    }
                    let keep_from = buffer.len() - MAX_LINE_CARRY / 2;
                    buffer.drain(..keep_from);
                }
            } else {
                // Prostý vzor: prohledat blok a ponechat překryv délky vzoru,
                // aby se našla i shoda přes hranici bloků.
                if self.regex.is_match(buffer) {
                    return Ok(true);
                }
                if buffer.len() > self.literal_len {
                    let keep_from = buffer.len() - self.literal_len;
                    buffer.drain(..keep_from);
                }
            }
        }
    }
}

/// Upraví masky pro hledání podle pravidla Salamandera: maska bez `*`, `?`
/// a `.` hledá jména, která ji obsahují („dog“ → „*dog*“); tečka na konci
/// tomu zabrání („dog.“ najde jen „dog“). Platí pro každou masku skupiny
/// (oddělené `;`) i pro vylučovací část za `|`.
pub fn find_mask_string(masks: &str) -> String {
    masks
        .split('|')
        .map(|part| {
            part.split(';')
                .map(|mask| {
                    let trimmed = mask.trim();
                    if trimmed.is_empty() || trimmed.contains(['*', '?', '.']) {
                        trimmed.to_string()
                    } else {
                        format!("*{}*", trimmed)
                    }
                })
                .collect::<Vec<_>>()
                .join(";")
        })
        .collect::<Vec<_>>()
        .join("|")
}

/// Spustí rekurzivní hledání (zachovaná jednoduchá varianta: všechny
/// podadresáře, bez hledání v obsahu).
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
    let options = FindOptions { subdirs: true, include_dirs, content: None, archives: false };
    find_items_ex(vfs, root, mask, &options, progress, &mut |_| {}, &mut |_, path, item| on_found(path, item))
}

/// Hledání s volbami dialogu Find.
///
/// Parametry jako u `find_items`, navíc:
/// - `options` – podadresáře, adresáře ve výsledcích, hledání v obsahu,
///   hledání v archivech,
/// - `on_dir` – hlášení právě prohledávaného adresáře (stavový řádek);
///   uvnitř archivu cesta archivu + cesta v něm,
/// - `on_found` – první parametr je cesta archivu (ve `vfs`), ve kterém
///   položka leží (`None` = položka přímo ve `vfs`), druhý cesta položky
///   (u archivu cesta uvnitř něj).
///
/// Nečitelný výchozí adresář je chyba; nečitelné podadresáře, soubory
/// a poškozené archivy se přeskočí a započítají do `FindStats::errors`.
pub fn find_items_ex(
    vfs: &dyn Vfs,
    root: &str,
    mask: &MaskGroup,
    options: &FindOptions,
    progress: &mut dyn ProgressCallback,
    on_dir: &mut dyn FnMut(&str),
    on_found: &mut dyn FnMut(Option<&str>, &str, &VfsItem) -> bool,
) -> SalResult<FindStats> {
    // Výchozí adresář musí jít přečíst – jinak hlásíme chybu (např. neexistuje).
    let children = vfs.list(root)?;
    let mut search = Search {
        vfs,
        mask,
        options,
        progress,
        on_dir,
        on_found,
        stats: FindStats::default(),
        buffer: Vec::new(),
        archive: None,
        deferred: Vec::new(),
    };
    search.scan_dir(root, children)?;
    search.check_deferred()?;
    Ok(search.stats)
}

/// Stav jednoho běhu hledání (sdílené parametry rekurze).
struct Search<'a> {
    vfs: &'a dyn Vfs,
    mask: &'a MaskGroup,
    options: &'a FindOptions,
    progress: &'a mut dyn ProgressCallback,
    on_dir: &'a mut dyn FnMut(&str),
    on_found: &'a mut dyn FnMut(Option<&str>, &str, &VfsItem) -> bool,
    stats: FindStats,
    /// Pracovní buffer hledání v obsahu (sdílený pro všechny soubory).
    buffer: Vec<u8>,
    /// Cesta právě prohledávaného archivu ve vnějším VFS; `None` = hledá se
    /// přímo ve `vfs` (archiv v archivu se neotevírá).
    archive: Option<&'a str>,
    /// Soubory čekající na kontrolu obsahu: pořadí dat (`Vfs::read_order`),
    /// cesta a položka. Odkládají se jen ve VFS, kde na pořadí čtení záleží
    /// (TAR), a zkontrolují se po průchodu v pořadí dat, viz `check_deferred`.
    deferred: Vec<(u64, String, VfsItem)>,
}

impl Search<'_> {
    /// Projde položky jednoho adresáře. Zrušení hledání (progresem nebo
    /// zpětným voláním) vrací jako `Err(SalError::Cancelled)`.
    fn scan_dir(&mut self, dir: &str, children: Vec<VfsItem>) -> SalResult<()> {
        self.report_dir(dir);
        for child in &children {
            // Průběh hlásíme po položkách; total=0 = neznámý celek.
            self.stats.scanned += 1;
            if !self.progress.on_progress(self.stats.scanned, 0) {
                return Err(SalError::Cancelled);
            }

            let is_dir = child.kind == VfsItemKind::Dir;
            let descend = is_dir && self.options.subdirs;
            // Adresáře se hlásí jen bez hledání v obsahu a když to volající chce
            // (masku u adresáře testujeme, jen když se může hlásit).
            let report_dirs = self.options.include_dirs && self.options.content.is_none();
            let name_matches = (!is_dir || report_dirs) && self.mask.matches(&child.name);
            // Archiv k prohledání: běžný soubor (ne odkaz) s příponou archivu
            // na lokálním disku; uvnitř archivu se další archivy neotevírají.
            let is_archive = self.options.archives
                && self.archive.is_none()
                && child.kind == VfsItemKind::File
                && is_archive_name(&child.name);
            // Cestu skládáme jen pro shodu, sestup do podadresáře nebo archiv.
            if !name_matches && !descend && !is_archive {
                continue;
            }
            let path = join_path(dir, &child.name);
            let matches = if is_dir || !name_matches {
                name_matches
            } else if let Some(content) = &self.options.content {
                match self.vfs.read_order(&path) {
                    // Kde záleží na pořadí čtení, kontroluje se obsah až nakonec.
                    Some(order) => {
                        self.deferred.push((order, path.clone(), child.clone()));
                        false
                    }
                    None => self.file_matches(&path, content)?,
                }
            } else {
                true
            };
            if matches {
                self.report(&path, child)?;
            }

            // Archiv se prohledá jako podadresář (otevírá se ze souboru na disku).
            if is_archive {
                if let Some(disk_path) = self.vfs.as_local().map(|local| local.disk_path(&path)) {
                    self.scan_archive(&path, &disk_path)?;
                }
            }

            // Rekurzivně do podadresářů (odkazy nenásledujeme, aby hledání
            // nezacyklilo); nečitelný podadresář se přeskočí.
            if descend {
                match self.vfs.list(&path) {
                    Ok(sub_children) => self.scan_dir(&path, sub_children)?,
                    Err(_) => self.stats.errors += 1,
                }
            }
        }
        Ok(())
    }

    /// Ohlásí nalezenou položku; odmítnutí zpětným voláním hledání zruší.
    fn report(&mut self, path: &str, item: &VfsItem) -> SalResult<()> {
        self.stats.found += 1;
        if (self.on_found)(self.archive, path, item) {
            Ok(())
        } else {
            Err(SalError::Cancelled)
        }
    }

    /// Ohlásí právě prohledávaný adresář; uvnitř archivu s cestou archivu
    /// na začátku (kořen archivu = jen cesta archivu).
    fn report_dir(&mut self, dir: &str) {
        match self.archive {
            Some(archive) => {
                let inner = if dir == "/" { "" } else { dir };
                (self.on_dir)(&format!("{}{}", archive, inner));
            }
            None => (self.on_dir)(dir),
        }
    }

    /// Prohledá archiv na disku stejnou maskou a volbami jako okolní adresáře.
    /// Soubor, který archivem není, se tiše přeskočí; poškozený archiv se
    /// započítá mezi chyby.
    ///
    /// Parametry:
    /// - `archive_path` – cesta archivu ve VFS (hlásí se u nálezů),
    /// - `disk_path` – tentýž soubor na disku (odtud se otevírá).
    fn scan_archive(&mut self, archive_path: &str, disk_path: &Path) -> SalResult<()> {
        let opened = open_archive(disk_path).and_then(|archive| match archive {
            Some(archive) => archive.list("/").map(|children| Some((archive, children))),
            None => Ok(None),
        });
        let (archive, children) = match opened {
            Ok(Some(opened)) => opened,
            Ok(None) => return Ok(()),
            Err(_) => {
                self.stats.errors += 1;
                return Ok(());
            }
        };
        // Vnořené hledání nad VFS archivu: sdílí zpětná volání, statistiku
        // i pracovní buffer s vnějším hledáním.
        let mut inner = Search {
            vfs: archive.as_ref(),
            mask: self.mask,
            options: self.options,
            progress: &mut *self.progress,
            on_dir: &mut *self.on_dir,
            on_found: &mut *self.on_found,
            stats: self.stats,
            buffer: std::mem::take(&mut self.buffer),
            archive: Some(archive_path),
            deferred: Vec::new(),
        };
        let result = inner.scan_dir("/", children).and_then(|()| inner.check_deferred());
        self.stats = inner.stats;
        self.buffer = inner.buffer;
        result
    }

    /// Zkontroluje obsah souborů odložených při průchodu a ohlásí ty, které
    /// vzor obsahují. Jdou v pořadí dat (`Vfs::read_order`), aby proudový
    /// archiv (TAR.GZ) stačilo projít jednou místo dekomprese od začátku pro
    /// každý soubor.
    fn check_deferred(&mut self) -> SalResult<()> {
        let Some(content) = self.options.content.as_ref() else {
            return Ok(());
        };
        let mut files = std::mem::take(&mut self.deferred);
        files.sort_by_key(|(order, _, _)| *order);
        // Pevné odkazy sdílejí data (stejné pořadí) – výsledek prvního platí
        // i pro další a kurzor archivu se kvůli nim nevrací.
        let mut last: Option<(u64, bool)> = None;
        for (order, path, item) in &files {
            let found = match last {
                Some((last_order, found)) if last_order == *order => found,
                _ => self.file_matches(path, content)?,
            };
            last = Some((*order, found));
            if found {
                self.report(path, item)?;
            }
        }
        Ok(())
    }

    /// Obsahuje soubor hledaný vzor? Nečitelný soubor (práva, zámek,
    /// zaheslovaná položka archivu) se přeskočí a započítá jako chyba;
    /// `Err` vrací jen zrušené hledání.
    fn file_matches(&mut self, path: &str, content: &ContentMatcher) -> SalResult<bool> {
        match self.file_contains(path, content) {
            Err(SalError::Cancelled) => Err(SalError::Cancelled),
            Err(_) => {
                self.stats.errors += 1;
                Ok(false)
            }
            found => found,
        }
    }

    /// Prohledá obsah souboru; mezi bloky se ptá progresu na zrušení.
    fn file_contains(&mut self, path: &str, content: &ContentMatcher) -> SalResult<bool> {
        let mut stream = self.vfs.open_read(path)?;
        let scanned = self.stats.scanned;
        let progress = &mut *self.progress;
        content.matches_stream_with(&mut stream, &mut self.buffer, &mut || !progress.on_progress(scanned, 0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local::LocalFs;
    use crate::ops::NoProgress;
    use std::fs;
    use std::path::{Path, PathBuf};

    /// Adresář: data/pod/x.txt, data/y.log, data/pod/pod2/z.txt;
    /// `tag` odliší adresáře paralelně běžících testů.
    fn prepare(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("salcore-find-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("pod").join("pod2")).unwrap();
        fs::write(base.join("pod").join("x.txt"), b"x").unwrap();
        fs::write(base.join("y.log"), b"y").unwrap();
        fs::write(base.join("pod").join("pod2").join("z.txt"), b"z").unwrap();
        base
    }

    #[test]
    fn test_find_by_mask() {
        let base = prepare("mask");
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

    #[test]
    fn test_find_mask_string() {
        // Maska bez *, ? a . = „obsahuje“; tečka na konci = přesné jméno.
        assert_eq!(find_mask_string("dog"), "*dog*");
        assert_eq!(find_mask_string("dog."), "dog.");
        assert_eq!(find_mask_string("*.txt;log"), "*.txt;*log*");
        assert_eq!(find_mask_string("a|tmp"), "*a*|*tmp*");
        let group = MaskGroup::new(&find_mask_string("dog"), true).unwrap();
        assert!(group.matches("hotdog.jpg"));
        assert!(group.matches("dogs.txt"));
        let group = MaskGroup::new(&find_mask_string("dog."), true).unwrap();
        assert!(group.matches("dog"));
        assert!(!group.matches("dogs"));
    }

    #[test]
    fn test_content_matcher() {
        let text = b"Hello Car world\nsecond line carpet\n\x01\x02 end".to_vec();
        let check = |matcher: ContentMatcher| {
            matcher.matches_stream(&mut text.as_slice(), &mut || false).unwrap()
        };
        // Velikost písmen.
        assert!(check(ContentMatcher::new(b"car", false, false, false, false).unwrap()));
        assert!(!check(ContentMatcher::new(b"CAR", true, false, false, false).unwrap()));
        // Celá slova: „car“ jako slovo (Car), ne jen část slova „carpet“.
        assert!(check(ContentMatcher::new(b"car", false, true, false, false).unwrap()));
        assert!(!check(ContentMatcher::new(b"carp", false, true, false, false).unwrap()));
        // Regulární výraz po řádcích.
        assert!(check(ContentMatcher::new(b"^second.*pet$", true, false, true, false).unwrap()));
        assert!(!check(ContentMatcher::new(b"world.second", true, false, true, false).unwrap()));
        // Konec řádku ve stylu Windows (CRLF) je pro `$` také konec řádku.
        let crlf = b"prvni radek\r\ndruhy radek\r\n".to_vec();
        let ends_line = ContentMatcher::new(b"prvni radek$", true, false, true, false).unwrap();
        assert!(ends_line.matches_stream(&mut crlf.as_slice(), &mut || false).unwrap());
        // HEX vzor (bajty přesně).
        assert!(check(ContentMatcher::new(&[1, 2, b' '], true, false, false, true).unwrap()));
        assert!(!check(ContentMatcher::new(&[2, 1], true, false, false, true).unwrap()));
        // Neplatný regulární výraz je chyba.
        assert!(ContentMatcher::new(b"(", true, false, true, false).is_err());

        // Shoda přes hranici bloků (velký soubor s vzorem na rozhraní).
        let mut big = vec![b'x'; CONTENT_CHUNK - 3];
        big.extend_from_slice(b"needle");
        big.extend(vec![b'y'; 1000]);
        let matcher = ContentMatcher::new(b"needle", true, false, false, false).unwrap();
        assert!(matcher.matches_stream(&mut big.as_slice(), &mut || false).unwrap());
    }

    #[test]
    fn test_find_with_options() {
        let base = prepare("options");
        fs::write(base.join("pod").join("x.txt"), b"obsah se SLOVEM uvnitr").unwrap();
        let vfs = LocalFs::new(base.to_str()).unwrap();
        let mask = MaskGroup::new("*", true).unwrap();

        // Bez podadresářů: jen položky kořene (y.log a adresář pod).
        let options = FindOptions { subdirs: false, include_dirs: true, content: None, archives: false };
        let mut found: Vec<String> = Vec::new();
        find_items_ex(&vfs, "/", &mask, &options, &mut NoProgress, &mut |_| {}, &mut |_, path, _| {
            found.push(path.to_string());
            true
        })
        .unwrap();
        found.sort();
        assert_eq!(found, vec!["/pod".to_string(), "/y.log".to_string()]);

        // Hledání v obsahu: jen soubor s textem, adresáře se nehlásí.
        let content = ContentMatcher::new(b"slovem", false, true, false, false).unwrap();
        let options = FindOptions { subdirs: true, include_dirs: true, content: Some(content), archives: false };
        let mut found: Vec<String> = Vec::new();
        let mut dirs: Vec<String> = Vec::new();
        find_items_ex(&vfs, "/", &mask, &options, &mut NoProgress, &mut |dir| dirs.push(dir.to_string()), &mut |_, path, _| {
            found.push(path.to_string());
            true
        })
        .unwrap();
        assert_eq!(found, vec!["/pod/x.txt".to_string()]);
        assert!(dirs.contains(&"/pod/pod2".to_string()));

        // Neexistující výchozí adresář je chyba.
        let options = FindOptions { subdirs: true, include_dirs: true, content: None, archives: false };
        assert!(find_items_ex(&vfs, "/neni", &mask, &options, &mut NoProgress, &mut |_| {}, &mut |_, _, _| true).is_err());

        fs::remove_dir_all(&base).unwrap();
    }

    /// Zdrojový strom pro testovací archivy: top.txt, a.log, doc/readme.txt
    /// (s textem „tajne heslo“), zz/last.txt.
    fn prepare_archive_source(tag: &str) -> PathBuf {
        let source = std::env::temp_dir().join(format!("salcore-find-src-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&source);
        fs::create_dir_all(source.join("doc")).unwrap();
        fs::create_dir_all(source.join("zz")).unwrap();
        fs::write(source.join("top.txt"), b"nahore").unwrap();
        fs::write(source.join("a.log"), b"protokol").unwrap();
        fs::write(source.join("doc").join("readme.txt"), b"zde je tajne heslo").unwrap();
        fs::write(source.join("zz").join("last.txt"), b"konec").unwrap();
        source
    }

    /// Zabalí zdrojový strom do ZIP (volitelně šifrovaného).
    fn write_zip(source: &Path, dest: &Path, encryption: &crate::pack::PackEncryption) {
        let vfs = LocalFs::new(source.to_str()).unwrap();
        crate::pack::pack_zip(&vfs, "/", &["top.txt", "a.log", "doc", "zz"], dest, encryption, &mut NoProgress).unwrap();
    }

    /// Zabalí zdrojový strom do TAR; položky jdou v jiném pořadí, než v jakém
    /// je hledání prochází (zz/ před doc/) – ověřuje čtení v pořadí dat.
    fn write_tar(source: &Path, dest: &Path) {
        let mut builder = tar::Builder::new(fs::File::create(dest).unwrap());
        for name in ["zz/last.txt", "top.txt", "doc/readme.txt", "a.log"] {
            builder.append_path_with_name(source.join(name), name).unwrap();
        }
        builder.finish().unwrap();
    }

    /// Spustí hledání a vrátí statistiku, nálezy „archiv|cesta“ (seřazené)
    /// a hlášené adresáře.
    fn run_find(vfs: &dyn Vfs, root: &str, mask: &str, options: &FindOptions) -> (FindStats, Vec<String>, Vec<String>) {
        let mask = MaskGroup::new(mask, true).unwrap();
        let mut found: Vec<String> = Vec::new();
        let mut dirs: Vec<String> = Vec::new();
        let stats = find_items_ex(
            vfs,
            root,
            &mask,
            options,
            &mut NoProgress,
            &mut |dir| dirs.push(dir.to_string()),
            &mut |archive, path, _| {
                found.push(format!("{}|{}", archive.unwrap_or(""), path));
                true
            },
        )
        .unwrap();
        found.sort();
        (stats, found, dirs)
    }

    #[test]
    fn test_find_in_archives() {
        use std::io::Write;

        let base = prepare("archives");
        let source = prepare_archive_source("archives");
        // Archivy: ZIP v kořeni, TAR a TAR.GZ v podadresáři.
        write_zip(&source, &base.join("data.zip"), &crate::pack::PackEncryption::None);
        write_tar(&source, &base.join("pod").join("t.tar"));
        let mut encoder = flate2::write::GzEncoder::new(
            fs::File::create(base.join("pod").join("t.TGZ")).unwrap(),
            flate2::Compression::default(),
        );
        encoder.write_all(&fs::read(base.join("pod").join("t.tar")).unwrap()).unwrap();
        encoder.finish().unwrap();
        // Soubor s příponou archivu, který archivem není – tiše se přeskočí.
        fs::write(base.join("pod").join("neni.zip"), b"jen text").unwrap();
        let vfs = LocalFs::new(base.to_str()).unwrap();

        // Bez volby se archivy neotevírají.
        let options = FindOptions { subdirs: true, include_dirs: false, content: None, archives: false };
        let (_, found, _) = run_find(&vfs, "/", "readme.txt", &options);
        assert!(found.is_empty());

        // S volbou: položka se najde ve všech třech archivech, s cestou archivu.
        let options = FindOptions { subdirs: true, include_dirs: false, content: None, archives: true };
        let (stats, found, dirs) = run_find(&vfs, "/", "readme.txt", &options);
        assert_eq!(
            found,
            ["/data.zip|/doc/readme.txt", "/pod/t.TGZ|/doc/readme.txt", "/pod/t.tar|/doc/readme.txt"]
        );
        assert_eq!(stats.errors, 0);
        // Stavový řádek: kořen archivu i adresář uvnitř.
        assert!(dirs.contains(&"/data.zip".to_string()));
        assert!(dirs.contains(&"/pod/t.tar/doc".to_string()));

        // Archiv sám je i běžný soubor odpovídající masce.
        let (_, found, _) = run_find(&vfs, "/", "*.zip", &options);
        assert_eq!(found, ["|/data.zip", "|/pod/neni.zip"]);

        // Bez podadresářů: archiv v prohledávaném adresáři se otevře, ale jen jeho kořen.
        let flat = FindOptions { subdirs: false, include_dirs: false, content: None, archives: true };
        let (_, found, _) = run_find(&vfs, "/", "*.txt", &flat);
        assert_eq!(found, ["/data.zip|/top.txt"]);

        // Hledání v obsahu uvnitř archivů (ZIP, TAR i TAR.GZ). Maska *.txt
        // vynechá samotný nekomprimovaný t.tar, který hledaný text také obsahuje.
        let content = ContentMatcher::new(b"heslo", false, false, false, false).unwrap();
        let options = FindOptions { subdirs: true, include_dirs: false, content: Some(content), archives: true };
        let (stats, found, _) = run_find(&vfs, "/", "*.txt", &options);
        assert_eq!(
            found,
            ["/data.zip|/doc/readme.txt", "/pod/t.TGZ|/doc/readme.txt", "/pod/t.tar|/doc/readme.txt"]
        );
        assert_eq!(stats.errors, 0);

        // Hledání v obsahu přímo ve VFS archivu TAR.GZ (panel stojící v archivu,
        // vytřídění nálezů): soubory se čtou v pořadí dat, ne v pořadí výpisu.
        let tar = crate::tarfs::TarFs::open(&base.join("pod").join("t.TGZ")).unwrap();
        let (stats, found, _) = run_find(&tar, "/", "*", &options);
        assert_eq!(found, ["|/doc/readme.txt"]);
        assert_eq!(stats.errors, 0);

        fs::remove_dir_all(&base).unwrap();
        fs::remove_dir_all(&source).unwrap();
    }

    #[test]
    fn test_find_in_broken_and_encrypted_archives() {
        let base = std::env::temp_dir().join(format!("salcore-find-enc-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let source = prepare_archive_source("enc");
        write_zip(&source, &base.join("tajny.zip"), &crate::pack::PackEncryption::Aes256("heslo123".to_string()));
        // Hlavička ZIP bez platného obsahu = poškozený archiv.
        fs::write(base.join("vadny.zip"), b"PK\x03\x04 a dal uz nic platneho").unwrap();
        let vfs = LocalFs::new(base.to_str()).unwrap();

        // Jména v zaheslovaném archivu se najdou; poškozený archiv je jedna chyba.
        let options = FindOptions { subdirs: true, include_dirs: false, content: None, archives: true };
        let (stats, found, _) = run_find(&vfs, "/", "readme.txt", &options);
        assert_eq!(found, ["/tajny.zip|/doc/readme.txt"]);
        assert_eq!(stats.errors, 1);

        // Obsah zaheslované položky bez hesla přečíst nejde – přeskočí se jako chyba.
        let content = ContentMatcher::new(b"heslo", false, false, false, false).unwrap();
        let options = FindOptions { subdirs: true, include_dirs: false, content: Some(content), archives: true };
        let (stats, found, _) = run_find(&vfs, "/", "readme.txt", &options);
        assert!(found.is_empty());
        assert_eq!(stats.errors, 2);

        fs::remove_dir_all(&base).unwrap();
        fs::remove_dir_all(&source).unwrap();
    }
}
