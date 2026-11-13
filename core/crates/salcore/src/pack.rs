// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Vytváření ZIP archivů z položek libovolného VFS.
//!
//! Čtení archivů řeší `zipfs` (ZIP jako VFS); tady je opačný směr –
//! „zabal“ vybrané položky do nového ZIP souboru na lokálním disku
//! (obdoba Salamander Pack). Postupně se projde celý obsah, ukládá se
//! s kompresí Deflate. Soubory lze šifrovat heslem: AES-256 (WinZip AE-2,
//! doporučeno) nebo ZipCrypto (slabé, jen kvůli kompatibilitě se starými
//! programy). Adresářové položky se nešifrují (nenesou data).

use std::io::{Read, Write};
use std::path::Path;

use zip::unstable::write::FileOptionsExt;
use zip::write::{FileOptions, SimpleFileOptions};
use zip::{AesMode, ZipWriter};

use crate::error::{SalError, SalResult};
use crate::ops::{ProgressCallback, TransferStats};
use crate::vfs::{join_path, Vfs, VfsItemKind};

/// Velikost přenosového bufferu při balení.
const PACK_BUFFER_SIZE: usize = 256 * 1024;

/// Šifrování souborů v nově vytvářeném ZIP archivu.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PackEncryption {
    /// Bez hesla.
    None,
    /// AES-256 (WinZip AE-2) – bezpečné, podporuje 7-Zip, WinZip, Salamander, macOS Archive Utility ne.
    Aes256(String),
    /// Tradiční ZipCrypto – slabé, ale čitelné prakticky všemi programy.
    ZipCrypto(String),
}

/// Zabalí vybrané položky z `src_dir` do nového ZIP archivu se zvoleným
/// šifrováním. Existující cílový soubor se přepíše, adresáře se zabalí
/// včetně obsahu. Prázdné heslo u AES/ZipCrypto je chyba (archiv by byl
/// nečitelný).
pub fn pack_zip(
    src: &dyn Vfs,
    src_dir: &str,
    names: &[&str],
    dest: &Path,
    encryption: &PackEncryption,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    // Kontrola hesla před vytvořením cílového souboru.
    match encryption {
        PackEncryption::Aes256(password) | PackEncryption::ZipCrypto(password) if password.is_empty() => {
            return Err(SalError::Io("Heslo pro šifrovaný archiv nesmí být prázdné.".to_string()));
        }
        _ => {}
    }

    // Celková velikost pro percentuální progress (jen pokud VFS umí scan).
    let total_bytes = if src.supports_size_scan() {
        crate::ops::measure_total(src, src_dir, names)
    } else {
        0
    };
    if !progress.on_progress(0, total_bytes) {
        return Err(SalError::Cancelled);
    }

    let file = std::fs::File::create(dest)?;
    let mut writer = ZipWriter::new(file);
    let base: SimpleFileOptions = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    // Volby pro soubory podle šifrování (heslo si volby jen půjčují).
    let options: FileOptions<'_, ()> = match encryption {
        PackEncryption::None => base,
        PackEncryption::Aes256(password) => base.with_aes_encryption(AesMode::Aes256, password),
        PackEncryption::ZipCrypto(password) => base.with_deprecated_encryption(password.as_bytes()),
    };

    let mut context = PackContext {
        writer: &mut writer,
        options,
        dir_options: base,
        total_bytes,
        stats: TransferStats::default(),
        transferred: 0,
        progress,
    };
    for name in names {
        // Vybrané položky leží v kořeni archivu.
        pack_item(src, src_dir, name, None, "", &mut context)?;
    }
    let stats = context.stats;

    writer.finish()?;
    progress.on_progress(total_bytes, total_bytes);
    Ok(stats)
}

/// Sdílený stav balení (writer, volby, statistiky, průběh).
struct PackContext<'a, 'k> {
    writer: &'a mut ZipWriter<std::fs::File>,
    /// Volby pro soubory (komprese + případné šifrování).
    options: FileOptions<'k, ()>,
    /// Volby pro adresářové položky (bez šifrování).
    dir_options: SimpleFileOptions,
    total_bytes: u64,
    stats: TransferStats,
    transferred: u64,
    progress: &'a mut dyn ProgressCallback,
}

