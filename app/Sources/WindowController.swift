// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Hlavní okno ve stylu Salamandera: horní nástrojová lišta, lišta disků,
// dva panely s prostřední lištou, řádek vestavěného terminálu (⌘F12 ho
// roztáhne na celé okno) a lišta F-kláves. Obsahuje veškeré příkazy (F2–F12,
// Ctrl/Alt varianty) a směrování kláves. Oken může být víc (⌘N), každé má
// vlastní panely i terminál.

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
    /// Vestavěný terminál: jeden řádek pod panely, nebo celé okno (⌘F12).
    let terminalPane = TerminalPane()
    let functionBar = FunctionKeyBar()
    /// Lišta disků a panely – při terminálu roztaženém na celé okno jsou skryté.
    private let panelArea = NSView()
    /// Vazby rozložení pro řádek terminálu pod panely a pro terminál přes celé okno.
    private var lineLayout: [NSLayoutConstraint] = []
    private var fullLayout: [NSLayoutConstraint] = []
    /// Fokus byl v terminálu už před jeho roztažením (po návratu tam zůstane).
    private var terminalHadFocusBeforeFull = false

    /// Progress dialog (pokud běží operace).
    private var progressDialog: ProgressDialog?
    /// Otevřený sheet (FTP, hledání) – drží kontroler naživu po dobu zobrazení.
    var sheetController: NSWindowController?
    /// Monitory klávesnice (F-klávesy, Tab, modifikátory pro lištu F-kláves).
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    /// Pozorovatelé oznámení (aktivace aplikace, nastavení); odhlásí se při
    /// zavření okna.
    private var appObservers: [NSObjectProtocol] = []

    /// Jméno automatického ukládání polohy okna.
    private static let frameAutosaveName = "MicroCommanderMain"
    /// Vazba „oba panely stejně široké“ (po prohození panelů se nahrazuje novou).
    private var equalWidthConstraint: NSLayoutConstraint?

    /// Neaktivní (cílový) panel.
    var inactivePanel: PanelController { activePanel === leftPanel ? rightPanel : leftPanel }

    /// Vytvoří hlavní okno.
    /// - Parameter source: okno, ze kterého se otevírá nové (⌘N) – nové okno
    ///   převezme adresáře jeho panelů a postaví se šikmo pod něj; nil = první
    ///   okno aplikace (uložené adresáře a poloha)
    init(openedFrom source: MainWindowController? = nil) {
        // Oba panely nad celým lokálním diskem – cesty ve VFS jsou reálné cesty.
        // Výchozí adresáře: jako ve zdrojovém okně, jinak naposledy otevřené
        // (pokud ještě existují), jinak domov a „/“.
        let disk = Vfs.localDisk
        let leftPath = source?.leftPanel.nearestLocalPath ?? Self.savedDirectory("leftPanelPath") ?? NSHomeDirectory()
        let rightPath = source?.rightPanel.nearestLocalPath ?? Self.savedDirectory("rightPanelPath") ?? "/"
        leftPanel = PanelController(location: Location(vfs: disk, path: leftPath))
        rightPanel = PanelController(location: Location(vfs: disk, path: rightPath))
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
            (.terminal, "terminal", "Terminal.app v adresáři (F9)"),
            nil,
            (.terminalNewTab, "plus.rectangle.on.rectangle", "Nová záložka terminálu (⌘T)"),
            (.newWindow, "macwindow.badge.plus", "Nové okno (⌘N)"),
        ], vertical: false)

        middleBar = CommandBar(entries: [
            (.copy, "doc.on.doc", "Kopírovat (F5)"),
            (.move, "arrow.right.doc.on.clipboard", "Přesunout (F6)"),
            (.mkdir, "folder.badge.plus", "Nový adresář (F7)"),
            (.delete, "trash", "Smazat do koše (F8, ⇧F8 trvale)"),
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
        if let sourceWindow = source?.window {
            // Další okno: stejně velké, posunuté tak, aby byly vidět oba titulky.
            window.setFrame(sourceWindow.frame, display: false)
            let topLeft = NSPoint(x: sourceWindow.frame.minX, y: sourceWindow.frame.maxY)
            window.setFrameTopLeftPoint(sourceWindow.cascadeTopLeft(from: topLeft))
        } else {
            // Polohu si pamatuje jen první okno (jméno ukládání může mít jediné okno).
            window.setFrameAutosaveName(MainWindowController.frameAutosaveName)
            if !window.setFrameUsingName(MainWindowController.frameAutosaveName) {
                window.center()
            }
        }

        buildLayout()
        wireCallbacks()
        installKeyMonitors()
        restoreSettings(from: source)

        leftPanel.reload()
        rightPanel.reload()
        activate(leftPanel)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    deinit {
        removeMonitorsAndObservers()
    }

    /// Odhlásí monitory kláves a pozorovatele oznámení (zavření okna, zánik
    /// kontroleru; opakované volání nevadí).
    private func removeMonitorsAndObservers() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        appObservers = []
    }

    // MARK: - Životní cyklus okna

    /// Okno, které je právě hlavní, dostává příkazy z menu.
    func windowDidBecomeMain(_ notification: Notification) {
        AppDelegate.shared?.activeController = self
    }

    /// Zavření okna: uloží adresáře panelů, ukončí shell terminálu a odhlásí
    /// monitory kláves a pozorovatele (kontroler pak může zaniknout).
    func windowWillClose(_ notification: Notification) {
        savePanelPaths()
        terminalPane.shutdown()
        removeMonitorsAndObservers()
        AppDelegate.shared?.windowClosed(self)
    }

    // MARK: - Rozvržení

    /// Svislé skládání: lišta, plocha panelů (disky, panely + prostřední lišta),
    /// řádek terminálu a F-klávesy. Terminál má dvě rozložení: jeden řádek pod
    /// panely, nebo celou plochu pod nástrojovou lištou (panely jsou pak skryté).
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
        // Vloží pohled přes celou šířku nadřazeného pohledu.
        func addFullWidth(_ view: NSView, to parent: NSView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ])
        }
        // Řetěz shora dolů přes celou šířku nadřazeného pohledu.
        func stack(_ views: [NSView], in parent: NSView) {
            var previous = parent.topAnchor
            for view in views {
                addFullWidth(view, to: parent)
                view.topAnchor.constraint(equalTo: previous).isActive = true
                previous = view.bottomAnchor
            }
        }
        // Plocha panelů: lišta disků, panely a oddělovač nad řádkem terminálu.
        stack([driveBar, separators[1], panelStack, separators[2]], in: panelArea)
        separators[2].bottomAnchor.constraint(equalTo: panelArea.bottomAnchor).isActive = true
        stack([topBar, separators[0], panelArea], in: container)

        addFullWidth(terminalPane, to: container)
        addFullWidth(functionBar, to: container)
        // Plocha terminálu roztaženého na celé okno; tuto výšku má terminál pořád,
        // v režimu jednoho řádku je z něj jen vidět řádek s kurzorem.
        let terminalArea = NSLayoutGuide()
        container.addLayoutGuide(terminalArea)
        NSLayoutConstraint.activate([
            terminalArea.topAnchor.constraint(equalTo: separators[0].bottomAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: functionBar.topAnchor),
            terminalPane.bottomAnchor.constraint(equalTo: functionBar.topAnchor),
            functionBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        terminalPane.bind(expandedHeight: terminalArea.heightAnchor)
        // Výšku terminálu pod panely určuje on sám: jeden řádek, s více
        // záložkami navíc lišta záložek.
        lineLayout = [panelArea.bottomAnchor.constraint(equalTo: terminalPane.topAnchor)]
        // Skryté panely si při roztaženém terminálu drží plochu pod ním (bez
        // vazby by jejich výška nebyla určená).
        fullLayout = [
            panelArea.bottomAnchor.constraint(equalTo: functionBar.topAnchor),
            terminalPane.topAnchor.constraint(equalTo: terminalArea.topAnchor),
        ]
        NSLayoutConstraint.activate(lineLayout)
        window?.contentView = container
        terminalPane.applyColors()
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
        panel.nearestLocalPath
    }

    /// Uloží adresáře obou panelů pro další spuštění (zavření okna, ukončení
    /// aplikace); ne při self-testu / kontrole kláves – ty pracují v dočasných
    /// adresářích. S více okny platí adresáře toho, které se ukládalo poslední.
    func savePanelPaths() {
        guard !AppDelegate.isAutomatedRun else { return }
        // Nastavení › Obecné: bez ukládání se příště otevřou výchozí adresáře.
        let save = Settings.savePanelPaths
        let defaults = UserDefaults.standard
        defaults.set(save ? Self.restorableDirectory(of: leftPanel) : nil, forKey: "leftPanelPath")
        defaults.set(save ? Self.restorableDirectory(of: rightPanel) : nil, forKey: "rightPanelPath")
    }

    /// Obnoví volby okna: skryté soubory a režimy zobrazení obou stran –
    /// převzaté ze zdrojového okna (⌘N), jinak uložené.
    /// - Parameter source: okno, ze kterého se toto otevírá (nil = první okno)
    private func restoreSettings(from source: MainWindowController?) {
        applyHiddenFiles()
        let defaults = UserDefaults.standard
        if let mode = source?.leftView.viewMode ?? ViewMode(rawValue: defaults.integer(forKey: "viewModeLeft")) {
            leftView.viewMode = mode
        }
        if let mode = source?.rightView.viewMode ?? ViewMode(rawValue: defaults.integer(forKey: "viewModeRight")) {
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
        // Prostřední lišta a skryté soubory podle nastavení; změna (v Nastavení
        // nebo v jiném okně) se projeví hned.
        middleBar.setCollapsed(!Settings.showMiddleBar)
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.middleBar.setCollapsed(!Settings.showMiddleBar)
            if self.applyHiddenFiles() { self.updateChrome() }
        })
        // Barevné schéma: panely a terminál si znovu načtou barvy.
        appObservers.append(center.addObserver(forName: Settings.colorSchemeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.leftView.applyColorScheme()
            self?.rightView.applyColorScheme()
            self?.terminalPane.applyColors()
        })
        functionBar.onCommand = { [weak self] in self?.perform($0) }
        driveBar.onPlace = { [weak self] place in
            guard let self else { return }
            self.open(place, in: self.activePanel)
        }
        driveBar.onEditPlaces = { [weak self] in self?.perform(.editPlaces) }
        driveBar.onConnect = { [weak self] in self?.perform(.connect) }
        // Terminál: nový shell startuje v adresáři aktivního panelu, „cd“
        // v shellu přesune aktivní panel a po doběhnutí příkazu se panely obnoví.
        terminalPane.startDirectory = { [weak self] in self?.activePanel.nearestLocalPath }
        terminalPane.onDirectoryChanged = { [weak self] directory in self?.followTerminal(to: directory) }
        terminalPane.onCommandFinished = { [weak self] in self?.reloadPanels() }
        terminalPane.onShellExited = { [weak self] in self?.setTerminalExpanded(false) }
    }

    /// Monitory: F-klávesy a Tab nad celým oknem, modifikátory pro lištu F-kláves.
    private func installKeyMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Diagnostický záznam kláves (zapíná `defaults write com.github.svopex.microcommander keyLog -bool YES`).
            // Monitor má každé hlavní okno – zapisuje jen první z nich, jinak by
            // byla každá klávesa v záznamu tolikrát, kolik je oken.
            if KeyLog.enabled, let controller = self, AppDelegate.shared?.windowControllers.first === controller {
                KeyLog.write(event, responder: event.window?.firstResponder)
            }
            guard let self, let window = self.window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            let inTerminal = self.terminalPane.hasFocus
            let fullTerminal = self.terminalPane.isExpanded
            // ⌘0–⌘9: místo z nabídky disků se zkratkou do aktivního panelu.
            if !fullTerminal, let digit = KeyCode.commandDigit(event), let place = PlaceStore.place(forShortcut: digit) {
                self.open(place, in: self.activePanel)
                return nil
            }
            // Klávesové zkratky příkazů (Nastavení › Klávesnice) dřív než menu a panel:
            // F-klávesy fungují odkudkoli, v textovém poli se nepoužijí zkratky
            // potřebné pro psaní (viz Shortcut.isTextEditing), v terminálu jen
            // některé (viz allowsShortcut).
            if let command = self.command(forKey: event) {
                self.perform(command)
                return nil
            }
            // Terminál přes celé okno dostane všechny ostatní klávesy.
            if fullTerminal {
                if inTerminal { self.terminalPane.noteKey(event) }
                return event
            }
            // Ctrl+Enter (zachytává se tady, protože macOS jinak ⌃↩ použije jako
            // „Zobrazit kontextovou nabídku“ a do panelu se klávesa nedostane):
            // jméno položky pod kurzorem na řádek terminálu.
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter, modifiers == .control {
                self.insertCurrentItemIntoTerminal()
                return nil
            }
            // ⌘Tab / Ctrl+Tab: přepínání mezi panelem a řádkem terminálu.
            if event.keyCode == KeyCode.tab, !event.modifierFlags.intersection([.control, .command]).isEmpty {
                if inTerminal {
                    self.focusActivePanel()
                } else {
                    self.terminalPane.focus()
                }
                return nil
            }
            if inTerminal {
                // PgUp/PgDn listují panelem (jeden řádek terminálu není kam posouvat);
                // ostatní klávesy patří shellu – Tab doplňuje, šipky listují historií.
                if event.keyCode == KeyCode.pageUp || event.keyCode == KeyCode.pageDown, modifiers.isEmpty {
                    _ = self.panelView(self.view(of: self.activePanel), keyDown: event)
                    return nil
                }
                self.terminalPane.noteKey(event)
                return event
            }
            // Tab v panelu přepíná panely (jako Salamander).
            if event.keyCode == KeyCode.tab, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               isPanelResponder(window.firstResponder) {
                self.activate(self.inactivePanel)
                return nil
            }
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.functionBar.update(modifiers: event.modifierFlags)
            return event
        }
        // Puštění modifikátoru v jiné aplikaci (např. po přepnutí ⌘Tab) aplikace
        // nedostane – lišta F-kláves by zůstala ve vrstvě Ctrl/Shift/Alt. Při
        // deaktivaci se vrátí základní vrstva, při aktivaci aktuální stav kláves.
        let center = NotificationCenter.default
        appObservers += [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.functionBar.update(modifiers: [])
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.functionBar.update(modifiers: NSEvent.modifierFlags)
            },
        ]
    }

    /// Příkaz pro stisknutou klávesu podle platných zkratek; v textovém poli
    /// (úprava cesty či jména, terminál) bez zkratek potřebných pro psaní.
    func command(forKey event: NSEvent) -> Command? {
        guard let command = KeyBindings.command(for: event, textEditing: !isPanelResponder(window?.firstResponder)),
              allowsShortcut(command, key: event) else { return nil }
        return command
    }

    /// Smí se klávesa použít jako zkratka příkazu? Terminál s fokusem si většinu
    /// kláves nechává: roztažený přes celé okno všechny kromě příkazů, které
    /// s ním počítají (⌘F12, záložky terminálu, ⌘N); v jednom řádku patří aplikaci F-klávesy
    /// a zkratky s ⌘, zbytek (⌃písmeno, ⌥znak…) shellu.
    private func allowsShortcut(_ command: Command, key event: NSEvent) -> Bool {
        if terminalPane.isExpanded { return command.worksInFullTerminal }
        guard terminalPane.hasFocus else { return true }
        return KeyCode.functionKeys.contains(event.keyCode) || event.modifierFlags.contains(.command)
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
        if !terminalPane.hasFocus {
            focusActivePanel()
        }
        updateChrome()
    }

    /// Fokus klávesnice do tabulky aktivního panelu; při terminálu roztaženém
    /// na celé okno (panely nejsou vidět) do terminálu.
    func focusActivePanel() {
        if terminalPane.isExpanded {
            terminalPane.focus()
            return
        }
        let target = view(of: activePanel).focusView
        if window?.firstResponder !== target {
            window?.makeFirstResponder(target)
        }
    }

    /// Pohled panelu.
    private func view(of panel: PanelController) -> PanelView {
        panel === leftPanel ? leftView : rightView
    }

    /// Obnoví řádky adresáře, informační řádky a titulek okna; terminál
    /// požádá o přechod do adresáře aktivního panelu.
    private func updateChrome() {
        for panel in [leftPanel, rightPanel] {
            let panelView = view(of: panel)
            panelView.directoryLine.path = panel.displayPath
            // Úprava cesty pracuje s cestou ve VFS (u archivu a serveru se
            // liší od zobrazeného textu s popiskem).
            panelView.directoryLine.editablePath = panel.location.path
            panelView.infoLine.text = infoText(for: panel)
        }
        syncTerminalDirectory()
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
            // Odkaz na adresář se počítá jako soubor (vlastní velikost odkazu).
            let dirs = marked.filter(\.isRealDir).count
            let files = marked.count - dirs
            let size = marked.filter { !$0.isRealDir }.reduce(UInt64(0)) { $0 + $1.size }
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
        let size = item.isDir ? panel.dirSize(of: item).map(formatExactSize) ?? "DIR" : formatExactSize(item.size)
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
            // Delete maže do koše, ⇧Delete trvale (jako F8 / ⇧F8).
            perform(flags.contains(.shift) ? .deletePermanent : .delete)
            return true
        case KeyCode.escape:
            if panel.quickSearch != nil { panel.endQuickSearch(); return true }
            // Escape smaže text rozepsaný na řádku terminálu.
            terminalPane.clearInput()
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
        // tady jako záložní cesta pro klávesy předané panelu jinak (kontrola
        // kláves bez okna).
        if let command = command(forKey: event) {
            perform(command)
            return true
        }

        // Zkratky s Ctrl/⌘ a písmenem (Ctrl varianty Salamandera).
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if ctrlOrCmd && !flags.contains(.option) {
            // Příkazy se zkratkami řeší KeyBindings v monitoru kláves; tady zůstává
            // jen vkládání cest panelů na řádek terminálu.
            switch chars {
            case "[":
                terminalPane.insert(shellQuote(leftPanel.displayPath) + " "); return true
            case "]":
                terminalPane.insert(shellQuote(rightPanel.displayPath) + " "); return true
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

    /// Zobrazovat skryté soubory (tečka na začátku, příznak UF_HIDDEN) – volba
    /// společná pro oba panely všech oken (Settings.showHiddenFiles).
    var showHiddenFiles: Bool { Settings.showHiddenFiles }

    /// Přepne zobrazení skrytých souborů; okna se o změně dozvědí oznámením.
    func toggleHiddenFiles() {
        Settings.showHiddenFiles.toggle()
    }

    /// Použije volbu skrytých souborů v obou panelech a na tlačítku lišty
    /// (výpis panelu se přestaví jen při změně).
    /// - Returns: true, pokud se zobrazení některého panelu změnilo
    @discardableResult
    private func applyHiddenFiles() -> Bool {
        let show = Settings.showHiddenFiles
        var changed = false
        for panel in [leftPanel, rightPanel] where panel.showHidden != show {
            panel.showHidden = show
            changed = true
        }
        topBar.setSymbol(show ? "eye" : "eye.slash", for: .toggleHidden)
        return changed
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
            .view, .edit, nil, .clipboardCopy, .clipboardCut, .clipboardPaste, nil,
            .copy, .move, .rename, .delete, .deletePermanent, nil,
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

    /// Soubory přetažené z jiné aplikace: okno do popředí (průběh a dotazy mají
    /// být vidět), cílový panel se stane aktivním a soubory se do něj vloží.
    func panelView(_ view: PanelView, dropFiles paths: [String], move: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        activate(view.panel)
        importFiles(paths, into: view.panel, move: move)
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
    /// Položku archivu, který žádný panel otevřený nemá, ukáže aktivní panel
    /// – vstoupí do archivu, je-li známá cesta jeho souboru na disku.
    /// - Parameters:
    ///   - vfs: souborový systém položky
    ///   - path: VFS cesta položky
    ///   - archivePath: `vfs` je archiv otevřený z tohoto souboru na disku
    ///     (nález okna Hledat s volbou Hledat v archivech)
    func showItem(vfs: Vfs, path: String, archivePath: String? = nil) {
        let dir = parentPath(path)
        let name = lastComponent(path)
        if vfs.kind == SAL_VFS_LOCAL, let localDir = vfs.realPath(dir) {
            let panel = activePanel
            if panel.location.vfs === Vfs.localDisk {
                panel.changePath(localDir, focus: name)
            } else {
                // Z archivu nebo serveru zpět na disk (zanoření se zavře).
                panel.navigate(Location(vfs: Vfs.localDisk, path: localDir), select: name)
            }
            activate(panel)
        } else if let panel = [activePanel, leftPanel, rightPanel].first(where: { $0.location.vfs === vfs }) {
            panel.changePath(dir, focus: name)
            activate(panel)
        } else if let archivePath {
            activePanel.showArchiveItem(vfs, archivePath: archivePath, path: path)
            activate(activePanel)
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
        // Spustitelný shell skript na lokálním disku: spustit ve vestavěném
        // terminálu v adresáři panelu (⌘Enter ho naopak otevře podle přípony).
        if let path = panel.localPath(of: item.name), isShellScript(atPath: path) {
            runInTerminal("./" + shellQuote(item.name), in: parentPath(path))
            return
        }
        withLocalFile(item, in: panel) { path in
            if let archive = Vfs.openArchive(path: path) {
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
                                           warning: wrong) else { return false }
        vfs.setPassword(password)
        return true
    }

    /// Modální dotaz na heslo ve stylu Salamandera (skryté pole, Enter = potvrdit,
    /// Escape = zrušit).
    /// - Parameters:
    ///   - title: nadpis dialogu
    ///   - text: vysvětlující text
    ///   - okTitle: popisek potvrzovacího tlačítka
    ///   - warning: výstražná ikona (chybné heslo), jinak ikona aplikace
    /// - Returns: zadané heslo, nil = zrušeno
    func askSecretText(title: String, text: String, okTitle: String = "OK", warning: Bool = false) -> String? {
        let dialog = PromptDialog(title: title, showsHeading: true, message: text,
                                  icon: warning ? PromptDialog.cautionIcon : NSApp.applicationIconImage,
                                  value: "", secure: true, buttons: [okTitle])
        let response = dialog.run(over: window)
        focusActivePanel()
        return response == 0 ? dialog.text : nil
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
        // Příkaz nad panely (menu, tlačítko lišty) při terminálu roztaženém na
        // celé okno: nejdřív zpět k panelům, ať je vidět, s čím příkaz pracuje.
        if terminalPane.isExpanded, !command.worksInFullTerminal {
            setTerminalExpanded(false)
        }
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
        case .delete: commandDelete(toTrash: true)
        case .deletePermanent: commandDelete(toTrash: false)
        case .terminal: commandTerminal()
        case .terminalFull: setTerminalExpanded(!terminalPane.isExpanded)
        case .terminalNewTab: terminalPane.addTab()
        case .terminalCloseTab: terminalPane.closeCurrentTab()
        case .terminalNextTab: terminalPane.selectAdjacentTab(offset: 1)
        case .terminalPreviousTab: terminalPane.selectAdjacentTab(offset: -1)
        case .newWindow: AppDelegate.shared?.openNewWindow(from: self)
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
        case .driveInfo: commandDriveInfo()
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
        case .clipboardCopy: commandClipboardCopy(cut: false)
        case .clipboardCut: commandClipboardCopy(cut: true)
        case .clipboardPaste: commandClipboardPaste()
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

    // MARK: - Schránka souborů a přetažení do panelu

    /// Cesty položek aktivního panelu pro schránku: označené, jinak položka pod
    /// kurzorem; jen z lokálního disku (položky archivu a serveru cestu nemají).
    private var clipboardSourcePaths: [String] {
        let panel = activePanel
        return panel.operationItems.compactMap { panel.localPath(of: $0.name) }
    }

    /// ⌘C / ⌘X – soubory do systémové schránky (vložit je lze v panelu i ve Finderu).
    /// - Parameter cut: vyjmout – vložení v panelu soubory přesune
    private func commandClipboardCopy(cut: Bool) {
        let paths = clipboardSourcePaths
        guard !paths.isEmpty else {
            NSSound.beep()
            return
        }
        FileClipboard.write(paths: paths, cut: cut)
    }

    /// ⌘V – vloží soubory ze schránky do adresáře aktivního panelu: zkopíruje
    /// je, po Vyjmout (⌘X) přesune.
    private func commandClipboardPaste() {
        let paths = FileClipboard.paths()
        guard !paths.isEmpty else {
            NSSound.beep()
            return
        }
        let move = FileClipboard.isCut
        importFiles(paths, into: activePanel, move: move) {
            // Přesunuté soubory už na původním místě nejsou – schránka se vyprázdní.
            if move { NSPasteboard.general.clearContents() }
        }
    }

    /// Vloží soubory a adresáře z lokálního disku do adresáře panelu (⌘V ze
    /// schránky, přetažení z jiné aplikace). Cíl může být i server; při konfliktu
    /// se zeptá na přepsání. Kopie do adresáře, kde položka už leží, vytvoří
    /// duplikát („jméno kopie“), přesun do téhož adresáře nedělá nic.
    /// - Parameters:
    ///   - paths: cesty zdrojových položek na lokálním disku
    ///   - target: panel, do jehož adresáře se vkládá
    ///   - move: přesunout místo kopírování
    ///   - onSuccess: voláno po úspěšném dokončení
    func importFiles(_ paths: [String], into target: PanelController, move: Bool, onSuccess: (() -> Void)? = nil) {
        // Během otevřeného sheetu (progress, dialog) se nevkládá.
        guard window?.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let verb = move ? "Přesun" : "Kopírování"
        let dst = target.location.vfs
        let dstDir = target.location.path
        guard dst.writable else {
            showAlert(title: verb, text: "Cílový souborový systém (\(dst.label)) je jen pro čtení.")
            return
        }
        // Jádro přenáší jména z jednoho adresáře – položky se seskupí podle
        // zdrojového adresáře (schránka z okna Hledat jich může mít víc).
        // Položky ležící už v cílovém adresáři jdou zvlášť jako duplikáty.
        // Adresáře se porovnávají bez symbolických odkazů v cestě (/tmp je na
        // disku /private/tmp) – stejně je porovnává jádro.
        func resolved(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let localTarget = target.localDirectory.map(resolved)
        var groups: [(dir: String, names: [String])] = []
        var groupIndex: [String: Int] = [:]
        var duplicates: [String] = []
        for path in paths {
            let dir = parentPath(path)
            if let index = groupIndex[dir] {
                groups[index].names.append(lastComponent(path))
            } else if resolved(dir) == localTarget {
                if !move { duplicates.append(path) }
            } else {
                groupIndex[dir] = groups.count
                groups.append((dir, [lastComponent(path)]))
            }
        }
        let count = groups.reduce(duplicates.count) { $0 + $1.names.count }
        guard count > 0 else { return }
        // Jméno, na které se po vložení postaví kurzor (duplikát dostane nové jméno).
        let focusName = groups.first?.names.first
        let what = count == 1 ? "„\(focusName ?? lastComponent(duplicates[0]))“" : "\(count) položek"
        let transferItems = move ? coreMove : coreCopy

        // Při konfliktu (Ask) se zeptá a operaci spustí znovu s režimem přepsání/přeskočení.
        func transfer(_ mode: OverwriteMode) {
            beginProgress(title: "\(verb) \(what)") { state in
                for group in groups {
                    // Opakovaný přesun: položky přesunuté před konfliktem už ve zdroji nejsou.
                    let names = move && mode != .ask
                        ? group.names.filter { FileManager.default.fileExists(atPath: joinPath(group.dir, $0)) }
                        : group.names
                    guard !names.isEmpty else { continue }
                    try transferItems(.localDisk, group.dir, names, dst, dstDir, mode, state)
                }
                // Duplikáty až nakonec: při opakování po konfliktu nevzniknou dvakrát.
                // Zrušení se kontroluje mezi položkami.
                for path in duplicates {
                    guard !state.isCancelled else { throw CoreError.code(SAL_ERR_CANCELLED, "") }
                    try duplicateLocalItem(atPath: path)
                }
            } completion: { [weak self] result in
                guard let self else { return }
                self.endProgress()
                switch result {
                case .failure(let error) where mode == .ask && (error as? CoreError)?.isExistsConflict == true:
                    if let choice = self.askOverwrite() {
                        transfer(choice)
                        return
                    }
                    // Dotaz zrušen – panely níže ukážou, co se stihlo přenést.
                case .failure(let error):
                    self.showErrorUnlessCancelled(title: verb, error)
                case .success:
                    // Kurzor na první vloženou položku (uplatní se při obnovení panelu).
                    if let focusName { target.focus(name: focusName) }
                    onSuccess?()
                }
                self.reloadPanels()
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
        // Index tlačítka: 0 = přepsat, 1 = přeskočit, nil = zrušeno.
        switch ask(title: "Cíl už existuje",
                   text: "Některé položky v cíli už existují. Přepsat je, přeskočit, nebo operaci zrušit?",
                   buttons: ["Přepsat vše", "Přeskočit existující"]) {
        case 0: return .overwrite
        case 1: return .skip
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

    /// F8 / Delete – smazání do koše, ⇧F8 / ⇧Delete – trvalé smazání
    /// (označené položky, jinak položka pod kurzorem).
    /// - Parameter toTrash: přesunout do koše; mimo lokální disk (archiv,
    ///   FTP/SFTP) koš není a maže se trvale – potvrzení to uvede
    private func commandDelete(toTrash: Bool) {
        let panel = activePanel
        let items = panel.operationItems
        guard !items.isEmpty else { return }
        guard panel.location.vfs.writable else {
            showAlert(title: "Smazat", text: "Souborový systém je jen pro čtení.")
            return
        }
        let vfs = panel.location.vfs
        let (text, useTrash) = deleteConfirmation(items: items, vfs: vfs, toTrash: toTrash, verb: "smazat")
        guard confirm(title: "Smazat", text: text, okTitle: "Smazat") else { return }

        let names = items.map(\.name)
        let dir = panel.location.path
        beginProgress(title: useTrash ? "Přesun do koše" : "Mazání", unit: .items) { state in
            try coreRemove(vfs: vfs, dir: dir, names: names, useTrash: useTrash, state: state)
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
                      icon: NSApp.applicationIconImage)
        }
    }

    /// ⌘F1 / ⌃F1 – informace o jednotce (svazku), na které leží adresář
    /// aktivního panelu; u archivu jde o svazek se souborem archivu.
    private func commandDriveInfo() {
        guard let path = activePanel.nearestLocalPath else {
            showAlert(title: "Informace o jednotce", text: "Informace o jednotce lze zobrazit jen pro lokální disk.")
            return
        }
        guard let info = VolumeInfo.load(path: path) else {
            showAlert(title: "Informace o jednotce", text: "Informace o jednotce se nepodařilo zjistit:\n\(path)")
            return
        }
        presentSheet(DriveInfoDialog(info: info))
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

    /// F9 – aplikace Terminal v adresáři aktivního panelu (samostatné okno
    /// vedle vestavěného terminálu).
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
        guard let path = panel.localPath(of: item.name), let archive = Vfs.openArchive(path: path) else {
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
        let location = panel.location
        let totals = SizeTotals()
        beginProgress(title: "Počítám velikost", unit: .items) { state in
            for item in items {
                // Odkaz na adresář se neprochází – jeho cíl do velikosti nepatří.
                if item.isRealDir {
                    totals.add(dirs: 1)
                    let collector = FindCollector()
                    do {
                        try coreFind(vfs: location.vfs, root: joinPath(location.path, item.name), mask: "*",
                                     includeDirs: true, state: state, collector: collector)
                    } catch let error as CoreError where !error.isCancelledLike {
                        // Nečitelný označený adresář (např. odepřený přístup) se přeskočí
                        // a zůstane u něj „DIR“; nečitelné podadresáře přeskakuje už jádro.
                        continue
                    }
                    // Součty adresáře lokálně, do celkových jedním voláním (bez zámku na položku).
                    var dirFiles = 0, subdirs = 0
                    var dirBytes: UInt64 = 0
                    for found in collector.snapshot() {
                        if found.item.isDir {
                            subdirs += 1
                        } else {
                            dirFiles += 1
                            dirBytes += found.item.size
                        }
                    }
                    totals.add(files: dirFiles, dirs: subdirs, bytes: dirBytes)
                    // Hotový adresář hned ukáže v panelu velikost místo „DIR“
                    // (postupně, jak výpočet prochází označené adresáře).
                    let name = item.name
                    DispatchQueue.main.async {
                        panel.setDirSize(dirBytes, for: name, in: location)
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
            let info = OccupiedSpaceInfo(panel: panel, items: items, totals: totals.snapshot())
            self?.presentSheet(OccupiedSpaceDialog(info: info))
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
            showAlert(title: "Porovnat adresáře", text: "Adresáře obsahují stejné soubory.", icon: NSApp.applicationIconImage)
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

    /// Aplikace Terminal macOS (F9).
    private static let terminalApp = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    // MARK: - Vestavěný terminál

    /// ⌘F12 – roztáhne terminál na celé okno (panely a lišta disků se skryjí),
    /// nebo ho vrátí na jeden řádek pod panely.
    private func setTerminalExpanded(_ expanded: Bool) {
        guard expanded != terminalPane.isExpanded else { return }
        if expanded {
            terminalHadFocusBeforeFull = terminalPane.hasFocus
            // Úprava cesty či jména v panelu se ukončí dřív, než panely zmizí.
            window?.makeFirstResponder(nil)
        }
        NSLayoutConstraint.deactivate(expanded ? lineLayout : fullLayout)
        NSLayoutConstraint.activate(expanded ? fullLayout : lineLayout)
        panelArea.isHidden = expanded
        terminalPane.setExpanded(expanded)
        if expanded || terminalHadFocusBeforeFull {
            terminalPane.focus()
        } else {
            focusActivePanel()
        }
    }

    /// Požádá terminál o přechod do lokálního adresáře aktivního panelu
    /// (opakovanou žádost o stejný adresář terminál ignoruje; v archivu a na
    /// serveru zůstává shell, kde byl).
    private func syncTerminalDirectory() {
        if let directory = activePanel.localDirectory {
            terminalPane.requestDirectory(directory)
        }
    }

    /// „cd“ v terminálu: aktivní panel přejde do adresáře shellu.
    private func followTerminal(to directory: String) {
        let panel = activePanel
        if let current = panel.localDirectory, terminalPane.isShellDirectory(current) { return }
        openDrive(directory, in: panel)
    }

    /// ⌃↩ – jméno položky pod kurzorem na řádek terminálu a fokus do terminálu.
    /// Soubor na prázdném řádku se vloží jako spuštění „./jméno“; je-li shell
    /// v jiném adresáři než panel (rozepsaný řádek, běžící program), vloží se
    /// celá cesta.
    private func insertCurrentItemIntoTerminal() {
        guard let item = activePanel.currentItem else { return }
        let directory = activePanel.localDirectory
        let text: String
        if let directory, !terminalPane.isShellDirectory(directory), let path = activePanel.localPath(of: item.name) {
            text = shellQuote(path)
        } else {
            let asCommand = !item.isDir && !terminalPane.hasPendingInput
            text = (asCommand ? "./" : "") + shellQuote(item.name)
        }
        terminalPane.insert(text + " ")
        terminalPane.focus()
    }

    /// Spustí příkaz ve vestavěném terminálu v daném adresáři a terminál
    /// roztáhne na celé okno, aby byl vidět výstup.
    /// - Parameters:
    ///   - command: text příkazu
    ///   - dir: pracovní adresář
    private func runInTerminal(_ command: String, in dir: String) {
        guard terminalPane.run(command, in: dir) else {
            showAlert(title: "Terminál",
                      text: "V terminálu běží jiný program nebo je na jeho řádku rozepsaný příkaz. Dokončete ho a zkuste to znovu.")
            return
        }
        setTerminalExpanded(true)
    }

    /// F1 – přehled ovládání.
    private func showHelp() {
        let text = """
        Panely: ↑↓ PgUp PgDn Home End – pohyb, Enter – otevřít (adresář, archiv, soubor; shell skript spustit v terminálu),
        ⌘Enter – spustit systémově (aplikace .app, soubor ve výchozí aplikaci),
        ⌫ – nadřazený adresář, Tab – druhý panel, ⌃Tab – řádek terminálu pod panely a zpět
        (shell v adresáři aktivního panelu), ⌘F12 – terminál na celé okno a zpět,
        ⌘T – nová záložka terminálu (⇧⌘W zavřít, ⌥⌘← / ⌥⌘→ přepnout),
        ⌃Enter – jméno položky do terminálu, ⌘N – nové okno,
        Space / Insert / ⇧↑↓ / ⌘klik – označit, Num + / − / * – maska / invertovat,
        ⌘A – označit vše (znovu = zrušit), ⌘D – nic, psaní písmen – rychlé hledání,
        ⌥← / ⌥→ – historie, ⌘\\ – kořen, ⌃H – skryté soubory.
        ⌘C / ⌘X / ⌘V – kopírovat / vyjmout / vložit soubory přes schránku (i z Finderu a do něj);
        soubory lze do panelu také přetáhnout myší z jiné aplikace (s ⌘ se přesunou).
        ⌘. (⌃.) – poslat aktuální adresář do druhého panelu (přepne se druhý panel).
        ⌘⇧. (⌃⇧.) – převzít adresář z druhého panelu (přepne se aktivní panel).

        F2 přejmenovat, F3 zobrazit, F4 upravit, F5 kopírovat, F6 přesunout,
        F7 nový adresář, F8 do koše (⇧F8 trvale), F9 Terminal.app, F10 ukončit, F11 FTP/SFTP, F12 odpojit.
        ⇧F4 nový soubor, ⇧F7 změnit adresář, ⌘F2 / ⌃F2 atributy, ⌥↩ / ⌘I vlastnosti, ⌃P oprávnění, ⌃F3–F6 řazení, ⌃F9 obnovit, ⌃F10 porovnat,
        ⌥F1/⌥F2 disk vlevo/vpravo (v nabídce ⌥↑/⌥↓ mění pořadí disků), ⌘F1 / ⌃F1 informace o jednotce,
        ⌥F5 zabalit, ⌥F6 rozbalit, ⌥F7 hledat, ⌥F10 velikost.

        Tip: na klávesnici Macu F-klávesy vyžadují Fn, nebo zapněte
        „Používat F1, F2 atd. jako standardní funkční klávesy“ v nastavení klávesnice.
        """
        showAlert(title: "MicroCommander – ovládání", text: text, icon: NSApp.applicationIconImage)
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
        let keyEvent = NSApp.currentEvent.flatMap { $0.type == .keyDown && $0.window === window ? $0 : nil }
        if let keyEvent, !isPanelResponder(window?.firstResponder), KeyBindings.isTextEditingKey(keyEvent) {
            return false
        }
        if menuItem.action == #selector(menuCommand(_:)),
           menuItem.tag >= 0, menuItem.tag < MainWindowController.menuCommands.count {
            let command = MainWindowController.menuCommands[menuItem.tag]
            // Klávesy, které si nechává terminál, menu nezachytí (viz allowsShortcut).
            if let keyEvent, !allowsShortcut(command, key: keyEvent) { return false }
            // Zavření a přepínání záložek terminálu jen s více záložkami.
            if command.needsTerminalTabs, terminalPane.tabCount < 2 { return false }
            // Schránka: kopírovat a vyjmout jen položky z lokálního disku, vložit
            // jen soubory a jen tam, kam lze zapisovat.
            switch command {
            case .clipboardCopy, .clipboardCut:
                if clipboardSourcePaths.isEmpty { return false }
            case .clipboardPaste:
                if !activePanel.location.vfs.writable || !FileClipboard.hasFiles() { return false }
            default:
                break
            }
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

    /// Hlášení ve stylu Salamandera s tlačítkem OK (Enter i Escape ho zavřou).
    /// - Parameter icon: ikona vlevo – výstraha u chyb a upozornění, ikona
    ///   aplikace (NSApp.applicationIconImage) u informací
    func showAlert(title: String, text: String, icon: NSImage? = PromptDialog.cautionIcon) {
        PromptDialog.show(title: title, message: text, icon: icon, over: window)
        focusActivePanel()
    }

    /// Dotaz s výstražnou ikonou ve stylu Salamandera (Enter = první tlačítko,
    /// Escape = zrušit); titulek jen opakuje text, proto bez nadpisu.
    /// - Returns: index stisknutého tlačítka, nil při zrušení
    private func ask(title: String, text: String, buttons: [String]) -> Int? {
        let response = PromptDialog.show(title: title, showsHeading: false, message: text, buttons: buttons,
                                         showsCancel: true, over: window)
        focusActivePanel()
        return response
    }

    /// Potvrzovací dotaz (Enter = potvrdit, Escape = zrušit).
    private func confirm(title: String, text: String, okTitle: String) -> Bool {
        ask(title: title, text: text, buttons: [okTitle]) == 0
    }

    /// Textový vstupní dialog ve stylu Salamandera; nil = zrušeno.
    /// selectBaseName označí jméno bez přípony.
    func promptText(title: String, message: String, value: String, okTitle: String = "OK",
                    selectBaseName: Bool = false) -> String? {
        let dialog = PromptDialog(title: title, message: message, value: value,
                                  selectsBaseName: selectBaseName, buttons: [okTitle])
        let response = dialog.run(over: window)
        focusActivePanel()
        guard response == 0 else { return nil }
        let result = dialog.text.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}

/// Dočasné soubory aplikace: kopie položek rozbalených z archivů a serverů
/// (F3, Enter, ⌘Enter). Kopie vzniklé za běhu se
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

/// Soubory v systémové schránce a v tažení myší (jako odkazy na soubory na
/// disku – stejně s nimi pracuje Finder, takže kopírování a vkládání funguje
/// i mezi aplikacemi).
enum FileClipboard {
    /// Čtení jen odkazů na soubory (webové adresy se ignorují).
    private static let fileURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// Stav schránky (changeCount) po posledním Vyjmout; dokud se schránka
    /// nezmění, vložení v panelu soubory přesune.
    private static var cutChangeCount: Int?

    /// Zapíše soubory do schránky (nahradí její obsah).
    /// - Parameters:
    ///   - paths: cesty souborů a adresářů na lokálním disku
    ///   - cut: vyjmout – vložení v panelu je přesune (Finder přesouvá přes ⌥⌘V)
    static func write(paths: [String], cut: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        cutChangeCount = cut ? pasteboard.changeCount : nil
    }

    /// Jsou soubory ve schránce vyjmuté (⌘X) a mají se vložením přesunout?
    static var isCut: Bool { cutChangeCount == NSPasteboard.general.changeCount }

    /// Obsahuje schránka (nebo tažení) soubory?
    static func hasFiles(in pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLOptions)
    }

    /// Cesty souborů ve schránce (nebo v tažení); prázdné, když v ní soubory nejsou.
    static func paths(from pasteboard: NSPasteboard = .general) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileURLOptions) as? [NSURL] ?? []
        // Finder může dát odkaz na soubor podle ID (file:///.file/id=…) – převod na cestu.
        return urls.compactMap { $0.filePathURL?.path }
    }
}

/// Zkopíruje soubor nebo adresář do téhož adresáře pod volným jménem
/// („jméno kopie.txt“, „jméno kopie 2.txt“ … jako Duplikovat ve Finderu).
/// - Parameter path: cesta položky na lokálním disku
func duplicateLocalItem(atPath path: String) throws {
    let manager = FileManager.default
    var isDirectory: ObjCBool = false
    _ = manager.fileExists(atPath: path, isDirectory: &isDirectory)
    // Přípona zůstává na konci jména; adresář se bere celým jménem.
    let name = lastComponent(path)
    let parts = isDirectory.boolValue ? (base: name, ext: "") : splitExtension(name)
    for index in 1... {
        let suffix = index == 1 ? " kopie" : " kopie \(index)"
        let target = joinPath(parentPath(path), parts.base + suffix + (parts.ext.isEmpty ? "" : "." + parts.ext))
        if !manager.fileExists(atPath: target) {
            try manager.copyItem(atPath: path, toPath: target)
            return
        }
    }
}

