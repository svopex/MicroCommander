// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Nastavení aplikace (⌘,) ve stylu dialogu Konfigurace Salamandera: vlevo
// seznam kategorií (Obecné, Panely, Barvy, Hlavní okno, Klávesnice), vpravo stránka
// s nadpisem, dole OK / Zrušit – změny se uloží až tlačítkem OK. Stránka
// Klávesnice mění klávesové zkratky všech příkazů (KeyBindings). Vlevo dole
// Obnovit vše (výchozí hodnoty), Načíst ze souboru… a Uložit do souboru…
// (SettingsSnapshot – nastavení jako soubor JSON).

import AppKit
import UniformTypeIdentifiers

/// Volby aplikace v UserDefaults.
enum Settings {
    /// Oznámení o změně nastavení (hlavní okno se překreslí).
    static let changed = Notification.Name("MicroCommanderSettingsChanged")
    /// Oznámení o změně barevného schématu (panely se přebarví).
    static let colorSchemeChanged = Notification.Name("MicroCommanderColorSchemeChanged")
    private static let middleBarKey = "showMiddleBar"
    private static let markDirsKey = "selectAllIncludesDirs"
    private static let savePanelPathsKey = "savePanelPaths"
    private static let colorSchemeKey = "colorScheme"
    private static let showHiddenKey = "showHiddenFiles"

