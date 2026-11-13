// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

//! SFTP jako virtuální souborový systém (ssh2 / libssh2).
//!
//! Autentizace heslem, souborem se soukromým klíčem (OpenSSH/PEM: ed25519,
//! ECDSA, RSA; volitelně chráněný heslem) nebo klíči ze ssh-agenta.
//! Session i Sftp kanál žijí
//! v jedné backendové struktuře za `Arc<Mutex<…>>`; streamy si drží Arc
//! a zamykají na každé čtení/zápis bloku – libssh2 Session není vláknově
//! bezpečná, proto se veškerý přístup serializuje jediným zámkem.
//!
//! Kořen VFS (`/`) odpovídá domovskému adresáři po přihlášení
//! (realpath „.“), překlad cest je stejný jako u FTP.

use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use ssh2::{File as SshFile, FileStat, OpenFlags, OpenType, Session, Sftp};

use crate::error::{SalError, SalResult};
use crate::vfs::{
    join_path, remote_path, split_path, Vfs, VfsItem, VfsItemKind, VfsKind, VfsReadStream,
    VfsWriteStream,
};

/// Vlastník SSH spojení: session + otevřený SFTP kanál.
struct SftpBackend {
    // Session musí žít stejně dlouho jako Sftp (raw ukazatel do ní ukazuje);
    // pole se čte nepřímo přes libssh2 handle, proto allow(dead_code).
    #[allow(dead_code)]
    session: Session,
    sftp: Sftp,
}

/// VFS nad jedním SFTP spojením.
pub struct SftpFs {
    backend: Arc<Mutex<SftpBackend>>,
    /// Domovský adresář na serveru (prefix pro překlad VFS cest).
    home: String,
    /// Popis pro titulek panelu.
    label: String,
    /// Identita účtu na serveru (`sftp://uživatel@server:port`) – stejná pro
    /// všechna připojení téhož účtu.
    account: String,
}

/// Způsob přihlášení k SSH serveru.
#[derive(Debug, Clone)]
pub enum SftpAuth {
    /// Uživatelské heslo.
    Password(String),
    /// Soubor se soukromým klíčem (veřejný klíč si libssh2 odvodí z něj,
    /// soubor `.pub` není potřeba). Passphrase = heslo ke klíči.
    KeyFile {
        private_key: PathBuf,
        passphrase: Option<String>,
    },
    /// Klíče načtené v ssh-agentovi (SSH_AUTH_SOCK) – zkouší se postupně všechny.
    Agent,
}

/// Rozbalí „~“ na začátku cesty na domovský adresář.
fn expand_home(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    path.to_path_buf()
}

/// Přihlášení soukromým klíčem ze souboru se srozumitelnými chybami.
fn auth_key_file(session: &Session, username: &str, private_key: &Path, passphrase: Option<&str>) -> SalResult<()> {
    let private_key = expand_home(private_key);
    if !private_key.is_file() {
        return Err(SalError::Io(format!("Soubor s klíčem {} neexistuje.", private_key.display())));
    }
    let passphrase = passphrase.filter(|value| !value.is_empty());
    // Klíč chráněný heslem bez zadaného hesla: chyba hned (UI se zeptá na heslo).
    if passphrase.is_none() && key_file_encrypted(&private_key)? {
        return Err(SalError::Io(KEY_PASSPHRASE_REQUIRED.to_string()));
    }
    // Veřejný klíč záměrně nepředáváme – libssh2 ho odvodí ze soukromého, takže
    // klíč (a heslo k němu) se ověří lokálně ještě před dotazem na server
    // a chyba „chybné heslo ke klíči“ se nesplete s „server klíč odmítl“.
    session
        .userauth_pubkey_file(username, None, &private_key, passphrase)
        .map_err(|error| key_auth_error(error, passphrase.is_some()))
}

/// Text chyby „klíč je chráněný heslem“ (UI podle něj nabídne zadání hesla ke klíči).
pub const KEY_PASSPHRASE_REQUIRED: &str = "Klíč je chráněný heslem – zadejte heslo ke klíči.";

