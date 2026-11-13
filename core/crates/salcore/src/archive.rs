// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Společné pomůcky archivních VFS (ZIP, TAR).
//!
//! Oba archivy si při otevření sestaví index položek setříděný podle
//! kanonického jména uvnitř archivu (`pod/b.txt`). Výpis adresáře, test
//! existence i test adresáře se pak řeší jen nad indexem – bez čtení archivu.
//! Adresář nemusí mít v archivu vlastní záznam: stačí, že pod ním leží
//! nějaká položka (implikovaný adresář).

use std::collections::BTreeMap;
use std::ops::Bound;

use crate::vfs::{normalize_vfs_path, VfsItem, VfsItemKind};

/// Kanonické jméno položky archivu: oddělovače `/`, bez prázdných složek,
/// bez `.` a `..` (ochrana před cestami mířícími ven z archivu) a bez
/// lomítek na začátku a na konci. Záznam samotného kořene (`./`) dá prázdný
/// řetězec – takovou položku volající do indexu nezařazuje.
pub(crate) fn canonical_entry_name(raw: &str) -> String {
    // Jméno končí prvním NUL (zbytek je výplň nebo podvržená data).
    let raw = raw.split('\0').next().unwrap_or("");
    raw.split(['/', '\\'])
        .filter(|part| !part.is_empty() && *part != "." && *part != "..")
        .collect::<Vec<_>>()
        .join("/")
}

/// Převede cestu VFS na jméno položky v indexu (kořen = prázdný řetězec).
fn inner_name_of(path: &str) -> String {
    normalize_vfs_path(path).trim_start_matches('/').to_string()
}

/// Prefix jmen všech položek ležících pod adresářem (kořen = prázdný prefix).
fn inner_prefix_of(path: &str) -> String {
    let name = inner_name_of(path);
    if name.is_empty() {
        name
    } else {
        name + "/"
    }
}

/// Položky indexu, jejichž jméno začíná prefixem. Index je setříděný, takže
/// stačí souvislý úsek od prefixu – O(log n + počet položek pod adresářem).
fn entries_under<'a, T>(
    index: &'a BTreeMap<String, T>,
    prefix: &'a str,
) -> impl Iterator<Item = (&'a str, &'a T)> {
    index
        .range::<str, _>((Bound::Included(prefix), Bound::Unbounded))
        .take_while(move |(name, _)| name.starts_with(prefix))
        .map(move |(name, entry)| (&name[prefix.len()..], entry))
}

/// Výpis přímých potomků adresáře `path` z indexu archivu.
///
/// Parametry:
/// - `index` – index položek podle kanonického jména,
/// - `path` – cesta VFS vypisovaného adresáře,
/// - `to_item` – převod záznamu indexu na položku výpisu (dostane jméno
///   bez cesty a záznam).
///
/// Položky ležící hlouběji přidají svůj nejbližší adresář jako implikovaný
/// (bez data a velikosti); vlastní záznam adresáře má přednost.
pub(crate) fn list_dir<T>(
    index: &BTreeMap<String, T>,
    path: &str,
    to_item: impl Fn(&str, &T) -> VfsItem,
) -> Vec<VfsItem> {
    let prefix = inner_prefix_of(path);
    let mut items: BTreeMap<&str, VfsItem> = BTreeMap::new();
    for (rest, entry) in entries_under(index, &prefix) {
        match rest.find('/') {
            Some(slash_index) => {
                // Cesta vede hlouběji – přímý potomek je adresář.
                let dir_name = &rest[..slash_index];
                items.entry(dir_name).or_insert_with(|| VfsItem {
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
                items.insert(rest, to_item(rest, entry));
            }
        }
    }
    items.into_values().collect()
}

/// Leží pod cestou `path` nějaká položka (adresář bez vlastního záznamu)?
fn has_implied_dir<T>(index: &BTreeMap<String, T>, path: &str) -> bool {
    let prefix = inner_prefix_of(path);
    // Kořen existuje vždy; jinak stačí první položka úseku s prefixem.
    prefix.is_empty() || entries_under(index, &prefix).next().is_some()
}

/// Záznam indexu pro cestu VFS (jen položky s vlastním záznamem v archivu).
pub(crate) fn find_entry<'a, T>(index: &'a BTreeMap<String, T>, path: &str) -> Option<&'a T> {
    index.get(&inner_name_of(path))
}

/// Existuje cesta v archivu – vlastním záznamem, nebo jako adresář
/// implikovaný cestou jiné položky?
pub(crate) fn exists<T>(index: &BTreeMap<String, T>, path: &str) -> bool {
    find_entry(index, path).is_some() || has_implied_dir(index, path)
}

/// Je cesta adresář – podle vlastního záznamu (`entry_is_dir`), nebo implikovaný?
pub(crate) fn is_dir<T>(index: &BTreeMap<String, T>, path: &str, entry_is_dir: impl Fn(&T) -> bool) -> bool {
    find_entry(index, path).is_some_and(entry_is_dir) || has_implied_dir(index, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_canonical_entry_name() {
        assert_eq!(canonical_entry_name("./pod/b.txt"), "pod/b.txt");
        assert_eq!(canonical_entry_name("pod/"), "pod");
        assert_eq!(canonical_entry_name("/a//b\\c"), "a/b/c");
        assert_eq!(canonical_entry_name("../../etc/passwd"), "etc/passwd");
        assert_eq!(canonical_entry_name("./"), "");
        assert_eq!(canonical_entry_name("a.txt\0vypln"), "a.txt");
    }

    #[test]
    fn test_list_dir_and_implied_dirs() {
        let mut index: BTreeMap<String, u64> = BTreeMap::new();
        for (name, size) in [("a.txt", 1), ("pod", 0), ("pod/b.txt", 2), ("pod2/hloub/c.txt", 3), ("podobny.txt", 4)] {
            index.insert(name.to_string(), size);
        }
        let to_item = |name: &str, size: &u64| VfsItem {
            name: name.to_string(),
            size: *size,
            mtime: 0,
            // Záznam s nulovou velikostí je v testu adresář.
            kind: if *size == 0 { VfsItemKind::Dir } else { VfsItemKind::File },
            hidden: false,
            readonly: true,
            encrypted: false,
        };
        let root: Vec<(String, VfsItemKind)> =
            list_dir(&index, "/", to_item).into_iter().map(|item| (item.name, item.kind)).collect();
        assert_eq!(
            root,
            vec![
                ("a.txt".to_string(), VfsItemKind::File),
                ("pod".to_string(), VfsItemKind::Dir),
                ("pod2".to_string(), VfsItemKind::Dir),
                ("podobny.txt".to_string(), VfsItemKind::File),
            ]
        );
        // Výpis podadresáře nesmí zahrnout sousedy se stejným začátkem jména.
        let sub: Vec<String> = list_dir(&index, "/pod", to_item).into_iter().map(|item| item.name).collect();
        assert_eq!(sub, vec!["b.txt".to_string()]);
        // Existence a test adresáře: vlastní záznam i implikovaný adresář.
        let entry_is_dir = |size: &u64| *size == 0;
        assert!(exists(&index, "/pod2") && is_dir(&index, "/pod2", entry_is_dir));
        assert!(is_dir(&index, "/pod2/hloub", entry_is_dir));
        assert!(is_dir(&index, "/pod", entry_is_dir));
        assert!(exists(&index, "/podobny.txt") && !is_dir(&index, "/podobny.txt", entry_is_dir));
        assert!(!exists(&index, "/neni"));
        assert!(is_dir(&index, "/", entry_is_dir));
    }
}
