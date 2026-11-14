# MicroCommander

Dvoupanelový správce souborů pro macOS – přepis Open Salamanderu (bez pluginů)
s jádrem v Rustu a tenkým UI ve Swift/AppKit. Licence GPL-2.0-or-later.

## Prvotni zadani

Prepis aplikaci, zatim bez pluginu, do:
Jádro (souborové operace, virtuální souborové systémy, archivy, FTP/SFTP, hledání) napíšete jednou v Rustu.
Nad ním postavíte tenké UI: Swift/AppKit na Macu, WinUI nebo Win32 na Windows a GTK 4 (přes gtk4-rs) na Linuxu.
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
  traitem `Vfs` – lokální disk, archivy ZIP/TAR/TAR.GZ (jen čtení), FTP (suppaftp;
  pool spojení – každý přenos a příkaz má vlastní řídicí spojení, takže panel
  lze vypisovat i během přenosu; výpis přes MLSD včetně skrytých souborů, na
  starších serverech LIST),
  SFTP (ssh2/libssh2; přihlášení heslem, souborem se soukromým klíčem
  OpenSSH/PEM – ed25519, ECDSA, RSA, i chráněným heslem – nebo klíči
  ze ssh-agenta). Souborové operace (copy/move/delete) pracují mezi libovolnou
  dvojicí VFS streamovaně po 256 KiB blocích, s hlášením průběhu a zrušením.
  Existující adresáře v cíli se slučují. Přesun na jednom lokálním svazku je
  přejmenování (okamžité), jinak se každá položka zkopíruje a její zdroj se
  smaže hned po potvrzeném zápisu; položky přeskočené kvůli existujícímu cíli
  zůstávají ve zdroji. Kopie či přesun do téhož adresáře a adresáře do sebe
  sama se odmítne, po chybě nebo zrušení nezůstane v cíli nedokončený soubor.
  Symbolické odkazy se přenášejí jako odkazy tam, kde to cíl umí (lokální
  disk, SFTP; i při rozbalení TAR), jinak se přenese to, na co ukazují.
  Odkaz na adresář na lokálním disku se v panelu chová jako adresář (řadí se
  mezi adresáře, má ikonu odkazu a Enter do něj vstoupí); kopie, přesun
  a mazání dál pracují s odkazem samotným, ne s jeho cílem, a do Obsazeného
  místa se cíl nepočítá.
  Hledání nad libovolným VFS s maskami ve stylu Salamandera (`*`, `?`, `#`,
  skupiny oddělené `;`, vyloučení za `|`; maska bez `*`, `?` a `.` hledá jména,
  která ji obsahují), volitelně bez podadresářů a s hledáním v obsahu souborů
  (text, HEX, rozlišení velikosti písmen, celá slova, regulární výraz – crate
  `regex`); nečitelné adresáře a soubory se přeskočí a spočítají. Volitelně
  i **hledání v archivech** na lokálním disku (`SAL_FIND_ARCHIVES`): soubor
  s příponou `.zip`, `.jar`, `.tar`, `.tgz` nebo `.tar.gz` se otevře jako VFS
  (formát se ověří podle obsahu) a projde stejnou maskou i hledáním v obsahu;
  nález nese cestu archivu a cestu uvnitř něj. Obsah se v archivu čte v pořadí
  dat (TAR.GZ se tak dekomprimuje jedním průchodem). Vytváření ZIP archivů (`pack_zip`,
  FFI `sal_pack_zip`) včetně adresářové struktury. **Zaheslované ZIP:** čtení
  AES-128/192/256 (WinZip AE-1/AE-2) i ZipCrypto; vytváření s AES-256
  (doporučeno) nebo ZipCrypto. Výpis šifrovaného
  archivu heslo nepotřebuje, heslo se nastavuje na otevřený archiv
  (`sal_vfs_set_password`) a chyby rozlišují „chybí heslo“ / „chybné heslo“.
- **FFI** (C ABI): `core/include/microcommander.h` + `core/include/module.modulemap`,
  implementace `core/crates/salcore/src/ffi.rs`. Handle = neprůhledný ukazatel,
  chyby jako kódy + text, panika jádra se zachycuje (nepřechází přes FFI).
- **UI** (Swift/AppKit) rozvržené podle originálu (help: `main.png`, `panel.png`):
  horní nástrojová lišta, lišta disků (kořen, domov, připojené svazky, FTP/SFTP servery),
  dva panely s prostřední svislou lištou operací (výchozí jen úzký pruh, ikony
  zapne Nastavení), řádek vestavěného terminálu (shell uživatele; ⌘F12 ho
  roztáhne na celé okno)
  a spodní lišta F-kláves (popisky se mění podle držených Shift/Ctrl/Alt/⌘ –
  ukazují jen to, co držený modifikátor s F-klávesou opravdu spustí).
  Oken může být víc (⌘N), každé má vlastní panely i terminál.
  Panel má řádek adresáře (aktivní panel zvýrazněný barvou, tlačítko disku,
  volné místo), sloupce Jméno/Přípona/Velikost/Datum/Čas/Atr, řádek „..“
  (UP-DIR), kurzor oddělený od označení (označené položky červeně) a informační
  řádek. Dialogy: progress se zrušením, správa FTP/SFTP serverů, okno hledání, interní
  prohlížeč (text/hex/obrázek).

### Struktura projektu

