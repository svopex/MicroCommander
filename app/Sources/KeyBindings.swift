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
    /// navigace a mezerník bez modifikátoru nebo jen s ⇧, ⌘↩ / ⌃↩ (spuštění,
    /// vložení jména), ⌘Tab / ⌃Tab (příkazová řádka) a ⌘0–⌘9 (místa disků).
    var isReserved: Bool {
        guard byKeyCode else { return false }
        let mods = modifiers
        if (Shortcut.navigationKeys.contains(keyCode) || keyCode == KeyCode.space) && mods.subtracting(.shift).isEmpty {
            return true
        }
        if (keyCode == KeyCode.returnKey || keyCode == KeyCode.enter || keyCode == KeyCode.tab)
            && (mods == .command || mods == .control) {
            return true
        }
        return mods == .command && (KeyCode.digits.contains(keyCode) || keyCode == KeyCode.digitZero)
    }

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
        if Shortcut.navigationKeys.contains(keyCode) && byKeyCode { return true }
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
        case .terminal: return "Terminál v adresáři"
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
        case .pack: return "Zabalit"
        case .find: return "Hledat"
        case .calcSize: return "Velikost"
        case .changeAttributes: return "Atributy"
        case .terminal: return "Terminál"
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
        (.newFile, [.function(4, .shift)]),
        (.copy, [.function(5)]),
        (.move, [.function(6)]),
        (.mkdir, [.function(7)]),
        // F8 maže do koše, ⇧F8 trvale (Delete / ⇧Delete řeší přímo panel).
        (.delete, [.function(8)]),
        (.deletePermanent, [.function(8, .shift)]),
        (.terminal, [.function(9)]),
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
        (.back, [char("[", .command)]),
        (.forward, [char("]", .command)]),
        (.up, [.code(KeyCode.up, key: String(UnicodeScalar(NSUpArrowFunctionKey)!), .command)]),
        (.root, cmdCtrl("\\")),
        (.home, [char("h", [.command, .shift])]),
        (.swap, cmdCtrl("u")),
        (.sameDirOther, [.code(KeyCode.period, key: ".", .command), .code(KeyCode.period, key: ".", .control)]),
        (.sameDir, [.code(KeyCode.period, key: ".", [.command, .shift]),
                    .code(KeyCode.period, key: ".", [.control, .shift])]),
        (.copyDirPath, [char("c", [.command, .option]), .code(KeyCode.insert, key: "", [.control, .option])]),
        (.viewBrief, [.code(KeyCode.digits[0], key: "1", .option)]),
        (.viewDetailed, [.code(KeyCode.digits[1], key: "2", .option)]),
        (.viewIcons, [.code(KeyCode.digits[2], key: "3", .option)]),
        (.viewThumbnails, [.code(KeyCode.digits[3], key: "4", .option)]),
        (.viewTiles, [.code(KeyCode.digits[4], key: "5", .option)]),
        (.viewTypes, [.code(KeyCode.digits[5], key: "6", .option)]),
        (.editPlaces, []),
    ]

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
        let saved = overrides
        let result = defaults.map { command, shortcuts in (command, saved[name(of: command)] ?? shortcuts) }
        cachedTable = result
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
                if textEditing && shortcut.isTextEditing { continue }
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

    /// Příkaz na F-klávese v dané vrstvě lišty (modifikátory vrstvy).
    static func functionKeyCommand(number: Int, modifiers: [NSEvent.ModifierFlags]) -> Command? {
        table.first { _, shortcuts in
            shortcuts.contains { $0.functionNumber == number && modifiers.contains($0.modifiers) }
        }?.0
    }
}
