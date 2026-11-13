// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! FTP jako virtuální souborový systém.
//!
//! Používá synchronní klient suppaftp (pasivní mód, binární přenos).
//!
//! **Spojení:** FTP dovoluje na jednom řídicím spojení jen jeden příkaz
//! nebo přenos zároveň. VFS proto drží malý pool přihlášených spojení:
//! každý příkaz i každý přenos (RETR/STOR) si jedno spojení vezme jen pro
//! sebe a po dokončení ho vrátí; když žádné volné není, otevře se další.
//! Panel tak může vypisovat adresář i během běžícího přenosu a kopírování
//! v rámci jednoho serveru (stahování a nahrávání zároveň) funguje.
//! Spojení, které dlouho leželo ladem, se před použitím ověří (NOOP)
//! a mrtvé se nahradí novým – server ho mezitím mohl zavřít.
//!
//! **Výpis:** umí-li server MLSD (RFC 3659), použije se – má přesné časy
//! a vrací i skryté soubory; jinak LIST s parserem unixového výpisu.
//! Test existence a druhu položky je na FTP výpis nadřazeného adresáře,
//! proto se poslední výpis krátce pamatuje (viz `DirCache`).
//!
//! Kořen VFS (`/`) odpovídá domovskému adresáři po přihlášení (PWD),
//! cesty se překládají na absolutní serverové cesty tímto prefixem.