```
core/                       # Rust workspace
  Cargo.toml                # workspace (release: LTO, strip)
  crates/salcore/           # jádro (rlib + cdylib)
    src/lib.rs              # moduly jádra
    src/vfs.rs              # trait Vfs, VfsItem, cesty (join/split/normalize)
    src/local.rs            # lokální disk (std::fs + statfs)
    src/archive.rs          # společné pro archivy: index položek podle jména,
                            #   výpis adresáře z indexu, implikované adresáře
    src/zipfs.rs            # ZIP jako VFS (jen čtení, AES/ZipCrypto s heslem;
                            #   archiv a index položek načtené jednou při otevření)
    src/tarfs.rs            # TAR/TAR.GZ jako VFS – vlastní parser (ustar,
                            #   GNU longname, PAX, odkazy, kontrolní součty hlaviček;
                            #   tar.gz sdílená dekompresní session pro
                            #   jednoprůchodové rozbalení)
    src/ftp.rs              # FTP VFS (suppaftp, pool spojení, MLSD/LIST,
                            #   RETR/STOR streamy)
    src/sftp.rs             # SFTP VFS (ssh2, serializace přístupu zámkem)
    src/mask.rs             # masky ve stylu Salamandera (port myšlenky masks.cpp)
    src/ops.rs              # copy/move/delete mezi VFS, progress, cancel,
                            #   přesun přejmenováním, kontrola cíle
    src/find.rs             # rekurzivní hledání nad VFS (maska, podadresáře,
                            #   obsah souborů: text/HEX/celá slova/regex)
    src/pack.rs             # vytváření ZIP z položek libovolného VFS
                            #   (bez hesla / AES-256 / ZipCrypto)
    src/error.rs            # SalError + kódy pro FFI
    src/ffi.rs              # C ABI (handle, list, operace, find, pack, probe, masky)
  include/microcommander.h  # C hlavička pro UI (přes module.modulemap)
app/                        # tenké UI pro macOS
  Sources/Core.swift        # Swift obálka nad C ABI (Vfs, operace, progress)
  Sources/Panel.swift       # model panelu: lokace, řádky s „..“, kurzor,
                            #   označení, řazení, rychlé hledání, historie
  Sources/PanelView.swift   # vizuál panelu: řádek adresáře, tabulka, info řádek,
                            #   přetahování souborů ven i dovnitř
  Sources/FileGridView.swift  # režimy zobrazení; mřížka Stručný/Ikony/
                            #   Miniatury/Dlaždice
  Sources/Bars.swift        # nástrojová lišta, disky, prostřední lišta,
                            #   lišta F-kláves
  Sources/TerminalPane.swift  # vestavěný terminál (SwiftTerm): shell
                            #   v pseudoterminálu, řádek / celé okno,
                            #   adresář shellu ↔ aktivní panel, integrace zsh
  Sources/WindowController.swift  # hlavní okno, příkazy, směrování kláves
  Sources/Dialogs.swift     # progress, správa FTP/SFTP serverů,
                            #   interní prohlížeč, nabídka disků, dialog
                            #   operací (cíl kopie/přesunu, potvrzení mazání)
  Sources/Attributes.swift  # dialog Změnit atributy (⌘F2 / ⌃F2)
  Sources/DriveInfo.swift   # dialog Informace o jednotce (⌘F1 / ⌃F1)
  Sources/OccupiedSpace.swift  # dialog Obsazené místo (⌥F10 / ⌃Q)
  Sources/FindWindow.swift  # okno Vyhledat soubory a adresáře (⌃F/⌥F7)
                            #   a dialog Upřesnit možnosti
  Sources/Servers.swift     # uložené FTP/SFTP servery (UserDefaults),
                            #   hesla v Klíčence, připojení serveru v panelu
  Sources/Places.swift      # místa nabídky disků (pořadí, skrytí, vlastní
                            #   adresáře, zkratky ⌘0–⌘9) a dialog Upravit
                            #   nabídku disků
  Sources/Settings.swift    # Nastavení (⌘,): kategorie, volby v UserDefaults,
                            #   editor klávesových zkratek, Obnovit vše,
                            #   uložení nastavení do souboru a načtení z něj
  Sources/ColorScheme.swift # barevná schémata panelů (macOS + schémata
                            #   Salamandera), barvy položek a kurzoru
  Sources/KeyBindings.swift # klávesové zkratky příkazů (výchozí + uživatelské)
  Sources/SelfTest.swift    # self-test UI (SAL_SELFTEST=1)
  Sources/main.swift        # NSApplication, hlavní menu
  Info.plist
  AppIcon.icns              # ikona aplikace (generuje `make icon`)
tools/make-icon.swift       # vykreslí ikonu: oranžový disk s tlapkou mloka
                            #   ve stylu Salamandera na macOS dlaždici
tests/main.swift            # end-to-end smoke test FFI (Swift CLI)
tests/sftp_test.sh          # SFTP end-to-end proti dočasnému sshd (make sftp-test)
Makefile                    # build celé aplikace jedním příkazem
fetch-samandarin.sh         # stáhne původní zdrojáky do samandarin/ (bez .git)
fetch-swiftterm.sh          # stáhne SwiftTerm v připnuté verzi do vendor/
vendor/SwiftTerm/           # zdrojáky emulátoru terminálu (MIT; mimo repozitář,
                            #   stáhnou se při prvním `make`)
CODESIGNING.md              # vlastní certifikát pro podpis (trvalá oprávnění macOS)
samandarin/                 # původní Windows zdrojáky (reference, nemění se)
```

### Build a spuštění

Vyžaduje Rust (cargo v `~/.cargo/bin`) a Xcode Command Line Tools (swiftc).
Aplikace se sestavuje pro macOS 13 a novější (Makefile bere minimum
z `LSMinimumSystemVersion` v `app/Info.plist`).

