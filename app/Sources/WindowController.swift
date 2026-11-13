// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Hlavní okno ve stylu Salamandera: horní nástrojová lišta, lišta disků,
// dva panely s prostřední lištou, příkazová řádka a lišta F-kláves.
// Obsahuje veškeré příkazy (F2–F12, Ctrl/Alt varianty) a směrování kláves.

import AppKit

/// Hlavní kontroler okna (dual-pane).
final class MainWindowController: NSWindowController, NSWindowDelegate, PanelDelegate, PanelInputHandler, NSMenuItemValidation {
    /// Panely – leftPanel je vždy ten, který je právě vlevo (⌘U je prohodí).
    private(set) var leftPanel: PanelController
    private(set) var rightPanel: PanelController
    private var leftView: PanelView
    private var rightView: PanelView
    /// Aktivní (zdrojový) panel.
    private(set) var activePanel: PanelController

    private let panelStack = NSStackView()
    private let topBar: CommandBar
    private let middleBar: CommandBar
    private let driveBar = DriveBar()
    let commandLine = CommandLineView()
    let functionBar = FunctionKeyBar()

    /// Progress dialog (pokud běží operace).
    private var progressDialog: ProgressDialog?
    /// Otevřený sheet (FTP, hledání) – drží kontroler naživu po dobu zobrazení.
    var sheetController: NSWindowController?
    /// Monitory klávesnice (F-klávesy, Tab, modifikátory pro lištu F-kláves).
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    /// Pozorovatelé aktivace aplikace (odregistrují se v deinit).
    private var appObservers: [NSObjectProtocol] = []

    /// Jméno automatického ukládání polohy okna.
    private static let frameAutosaveName = "MicroCommanderMain"
    /// Vazba „oba panely stejně široké“ (po prohození panelů se nahrazuje novou).
    private var equalWidthConstraint: NSLayoutConstraint?

    /// Neaktivní (cílový) panel.
    var inactivePanel: PanelController { activePanel === leftPanel ? rightPanel : leftPanel }

    init() {
        // Oba panely nad celým lokálním diskem – cesty ve VFS jsou reálné cesty.
        // Výchozí adresáře: naposledy otevřené (pokud ještě existují), jinak domov a „/“.
        let disk = Vfs.localDisk
        leftPanel = PanelController(location: Location(vfs: disk, path: Self.savedDirectory("leftPanelPath") ?? NSHomeDirectory()))
        rightPanel = PanelController(location: Location(vfs: disk, path: Self.savedDirectory("rightPanelPath") ?? "/"))
        leftView = PanelView(panel: leftPanel)
        rightView = PanelView(panel: rightPanel)
        activePanel = leftPanel

        topBar = CommandBar(entries: [
            (.back, "chevron.left", "Zpět (⌥←)"),
            (.forward, "chevron.right", "Vpřed (⌥→)"),
            (.up, "arrow.turn.left.up", "Nadřazený adresář (⌫)"),
            (.root, "arrow.up.to.line", "Kořenový adresář (⌘\\)"),
            (.home, "house", "Domovský adresář"),
            nil,
            (.refresh, "arrow.clockwise", "Obnovit (⌘R)"),
            (.swap, "arrow.left.arrow.right", "Prohodit panely (⌘U)"),
            (.sameDirOther, "arrow.right.to.line.square", "Poslat aktuální adresář do druhého panelu (⌘. / ⌃.)"),
            (.sameDir, "arrow.left.to.line.square", "Převzít adresář z druhého panelu (⌘⇧. / ⌃⇧.)"),
            nil,
            (.selectMask, "plus.square", "Označit podle masky (Num +)"),
            (.unselectMask, "minus.square", "Odznačit podle masky (Num −)"),
            (.invertMarks, "plusminus", "Invertovat označení (Num *)"),
            nil,
            (.find, "magnifyingglass", "Vyhledat soubory a adresáře (⌥F7, ⌃F)"),
            (.compare, "rectangle.split.2x1", "Porovnat adresáře (⌃F10)"),
            (.calcSize, "sum", "Spočítat velikost (⌥F10)"),
            (.toggleHidden, "eye", "Zobrazovat skryté soubory (⌃H)"),
            (.viewMenu, "square.grid.2x2", "Režim zobrazení panelu (⌥1–⌥6)"),
            nil,
            (.connect, "network", "FTP/SFTP servery (F11)"),
            (.disconnect, "eject", "Odpojit / zavřít archiv (F12)"),
            (.terminal, "terminal", "Terminál v adresáři (F9)"),
        ], vertical: false)

        middleBar = CommandBar(entries: [
            (.copy, "doc.on.doc", "Kopírovat (F5)"),
            (.move, "arrow.right.doc.on.clipboard", "Přesunout (F6)"),
            (.mkdir, "folder.badge.plus", "Nový adresář (F7)"),
            (.delete, "trash", "Smazat (F8)"),
            nil,
            (.rename, "pencil", "Přejmenovat (F2)"),
            (.view, "eye.square", "Zobrazit (F3)"),
            (.edit, "square.and.pencil", "Upravit (F4)"),
            (.newFile, "doc.badge.plus", "Nový soubor (⇧F4)"),
            nil,
            (.pack, "archivebox", "Zabalit do ZIP (⌥F5)"),
            (.unpack, "shippingbox.and.arrow.backward", "Rozbalit (⌥F6)"),
        ], vertical: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MicroCommander"
        window.minSize = NSSize(width: 820, height: 460)
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName(MainWindowController.frameAutosaveName)
        if !window.setFrameUsingName(MainWindowController.frameAutosaveName) {
            window.center()
        }

        buildLayout()
        wireCallbacks()
        installKeyMonitors()
        restoreSettings()

        leftPanel.reload()
        rightPanel.reload()
        activate(leftPanel)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Rozvržení

    /// Svislé skládání: lišta, disky, panely (+ prostřední lišta), příkazová řádka, F-klávesy.
    private func buildLayout() {
        let container = NSView()
        panelStack.orientation = .horizontal
        panelStack.spacing = 0
        panelStack.distribution = .fill
        panelStack.alignment = .height
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        panelStack.addArrangedSubview(leftView)
        panelStack.addArrangedSubview(middleBar)
        panelStack.addArrangedSubview(rightView)
        pinEqualPanelWidths()

        let separators = (0..<3).map { _ -> NSBox in
            let box = NSBox()
            box.boxType = .separator
            box.translatesAutoresizingMaskIntoConstraints = false
            return box
        }
        let views: [NSView] = [topBar, separators[0], driveBar, separators[1], panelStack, separators[2], commandLine, functionBar]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        // Řetěz shora dolů.
        var previous = container.topAnchor
        for view in views {
            view.topAnchor.constraint(equalTo: previous).isActive = true
            previous = view.bottomAnchor
        }
        functionBar.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        window?.contentView = container
    }

    /// Oba panely stejně široké. Vazba se váže na konkrétní dvojici pohledů,
    /// proto se po prohození panelů stará zruší a vytvoří nová (jinak by
    /// s každým ⌘U jedna přibyla).
    private func pinEqualPanelWidths() {
        equalWidthConstraint?.isActive = false
        let constraint = leftView.widthAnchor.constraint(equalTo: rightView.widthAnchor)
        constraint.isActive = true
        equalWidthConstraint = constraint
    }

    /// Uložený adresář panelu z předvoleb, pokud stále existuje (jinak nil).
    private static func savedDirectory(_ key: String) -> String? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? path : nil
    }

    /// Lokální adresář panelu pro obnovení po dalším spuštění: na disku aktuální
    /// cesta, v archivu či na FTP nejbližší lokální adresář, ze kterého se vešlo.
    private static func restorableDirectory(of panel: PanelController) -> String? {
        let locations = [panel.location] + panel.parentLocations.reversed().map(\.location)
        for location in locations where location.vfs.kind == SAL_VFS_LOCAL {
            if let path = location.vfs.realPath(location.path) { return path }
        }
        return nil
    }

    /// Při ukončení aplikace uloží adresáře obou panelů (ne při self-testu /
    /// kontrole kláves – ty pracují v dočasných adresářích).
    private func observeTermination() {
        guard !AppDelegate.isAutomatedRun else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            // Nastavení › Obecné: bez ukládání se příště otevřou výchozí adresáře.
            let save = Settings.savePanelPaths
            let defaults = UserDefaults.standard
            defaults.set(save ? Self.restorableDirectory(of: self.leftPanel) : nil, forKey: "leftPanelPath")
            defaults.set(save ? Self.restorableDirectory(of: self.rightPanel) : nil, forKey: "rightPanelPath")
        }
    }