use std::io::{self, Read, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use suppaftp::list::File as FtpListEntry;
use suppaftp::types::FileType;
use suppaftp::FtpError;
use suppaftp::FtpStream;
use suppaftp::Status;

use crate::error::{SalError, SalResult};
use crate::vfs::{
    civil_to_unix, join_path, normalize_vfs_path, remote_path, split_path, system_time_to_unix, Vfs,
    VfsItem, VfsItemKind, VfsKind, VfsReadStream, VfsWriteStream,
};

/// Kolik volných spojení si pool nechává (další se po použití zavřou).
const MAX_IDLE_CONNECTIONS: usize = 2;
/// Spojení nečinné déle se před použitím ověří příkazem NOOP.
const IDLE_CHECK_AFTER: Duration = Duration::from_secs(20);
/// Jak dlouho platí zapamatovaný výpis adresáře pro testy existence.
const DIR_CACHE_TTL: Duration = Duration::from_secs(3);

/// Převede chybu suppaftp na SalError (text zprávy serveru zachová).
fn ftp_error(error: FtpError) -> SalError {
    SalError::Io(error.to_string())
}

/// Zapamatovaný výpis jednoho adresáře pro `exists` / `is_dir`.
///
/// Kopírování do existujícího adresáře testuje existenci každého souboru;
/// bez paměti by to byl jeden LIST téhož adresáře na každý soubor. Výpis
/// platí jen krátce (`DIR_CACHE_TTL`) a vlastní změny (nahrání, mkdir,
/// mazání) se do něj promítají, takže zastarat může jen vůči změnám, které
/// na serveru udělal někdo jiný.
struct DirCache {
    /// Normalizovaná cesta VFS vypsaného adresáře.
    dir: String,
    items: Vec<VfsItem>,
    listed_at: Instant,
}

/// Stav sdílený mezi VFS a jeho streamy: přihlašovací údaje pro další
/// spojení, pool volných spojení a paměť posledního výpisu.
struct FtpShared {
    host: String,
    port: u16,
    username: String,
    password: String,
    timeout: Duration,
    /// Volná přihlášená spojení s časem posledního použití.
    idle: Mutex<Vec<(FtpStream, Instant)>>,
    dir_cache: Mutex<Option<DirCache>>,
}

impl FtpShared {
    /// Otevře nové spojení: připojení s timeoutem (první fungující adresa),
    /// přihlášení a binární režim přenosu.
    fn connect(&self) -> SalResult<FtpStream> {
        use std::net::ToSocketAddrs;
        let addresses = (self.host.as_str(), self.port)
            .to_socket_addrs()
            .map_err(|err| SalError::Io(format!("Nepodařilo se přeložit adresu {}: {}", self.host, err)))?;
        let mut last_error = SalError::Io(format!("Server {}:{} nenalezen.", self.host, self.port));
        let mut stream = None;
        for address in addresses {
            match FtpStream::connect_timeout(address, self.timeout) {
                Ok(connected) => {
                    stream = Some(connected);
                    break;
                }
                Err(err) => last_error = ftp_error(err),
            }
        }
        let mut stream = stream.ok_or(last_error)?;
        // Nejdřív přihlášení: před ním servery jiné příkazy odmítají (530).
        stream.login(self.username.as_str(), self.password.as_str()).map_err(ftp_error)?;
        // Binární přenos je pro soubory povinnost (ASCII by rozbil binární data).
        stream.transfer_type(FileType::Image).map_err(ftp_error)?;
        Ok(stream)
    }

    /// Vezme z poolu spojení jen pro volajícího; když žádné použitelné není,
    /// otevře nové.
    fn take(&self) -> SalResult<FtpStream> {
        loop {
            let candidate = self.idle.lock().ok().and_then(|mut idle| idle.pop());
            let Some((mut stream, last_used)) = candidate else {
                return self.connect();
            };
            // Čerstvě použité spojení bereme rovnou; dlouho nečinné mohl
            // server zavřít – ověříme ho a mrtvé zahodíme.
            if last_used.elapsed() < IDLE_CHECK_AFTER || stream.noop().is_ok() {
                return Ok(stream);
            }
        }
    }

    /// Vrátí použitelné spojení do poolu (nadbytečné zdvořile ukončí).
    fn give(&self, mut stream: FtpStream) {
        if let Ok(mut idle) = self.idle.lock() {
            if idle.len() < MAX_IDLE_CONNECTIONS {
                idle.push((stream, Instant::now()));
                return;
            }
        }
        let _ = stream.quit();
    }

    /// Provede příkaz na vlastním spojení z poolu a spojení vrátí volajícímu
    /// spolu s výsledkem (přenos si ho nechá do konce). Po chybě se o spojení
    /// postará sama: zamítavá odpověď serveru ho nechává použitelné (vrátí se
    /// do poolu), po chybě spojení, nesrozumitelné odpovědi nebo ohlášeném
    /// ukončení služby (421) se zahodí.
    fn start<T>(&self, command: impl FnOnce(&mut FtpStream) -> Result<T, FtpError>) -> SalResult<(FtpStream, T)> {
        let mut stream = self.take()?;
        match command(&mut stream) {
            Ok(value) => Ok((stream, value)),
            Err(err) => {
                if matches!(&err, FtpError::UnexpectedResponse(response) if response.status != Status::NotAvailable) {
                    self.give(stream);
                }
                Err(ftp_error(err))
            }
        }
    }

    /// Provede jeden příkaz na vlastním spojení z poolu.
    fn run<T>(&self, command: impl FnOnce(&mut FtpStream) -> Result<T, FtpError>) -> SalResult<T> {
        let (stream, value) = self.start(command)?;
        self.give(stream);
        Ok(value)
    }

    /// Upraví zapamatovaný výpis po vlastní změně na serveru: `update`
    /// dostane položky adresáře `dir`, pokud je právě zapamatovaný.
    fn update_cache(&self, dir: &str, update: impl FnOnce(&mut Vec<VfsItem>)) {
        if let Ok(mut cache) = self.dir_cache.lock() {
            if let Some(cache) = cache.as_mut().filter(|cache| cache.dir == dir) {
                update(&mut cache.items);
            }
        }
    }

    /// Promítne do zapamatovaného výpisu, že položka `path` na serveru právě
    /// vznikla (`Some(druh)`) nebo zanikla (`None`).
    fn note_change(&self, path: &str, created: Option<VfsItemKind>) {
        let (parent, name) = split_path(path);
        self.update_cache(&parent, |items| {
            items.retain(|item| item.name != name);
            items.extend(created.and_then(|kind| list_item(&name, kind, 0, 0)));
        });
    }

    /// Zahodí zapamatovaný výpis (po změně, kterou do něj nelze promítnout).
    fn clear_cache(&self) {
        if let Ok(mut cache) = self.dir_cache.lock() {
            *cache = None;
        }
    }
}

/// VFS nad FTP účtem na serveru.
pub struct FtpFs {
    shared: Arc<FtpShared>,
    /// Domovský adresář na serveru (prefix pro překlad VFS cest).
    home: String,
    /// Popis pro titulek panelu.
    label: String,
    /// Identita účtu na serveru (`ftp://uživatel@server:port`) – stejná pro
    /// všechna připojení téhož účtu.
    account: String,
    /// Server umí strojově čitelný výpis MLSD (zjištěno příkazem FEAT).
    use_mlsd: bool,
}

impl FtpFs {
    /// Připojí se k FTP serveru a přihlásí uživatele.
    /// Kořen VFS je domovský adresář účtu (zjistíme přes PWD).
    pub fn connect(host: &str, port: u16, username: &str, password: &str, timeout: Duration) -> SalResult<FtpFs> {
        let shared = Arc::new(FtpShared {
            host: host.to_string(),
            port,
            username: username.to_string(),
            password: password.to_string(),
            timeout,
            idle: Mutex::new(Vec::new()),
            dir_cache: Mutex::new(None),
        });
        let mut stream = shared.connect()?;
        // Domovský adresář = kořen našeho VFS.
        let home = stream.pwd().map_err(ftp_error)?;
        let home = home.trim_end_matches('/').to_string();
        // MLSD ohlašuje server v odpovědi na FEAT řádkem „MLST …“ (RFC 3659);
        // server bez FEAT nebo bez MLST se vypisuje příkazem LIST.
        let use_mlsd = stream
            .feat()
            .map(|features| features.keys().any(|name| name.eq_ignore_ascii_case("MLST")))
            .unwrap_or(false);
        shared.give(stream);

        Ok(FtpFs {
            shared,
            home,
            label: format!("FTP: {}:{}", host, port),
            account: format!("ftp://{}@{}:{}", username, host, port),
            use_mlsd,
        })
    }

    /// Převede cestu VFS na absolutní cestu na serveru.
    fn server_path(&self, vfs_path: &str) -> String {
        remote_path(&self.home, vfs_path)
    }

    /// Položka jména `name` v adresáři `parent` (normalizovaná cesta VFS) –
    /// ze zapamatovaného výpisu, je-li čerstvý, jinak z nového (ten se zapamatuje).
    fn find_item(&self, parent: &str, name: &str) -> SalResult<Option<VfsItem>> {
        if let Ok(cache) = self.shared.dir_cache.lock() {
            if let Some(cache) = cache.as_ref() {
                if cache.dir == parent && cache.listed_at.elapsed() < DIR_CACHE_TTL {
                    return Ok(cache.items.iter().find(|item| item.name == name).cloned());
                }
            }
        }
        Ok(self.list(parent)?.into_iter().find(|item| item.name == name))
    }
}

/// Čtecí stream z FTP (RETR) s vlastním spojením z poolu.
///
/// Po přečtení celého souboru se přečte závěrečná odpověď serveru a spojení
/// se vrátí do poolu. Stream zahozený před koncem souboru (zrušení, hledání
/// v obsahu po první shodě) přenos přeruší příkazem ABOR; když se to
/// nepovede, spojení se zavře a pool si příště otevře nové.
pub struct FtpReadStream {
    // Konkrétní typ DataStream<NoTlsStream> nelze pojmenovat (privátní modul
    // suppaftp::sync_ftp) – ukládáme typově smazaný stream. DataStream je Send.
    data: Option<Box<dyn Read + Send>>,
    /// Řídicí spojení přenosu (po dokončení se vrací do poolu).
    control: Option<FtpStream>,
    shared: Arc<FtpShared>,
}

impl Drop for FtpReadStream {
    fn drop(&mut self) {
        // Nedočtený přenos: po úspěšném ABOR je spojení dál použitelné.
        if let (Some(data), Some(mut control)) = (self.data.take(), self.control.take()) {
            if control.abort(data).is_ok() {
                self.shared.give(control);
            }
        }
    }
}

impl Read for FtpReadStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(data) = self.data.as_mut() else {
            return Ok(0);
        };
        let read = data.read(buf)?;
        if read == 0 {
            // Konec souboru: závěrečná odpověď serveru a spojení zpět do poolu.
            if let (Some(data), Some(mut control)) = (self.data.take(), self.control.take()) {
                control
                    .finalize_retr_stream(data)
                    .map_err(|err| io::Error::other(err.to_string()))?;
                self.shared.give(control);
            }
        }
        Ok(read)
    }
}
impl VfsReadStream for FtpReadStream {}

