// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! TAR a TAR.GZ archiv jako virtuální souborový systém (jen pro čtení).
//!
//! Používáme vlastní minimální TAR parser, protože potřebujeme:
//! - u plain TAR seekovat přímo na data položky (rychlé čtení),
//! - u TAR.GZ pokračovat v dekompresi tam, kde předchozí čtení skončilo,
//!   aby rozbalení celého archivu proběhlo jedním průchodem.
//!
//! Podporované formáty: ustar (včetně prefixu), GNU longname ('L') a
//! PAX rozšířené hlavičky ('x' – path, size, mtime).

use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use flate2::read::GzDecoder;

use crate::error::{SalError, SalResult};
use crate::vfs::{
    normalize_vfs_path, Vfs, VfsItem, VfsItemKind, VfsKind, VfsReadStream, VfsWriteStream,
};

/// Velikost jedné TAR hlavičky a zarovnání datových bloků.
const TAR_BLOCK: u64 = 512;

/// Formát archivu na disku.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TarFormat {
    /// Ne komprimovaný .tar – lze seekovat přímo na data.
    Plain,
    /// Gzipem komprimovaný .tar.gz – čtení je sekvenční.
    Gzip,
}

/// Detekce formátu archivu podle magických bajtů na začátku souboru.
/// Vrací None, pokud soubor není ani gzip, ani TAR ( ZIP řeší volající).
pub fn probe_tar_format(path: &Path) -> SalResult<Option<TarFormat>> {
    let mut file = File::open(path)?;
    let mut head = [0u8; 512];
    let read = read_up_to(&mut file, &mut head)?;
    if read >= 2 && head[0] == 0x1f && head[1] == 0x8b {
        // GZIP magické bajty – předpokládáme tar.gz.
        return Ok(Some(TarFormat::Gzip));
    }
    // TAR: magické "ustar" na offsetu 257 (ustar i GNU tar).
    if read >= 262 && &head[257..262] == b"ustar" {
        return Ok(Some(TarFormat::Plain));
    }
    // Starší TAR bez magického řetězce: ověříme platnost oktalového size pole
    // a rozumnou hodnotou mtime – jinak soubor necháme být.
    if read >= 512 && parse_octal(&head[124..136]).is_some() && parse_octal(&head[136..148]).is_some()
    {
        return Ok(Some(TarFormat::Plain));
    }
    Ok(None)
}

/// Přečte až `buf.len()` bajtů; vrací počet přečtených (0 = čistý EOF).
fn read_up_to<R: Read + ?Sized>(reader: &mut R, buf: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0usize;
    while filled < buf.len() {
        let read = reader.read(&mut buf[filled..])?;
        if read == 0 {
            break;
        }
        filled += read;
    }
    Ok(filled)
}

/// Zparsuje oktalové číslo z pole hlavičky (toleruje NUL/mezery na konci;
/// rozumí i GNU base-256 kódování pro velké soubory).
/// Vrací None pro prázdné či nevalidní pole.
fn parse_octal(field: &[u8]) -> Option<u64> {
    // GNU base-256: první bajt má nastavený nejvyšší bit.
    if !field.is_empty() && field[0] & 0x80 != 0 {
        let mut value: u64 = (field[0] & 0x7f) as u64;
        for &byte in &field[1..] {
            value = value.checked_mul(256)?.checked_add(byte as u64)?;
        }
        return Some(value);
    }
    let digits: Vec<u8> = field
        .iter()
        .copied()
        .take_while(|&byte| byte != 0)
        .collect();
    let trimmed: &[u8] = {
        let start = digits.iter().position(|&b| b != b' ').unwrap_or(0);
        &digits[start..]
    };
    if trimmed.is_empty() {
        return None;
    }
    let mut value: u64 = 0;
    for &byte in trimmed {
        if byte == b' ' {
            break;
        }
        if !byte.is_ascii_digit() {
            return None;
        }
        value = value.checked_mul(8)?.checked_add((byte - b'0') as u64)?;
    }
    Some(value)
}

