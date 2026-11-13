# Průběh prací: MicroCommander (přepis Salamanderu) → Rust jádro + Swift/AppKit UI (macOS)

Cíl (README.md): přepsat aplikaci bez pluginů — jádro v Rustu (souborové operace,
VFS, archivy, FTP/SFTP, hledání), nad ním tenké UI ve Swift/AppKit pro macOS.
Původní Windows zdrojáky: `samandarin/` (reference, neměníme).

Pracovní adresář: kořen repozitáře (lokálně adresář `salamander`)

## Prostředí

- Rust: `~/.cargo/bin` (rustc/cargo 1.88.0) — nutné `export PATH="$HOME/.cargo/bin:$PATH"`
- Swift 6.4.2 (`/usr/bin/swiftc`), target arm64-apple-macosx
- crates.io přístup funguje (cargo fetch OK)
- Adresář není git repozitář (jen obsahuje `samandarin/` s vlastním repem)
- Platforma: macOS, arm64 (Apple Silicon)

## Schválený plán (checklist)

1. [x] Kostra Rust workspace (salcore) s VFS traitem a typy
2. [x] Lokální souborový systém nad VFS
3. [x] Masky a rekurzivní hledání
4. [x] Copy/move/delete s progresem a cancellací
5. [x] ZIP VFS + TAR/TAR.GZ VFS (vlastní TAR parser)
6. [x] FTP VFS (ftp.rs — suppaftp, Arc<Mutex<FtpStream>>, RETR/STOR streamy s finalize/abort)
7. [x] SFTP VFS (sftp.rs — ssh2, per-call lock, realpath home)
8. [x] FFI C ABI + hlavička + smoke test — ffi.rs + salamander.h + module.modulemap;
     end-to-end smoke test PROŠEL (list/copy/mkdir/rename/delete/find/pack ZIP/probe)
9. [x] Swift/AppKit tenké UI — dual-pane běží, ověřeno screenshotem
10. [x] Build, ověření, README update — make/make run/make test/make smoke fungují

## Struktura projektu

```
core/Cargo.toml               # workspace, members = crates/salcore, release LTO
core/crates/salcore/Cargo.toml
core/crates/salcore/src/
  lib.rs        # moduly: error, find, local, mask, ops, tarfs, vfs, zipfs
  error.rs      # SalError (Cancelled/NotFound/AlreadyExists/... + kódy pro FFI)
  vfs.rs        # trait Vfs (list/open_read/open_write/mkdir/delete/rename/
                #   exists/is_dir/free_space/writable/as_local/supports_size_scan),
                #   VfsItem, VfsItemKind, join_path/normalize/split/parent
  local.rs      # LocalFs nad std::fs, statfs free_space, same_root, as_local
  mask.rs       # MaskGroup: DOS masky *, ?, # ; skupiny ; a vyloučení |
                #   zvláštní případy: *.* = vše, maska končící tečkou = bez přípony
  ops.rs        # copy_items/move_items/delete_items, OverwriteMode
                #   (Ask/Overwrite/Skip), ProgressCallback (false = cancel),
                #   TransferStats; move fast-path přes rename při stejném LocalFs root
  find.rs       # find_items (rekurzivní, maska, include_dirs, on_found callback)
  zipfs.rs      # ZipFs (zip crate 4.x, jen čtení), ZipReadStream s unsafe
                #   lifetime rozšířením (Box<ZipArchive> heap, pořadí polí!),
                #   zip_time_to_unix (days-from-civil), pub inner_prefix_of()
  tarfs.rs      # TarFs - VLASTNÍ TAR parser (bez tar crate API pro čtení):
                #   ustar + GNU longname 'L' + PAX 'x' (path/size/mtime),
                #   plain TAR = seek na data; tar.gz = GzCursor sdílená session
                #   (Arc<Mutex<GzSession>>) pro jednoprůchodové čtení více souborů,
                #   restart kurzoru při zpětném čtení; probe_tar_format (gzip magic
                #   1f 8b, ustar na 257, fallback oktal validace)
  ftp.rs        # FtpFs (suppaftp 6.3): FtpStream alias pro ImplFtpStream<NoTlsStream>,
                #   connect_timeout + resolv, FileType::Image (NE Binary!),
                #   list přes LIST + from_posix_line parser (jméno "-> cíl" očistit!),
                #   RETR/STOR streamy: finalize_retr_stream/abort při dropu,
                #   VFS root = PWD home
  sftp.rs       # SftpFs (ssh2 0.9.7): Sftp/File BEZ lifetime parametrů (raw ptr),
                #   Arc<Mutex<backend{Session,Sftp}>>, stream drží Arc a lockuje
                #   per read/write blok, realpath(".") home, stat is_dir,
                #   open_mode WRITE|CREATE|TRUNCATE, rename s OVERWRITE flag,
                #   recursive delete ručně (SFTP rmdir jen prázdné)
progress.md     # tento soubor
README.md       # zadání (aktualizovat na konci)
```

