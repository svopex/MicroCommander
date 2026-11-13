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
        let compiled = RegexBuilder::new(&body)
            .case_insensitive(!case_sensitive && !hex)
            .multi_line(true)
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
    let options = FindOptions { subdirs: true, include_dirs, content: None };
    find_items_ex(vfs, root, mask, &options, progress, &mut |_| {}, on_found)
}

/// Hledání s volbami dialogu Find.
///
/// Parametry jako u `find_items`, navíc:
/// - `options` – podadresáře, adresáře ve výsledcích, hledání v obsahu,
/// - `on_dir` – hlášení právě prohledávaného adresáře (stavový řádek).
///
/// Nečitelný výchozí adresář je chyba; nečitelné podadresáře a soubory se
/// přeskočí a započítají do `FindStats::errors`.
pub fn find_items_ex(
    vfs: &dyn Vfs,
    root: &str,
    mask: &MaskGroup,
    options: &FindOptions,
    progress: &mut dyn ProgressCallback,
    on_dir: &mut dyn FnMut(&str),
    on_found: &mut dyn FnMut(&str, &VfsItem) -> bool,
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
    };
    if !search.scan_dir(root, children)? {
        return Err(SalError::Cancelled);
    }
    Ok(search.stats)
}

/// Stav jednoho běhu hledání (sdílené parametry rekurze).
struct Search<'a> {
    vfs: &'a dyn Vfs,
    mask: &'a MaskGroup,
    options: &'a FindOptions,
    progress: &'a mut dyn ProgressCallback,
    on_dir: &'a mut dyn FnMut(&str),
    on_found: &'a mut dyn FnMut(&str, &VfsItem) -> bool,
    stats: FindStats,
    /// Pracovní buffer hledání v obsahu (sdílený pro všechny soubory).
    buffer: Vec<u8>,
}

impl Search<'_> {
    /// Projde položky jednoho adresáře. Vrací `false`, pokud bylo hledání
    /// zrušeno (progresem nebo zpětným voláním).
    fn scan_dir(&mut self, dir: &str, children: Vec<VfsItem>) -> SalResult<bool> {
        (self.on_dir)(dir);
        for child in &children {
            // Průběh hlásíme po položkách; total=0 = neznámý celek.
            self.stats.scanned += 1;
            if !self.progress.on_progress(self.stats.scanned, 0) {
                return Ok(false);
            }

            let is_dir = child.kind == VfsItemKind::Dir;
            let descend = is_dir && self.options.subdirs;
            // Adresáře se hlásí jen bez hledání v obsahu a když to volající chce
            // (masku u adresáře testujeme, jen když se může hlásit).
            let report_dirs = self.options.include_dirs && self.options.content.is_none();
            let name_matches = (!is_dir || report_dirs) && self.mask.matches(&child.name);
            // Cestu skládáme jen pro shodu nebo sestup do podadresáře.
            if !name_matches && !descend {
                continue;
            }
            let path = join_path(dir, &child.name);
            let matches = if is_dir || !name_matches {
                name_matches
            } else if let Some(content) = &self.options.content {
                match self.file_contains(&path, content) {
                    Ok(found) => found,
                    Err(SalError::Cancelled) => return Ok(false),
                    Err(_) => {
                        // Nečitelný soubor (práva, zámek) – přeskočit a započítat chybu.
                        self.stats.errors += 1;
                        false
                    }
                }
            } else {
                true
            };
            if matches {
                self.stats.found += 1;
                if !(self.on_found)(&path, child) {
                    return Ok(false);
                }
            }

            // Rekurzivně do podadresářů (odkazy nenásledujeme, aby hledání
            // nezacyklilo); nečitelný podadresář se přeskočí.
            if descend {
                match self.vfs.list(&path) {
                    Ok(sub_children) => {
                        if !self.scan_dir(&path, sub_children)? {
                            return Ok(false);
                        }
                    }
                    Err(_) => self.stats.errors += 1,
                }
            }
        }
        Ok(true)
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
    use std::path::PathBuf;

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
        let options = FindOptions { subdirs: false, include_dirs: true, content: None };
        let mut found: Vec<String> = Vec::new();
        find_items_ex(&vfs, "/", &mask, &options, &mut NoProgress, &mut |_| {}, &mut |path, _| {
            found.push(path.to_string());
            true
        })
        .unwrap();
        found.sort();
        assert_eq!(found, vec!["/pod".to_string(), "/y.log".to_string()]);

        // Hledání v obsahu: jen soubor s textem, adresáře se nehlásí.
        let content = ContentMatcher::new(b"slovem", false, true, false, false).unwrap();
        let options = FindOptions { subdirs: true, include_dirs: true, content: Some(content) };
        let mut found: Vec<String> = Vec::new();
        let mut dirs: Vec<String> = Vec::new();
        find_items_ex(&vfs, "/", &mask, &options, &mut NoProgress, &mut |dir| dirs.push(dir.to_string()), &mut |path, _| {
            found.push(path.to_string());
            true
        })
        .unwrap();
        assert_eq!(found, vec!["/pod/x.txt".to_string()]);
        assert!(dirs.contains(&"/pod/pod2".to_string()));

        // Neexistující výchozí adresář je chyba.
        let options = FindOptions { subdirs: true, include_dirs: true, content: None };
        assert!(find_items_ex(&vfs, "/neni", &mask, &options, &mut NoProgress, &mut |_| {}, &mut |_, _| true).is_err());

        fs::remove_dir_all(&base).unwrap();
    }
}
