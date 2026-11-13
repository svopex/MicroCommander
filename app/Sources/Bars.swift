// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Lišty hlavního okna podle Salamandera: horní nástrojová lišta, lišta disků,
// prostřední lišta mezi panely, příkazová řádka a spodní lišta F-kláves
// (popisky se mění podle držených modifikátorů Shift/Ctrl/Alt).

import AppKit

/// Příkazy aplikace – sdílené menu, lištami i klávesami.
/// CaseIterable: tag položky menu = index v `Command.allCases`.
enum Command: CaseIterable {
    case help, rename, view, edit, newFile, copy, move, mkdir, changeDir, delete
    case terminal, quit, connect, disconnect
    case sortName, sortExt, sortTime, sortSize, refresh, compare
    case driveLeft, driveRight, pack, unpack, find, calcSize
    case back, forward, up, root, home, swap, sameDir, sameDirOther, toggleHidden
    case selectMask, unselectMask, invertMarks, selectAll, unselectAll
    case viewMenu, viewBrief, viewDetailed, viewIcons, viewThumbnails, viewTiles, viewTypes

    /// Režim zobrazení, který příkaz nastavuje (nil = příkaz není volba režimu).
    var viewMode: ViewMode? {
        switch self {
        case .viewBrief: return .brief
        case .viewDetailed: return .detailed
        case .viewIcons: return .icons
        case .viewThumbnails: return .thumbnails
        case .viewTiles: return .tiles
        case .viewTypes: return .types
        default: return nil
        }
    }
}

/// Tlačítko lišty s ikonou SF Symbol a tooltipem.
private func makeToolButton(symbol: String, tip: String, target: AnyObject, action: Selector, tag: Int) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
    let button = NSButton(image: image, target: target, action: action)
    button.bezelStyle = .texturedRounded
    button.isBordered = false
    button.toolTip = tip
    button.tag = tag
    button.imageScaling = .scaleProportionallyDown
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 26).isActive = true
    button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return button
}

/// Svislý/vodorovný oddělovač v liště.
private func makeSeparator(vertical: Bool) -> NSView {
    let box = NSBox()
    box.boxType = .separator
    box.translatesAutoresizingMaskIntoConstraints = false
    if vertical {
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
    } else {
        box.widthAnchor.constraint(equalToConstant: 18).isActive = true
    }
    return box
}

/// Lišta s tlačítky příkazů (horní vodorovná nebo prostřední svislá).
final class CommandBar: NSView {
    /// Položka lišty: příkaz s ikonou a popisem, nil = oddělovač.
    typealias Entry = (command: Command, symbol: String, tip: String)?

    private let stack = NSStackView()
    private var commands: [Command] = []
    var onCommand: ((Command) -> Void)?

