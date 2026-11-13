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
use crate::vfs::{Vfs, VfsItem, VfsItemKind, VfsKind, VfsReadStream, VfsWriteStream};

/// VFS nad jedním FTP spojením.
pub struct FtpFs {
    /// Sdílené příkazové spojení; data streamy si půjčují přes Arc.
    stream: Arc<Mutex<FtpStream>>,
    /// Domovský adresář na serveru (prefix pro překlad VFS cest).
    home: String,
    /// Popis pro titulek panelu.
    label: String,
}

/// Převede chybu suppaftp na SalError (text zprávy serveru zachová).
fn ftp_error(error: FtpError) -> SalError {
    SalError::Io(error.to_string())
}

use crate::vfs::system_time_to_unix;

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

        // Binární přenos je pro soubory povinnost (ASCII by rozbil binární data).
        stream
            .transfer_type(FileType::Image)
            .map_err(ftp_error)?;
        stream.login(username, password).map_err(ftp_error)?;

        // Domovský adresář = kořen našeho VFS.
        let home = stream.pwd().map_err(ftp_error)?;
        let home = home.trim_end_matches('/').to_string();

        Ok(FtpFs {
            stream: Arc::new(Mutex::new(stream)),
            home,
            label: format!("FTP: {}:{}", host, port),
        })
    }

    /// Převede cestu VFS na absolutní cestu na serveru.
    fn server_path(&self, vfs_path: &str) -> String {
        crate::vfs::remote_path(&self.home, vfs_path)
    }

    /// Uzamkne spojení (helper proti opakování lock bohemi v kódu).
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
/// Data se posílají do datového spojení; při dokončení (drop po flush)
/// se finalizuje odpověď serveru, při chybě abort.
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
    /// Finalizace uploadu: uzavře datový stream a přečte odpověď serveru.
    fn finalize(&mut self) {
        if let Some(data) = self.data.take() {
            if let Ok(mut guard) = self.cmd.lock() {
                if self.failed {
                    let _ = guard.abort(data);
                } else {
                    let _ = guard.finalize_put_stream(data);
                }
            }
        }
    }
}

impl Drop for FtpWriteStream {
    fn drop(&mut self) {
        self.finalize();
    }
}
impl VfsWriteStream for FtpWriteStream {}

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
        let server_path = self.server_path(path);
        let mut guard = self.lock()?;
        // LIST s absolutní cestou; některé servery odmítají prázdný kořen,
        // proto prázdnou cestu měníme na None (= aktuální adresář).
        let listing_target = if server_path.is_empty() {
            None
        } else {
            Some(server_path.as_str())
        };
        let lines = guard.list(listing_target).map_err(ftp_error)?;
        drop(guard);

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
        // U mazání adresáře musíme vědět, co mažeme (DELE vs RMD).
        if self.is_dir(path)? {
            let items = self.list(path)?;
            if !recursive && !items.is_empty() {
                // Neprázdný adresář bez rekurze smazat nelze.
                return Err(SalError::NotEmpty);
            }
            // Rekurzivně: nejdřív obsah (FTP RMD maže jen prázdné adresáře).
            for item in items {
                self.delete(&crate::vfs::join_path(path, &item.name), true)?;
            }
            let mut guard = self.lock()?;
            guard.rmdir(self.server_path(path)).map_err(ftp_error)
        } else {
            let mut guard = self.lock()?;
            guard.rm(self.server_path(path)).map_err(ftp_error)
        }
    }

    fn rename(&self, path: &str, new_name: &str) -> SalResult<()> {
        // RNFR/RNTO s absolutními cestami ve stejném adresáři.
        let (parent, _) = crate::vfs::split_path(path);
        let from = self.server_path(path);
        let to = self.server_path(&crate::vfs::join_path(&parent, new_name));
        let mut guard = self.lock()?;
        guard.rename(from, to).map_err(ftp_error)
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = crate::vfs::split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let items = self.list(&parent)?;
        Ok(items.iter().any(|item| item.name == name))
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        let (parent, name) = crate::vfs::split_path(path);
        if name.is_empty() {
            return Ok(true);
        }
        let items = self.list(&parent)?;
        Ok(items
            .iter()
            .any(|item| item.name == name && item.kind == VfsItemKind::Dir))
    }

    fn free_space(&self, _path: &str) -> SalResult<Option<u64>> {
        // FTP nemá standardní způsob, jak zjistit volné místo.
        Ok(None)
    }

    fn writable(&self) -> bool {
        true
    }

    fn supports_size_scan(&self) -> bool {
        // Rekurzivní scan by znamenal dvojitý výpis všech adresářů
        // přes síť – zbytečně pomalé; progress bez celku.
        false
    }
}

#[cfg(test)]
mod tests {
    use std::time::UNIX_EPOCH;
    use super::*;

    /// Unit testy jen čistých funkcí – živé spojení vyžaduje server,
    /// což v CI není k dispozici. Integrita přenosu se ověřuje
    /// testy ops/find nad lokálním FS a zip/tar VFS.
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
    }
}