/// Zapisovací stream na FTP (STOR) s vlastním spojením z poolu.
///
/// `finish` uzavře datové spojení a vrátí závěrečnou odpověď serveru
/// (teprve ta potvrzuje uložení souboru). Stream zahozený bez `finish`
/// (zrušení, chyba) řídicí spojení zavře.
pub struct FtpWriteStream {
    data: Option<Box<dyn Write + Send>>,
    /// Řídicí spojení přenosu (po dokončení se vrací do poolu).
    control: Option<FtpStream>,
    shared: Arc<FtpShared>,
}

impl Write for FtpWriteStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self.data.as_mut() {
            Some(data) => data.write(buf),
            None => Err(io::Error::new(io::ErrorKind::NotConnected, "Datové spojení už je uzavřené.")),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self.data.as_mut() {
            Some(data) => data.flush(),
            None => Ok(()),
        }
    }
}

impl VfsWriteStream for FtpWriteStream {
    fn finish(&mut self) -> io::Result<()> {
        self.flush()?;
        if let (Some(data), Some(mut control)) = (self.data.take(), self.control.take()) {
            control
                .finalize_put_stream(data)
                .map_err(|err| io::Error::other(err.to_string()))?;
            self.shared.give(control);
        }
        Ok(())
    }
}

/// Očistí jméno položky z LIST výpisu od symlinkového cíle („jméno -> cíl“).
fn clean_list_name(name: &str) -> &str {
    match name.find(" -> ") {
        Some(idx) => &name[..idx],
        None => name,
    }
}

