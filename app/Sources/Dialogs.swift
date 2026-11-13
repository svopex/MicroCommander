// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Dialogy: průběh operace s cancel, správa a připojení FTP/SFTP serverů, hledání.

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
    /// Volitelná akce po stisku Zrušit (beginProgress s dismissOnCancel dialog hned zavře).
    var onCancel: (() -> Void)?

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
        onCancel?()
    }
}

/// Správa FTP/SFTP serverů: seznam uložených serverů vlevo (přidat +, odebrat −),
/// formulář vybraného serveru vpravo. Úpravy se ukládají průběžně (přepnutí
/// serveru, Připojit, Zavřít). U SFTP lze zvolit ověření: heslo, soubor se
/// soukromým klíčem (s volitelným heslem ke klíči) nebo ssh-agent. Hesla se
/// ukládají jen na přání, a to do Klíčenky.
final class ConnectWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let nameField = NSTextField()
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
    private let saveSecretCheckbox = NSButton(checkboxWithTitle: "Uložit heslo do Klíčenky", target: nil, action: nil)
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Připojit", target: nil, action: nil)
    private let removeButton = NSButton()
    private let tableView = NSTableView()
    private var grid: NSGridView!
    /// Řádky mřížky skrývané podle protokolu a ověření.
    private var authRow: NSGridRow!
    private var passwordRow: NSGridRow!
    private var keyRow: NSGridRow!
    private var passphraseRow: NSGridRow!
    private var saveSecretRow: NSGridRow!
    private weak var mainController: MainWindowController?
    /// Panel, ve kterém se server otevře (nil = aktivní panel).
    private weak var targetPanel: PanelController?

    /// Uložené servery (pracovní kopie; ukládá se přes persist()).
    private var servers: [ServerProfile] = []
    /// Index serveru, jehož hodnoty jsou ve formuláři (nil = žádný).
    private var editingIndex: Int?
    /// Heslo z Klíčenky při načtení formuláře (zápis jen při změně).
    private var loadedSecret = ""
    /// Měl upravovaný server uložené heslo (při vypnutí volby se smaže)?
    private var hadStoredSecret = false

    /// Zobrazí správu serverů jako sheet nad hlavním oknem.
    /// - Parameters:
    ///   - panel: panel, ve kterém se server otevře (nil = aktivní)
    ///   - selecting: server, který se má předvybrat (nil = první)
    static func show(parent: MainWindowController, panel: PanelController? = nil, selecting: UUID? = nil) {
        // Kontroler musí žít po celou dobu sheetu (jinak tlačítka nereagují).
        let controller = ConnectWindowController(owner: parent, panel: panel, selecting: selecting)
        parent.sheetController = controller
        parent.window!.beginSheet(controller.window!) { [weak parent] _ in
            parent?.sheetController = nil
            parent?.focusActivePanel()
        }
    }

    init(owner: MainWindowController, panel: PanelController? = nil, selecting: UUID? = nil) {
        self.mainController = owner
        self.targetPanel = panel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 380),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "FTP/SFTP servery"
        super.init(window: window)
        buildLayout()
        servers = ServerStore.load()
        tableView.reloadData()
        let initial = selecting.flatMap { id in servers.firstIndex { $0.id == id } } ?? 0
        if servers.isEmpty {
            loadForm(nil)
        } else {
            select(initial)
        }
        // Fokus do seznamu (šipky vyberou server, Enter připojí); u serveru bez adresy do pole Server.
        window.initialFirstResponder = editingIndex != nil && hostField.stringValue.isEmpty ? hostField : tableView
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    // MARK: - Rozvržení

    /// Seznam serverů s tlačítky +/− vlevo, mřížka popisek + pole vpravo;
    /// řádky pro heslo/klíč se skrývají podle volby ověření.
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
        nameField.placeholderString = "uživatel@server"
        keyField.placeholderString = "~/.ssh/id_ed25519"
        keyField.lineBreakMode = .byTruncatingHead
        passphraseField.placeholderString = "jen u klíče chráněného heslem"
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        for field in [nameField, hostField, portField, userField, passField, keyField, passphraseField] {
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
        }
        // Název v seznamu se mění průběžně s poli název/server/uživatel.
        for field in [nameField, hostField, userField] {
            field.delegate = self
        }

        let kindRow = NSStackView(views: [kindFtp, kindSftp])
        kindRow.spacing = 16
        let keyStack = NSStackView(views: [keyField, keyButton])
        keyStack.spacing = 6
        keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        grid = NSGridView(views: [
            [NSTextField(labelWithString: "Název:"), nameField],
            [NSTextField(labelWithString: "Protokol:"), kindRow],
            [NSTextField(labelWithString: "Server:"), hostField],
            [NSTextField(labelWithString: "Port:"), portField],
            [NSTextField(labelWithString: "Uživatel:"), userField],
            [NSTextField(labelWithString: "Ověření:"), authPopup],
            [NSTextField(labelWithString: "Heslo:"), passField],
            [NSTextField(labelWithString: "Soubor s klíčem:"), keyStack],
            [NSTextField(labelWithString: "Heslo ke klíči:"), passphraseField],
            [NSGridCell.emptyContentView, saveSecretCheckbox],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        // Řádek mřížky podle pole v něm (nezávisí na pořadí řádků).
        func row(of view: NSView) -> NSGridRow { grid.cell(for: view)!.row! }
        authRow = row(of: authPopup)
        passwordRow = row(of: passField)
        keyRow = row(of: keyStack)
        passphraseRow = row(of: passphraseField)
        saveSecretRow = row(of: saveSecretCheckbox)
        hostField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        // Seznam serverů (jeden sloupec bez záhlaví), dvojklik = připojit.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 34
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(connectClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        column.width = 200

        let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Přidat")!,
                                 target: self, action: #selector(addClicked(_:)))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Odebrat")
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        for button in [addButton, removeButton] {
            button.bezelStyle = .smallSquare
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        }
        addButton.toolTip = "Přidat server"
        removeButton.toolTip = "Odebrat vybraný server"
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.spacing = 0

        let closeButton = NSButton(title: "Zavřít", target: self, action: #selector(closeClicked(_:)))
        closeButton.keyEquivalent = "\u{1b}"
        connectButton.target = self
        connectButton.action = #selector(connectClicked(_:))
        connectButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [closeButton, connectButton])
        buttons.spacing = 10

        let content = NSView()
        for view in [scroll, listButtons, grid!, noteLabel, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.widthAnchor.constraint(equalToConstant: 210),
            listButtons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -1),
            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: buttons.bottomAnchor),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),
            noteLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 10),
            noteLabel.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: noteLabel.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 760),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
        ])
        window?.contentView = content
    }

    // MARK: - Seznam serverů

    func numberOfRows(in tableView: NSTableView) -> Int {
        servers.count
    }

    /// Řádek seznamu: název tučně, pod ním adresa šedě.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Upravovaný server se kreslí z formuláře (název se mění při psaní).
        let server = row == editingIndex ? readForm(into: servers[row]) : servers[row]
        let text = NSMutableAttributedString(string: server.displayName,
                                             attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        text.append(NSAttributedString(string: "\n" + server.urlString,
                                       attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        let cell = NSTableCellView()
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Přepnutí serveru: uložit rozpracovaný formulář a načíst vybraný server.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row != editingIndex else { return }
        commitForm()
        loadForm(row >= 0 ? row : nil)
    }

    /// Vybere server v seznamu a načte ho do formuláře (nil = nic, formulář se zakáže).
    /// Vybere server v seznamu; formulář načte delegát výběru. Pokud se výběr
    /// nezměnil (např. po odebrání zůstal stejný index), načte se ručně.
    private func select(_ index: Int) {
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        if editingIndex != index {
            commitForm()
            loadForm(index)
        }
    }

    /// Průběžná aktualizace názvu v seznamu při psaní.
    func controlTextDidChange(_ obj: Notification) {
        refreshEditingRow()
    }

    /// Překreslí řádek upravovaného serveru podle formuláře.
    private func refreshEditingRow() {
        guard let index = editingIndex else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: - Formulář

    /// Naplní formulář hodnotami serveru (heslo z Klíčenky, je-li uložené).
    private func loadForm(_ index: Int?) {
        editingIndex = index
        let server = index.map { servers[$0] } ?? ServerProfile()
        hadStoredSecret = server.savePassword
        nameField.stringValue = server.name
        kindSftp.state = server.isSftp ? .on : .off
        kindFtp.state = server.isSftp ? .off : .on
        hostField.stringValue = server.host
        portField.stringValue = String(server.port)
        userField.stringValue = server.user
        authPopup.selectItem(at: server.auth.rawValue)
        keyField.stringValue = server.keyPath
        saveSecretCheckbox.state = server.savePassword ? .on : .off
        loadedSecret = server.savePassword ? (ServerKeychain.secret(for: server.id) ?? "") : ""
        passField.stringValue = server.effectiveAuth == .password ? loadedSecret : ""
        passphraseField.stringValue = server.effectiveAuth == .keyFile ? loadedSecret : ""
        // Bez vybraného serveru je formulář neaktivní.
        let enabled = index != nil
        for control in [nameField, kindFtp, kindSftp, hostField, portField, userField, authPopup,
                        passField, keyField, keyButton, passphraseField, saveSecretCheckbox,
                        connectButton, removeButton] as [NSControl] {
            control.isEnabled = enabled
        }
        updateVisibility()
    }

    /// Hodnoty formuláře přenesené do profilu (id zůstává).
    private func readForm(into server: ServerProfile) -> ServerProfile {
        var result = server
        result.name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        result.isSftp = kindSftp.state == .on
        result.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        result.port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces))
            ?? ServerProfile.defaultPort(sftp: result.isSftp)
        result.user = userField.stringValue.trimmingCharacters(in: .whitespaces)
        result.auth = ServerAuth(rawValue: authPopup.indexOfSelectedItem) ?? .password
        result.keyPath = keyField.stringValue.trimmingCharacters(in: .whitespaces)
        result.savePassword = saveSecretCheckbox.state == .on
        return result
    }

    /// Tajný údaj z formuláře podle ověření (heslo, nebo heslo ke klíči).
    private var formSecret: String {
        switch authMethod {
        case .password: return passField.stringValue
        case .keyFile: return passphraseField.stringValue
        case .agent: return ""
        }
    }

    /// Uloží formulář do vybraného serveru (seznam do UserDefaults jen při změně);
    /// heslo zapíše do Klíčenky (jen při změně), bez volby „Uložit heslo“ ho smaže.
    private func commitForm() {
        guard let index = editingIndex else { return }
        let server = readForm(into: servers[index])
        if server != servers[index] {
            servers[index] = server
            ServerStore.save(servers)
        }
        if server.savePassword && server.effectiveAuth != .agent {
            let secret = formSecret
            if secret != loadedSecret {
                if secret.isEmpty {
                    ServerKeychain.removeSecret(for: server.id)
                } else {
                    ServerKeychain.setSecret(secret, for: server.id)
                }
                loadedSecret = secret
            }
            hadStoredSecret = true
        } else if hadStoredSecret {
            ServerKeychain.removeSecret(for: server.id)
            loadedSecret = ""
            hadStoredSecret = false
        }
    }

    /// Zvolený způsob ověření podle formuláře (FTP vždy heslo).
    private var authMethod: ServerAuth {
        readForm(into: ServerProfile()).effectiveAuth
    }

    /// Zobrazí jen řádky, které platí pro protokol a způsob ověření; poznámka vysvětlí volbu.
    private func updateVisibility() {
        let sftp = kindSftp.state == .on
        let method = authMethod
        authRow.isHidden = !sftp
        passwordRow.isHidden = method != .password
        keyRow.isHidden = method != .keyFile
        passphraseRow.isHidden = method != .keyFile
        saveSecretRow.isHidden = method == .agent
        saveSecretCheckbox.title = method == .keyFile ? "Uložit heslo ke klíči do Klíčenky" : "Uložit heslo do Klíčenky"
        if editingIndex == nil {
            noteLabel.stringValue = servers.isEmpty
                ? "Seznam serverů je prázdný – server přidáte tlačítkem +."
                : "Vyberte server v seznamu."
            return
        }
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
        let defaultPorts = [ServerProfile.defaultPort(sftp: true), ServerProfile.defaultPort(sftp: false)].map(String.init)
        if defaultPorts.contains(portField.stringValue) || portField.stringValue.isEmpty {
            portField.stringValue = String(ServerProfile.defaultPort(sftp: sftp))
        }
        if sftp && userField.stringValue == "anonymous" {
            userField.stringValue = NSUserName()
        }
        updateVisibility()
        refreshEditingRow()
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

    // MARK: - Tlačítka

    /// Nový server (FTP, výchozí hodnoty, klíč = první běžný v ~/.ssh) na konec seznamu.
    @objc private func addClicked(_ sender: Any?) {
        var server = ServerProfile()
        server.keyPath = ConnectWindowController.defaultKeyPath() ?? ""
        servers.append(server)
        tableView.reloadData()
        // Výběr uloží rozpracovaný server, nový se uloží s prvním commitem.
        select(servers.count - 1)
        ServerStore.save(servers)
        window?.makeFirstResponder(hostField)
    }

    /// Odebrání vybraného serveru po potvrzení (smaže i heslo v Klíčence).
    @objc private func removeClicked(_ sender: Any?) {
        guard let index = editingIndex, let window else { return }
        let server = servers[index]
        let alert = NSAlert()
        alert.messageText = "Odebrat server „\(server.displayName)“?"
        alert.informativeText = "Server zmizí ze seznamu i z nabídky disků; uložené heslo se smaže z Klíčenky."
        alert.addButton(withTitle: "Odebrat")
        alert.addCancelButton()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            ServerKeychain.removeSecret(for: server.id)
            self.servers.remove(at: index)
            ServerStore.save(self.servers)
            // Upravovaný server už neexistuje – nic se z formuláře neukládá.
            self.editingIndex = nil
            self.tableView.reloadData()
            if self.servers.isEmpty {
                self.loadForm(nil)
            } else {
                self.select(min(index, self.servers.count - 1))
            }
        }
    }

    /// Zavření: rozpracované úpravy se uloží.
    @objc private func closeClicked(_ sender: Any?) {
        commitForm()
        window?.sheetParent?.endSheet(window!)
    }

    @objc private func connectClicked(_ sender: Any?) {
        guard let mainController, let index = editingIndex else { return }
        commitForm()
        let server = servers[index]
        guard !server.host.isEmpty else {
            window?.makeFirstResponder(hostField)
            NSSound.beep()
            return
        }
        // Klíč: kontrola souboru a hesla ke klíči ještě před připojením.
        if server.effectiveAuth == .keyFile {
            switch sshKeyEncrypted(path: server.expandedKeyPath) {
            case nil:
                showError("Soubor s klíčem „\(server.keyPath)“ nelze přečíst.")
                return
            case true? where formSecret.isEmpty:
                noteLabel.stringValue = "Klíč je chráněný heslem – zadejte heslo ke klíči."
                window?.makeFirstResponder(passphraseField)
                NSSound.beep()
                return
            default:
                break
            }
        }
        // Dialog se zavře, připojení s průběhem a chybami řeší hlavní okno.
        let secret = formSecret
        let panel = targetPanel ?? mainController.activePanel
        window?.sheetParent?.endSheet(window!)
        mainController.connect(server: server, secret: secret, in: panel)
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

    /// Chyba jako sheet nad dialogem (dialog zůstane otevřený k opravě).
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
    /// Kolik položek od začátku lze přesouvat (disky; servery a „FTP/SFTP servery…“ se nepřesouvají).
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
