// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Překlady textů jádra (chybové hlášky) – čeština (zdrojový jazyk) a angličtina.
//!
//! Zdrojové texty jsou česky a slouží jako klíče tabulky [`EN`]. Jazyk nastaví
//! UI při startu přes FFI (`sal_set_language`); výchozí je čeština, takže testy
//! jádra porovnávají české texty beze změny.
//!
//! Použití: `tr("Přístup odepřen.")`, s hodnotami
//! `trf("Soubor {} nelze přečíst: {}", &[&path.display(), &err])` – `{}` se
//! nahrazují postupně. Úplnost kontroluje `tools/i18n_check.py`.

use std::fmt::Display;
use std::sync::atomic::{AtomicBool, Ordering};

/// Zda jádro mluví anglicky (jinak česky).
static ENGLISH: AtomicBool = AtomicBool::new(false);

/// Anglická tabulka překladů (český text, anglický překlad).
pub const EN: &[(&str, &str)] = &[
    // Chyby SalError (error.rs)
    ("Operace byla zrušena.", "The operation was canceled."),
    ("Soubor nebo adresář nebyl nalezen.", "File or folder not found."),
    ("Cíl už existuje.", "The destination already exists."),
    ("Adresář není prázdný.", "The folder is not empty."),
    ("Přístup odepřen.", "Access denied."),
    ("Soubor v archivu je zaheslovaný – zadejte heslo.", "The file in the archive is password-protected – enter the password."),
    ("Chybné heslo k archivu.", "Wrong archive password."),
    // Rozhraní FFI (ffi.rs)
    ("Interní chyba jádra (neošetřená panika).", "Internal core error (unhandled panic)."),
    ("Chybí adresa serveru.", "The server address is missing."),
    ("Chybí cesta k souboru s klíčem.", "The key file path is missing."),
    ("Neplatné argumenty {}.", "Invalid arguments to {}."),
    ("Neznámý režim šifrování ZIP.", "Unknown ZIP encryption mode."),
    // Hledání a masky (find.rs, mask.rs)
    ("Prázdný řetězec zde není povolen.", "An empty string is not allowed here."),
    ("Chybný regulární výraz: {}", "Invalid regular expression: {}"),
    ("Oddělovač '|' smí být v masce pouze jednou.", "The '|' separator may appear in the mask only once."),
    ("Za oddělovačem '|' chybí maska.", "A mask is missing after the '|' separator."),
    ("Prázdná maska.", "Empty mask."),
    // Souborové operace a balení (local.rs, ops.rs, pack.rs, vfs.rs)
    ("Kořen lokálního souborového systému musí být absolutní cesta.", "The root of the local file system must be an absolute path."),
    ("Odkaz {} vede do sebe sama (odkaz na nadřazený adresář?).", "Link {} points to itself (a link to a parent folder?)."),
    ("Zdrojový a cílový adresář jsou stejné.", "The source and destination folders are the same."),
    ("Položku „{}“ nelze přenést do sebe sama.", "Item “{}” cannot be transferred into itself."),
    ("Heslo pro šifrovaný archiv nesmí být prázdné.", "The password for an encrypted archive must not be empty."),
    ("Souborový systém nepodporuje symbolické odkazy.", "The file system does not support symbolic links."),
    // Síťová spojení (ftp.rs, sftp.rs)
    ("Nepodařilo se přeložit adresu {}: {}", "Could not resolve address {}: {}"),
    ("Server {}:{} nenalezen.", "Server {}:{} not found."),
    ("Datové spojení už je uzavřené.", "The data connection is already closed."),
    ("Soubor s klíčem {} neexistuje.", "Key file {} does not exist."),
    ("Klíč je chráněný heslem – zadejte heslo ke klíči.", "The key is passphrase-protected – enter the key passphrase."),
    ("Soubor s klíčem {} nelze přečíst: {}", "Cannot read key file {}: {}"),
    ("Nelze se připojit k ssh-agentovi (není spuštěn nebo chybí SSH_AUTH_SOCK).", "Cannot connect to ssh-agent (it is not running or SSH_AUTH_SOCK is not set)."),
    ("ssh-agent nemá načtené žádné klíče (přidejte je příkazem ssh-add).", "ssh-agent has no keys loaded (add them with ssh-add)."),
    ("Server nepřijal žádný z {} klíčů v ssh-agentovi.", "The server accepted none of the {} keys in ssh-agent."),
    ("Klíč nelze načíst – chybné heslo ke klíči nebo nepodporovaný formát.", "Cannot load the key – wrong key passphrase or unsupported format."),
    ("Klíč nelze načíst – je chráněný heslem (zadejte heslo ke klíči) nebo má nepodporovaný formát.", "Cannot load the key – it is passphrase-protected (enter the key passphrase) or has an unsupported format."),
    ("Server klíč odmítl (veřejný klíč není v ~/.ssh/authorized_keys na serveru?).", "The server rejected the key (is the public key missing from ~/.ssh/authorized_keys on the server?)."),
    ("Přihlášení klíčem selhalo: {}", "Key authentication failed: {}"),
    ("Přihlášení heslem selhalo (chybné jméno nebo heslo).", "Password authentication failed (wrong username or password)."),
    ("SFTP spojení je nedostupné (uzamčené).", "The SFTP connection is unavailable (locked)."),
    ("SFTP spojení je uzamčené.", "The SFTP connection is locked."),
    ("SFTP handle už je uzavřený.", "The SFTP handle is already closed."),
    // Archivy TAR a ZIP (tarfs.rs, zipfs.rs)
    ("Poškozený TAR archiv (příliš velká rozšířená hlavička).", "Corrupted TAR archive (extended header too large)."),
    ("Poškozený TAR archiv (neúplná rozšířená hlavička).", "Corrupted TAR archive (incomplete extended header)."),
    ("Poškozená TAR hlavička (neúplný blok).", "Corrupted TAR header (incomplete block)."),
    ("Soubor není čitelný TAR archiv.", "The file is not a readable TAR archive."),
    ("Archiv skončil dříve, než očekával scanner.", "The archive ended earlier than the scanner expected."),
    ("Uzamčená dekompresní session archivu.", "The archive decompression session is locked."),
    ("Do otevřeného TAR archivu nelze zapisovat (jen pro čtení).", "Cannot write to an open TAR archive (read-only)."),
    ("Neplatná pozice v souboru archivu.", "Invalid position in the archive file."),
    ("Do otevřeného ZIP archivu nelze zapisovat (jen pro čtení).", "Cannot write to an open ZIP archive (read-only)."),
    ("Z otevřeného ZIP archivu nelze mazat (jen pro čtení).", "Cannot delete from an open ZIP archive (read-only)."),
    ("V otevřeném ZIP archivu nelze přejmenovávat (jen pro čtení).", "Cannot rename in an open ZIP archive (read-only)."),
];

