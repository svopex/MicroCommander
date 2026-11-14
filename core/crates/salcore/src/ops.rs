// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! Souborové operace (kopírování, přesun, mazání) mezi libovolnými VFS.
//!
//! Všechny operace podporují hlášení průběhu a zrušení uživatelem.
//! Kopírování probíhá streamováním po 256 KiB blocích, takže funguje
//! mezi všemi kombinacemi zdroje a cíle (disk, archiv, FTP, SFTP)
//! bez nutnosti vejít se do paměti.

use std::collections::HashMap;

use crate::error::{SalError, SalResult};
use crate::local::LocalFs;
use crate::vfs::{join_path, normalize_vfs_path, Vfs, VfsItem, VfsItemKind, VfsReadStream, VfsWriteStream};

/// Velikost přenosového bufferu pro streamované kopírování.
const COPY_BUFFER_SIZE: usize = 256 * 1024;
/// Kolik odkazů na adresář smí být zanořeno v sobě, když se odkazy přenášejí
/// obsahem (cíl odkazy neumí). Odkaz na nadřazený adresář by jinak přenos
/// zacyklil; skutečné stromy tolik odkazů v jedné cestě nemají.
const MAX_FOLLOWED_LINKS: u32 = 16;

/// Rozhodnutí při existenci cílového souboru/adresáře.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverwriteMode {
    /// Přeruší operaci chybou AlreadyExists; UI se zeptá a spustí znovu.
    Ask,
    /// Existující cíle přepíše.
    Overwrite,
    /// Existující cíle přeskočí.
    Skip,
}

/// Rozhraní pro hlášení průběhu operace.
/// Návratová hodnota `false` operaci zruší (vrátí SalError::Cancelled).
pub trait ProgressCallback: Send {
    fn on_progress(&mut self, done: u64, total: u64) -> bool;
}

/// Prázdný progress – operace bez sledování průběhu.
pub struct NoProgress;
impl ProgressCallback for NoProgress {
    fn on_progress(&mut self, _done: u64, _total: u64) -> bool {
        true
    }
}

/// Statistika provedené operace (počty přenesených položek).
#[derive(Debug, Default, Clone, Copy)]
pub struct TransferStats {
    pub files: u64,
    pub dirs: u64,
    pub bytes: u64,
    pub skipped: u64,
}

/// Celková velikost vybraných položek adresáře `src_dir` (adresáře
/// rekurzivně) pro procentuální průběh; nečitelné části se nepočítají.
pub(crate) fn measure_total(src: &dyn Vfs, src_dir: &str, names: &[&str]) -> u64 {
    match src.list(src_dir) {
        Ok(items) => select_items(&items, names).into_iter().map(|item| measure_item(src, src_dir, item)).sum(),
        Err(_) => 0,
    }
}

/// Velikost položky adresáře `dir` (adresář = součet obsahu rekurzivně).
fn measure_item(src: &dyn Vfs, dir: &str, item: &VfsItem) -> u64 {
    if item.kind != VfsItemKind::Dir {
        return item.size;
    }
    let path = join_path(dir, &item.name);
    // Nečitelný podadresář se z celku vynechá (chybu ohlásí až přenos).
    src.list(&path)
        .map(|children| children.iter().map(|child| measure_item(src, &path, child)).sum())
        .unwrap_or(0)
}

/// Vybere z výpisu adresáře položky daných jmen (v pořadí jmen; jména,
/// která ve výpisu nejsou, se vynechají).
fn select_items<'a>(items: &'a [VfsItem], names: &[&str]) -> Vec<&'a VfsItem> {
    let by_name: HashMap<&str, &VfsItem> = items.iter().map(|item| (item.name.as_str(), item)).collect();
    names.iter().filter_map(|name| by_name.get(name).copied()).collect()
}

/// Stav jednoho přenosu (kopírování nebo přesun) sdílený rekurzí.
struct Transfer<'a> {
    src: &'a dyn Vfs,
    dst: &'a dyn Vfs,
    overwrite: OverwriteMode,
    /// Přesun: zdroj se po úspěšném přenesení smaže.
    remove_source: bool,
    /// Přesun v rámci jednoho lokálního svazku (zdrojový a cílový lokální
    /// VFS): položky se přejmenují místo kopírování a mazání.
    rename_local: Option<(&'a LocalFs, &'a LocalFs)>,
    /// Celková velikost pro procenta (0 = neznámý celek).
    total_bytes: u64,
    transferred: u64,
    stats: TransferStats,
    progress: &'a mut dyn ProgressCallback,
    /// Přenosový buffer společný pro všechny soubory.
    buffer: Vec<u8>,
    /// Počet právě následovaných odkazů na adresář (zanořených v sobě).
    followed_links: u32,
}

