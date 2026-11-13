// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! FTP jako virtuální souborový systém.
//!
//! Používá synchronní klient suppaftp (pasivní mód, binární přenos).
//! Příkazová connection je sdílená přes `Arc<Mutex<…>>` – operace nad
//! jedním spojením se serializují (jako v původním Salamanderu).
//!
//! Kořen VFS (`/`) odpovídá domovskému adresáři po přihlášení (PWD),
//! cesty se překládají na absolutní serverové cesty tímto prefixem.
//!
//! Streamy: čtení přes RETR (data stream + finalizace odpovědi při
//! dokončení, ABORT při přerušení), zápis přes STOR.

use std::io::{self, Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use suppaftp::list::File as FtpListEntry;
use suppaftp::types::FileType;
use suppaftp::FtpError;
use suppaftp::FtpStream;

use crate::error::{SalError, SalResult};
use crate::vfs::{
    join_path, remote_path, split_path, system_time_to_unix, Vfs, VfsItem, VfsItemKind, VfsKind,
    VfsReadStream, VfsWriteStream,
};

/// VFS nad jedním FTP spojením.
pub struct FtpFs {
    /// Sdílené příkazové spojení; data streamy si půjčují přes Arc.
    stream: Arc<Mutex<FtpStream>>,
    /// Domovský adresář na serveru (prefix pro překlad VFS cest).
    home: String,
    /// Popis pro titulek panelu.
    label: String,
    /// Identita účtu na serveru (`ftp://uživatel@server:port`) – stejná pro
    /// všechna připojení téhož účtu.
    account: String,
}

/// Převede chybu suppaftp na SalError (text zprávy serveru zachová).
fn ftp_error(error: FtpError) -> SalError {
    SalError::Io(error.to_string())
}

/// Očistí jméno položky z LIST výpisu od symlinkového cíle („jméno -> cíl“).
fn clean_list_name(name: &str) -> &str {
    match name.find(" -> ") {
        Some(idx) => &name[..idx],
        None => name,
    }
}

impl FtpFs {
    /// Připojí se k FTP serveru a přihlásí uživatele.
    /// Kořen VFS je domovský adresář účtu (zjistíme přes PWD).
    pub fn connect(
        host: &str,
        port: u16,
        username: &str,
        password: &str,
        timeout: Duration,
    ) -> SalResult<FtpFs> {
        // Resolvnutí adresy a připojení s timeoutem (první fungující adresa).
        use std::net::ToSocketAddrs;
        let addresses = (host, port)
            .to_socket_addrs()
            .map_err(|err| SalError::Io(format!("Nepodařilo se přeložit adresu {}: {}", host, err)))?;
        let mut last_error = SalError::Io(format!("Server {}:{} nenalezen.", host, port));
        let mut stream = None;
        for address in addresses {
            match FtpStream::connect_timeout(address, timeout) {
                Ok(connected) => {
                    stream = Some(connected);
                    break;
                }
                Err(err) => {
                    last_error = ftp_error(err);
                }
            }
        }
        let mut stream = stream.ok_or(last_error)?;

        // Nejdřív přihlášení: před ním servery jiné příkazy odmítají (530).
        stream.login(username, password).map_err(ftp_error)?;
        // Binární přenos je pro soubory povinnost (ASCII by rozbil binární data).
        stream
            .transfer_type(FileType::Image)
            .map_err(ftp_error)?;

        // Domovský adresář = kořen našeho VFS.
        let home = stream.pwd().map_err(ftp_error)?;
        let home = home.trim_end_matches('/').to_string();

        Ok(FtpFs {
            stream: Arc::new(Mutex::new(stream)),
            home,
            label: format!("FTP: {}:{}", host, port),
            account: format!("ftp://{}@{}:{}", username, host, port),
        })
    }

    /// Převede cestu VFS na absolutní cestu na serveru.
    fn server_path(&self, vfs_path: &str) -> String {
        remote_path(&self.home, vfs_path)
    }

    /// Uzamkne spojení (společné místo pro chybu otráveného zámku).
    fn lock(&self) -> SalResult<std::sync::MutexGuard<'_, FtpStream>> {
        self.stream.lock().map_err(|_| {
            SalError::Io("FTP spojení je nedostupné (uzamčené).".to_string())
        })
    }
}

/// Čtecí stream z FTP (RETR).
///
/// Drží datový stream a sdílené příkazové spojení. Po přečtení celého
/// souboru (EOF) nebo při dropu dojde k finalizaci – přečte se závěrečná
/// odpověď serveru; při přerušení se pošle ABOR, aby spojení zůstalo
/// použitelné.
pub struct FtpReadStream {
    // Konkrétní typ DataStream<NoTlsStream> nelze pojmenovat (privátní modul
    // suppaftp::sync_ftp) – ukládáme typově smazaný stream. DataStream je Send.
    data: Option<Box<dyn Read + Send>>,
    cmd: Arc<Mutex<FtpStream>>,
    /// Příznak kompletně přečteného souboru (EOF).
    done: bool,
}