/// Je soubor se soukromým klíčem zašifrovaný heslem?
/// OpenSSH formát: šifra v hlavičce „openssh-key-v1“ ≠ „none“;
/// PEM: hlavička „Proc-Type: 4,ENCRYPTED“ nebo „BEGIN ENCRYPTED PRIVATE KEY“.
pub fn key_file_encrypted(path: &Path) -> SalResult<bool> {
    let path = expand_home(path);
    let text = std::fs::read_to_string(&path)
        .map_err(|err| SalError::Io(format!("Soubor s klíčem {} nelze přečíst: {}", path.display(), err)))?;
    if text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.contains("Proc-Type: 4,ENCRYPTED") {
        return Ok(true);
    }
    if text.contains("BEGIN OPENSSH PRIVATE KEY") {
        // Base64 tělo mezi hlavičkami → binární hlavička: magic, pak délka + jméno šifry.
        let body: String = text
            .lines()
            .filter(|line| !line.starts_with("-----"))
            .collect::<Vec<_>>()
            .concat();
        let data = decode_base64(&body);
        let magic = b"openssh-key-v1\0";
        if data.len() > magic.len() + 4 && data.starts_with(magic) {
            let offset = magic.len();
            let length = u32::from_be_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]) as usize;
            let cipher = data.get(offset + 4..offset + 4 + length).unwrap_or(b"");
            return Ok(cipher != b"none");
        }
    }
    Ok(false)
}

/// Minimální dekodér base64 (standardní abeceda) – jen pro hlavičku klíče.
fn decode_base64(text: &str) -> Vec<u8> {
    let mut output = Vec::with_capacity(text.len() * 3 / 4);
    let mut buffer = 0u32;
    let mut bits = 0;
    for byte in text.bytes() {
        // Hodnota znaku v abecedě; „=“ a bílé znaky se přeskočí.
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => continue,
        };
        buffer = (buffer << 6) | value as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            output.push((buffer >> bits) as u8);
        }
    }
    output
}

/// Přihlášení klíči ze ssh-agenta: zkouší všechny identity, dokud server jednu nepřijme.
fn auth_agent(session: &Session, username: &str) -> SalResult<()> {
    let mut agent = session.agent().map_err(ssh_error)?;
    agent.connect().map_err(|_| {
        SalError::Io("Nelze se připojit k ssh-agentovi (není spuštěn nebo chybí SSH_AUTH_SOCK).".to_string())
    })?;
    agent.list_identities().map_err(ssh_error)?;
    let identities = agent.identities().map_err(ssh_error)?;
    if identities.is_empty() {
        return Err(SalError::Io("ssh-agent nemá načtené žádné klíče (přidejte je příkazem ssh-add).".to_string()));
    }
    for identity in &identities {
        if agent.userauth(username, identity).is_ok() {
            return Ok(());
        }
    }
    Err(SalError::Io(format!(
        "Server nepřijal žádný z {} klíčů v ssh-agentovi.",
        identities.len()
    )))
}

/// Chyba přihlášení klíčem → srozumitelná zpráva podle kódu libssh2.
fn key_auth_error(error: ssh2::Error, has_passphrase: bool) -> SalError {
    // Kódy libssh2: -16 FILE (klíč nejde načíst), -18 AUTHENTICATION_FAILED,
    // -19 PUBLICKEY_UNVERIFIED (server klíč odmítl).
    match error.code() {
        ssh2::ErrorCode::Session(-16) => SalError::Io(if has_passphrase {
            "Klíč nelze načíst – chybné heslo ke klíči nebo nepodporovaný formát.".to_string()
        } else {
            "Klíč nelze načíst – je chráněný heslem (zadejte heslo ke klíči) nebo má nepodporovaný formát.".to_string()
        }),
        ssh2::ErrorCode::Session(-18) | ssh2::ErrorCode::Session(-19) => SalError::Io(
            "Server klíč odmítl (veřejný klíč není v ~/.ssh/authorized_keys na serveru?).".to_string(),
        ),
        _ => SalError::Io(format!("Přihlášení klíčem selhalo: {}", error)),
    }
}

