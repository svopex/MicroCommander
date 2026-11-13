// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Masky jmen podle vzoru Salamandera (port myšlenky z masks.cpp).
//!
//! Podporované zástupné znaky:
//! - `*` libovolný řetězec (i prázdný)
//! - `?` právě jeden libovolný znak
//! - `#` právě jedna číslice (pouze v rozšířeném režimu)
//!
//! Skupina masek se zadává jako jeden řetězec, jednotlivé masky odděluje `;`.
//! Oddělovač `|` rozděluje inkluzivní a exkluzivní část: vše za ním jsou
//! masky negativní (shoda s nimi znamená zamítnutí jména).
//!
//! Zvláštní případy kvěli kompatibilitě s zvyklostmi z DOS/Salamandera:
//! - `*` i `*.*` znamená vše
//! - maska končící tečkou (např. `*.`) matchne jen jména bez přípony
//!
//! Porovnávání názvů nerozlišuje velikost písmen.

use crate::error::{SalError, SalResult};

/// Předparsovaná skupina masek pro opakované dotazování (hledání, filtry).
pub struct MaskGroup {
    /// Inkluzivní masky (lowercase, po znacích).
    include: Vec<Vec<char>>,
    /// Exkluzivní masky za oddělovačem `|`.
    exclude: Vec<Vec<char>>,
    /// Rozšířený režim (`#` = číslice).
    extended: bool,
    /// Zkratka pro „vše“ (maska `*` nebo `*.*`), urychluje hledání.
    match_all: bool,
}

impl MaskGroup {
    /// Naparsuje řetězec masek. Vrací chybu pro prázdnou skupinu,
    /// vícenásobné `|` nebo `|` bez následující masky.
    pub fn new(masks: &str, extended: bool) -> SalResult<MaskGroup> {
        // Rozdělení na inkluzivní a exkluzivní část; víc než jeden oddělovač je chyba.
        let parts: Vec<&str> = masks.split('|').collect();
        if parts.len() > 2 {
            return Err(SalError::Io(
                "Oddělovač '|' smí být v masce pouze jednou.".to_string(),
            ));
        }
        let include = parse_mask_list(parts[0]);
        let exclude = parse_mask_list(parts.get(1).copied().unwrap_or(""));

        // Za '|' musí být alespoň jedna maska, celkově taky.
        if parts.len() == 2 && exclude.is_empty() {
            return Err(SalError::Io(
                "Za oddělovačem '|' chybí maska.".to_string(),
            ));
        }
        if include.is_empty() && exclude.is_empty() {
            return Err(SalError::Io("Prázdná maska.".to_string()));
        }

        // `*` případně `*.*` jako jediná inkluzivní maska znamená vše.
        // Prázdná inkluzivní část („|*.txt“) znamená také vše – jen s vyloučením
        // (zvyklost z Salamandera: před | se automaticky dosadí *).
        let match_all = (include.is_empty() && !exclude.is_empty())
            || (include.len() == 1 && is_all_mask(&include[0]));
        Ok(MaskGroup {
            include,
            exclude,
            extended,
            match_all,
        })
    }

    /// Zhodnotí jméno souboru proti celé skupině masek.
    pub fn matches(&self, name: &str) -> bool {
        // Jméno i masky převádíme na malá písmena – porovnání nerozlišuje velikost.
        let name_lower: Vec<char> = name.to_lowercase().chars().collect();
        let name_has_dot = name.contains('.');

        let included = self.match_all || {
            self.include
                .iter()
                .any(|mask| match_single(&name_lower, name_has_dot, mask, self.extended))
        };
        if !included {
            return false;
        }
        // Exkluzivní masky mají přednost – shoda s nimi jméno zamítne.
        !self
            .exclude
            .iter()
            .any(|mask| match_single(&name_lower, name_has_dot, mask, self.extended))
    }
}

/// Rozdělí seznam masek oddělených `;`, zahodí prázdné segmenty,
/// převede na lowercase znakové vektory.
fn parse_mask_list(list: &str) -> Vec<Vec<char>> {
    list.split(';')
        .map(str::trim)
        .filter(|mask| !mask.is_empty())
        .map(|mask| mask.to_lowercase().chars().collect())
        .collect()
}

/// Rozpozná „vše“ masku (`*` nebo `*.*`).
fn is_all_mask(mask: &[char]) -> bool {
    mask == ['*'] || mask == ['*', '.', '*']
}