/// Vytěží řetězec z NUL-ukončeného pole hlavičky.
fn field_string(field: &[u8]) -> String {
    let end = field.iter().position(|&byte| byte == 0).unwrap_or(field.len());
    String::from_utf8_lossy(&field[..end]).to_string()
}

/// Jedna položka indexu archivu (naparsovaná metadata bez obsahu).
#[derive(Debug, Clone)]
struct TarIndexEntry {
    /// Cesta uvnitř archivu ve VFS tvaru bez úvodního lomítka (např. „pod/b.txt").
    name: String,
    size: u64,
    mtime: i64,
    kind: VfsItemKind,
    /// Offset dat v (dekomprimovaném) TAR streamu.
    data_offset: u64,
}

/// Abstrakce zdroje dat pro skenování: plain TAR umí seek (rychlé
/// přeskakování dat), TAR.GZ umí jen číst (data se zahodí).
trait TarSource: Read {
    /// Přeskočí `bytes` bajtů dat; vrací novou pozici.
    fn skip(&mut self, bytes: u64) -> io::Result<u64>;
}

/// Seekovatelný zdroj (soubor plain TAR).
struct SeekSource<R: Read + Seek> {
    reader: R,
    pos: u64,
}

impl<R: Read + Seek> Read for SeekSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = self.reader.read(buf)?;
        self.pos += read as u64;
        Ok(read)
    }
}

impl<R: Read + Seek> TarSource for SeekSource<R> {
    fn skip(&mut self, bytes: u64) -> io::Result<u64> {
        self.reader.seek(SeekFrom::Current(bytes as i64))?;
        self.pos += bytes;
        Ok(self.pos)
    }
}

/// Sekvenční zdroj (gzip dekodér).
struct SeqSource<R: Read> {
    reader: R,
    pos: u64,
}

impl<R: Read> Read for SeqSource<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = self.reader.read(buf)?;
        self.pos += read as u64;
        Ok(read)
    }
}

impl<R: Read> TarSource for SeqSource<R> {
    fn skip(&mut self, mut bytes: u64) -> io::Result<u64> {
        // Gzip nelze seekovat – data přečteme a zahodíme po blocích.
        let mut sink = [0u8; 64 * 1024];
        while bytes > 0 {
            let want = std::cmp::min(bytes, sink.len() as u64) as usize;
            let read = read_up_to(&mut self.reader, &mut sink[..want])?;
            if read == 0 {
                break; // EOF dřív než očekáváno
            }
            bytes -= read as u64;
            self.pos += read as u64;
        }
        Ok(self.pos)
    }
}