    init(entries: [Entry], vertical: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = 1
        stack.alignment = vertical ? .centerX : .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Tlačítka v pořadí; tag = index do pole příkazů.
        for entry in entries {
            if let entry {
                let button = makeToolButton(symbol: entry.symbol, tip: entry.tip, target: self,
                                            action: #selector(buttonClicked(_:)), tag: commands.count)
                commands.append(entry.command)
                stack.addArrangedSubview(button)
            } else {
                stack.addArrangedSubview(makeSeparator(vertical: !vertical))
            }
        }
        addSubview(stack)
        if vertical {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                widthAnchor.constraint(equalToConstant: 30),
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(equalToConstant: 28),
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        onCommand?(commands[sender.tag])
    }

    /// Změní ikonu tlačítka příkazu (např. oko / přeškrtnuté oko u skrytých souborů).
    func setSymbol(_ symbol: String, for command: Command) {
        guard let index = commands.firstIndex(of: command) else { return }
        let button = stack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.tag == index }
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

/// Lišta disků: kořen, domov, připojené svazky a FTP.
final class DriveBar: NSView {
    /// Svazek na liště (název, cesta, ikona).
    struct Drive {
        let title: String
        let path: String
        let icon: NSImage
    }

    private let stack = NSStackView()
    private(set) var drives: [Drive] = []
    var onDrive: ((Drive) -> Void)?
    var onConnect: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        refresh()
        // Připojení/odpojení svazku lištu obnoví.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(volumesChanged(_:)),
                                               name: DriveBar.orderChanged, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    @objc private func volumesChanged(_ notification: Notification) {
        refresh()
    }

    /// Načte seznam svazků a znovu sestaví tlačítka.
    func refresh() {
        drives = DriveBar.listDrives()
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, drive) in drives.enumerated() {
            let button = NSButton(title: drive.title, image: drive.icon, target: self, action: #selector(driveClicked(_:)))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.font = NSFont.systemFont(ofSize: 11)
            button.tag = index
            button.toolTip = drive.path + " – pravým tlačítkem změníte pořadí"
            button.menu = reorderMenu(for: index)
            stack.addArrangedSubview(button)
        }
        let ftp = NSButton(title: "FTP/SFTP", image: NSImage(systemSymbolName: "network", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(connectClicked(_:)))
        ftp.bezelStyle = .texturedRounded
        ftp.isBordered = false
        ftp.imagePosition = .imageLeading
        ftp.font = NSFont.systemFont(ofSize: 11)
        ftp.toolTip = "Připojit FTP/SFTP (F11)"
        stack.addArrangedSubview(ftp)
    }

    /// Klíč uloženého pořadí disků (pole cest) v UserDefaults.
    private static let orderKey = "driveOrder"
    /// Oznámení o změně pořadí (lišta disků se překreslí).
    static let orderChanged = Notification.Name("MicroCommanderDriveOrderChanged")

    /// Disky v pořadí uživatele: uložené cesty první, nové svazky na konec.
    /// Výchozí pořadí (nic uloženo): Domů, kořen „/“, svazky.
    static func listDrives() -> [Drive] {
        let natural = naturalDrives()
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? [NSHomeDirectory(), "/"]
        var ordered: [Drive] = saved.compactMap { path in natural.first { $0.path == path } }
        ordered += natural.filter { drive in !ordered.contains { $0.path == drive.path } }
        return ordered
    }

    /// Uloží pořadí disků (cesty) a oznámí změnu.
    static func saveOrder(_ paths: [String]) {
        UserDefaults.standard.set(paths, forKey: orderKey)
        NotificationCenter.default.post(name: orderChanged, object: nil)
    }

    /// Přesune disk v uloženém pořadí z indexu `from` na `to`.
    static func moveDrive(from: Int, to: Int) {
        var paths = listDrives().map(\.path)
        guard from >= 0, from < paths.count, to >= 0, to < paths.count, from != to else { return }
        let path = paths.remove(at: from)
        paths.insert(path, at: to)
        saveOrder(paths)
    }

    /// Kořen disku, domovský adresář a připojené svazky (/Volumes) v systémovém pořadí.
    private static func naturalDrives() -> [Drive] {
        func icon(_ path: String) -> NSImage {
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        var result = [
            Drive(title: "/", path: "/", icon: icon("/")),
            Drive(title: "Domů", path: NSHomeDirectory(), icon: icon(NSHomeDirectory())),
        ]
        // Svazky kromě systémového (ten je už jako "/").
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsRootFileSystem == true { continue }
            result.append(Drive(title: values?.volumeName ?? url.lastPathComponent, path: url.path, icon: icon(url.path)))
        }
        return result
    }

    /// Kontextové menu tlačítka disku: změna pořadí.
    private func reorderMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Int)] = [("Na první místo", 0), ("Posunout doleva", index - 1), ("Posunout doprava", index + 1)]
        for (title, target) in entries {
            let item = NSMenuItem(title: title, action: #selector(reorderSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [index, target]
            item.isEnabled = target >= 0 && target < drives.count && target != index
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc private func reorderSelected(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        DriveBar.moveDrive(from: pair[0], to: pair[1])
    }

    @objc private func driveClicked(_ sender: NSButton) {
        onDrive?(drives[sender.tag])
    }

    @objc private func connectClicked(_ sender: Any?) {
        onConnect?()
    }
}

/// Příkazová řádka: „cesta>“ + vstup; Enter spustí příkaz v adresáři panelu.
final class CommandLineView: NSView, NSTextFieldDelegate {
    private let promptLabel = NSTextField(labelWithString: "")
    let field = NSTextField()
    private var history: [String] = []
    private var historyIndex = 0

    var onExecute: ((String) -> Void)?
    var onLeave: (() -> Void)?
    /// Předání klávesy panelu (navigace při prázdné příkazové řádce).
    var onForwardKey: ((NSEvent) -> Void)?

    /// Prompt (aktuální adresář aktivního panelu).
    var prompt: String = "" {
        didSet { promptLabel.stringValue = prompt + ">" }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        promptLabel.lineBreakMode = .byTruncatingHead
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setContentHuggingPriority(.required, for: .horizontal)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.focusRingType = .none
        field.bezelStyle = .squareBezel
        field.placeholderString = "příkazová řádka (⌃Tab) – Enter spustí příkaz v adresáři panelu, cd změní adresář"
        for view in [promptLabel, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            promptLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            promptLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.45),
            field.leadingAnchor.constraint(equalTo: promptLabel.trailingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Vloží text na konec příkazové řádky (⌘↩ vkládá jméno položky).
    func insert(_ text: String) {
        let current = field.stringValue
        let separator = current.isEmpty || current.hasSuffix(" ") ? "" : " "
        field.stringValue = current + separator + text
    }

    /// Enter spustí, Escape vymaže a vrátí se do panelu, šipky listují historií.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Prázdná řádka: Home/End/PgUp/PgDn ovládají panel (jako v Salamanderu).
        let navigation: Set<Selector> = [
            #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
            #selector(NSResponder.scrollToBeginningOfDocument(_:)), #selector(NSResponder.scrollToEndOfDocument(_:)),
            #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.scrollPageDown(_:)),
            #selector(NSResponder.pageUp(_:)), #selector(NSResponder.pageDown(_:)),
        ]
        if field.stringValue.isEmpty, navigation.contains(commandSelector),
           let event = NSApp.currentEvent, event.type == .keyDown {
            onForwardKey?(event)
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let command = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else {
                onLeave?()
                return true
            }
            history.append(command)
            historyIndex = history.count
            field.stringValue = ""
            onExecute?(command)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = ""
            onLeave?()
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !history.isEmpty else { return true }
            historyIndex = max(0, historyIndex - 1)
            field.stringValue = history[historyIndex]
            return true
        case #selector(NSResponder.moveDown(_:)):
            guard !history.isEmpty else { return true }
            historyIndex = min(history.count, historyIndex + 1)
            field.stringValue = historyIndex < history.count ? history[historyIndex] : ""
            return true
        default:
            return false
        }
    }
}

/// Spodní lišta F-kláves; popisky odpovídají drženým modifikátorům.
final class FunctionKeyBar: NSView {
    /// Sada modifikátorů lišty (jako Salamander: žádný, Shift, Ctrl, Alt).
    enum Layer {
        case plain, shift, control, option
    }

    /// Popisky a příkazy pro F1–F12 v jednotlivých vrstvách.
    static let layers: [Layer: [(String, Command?)]] = [
        .plain: [("Nápověda", .help), ("Přejmen.", .rename), ("Zobrazit", .view), ("Upravit", .edit),
                 ("Kopírovat", .copy), ("Přesunout", .move), ("Nový adr.", .mkdir), ("Smazat", .delete),
                 ("Terminál", .terminal), ("Ukončit", .quit), ("Připojit", .connect), ("Odpojit", .disconnect)],
        .shift: [("", nil), ("", nil), ("", nil), ("Nový soub.", .newFile),
                 ("", nil), ("Přejmen.", .rename), ("Změnit adr.", .changeDir), ("Smazat", .delete),
                 ("", nil), ("", nil), ("", nil), ("", nil)],
        .control: [("", nil), ("", nil), ("Jméno", .sortName), ("Přípona", .sortExt),
                   ("Čas", .sortTime), ("Velikost", .sortSize), ("", nil), ("", nil),
                   ("Obnovit", .refresh), ("Porovnat", .compare), ("", nil), ("", nil)],
        .option: [("Levý disk", .driveLeft), ("Pravý disk", .driveRight), ("Zobrazit", .view), ("Ukončit", .quit),
                  ("Zabalit", .pack), ("Rozbalit", .unpack), ("Hledat", .find), ("", nil),
                  ("Rozbalit", .unpack), ("Velikost", .calcSize), ("", nil), ("", nil)],
    ]

    private var buttons: [FunctionKeyButton] = []
    private(set) var currentLayer: Layer = .plain
    var onCommand: ((Command) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        for index in 0..<12 {
            let button = FunctionKeyButton(number: index + 1)
            button.onClick = { [weak self] in self?.keyClicked(index) }
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setLayer(.plain)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Přepne popisky podle modifikátorů (volá monitor flagsChanged).
    func update(modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection([.shift, .control, .option, .command])
        if flags == .shift {
            setLayer(.shift)
        } else if flags == .control || flags == .command {
            setLayer(.control)
        } else if flags == .option {
            setLayer(.option)
        } else {
            setLayer(.plain)
        }
    }

    private func setLayer(_ newLayer: Layer) {
        currentLayer = newLayer
        let entries = FunctionKeyBar.layers[newLayer] ?? []
        for (index, button) in buttons.enumerated() {
            let title = index < entries.count ? entries[index].0 : ""
            button.title = title
            button.isEnabled = index < entries.count && entries[index].1 != nil
        }
    }

    private func keyClicked(_ index: Int) {
        guard let entries = FunctionKeyBar.layers[currentLayer], index < entries.count,
              let command = entries[index].1 else { return }
        onCommand?(command)
    }
}

/// Ploché tlačítko lišty F-kláves: tučné číslo klávesy + popisek (jako Salamander).
final class FunctionKeyButton: NSView {
    private let number: Int
    var onClick: (() -> Void)?
    var title = "" {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }
    /// Stisknuté tlačítko (během držení myši).
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Rámeček, výplň a text; nepoužitá klávesa má jen šedé číslo.
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        // Neprůhledné barvy (controlColor je v tmavém režimu poloprůhledná a splývá s textem).
        (pressed ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let textColor: NSColor = pressed ? .white : (isEnabled ? .labelColor : .tertiaryLabelColor)
        let text = NSMutableAttributedString(string: "F\(number) ",
                                             attributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: textColor])
        text.append(NSAttributedString(string: title,
                                       attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: textColor]))
        let size = text.size()
        text.draw(at: NSPoint(x: 5, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
    }

    /// Klik platí, jen když se myš pustí nad tlačítkem.
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }
}
