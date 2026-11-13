// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Dialogy: průběh operace s cancel, připojení FTP/SFTP, hledání.

import AppKit

/// Progress dialog: ukazatel průběhu + tlačítko Zrušit.
final class ProgressDialog: NSWindowController {
    /// Stav pro C callback (cancel + čísla).
    let state = ProgressState()
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private let parent: NSWindow?

    init(title: String, parentWindow: NSWindow?) {
        parent = parentWindow
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        super.init(window: window)
        label.stringValue = title

        bar.isIndeterminate = true
        bar.startAnimation(nil)
        bar.minValue = 0
        bar.maxValue = 100
        bar.frame = NSRect(x: 20, y: 60, width: 380, height: 18)
        label.frame = NSRect(x: 20, y: 30, width: 380, height: 20)
        let cancel = NSButton(title: "Zrušit", target: self, action: #selector(cancelClicked(_:)))
        cancel.frame = NSRect(x: 320, y: 5, width: 80, height: 24)
        cancel.keyEquivalent = "\u{1b}"

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        content.addSubview(bar)
        content.addSubview(label)
        content.addSubview(cancel)
        window.contentView = content

        // Periodická aktualizace ukazatele (progress callback jen nastavuje stav).
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    private var timer: Timer?

    /// Zobrazí dialog jako sheet nad hlavním oknem.
    func begin() {
        if let parent {
            parent.beginSheet(self.window!)
        } else {
            showWindow(nil)
        }
    }

    /// Zavře dialog (sheet i okno).
    override func close() {
        timer?.invalidate()
        timer = nil
        // Sheet je nutné ukončit přes endSheet na rodiči (window.parent je u sheetu nil),
        // jinak rodičovské okno zůstane v modálním stavu a nepřijímá vstup.
        if let window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        }
        window?.orderOut(nil)
    }

    /// Aktualizuje ukazatel podle stavu operace.
    private func refresh() {
        let snapshot = state.snapshot()
        if snapshot.total > 0 {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            let percent = Double(snapshot.done) / Double(snapshot.total) * 100
            bar.doubleValue = percent
            label.stringValue = "\(formatSize(snapshot.done)) z \(formatSize(snapshot.total)) (\(Int(percent)) %)"
        } else if snapshot.done > 0 {
            label.stringValue = "Přeneseno \(formatSize(snapshot.done))"
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        state.cancel()
    }
}

/// Dialog připojení k FTP/SFTP. U SFTP lze zvolit ověření: heslo, soubor se
/// soukromým klíčem (s volitelným heslem ke klíči) nebo ssh-agent.
/// Poslední server, port, uživatel, způsob ověření a cesta ke klíči se pamatují
/// (hesla nikdy).
final class ConnectWindowController: NSWindowController {
    private let kindFtp = NSButton(radioButtonWithTitle: "FTP", target: nil, action: nil)
    private let kindSftp = NSButton(radioButtonWithTitle: "SFTP", target: nil, action: nil)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let authPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passField = NSSecureTextField()
    private let keyField = NSTextField()
    private let keyButton = NSButton(title: "Vybrat…", target: nil, action: nil)
    private let passphraseField = NSSecureTextField()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Připojit", target: nil, action: nil)
    private var grid: NSGridView!
    private weak var mainController: MainWindowController?

    /// Způsob ověření u SFTP (index v nabídce).
    private enum AuthMethod: Int {
        case password = 0, keyFile = 1, agent = 2
    }

    /// Zobrazí dialog jako sheet nad hlavním oknem.
    static func show(parent: MainWindowController) {
        // Kontroler musí žít po celou dobu sheetu (jinak tlačítka nereagují).
        let controller = ConnectWindowController(owner: parent)
        parent.sheetController = controller
        parent.window!.beginSheet(controller.window!) { [weak parent] _ in
            parent?.sheetController = nil
            parent?.focusActivePanel()
        }
    }

    init(owner: MainWindowController) {
        self.mainController = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Připojit vzdálený disk"
        super.init(window: window)
        buildLayout()
        restoreValues()
        updateVisibility()
        window.initialFirstResponder = hostField.stringValue.isEmpty ? hostField : (kindSftp.state == .on ? userField : passField)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Mřížka popisek + pole; řádky pro heslo/klíč se skrývají podle volby ověření.
    private func buildLayout() {
        for button in [kindFtp, kindSftp] {
            button.target = self
            button.action = #selector(kindChanged(_:))
        }
        authPopup.addItems(withTitles: ["Heslo", "Soubor s klíčem", "Klíče ze ssh-agenta"])
        authPopup.target = self
        authPopup.action = #selector(authChanged(_:))
        keyButton.target = self
        keyButton.action = #selector(chooseKey(_:))
        keyButton.bezelStyle = .rounded
        keyField.placeholderString = "~/.ssh/id_ed25519"
        keyField.lineBreakMode = .byTruncatingHead
        passphraseField.placeholderString = "jen u klíče chráněného heslem"
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        for field in [hostField, portField, userField, passField, keyField, passphraseField] {
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }

        let kindRow = NSStackView(views: [kindFtp, kindSftp])
        kindRow.spacing = 16
        let keyRow = NSStackView(views: [keyField, keyButton])
        keyRow.spacing = 6
        keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid = NSGridView(views: [
            [NSTextField(labelWithString: "Protokol:"), kindRow],
            [NSTextField(labelWithString: "Server:"), hostField],
            [NSTextField(labelWithString: "Port:"), portField],
            [NSTextField(labelWithString: "Uživatel:"), userField],
            [NSTextField(labelWithString: "Ověření:"), authPopup],
            [NSTextField(labelWithString: "Heslo:"), passField],
            [NSTextField(labelWithString: "Soubor s klíčem:"), keyRow],
            [NSTextField(labelWithString: "Heslo ke klíči:"), passphraseField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        hostField.widthAnchor.constraint(equalToConstant: 310).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let cancelButton = NSButton(title: "Zrušit", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton.target = self
        connectButton.action = #selector(connectClicked(_:))
        connectButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancelButton, connectButton])
        buttons.spacing = 10

        let content = NSView()
        for view in [grid!, noteLabel, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            noteLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            noteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            noteLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 480),
        ])
        window?.contentView = content
    }

    /// Obnoví poslední hodnoty dialogu (bez hesel); výchozí klíč = první existující v ~/.ssh.
    private func restoreValues() {
        let defaults = UserDefaults.standard
        let sftp = defaults.bool(forKey: "connectSftp")
        kindSftp.state = sftp ? .on : .off
        kindFtp.state = sftp ? .off : .on
        hostField.stringValue = defaults.string(forKey: "connectHost") ?? ""
        portField.stringValue = defaults.string(forKey: "connectPort") ?? (sftp ? "22" : "21")
        userField.stringValue = defaults.string(forKey: "connectUser") ?? (sftp ? NSUserName() : "anonymous")
        authPopup.selectItem(at: defaults.integer(forKey: "connectAuth"))
        let savedKey = defaults.string(forKey: "connectKey")
        keyField.stringValue = savedKey ?? ConnectWindowController.defaultKeyPath() ?? ""
    }

    /// Uloží hodnoty dialogu pro příště (hesla se neukládají).
    private func saveValues() {
        let defaults = UserDefaults.standard
        defaults.set(kindSftp.state == .on, forKey: "connectSftp")
        defaults.set(hostField.stringValue, forKey: "connectHost")
        defaults.set(portField.stringValue, forKey: "connectPort")
        defaults.set(userField.stringValue, forKey: "connectUser")
        defaults.set(authPopup.indexOfSelectedItem, forKey: "connectAuth")
        defaults.set(keyField.stringValue, forKey: "connectKey")
    }

    /// První existující běžný klíč v ~/.ssh (zkráceně s „~“).
    static func defaultKeyPath() -> String? {
        let home = NSHomeDirectory()
        for name in ["id_ed25519", "id_ecdsa", "id_rsa"] {
            if FileManager.default.fileExists(atPath: home + "/.ssh/" + name) {
                return "~/.ssh/" + name
            }
        }
        return nil
    }

    /// Zvolený způsob ověření (FTP vždy heslo).
    private var authMethod: AuthMethod {
        kindSftp.state == .on ? (AuthMethod(rawValue: authPopup.indexOfSelectedItem) ?? .password) : .password
    }

    /// Zobrazí jen řádky, které platí pro protokol a způsob ověření; poznámka vysvětlí volbu.
    private func updateVisibility() {
        let sftp = kindSftp.state == .on
        let method = authMethod
        grid.row(at: 4).isHidden = !sftp
        grid.row(at: 5).isHidden = method != .password
        grid.row(at: 6).isHidden = method != .keyFile
        grid.row(at: 7).isHidden = method != .keyFile
        switch (sftp, method) {
        case (true, .keyFile):
            noteLabel.stringValue = "Soukromý klíč OpenSSH/PEM (ed25519, ECDSA, RSA). Veřejný klíč musí být na serveru v ~/.ssh/authorized_keys."
        case (true, .agent):
            noteLabel.stringValue = "Použijí se klíče načtené v ssh-agentovi (ssh-add); zkoušejí se postupně všechny."
        case (true, .password):
            noteLabel.stringValue = "Přihlášení heslem uživatele na serveru."
        default:
            noteLabel.stringValue = "FTP bez šifrování – heslo se posílá nezašifrovaně."
        }
    }

    @objc private func kindChanged(_ sender: Any?) {
        // Změna protokolu přednastaví výchozí port a uživatele.
        let sftp = kindSftp.state == .on
        if portField.stringValue == "21" || portField.stringValue == "22" || portField.stringValue.isEmpty {
            portField.stringValue = sftp ? "22" : "21"
        }
        if sftp && userField.stringValue == "anonymous" {
            userField.stringValue = NSUserName()
        }
        updateVisibility()
    }

    @objc private func authChanged(_ sender: Any?) {
        updateVisibility()
    }

    /// Výběr souboru s klíčem (otevře ~/.ssh, ukazuje skryté soubory).
    @objc private func chooseKey(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Soubor se soukromým klíčem"
        panel.prompt = "Vybrat"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            // Cestu v domově zobrazíme zkráceně s „~“.
            let home = NSHomeDirectory()
            self.keyField.stringValue = url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
            self.updatePassphraseHint()
        }
    }

    /// Po výběru klíče: chráněný heslem → upozornit a předvybrat pole hesla ke klíči.
    private func updatePassphraseHint() {
        let path = (keyField.stringValue as NSString).expandingTildeInPath
        if sshKeyEncrypted(path: path) == true {
            noteLabel.stringValue = "Klíč je chráněný heslem – zadejte heslo ke klíči."
            window?.makeFirstResponder(passphraseField)
        } else {
            updateVisibility()
        }
    }

    @objc private func cancelClicked(_ sender: Any?) {
        window?.sheetParent?.endSheet(window!)
    }

    @objc private func connectClicked(_ sender: Any?) {
        guard let mainController else { return }
        let isSftp = kindSftp.state == .on
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let port = UInt16(portField.stringValue) ?? (isSftp ? 22 : 21)
        let user = userField.stringValue
        let password = passField.stringValue
        let method = authMethod
        let keyPath = (keyField.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let passphrase = passphraseField.stringValue
        guard !host.isEmpty else {
            window?.makeFirstResponder(hostField)
            return
        }
        // Klíč: kontrola souboru a hesla ke klíči ještě před připojením.
        if method == .keyFile {
            switch sshKeyEncrypted(path: keyPath) {
            case nil:
                showError("Soubor s klíčem „\(keyField.stringValue)“ nelze přečíst.")
                return
            case true? where passphrase.isEmpty:
                noteLabel.stringValue = "Klíč je chráněný heslem – zadejte heslo ke klíči."
                window?.makeFirstResponder(passphraseField)
                NSSound.beep()
                return
            default:
                break
            }
        }
        saveValues()
        connectButton.isEnabled = false
        connectButton.title = "Připojuji…"

        // Připojení běží na pozadí (síť), pak se lokace otevře v aktivním panelu.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let vfs: Vfs
                switch (isSftp, method) {
                case (false, _):
                    vfs = try Vfs.connectFtp(host: host, port: port, user: user, password: password, timeout: 15)
                case (true, .password):
                    vfs = try Vfs.connectSftp(host: host, port: port, user: user, password: password, timeout: 15)
                case (true, .keyFile):
                    vfs = try Vfs.connectSftpKey(host: host, port: port, user: user, keyPath: keyPath,
                                                 passphrase: passphrase, timeout: 15)
                case (true, .agent):
                    vfs = try Vfs.connectSftpAgent(host: host, port: port, user: user, timeout: 15)
                }
                DispatchQueue.main.async {
                    guard let self, let sheet = self.window else { return }
                    self.window?.sheetParent?.endSheet(sheet)
                    let panel = mainController.activePanel
                    panel.navigate(Location(vfs: vfs, path: "/"), nested: true,
                                   focus: panel.currentItem?.name)
                    mainController.activate(panel)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.connectButton.isEnabled = true
                    self.connectButton.title = "Připojit"
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    /// Chyba připojení jako sheet nad dialogem (dialog zůstane otevřený k opravě).
    private func showError(_ text: String) {
        guard let sheet = window else { return }
        let alert = NSAlert()
        alert.messageText = "Připojení se nezdařilo"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.beginSheetModal(for: sheet)
    }
}

/// Okno výsledků hledání.
final class FindWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var results: [FindResult] = []
    private let tableView = NSTableView()
    private let maskField = NSTextField(frame: NSRect(x: 0, y: 0, width: 0, height: 0))
    private let dirsCheckbox = NSButton(checkboxWithTitle: "Zahrnout adresáře", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private var searchButton: NSButton!
    private weak var mainController: MainWindowController?
    private var runningState: ProgressState?

    /// Zobrazí dialog hledání (sheet nad hlavním oknem).
    static func show(parent: MainWindowController) {
        let controller = FindWindowController(owner: parent)
        parent.sheetController = controller
        parent.window!.beginSheet(controller.window!) { [weak parent] _ in
            parent?.sheetController = nil
            parent?.focusActivePanel()
        }
    }

    init(owner: MainWindowController) {
        self.mainController = owner
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hledat"
        super.init(window: window)

        // Panel s parametry hledání + tabulka výsledků.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 460))
        let maskLabel = NSTextField(labelWithString: "Maska:")
        maskLabel.frame = NSRect(x: 16, y: 402, width: 60, height: 20)
        maskField.frame = NSRect(x: 80, y: 398, width: 380, height: 24)
        maskField.stringValue = "*"
        searchButton = NSButton(title: "Hledat", target: self, action: #selector(searchClicked(_:)))
        searchButton.frame = NSRect(x: 470, y: 396, width: 90, height: 26)
        searchButton.keyEquivalent = "\r"
        let closeButton = NSButton(title: "Zavřít", target: self, action: #selector(closeClicked(_:)))
        closeButton.frame = NSRect(x: 540, y: 14, width: 90, height: 26)
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.autoresizingMask = [.minXMargin]
        content.addSubview(closeButton)
        dirsCheckbox.frame = NSRect(x: 80, y: 372, width: 200, height: 20)
        dirsCheckbox.state = .off

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 56, width: 640, height: 310))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Cesta"
        nameColumn.width = 400
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Velikost"
        sizeColumn.width = 110
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(resultDoubleClicked(_:))
        tableView.target = self
        scroll.documentView = tableView

        statusLabel.frame = NSRect(x: 16, y: 30, width: 500, height: 18)
        statusLabel.textColor = .secondaryLabelColor

        content.addSubview(maskLabel)
        content.addSubview(maskField)
        content.addSubview(searchButton)
        content.addSubview(dirsCheckbox)
        content.addSubview(scroll)
        content.addSubview(statusLabel)
        window.contentView = content
        window.initialFirstResponder = maskField
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Zavře dialog (běžící hledání nejdřív zruší).
    @objc private func closeClicked(_ sender: Any?) {
        runningState?.cancel()
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
    }

    @objc private func searchClicked(_ sender: Any?) {
        // Během hledání tlačítko slouží jako „Zrušit“.
        if let runningState {
            runningState.cancel()
            return
        }
        guard let mainController else { return }
        let mask = maskField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !mask.isEmpty else { return }

        let panel = mainController.activePanel
        let vfs = panel.location.vfs
        let root = panel.location.path
        let includeDirs = dirsCheckbox.state == .on

        // Sběr výsledků; průběžné doplňování tabulky přes timer.
        let collector = FindCollector()
        let state = ProgressState()
        runningState = state
        results = []
        tableView.reloadData()
        statusLabel.stringValue = "Hledám…"
        searchButton.title = "Zrušit"

        let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let snapshot = collector.snapshot()
            if snapshot.count != self.results.count {
                self.results = snapshot
                self.tableView.reloadData()
            }
            let snap = state.snapshot()
            self.statusLabel.stringValue = snap.total > 0
                ? "Prohledáno \(snap.done), nalezeno \(snapshot.count)"
                : "Prohledáno \(snap.done), nalezeno \(snapshot.count)"
        }
        RunLoop.main.add(timer, forMode: .default)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                try coreFind(vfs: vfs, root: root, mask: mask, includeDirs: includeDirs,
                             state: state, collector: collector)
                result = .success(())
            } catch let error as CoreError where error.isCancelledLike {
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                timer.invalidate()
                self?.runningState = nil
                self?.searchButton.title = "Hledat"
                self?.results = collector.snapshot()
                self?.tableView.reloadData()
                if case .failure(let failure) = result {
                    self?.statusLabel.stringValue = "Hledání selhalo: \(failure.localizedDescription)"
                } else {
                    self?.statusLabel.stringValue = "Nalezeno \(self?.results.count ?? 0) položek."
                }
            }
        }
    }

    /// Dvojklik na výsledek: aktivní panel otevře adresář s položkou.
    @objc private func resultDoubleClicked(_ sender: Any?) {
        guard let mainController else { return }
        let row = tableView.clickedRow
        guard row >= 0, row < results.count else { return }
        let result = results[row]
        let parent = parentPath(result.path)
        let panel = mainController.activePanel
        // Výsledek je ve stejném VFS jako panel (hledáme v něm); kurzor na nalezenou položku.
        runningState?.cancel()
        panel.changePath(parent, focus: result.item.name)
        if let window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        }
    }

    // MARK: - Tabulka výsledků

    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count else { return nil }
        let result = results[row]
        let isSize = tableColumn?.identifier.rawValue == "size"
        let text = isSize ? formatSize(result.item.size) : result.path
        let identifier = NSUserInterfaceItemIdentifier(tableColumn?.identifier.rawValue ?? "name")
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = text
            return cell
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.topAnchor.constraint(equalTo: cell.topAnchor),
            field.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }
}

extension CoreError {
    /// Je to zrušení operace uživatelem (není to selhání)?
    var isCancelledLike: Bool {
        if case .code(let code, _) = self, code == SAL_ERR_CANCELLED { return true }
        return false
    }
}

/// Interní prohlížeč (F3): text, obrázek, nebo hexadecimální výpis binárních dat.
/// Escape, F3 i F10 okno zavřou (jako prohlížeč Salamandera).
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    /// Otevřená okna prohlížeče (drží kontrolery naživu).
    private static var openViewers: [ViewerWindowController] = []
    /// Maximum načtených dat (větší soubory se zobrazí zkráceně).
    private static let maxBytes = 8 * 1024 * 1024

