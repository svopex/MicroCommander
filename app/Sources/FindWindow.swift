// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Okno „Vyhledat soubory a adresáře“ (Ctrl+F / Alt+F7) podle dialogu Find
// Salamandera (IDD_FIND v samandarin/src/lang/lang.rc, menu FindMenuTemplate
// v menu4.cpp): Název, Hledat v, Včetně podadresářů, Hledat v souboru
// (Obsahující + Šestnáctkový režim / Rozlišovat malá a velká písmena / Celá
// slova / Regulární výraz), Upřesnit… (atributy, velikost, datum a čas),
// seznam nalezených položek a stavový řádek. Okno je nemodální – během
// hledání lze pracovat s hlavním oknem a otevřít víc oken hledání. Dokud je
// okno aktivní, hlavní menu aplikace nahradí menu dialogu (Soubory, Příkazy,
// Upravit, Zobrazit, Možnosti) jako v originále.

import AppKit

// MARK: - Upřesnit (pokročilá kritéria)

/// Kritéria dialogu Upřesnit možnosti (atributy, velikost, datum a čas).
/// Atributy jsou třístavové: nil = ignorovat, true = musí mít, false = nesmí mít.
struct FindAdvanced: Codable, Equatable {
    var readonly: Bool?
    var hidden: Bool?
    var encrypted: Bool?
    var directory: Bool?
    var useMinSize = false
    var minSize: UInt64 = 0
    var minUnit = 0
    var useMaxSize = false
    var maxSize: UInt64 = 0
    var maxUnit = 0
    /// Datum a čas: 0 = ignorovat, 1 = změněno během, 2 = změněno od–do.
    var timeMode = 0
    var duringValue = 1
    var duringUnit = 3
    var useFrom = false
    var from = Date()
    var useTo = false
    var to = Date()

    /// Jednotky velikosti (násobky 1024).
    static let sizeUnits = ["B", "KB", "MB", "GB"]
    /// Jednotky „Změněno během“ a jejich délka v sekundách.
    static let duringUnits: [(String, Double)] = [
        ("sekund", 1), ("minut", 60), ("hodin", 3600), ("dnů", 86400),
        ("týdnů", 7 * 86400), ("měsíců", 30 * 86400), ("let", 365 * 86400),
    ]

    /// Velikost v bajtech podle hodnoty a jednotky.
    private static func bytes(_ value: UInt64, unit: Int) -> UInt64 {
        value.multipliedReportingOverflow(by: UInt64(1) << (10 * UInt64(unit))).partialValue
    }

    /// Text vedle tlačítka Upřesnit (jako GetAdvancedDescription v filter.cpp).
    var summary: String {
        var parts: [String] = []
        // Atributy ve tvaru +R-H…
        var attributes = ""
        for (value, letter) in [(readonly, "R"), (hidden, "H"), (encrypted, "E"), (directory, "D")] {
            if let value { attributes += (value ? "+" : "-") + letter }
        }
        if !attributes.isEmpty { parts.append("Atributy: " + attributes) }
        if useMinSize || useMaxSize { parts.append("Velikost") }
        if timeMode == 1 { parts.append(duringUnit >= 3 ? "Datum" : "Čas") }
        if timeMode == 2 && (useFrom || useTo) { parts.append("Datum") }
        return isActive ? "Používá možnosti: " + parts.joined(separator: ", ") : "Žádné možnosti"
    }

    /// Používá dialog nějaké kritérium?
    var isActive: Bool {
        readonly != nil || hidden != nil || encrypted != nil || directory != nil
            || useMinSize || useMaxSize || timeMode == 1 || (timeMode == 2 && (useFrom || useTo))
    }

    /// Vyhoví položka kritériím? Velikost se testuje jen u souborů.
    func matches(_ item: Item, now: Date) -> Bool {
        // Třístavové atributy: nil = libovolně, jinak musí odpovídat.
        if let readonly, readonly != item.isReadonly { return false }
        if let hidden, hidden != item.isHidden { return false }
        if let encrypted, encrypted != item.isEncrypted { return false }
        if let directory, directory != item.isDir { return false }
        if !item.isDir {
            if useMinSize && item.size < Self.bytes(minSize, unit: minUnit) { return false }
            if useMaxSize && item.size > Self.bytes(maxSize, unit: maxUnit) { return false }
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(item.mtime))
        switch timeMode {
        case 1:
            // Změněno během posledních N jednotek.
            let seconds = Double(max(duringValue, 0)) * Self.duringUnits[min(max(duringUnit, 0), Self.duringUnits.count - 1)].1
            if modified < now.addingTimeInterval(-seconds) { return false }
        case 2:
            if useFrom && modified < from { return false }
            if useTo && modified > to { return false }
        default:
            break
        }
        return true
    }
}

/// Dialog Upřesnit možnosti (sheet nad oknem hledání).
final class FindAdvancedController: NSWindowController {
    private var result: FindAdvanced
    private var completion: ((FindAdvanced?) -> Void)?

    private let readonlyBox = NSButton.triStateCheckbox("&Jen pro čtení")
    private let hiddenBox = NSButton.triStateCheckbox("&Skrytý")
    private let encryptedBox = NSButton.triStateCheckbox("Ši&frovaný")
    private let directoryBox = NSButton.triStateCheckbox("Ad&resář")
    private let minSizeBox = NSButton(checkboxWithTitle: "Nejméně:", target: nil, action: nil)
    private let minSizeField = NSTextField()
    private let minUnitPopup = NSPopUpButton()
    private let maxSizeBox = NSButton(checkboxWithTitle: "Nejvýše:", target: nil, action: nil)
    private let maxSizeField = NSTextField()
    private let maxUnitPopup = NSPopUpButton()
    private let ignoreRadio = NSButton(radioButtonWithTitle: "Ignorovat", target: nil, action: nil)
    private let duringRadio = NSButton(radioButtonWithTitle: "Změněno během:", target: nil, action: nil)
    private let fromToRadio = NSButton(radioButtonWithTitle: "Změněno od:", target: nil, action: nil)
    private let duringField = NSTextField()
    private let duringUnitPopup = NSPopUpButton()
    private let fromBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let fromPicker = NSDatePicker()
    private let toBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let toPicker = NSDatePicker()

    /// Otevře dialog jako sheet.
    /// - Parameters:
    ///   - parent: okno hledání
    ///   - value: aktuální kritéria
    ///   - completion: nová kritéria, nil = Storno
    static func run(on parent: NSWindow, value: FindAdvanced, completion: @escaping (FindAdvanced?) -> Void) {
        let controller = FindAdvancedController(value: value)
        controller.completion = completion
        parent.beginSheet(controller.window!) { _ in
            // Kontroler drží blok sheetu až do zavření.
            _ = controller
        }
    }

