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
    case driveLeft, driveRight, editPlaces, pack, unpack, find, calcSize
    case back, forward, up, root, home, swap, sameDir, sameDirOther, toggleHidden, copyDirPath
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
    /// Šířka svislé lišty (mění ji setCollapsed).
    private var widthConstraint: NSLayoutConstraint?
    /// Šířka svislé lišty s ikonami a sbalené (jen dělicí pruh).
    private static let verticalWidth: CGFloat = 30
    private static let collapsedWidth: CGFloat = 5

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
            let width = widthAnchor.constraint(equalToConstant: CommandBar.verticalWidth)
            widthConstraint = width
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                width,
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

    /// Sbalí svislou lištu na úzký dělicí pruh bez ikon (nebo ji obnoví).
    func setCollapsed(_ collapsed: Bool) {
        stack.isHidden = collapsed
        widthConstraint?.constant = collapsed ? CommandBar.collapsedWidth : CommandBar.verticalWidth
    }

    /// Změní ikonu tlačítka příkazu (např. oko / přeškrtnuté oko u skrytých souborů).
    func setSymbol(_ symbol: String, for command: Command) {
        guard let index = commands.firstIndex(of: command) else { return }
        let button = stack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.tag == index }
        button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

/// Lišta disků: místa z nabídky disků kromě serverů (disky, vlastní adresáře)
/// v jejím pořadí a bez skrytých, na konci tlačítko FTP/SFTP serverů.
final class DriveBar: NSView {
    private let stack = NSStackView()
    /// Místa na liště (index = tag tlačítka).
    private(set) var places: [Place] = []
    var onPlace: ((Place) -> Void)?
    var onConnect: (() -> Void)?
    /// Otevření dialogu „Upravit nabídku disků“ (kontextové menu).
    var onEditPlaces: (() -> Void)?

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
        // Připojení/odpojení svazku a změna nabídky disků lištu obnoví.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(placesChanged(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(placesChanged(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(placesChanged(_:)),
                                               name: PlaceStore.changed, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    @objc private func placesChanged(_ notification: Notification) {
        refresh()
    }

    /// Načte zobrazená místa (bez serverů) a znovu sestaví tlačítka.
    func refresh() {
        places = PlaceStore.visiblePlaces().filter { !$0.isServer }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, place) in places.enumerated() {
            let button = NSButton(title: place.title, image: place.icon ?? NSImage(), target: self, action: #selector(placeClicked(_:)))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imagePosition = .imageLeading
            button.font = NSFont.systemFont(ofSize: 11)
            button.tag = index
            button.toolTip = place.detail + " – pravým tlačítkem změníte pořadí nebo položku skryjete"
            button.menu = contextMenu(for: index)
            stack.addArrangedSubview(button)
        }
        let ftp = NSButton(title: "FTP/SFTP", image: NSImage(systemSymbolName: "network", accessibilityDescription: nil) ?? NSImage(),
                           target: self, action: #selector(connectClicked(_:)))
        ftp.bezelStyle = .texturedRounded
        ftp.isBordered = false
        ftp.imagePosition = .imageLeading
        ftp.font = NSFont.systemFont(ofSize: 11)
        ftp.toolTip = "FTP/SFTP servery – přidat, upravit, připojit (F11)"
        stack.addArrangedSubview(ftp)
    }

    /// Kontextové menu tlačítka: změna pořadí, skrytí, úprava nabídky disků.
    private func contextMenu(for index: Int) -> NSMenu {
        let menu = NSMenu()
        let front = NSMenuItem(title: "Na první místo", action: #selector(moveToFrontSelected(_:)), keyEquivalent: "")
        front.target = self
        front.tag = index
        front.isEnabled = index > 0
        menu.addItem(front)
        for (title, target) in [("Posunout doleva", index - 1), ("Posunout doprava", index + 1)] {
            let item = NSMenuItem(title: title, action: #selector(swapSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [index, target]
            item.isEnabled = target >= 0 && target < places.count
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Skrýt", action: #selector(hideSelected(_:)), keyEquivalent: "")
        hide.target = self
        hide.tag = index
        menu.addItem(hide)
        let edit = NSMenuItem(title: "Upravit nabídku disků…", action: #selector(editSelected(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        menu.autoenablesItems = false
        return menu
    }

    @objc private func moveToFrontSelected(_ sender: NSMenuItem) {
        PlaceStore.moveToFront(places[sender.tag].key)
    }

    /// Posun na liště = prohození se sousedním tlačítkem v celkovém pořadí míst.
    @objc private func swapSelected(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        PlaceStore.swap(places[pair[0]].key, places[pair[1]].key)
    }

    @objc private func hideSelected(_ sender: NSMenuItem) {
        PlaceStore.setHidden(places[sender.tag].key, true)
    }

    @objc private func editSelected(_ sender: Any?) {
        onEditPlaces?()
    }

    @objc private func placeClicked(_ sender: NSButton) {
        onPlace?(places[sender.tag])
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

    /// Vloží text na konec příkazové řádky (⌃↩ vkládá jméno položky).
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