## Závislosti (Cargo.toml)

- zip 4 (default-features=false, features deflate+time) — ZIP
- tar 0.4 + flate2 1 — tar: jen pro *vytváření* testovacích archivů; čtení vlastní parser
- suppaftp 6.3.0 (default-features=false, sync API je výchozí; POZOR: feature "sync" NEEXISTUJE)
- ssh2 0.9 (vendored-openssl — build trvá déle)
- libc 0.2 (statfs)

## Ověřená API faktů (z ~/.cargo/registry)

### suppaftp 6.3.0
- `suppaftp::{FtpError, FtpResult, Mode}` exporty; sync stream = `suppaftp::ImplFtpStream` (alias FtpStream neexistuje v 6.x!)
- `ImplFtpStream::connect(addr: A: ToSocketAddrs) -> FtpResult<Self>` — passive je výchozí
- `login(user, pass)`, `cwd(path)`, `cdup()`, `pwd()`, `mkdir`, `rename(from,to)`,
  `rm(filename)`, `rmdir(pathname)`, `list(Option<&str>) -> Vec<String>` (UNIX ls výpis),
  `nlst`, `mlsd`, `size`, `quit()`, `abort(data_stream)`
- `retr_as_stream(file) -> FtpResult<DataStream<T>>` + `finalize_retr_stream(stream)`
- `put_with_stream(filename) -> FtpResult<DataStream<T>>` + `finalize_put_stream(stream)`
- `suppaftp::list::File` (pub struct: name, file_type: FileType, size: usize,
  modified: SystemTime, uid/gid, posix_pex) — parser UNIX LIST řádků

### tar 0.4.46
- `Archive::entries()` jen sekvenční; proto vlastní parser v tarfs.rs (viz výše)

### ssh2 0.9 — ještě ověřit detaily (Session::new, handshake, userauth_password,
  sftp(), open/read/write, readdir, mkdir/unlink/rename) při implementaci sftp.rs

## Stav testů

- **21/21 unit testů PROŠLO** (cargo test) — vfs, mask, local, ops, find, zipfs,
  tarfs (plain i gzip + copy all), ftp čisté funkce, sftp formát
- Opravené bugy z testů: race testů na sdíleném temp adresáři (tagy),
  maska `|*.txt` = vše kromě, tar.gz kurzor pos po scanu, cílové adresáře testů
- pack.rs: vytváření ZIP z libovolného VFS (hotovo, bez vlastního testu —
  použije se v UI „zabalit“)

### Opraveno
- error.rs: SalError už není Copy (Io(String))
- vfs.rs test: tuple String/String
- zipfs.rs: ZipFile = zip::read::ZipFile<'static, File> (zip 4.6.1 má 2 generika),
  From<ZipError> pro SalError (FileNotFound→NotFound), last_modified() je Option
  → unwrap_or_default(), zip::read::ZipArchive
- ops.rs: copy/move/delete berou `&mut dyn ProgressCallback` (ne impl Trait),
  PathBuf import do testů, testy volají `&mut NoProgress` / `&mut CancelNow`,
  VfsItem import odstraněn, move_local_rename bez nepoužitého parametru dst
- find.rs test: contains(&str) → iter().any()
- local.rs: DirEntry::symlink_metadata() neexistuje → std::fs::symlink_metadata(entry.path())
- sftp.rs: ErrorCode::Sftp → ErrorCode::SFTP, odstraněn nepoužitý PathBuf import

### Zbývá opravit (nespuštěno znovu)
- tarfs.rs:
  - parse_octal base-256: `field[0] & 0x7f` je u8 → `(field[0] & 0x7f) as u64`
  - read_up_to potrebuje `R: Read + ?Sized` (volání s &mut dyn TarSource)
  - E0505: open_read_gzip — drop(guard) PŘED přesunem `session` do struktury
    (MutexGuard drží borrow Arcu)
  - test test_tar_gzip_copy_all: dočasná hodnota src.list("/") — bind do let