impl Read for FtpReadStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(data) = self.data.as_mut() else {
            return Ok(0);
        };
        let read = data.read(buf)?;
        if read == 0 {
            // Konec souboru – finalizujeme hned, ať je spojení volné.
            self.done = true;
            self.finalize();
        }
        Ok(read)
    }
}

impl FtpReadStream {
    /// Finalizace přenosu: přečte závěrečnou odpověď a uvolní data stream.
    /// Při nekompletním čtení pošle ABOR (server ukončí přenos).
    fn finalize(&mut self) {
        if let Some(data) = self.data.take() {
            if let Ok(mut guard) = self.cmd.lock() {
                if self.done {
                    // Dokončený přenos – standardní finalizace.
                    let _ = guard.finalize_retr_stream(data);
                } else {
                    // Přerušený přenos – abort, aby spojení zůstalo živé.
                    let _ = guard.abort(data);
                }
            }
        }
    }
}

impl Drop for FtpReadStream {
    fn drop(&mut self) {
        self.finalize();
    }
}
impl VfsReadStream for FtpReadStream {}

/// Společný trait pro datové streamy, které umí číst i zapisovat
/// (FTP data spojení je oboustranné; abort chce Read, STOR chce Write).
trait ReadWrite: Read + Write {}
impl<T: Read + Write> ReadWrite for T {}

/// Zapisovací stream na FTP (STOR).
///
/// Data se posílají do datového spojení. `finish` spojení uzavře a vrátí
/// závěrečnou odpověď serveru (teprve ta potvrzuje uložení souboru);
/// stream zahozený bez `finish` se uzavře také, po chybě zápisu přes ABOR.
pub struct FtpWriteStream {
    data: Option<Box<dyn ReadWrite + Send>>,
    cmd: Arc<Mutex<FtpStream>>,
    /// Nastane-li chyba zápisu, přenos při dropu přerušíme ABOR.
    failed: bool,
}

impl Write for FtpWriteStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let Some(data) = self.data.as_mut() else {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "Datové spojení už je uzavřené.",
            ));
        };
        match data.write(buf) {
            Ok(written) => Ok(written),
            Err(err) => {
                self.failed = true;
                Err(err)
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        let Some(data) = self.data.as_mut() else {
            return Ok(());
        };
        match data.flush() {
            Ok(()) => Ok(()),
            Err(err) => {
                self.failed = true;
                Err(err)
            }
        }
    }
}

impl FtpWriteStream {
    /// Finalizace uploadu: uzavře datový stream a přečte odpověď serveru
    /// (po chybě zápisu přenos přeruší). Opakované volání už nic nedělá.
    fn finalize(&mut self) -> io::Result<()> {
        let Some(data) = self.data.take() else {
            return Ok(());
        };
        let mut guard = self
            .cmd
            .lock()
            .map_err(|_| io::Error::other("FTP spojení je nedostupné (uzamčené)."))?;
        let result = if self.failed {
            guard.abort(data)
        } else {
            guard.finalize_put_stream(data)
        };
        result.map_err(|err| io::Error::other(err.to_string()))
    }
}

impl Drop for FtpWriteStream {
    fn drop(&mut self) {
        // Bez `finish` (chyba, zrušení) už výsledek nikdo nečeká.
        let _ = self.finalize();
    }
}

impl VfsWriteStream for FtpWriteStream {
    fn finish(&mut self) -> io::Result<()> {
        self.flush()?;
        self.finalize()
    }
}

/// Převede položku z LIST výpisu na VfsItem.
fn list_entry_to_item(entry: &FtpListEntry) -> Option<VfsItem> {
    let name = clean_list_name(entry.name());
    // Vlastní adresáře a rodiče ve výpisu nechceme.
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    let kind = if entry.is_symlink() {
        VfsItemKind::Link
    } else if entry.is_directory() {
        VfsItemKind::Dir
    } else {
        VfsItemKind::File
    };
    Some(VfsItem {
        name: name.to_string(),
        size: entry.size() as u64,
        mtime: system_time_to_unix(entry.modified()),
        kind,
        hidden: name.starts_with('.'),
        readonly: false,
        encrypted: false,
    })
}

impl Vfs for FtpFs {
    fn kind(&self) -> VfsKind {
        VfsKind::Ftp
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        // LIST s absolutní cestou (zámek jen po dobu příkazu).
        let server_path = self.server_path(path);
        let lines = self.lock()?.list(Some(server_path.as_str())).map_err(ftp_error)?;

        let mut items = Vec::new();
        for line in lines {
            // Řádky, které parser nepochopí („total 0“, hlášky), přeskočíme.
            if let Some(item) = FtpListEntry::from_posix_line(&line)
                .ok()
                .and_then(|entry| list_entry_to_item(&entry))
            {
                items.push(item);
            }
        }
        Ok(items)
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        let server_path = self.server_path(path);
        let mut guard = self.lock()?;
        // Otevření datového spojení; odpověď se finalizuje ve streamu.
        let data = guard
            .retr_as_stream(server_path.as_str())
            .map_err(ftp_error)?;
        drop(guard);
        Ok(Box::new(FtpReadStream {
            data: Some(Box::new(data)),
            cmd: self.stream.clone(),
            done: false,
        }))
    }

