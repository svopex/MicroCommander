// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Dialog „Oprávnění“ (⌃P): unixová práva čtení / zápisu / spouštění pro
// vlastníka, skupinu a ostatní, zvláštní bity (Set UID, Set GID, Sticky),
// číselný zápis (755), změna skupiny a volitelně i obsah podadresářů jen
// pro soubory nebo jen pro adresáře. Okno Informace z Finderu spouštění
// nastavit neumí, proto vlastní dialog. Jen lokální disk; symbolické odkazy
// se přeskakují (chmod by měnil jejich cíl).

import AppKit

/// Na které položky se při procházení podadresářů změny uplatní.
enum PermissionScope: Int {
    case all, files, directories
}

/// Požadované změny oprávnění: bity k nastavení a k odebrání (ostatní se
/// nemění – u výběru s různými právy zůstane smíšený bit u každé položky jak byl).
struct PermissionChanges {
    var setBits: mode_t = 0
    var clearBits: mode_t = 0
    /// Nová skupina; nil = neměnit.
    var group: gid_t?
    /// Změnit i obsah podadresářů.
    var recursive = false
    /// Změnit jen soubory / jen adresáře (jen s `recursive`, platí i pro vybrané
    /// položky); bez procházení podadresářů vždy `.all`.
    var scope = PermissionScope.all
}

/// Oprávnění jedné položky načtená přes lstat.
struct PermissionInfo {
    let mode: mode_t
    let uid: uid_t
    let gid: gid_t
    let isDirectory: Bool

    /// Načte oprávnění položky; nil pro symbolický odkaz nebo nečitelnou položku.
    /// - Parameter path: lokální cesta
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return nil }
        mode = info.st_mode & 0o7777
        uid = info.st_uid
        gid = info.st_gid
        isDirectory = info.st_mode & S_IFMT == S_IFDIR
    }
}

/// Jméno uživatele podle UID (číslo, když uživatel neexistuje).
func userName(_ uid: uid_t) -> String {
    getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
}

/// Jméno skupiny podle GID (číslo, když skupina neexistuje).
func groupName(_ gid: gid_t) -> String {
    getgrgid(gid).map { String(cString: $0.pointee.gr_name) } ?? String(gid)
}

/// Skupiny aktuálního uživatele (jen do nich smí vlastník položku převést).
func currentUserGroups() -> Set<gid_t> {
    let name = userName(getuid())
    // getgrouplist při malém poli vrátí -1 a skutečný počet – pole se zvětší.
    var count: Int32 = 64
    var groups = [Int32](repeating: 0, count: Int(count))
    while getgrouplist(name, Int32(bitPattern: getgid()), &groups, &count) == -1 {
        count *= 2
        groups = [Int32](repeating: 0, count: Int(count))
    }
    return Set(groups.prefix(Int(count)).map { gid_t(bitPattern: $0) })
}

/// Uplatní změny na jednu položku: nejdřív skupina (chown může zrušit Set UID /
/// Set GID), pak práva jedním chmod. Odkaz se přeskočí.
/// - Parameters:
///   - changes: požadované změny
///   - path: lokální cesta položky
/// - Returns: true, pokud je položka adresář (pro rekurzi)
private func applyPermissionChanges(_ changes: PermissionChanges, at path: String) throws -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw posixError() }
    let type = info.st_mode & S_IFMT
    guard type != S_IFLNK else { return false }
    let isDirectory = type == S_IFDIR

    // Rozsah: jen soubory přeskočí adresáře a obráceně.
    guard changes.scope != (isDirectory ? .files : .directories) else { return isDirectory }

    // Skupina: UID -1 = vlastníka neměnit.
    if let group = changes.group, group != info.st_gid {
        guard chown(path, uid_t.max, group) == 0 else { throw posixError() }
        // Změna skupiny mohla shodit Set UID / Set GID – jen tehdy práva znovu načíst.
        if info.st_mode & 0o6000 != 0, lstat(path, &info) != 0 { throw posixError() }
    }
    let mode = info.st_mode & 0o7777
    let updated = (mode & ~changes.clearBits) | changes.setBits
    if updated != mode, chmod(path, updated) != 0 { throw posixError() }
    return isDirectory
}