/// Položka výpisu z jejích údajů; `.` a `..` do výpisu nepatří.
fn list_item(name: &str, kind: VfsItemKind, size: u64, mtime: i64) -> Option<VfsItem> {
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    Some(VfsItem {
        name: name.to_string(),
        size,
        mtime,
        kind,
        hidden: name.starts_with('.'),
        readonly: false,
        encrypted: false,
    })
}

/// Převede řádek unixového LIST výpisu na VfsItem (řádky, které parser
/// nepochopí – „total 0“, hlášky – dají None).
fn parse_list_line(line: &str) -> Option<VfsItem> {
    let entry = FtpListEntry::from_posix_line(line).ok()?;
    let kind = if entry.is_symlink() {
        VfsItemKind::Link
    } else if entry.is_directory() {
        VfsItemKind::Dir
    } else {
        VfsItemKind::File
    };
    list_item(clean_list_name(entry.name()), kind, entry.size() as u64, system_time_to_unix(entry.modified()))
}

/// Převede řádek MLSD („fakt=hodnota;fakt=hodnota; jméno“, RFC 3659) na
/// VfsItem. Záznamy samotného adresáře a jeho rodiče (type=cdir/pdir) dají None.
fn parse_mlsd_line(line: &str) -> Option<VfsItem> {
    // Fakta končí první mezerou; jméno za ní smí obsahovat mezery i středníky.
    let (facts, name) = line.split_once(' ')?;
    let mut kind = VfsItemKind::File;
    let mut size = 0u64;
    let mut mtime = 0i64;
    for fact in facts.split(';') {
        let Some((key, value)) = fact.split_once('=') else {
            continue;
        };
        match key.to_ascii_lowercase().as_str() {
            "type" => {
                let value = value.to_ascii_lowercase();
                kind = match value.as_str() {
                    "cdir" | "pdir" => return None,
                    "dir" => VfsItemKind::Dir,
                    // Odkaz hlásí servery jako „OS.unix=symlink“ / „OS.unix=slink:cíl“.
                    _ if value.starts_with("os.unix=s") || value == "link" => VfsItemKind::Link,
                    _ => VfsItemKind::File,
                };
            }
            "size" => size = value.parse().unwrap_or(0),
            "modify" => mtime = parse_mlsd_time(value).unwrap_or(0),
            _ => {}
        }
    }
    list_item(name, kind, size, mtime)
}

/// Čas faktu `modify` („YYYYMMDDHHMMSS[.sss]“, vždy UTC) jako unixové sekundy.
fn parse_mlsd_time(value: &str) -> Option<i64> {
    // Části pevné délky; zlomky sekund za tečkou se nepoužívají.
    let digits = value.get(..14)?;
    if !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let part = |range: std::ops::Range<usize>| digits[range].parse::<i64>().ok();
    Some(civil_to_unix(part(0..4)?, part(4..6)?, part(6..8)?, part(8..10)?, part(10..12)?, part(12..14)?))
}