/// Přeloží chybu ssh2 na SalError; NotFound rozpoznané z kódu 2 (ENOENT).
fn ssh_error(error: ssh2::Error) -> SalError {
    // libssh2 vrací SFTP kódy v higher bits; 2 = SSH_FX_NO_SUCH_FILE.
    if error.code() == ssh2::ErrorCode::SFTP(2) {
        SalError::NotFound
    } else {
        SalError::Io(error.to_string())
    }
}

impl SftpFs {
    /// Připojí se k SSH serveru, přihlásí heslem a otevře SFTP kanál.
    pub fn connect(
        host: &str,
        port: u16,
        username: &str,
        password: &str,
        timeout: Duration,
    ) -> SalResult<SftpFs> {
        Self::connect_with(host, port, username, &SftpAuth::Password(password.to_string()), timeout)
    }

    /// Připojí se k SSH serveru se zvoleným způsobem přihlášení a otevře SFTP kanál.
    pub fn connect_with(
        host: &str,
        port: u16,
        username: &str,
        auth: &SftpAuth,
        timeout: Duration,
    ) -> SalResult<SftpFs> {
        // TCP spojení s timeoutem (resolv přes std).
        use std::net::ToSocketAddrs;
        let addresses = (host, port)
            .to_socket_addrs()
            .map_err(|err| {
                SalError::Io(format!("Nepodařilo se přeložit adresu {}: {}", host, err))
            })?;
        let mut tcp = None;
        let mut last_error = SalError::Io(format!("Server {}:{} nenalezen.", host, port));
        for address in addresses {
            match TcpStream::connect_timeout(&address, timeout) {
                Ok(stream) => {
                    tcp = Some(stream);
                    break;
                }
                Err(err) => {
                    last_error = SalError::Io(err.to_string());
                }
            }
        }
        let tcp = tcp.ok_or(last_error)?;

        // SSH handshake + autentizace.
        let mut session = Session::new().map_err(ssh_error)?;
        session.set_tcp_stream(tcp);
        // Timeout i pro handshake a přihlášení (jinak by mrtvý server blokoval navždy).
        session.set_timeout(timeout.as_millis().min(u32::MAX as u128) as u32);
        session.handshake().map_err(ssh_error)?;
        match auth {
            SftpAuth::Password(password) => session
                .userauth_password(username, password)
                .map_err(|_| SalError::Io("Přihlášení heslem selhalo (chybné jméno nebo heslo).".to_string()))?,
            SftpAuth::KeyFile { private_key, passphrase } => {
                auth_key_file(&session, username, private_key, passphrase.as_deref())?
            }
            SftpAuth::Agent => auth_agent(&session, username)?,
        }
        if !session.authenticated() {
            return Err(SalError::PermissionDenied);
        }
        // Po přihlášení bez časového limitu (dlouhé přenosy velkých souborů).
        session.set_timeout(0);
        // SFTP kanál (SSH_FXP subsystem).
        let sftp = session.sftp().map_err(ssh_error)?;

        // Domovský adresář = kořen VFS (realpath ".").
        let home = sftp
            .realpath(Path::new("."))
            .map_err(ssh_error)?
            .to_string_lossy()
            .trim_end_matches('/')
            .to_string();

        Ok(SftpFs {
            backend: Arc::new(Mutex::new(SftpBackend { session, sftp })),
            home,
            label: format!("SFTP: {}:{}", host, port),
            account: format!("sftp://{}@{}:{}", username, host, port),
        })
    }

    /// Převede cestu VFS na absolutní cestu na serveru.
    fn server_path(&self, vfs_path: &str) -> String {
        remote_path(&self.home, vfs_path)
    }

    /// Uzamkne backend (všechny operace nad Session musí běžet pod zámkem).
    fn lock(&self) -> SalResult<MutexGuard<'_, SftpBackend>> {
        self.backend.lock().map_err(|_| {
            SalError::Io("SFTP spojení je nedostupné (uzamčené).".to_string())
        })
    }
}

