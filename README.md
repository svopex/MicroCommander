# MicroCommander

Dvoupanelový správce souborů pro macOS – přepis Open Salamanderu (bez pluginů)
s jádrem v Rustu a tenkým UI ve Swift/AppKit. Licence GPL-2.0-or-later.

## Prvotni zadani

Prepis aplikaci, zatim bez pluginu, do:
Jádro (souborové operace, virtuální souborové systémy, archivy, FTP/SFTP, hledání) napíšete jednou v Rustu. 
Nad ním postavíte tenké UI: Swift/AppKit na Macu, WinUI nebo Win32 na Windows.
Zatim chci verzi pro MAC OS, tenke UI delej tedy pouze pro tuto platformu.
Puvodni zdrojove kody pro windows jsou v adresari `samandarin`.

> Adresář `samandarin/` (původní Windows zdrojáky Open Samandarin, ~138 MB) slouží
> jen jako lokální reference a do repozitáře se necommituje (viz `.gitignore`).
> Stáhne se skriptem `./fetch-samandarin.sh` (volitelně s názvem větve/tagu), který
> naklonuje https://github.com/KRtkovo-eu-AI/salamander včetně všech
> git submodulů (pluginy, 3rd-party), odstraní adresář `.git` a nahradí stávající
> obsah `samandarin/`.

## Stav realizace (2026-11-12)

Zadání je realizováno pro macOS: jádro `salcore` v Rustu + tenké UI ve Swift/AppKit
(dvoupanelový správce souborů). Původní Windows zdrojáky v `samandarin/` zůstávají
nezměněné a slouží jako reference chování (masky, VFS koncept).

### Architektura

```
┌─────────────────────────────┐
│  app/  Swift/AppKit UI      │  tenké UI: dva panely, příkazy, dialogy
│         (macOS, arm64)      │  volá jádro přes C ABI (core/include/microcommander.h)
├─────────────────────────────┤
│  core/  salcore (Rust)      │  jediné místo s veškerou logikou:
│         libsalcore.dylib    │  VFS trait + operace + hledání + FFI (C ABI)
└─────────────────────────────┘
```

- **Jádro** (Rust, crate `salcore`): virtuální souborové systémy za společným
  traitem `Vfs` – lokální disk, archivy ZIP/TAR/TAR.GZ (jen čtení), FTP (suppaftp),
  SFTP (ssh2/libssh2; přihlášení heslem, souborem se soukromým klíčem
  OpenSSH/PEM – ed25519, ECDSA, RSA, i chráněným heslem – nebo klíči
  ze ssh-agenta). Souborové operace (copy/move/delete) pracují mezi libovolnou
  dvojicí VFS streamovaně po 256 KiB blocích, s hlášením průběhu a zrušením.
  Hledání nad libovolným VFS s maskami ve stylu Salamandera (`*`, `?`, `#`,
  skupiny oddělené `;`, vyloučení za `|`). Vytváření ZIP archivů (`pack_zip`)
  včetně adresářové struktury. **Zaheslované ZIP:** čtení AES-128/192/256
  (WinZip AE-1/AE-2) i ZipCrypto; vytváření s AES-256 (doporučeno) nebo
  ZipCrypto (`pack_zip_encrypted`, FFI `sal_pack_zip_ex`). Výpis šifrovaného
  archivu heslo nepotřebuje, heslo se nastavuje na otevřený archiv
  (`sal_vfs_set_password`) a chyby rozlišují „chybí heslo“ / „chybné heslo“.
- **FFI** (C ABI): `core/include/microcommander.h` + `core/include/module.modulemap`,
  implementace `core/crates/salcore/src/ffi.rs`. Handle = neprůhledný ukazatel,
  chyby jako kódy + text, panika jádra se zachycuje (nepřechází přes FFI).
- **UI** (Swift/AppKit) rozvržené podle originálu (help: `main.png`, `panel.png`):
  horní nástrojová lišta, lišta disků (kořen, domov, připojené svazky, FTP/SFTP servery),
  dva panely s prostřední svislou lištou operací, příkazová řádka `cesta>`
  a spodní lišta F-kláves (popisky se mění podle držených Shift/Ctrl/Alt).
  Panel má řádek adresáře (aktivní panel zvýrazněný barvou, tlačítko disku,
  volné místo), sloupce Jméno/Přípona/Velikost/Datum/Čas/Atr, řádek „..“
  (UP-DIR), kurzor oddělený od označení (označené položky červeně) a informační
  řádek. Dialogy: progress se zrušením, správa FTP/SFTP serverů, hledání, interní
  prohlížeč (text/hex/obrázek).