impl Transfer<'_> {
    /// Přenese jednu položku (soubor, nebo adresář rekurzivně) ze `src_path`
    /// do `dst_path`. Druh položky je známý z výpisu rodiče (`item`), takže se
    /// zdroj znovu nevypisuje. `dst_may_exist` = cíl může existovat (v právě
    /// vytvořeném cílovém adresáři nic být nemůže – existence se pak netestuje,
    /// což u FTP ušetří výpis adresáře na každý soubor).
    ///
    /// Vrací `true`, pokud byla položka přenesena celá; `false`, pokud v cíli
    /// existovala a byla přeskočena (ona sama nebo něco uvnitř adresáře) –
    /// při přesunu pak zdroj zůstává na místě.
    fn transfer_item(&mut self, item: &VfsItem, src_path: &str, dst_path: &str, dst_may_exist: bool) -> SalResult<bool> {
        // Zrušení se kontroluje i mezi položkami (prázdné soubory a adresáře
        // jinak průběh nehlásí).
        if !self.progress.on_progress(self.transferred, self.total_bytes) {
            return Err(SalError::Cancelled);
        }
        let dst_exists = dst_may_exist && self.dst.exists(dst_path)?;
        if let Some((src_local, dst_local)) = self.rename_local {
            if let Some(moved) = self.rename_item(src_local, dst_local, item, src_path, dst_path, dst_exists)? {
                return Ok(moved);
            }
        }
        // Symbolický odkaz se přenáší jako odkaz, pokud zdroj umí přečíst
        // jeho cíl a úložiště cíle odkazy umí; jinak se přenese to, na co
        // ukazuje (adresář rekurzivně, soubor obsahem).
        if item.kind == VfsItemKind::Link {
            let complete = match self.transfer_link(src_path, dst_path, dst_exists)? {
                Some(done) => done,
                None => self.transfer_link_target(item, src_path, dst_path, dst_exists)?,
            };
            // Při přesunu se maže jen odkaz sám, ne to, na co ukazuje.
            if self.remove_source && complete {
                self.src.delete_known(src_path, false, false)?;
            }
            return Ok(complete);
        }
        if item.kind == VfsItemKind::Dir {
            self.transfer_dir(src_path, dst_path, dst_exists)
        } else {
            self.transfer_file(item, src_path, dst_path, dst_exists)
        }
    }

    /// Přenese symbolický odkaz jako odkaz se stejným cílem.
    ///
    /// Vrací `None`, když to nejde (zdroj cíl odkazu nezná, cílové úložiště
    /// odkazy neumí) a položku je třeba přenést obsahem; jinak `Some` se
    /// stejným významem jako `transfer_item`.
    fn transfer_link(&mut self, src_path: &str, dst_path: &str, dst_exists: bool) -> SalResult<Option<bool>> {
        if !self.dst.supports_symlinks() {
            return Ok(None);
        }
        let Some(target) = self.src.read_link(src_path)? else {
            return Ok(None);
        };
        if dst_exists {
            if !self.overwrite_existing()? {
                return Ok(Some(false));
            }
            // Odkaz se přes existující položku vytvořit nedá (neprázdný
            // adresář v cíli zůstane a vytvoření odkazu ohlásí chybu).
            let _ = self.dst.delete(dst_path, false);
        }
        self.dst.create_symlink(dst_path, &target)?;
        self.stats.files += 1;
        Ok(Some(true))
    }

    /// Přenese to, na co odkaz ukazuje (adresář rekurzivně, soubor obsahem),
    /// když ho nelze přenést jako odkaz. Zdroj se přitom nemaže – obsah patří
    /// cíli odkazu, ne přesouvané položce.
    fn transfer_link_target(&mut self, item: &VfsItem, src_path: &str, dst_path: &str, dst_exists: bool) -> SalResult<bool> {
        let is_dir = self.src.is_dir(src_path)?;
        if is_dir && self.followed_links >= MAX_FOLLOWED_LINKS {
            return Err(SalError::Io(format!(
                "Odkaz {} vede do sebe sama (odkaz na nadřazený adresář?).",
                src_path
            )));
        }
        let remove_source = std::mem::replace(&mut self.remove_source, false);
        self.followed_links += 1;
        let result = if is_dir {
            self.transfer_dir(src_path, dst_path, dst_exists)
        } else {
            self.transfer_file(item, src_path, dst_path, dst_exists)
        };
        self.followed_links -= 1;
        self.remove_source = remove_source;
        result
    }

    /// Rozhodne konflikt s existujícím cílem podle režimu přepsání.
    /// Vrací `true` = cíl přepsat, `false` = položku přeskočit (započítá ji);
    /// v režimu Ask končí chybou AlreadyExists.
    fn overwrite_existing(&mut self) -> SalResult<bool> {
        match self.overwrite {
            OverwriteMode::Overwrite => Ok(true),
            OverwriteMode::Skip => {
                self.stats.skipped += 1;
                Ok(false)
            }
            OverwriteMode::Ask => Err(SalError::AlreadyExists),
        }
    }

    /// Přesun položky přejmenováním na lokálním disku.
    ///
    /// Vrací `Some(true)` po přesunu, `Some(false)` u přeskočeného konfliktu
    /// a `None`, když přejmenovat nelze a má se použít kopírování s mazáním
    /// (slučování do existujícího adresáře, cíl na jiném svazku).
    fn rename_item(
        &mut self,
        src_local: &LocalFs,
        dst_local: &LocalFs,
        item: &VfsItem,
        src_path: &str,
        dst_path: &str,
        dst_exists: bool,
    ) -> SalResult<Option<bool>> {
        if dst_exists {
            // Adresář do existujícího adresáře se slučuje položku po položce.
            if item.kind == VfsItemKind::Dir && self.dst.is_dir(dst_path)? {
                return Ok(None);
            }
            // Přejmenování existující cílový soubor nahradí samo.
            if !self.overwrite_existing()? {
                return Ok(Some(false));
            }
        }
        match src_local.rename_to(src_path, dst_local, dst_path) {
            Ok(()) => {
                if item.kind == VfsItemKind::Dir {
                    self.stats.dirs += 1;
                } else {
                    self.stats.files += 1;
                }
                Ok(Some(true))
            }
            // Jiný svazek (např. bod připojení uvnitř stromu): kopírovat a mazat.
            Err(err) if err.raw_os_error() == Some(libc::EXDEV) => Ok(None),
            Err(err) => Err(SalError::from(err)),
        }
    }

    /// Přenese adresář: cílový vytvoří (existující se slučuje) a přenese obsah.
    fn transfer_dir(&mut self, src_path: &str, dst_path: &str, dst_exists: bool) -> SalResult<bool> {
        if !dst_exists {
            self.dst.mkdir(dst_path)?;
            self.stats.dirs += 1;
        }
        let mut complete = true;
        for child in self.src.list(src_path)? {
            let child_src = join_path(src_path, &child.name);
            let child_dst = join_path(dst_path, &child.name);
            complete &= self.transfer_item(&child, &child_src, &child_dst, dst_exists)?;
        }
        // Zdrojový adresář se při přesunu maže, jen když je už prázdný
        // (přeskočené položky v něm zůstávají).
        if self.remove_source && complete {
            self.src.delete_known(src_path, true, false)?;
        }
        Ok(complete)
    }

    /// Přenese soubor (nebo to, na co ukazuje odkaz) streamovaným kopírováním.
    fn transfer_file(&mut self, item: &VfsItem, src_path: &str, dst_path: &str, dst_exists: bool) -> SalResult<bool> {
        // Existující cílový soubor řeší režim přepsání.
        if dst_exists && !self.overwrite_existing()? {
            return Ok(false);
        }
        // Zdroj se otevírá dřív, než se sáhne na cíl: nečitelný zdroj (chybné
        // heslo archivu, chybějící práva) nesmí stát existující cílový soubor.
        let mut reader = self.src.open_read(src_path)?;
        if dst_exists {
            // Starý cíl se maže, aby se nezapisovalo skrz odkaz nebo do souboru
            // jen pro čtení (případnou chybu ohlásí až otevření pro zápis).
            let _ = self.dst.delete(dst_path, false);
        }
        let mut writer = self.dst.open_write(dst_path, Some(item.size))?;
        let result = self.copy_stream(reader.as_mut(), writer.as_mut());
        // Streamy se zavírají dřív, než se sáhne na cíl nebo zdroj (mazání).
        drop(writer);
        drop(reader);
        let copied = match result {
            Ok(copied) => copied,
            Err(err) => {
                // Nedokončený cílový soubor po chybě nebo zrušení nenecháváme –
                // vypadal by jako hotová kopie.
                let _ = self.dst.delete_known(dst_path, false, false);
                return Err(err);
            }
        };
        self.stats.files += 1;
        self.stats.bytes += copied;
        if self.remove_source {
            // Druh je známý z výpisu – bez dalšího dotazu na zdroj.
            self.src.delete_known(src_path, false, false)?;
        }
        Ok(true)
    }

    /// Zkopíruje obsah souboru po blocích s hlášením průběhu a potvrdí
    /// dokončení zápisu. Vrací počet přenesených bajtů.
    fn copy_stream(&mut self, reader: &mut dyn VfsReadStream, writer: &mut dyn VfsWriteStream) -> SalResult<u64> {
        let mut copied = 0u64;
        loop {
            let read = reader.read(&mut self.buffer)?;
            if read == 0 {
                break;
            }
            writer.write_all(&self.buffer[..read])?;
            copied += read as u64;
            self.transferred += read as u64;
            // Hlášení průběhu po každém bloku je zároveň kontrola zrušení.
            if !self.progress.on_progress(self.transferred, self.total_bytes) {
                return Err(SalError::Cancelled);
            }
        }
        // Teprve potvrzené dokončení znamená, že cíl data opravdu přijal
        // (u FTP závěrečná odpověď serveru) – při přesunu se pak maže zdroj.
        writer.finish()?;
        Ok(copied)
    }
}