/// Převede metadata ze serveru na VfsItem (jméno zvlášť – readdir ho
/// vrací jako PathBuf).
fn stat_to_item(name: &str, stat: &FileStat) -> Option<VfsItem> {
    if name.is_empty() || name == "." || name == ".." {
        return None;
    }
    // Druh položky podle Permission bits (S_IFMT maska).
    let mode = stat.perm.unwrap_or(0o100644);
    let kind = match mode & 0o170000 {
        0o040000 => VfsItemKind::Dir,
        0o120000 => VfsItemKind::Link,
        _ => VfsItemKind::File,
    };
    Some(VfsItem {
        name: name.to_string(),
        size: stat.size.unwrap_or(0),
        mtime: stat.mtime.unwrap_or(0) as i64,
        kind,
        hidden: name.starts_with('.'),
        // Jen pro čtení = právo zápisu nemá vlastník, skupina ani ostatní.
        readonly: mode & 0o222 == 0,
        encrypted: false,
    })
}

/// Zámek backendu pro čtení/zápis bloku ve streamu (chyba jako io::Error).
fn lock_stream(backend: &Mutex<SftpBackend>) -> io::Result<MutexGuard<'_, SftpBackend>> {
    backend.lock().map_err(|_| io::Error::other("SFTP spojení je uzamčené."))
}

/// Čtecí stream z SFTP: drží otevřený handle a Arc na backend.
/// Každé čtení zamkne sdílený zámek (Session není vláknově bezpečná).
pub struct SftpReadStream {
    file: Option<SshFile>,
    backend: Arc<Mutex<SftpBackend>>,
}

impl Read for SftpReadStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let Some(file) = self.file.as_mut() else {
            return Ok(0);
        };
        // Zámek držíme po dobu čtení – libssh2 Session není vláknově bezpečná,
        // veškerý přístup musí být serializovaný.
        let _guard = lock_stream(&self.backend)?;
        file.read(buf)
    }
}
impl VfsReadStream for SftpReadStream {}

/// Zapisovací stream na SFTP: obdobně jako čtecí, handle z `create`.
pub struct SftpWriteStream {
    file: Option<SshFile>,
    backend: Arc<Mutex<SftpBackend>>,
}

impl Write for SftpWriteStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let Some(file) = self.file.as_mut() else {
            return Err(io::Error::new(
                io::ErrorKind::NotConnected,
                "SFTP handle už je uzavřený.",
            ));
        };
        // Zámek držíme po dobu zápisu – libssh2 Session není vláknově bezpečná.
        let _guard = lock_stream(&self.backend)?;
        file.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        let Some(file) = self.file.as_mut() else {
            return Ok(());
        };
        let _guard = lock_stream(&self.backend)?;
        file.flush()
    }
}

impl VfsWriteStream for SftpWriteStream {
    /// Zavře soubor na serveru a vrátí případnou chybu zavření (jinak by ji
    /// zahození streamu spolklo).
    fn finish(&mut self) -> io::Result<()> {
        self.flush()?;
        let Some(mut file) = self.file.take() else {
            return Ok(());
        };
        let _guard = lock_stream(&self.backend)?;
        file.close().map_err(io::Error::from)
    }
}

impl Vfs for SftpFs {
    fn kind(&self) -> VfsKind {
        VfsKind::Sftp
    }

    fn label(&self) -> String {
        self.label.clone()
    }

    fn list(&self, path: &str) -> SalResult<Vec<VfsItem>> {
        let server_path = self.server_path(path);
        let guard = self.lock()?;
        let entries = guard
            .sftp
            .readdir(Path::new(&server_path))
            .map_err(ssh_error)?;
        let mut items = Vec::new();
        for (entry_path, stat) in entries {
            // readdir vrací jména položek (ne absolutní cesty).
            let name = entry_path
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_else(|| entry_path.to_string_lossy().to_string());
            if let Some(item) = stat_to_item(&name, &stat) {
                items.push(item);
            }
        }
        Ok(items)
    }

