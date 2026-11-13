// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Dialog „Změnit atributy“ (⌘F2 / ⌃F2) podle IDD_ATTRIBUTES Salamandera:
// atributy (Jen pro čtení, Skrytý – třístavově), změna data a času (Změněno,
// Vytvořeno, Otevřeno, Nastavit aktuální) a volba Včetně podadresářů.
// Pracuje s položkami na lokálním disku; Windows atributy (Archivovat,
// Systémový, Komprimovaný, Šifrovaný) jsou kvůli shodnému rozvržení vidět,
// ale macOS je nemá, proto jsou nedostupné.

import AppKit

/// Požadované změny atributů; nil = položku neměnit.
struct AttributeChanges {
    /// Jen pro čtení: true = odebrat právo zápisu všem, false = přidat zápis vlastníkovi.
    var readonly: Bool?
    /// Skrytý (příznak UF_HIDDEN, jako ve Finderu).
    var hidden: Bool?
    var modified: Date?
    var created: Date?
    var accessed: Date?
    /// Změnit i obsah podadresářů.
    var recursive = false
}

/// Chyba posledního systémového volání (errno) jako NSError s popisem.
private func posixError() -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

/// Unixový čas jako timespec (sekundy + nanosekundy).
private func timespecOf(_ date: Date) -> timespec {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    return timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
}

/// Uplatní změny na jednu položku přímo systémovými voláními (nenásledují
/// symbolické odkazy a nepotřebují právo zápisu – stačí být vlastníkem):
/// skrytí `lchflags(UF_HIDDEN)`, změna/otevření `utimensat`, vytvoření
/// `setattrlist(ATTR_CMN_CRTIME)`, práva jedním `chmod` (u odkazu se nemění).
/// - Parameters:
///   - changes: požadované změny
///   - path: lokální cesta položky
/// - Returns: true, pokud je položka adresář (pro rekurzi)
@discardableResult
private func applyAttributeChanges(_ changes: AttributeChanges, at path: String) throws -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { throw posixError() }
    let type = info.st_mode & S_IFMT
    let isLink = type == S_IFLNK

    // Skrytý: příznak UF_HIDDEN (jako Finder).
    if let hidden = changes.hidden {
        let flags = hidden ? info.st_flags | UInt32(UF_HIDDEN) : info.st_flags & ~UInt32(UF_HIDDEN)
        if flags != info.st_flags, lchflags(path, flags) != 0 { throw posixError() }
    }
    // Změněno / Otevřeno: neměněný čas se vynechá (UTIME_OMIT).
    if changes.modified != nil || changes.accessed != nil {
        let omit = timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))
        var times = [changes.accessed.map(timespecOf) ?? omit, changes.modified.map(timespecOf) ?? omit]
        if utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW) != 0 { throw posixError() }
    }
    // Vytvořeno: čas vytvoření přes setattrlist.
    if let created = changes.created {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var time = timespecOf(created)
        if setattrlist(path, &request, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) != 0 {
            throw posixError()
        }
    }
    // Jen pro čtení: true = odebrat zápis všem, false = přidat vlastníkovi.
    if let readonly = changes.readonly, !isLink {
        let mode = info.st_mode & 0o7777
        let updated = readonly ? mode & ~0o222 : mode | 0o200
        if updated != mode, chmod(path, updated) != 0 { throw posixError() }
    }
    return type == S_IFDIR
}