/// Provede úplný průchod TAR streamem a vytvoří index položek.
/// Přebírá metadata z rozšířených hlaviček (GNU longname, PAX).
fn scan_tar(source: &mut dyn TarSource) -> io::Result<Vec<TarIndexEntry>> {
    let mut entries: Vec<TarIndexEntry> = Vec::new();
    let mut pos: u64 = 0; // pozice aktuální hlavičky
    // Odložená metadata z rozšířených hlaviček platná pro následující položku.
    let mut pending_name: Option<String> = None;
    let mut pax_path: Option<String> = None;
    let mut pax_size: Option<u64> = None;
    let mut pax_mtime: Option<i64> = None;

    loop {
        let mut header = [0u8; TAR_BLOCK as usize];
        let read = read_up_to(source, &mut header)?;
        if read == 0 {
            break; // čisté EOF
        }
        if read < header.len() {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "Poškozená TAR hlavička (neúplný blok).",
            ));
        }
        pos += TAR_BLOCK;

        // Celé nulové bloky na konci archivu (min. dva) ukončují scan.
        if header.iter().all(|&byte| byte == 0) {
            break;
        }

        // Povinné položky hlavičky; nevalidní size/mtime bereme jako 0.
        let size = parse_octal(&header[124..136]).unwrap_or(0);
        let mtime = parse_octal(&header[136..148]).unwrap_or(0) as i64;
        let typeflag = header[156];
        let data_offset = pos;
        let padded = size.div_ceil(TAR_BLOCK) * TAR_BLOCK;
        pos += padded;

        // Vlastní jméno: ustar prefix + name.
        let mut name = field_string(&header[0..100]);
        let prefix = field_string(&header[345..500]);
        if !prefix.is_empty() {
            name = format!("{}/{}", prefix, name);
        }

        match typeflag {
            b'L' => {
                // GNU longname: data blok obsahuje jméno následující položky.
                let mut buffer = vec![0u8; size as usize];
                read_up_to(source, &mut buffer)?;
                let end = buffer.iter().position(|&byte| byte == 0).unwrap_or(buffer.len());
                pending_name = Some(String::from_utf8_lossy(&buffer[..end]).to_string());
            }
            b'x' | b'X' => {
                // PAX rozšířené hlavičky: záznamy „len key=value\\n".
                let mut buffer = vec![0u8; size as usize];
                read_up_to(source, &mut buffer)?;
                parse_pax_records(&buffer, &mut pax_path, &mut pax_size, &mut pax_mtime);
            }
            b'5' => {
                // Adresář (velikost dat bývá 0, skip je bezpečný).
                let dir_name = pax_path.clone().or(pending_name.take()).unwrap_or(name);
                entries.push(TarIndexEntry {
                    name: normalize_inner_name(&dir_name),
                    size: 0,
                    mtime: pax_mtime.unwrap_or(mtime),
                    kind: VfsItemKind::Dir,
                    data_offset,
                });
                source.skip(padded)?;
                reset_pax(&mut pax_path, &mut pax_size, &mut pax_mtime);
            }
            b'1' | b'2' => {
                // Hardlink / symlink – uvádíme jako odkaz (bez dat).
                let link_name = pax_path.clone().or(pending_name.take()).unwrap_or(name);
                entries.push(TarIndexEntry {
                    name: normalize_inner_name(&link_name),
                    size: 0,
                    mtime: pax_mtime.unwrap_or(mtime),
                    kind: VfsItemKind::Link,
                    data_offset,
                });
                source.skip(padded)?;
                reset_pax(&mut pax_path, &mut pax_size, &mut pax_mtime);
            }
            b'0' | 0 | b'7' => {
                // Běžný soubor (starý formát má NUL místo '0').
                let file_name = pax_path
                    .clone()
                    .or(pending_name.take())
                    .unwrap_or(name);
                entries.push(TarIndexEntry {
                    name: normalize_inner_name(&file_name),
                    size: pax_size.unwrap_or(size),
                    mtime: pax_mtime.unwrap_or(mtime),
                    kind: VfsItemKind::File,
                    data_offset,
                });
                source.skip(padded)?;
                reset_pax(&mut pax_path, &mut pax_size, &mut pax_mtime);
            }
            _ => {
                // Ostatní typy (zařízení, FIFO…) přeskočíme bez evidence.
                source.skip(padded)?;
                reset_pax(&mut pax_path, &mut pax_size, &mut pax_mtime);
                pending_name = None;
            }
        }
    }
    Ok(entries)
}

/// Vyčistí použité PAX přepsání po zpracování položky.
fn reset_pax(pax_path: &mut Option<String>, pax_size: &mut Option<u64>, pax_mtime: &mut Option<i64>) {
    *pax_path = None;
    *pax_size = None;
    *pax_mtime = None;
}

/// Zpracuje PAX záznamy; zajímají nás klíče path, size a mtime.
fn parse_pax_records(
    data: &[u8],
    pax_path: &mut Option<String>,
    pax_size: &mut Option<u64>,
    pax_mtime: &mut Option<i64>,
) {
    let mut offset = 0usize;
    while offset < data.len() {
        // Délka záznamu je na začátku do mezery (včetně mezery a \\n).
        let Some(space) = data[offset..].iter().position(|&byte| byte == b' ') else {
            break;
        };
        let length_str = String::from_utf8_lossy(&data[offset..offset + space]);
        let Ok(record_len) = length_str.trim().parse::<usize>() else {
            break;
        };
        if record_len == 0 || offset + record_len > data.len() {
            break;
        }
        let record = String::from_utf8_lossy(&data[offset + space + 1..offset + record_len]);
        let record = record.trim_end_matches('\n');
        if let Some((key, value)) = record.split_once('=') {
            match key {
                "path" => *pax_path = Some(value.to_string()),
                "size" => {
                    if let Ok(size) = value.parse::<u64>() {
                        *pax_size = Some(size);
                    }
                }
                "mtime" => {
                    if let Ok(seconds) = value.parse::<f64>() {
                        *pax_mtime = Some(seconds as i64);
                    }
                }
                _ => {}
            }
        }
        offset += record_len;
    }
}