    /// Otevře soubor z lokálního disku.
    static func open(path: String, title: String) {
        let url = URL(fileURLWithPath: path)
        // Obrázky zobrazíme jako obrázek, ostatní jako text / hex.
        if let image = NSImage(contentsOf: url), image.isValid, !path.lowercased().hasSuffix(".pdf") {
            show(ViewerWindowController(title: title, image: image))
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            let alert = NSAlert()
            alert.messageText = "Zobrazit"
            alert.informativeText = "Soubor \(path) nelze otevřít."
            alert.runModal()
            return
        }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        try? handle.close()
        let truncated = data.count >= maxBytes
        show(ViewerWindowController(title: title, text: decodeForViewing(data, truncated: truncated)))
    }

    /// Otevře hotový text (např. výstup příkazové řádky).
    static func open(text: String, title: String) {
        show(ViewerWindowController(title: title, text: text))
    }

    private static func show(_ controller: ViewerWindowController) {
        openViewers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Text pro zobrazení: UTF-8, jinak Windows-1250/Latin-1; binární data jako hex výpis.
    private static func decodeForViewing(_ data: Data, truncated: Bool) -> String {
        let sample = data.prefix(8192)
        let zeroCount = sample.filter { $0 == 0 }.count
        var text: String
        if zeroCount > sample.count / 100 + 1 {
            text = hexDump(data.prefix(1024 * 1024))
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let cp1250 = String(data: data, encoding: .windowsCP1250) {
            text = cp1250
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        if truncated {
            text += "\n\n[… zobrazena jen část souboru]"
        }
        return text
    }

    /// Hexadecimální výpis po 16 bajtech s ASCII sloupcem.
    private static func hexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08X  ", offset) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + ascii)
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    /// Okno s textem (neupravitelný NSTextView, neproporcionální písmo).
    private init(title: String, text: String) {
        let window = ViewerWindowController.makeWindow(title: title)
        super.init(window: window)
        window.delegate = self
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.string = text
            textView.textContainerInset = NSSize(width: 6, height: 6)
        }
        window.contentView = scroll
        window.initialFirstResponder = scroll.documentView
    }

    /// Okno s obrázkem (přizpůsobení velikosti okna).
    private init(title: String, image: NSImage) {
        let window = ViewerWindowController.makeWindow(title: title)
        super.init(window: window)
        window.delegate = self
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = imageView
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    private static func makeWindow(title: String) -> NSWindow {
        let window = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        ViewerWindowController.openViewers.removeAll { $0 === self }
    }
}

/// Okno prohlížeče: Escape, F3 a F10 ho zavřou.
private final class ViewerWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape || event.keyCode == 99 || event.keyCode == 109 {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Volby šifrování v dialogu „Zabalit do ZIP“ (accessory view NSSavePanelu):
/// šifrování (žádné / AES-256 / ZipCrypto), heslo a jeho potvrzení.
/// Jako delegát panelu ověří hesla před uložením (shoda, neprázdné).
final class PackOptionsView: NSView, NSOpenSavePanelDelegate {
    private let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passwordField = NSSecureTextField()
    private let confirmField = NSSecureTextField()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    /// Zvolené šifrování (čte se po potvrzení dialogu).
    var encryption: ZipEncryption {
        switch methodPopup.indexOfSelectedItem {
        case 1: return .aes256(passwordField.stringValue)
        case 2: return .zipCrypto(passwordField.stringValue)
        default: return .none
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 132))
        methodPopup.addItems(withTitles: ["Bez šifrování", "AES-256 (doporučeno)", "ZipCrypto (slabé, kompatibilní)"])
        methodPopup.target = self
        methodPopup.action = #selector(methodChanged(_:))
        passwordField.placeholderString = "heslo"
        confirmField.placeholderString = "heslo znovu"
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor

        // Mřížka popisek + ovládací prvek, pod ní poznámka k režimu.
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Šifrování:"), methodPopup],
            [NSTextField(labelWithString: "Heslo:"), passwordField],
            [NSTextField(labelWithString: "Potvrzení:"), confirmField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        addSubview(noteLabel)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            passwordField.widthAnchor.constraint(equalToConstant: 240),
            confirmField.widthAnchor.constraint(equalToConstant: 240),
            noteLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            noteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            noteLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
        methodChanged(nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Hesla jsou aktivní jen se šifrováním; poznámka popisuje kompatibilitu režimu.
    @objc private func methodChanged(_ sender: Any?) {
        let index = methodPopup.indexOfSelectedItem
        passwordField.isEnabled = index != 0
        confirmField.isEnabled = index != 0
        switch index {
        case 1:
            noteLabel.stringValue = "WinZip AES-256: otevře 7-Zip, WinZip, Salamander, Keka. Vestavěná Archivační utilita macOS AES neumí."
        case 2:
            noteLabel.stringValue = "ZipCrypto je snadno prolomitelné – použijte jen kvůli starým programům."
        default:
            noteLabel.stringValue = "Archiv nebude chráněn heslem."
        }
    }

    /// Ověření před uložením: se šifrováním musí být heslo neprázdné a obě pole stejná.
    func panel(_ sender: Any, validate url: URL) throws {
        guard methodPopup.indexOfSelectedItem != 0 else { return }
        let message: String?
        if passwordField.stringValue.isEmpty {
            message = "Zadejte heslo pro šifrovaný archiv."
        } else if passwordField.stringValue != confirmField.stringValue {
            message = "Heslo a jeho potvrzení se neshodují."
        } else {
            message = nil
        }
        if let message {
            throw NSError(domain: "MicroCommander", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// Nabídka disků (⌥F1 / ⌥F2, tlačítko disku na řádku adresáře) ve stylu
/// Change Drive menu Salamandera. Vlastní okno místo NSMenu kvůli ovládání:
/// ↑/↓ cyklí (z poslední položky na první a obráceně), Home/End, PgUp/PgDn,
/// číslice 1–9 vyberou položku přímo, Enter potvrdí, Escape / klik mimo zavře.
final class DriveChooser: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Položka nabídky: název, cesta/popis, ikona.
    struct Entry {
        let title: String
        let detail: String
        let icon: NSImage?
    }

    /// Právě otevřená nabídka (drží kontroler naživu).
    private static var current: DriveChooser?

    private var entries: [Entry]
    private let onChoose: (Int) -> Void
    /// Kolik položek od začátku lze přesouvat (disky; „Připojit FTP“ zůstává na konci).
    var movableCount = 0
    /// Přesun položky (z indexu, na index) – volající uloží nové pořadí.
    var onMove: ((Int, Int) -> Void)?
    let tableView = DriveTableView()
    /// Výběr se už zpracoval (zavření po výběru nevolá nic dalšího).
    private var finished = false

    /// Cyklický posun indexu: za koncem začíná znovu od začátku a obráceně.
    static func wrappedIndex(_ index: Int, delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// Otevře nabídku pod pohledem `anchor`; `selected` = výchozí řádek (aktuální disk).
    @discardableResult
    static func show(entries: [Entry], selected: Int, below anchor: NSView,
                     onChoose: @escaping (Int) -> Void) -> DriveChooser {
        current?.cancel()
        let chooser = DriveChooser(entries: entries, selected: selected, onChoose: onChoose)
        current = chooser
        if let window = chooser.window, let parent = anchor.window {
            // Umístění pod tlačítko (souřadnice obrazovky).
            let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            window.setFrameTopLeftPoint(NSPoint(x: anchorRect.minX, y: anchorRect.minY - 2))
            parent.addChildWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(chooser.tableView)
        }
        return chooser
    }

    /// Vytvoří nabídku (bez zobrazení – používá i kontrola kláves bez okna).
    init(entries: [Entry], selected: Int, onChoose: @escaping (Int) -> Void) {
        self.entries = entries
        self.onChoose = onChoose
        let rowHeight: CGFloat = 22
        // Výška přesně na počet řádků (bez mezer mezi řádky), max. 480 bodů.
        let height = min(CGFloat(entries.count) * rowHeight + 8, 480)
        let panel = DriveChooserPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .windowBackgroundColor
        super.init(window: panel)
        panel.delegate = self

        // Tabulka bez záhlaví: ikona + název + cesta.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("drive"))
        column.width = 370
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.style = .plain
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.chooser = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        let scroll = NSScrollView(frame: panel.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = tableView
        scroll.hasVerticalScroller = entries.count * Int(rowHeight) > 480
        scroll.drawsBackground = false
        // Bez automatických odsazení (okno nemá titulek) a s malým okrajem nahoře/dole.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        panel.contentView = scroll
        tableView.reloadData()
        select(max(0, min(selected, entries.count - 1)))
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Vybraný řádek.
    var selectedIndex: Int { tableView.selectedRow }

    /// Označí řádek a posune ho do viditelné oblasti.
    func select(_ index: Int) {
        guard !entries.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    /// Klávesy nabídky; true = zpracováno.
    func handleKey(_ event: NSEvent) -> Bool {
        let count = entries.count
        let current = max(selectedIndex, 0)
        // ⌥↑/⌥↓ (nebo ⌘↑/⌘↓) přesune vybraný disk v pořadí.
        let flags = event.modifierFlags.intersection([.option, .command])
        if !flags.isEmpty, event.keyCode == KeyCode.up || event.keyCode == KeyCode.down {
            move(current, by: event.keyCode == KeyCode.up ? -1 : 1)
            return true
        }
        switch event.keyCode {
        case KeyCode.down:
            select(DriveChooser.wrappedIndex(current, delta: 1, count: count))
        case KeyCode.up:
            select(DriveChooser.wrappedIndex(current, delta: -1, count: count))
        case KeyCode.home, KeyCode.pageUp:
            select(0)
        case KeyCode.end, KeyCode.pageDown:
            select(count - 1)
        case KeyCode.returnKey, KeyCode.enter, KeyCode.space:
            choose(current)
        case KeyCode.escape:
            cancel()
        default:
            // Číslice 1–9 vyberou položku přímo (jako písmena disků ve Windows).
            if let digit = KeyCode.digits.firstIndex(of: event.keyCode), digit < count {
                choose(digit)
                return true
            }
            return false
        }
        return true
    }

    /// Přesune položku o krok nahoru/dolů (jen v rozsahu přesouvatelných disků).
    func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard index < movableCount, target >= 0, target < movableCount else {
            NSSound.beep()
            return
        }
        entries.swapAt(index, target)
        tableView.reloadData()
        select(target)
        onMove?(index, target)
    }

    /// Potvrzení položky: zavřít nabídku a zavolat akci.
    func choose(_ index: Int) {
        guard !finished, index >= 0, index < entries.count else { return }
        finished = true
        closeWindow()
        onChoose(index)
    }

    /// Zrušení bez výběru.
    func cancel() {
        finished = true
        closeWindow()
    }

    private func closeWindow() {
        if let window {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
        if DriveChooser.current === self {
            DriveChooser.current = nil
        }
    }

    /// Klik mimo nabídku (ztráta fokusu) ji zavře.
    func windowDidResignKey(_ notification: Notification) {
        if !finished { cancel() }
    }

    @objc private func rowClicked(_ sender: Any?) {
        if tableView.clickedRow >= 0 {
            choose(tableView.clickedRow)
        }
    }

    // MARK: - Tabulka

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: entry.icon ?? NSImage())
        // Číslo položky (1–9) jako zkratka, pak název a šedě cesta.
        let number = row < 9 ? "\(row + 1)  " : "   "
        let text = NSMutableAttributedString(string: number, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)])
        text.append(NSAttributedString(string: entry.title, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        if !entry.detail.isEmpty {
            text.append(NSAttributedString(string: "   " + entry.detail,
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingMiddle
        for view in [image, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// Tabulka nabídky disků – klávesy řídí DriveChooser (cyklení, číslice).
final class DriveTableView: NSTableView {
    weak var chooser: DriveChooser?

    override func keyDown(with event: NSEvent) {
        if chooser?.handleKey(event) != true {
            super.keyDown(with: event)
        }
    }
}

/// Okno bez rámečku, které umí být key (kvůli klávesnici).
private final class DriveChooserPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
