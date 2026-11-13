// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Místa v nabídce disků (⌥F1/⌥F2) a na liště disků: systémové disky, vlastní
// adresáře uživatele a uložené FTP/SFTP servery v jednom společném pořadí,
// s možností libovolnou položku skrýt. Dialog „Upravit nabídku disků…“.

import AppKit

/// Položka nabídky disků (disk, vlastní adresář nebo server).
struct Place {
    enum Kind {
        case drive
        case folder
        case server(ServerProfile)
    }

    /// Trvalý klíč pro pořadí a skrytí („drive:/cesta“, „folder:/cesta“, „server:UUID“).
    let key: String
    let kind: Kind
    let title: String
    /// Cesta (disk, adresář) nebo adresa serveru.
    let detail: String
    let icon: NSImage?

    /// Cesta na disku (nil u serveru).
    var path: String? {
        if case .server = kind { return nil }
        return detail
    }

    /// Je položka server?
    var isServer: Bool {
        if case .server = kind { return true }
        return false
    }

    /// Je položka vlastní adresář?
    var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    // Klíče míst (jediné místo, kde se skládají prefixy).
    static func key(drive path: String) -> String { "drive:" + path }
    static func key(folder path: String) -> String { "folder:" + path }
    static func key(server id: UUID) -> String { "server:" + id.uuidString }

    /// Popis typu položky pro dialog úprav.
    var kindName: String {
        switch kind {
        case .drive: return "Disk"
        case .folder: return "Adresář"
        case .server(let server): return server.isSftp ? "SFTP" : "FTP"
        }
    }
}

/// Vlastní adresář v nabídce disků.
struct CustomFolder: Codable, Equatable {
    var path: String
    /// Název v nabídce (výchozí = jméno adresáře).
    var title: String
}

/// Pořadí, skrytí a vlastní adresáře nabídky disků (UserDefaults).
enum PlaceStore {
    /// Oznámení o změně (lišta disků se překreslí).
    static let changed = Notification.Name("MicroCommanderPlacesChanged")
    private static let orderKey = "placesOrder"
    private static let hiddenKey = "hiddenPlaces"
    private static let foldersKey = "customFolders"
    private static let shortcutsKey = "placeShortcuts"

    // MARK: Seznam míst

    /// Všechna místa v uloženém pořadí včetně skrytých.
    static func allPlaces() -> [Place] {
        ordered(naturalPlaces(), saved: savedOrder())
    }

    /// Místa zobrazená v nabídce (bez skrytých).
    static func visiblePlaces() -> [Place] {
        let hidden = hiddenKeys
        return allPlaces().filter { !hidden.contains($0.key) }
    }

    /// Seřadí místa podle uložených klíčů; místa, která v uloženém pořadí
    /// nejsou (nový svazek, nový server, nový adresář), přijdou na konec
    /// v přirozeném pořadí. Neexistující uložené klíče se přeskočí.
    static func ordered(_ natural: [Place], saved: [String]) -> [Place] {
        var byKey: [String: Place] = [:]
        for place in natural where byKey[place.key] == nil {
            byKey[place.key] = place
        }
        var result = saved.compactMap { byKey.removeValue(forKey: $0) }
        result += natural.filter { byKey.removeValue(forKey: $0.key) != nil }
        return result
    }