/// Zabalí jednu položku (soubor nebo adresář rekurzivně) do archivu.
/// `known_dir` = druh z výpisu rodiče (None = zjistit dotazem, např. u odkazů);
/// `entry_prefix` je cesta nadřazeného adresáře uvnitř archivu („“ nebo „dir/“).
fn pack_item(
    src: &dyn Vfs,
    parent_dir: &str,
    name: &str,
    known_dir: Option<bool>,
    entry_prefix: &str,
    context: &mut PackContext<'_, '_>,
) -> SalResult<()> {
    let src_path = join_path(parent_dir, name);
    let entry_name = format!("{}{}", entry_prefix, name);
    // Adresáře zapíšeme jako adresářové položky (bez šifrování – nenesou data)
    // a rekurzivně jejich obsah s cestou v archivu.
    let is_dir = match known_dir {
        Some(value) => value,
        None => src.is_dir(&src_path)?,
    };
    if is_dir {
        context.writer.add_directory(entry_name.as_str(), context.dir_options)?;
        context.stats.dirs += 1;
        let child_prefix = format!("{}/", entry_name);
        for child in src.list(&src_path)? {
            // Druh je známý z výpisu (ušetří stat/síťový dotaz); odkaz se ověří.
            let child_dir = match child.kind {
                VfsItemKind::Dir => Some(true),
                VfsItemKind::File => Some(false),
                VfsItemKind::Link => None,
            };
            pack_item(src, &src_path, &child.name, child_dir, &child_prefix, context)?;
        }
        return Ok(());
    }

    // Soubor streamovaně po blocích s hlášením průběhu (false = zrušit).
    let mut reader = src.open_read(&src_path)?;
    context.writer.start_file(entry_name.as_str(), context.options)?;
    let mut buffer = vec![0u8; PACK_BUFFER_SIZE];
    let mut file_bytes = 0u64;
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        context.writer.write_all(&buffer[..read])?;
        context.transferred += read as u64;
        file_bytes += read as u64;
        if !context.progress.on_progress(context.transferred, context.total_bytes) {
            return Err(SalError::Cancelled);
        }
    }
    context.stats.files += 1;
    context.stats.bytes += file_bytes;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local::LocalFs;
    use crate::ops::NoProgress;
    use crate::zipfs::ZipFs;
    use std::fs;

    /// Připraví zdrojový strom: a.txt a pod/b.txt v unikátním temp adresáři.
    fn prepare_source(tag: &str) -> std::path::PathBuf {
        let base = std::env::temp_dir().join(format!("salcore-pack-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(base.join("src/pod")).unwrap();
        fs::write(base.join("src/a.txt"), b"obsah a").unwrap();
        fs::write(base.join("src/pod/b.txt"), b"tajny obsah b").unwrap();
        base
    }

    /// Přečte celý soubor z VFS do řetězce.
    fn read_all(vfs: &dyn Vfs, path: &str) -> SalResult<String> {
        let mut reader = vfs.open_read(path)?;
        let mut text = String::new();
        reader.read_to_string(&mut text)?;
        Ok(text)
    }

    /// Zabalí a.txt + pod/ s daným šifrováním a vrátí cestu k archivu.
    fn pack_with(base: &std::path::Path, encryption: &PackEncryption) -> std::path::PathBuf {
        let src = LocalFs::new(None).unwrap();
        let dest = base.join("out.zip");
        let src_dir = base.join("src").to_string_lossy().to_string();
        let stats = pack_zip(&src, &src_dir, &["a.txt", "pod"], &dest, encryption, &mut NoProgress).unwrap();
        assert_eq!(stats.files, 2);
        assert_eq!(stats.bytes, 7 + 13);
        dest
    }

    #[test]
    fn test_pack_keeps_directory_structure() {
        let base = prepare_source("plain");
        let dest = pack_with(&base, &PackEncryption::None);
        let zip = ZipFs::open(&dest).unwrap();
        assert!(!zip.has_encrypted());
        // Vnořený soubor musí být v archivu pod svou cestou (pod/b.txt).
        assert_eq!(read_all(&zip, "/pod/b.txt").unwrap(), "tajny obsah b");
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn test_pack_aes256_roundtrip() {
        let base = prepare_source("aes");
        let dest = pack_with(&base, &PackEncryption::Aes256("heslo123".to_string()));
        let zip = ZipFs::open(&dest).unwrap();
        assert!(zip.has_encrypted());

        // Výpis funguje bez hesla a hlásí šifrované položky.
        let items = zip.list("/pod").unwrap();
        assert_eq!(items[0].name, "b.txt");
        assert!(items[0].encrypted);
        assert_eq!(items[0].size, 13);

        // Bez hesla → PasswordRequired, chybné heslo → InvalidPassword, správné → obsah.
        assert_eq!(read_all(&zip, "/pod/b.txt").unwrap_err(), SalError::PasswordRequired);
        zip.set_password(Some("spatne"));
        assert_eq!(read_all(&zip, "/pod/b.txt").unwrap_err(), SalError::InvalidPassword);
        zip.set_password(Some("heslo123"));
        assert_eq!(read_all(&zip, "/pod/b.txt").unwrap(), "tajny obsah b");
        assert_eq!(read_all(&zip, "/a.txt").unwrap(), "obsah a");

        // Archiv je opravdu AES-256 (WinZip AE-x, kompresní metoda 99 v hlavičce).
        let raw = fs::read(&dest).unwrap();
        assert!(raw.windows(2).any(|w| w == [0x01, 0x99]), "chybí AES extra field 0x9901");
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn test_pack_zipcrypto_roundtrip() {
        let base = prepare_source("zc");
        let dest = pack_with(&base, &PackEncryption::ZipCrypto("stare".to_string()));
        let zip = ZipFs::open(&dest).unwrap();
        assert!(zip.has_encrypted());
        assert_eq!(read_all(&zip, "/a.txt").unwrap_err(), SalError::PasswordRequired);
        zip.set_password(Some("stare"));
        assert_eq!(read_all(&zip, "/a.txt").unwrap(), "obsah a");
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn test_pack_rejects_empty_password() {
        let base = prepare_source("empty");
        let src = LocalFs::new(None).unwrap();
        let src_dir = base.join("src").to_string_lossy().to_string();
        let result = pack_zip(&src, &src_dir, &["a.txt"], &base.join("x.zip"),
                                        &PackEncryption::Aes256(String::new()), &mut NoProgress);
        assert!(result.is_err());
        assert!(!base.join("x.zip").exists());
        fs::remove_dir_all(&base).unwrap();
    }
}