/// Porovná jedno jméno s jednou maskou (iterativní algoritmus s backtrackingem
/// na poslední hvězdičku – bez rekurze, aby zlobivé masky nepřetěžovaly zásobník).
fn match_single(name: &[char], name_has_dot: bool, mask: &[char], extended: bool) -> bool {
    // Maska končící tečkou matchne jen jména bez přípony (zvyklost z DOS).
    if mask.len() > 1 && mask[mask.len() - 1] == '.' {
        let head = &mask[..mask.len() - 1];
        return !name_has_dot && match_wildcards(name, head, extended);
    }
    match_wildcards(name, mask, extended)
}

/// Klasický two-pointer wildcard match: `*` = cokoli, `?` = jeden znak,
/// `#` = jedna číslice (jen v rozšířeném režimu).
fn match_wildcards(name: &[char], mask: &[char], extended: bool) -> bool {
    let (mut n, mut m) = (0usize, 0usize);
    // Pozice poslední hvězdičky a odpovídající pozice v jméně pro backtracking.
    let (mut star_mask, mut star_name) = (usize::MAX, 0usize);

    while n < name.len() {
        if m < mask.len() {
            match mask[m] {
                '*' => {
                    star_mask = m;
                    star_name = n;
                    m += 1;
                    continue;
                }
                '?' => {
                    n += 1;
                    m += 1;
                    continue;
                }
                '#' if extended && name[n].is_ascii_digit() => {
                    n += 1;
                    m += 1;
                    continue;
                }
                ch if ch == name[n] => {
                    n += 1;
                    m += 1;
                    continue;
                }
                _ => {}
            }
        }
        // Nesoulad: pokud jsme už prošli hvězdičku, zkusíme delší shodu.
        if star_mask != usize::MAX {
            star_name += 1;
            n = star_name;
            m = star_mask + 1;
        } else {
            return false;
        }
    }

    // Zbývající hvězdičky na konci masky matchnou prázdný řetězec.
    while m < mask.len() && mask[m] == '*' {
        m += 1;
    }
    m == mask.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(masks: &str) -> MaskGroup {
        MaskGroup::new(masks, true).unwrap()
    }

    #[test]
    fn test_basic_wildcards() {
        assert!(m("*").matches("cokoliv"));
        assert!(m("*").matches("bez.tecky"));
        assert!(m("*.txt").matches("soubor.TXT"));
        assert!(m("*.txt").matches("a.b.txt"));
        assert!(!m("*.txt").matches("soubor.doc"));
        assert!(m("*.t??").matches("soubor.txt"));
        assert!(!m("*.t??").matches("soubor.t"));
        assert!(m("data#.dat").matches("data7.dat"));
        assert!(!m("data#.dat").matches("datax.dat"));
        assert!(!m("data#.dat").matches("data.dat"));
    }

    #[test]
    fn test_dos_special_cases() {
        // `*.*` znamená vše (včetně jmen bez tečky).
        assert!(m("*.*").matches("soubor"));
        assert!(m("*.*").matches("soubor.txt"));
        // Maska končící tečkou matchne jen jména bez přípony.
        assert!(m("*.").matches("soubor"));
        assert!(!m("*.").matches("soubor.txt"));
        assert!(m("a*.").matches("adresar"));
        assert!(!m("a*.").matches("a.txt"));
    }

    #[test]
    fn test_groups_and_exclusions() {
        assert!(m("*.txt;*.cpp").matches("main.cpp"));
        assert!(m("*.txt;*.cpp").matches("readme.txt"));
        assert!(!m("*.txt;*.cpp").matches("main.rs"));
        // Vyloučení za `|`.
        assert!(!m("*.h*|*.html").matches("index.html"));
        assert!(m("*.h*|*.html").matches("header.hpp"));
        assert!(!m("|*.txt").matches("a.txt"));
        assert!(m("|*.txt").matches("a.md"));
    }

    #[test]
    fn test_case_insensitive_unicode() {
        assert!(m("PŘÍLIŠ*").matches("příliš žluťoučký"));
        assert!(m("název*").matches("NÁZEV.txt"));
    }

    #[test]
    fn test_invalid_groups() {
        assert!(MaskGroup::new("", true).is_err());
        assert!(MaskGroup::new("a|b|c", true).is_err());
        assert!(MaskGroup::new("a|", true).is_err());
        assert!(MaskGroup::new(";;", true).is_err());
    }
}