    /// Zobrazovat skryté soubory a adresáře – společně pro oba panely všech
    /// oken; výchozí ne. Změna se oknům oznámí.
    static var showHiddenFiles: Bool {
        get { UserDefaults.standard.object(forKey: showHiddenKey) as? Bool ?? SettingsSnapshot.defaults.showHiddenFiles }
        set {
            UserDefaults.standard.set(newValue, forKey: showHiddenKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Zobrazovat svislou lištu příkazů mezi panely; výchozí ne = jen úzký
    /// dělicí pruh jako v Salamanderu.
    static var showMiddleBar: Bool {
        get { UserDefaults.standard.object(forKey: middleBarKey) as? Bool ?? SettingsSnapshot.defaults.showMiddleBar }
        set {
            UserDefaults.standard.set(newValue, forKey: middleBarKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Označit vše (⌘A) a Invertovat označení (Num *) pracují i s adresáři;
    /// výchozí ano (bez uložené volby).
    /// Zrušení označení platí vždy i pro adresáře.
    static var markingIncludesDirs: Bool {
        get { UserDefaults.standard.object(forKey: markDirsKey) as? Bool ?? SettingsSnapshot.defaults.markingIncludesDirs }
        set { UserDefaults.standard.set(newValue, forKey: markDirsKey) }
    }

    /// Před ukončením uložit adresáře panelů (po spuštění se otevřou znovu);
    /// výchozí ano.
    static var savePanelPaths: Bool {
        get { UserDefaults.standard.object(forKey: savePanelPathsKey) as? Bool ?? SettingsSnapshot.defaults.savePanelPaths }
        set { UserDefaults.standard.set(newValue, forKey: savePanelPathsKey) }
    }

    /// Barevné schéma panelů; výchozí PanelColorScheme.defaultScheme. Změna nastaví vzhled
    /// aplikace a oznámí překreslení panelů.
    static var colorScheme: PanelColorScheme {
        get {
            UserDefaults.standard.string(forKey: colorSchemeKey).flatMap(PanelColorScheme.init(rawValue:))
                ?? SettingsSnapshot.defaults.colorScheme
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: colorSchemeKey)
            applyAppearance()
            NotificationCenter.default.post(name: colorSchemeChanged, object: nil)
        }
    }

    /// Nastaví vzhled aplikace (světlý/tmavý) a barvy panelů podle barevného
    /// schématu (jediné čtení předvolby – kreslení pak bere PanelColors.current).
    static func applyAppearance() {
        let scheme = colorScheme
        NSApp.appearance = scheme.appearance
        PanelColors.current = scheme.colors
    }
}

/// Chyba při načítání souboru s nastavením.
enum SettingsFileError: LocalizedError {
    /// Soubor není nastavení MicroCommanderu (chybí nebo nesedí značka formátu).
    case notSettings
    /// Soubor uložila novější verze aplikace (číslo verze formátu).
    case newerVersion(Int)
    /// Soubor má značku formátu, ale neplatný obsah (poškozený nebo ručně upravený JSON).
    case corrupted

    var errorDescription: String? {
        switch self {
        case .notSettings:
            return "Soubor neobsahuje nastavení MicroCommanderu."
        case .newerVersion(let version):
            return "Soubor je z novější verze MicroCommanderu (formát \(version)) a tato verze ho neumí načíst."
        case .corrupted:
            return "Soubor není platné nastavení MicroCommanderu (poškozený nebo ručně upravený JSON)."
        }
    }
}

/// Snímek všech voleb dialogu Nastavení: výchozí hodnoty (`defaults`), právě
/// platné nastavení (`current`), jeho použití (`apply`) a uložení do souboru
/// JSON / načtení z něj. Výchozí hodnoty vlastností jsou zároveň výchozím
/// nastavením aplikace (berou si je odtud i gettery v `Settings`).
struct SettingsSnapshot: Codable, Equatable {
    /// Značka formátu v souboru (podle ní se pozná cizí JSON).
    static let fileFormat = "MicroCommander settings"
    /// Verze formátu souboru; novější soubor se odmítne.
    static let fileVersion = 1
    /// Výchozí nastavení aplikace.
    static let defaults = SettingsSnapshot()

    /// Obecné: před ukončením uložit adresáře panelů.
    var savePanelPaths = true
    /// Panely: zobrazovat skryté soubory a adresáře.
    var showHiddenFiles = false
    /// Panely: Označit vše a Invertovat označení i s adresáři.
    var markingIncludesDirs = true
    /// Hlavní okno: lišta příkazů mezi panely.
    var showMiddleBar = false
    /// Barvy: barevné schéma panelů.
    var colorScheme = PanelColorScheme.defaultScheme
    /// Klávesnice: změny zkratek oproti výchozím (název příkazu → zkratky).
    var keyBindings: [String: [Shortcut]] = [:]

    init() {}

    // Klíče v souboru odpovídají názvům předvoleb (viz README).
    private enum CodingKeys: String, CodingKey {
        case format, version
        case savePanelPaths, showHiddenFiles, showMiddleBar, colorScheme, keyBindings
        case markingIncludesDirs = "selectAllIncludesDirs"
    }

    // MARK: Platné nastavení

    /// Právě platné (uložené) nastavení aplikace.
    static var current: SettingsSnapshot {
        var snapshot = SettingsSnapshot()
        snapshot.savePanelPaths = Settings.savePanelPaths
        snapshot.showHiddenFiles = Settings.showHiddenFiles
        snapshot.markingIncludesDirs = Settings.markingIncludesDirs
        snapshot.showMiddleBar = Settings.showMiddleBar
        snapshot.colorScheme = Settings.colorScheme
        snapshot.keyBindings = KeyBindings.overrides
        return snapshot
    }

    /// Uloží snímek jako platné nastavení aplikace. Volby s viditelným dopadem
    /// (lišta, schéma, skryté soubory, zkratky) se zapisují jen při změně –
    /// jejich zápis překresluje okno a posílá oznámení.
    func apply() {
        Settings.savePanelPaths = savePanelPaths
        Settings.markingIncludesDirs = markingIncludesDirs
        if Settings.showMiddleBar != showMiddleBar {
            Settings.showMiddleBar = showMiddleBar
        }
        if Settings.colorScheme != colorScheme {
            Settings.colorScheme = colorScheme
        }
        if Settings.showHiddenFiles != showHiddenFiles {
            Settings.showHiddenFiles = showHiddenFiles
        }
        if KeyBindings.overrides != keyBindings {
            KeyBindings.overrides = keyBindings
        }
    }

    // MARK: Soubor

    /// Načtení ze souboru: chybějící volba dostane výchozí hodnotu (soubor ze
    /// starší verze nebo ručně zkrácený), cizí JSON a novější formát se odmítnou.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decodeIfPresent(String.self, forKey: .format) == Self.fileFormat else {
            throw SettingsFileError.notSettings
        }
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version <= Self.fileVersion else {
            throw SettingsFileError.newerVersion(version)
        }
        let defaults = Self.defaults
        savePanelPaths = try container.decodeIfPresent(Bool.self, forKey: .savePanelPaths) ?? defaults.savePanelPaths
        showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? defaults.showHiddenFiles
        markingIncludesDirs = try container.decodeIfPresent(Bool.self, forKey: .markingIncludesDirs)
            ?? defaults.markingIncludesDirs
        showMiddleBar = try container.decodeIfPresent(Bool.self, forKey: .showMiddleBar) ?? defaults.showMiddleBar
        // Neznámé schéma (z jiné verze) = výchozí.
        colorScheme = try container.decodeIfPresent(String.self, forKey: .colorScheme)
            .flatMap(PanelColorScheme.init(rawValue:)) ?? defaults.colorScheme
        // Zkratky jen v rozsahu, který jde nastavit i v dialogu.
        keyBindings = KeyBindings.sanitized(
            try container.decodeIfPresent([String: [Shortcut]].self, forKey: .keyBindings) ?? [:])
    }

    /// Uložení do souboru: značka formátu, verze a všechny volby.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.fileFormat, forKey: .format)
        try container.encode(Self.fileVersion, forKey: .version)
        try container.encode(savePanelPaths, forKey: .savePanelPaths)
        try container.encode(showHiddenFiles, forKey: .showHiddenFiles)
        try container.encode(markingIncludesDirs, forKey: .markingIncludesDirs)
        try container.encode(showMiddleBar, forKey: .showMiddleBar)
        try container.encode(colorScheme.rawValue, forKey: .colorScheme)
        try container.encode(keyBindings, forKey: .keyBindings)
    }

    /// Načte nastavení ze souboru JSON. Neplatný obsah hlásí jako
    /// `SettingsFileError` (srozumitelný text místo technické hlášky dekodéru).
    /// - Parameter url: soubor uložený přes `write(to:)`
    static func read(from url: URL) throws -> SettingsSnapshot {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        } catch is DecodingError {
            throw SettingsFileError.corrupted
        }
    }

    /// Zapíše nastavení do souboru JSON (čitelně odsazený, klíče abecedně –
    /// stejné nastavení dá vždy stejný soubor).
    /// - Parameter url: cílový soubor (existující se přepíše)
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Okno Nastavení (jedno pro celou aplikaci, otevírá se z menu ⌘,).
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// Jediná instance (okno se při dalším otevření jen přenese dopředu).
    private static var shared: SettingsWindowController?

    /// Stránky dialogu (pořadí v seznamu kategorií).
    private enum Page: Int, CaseIterable {
        case general, panels, colors, mainWindow, keyboard

        var title: String {
            switch self {
            case .general: return "Obecné"
            case .panels: return "Panely"
            case .colors: return "Barvy"
            case .mainWindow: return "Hlavní okno"
            case .keyboard: return "Klávesnice"
            }
        }
    }

    // Kostra dialogu: seznam kategorií, nadpis stránky, obsah stránky.
    private let categoryTable = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let pageContainer = NSView()
    private var pageViews: [Page: NSView] = [:]

    // Volby stránek (hodnoty se zapíšou až tlačítkem OK).
    private let savePathsBox = NSButton(checkboxWithTitle: "Před ukončením uložit adresáře panelů",
                                        target: nil, action: nil)
    private let showHiddenBox = NSButton(checkboxWithTitle: "Zobrazovat skryté soubory a adresáře",
                                         target: nil, action: nil)
    private let markDirsBox = NSButton(checkboxWithTitle: "Označit vše (⌘A) a Invertovat označení i s adresáři",
                                       target: nil, action: nil)
    private let middleBarBox = NSButton(checkboxWithTitle: "Zobrazovat lištu příkazů mezi panely",
                                        target: nil, action: nil)
    private let schemePopup = NSPopUpButton()

    // Stránka Klávesnice: rozpracované zkratky (všechny příkazy) a jejich tabulka.
    private var draftBindings: [Command: [Shortcut]] = [:]
    private let bindingsTable = NSTableView()
    private let filterField = NSSearchField()
    private var visibleCommands: [Command] = []
    private var removeButton: NSButton!
    private var resetButton: NSButton!

    /// Zobrazí okno Nastavení s aktuálními hodnotami (vytvoří ho při prvním otevření).
    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        // Vždy aktuální uložené nastavení (rozpracované změny z minula se zahodí).
        controller.draft = .current
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Nastavení"
        window.minSize = NSSize(width: 700, height: 440)
        window.isReleasedWhenClosed = false
        // Na střed jen při vytvoření (posunuté okno zůstává, kde ho uživatel nechal).
        window.center()
        super.init(window: window)
        buildLayout()
        selectPage(.general)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    // MARK: Kostra

    /// Rozvržení jako Konfigurace Salamandera: seznam kategorií vlevo, vpravo
    /// pruh s nadpisem stránky a stránka, dole oddělovač a tlačítka OK / Zrušit.
    private func buildLayout() {
        let content = NSView()

        // Seznam kategorií.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        categoryTable.addTableColumn(column)
        categoryTable.headerView = nil
        categoryTable.rowHeight = 24
        categoryTable.dataSource = self
        categoryTable.delegate = self
        let categoryScroll = NSScrollView()
        categoryScroll.documentView = categoryTable
        categoryScroll.borderType = .bezelBorder
        categoryScroll.hasVerticalScroller = true

        // Pruh s nadpisem stránky.
        let headerBox = NSBox()
        headerBox.boxType = .custom
        headerBox.fillColor = .controlBackgroundColor
        headerBox.borderColor = .separatorColor
        headerBox.borderWidth = 1
        headerBox.cornerRadius = 0
        headerBox.contentViewMargins = NSSize(width: 10, height: 6)
        headerLabel.font = NSFont.systemFont(ofSize: 17)
        headerBox.contentView?.addSubview(headerLabel)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        // Tlačítka OK / Zrušit.
        let separator = NSBox()
        separator.boxType = .separator
        let okButton = NSButton(title: "OK", target: self, action: #selector(okClicked(_:)))
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Zrušit", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}"

        // Vlevo dole: výchozí hodnoty a nastavení v souboru. Všechna tři tlačítka
        // pracují s hodnotami v dialogu – platit začnou až tlačítkem OK.
        let resetAllButton = NSButton(title: "Obnovit vše", target: self, action: #selector(resetAllSettingsClicked(_:)))
        resetAllButton.toolTip = "Nastaví všechny volby i klávesové zkratky na výchozí hodnoty (uloží se až tlačítkem OK)."
        let importButton = NSButton(title: "Načíst ze souboru…", target: self, action: #selector(importClicked(_:)))
        importButton.toolTip = "Načte do dialogu nastavení uložené v souboru (uloží se až tlačítkem OK)."
        let exportButton = NSButton(title: "Uložit do souboru…", target: self, action: #selector(exportClicked(_:)))
        exportButton.toolTip = "Uloží nastavení zobrazené v dialogu do souboru JSON."
        let fileButtons = NSStackView(views: [resetAllButton, importButton, exportButton])
        fileButtons.orientation = .horizontal
        fileButtons.spacing = 10

        for view in [categoryScroll, headerBox, pageContainer, separator, fileButtons, okButton, cancelButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            categoryScroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            categoryScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            categoryScroll.widthAnchor.constraint(equalToConstant: 190),
            categoryScroll.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),

            headerBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            headerBox.leadingAnchor.constraint(equalTo: categoryScroll.trailingAnchor, constant: 12),
            headerBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            headerBox.heightAnchor.constraint(equalToConstant: 38),
            headerLabel.leadingAnchor.constraint(equalTo: headerBox.contentView!.leadingAnchor),
            headerLabel.centerYAnchor.constraint(equalTo: headerBox.contentView!.centerYAnchor),

            pageContainer.topAnchor.constraint(equalTo: headerBox.bottomAnchor, constant: 14),
            pageContainer.leadingAnchor.constraint(equalTo: headerBox.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: headerBox.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            separator.bottomAnchor.constraint(equalTo: okButton.topAnchor, constant: -12),

            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            cancelButton.widthAnchor.constraint(equalToConstant: 100),
            okButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            okButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
            okButton.widthAnchor.constraint(equalToConstant: 100),

            fileButtons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            fileButtons.centerYAnchor.constraint(equalTo: okButton.centerYAnchor),
            fileButtons.trailingAnchor.constraint(lessThanOrEqualTo: okButton.leadingAnchor, constant: -20),
        ])
        window?.contentView = content

        pageViews = [
            .general: optionsPage([(savePathsBox, "Adresáře levého a pravého panelu se po dalším spuštění "
                                    + "otevřou znovu (z archivu či FTP nejbližší lokální adresář).")]),
            .panels: optionsPage([(showHiddenBox, "Jména s úvodní tečkou a položky skryté ve Finderu (⌃H)."),
                                  (markDirsBox, "Bez zaškrtnutí ⌘A označí a Invertovat (Num *) invertuje jen soubory. "
                                    + "Opakovaný stisk ⌘A zruší celé označení (vždy i adresáře).")]),
            .colors: colorsPage(),
            .mainWindow: optionsPage([(middleBarBox, "Svislá lišta s ikonami operací mezi levým a pravým panelem. "
                                       + "Vypnutá lišta zůstane jen jako úzký dělicí pruh.")]),
            .keyboard: keyboardPage(),
        ]
        categoryTable.reloadData()
    }

    /// Šedá zalamovaná vysvětlivka pod volbou (společný styl všech stránek).
    private func noteLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Stránka se zaškrtávacími volbami, pod každou šedá vysvětlivka.
    private func optionsPage(_ options: [(NSButton, String)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for (index, (box, note)) in options.enumerated() {
            let label = noteLabel(note)
            stack.addArrangedSubview(box)
            stack.addArrangedSubview(label)
            label.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20).isActive = true
            label.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor).isActive = true
            if index < options.count - 1 { stack.setCustomSpacing(16, after: label) }
        }
        let page = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -4),
        ])
        return page
    }