/// Upraví jméno z archivu do kanonického tvaru (bez ./ a lomítek na konci).
fn normalize_inner_name(name: &str) -> String {
    let mut name = name.trim_start_matches("./").replace('\\', "/");
    while name.starts_with('/') {
        name.remove(0);
    }
    while name.ends_with('/') {
        name.pop();
    }
    name
}

/// Sdílený dekompresní kurzor pro čtení z .tar.gz – umožňuje pokračovat
/// v dekompresi od poslední pozice, takže rozbalení celého archivu
/// proběhne jedním průchodem gzip streamu.
struct GzCursor {
    decoder: GzDecoder<File>,
    /// Pozice v dekomprimovaném TAR streamu.
    pos: u64,
}

impl GzCursor {
    /// Otevře nový kurzor od začátku archivu.
    fn new(archive_path: &Path) -> io::Result<GzCursor> {
        let file = File::open(archive_path)?;
        Ok(GzCursor {
            decoder: GzDecoder::new(file),
            pos: 0,
        })
    }

    /// Přečte bajty od aktuální pozice; aktualizuje pozici kurzoru.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = read_up_to(&mut self.decoder, buf)?;
        self.pos += read as u64;
        Ok(read)
    }

    /// Zahodí `bytes` bajtů od aktuální pozice.
    fn skip(&mut self, mut bytes: u64) -> io::Result<()> {
        let mut sink = [0u8; 64 * 1024];
        while bytes > 0 {
            let want = std::cmp::min(bytes, sink.len() as u64) as usize;
            let read = read_up_to(&mut self.decoder, &mut sink[..want])?;
            if read == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Archiv skončil dříve, než očekával scanner.",
                ));
            }
            bytes -= read as u64;
            self.pos += read as u64;
        }
        Ok(())
    }
}

/// Stav sdílené session: kurzor je buď „zapůjčený" streamu, nebo volný.
#[derive(Default)]
struct GzSession {
    available: Option<GzCursor>,
}

/// VFS nad TAR / TAR.GZ archivem.
pub struct TarFs {
    archive_path: PathBuf,
    format: TarFormat,
    /// Index položek sestavený při otevření (jméno → metadata).
    index: BTreeMap<String, TarIndexEntry>,
    /// Session pro sdílenou dekompresi (pouze .tar.gz).
    gz_session: Option<Arc<Mutex<GzSession>>>,
}

impl TarFs {
    /// Je `parent/name` implikovaný adresář (nějaká položka leží pod ním)?
    /// Index je setříděný (BTreeMap), stačí první klíč od prefixu – O(log n).
    fn has_implied_dir(&self, parent: &str, name: &str) -> bool {
        let target = format!("{}{}/", crate::zipfs::inner_prefix_of(parent), name);
        self.index
            .range(target.clone()..)
            .next()
            .is_some_and(|(key, _)| key.starts_with(&target))
    }

    /// Otevře archiv, detekuje formát a sestaví index položek.
    pub fn open(archive_path: &Path) -> SalResult<TarFs> {
        let format = probe_tar_format(archive_path)?
            .ok_or_else(|| SalError::Io("Soubor není čitelný TAR archiv.".to_string()))?;

        let (index, gz_session) = match format {
            TarFormat::Plain => {
                // Plain TAR: seekovatelný průchod jen po hlavičkách.
                let file = File::open(archive_path)?;
                let mut source = SeekSource { reader: file, pos: 0 };
                let entries = scan_tar(&mut source).map_err(SalError::from)?;
                (build_index(entries), None)
            }
            TarFormat::Gzip => {
                // TAR.GZ: jediný sekvenční průchod dekompresí.
                let mut cursor = GzCursor::new(archive_path)?;
                let mut source = SeqSource {
                    reader: &mut cursor.decoder,
                    pos: 0,
                };
                let entries = scan_tar(&mut source).map_err(SalError::from)?;
                // Po scanu je dekodér na konci archivu – pozici musíme
                // přenést do kurzoru, jinak by session myslela, že je na začátku.
                cursor.pos = source.pos;
                let session = Arc::new(Mutex::new(GzSession {
                    available: Some(cursor),
                }));
                (build_index(entries), Some(session))
            }
        };

        Ok(TarFs {
            archive_path: archive_path.to_path_buf(),
            format,
            index,
            gz_session,
        })
    }