- ftp.rs: NoTlsStream je PRIVÁTNÍ (mod sync_ftp není pub!) → streamy ukládat
  jako `Box<dyn Read + Send>` / `Box<dyn Write + Send>` (DataStream je Send),
  finalize_retr_stream/abort/finalize_put_stream přijímají impl Read/Write
  po hodnotě — Box to splňuje; odstranit import NoTlsStream a DataStream

### Klíčová API fakta navíc
- zip 4.6.1: ZipError { Io, InvalidArchive(Cow), UnsupportedArchive(&str),
  FileNotFound, InvalidPassword }; ZipFile::name/mangled_name/size existují
- suppaftp 6.3: `mod sync_ftp` je PRIVÁTNÍ — typ NoTlsStream nelze pojmenovat;
  FtpStream = ImplFtpStream<NoTlsStream> je pub alias; DataStream<T> enum
  {Tcp(TcpStream), Ssl(Box<T>)} je Send pro NoTlsStream
- ssh2 0.9.7: ErrorCode::SFTP(u32) (ne Sftp); FileStat.is_dir() existuje

## FFI plán (ffi.rs + core/include/salamander.h + module.modulemap)

- Handle = Box<dyn Vfs> přes into_raw; sal_vfs_close uvolní
- sal_open_local(root), sal_open_zip(path), sal_open_tar(path),
  sal_connect_ftp/sftp(host, port, user, pass, timeout_s)
- sal_vfs_list -> SalItem[] {name, size, mtime, flags}, sal_free_items
- sal_vfs_is_dir/exists/free_space/writable/kind/label
- sal_copy/sal_move/sal_delete(src, dir, names**, dst, dir, overwrite(0/1/2),
  progress_cb(done,total,user)->bool, user)
- sal_find(vfs, root, mask, include_dirs, found_cb(path,size,mtime,flags,user), progress_cb)
- sal_pack_zip(vfs, dir, names, dest_zip, progress)
- sal_probe_archive(path) -> 0 none / 2 zip / 3 tar
- Chyby: návratový int kód (SAL_ERR_*), sal_last_error_message() thread-local
- Swift UI: import salamander přes modulemap (clang importer),
  `swiftc -I core/include app/*.swift -framework AppKit`

## Další kroky (v pořadí)

1. **ftp.rs** — FtpFs: Mutex<ImplFtpStream>, list přes LIST + suppaftp::list::File
   parser, open_read = retr_as_stream + finalize při dropu, open_write = put_with_stream,
   delete = rm/rmdir, rename, mkdir, free_space = None, supports_size_scan = false
2. **sftp.rs** — SftpFs přes ssh2 (username/password), Mutex<Session+Sftp>
3. **ffi.rs** — C ABI: sal_open_local/sal_list/sal_free_list/sal_read.../operace;
   + `include/salamander.h`; cdylib
4. **UI** — `app/` Swift/AppKit: dual-pane, NSTableView, F5 copy F6 move F7 mkdir F8 delete,
   Enter = vstup do adresáře / otevření archivu jako VFS, ⌘↑ nahoru, connect dialog
   FTP/SFTP, find dialog, progress sheet s cancel
5. **Makefile** — make / make run: cargo build --release + swiftc + .app bundle
   (dylib do Contents/Frameworks, install_name fix)
6. **README.md** — aktualizovat podle CLAUDE.md pokynů
7. `cargo test` + `cargo clippy` v core/, build a spuštění UI

## Poznámky / rozhodnutí

- Archivy jsou VFS jen pro čtení (pack = vytvoření nového ZIP přes zip crate až v UI
  operacích — přítomno v zip crate; zatím není implementováno jako VFS operace)
- Cesty VFS: vždy `/` oddělovač, absolutní od kořene VFS
- VfsItem kind: File/Dir/Link; hidden = tečka na začátku (unix)
- Progress: on_progress(done,total) -> bool (false = zrušit); total=0 = neznámý celek
- move_items: fast-path rename pokud oba LocalFs se stejným rootem
- Kód a identifikátory anglicky, komentáře česky (pravidla uživatele)
- Commit messages česky, přítomný čas, tečka na konci (až budeme commitovat — adresář
  není git repozitář, zatím bez commitů)

## Poslední aktualizace

- 2026-11-13 (23): Více FTP/SFTP serverů: Servers.swift (ServerProfile Codable
  s decodeIfPresent, ServerStore = UserDefaults „servers“ + převod starých
  klíčů connect*, ServerKeychain = hesla v Klíčence), ConnectWindowController
  přepsán na správu serverů (seznam +/−, formulář, průběžné ukládání),
  nabídka disků ⌥F1/⌥F2 ukazuje servery (DriveChoice, driveChooserItems),
  beginProgress(dismissOnCancel:), sdílený askSecretText. Keycheck OK.