    fn open_write(&self, path: &str, _size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
        let server_path = self.server_path(path);
        let mut guard = self.lock()?;
        let data = guard
            .put_with_stream(server_path.as_str())
            .map_err(ftp_error)?;
        drop(guard);
        Ok(Box::new(FtpWriteStream {
            data: Some(Box::new(data)),
            cmd: self.stream.clone(),
            failed: false,
        }))
    }

    fn mkdir(&self, path: &str) -> SalResult<()> {
        let mut guard = self.lock()?;
        guard.mkdir(self.server_path(path)).map_err(ftp_error)
    }

    fn delete(&self, path: &str, recursive: bool) -> SalResult<()> {
        // U mazání musíme vědět, co mažeme (DELE vs RMD) – druh dá výpis rodiče.
        self.delete_known(path, self.is_dir(path)?, recursive)
    }

    /// Mazání se známým druhem položky (bez výpisu rodiče kvůli každé položce).
    /// Adresář: při `recursive` nejdřív obsah (FTP RMD maže jen prázdné
    /// adresáře), jinak musí být prázdný.
    fn delete_known(&self, path: &str, is_dir: bool, recursive: bool) -> SalResult<()> {
        if !is_dir {
            // Soubor i odkaz (i odkaz na adresář) se maže příkazem DELE.
            return self.lock()?.rm(self.server_path(path)).map_err(ftp_error);
        }
        let children = self.list(path)?;
        if !recursive && !children.is_empty() {
            return Err(SalError::NotEmpty);
        }
        for child in children {
            self.delete_known(&join_path(path, &child.name), child.kind == VfsItemKind::Dir, true)?;
        }
        self.lock()?.rmdir(self.server_path(path)).map_err(ftp_error)
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
        let mut guard = self.lock()?;
        guard.rename(from, to).map_err(ftp_error)
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let items = self.list(&parent)?;
        Ok(items.iter().any(|item| item.name == name))
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let items = self.list(&parent)?;
        Ok(items
            .iter()
            .any(|item| item.name == name && item.kind == VfsItemKind::Dir))
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
    use std::time::UNIX_EPOCH;
    use super::*;

    /// Přihlášení proti minimálnímu serveru na 127.0.0.1, který se chová jako
    /// skutečné FTP servery: před přihlášením odmítá vše kromě USER/PASS
    /// kódem 530. Ověřuje pořadí příkazů při připojení (USER, PASS, TYPE, PWD)
    /// a domovský adresář jako kořen VFS.
    #[test]
    fn test_connect_logs_in_before_other_commands() {
        use std::io::{BufRead, BufReader};
        use std::net::TcpListener;

        // V prostředí bez povoleného naslouchání na portu se test přeskočí.
        let Ok(listener) = TcpListener::bind("127.0.0.1:0") else {
            return;
        };
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut lines = BufReader::new(socket.try_clone().unwrap()).lines();
            let mut commands: Vec<String> = Vec::new();
            let mut logged_in = false;
            socket.write_all(b"220 test\r\n").unwrap();
            while let Some(Ok(line)) = lines.next() {
                let verb = line.split(' ').next().unwrap_or("").to_uppercase();
                let reply = match verb.as_str() {
                    "USER" => "331 heslo\r\n",
                    "PASS" => {
                        logged_in = true;
                        "230 ok\r\n"
                    }
                    _ if !logged_in => "530 Please login with USER and PASS.\r\n",
                    "TYPE" => "200 ok\r\n",
                    "PWD" => "257 \"/home/tester/\" is current directory\r\n",
                    _ => "502 neumim\r\n",
                };
                commands.push(verb);
                socket.write_all(reply.as_bytes()).unwrap();
            }
            commands
        });

        let fs = FtpFs::connect("127.0.0.1", port, "tester", "heslo", Duration::from_secs(5))
            .expect("připojení k testovacímu FTP serveru");
        assert_eq!(fs.home, "/home/tester");
        assert_eq!(fs.server_path("/"), "/home/tester");
        assert_eq!(fs.server_path("/pod/a.txt"), "/home/tester/pod/a.txt");
        // Identita adresáře je stejná pro každé připojení téhož účtu.
        assert_eq!(fs.dir_identity("/pod"), Some(format!("ftp://tester@127.0.0.1:{}/home/tester/pod", port)));
        // Zavření spojení ukončí vlákno serveru.
        drop(fs);
        assert_eq!(server.join().unwrap(), ["USER", "PASS", "TYPE", "PWD"]);
    }

    #[test]
    fn test_clean_list_name() {
        assert_eq!(clean_list_name("soubor.txt"), "soubor.txt");
        assert_eq!(clean_list_name("link -> /cesta/cil"), "link");
    }

    #[test]
    fn test_system_time_to_unix() {
        assert_eq!(system_time_to_unix(UNIX_EPOCH), 0);
        assert_eq!(
            system_time_to_unix(UNIX_EPOCH + Duration::from_secs(12345)),
            12345
        );
        // Čas před rokem 1970 se hlásí jako neznámý.
        assert_eq!(system_time_to_unix(UNIX_EPOCH - Duration::from_secs(1)), 0);
    }
}