    /// Najde položku indexu podle VFS cesty.
    fn find_entry(&self, path: &str) -> Option<&TarIndexEntry> {
        let inner = normalize_vfs_path(path).trim_start_matches('/').to_string();
        self.index.get(&inner)
    }

    /// Otevře čtecí stream pro plain TAR (seek na data položky).
    fn open_read_plain(&self, entry: &TarIndexEntry) -> SalResult<Box<dyn VfsReadStream>> {
        let mut file = File::open(&self.archive_path)?;
        file.seek(SeekFrom::Start(entry.data_offset))?;
        Ok(Box::new(TarPlainReadStream {
            file,
            remaining: entry.size,
        }))
    }

    /// Otevře čtecí stream pro TAR.GZ s využitím sdílené session.
    /// Pokud je požadovaná položka „před" aktuální pozicí kurzoru,
    /// otevře se kurzor nový od začátku (vzácný případ zpětného čtení).
    fn open_read_gzip(&self, entry: &TarIndexEntry) -> SalResult<Box<dyn VfsReadStream>> {
        let session = self.gz_session.as_ref().unwrap().clone();
        let mut guard = session.lock().map_err(|_| {
            SalError::Io("Uzamčená dekompresní session archivu.".to_string())
        })?;

        let mut cursor = match guard.available.take() {
            Some(cursor) if cursor.pos <= entry.data_offset => cursor,
            Some(cursor) => {
                // Pozice je za požadovanou položkou – restart od začátku.
                drop(cursor);
                GzCursor::new(&self.archive_path)?
            }
            None => {
                // Kurzor je zapůjčen jinému streamu – otevřeme nezávislý.
                GzCursor::new(&self.archive_path)?
            }
        };
        // Guard (borrow session) musí být uvolněn před přesunem Arcu
        // do streamu – jinak E0505 (MutexGuard má Drop).
        drop(guard);

        // Dosažení začátku dat požadované položky.
        let to_skip = entry.data_offset - cursor.pos;
        cursor.skip(to_skip)?;

        Ok(Box::new(TarGzReadStream {
            cursor: Some(cursor),
            remaining: entry.size,
            session: Some(session),
        }))
    }
}

/// Převede seznam položek na index; adresáře zapisované explicitně
/// se ukládají zvlášť, soubory implikují své rodiče při výpisu.
fn build_index(entries: Vec<TarIndexEntry>) -> BTreeMap<String, TarIndexEntry> {
    let mut index = BTreeMap::new();
    for entry in entries {
        // Poslední výhra vyhrává – u duplicit bereme novější záznam.
        index.insert(entry.name.clone(), entry);
    }
    index
}

/// Čtecí stream pro plain TAR – seek na data, omezená délka.
struct TarPlainReadStream {
    file: File,
    remaining: u64,
}

impl Read for TarPlainReadStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.remaining == 0 {
            return Ok(0);
        }
        let want = std::cmp::min(buf.len() as u64, self.remaining) as usize;
        let read = self.file.read(&mut buf[..want])?;
        self.remaining -= read as u64;
        Ok(read)
    }
}
impl VfsReadStream for TarPlainReadStream {}

/// Čtecí stream pro TAR.GZ – drží kurzor a po dokončení jej vrací
/// do sdílené session, aby mohl pokračovat dalším souborem.
struct TarGzReadStream {
    cursor: Option<GzCursor>,
    remaining: u64,
    session: Option<Arc<Mutex<GzSession>>>,
}

