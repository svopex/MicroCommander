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
  skupiny oddělené `;`, vyloučení za `|`; maska bez `*`, `?` a `.` hledá jména,
  která ji obsahují), volitelně bez podadresářů a s hledáním v obsahu souborů
  (text, HEX, rozlišení velikosti písmen, celá slova, regulární výraz – crate
  `regex`); nečitelné adresáře a soubory se přeskočí a spočítají. Vytváření ZIP archivů (`pack_zip`)
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
  dva panely s prostřední svislou lištou operací (výchozí jen úzký pruh, ikony
  zapne Nastavení), příkazová řádka `cesta>`
  a spodní lišta F-kláves (popisky se mění podle držených Shift/Ctrl/Alt).
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
    src/zipfs.rs            # ZIP jako VFS (jen čtení, AES/ZipCrypto s heslem)
    src/tarfs.rs            # TAR/TAR.GZ jako VFS – vlastní parser (ustar,
                            #   GNU longname, PAX; tar.gz sdílená dekompresní
                            #   session pro jednoprůchodové rozbalení)
    src/ftp.rs              # FTP VFS (suppaftp, RETR/STOR streamy, abort)
    src/sftp.rs             # SFTP VFS (ssh2, serializace přístupu zámkem)
    src/mask.rs             # masky ve stylu Salamandera (port myšlenky masks.cpp)
    src/ops.rs              # copy/move/delete mezi VFS, progress, cancel
    src/find.rs             # rekurzivní hledání nad VFS (maska, podadresáře,
                            #   obsah souborů: text/HEX/celá slova/regex)
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
  Sources/Dialogs.swift     # progress, správa FTP/SFTP serverů,
                            #   interní prohlížeč, nabídka disků
  Sources/Attributes.swift  # dialog Změnit atributy (⌘F2 / ⌃F2)
  Sources/FindWindow.swift  # okno Vyhledat soubory a adresáře (⌃F/⌥F7)
                            #   a dialog Upřesnit možnosti
  Sources/Servers.swift     # uložené FTP/SFTP servery (UserDefaults),
                            #   hesla v Klíčence, připojení serveru v panelu
  Sources/Places.swift      # místa nabídky disků (pořadí, skrytí, vlastní
                            #   adresáře, zkratky ⌘0–⌘9) a dialog Upravit
                            #   nabídku disků
  Sources/Settings.swift    # Nastavení (⌘,): volby vzhledu v UserDefaults
  Sources/SelfTest.swift    # self-test UI (SAL_SELFTEST=1)
  Sources/main.swift        # NSApplication, hlavní menu
  Info.plist
  AppIcon.icns              # ikona aplikace (generuje `make icon`)
tools/make-icon.swift       # vykreslí ikonu: oranžový disk s tlapkou mloka
                            #   ve stylu Salamandera na macOS dlaždici