### Struktura projektu

```
core/                       # Rust workspace
  Cargo.toml                # workspace (release: LTO, strip)
  crates/salcore/           # jádro (rlib + cdylib)
    src/lib.rs              # moduly jádra
    src/vfs.rs              # trait Vfs, VfsItem, cesty (join/split/normalize)
    src/local.rs            # lokální disk (std::fs + statfs)
    src/zipfs.rs            # ZIP jako VFS (jen čtení, AES/ZipCrypto s heslem)
    src/tarfs.rs            # TAR/TAR.GZ jako VFS – vlastní parser (ustar,
                            #   GNU longname, PAX; tar.gz sdílená dekompresní
                            #   session pro jednoprůchodové rozbalení)
    src/ftp.rs              # FTP VFS (suppaftp, RETR/STOR streamy, abort)
    src/sftp.rs             # SFTP VFS (ssh2, serializace přístupu zámkem)
    src/mask.rs             # masky ve stylu Salamandera (port myšlenky masks.cpp)
    src/ops.rs              # copy/move/delete mezi VFS, progress, cancel
    src/find.rs             # rekurzivní hledání nad VFS
    src/pack.rs             # vytváření ZIP z položek libovolného VFS
                            #   (bez hesla / AES-256 / ZipCrypto)
    src/error.rs            # SalError + kódy pro FFI
    src/ffi.rs              # C ABI (handle, list, operace, find, pack, probe)
  include/microcommander.h  # C hlavička pro UI (přes module.modulemap)
app/                        # tenké UI pro macOS
  Sources/Core.swift        # Swift obálka nad C ABI (Vfs, operace, progress)
  Sources/Panel.swift       # model panelu: lokace, řádky s „..“, kurzor,
                            #   označení, řazení, rychlé hledání, historie
  Sources/PanelView.swift   # vizuál panelu: řádek adresáře, tabulka, info řádek
  Sources/FileGridView.swift  # režimy zobrazení; mřížka Stručný/Ikony/
                            #   Miniatury/Dlaždice
  Sources/Bars.swift        # nástrojová lišta, disky, prostřední lišta,
                            #   příkazová řádka, lišta F-kláves
  Sources/WindowController.swift  # hlavní okno, příkazy, směrování kláves
  Sources/Dialogs.swift     # progress, správa FTP/SFTP serverů, hledání,
                            #   interní prohlížeč, nabídka disků
  Sources/Servers.swift     # uložené FTP/SFTP servery (UserDefaults),
                            #   hesla v Klíčence, připojení serveru v panelu
  Sources/SelfTest.swift    # self-test UI (SAL_SELFTEST=1)
  Sources/main.swift        # NSApplication, hlavní menu
  Info.plist
tests/main.swift            # end-to-end smoke test FFI (Swift CLI)
Makefile                    # build celé aplikace jedním příkazem
fetch-samandarin.sh         # stáhne původní zdrojáky do samandarin/ (bez .git)
samandarin/                 # původní Windows zdrojáky (reference, nemění se)
```

### Build a spuštění

Vyžaduje Rust (cargo v `~/.cargo/bin`) a Xcode Command Line Tools (swiftc).

```
make            # sestaví jádro (release) i aplikaci: build/MicroCommander.app
make run        # sestaví a spustí aplikaci
make test       # unit testy jádra (cargo test)
make smoke      # end-to-end test FFI vrstvy (Swift CLI binárka)
make selftest   # self-test UI: klávesy, dialogy, F5/F8 (aplikace se sama ukončí)
make clean      # smaže build/
```

Nastavení (režimy zobrazení, pořadí disků, skryté soubory, poloha okna) se ukládá
do předvoleb `com.github.svopex.microcommander`; při prvním spuštění se jednorázově
převezme z dřívější domény `eu.krtkovo.salamander` (z doby názvu Salamander).