impl TarGzReadStream {
    /// Vrátí kurzor zpět do session (pokud ještě nebyl vrácen).
    fn release_cursor(&mut self) {
        if let (Some(cursor), Some(session)) = (self.cursor.take(), self.session.take()) {
            if let Ok(mut guard) = session.lock() {
                // Session si drží nanejvýš jeden volný kurzor.
                guard.available = Some(cursor);
            }
        }
    }
}

impl Read for TarGzReadStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(cursor) = self.cursor.as_mut() else {
            return Ok(0);
        };
        if self.remaining == 0 {
            // Data vyčerpána – kurzor vracíme do session pro další použití.
            self.release_cursor();
            return Ok(0);
        }
        let want = std::cmp::min(buf.len() as u64, self.remaining) as usize;
        let read = cursor.read(&mut buf[..want])?;
        self.remaining -= read as u64;
        if self.remaining == 0 {
            self.release_cursor();
        }
        Ok(read)
    }
}

impl Drop for TarGzReadStream {
    fn drop(&mut self) {
        // Předčasné ukončení čtení – kurzor přesto vracíme (pos se drží za daty).
        self.release_cursor();
    }
}
impl VfsReadStream for TarGzReadStream {}

// Zápis do archivu v této verzi nepodporujeme – konstantní chybová zpráva.
const READONLY_MSG: &str = "Do otevřeného TAR archivu nelze zapisovat (jen pro čtení).";

impl Vfs for TarFs {
    fn kind(&self) -> VfsKind {
        // Vnějšku nezajímá komprese – hlásíme TAR jako takový.
        VfsKind::Tar
    }