    private init(value: FindAdvanced) {
        result = value
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 404),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Upřesnit možnosti"
        super.init(window: window)
        buildContent()
        load(value)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Rozvržení podle IDD_FINDADVANCED (Atributy, Velikost souboru, Datum a čas).
    private func buildContent() {
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 404))

        // Atributy: Windows-only atributy (Archivovat, Systémový, Komprimovaný)
        // macOS nemá – zobrazí se jako nedostupné, aby rozvržení odpovídalo originálu.
        content.addSection("Atributy", y: 10)
        let archiveBox = NSButton(checkboxWithTitle: "Archivovat", target: nil, action: nil)
        let systemBox = NSButton(checkboxWithTitle: "Systémový", target: nil, action: nil)
        let compressedBox = NSButton(checkboxWithTitle: "Komprimovaný", target: nil, action: nil)
        for box in [archiveBox, systemBox, compressedBox] { box.isEnabled = false }
        content.place(archiveBox, NSRect(x: 24, y: 32, width: 120, height: 18))
        content.place(hiddenBox, NSRect(x: 146, y: 32, width: 110, height: 18))
        content.place(compressedBox, NSRect(x: 260, y: 32, width: 130, height: 18))
        content.place(readonlyBox, NSRect(x: 24, y: 54, width: 120, height: 18))
        content.place(systemBox, NSRect(x: 146, y: 54, width: 110, height: 18))
        content.place(encryptedBox, NSRect(x: 260, y: 54, width: 130, height: 18))
        content.place(directoryBox, NSRect(x: 24, y: 76, width: 120, height: 18))

        // Velikost souboru: nejméně / nejvýše s jednotkou.
        content.addSection("Velikost souboru", y: 106)
        minUnitPopup.addItems(withTitles: FindAdvanced.sizeUnits)
        maxUnitPopup.addItems(withTitles: FindAdvanced.sizeUnits)
        content.place(minSizeBox, NSRect(x: 24, y: 130, width: 110, height: 18))
        content.place(minSizeField, NSRect(x: 146, y: 128, width: 120, height: 22))
        content.place(minUnitPopup, NSRect(x: 274, y: 126, width: 114, height: 26))
        content.place(maxSizeBox, NSRect(x: 24, y: 158, width: 110, height: 18))
        content.place(maxSizeField, NSRect(x: 146, y: 156, width: 120, height: 22))
        content.place(maxUnitPopup, NSRect(x: 274, y: 154, width: 114, height: 26))

        // Datum a čas: ignorovat / změněno během / změněno od–do.
        content.addSection("Datum a čas", y: 192)
        for radio in [ignoreRadio, duringRadio, fromToRadio] {
            radio.target = self
            radio.action = #selector(timeModeChanged(_:))
        }
        duringUnitPopup.addItems(withTitles: FindAdvanced.duringUnits.map(\.0))
        for picker in [fromPicker, toPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        }
        content.place(ignoreRadio, NSRect(x: 24, y: 216, width: 200, height: 18))
        content.place(duringRadio, NSRect(x: 24, y: 242, width: 120, height: 18))
        content.place(duringField, NSRect(x: 146, y: 240, width: 120, height: 22))
        content.place(duringUnitPopup, NSRect(x: 274, y: 238, width: 114, height: 26))
        content.place(fromToRadio, NSRect(x: 24, y: 270, width: 120, height: 18))
        content.place(fromBox, NSRect(x: 146, y: 270, width: 20, height: 18))
        content.place(fromPicker, NSRect(x: 168, y: 267, width: 220, height: 24))
        let toLabel = NSTextField(labelWithString: "Do:")
        toLabel.alignment = .right
        content.place(toLabel, NSRect(x: 100, y: 300, width: 40, height: 17))
        content.place(toBox, NSRect(x: 146, y: 299, width: 20, height: 18))
        content.place(toPicker, NSRect(x: 168, y: 296, width: 220, height: 24))
        let note = NSTextField(labelWithString: "Poznámka: nezaškrtnuté hodnoty se ignorují")
        note.alignment = .right
        note.textColor = .secondaryLabelColor
        content.place(note, NSRect(x: 12, y: 328, width: 376, height: 17))

        // Tlačítka: Obnovit (výchozí hodnoty), OK, Storno.
        let line = NSBox(frame: NSRect(x: 12, y: 354, width: 376, height: 1))
        line.boxType = .separator
        content.addSubview(line)
        let resetButton = NSButton(title: "Obnovit", target: self, action: #selector(resetClicked(_:)))
        content.place(resetButton, NSRect(x: 12, y: 366, width: 100, height: 28))
        let okButton = NSButton(title: "OK", target: self, action: #selector(okClicked(_:)))
        okButton.keyEquivalent = "\r"
        content.place(okButton, NSRect(x: 184, y: 366, width: 100, height: 28))
        let cancelButton = NSButton(title: "Zrušit", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        content.place(cancelButton, NSRect(x: 288, y: 366, width: 100, height: 28))
        window?.contentView = content
    }

    /// Hodnoty kritérií do ovládacích prvků.
    private func load(_ value: FindAdvanced) {
        func state(_ flag: Bool?) -> NSControl.StateValue {
            guard let flag else { return .mixed }
            return flag ? .on : .off
        }
        readonlyBox.state = state(value.readonly)
        hiddenBox.state = state(value.hidden)
        encryptedBox.state = state(value.encrypted)
        directoryBox.state = state(value.directory)
        minSizeBox.state = value.useMinSize ? .on : .off
        minSizeField.stringValue = String(value.minSize)
        minUnitPopup.selectItem(at: value.minUnit)
        maxSizeBox.state = value.useMaxSize ? .on : .off
        maxSizeField.stringValue = String(value.maxSize)
        maxUnitPopup.selectItem(at: value.maxUnit)
        [ignoreRadio, duringRadio, fromToRadio][min(max(value.timeMode, 0), 2)].state = .on
        duringField.stringValue = String(value.duringValue)
        duringUnitPopup.selectItem(at: value.duringUnit)
        fromBox.state = value.useFrom ? .on : .off
        fromPicker.dateValue = value.from
        toBox.state = value.useTo ? .on : .off
        toPicker.dateValue = value.to
        updateTimeControls()
    }

    /// Ovládací prvky data/času jsou aktivní jen pro zvolený režim.
    private func updateTimeControls() {
        let during = duringRadio.state == .on
        let fromTo = fromToRadio.state == .on
        duringField.isEnabled = during
        duringUnitPopup.isEnabled = during
        for control in [fromBox, fromPicker, toBox, toPicker] as [NSControl] {
            control.isEnabled = fromTo
        }
    }

    @objc private func timeModeChanged(_ sender: Any?) {
        updateTimeControls()
    }

    @objc private func resetClicked(_ sender: Any?) {
        load(FindAdvanced())
    }

    @objc private func okClicked(_ sender: Any?) {
        func flag(_ box: NSButton) -> Bool? {
            box.state == .mixed ? nil : box.state == .on
        }
        // Číselné hodnoty: neplatné nebo prázdné vstupy dialog nepustí dál.
        guard let minSize = UInt64(minSizeField.stringValue.trimmingCharacters(in: .whitespaces)),
              let maxSize = UInt64(maxSizeField.stringValue.trimmingCharacters(in: .whitespaces)),
              let during = Int(duringField.stringValue.trimmingCharacters(in: .whitespaces)), during >= 0 else {
            NSSound.beep()
            return
        }
        result.readonly = flag(readonlyBox)
        result.hidden = flag(hiddenBox)
        result.encrypted = flag(encryptedBox)
        result.directory = flag(directoryBox)
        result.useMinSize = minSizeBox.state == .on
        result.minSize = minSize
        result.minUnit = minUnitPopup.indexOfSelectedItem
        result.useMaxSize = maxSizeBox.state == .on
        result.maxSize = maxSize
        result.maxUnit = maxUnitPopup.indexOfSelectedItem
        result.timeMode = duringRadio.state == .on ? 1 : (fromToRadio.state == .on ? 2 : 0)
        result.duringValue = during
        result.duringUnit = duringUnitPopup.indexOfSelectedItem
        result.useFrom = fromBox.state == .on
        result.from = fromPicker.dateValue
        result.useTo = toBox.state == .on
        result.to = toPicker.dateValue
        finish(result)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(nil)
    }

    /// Zavře sheet a předá výsledek.
    private func finish(_ value: FindAdvanced?) {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        completion?(value)
        completion = nil
    }
}

/// Pohled s počátkem vlevo nahoře (snazší rozvržení dialogů shora dolů).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    /// Nadpis oddílu dialogu s vodorovnou čarou do pravého okraje (jako v Salamanderu).
    /// - Parameters:
    ///   - title: text nadpisu
    ///   - y: svislá poloha nadpisu
    func addSection(_ title: String, y: CGFloat) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 12, y: y, width: 200, height: 17)
        label.sizeToFit()
        addSubview(label)
        let line = NSBox(frame: NSRect(x: label.frame.maxX + 6, y: y + 9, width: bounds.width - 12 - label.frame.maxX - 6, height: 1))
        line.boxType = .separator
        addSubview(line)
    }

    /// Vodorovná čára přes šířku dialogu (oddělovač oddílů).
    /// - Parameter y: svislá poloha oddílu, který čára uzavírá
    /// - Returns: svislá poloha pro další obsah pod čarou
    func addSeparator(y: CGFloat) -> CGFloat {
        let line = NSBox(frame: NSRect(x: 12, y: y + 4, width: bounds.width - 24, height: 1))
        line.boxType = .separator
        addSubview(line)
        return y + 18
    }

    /// Přidá prvek s danou polohou.
    func place(_ view: NSView, _ frame: NSRect) {
        view.frame = frame
        addSubview(view)
    }
}

extension NSButton {
    /// Třístavové zaškrtávací pole (smíšený stav = neměnit / ignorovat);
    /// znak „&“ (akcelerátor z předlohy Salamandera) se z titulku odstraní.
    static func triStateCheckbox(_ title: String) -> NSButton {
        let box = NSButton(checkboxWithTitle: title.replacingOccurrences(of: "&", with: ""), target: nil, action: nil)
        box.allowsMixedState = true
        return box
    }
}

// MARK: - Seznam nalezených položek

