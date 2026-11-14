// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Klávesové zkratky příkazů na jednom místě: výchozí přiřazení (podle
// Salamandera s macOS variantami ⌘) a uživatelské změny z Nastavení › Klávesnice
// (UserDefaults „keyBindings“). Podle téže tabulky se řídí obsluha kláves
// hlavního okna, zkratky v hlavním menu i popisky spodní lišty F-kláves.
// Navigační klávesy (šipky, Enter, Tab, mezerník, psaní) zůstávají pevné.

import AppKit

/// Klávesová zkratka: klávesa + modifikátory.
struct Shortcut: Codable, Hashable {
    /// Kód klávesy (fyzická poloha).
    var keyCode: UInt16
    /// Znak klávesy bez modifikátorů (pro porovnání u písmen a pro menu).
    var key: String
    /// Porovnávat podle kódu klávesy (F-klávesy, šipky, numerická klávesnice,
    /// číslice a tečka – nezávisle na rozložení), jinak podle znaku.
    var byKeyCode: Bool
    /// Modifikátory (⌃ ⌥ ⇧ ⌘) jako surová hodnota NSEvent.ModifierFlags.
    var modifierBits: UInt

    init(keyCode: UInt16, key: String, byKeyCode: Bool, modifierBits: UInt) {
        self.keyCode = keyCode
        self.key = key
        self.byKeyCode = byKeyCode
        self.modifierBits = modifierBits
    }