impl Vfs for FtpFs {
    fn kind(&self) -> VfsKind {
        VfsKind::Ftp
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        // Výpis s absolutní cestou: MLSD, umí-li ho server, jinak LIST.
        let server_path = self.server_path(path);
        let items: Vec<VfsItem> = if self.use_mlsd {
            let lines = self.shared.run(|stream| stream.mlsd(Some(server_path.as_str())))?;
            lines.iter().filter_map(|line| parse_mlsd_line(line)).collect()
        } else {
            let lines = self.shared.run(|stream| stream.list(Some(server_path.as_str())))?;
            lines.iter().filter_map(|line| parse_list_line(line)).collect()
        };
        // Čerstvý výpis poslouží i následujícím testům existence.
        if let Ok(mut cache) = self.shared.dir_cache.lock() {
            *cache = Some(DirCache {
                dir: normalize_vfs_path(path),
                items: items.clone(),
                listed_at: Instant::now(),
            });
        }
        Ok(items)
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        // Přenos má řídicí spojení jen pro sebe až do konce čtení.
        let server_path = self.server_path(path);
        let (control, data) = self.shared.start(|stream| stream.retr_as_stream(server_path.as_str()))?;
        Ok(Box::new(FtpReadStream {
            data: Some(Box::new(data)),
            control: Some(control),
            shared: self.shared.clone(),
        }))
    }

    fn open_write(&self, path: &str, _size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
        let server_path = self.server_path(path);
        let (control, data) = self.shared.start(|stream| stream.put_with_stream(server_path.as_str()))?;
        // Soubor na serveru vzniká už teď.
        self.shared.note_change(path, Some(VfsItemKind::File));
        Ok(Box::new(FtpWriteStream {
            data: Some(Box::new(data)),
            control: Some(control),
            shared: self.shared.clone(),
        }))
    }

    fn mkdir(&self, path: &str) -> SalResult<()> {
        self.shared.run(|stream| stream.mkdir(self.server_path(path)))?;
        self.shared.note_change(path, Some(VfsItemKind::Dir));
        Ok(())
    }

    fn delete(&self, path: &str, recursive: bool) -> SalResult<()> {
        // U mazání musíme vědět, co mažeme (DELE vs RMD) – druh dá výpis rodiče.
        self.delete_known(path, self.is_dir(path)?, recursive)
    }

    /// Mazání se známým druhem položky (bez výpisu rodiče kvůli každé položce).
    /// Adresář: při `recursive` nejdřív obsah (FTP RMD maže jen prázdné
    /// adresáře), jinak musí být prázdný.
    fn delete_known(&self, path: &str, is_dir: bool, recursive: bool) -> SalResult<()> {
        if is_dir {
            let children = self.list(path)?;
            if !recursive && !children.is_empty() {
                return Err(SalError::NotEmpty);
            }
            for child in children {
                self.delete_known(&join_path(path, &child.name), child.kind == VfsItemKind::Dir, true)?;
            }
            self.shared.run(|stream| stream.rmdir(self.server_path(path)))?;
        } else {
            // Soubor i odkaz (i odkaz na adresář) se maže příkazem DELE.
            self.shared.run(|stream| stream.rm(self.server_path(path)))?;
        }
        self.shared.note_change(path, None);
        Ok(())
    }

    fn rename(&self, path: &str, new_name: &str) -> SalResult<()> {
        // RNFR/RNTO s absolutními cestami ve stejném adresáři.
        let (parent, _) = split_path(path);
        let new_path = join_path(&parent, new_name);
        // RNTO by existující cíl na většině serverů tiše nahradilo.
        if self.exists(&new_path)? {
            return Err(SalError::AlreadyExists);
        }
        let from = self.server_path(path);
        let to = self.server_path(&new_path);
        self.shared.run(|stream| stream.rename(from.as_str(), to.as_str()))?;
        self.shared.clear_cache();
        Ok(())
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        Ok(self.find_item(&parent, &name)?.is_some())
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        Ok(self.find_item(&parent, &name)?.is_some_and(|item| item.kind == VfsItemKind::Dir))
    }

    fn supports_size_scan(&self) -> bool {
        // Rekurzivní scan by znamenal dvojitý výpis všech adresářů
        // přes síť – zbytečně pomalé; progress bez celku.
        false
    }