/// Tabulka nalezených položek: klávesy dialogu Find (Enter, Shift+Enter,
/// mezerník, F3, F4, F8/Delete, Alt+Insert…) předává oknu hledání.
final class FoundTableView: NSTableView {
    /// Obsluha kláves; true = klávesa zpracována.
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Řádek seznamu: VFS cesta a položka.
private struct FoundRow {
    let path: String
    let item: Item
    /// Adresář položky pro sloupec Cesta.
    var dir: String { parentPath(path) }
}

/// Sloupce seznamu nalezených položek (jako v originále; Atributy nejdou řadit).
private enum FoundColumn: String, CaseIterable {
    case name, path, size, date, time, attr

    var title: String {
        switch self {
        case .name: return "Název"
        case .path: return "Cesta"
        case .size: return "Velikost"
        case .date: return "Datum"
        case .time: return "Čas"
        case .attr: return "Atributy"
        }
    }

    /// Výchozí šířka sloupce.
    var width: CGFloat {
        switch self {
        case .name: return 170
        case .path: return 230
        case .size: return 80
        case .date: return 76
        case .time: return 64
        case .attr: return 56
        }
    }

    /// Klíč řazení (Datum a Čas sdílejí čas změny, Atributy řadit nejde).
    var sortKey: FoundSort? {
        switch self {
        case .name: return .name
        case .path: return .path
        case .size: return .size
        case .date, .time: return .time
        case .attr: return nil
        }
    }
}

/// Řazení seznamu (Datum a Čas sdílejí jeden klíč).
private enum FoundSort {
    case name, path, time, size
}

/// Režim spuštění hledání (tlačítko Najít a jeho rozbalovací nabídka).
private enum FindMode {
    /// Najít – vyprázdní seznam a hledá znovu.
    case now
    /// Připojit k nalezeným položkám – seznam nevyprazdňuje.
    case append
    /// Vytřídit – Průnik: ponechá jen položky splňující kritéria.
    case intersect
    /// Vytřídit – Odečíst: odebere položky splňující kritéria.
    case subtract
}

// MARK: - Okno hledání

/// Okno Vyhledat soubory a adresáře.
final class FindWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                  NSTableViewDelegate, NSComboBoxDelegate, NSMenuItemValidation {
    /// Otevřená okna hledání (drží kontrolery naživu).
    private static var openWindows: [FindWindowController] = []
    /// Titulek okna (IDS_FF_NAME).
    private static let baseTitle = "Vyhledat soubory a adresáře"
    /// Příkazy hledání (menu Příkazy i nabídka u tlačítka Najít): titulek, akce, klávesa s Ctrl.
    private static let findCommands: [(title: String, action: Selector, key: String)] = [
        ("Najít", #selector(findNowClicked(_:)), "f"),
        ("Vytřídit - Průnik s nalezenými položkami", #selector(intersectClicked(_:)), "i"),
        ("Vytřídit - Odečíst od nalezených položek", #selector(subtractClicked(_:)), "s"),
        ("Připojit k nalezeným položkám", #selector(appendClicked(_:)), "w"),
    ]
    /// Maximální délka historie rozbalovacích polí.
    private static let historyLimit = 20

    private weak var mainController: MainWindowController?
    /// Prohledávaný souborový systém: lokální disk (cesty = skutečné cesty)
    /// nebo VFS aktivního panelu (archiv, FTP/SFTP – cesty uvnitř VFS).
    private let vfs: Vfs

    // Ovládací prvky podle IDD_FIND.
    private let content = FlippedView()
    private let topLine = NSBox()
    private let namedLabel = NSTextField(labelWithString: "Název:")
    private let namedCombo = NSComboBox()
    private let findButton = NSButton(title: "Najít", target: nil, action: nil)
    private let findMenuButton = NSButton(title: "", target: nil, action: nil)
    private let lookInLabel = NSTextField(labelWithString: "Hledat v:")
    private let lookInCombo = NSComboBox()
    private let addButton = NSButton(title: "Přidat", target: nil, action: nil)
    private let subdirsBox = NSButton(checkboxWithTitle: "Včetně podadresářů", target: nil, action: nil)
    private let archivesBox = NSButton(checkboxWithTitle: "Hledat v archivech", target: nil, action: nil)
    private let grepBox = NSButton(checkboxWithTitle: "Hledat v souboru", target: nil, action: nil)
    private let grepLine = NSBox()
    private let containingLabel = NSTextField(labelWithString: "Obsahující:")
    private let containingCombo = NSComboBox()
    private let regexHelpButton = NSButton(title: "", target: nil, action: nil)
    private let hexBox = NSButton(checkboxWithTitle: "Šestnáctkový režim", target: nil, action: nil)
    private let caseBox = NSButton(checkboxWithTitle: "Rozlišovat malá a velká písmena", target: nil, action: nil)
    private let wholeBox = NSButton(checkboxWithTitle: "Celá slova", target: nil, action: nil)
    private let regexBox = NSButton(checkboxWithTitle: "Regulární výraz", target: nil, action: nil)
    private let advancedButton = NSButton(title: "Upřesnit…", target: nil, action: nil)
    private let advancedField = NSTextField()
    private let foundLabel = NSTextField(labelWithString: "")
    private let headerToolbar = NSStackView()
    private var stopButton: NSButton!
    private let scrollView = NSScrollView()
    private let tableView = FoundTableView()
    private let statusLabel = NSTextField(labelWithString: "")

    // Stav hledání a výsledky.
    private var rows: [FoundRow] = []
    private var advanced = FindAdvanced()
    private var runningState: ProgressState?
    private var sort: FoundSort = .name
    private var sortAscending = true
    /// Menu dialogu (nahrazuje hlavní menu, dokud je okno aktivní).
    private var findMenu: NSMenu!
    /// Původní hlavní menu aplikace (vrací se při deaktivaci okna).
    private var savedMainMenu: NSMenu?

    /// Řadit soubory a adresáře dohromady (Možnosti; jinak adresáře nahoře).
    private var sortMixed: Bool {
        get { UserDefaults.standard.bool(forKey: "findSortMixed") }
        set { UserDefaults.standard.set(newValue, forKey: "findSortMixed") }
    }

    /// Otevřená okna hledání (pro self-test).
    static var windows: [FindWindowController] { openWindows }
    /// Počet nalezených položek a běží hledání? (pro self-test).
    var foundCount: Int { rows.count }
    var isSearching: Bool { runningState != nil }

    /// Otevře nové okno hledání s výchozím adresářem aktivního panelu
    /// (jako Ctrl+F / Alt+F7 v Salamanderu; každé volání otevře další okno).
    static func show(owner: MainWindowController) {
        let controller = FindWindowController(owner: owner)
        openWindows.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.namedCombo)
    }

    private init(owner: MainWindowController) {
        self.mainController = owner
        let panel = owner.activePanel
        // Lokální panel: hledá se přes kořen disku (skutečné cesty, Hledat v lze
        // libovolně měnit); jinak ve VFS panelu (archiv, FTP/SFTP).
        let panelVfs = panel.location.vfs
        let localRoot = panelVfs.kind == SAL_VFS_LOCAL ? Vfs.localDisk : nil
        vfs = localRoot ?? panelVfs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Self.baseTitle
        window.minSize = NSSize(width: 520, height: 400)
        window.setFrameAutosaveName("FindWindow")
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false

        buildControls()
        buildMenu()
        loadState(lookIn: localRoot != nil ? panel.displayPath : panel.location.path)
        window.contentView = content
        layoutControls()
        // Další okna se posunou, aby se nepřekrývala úplně.
        if let last = Self.openWindows.last?.window, last.isVisible {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else if window.frame.origin == .zero {
            window.center()
        }
        setStatus("Zadejte možnosti hledání a klepněte na tlačítko Najít.")
        updateFoundLabel()
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    // MARK: Ovládací prvky

    /// Vytvoří ovládací prvky dialogu (rozmístí je `layoutControls`).
    private func buildControls() {
        topLine.boxType = .separator
        grepLine.boxType = .separator

        // Rozbalovací pole s historií; Enter v nich spustí Najít (viz delegát).
        for combo in [namedCombo, lookInCombo, containingCombo] {
            combo.completes = false
            combo.numberOfVisibleItems = 12
            combo.delegate = self
            combo.cell?.lineBreakMode = .byTruncatingHead
            combo.cell?.isScrollable = true
        }

        findButton.target = self
        findButton.action = #selector(findNowClicked(_:))
        findButton.bezelStyle = .rounded
        // Šipka vedle Najít = nabídka dalších příkazů (Průnik, Odečíst, Připojit).
        findMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Další příkazy hledání")
        findMenuButton.imagePosition = .imageOnly
        findMenuButton.bezelStyle = .rounded
        findMenuButton.target = self
        findMenuButton.action = #selector(findMenuClicked(_:))

        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        addButton.bezelStyle = .rounded
        // Hledání v archivech jádro zatím neumí – volba je vidět, ale nedostupná.
        archivesBox.isEnabled = false
        archivesBox.toolTip = "Hledání uvnitř archivů zatím není podporováno."

        grepBox.target = self
        grepBox.action = #selector(grepToggled(_:))
        for box in [hexBox, regexBox] {
            box.target = self
            box.action = #selector(contentOptionChanged(_:))
        }
        regexHelpButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Regulární výrazy")
        regexHelpButton.imagePosition = .imageOnly
        regexHelpButton.bezelStyle = .rounded
        regexHelpButton.target = self
        regexHelpButton.action = #selector(regexHelpClicked(_:))

        advancedButton.target = self
        advancedButton.action = #selector(advancedClicked(_:))
        advancedButton.bezelStyle = .rounded
        advancedField.isEditable = false
        advancedField.isSelectable = false
        advancedField.lineBreakMode = .byTruncatingTail

        // Nástrojová lišta vpravo nad seznamem (Ukázat, Zobrazit, Upravit,
        // Odstranit, Vyjmout, Kopírovat, Zastavit) jako hlavička originálu.
        let tools: [(String, String, Selector)] = [
            ("scope", "Ukázat položku (mezerník)", #selector(focusItem(_:))),
            ("eye", "Zobrazit soubor (F3)", #selector(viewItem(_:))),
            ("square.and.pencil", "Upravit soubor (F4)", #selector(editItem(_:))),
            ("trash", "Odstranit do koše (F8, ⇧F8 trvale)", #selector(deleteItems(_:))),
            ("scissors", "Vyjmout (⌘X)", #selector(cut(_:))),
            ("doc.on.doc", "Kopírovat (⌘C)", #selector(copy(_:))),
            ("stop.circle", "Zastavit (Escape)", #selector(stopClicked(_:))),
        ]
        headerToolbar.orientation = .horizontal
        headerToolbar.spacing = 2
        for (symbol, tip, action) in tools {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                                  target: self, action: action)
            button.isBordered = false
            button.toolTip = tip
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            headerToolbar.addArrangedSubview(button)
            if action == #selector(stopClicked(_:)) { stopButton = button }
        }
        stopButton.isEnabled = false

        // Tabulka nalezených položek: Název, Cesta, Velikost, Datum, Čas, Atributy.
        for column in FoundColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 30
            if column == .size { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openItem(_:))
        tableView.keyHandler = { [weak self] event in self?.tableKeyDown(event) ?? false }
        tableView.menu = makeFilesMenu(withShortcuts: false)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.textColor = .secondaryLabelColor

        for view in [topLine, namedLabel, namedCombo, findButton, findMenuButton, lookInLabel, lookInCombo,
                     addButton, subdirsBox, archivesBox, grepBox, grepLine, containingLabel, containingCombo,
                     regexHelpButton, hexBox, caseBox, wholeBox, regexBox, advancedButton, advancedField,
                     foundLabel, headerToolbar, scrollView, statusLabel] as [NSView] {
            content.addSubview(view)
        }
    }

    /// Rozmístí ovládací prvky podle šířky okna; část „Obsahující“ je vidět jen
    /// se zaškrtnutým „Hledat v souboru“ (jako SetContentVisible v originále).
    private func layoutControls() {
        let width = content.bounds.width > 0 ? content.bounds.width : 640
        let height = content.bounds.height > 0 ? content.bounds.height : 520
        let margin: CGFloat = 12
        let comboX: CGFloat = 104
        let buttonWidth: CGFloat = 96
        let rightEdge = width - margin
        let comboWidth = rightEdge - buttonWidth - 8 - comboX

        topLine.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        namedLabel.frame = NSRect(x: margin, y: 15, width: comboX - margin - 4, height: 17)
        namedCombo.frame = NSRect(x: comboX, y: 11, width: comboWidth, height: 25)
        findButton.frame = NSRect(x: rightEdge - buttonWidth, y: 9, width: buttonWidth - 26, height: 28)
        findMenuButton.frame = NSRect(x: rightEdge - 28, y: 9, width: 28, height: 28)
        lookInLabel.frame = NSRect(x: margin, y: 47, width: comboX - margin - 4, height: 17)
        lookInCombo.frame = NSRect(x: comboX, y: 43, width: comboWidth, height: 25)
        addButton.frame = NSRect(x: rightEdge - buttonWidth, y: 41, width: buttonWidth, height: 28)
        subdirsBox.frame = NSRect(x: comboX, y: 76, width: 180, height: 18)
        archivesBox.frame = NSRect(x: comboX + 190, y: 76, width: 180, height: 18)
        grepBox.frame = NSRect(x: margin, y: 102, width: 140, height: 18)
        grepLine.frame = NSRect(x: margin + 144, y: 111, width: rightEdge - margin - 144, height: 1)

        // Část „Obsahující“ se sbaluje; prvky pod ní se posunou nahoru.
        let expanded = grepBox.state == .on
        for view in [containingLabel, containingCombo, regexHelpButton, hexBox, caseBox, wholeBox, regexBox] as [NSView] {
            view.isHidden = !expanded
        }
        var y: CGFloat = 128
        if expanded {
            containingLabel.frame = NSRect(x: margin, y: y + 4, width: comboX - margin - 4, height: 17)
            containingCombo.frame = NSRect(x: comboX, y: y, width: rightEdge - 34 - comboX, height: 25)
            regexHelpButton.frame = NSRect(x: rightEdge - 28, y: y - 2, width: 28, height: 28)
            hexBox.frame = NSRect(x: comboX, y: y + 32, width: 180, height: 18)
            caseBox.frame = NSRect(x: comboX + 190, y: y + 32, width: 240, height: 18)
            wholeBox.frame = NSRect(x: comboX, y: y + 54, width: 180, height: 18)
            regexBox.frame = NSRect(x: comboX + 190, y: y + 54, width: 240, height: 18)
            y += 84
        }
        advancedButton.frame = NSRect(x: margin - 2, y: y, width: comboX - margin, height: 28)
        advancedField.frame = NSRect(x: comboX, y: y + 3, width: rightEdge - comboX, height: 22)
        y += 40
        foundLabel.frame = NSRect(x: margin, y: y + 2, width: 260, height: 17)
        let toolbarWidth = headerToolbar.fittingSize.width
        headerToolbar.frame = NSRect(x: rightEdge - toolbarWidth, y: y, width: toolbarWidth, height: 20)
        y += 24
        let statusHeight: CGFloat = 22
        scrollView.frame = NSRect(x: margin, y: y, width: rightEdge - margin, height: max(60, height - y - statusHeight - 4))
        statusLabel.frame = NSRect(x: margin, y: height - statusHeight + 2, width: rightEdge - margin, height: 17)
    }

    func windowDidResize(_ notification: Notification) {
        layoutControls()
    }

    /// Načte poslední nastavení a historii (Název, Hledat v, Obsahující).
    private func loadState(lookIn: String) {
        let defaults = UserDefaults.standard
        namedCombo.addItems(withObjectValues: defaults.stringArray(forKey: "findNamedHistory") ?? [])
        lookInCombo.addItems(withObjectValues: defaults.stringArray(forKey: "findLookInHistory") ?? [])
        containingCombo.addItems(withObjectValues: defaults.stringArray(forKey: "findContainingHistory") ?? [])
        // Název: poslední maska, poprvé „*.*“ (jako originál); Hledat v = adresář panelu.
        namedCombo.stringValue = (defaults.stringArray(forKey: "findNamedHistory") ?? []).first ?? "*.*"
        lookInCombo.stringValue = lookIn
        subdirsBox.state = defaults.object(forKey: "findSubdirs") as? Bool == false ? .off : .on
        grepBox.state = .off
        hexBox.state = defaults.bool(forKey: "findHex") ? .on : .off
        caseBox.state = defaults.bool(forKey: "findCase") ? .on : .off
        wholeBox.state = defaults.bool(forKey: "findWholeWords") ? .on : .off
        regexBox.state = defaults.bool(forKey: "findRegex") ? .on : .off
        if let data = defaults.data(forKey: "findAdvanced"),
           let saved = try? JSONDecoder().decode(FindAdvanced.self, from: data) {
            advanced = saved
        }
        addButton.isEnabled = vfs.kind == SAL_VFS_LOCAL
        updateAdvancedText()
        updateContentOptions()
    }

    /// Uloží volby a historii pro další okno hledání.
    private func saveState() {
        let defaults = UserDefaults.standard
        Self.remember(namedCombo, key: "findNamedHistory")
        if vfs.kind == SAL_VFS_LOCAL { Self.remember(lookInCombo, key: "findLookInHistory") }
        if grepBox.state == .on { Self.remember(containingCombo, key: "findContainingHistory") }
        defaults.set(subdirsBox.state == .on, forKey: "findSubdirs")
        defaults.set(hexBox.state == .on, forKey: "findHex")
        defaults.set(caseBox.state == .on, forKey: "findCase")
        defaults.set(wholeBox.state == .on, forKey: "findWholeWords")
        defaults.set(regexBox.state == .on, forKey: "findRegex")
        if let data = try? JSONEncoder().encode(advanced) {
            defaults.set(data, forKey: "findAdvanced")
        }
    }

    /// Přidá hodnotu pole na začátek historie (bez duplicit, nejvýš 20 položek).
    private static func remember(_ combo: NSComboBox, key: String) {
        let value = combo.stringValue
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var history = UserDefaults.standard.stringArray(forKey: key) ?? []
        history.removeAll { $0 == value }
        history.insert(value, at: 0)
        history = Array(history.prefix(historyLimit))
        UserDefaults.standard.set(history, forKey: key)
        combo.removeAllItems()
        combo.addItems(withObjectValues: history)
        combo.stringValue = value
    }

    private func updateAdvancedText() {
        advancedField.stringValue = advanced.summary
        advancedField.textColor = advanced.isActive ? .labelColor : .disabledControlTextColor
    }

    /// HEX režim vylučuje Celá slova, Rozlišovat a Regulární výraz (jako originál);
    /// pomocník regulárních výrazů je aktivní jen s volbou Regulární výraz.
    private func updateContentOptions() {
        let hex = hexBox.state == .on
        caseBox.isEnabled = !hex
        wholeBox.isEnabled = !hex
        regexBox.isEnabled = !hex
        hexBox.isEnabled = regexBox.state != .on
        regexHelpButton.isEnabled = regexBox.state == .on && !hex
    }

    // MARK: Menu dialogu

    /// Položky nabídky Soubory (pro menu dialogu i kontextové menu seznamu).
    private func makeFilesMenu(withShortcuts: Bool) -> NSMenu {
        let menu = NSMenu(title: "Soubory")
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: withShortcuts ? key : "")
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
        }
        add("Otevřít", #selector(openItem(_:)))
        add("Otevřít všechny označené", #selector(openSelected(_:)))
        add("Ukázat", #selector(focusItem(_:)))
        add("Skrýt", #selector(hideSelected(_:)), "h", [.control])
        add("Skrýt duplicitní názvy", #selector(hideDuplicates(_:)), "h", [.control, .shift])
        menu.addItem(.separator())
        add("Zobrazit", #selector(viewItem(_:)), KeyCode.functionKeyString(3), [])
        add("Upravit", #selector(editItem(_:)), KeyCode.functionKeyString(4), [])
        add("Odstranit", #selector(deleteItems(_:)), KeyCode.functionKeyString(8), [])
        add("Odstranit trvale", #selector(deleteItemsPermanently(_:)), KeyCode.functionKeyString(8), [.shift])
        add("Zobrazit ve Finderu", #selector(revealInFinder(_:)))
        if withShortcuts {
            menu.addItem(.separator())
            add("Zavřít", #selector(closeWindow(_:)), "w", [.command])
        }
        return menu
    }

    /// Sestaví menu dialogu (Soubory, Příkazy, Upravit, Zobrazit, Možnosti).
    private func buildMenu() {
        let menu = NSMenu(title: "Hledat")
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let sub = NSMenu(title: title)
            items.forEach { $0.menu?.removeItem($0); sub.addItem($0) }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            menu.addItem(holder)
        }
        // toResponder: cíl nil = akce jde přes řetězec respondérů (textová pole, seznam).
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [],
                  toResponder: Bool = false) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = toResponder ? nil : self
            return entry
        }

        submenu("Soubory", makeFilesMenu(withShortcuts: true).items)
        submenu("Příkazy", Self.findCommands.map { item($0.title, $0.action, $0.key, [.control]) } + [
            .separator(),
            item("Zastavit", #selector(stopClicked(_:)), "p", [.option]),
        ])

        // Upravit: standardní akce (cut:/copy:/paste:/selectAll:) jdou přes responder
        // chain – v textových polích pracují s textem, v seznamu s nalezenými položkami.
        submenu("Upravit", [
            item("Vyjmout", #selector(NSText.cut(_:)), "x", [.command], toResponder: true),
            item("Kopírovat", #selector(NSText.copy(_:)), "c", [.command], toResponder: true),
            item("Vložit", #selector(NSText.paste(_:)), "v", [.command], toResponder: true),
            .separator(),
            item("Kopírovat cestu + název jako text", #selector(copyFullNameAsText(_:)), "c", [.command, .option]),
            item("Kopírovat název jako text", #selector(copyNameAsText(_:)), "c", [.command, .option, .shift]),
            item("Kopírovat cestu jako text", #selector(copyPathAsText(_:)), "c", [.command, .control]),
            .separator(),
            item("Vybrat vše", #selector(NSText.selectAll(_:)), "a", [.command], toResponder: true),
            item("Invertovat výběr", #selector(invertSelection(_:))),
        ])
        submenu("Zobrazit", [
            item("Seřadit podle názvu", #selector(sortByName(_:)), KeyCode.functionKeyString(3), [.control]),
            item("Seřadit podle cesty", #selector(sortByPath(_:)), KeyCode.functionKeyString(4), [.control]),
            item("Seřadit podle data", #selector(sortByTime(_:)), KeyCode.functionKeyString(5), [.control]),
            item("Seřadit podle velikosti", #selector(sortBySize(_:)), KeyCode.functionKeyString(6), [.control]),
        ])
        submenu("Možnosti", [
            item("Řadit soubory a adresáře dohromady", #selector(toggleSortMixed(_:))),
        ])
        findMenu = menu
    }

    /// Okno je aktivní: hlavní menu nahradí menu dialogu (aplikační menu zůstává),
    /// aby F3/F4/F8 a Ctrl zkratky šly do okna hledání, ne do panelů.
    func windowDidBecomeKey(_ notification: Notification) {
        guard savedMainMenu == nil, let mainMenu = NSApp.mainMenu, mainMenu !== findMenu,
              let appItem = mainMenu.items.first else { return }
        savedMainMenu = mainMenu
        mainMenu.removeItem(appItem)
        findMenu.insertItem(appItem, at: 0)
        NSApp.mainMenu = findMenu
    }

    func windowDidResignKey(_ notification: Notification) {
        restoreMainMenu()
    }

    /// Vrátí hlavní menu aplikace (i s aplikačním menu).
    private func restoreMainMenu() {
        guard let mainMenu = savedMainMenu, let appItem = findMenu.items.first else { return }
        findMenu.removeItem(appItem)
        mainMenu.insertItem(appItem, at: 0)
        NSApp.mainMenu = mainMenu
        savedMainMenu = nil
    }

    func windowWillClose(_ notification: Notification) {
        runningState?.cancel()
        restoreMainMenu()
        saveState()
        Self.openWindows.removeAll { $0 === self }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let searching = runningState != nil
        let hasSelection = !selectedRows.isEmpty
        switch menuItem.action {
        case #selector(findNowClicked(_:)), #selector(appendClicked(_:)):
            return !searching
        case #selector(intersectClicked(_:)), #selector(subtractClicked(_:)):
            return !searching && !rows.isEmpty
        case #selector(stopClicked(_:)):
            return searching
        case #selector(toggleSortMixed(_:)):
            menuItem.state = sortMixed ? .on : .off
            return true
        case #selector(sortByName(_:)), #selector(sortByPath(_:)), #selector(sortByTime(_:)), #selector(sortBySize(_:)),
             #selector(hideDuplicates(_:)), #selector(invertSelection(_:)):
            return !rows.isEmpty
        case #selector(deleteItems(_:)), #selector(deleteItemsPermanently(_:)):
            return hasSelection && !searching && vfs.writable
        case #selector(editItem(_:)):
            return focusedRow.map { !$0.item.isDir && vfs.kind == SAL_VFS_LOCAL } ?? false
        case #selector(viewItem(_:)):
            return focusedRow.map { !$0.item.isDir } ?? false
        case #selector(revealInFinder(_:)):
            return hasSelection && vfs.kind == SAL_VFS_LOCAL
        default:
            return hasSelection
        }
    }

    // MARK: Hledání

    @objc private func findNowClicked(_ sender: Any?) { startSearch(.now) }
    @objc private func appendClicked(_ sender: Any?) { startSearch(.append) }
    @objc private func intersectClicked(_ sender: Any?) { startSearch(.intersect) }
    @objc private func subtractClicked(_ sender: Any?) { startSearch(.subtract) }

    @objc private func stopClicked(_ sender: Any?) {
        runningState?.cancel()
    }

    /// Nabídka pod šipkou tlačítka Najít.
    @objc private func findMenuClicked(_ sender: NSButton) {
        let menu = NSMenu()
        for (title, action, _) in Self.findCommands {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Převede text „Obsahující“ na hledané bajty; v HEX režimu dvojice
    /// šestnáctkových číslic a text v uvozovkách ('01 02 "text" 00').
    /// - Returns: bajty vzoru, nil = chybný zápis
    static func parseHex(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var index = text.startIndex
        var pendingDigit: Character?
        while index < text.endIndex {
            let char = text[index]
            if char == "\"" {
                // Text v uvozovkách se bere doslova (UTF-8).
                guard pendingDigit == nil else { return nil }
                let start = text.index(after: index)
                guard let end = text[start...].firstIndex(of: "\"") else { return nil }
                bytes.append(contentsOf: Array(text[start..<end].utf8))
                index = text.index(after: end)
                continue
            }
            if char.isWhitespace {
                guard pendingDigit == nil else { return nil }
            } else if char.isHexDigit {
                if let high = pendingDigit {
                    guard let value = UInt8(String([high, char]), radix: 16) else { return nil }
                    bytes.append(value)
                    pendingDigit = nil
                } else {
                    pendingDigit = char
                }
            } else {
                return nil
            }
            index = text.index(after: index)
        }
        return pendingDigit == nil ? bytes : nil
    }

    /// Kritéria z ovládacích prvků; při chybě zobrazí hlášení a vrátí nil.
    private func currentSpec() -> FindSpec? {
        let mask = namedCombo.stringValue.trimmingCharacters(in: .whitespaces)
        var content: [UInt8]?
        if grepBox.state == .on {
            let text = containingCombo.stringValue
            if hexBox.state == .on {
                guard let bytes = Self.parseHex(text) else {
                    showError("Chybný šestnáctkový řetězec. Zadejte dvojice číslic 0–9, A–F, text uzavřete do uvozovek.")
                    return nil
                }
                content = bytes
            } else {
                content = Array(text.utf8)
            }
        }
        return FindSpec(mask: mask.isEmpty ? "*" : mask, subdirs: subdirsBox.state == .on,
                        content: content, caseSensitive: caseBox.state == .on,
                        wholeWords: wholeBox.state == .on, regex: regexBox.state == .on,
                        hex: hexBox.state == .on)
    }

    /// Výchozí adresáře z „Hledat v“ (oddělené středníkem; lokálně s rozvinutím ~).
    private func lookInRoots() -> [String] {
        lookInCombo.stringValue.split(separator: ";").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return vfs.kind == SAL_VFS_LOCAL ? (trimmed as NSString).expandingTildeInPath : trimmed
        }.filter { !$0.isEmpty }
    }

    /// Spustí hledání podle režimu (Najít, Připojit, Průnik, Odečíst).
    private func startSearch(_ mode: FindMode) {
        guard runningState == nil, let spec = currentSpec() else { return }
        // Průnik/Odečíst prohledá adresáře nalezených položek bez podadresářů;
        // ostatní režimy výchozí adresáře z „Hledat v“.
        var searchSpec = spec
        let roots: [String]
        let refinePaths: Set<String>
        switch mode {
        case .intersect, .subtract:
            refinePaths = Set(rows.map(\.path))
            var seen = Set<String>()
            roots = rows.map(\.dir).filter { seen.insert($0).inserted }
            searchSpec.subdirs = false
        case .now, .append:
            refinePaths = []
            roots = lookInRoots()
            guard !roots.isEmpty else {
                showError("Prázdný řetězec zde není povolen.")
                window?.makeFirstResponder(lookInCombo)
                return
            }
        }
        saveState()
        if mode == .now {
            rows = []
            tableView.reloadData()
        }

        let state = ProgressState()
        runningState = state
        let collector = FindCollector()
        let advanced = advanced
        let vfs = vfs
        let now = Date()
        setSearching(true)

        // Výsledky po filtru Upřesnit (bez aktivního filtru se nic netestuje).
        let baseRows = rows
        func foundRows(_ results: [FindResult]) -> [FoundRow] {
            results
                .filter { !advanced.isActive || advanced.matches($0.item, now: now) }
                .map { FoundRow(path: $0.path, item: $0.item) }
        }
        // Průběžné doplňování seznamu (jen přibylé položky, seznam při hledání
        // jen roste) a stavového řádku „Vyhledávání: adresář“.
        var consumed = 0
        let showsProgress = mode == .now || mode == .append
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if showsProgress {
                let fresh = collector.items(from: consumed)
                consumed += fresh.count
                let added = foundRows(fresh)
                if !added.isEmpty {
                    self.rows += added
                    self.tableView.noteNumberOfRowsChanged()
                    self.updateFoundLabel()
                }
            }
            self.setStatus("Vyhledávání: " + collector.currentDir)
        }
        RunLoop.main.add(timer, forMode: .common)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var errors: UInt64 = 0
            var failure: Error?
            for root in roots {
                if state.isCancelled { break }
                do {
                    errors += try coreFindEx(vfs: vfs, root: root, spec: searchSpec, state: state, collector: collector)
                } catch let error as CoreError where error.isCancelledLike {
                    break
                } catch {
                    // Nečitelný výchozí adresář: u více adresářů pokračovat, chybu nahlásit.
                    errors += 1
                    failure = error
                }
            }
            DispatchQueue.main.async {
                timer.invalidate()
                guard let self else { return }
                let found = foundRows(collector.snapshot())
                switch mode {
                case .now, .append:
                    self.rows = baseRows + found
                case .intersect, .subtract:
                    // Výsledek vytřídění se uplatní jen při dokončení (ne po zastavení).
                    if !state.isCancelled {
                        let matching = Set(found.map(\.path)).intersection(refinePaths)
                        self.rows = baseRows.filter { matching.contains($0.path) == (mode == .intersect) }
                    }
                }
                self.finishSearch(stopped: state.isCancelled, errors: errors,
                                  failure: roots.count == 1 ? failure : nil)
            }
        }
    }

    /// Přepne vzhled okna mezi hledáním a nečinností (tlačítko Najít/Zastavit, titulek).
    private func setSearching(_ searching: Bool) {
        findButton.title = searching ? "Zastavit" : "Najít"
        findButton.action = searching ? #selector(stopClicked(_:)) : #selector(findNowClicked(_:))
        findMenuButton.isEnabled = !searching
        stopButton.isEnabled = searching
        window?.title = searching
            ? "\(Self.baseTitle) [vyhledávání \(namedCombo.stringValue)]"
            : Self.baseTitle
    }

    /// Dokončení hledání: seřazení, stavový řádek (počet / Zastaveno / nic nenalezeno).
    private func finishSearch(stopped: Bool, errors: UInt64, failure: Error?) {
        runningState = nil
        setSearching(false)
        applySort()
        updateFoundLabel()
        if let failure {
            setStatus(failure.localizedDescription)
        } else if stopped {
            setStatus("Zastaveno.")
        } else if rows.isEmpty {
            setStatus("Nenalezeny žádné soubory nebo adresáře.")
        } else {
            updateSelectionStatus()
        }
        // Přeskočené nečitelné adresáře/soubory (obdoba Protokolu hledání).
        if errors > 0 && failure == nil {
            statusLabel.stringValue += "  (přeskočeno nečitelných položek: \(errors))"
        }
        if !stopped, !rows.isEmpty, window?.firstResponder is NSTextView {
            // Po hledání fokus do seznamu na první položku (jako originál).
            window?.makeFirstResponder(tableView)
            if tableView.selectedRow < 0 {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            }
        }
        if !stopped, NSApp.keyWindow !== window {
            NSSound.beep()
        }
    }

    private func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    private func updateFoundLabel() {
        foundLabel.stringValue = "Nalezené položky: (\(rows.count))"
    }

    /// Stavový řádek podle označení: velikost a počet souborů/adresářů.
    private func updateSelectionStatus() {
        guard runningState == nil else { return }
        let selected = selectedRows
        guard !selected.isEmpty else {
            setStatus("")
            return
        }
        let files = selected.filter { !$0.item.isDir }
        let dirs = selected.count - files.count
        if dirs > 0 {
            setStatus("Označeno: \(Self.plural(files.count, "soubor", "soubory", "souborů")), \(Self.plural(dirs, "adresář", "adresáře", "adresářů"))")
        } else {
            let size = files.reduce(UInt64(0)) { $0 + $1.item.size }
            setStatus("Označeno: \(formatSize(size)) v \(Self.plural(files.count, "souboru", "souborech", "souborech"))")
        }
    }

    /// Číslo s českým tvarem slova (1 / 2–4 / 5+).
    private static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let word = count == 1 ? one : (2...4).contains(count) ? few : many
        return "\(count) \(word)"
    }

    private func showError(_ text: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Chyba"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: Ovládací prvky – akce

    @objc private func grepToggled(_ sender: Any?) {
        layoutControls()
        if grepBox.state == .on {
            window?.makeFirstResponder(containingCombo)
        }
    }

    @objc private func contentOptionChanged(_ sender: Any?) {
        updateContentOptions()
    }

    /// Přidat: Procházet… (výběr adresáře) a Všechny místní jednotky.
    @objc private func addClicked(_ sender: NSButton) {
        let menu = NSMenu()
        let browse = NSMenuItem(title: "Procházet…", action: #selector(browseLookIn(_:)), keyEquivalent: "")
        browse.target = self
        menu.addItem(browse)
        menu.addItem(.separator())
        let drives = NSMenuItem(title: "Všechny místní jednotky", action: #selector(addLocalDrives(_:)), keyEquivalent: "")
        drives.target = self
        menu.addItem(drives)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    /// Přidá cestu do „Hledat v“ (oddělovač středník, bez duplicit).
    private func appendLookIn(_ paths: [String]) {
        var current = lookInCombo.stringValue.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for path in paths where !current.contains(path) {
            current.append(path)
        }
        lookInCombo.stringValue = current.joined(separator: ";")
    }

    @objc private func browseLookIn(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Přidat"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.appendLookIn(panel.urls.map(\.path))
        }
    }

    /// Kořen disku a připojené svazky (obdoba „Všechny místní jednotky“).
    @objc private func addLocalDrives(_ sender: Any?) {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        appendLookIn(["/"] + volumes.map(\.path).filter { $0 != "/" })
    }

    /// Nabídka pomocníka regulárních výrazů (vloží konstrukci do pole Obsahující).
    @objc private func regexHelpClicked(_ sender: NSButton) {
        let entries: [(String, String)?] = [
            ("Libovolný znak", "."), ("Libovolný z množiny znaků", "[]"),
            ("Libovolný mimo množinu znaků", "[^]"), ("Libovolný z rozsahu znaků", "[-]"),
            ("Začátek řádku", "^"), ("Konec řádku", "$"), ("Nebo", "|"),
            ("0 nebo více odpovídajících", "*"), ("1 nebo více odpovídajících", "+"),
            ("0 nebo 1 odpovídající", "?"), nil,
            ("Levá závorka '('", "\\("), ("Pravá závorka ')'", "\\)"), ("Tečka '.'", "\\."),
            ("Plus '+'", "\\+"), ("Hvězdička '*'", "\\*"), nil,
            ("Alfanumerický znak", "[a-zA-Z0-9]"), ("Znak abecedy", "[a-zA-Z]"), ("Desítková číslice", "[0-9]"), nil,
            ("Desítkové číslo", "[0-9]+"), ("Šestnáctkové číslo", "[0-9a-fA-F]+"),
            ("Reálné číslo", "[0-9]+\\.[0-9]*"), nil,
            ("Řetězec ze znaků abecedy", "[a-zA-Z]+"), ("Identifikátor", "[a-zA-Z_][a-zA-Z0-9_]*"),
            ("Řetězec v uvozovkách", "\"[^\"]*\""),
        ]
        let menu = NSMenu()
        for entry in entries {
            guard let (title, snippet) = entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: "\(title)\t\(snippet)", action: #selector(insertRegexSnippet(_:)), keyEquivalent: "")
            item.representedObject = snippet
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.width, y: 0), in: sender)
    }

    @objc private func insertRegexSnippet(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? String else { return }
        window?.makeFirstResponder(containingCombo)
        if let editor = containingCombo.currentEditor() {
            editor.insertText(snippet)
        } else {
            containingCombo.stringValue += snippet
        }
    }

    @objc private func advancedClicked(_ sender: Any?) {
        guard let window else { return }
        FindAdvancedController.run(on: window, value: advanced) { [weak self] value in
            guard let self, let value else { return }
            self.advanced = value
            self.updateAdvancedText()
        }
    }

    /// Enter v rozbalovacích polích spustí Najít; Escape zastaví hledání / zavře okno.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            startSearch(.now)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelOperation(nil)
            return true
        }
        return false
    }

    /// Escape: běžící hledání zastaví, jinak okno zavře.
    override func cancelOperation(_ sender: Any?) {
        if runningState != nil {
            runningState?.cancel()
        } else {
            window?.performClose(nil)
        }
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
    }

    // MARK: Seznam – klávesy a akce

    /// Klávesy seznamu nalezených položek podle originálu.
    private func tableKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.enter:
            if flags == .shift { openSelected(nil) } else { openItem(nil) }
            return true
        case KeyCode.space where flags.isEmpty:
            focusItem(nil)
            return true
        case KeyCode.forwardDelete, KeyCode.backspace:
            // ⌦ / ⌘⌫ do koše, ⇧⌦ / ⇧⌫ trvale (jako v panelu); holé ⌫ nic nedělá.
            guard let toTrash = KeyCode.deleteIntent(keyCode: event.keyCode, flags: flags) else { return false }
            confirmDelete(toTrash: toTrash)
            return true
        case KeyCode.escape:
            cancelOperation(nil)
            return true
        case KeyCode.insert where flags.contains(.option):
            // Alt+Insert / Alt+Shift+Insert / Ctrl+Alt+Insert jako v originále.
            if flags.contains(.shift) { copyNameAsText(nil) }
            else if flags.contains(.control) { copyPathAsText(nil) }
            else { copyFullNameAsText(nil) }
            return true
        default:
            break
        }
        // Ctrl+C / Ctrl+X / Ctrl+A (Windows varianty ⌘ zkratek menu).
        if flags == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return true
            case "x": cut(nil); return true
            case "a": tableView.selectAll(nil); return true
            default: break
            }
        }
        return false
    }

    /// Označené řádky seznamu (bez označení řádek pod kurzorem).
    private var selectedRows: [FoundRow] {
        tableView.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
    }

    /// Řádek pod kurzorem (poslední klik/aktivní řádek).
    private var focusedRow: FoundRow? {
        let clicked = tableView.clickedRow
        let index = clicked >= 0 ? clicked : tableView.selectedRow
        return index >= 0 && index < rows.count ? rows[index] : nil
    }

    /// Otevřít: adresář otevře v aktivním panelu, soubor výchozí aplikací.
    @objc private func openItem(_ sender: Any?) {
        guard let row = focusedRow else { return }
        open(row)
    }

    @objc private func openSelected(_ sender: Any?) {
        selectedRows.forEach(open)
    }

    private func open(_ row: FoundRow) {
        guard let owner = mainController else { return }
        if row.item.isDir {
            // Panel nejdřív přejde do nadřazeného adresáře (správné VFS) a pak dovnitř.
            owner.showItem(vfs: vfs, path: row.path)
            owner.activePanel.changePath(vfs.realPath(row.path) ?? row.path)
            return
        }
        owner.withLocalFile(row.item, vfs: vfs, dir: row.dir) { path in
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Ukázat: aktivní panel přejde do adresáře položky s kurzorem na ní.
    @objc private func focusItem(_ sender: Any?) {
        guard let row = focusedRow else { return }
        mainController?.showItem(vfs: vfs, path: row.path)
    }

    @objc private func viewItem(_ sender: Any?) {
        guard let row = focusedRow, !row.item.isDir else { return }
        let title = vfs.realPath(row.path) ?? row.path
        mainController?.withLocalFile(row.item, vfs: vfs, dir: row.dir) { path in
            ViewerWindowController.open(path: path, title: title)
        }
    }

    @objc private func editItem(_ sender: Any?) {
        guard let row = focusedRow, !row.item.isDir, let path = vfs.realPath(row.path) else { return }
        mainController?.openInEditor(path)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        let urls = selectedRows.compactMap { vfs.realPath($0.path) }.map { URL(fileURLWithPath: $0) }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// F8 / Delete – odstranit označené položky do koše (po potvrzení) a odebrat je ze seznamu.
    @objc private func deleteItems(_ sender: Any?) {
        confirmDelete(toTrash: true)
    }

    /// ⇧F8 / ⇧Delete – odstranit označené položky trvale, bez koše.
    @objc private func deleteItemsPermanently(_ sender: Any?) {
        confirmDelete(toTrash: false)
    }

    /// Potvrzení odstranění označených položek.
    /// - Parameter toTrash: přesunout do koše; mimo lokální disk koš není
    ///   a maže se trvale – potvrzení to uvede
    private func confirmDelete(toTrash: Bool) {
        let selected = selectedRows
        guard let window, !selected.isEmpty, runningState == nil, vfs.writable else { return }
        let (text, useTrash) = deleteConfirmation(items: selected.map(\.item), vfs: vfs,
                                                  toTrash: toTrash, verb: "odstranit")
        let alert = NSAlert()
        alert.messageText = "Odstranit"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Odstranit")
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(selected, toTrash: useTrash)
        }
    }

    /// Smaže položky po adresářích na pozadí; smazané zmizí ze seznamu.
    /// - Parameter toTrash: přesunout do koše místo trvalého smazání
    private func performDelete(_ selected: [FoundRow], toTrash: Bool) {
        let vfs = vfs
        let groups = Dictionary(grouping: selected, by: \.dir)
        let state = ProgressState()
        runningState = state
        setStatus(toTrash ? "Přesouvám do koše…" : "Odstraňuji…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var deleted = Set<String>()
            var failure: Error?
            for (dir, items) in groups {
                do {
                    try coreRemove(vfs: vfs, dir: dir, names: items.map(\.item.name),
                                   useTrash: toTrash, state: state)
                    deleted.formUnion(items.map(\.path))
                } catch {
                    failure = error
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.runningState = nil
                // Odebrat smazané položky i vše uvnitř smazaných adresářů.
                self.rows.removeAll { row in
                    deleted.contains(row.path) || deleted.contains { row.path.hasPrefix($0 + "/") }
                }
                self.tableView.reloadData()
                self.updateFoundLabel()
                self.updateSelectionStatus()
                self.mainController?.reloadPanels()
                if let failure { self.showError(failure.localizedDescription) }
            }
        }
    }

    @objc private func hideSelected(_ sender: Any?) {
        let indexes = tableView.selectedRowIndexes
        rows = rows.enumerated().filter { !indexes.contains($0.offset) }.map(\.element)
        tableView.reloadData()
        updateFoundLabel()
    }

    /// Skrýt duplicitní názvy: položky nalezené víckrát (Připojit) zůstanou jednou.
    @objc private func hideDuplicates(_ sender: Any?) {
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.path).inserted }
        tableView.reloadData()
        updateFoundLabel()
    }

    @objc private func invertSelection(_ sender: Any?) {
        let current = tableView.selectedRowIndexes
        let inverted = IndexSet(0..<rows.count).subtracting(current)
        tableView.selectRowIndexes(inverted, byExtendingSelection: false)
    }

    // MARK: Schránka

    /// Kopírovat (⌘C / Ctrl+C v seznamu): lokální soubory jako soubory pro Finder.
    @objc func copy(_ sender: Any?) {
        writeFilesToPasteboard(cut: false)
    }

    /// Vyjmout: soubory do schránky; vložení ve Finderu přes ⌥⌘V je přesune.
    @objc func cut(_ sender: Any?) {
        writeFilesToPasteboard(cut: true)
    }

    private func writeFilesToPasteboard(cut: Bool) {
        let urls = selectedRows.compactMap { vfs.realPath($0.path) }.map { URL(fileURLWithPath: $0) as NSURL }
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls)
        if cut { setStatus("Soubory jsou ve schránce – ve Finderu je přesunete pomocí ⌥⌘V.") }
    }

    /// Zapíše text označených položek do schránky (jedna položka na řádek).
    private func copyText(_ transform: (FoundRow) -> String) {
        let text = selectedRows.map(transform).joined(separator: "\n")
        guard !text.isEmpty else { return }
        copyTextToPasteboard(text)
    }

    @objc private func copyFullNameAsText(_ sender: Any?) {
        copyText { self.vfs.realPath($0.path) ?? $0.path }
    }

    @objc private func copyNameAsText(_ sender: Any?) {
        copyText { $0.item.name }
    }

    @objc private func copyPathAsText(_ sender: Any?) {
        copyText { self.vfs.realPath($0.dir) ?? $0.dir }
    }

    // MARK: Řazení

    @objc private func sortByName(_ sender: Any?) { toggleSort(.name) }
    @objc private func sortByPath(_ sender: Any?) { toggleSort(.path) }
    @objc private func sortByTime(_ sender: Any?) { toggleSort(.time) }
    @objc private func sortBySize(_ sender: Any?) { toggleSort(.size) }

    @objc private func toggleSortMixed(_ sender: Any?) {
        sortMixed.toggle()
        applySort()
    }

    /// Stejný klíč znovu obrátí směr, jiný klíč řadí vzestupně.
    private func toggleSort(_ key: FoundSort) {
        if sort == key {
            sortAscending.toggle()
        } else {
            sort = key
            sortAscending = true
        }
        applySort()
    }

    /// Seřadí seznam (adresáře nahoře, pokud není zapnuto řazení dohromady)
    /// a zachová označení položek.
    private func applySort() {
        let selectedPaths = Set(selectedRows.map(\.path))
        let key = sort
        let ascending = sortAscending
        let mixed = sortMixed
        rows.sort { left, right in
            if !mixed && left.item.isDir != right.item.isDir {
                return left.item.isDir
            }
            let order: ComparisonResult
            switch key {
            case .name: order = left.item.name.localizedStandardCompare(right.item.name)
            case .path: order = left.path.localizedStandardCompare(right.path)
            case .time: order = Self.compare(left.item.mtime, right.item.mtime)
            case .size: order = Self.compare(left.item.size, right.item.size)
            }
            if order == .orderedSame {
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        tableView.reloadData()
        let indexes = IndexSet(rows.indices.filter { selectedPaths.contains(rows[$0].path) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        updateSortIndicators()
    }

    /// Porovnání dvou hodnot jako ComparisonResult.
    private static func compare<T: Comparable>(_ left: T, _ right: T) -> ComparisonResult {
        left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
    }

    /// Šipky řazení v záhlaví (Datum a Čas sdílejí klíč – šipku mají oba).
    private func updateSortIndicators() {
        let image = NSImage(named: sortAscending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
        for column in tableView.tableColumns {
            let active = FoundColumn(rawValue: column.identifier.rawValue)?.sortKey == sort
            tableView.setIndicatorImage(active ? image : nil, in: column)
        }
    }

    /// Klik na záhlaví řadí (sloupec Atributy řadit nejde).
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        if let key = FoundColumn(rawValue: tableColumn.identifier.rawValue)?.sortKey {
            toggleSort(key)
        }
    }

    // MARK: Tabulka – data

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionStatus()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let identifier = tableColumn?.identifier,
              let column = FoundColumn(rawValue: identifier.rawValue) else { return nil }
        let entry = rows[row]
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier, withIcon: column == .name)
        let item = entry.item
        switch column {
        case .name:
            cell.textField?.stringValue = item.name
            cell.imageView?.image = listIcon(for: item)
        case .path:
            cell.textField?.stringValue = vfs.realPath(entry.dir) ?? entry.dir
        case .size:
            cell.textField?.stringValue = item.isDir ? "ADRESÁŘ" : formatSize(item.size)
        case .date:
            cell.textField?.stringValue = formatDay(item.mtime)
        case .time:
            cell.textField?.stringValue = formatTime(item.mtime)
        case .attr:
            cell.textField?.stringValue = attributes(of: item)
        }
        cell.textField?.alignment = column == .size ? .right : .left
        cell.textField?.lineBreakMode = column == .path ? .byTruncatingHead : .byTruncatingTail
        return cell
    }

    /// Buňka tabulky (u sloupce Název s ikonou).
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field
        cell.addSubview(field)
        var leading = cell.leadingAnchor
        if withIcon {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.imageView = imageView
            cell.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = imageView.trailingAnchor
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leading, constant: 3),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