Aplikace se spouští jako `build/MicroCommander.app`; knihovna `libsalcore.dylib`
je součástí bundle (`Contents/Frameworks`, načítá se přes `@rpath`).

### Ovládání

Ovládání odpovídá Salamanderu; Ctrl zkratky mají na Macu i variantu s ⌘.
Na klávesnici Macu F-klávesy vyžadují Fn (nebo zapnout „Používat F1, F2 atd.
jako standardní funkční klávesy“). Přehled zobrazí F1.

- **Panely:** ↑↓ PgUp PgDn Home End – pohyb kurzoru; Enter / dvojklik – otevřít
  adresář, archiv (ZIP/TAR/TAR.GZ jako panel) nebo soubor ve výchozí aplikaci;
  ⌫ / „..“ – nadřazený adresář (kurzor se vrátí na adresář, ze kterého se
  přišlo; na kořeni archivu/FTP se lokace zavře); Tab – druhý panel;
  Home / End (fn+← / fn+→, ⌘← / ⌘→) a ⌥↑ / ⌥↓ – první položka (obvykle „..“) /
  poslední položka ve všech režimech zobrazení (i když systém nebo klávesnice
  posílá Home/End jako příkaz začátek/konec dokumentu); funguje i z prázdné
  příkazové řádky, stejně jako PgUp/PgDn;
  ⌥← / ⌥→ – historie; ⌘\ – kořen; ⌘. (⌃.) – poslat aktuální adresář do druhého panelu (přepne se druhý panel);
  ⌘⇧. (⌃⇧.) – převzít adresář z druhého panelu (přepne se aktivní; oba směry fungují
  i v archivu a na FTP/SFTP – panel převezme i zanoření, „..“ vede ven); ⇧F7 / ⌘G / dvojklik na řádek adresáře – zadat cestu
- **Označování:** Space / Insert – označit a posunout; ⇧↑↓, ⇧PgUp/PgDn,
  ⇧Home/End, ⌘klik, ⇧klik; ⌘A / ⌘D – vše / nic; Num + / Num − (⌘= / ⌘−) –
  podle masky; Num * – invertovat. Operace pracují s označenými položkami,
  bez označení s položkou pod kurzorem.
- **Režimy zobrazení** (⌥1–⌥6, menu Zobrazení, tlačítko na liště, kontextové
  menu): Stručný (sloupce jmen, ←/→ přeskakují sloupec), Podrobný (výchozí),
  Ikony, Miniatury (náhledy Quick Look u lokálních souborů), Dlaždice (ikona +
  typ, velikost, datum), Typy (Podrobný se sloupcem Typ). Režim se pamatuje
  zvlášť pro levou a pravou stranu.
- **Skryté soubory:** ⌃H (jako Ctrl+H v Salamanderu) / tlačítko s okem / Zobrazení › Zobrazovat
  skryté soubory – přepíná oba panely a volba se pamatuje. Za skryté se
  považují jména s úvodní tečkou i položky s příznakem UF_HIDDEN (jako Finder,
  např. `~/Library`); informační řádek ukazuje počet skrytých.
- **Rychlé hledání:** psaní písmen skáče na položku podle prefixu, ↑↓ další
  shoda, Escape konec.
- **F-klávesy:** F1 nápověda, F2 přejmenovat, F3 prohlížeč, F4 editor, F5
  kopírovat, F6 přesunout (oba s dialogem cíle), F7 nový adresář, F8 smazat,
  F9 terminál v adresáři, F10 ukončit, F11 FTP/SFTP servery, F12 odpojit /
  zavřít archiv; ⇧F4 nový soubor, ⇧F6 přejmenovat; ⌃F3–⌃F6 řazení podle
  jména/přípony/času/velikosti (opakovaně obrací), ⌃F9 obnovit, ⌃F10 porovnat
  adresáře (označí odlišné soubory); ⌥F1/⌥F2 disk vlevo/vpravo, ⌥F5 zabalit do
  ZIP, ⌥F6 rozbalit do druhého panelu, ⌥F7 hledat, ⌥F10 obsazené místo.