/// Odmítne přenos, který by zničil data nebo se zacyklil: do téhož adresáře
/// (položka by přepsala sama sebe) a adresáře do sebe sama či svého podadresáře.
///
/// Adresáře se porovnávají podle identity úložiště (`Vfs::dir_identity` –
/// pozná tentýž adresář i přes dva lokální VFS nebo dvě připojení k jednomu
/// serveru); VFS bez identity jen tehdy, jde-li o tutéž instanci.
fn check_destination(src: &dyn Vfs, src_dir: &str, names: &[&str], dst: &dyn Vfs, dst_dir: &str) -> SalResult<()> {
    let (source_dir, target_dir) = match (src.dir_identity(src_dir), dst.dir_identity(dst_dir)) {
        (Some(source), Some(target)) => (source, target),
        _ if std::ptr::addr_eq(src as *const dyn Vfs, dst as *const dyn Vfs) => {
            (normalize_vfs_path(src_dir), normalize_vfs_path(dst_dir))
        }
        // Různá úložiště se překrývat nemohou.
        _ => return Ok(()),
    };
    if source_dir == target_dir {
        return Err(SalError::Io("Zdrojový a cílový adresář jsou stejné.".to_string()));
    }
    for name in names {
        // Cíl leží uvnitř přenášené položky (nebo je to ona sama).
        let source_item = join_path(&source_dir, name);
        if target_dir == source_item || target_dir.starts_with(&format!("{}/", source_item)) {
            return Err(SalError::Io(format!("Položku „{}“ nelze přenést do sebe sama.", name)));
        }
    }
    Ok(())
}