    /// Uložené pořadí klíčů; bez něj Domů a „/“ první.
    private static func savedOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: orderKey)
            ?? [NSHomeDirectory(), "/"].map(Place.key(drive:))
    }

    /// Místa v přirozeném pořadí: kořen, domov, svazky, vlastní adresáře, servery.
    private static func naturalPlaces() -> [Place] {
        func icon(_ path: String) -> NSImage {
            let image = NSWorkspace.shared.icon(forFile: path)
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        var result = [
            Place(key: Place.key(drive: "/"), kind: .drive, title: "/", detail: "/", icon: icon("/")),
            Place(key: Place.key(drive: NSHomeDirectory()), kind: .drive, title: "Domů", detail: NSHomeDirectory(),
                  icon: icon(NSHomeDirectory())),
        ]
        // Svazky kromě systémového (ten je už jako "/").
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.volumeIsRootFileSystem == true { continue }
            result.append(Place(key: Place.key(drive: url.path), kind: .drive, title: values?.volumeName ?? url.lastPathComponent,
                                detail: url.path, icon: icon(url.path)))
        }
        // Vlastní adresáře (i neexistující – ikona obecné složky jako v panelu).
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        folderIcon.size = NSSize(width: 16, height: 16)
        for folder in customFolders() {
            let exists = FileManager.default.fileExists(atPath: folder.path)
            result.append(Place(key: Place.key(folder: folder.path), kind: .folder, title: folder.title, detail: folder.path,
                                icon: exists ? icon(folder.path) : folderIcon))
        }
        let serverIcon = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
        for server in ServerStore.load() {
            result.append(Place(key: Place.key(server: server.id), kind: .server(server), title: server.displayName,
                                detail: server.urlString, icon: serverIcon))
        }
        return result
    }

    // MARK: Pořadí

    /// Uloží pořadí klíčů a oznámí změnu.
    private static func saveOrder(_ keys: [String]) {
        UserDefaults.standard.set(keys, forKey: orderKey)
        notify()
    }

    /// Prohodí dvě místa v celkovém pořadí (skrytá místa mezi nimi zůstanou).
    static func swap(_ first: String, _ second: String) {
        var keys = allPlaces().map(\.key)
        guard let a = keys.firstIndex(of: first), let b = keys.firstIndex(of: second) else { return }
        keys.swapAt(a, b)
        saveOrder(keys)
    }

    /// Přesune místo na první pozici.
    static func moveToFront(_ key: String) {
        move(key, before: allPlaces().first?.key)
    }

    /// Přesune místo před jiné místo (nil = na konec) – přetažení myší.
    static func move(_ key: String, before target: String?) {
        var keys = allPlaces().map(\.key)
        guard key != target, let index = keys.firstIndex(of: key) else { return }
        keys.remove(at: index)
        let insertAt = target.flatMap { keys.firstIndex(of: $0) } ?? keys.count
        keys.insert(key, at: insertAt)
        saveOrder(keys)
    }

    // MARK: Klávesové zkratky

    /// Zkratky míst: klíč místa → číslice 0–9 (⌘0–⌘9).
    static var shortcuts: [String: Int] {
        (UserDefaults.standard.dictionary(forKey: shortcutsKey) as? [String: Int]) ?? [:]
    }

    /// Nastaví (nil = zruší) zkratku místa; stejnou číslici ostatním místům odebere.
    /// Bez oznámení – lišta disků zkratky neukazuje, nabídka je čte při otevření.
    static func setShortcut(_ key: String, digit: Int?) {
        var map = shortcuts.filter { $0.key != key && $0.value != digit }
        if let digit { map[key] = digit }
        UserDefaults.standard.set(map, forKey: shortcutsKey)
    }

    /// Místo se zkratkou ⌘<číslice> (i skryté); nil = žádné.
    static func place(forShortcut digit: Int) -> Place? {
        guard let key = shortcuts.first(where: { $0.value == digit })?.key else { return nil }
        return allPlaces().first { $0.key == key }
    }

    /// Text zkratky pro zobrazení („⌘3“).
    static func shortcutLabel(_ digit: Int) -> String {
        "⌘\(digit)"
    }

    // MARK: Skrytí

    /// Klíče skrytých míst.
    static var hiddenKeys: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
    }

    /// Skryje nebo zobrazí místo.
    static func setHidden(_ key: String, _ hidden: Bool) {
        var keys = hiddenKeys
        if hidden { keys.insert(key) } else { keys.remove(key) }
        UserDefaults.standard.set(keys.sorted(), forKey: hiddenKey)
        notify()
    }

    // MARK: Vlastní adresáře

    /// Vlastní adresáře v pořadí přidání.
    private static func customFolders() -> [CustomFolder] {
        guard let data = UserDefaults.standard.data(forKey: foldersKey) else { return [] }
        return (try? JSONDecoder().decode([CustomFolder].self, from: data)) ?? []
    }

    private static func saveFolders(_ folders: [CustomFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: foldersKey)
        notify()
    }

    /// Přidá adresáře (už přidané se přeskočí); název = jméno adresáře.
    static func addFolders(_ paths: [String]) {
        var folders = customFolders()
        for path in paths where !folders.contains(where: { $0.path == path }) {
            let name = (path as NSString).lastPathComponent
            folders.append(CustomFolder(path: path, title: name.isEmpty ? path : name))
        }
        saveFolders(folders)
    }

    /// Odebere vlastní adresář (i jeho příznak skrytí a zkratku ⌘0–⌘9, aby
    /// číslice nezůstala obsazená místem, které už neexistuje).
    static func removeFolder(path: String) {
        let key = Place.key(folder: path)
        if hiddenKeys.contains(key) {
            setHidden(key, false)
        }
        if shortcuts[key] != nil {
            setShortcut(key, digit: nil)
        }
        saveFolders(customFolders().filter { $0.path != path })
    }

    /// Přejmenuje vlastní adresář; prázdný název = jméno adresáře.
    static func renameFolder(path: String, title: String) {
        var folders = customFolders()
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        folders[index].title = trimmed.isEmpty ? (path as NSString).lastPathComponent : trimmed
        saveFolders(folders)
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Dialog „Upravit nabídku disků“: všechna místa v pořadí nabídky, zaškrtnutí =
/// zobrazit, přidání/odebrání a přejmenování vlastních adresářů, posun nahoru/dolů.
/// Změny se ukládají hned.
final class PlacesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "Odebrat", target: nil, action: nil)
    private let upButton = NSButton()
    private let downButton = NSButton()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private var places: [Place] = []
    private var hidden: Set<String> = []
    private var shortcuts: [String: Int] = [:]

    /// Typ dat při přetahování řádku (index řádku jako text).
    private static let rowType = NSPasteboard.PasteboardType("com.github.svopex.microcommander.place-row")
    private static let showColumn = NSUserInterfaceItemIdentifier("show")
    private static let titleColumn = NSUserInterfaceItemIdentifier("title")
    private static let shortcutColumn = NSUserInterfaceItemIdentifier("shortcut")
    private static let detailColumn = NSUserInterfaceItemIdentifier("detail")

    /// Zobrazí dialog jako sheet nad hlavním oknem.
    static func show(parent: MainWindowController) {
        parent.presentSheet(PlacesWindowController())
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Upravit nabídku disků"
        super.init(window: window)
        buildLayout()
        reload(selecting: 0)
        window.initialFirstResponder = tableView
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    // MARK: Rozvržení

    /// Tabulka (Zobrazit / Název / Typ a cesta), pod ní tlačítka.
    private func buildLayout() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (PlacesWindowController.showColumn, "Zobrazit", 64),
            (PlacesWindowController.titleColumn, "Název", 210),
            (PlacesWindowController.shortcutColumn, "Zkratka", 86),
            (PlacesWindowController.detailColumn, "Typ a cesta / adresa", 350),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.rowHeight = 22
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        // Poslední sloupec vyplní zbytek šířky (nepřetéká mimo viditelnou oblast,
        // dlouhá cesta se zkrátí „…“ místo oříznutí okrajem).
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        // Přetahování řádků myší mění pořadí (vkládání mezi řádky).
        tableView.registerForDraggedTypes([PlacesWindowController.rowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let addButton = NSButton(title: "Přidat adresář…", target: self, action: #selector(addClicked(_:)))
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        let arrows: [(NSButton, String, Selector, String)] = [
            (upButton, "chevron.up", #selector(upClicked(_:)), "Posunout nahoru"),
            (downButton, "chevron.down", #selector(downClicked(_:)), "Posunout dolů"),
        ]
        for (button, symbol, action, tip) in arrows {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        for button in [addButton, removeButton, upButton, downButton] {
            button.bezelStyle = .rounded
        }
        let closeButton = NSButton(title: "Zavřít", target: self, action: #selector(closeClicked(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [addButton, removeButton, upButton, downButton, spacer, closeButton])
        buttons.spacing = 8
        noteLabel.font = NSFont.systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.stringValue = "Odškrtnutá místa se v nabídce disků (⌥F1/⌥F2) a na liště disků nezobrazí. "
            + "Pořadí změníte přetažením myší nebo šipkami. Zkratka ⌘0–⌘9 otevře místo v aktivním panelu. "
            + "Název vlastního adresáře změníte dvojklikem. Servery se přidávají a odebírají ve správě FTP/SFTP serverů (F11)."

        let content = NSView()
        for view in [scroll, noteLabel, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            noteLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            noteLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            noteLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 780),
            content.heightAnchor.constraint(equalToConstant: 440),
        ])
        window?.contentView = content
    }

    /// Znovu načte místa a vybere místo podle klíče (nil = beze změny výběru).
    private func reload(selectingKey key: String?) {
        reload(selecting: nil)
        if let key, let row = places.firstIndex(where: { $0.key == key }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    /// Znovu načte místa a skrytí z úložiště a vybere řádek.
    private func reload(selecting row: Int?) {
        places = PlaceStore.allPlaces()
        hidden = PlaceStore.hiddenKeys
        shortcuts = PlaceStore.shortcuts
        tableView.reloadData()
        if let row, !places.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: max(0, min(row, places.count - 1))), byExtendingSelection: false)
            tableView.scrollRowToVisible(tableView.selectedRow)
        }
        updateButtons()
    }

    /// Odebrat jde jen vlastní adresář; posun podle pozice.
    private func updateButtons() {
        let row = tableView.selectedRow
        let valid = row >= 0 && row < places.count
        removeButton.isEnabled = valid && places[row].isFolder
        upButton.isEnabled = valid && row > 0
        downButton.isEnabled = valid && row < places.count - 1
    }

    // MARK: Tabulka

    func numberOfRows(in tableView: NSTableView) -> Int {
        places.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let place = places[row]
        switch tableColumn?.identifier {
        case PlacesWindowController.showColumn?:
            // Zaškrtávátko zobrazení (tag = řádek).
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(visibilityToggled(_:)))
            checkbox.state = hidden.contains(place.key) ? .off : .on
            checkbox.tag = row
            return centered(checkbox)
        case PlacesWindowController.shortcutColumn?:
            // Nabídka zkratky: žádná nebo ⌘0–⌘9 (tag = řádek).
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            popup.addItem(withTitle: "—")
            popup.addItems(withTitles: (0...9).map(PlaceStore.shortcutLabel))
            if let digit = shortcuts[place.key] {
                popup.selectItem(at: digit + 1)
            }
            popup.target = self
            popup.action = #selector(shortcutChanged(_:))
            popup.tag = row
            return centered(popup)
        case PlacesWindowController.titleColumn?:
            // Ikona + název; u vlastního adresáře upravitelný.
            let cell = NSTableCellView()
            let image = NSImageView(image: place.icon ?? NSImage())
            let field = NSTextField(string: place.title)
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingTail
            if place.isFolder {
                field.isEditable = true
                field.delegate = self
                field.tag = row
            } else {
                field.isEditable = false
                field.isSelectable = false
            }
            for view in [image, field] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(view)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        default:
            // Typ položky a cesta / adresa (šedě).
            let text = NSMutableAttributedString(string: place.kindName + "   ",
                                                 attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            text.append(NSAttributedString(string: place.detail,
                                           attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            // Vždy jeden řádek – dlouhá cesta se zkrátí uprostřed, nezalomí.
            let label = NSTextField(labelWithAttributedString: text.truncatingMiddle())
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.toolTip = place.detail
            return centered(label)
        }
    }

    /// Obal pohledu svisle vycentrovaný v buňce.
    private func centered(_ view: NSView) -> NSView {
        let cell = NSTableCellView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            view.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: Přetahování

    /// Zdroj přetažení: index řádku.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: PlacesWindowController.rowType)
        return item
    }

    /// Cíl přetažení: jen mezi řádky (ne na řádek), jen z této tabulky.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === tableView else { return [] }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    /// Puštění: místo se přesune před řádek pod kurzorem (za poslední = na konec).
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let text = info.draggingPasteboard.string(forType: PlacesWindowController.rowType),
              let source = Int(text), source < places.count else { return false }
        let key = places[source].key
        PlaceStore.move(key, before: row < places.count ? places[row].key : nil)
        reload(selectingKey: key)
        return true
    }

    /// Dokončená úprava názvu vlastního adresáře.
    func controlTextDidEndEditing(_ obj: Notification) {
        // Bez změny názvu (Tab, ztráta fokusu) se nic neukládá.
        guard let field = obj.object as? NSTextField, field.tag < places.count,
              let path = places[field.tag].path, field.stringValue != places[field.tag].title else { return }
        PlaceStore.renameFolder(path: path, title: field.stringValue)
        reload(selecting: field.tag)
    }

    // MARK: Akce

    @objc private func visibilityToggled(_ sender: NSButton) {
        guard sender.tag < places.count else { return }
        let key = places[sender.tag].key
        PlaceStore.setHidden(key, sender.state == .off)
        if sender.state == .off { hidden.insert(key) } else { hidden.remove(key) }
    }

    /// Změna zkratky; stejná zkratka se jinému místu odebere (překreslí se tabulka).
    @objc private func shortcutChanged(_ sender: NSPopUpButton) {
        guard sender.tag < places.count else { return }
        let index = sender.indexOfSelectedItem
        PlaceStore.setShortcut(places[sender.tag].key, digit: index > 0 ? index - 1 : nil)
        // Mění se jen sloupec zkratek (jinému místu mohla zkratka zmizet).
        shortcuts = PlaceStore.shortcuts
        if let column = tableView.tableColumns.firstIndex(where: { $0.identifier == PlacesWindowController.shortcutColumn }) {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<places.count), columnIndexes: IndexSet(integer: column))
        }
    }

    /// Výběr adresářů (i více najednou) a jejich přidání na konec nabídky.
    @objc private func addClicked(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Přidat adresáře do nabídky disků"
        panel.prompt = "Přidat"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            PlaceStore.addFolders(panel.urls.map(\.path))
            // Výběr na první z přidaných adresářů.
            let key = panel.urls.first.map { Place.key(folder: $0.path) }
            self.reload(selectingKey: key)
        }
    }

    @objc private func removeClicked(_ sender: Any?) {
        let row = tableView.selectedRow
        guard row >= 0, row < places.count, places[row].isFolder, let path = places[row].path else { return }
        PlaceStore.removeFolder(path: path)
        reload(selecting: row)
    }

    @objc private func upClicked(_ sender: Any?) {
        move(by: -1)
    }

    @objc private func downClicked(_ sender: Any?) {
        move(by: 1)
    }

    /// Posun vybraného místa o krok (výběr jde s ním).
    private func move(by delta: Int) {
        let row = tableView.selectedRow
        let target = row + delta
        guard row >= 0, target >= 0, target < places.count else { return }
        PlaceStore.swap(places[row].key, places[target].key)
        reload(selecting: target)
    }

    @objc private func closeClicked(_ sender: Any?) {
        window?.sheetParent?.endSheet(window!)
    }
}