    /// Modifikátory zkratky.
    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    /// Relevantní modifikátory události (bez fn, numerické klávesnice apod.).
    static func relevantModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.control, .option, .shift, .command])
    }

    /// Zkratka podle znaku (písmena, symboly).
    static func char(_ key: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Shortcut {
        Shortcut(keyCode: keyCode, key: key, byKeyCode: false, modifierBits: modifiers.rawValue)
    }

    /// Zkratka podle kódu klávesy (F-klávesy, šipky, numerická klávesnice…).
    static func code(_ keyCode: UInt16, key: String, _ modifiers: NSEvent.ModifierFlags) -> Shortcut {
        Shortcut(keyCode: keyCode, key: key, byKeyCode: true, modifierBits: modifiers.rawValue)
    }

    /// F-klávesa F1–F12.
    static func function(_ number: Int, _ modifiers: NSEvent.ModifierFlags = []) -> Shortcut {
        code(KeyCode.functionKeys[number - 1], key: KeyCode.functionKeyString(number), modifiers)
    }

    /// Zkratka ze stisknuté klávesy (záznam v Nastavení › Klávesnice). Písmena
    /// a symboly se porovnávají podle znaku, ostatní klávesy podle kódu.
    init?(event: NSEvent) {
        let modifiers = Shortcut.relevantModifiers(event.modifierFlags)
        let raw = event.charactersIgnoringModifiers ?? ""
        let isSpecial = KeyCode.functionKeys.contains(event.keyCode) || Shortcut.namedKeys[event.keyCode] != nil
            || KeyCode.digits.contains(event.keyCode) || event.keyCode == KeyCode.digitZero
            || event.keyCode == KeyCode.period || event.modifierFlags.contains(.numericPad)
        if isSpecial {
            let key = KeyCode.functionKeys.firstIndex(of: event.keyCode).map { KeyCode.functionKeyString($0 + 1) }
                ?? (raw.isEmpty ? " " : raw.lowercased())
            self = .code(event.keyCode, key: key, modifiers)
        } else {
            guard let first = raw.lowercased().first, !raw.isEmpty else { return nil }
            self = .char(String(first), keyCode: event.keyCode, modifiers)
        }
    }

    /// Odpovídá zkratka stisknuté klávese?
    /// - Parameters:
    ///   - keyCode: kód klávesy události
    ///   - chars: znak klávesy bez modifikátorů (malými písmeny)
    ///   - modifiers: relevantní modifikátory události
    func matches(keyCode: UInt16, chars: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers == self.modifiers else { return false }
        return byKeyCode ? keyCode == self.keyCode : chars == key
    }

    /// Klávesa vyhrazená pro pevné ovládání (nelze ji přiřadit příkazu):
    /// navigace (šipky, PgUp/PgDn, Home/End, Enter, Tab, Esc, ⌫) a mezerník bez
    /// modifikátoru nebo jen s ⇧. Delete (vpřed) jde přiřadit i bez modifikátoru
    /// – výchozí mazání do koše. ⌘0–⌘9 přiřadit jde; v panelu má přednost místo
    /// z nabídky disků se stejnou zkratkou.
    var isReserved: Bool {
        guard byKeyCode, keyCode != KeyCode.forwardDelete else { return false }
        return (Shortcut.navigationKeys.contains(keyCode) || keyCode == KeyCode.space)
            && modifiers.subtracting(.shift).isEmpty
    }

    /// Písmeno, číslice nebo symbol bez modifikátoru (nejvýš s ⇧) – jako zkratka
    /// by v panelu blokovalo rychlé hledání, proto ho příkazu přiřadit nelze.
    var blocksQuickSearch: Bool { !byKeyCode && modifiers.subtracting(.shift).isEmpty }

    /// Lze zkratku přiřadit příkazu? (Záznam v Nastavení i načtení ze souboru.)
    var isAssignable: Bool { !isReserved && !blocksQuickSearch }

    /// Je to F-klávesa?
    var isFunctionKey: Bool { functionNumber != nil }

    /// Číslo F-klávesy (1–12), jinak nil.
    var functionNumber: Int? {
        guard byKeyCode, let index = KeyCode.functionKeys.firstIndex(of: keyCode) else { return nil }
        return index + 1
    }

    /// Zkratka, kterou při psaní v textovém poli potřebuje pole samo (psaní,
    /// pohyb kurzorem, ⌘A/⌘C/⌘V/⌘X/⌘Z) – tam se příkaz nespouští.
    var isTextEditing: Bool {
        if isFunctionKey { return false }
        let mods = modifiers
        if mods.subtracting(.shift).isEmpty { return true }
        // Klávesy pohybu patří poli – kromě kombinace s ⌥⌘, kterou textová pole
        // ani shell nepoužívají (přepínání záložek terminálu).
        if Shortcut.navigationKeys.contains(keyCode) && byKeyCode {
            return !(mods.contains(.command) && mods.contains(.option))
        }
        // ⌘A/⌘C/⌘V/⌘X/⌘Z a ⌃písmeno (emacsové pohyby a mazání v poli) patří poli.
        if mods == .control && !byKeyCode && key.first?.isLetter == true { return true }
        return mods == .command && ["a", "c", "v", "x", "z"].contains(key)
    }

    /// Hodí se jako zkratka položky menu? (Bez modifikátoru jen F-klávesy, jinak
    /// by položka menu zachytávala psaní.)
    var isMenuSafe: Bool { isFunctionKey || !modifiers.subtracting(.shift).isEmpty }

    /// Znak pro keyEquivalent položky menu.
    var menuKey: String {
        byKeyCode ? (Shortcut.menuKeys[keyCode] ?? key) : key
    }

    /// Modifikátory položky menu (u symbolu psaného s ⇧ je ⇧ už ve znaku).
    var menuModifiers: NSEvent.ModifierFlags {
        let isLetter = key.count == 1 && key.first?.isLetter == true
        return !isLetter && !byKeyCode ? modifiers.subtracting(.shift) : modifiers
    }

    /// Text zkratky pro zobrazení (⌃⌥⇧⌘ + klávesa).
    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let number = functionNumber { return text + "F\(number)" }
        if byKeyCode, let name = Shortcut.namedKeys[keyCode] { return text + name }
        return text + key.uppercased()
    }

    /// Klávesy s vlastním názvem (šipky, Enter, numerická klávesnice…).
    static let namedKeys: [UInt16: String] = [
        KeyCode.up: "↑", KeyCode.down: "↓", KeyCode.left: "←", KeyCode.right: "→",
        KeyCode.returnKey: "↩", KeyCode.enter: "⌤", KeyCode.tab: "⇥", KeyCode.space: "Mezerník",
        KeyCode.backspace: "⌫", KeyCode.forwardDelete: "⌦", KeyCode.escape: "Esc",
        KeyCode.insert: "Insert", KeyCode.home: "Home", KeyCode.end: "End",
        KeyCode.pageUp: "PgUp", KeyCode.pageDown: "PgDn",
        KeyCode.keypadPlus: "Num +", KeyCode.keypadMinus: "Num −", KeyCode.keypadMultiply: "Num *",
    ]

    /// Klávesy pohybu kurzoru (v textovém poli patří poli).
    static let navigationKeys: Set<UInt16> = [
        KeyCode.up, KeyCode.down, KeyCode.left, KeyCode.right, KeyCode.home, KeyCode.end,
        KeyCode.pageUp, KeyCode.pageDown, KeyCode.backspace, KeyCode.forwardDelete,
        KeyCode.returnKey, KeyCode.enter, KeyCode.tab, KeyCode.escape,
    ]

    /// keyEquivalent menu pro číslice a tečku podle kódu klávesy (znak závisí
    /// na rozložení – česká horní řada dává „+ě…“, ⇧. dvojtečku).
    static let menuKeys: [UInt16: String] = {
        var keys: [UInt16: String] = [KeyCode.digitZero: "0", KeyCode.period: "."]
        for (index, code) in KeyCode.digits.enumerated() { keys[code] = "\(index + 1)" }
        return keys
    }()
}