- 2026-11-13 (22): /simplify před prvním commitem: sloučená obsluha vstupu
  tabulky a mřížky (PanelView.handle*, edgeCommands + doCommand), Command:
  CaseIterable + Command.viewMode, rowTextColor, NSAlert.addCancelButton,
  coreTransfer, transfer_ffi/overwrite_mode, vfs::remote_path a
  system_time_to_unix, TarFs::has_implied_dir (O(log n)), pack bez is_dir
  u položek z výpisu, cache šířky jmen a kreslení jen viditelných buněk.
  Oprava: FTP rekurzivní mazání neprázdného adresáře.

- 2026-11-13 (21): Projekt přejmenován na **MicroCommander** (MicroCommander.app,
  bundle com.github.svopex.microcommander, hlavička microcommander.h, modul
  microcommander, log ~/Library/Logs/MicroCommander). Zmínky o původním
  Salamanderu zůstaly. Jednorázový převod předvoleb z eu.krtkovo.salamander
  (bez keyLog). Git repozitář, GitHub svopex/MicroCommander (veřejný),
  samandarin/ v .gitignore.

- 2026-11-13 (20): Menu Panel ukazuje ⌘. / ⌘⇧. (⌃ varianty v názvu položky),
  nápověda F1 a README uvádějí ⌘ zkratky na prvním místě.

- 2026-11-13 (19): Skryté soubory jen ⌃H (jako Ctrl+H v Salamanderu, i v menu);
  ⌘⇧. uvolněno → stejně jako ⌃⇧. převzít adresář z druhého panelu.

- 2026-11-13 (18): Podle záznamu kláves kód dělal to, co říkaly texty menu,
  ale uživatel je chápal opačně. Upřesněno otázkou: ⌃. / ⌘. = POSLAT aktuální
  adresář do druhého panelu (sameDirOther), ⌃⇧. = PŘEVZÍT adresář z druhého
  (sameDir); jednoznačné texty v menu, liště, F1, README. keyLog dočasně zapnut.

- 2026-11-13 (17): Oprava prohozených ⌃. / ⌃⇧.: AppKit přiřadil ⌃⇧. (znak „.“)
  položce menu ⌃. (Shift ignoruje). Zkratky s tečkou teď řeší monitor kláves
  podle keyCode 47 před menu (periodShortcutCommand); keycheck ověřuje varianty
  znaků „.“, „:“ (CZ), „>“ (US).

- 2026-11-13 (16): Zkratky dle upřesnění: ⌃. (⌘.) = aktivní panel do adresáře
  druhého, ⌃⇧. = druhý panel do adresáře aktivního; obě v nápovědě F1.

- 2026-11-13 (15): ⌃⇧. druhý panel do adresáře aktivního (Command.sameDirOther,
  menu Panel, tlačítko lišty); oba směry přes PanelController.adoptLocation
  (převezme i zanoření archivu/FTP). Tečka se rozpoznává podle keyCode 47
  (česká klávesnice: ⇧. = „:“). Keycheck ověřuje oba směry i v ZIP.

- 2026-11-13 (14): SFTP přihlášení klíčem: SftpAuth {Password, KeyFile, Agent},
  SftpFs::connect_with, key_file_encrypted (OpenSSH hlavička / PEM), veřejný
  klíč se nepředává (chyba hesla ke klíči lokálně, -16), srozumitelné chyby;
  FFI sal_connect_sftp_key / sal_connect_sftp_agent / sal_ssh_key_encrypted;
  nový dialog připojení (NSGridView, Vybrat… z ~/.ssh, pamatuje hodnoty bez
  hesel). `make sftp-test` = dočasný sshd + klíče + agent, 5 Rust testů + FFI.

- 2026-11-13 (13): Pořadí disků (DriveBar.listDrives podle UserDefaults
  driveOrder, výchozí Domů první; ⌥↑/⌥↓ v DriveChooser, kontextové menu lišty
  disků). Home/End i podle znaku (NSHome/EndFunctionKey) a ⌘←/⌘→; KeyLog
  (defaults keyLog). Stručný režim: rezerva pro překryvný vodorovný posuvník
  (poslední řádek sloupců byl zakrytý). Keycheck s 500 soubory a viditelností
  kurzoru. Uživatel potvrdil, že Home/End fungují.