    fn open_read(&self, path: &str) -> SalResult<Box<dyn VfsReadStream>> {
        let server_path = self.server_path(path);
        let guard = self.lock()?;
        let file = guard.sftp.open(Path::new(&server_path)).map_err(ssh_error)?;
        drop(guard);
        Ok(Box::new(SftpReadStream {
            file: Some(file),
            backend: self.backend.clone(),
        }))
    }

    fn open_write(&self, path: &str, _size_hint: Option<u64>) -> SalResult<Box<dyn VfsWriteStream>> {
        let server_path = self.server_path(path);
        let guard = self.lock()?;
        // Vytvoření nového souboru (truncate + write).
        let file = guard
            .sftp
            .open_mode(
                Path::new(&server_path),
                OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::TRUNCATE,
                0o644,
                OpenType::File,
            )
            .map_err(ssh_error)?;
        drop(guard);
        Ok(Box::new(SftpWriteStream {
            file: Some(file),
            backend: self.backend.clone(),
        }))
    }

    fn mkdir(&self, path: &str) -> SalResult<()> {
        let server_path = self.server_path(path);
        let guard = self.lock()?;
        guard
            .sftp
            .mkdir(Path::new(&server_path), 0o755)
            .map_err(ssh_error)
    }

    fn delete(&self, path: &str, recursive: bool) -> SalResult<()> {
        // lstat (ne stat): odkaz na adresář se smaže jako odkaz – rekurze do
        // něj by smazala obsah adresáře, na který ukazuje.
        let server_path = self.server_path(path);
        let is_dir = self.lock()?.sftp.lstat(Path::new(&server_path)).map_err(ssh_error)?.is_dir();
        self.delete_known(path, is_dir, recursive)
    }

    /// Mazání se známým druhem položky (z lstat nebo z výpisu rodiče).
    /// Adresář: při `recursive` nejdřív obsah (SFTP rmdir maže jen prázdné
    /// adresáře), jinak musí být prázdný. Odkaz se maže jako soubor – jeho
    /// cíl zůstává.
    fn delete_known(&self, path: &str, is_dir: bool, recursive: bool) -> SalResult<()> {
        let server_path = self.server_path(path);
        if !is_dir {
            return self.lock()?.sftp.unlink(Path::new(&server_path)).map_err(ssh_error);
        }
        let children = self.list(path)?;
        if !recursive && !children.is_empty() {
            return Err(SalError::NotEmpty);
        }
        for child in children {
            self.delete_known(&join_path(path, &child.name), child.kind == VfsItemKind::Dir, true)?;
        }
        self.lock()?.sftp.rmdir(Path::new(&server_path)).map_err(ssh_error)
    }

    fn rename(&self, path: &str, new_name: &str) -> SalResult<()> {
        let (parent, _) = split_path(path);
        let from = self.server_path(path);
        let to = self.server_path(&join_path(&parent, new_name));
        let guard = self.lock()?;
        // Existující cíl se nesmí nahradit (lstat: i odkaz vedoucí nikam je položka).
        if guard.sftp.lstat(Path::new(&to)).is_ok() {
            return Err(SalError::AlreadyExists);
        }
        guard.sftp.rename(Path::new(&from), Path::new(&to), None).map_err(ssh_error)
    }

    fn exists(&self, path: &str) -> SalResult<bool> {
        let server_path = self.server_path(path);
        let guard = self.lock()?;
        match guard.sftp.stat(Path::new(&server_path)) {
            Ok(_) => Ok(true),
            Err(err) if err.code() == ssh2::ErrorCode::SFTP(2) => Ok(false),
            Err(err) => Err(ssh_error(err)),
        }
    }

    fn is_dir(&self, path: &str) -> SalResult<bool> {
        let server_path = self.server_path(path);
        let guard = self.lock()?;
        match guard.sftp.stat(Path::new(&server_path)) {
            Ok(stat) => Ok(stat.is_dir()),
            Err(err) if err.code() == ssh2::ErrorCode::SFTP(2) => Ok(false),
            Err(err) => Err(ssh_error(err)),
        }
    }