Vestavěný terminál používá knihovnu [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(licence MIT). První `make` si její zdrojáky stáhne z GitHubu do `vendor/SwiftTerm`
(verze připnutá tagem i commitem v Makefile, skript `fetch-swiftterm.sh`)
a přeloží je přes `swiftc` jako statickou knihovnu do `build/`; další sestavení
už síť nepotřebují. Licence knihovny se kopíruje do balíčku aplikace
(`Contents/Resources/SwiftTerm-LICENSE.txt`).

```
make            # sestaví jádro (release) i aplikaci: build/MicroCommander.app
make run        # sestaví a spustí aplikaci
make icon       # znovu vykreslí ikonu do app/AppIcon.icns (jen při změně návrhu)
make test       # unit testy jádra (cargo test)
make smoke      # end-to-end test FFI vrstvy (Swift CLI binárka)
make selftest   # self-test UI: klávesy, dialogy, F5/F8 (aplikace se sama ukončí)
make clean      # smaže build/
```

Nastavení (režimy zobrazení, pořadí disků, skryté soubory, poloha okna, adresáře
panelů – po dalším spuštění se otevřou stejné adresáře; z archivu či FTP nejbližší
lokální adresář) se ukládá
do předvoleb `com.github.svopex.microcommander`.

**Podpis:** `make` podepíše aplikaci certifikátem `MicroCommander Dev` z klíčenky
(pokud existuje), aby macOS po každém buildu znovu nežádal o přístup ke složkám
(Stahování apod.). Vytvoření certifikátu popisuje [CODESIGNING.md](CODESIGNING.md);
bez něj zůstane ad-hoc podpis.

Aplikace se spouští jako `build/MicroCommander.app`; knihovna `libsalcore.dylib`
je součástí bundle (`Contents/Frameworks`, načítá se přes `@rpath`).

### Ovládání

Ovládání odpovídá Salamanderu; Ctrl zkratky mají na Macu i variantu s ⌘.
Na klávesnici Macu F-klávesy vyžadují Fn (nebo zapnout „Používat F1, F2 atd.
jako standardní funkční klávesy“). Přehled zobrazí F1.

- **Panely:** ↑↓ PgUp PgDn Home End – pohyb kurzoru; Enter / dvojklik – otevřít
  adresář, archiv (ZIP/TAR/TAR.GZ jako panel; pozná se podle obsahu, samostatný
  `.gz` bez TAR uvnitř archiv není) nebo soubor ve výchozí aplikaci;
  **spustitelný shell skript** (právo `+x` a shebang `sh`/`bash`/`zsh`/`dash`/`ksh`,
  i přes `/usr/bin/env`; přípona nerozhoduje) Enter spustí ve vestavěném
  terminálu v adresáři panelu (terminál se roztáhne na celé okno, aby byl
  vidět výstup) – skript bez `+x` nebo bez shebangu se jen otevře;
  **⌘Enter** – spustit / otevřít systémově bez vstupu dovnitř (aplikace `.app`
  se spustí, archiv se otevře ve výchozí aplikaci, adresář ve Finderu, skript
  se shebangem se otevře podle přípony – bez přípony v textovém editoru;
  z archivu či FTP se soubor nejdřív rozbalí do dočasného adresáře);
  ⌫ / „..“ – nadřazený adresář (kurzor se vrátí na adresář, ze kterého se
  přišlo; na kořeni archivu/FTP se lokace zavře); Tab – druhý panel;
  Home / End (fn+← / fn+→, ⌘← / ⌘→) a ⌥↑ / ⌥↓ – první položka (obvykle „..“) /
  poslední položka ve všech režimech zobrazení (i když systém nebo klávesnice
  posílá Home/End jako příkaz začátek/konec dokumentu); PgUp/PgDn listují
  panelem i z řádku terminálu;
  ⌥← / ⌥→ – historie; ⌘\ – kořen; ⌘. (⌃.) – poslat aktuální adresář do druhého panelu (přepne se druhý panel);
  ⌘⇧. (⌃⇧.) – převzít adresář z druhého panelu (přepne se aktivní; oba směry fungují
  i v archivu a na FTP/SFTP – panel převezme i zanoření, „..“ vede ven); ⇧F7 / ⌘G / dvojklik na řádek adresáře – zadat cestu
  (v archivu a na serveru cestu uvnitř něj); historie ⌥← / ⌥→ si pamatuje i zanoření do archivu
  či serveru, po jeho zavření (F12, „..“ na kořeni) se kroky do něj zahodí a spojení se uzavře;
  pravé tlačítko na řádku adresáře – Kopírovat cestu do schránky / Změnit adresář…;
  ⌥⌘C (Úpravy › Kopírovat cestu adresáře, ⌃⌥Insert) – cesta aktuálního adresáře
  aktivního panelu do schránky (u archivu/FTP tak, jak ji ukazuje řádek adresáře)
- **Označování:** Space / Insert – označit a posunout; ⇧↑↓, ⇧PgUp/PgDn,
  ⇧Home/End, ⌘klik, ⇧klik; ⌘A – označit vše (opakovaný stisk označení zruší;
  adresáře podle Nastavení, výchozí i adresáře), ⌘D – nic; Num + / Num − (⌘= / ⌘−) –
  podle masky (stejné masky jako při hledání: `*`, `?`, `#`, skupiny `;`,
  vyloučení za `|`); Num * – invertovat (adresáře podle Nastavení). Operace pracují s označenými položkami,
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
- **F-klávesy:** F1 nápověda, F2 přejmenovat (přímo v panelu bez dialogu:
  předvybrané jméno bez přípony, Enter potvrdí, Escape zruší, klik jinam
  potvrdí; jméno jiné existující položky se odmítne), F3 prohlížeč, F4 editor, F5
  kopírovat, F6 přesunout (oba s dialogem cíle), F7 nový adresář, F8 / Delete
  (i ⌘⌫) smazat do koše, ⇧F8 / ⌘F8 / ⇧Delete smazat trvale bez koše (v archivu,
  na FTP/SFTP a na discích bez koše – např. pCloud Drive nebo svazek Time
  Machine – koš není, maže se vždy trvale a potvrzení to uvede; v okně Hledat
  se u výběru z více disků přesune do koše, co jde, a trvale se smaže jen to,
  co leží na disku bez koše; dotazy na cíl,
  potvrzení mazání i konflikt existujících cílů jsou dialogy ve stylu
  Salamandera, stejné jako Informace o jednotce: text, vstupní pole, dole
  tlačítka; Enter potvrdí, Escape zruší),
  F9 aplikace Terminal v adresáři panelu (samostatné okno vedle vestavěného
  terminálu), F10 ukončit, F11 FTP/SFTP servery, F12 odpojit /
  zavřít archiv, **⌘F12 vestavěný terminál na celé okno a zpět**; ⇧F4 nový soubor, ⇧F6 přejmenovat; ⌘F1 / ⌃F1 informace o
  jednotce; **⌘F2 / ⌃F2 změnit atributy**
  (dialog podle Salamandera: Jen pro čtení a Skrytý třístavově – smíšený stav
  = neměnit, změna data a času Změněno / Vytvořeno / Otevřeno, Nastavit
  aktuální, Včetně podadresářů; označené položky, jinak položka pod kurzorem;
  jen lokální disk; Windows atributy jsou vidět, ale nedostupné); ⌃F3–⌃F6 řazení podle
  jména/přípony/času/velikosti (opakovaně obrací), ⌃F9 obnovit, ⌃F10 porovnat
  adresáře (označí odlišné soubory; shodu ohlásí); ⌥F1/⌥F2 disk vlevo/vpravo, ⌥F5 zabalit do
  ZIP, ⌥F6 rozbalit do druhého panelu, ⌥F7 hledat (také ⌃F), ⌥F10 obsazené místo
  (také ⌃Q; dialog ve stylu Informací o jednotce: umístění, položka nebo počet
  označených položek, velikost v bajtech i zaokrouhleně, počty souborů
  a adresářů; hodnoty lze označit a zkopírovat, zavírá se Enterem nebo Escape;
  u označených adresářů se během výpočtu postupně místo „DIR“ ve sloupci
  Velikost zobrazí jejich spočítaná velikost, která zůstává do změny adresáře;
  nepřístupné adresáře se přeskočí a výpočet pokračuje). Sloupec Velikost
  se rozšíří, aby se vešlo celé nejdelší číslo (velké soubory i spočítané
  adresáře), v jiném adresáři se vrátí na výchozí šířku.
- **Vlastnosti a oprávnění** (jako Alt+Enter a Ctrl+P v Salamanderu): ⌥↩ / ⌘I
  (Soubory › Vlastnosti…, kontextové menu) a ⌃P (Soubory › Oprávnění…) otevřou
  okno Informace z Finderu pro označené položky (jinak pro položku pod
  kurzorem) – Otevřít v aplikaci, Sdílení a oprávnění atd. Otevírá se systémovou
  službou Finderu „Zobrazit informace“ (bez AppleScriptu a dotazu na povolení);
  je-li služba vypnutá, položky se vyberou ve Finderu (pak ⌘I). Víc než 20 oken
  se otevře až po potvrzení. Jen lokální disk.
- **Informace o jednotce** (jako Ctrl+F1 v Salamanderu): ⌘F1 / ⌃F1 (Panel ›
  Informace o jednotce…) ukáže údaje o svazku, na kterém leží adresář aktivního
  panelu (u archivu svazek se souborem archivu): název svazku, přípojný bod,
  zařízení (u síťové jednotky adresa sdílení), UUID svazku, typ (interní /
  externí / výměnný disk, síťová jednotka), využité a volné místo a kapacitu
  v bajtech i zaokrouhleně s koláčovým grafem, velikost a počty bloků, systém
  souborů a jeho příznaky (velká a malá písmena, šifrování, žurnál, zhuštěné
  soubory, odkazy, ACL…). Hodnoty lze označit a zkopírovat; dialog je jen pro
  čtení, zavírá se Enterem nebo Escape. Jen lokální disk (ne FTP/SFTP).
- **Nabídka disků** (⌥F1 levý / ⌥F2 pravý panel, tlačítko disku na řádku
  adresáře): kořen, domov, připojené svazky, **vlastní adresáře** a **uložené
  FTP/SFTP servery** (výběr serveru ho připojí v daném panelu), na konci
  „FTP/SFTP servery…“ (správa) a „Upravit nabídku disků…“; kurzor začíná na
  místě, kde panel je. ↑/↓ cyklí (z poslední položky na první a obráceně),
  Home/End, číslice 1–9 (horní řada i numerická klávesnice) položku rovnou
  vyberou a otevřou, Enter potvrdí, Escape nebo klik mimo
  zavře. **Pořadí** je jedno společné pro všechny položky (disky, adresáře
  i servery lze libovolně promíchat); výchozí Domů, „/“, svazky, adresáře,
  servery. Mění se šipkami nahoru/dolů vpravo v řádku, klávesami ⌥↑ / ⌥↓
  (⌘↑ / ⌘↓), v dialogu Upravit nabídku disků nebo pravým tlačítkem na liště
  disků (Na první místo / Posunout doleva / doprava / Skrýt). Pořadí se
  pamatuje a platí pro lištu i nabídku; nová místa (svazek, adresář, server)
  se řadí na konec. Nabídka je široká podle nejdelší položky, text je vždy na
  jednom řádku.
- **Upravit nabídku disků** (menu Panel, poslední položka nabídky disků,
  pravé tlačítko na liště disků): všechna místa v pořadí nabídky; zaškrtnutí
  „Zobrazit“ = položka je v nabídce a na liště disků, odškrtnutá je **skrytá**
  (i disk nebo server). **Přidat adresář…** přidá vlastní adresáře (i více
  najednou), **Odebrat** je smaže, dvojklik na název vlastního adresáře ho
  přejmenuje; pořadí se mění **přetažením myší** nebo šipkami pro vybranou
  položku. Sloupec **Zkratka** přiřadí místu ⌘0–⌘9 (stisk v hlavním okně
  otevře místo v aktivním panelu, i skryté; stejná zkratka se jinému místu
  odebere; zkratka je vidět i v nabídce disků). Změny platí hned. Lišta disků
  ukazuje disky a vlastní adresáře (servery jen v nabídce). Uložení
  v předvolbách: `placesOrder` (pořadí), `hiddenPlaces` (skryté),
  `customFolders` (adresáře), `placeShortcuts` (zkratky).
- **Nastavení** (⌘, v aplikačním menu) ve stylu dialogu Konfigurace
  Salamandera: vlevo kategorie, vpravo stránka s nadpisem, změny se uloží až
  tlačítkem **OK** (Zrušit je zahodí).
  - **Obecné:** Před ukončením uložit adresáře panelů (výchozí zapnuto,
    předvolba `savePanelPaths`; vypnuté = po spuštění domov a „/“).
  - **Panely:** Zobrazovat skryté soubory a adresáře (jako ⌃H, výchozí vypnuto,
    předvolba `showHiddenFiles`); Označit vše (⌘A)
    a Invertovat označení i s adresáři – výchozí zapnuto (vypnuté = ⌘A označí
    a Num * invertuje jen soubory), zrušení označení platí vždy i pro adresáře
    (předvolba `selectAllIncludesDirs`).
  - **Barvy:** barevné schéma panelů podle Konfigurace › Barvy Salamandera
    (předvolba `colorScheme`): **macOS – podle systému** (výchozí; systémové
    barvy, světlý/tmavý režim podle macOS), **macOS – tmavé** (systémové barvy
    a vynucený tmavý režim celé aplikace) a schémata převzatá z Open Salamanderu se světlým okolím panelů –
    **Open Salamander** (bílé pozadí, označené červeně, šedý kurzor), **Windows
    Explorer** (označené bíle na tmavě modré), **Norton Commander** (azurová
    na tmavě modré, označené žlutě, tyrkysový kurzor) a **DOS Navigator** (bílá
    na tmavě šedé). Schéma barví položky, kurzor, označení a řádek adresáře
    v tabulce i mřížce.
  - **Hlavní okno:** Zobrazovat lištu příkazů mezi panely – výchozí vypnuto,
    mezi panely je jen úzký dělicí pruh jako v Salamanderu (`showMiddleBar`).
  - **Klávesnice:** klávesové zkratky všech příkazů (tabulka Příkaz / Klávesové
    zkratky s hledáním). Přidat zkratku… (nebo dvojklik) zaznamená stisk klávesy –
    zkratka používaná jiným příkazem se po potvrzení přeřadí, písmeno bez
    modifikátoru se odmítne (blokovalo by rychlé hledání); Odebrat zkratku…,
    Výchozí (vybraný příkaz) a Obnovit zkratky (všechny příkazy). Podle zkratek se řídí obsluha kláves,
    zkratky v menu i popisky lišty F-kláves. V textových polích (úprava
    cesty) se nepoužijí zkratky potřebné pro psaní (⌘A/⌘C/⌘V/⌘X/⌘Z,
    ⌃písmeno, šipky); terminál si nechává ještě víc kláves (viz Vestavěný
    terminál). Pevné zůstávají navigační klávesy (šipky, Enter, Tab,
    mezerník, psaní), ⌘Enter / ⌃Enter, ⌘Tab a ⌘0–⌘9 míst. Uloží se jen změny
    oproti výchozím (předvolba `keyBindings`).
  - **Obnovit vše** (vlevo dole): nastaví všechny volby na všech stránkách
    i klávesové zkratky na výchozí hodnoty.
  - **Uložit do souboru… / Načíst ze souboru…** (vlevo dole): nastavení z dialogu
    (všechny stránky včetně klávesových zkratek) se uloží do souboru JSON
    (výchozí název `MicroCommander-nastaveni.json`) a dá se z něj znovu načíst,
    např. na jiném počítači. Soubor má značku formátu a verzi; klíče odpovídají
    předvolbám (`savePanelPaths`, `showHiddenFiles`, `selectAllIncludesDirs`,
    `showMiddleBar`, `colorScheme`, `keyBindings`). Chybějící volba dostane
    výchozí hodnotu, cizí JSON a soubor z novější verze se odmítnou, zkratky
    neznámých příkazů a nepřiřaditelné klávesy se přeskočí. Ukládá se, co
    dialog právě ukazuje (i rozpracované změny). Obnovit vše i Načíst ze
    souboru… jen naplní dialog – platit začnou až tlačítkem **OK**, Zrušit
    ponechá dosavadní nastavení. Mimo soubor zůstávají nabídka disků, uložené
    servery, režimy zobrazení, poloha okna a historie hledání.
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
  vyžádá. Seznam serverů je v předvolbách (`servers`, JSON bez hesel).
  Neúspěšné připojení nabídne „Upravit server…“, Zrušit v průběhu připojování
  dialog hned zavře.
- **Vyhledat soubory a adresáře** (⌃F, ⌘F, ⌥F7 – podle dialogu Find
  Salamandera): nemodální okno, lze jich otevřít víc a během hledání pracovat
  v panelech. **Název** (masky, poprvé `*.*`; maska bez `*`, `?` a `.` hledá
  jména obsahující text – `dog` najde `hotdog.jpg`, `dog.` jen `dog`), **Hledat
  v** (předvyplněno adresářem panelu, víc adresářů oddělených `;`, **Přidat** ›
  Procházet… / Všechny místní jednotky), **Včetně podadresářů**, **Hledat
  v souboru** – rozbalí část **Obsahující** s volbami Šestnáctkový režim
  (`01 02 "text" 00`), Rozlišovat malá a velká písmena, Celá slova a Regulární
  výraz (vyhodnocuje se po řádcích, konec řádku je LF i CRLF; tlačítko › vkládá konstrukce),
  **Upřesnit…** (atributy R/H/E/adresář třístavově, velikost nejméně/nejvýše,
  změněno během / od–do). Pole mají historii. **Najít** (Enter, ⌃F) se během
  hledání mění na **Zastavit** (Escape, ⌥P); šipka vedle nabízí Vytřídit –
  Průnik (⌃I), Vytřídit – Odečíst (⌃S) a Připojit k nalezeným položkám (⌃W).
  Titulek ukazuje hledanou masku, stavový řádek prohledávaný adresář, po
  skončení označení (velikost, počty), „Zastaveno.“, „Nenalezeny žádné soubory
  nebo adresáře.“ a počet přeskočených nečitelných položek. Seznam **Nalezené
  položky: (N)** se sloupci Název, Cesta, Velikost, Datum, Čas, Atributy (klik
  na záhlaví řadí, znovu obrací; adresáře nahoře, pokud není Možnosti › Řadit
  soubory a adresáře dohromady). V seznamu: Enter otevřít (adresář v panelu),
  ⇧Enter otevřít všechny označené, mezerník Ukázat (panel přejde na položku),
  F3 zobrazit, F4 upravit, F8 / Delete odstranit do koše, ⇧F8 / ⇧Delete
  trvale, ⌃H skrýt, ⌃⇧H skrýt duplicity,
  ⌘C / ⌃C kopírovat soubory do schránky (pro panel i Finder), ⌘X vyjmout
  (⌘V v panelu je pak přesune), ⌥⌘C / ⌥⌘⇧C /
  ⌃⌘C cestu + název / název / cestu jako text (i ⌥Insert varianty), ⌘A vybrat vše.
  Dokud je okno aktivní, hlavní menu nahradí menu dialogu (Soubory, Příkazy,
  Upravit, Zobrazit, Možnosti). V archivu či na FTP/SFTP se hledá ve VFS panelu.
  **Hledat v archivech** (jen při hledání na lokálním disku, předvolba
  `findArchives`): prohledá i obsah archivů ZIP, TAR a TAR.GZ – soubory
  s příponou `.zip`, `.jar`, `.tar`, `.tgz`, `.tar.gz` – jménem i volbou Hledat
  v souboru. Archiv se chová jako adresář: sloupec Cesta ukazuje cestu archivu
  a cestu uvnitř, podadresáře archivu se řídí volbou Včetně podadresářů.
  Položku z archivu lze Ukázat (panel vstoupí do archivu, „..“ vede zpět
  k jeho souboru), Otevřít a Zobrazit (rozbalí se do dočasného adresáře, na
  heslo se zeptá až zde); Zobrazit ve Finderu ukáže soubor archivu. Upravit,
  Odstranit a kopírování souborů do schránky pro ni nejsou (archivy jsou jen
  pro čtení). Při hledání v obsahu se zaheslované soubory přeskočí a započítají
  mezi nečitelné položky stejně jako poškozený archiv; archiv uvnitř archivu
  se neotevírá. Velké archivy hledání zpomalí – každý se musí otevřít a u TAR.GZ
  celý dekomprimovat.
  Nastavení a historie: předvolby `find*` (`findNamedHistory`,
  `findLookInHistory`, `findContainingHistory`, `findAdvanced`, …).
- **Schránka souborů** (⌘C / ⌘X / ⌘V, i ⌃C / ⌃X / ⌃V; menu Úpravy, kontextové
  menu panelu; zkratky jdou změnit v Nastavení › Klávesnice): ⌘C zkopíruje
  označené položky (jinak položku pod kurzorem) do systémové schránky jako
  soubory – vložit je lze v druhém panelu, v jiném okně i ve Finderu a naopak
  soubory zkopírované ve Finderu jdou vložit do panelu. ⌘V vloží soubory ze
  schránky do adresáře aktivního panelu (i na FTP/SFTP server; při konfliktu se
  zeptá přepsat / přeskočit); po ⌘X (Vyjmout) je vložení přesune. Vložení do
  adresáře, kde položka už leží, vytvoří duplikát „jméno kopie.přípona“
  („kopie 2“, …). Do schránky jdou jen položky z lokálního disku (ne z archivu
  či FTP/SFTP). V textových polích a v terminálu tytéž klávesy dál pracují
  s textem.
- **Přetažení myší ven z aplikace:** položku (nebo všechny označené, pokud se
  táhne za označenou) lze přetáhnout do Finderu, Zpráv (iMessage), Mailu
  a dalších aplikací ve všech režimech zobrazení; tažení začne po posunu myši
  o pár bodů. Platí zvyklosti macOS a rozhoduje cíl: Finder na stejném disku
  soubory přesune a se stisknutým ⌥ (Option) zkopíruje, na jiný disk je
  zkopíruje a s ⌘ přesune, s ⌃ vytvoří odkaz; puštěním na Koš v Docku se
  přesunou do koše. Tažení se stisknutým ⌘ označení položek nemění. Aby se
  kurzor u cíle (zelené plus = kopie) po stisku či puštění klávesy změnil hned,
  i když myš stojí, vloží panel při změně kláves do fronty událostí umělé
  nepatrné pohnutí myší (bez něj se kurzor měnil až s dalším pohybem). Jen
  soubory z lokálního disku (ne z archivu či FTP/SFTP).
- **Přetažení myší mezi panely:** položky lze přetáhnout do druhého panelu
  (i do panelu jiného okna) se stejnými pravidly jako ve Finderu: na stejném
  disku se přesunou, s ⌥ zkopírují; na jiný disk nebo na FTP/SFTP server se
  zkopírují, s ⌘ přesunou (kurzor se zeleným plus = kopie). Při konfliktu se
  zeptá přepsat / přeskočit. Zdrojem může být jen lokální disk; do téhož
  adresáře se netáhne.
- **Přetažení myší do panelu:** pro soubory a adresáře přetažené z jiné
  aplikace (Finder a další) do adresáře panelu, nad kterým se pustí, platí
  totéž: ze stejného disku se přesunou, s ⌥ zkopírují; z jiného disku (a na
  FTP/SFTP server) se zkopírují, s ⌘ přesunou. Přijímají se i přislíbené
  soubory (příloha z Mailu, fotka z Fotek, obrázek z prohlížeče) – ty zapisuje
  zdrojová aplikace, proto jen jako kopie do adresáře na lokálním disku. Do
  archivu přetáhnout nelze (je jen pro čtení).
  U souboru přetaženého (nebo vloženého ze schránky) ze složky, kterou macOS
  nedovolí vypsat – typicky z Koše bez Plného přístupu k disku – se čte jen
  soubor sám, složka se nevypisuje; odepře-li systém i soubor, hlášení poradí
  povolit MicroCommander v Nastavení systému › Soukromí a zabezpečení › Plný
  přístup k disku.
- **Další:** ⌘R obnovit, ⌘U prohodit panely, klik na záhlaví sloupce
  řadí, pravé tlačítko – kontextové menu (schránka souborů, operace, Zobrazit
  ve Finderu, Kopírovat cestu; na položce „..“ platí poslední dvě pro adresář
  panelu – Finder ho otevře v okně).
- **Vestavěný terminál** (místo dřívější příkazové řádky): pod panely je jeden
  řádek skutečného terminálu s login shellem uživatele (`$SHELL`, prompt
  shellu, historie a doplňování shellu, barvy, interaktivní programy, dotazy
  na heslo). **⌘F12** (Příkazy › Terminál na celé okno) ho roztáhne na celou
  plochu okna pod nástrojovou lištou – panely a lišta disků se skryjí – a druhý
  stisk vrátí jeden řádek. Terminál má pořád velikost celé plochy, v řádku je
  z něj jen vidět řádek s kurzorem: výstup příkazu spuštěného z řádku je po
  ⌘F12 vidět celý a programy mají správné rozměry.
  - **Fokus:** ⌃Tab (⌘Tab) nebo klik přepne mezi panelem a řádkem terminálu.
    V řádku patří aplikaci F-klávesy a zkratky s ⌘ (F5 kopíruje i z terminálu),
    PgUp/PgDn listují panelem; vše ostatní dostane shell (Tab doplňuje, šipky
    listují historií, ⌃C, ⌃R…, ⌥ píše znaky české klávesnice). V terminálu
    přes celé okno dostane program všechny klávesy včetně F-kláves (mc, htop,
    vim) – aplikaci zůstává jen ⌘F12, zkratky záložek terminálu a ⌘N; příkaz
    nad panely zvolený z menu
    nebo tlačítkem lišty nejdřív vrátí panely.
  - **Adresář:** shell jde za aktivním panelem – po změně adresáře (i přepnutí
    panelu Tabem) aplikace do nečinného shellu s prázdným řádkem napíše `cd`
    (začíná mezerou, takže nejde do historie, a po sobě svůj řádek smaže);
    běží-li v terminálu program nebo je na řádku rozepsaný příkaz, počká se.
    Naopak `cd` v terminálu přesune aktivní panel a po doběhnutí každého
    příkazu se oba panely obnoví. V archivu a na FTP/SFTP zůstává shell
    v posledním lokálním adresáři.
  - **⌃↩** vloží na řádek terminálu jméno položky pod kurzorem a předá mu
    fokus – soubor na prázdném řádku jako `./jméno` (Enter ho rovnou spustí),
    jinak jako argument; je-li shell v jiném adresáři než panel, vloží se celá
    cesta. ⌃[ / ⌃] vloží cestu levého/pravého panelu, Escape v panelu smaže
    rozepsaný řádek terminálu.
  - Shell, který skončí (`exit`, ⌃D), se spustí znovu v adresáři aktivního
    panelu. Barvy terminálu se řídí barevným schématem panelů. **zsh** dostane
    přes `ZDOTDIR` integrační `.zshenv` (uložený v
    `~/Library/Application Support/MicroCommander/zsh`), který vrátí původní
    `ZDOTDIR`, načte váš `.zshenv` a před promptem zapne `HIST_IGNORE_SPACE`
    a ohlásí adresář (OSC 7, kvůli cestám přes symbolické odkazy); bash má
    `HISTCONTROL=ignoreboth`, pokud ho prostředí nenastavuje jinak.
  - **Záložky:** ⌘T (Příkazy › Nová záložka terminálu, ikona na nástrojové
    liště) přidá další terminál s vlastním shellem v adresáři aktivního
    panelu. S jedinou záložkou vypadá terminál jako dřív; teprve se dvěma
    a více se nad ním objeví úzká lišta záložek (pořadí a adresář shellu,
    klik vybere, × zavře, + přidá) – pod panely i v celém okně. ⌥⌘→ / ⌥⌘←
    přepínají záložky, ⇧⌘W zavře vybranou (i `exit` v jejím shellu); poslední
    záložka zůstává. Za panelem jde a panel vede jen vybraná záložka, shelly
    ostatních běží dál na pozadí.
  - Kurzor terminálu trvale svítí (neblikající blok).
  - F9 dál otevírá aplikaci Terminal v adresáři panelu.
- **Více oken:** ⌘N (Soubory › Nové okno, Okno › Nové okno, ikona na nástrojové
  liště, také nabídka ikony v Docku) otevře další
  hlavní okno ve stejných adresářích jako to aktuální; každé okno má vlastní
  panely, připojení i terminál. Příkazy z menu provádí naposledy aktivní okno,
  přepínat mezi nimi jde v menu Okno (⌘W okno zavře, poslední zavřené okno
  ukončí aplikaci). Skryté soubory, zkratky a barvy platí pro všechna okna;
  polohu si pamatuje první okno a pro příští spuštění se ukládají adresáře
  naposledy aktivního (zavíraného) okna.
- **Zaheslované archivy:** šifrované položky mají v atributech „E“ (info řádek
  „šifrováno“). Při F3/Enter, F5/F6 nebo ⌥F6 ze zaheslovaného ZIP se aplikace
  zeptá na heslo (jednou pro otevřený archiv); při chybném hesle se zeptá
  znovu a operaci zopakuje. ⌥F5 (Zabalit do ZIP) má v dialogu uložení volbu
  šifrování – Bez šifrování / **AES-256** / ZipCrypto – s heslem a potvrzením
  (prázdné nebo neshodné heslo dialog nepustí dál).
- Dialogy: Enter potvrdí, Escape zruší. Všechna hlášení a dotazy (chyby,
  upozornění, potvrzení, dotaz na heslo, O aplikaci) mají vlastní vzhled
  aplikace ve stylu Salamandera – ikona, tučný nadpis, text a tlačítka uprostřed –
  místo systémového okna; zobrazují se jako sheet nad oknem, ze kterého vzešly.
  Systémové zůstávají jen dialogy výběru souboru. Při konfliktu v cíli se UI zeptá:
  přepsat vše / přeskočit existující / zrušit (adresáře se slučují; při přesunu
  přeskočené položky zůstanou ve zdroji). Cílem nemůže být zdrojový adresář
  ani přenášený adresář sám. Dialog průběhu ukazuje u přenosů bajty a procenta,
  u mazání, počítání velikosti a změny atributů počet položek.

### Funkční omezení první verze

- bez pluginů (podle zadání)
- archivy jsou jen pro čtení (nové ZIP lze vytvářet přes ⌥F5 / pack_zip);
  symbolické odkazy uvnitř ZIP se čtou jako soubor s cílem odkazu
- šifrování jen u ZIP (TAR šifrování nemá; 7z/RAR nejsou podporované); heslo se
  drží jen v paměti po dobu otevření archivu; AES-256 ZIP neotevře vestavěná
  Archivační utilita macOS (7-Zip, Keka, WinZip, bsdtar ano)
- F3/Enter nad souborem v archivu či na FTP ho nejprve rozbalí do dočasného
  adresáře (smaže se při ukončení aplikace, zbytky po pádu při dalším
  spuštění); F4 funguje jen na lokálním disku a terminál zůstává v posledním
  lokálním adresáři
- koš funguje jen na lokálním disku, který koš má; v archivu, na FTP/SFTP a na
  discích bez koše (pCloud Drive, svazek Time Machine…) je mazání trvalé
- FTP bez TLS (FTPS není zapojeno)
- SFTP neověřuje klíč serveru proti ~/.ssh/known_hosts (připojí se k jakémukoli
  serveru na dané adrese)
- kořen FTP/SFTP panelu = domovský adresář po přihlášení
- FTP: souběžné příkazy otevírají další spojení (server omezující počet
  spojení na účet je může odmítnout); symbolické odkazy na FTP vytvářet nelze
  a odkaz na adresář se ve výpisu chová jako soubor
- hledání: bez hledání duplicit, protokolu hledání, seznamu ignorovaných
  adresářů a správce uložených nastavení (Windows-only atributy a tagy
  v Upřesnit chybí); hledání v archivech jen na lokálním disku, podle přípony
  souboru a bez archivů vnořených v archivu
- vzdálené VFS (FTP/SFTP) nepodporují předměření celkové velikosti přenosu
  (progress běží bez procent)

### Testy

- `make test` – 51 unit testů jádra (masky, cesty, operace včetně přesunu
  v jednom VFS, konfliktů a přeskakování, symbolických odkazů, odmítnutí
  přenosu do téhož adresáře, kopie z adresáře, který nejde vypsat,
  a úklidu po zrušení, hledání včetně obsahu
  souborů, HEX a regulárních výrazů, hledání v archivech ZIP / TAR / TAR.GZ
  včetně obsahu, poškozeného a zaheslovaného archivu, ZIP včetně adresářových záznamů, TAR
  plain i TAR.GZ včetně rekurzivního rozbalení, dlouhých jmen, PAX hlaviček
  a odkazů, rozpoznání ne-archivů, balení s adresářovou strukturou, AES-256
  a ZipCrypto: bez hesla / chybné / správné heslo, FTP proti minimálnímu
  serveru na 127.0.0.1: přihlášení, výpis MLSD i LIST, paměť výpisu, příkazy
  během přenosu na dalším spojení)
- `make smoke` – end-to-end test vazby Swift↔Rust: otevření VFS, list, copy,
  move (v rámci jednoho VFS jako v aplikaci), mkdir, rename, delete, find,
  výběr podle masky, pack ZIP, probe, otevření ZIP, hledání v archivech
  (jménem i v obsahu), AES-256 ZIP přes
  FFI (kódy chyb hesla) a kompatibilita s libarchive (`bsdtar`) oběma směry:
  náš AES-256 archiv rozbalí bsdtar, AES-256 i ZipCrypto archiv z bsdtar
  přečte jádro
- `make selftest` – UI self-test: aplikace si posílá skutečné klávesové události
  a ověřuje kurzor, Space, Tab, rychlé hledání, F7/F5/F8 dialogy (žádné
  zamrznutí), ⌫ s návratem kurzoru, ⌘U, ⌃F (okno hledání: Enter najde položky, Hledat v archivech najde položky uvnitř ZIP a Ukázat zavede panel do archivu, Escape zavře) a F11 (správa serverů) se zavřením Escapem
  a zaheslovaný AES-256 ZIP (Enter do archivu, F5, chybné → správné heslo),
  Home/End, ⌥↑/⌥↓, ⌃H (skryté soubory), ⌥1/⌥3/⌥6/⌥2 (režimy) se šipkami;
  test otevírá okno aplikace a posílá jí klávesy – při současné práci
  s počítačem může selhat kvůli ztrátě fokusu, pouštějte ho bez zásahů
- `make keycheck` – Home/End, ⌥↑/⌥↓ a systémové příkazy začátek/konec
  dokumentu ve všech šesti režimech s 500 soubory v okně skutečné velikosti
  (kurzor na „..“ / poslední položku a zůstane vidět), cyklení a změna pořadí
  v nabídce disků, řazení míst podle uloženého pořadí, uložené FTP/SFTP servery (název, adresa, potřeba hesla,
  uložení do JSON), vestavěný terminál se skutečným shellem uživatele (shell
  jde za adresářem panelu, vložené `cd` po sobě smaže řádek, `cd` v shellu
  přesune panel, ⌘F12 roztáhne terminál a vrátí jeden řádek; volitelné snímky
  obou režimů `SAL_TERMINAL_SNAPSHOT=/cesta/predpona`), záložky terminálu
  (lišta jen při dvou a více záložkách), vrstvy lišty F-kláves a schránka
  souborů (zkratky ⌘C / ⌘X / ⌘V, kontextové menu, čtení souborů ze schránky,
  vložení z více adresářů, duplikát v témže adresáři, přesun, registrace
  panelu pro přetažení – systémové schránky se nedotkne), tažení mezi panely
  (odmítnutí tažení do téhož panelu, přesun na stejném svazku, kopie s ⌥,
  přesun s ⌘, umělé pohnutí myší při změně klávesy během tažení ven), zkratky
  trvalého mazání (⇧F8, ⌘F8) a koš podle svazku;
  běží bez zobrazení okna, nepřebírá fokus
- diagnostika kláves: `defaults write com.github.svopex.microcommander keyLog -bool YES`
  zapíše každý stisk (kód klávesy, znak, modifikátory, fokus) do
  `~/Library/Logs/MicroCommander/keys.log`; vypnutí `defaults delete com.github.svopex.microcommander keyLog`
- `make sftp-test` – SFTP end-to-end: spustí dočasný `sshd` jen na 127.0.0.1
  (pod uživatelem, vlastní konfigurace, volný port), vygeneruje klíče a ověří
  přihlášení ed25519 bez hesla / s heslem (bez hesla, chybné, správné), RSA PEM,
  ECDSA, ssh-agent, odmítnutý klíč a chybějící soubor, vždy se zápisem, čtením
  a smazáním souboru (včetně odkazu na adresář – jeho cíl musí zůstat); totéž
  přes FFI (Swift). Systémové Vzdálené přihlášení se
  nemění, vše se po testu uklidí
- vývojářský snímek okna: `SAL_SNAPSHOT=/cesta.png build/MicroCommander.app/Contents/MacOS/MicroCommander`