    /// Stránka Barvy: výběr barevného schématu panelů (jako Konfigurace ›
    /// Barvy › Schéma v Salamanderu).
    private func colorsPage() -> NSView {
        schemePopup.removeAllItems()
        for scheme in PanelColorScheme.allCases {
            schemePopup.addItem(withTitle: scheme.title)
        }
        let label = NSTextField(labelWithString: "Schéma:")
        let row = NSStackView(views: [label, schemePopup])
        row.orientation = .horizontal
        row.spacing = 8
        let note = noteLabel(
            "„\(PanelColorScheme.macSystem.title)“ používá systémové barvy a přepíná světlý a tmavý režim "
            + "s macOS, „\(PanelColorScheme.macDark.title)“ je vždy v tmavém režimu. "
            + "Výchozí je „\(PanelColorScheme.defaultScheme.title)“. Ostatní schémata odpovídají Open Salamanderu "
            + "a mají světlé okolí panelů.")
        let page = NSView()
        for view in [row, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: page.topAnchor),
            row.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            note.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 4),
            note.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -4),
        ])
        return page
    }

    /// Přepne stránku (nadpis + obsah).
    private func selectPage(_ page: Page) {
        headerLabel.stringValue = page.title
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view = pageViews[page] else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
        ])
        if categoryTable.selectedRow != page.rawValue {
            categoryTable.selectRowIndexes(IndexSet(integer: page.rawValue), byExtendingSelection: false)
        }
    }

    // MARK: Hodnoty

    /// Nastavení tak, jak ho právě ukazují ovládací prvky dialogu (rozpracované,
    /// ještě neuložené). Zápis hodnoty naplní všechny stránky dialogu.
    var draft: SettingsSnapshot {
        get {
            var snapshot = SettingsSnapshot()
            snapshot.savePanelPaths = savePathsBox.state == .on
            snapshot.showHiddenFiles = showHiddenBox.state == .on
            snapshot.markingIncludesDirs = markDirsBox.state == .on
            snapshot.showMiddleBar = middleBarBox.state == .on
            snapshot.colorScheme = PanelColorScheme.allCases[max(0, schemePopup.indexOfSelectedItem)]
            // Ukládají se jen zkratky odlišné od výchozích.
            snapshot.keyBindings = KeyBindings.overrides(for: draftBindings)
            return snapshot
        }
        set {
            savePathsBox.state = newValue.savePanelPaths ? .on : .off
            showHiddenBox.state = newValue.showHiddenFiles ? .on : .off
            markDirsBox.state = newValue.markingIncludesDirs ? .on : .off
            middleBarBox.state = newValue.showMiddleBar ? .on : .off
            schemePopup.selectItem(at: PanelColorScheme.allCases.firstIndex(of: newValue.colorScheme) ?? 0)
            draftBindings = Dictionary(uniqueKeysWithValues: KeyBindings.table(applying: newValue.keyBindings))
            reloadBindings()
        }
    }

    /// OK: uloží všechny volby a zkratky a zavře okno.
    @objc private func okClicked(_ sender: Any?) {
        draft.apply()
        window?.close()
    }

    /// Zrušit: zavře okno bez uložení (při dalším otevření se načte uložený stav).
    @objc private func cancelClicked(_ sender: Any?) {
        window?.close()
    }

    // MARK: Výchozí hodnoty a soubor

    /// Obnovit vše: všechny stránky dialogu na výchozí hodnoty (uloží až OK).
    @objc private func resetAllSettingsClicked(_ sender: Any?) {
        draft = .defaults
    }

    /// Uložit do souboru: nastavení zobrazené v dialogu (i rozpracované) jako JSON.
    @objc private func exportClicked(_ sender: Any?) {
        guard let window else { return }
        let snapshot = draft
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MicroCommander-nastaveni.json"
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try snapshot.write(to: url)
            } catch {
                self?.showFileError("Nastavení se nepodařilo uložit.", error, after: panel)
            }
        }
    }

    /// Načíst ze souboru: naplní dialog nastavením ze souboru (uloží až OK,
    /// Zrušit ponechá dosavadní nastavení).
    @objc private func importClicked(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                self?.draft = try SettingsSnapshot.read(from: url)
            } catch {
                self?.showFileError("Nastavení se nepodařilo načíst.", error, after: panel)
            }
        }
    }

    /// Chyba práce se souborem nastavení jako sheet okna.
    /// - Parameters:
    ///   - message: co se nepodařilo
    ///   - error: příčina (chyba formátu nebo systémová chyba čtení / zápisu)
    ///   - panel: dialog výběru souboru – musí zmizet dřív, než se ukáže další sheet
    private func showFileError(_ message: String, _ error: Error, after panel: NSSavePanel) {
        panel.orderOut(nil)
        // Až po úplném zavření dialogu výběru souboru (jeho sheet se uvolní
        // na konci obsluhy dokončení), aby hlášení nečekalo ve frontě sheetů.
        DispatchQueue.main.async { [weak self] in
            PromptDialog.show(title: message, message: error.localizedDescription, over: self?.window)
        }
    }

    // MARK: Klávesnice

    /// Stránka Klávesnice: hledání, tabulka Příkaz / Zkratky a tlačítka úprav.
    private func keyboardPage() -> NSView {
        filterField.placeholderString = "Hledat příkaz nebo zkratku"
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))

        for (identifier, title, width) in [("command", "Příkaz", 260.0), ("shortcuts", "Klávesové zkratky", 300.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            bindingsTable.addTableColumn(column)
        }
        bindingsTable.usesAlternatingRowBackgroundColors = true
        bindingsTable.dataSource = self
        bindingsTable.delegate = self
        bindingsTable.target = self
        bindingsTable.doubleAction = #selector(addShortcutClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = bindingsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let addButton = NSButton(title: "Přidat zkratku…", target: self, action: #selector(addShortcutClicked(_:)))
        removeButton = NSButton(title: "Odebrat zkratku…", target: self, action: #selector(removeShortcutClicked(_:)))
        resetButton = NSButton(title: "Výchozí", target: self, action: #selector(resetCommandClicked(_:)))
        let resetAllButton = NSButton(title: "Obnovit zkratky", target: self, action: #selector(resetAllClicked(_:)))
        resetAllButton.toolTip = "Nastaví zkratky všech příkazů na výchozí (ostatní volby nemění)."
        let buttons = NSStackView(views: [addButton, removeButton, resetButton, NSView(), resetAllButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let note = noteLabel(
            "Dvojklik nebo Přidat zkratku… přiřadí příkazu další klávesovou zkratku. Navigační klávesy "
            + "(šipky, Enter, Tab, mezerník, psaní) a ⌘0–⌘9 míst z nabídky disků se nemění.")

        let page = NSView()
        for view in [filterField, scroll, buttons, note] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(view)
        }
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: page.topAnchor),
            filterField.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            filterField.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            note.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 8),
            note.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }

    /// Obnoví tabulku zkratek podle filtru (název příkazu nebo text zkratky).
    private func reloadBindings() {
        let filter = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visibleCommands = KeyBindings.commands.filter { command in
            filter.isEmpty || command.title.lowercased().contains(filter)
                || shortcutsText(command).lowercased().contains(filter)
        }
        let selected = selectedCommand
        bindingsTable.reloadData()
        if let selected, let row = visibleCommands.firstIndex(of: selected) {
            bindingsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateKeyboardButtons()
    }

    /// Zkratky příkazu jako text (např. „F5, ⌥F3“).
    private func shortcutsText(_ command: Command) -> String {
        (draftBindings[command] ?? []).map(\.display).joined(separator: ", ")
    }

    /// Příkaz na vybraném řádku tabulky zkratek.
    private var selectedCommand: Command? {
        let row = bindingsTable.selectedRow
        return row >= 0 && row < visibleCommands.count ? visibleCommands[row] : nil
    }

    private func updateKeyboardButtons() {
        let command = selectedCommand
        removeButton?.isEnabled = command.map { !(draftBindings[$0] ?? []).isEmpty } ?? false
        resetButton?.isEnabled = command.map { draftBindings[$0] != KeyBindings.defaultShortcuts(for: $0) } ?? false
    }

    @objc private func filterChanged(_ sender: Any?) {
        reloadBindings()
    }

    /// Přidat zkratku: zaznamená stisk klávesy a přiřadí ho příkazu; je-li zkratka
    /// u jiného příkazu, nabídne ji přeřadit.
    @objc private func addShortcutClicked(_ sender: Any?) {
        guard let command = selectedCommand, let window else { return }
        ShortcutRecorder.record(on: window, title: command.title) { [weak self] shortcut in
            guard let self, let shortcut else { return }
            self.assign(shortcut, to: command)
        }
    }

    /// Přiřadí zkratku příkazu (s kontrolou kolize s jiným příkazem).
    private func assign(_ shortcut: Shortcut, to command: Command) {
        guard !(draftBindings[command] ?? []).contains(where: { $0.display == shortcut.display }) else { return }
        if let other = KeyBindings.commands.first(where: { other in
            other != command && (draftBindings[other] ?? []).contains { $0.display == shortcut.display }
        }) {
            let response = PromptDialog.show(title: "Zkratka \(shortcut.display) už patří příkazu „\(other.title)“.",
                                             message: "Přeřadit ji příkazu „\(command.title)“?",
                                             buttons: ["Přeřadit"], showsCancel: true, over: window)
            guard response == 0 else { return }
            draftBindings[other]?.removeAll { $0.display == shortcut.display }
        }
        draftBindings[command, default: []].append(shortcut)
        reloadBindings()
    }

    /// Odebrat zkratku: nabídka zkratek vybraného příkazu, vybraná se odebere.
    @objc private func removeShortcutClicked(_ sender: NSButton) {
        guard let command = selectedCommand else { return }
        let menu = NSMenu()
        for shortcut in draftBindings[command] ?? [] {
            let item = NSMenuItem(title: shortcut.display, action: #selector(removeShortcutItem(_:)), keyEquivalent: "")
            item.representedObject = shortcut.display
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func removeShortcutItem(_ sender: NSMenuItem) {
        guard let command = selectedCommand, let display = sender.representedObject as? String else { return }
        draftBindings[command]?.removeAll { $0.display == display }
        reloadBindings()
    }

    /// Výchozí zkratky vybraného příkazu (kolidující zkratky se jinde odeberou).
    @objc private func resetCommandClicked(_ sender: Any?) {
        guard let command = selectedCommand else { return }
        let defaults = KeyBindings.defaultShortcuts(for: command)
        let displays = Set(defaults.map(\.display))
        for other in KeyBindings.commands where other != command {
            draftBindings[other]?.removeAll { displays.contains($0.display) }
        }
        draftBindings[command] = defaults
        reloadBindings()
    }

    /// Všechny zkratky na výchozí hodnoty.
    @objc private func resetAllClicked(_ sender: Any?) {
        draftBindings = Dictionary(uniqueKeysWithValues: KeyBindings.defaults)
        reloadBindings()
    }

    // MARK: Tabulky

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === categoryTable ? Page.allCases.count : visibleCommands.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === categoryTable {
            text = Page(rawValue: row)?.title ?? ""
        } else {
            guard row < visibleCommands.count else { return nil }
            let command = visibleCommands[row]
            text = tableColumn?.identifier.rawValue == "command" ? command.title : shortcutsText(command)
        }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = field
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = text
        cell.textField?.font = tableView === categoryTable ? NSFont.systemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === categoryTable, let page = Page(rawValue: categoryTable.selectedRow) {
            selectPage(page)
        } else if table === bindingsTable {
            updateKeyboardButtons()
        }
    }
}

/// Záznam klávesové zkratky: sheet „Stiskněte zkratku“, další stisk klávesy se
/// stane zkratkou (Escape bez modifikátoru zruší).
final class ShortcutRecorder: NSWindowController {
    private var monitor: Any?
    private var completion: ((Shortcut?) -> Void)?
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    /// Otevře záznam jako sheet.
    /// - Parameters:
    ///   - parent: okno Nastavení
    ///   - title: název příkazu
    ///   - completion: zaznamenaná zkratka, nil = zrušeno
    static func record(on parent: NSWindow, title: String, completion: @escaping (Shortcut?) -> Void) {
        let recorder = ShortcutRecorder(title: title)
        recorder.completion = completion
        parent.beginSheet(recorder.window!) { _ in
            // Kontroler drží blok sheetu až do zavření.
            _ = recorder
        }
        recorder.startMonitoring()
    }

    private init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: window)
        let heading = NSTextField(labelWithString: "Stiskněte klávesovou zkratku")
        heading.font = NSFont.boldSystemFont(ofSize: 13)
        messageLabel.stringValue = "pro příkaz „\(title)“ (Escape = zrušit)."
        let cancel = NSButton(title: "Zrušit", target: self, action: #selector(cancelClicked(_:)))
        let content = NSView()
        for view in [heading, messageLabel, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            messageLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            messageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Zachytává klávesy dřív než menu (i ⌘ zkratky aplikace).
    private func startMonitoring() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let modifiers = Shortcut.relevantModifiers(event.modifierFlags)
            if event.keyCode == KeyCode.escape && modifiers.isEmpty {
                self.finish(nil)
                return nil
            }
            guard let shortcut = Shortcut(event: event) else { return nil }
            // Písmeno nebo číslice bez modifikátoru by v panelu zablokovalo rychlé hledání.
            if shortcut.blocksQuickSearch {
                self.reject("Zkratka \(shortcut.display) by blokovala rychlé hledání – "
                            + "použijte modifikátor (⌘ ⌃ ⌥) nebo F-klávesu.")
                return nil
            }
            // Pevné klávesy (navigace, ⌘↩, ⌃↩, ⌘Tab, ⌘0–⌘9) přiřadit nejdou.
            if shortcut.isReserved {
                self.reject("Klávesa \(shortcut.display) je vyhrazená pro pevné ovládání – zvolte jinou.")
                return nil
            }
            self.finish(shortcut)
            return nil
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(nil)
    }

    /// Odmítnutá klávesa: vysvětlení v dialogu a pípnutí, záznam pokračuje.
    private func reject(_ message: String) {
        messageLabel.stringValue = message
        NSSound.beep()
    }

    /// Ukončí záznam a zavře sheet.
    private func finish(_ shortcut: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        completion?(shortcut)
        completion = nil
    }
}