- **Nabídka disků** (⌥F1 levý / ⌥F2 pravý panel, tlačítko disku na řádku
  adresáře): kořen, domov, připojené svazky, **uložené FTP/SFTP servery**
  (výběr serveru ho připojí v daném panelu) a „FTP/SFTP servery…“ (správa);
  kurzor začíná na disku,
  kde panel je. ↑/↓ cyklí (z poslední položky na první a obráceně), Home/End,
  číslice 1–9 vyberou přímo, Enter potvrdí, Escape nebo klik mimo zavře.
  **Pořadí disků** je výchozí Domů, „/“, svazky; mění se v nabídce šipkami
  nahoru/dolů vpravo v řádku, klávesami ⌥↑ / ⌥↓ (⌘↑ / ⌘↓) nebo pravým
  tlačítkem na disku v liště disků (Na první místo / Posunout doleva /
  doprava). Stejně (šipkami v řádku, ⌥↑ / ⌥↓) se mění i **pořadí serverů** –
  disky i servery se přesouvají jen v rámci své skupiny. Pořadí se pamatuje
  a platí pro lištu i nabídku; nově připojené svazky se řadí na konec.
  Nabídka je široká podle nejdelší položky, text je vždy na jednom řádku.
- **FTP/SFTP servery** (F11, tlačítko FTP/SFTP v liště disků, poslední položka
  nabídky disků): seznam libovolného počtu uložených serverů – **+** přidá,
  **−** odebere (po potvrzení), **Duplikovat** vytvoří kopii vybraného serveru
  se všemi nastaveními (i uloženým heslem) s názvem „… (kopie)“, vybraný server se upravuje ve formuláři vpravo
  (název, protokol, server, port, uživatel, ověření). Úpravy se ukládají
  průběžně (přepnutí serveru, Připojit, Zavřít/Escape); Enter nebo dvojklik
  připojí vybraný server v panelu, odkud byl dialog otevřen. Každý panel může
  být připojený k jinému serveru zároveň; F12 spojení zavře. U SFTP volba
  ověření – Heslo / **Soubor s klíčem** / Klíče ze ssh-agenta. Soubor s klíčem
  se předvyplní prvním z `~/.ssh/id_ed25519`, `id_ecdsa`, `id_rsa`; tlačítko
  Vybrat… otevře `~/.ssh` (i skryté soubory). Klíč chráněný heslem aplikace
  pozná sama a vyzve k zadání hesla ke klíči; chyby rozlišují chybné heslo ke
  klíči, klíč odmítnutý serverem a chybějící soubor. Heslo (heslo ke klíči) se
  ukládá jen se zaškrtnutým „Uložit heslo do Klíčenky“ – do macOS Klíčenky
  (služba „MicroCommander FTP/SFTP“), jinak se při připojení z nabídky disků
  vyžádá. Seznam serverů je v předvolbách (`servers`, JSON bez hesel); dříve
  zapamatovaný server z jednoduchého dialogu se při prvním spuštění převezme.
  Neúspěšné připojení nabídne „Upravit server…“, Zrušit v průběhu připojování
  dialog hned zavře.
- **Další:** ⌘R obnovit, ⌘U prohodit panely, ⌘F hledat, klik na záhlaví sloupce
  řadí, pravé tlačítko – kontextové menu (Finder, kopírovat cestu).
- **Příkazová řádka** (⌃Tab): Enter spustí příkaz v login shellu v adresáři
  panelu (výstup v prohlížeči), `cd cesta` mění adresář panelu, ↑↓ historie,
  ⌘↩ v panelu vloží jméno položky, ⌃[ / ⌃] cestu levého/pravého panelu.
- **Zaheslované archivy:** šifrované položky mají v atributech „E“ (info řádek
  „šifrováno“). Při F3/Enter, F5/F6 nebo ⌥F6 ze zaheslovaného ZIP se aplikace
  zeptá na heslo (jednou pro otevřený archiv); při chybném hesle se zeptá
  znovu a operaci zopakuje. ⌥F5 (Zabalit do ZIP) má v dialogu uložení volbu
  šifrování – Bez šifrování / **AES-256** / ZipCrypto – s heslem a potvrzením
  (prázdné nebo neshodné heslo dialog nepustí dál).
- Dialogy: Enter potvrdí, Escape zruší. Při konfliktu v cíli se UI zeptá:
  přepsat vše / přeskočit existující / zrušit.