    /// Obnoví uložené volby: skryté soubory a režimy zobrazení obou stran.
    private func restoreSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showHiddenFiles") != nil {
            showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        }
        leftPanel.showHidden = showHiddenFiles
        rightPanel.showHidden = showHiddenFiles
        topBar.setSymbol(showHiddenFiles ? "eye" : "eye.slash", for: .toggleHidden)
        if let mode = ViewMode(rawValue: defaults.integer(forKey: "viewModeLeft")) {
            leftView.viewMode = mode
        }
        if let mode = ViewMode(rawValue: defaults.integer(forKey: "viewModeRight")) {
            rightView.viewMode = mode
        }
    }

    /// Napojení lišt a panelů na příkazy.
    private func wireCallbacks() {
        observeTermination()
        for (panel, view) in [(leftPanel, leftView), (rightPanel, rightView)] {
            panel.delegate = self
            view.inputHandler = self
        }
        topBar.onCommand = { [weak self] in self?.perform($0) }
        middleBar.onCommand = { [weak self] in self?.perform($0) }
        // Prostřední lišta podle nastavení; změna v Nastavení se projeví hned.
        middleBar.setCollapsed(!Settings.showMiddleBar)
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.middleBar.setCollapsed(!Settings.showMiddleBar)
        }
        // Barevné schéma: panely si znovu načtou barvy.
        NotificationCenter.default.addObserver(forName: Settings.colorSchemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.leftView.applyColorScheme()
            self?.rightView.applyColorScheme()
        }
        functionBar.onCommand = { [weak self] in self?.perform($0) }
        driveBar.onPlace = { [weak self] place in
            guard let self else { return }
            self.open(place, in: self.activePanel)
        }
        driveBar.onEditPlaces = { [weak self] in self?.perform(.editPlaces) }
        driveBar.onConnect = { [weak self] in self?.perform(.connect) }
        commandLine.onExecute = { [weak self] command, inTerminal in
            self?.executeCommandLine(command, inTerminal: inTerminal)
        }
        commandLine.onLeave = { [weak self] in self?.focusActivePanel() }
        commandLine.onForwardKey = { [weak self] event in
            guard let self else { return }
            _ = self.panelView(self.view(of: self.activePanel), keyDown: event)
        }
    }

    /// Monitory: F-klávesy a Tab nad celým oknem, modifikátory pro lištu F-kláves.
    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Diagnostický záznam kláves (zapíná `defaults write com.github.svopex.microcommander keyLog -bool YES`).
            if KeyLog.enabled {
                KeyLog.write(event, responder: event.window?.firstResponder)
            }
            guard let self, let window = self.window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            // ⌘0–⌘9: místo z nabídky disků se zkratkou do aktivního panelu.
            if let digit = KeyCode.commandDigit(event), let place = PlaceStore.place(forShortcut: digit) {
                self.open(place, in: self.activePanel)
                return nil
            }
            // Klávesové zkratky příkazů (Nastavení › Klávesnice) dřív než menu a panel:
            // F-klávesy fungují odkudkoli, v textovém poli se nepoužijí zkratky
            // potřebné pro psaní (viz Shortcut.isTextEditing).
            if let command = self.command(forKey: event) {
                self.perform(command)
                return nil
            }
            // Enter s modifikátorem (zachytává se tady, protože macOS jinak ⌃↩ použije
            // jako „Zobrazit kontextovou nabídku“ a do panelu se klávesa nedostane):
            // - ⌘Enter / Ctrl+Enter v příkazové řádce s příkazem: spustit ho v novém
            //   okně Terminalu (interaktivní skripty, dotazy na heslo, průběžný výstup),
            // - Ctrl+Enter jinde (panel, prázdná řádka): jméno položky do řádky.
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter,
               modifiers == .command || modifiers == .control {
                if self.commandLineHasFocus, modifiers == .command || self.commandLine.hasCommand {
                    self.commandLine.submit(inTerminal: true)
                    return nil
                }
                guard modifiers == .control else { return event }
                if let item = self.activePanel.currentItem {
                    // Soubor na začátku prázdné řádky = „./jméno“ připravené ke spuštění;
                    // fokus pak do řádky (kurzor na konec), aby Enter příkaz spustil.
                    if self.commandLine.insert(shellQuote(item.name), asCommand: !item.isDir),
                       !self.commandLineHasFocus {
                        window.makeFirstResponder(self.commandLine.field)
                        self.commandLine.field.currentEditor()?.moveToEndOfDocument(nil)
                    }
                }
                return nil
            }
            // ⌘Tab / Ctrl+Tab: přepínání mezi panelem a příkazovou řádkou.
            if event.keyCode == KeyCode.tab, !event.modifierFlags.intersection([.control, .command]).isEmpty {
                if self.commandLineHasFocus {
                    self.focusActivePanel()
                } else {
                    window.makeFirstResponder(self.commandLine.field)
                }
                return nil
            }
            // Tab v příkazové řádce i v panelu přepíná panely (jako Salamander).
            if event.keyCode == KeyCode.tab, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               self.commandLineHasFocus || isPanelResponder(window.firstResponder) {
                self.activate(self.inactivePanel)
                return nil
            }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.functionBar.update(modifiers: event.modifierFlags)
            return event
        }
        // Puštění modifikátoru v jiné aplikaci (např. ⌃↩ spustí Terminal) aplikace
        // nedostane – lišta F-kláves by zůstala ve vrstvě Ctrl/Shift/Alt. Při
        // deaktivaci se vrátí základní vrstva, při aktivaci aktuální stav kláves.
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.functionBar.update(modifiers: [])
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.functionBar.update(modifiers: NSEvent.modifierFlags)
            },
        ]
    }

    /// Má fokus příkazová řádka (její field editor)?
    private var commandLineHasFocus: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate as? NSTextField === commandLine.field
    }

    /// Příkaz pro stisknutou klávesu podle platných zkratek; v textovém poli
    /// (příkazová řádka, úprava cesty či jména) bez zkratek potřebných pro psaní.
    func command(forKey event: NSEvent) -> Command? {
        KeyBindings.command(for: event, textEditing: !isPanelResponder(window?.firstResponder))
    }

    // MARK: - Aktivní panel

    /// Udělá panel aktivním (zvýraznění řádku adresáře, fokus tabulky).
    func activate(_ panel: PanelController) {
        let changed = activePanel !== panel
        activePanel = panel
        leftPanel.isActive = panel === leftPanel
        rightPanel.isActive = panel === rightPanel
        if changed {
            leftPanel.endQuickSearch()
            rightPanel.endQuickSearch()
        }
        leftView.refreshAppearance()
        rightView.refreshAppearance()
        if !commandLineHasFocus {
            focusActivePanel()
        }
        updateChrome()
    }

    /// Fokus klávesnice do tabulky aktivního panelu.
    func focusActivePanel() {
        let target = view(of: activePanel).focusView
        if window?.firstResponder !== target {
            window?.makeFirstResponder(target)
        }
    }

    /// Pohled panelu.
    private func view(of panel: PanelController) -> PanelView {
        panel === leftPanel ? leftView : rightView
    }

    /// Obnoví řádky adresáře, informační řádky a prompt příkazové řádky.
    private func updateChrome() {
        for panel in [leftPanel, rightPanel] {
            let panelView = view(of: panel)
            panelView.directoryLine.path = panel.displayPath
            // Úprava cesty pracuje s cestou ve VFS (u archivu a serveru se
            // liší od zobrazeného textu s popiskem).
            panelView.directoryLine.editablePath = panel.location.path
            panelView.infoLine.text = infoText(for: panel)
        }
        commandLine.prompt = activePanel.displayPath
        window?.title = "MicroCommander – \(activePanel.displayPath)"
    }

    /// Volné místo na řádku adresáře (jen lokální disk).
    private func updateFreeSpace(_ panel: PanelController) {
        let location = panel.location
        var text = ""
        if location.vfs.kind == SAL_VFS_LOCAL, let free = location.vfs.freeSpace(location.path) {
            text = formatSize(UInt64(free)) + " volných"
        }
        view(of: panel).directoryLine.freeSpace = text
    }

    /// Text informačního řádku: rychlé hledání, souhrn označení, nebo položka pod kurzorem.
    private func infoText(for panel: PanelController) -> String {
        if panel.isLoading {
            return "Načítám…"
        }
        if let search = panel.quickSearch {
            return "Rychlé hledání: \(search)"
        }
        let marked = panel.markedItems
        if !marked.isEmpty {
            let dirs = marked.filter(\.isDir).count
            let files = marked.count - dirs
            let size = marked.filter { !$0.isDir }.reduce(UInt64(0)) { $0 + $1.size }
            return "Označeno: \(formatExactSize(size)) B v \(files) souborech a \(dirs) adresářích"
        }
        guard let row = panel.currentRow else {
            return "Prázdný adresář"
        }
        if row.isParent {
            // Počty jen viditelných položek (jeden průchod); skryté zvlášť.
            var visibleCount = 0
            var dirs = 0
            for entry in panel.rows where !entry.isParent {
                visibleCount += 1
                if entry.item.isDir { dirs += 1 }
            }
            let hiddenCount = panel.items.count - visibleCount
            let hiddenText = hiddenCount > 0 ? " (skryto \(hiddenCount))" : ""
            return "..: nadřazený adresář • \(visibleCount - dirs) souborů, \(dirs) adresářů\(hiddenText)"
        }
        let item = row.item
        let size = item.isDir ? "DIR" : formatExactSize(item.size)
        var parts = ["\(item.name): \(size)", "\(formatDay(item.mtime)) \(formatTime(item.mtime))"]
        if item.isReadonly || item.isHidden || item.isLink || item.isEncrypted {
            parts.append([item.isReadonly ? "R" : "", item.isHidden ? "H" : "", item.isLink ? "L" : "",
                          item.isEncrypted ? "E" : ""].joined())
        }
        if item.isEncrypted {
            parts.append("šifrováno")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - PanelDelegate

    func panelDidReload(_ panel: PanelController) {
        updateFreeSpace(panel)
        updateChrome()
    }

    func panelStateChanged(_ panel: PanelController) {
        updateChrome()
    }

    func panelWantsActivation(_ panel: PanelController) {
        if activePanel !== panel || !isPanelResponder(window?.firstResponder) {
            activate(panel)
        }
    }

    /// Chyba výpisu: hlášení a návrat zpět (nebo nahoru), aby panel nezůstal prázdný.
    func panel(_ panel: PanelController, failedWithPath path: String, error: Error) {
        showAlert(title: "Nelze otevřít adresář", text: "\(path)\n\n\(error.localizedDescription)")
        if panel.canGoUp {
            panel.goUp()
        }
    }

    // MARK: - Vstup z panelu (klávesy, myš)

    /// Klávesy v panelu podle Salamandera (s macOS ekvivalenty ⌘ pro Ctrl).
    func panelView(_ view: PanelView, keyDown event: NSEvent) -> Bool {
        let panel = view.panel
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let ctrlOrCmd = flags.contains(.control) || flags.contains(.command)

        // Home/End podle znaku klávesy (ne jen kódu): přemapované a externí klávesnice,
        // Karabiner či vzdálená plocha mohou poslat znak Home/End s jiným kódem klávesy.
        // ⌘← / ⌘→ fungují jako Home / End (konvence macOS „na začátek/konec“).
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
            let isHome = scalar == NSHomeFunctionKey || scalar == 0xF73A /* NSBeginOfLineFunctionKey */
                || (scalar == NSLeftArrowFunctionKey && flags.contains(.command))
            let isEnd = scalar == NSEndFunctionKey || scalar == 0xF73B /* NSEndOfLineFunctionKey */
                || (scalar == NSRightArrowFunctionKey && flags.contains(.command))
            if isHome || isEnd {
                view.moveCursorToEdge(first: isHome, extend: flags.contains(.shift))
                return true
            }
        }

        switch event.keyCode {
        case KeyCode.up:
            if flags.contains(.command) { panel.goUp(); return true }
            // ⌥↑ = první položka (konvence seznamů v macOS, obdoba Home).
            if flags == .option { view.moveCursorToEdge(first: true, extend: false); return true }
            if panel.quickSearch != nil, flags.isEmpty { panel.quickSearchNext(forward: false); return true }
            moveCursor(view, key: .up, flags: flags)
            return true
        case KeyCode.down:
            if flags.contains(.command) { openRow(panel.cursor, in: panel); return true }
            // ⌥↓ = poslední položka (obdoba End).
            if flags == .option { view.moveCursorToEdge(first: false, extend: false); return true }
            if panel.quickSearch != nil, flags.isEmpty { panel.quickSearchNext(forward: true); return true }
            moveCursor(view, key: .down, flags: flags)
            return true
        case KeyCode.pageUp:
            if ctrlOrCmd { panel.goUp(); return true }
            moveCursor(view, key: .pageUp, flags: flags)
            return true
        case KeyCode.pageDown:
            if ctrlOrCmd { openRow(panel.cursor, in: panel); return true }
            moveCursor(view, key: .pageDown, flags: flags)
            return true
        case KeyCode.home:
            // Home / fn+← – první položka; ⇧Home označí rozsah ke začátku.
            view.moveCursorToEdge(first: true, extend: flags.contains(.shift))
            return true
        case KeyCode.end:
            // End / fn+→ – poslední položka; ⇧End označí rozsah ke konci.
            view.moveCursorToEdge(first: false, extend: flags.contains(.shift))
            return true
        case KeyCode.left:
            // ⌥← zpět v historii; jinak pohyb podle režimu (v Podrobném nic).
            if flags.contains(.option) { panel.goBack(); return true }
            moveCursor(view, key: .left, flags: flags)
            return true
        case KeyCode.right:
            if flags.contains(.option) { panel.goForward(); return true }
            moveCursor(view, key: .right, flags: flags)
            return true
        case KeyCode.returnKey, KeyCode.enter:
            panel.endQuickSearch()
            // ⌘↩ spustí položku systémově (aplikaci .app místo vstupu do ní).
            if flags.contains(.command) { launchRow(panel.cursor, in: panel); return true }
            openRow(panel.cursor, in: panel)
            return true
        case KeyCode.backspace:
            if panel.quickSearch != nil { panel.quickSearchBackspace(); return true }
            if flags.contains(.command) { perform(.delete); return true }
            if flags.contains(.shift) || flags.contains(.control) { panel.goRoot(); return true }
            panel.goUp()
            return true
        case KeyCode.forwardDelete:
            perform(.delete)
            return true
        case KeyCode.escape:
            if panel.quickSearch != nil { panel.endQuickSearch(); return true }
            commandLine.field.stringValue = ""
            return true
        case KeyCode.space where flags.isEmpty && panel.quickSearch == nil,
             KeyCode.insert:
            // Space/Insert: označit položku a posunout kurzor (Insert z Windows).
            panel.toggleMark(row: panel.cursor)
            panel.setCursor(panel.cursor + 1)
            return true
        default:
            break
        }

        // Zkratky příkazů (KeyBindings). Normálně je vyřídí už monitor kláves okna;
        // tady jako záložní cesta pro klávesy předané panelu jinak (z příkazové
        // řádky, kontrola kláves bez okna).
        if let command = command(forKey: event) {
            perform(command)
            return true
        }

        // Zkratky s Ctrl/⌘ a písmenem (Ctrl varianty Salamandera).
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if ctrlOrCmd && !flags.contains(.option) {
            // Příkazy se zkratkami řeší KeyBindings v monitoru kláves; tady zůstává
            // jen vkládání cest panelů do příkazové řádky.
            switch chars {
            case "[":
                commandLine.insert(shellQuote(leftPanel.displayPath)); return true
            case "]":
                commandLine.insert(shellQuote(rightPanel.displayPath)); return true
            default: break
            }
        }

        // Tisknutelné znaky bez modifikátorů: rychlé hledání (Quick Search).
        if flags.subtracting(.shift).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            if typed == " " && panel.quickSearch == nil { return true }
            panel.quickSearchType(typed)
            return true
        }
        return false
    }

    /// Pohyb kurzoru směrovou klávesou podle rozvržení režimu zobrazení.
    /// ⇧↑/⇧↓ přepnou označení položky (jako Insert), ⇧ u větších skoků označí rozsah.
    private func moveCursor(_ view: PanelView, key: NavigationKey, flags: NSEvent.ModifierFlags) {
        let panel = view.panel
        panel.endQuickSearch()
        guard let target = view.target(from: panel.cursor, key: key) else { return }
        let clamped = max(0, min(target, panel.rows.count - 1))
        if flags.contains(.shift) {
            if key == .up || key == .down {
                panel.toggleMark(row: panel.cursor)
            } else {
                panel.setMarkRange(from: panel.cursor, to: clamped, true)
            }
        }
        panel.setCursor(clamped)
    }

    /// Je responder tabulkou nebo mřížkou některého panelu?
    private func isPanelResponder(_ responder: NSResponder?) -> Bool {
        responder is SalTableView || responder is FileGridView
    }

    /// Nastaví režim zobrazení panelu a uloží ho (pro levou/pravou stranu zvlášť).
    func setViewMode(_ mode: ViewMode, for panel: PanelController) {
        view(of: panel).viewMode = mode
        saveViewModes()
        updateChrome()
    }

    /// Uloží režimy zobrazení obou stran do UserDefaults.
    private func saveViewModes() {
        UserDefaults.standard.set(leftView.viewMode.rawValue, forKey: "viewModeLeft")
        UserDefaults.standard.set(rightView.viewMode.rawValue, forKey: "viewModeRight")
    }

    /// Menu režimů zobrazení pro aktivní panel (tlačítko lišty, kontextové menu).
    func viewModeMenu() -> NSMenu {
        let menu = NSMenu()
        let current = view(of: activePanel).viewMode
        for mode in ViewMode.allCases {
            // Zkratka režimu podle Nastavení › Klávesnice (výchozí ⌥1–⌥6).
            let shortcut = Command.allCases.first { $0.viewMode == mode }.flatMap(KeyBindings.menuShortcut(for:))
            let item = NSMenuItem(title: mode.title, action: #selector(viewModeSelected(_:)), keyEquivalent: shortcut?.menuKey ?? "")
            item.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
            item.tag = mode.rawValue
            item.state = mode == current ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hidden = NSMenuItem(title: "Zobrazovat skryté soubory", action: #selector(menuCommand(_:)), keyEquivalent: "")
        hidden.tag = MainWindowController.menuCommandIndex(.toggleHidden)
        hidden.state = showHiddenFiles ? .on : .off
        hidden.target = self
        menu.addItem(hidden)
        return menu
    }

    @objc func viewModeSelected(_ sender: NSMenuItem) {
        guard let mode = ViewMode(rawValue: sender.tag) else { return }
        setViewMode(mode, for: activePanel)
    }

    // MARK: - Skryté soubory

    /// Zobrazovat skryté soubory (tečka na začátku, příznak UF_HIDDEN) – globálně pro oba panely.
    private(set) var showHiddenFiles = true

    /// Přepne zobrazení skrytých souborů v obou panelech a uloží volbu.
    func toggleHiddenFiles() {
        showHiddenFiles.toggle()
        leftPanel.showHidden = showHiddenFiles
        rightPanel.showHidden = showHiddenFiles
        UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles")
        topBar.setSymbol(showHiddenFiles ? "eye" : "eye.slash", for: .toggleHidden)
        updateChrome()
    }

    func panelView(_ view: PanelView, openRow row: Int) {
        openRow(row, in: view.panel)
    }

    /// Kontextové menu panelu (operace nad položkami).
    func panelView(_ view: PanelView, menuForRow row: Int) -> NSMenu? {
        let menu = NSMenu()
        // „Otevřít“ = Enter na položce (není to příkaz z Command).
        let open = NSMenuItem(title: "Otevřít", action: #selector(contextOpen(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let entries: [Command?] = [
            .view, .edit, nil, .copy, .move, .rename, .delete, nil,
            .pack, .unpack, .calcSize, nil, .changeAttributes, .properties,
        ]
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            // Název příkazu se zkratkou podle Nastavení › Klávesnice.
            let title = KeyBindings.shortcuts(for: entry).first.map { "\(entry.title) (\($0.display))" } ?? entry.title
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.tag = MainWindowController.menuCommandIndex(entry)
            item.target = self
            menu.addItem(item)
        }
        // Režim zobrazení jako podmenu (⌥1–⌥6).
        menu.addItem(.separator())
        let modes = NSMenuItem(title: "Zobrazení", action: nil, keyEquivalent: "")
        modes.submenu = viewModeMenu()
        menu.addItem(modes)
        // Lokální soubory: Finder a cesta do schránky.
        if let item = view.panel.currentItem, let path = view.panel.localPath(of: item.name) {
            menu.addItem(.separator())
            let finder = NSMenuItem(title: "Zobrazit ve Finderu", action: #selector(revealInFinder(_:)), keyEquivalent: "")
            finder.representedObject = path
            finder.target = self
            menu.addItem(finder)
            let copyPath = NSMenuItem(title: "Kopírovat cestu", action: #selector(copyPathToPasteboard(_:)), keyEquivalent: "")
            copyPath.representedObject = path
            copyPath.target = self
            menu.addItem(copyPath)
        }
        return menu
    }

    /// Akce položky nabídky disků.
    enum DriveChoice {
        case place(Place)
        case manageServers
        case editPlaces

        /// Místo (nil u pevných položek na konci nabídky).
        var place: Place? {
            if case .place(let place) = self { return place }
            return nil
        }
    }

    /// Položky nabídky disků: zobrazená místa (disky, vlastní adresáře, servery)
    /// ve společném pořadí, na konci správa serverů a úprava nabídky. Sdílí
    /// nabídka i self-test.
    static func driveChooserItems() -> [(entry: DriveChooser.Entry, choice: DriveChoice)] {
        // Cestu ukážeme jen tam, kde se liší od názvu (kořen „/“ by byl dvakrát).
        // Zkratka ⌘0–⌘9 se připojí k popisu položky.
        let shortcuts = PlaceStore.shortcuts
        var items = PlaceStore.visiblePlaces().map { place in
            let path = place.title == place.detail ? "" : place.detail
            let shortcut = shortcuts[place.key].map(PlaceStore.shortcutLabel) ?? ""
            let detail = [path, shortcut].filter { !$0.isEmpty }.joined(separator: "   ")
            return (entry: DriveChooser.Entry(title: place.title, detail: detail, icon: place.icon),
                    choice: DriveChoice.place(place))
        }
        items.append((entry: DriveChooser.Entry(title: "FTP/SFTP servery…", detail: "",
                                                icon: NSImage(systemSymbolName: "network", accessibilityDescription: nil)),
                      choice: .manageServers))
        items.append((entry: DriveChooser.Entry(title: "Upravit nabídku disků…", detail: "",
                                                icon: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)),
                      choice: .editPlaces))
        return items
    }

    /// Přesouvatelné položky nabídky: všechna místa (bez omezení mezi typy),
    /// pevné zůstávají jen dvě položky na konci.
    static func driveChooserGroups(_ items: [(entry: DriveChooser.Entry, choice: DriveChoice)]) -> [Range<Int>] {
        [0..<items.compactMap(\.choice.place).count]
    }

    func panelView(_ view: PanelView, perform command: Command) {
        activate(view.panel)
        perform(command)
    }

    /// Nabídka disků pro panel (⌥F1/⌥F2, tlačítko disku). Výchozí řádek = místo,
    /// na kterém panel právě je; místa lze přesouvat (šipky v řádku, ⌥↑/⌥↓).
    func panelViewShowDriveChooser(_ view: PanelView, anchor: NSView) {
        let panel = view.panel
        // Položky se při přesunu v nabídce prohazují – výběr pak odpovídá novému pořadí.
        var items = MainWindowController.driveChooserItems()
        let places = items.compactMap(\.choice.place)
        let chooser = DriveChooser.show(entries: items.map(\.entry), selected: currentPlaceIndex(places, panel: panel),
                                        movableGroups: MainWindowController.driveChooserGroups(items),
                                        below: anchor) { [weak self] index in
            guard let self else { return }
            self.activate(panel)
            switch items[index].choice {
            case .place(let place): self.open(place, in: panel)
            case .manageServers: ConnectWindowController.show(parent: self, panel: panel)
            case .editPlaces: PlacesWindowController.show(parent: self)
            }
        }
        chooser.onMove = { from, to in
            items.swapAt(from, to)
            // Prohození v celkovém pořadí míst (skrytá místa zůstávají na svém místě).
            if let first = items[from].choice.place, let second = items[to].choice.place {
                PlaceStore.swap(first.key, second.key)
            }
        }
    }

    /// Otevře místo v panelu: disk/adresář jako cestu, server připojí.
    func open(_ place: Place, in panel: PanelController) {
        switch place.kind {
        case .drive, .folder: openDrive(place.detail, in: panel)
        case .server(let server): connect(server: server, in: panel)
        }
    }

    /// Index místa, pod které patří aktuální cesta panelu (nejdelší shodný prefix
    /// cesty disku nebo adresáře); vzdálený panel → 0.
    private func currentPlaceIndex(_ places: [Place], panel: PanelController) -> Int {
        guard let path = panel.location.vfs.realPath(panel.location.path) else { return 0 }
        var best = 0
        var bestLength = -1
        for (index, place) in places.enumerated() {
            guard let placePath = place.path else { continue }
            let prefix = placePath == "/" ? "/" : placePath + "/"
            if (path == placePath || path.hasPrefix(prefix)) && placePath.count > bestLength {
                best = index
                bestLength = placePath.count
            }
        }
        return best
    }

    @objc private func contextOpen(_ sender: Any?) {
        openRow(activePanel.cursor, in: activePanel)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func copyPathToPasteboard(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        copyTextToPasteboard(path)
    }

    /// Ukáže položku v panelu (Ukázat v okně Hledat): aktivní panel přejde do
    /// jejího adresáře a kurzor na ni. Lokální položky jdou do aktivního panelu,
    /// položky archivu/FTP do panelu, který má daný VFS otevřený.
    /// - Parameters:
    ///   - vfs: souborový systém položky
    ///   - path: VFS cesta položky
    func showItem(vfs: Vfs, path: String) {
        let dir = parentPath(path)
        let name = lastComponent(path)
        if vfs.kind == SAL_VFS_LOCAL, let localDir = vfs.realPath(dir) {
            let panel = activePanel
            if panel.location.vfs === Vfs.localDisk {
                panel.changePath(localDir, focus: name)
            } else {
                // Z archivu nebo serveru zpět na disk (zanoření se zavře).
                panel.navigate(Location(vfs: Vfs.localDisk, path: localDir))
                panel.focus(name: name)
            }
            activate(panel)
        } else if let panel = [activePanel, leftPanel, rightPanel].first(where: { $0.location.vfs === vfs }) {
            panel.changePath(dir, focus: name)
            activate(panel)
        } else {
            NSSound.beep()
            return
        }
        window?.makeKeyAndOrderFront(nil)
    }

    /// Znovu načte oba panely (po změnách z okna Hledat).
    func reloadPanels() {
        leftPanel.reload()
        rightPanel.reload()
    }

    /// Otevře lokální svazek v panelu (na lokálním disku jen změní cestu).
    private func openDrive(_ path: String, in panel: PanelController?) {
        guard let panel else { return }
        if panel.location.vfs === Vfs.localDisk {
            panel.changePath(path)
        } else {
            // Z archivu nebo serveru zpět na disk (zanoření se zavře).
            panel.navigate(Location(vfs: Vfs.localDisk, path: path))
        }
        activate(panel)
    }

    // MARK: - Otevírání položek

    /// Enter/dvojklik: adresář otevřít, archiv otevřít jako panel, soubor spustit.
    func openRow(_ row: Int, in panel: PanelController) {
        guard row >= 0, row < panel.rows.count else { return }
        let entry = panel.rows[row]
        if entry.isParent {
            panel.goUp()
            return
        }
        let item = entry.item
        if item.isDir {
            panel.changePath(joinPath(panel.location.path, item.name))
            return
        }
        // Spustitelný shell skript na lokálním disku: spustit v Terminalu v adresáři
        // panelu (⌘Enter ho naopak otevře podle přípony).
        if let path = panel.localPath(of: item.name), isShellScript(atPath: path) {
            runInTerminal("./" + shellQuote(item.name), in: parentPath(path))
            return
        }
        withLocalFile(item, in: panel) { [weak self] path in
            guard let self else { return }
            if let archive = self.openArchive(path) {
                panel.navigate(Location(vfs: archive, path: "/"), nested: true, focus: item.name)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// ⌘Enter: otevře položku výchozí aplikací macOS bez vstupu dovnitř –
    /// aplikace (.app) se spustí, balíček/adresář se otevře ve Finderu, soubor
    /// (i archiv) ve výchozí aplikaci.
    func launchRow(_ row: Int, in panel: PanelController) {
        guard row >= 0, row < panel.rows.count, !panel.rows[row].isParent else { return }
        let item = panel.rows[row].item
        // Adresář ve vzdáleném VFS nebo archivu rozbalit nejde (extractToTemp bere soubor).
        guard !item.isDir || panel.localPath(of: item.name) != nil else {
            NSSound.beep()
            return
        }
        withLocalFile(item, in: panel) { [weak self] path in
            // Spustitelný skript bez přípony by macOS spustil v Terminalu – otevřít
            // ho v textovém editoru (skript s příponou otevře aplikace podle přípony).
            if splitExtension(item.name).ext.isEmpty, scriptInterpreter(atPath: path) != nil {
                self?.openInEditor(path)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }

    /// Zavolá akci s lokální cestou položky: na disku přímo, z archivu / FTP
    /// po rozbalení do dočasného adresáře.
    private func withLocalFile(_ item: Item, in panel: PanelController, action: @escaping (String) -> Void) {
        withLocalFile(item, vfs: panel.location.vfs, dir: panel.location.path, action: action)
    }

    /// Zavolá akci s lokální cestou položky libovolného VFS (i mimo panel –
    /// např. nalezené položky okna Hledat).
    /// - Parameters:
    ///   - item: položka
    ///   - vfs: souborový systém položky
    ///   - dir: adresář položky (VFS cesta)
    ///   - action: akce s lokální cestou
    func withLocalFile(_ item: Item, vfs: Vfs, dir: String, action: @escaping (String) -> Void) {
        if let path = vfs.realPath(joinPath(dir, item.name)) {
            action(path)
        } else {
            extractToTemp(item, vfs: vfs, dir: dir, completion: action)
        }
    }

    /// Otevře soubor jako archivní VFS, pokud to archiv je (podle obsahu).
    private func openArchive(_ path: String) -> Vfs? {
        switch probeArchive(path: path) {
        case SAL_VFS_ZIP: return Vfs.openZip(path: path)
        case SAL_VFS_TAR: return Vfs.openTar(path: path)
        default: return nil
        }
    }

    /// Zkopíruje položku z nelokálního VFS (adresář `dir`) do dočasného adresáře (s progresem).
    private func extractToTemp(_ item: Item, vfs src: Vfs, dir: String, completion: @escaping (String) -> Void) {
        let tempDir: String
        do {
            tempDir = try TempFiles.makeDirectory()
        } catch {
            showAlert(title: "Rozbalení", text: error.localizedDescription)
            return
        }
        let disk = Vfs.localDisk
        // Šifrovaná položka: heslo se zeptá předem (jen poprvé pro daný archiv).
        if item.isEncrypted, !ensurePassword(src) { return }
        func extract() {
            beginProgress(title: "Rozbaluji \(item.name)") { state in
                try coreCopy(src: src, srcDir: dir, names: [item.name], dst: disk, dstDir: tempDir,
                             overwrite: .overwrite, state: state)
            } completion: { [weak self] result in
                guard let self else { return }
                self.endProgress()
                switch result {
                case .success:
                    completion((tempDir as NSString).appendingPathComponent(item.name))
                case .failure(let error):
                    // Chybné/chybějící heslo: zeptat se znovu a opakovat.
                    if self.askPasswordAfterError(error, vfs: src) {
                        extract()
                    } else {
                        self.showErrorUnlessCancelled(title: "Rozbalení", error)
                    }
                }
            }
        }
        extract()
    }

    // MARK: - Hesla k archivům

    /// Před čtením ze zaheslovaného archivu se zeptá na heslo (pokud ještě nebylo zadáno).
    /// Vrací false, když uživatel dotaz zruší.
    func ensurePassword(_ vfs: Vfs) -> Bool {
        guard vfs.hasEncrypted, vfs.password == nil else { return true }
        return askPassword(for: vfs, wrong: false)
    }

    /// Po chybě „chybí heslo“ / „chybné heslo“ se zeptá znovu; true = opakovat operaci.
    func askPasswordAfterError(_ error: Error, vfs: Vfs) -> Bool {
        guard let error = error as? CoreError, error.isPasswordRequired || error.isBadPassword else { return false }
        return askPassword(for: vfs, wrong: error.isBadPassword)
    }

    /// Dialog s heslem k archivu (zadané heslo platí pro celý otevřený archiv).
    private func askPassword(for vfs: Vfs, wrong: Bool) -> Bool {
        let text = wrong
            ? "Heslo k archivu „\(vfs.label)“ není správné. Zadejte ho znovu:"
            : "Archiv „\(vfs.label)“ obsahuje šifrované soubory (AES nebo ZipCrypto). Zadejte heslo:"
        guard let password = askSecretText(title: wrong ? "Chybné heslo" : "Zaheslovaný archiv", text: text,
                                           style: wrong ? .warning : .informational) else { return false }
        vfs.setPassword(password)
        return true
    }

    /// Modální dotaz na heslo (skryté pole, Enter = potvrdit, Escape = zrušit).
    /// - Parameters:
    ///   - title: nadpis dialogu
    ///   - text: vysvětlující text
    ///   - okTitle: popisek potvrzovacího tlačítka
    ///   - style: styl dialogu
    /// - Returns: zadané heslo, nil = zrušeno
    func askSecretText(title: String, text: String, okTitle: String = "OK",
                       style: NSAlert.Style = .informational) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.usesSingleLineMode = true
        alert.accessoryView = input
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        focusActivePanel()
        return response == .alertFirstButtonReturn ? input.stringValue : nil
    }

    // MARK: - Příkazy

    /// Provedení příkazu (z menu, lišt, F-kláves).
    func perform(_ command: Command) {
        // Diagnostika: zapsat spuštěný příkaz a stav panelů (viz KeyLog).
        if KeyLog.enabled {
            KeyLog.note("perform \(command) aktivní=\(activePanel === leftPanel ? "levý" : "pravý") "
                        + "levý=\(leftPanel.displayPath) pravý=\(rightPanel.displayPath) sheet=\(window?.attachedSheet != nil)")
        }
        // Během otevřeného sheetu (progress, dialog) příkazy neběží.
        guard window?.attachedSheet == nil else { return }
        let panel = activePanel
        switch command {
        case .help: showHelp()
        case .rename: commandRename()
        case .view: commandView()
        case .edit: commandEdit()
        case .newFile: commandNewFile()
        case .copy: runTransfer(move: false)
        case .move: runTransfer(move: true)
        case .mkdir: commandMkdir()
        case .changeDir: view(of: panel).directoryLine.beginEditing()
        case .delete: commandDelete()
        case .terminal: commandTerminal()
        case .quit: NSApp.terminate(nil)
        case .connect: ConnectWindowController.show(parent: self)
        case .editPlaces: PlacesWindowController.show(parent: self)
        case .disconnect: panel.closeNested()
        case .sortName: panel.setSort(.name)
        case .sortExt: panel.setSort(.ext)
        case .sortTime: panel.setSort(.time)
        case .sortSize: panel.setSort(.size)
        case .refresh: panel.reload()
        case .compare: commandCompare()
        case .driveLeft: activate(leftPanel); leftView.showDriveMenu()
        case .driveRight: activate(rightPanel); rightView.showDriveMenu()
        case .pack: commandPack()
        case .unpack: commandUnpack()
        case .find: FindWindowController.show(owner: self)
        case .calcSize: commandCalcSize()
        case .back: panel.goBack()
        case .forward: panel.goForward()
        case .up: panel.goUp()
        case .root: panel.goRoot()
        case .home: openDrive(NSHomeDirectory(), in: panel)
        case .swap: swapPanels()
        case .sameDir: commandSameDir()
        case .sameDirOther: commandSameDirOther()
        case .toggleHidden: toggleHiddenFiles()
        case .changeAttributes: commandChangeAttributes()
        case .properties, .permissions: commandShowInfo()
        // Cesta tak, jak ji ukazuje řádek adresáře (u archivu/FTP i s popiskem VFS).
        case .copyDirPath: copyTextToPasteboard(activePanel.displayPath)
        case .viewMenu: showViewModeMenu()
        case .viewBrief, .viewDetailed, .viewIcons, .viewThumbnails, .viewTiles, .viewTypes:
            if let mode = command.viewMode { setViewMode(mode, for: panel) }
        case .selectMask: commandMarkByMask(select: true)
        case .unselectMask: commandMarkByMask(select: false)
        // Invertovat označení: adresáře podle stejné volby jako Označit vše (⌘A).
        case .invertMarks: panel.invertMarks(includeDirs: Settings.markingIncludesDirs)
        // ⌘A / Označit vše: opakovaně přepíná označit vše ↔ zrušit označení;
        // adresáře podle Nastavení.
        case .selectAll: panel.toggleMarkAll(includeDirs: Settings.markingIncludesDirs)
        case .unselectAll: panel.markAll(false)
        }
    }

    /// F5/F6 – kopírování/přesun do protějšího panelu (cíl lze v dialogu upravit).
    private func runTransfer(move: Bool) {
        let source = activePanel
        let target = inactivePanel
        let items = source.operationItems
        guard !items.isEmpty else { return }
        let verb = move ? "Přesun" : "Kopírování"
        if move && !source.location.vfs.writable {
            showAlert(title: verb, text: "Zdrojový souborový systém je jen pro čtení.")
            return
        }
        guard target.location.vfs.writable else {
            showAlert(title: verb, text: "Cílový souborový systém (\(target.location.vfs.label)) je jen pro čtení.")
            return
        }

        // Dialog s cílem jako v Salamanderu („Kopírovat 3 soubory do:“).
        let what = items.count == 1 ? "„\(items[0].name)“" : "\(items.count) položek"
        guard let typed = promptText(title: move ? "Přesunout" : "Kopírovat",
                                     message: "\(move ? "Přesunout" : "Kopírovat") \(what) do:",
                                     value: target.location.path, okTitle: move ? "Přesunout" : "Kopírovat") else { return }
        let dst = target.location.vfs
        let dstDir = resolveTypedPath(typed, in: target.location)
        // Neexistující cíl: nabídnout vytvoření adresáře.
        if !dst.isDir(dstDir) {
            guard confirm(title: verb, text: "Cílový adresář \(dstDir) neexistuje. Vytvořit?", okTitle: "Vytvořit") else { return }
            do {
                try createDirectories(dst, dstDir)
            } catch {
                showAlert(title: verb, text: error.localizedDescription)
                return
            }
        }

        let names = items.map(\.name)
        let src = source.location.vfs
        let srcDir = source.location.path
        // Zaheslovaný archiv: heslo předem (adresáře mohou obsahovat šifrované soubory).
        if items.contains(where: { $0.isEncrypted || $0.isDir }), !ensurePassword(src) { return }

        // Při konfliktu (Ask) se zeptá a operaci spustí znovu s režimem přepsání/přeskočení.
        func transfer(_ mode: OverwriteMode) {
            beginProgress(title: "\(verb) \(what)") { state in
                if move {
                    try coreMove(src: src, srcDir: srcDir, names: names, dst: dst, dstDir: dstDir, overwrite: mode, state: state)
                } else {
                    try coreCopy(src: src, srcDir: srcDir, names: names, dst: dst, dstDir: dstDir, overwrite: mode, state: state)
                }
            } completion: { [weak self] result in
                guard let self else { return }
                self.endProgress()
                if case .failure(let error) = result, (error as? CoreError)?.isExistsConflict == true, mode == .ask {
                    if let choice = self.askOverwrite() {
                        transfer(choice)
                    }
                    return
                }
                // Chybné/chybějící heslo k archivu: zeptat se a opakovat se stejným režimem.
                if case .failure(let error) = result, self.askPasswordAfterError(error, vfs: src) {
                    transfer(mode)
                    return
                }
                if case .failure(let error) = result {
                    self.showErrorUnlessCancelled(title: verb, error)
                } else {
                    // Po úspěchu se označení zruší (jako Salamander).
                    source.markAll(false)
                }
                source.reload()
                target.reload()
            }
        }
        transfer(.ask)
    }

    /// Vytvoří adresář včetně chybějících rodičů.
    private func createDirectories(_ vfs: Vfs, _ path: String) throws {
        var current = "/"
        for component in path.split(separator: "/") {
            current = joinPath(current, String(component))
            if !vfs.isDir(current) {
                try vfs.mkdir(current)
            }
        }
    }

    /// Dotaz na konflikt existujících cílů.
    private func askOverwrite() -> OverwriteMode? {
        let alert = NSAlert()
        alert.messageText = "Cíl už existuje"
        alert.informativeText = "Některé položky v cíli už existují. Přepsat je, přeskočit, nebo operaci zrušit?"
        alert.addButton(withTitle: "Přepsat vše")
        alert.addButton(withTitle: "Přeskočit existující")
        alert.addCancelButton()
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .skip
        default: return nil
        }
    }

    /// F7 – nový adresář v aktivním panelu (kurzor se na něj postaví).
    private func commandMkdir() {
        let panel = activePanel
        guard panel.location.vfs.writable else {
            showAlert(title: "Nový adresář", text: "Souborový systém je jen pro čtení.")
            return
        }
        guard let name = promptText(title: "Nový adresář", message: "Jméno nového adresáře:", value: "", okTitle: "Vytvořit") else { return }
        do {
            try createDirectories(panel.location.vfs, normalizePath(joinPath(panel.location.path, name)))
            panel.focus(name: name.split(separator: "/").first.map(String.init) ?? name)
            panel.reload()
        } catch {
            showAlert(title: "Nový adresář", text: error.localizedDescription)
        }
    }

    /// F8 / Delete – smazání (označené položky, jinak položka pod kurzorem).
    private func commandDelete() {
        let panel = activePanel
        let items = panel.operationItems
        guard !items.isEmpty else { return }
        guard panel.location.vfs.writable else {
            showAlert(title: "Smazat", text: "Souborový systém je jen pro čtení.")
            return
        }
        let what = items.count == 1
            ? "\(items[0].isDir ? "adresář" : "soubor") „\(items[0].name)“"
            : "\(items.count) označených položek"
        guard confirm(title: "Smazat", text: "Opravdu smazat \(what)?\nMazání je trvalé (bez koše).", okTitle: "Smazat") else { return }

        let names = items.map(\.name)
        let dir = panel.location.path
        let vfs = panel.location.vfs
        beginProgress(title: "Mazání", unit: .items) { state in
            try coreDelete(vfs: vfs, dir: dir, names: names, state: state)
        } completion: { [weak self] result in
            self?.endProgress()
            if case .failure(let error) = result {
                self?.showErrorUnlessCancelled(title: "Mazání", error)
            }
            panel.markAll(false)
            self?.leftPanel.reload()
            self?.rightPanel.reload()
        }
    }

    /// ⌥↩ / ⌘I Vlastnosti a ⌃P Oprávnění: jako v Salamanderu systémový dialog
    /// vlastností – na macOS okno Informace z Finderu (Otevřít v aplikaci,
    /// Sdílení a oprávnění, …) pro označené položky, jinak položku pod kurzorem.
    /// Otevírá se systémovou službou Finderu „Show Info“ (bez AppleScriptu a bez
    /// oprávnění k Automatizaci); je-li služba vypnutá, položky se aspoň ukážou
    /// ve Finderu.
    private func commandShowInfo() {
        let panel = activePanel
        let items = panel.operationItems
        guard !items.isEmpty else { return }
        let urls = items.compactMap { panel.localPath(of: $0.name) }.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else {
            showAlert(title: "Vlastnosti", text: "Vlastnosti lze zobrazit jen pro položky na lokálním disku.")
            return
        }
        // Každá položka = jedno okno Informace; u velkého výběru se nejdřív zeptat.
        if urls.count > 20, !confirm(title: "Vlastnosti", text: "Otevřít \(urls.count) oken Informace?", okTitle: "Otevřít") {
            return
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MicroCommander-ShowInfo"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        if !NSPerformService("Finder/Show Info", pasteboard) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            showAlert(title: "Vlastnosti",
                      text: "Služba Finderu „Zobrazit informace“ je vypnutá (Nastavení systému › Klávesnice › Klávesové zkratky › Služby). Položky jsou vybrané ve Finderu – informace zobrazíte stiskem ⌘I.",
                      style: .informational)
        }
    }

    /// ⌘F2 / ⌃F2 – změna atributů označených položek (jinak položky pod kurzorem):
    /// jen pro čtení, skrytý, časy změny/vytvoření/otevření, i rekurzivně.
    private func commandChangeAttributes() {
        let panel = activePanel
        let items = panel.operationItems
        guard !items.isEmpty, let window else { return }
        let paths = items.compactMap { panel.localPath(of: $0.name) }
        guard paths.count == items.count else {
            showAlert(title: "Změnit atributy", text: "Atributy lze měnit jen na lokálním disku.")
            return
        }
        AttributesDialog.run(on: window, items: items, firstPath: paths[0]) { [weak self] changes in
            guard let self, let changes else { return }
            self.beginProgress(title: "Změna atributů", unit: .items) { state in
                try applyAttributeChanges(changes, to: paths, state: state)
            } completion: { [weak self] result in
                guard let self else { return }
                self.endProgress()
                if case .failure(let error) = result {
                    self.showErrorUnlessCancelled(title: "Změnit atributy", error)
                }
                self.reloadPanels()
            }
        }
    }

    /// F2 / Shift+F6 – přejmenování položky pod kurzorem.
    private func commandRename() {
        let panel = activePanel
        guard let item = panel.currentItem else { return }
        guard panel.location.vfs.writable else {
            showAlert(title: "Přejmenovat", text: "Souborový systém je jen pro čtení.")
            return
        }
        // Jméno se upraví přímo v panelu (bez dialogu); nil = zrušeno / beze změny.
        let dir = panel.location.path
        let vfs = panel.location.vfs
        panel.view?.beginInlineRename { [weak self] newName in
            guard let newName else { return }
            do {
                try vfs.rename(dir: dir, oldName: item.name, newName: newName)
                panel.focus(name: newName)
                panel.reload()
            } catch let error as CoreError where error.isExistsConflict {
                // Jádro existující položku téhož jména nenahradí.
                self?.showAlert(title: "Přejmenovat", text: "Položka „\(newName)“ v tomto adresáři už existuje.")
            } catch {
                self?.showAlert(title: "Přejmenovat", text: error.localizedDescription)
            }
        }
    }

    /// F3 – interní prohlížeč (text/obrázek); z archivu/FTP přes dočasnou kopii.
    private func commandView() {
        let panel = activePanel
        guard let item = panel.currentItem, !item.isDir else { return }
        if let path = panel.localPath(of: item.name) {
            ViewerWindowController.open(path: path, title: path)
        } else {
            let title = panel.displayPath + "/" + item.name
            extractToTemp(item, vfs: panel.location.vfs, dir: panel.location.path) { localPath in
                ViewerWindowController.open(path: localPath, title: title)
            }
        }
    }

    /// F4 – otevření v textovém editoru (jen lokální soubory).
    private func commandEdit() {
        let panel = activePanel
        guard let item = panel.currentItem, !item.isDir else { return }
        guard let path = panel.localPath(of: item.name) else {
            showAlert(title: "Upravit", text: "Upravovat lze jen soubory na lokálním disku.")
            return
        }
        openInEditor(path)
    }

    /// Otevře soubor ve výchozím textovém editoru systému.
    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shift+F4 – nový soubor a jeho otevření v editoru.
    private func commandNewFile() {
        let panel = activePanel
        guard let dir = panel.location.vfs.realPath(panel.location.path) else {
            showAlert(title: "Nový soubor", text: "Nový soubor lze vytvořit jen na lokálním disku.")
            return
        }
        guard let name = promptText(title: "Nový soubor", message: "Jméno nového souboru:", value: "novy.txt",
                                    okTitle: "Vytvořit", selectBaseName: true) else { return }
        let path = (dir as NSString).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: Data()) else {
                showAlert(title: "Nový soubor", text: "Soubor \(path) nelze vytvořit.")
                return
            }
        }
        panel.focus(name: name)
        panel.reload()
        openInEditor(path)
    }

    /// F9 – Terminál v adresáři aktivního panelu.
    private func commandTerminal() {
        guard let dir = activePanel.location.vfs.realPath(activePanel.location.path) else {
            showAlert(title: "Terminál", text: "Terminál lze otevřít jen v adresáři na lokálním disku.")
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: Self.terminalApp,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Alt+F5 – zabalení položek do nového ZIP (výchozí cíl: protější panel).
    private func commandPack() {
        let panel = activePanel
        let items = panel.operationItems
        guard !items.isEmpty, let window else { return }
        let save = NSSavePanel()
        save.allowedContentTypes = [.zip]
        let baseName = items.count == 1 ? splitExtension(items[0].name).base : lastComponent(panel.location.path)
        save.nameFieldStringValue = (baseName.isEmpty || baseName == "/" ? "archiv" : baseName) + ".zip"
        if let targetDir = inactivePanel.location.vfs.realPath(inactivePanel.location.path) {
            save.directoryURL = URL(fileURLWithPath: targetDir)
        }
        // Volby šifrování (AES-256 / ZipCrypto + heslo) přímo v dialogu uložení.
        let options = PackOptionsView()
        save.accessoryView = options
        save.isExtensionHidden = false
        save.delegate = options
        // Balení ze zaheslovaného archivu potřebuje heslo ke čtení.
        let src = panel.location.vfs
        if !ensurePassword(src) { return }
        save.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = save.url, let self else { return }
            let dir = panel.location.path
            let names = items.map(\.name)
            let encryption = options.encryption
            // Sheet uložení se musí zavřít dřív, než se otevře progress sheet.
            func pack() {
                self.beginProgress(title: "Zabalování do \(url.lastPathComponent)") { state in
                    try corePackZip(src: src, srcDir: dir, names: names, dest: url.path,
                                    encryption: encryption, state: state)
                } completion: { result in
                    self.endProgress()
                    if case .failure(let error) = result, self.askPasswordAfterError(error, vfs: src) {
                        pack()
                        return
                    }
                    if case .failure(let error) = result {
                        // Nedokončený archiv po chybě/zrušení nenecháváme na disku.
                        try? FileManager.default.removeItem(at: url)
                        self.showErrorUnlessCancelled(title: "Zabalování", error)
                    } else {
                        panel.markAll(false)
                    }
                    self.leftPanel.reload()
                    self.rightPanel.reload()
                }
            }
            DispatchQueue.main.async { pack() }
        }
    }

    /// Alt+F6 – rozbalení archivu pod kurzorem do protějšího panelu.
    private func commandUnpack() {
        let panel = activePanel
        let target = inactivePanel
        guard let item = panel.currentItem, !item.isDir else { return }
        guard let path = panel.localPath(of: item.name), let archive = openArchive(path) else {
            showAlert(title: "Rozbalit", text: "„\(item.name)“ není podporovaný archiv (ZIP, TAR, TAR.GZ) na lokálním disku.")
            return
        }
        guard target.location.vfs.writable else {
            showAlert(title: "Rozbalit", text: "Cílový souborový systém je jen pro čtení.")
            return
        }
        guard let typed = promptText(title: "Rozbalit", message: "Rozbalit „\(item.name)“ do:",
                                     value: target.location.path, okTitle: "Rozbalit") else { return }
        let dst = target.location.vfs
        let dstDir = resolveTypedPath(typed, in: target.location)
        let names: [String]
        do {
            names = try archive.list("/").map(\.name)
            if !dst.isDir(dstDir) {
                try createDirectories(dst, dstDir)
            }
        } catch {
            showAlert(title: "Rozbalit", text: error.localizedDescription)
            return
        }
        // Zaheslovaný archiv: heslo předem.
        guard ensurePassword(archive) else { return }
        func unpack(_ mode: OverwriteMode) {
            beginProgress(title: "Rozbaluji \(item.name)") { state in
                try coreCopy(src: archive, srcDir: "/", names: names, dst: dst, dstDir: dstDir, overwrite: mode, state: state)
            } completion: { [weak self] result in
                guard let self else { return }
                self.endProgress()
                if case .failure(let error) = result, (error as? CoreError)?.isExistsConflict == true, mode == .ask {
                    if let choice = self.askOverwrite() { unpack(choice) }
                    return
                }
                if case .failure(let error) = result, self.askPasswordAfterError(error, vfs: archive) {
                    unpack(mode)
                    return
                }
                if case .failure(let error) = result {
                    self.showErrorUnlessCancelled(title: "Rozbalit", error)
                }
                target.reload()
            }
        }
        unpack(.ask)
    }

    /// Alt+F10 – velikost označených položek (adresáře rekurzivně přes hledání jádra).
    private func commandCalcSize() {
        let panel = activePanel
        let items = panel.operationItems
        guard !items.isEmpty else { return }
        let vfs = panel.location.vfs
        let dir = panel.location.path
        let totals = SizeTotals()
        beginProgress(title: "Počítám velikost", unit: .items) { state in
            for item in items {
                if item.isDir {
                    totals.add(dirs: 1)
                    let collector = FindCollector()
                    try coreFind(vfs: vfs, root: joinPath(dir, item.name), mask: "*", includeDirs: true,
                                 state: state, collector: collector)
                    for found in collector.snapshot() {
                        if found.item.isDir { totals.add(dirs: 1) } else { totals.add(files: 1, bytes: found.item.size) }
                    }
                } else {
                    totals.add(files: 1, bytes: item.size)
                }
            }
        } completion: { [weak self] result in
            self?.endProgress()
            if case .failure(let error) = result {
                self?.showErrorUnlessCancelled(title: "Velikost", error)
                return
            }
            let value = totals.snapshot()
            self?.showAlert(title: "Obsazené místo",
                            text: "\(formatExactSize(value.bytes)) B (\(formatSize(value.bytes)))\n\(value.files) souborů, \(value.dirs) adresářů",
                            style: .informational)
        }
    }

    /// Ctrl+F10 – porovnání adresářů: označí soubory, které chybí nebo se liší v druhém panelu.
    private func commandCompare() {
        let left = leftPanel
        let right = rightPanel
        let leftFiles = Dictionary(left.items.filter { !$0.isDir }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let rightFiles = Dictionary(right.items.filter { !$0.isDir }.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // Liší se: chybí na druhé straně, jiná velikost, nebo je novější.
        func differs(_ item: Item, _ other: Item?) -> Bool {
            guard let other else { return true }
            return item.size != other.size || item.mtime > other.mtime
        }
        let leftMarks = Set(leftFiles.values.filter { differs($0, rightFiles[$0.name]) }.map(\.name))
        let rightMarks = Set(rightFiles.values.filter { differs($0, leftFiles[$0.name]) }.map(\.name))
        left.setMarked(leftMarks)
        right.setMarked(rightMarks)
        if leftMarks.isEmpty && rightMarks.isEmpty {
            showAlert(title: "Porovnat adresáře", text: "Adresáře obsahují stejné soubory.", style: .informational)
        }
    }

    /// ⌃⇧. – převzít adresář z druhého panelu (aktivní panel přejde tam, kde je druhý).
    private func commandSameDir() {
        activePanel.adoptLocation(of: inactivePanel)
    }

    /// ⌃. / ⌘. – poslat aktuální adresář do druhého panelu (druhý panel přejde sem)
    /// (aktivní panel i jeho kurzor zůstávají).
    private func commandSameDirOther() {
        inactivePanel.adoptLocation(of: activePanel)
    }

    /// Num +/- – označení/odznačení podle masky.
    private func commandMarkByMask(select: Bool) {
        guard let mask = promptText(title: select ? "Označit" : "Odznačit",
                                    message: "Maska souborů (např. *.txt;*.md, vyloučení za |: *.*|*.bak):", value: "*.*",
                                    okTitle: select ? "Označit" : "Odznačit") else { return }
        do {
            try activePanel.markByMask(mask, select: select, includeDirs: false)
        } catch {
            // Chybná maska (např. dva oddělovače „|“).
            showAlert(title: select ? "Označit" : "Odznačit", text: error.localizedDescription)
        }
    }

    /// ⌘U – prohodí panely (levý ↔ pravý) včetně jejich obsahu.
    private func swapPanels() {
        swap(&leftPanel, &rightPanel)
        swap(&leftView, &rightView)
        panelStack.setViews([leftView, middleBar, rightView], in: .leading)
        pinEqualPanelWidths()
        saveViewModes()
        activate(activePanel)
    }

    /// Terminal macOS (F9, ⌘Enter / ⌃Enter v příkazové řádce).
    private static let terminalApp = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    /// Login shell uživatele pro příkazovou řádku.
    private static var userShell: String { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }

    /// Příkazová řádka: „cd cesta“ mění adresář panelu, jinak spustí příkaz
    /// v shellu v adresáři panelu – na pozadí s výstupem v prohlížeči, nebo
    /// v novém okně Terminalu.
    /// - Parameters:
    ///   - command: text příkazu
    ///   - inTerminal: spustit v Terminalu (⌘Enter / ⌃Enter)
    private func executeCommandLine(_ command: String, inTerminal: Bool) {
        let panel = activePanel
        if command == "cd" || command.hasPrefix("cd ") {
            let target = command.count > 3 ? String(command.dropFirst(3)) : "~"
            if panel.location.vfs.kind == SAL_VFS_LOCAL {
                panel.goToTypedPath(target.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            } else {
                panel.goToTypedPath(target)
            }
            focusActivePanel()
            return
        }
        guard let dir = panel.location.vfs.realPath(panel.location.path) else {
            showAlert(title: "Příkazová řádka", text: "Příkazy lze spouštět jen v adresáři na lokálním disku.")
            return
        }
        if inTerminal {
            runInTerminal(command, in: dir)
        } else {
            runInBackground(command, in: dir)
        }
    }

    /// Spustí příkaz v novém okně Terminalu přes dočasný skript `.command`, který
    /// Terminal sám spustí (bez oprávnění k ovládání Terminalu přes AppleScript);
    /// po doběhnutí příkazu zůstane v okně interaktivní shell.
    /// - Parameters:
    ///   - command: text příkazu
    ///   - dir: pracovní adresář
    private func runInTerminal(_ command: String, in dir: String) {
        let shell = Self.userShell
        // Skript se po spuštění sám smaže; příkaz běží v login shellu uživatele.
        let script = """
        #!\(shell) -l
        rm -f "$0"
        cd \(shellQuote(dir)) || exit 1
        \(command)
        exec \(shellQuote(shell)) -l
        """
        let path = TempFiles.newPath(suffix: ".command")
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            showAlert(title: "Příkazová řádka", text: error.localizedDescription)
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: Self.terminalApp,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Spustí příkaz na pozadí v login shellu uživatele (bez terminálu);
    /// výstup se po doběhnutí zobrazí v prohlížeči.
    /// - Parameters:
    ///   - command: text příkazu
    ///   - dir: pracovní adresář
    private func runInBackground(_ command: String, in dir: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.userShell)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            showAlert(title: "Příkazová řádka", text: error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard let self else { return }
                let output = String(decoding: data, as: UTF8.self)
                if !output.isEmpty || process.terminationStatus != 0 {
                    let text = output + "\n[návratový kód \(process.terminationStatus)]"
                    ViewerWindowController.open(text: text, title: "\(dir)> \(command)")
                }
                self.leftPanel.reload()
                self.rightPanel.reload()
            }
        }
    }

    /// F1 – přehled ovládání.
    private func showHelp() {
        let text = """
        Panely: ↑↓ PgUp PgDn Home End – pohyb, Enter – otevřít (adresář, archiv, soubor; shell skript spustit v Terminalu),
        ⌘Enter – spustit systémově (aplikace .app, soubor ve výchozí aplikaci),
        ⌫ – nadřazený adresář, Tab – druhý panel, ⌘Tab (⌃Tab) – příkazová řádka
        (v ní Enter spustí s výstupem v prohlížeči, ⌘Enter / ⌃Enter v Terminalu),
        Space / Insert / ⇧↑↓ / ⌘klik – označit, Num + / − / * – maska / invertovat,
        ⌘A – označit vše (znovu = zrušit), ⌘D – nic, psaní písmen – rychlé hledání,
        ⌥← / ⌥→ – historie, ⌘\\ – kořen, ⌃H – skryté soubory.
        ⌘. (⌃.) – poslat aktuální adresář do druhého panelu (přepne se druhý panel).
        ⌘⇧. (⌃⇧.) – převzít adresář z druhého panelu (přepne se aktivní panel).

        F2 přejmenovat, F3 zobrazit, F4 upravit, F5 kopírovat, F6 přesunout,
        F7 nový adresář, F8 smazat, F9 terminál, F10 ukončit, F11 FTP/SFTP, F12 odpojit.
        ⇧F4 nový soubor, ⇧F7 změnit adresář, ⌘F2 / ⌃F2 atributy, ⌥↩ / ⌘I vlastnosti, ⌃P oprávnění, ⌃F3–F6 řazení, ⌃F9 obnovit, ⌃F10 porovnat,
        ⌥F1/⌥F2 disk vlevo/vpravo (v nabídce ⌥↑/⌥↓ mění pořadí disků), ⌥F5 zabalit, ⌥F6 rozbalit, ⌥F7 hledat, ⌥F10 velikost.

        Tip: na klávesnici Macu F-klávesy vyžadují Fn, nebo zapněte
        „Používat F1, F2 atd. jako standardní funkční klávesy“ v nastavení klávesnice.
        """
        showAlert(title: "MicroCommander – ovládání", text: text, style: .informational)
    }

    /// Uloží obsah okna jako PNG (vývojářský snímek, viz SAL_SNAPSHOT).
    func saveSnapshot(to path: String) {
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Menu

    /// Příkazy dostupné z hlavního menu (tag položky = index).
    static let menuCommands = Command.allCases

    static func menuCommandIndex(_ command: Command) -> Int {
        menuCommands.firstIndex(of: command) ?? 0
    }

    @objc func menuCommand(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < MainWindowController.menuCommands.count else { return }
        perform(MainWindowController.menuCommands[sender.tag])
    }

    /// Položky menu jsou neaktivní, dokud je otevřený sheet (progress, dialog);
    /// zaškrtnutí ukazuje aktuální režim zobrazení a skryté soubory.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Zkratku potřebnou pro psaní (⌃písmeno, ⌘C…) nechá menu textovému poli –
        // stejné pravidlo jako monitor kláves (KeyBindings.isTextEditingKey).
        if let event = NSApp.currentEvent, event.type == .keyDown, event.window === window,
           !isPanelResponder(window?.firstResponder), KeyBindings.isTextEditingKey(event) {
            return false
        }
        if menuItem.action == #selector(menuCommand(_:)),
           menuItem.tag >= 0, menuItem.tag < MainWindowController.menuCommands.count {
            let command = MainWindowController.menuCommands[menuItem.tag]
            if command == .toggleHidden {
                menuItem.state = showHiddenFiles ? .on : .off
            } else if let mode = command.viewMode {
                menuItem.state = mode == view(of: activePanel).viewMode ? .on : .off
            }
            return window?.attachedSheet == nil
        }
        return true
    }

    /// Menu režimů zobrazení u kurzoru myši (tlačítko na liště).
    private func showViewModeMenu() {
        guard let contentView = window?.contentView, let window else { return }
        let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        viewModeMenu().popUp(positioning: nil, at: point, in: contentView)
    }

    // MARK: - Dialogy operací

    /// Otevře progress dialog a spustí operaci na pozadí.
    /// - Parameters:
    ///   - title: titulek dialogu
    ///   - unit: v čem operace hlásí průběh (bajty přenosu / zpracované položky)
    ///   - dismissOnCancel: Zrušit dialog hned zavře a výsledek operace
    ///     (doběhne na pozadí) se zahodí – pro operace, které zrušit nejdou (připojení)
    ///   - operation: operace na pozadí (dostane stav pro průběh a zrušení)
    ///   - completion: výsledek operace na hlavním vlákně
    func beginProgress(title: String, unit: ProgressUnit = .bytes, dismissOnCancel: Bool = false,
                       operation: @escaping (ProgressState) throws -> Void,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        let dialog = ProgressDialog(title: title, unit: unit, parentWindow: window)
        progressDialog = dialog
        dialog.begin()
        let state = dialog.state
        if dismissOnCancel {
            dialog.onCancel = { [weak self] in self?.endProgress() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try operation(state) }
            DispatchQueue.main.async {
                if dismissOnCancel && state.isCancelled { return }
                completion(result)
            }
        }
    }

    /// Zavře progress dialog a vrátí fokus do panelu.
    func endProgress() {
        progressDialog?.close()
        progressDialog = nil
        focusActivePanel()
    }

    /// Chybové hlášení; zrušení uživatelem se nehlásí.
    private func showErrorUnlessCancelled(title: String, _ error: Error) {
        if let error = error as? CoreError, error.isCancelledLike { return }
        showAlert(title: title, text: error.localizedDescription)
    }

    /// Zobrazí kontroler jako sheet nad hlavním oknem. Kontroler se drží
    /// v `sheetController` po celou dobu sheetu (jinak tlačítka nereagují),
    /// po zavření se vrátí fokus do panelu.
    func presentSheet(_ controller: NSWindowController) {
        sheetController = controller
        window!.beginSheet(controller.window!) { [weak self] _ in
            self?.sheetController = nil
            self?.focusActivePanel()
        }
    }

    /// Zobrazí hlášení (modálně).
    func showAlert(title: String, text: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
        focusActivePanel()
    }

    /// Potvrzovací dotaz (Enter = potvrdit, Escape = zrušit).
    private func confirm(title: String, text: String, okTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        let result = alert.runModal() == .alertFirstButtonReturn
        focusActivePanel()
        return result
    }

    /// Textový vstupní dialog; nil = zrušeno. selectBaseName označí jméno bez přípony.
    func promptText(title: String, message: String, value: String, okTitle: String = "OK",
                    selectBaseName: Bool = false) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        // Jednořádkové pole: dlouhá cesta se posouvá, nezalamuje se (jinak by se
        // druhý řádek useknul).
        input.usesSingleLineMode = true
        input.cell?.wraps = false
        input.cell?.isScrollable = true
        input.lineBreakMode = .byClipping
        input.stringValue = value
        alert.accessoryView = input
        alert.addButton(withTitle: okTitle)
        alert.addCancelButton()
        alert.window.initialFirstResponder = input
        // Výběr textu až po zobrazení (field editor vzniká při aktivaci pole).
        DispatchQueue.main.async {
            guard let editor = input.currentEditor() else { return }
            MicroCommander.selectBaseName(of: value, in: editor, wholeName: !selectBaseName)
        }
        let response = alert.runModal()
        focusActivePanel()
        guard response == .alertFirstButtonReturn else { return nil }
        let result = input.stringValue.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}

/// Dočasné soubory aplikace: kopie položek rozbalených z archivů a serverů
/// (F3, Enter, ⌘Enter) a skripty pro Terminal. Kopie vzniklé za běhu se
/// smažou při ukončení aplikace; co zbylo po pádu, uklidí další spuštění.
enum TempFiles {
    /// Společný začátek jmen (podle něj se pozná, co uklízet).
    private static let prefix = "microcommander-"
    /// Zbytky starší než tento čas se při spuštění smažou (mladší mohou
    /// patřit jiné běžící instanci).
    private static let staleAfter: TimeInterval = 24 * 3600
    /// Adresáře vytvořené za tohoto běhu (jen z hlavního vlákna).
    private static var created: [String] = []

    /// Nová jedinečná cesta v dočasném adresáři systému (nic nevytváří).
    static func newPath(suffix: String = "") -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(prefix + UUID().uuidString + suffix)
    }

    /// Vytvoří nový dočasný adresář (při ukončení aplikace se smaže).
    static func makeDirectory() throws -> String {
        let path = newPath()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        created.append(path)
        return path
    }

    /// Smaže adresáře vytvořené za tohoto běhu (ukončení aplikace).
    static func removeCreated() {
        created.forEach { try? FileManager.default.removeItem(atPath: $0) }
        created.removeAll()
    }

    /// Smaže staré zbytky po dřívějších bězích (pád, vynucené ukončení).
    static func removeStale() {
        let directory = NSTemporaryDirectory()
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix(prefix) {
            let path = (directory as NSString).appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let modified, Date().timeIntervalSince(modified) > staleAfter {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }
}

/// Součty pro výpočet velikosti (plněné z pracovního vlákna).
final class SizeTotals {
    private let lock = NSLock()
    private var files = 0
    private var dirs = 0
    private var bytes: UInt64 = 0

    func add(files: Int = 0, dirs: Int = 0, bytes: UInt64 = 0) {
        lock.lock()
        self.files += files
        self.dirs += dirs
        self.bytes += bytes
        lock.unlock()
    }

    func snapshot() -> (files: Int, dirs: Int, bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (files, dirs, bytes)
    }
}

/// Uzavře jméno do uvozovek pro shell, pokud obsahuje mezery či zvláštní znaky.
func shellQuote(_ text: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/+@%:,"))
    if text.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return text
    }
    return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Kódy kláves macOS (virtual key codes).
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let enter: UInt16 = 76
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let backspace: UInt16 = 51
    static let escape: UInt16 = 53
    static let forwardDelete: UInt16 = 117
    static let insert: UInt16 = 114
    static let home: UInt16 = 115
    static let end: UInt16 = 119
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let keypadPlus: UInt16 = 69
    static let keypadMinus: UInt16 = 78
    static let keypadMultiply: UInt16 = 67
    /// Klávesa tečky (stejná fyzická klávesa ve všech rozloženích).
    static let period: UInt16 = 47
    /// Číslice 1–9 na hlavní klávesnici (pro ⌥1–⌥6 režimy zobrazení).
    static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// Číslice 0 na hlavní klávesnici.
    static let digitZero: UInt16 = 29

    /// Číslice 0–9 podle stisknuté klávesy: horní řada podle kódu klávesy (česká
    /// klávesnice dává bez Shiftu +ěšč…), jinak podle znaku (numerická klávesnice,
    /// jiná rozložení); nil = jiná klávesa.
    static func digitValue(_ event: NSEvent) -> Int? {
        if event.keyCode == digitZero { return 0 }
        if let index = digits.firstIndex(of: event.keyCode) { return index + 1 }
        if let value = event.charactersIgnoringModifiers?.first?.wholeNumberValue, (0...9).contains(value) {
            return value
        }
        return nil
    }

    /// Číslice 0–9 stisknutá jen s ⌘; nil = jiná klávesa nebo jiné modifikátory.
    static func commandDigit(_ event: NSEvent) -> Int? {
        guard event.modifierFlags.intersection([.shift, .control, .option, .command]) == .command else { return nil }
        return digitValue(event)
    }
    /// F1–F12 v pořadí.
    static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    /// Znak F-klávesy (NSF1FunctionKey + n − 1) – keyEquivalent menu i syntetické události.
    static func functionKeyString(_ number: Int) -> String {
        String(UnicodeScalar(NSF1FunctionKey + number - 1)!)
    }
}

/// Diagnostický záznam stisknutých kláves do ~/Library/Logs/MicroCommander/keys.log.
/// Slouží k odhalení, co posílá konkrétní klávesnice (kód klávesy, znak, modifikátory).
enum KeyLog {
    /// Zapnuto volbou `keyLog` v uživatelských předvolbách aplikace.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "keyLog") }

    /// Cesta k souboru se záznamem.
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/MicroCommander/keys.log")
    }

    /// Formát času záznamu (vytváření formatteru je drahé – jednou).
    private static let timestamp = ISO8601DateFormatter()

    /// Připíše libovolnou poznámku (např. spuštěný příkaz).
    static func note(_ text: String) {
        append(timestamp.string(from: Date()) + " " + text + "\n")
    }

    /// Připíše jeden řádek: čas, kód klávesy, znaky (hex), modifikátory, kdo má fokus.
    static func write(_ event: NSEvent, responder: NSResponder?) {
        let scalars = (event.charactersIgnoringModifiers ?? "").unicodeScalars.map { String(format: "U+%04X", $0.value) }
        let responderName = responder.map { String(describing: type(of: $0)) } ?? "-"
        let line = String(format: "%@ keyCode=%d chars=%@ flags=0x%lx responder=%@\n",
                          timestamp.string(from: Date()), Int(event.keyCode),
                          scalars.joined(separator: ","), event.modifierFlags.rawValue, responderName)
        append(line)
    }

    /// Připsání textu na konec souboru se záznamem.
    private static func append(_ line: String) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // Připsání na konec souboru (vytvoří ho, pokud neexistuje).
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

/// Interprety, jejichž skripty Enter v panelu spouští v Terminalu.
private let shellInterpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

/// Interpret spustitelného skriptu podle shebangu (`#!/bin/bash` → „bash“,
/// `#!/usr/bin/env python3` → „python3“); nil = soubor není spustitelný nebo
/// nezačíná `#!`. Přípona nerozhoduje.
/// - Parameter path: lokální cesta souboru
func scriptInterpreter(atPath path: String) -> String? {
    guard FileManager.default.isExecutableFile(atPath: path),
          let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    // Stačí první řádek (shebang) – čte se nejvýš 256 bajtů.
    guard let head = try? handle.read(upToCount: 256), head.starts(with: Array("#!".utf8)),
          let line = String(data: head.dropFirst(2).prefix { $0 != 0x0A }, encoding: .utf8) else { return nil }
    // Interpret = první slovo; u „env“ první slovo, které není přepínač (env -S …).
    let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let first = words.first else { return nil }
    let name = lastComponent(first) == "env"
        ? words.dropFirst().first { !$0.hasPrefix("-") && !$0.contains("=") }
        : first
    return name.map(lastComponent)
}

/// Je soubor spustitelný shell skript (shebang sh/bash/zsh/dash/ksh)?
/// - Parameter path: lokální cesta souboru
func isShellScript(atPath path: String) -> Bool {
    scriptInterpreter(atPath: path).map(shellInterpreters.contains) ?? false
}

/// Zapíše text do systémové schránky (nahradí její obsah).
func copyTextToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension NSAlert {
    /// Přidá tlačítko „Zrušit“ s Escapem (NSAlert ho sám přiřadí jen tlačítku
    /// s anglickým titulkem „Cancel“).
    func addCancelButton() {
        addButton(withTitle: "Zrušit").keyEquivalent = "\u{1b}"
    }
}