/// Nastaví jazyk textů jádra ("en" = angličtina, cokoli jiného = čeština).
pub fn set_language(code: &str) {
    ENGLISH.store(code == "en", Ordering::Relaxed);
}

/// Přeloží český text do jazyka jádra (bez překladu vrátí originál).
/// Tabulka je malá a hlášky vznikají jen při chybách – stačí lineární hledání.
pub fn tr(text: &str) -> String {
    if ENGLISH.load(Ordering::Relaxed) {
        if let Some((_, english)) = EN.iter().find(|(czech, _)| *czech == text) {
            return (*english).to_string();
        }
    }
    text.to_string()
}

/// Přeloží šablonu a postupně dosadí hodnoty za `{}` (přebytečné `{}` zůstanou).
pub fn trf(template: &str, values: &[&dyn Display]) -> String {
    let template = tr(template);
    let mut parts = template.split("{}");
    let mut result = parts.next().unwrap_or_default().to_string();
    let mut values = values.iter();
    for part in parts {
        match values.next() {
            Some(value) => result.push_str(&value.to_string()),
            None => result.push_str("{}"),
        }
        result.push_str(part);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translates_and_formats() {
        // Česky se text nemění a {} se dosadí; neznámý text zůstane v originále
        assert_eq!(trf("A {} B {}", &[&1, &"x"]), "A 1 B x");
        assert_eq!(tr("Neznámý text"), "Neznámý text");
        // Každá šablona tabulky má v překladu stejný počet {} jako originál
        for (czech, english) in EN {
            assert_eq!(czech.matches("{}").count(), english.matches("{}").count(), "{czech}");
        }
    }
}