/// Uplatní změny oprávnění na položky (adresáře volitelně rekurzivně, bez
/// následování odkazů); chyby se sbírají a nahlásí najednou.
/// - Parameters:
///   - changes: požadované změny
///   - paths: lokální cesty položek
///   - state: progress (zrušení, počet zpracovaných položek)
func applyPermissionChanges(_ changes: PermissionChanges, to paths: [String], state: ProgressState) throws {
    try applyToLocalItems(paths, recursive: changes.recursive, state: state,
                          failureMessage: tr("Některá oprávnění se nepodařilo změnit")) { path in
        try applyPermissionChanges(changes, at: path)
    }
}

/// Symbolický zápis práv jako v `ls -l` (rwxr-xr-x, s/S/t/T pro zvláštní
/// bity); u nejistého bitu (smíšený stav) otazník.
/// - Parameters:
///   - mode: bity, které jsou nastavené
///   - unknown: bity ve smíšeném stavu
func symbolicMode(_ mode: mode_t, unknown: mode_t = 0) -> String {
    // Trojice (čtení, zápis, spouštění, zvláštní bit, jeho znak) pro u, g, o.
    let triples: [(mode_t, mode_t, mode_t, mode_t, Character)] = [
        (0o400, 0o200, 0o100, 0o4000, "s"),
        (0o040, 0o020, 0o010, 0o2000, "s"),
        (0o004, 0o002, 0o001, 0o1000, "t"),
    ]
    var result = ""
    for (read, write, execute, special, letter) in triples {
        for (bit, char) in [(read, Character("r")), (write, Character("w"))] {
            result.append(unknown & bit != 0 ? "?" : mode & bit != 0 ? char : "-")
        }
        // Spouštění se zvláštním bitem: s/t (i spustitelné), S/T (jen zvláštní bit).
        if unknown & (execute | special) != 0 {
            result.append("?")
        } else if mode & special != 0 {
            result.append(mode & execute != 0 ? letter : Character(letter.uppercased()))
        } else {
            result.append(mode & execute != 0 ? "x" : "-")
        }
    }
    return result
}

/// Dialog Oprávnění (sheet nad hlavním oknem).
final class PermissionsDialog: NSWindowController, NSTextFieldDelegate {
    private var completion: ((PermissionChanges?) -> Void)?

    /// Zaškrtávací pole práv v pořadí čtení/zápis/spouštění × vlastník/skupina/ostatní.
    private let modeBoxes: [(bit: mode_t, box: NSButton)] = [
        0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001,
    ].map { (mode_t($0), NSButton(checkboxWithTitle: "", target: nil, action: nil)) }
    /// Zvláštní bity.
    private let specialBoxes: [(bit: mode_t, box: NSButton)] = [
        (0o4000, NSButton(checkboxWithTitle: "Set UID", target: nil, action: nil)),
        (0o2000, NSButton(checkboxWithTitle: "Set GID", target: nil, action: nil)),
        (0o1000, NSButton(checkboxWithTitle: "Sticky", target: nil, action: nil)),
    ]
    private var allBoxes: [(bit: mode_t, box: NSButton)] { modeBoxes + specialBoxes }

    private let nameLabel = NSTextField(labelWithString: "")
    private let ownerLabel = NSTextField(labelWithString: "")
    private let groupPopup = NSPopUpButton()
    private let octalField = NSTextField()
    private let symbolicLabel = NSTextField(labelWithString: "")
    private let recursiveBox = NSButton(checkboxWithTitle: tr("Včetně podadresářů"), target: nil, action: nil)
    private let scopePopup = NSPopUpButton()
    /// Skupina položek, když je u všech stejná (výběr ve vyskakovacím seznamu
    /// ji pak nemění); nil = různé skupiny.
    private var commonGroup: gid_t?

    /// Otevře dialog; výchozí stav podle položek (bit shodný u všech =
    /// zaškrtnuto/nezaškrtnuto, rozdílný = smíšený, tj. neměnit).
    /// - Parameters:
    ///   - window: hlavní okno
    ///   - itemsDescription: popis měněných položek („jméno“ / N položek)
    ///   - infos: načtená oprávnění položek (bez odkazů)
    ///   - completion: změny, nil = Zrušit
    static func run(on window: NSWindow, itemsDescription: String, infos: [PermissionInfo],
                    completion: @escaping (PermissionChanges?) -> Void) {
        let dialog = PermissionsDialog()
        dialog.completion = completion
        dialog.load(itemsDescription: itemsDescription, infos: infos)
        window.beginSheet(dialog.window!) { _ in
            // Kontroler drží blok sheetu až do zavření.
            _ = dialog
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 452),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = tr("Oprávnění")
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError(tr("Není podporováno"))
    }