/// Uplatní změny na položky (adresáře volitelně rekurzivně, bez následování
/// odkazů). Chyby jednotlivých položek se sbírají a nahlásí najednou, zbytek
/// se dokončí.
/// - Parameters:
///   - changes: požadované změny
///   - paths: lokální cesty položek
///   - state: progress (zrušení, počet zpracovaných položek)
func applyAttributeChanges(_ changes: AttributeChanges, to paths: [String], state: ProgressState) throws {
    var failures: [String] = []
    var done: UInt64 = 0

    // Jedna položka s evidencí chyb a průběhu; vrací, zda je adresář.
    func apply(_ path: String) -> Bool {
        defer {
            done += 1
            state.update(done: done, total: 0)
        }
        do {
            return try applyAttributeChanges(changes, at: path)
        } catch {
            failures.append("\(path): \(error.localizedDescription)")
            return false
        }
    }

    for path in paths {
        if state.isCancelled { throw CoreError.code(SAL_ERR_CANCELLED, "") }
        // Obsah adresáře jen s volbou Včetně podadresářů.
        guard apply(path), changes.recursive,
              let enumerator = FileManager.default.enumerator(atPath: path) else { continue }
        while let relative = enumerator.nextObject() as? String {
            if state.isCancelled { throw CoreError.code(SAL_ERR_CANCELLED, "") }
            _ = apply((path as NSString).appendingPathComponent(relative))
        }
    }
    if !failures.isEmpty {
        let shown = failures.prefix(10).joined(separator: "\n")
        let more = failures.count > 10 ? "\n… a dalších \(failures.count - 10)" : ""
        throw CoreError.code(SAL_ERR_GENERIC, "Některé atributy se nepodařilo změnit:\n\(shown)\(more)")
    }
}

/// Dialog Změnit atributy (sheet nad hlavním oknem).
final class AttributesDialog: NSWindowController {
    private var completion: ((AttributeChanges?) -> Void)?

    private let readonlyBox = NSButton.triStateCheckbox("Jen pro čtení")
    private let hiddenBox = NSButton.triStateCheckbox("Skrytý")
    private let modifiedBox = NSButton(checkboxWithTitle: "Změněno:", target: nil, action: nil)
    private let createdBox = NSButton(checkboxWithTitle: "Vytvořeno:", target: nil, action: nil)
    private let accessedBox = NSButton(checkboxWithTitle: "Otevřeno:", target: nil, action: nil)
    private let modifiedPicker = NSDatePicker()
    private let createdPicker = NSDatePicker()
    private let accessedPicker = NSDatePicker()
    private let recursiveBox = NSButton(checkboxWithTitle: "Včetně podadresářů", target: nil, action: nil)
    /// Řádky změny data a času: zaškrtávací pole a výběr data.
    private lazy var dateRows = [(modifiedBox, modifiedPicker), (createdBox, createdPicker), (accessedBox, accessedPicker)]