tests/main.swift            # end-to-end smoke test FFI (Swift CLI)
Makefile                    # build celé aplikace jedním příkazem
fetch-samandarin.sh         # stáhne původní zdrojáky do samandarin/ (bez .git)
CODESIGNING.md              # vlastní certifikát pro podpis (trvalá oprávnění macOS)
samandarin/                 # původní Windows zdrojáky (reference, nemění se)
```

### Build a spuštění

Vyžaduje Rust (cargo v `~/.cargo/bin`) a Xcode Command Line Tools (swiftc).

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
do předvoleb `com.github.svopex.microcommander`; při prvním spuštění se jednorázově
převezme z dřívější domény `eu.krtkovo.salamander` (z doby názvu Salamander).

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
  adresář, archiv (ZIP/TAR/TAR.GZ jako panel) nebo soubor ve výchozí aplikaci;
  **spustitelný shell skript** (právo `+x` a shebang `sh`/`bash`/`zsh`/`dash`/`ksh`,
  i přes `/usr/bin/env`; přípona nerozhoduje) Enter spustí v Terminalu
  v adresáři panelu – skript bez `+x` nebo bez shebangu se jen otevře;
  **⌘Enter** – spustit / otevřít systémově bez vstupu dovnitř (aplikace `.app`
  se spustí, archiv se otevře ve výchozí aplikaci, adresář ve Finderu, skript
  se shebangem se otevře podle přípony – bez přípony v textovém editoru;
  z archivu či FTP se soubor nejdřív rozbalí do dočasného adresáře);
  ⌫ / „..“ – nadřazený adresář (kurzor se vrátí na adresář, ze kterého se
  přišlo; na kořeni archivu/FTP se lokace zavře); Tab – druhý panel;
  Home / End (fn+← / fn+→, ⌘← / ⌘→) a ⌥↑ / ⌥↓ – první položka (obvykle „..“) /
  poslední položka ve všech režimech zobrazení (i když systém nebo klávesnice
  posílá Home/End jako příkaz začátek/konec dokumentu); funguje i z prázdné
  příkazové řádky, stejně jako PgUp/PgDn;
  ⌥← / ⌥→ – historie; ⌘\ – kořen; ⌘. (⌃.) – poslat aktuální adresář do druhého panelu (přepne se druhý panel);
  ⌘⇧. (⌃⇧.) – převzít adresář z druhého panelu (přepne se aktivní; oba směry fungují
  i v archivu a na FTP/SFTP – panel převezme i zanoření, „..“ vede ven); ⇧F7 / ⌘G / dvojklik na řádek adresáře – zadat cestu;
  pravé tlačítko na řádku adresáře – Kopírovat cestu do schránky / Změnit adresář…;
  ⌥⌘C (Úpravy › Kopírovat cestu adresáře, ⌃⌥Insert) – cesta aktuálního adresáře
  aktivního panelu do schránky (u archivu/FTP tak, jak ji ukazuje řádek adresáře)
- **Označování:** Space / Insert – označit a posunout; ⇧↑↓, ⇧PgUp/PgDn,
  ⇧Home/End, ⌘klik, ⇧klik; ⌘A – označit vše (opakovaný stisk označení zruší;
  adresáře podle Nastavení, výchozí i adresáře), ⌘D – nic; Num + / Num − (⌘= / ⌘−) –
  podle masky; Num * – invertovat (adresáře podle Nastavení). Operace pracují s označenými položkami,
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
  potvrdí), F3 prohlížeč, F4 editor, F5
  kopírovat, F6 přesunout (oba s dialogem cíle), F7 nový adresář, F8 smazat,
  F9 terminál v adresáři, F10 ukončit, F11 FTP/SFTP servery, F12 odpojit /
  zavřít archiv; ⇧F4 nový soubor, ⇧F6 přejmenovat; **⌘F2 / ⌃F2 změnit atributy**
  (dialog podle Salamandera: Jen pro čtení a Skrytý třístavově – smíšený stav
  = neměnit, změna data a času Změněno / Vytvořeno / Otevřeno, Nastavit
  aktuální, Včetně podadresářů; označené položky, jinak položka pod kurzorem;
  jen lokální disk; Windows atributy jsou vidět, ale nedostupné); ⌃F3–⌃F6 řazení podle
  jména/přípony/času/velikosti (opakovaně obrací), ⌃F9 obnovit, ⌃F10 porovnat
  adresáře (označí odlišné soubory); ⌥F1/⌥F2 disk vlevo/vpravo, ⌥F5 zabalit do
  ZIP, ⌥F6 rozbalit do druhého panelu, ⌥F7 hledat (také ⌃F), ⌥F10 obsazené místo
  (také ⌃Q).
- **Vlastnosti a oprávnění** (jako Alt+Enter a Ctrl+P v Salamanderu): ⌥↩ / ⌘I
  (Soubory › Vlastnosti…, kontextové menu) a ⌃P (Soubory › Oprávnění…) otevřou
  okno Informace z Finderu pro označené položky (jinak pro položku pod
  kurzorem) – Otevřít v aplikaci, Sdílení a oprávnění atd. Otevírá se systémovou
  službou Finderu „Zobrazit informace“ (bez AppleScriptu a dotazu na povolení);
  je-li služba vypnutá, položky se vyberou ve Finderu (pak ⌘I). Víc než 20 oken
  se otevře až po potvrzení. Jen lokální disk.
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
  `customFolders` (adresáře), `placeShortcuts` (zkratky); dřívější
  `driveOrder` se převezme.
- **Nastavení** (⌘, v aplikačním menu): **Zobrazovat lištu příkazů mezi
  panely** – svislá lišta s ikonami operací; výchozí je vypnutá, mezi panely
  je jen úzký dělicí pruh jako v Salamanderu. Změna platí hned (předvolba
  `showMiddleBar`). **Označit vše (⌘A) a Invertovat označení i s adresáři** –
  výchozí zapnuto (vypnuté = ⌘A označí a Num * invertuje jen soubory); zrušení
  označení platí vždy i pro adresáře
  (předvolba `selectAllIncludesDirs`).
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
- **Vyhledat soubory a adresáře** (⌃F, ⌘F, ⌥F7 – podle dialogu Find
  Salamandera): nemodální okno, lze jich otevřít víc a během hledání pracovat
  v panelech. **Název** (masky, poprvé `*.*`; maska bez `*`, `?` a `.` hledá
  jména obsahující text – `dog` najde `hotdog.jpg`, `dog.` jen `dog`), **Hledat
  v** (předvyplněno adresářem panelu, víc adresářů oddělených `;`, **Přidat** ›
  Procházet… / Všechny místní jednotky), **Včetně podadresářů**, **Hledat
  v souboru** – rozbalí část **Obsahující** s volbami Šestnáctkový režim
  (`01 02 "text" 00`), Rozlišovat malá a velká písmena, Celá slova a Regulární
  výraz (vyhodnocuje se po řádcích; tlačítko › vkládá konstrukce),
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
  F3 zobrazit, F4 upravit, F8 / Delete odstranit, ⌃H skrýt, ⌃⇧H skrýt duplicity,
  ⌘C / ⌃C kopírovat soubory do schránky (pro Finder), ⌘X vyjmout, ⌥⌘C / ⌥⌘⇧C /
  ⌃⌘C cestu + název / název / cestu jako text (i ⌥Insert varianty), ⌘A vybrat vše.
  Dokud je okno aktivní, hlavní menu nahradí menu dialogu (Soubory, Příkazy,
  Upravit, Zobrazit, Možnosti). V archivu či na FTP/SFTP se hledá ve VFS panelu.
  Nastavení a historie: předvolby `find*` (`findNamedHistory`,
  `findLookInHistory`, `findContainingHistory`, `findAdvanced`, …).
- **Přetažení myší ven z aplikace:** položku (nebo všechny označené, pokud se
  táhne za označenou) lze přetáhnout do Finderu, Zpráv (iMessage), Mailu
  a dalších aplikací ve všech režimech zobrazení; tažení začne po posunu myši
  o pár bodů. Jen soubory z lokálního disku (ne z archivu či FTP/SFTP);
  přetažení do panelu zatím není.
- **Další:** ⌘R obnovit, ⌘U prohodit panely, klik na záhlaví sloupce
  řadí, pravé tlačítko – kontextové menu (Finder, kopírovat cestu).
- **Příkazová řádka** (⌘Tab, také ⌃Tab): Enter spustí příkaz v login shellu v adresáři
  panelu (na pozadí, bez terminálu; výstup v prohlížeči po doběhnutí), **⌘Enter**
  nebo **⌃Enter** ho spustí v novém okně Terminalu v adresáři panelu (interaktivní skripty, dotazy
  na heslo, průběžný výstup; po doběhnutí zůstane v okně shell), `cd cesta` mění adresář panelu, ↑↓ historie,
  ⌃↩ v panelu (nebo v prázdné příkazové řádce) vloží jméno položky pod kurzorem na pozici
  kurzoru v řádce – u souboru na začátku prázdné řádky jako `./jméno` a fokus
  přejde do řádky, takže Enter skript/program rovnou spustí; jinde jako argument
  (za „./“ bez mezery), ⌃[ / ⌃] cestu levého/pravého panelu.
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
- hledání: bez hledání uvnitř archivů, hledání duplicit, protokolu hledání,
  seznamu ignorovaných adresářů a správce uložených nastavení (Windows-only
  atributy a tagy v Upřesnit chybí)
- vzdálené VFS (FTP/SFTP) nepodporují předměření celkové velikosti přenosu
  (progress běží bez procent)

### Testy

- `make test` – 28 unit testů jádra (masky, cesty, operace, hledání včetně
  obsahu souborů, HEX a regulárních výrazů, ZIP,
  TAR plain i TAR.GZ včetně rekurzivního rozbalení, balení s adresářovou
  strukturou, AES-256 a ZipCrypto: bez hesla / chybné / správné heslo)
- `make smoke` – end-to-end test vazby Swift↔Rust: otevření VFS, list, copy,
  mkdir, rename, delete, find, pack ZIP, probe, otevření ZIP, AES-256 ZIP přes
  FFI (kódy chyb hesla) a kompatibilita s libarchive (`bsdtar`) oběma směry:
  náš AES-256 archiv rozbalí bsdtar, AES-256 i ZipCrypto archiv z bsdtar
  přečte jádro
- `make selftest` – UI self-test: aplikace si posílá skutečné klávesové události
  a ověřuje kurzor, Space, Tab, rychlé hledání, F7/F5/F8 dialogy (žádné
  zamrznutí), ⌫ s návratem kurzoru, ⌘U, ⌃F (okno hledání: Enter najde položky, Escape zavře) a F11 (správa serverů) se zavřením Escapem
  a zaheslovaný AES-256 ZIP (Enter do archivu, F5, chybné → správné heslo),
  Home/End, ⌥↑/⌥↓, ⌃H (skryté soubory), ⌥1/⌥3/⌥6/⌥2 (režimy) se šipkami;
  test otevírá okno aplikace a posílá jí klávesy – při současné práci
  s počítačem může selhat kvůli ztrátě fokusu, pouštějte ho bez zásahů
- `make keycheck` – Home/End, ⌥↑/⌥↓ a systémové příkazy začátek/konec
  dokumentu ve všech šesti režimech s 500 soubory v okně skutečné velikosti
  (kurzor na „..“ / poslední položku a zůstane vidět), cyklení a změna pořadí
  v nabídce disků, řazení míst podle uloženého pořadí, uložené FTP/SFTP servery (název, adresa, potřeba hesla,
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