    fn supports_size_scan(&self) -> bool {
        // Rekurzivní scan = dvojitý průchod síťí; vypnuto jako u FTP.
        false
    }

    fn dir_identity(&self, dir: &str) -> Option<String> {
        Some(format!("{}{}", self.account, self.server_path(dir)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// Bez živého serveru: převod atributů ze serveru na položku výpisu
    /// (druh podle typu souboru v právech, jen pro čtení, skryté jméno).
    #[test]
    fn test_stat_to_item() {
        let stat = |perm: u32| FileStat { size: Some(5), uid: None, gid: None, perm: Some(perm), atime: None, mtime: Some(7) };
        let file = stat_to_item("a.txt", &stat(0o100644)).unwrap();
        assert_eq!((file.kind, file.size, file.mtime, file.readonly), (VfsItemKind::File, 5, 7, false));
        assert_eq!(stat_to_item("pod", &stat(0o040755)).unwrap().kind, VfsItemKind::Dir);
        // Odkaz zůstává odkazem (mazání ho pak nesmí procházet jako adresář).
        assert_eq!(stat_to_item("odkaz", &stat(0o120777)).unwrap().kind, VfsItemKind::Link);
        let readonly = stat_to_item(".skryty", &stat(0o100444)).unwrap();
        assert!(readonly.readonly && readonly.hidden);
        assert!(stat_to_item("..", &stat(0o040755)).is_none());
    }

    // ------------------------------------------------------------------
    // End-to-end testy proti živému SSH serveru (spouští `make sftp-test`,
    // který nastartuje dočasný sshd na 127.0.0.1 a vygeneruje klíče).
    // Bez proměnných prostředí se přeskočí (#[ignore] + kontrola env).
    // ------------------------------------------------------------------

    /// Parametry testovacího serveru z prostředí (port, adresář s klíči, uživatel).
    fn server() -> Option<(u16, PathBuf, String)> {
        let port = std::env::var("SAL_TEST_SSH_PORT").ok()?.parse().ok()?;
        let keys = PathBuf::from(std::env::var("SAL_TEST_SSH_KEYDIR").ok()?);
        let user = std::env::var("USER").unwrap_or_else(|_| "root".to_string());
        Some((port, keys, user))
    }

    /// Připojení klíčem ze souboru `name` v adresáři klíčů.
    fn connect_key(name: &str, passphrase: Option<&str>) -> SalResult<SftpFs> {
        let (port, keys, user) = server().expect("chybí SAL_TEST_SSH_PORT / SAL_TEST_SSH_KEYDIR");
        let auth = SftpAuth::KeyFile { private_key: keys.join(name), passphrase: passphrase.map(str::to_string) };
        SftpFs::connect_with("127.0.0.1", port, &user, &auth, Duration::from_secs(10))
    }

    /// Ověří funkční spojení: zápis, výpis, čtení a smazání souboru v pracovním adresáři testu.
    fn roundtrip(fs: &SftpFs, tag: &str) {
        // Kořen VFS = domov uživatele: pracovní adresář testu v domově (po testu se smaže).
        let relative = format!("/.sal-sftp-test-{}-{}", std::process::id(), tag);
        fs.mkdir(&relative).unwrap();
        let file = format!("{}/{}.txt", relative, tag);
        let mut writer = fs.open_write(&file, None).unwrap();
        writer.write_all(format!("obsah {}", tag).as_bytes()).unwrap();
        writer.flush().unwrap();
        drop(writer);
        let names: Vec<String> = fs.list(&relative).unwrap().into_iter().map(|item| item.name).collect();
        assert!(names.contains(&format!("{}.txt", tag)), "výpis neobsahuje soubor: {:?}", names);
        let mut text = String::new();
        fs.open_read(&file).unwrap().read_to_string(&mut text).unwrap();
        assert_eq!(text, format!("obsah {}", tag));
        // Přejmenování: na volné jméno projde, existující položku nenahradí.
        fs.rename(&file, "jiny.txt").unwrap();
        assert_eq!(fs.rename(&relative, &relative[1..]).unwrap_err(), SalError::AlreadyExists);
        // Stejný adresář má stejnou identitu pro každé připojení účtu.
        assert!(fs.dir_identity(&relative).unwrap().starts_with("sftp://"));
        // Odkaz na adresář uvnitř mazaného stromu: smaže se jen odkaz, obsah
        // adresáře, na který ukazuje, musí zůstat.
        let target = format!("{}-cil", relative);
        fs.mkdir(&target).unwrap();
        let kept = format!("{}/zustane.txt", target);
        let mut writer = fs.open_write(&kept, None).unwrap();
        writer.write_all(b"x").unwrap();
        writer.finish().unwrap();
        drop(writer);
        fs.lock()
            .unwrap()
            .sftp
            .symlink(Path::new(&fs.server_path(&target)), Path::new(&fs.server_path(&format!("{}/odkaz", relative))))
            .unwrap();
        fs.delete(&relative, true).unwrap();
        assert!(!fs.exists(&relative).unwrap_or(true), "pracovní adresář testu zůstal");
        assert!(fs.exists(&kept).unwrap(), "mazání odkazu smazalo obsah cílového adresáře");
        fs.delete(&target, true).unwrap();
    }

    #[test]
    #[ignore]
    fn sftp_key_ed25519_plain() {
        let Some(_) = server() else { return };
        let fs = connect_key("id_plain", None).expect("ed25519 bez hesla");
        roundtrip(&fs, "plain");
    }

    #[test]
    #[ignore]
    fn sftp_key_ed25519_passphrase() {
        let Some(_) = server() else { return };
        let (_, keys, _) = server().unwrap();
        assert!(key_file_encrypted(&keys.join("id_pass")).unwrap(), "id_pass má být rozpoznán jako šifrovaný");
        assert!(!key_file_encrypted(&keys.join("id_plain")).unwrap(), "id_plain šifrovaný není");
        assert!(!key_file_encrypted(&keys.join("id_rsa_pem")).unwrap(), "RSA PEM bez hesla šifrovaný není");
        let missing = connect_key("id_pass", None).err().expect("bez hesla ke klíči musí selhat").to_string();
        assert!(missing.contains("chráněný heslem"), "{}", missing);
        let wrong = connect_key("id_pass", Some("spatne")).err().expect("chybné heslo musí selhat").to_string();
        assert!(wrong.contains("chybné heslo"), "{}", wrong);
        let fs = connect_key("id_pass", Some("tajne-heslo")).expect("správné heslo ke klíči");
        roundtrip(&fs, "pass");
    }

    #[test]
    #[ignore]
    fn sftp_key_rsa_pem_and_ecdsa() {
        let Some(_) = server() else { return };
        roundtrip(&connect_key("id_rsa_pem", None).expect("RSA PEM"), "rsa");
        roundtrip(&connect_key("id_ecdsa", None).expect("ECDSA"), "ecdsa");
    }

    #[test]
    #[ignore]
    fn sftp_key_rejected_and_missing() {
        let Some(_) = server() else { return };
        let rejected = connect_key("id_other", None).err().expect("neautorizovaný klíč").to_string();
        assert!(rejected.contains("odmítl"), "{}", rejected);
        let missing = connect_key("neexistuje", None).err().expect("chybějící soubor").to_string();
        assert!(missing.contains("neexistuje"), "{}", missing);
    }

    #[test]
    #[ignore]
    fn sftp_agent() {
        let Some((port, _, user)) = server() else { return };
        // Socket testovacího agenta (s načteným id_plain) předá skript.
        let Ok(socket) = std::env::var("SAL_TEST_SSH_AGENT_SOCK") else { return };
        std::env::set_var("SSH_AUTH_SOCK", socket);
        let fs = SftpFs::connect_with("127.0.0.1", port, &user, &SftpAuth::Agent, Duration::from_secs(10))
            .expect("přihlášení přes ssh-agent");
        roundtrip(&fs, "agent");
    }
}