    fn label(&self) -> String {
        self.archive_path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| self.archive_path.to_string_lossy().to_string())
    }

    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        let prefix = crate::zipfs::inner_prefix_of(path);
        // Potomci: přímé děti z indexu + adresáře implikované cestami.
        let mut items: BTreeMap<String, VfsItem> = BTreeMap::new();
        for (name, entry) in &self.index {
            let Some(rest) = name.strip_prefix(&prefix) else {
                continue;
            };
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
                    items.insert(
                        rest.to_string(),
                        VfsItem {
                            name: rest.to_string(),
                            size: entry.size,
                            mtime: entry.mtime,
                            kind: entry.kind,
                            hidden: rest.starts_with('.'),
                            readonly: true,
                            encrypted: false,
                        },
                    );
                }
            }
        }
        Ok(items.into_values().collect())
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        let entry = self
            .find_entry(path)
            .ok_or_else(|| SalError::NotFound)?;
        match self.format {
            TarFormat::Plain => self.open_read_plain(entry),
            TarFormat::Gzip => self.open_read_gzip(entry),
        }
    }

    fn open_write(&self, _path: &str, _size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
        Err(SalError::Io(READONLY_MSG.to_string()))
    }

    fn mkdir(&self, _path: &str) -> SalResult<()> {
        Err(SalError::Io(READONLY_MSG.to_string()))
    }

    fn delete(&self, _path: &str, _recursive: bool) -> SalResult<()> {
        Err(SalError::Io(READONLY_MSG.to_string()))
    }

    fn rename(&self, _path: &str, _new_name: &str) -> SalResult<()> {
        Err(SalError::Io(READONLY_MSG.to_string()))
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = crate::vfs::split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        // Existuje přímo, nebo jako implikovaný rodič nějaké položky.
        if self.find_entry(path).is_some() {
            return Ok(true);
        }
        Ok(self.has_implied_dir(&parent, &name))
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = crate::vfs::split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let direct = self
            .find_entry(path)
            .map(|entry| entry.kind == VfsItemKind::Dir)
            .unwrap_or(false);
        // Adresář může být i implikovaný (bez vlastního záznamu v archivu).
        Ok(direct || self.has_implied_dir(&parent, &name))
    }

    fn writable(&self) -> bool {
        false
    }

    fn supports_size_scan(&self) -> bool {
        // Velikosti máme v indexu – scan je levný.
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    /// Vytvoří testovací archivy: test.tar a test.tar.gz (a.txt, pod/b.txt).
    fn prepare(tag: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!("salcore-tar-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).unwrap();
        let tar_path = base.join("test.tar");
        let gz_path = base.join("test.tar.gz");

        let file = File::create(&tar_path).unwrap();
        let mut builder = tar::Builder::new(file);
        let mut header = tar::Header::new_gnu();
        header.set_size(7);
        header.set_mode(0o644);
        header.set_mtime(1_700_000_000);
        header.set_cksum();
        builder.append_data(&mut header, "a.txt", b"obsah a".as_slice()).unwrap();
        header.set_size(7);
        header.set_cksum();
        builder.append_data(&mut header, "pod/b.txt", b"obsah b".as_slice()).unwrap();
        builder.finish().unwrap();

        // Gzip variantu vytvoříme komprimací hotového taru.
        let tar_bytes = fs::read(&tar_path).unwrap();
        let gz_file = File::create(&gz_path).unwrap();
        let mut encoder = flate2::write::GzEncoder::new(gz_file, flate2::Compression::default());
        encoder.write_all(&tar_bytes).unwrap();
        encoder.finish().unwrap();
        base
    }

    /// Ověří výpis a čtení pro daný formát archivu.
    fn check_list_and_read(vfs: &TarFs) {
        let items = vfs.list("/").unwrap();
        let names: Vec<&str> = items.iter().map(|item| item.name.as_str()).collect();
        assert!(names.contains(&"a.txt"));
        assert!(names.contains(&"pod"));

        let sub = vfs.list("/pod").unwrap();
        assert_eq!(sub.len(), 1);
        assert_eq!(sub[0].name, "b.txt");
        assert_eq!(sub[0].size, 7);

        let mut reader = vfs.open_read("/pod/b.txt").unwrap();
        let mut content = String::new();
        reader.read_to_string(&mut content).unwrap();
        assert_eq!(content, "obsah b");

        assert!(vfs.exists("/a.txt").unwrap());
        assert!(vfs.is_dir("/pod").unwrap());
        assert!(!vfs.is_dir("/a.txt").unwrap());
        assert!(!vfs.writable());
    }

    #[test]
    fn test_tar_plain() {
        let base = prepare("plain");
        let vfs = TarFs::open(&base.join("test.tar")).unwrap();
        check_list_and_read(&vfs);
        fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn test_tar_gzip() {
        let base = prepare("gzip");
        let vfs = TarFs::open(&base.join("test.tar.gz")).unwrap();
        check_list_and_read(&vfs);

        // Sekvenční čtení více souborů má pokračovat ve sdíleném kurzoru.
        let mut first = vfs.open_read("/a.txt").unwrap();
        let mut content = String::new();
        first.read_to_string(&mut content).unwrap();
        drop(first);
        let mut second = vfs.open_read("/pod/b.txt").unwrap();
        let mut content = String::new();
        second.read_to_string(&mut content).unwrap();
        assert_eq!(content, "obsah b");

        // Zpětné čtení (a.txt je v archivu dřív) musí fungovat přes restart.
        let mut again = vfs.open_read("/a.txt").unwrap();
        let mut content = String::new();
        again.read_to_string(&mut content).unwrap();
        assert_eq!(content, "obsah a");

        fs::remove_dir_all(&base).unwrap();
    }

    /// Kopírování celého obsahu tar.gz do lokálního adresáře
    /// (hlavní scénář „rozbalit archiv") – musí projít bez chyb.
    #[test]
    fn test_tar_gzip_copy_all() {
        use crate::local::LocalFs;
        use crate::ops::{copy_items, NoProgress, OverwriteMode};
        let base = prepare("copyall");
        let src = TarFs::open(&base.join("test.tar.gz")).unwrap();
        let out_dir = base.join("out");
        fs::create_dir_all(&out_dir).unwrap();
        let dst = LocalFs::new(out_dir.to_str()).unwrap();
        let items = src.list("/").unwrap();
        let names: Vec<&str> = items.iter().map(|item| item.name.as_str()).collect();
        let stats = copy_items(&src, "/", &names, &dst, "/", OverwriteMode::Ask, &mut NoProgress).unwrap();
        assert_eq!(stats.files, 2);
        assert_eq!(fs::read_to_string(base.join("out/pod/b.txt")).unwrap(), "obsah b");
        fs::remove_dir_all(&base).unwrap();
    }
}
