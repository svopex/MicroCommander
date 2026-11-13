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

    /// Jméno automatického ukládání polohy okna (používá i převod nastavení v main.swift).
    static let frameAutosaveName = "MicroCommanderMain"

    /// Neaktivní (cílový) panel.
    var inactivePanel: PanelController { activePanel === leftPanel ? rightPanel : leftPanel }

    init() {
        // Oba panely nad celým lokálním diskem – cesty ve VFS jsou reálné cesty.
        let disk = Vfs.openLocal(root: nil)!
        leftPanel = PanelController(location: Location(vfs: disk, path: NSHomeDirectory()))
        rightPanel = PanelController(location: Location(vfs: disk, path: "/"))
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
            (.find, "magnifyingglass", "Hledat (⌥F7)"),
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
        // Oba panely stejně široké.
        leftView.widthAnchor.constraint(equalTo: rightView.widthAnchor).isActive = true

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
        for (panel, view) in [(leftPanel, leftView), (rightPanel, rightView)] {
            panel.delegate = self
            view.inputHandler = self
        }
        topBar.onCommand = { [weak self] in self?.perform($0) }
        middleBar.onCommand = { [weak self] in self?.perform($0) }
        functionBar.onCommand = { [weak self] in self?.perform($0) }
        driveBar.onDrive = { [weak self] drive in self?.openDrive(drive.path, in: self?.activePanel) }
        driveBar.onConnect = { [weak self] in self?.perform(.connect) }
        commandLine.onExecute = { [weak self] in self?.executeCommandLine($0) }
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
            // Zkratky s tečkou dřív než menu: AppKit by ⌃⇧. přiřadil položce ⌃.
            // (Shift ignoruje) a akce by se prohodily.
            if let command = self.periodShortcutCommand(event) {
                self.perform(command)
                return nil
            }
            // F1–F12 fungují odkudkoli z hlavního okna (i z příkazové řádky).
            if let command = self.functionKeyCommand(event) {
                self.perform(command)
                return nil
            }
            // Ctrl+Tab: přepínání mezi panelem a příkazovou řádkou.
            if event.keyCode == KeyCode.tab, event.modifierFlags.contains(.control) {
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
    }

    /// Má fokus příkazová řádka (její field editor)?
    private var commandLineHasFocus: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate as? NSTextField === commandLine.field
    }

    /// Zkratky na klávese tečky podle kódu klávesy (rozložení i znak nerozhodují):
    /// ⌃. / ⌘. poslat aktuální adresář do druhého panelu, ⌃⇧. / ⌘⇧. převzít adresář
    /// z druhého panelu. nil = není to zkratka s tečkou.
    func periodShortcutCommand(_ event: NSEvent) -> Command? {
        guard event.keyCode == KeyCode.period else { return nil }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch flags {
        case [.control], [.command]: return .sameDirOther
        case [.control, .shift], [.command, .shift]: return .sameDir
        default: return nil
        }
    }

    /// Převod F-klávesy + modifikátorů na příkaz podle lišty F-kláves.
    private func functionKeyCommand(_ event: NSEvent) -> Command? {
        guard let index = KeyCode.functionKeys.firstIndex(of: event.keyCode) else { return nil }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let layer: FunctionKeyBar.Layer
        if flags.isEmpty {
            layer = .plain
        } else if flags == .shift {
            layer = .shift
        } else if flags == .control || flags == .command {
            layer = .control
        } else if flags == .option {
            layer = .option
        } else {
            return nil
        }
        return FunctionKeyBar.layers[layer]?[index].1
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

        // ⌥1–⌥6: režim zobrazení aktivního panelu (jako Alt+1..6 v Salamanderu).
        if flags == .option, let digit = KeyCode.digits.firstIndex(of: event.keyCode),
           let mode = ViewMode(rawValue: digit + 1) {
            setViewMode(mode, for: panel)
            return true
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
            if ctrlOrCmd, let item = panel.currentItem {
                // ⌘↩ / Ctrl+Enter: jméno položky do příkazové řádky.
                commandLine.insert(shellQuote(item.name))
                return true
            }
            if flags.contains(.option) { perform(.calcSize); return true }
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
        case KeyCode.keypadPlus:
            perform(ctrlOrCmd ? .selectAll : .selectMask)
            return true
        case KeyCode.keypadMinus:
            perform(ctrlOrCmd ? .unselectAll : .unselectMask)
            return true
        case KeyCode.keypadMultiply:
            perform(.invertMarks)
            return true
        default:
            break
        }

        // Klávesa tečky podle kódu (47), ne znaku: na české klávesnici dává ⇧. dvojtečku.
        // Záložní cesta (normálně to vyřídí monitor kláves): stejné přiřazení
        // jako periodShortcutCommand.
        if let command = periodShortcutCommand(event) {
            perform(command)
            return true
        }

        // Zkratky s Ctrl/⌘ a písmenem (Ctrl varianty Salamandera).
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if ctrlOrCmd && !flags.contains(.option) {
            switch chars {
            case "d": perform(.unselectAll); return true
            case "r": perform(.refresh); return true
            case "u": perform(.swap); return true
            case "g": perform(.changeDir); return true
            case "\\": perform(.root); return true
            case "=", "+": perform(.selectMask); return true
            case "-": perform(.unselectMask); return true
            case "*": perform(.invertMarks); return true
            case ".":
                // (Záložní cesta podle znaku – stejné přiřazení jako u kódu klávesy výše.)
                if flags.contains(.shift) {
                    perform(.sameDir)
                } else {
                    perform(.sameDirOther)
                }
                return true
            case "h" where flags.contains(.control): perform(.toggleHidden); return true
            case "q" where flags.contains(.control): perform(.calcSize); return true
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
            let item = NSMenuItem(title: mode.title, action: #selector(viewModeSelected(_:)), keyEquivalent: "\(mode.rawValue)")
            item.keyEquivalentModifierMask = [.option]
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
        let entries: [(String, Command)?] = [
            ("Zobrazit (F3)", .view), ("Upravit (F4)", .edit), nil,
            ("Kopírovat (F5)", .copy), ("Přesunout (F6)", .move), ("Přejmenovat (F2)", .rename), ("Smazat (F8)", .delete), nil,
            ("Zabalit do ZIP (⌥F5)", .pack), ("Rozbalit (⌥F6)", .unpack), ("Spočítat velikost (⌥F10)", .calcSize),
        ]
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.0, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.tag = MainWindowController.menuCommandIndex(entry.1)
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
        case drive(path: String)
        case server(ServerProfile)
        case manageServers
    }

    /// Položky nabídky disků: kořen, domov, svazky (v uloženém pořadí), uložené
    /// FTP/SFTP servery a na konci správa serverů. Sdílí nabídka i self-test.
    static func driveChooserItems() -> [(entry: DriveChooser.Entry, choice: DriveChoice)] {
        // Cestu ukážeme jen tam, kde se liší od názvu (kořen „/“ by byl dvakrát).
        var items = DriveBar.listDrives().map {
            (entry: DriveChooser.Entry(title: $0.title, detail: $0.title == $0.path ? "" : $0.path, icon: $0.icon),
             choice: DriveChoice.drive(path: $0.path))
        }
        let serverIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        items += ServerStore.load().map {
            (entry: DriveChooser.Entry(title: $0.displayName, detail: $0.urlString, icon: serverIcon),
             choice: DriveChoice.server($0))
        }
        items.append((entry: DriveChooser.Entry(title: "FTP/SFTP servery…", detail: "",
                                                icon: NSImage(systemSymbolName: "network", accessibilityDescription: nil)),
                      choice: .manageServers))
        return items
    }

    /// Nabídka disků pro panel (⌥F1/⌥F2, tlačítko disku). Výchozí řádek = disk,
    /// na kterém panel právě je; přesouvat (⌥↑/⌥↓) lze jen disky.
    func panelViewShowDriveChooser(_ view: PanelView, anchor: NSView) {
        let panel = view.panel
        let drives = DriveBar.listDrives()
        // Položky se při přesunu v nabídce prohazují – výběr pak odpovídá novému pořadí.
        var items = MainWindowController.driveChooserItems()
        let chooser = DriveChooser.show(entries: items.map(\.entry), selected: currentDriveIndex(drives, panel: panel),
                                        below: anchor) { [weak self] index in
            guard let self else { return }
            self.activate(panel)
            switch items[index].choice {
            case .drive(let path): self.openDrive(path, in: panel)
            case .server(let server): self.connect(server: server, in: panel)
            case .manageServers: ConnectWindowController.show(parent: self, panel: panel)
            }
        }
        chooser.movableCount = drives.count
        chooser.onMove = { from, to in
            items.swapAt(from, to)
            DriveBar.saveOrder(items.prefix(drives.count).compactMap {
                if case .drive(let path) = $0.choice { return path } else { return nil }
            })
        }
    }

    /// Index disku, pod který patří aktuální cesta panelu (nejdelší shodný prefix).
    private func currentDriveIndex(_ drives: [DriveBar.Drive], panel: PanelController) -> Int {
        guard let path = panel.location.vfs.realPath(panel.location.path) else { return 0 }
        var best = 0
        var bestLength = -1
        for (index, drive) in drives.enumerated() {
            let prefix = drive.path == "/" ? "/" : drive.path + "/"
            if (path == drive.path || path.hasPrefix(prefix)) && drive.path.count > bestLength {
                best = index
                bestLength = drive.path.count
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Otevře lokální svazek v panelu (na lokálním disku jen změní cestu).
    private func openDrive(_ path: String, in panel: PanelController?) {
        guard let panel else { return }
        if panel.location.vfs.kind == SAL_VFS_LOCAL && panel.location.vfs.label == "/" {
            panel.closeNested()
            panel.changePath(path)
        } else if let disk = Vfs.openLocal(root: nil) {
            panel.navigate(Location(vfs: disk, path: path))
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
        // Soubor na lokálním disku: archiv do panelu, jinak výchozí aplikace.
        if let path = panel.localPath(of: item.name) {
            if let archive = openArchive(path) {
                panel.navigate(Location(vfs: archive, path: "/"), nested: true, focus: item.name)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            return
        }
        // Soubor v archivu / na FTP: rozbalit do dočasného adresáře a otevřít.
        extractToTemp(item, from: panel) { [weak self] localPath in
            guard let self else { return }
            if let archive = self.openArchive(localPath) {
                panel.navigate(Location(vfs: archive, path: "/"), nested: true, focus: item.name)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
            }
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

    /// Zkopíruje položku z nelokálního VFS do dočasného adresáře (s progresem).
    private func extractToTemp(_ item: Item, from panel: PanelController, completion: @escaping (String) -> Void) {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("microcommander-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        } catch {
            showAlert(title: "Rozbalení", text: error.localizedDescription)
            return
        }
        guard let disk = Vfs.openLocal(root: nil) else { return }
        let src = panel.location.vfs
        let dir = panel.location.path
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
        case .find: FindWindowController.show(parent: self)
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
        case .viewMenu: showViewModeMenu()
        case .viewBrief, .viewDetailed, .viewIcons, .viewThumbnails, .viewTiles, .viewTypes:
            if let mode = command.viewMode { setViewMode(mode, for: panel) }
        case .selectMask: commandMarkByMask(select: true)
        case .unselectMask: commandMarkByMask(select: false)
        case .invertMarks: panel.invertMarks(includeDirs: false)
        case .selectAll: panel.markAll(true)
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
        var dstDir = typed.hasPrefix("/") ? normalizePath(typed) : normalizePath(joinPath(target.location.path, typed))
        if dst.kind == SAL_VFS_LOCAL, typed.hasPrefix("~") {
            dstDir = (typed as NSString).expandingTildeInPath
        }
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
        beginProgress(title: "Mazání") { state in
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

    /// F2 / Shift+F6 – přejmenování položky pod kurzorem.
    private func commandRename() {
        let panel = activePanel
        guard let item = panel.currentItem else { return }
        guard panel.location.vfs.writable else {
            showAlert(title: "Přejmenovat", text: "Souborový systém je jen pro čtení.")
            return
        }
        guard let newName = promptText(title: "Přejmenovat", message: "Nové jméno pro „\(item.name)“:",
                                       value: item.name, okTitle: "Přejmenovat", selectBaseName: !item.isDir),
              newName != item.name else { return }
        do {
            try panel.location.vfs.rename(dir: panel.location.path, oldName: item.name, newName: newName)
            panel.focus(name: newName)
            panel.reload()
        } catch {
            showAlert(title: "Přejmenovat", text: error.localizedDescription)
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
            extractToTemp(item, from: panel) { localPath in
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
    private func openInEditor(_ path: String) {
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
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([URL(fileURLWithPath: dir)], withApplicationAt: terminal,
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
        let dstDir = typed.hasPrefix("/") ? normalizePath(typed) : normalizePath(joinPath(target.location.path, typed))
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
        beginProgress(title: "Počítám velikost") { state in
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
                                    message: "Maska souborů (např. *.txt;*.md):", value: "*.*",
                                    okTitle: select ? "Označit" : "Odznačit") else { return }
        activePanel.markByMask(mask, select: select, includeDirs: false)
    }

    /// ⌘U – prohodí panely (levý ↔ pravý) včetně jejich obsahu.
    private func swapPanels() {
        swap(&leftPanel, &rightPanel)
        swap(&leftView, &rightView)
        panelStack.setViews([leftView, middleBar, rightView], in: .leading)
        leftView.widthAnchor.constraint(equalTo: rightView.widthAnchor).isActive = true
        saveViewModes()
        activate(activePanel)
    }

    /// Příkazová řádka: „cd cesta“ mění adresář, jinak spustí příkaz v shellu.
    private func executeCommandLine(_ command: String) {
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
        // Spuštění v login shellu uživatele; výstup se zobrazí v prohlížeči.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
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
        Panely: ↑↓ PgUp PgDn Home End – pohyb, Enter – otevřít (adresář, archiv, soubor),
        ⌫ – nadřazený adresář, Tab – druhý panel, ⌃Tab – příkazová řádka,
        Space / Insert / ⇧↑↓ / ⌘klik – označit, Num + / − / * – maska / invertovat,
        ⌘A / ⌘D – označit vše / nic, psaní písmen – rychlé hledání,
        ⌥← / ⌥→ – historie, ⌘\\ – kořen, ⌃H – skryté soubory.
        ⌘. (⌃.) – poslat aktuální adresář do druhého panelu (přepne se druhý panel).
        ⌘⇧. (⌃⇧.) – převzít adresář z druhého panelu (přepne se aktivní panel).

        F2 přejmenovat, F3 zobrazit, F4 upravit, F5 kopírovat, F6 přesunout,
        F7 nový adresář, F8 smazat, F9 terminál, F10 ukončit, F11 FTP/SFTP, F12 odpojit.
        ⇧F4 nový soubor, ⇧F7 změnit adresář, ⌃F3–F6 řazení, ⌃F9 obnovit, ⌃F10 porovnat,
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
    /// - Parameter dismissOnCancel: Zrušit dialog hned zavře a výsledek operace
    ///   (doběhne na pozadí) se zahodí – pro operace, které zrušit nejdou (připojení).
    func beginProgress(title: String, dismissOnCancel: Bool = false,
                       operation: @escaping (ProgressState) throws -> Void,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        let dialog = ProgressDialog(title: title, parentWindow: window)
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
            let base = selectBaseName ? splitExtension(value).base : value
            editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
        let response = alert.runModal()
        focusActivePanel()
        guard response == .alertFirstButtonReturn else { return nil }
        let result = input.stringValue.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
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

extension NSAlert {
    /// Přidá tlačítko „Zrušit“ s Escapem (NSAlert ho sám přiřadí jen tlačítku
    /// s anglickým titulkem „Cancel“).
    func addCancelButton() {
        addButton(withTitle: "Zrušit").keyEquivalent = "\u{1b}"
    }
}