/// Společná implementace kopírování a přesunu sady položek
/// (`remove_source` = přesun).
#[allow(clippy::too_many_arguments)]
fn transfer_items(
    src: &dyn Vfs,
    src_dir: &str,
    names: &[&str],
    dst: &dyn Vfs,
    dst_dir: &str,
    overwrite: OverwriteMode,
    remove_source: bool,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    check_destination(src, src_dir, names, dst, dst_dir)?;
    // Výpis zdrojového adresáře jednou: druhy a velikosti vybraných položek.
    // Adresář, který systém nedovolí vypsat (Koš na macOS), může jednotlivé
    // položky přesto zpřístupnit (soubor přetažený z Finderu) – zjistí se po jedné.
    // VFS, který to neumí, skončí původním odepřeným přístupem.
    let listed = match src.list(src_dir) {
        Err(SalError::PermissionDenied) => names
            .iter()
            .map(|name| src.item(&join_path(src_dir, name))?.ok_or(SalError::PermissionDenied))
            .collect::<SalResult<Vec<_>>>()?,
        other => other?,
    };
    let items = select_items(&listed, names);
    if items.len() < names.len() {
        return Err(SalError::NotFound);
    }
    // Přesun na témže lokálním svazku je jen přejmenování – bez měření velikosti.
    let rename_local = match (src.as_local(), dst.as_local()) {
        (Some(src_local), Some(dst_local)) if remove_source && src_local.same_device(src_dir, dst_local, dst_dir) => {
            Some((src_local, dst_local))
        }
        _ => None,
    };
    // Celková velikost pro procentuální progress. U vzdálených protokolů se
    // neměří (dvojitý výpis by operaci zbytečně prodlužoval) – total 0
    // znamená „neznámý celek“.
    let total_bytes = if src.supports_size_scan() && rename_local.is_none() {
        items.iter().map(|item| measure_item(src, src_dir, item)).sum()
    } else {
        0
    };
    let mut transfer = Transfer {
        src,
        dst,
        overwrite,
        remove_source,
        rename_local,
        total_bytes,
        transferred: 0,
        stats: TransferStats::default(),
        progress,
        buffer: vec![0u8; COPY_BUFFER_SIZE],
        followed_links: 0,
    };
    for item in items {
        let src_path = join_path(src_dir, &item.name);
        let dst_path = join_path(dst_dir, &item.name);
        transfer.transfer_item(item, &src_path, &dst_path, true)?;
    }
    let done = transfer.transferred.max(total_bytes);
    transfer.progress.on_progress(done, total_bytes);
    Ok(transfer.stats)
}