### Funkční omezení první verze

- bez pluginů (podle zadání)
- archivy jsou jen pro čtení (nové ZIP lze vytvářet přes ⌥F5 / pack_zip)
- šifrování jen u ZIP (TAR šifrování nemá; 7z/RAR nejsou podporované); heslo se
  drží jen v paměti po dobu otevření archivu; AES-256 ZIP neotevře vestavěná
  Archivační utilita macOS (7-Zip, Keka, WinZip, bsdtar ano)
- F3/Enter nad souborem v archivu či na FTP ho nejprve rozbalí do dočasného
  adresáře; F4 a příkazová řádka fungují jen na lokálním disku
- mazání je trvalé (bez koše)
- FTP bez TLS (FTPS není zapojeno)
- SFTP neověřuje klíč serveru proti ~/.ssh/known_hosts (připojí se k jakémukoli
  serveru na dané adrese)
- kořen FTP/SFTP panelu = domovský adresář po přihlášení
- progress hledání hlásí prohledané položky (celkový počet není předem známý)
- vzdálené VFS (FTP/SFTP) nepodporují předměření celkové velikosti přenosu
  (progress běží bez procent)

### Testy

- `make test` – 25 unit testů jádra (masky, cesty, operace, hledání, ZIP,
  TAR plain i TAR.GZ včetně rekurzivního rozbalení, balení s adresářovou
  strukturou, AES-256 a ZipCrypto: bez hesla / chybné / správné heslo)
- `make smoke` – end-to-end test vazby Swift↔Rust: otevření VFS, list, copy,
  mkdir, rename, delete, find, pack ZIP, probe, otevření ZIP, AES-256 ZIP přes
  FFI (kódy chyb hesla) a kompatibilita s libarchive (`bsdtar`) oběma směry:
  náš AES-256 archiv rozbalí bsdtar, AES-256 i ZipCrypto archiv z bsdtar
  přečte jádro
- `make selftest` – UI self-test: aplikace si posílá skutečné klávesové události
  a ověřuje kurzor, Space, Tab, rychlé hledání, F7/F5/F8 dialogy (žádné
  zamrznutí), ⌫ s návratem kurzoru, ⌘U, ⌥F7 a F11 (správa serverů) se zavřením Escapem
  a zaheslovaný AES-256 ZIP (Enter do archivu, F5, chybné → správné heslo),
  Home/End, ⌥↑/⌥↓, ⌃H (skryté soubory), ⌥1/⌥3/⌥6/⌥2 (režimy) se šipkami;
  test otevírá okno aplikace a posílá jí klávesy – při současné práci
  s počítačem může selhat kvůli ztrátě fokusu, pouštějte ho bez zásahů
- `make keycheck` – Home/End, ⌥↑/⌥↓ a systémové příkazy začátek/konec
  dokumentu ve všech šesti režimech s 500 soubory v okně skutečné velikosti
  (kurzor na „..“ / poslední položku a zůstane vidět), cyklení a změna pořadí
  v nabídce disků, uložené FTP/SFTP servery (název, adresa, potřeba hesla,
  uložení do JSON);
  běží bez zobrazení okna, nepřebírá fokus
- diagnostika kláves: `defaults write com.github.svopex.microcommander keyLog -bool YES`
  zapíše každý stisk (kód klávesy, znak, modifikátory, fokus) do
  `~/Library/Logs/MicroCommander/keys.log`; vypnutí `defaults delete com.github.svopex.microcommander keyLog`
- `make sftp-test` – SFTP end-to-end: spustí dočasný `sshd` jen na 127.0.0.1
  (pod uživatelem, vlastní konfigurace, volný port), vygeneruje klíče a ověří
  přihlášení ed25519 bez hesla / s heslem (bez hesla, chybné, správné), RSA PEM,
  ECDSA, ssh-agent, odmítnutý klíč a chybějící soubor, vždy se zápisem, čtením
  a smazáním souboru; totéž přes FFI (Swift). Systémové Vzdálené přihlášení se
  nemění, vše se po testu uklidí
- vývojářský snímek okna: `SAL_SNAPSHOT=/cesta.png build/MicroCommander.app/Contents/MacOS/MicroCommander`