extension Command {
    /// Název příkazu (Nastavení › Klávesnice).
    var title: String {
        switch self {
        case .help: return "Nápověda ke klávesám"
        case .rename: return "Přejmenovat"
        case .view: return "Zobrazit"
        case .edit: return "Upravit"
        case .newFile: return "Nový soubor"
        case .copy: return "Kopírovat"
        case .move: return "Přesunout"
        case .mkdir: return "Nový adresář"
        case .changeDir: return "Změnit adresář"
        case .delete: return "Smazat (do koše)"
        case .deletePermanent: return "Smazat trvale (bez koše)"
        case .terminal: return "Terminal.app v adresáři"
        case .terminalFull: return "Terminál na celé okno"
        case .terminalNewTab: return "Nová záložka terminálu"
        case .terminalCloseTab: return "Zavřít záložku terminálu"
        case .terminalNextTab: return "Další záložka terminálu"
        case .terminalPreviousTab: return "Předchozí záložka terminálu"
        case .newWindow: return "Nové okno"
        case .quit: return "Ukončit"
        case .connect: return "FTP/SFTP servery"
        case .disconnect: return "Odpojit / zavřít archiv"
        case .sortName: return "Řadit podle jména"
        case .sortExt: return "Řadit podle přípony"
        case .sortTime: return "Řadit podle času"
        case .sortSize: return "Řadit podle velikosti"
        case .refresh: return "Obnovit"
        case .compare: return "Porovnat adresáře"
        case .driveLeft: return "Disk v levém panelu"
        case .driveRight: return "Disk v pravém panelu"
        case .editPlaces: return "Upravit nabídku disků"
        case .driveInfo: return "Informace o jednotce"
        case .pack: return "Zabalit do ZIP"
        case .unpack: return "Rozbalit"
        case .find: return "Vyhledat soubory a adresáře"
        case .calcSize: return "Spočítat velikost"
        case .back: return "Zpět"
        case .forward: return "Vpřed"
        case .up: return "Nadřazený adresář"
        case .root: return "Kořenový adresář"
        case .home: return "Domovský adresář"
        case .swap: return "Prohodit panely"
        case .sameDir: return "Převzít adresář z druhého panelu"
        case .sameDirOther: return "Poslat adresář do druhého panelu"
        case .toggleHidden: return "Zobrazovat skryté soubory"
        case .copyDirPath: return "Kopírovat cestu adresáře"
        case .revealInFinder: return "Zobrazit ve Finderu"
        case .clipboardCopy: return "Kopírovat do schránky"
        case .clipboardCut: return "Vyjmout do schránky"
        case .clipboardPaste: return "Vložit ze schránky"
        case .changeAttributes: return "Změnit atributy"
        case .properties: return "Vlastnosti"
        case .permissions: return "Oprávnění"
        case .selectMask: return "Označit podle masky"
        case .unselectMask: return "Odznačit podle masky"
        case .invertMarks: return "Invertovat označení"
        case .selectAll: return "Označit vše"
        case .unselectAll: return "Zrušit označení"
        case .viewMenu: return "Nabídka režimů zobrazení"
        case .viewBrief: return "Režim Stručný"
        case .viewDetailed: return "Režim Podrobný"
        case .viewIcons: return "Režim Ikony"
        case .viewThumbnails: return "Režim Miniatury"
        case .viewTiles: return "Režim Dlaždice"
        case .viewTypes: return "Režim Typy"
        case .openItem: return "Otevřít položku"
        case .launchItem: return "Spustit systémově"
        case .firstItem: return "První položka"
        case .lastItem: return "Poslední položka"
        case .toggleMark: return "Označit položku a posunout se"
        case .insertLeftPath: return "Cesta levého panelu do terminálu"
        case .insertRightPath: return "Cesta pravého panelu do terminálu"
        case .toggleTerminalFocus: return "Přepnout panel ↔ řádek terminálu"
        case .insertNameToTerminal: return "Jméno položky do terminálu"
        case .terminalTab9: return "Poslední záložka terminálu"
        case .terminalTab1, .terminalTab2, .terminalTab3, .terminalTab4, .terminalTab5,
             .terminalTab6, .terminalTab7, .terminalTab8:
            return "Záložka terminálu \(terminalTabNumber ?? 0)"
        }
    }