    /// Otevře dialog pro položky; výchozí stav atributů podle položek (shodný =
    /// zaškrtnuto/nezaškrtnuto, rozdílný = smíšený), časy podle první položky.
    /// - Parameters:
    ///   - window: hlavní okno
    ///   - items: měněné položky
    ///   - firstPath: lokální cesta první položky (výchozí časy)
    ///   - completion: změny, nil = Storno
    static func run(on window: NSWindow, items: [Item], firstPath: String,
                    completion: @escaping (AttributeChanges?) -> Void) {
        let dialog = AttributesDialog()
        dialog.completion = completion
        dialog.load(items: items, firstPath: firstPath)
        window.beginSheet(dialog.window!) { _ in
            // Kontroler drží blok sheetu až do zavření.
            _ = dialog
        }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 372),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Změnit atributy"
        super.init(window: window)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Rozvržení podle IDD_ATTRIBUTES: Atributy, Změna data a času, Možnosti.
    private func buildContent() {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 380, height: 372))

        // Atributy; Windows atributy jen pro shodné rozvržení (nedostupné).
        content.addSection("Atributy", y: 10)
        let archiveBox = NSButton(checkboxWithTitle: "Archivovat", target: nil, action: nil)
        let compressedBox = NSButton(checkboxWithTitle: "Komprimovaný", target: nil, action: nil)
        let systemBox = NSButton(checkboxWithTitle: "Systémový", target: nil, action: nil)
        let encryptedBox = NSButton(checkboxWithTitle: "Šifrovaný", target: nil, action: nil)
        for box in [archiveBox, compressedBox, systemBox, encryptedBox] { box.isEnabled = false }
        content.place(archiveBox, NSRect(x: 24, y: 32, width: 110, height: 18))
        content.place(hiddenBox, NSRect(x: 140, y: 32, width: 100, height: 18))
        content.place(compressedBox, NSRect(x: 246, y: 32, width: 124, height: 18))
        content.place(readonlyBox, NSRect(x: 24, y: 54, width: 110, height: 18))
        content.place(systemBox, NSRect(x: 140, y: 54, width: 100, height: 18))
        content.place(encryptedBox, NSRect(x: 246, y: 54, width: 124, height: 18))

        // Změna data a času: zaškrtnuté hodnoty se nastaví, ostatní se nemění.
        content.addSection("Změna data a času", y: 90)
        for (index, (box, picker)) in dateRows.enumerated() {
            let y = 114 + CGFloat(index) * 30
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            box.target = self
            box.action = #selector(dateBoxChanged(_:))
            content.place(box, NSRect(x: 24, y: y + 2, width: 110, height: 18))
            content.place(picker, NSRect(x: 140, y: y, width: 228, height: 24))
        }
        let currentButton = NSButton(title: "Nastavit aktuální", target: self, action: #selector(setCurrentClicked(_:)))
        content.place(currentButton, NSRect(x: 228, y: 204, width: 140, height: 28))

        // Možnosti.
        content.addSection("Možnosti", y: 246)
        content.place(recursiveBox, NSRect(x: 24, y: 270, width: 300, height: 18))

        // Tlačítka.
        let line = NSBox(frame: NSRect(x: 12, y: 306, width: 356, height: 1))
        line.boxType = .separator
        content.addSubview(line)
        let okButton = NSButton(title: "OK", target: self, action: #selector(okClicked(_:)))
        okButton.keyEquivalent = "\r"
        content.place(okButton, NSRect(x: 164, y: 322, width: 100, height: 28))
        let cancelButton = NSButton(title: "Zrušit", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        content.place(cancelButton, NSRect(x: 268, y: 322, width: 100, height: 28))
        window?.contentView = content
    }

    /// Výchozí hodnoty podle položek.
    private func load(items: [Item], firstPath: String) {
        // Shodný atribut u všech položek = zaškrtnuto/nezaškrtnuto, jinak smíšený.
        func state(_ value: (Item) -> Bool) -> NSControl.StateValue {
            let values = Set(items.map(value))
            return values.count == 1 ? (values.first! ? .on : .off) : .mixed
        }
        readonlyBox.state = state(\.isReadonly)
        hiddenBox.state = state(\.isHidden)
        let values = try? URL(fileURLWithPath: firstPath)
            .resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .contentAccessDateKey])
        modifiedPicker.dateValue = values?.contentModificationDate ?? Date()
        createdPicker.dateValue = values?.creationDate ?? Date()
        accessedPicker.dateValue = values?.contentAccessDate ?? Date()
        recursiveBox.isEnabled = items.contains(where: \.isRealDir)
        updateDatePickers()
    }

    /// Časové pole je aktivní jen se zaškrtnutou hodnotou.
    private func updateDatePickers() {
        for (box, picker) in dateRows {
            picker.isEnabled = box.state == .on
        }
    }

    @objc private func dateBoxChanged(_ sender: Any?) {
        updateDatePickers()
    }

    /// Nastavit aktuální: všechny tři časy na teď (a zaškrtnout je).
    @objc private func setCurrentClicked(_ sender: Any?) {
        let now = Date()
        for (box, picker) in dateRows {
            box.state = .on
            picker.dateValue = now
        }
        updateDatePickers()
    }

    @objc private func okClicked(_ sender: Any?) {
        func flag(_ box: NSButton) -> Bool? {
            box.state == .mixed ? nil : box.state == .on
        }
        var changes = AttributeChanges()
        changes.readonly = flag(readonlyBox)
        changes.hidden = flag(hiddenBox)
        changes.modified = modifiedBox.state == .on ? modifiedPicker.dateValue : nil
        changes.created = createdBox.state == .on ? createdPicker.dateValue : nil
        changes.accessed = accessedBox.state == .on ? accessedPicker.dateValue : nil
        changes.recursive = recursiveBox.isEnabled && recursiveBox.state == .on
        finish(changes)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(nil)
    }

    /// Zavře sheet a předá výsledek.
    private func finish(_ changes: AttributeChanges?) {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        completion?(changes)
        completion = nil
    }
}