- 2026-11-13 (12): Nabídka disků jako vlastní okno DriveChooser (Dialogs.swift)
  místo NSMenu – ↑/↓ cyklí přes konec, Home/End, číslice, výchozí řádek =
  aktuální disk; PanelInputHandler.panelViewShowDriveChooser. Keycheck rozšířen.

- 2026-11-13 (11): Home/End ve všech režimech: PanelView.moveCursorToEdge,
  tabulka i mřížka posílají nezpracované klávesy přes interpretKeyEvents a
  příkazy scroll/moveTo(Beginning|End)OfDocument přesouvají kurzor (dřív
  NSTableView jen posunula obsah). `make keycheck` (SAL_KEYCHECK) – bez okna.

- 2026-11-13 (10): Režimy zobrazení ⌥1–⌥6 (FileGridView.swift: Stručný,
  Ikony, Miniatury přes QLThumbnailGenerator, Dlaždice; Podrobný/Typy =
  tabulka, sloupec Typ), ukládání po stranách (UserDefaults viewModeLeft/Right).
  Skryté soubory globálně + persistence (showHiddenFiles), jádro hlásí i
  UF_HIDDEN (local.rs st_flags). Home/End/⌥↑/⌥↓ přes moveCursorToEdge,
  navigace podle režimu (PanelView.target), prázdná příkazová řádka předává
  Home/End/PgUp/PgDn panelu. Oprava: vstupní pole dialogů se nezalamuje.
  Selftest OK v klidu; při práci uživatele kolísá (ztráta fokusu).

- 2026-11-13 (9): **Zaheslované ZIP (AES-256)**. zip crate feature aes-crypto;
  ZipFs čte AES-128/192/256 i ZipCrypto (výpis přes by_index_raw bez hesla,
  čtení by_index_decrypt), SalError::PasswordRequired (-7) / InvalidPassword (-8),
  příznak SAL_FLAG_ENCRYPTED (16); pack_zip_encrypted (AES-256 / ZipCrypto,
  ZipCrypto přes zip::unstable::write::FileOptionsExt); FFI sal_pack_zip_ex,
  sal_vfs_set_password, sal_vfs_has_encrypted. Opravena chyba balení – vnořené
  soubory ztrácely cestu v archivu (a stats.bytes se načítaly kumulativně).
  UI: dotaz na heslo předem i po chybě (opakování operace), volby šifrování
  v dialogu ⌥F5 (PackOptionsView), atribut „E“. Testy: 25/25, smoke vč. bsdtar
  oběma směry, selftest vč. AES scénáře. Pozn.: build s novými crates potřebuje
  zápis do ~/.cargo/registry (mimo sandbox).

- 2026-11-13 (8): **Přepis UI podle předlohy Salamandera** (help main.png/panel.png):
  nástrojová lišta, lišta disků, prostřední lišta, řádek adresáře, „..“, sloupce
  Jméno/Přípona/Velikost/Datum/Čas/Atr, kurzor ≠ označení, info řádek, příkazová
  řádka, lišta F-kláves s vrstvami Shift/Ctrl/Alt, interní prohlížeč F3.
  Opravené příčiny zamrzání: progress sheet se neukončoval (window.parent místo
  sheetParent), kontrolery FTP/Hledat se hned uvolnily (mrtvá tlačítka),
  „Zrušit“ v NSAlertu nereagovalo na Escape, fokus po startu v poli cesty,
  kurzor po změně adresáře zůstával na starém indexu. Nový `make selftest`
  (SelfTest.swift) – vše OK; make test 21/21, make smoke OK.

- 2026-11-12 (7): **HOTOVO**. Aplikace běží (build/Salamander.app), UI ověřeno
  screenshoty (dva panely, ikony, stavový řádek). 21/21 unit testů jádra +
  FFI smoke test 14/14 OK. README.md přepsáno (architektura, build, ovládání,
  omezení). Realizováno celé zadání: jádro v Rustu (VFS/operace/archivy/FTP/
  SFTP/hledání) + tenké Swift/AppKit UI pro macOS bez pluginů.

## Jak navázat (pokud by se mělo pokračovat)

- build: `make` (nebo `make run` pro spuštění), testy: `make test`, FFI: `make smoke`
- aplikace: build/Salamander.app — F5 copy, F6 move, F7 mkdir, F8 delete, F2 rename,
  ⌘K FTP/SFTP, ⌘F find, ⌘B pack ZIP, ⌘R obnovit, ⌘U prohodit panely
- potenciální rozšíření: FTPS/klíče SFTP, thumbnails, rychlý náhled,
  parallel přenosy (storage scheduling jako v originále), historie vpřed/zpět