    fn dir_identity(&self, dir: &str) -> Option<String> {
        Some(format!("{}{}", self.account, self.server_path(dir)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::io::{BufRead, BufReader};
    use std::net::{TcpListener, TcpStream};
    use std::time::UNIX_EPOCH;

    /// Minimální FTP server na 127.0.0.1 pro testy: přihlášení (před ním
    /// odmítá vše kódem 530 jako skutečné servery), pasivní datová spojení,
    /// výpis (MLSD volitelně, LIST), RETR, STOR, DELE, MKD. Soubory drží
    /// v paměti; každé řídicí spojení obsluhuje vlastní vlákno.
    struct TestServer {
        port: u16,
        state: Arc<ServerState>,
    }

    struct ServerState {
        /// Ohlašovat a umět MLSD?
        mlsd: bool,
        /// Soubory v domovském adresáři (jméno → obsah).
        files: Mutex<HashMap<String, Vec<u8>>>,
        /// Přijaté příkazy s číslem řídicího spojení („0 USER“).
        log: Mutex<Vec<String>>,
        /// Počet přijatých řídicích spojení.
        connections: Mutex<usize>,
    }

    impl TestServer {
        /// Spustí server; None v prostředí bez povoleného naslouchání na portu.
        fn start(mlsd: bool, files: &[(&str, &[u8])]) -> Option<TestServer> {
            let listener = TcpListener::bind("127.0.0.1:0").ok()?;
            let port = listener.local_addr().unwrap().port();
            let state = Arc::new(ServerState {
                mlsd,
                files: Mutex::new(files.iter().map(|(name, data)| (name.to_string(), data.to_vec())).collect()),
                log: Mutex::new(Vec::new()),
                connections: Mutex::new(0),
            });
            let accept_state = state.clone();
            std::thread::spawn(move || {
                for socket in listener.incoming().flatten() {
                    let state = accept_state.clone();
                    let id = {
                        let mut connections = state.connections.lock().unwrap();
                        *connections += 1;
                        *connections - 1
                    };
                    std::thread::spawn(move || serve(socket, id, &state));
                }
            });
            Some(TestServer { port, state })
        }

        fn connect(&self) -> FtpFs {
            FtpFs::connect("127.0.0.1", self.port, "tester", "heslo", Duration::from_secs(5))
                .expect("připojení k testovacímu FTP serveru")
        }

        /// Příkazy přijaté od začátku (bez čísla spojení).
        fn commands(&self) -> Vec<String> {
            self.state.log.lock().unwrap().iter().map(|entry| entry.split(' ').nth(1).unwrap().to_string()).collect()
        }

        fn count(&self, verb: &str) -> usize {
            self.commands().iter().filter(|command| command.as_str() == verb).count()
        }
    }

    /// Obsluha jednoho řídicího spojení testovacího serveru.
    fn serve(mut socket: TcpStream, id: usize, state: &ServerState) {
        let mut lines = BufReader::new(socket.try_clone().unwrap()).lines();
        let mut logged_in = false;
        // Naslouchání pro datové spojení otevřené posledním PASV.
        let mut passive: Option<TcpListener> = None;
        let reply = |socket: &mut TcpStream, text: &str| socket.write_all(format!("{}\r\n", text).as_bytes()).is_ok();
        reply(&mut socket, "220 test");
        while let Some(Ok(line)) = lines.next() {
            let (verb, argument) = line.split_once(' ').unwrap_or((line.as_str(), ""));
            let verb = verb.to_uppercase();
            state.log.lock().unwrap().push(format!("{} {}", id, verb));
            // Jméno souboru z absolutní cesty v domovském adresáři.
            let name = argument.rsplit('/').next().unwrap_or("").to_string();
            let ok = match verb.as_str() {
                "USER" => reply(&mut socket, "331 heslo"),
                "PASS" => {
                    logged_in = true;
                    reply(&mut socket, "230 ok")
                }
                _ if !logged_in => reply(&mut socket, "530 Please login with USER and PASS."),
                "TYPE" | "NOOP" => reply(&mut socket, "200 ok"),
                "PWD" => reply(&mut socket, "257 \"/home/tester/\" is current directory"),
                "FEAT" if state.mlsd => reply(&mut socket, "211-Features:\r\n MLST type*;size*;modify*;\r\n211 End"),
                "PASV" => {
                    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
                    let port = listener.local_addr().unwrap().port();
                    passive = Some(listener);
                    reply(&mut socket, &format!("227 Entering Passive Mode (127,0,0,1,{},{})", port / 256, port % 256))
                }
                "MLSD" | "LIST" | "RETR" | "STOR" if verb != "MLSD" || state.mlsd => {
                    let Some(listener) = passive.take() else {
                        break;
                    };
                    // RETR neexistujícího souboru server odmítne bez přenosu.
                    if verb == "RETR" && !state.files.lock().unwrap().contains_key(&name) {
                        reply(&mut socket, "550 No such file");
                        continue;
                    }
                    reply(&mut socket, "150 ok");
                    let (mut data, _) = listener.accept().unwrap();
                    let files = state.files.lock().unwrap().clone();
                    match verb.as_str() {
                        "MLSD" => {
                            let mut listing = "type=cdir;modify=20240101000000; .\r\n".to_string();
                            listing += "type=dir;modify=20240102030405; pod adresar\r\n";
                            listing += "type=OS.unix=symlink;size=4; odkaz\r\n";
                            for (name, content) in &files {
                                listing += &format!("type=file;size={};modify=20240102030405.123; {}\r\n", content.len(), name);
                            }
                            let _ = data.write_all(listing.as_bytes());
                        }
                        "LIST" => {
                            let mut listing = "total 1\r\ndrwxr-xr-x 2 u g 4096 Jan  2  2024 pod\r\n".to_string();
                            for (name, content) in &files {
                                listing += &format!("-rw-r--r-- 1 u g {} Jan  2  2024 {}\r\n", content.len(), name);
                            }
                            let _ = data.write_all(listing.as_bytes());
                        }
                        "RETR" => {
                            let _ = data.write_all(&files[&name]);
                        }
                        _ => {
                            let mut content = Vec::new();
                            let _ = data.read_to_end(&mut content);
                            state.files.lock().unwrap().insert(name, content);
                        }
                    }
                    drop(data);
                    reply(&mut socket, "226 done")
                }
                "DELE" => {
                    let removed = state.files.lock().unwrap().remove(&name).is_some();
                    reply(&mut socket, if removed { "250 ok" } else { "550 No such file" })
                }
                "MKD" => reply(&mut socket, "257 created"),
                "QUIT" => {
                    reply(&mut socket, "221 bye");
                    break;
                }
                _ => reply(&mut socket, "502 neumim"),
            };
            if !ok {
                break;
            }
        }
    }

    /// Přečte celý soubor z VFS.
    fn read_all(fs: &FtpFs, path: &str) -> SalResult<Vec<u8>> {
        let mut content = Vec::new();
        fs.open_read(path)?.read_to_end(&mut content)?;
        Ok(content)
    }

    /// Připojení: přihlášení před ostatními příkazy, domovský adresář jako
    /// kořen VFS, identita adresáře stejná pro každé připojení účtu.
    #[test]
    fn test_connect_logs_in_before_other_commands() {
        let Some(server) = TestServer::start(false, &[]) else {
            return;
        };
        let fs = server.connect();
        assert_eq!(fs.home, "/home/tester");
        assert!(!fs.use_mlsd);
        assert_eq!(fs.server_path("/"), "/home/tester");
        assert_eq!(fs.server_path("/pod/a.txt"), "/home/tester/pod/a.txt");
        assert_eq!(
            fs.dir_identity("/pod"),
            Some(format!("ftp://tester@127.0.0.1:{}/home/tester/pod", server.port))
        );
        assert_eq!(server.commands(), ["USER", "PASS", "TYPE", "PWD", "FEAT"]);
    }

    /// Výpis přes MLSD: skryté soubory, adresář se jménem s mezerou, odkaz,
    /// přesný čas v UTC; záznam samotného adresáře (cdir) ve výpisu není.
    #[test]
    fn test_list_mlsd() {
        let Some(server) = TestServer::start(true, &[(".skryty", b"x"), ("a.txt", b"obsah")]) else {
            return;
        };
        let fs = server.connect();
        assert!(fs.use_mlsd);
        let mut items = fs.list("/").unwrap();
        items.sort_by(|left, right| left.name.cmp(&right.name));
        let summary: Vec<(&str, VfsItemKind, u64)> =
            items.iter().map(|item| (item.name.as_str(), item.kind, item.size)).collect();
        assert_eq!(
            summary,
            [
                (".skryty", VfsItemKind::File, 1),
                ("a.txt", VfsItemKind::File, 5),
                ("odkaz", VfsItemKind::Link, 4),
                ("pod adresar", VfsItemKind::Dir, 0),
            ]
        );
        assert!(items[0].hidden);
        // 2. 1. 2024 03:04:05 UTC.
        assert_eq!(items[1].mtime, 1_704_164_645);
        assert_eq!(server.count("LIST"), 0);
    }

    /// Výpis přes LIST (server bez MLSD) a zapamatovaný výpis: opakované
    /// testy existence v jednom adresáři nestojí další výpis a vlastní změny
    /// (nahrání, smazání) se do něj promítají.
    #[test]
    fn test_list_fallback_and_dir_cache() {
        let Some(server) = TestServer::start(false, &[("a.txt", b"obsah")]) else {
            return;
        };
        let fs = server.connect();
        assert!(fs.exists("/a.txt").unwrap());
        assert!(fs.is_dir("/pod").unwrap());
        assert!(!fs.is_dir("/a.txt").unwrap());
        assert!(!fs.exists("/novy.txt").unwrap());
        assert_eq!(server.count("LIST"), 1);

        let mut writer = fs.open_write("/novy.txt", None).unwrap();
        writer.write_all(b"data").unwrap();
        writer.finish().unwrap();
        drop(writer);
        assert!(fs.exists("/novy.txt").unwrap());
        fs.delete_known("/a.txt", false, false).unwrap();
        assert!(!fs.exists("/a.txt").unwrap());
        assert_eq!(server.count("LIST"), 1);
        assert_eq!(read_all(&fs, "/novy.txt").unwrap(), b"data");
        // Chybějící soubor: server odmítne, spojení zůstává použitelné.
        assert!(read_all(&fs, "/neni.txt").is_err());
        assert_eq!(read_all(&fs, "/novy.txt").unwrap(), b"data");
    }

    /// Během otevřeného přenosu běží další příkazy na jiném spojení – výpis
    /// při stahování i kopie v rámci jednoho serveru (RETR a STOR zároveň).
    #[test]
    fn test_commands_during_transfer_use_another_connection() {
        let Some(server) = TestServer::start(false, &[("a.txt", b"obsah a")]) else {
            return;
        };
        let fs = server.connect();
        let mut reader = fs.open_read("/a.txt").unwrap();
        // Výpis i nahrávání při otevřeném stahování.
        assert_eq!(fs.list("/").unwrap().len(), 2);
        let mut writer = fs.open_write("/kopie.txt", None).unwrap();
        io::copy(&mut reader, &mut writer).unwrap();
        writer.finish().unwrap();
        drop((reader, writer));
        assert_eq!(read_all(&fs, "/kopie.txt").unwrap(), b"obsah a");
        // Stahování drželo první spojení; výpis otevřel druhé, vrátil ho a
        // nahrávání si ho vzalo. Dál se používají vrácená spojení z poolu.
        let connections = *server.state.connections.lock().unwrap();
        assert_eq!(connections, 2);
        assert_eq!(fs.list("/").unwrap().len(), 3);
        assert_eq!(*server.state.connections.lock().unwrap(), connections);
    }

    #[test]
    fn test_parse_listing_lines() {
        assert_eq!(clean_list_name("soubor.txt"), "soubor.txt");
        assert_eq!(clean_list_name("link -> /cesta/cil"), "link");
        let link = parse_list_line("lrwxrwxrwx 1 u g 4 Jan  2  2024 odkaz -> cil").unwrap();
        assert_eq!((link.name.as_str(), link.kind), ("odkaz", VfsItemKind::Link));
        assert!(parse_list_line("total 12").is_none());
        // MLSD: jméno se středníkem a mezerou, neznámá fakta, rodič (pdir).
        let item = parse_mlsd_line("Type=file;Size=7;UNIX.mode=0644; a; b.txt").unwrap();
        assert_eq!((item.name.as_str(), item.size, item.mtime), ("a; b.txt", 7, 0));
        assert!(parse_mlsd_line("type=pdir; ..").is_none());
        assert_eq!(parse_mlsd_time("19700101000001"), Some(1));
        assert_eq!(parse_mlsd_time("2024"), None);
    }

    #[test]
    fn test_system_time_to_unix() {
        assert_eq!(system_time_to_unix(UNIX_EPOCH), 0);
        assert_eq!(system_time_to_unix(UNIX_EPOCH + Duration::from_secs(12345)), 12345);
        // Čas před rokem 1970 se hlásí jako neznámý.
        assert_eq!(system_time_to_unix(UNIX_EPOCH - Duration::from_secs(1)), 0);
    }
}