    /// Krátký popisek na liště F-kláves.
    var shortTitle: String {
        switch self {
        case .help: return "Nápověda"
        case .rename: return "Přejmen."
        case .newFile: return "Nový soub."
        case .mkdir: return "Nový adr."
        case .changeDir: return "Změnit adr."
        case .delete: return "Smazat"
        case .deletePermanent: return "Smazat trvale"
        case .connect: return "Připojit"
        case .disconnect: return "Odpojit"
        case .sortName: return "Jméno"
        case .sortExt: return "Přípona"
        case .sortTime: return "Čas"
        case .sortSize: return "Velikost"
        case .compare: return "Porovnat"
        case .driveLeft: return "Levý disk"
        case .driveRight: return "Pravý disk"
        case .driveInfo: return "Jednotka"
        case .revealInFinder: return "Finder"
        case .pack: return "Zabalit"
        case .find: return "Hledat"
        case .calcSize: return "Velikost"
        case .changeAttributes: return "Atributy"
        case .terminal: return "Terminal.app"
        case .terminalFull: return "Terminál"
        default: return title
        }
    }
}

/// Přiřazení klávesových zkratek příkazům (výchozí + uživatelské změny).
enum KeyBindings {
    /// Oznámení o změně zkratek (menu a lišta F-kláves se aktualizují).
    static let changed = Notification.Name("MicroCommanderKeyBindingsChanged")
    private static let storageKey = "keyBindings"