    /// Rozvržení: Položky (jméno, vlastník, skupina), Oprávnění (mřížka
    /// u/g/o × r/w/x, zvláštní bity, číselně), Možnosti, tlačítka.
    private func buildContent() {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 420, height: 452))

        // Položky: jméno, vlastník (jen ke čtení – změna vyžaduje root) a skupina.
        content.addSection(tr("Položky"), y: 10)
        let rows: [(String, NSView, CGFloat)] = [(tr("Jméno:"), nameLabel, 32), (tr("Vlastník:"), ownerLabel, 56)]
        for (title, value, y) in rows {
            content.place(NSTextField(labelWithString: title), NSRect(x: 24, y: y, width: 80, height: 17))
            (value as? NSTextField)?.lineBreakMode = .byTruncatingMiddle
            content.place(value, NSRect(x: 110, y: y, width: 296, height: 17))
        }
        content.place(NSTextField(labelWithString: tr("Skupina:")), NSRect(x: 24, y: 82, width: 80, height: 17))
        content.place(groupPopup, NSRect(x: 106, y: 77, width: 220, height: 26))

        // Mřížka práv: sloupce Čtení / Zápis / Spouštění, řádky u / g / o.
        content.addSection(tr("Oprávnění"), y: 118)
        let columns: [CGFloat] = [150, 230, 310]
        for (title, x) in zip([tr("Čtení"), tr("Zápis"), tr("Spouštění")], columns) {
            let label = NSTextField(labelWithString: title)
            label.alignment = .center
            content.place(label, NSRect(x: x - 32, y: 140, width: 80, height: 17))
        }
        for (row, title) in [tr("Vlastník"), tr("Skupina"), tr("Ostatní")].enumerated() {
            let y = 164 + CGFloat(row) * 24
            content.place(NSTextField(labelWithString: title), NSRect(x: 24, y: y, width: 100, height: 17))
            for column in 0..<3 {
                content.place(modeBoxes[row * 3 + column].box, NSRect(x: columns[column], y: y, width: 20, height: 18))
            }
        }
        content.place(NSTextField(labelWithString: tr("Zvláštní:")), NSRect(x: 24, y: 242, width: 80, height: 17))
        for (index, entry) in specialBoxes.enumerated() {
            content.place(entry.box, NSRect(x: 110 + CGFloat(index) * 96, y: 242, width: 90, height: 18))
        }
        for entry in allBoxes {
            entry.box.target = self
            entry.box.action = #selector(boxChanged(_:))
        }
        // Číselný zápis (3 nebo 4 osmičkové číslice) a symbolický náhled.
        content.place(NSTextField(labelWithString: tr("Číselně:")), NSRect(x: 24, y: 274, width: 80, height: 17))
        octalField.delegate = self
        octalField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        content.place(octalField, NSRect(x: 110, y: 271, width: 64, height: 22))
        symbolicLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        symbolicLabel.textColor = .secondaryLabelColor
        content.place(symbolicLabel, NSRect(x: 186, y: 274, width: 200, height: 17))

        // Možnosti: rekurze a rozsah (jen soubory / jen adresáře).
        content.addSection(tr("Možnosti"), y: 308)
        recursiveBox.target = self
        recursiveBox.action = #selector(recursiveChanged(_:))
        content.place(recursiveBox, NSRect(x: 24, y: 332, width: 300, height: 18))
        content.place(NSTextField(labelWithString: tr("Použít na:")), NSRect(x: 44, y: 360, width: 80, height: 17))
        scopePopup.addItems(withTitles: [tr("Soubory i adresáře"), tr("Jen soubory"), tr("Jen adresáře")])
        content.place(scopePopup, NSRect(x: 126, y: 355, width: 200, height: 26))

        // Tlačítka.
        _ = content.addSeparator(y: 392)
        let okButton = NSButton(title: "OK", target: self, action: #selector(okClicked(_:)))
        okButton.keyEquivalent = "\r"
        content.place(okButton, NSRect(x: 204, y: 410, width: 100, height: 28))
        let cancelButton = NSButton(title: tr("Zrušit"), target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        content.place(cancelButton, NSRect(x: 308, y: 410, width: 100, height: 28))
        window?.contentView = content
    }

    /// Výchozí hodnoty podle položek.
    private func load(itemsDescription: String, infos: [PermissionInfo]) {
        nameLabel.stringValue = itemsDescription
        let owners = Set(infos.map(\.uid))
        ownerLabel.stringValue = owners.count == 1 ? userName(owners.first!) : tr("různí")

        // Bity jedním průchodem: nastavený u všech (AND) = zaškrtnuto, u některých
        // (OR bez AND) = smíšený. Smíšený stav se nabízí jen tam, kde opravdu nastal.
        let common = infos.reduce(mode_t(0o7777)) { $0 & $1.mode }
        let any = infos.reduce(mode_t(0)) { $0 | $1.mode }
        for (bit, box) in allBoxes {
            let mixed = (any & ~common) & bit != 0
            box.allowsMixedState = mixed
            box.state = mixed ? .mixed : (common & bit != 0 ? .on : .off)
        }

        // Skupiny: skupiny uživatele + skupina položek; u různých skupin úvodní „neměnit“.
        let groups = Set(infos.map(\.gid))
        commonGroup = groups.count == 1 ? groups.first : nil
        if commonGroup == nil {
            groupPopup.addItem(withTitle: tr("(různé – neměnit)"))
        }
        let choices = currentUserGroups().union(groups)
            .map { (gid: $0, name: groupName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for choice in choices {
            groupPopup.addItem(withTitle: choice.name)
            groupPopup.lastItem?.representedObject = NSNumber(value: choice.gid)
            if choice.gid == commonGroup { groupPopup.select(groupPopup.lastItem) }
        }

        recursiveBox.isEnabled = infos.contains(where: \.isDirectory)
        updateOctalField()
        updateScope()
    }

    /// Nastavené a smíšené bity podle zaškrtávacích polí.
    private var currentBits: (set: mode_t, unknown: mode_t) {
        var set: mode_t = 0
        var unknown: mode_t = 0
        for (bit, box) in allBoxes {
            if box.state == .on { set |= bit }
            if box.state == .mixed { unknown |= bit }
        }
        return (set, unknown)
    }

    /// Číselný a symbolický zápis podle zaškrtávacích polí; smíšený bit číslo nemá.
    private func updateOctalField() {
        let bits = currentBits
        octalField.placeholderString = bits.unknown != 0 ? tr("různé") : nil
        octalField.stringValue = bits.unknown != 0 ? "" : String(format: "%03o", UInt32(bits.set))
        symbolicLabel.stringValue = symbolicMode(bits.set, unknown: bits.unknown)
    }

    /// Rozsah se volí jen při procházení podadresářů.
    private func updateScope() {
        scopePopup.isEnabled = recursiveBox.isEnabled && recursiveBox.state == .on
    }

    @objc private func boxChanged(_ sender: Any?) {
        updateOctalField()
    }

    @objc private func recursiveChanged(_ sender: Any?) {
        updateScope()
    }

    /// Psaní čísla: platné 3–4 osmičkové číslice hned přepíší zaškrtávací pole
    /// (3 číslice = bez zvláštních bitů, jako chmod).
    func controlTextDidChange(_ obj: Notification) {
        let text = octalField.stringValue
        guard (3...4).contains(text.count), text.allSatisfy({ ("0"..."7").contains($0) }),
              let value = mode_t(text, radix: 8) else { return }
        for (bit, box) in allBoxes {
            box.state = value & bit != 0 ? .on : .off
        }
        symbolicLabel.stringValue = symbolicMode(value)
    }

    @objc private func okClicked(_ sender: Any?) {
        var changes = PermissionChanges()
        // Zaškrtnuté bity nastavit, nezaškrtnuté odebrat, smíšené nechat.
        let bits = currentBits
        changes.setBits = bits.set
        changes.clearBits = 0o7777 & ~(bits.set | bits.unknown)
        // Skupina jen při skutečné změně.
        if let gid = (groupPopup.selectedItem?.representedObject as? NSNumber)?.uint32Value, gid != commonGroup {
            changes.group = gid
        }
        changes.recursive = recursiveBox.isEnabled && recursiveBox.state == .on
        // Rozsah jen s procházením podadresářů.
        changes.scope = changes.recursive ? PermissionScope(rawValue: scopePopup.indexOfSelectedItem) ?? .all : .all
        finish(changes)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(nil)
    }

    /// Zavře sheet a předá výsledek.
    private func finish(_ changes: PermissionChanges?) {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        completion?(changes)
        completion = nil
    }
}