/// Zkopíruje sadu položek z adresáře `src_dir` ve zdrojovém VFS do
/// adresáře `dst_dir` v cílovém VFS (rekurzivně). Existující adresáře se
/// slučují, existující soubory řeší `overwrite`.
pub fn copy_items(
    src: &dyn Vfs,
    src_dir: &str,
    names: &[&str],
    dst: &dyn Vfs,
    dst_dir: &str,
    overwrite: OverwriteMode,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    transfer_items(src, src_dir, names, dst, dst_dir, overwrite, false, progress)
}

/// Přesune sadu položek. Na jednom lokálním svazku se položky přejmenují,
/// jinak se každá zkopíruje a její zdroj se hned poté smaže. Položky
/// přeskočené kvůli existujícímu cíli (`OverwriteMode::Skip`) zůstávají
/// ve zdroji.
pub fn move_items(
    src: &dyn Vfs,
    src_dir: &str,
    names: &[&str],
    dst: &dyn Vfs,
    dst_dir: &str,
    overwrite: OverwriteMode,
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    transfer_items(src, src_dir, names, dst, dst_dir, overwrite, true, progress)
}

/// Smaže sadu položek v adresáři `dir` daného VFS (rekurzivně).
pub fn delete_items(
    vfs: &dyn Vfs,
    dir: &str,
    names: &[&str],
    progress: &mut dyn ProgressCallback,
) -> SalResult<TransferStats> {
    let mut stats = TransferStats::default();
    for (index, name) in names.iter().enumerate() {
        if !progress.on_progress(index as u64, names.len() as u64) {
            return Err(SalError::Cancelled);
        }
        vfs.delete(&join_path(dir, name), true)?;
        stats.files += 1;
    }
    progress.on_progress(names.len() as u64, names.len() as u64);
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::local::LocalFs;
    use std::fs;
    use std::path::PathBuf;

    /// Vytvoří dva lokální VFS (zdroj a cíl) s testovacími daty.
    /// Tag odděluje adresáře jednotlivých testů (běží paralelně).
    fn prepare(tag: &str) -> (LocalFs, LocalFs, PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("salcore-ops-{}-{}", tag, std::process::id()));
        let src_dir = base.join("src");
        let dst_dir = base.join("dst");
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(src_dir.join("pod")).unwrap();
        fs::create_dir_all(&dst_dir).unwrap();
        fs::write(src_dir.join("a.txt"), b"aaa").unwrap();
        fs::write(src_dir.join("pod").join("b.txt"), b"bbb").unwrap();
        let src = LocalFs::new(src_dir.to_str()).unwrap();
        let dst = LocalFs::new(dst_dir.to_str()).unwrap();
        (src, dst, src_dir, dst_dir)
    }

    /// Zdrojový adresář nejde vypsat (práva jen pro průchod – jako Koš na
    /// macOS), jednotlivý soubor ale číst lze: kopírování projde, jméno,
    /// které v adresáři není, skončí chybou „nenalezeno“.
    #[cfg(unix)]
    #[test]
    fn test_copy_from_unlistable_directory() {
        use std::os::unix::fs::PermissionsExt;
        let (src, dst, src_path, _dst_path) = prepare("unlistable");
        fs::set_permissions(&src_path, fs::Permissions::from_mode(0o300)).unwrap();
        let copied = copy_items(&src, "/", &["a.txt"], &dst, "/", OverwriteMode::Ask, &mut NoProgress);
        let missing = copy_items(&src, "/", &["neni.txt"], &dst, "/", OverwriteMode::Ask, &mut NoProgress);
        // Práva vrátit před kontrolami, aby šel adresář po testu smazat.
        fs::set_permissions(&src_path, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(copied.unwrap().files, 1);
        assert!(dst.exists("/a.txt").unwrap());
        assert_eq!(missing.unwrap_err(), SalError::NotFound);
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    #[test]
    fn test_copy_items_recursive() {
        let (src, dst, src_path, dst_path) = prepare("copy");
        let stats = copy_items(
            &src,
            "/",
            &["a.txt", "pod"],
            &dst,
            "/",
            OverwriteMode::Ask,
            &mut NoProgress,
        )
        .unwrap();
        assert_eq!(stats.files, 2);
        assert_eq!(stats.dirs, 1);
        assert!(dst.exists("/a.txt").unwrap());
        assert!(dst.exists("/pod/b.txt").unwrap());

        // Konflikt v režimu Ask skončí chybou AlreadyExists.
        let result = copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Ask,
            &mut NoProgress,
        );
        assert_eq!(result.unwrap_err(), SalError::AlreadyExists);
        // Režim Overwrite projde, režim Skip položku přeskočí.
        copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Overwrite,
            &mut NoProgress,
        )
        .unwrap();
        let stats = copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Skip,
            &mut NoProgress,
        )
        .unwrap();
        assert_eq!(stats.skipped, 1);

        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
        let _ = dst_path;
    }

    #[test]
    fn test_move_between_roots() {
        let (src, dst, src_path, dst_path) = prepare("move");
        move_items(&src, "/", &["pod"], &dst, "/", OverwriteMode::Ask, &mut NoProgress).unwrap();
        assert!(!src.exists("/pod").unwrap());
        assert!(dst.exists("/pod/b.txt").unwrap());
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
        let _ = dst_path;
    }

    /// Přesun mezi adresáři jednoho VFS – stav v aplikaci, kde oba panely
    /// sdílejí lokální VFS s kořenem „/“.
    #[test]
    fn test_move_within_one_vfs() {
        let (_src, _dst, src_path, _dst_path) = prepare("move-one");
        let base = src_path.parent().unwrap();
        let vfs = LocalFs::new(base.to_str()).unwrap();
        let stats =
            move_items(&vfs, "/src", &["a.txt", "pod"], &vfs, "/dst", OverwriteMode::Ask, &mut NoProgress).unwrap();
        assert_eq!((stats.files, stats.dirs), (1, 1));
        assert!(vfs.list("/src").unwrap().is_empty());
        assert_eq!(fs::read(base.join("dst/a.txt")).unwrap(), b"aaa");
        assert_eq!(fs::read(base.join("dst/pod/b.txt")).unwrap(), b"bbb");
        fs::remove_dir_all(base).unwrap();
    }

    /// Konflikty při přesunu: Ask hlásí konflikt, Skip nechá zdroj i cíl beze
    /// změny, Overwrite cíl nahradí; adresář se s existujícím slučuje.
    #[test]
    fn test_move_conflicts() {
        let (_src, _dst, src_path, _dst_path) = prepare("move-conflict");
        let base = src_path.parent().unwrap();
        let vfs = LocalFs::new(base.to_str()).unwrap();
        fs::write(base.join("dst/a.txt"), b"puvodni").unwrap();
        fs::create_dir_all(base.join("dst/pod")).unwrap();
        fs::write(base.join("dst/pod/jiny.txt"), b"jiny").unwrap();
        fs::write(base.join("dst/pod/b.txt"), b"stare b").unwrap();

        let result = move_items(&vfs, "/src", &["a.txt"], &vfs, "/dst", OverwriteMode::Ask, &mut NoProgress);
        assert_eq!(result.unwrap_err(), SalError::AlreadyExists);

        // Skip: přeskočený soubor zůstává ve zdroji, cíl se nemění; adresář
        // se nesmaže, dokud v něm zůstává přeskočená položka.
        let stats =
            move_items(&vfs, "/src", &["a.txt", "pod"], &vfs, "/dst", OverwriteMode::Skip, &mut NoProgress).unwrap();
        assert_eq!(stats.skipped, 2);
        assert_eq!(fs::read(base.join("src/a.txt")).unwrap(), b"aaa");
        assert_eq!(fs::read(base.join("dst/a.txt")).unwrap(), b"puvodni");
        assert_eq!(fs::read(base.join("src/pod/b.txt")).unwrap(), b"bbb");

        // Overwrite: soubory se nahradí, cizí obsah cílového adresáře zůstane.
        move_items(&vfs, "/src", &["a.txt", "pod"], &vfs, "/dst", OverwriteMode::Overwrite, &mut NoProgress).unwrap();
        assert!(vfs.list("/src").unwrap().is_empty());
        assert_eq!(fs::read(base.join("dst/a.txt")).unwrap(), b"aaa");
        assert_eq!(fs::read(base.join("dst/pod/b.txt")).unwrap(), b"bbb");
        assert_eq!(fs::read(base.join("dst/pod/jiny.txt")).unwrap(), b"jiny");
        fs::remove_dir_all(base).unwrap();
    }

    /// Přesun kopírováním a mazáním (mezi různými VFS – tady ZIP nelze, proto
    /// vynucené kopírování přes VFS bez lokálního přejmenování): přeskočený
    /// soubor nesmí ze zdroje zmizet.
    #[test]
    fn test_move_by_copy_keeps_skipped_source() {
        let (src, dst, src_path, dst_path) = prepare("move-copy");
        fs::write(dst_path.join("a.txt"), b"puvodni").unwrap();
        let (src, dst) = (NotLocal(src), NotLocal(dst));
        let stats =
            move_items(&src, "/", &["a.txt", "pod"], &dst, "/", OverwriteMode::Skip, &mut NoProgress).unwrap();
        assert_eq!((stats.skipped, stats.files), (1, 1));
        assert_eq!(fs::read(src_path.join("a.txt")).unwrap(), b"aaa");
        assert_eq!(fs::read(dst_path.join("a.txt")).unwrap(), b"puvodni");
        assert!(!src_path.join("pod").exists());
        assert_eq!(fs::read(dst_path.join("pod/b.txt")).unwrap(), b"bbb");
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    /// Kopie či přesun do téhož adresáře nebo adresáře do sebe sama se odmítne
    /// dřív, než se čehokoli dotkne (dřív „Přepsat“ zdrojový soubor smazalo).
    #[test]
    fn test_rejects_same_directory_and_self_nesting() {
        let (_src, _dst, src_path, _dst_path) = prepare("same-dir");
        let base = src_path.parent().unwrap();
        let vfs = LocalFs::new(base.to_str()).unwrap();
        for operation in [copy_items, move_items] {
            let same = operation(&vfs, "/src", &["a.txt"], &vfs, "/src", OverwriteMode::Overwrite, &mut NoProgress);
            assert!(matches!(same, Err(SalError::Io(_))));
            let nested = operation(&vfs, "/src", &["pod"], &vfs, "/src/pod", OverwriteMode::Ask, &mut NoProgress);
            assert!(matches!(nested, Err(SalError::Io(_))));
        }
        assert_eq!(fs::read(base.join("src/a.txt")).unwrap(), b"aaa");
        // Jiný lokální VFS mířící na stejný adresář se pozná také.
        let other = LocalFs::new(base.join("src").to_str()).unwrap();
        let same = copy_items(&vfs, "/src", &["a.txt"], &other, "/", OverwriteMode::Overwrite, &mut NoProgress);
        assert!(matches!(same, Err(SalError::Io(_))));
        assert_eq!(fs::read(base.join("src/a.txt")).unwrap(), b"aaa");
        fs::remove_dir_all(base).unwrap();
    }

    /// Symbolické odkazy: mezi úložišti, která je umí, se kopírují jako
    /// odkazy (i odkaz na adresář a odkaz vedoucí nikam); kam odkaz vytvořit
    /// nejde, přenese se to, na co ukazuje.
    #[test]
    fn test_symlinks() {
        use std::os::unix::fs::symlink;
        let (src, dst, src_path, dst_path) = prepare("links");
        symlink("a.txt", src_path.join("na-soubor")).unwrap();
        symlink("pod", src_path.join("na-adresar")).unwrap();
        symlink("neexistuje", src_path.join("nikam")).unwrap();
        let names = ["na-soubor", "na-adresar", "nikam"];
        copy_items(&src, "/", &names, &dst, "/", OverwriteMode::Ask, &mut NoProgress).unwrap();
        for (name, target) in [("na-soubor", "a.txt"), ("na-adresar", "pod"), ("nikam", "neexistuje")] {
            assert_eq!(fs::read_link(dst_path.join(name)).unwrap().to_str(), Some(target));
        }
        // Přesun kopírováním odkaz ve zdroji smaže, jeho cíl ne.
        let other = dst_path.join("jinam");
        fs::create_dir(&other).unwrap();
        move_items(&NotLocal(src), "/", &["na-adresar"], &NotLocal(dst), "/jinam", OverwriteMode::Ask, &mut NoProgress)
            .unwrap();
        assert!(fs::symlink_metadata(src_path.join("na-adresar")).is_err());
        assert_eq!(fs::read(src_path.join("pod/b.txt")).unwrap(), b"bbb");
        // Cíl bez podpory odkazů (obálka NotLocal ji nepřebírá): obsah cíle odkazu.
        assert_eq!(fs::read(other.join("na-adresar/b.txt")).unwrap(), b"bbb");
        assert!(fs::symlink_metadata(other.join("na-adresar")).unwrap().is_dir());
        // Odkaz na nadřazený adresář přenášený obsahem skončí chybou, nezacyklí se.
        fs::remove_file(src_path.join("nikam")).unwrap();
        symlink("..", src_path.join("pod/nahoru")).unwrap();
        let cycle = fs::canonicalize(&dst_path).unwrap().join("cyklus");
        fs::create_dir(&cycle).unwrap();
        let (src, dst) = (NotLocal(LocalFs::new(src_path.to_str()).unwrap()), NotLocal(LocalFs::new(cycle.to_str()).unwrap()));
        let result = copy_items(&src, "/", &["pod"], &dst, "/", OverwriteMode::Overwrite, &mut NoProgress);
        assert!(matches!(result, Err(SalError::Io(_))));
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    /// Zrušení uprostřed souboru nenechá v cíli nedokončenou kopii.
    #[test]
    fn test_cancel_removes_partial_file() {
        let (src, dst, src_path, dst_path) = prepare("partial");
        fs::write(src_path.join("velky.bin"), vec![7u8; COPY_BUFFER_SIZE * 2]).unwrap();
        let result = copy_items(&src, "/", &["velky.bin"], &dst, "/", OverwriteMode::Ask, &mut CancelAfter(2));
        assert_eq!(result.unwrap_err(), SalError::Cancelled);
        assert!(!dst_path.join("velky.bin").exists());
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    /// Chybějící zdrojová položka je chyba (nic se tiše nevynechá).
    #[test]
    fn test_missing_source_item() {
        let (src, dst, src_path, _dst_path) = prepare("missing");
        let result = copy_items(&src, "/", &["neni.txt"], &dst, "/", OverwriteMode::Ask, &mut NoProgress);
        assert_eq!(result.unwrap_err(), SalError::NotFound);
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    #[test]
    fn test_delete_items() {
        let (src, _dst, src_path, _dst_path) = prepare("delete");
        delete_items(&src, "/", &["a.txt", "pod"], &mut NoProgress).unwrap();
        let items = src.list("/").unwrap();
        assert!(items.is_empty());
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }

    /// Progress, který operaci zruší při N-tém hlášení.
    struct CancelAfter(u32);
    impl ProgressCallback for CancelAfter {
        fn on_progress(&mut self, _done: u64, _total: u64) -> bool {
            self.0 = self.0.saturating_sub(1);
            self.0 > 0
        }
    }

    /// Obálka skrývající, že VFS je lokální – vynutí obecnou cestu přesunu
    /// (kopírování a mazání) jako u archivů a vzdálených serverů.
    struct NotLocal(LocalFs);
    impl Vfs for NotLocal {
        fn kind(&self) -> crate::vfs::VfsKind {
            crate::vfs::VfsKind::Ftp
        }
        fn label(&self) -> String {
            self.0.label()
        }
        fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
            self.0.list(path)
        }
        fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
            self.0.open_read(path)
        }
        fn open_write(&self, path: &str, size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
            self.0.open_write(path, size_hint)
        }
        fn mkdir(&self, path: &str) -> SalResult<()> {
            self.0.mkdir(path)
        }
        fn delete(&self, path: &str, recursive: bool) -> SalResult<()> {
            self.0.delete(path, recursive)
        }
        fn rename(&self, path: &str, new_name: &str) -> SalResult<()> {
            self.0.rename(path, new_name)
        }
        fn exists(&self, path: &str) -> SalResult<bool> {
            self.0.exists(path)
        }
        fn is_dir(&self, path: &str) -> SalResult<bool> {
            self.0.is_dir(path)
        }
    }

    /// Progress, který operaci zruší hned na začátku.
    struct CancelNow;
    impl ProgressCallback for CancelNow {
        fn on_progress(&mut self, _done: u64, _total: u64) -> bool {
            false
        }
    }

    #[test]
    fn test_cancellation() {
        let (src, dst, src_path, _dst_path) = prepare("cancel");
        let result = copy_items(
            &src,
            "/",
            &["a.txt"],
            &dst,
            "/",
            OverwriteMode::Ask,
            &mut CancelNow,
        );
        assert_eq!(result.unwrap_err(), SalError::Cancelled);
        fs::remove_dir_all(src_path.parent().unwrap()).unwrap();
    }
}