    /// Zkratka podle znaku (kód klávesy se u ní neporovnává).
    private static func char(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Shortcut {
        .char(key, keyCode: 0, modifiers)
    }

    /// ⌘ i ⌃ varianta (Ctrl zkratky Salamandera mají na Macu i ⌘).
    private static func cmdCtrl(_ key: String, _ extra: NSEvent.ModifierFlags = []) -> [Shortcut] {
        [char(key, extra.union(.command)), char(key, extra.union(.control))]
    }

    /// Zkratka zvláštní klávesy podle kódu (šipky, Enter, Tab, Delete…).
    /// - Parameters:
    ///   - keyCode: kód klávesy
    ///   - scalar: znak klávesy (NSUpArrowFunctionKey apod.)
    ///   - modifiers: modifikátory
    private static func special(_ keyCode: UInt16, _ scalar: Int, _ modifiers: NSEvent.ModifierFlags) -> Shortcut {
        .code(keyCode, key: String(UnicodeScalar(UInt32(scalar)).map(Character.init) ?? " "), modifiers)
    }

    /// ⌘Fn i ⌃Fn (vrstva Ctrl lišty F-kláves).
    private static func cmdCtrlFunction(_ number: Int) -> [Shortcut] {
        [.function(number, .command), .function(number, .control)]
    }

    /// Výchozí zkratky v pořadí zobrazení v Nastavení (pořadí rozhoduje i o tom,
    /// který příkaz má na liště F-kláves přednost při shodě).
    static let defaults: [(Command, [Shortcut])] = [
        (.help, [.function(1)]),
        (.rename, [.function(2), .function(6, .shift)]),
        (.view, [.function(3), .function(3, .option)]),
        (.edit, [.function(4)]),
        // ⇧F3 – Shift+F3 Salamandera (otevřít aktivní složku v Exploreru).
        (.revealInFinder, [.function(3, .shift)]),
        (.newFile, [.function(4, .shift)]),
        (.copy, [.function(5)]),
        (.move, [.function(6)]),
        (.mkdir, [.function(7)]),
        // F8 maže do koše, ⇧F8 i ⌘F8 trvale (Delete / ⇧Delete řeší přímo panel).
        // Delete / ⌘⌫ do koše, ⇧Delete trvale (jako Finder a Salamander).
        (.delete, [.function(8), special(KeyCode.forwardDelete, NSDeleteFunctionKey, []),
                   special(KeyCode.backspace, 0x7f, .command)]),
        (.deletePermanent, [.function(8, .shift), .function(8, .command),
                            special(KeyCode.forwardDelete, NSDeleteFunctionKey, .shift)]),
        (.terminal, [.function(9)]),
        // ⌘F12 roztáhne vestavěný terminál na celé okno a zpět.
        (.terminalFull, [.function(12, .command)]),
        // Záložky terminálu: ⌘T nová, ⇧⌘W zavřít, ⌥⌘→ / ⌥⌘← další / předchozí.
        (.terminalNewTab, [char("t", .command)]),
        (.terminalCloseTab, [char("w", [.command, .shift])]),
        (.terminalNextTab, [special(KeyCode.right, NSRightArrowFunctionKey, [.command, .option])]),
        (.terminalPreviousTab, [special(KeyCode.left, NSLeftArrowFunctionKey, [.command, .option])]),
        (.newWindow, [char("n", .command)]),
        (.quit, [.function(10), .function(4, .option)]),
        (.connect, [.function(11)]),
        (.disconnect, [.function(12)]),
        (.changeDir, [.function(7, .shift)] + cmdCtrl("g")),
        (.changeAttributes, cmdCtrlFunction(2)),
        (.properties, [char("i", .command), .code(KeyCode.returnKey, key: "\r", .option)]),
        (.permissions, [char("p", .control)]),
        (.sortName, cmdCtrlFunction(3)),
        (.sortExt, cmdCtrlFunction(4)),
        (.sortTime, cmdCtrlFunction(5)),
        (.sortSize, cmdCtrlFunction(6)),
        (.refresh, cmdCtrlFunction(9) + cmdCtrl("r")),
        (.compare, cmdCtrlFunction(10)),
        (.driveLeft, [.function(1, .option)]),
        (.driveRight, [.function(2, .option)]),
        (.driveInfo, cmdCtrlFunction(1)),
        (.pack, [.function(5, .option)]),
        (.unpack, [.function(6, .option), .function(9, .option)]),
        (.find, [.function(7, .option)] + cmdCtrl("f")),
        (.calcSize, [.function(10, .option), char("q", .control)]),
        (.selectAll, [char("a", .command), .code(KeyCode.keypadPlus, key: "+", .command),
                      .code(KeyCode.keypadPlus, key: "+", .control)]),
        (.unselectAll, cmdCtrl("d") + [.code(KeyCode.keypadMinus, key: "-", .command),
                                      .code(KeyCode.keypadMinus, key: "-", .control)]),
        (.selectMask, [.code(KeyCode.keypadPlus, key: "+", [])] + cmdCtrl("=")),
        (.unselectMask, [.code(KeyCode.keypadMinus, key: "-", [])] + cmdCtrl("-")),
        (.invertMarks, [.code(KeyCode.keypadMultiply, key: "*", [])] + cmdCtrl("*", .shift)),
        (.toggleHidden, [char("h", .control)]),
        // Historie: ⌘[ / ⌘] a ⌥← / ⌥→.
        (.back, [char("[", .command), special(KeyCode.left, NSLeftArrowFunctionKey, .option)]),
        (.forward, [char("]", .command), special(KeyCode.right, NSRightArrowFunctionKey, .option)]),
        (.up, [special(KeyCode.up, NSUpArrowFunctionKey, .command), special(KeyCode.pageUp, NSPageUpFunctionKey, .command),
               special(KeyCode.pageUp, NSPageUpFunctionKey, .control)]),
        // Kořen: ⌘\ / ⌃\ a ⌃⌫ (⇧⌫ zůstává pevně).
        (.root, cmdCtrl("\\") + [special(KeyCode.backspace, 0x7f, .control)]),
        (.home, [char("h", [.command, .shift])]),
        (.swap, cmdCtrl("u")),
        (.sameDirOther, [.code(KeyCode.period, key: ".", .command), .code(KeyCode.period, key: ".", .control)]),
        (.sameDir, [.code(KeyCode.period, key: ".", [.command, .shift]),
                    .code(KeyCode.period, key: ".", [.control, .shift])]),
        (.copyDirPath, [char("c", [.command, .option]), .code(KeyCode.insert, key: "", [.control, .option])]),
        // Schránka souborů v panelu (Ctrl+C / Ctrl+X / Ctrl+V Salamandera); v textovém
        // poli a v terminálu tytéž klávesy dál pracují s textem (Shortcut.isTextEditing).
        (.clipboardCopy, cmdCtrl("c")),
        (.clipboardCut, cmdCtrl("x")),
        (.clipboardPaste, cmdCtrl("v")),
        (.viewBrief, [.code(KeyCode.digits[0], key: "1", .option)]),
        (.viewDetailed, [.code(KeyCode.digits[1], key: "2", .option)]),
        (.viewIcons, [.code(KeyCode.digits[2], key: "3", .option)]),
        (.viewThumbnails, [.code(KeyCode.digits[3], key: "4", .option)]),
        (.viewTiles, [.code(KeyCode.digits[4], key: "5", .option)]),
        (.viewTypes, [.code(KeyCode.digits[5], key: "6", .option)]),
        (.editPlaces, []),
        // Pohyb a označování v panelu (Enter, šipky, Home/End a mezerník zůstávají pevné).
        (.openItem, [special(KeyCode.down, NSDownArrowFunctionKey, .command),
                     special(KeyCode.pageDown, NSPageDownFunctionKey, .command),
                     special(KeyCode.pageDown, NSPageDownFunctionKey, .control)]),
        (.launchItem, [special(KeyCode.returnKey, 0x0d, .command), special(KeyCode.enter, 0x03, .command)]),
        (.firstItem, [special(KeyCode.up, NSUpArrowFunctionKey, .option), special(KeyCode.left, NSLeftArrowFunctionKey, .command)]),
        (.lastItem, [special(KeyCode.down, NSDownArrowFunctionKey, .option), special(KeyCode.right, NSRightArrowFunctionKey, .command)]),
        (.toggleMark, [special(KeyCode.insert, NSHelpFunctionKey, [])]),
        // Terminál: ⌘Tab / ⌃Tab fokus, ⌃↩ jméno položky, ⌃[ / ⌃] cesty panelů.
        (.toggleTerminalFocus, [special(KeyCode.tab, 0x09, .command), special(KeyCode.tab, 0x09, .control)]),
        (.insertNameToTerminal, [special(KeyCode.returnKey, 0x0d, .control), special(KeyCode.enter, 0x03, .control)]),
        (.insertLeftPath, [char("[", .control)]),
        (.insertRightPath, [char("]", .control)]),
    ]
    // ⌘1–⌘9 v terminálu: záložka podle pořadí, ⌘9 poslední.
    + Command.terminalTabs.enumerated().map { index, command in
        (command, [Shortcut.code(KeyCode.digits[index], key: "\(index + 1)", .command)])
    }

    /// Příkazy, kterým lze přiřadit zkratku (v pořadí zobrazení).
    static var commands: [Command] { defaults.map(\.0) }

    /// Výchozí zkratky příkazu.
    static func defaultShortcuts(for command: Command) -> [Shortcut] {
        defaults.first { $0.0 == command }?.1 ?? []
    }

    /// Uživatelské změny (název příkazu → zkratky); chybějící příkaz = výchozí.
    static var overrides: [String: [Shortcut]] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([String: [Shortcut]].self, from: data) else { return [:] }
            return decoded
        }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: storageKey)
            } else if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
            reload()
        }
    }

    /// Uživatelské změny z vnějšího zdroje (soubor s nastavením) očištěné na to,
    /// co jde nastavit i v dialogu: jen známé příkazy a jen přiřaditelné klávesy
    /// (ručně upravený soubor nesmí zablokovat navigaci ani rychlé hledání).
    static func sanitized(_ overrides: [String: [Shortcut]]) -> [String: [Shortcut]] {
        let known = Set(commands.map(name(of:)))
        return overrides.filter { known.contains($0.key) }.mapValues { $0.filter(\.isAssignable) }
    }

    /// Stálý název příkazu pro uložení.
    static func name(of command: Command) -> String { String(describing: command) }

    /// Platné zkratky příkazu (uživatelské, jinak výchozí).
    static func shortcuts(for command: Command) -> [Shortcut] {
        table.first { $0.0 == command }?.1 ?? []
    }

    /// Platná tabulka zkratek (v pořadí výchozích příkazů).
    private static var cachedTable: [(Command, [Shortcut])]?
    static var table: [(Command, [Shortcut])] {
        if let cachedTable { return cachedTable }
        let result = table(applying: overrides)
        cachedTable = result
        return result
    }

    /// Tabulka zkratek pro dané uživatelské změny (v pořadí výchozích příkazů;
    /// příkaz bez změny má výchozí zkratky, neznámé názvy příkazů se ignorují).
    static func table(applying overrides: [String: [Shortcut]]) -> [(Command, [Shortcut])] {
        defaults.map { command, shortcuts in (command, overrides[name(of: command)] ?? shortcuts) }
    }

    /// Uživatelské změny pro dané přiřazení zkratek: jen příkazy, jejichž zkratky
    /// se liší od výchozích (příkaz chybějící v přiřazení = bez zkratek).
    static func overrides(for bindings: [Command: [Shortcut]]) -> [String: [Shortcut]] {
        var result: [String: [Shortcut]] = [:]
        for (command, defaultShortcuts) in defaults {
            let shortcuts = bindings[command] ?? []
            if shortcuts != defaultShortcuts {
                result[name(of: command)] = shortcuts
            }
        }
        return result
    }

    /// Příkaz pro stisknutou klávesu.
    /// - Parameters:
    ///   - event: událost klávesy
    ///   - textEditing: fokus je v textovém poli – zkratky potřebné pro psaní
    ///     (viz Shortcut.isTextEditing) se pak nepoužijí
    static func command(for event: NSEvent, textEditing: Bool = false) -> Command? {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = Shortcut.relevantModifiers(event.modifierFlags)
        for (command, shortcuts) in table {
            for shortcut in shortcuts where shortcut.matches(keyCode: event.keyCode, chars: chars, modifiers: modifiers) {
                // Psaní v poli má přednost – kromě ovládání terminálu (⌘Tab, ⌃↩).
                if textEditing && shortcut.isTextEditing && !command.ignoresTextEditing { continue }
                return command
            }
        }
        return nil
    }

    /// Zkratka pro položku menu (první vhodná – bez modifikátoru jen F-klávesa).
    static func menuShortcut(for command: Command) -> Shortcut? {
        shortcuts(for: command).first(where: \.isMenuSafe)
    }

    /// Zkratka, kterou při psaní v textovém poli potřebuje pole samo – menu ji
    /// pak příkazu nepředá (stejné pravidlo jako monitor kláves okna).
    static func isTextEditingKey(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let modifiers = Shortcut.relevantModifiers(event.modifierFlags)
        return table.contains { _, shortcuts in
            shortcuts.contains { $0.isTextEditing && $0.matches(keyCode: event.keyCode, chars: chars, modifiers: modifiers) }
        }
    }

    /// Znovu načte uložené zkratky (po zápisu do UserDefaults mimo `overrides`)
    /// a oznámí změnu.
    static func reload() {
        cachedTable = nil
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Příkaz na F-klávese v dané vrstvě lišty (modifikátor vrstvy).
    static func functionKeyCommand(number: Int, modifiers: NSEvent.ModifierFlags) -> Command? {
        table.first { _, shortcuts in
            shortcuts.contains { $0.functionNumber == number && $0.modifiers == modifiers }
        }?.0
    }
}
