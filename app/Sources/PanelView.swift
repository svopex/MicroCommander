// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vizuál panelu ve stylu Salamandera: řádek adresáře (Directory Line)
// s tlačítkem disku a volným místem, tabulka (Jméno/Přípona/Velikost/
// Datum/Čas/Atr) s kurzorem odděleným od označení a informační řádek.

import AppKit
import UniformTypeIdentifiers

/// Obsluha kláves a myši tabulky – implementuje hlavní okno.
protocol PanelInputHandler: AnyObject {
    /// Stisk klávesy v tabulce panelu; true = zpracováno.
    func panelView(_ view: PanelView, keyDown event: NSEvent) -> Bool
    /// Otevření položky (dvojklik).
    func panelView(_ view: PanelView, openRow row: Int)
    /// Kontextové menu pro řádek.
    func panelView(_ view: PanelView, menuForRow row: Int) -> NSMenu?
    /// Menu disků (tlačítko na řádku adresáře).
    func panelViewShowDriveChooser(_ view: PanelView, anchor: NSView)
    /// Příkaz vyvolaný z pohledu panelu (např. ⌘A přes Označit › Označit vše).
    func panelView(_ view: PanelView, perform command: Command)
    /// Soubory přetažené do panelu z jiné aplikace (cesty na lokálním disku);
    /// move = přesunout místo kopírování.
    func panelView(_ view: PanelView, dropFiles paths: [String], move: Bool)
}

/// Celý panel: řádek adresáře + tabulka + informační řádek.
final class PanelView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let panel: PanelController
    let tableView = SalTableView()
    /// Mřížka pro režimy Stručný / Ikony / Miniatury / Dlaždice.
    let gridView = FileGridView()
    let scrollView = NSScrollView()
    let directoryLine = DirectoryLineView()
    let infoLine = InfoLineView()
    weak var inputHandler: PanelInputHandler?
    /// Co nese tažení probíhající nad panelem (soubory na disku / přislíbené
    /// soubory); zjišťuje se jednou při vstupu tažení, ne při každém pohybu myši.
    private var dragContent = (hasFiles: false, hasPromises: false)

    /// Režim zobrazení panelu (⌥1–⌥6); Podrobný a Typy = tabulka, jinak mřížka.
    var viewMode: ViewMode = .detailed {
        didSet {
            if oldValue != viewMode { applyViewMode() }
        }
    }

    /// Pohled, který přijímá klávesy (tabulka nebo mřížka podle režimu).
    var focusView: NSView {
        viewMode.usesTable ? tableView : gridView
    }

    init(panel: PanelController) {
        self.panel = panel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        panel.view = self
        buildTable()
        buildLayout()
        gridView.owner = self
        // Příjem souborů přetažených z jiných aplikací: soubory na disku (Finder)
        // i přislíbené soubory (Mail, Fotky, prohlížeč). Registruje se celý panel,
        // přetažení tak platí nad tabulkou, mřížkou i řádkem adresáře.
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        directoryLine.onDriveButton = { [weak self] button in
            guard let self else { return }
            self.inputHandler?.panelViewShowDriveChooser(self, anchor: button)
        }
        directoryLine.onActivate = { [weak self] in
            guard let self else { return }
            self.panel.delegate?.panelWantsActivation(self.panel)
        }
        directoryLine.onPathEntered = { [weak self] text in
            guard let self else { return }
            self.panel.goToTypedPath(text)
            self.window?.makeFirstResponder(self.focusView)
        }
        directoryLine.onEditCancelled = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.focusView)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    // MARK: - Sestavení

    /// Sloupce tabulky podle výchozího „Detailed“ pohledu Salamandera.
    private func buildTable() {
        let columns: [(String, String, CGFloat, CGFloat)] = [
            (ColumnID.name, "Jméno", 200, 80),
            (ColumnID.ext, "Přípona", 50, 30),
            (ColumnID.type, "Typ", 130, 50),
            (ColumnID.size, "Velikost", Self.sizeColumnWidth, 40),
            (ColumnID.date, "Datum", 76, 50),
            (ColumnID.time, "Čas", 58, 40),
            (ColumnID.attr, "Atr", 34, 24),
        ]
        for (identifier, title, width, minWidth) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = minWidth
            // Jméno se roztahuje, ostatní sloupce drží šířku.
            column.resizingMask = identifier == ColumnID.name ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            if identifier == ColumnID.size {
                column.headerCell.alignment = .right
            }
            // Sloupec Typ je vidět jen v režimu Typy.
            column.isHidden = identifier == ColumnID.type
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 17
        tableView.intercellSpacing = NSSize(width: 4, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnReordering = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.owner = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        applyBackgroundColor()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        updateSortIndicator()
    }

    /// Rozvržení: řádek adresáře nahoře, informační řádek dole.
    private func buildLayout() {
        addSubview(directoryLine)
        addSubview(scrollView)
        addSubview(infoLine)
        NSLayoutConstraint.activate([
            directoryLine.topAnchor.constraint(equalTo: topAnchor),
            directoryLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            directoryLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            directoryLine.heightAnchor.constraint(equalToConstant: 20),
            scrollView.topAnchor.constraint(equalTo: directoryLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoLine.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            infoLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            infoLine.heightAnchor.constraint(equalToConstant: 19),
        ])
    }

    // MARK: - Režim zobrazení

    /// Přepne obsah scroll view mezi tabulkou a mřížkou a zachová fokus i kurzor.
    private func applyViewMode() {
        let hadFocus = window?.firstResponder === tableView || window?.firstResponder === gridView
        if let typeColumn = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ColumnID.type)) {
            typeColumn.isHidden = viewMode != .types
        }
        if viewMode.usesTable {
            scrollView.documentView = tableView
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = true
        } else {
            gridView.mode = viewMode
            scrollView.documentView = gridView
            // Stručný režim teče do sloupců → vodorovné posouvání, ostatní svislé.
            scrollView.hasHorizontalScroller = viewMode == .brief
            scrollView.hasVerticalScroller = viewMode != .brief
        }
        reloadTable()
        scrollCursorVisible()
        if hadFocus {
            window?.makeFirstResponder(focusView)
        }
    }

    /// Při změně velikosti panelu se mřížka přepočítá (počet sloupců/řádků).
    override func layout() {
        super.layout()
        if !viewMode.usesTable {
            gridView.relayout()
        }
    }

    // MARK: - Společná obsluha vstupu (tabulka i mřížka)

    /// Systémové příkazy „začátek/konec dokumentu“ (Home/End přemapované klávesnicí,
    /// ⌘↑/⌘↓ v některých rozloženích): kurzor na první („..“) / poslední položku,
    /// varianty „AndModifySelection“ s označením rozsahu.
    static let edgeCommands: [Selector: (first: Bool, extend: Bool)] = [
        #selector(NSResponder.scrollToBeginningOfDocument(_:)): (true, false),
        #selector(NSResponder.moveToBeginningOfDocument(_:)): (true, false),
        #selector(NSResponder.scrollToEndOfDocument(_:)): (false, false),
        #selector(NSResponder.moveToEndOfDocument(_:)): (false, false),
        #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)): (true, true),
        #selector(NSResponder.moveToEndOfDocumentAndModifySelection(_:)): (false, true),
    ]

    /// Klávesa v tabulce/mřížce: nejdřív obsluha panelu, nezpracované projdou
    /// převodem na příkazy (interpretKeyEvents → doCommand) místo výchozí obsluhy
    /// NSTableView, která by u Home/End jen posunula obsah bez kurzoru.
    func handleKeyDown(_ event: NSEvent, in responder: NSResponder) {
        if inputHandler?.panelView(self, keyDown: event) != true {
            responder.interpretKeyEvents([event])
        }
    }

    /// Příkaz z interpretKeyEvents; true = zpracováno (začátek/konec dokumentu).
    func handleCommand(_ selector: Selector) -> Bool {
        guard let edge = PanelView.edgeCommands[selector] else { return false }
        moveCursorToEdge(first: edge.first, extend: edge.extend)
        return true
    }

    /// Klik na položku: kurzor; ⌘-klik přepne označení; ⇧-klik označí rozsah od
    /// `anchor`; dvojklik otevře. `index` nil = klik mimo položky.
    func handleClick(index: Int?, event: NSEvent, anchor: inout Int, in view: NSView) {
        view.window?.makeFirstResponder(view)
        panel.delegate?.panelWantsActivation(panel)
        guard let index else { return }
        panel.endQuickSearch()
        if event.modifierFlags.contains(.command) {
            panel.toggleMark(row: index)
            anchor = index
        } else if event.modifierFlags.contains(.shift) {
            panel.setMarkRange(from: anchor, to: index, true)
        } else {
            anchor = index
        }
        panel.setCursor(index)
        if event.clickCount == 2 && !event.modifierFlags.contains(.command) {
            inputHandler?.panelView(self, openRow: index)
        }
    }

    // MARK: - Přejmenování přímo v panelu

    /// Editační pole přejmenování a jeho dokončení (nil = žádné probíhá).
    private var renameField: NSTextField?
    private var renameCompletion: ((String?) -> Void)?

    /// Přejmenování položky pod kurzorem přímo v panelu (F2 / ⇧F6, bez dialogu):
    /// nad jménem se objeví editační pole, Enter potvrdí, Escape zruší, klik
    /// jinam potvrdí. U souboru je předvybrané jméno bez přípony.
    /// - Parameter completion: nové jméno, nil = zrušeno nebo beze změny
    func beginInlineRename(completion: @escaping (String?) -> Void) {
        finishInlineRename(commit: false)
        let row = panel.cursor
        guard row >= 0, row < panel.rows.count, !panel.rows[row].isParent else { return }
        let item = panel.rows[row].item
        // Pole přesně nad nakresleným jménem: v tabulce popisek buňky sloupce Jméno,
        // v mřížce obdélník jména podle režimu (stejný, jaký používá kreslení).
        let host = focusView
        var frame: NSRect
        if viewMode.usesTable {
            tableView.scrollRowToVisible(row)
            let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(ColumnID.name))
            let cell = tableView.frameOfCell(atColumn: column, row: row)
            if let label = (tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField {
                frame = tableView.convert(label.frame, from: label.superview)
                frame.size.width = cell.maxX - frame.minX
            } else {
                frame = cell
            }
        } else {
            gridView.scrollToVisible(gridView.rect(for: row))
            frame = gridView.nameRect(for: row)
        }
        // Minimální šířka pro pohodlnou úpravu, výška aspoň jeden řádek pole.
        frame.size.width = max(frame.width, 160)
        frame = frame.insetBy(dx: 0, dy: min(0, (frame.height - 20) / 2))

        let field = NSTextField(frame: frame)
        field.stringValue = item.name
        field.font = listFont
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        host.addSubview(field)
        renameField = field
        // Dokončení porovná s původním jménem (nezávisle na kurzoru panelu).
        renameCompletion = { newName in
            completion(newName.flatMap { $0 != item.name ? $0 : nil })
        }
        window?.makeFirstResponder(field)
        // Předvýběr jména bez přípony (u adresáře celé jméno).
        if let editor = field.currentEditor() {
            selectBaseName(of: item.name, in: editor, wholeName: item.isDir)
        }
    }

    /// Ukončí přejmenování: commit předá nové jméno (pokud se změnilo), jinak nil.
    private func finishInlineRename(commit: Bool) {
        guard let field = renameField else { return }
        renameField = nil
        let completion = renameCompletion
        renameCompletion = nil
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        window?.makeFirstResponder(focusView)
        completion?(commit && !newName.isEmpty ? newName : nil)
    }

    /// Zahájí přetažení souborů (Finder, Zprávy, Mail…): táhne označené položky,
    /// pokud je mezi nimi položka pod myší, jinak jen ji. Táhnout lze jen soubory
    /// z lokálního disku (archiv/FTP nemají cestu, kterou by cíl mohl otevřít).
    /// - Parameters:
    ///   - index: řádek, na kterém tažení začalo
    ///   - event: událost tažení myší
    ///   - view: pohled (tabulka / mřížka), ze kterého se táhne
    func beginFileDrag(index: Int, event: NSEvent, in view: NSView) {
        guard index < panel.rows.count, !panel.rows[index].isParent else { return }
        let items = panel.isMarked(row: index) ? panel.markedItems : [panel.rows[index].item]
        let files = items.compactMap { item in panel.localPath(of: item.name).map { (item, $0) } }
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }
        // Obrázky položek u kurzoru myši, mírně posunuté pod sebou. Skutečnou ikonu
        // souboru (dotaz na disk) mají jen první viditelné položky, ostatní ikonu
        // z cache podle přípony – tažení tisíců souborů tak nezdrží.
        let origin = view.convert(event.locationInWindow, from: nil)
        let size: CGFloat = 32
        let draggingItems = files.enumerated().map { offset, file -> NSDraggingItem in
            let (item, path) = file
            let dragItem = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
            let image = offset < 6 ? NSWorkspace.shared.icon(forFile: path) : listIcon(for: item)
            let shift = CGFloat(min(offset, 5)) * 4
            dragItem.setDraggingFrame(NSRect(x: origin.x - size / 2 + shift, y: origin.y - size / 2 - shift,
                                             width: size, height: size), contents: image)
            return dragItem
        }
        view.beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    /// Příkaz z menu doručený pohledu panelu přes responder chain
    /// (selectAll:/copy:/cut:/paste:).
    func performFromMenu(_ command: Command) {
        inputHandler?.panelView(self, perform: command)
    }

    /// Pravé tlačítko: kurzor na položku a kontextové menu operací.
    func handleContextMenu(index: Int?, in view: NSView) -> NSMenu? {
        view.window?.makeFirstResponder(view)
        if let index {
            panel.setCursor(index)
        }
        return inputHandler?.panelView(self, menuForRow: index ?? -1)
    }

    /// Pohled panelu dostal fokus → panel se stane aktivním.
    func handleBecameFirstResponder() {
        panel.delegate?.panelWantsActivation(panel)
    }

    /// Kurzor na první (obvykle „..“) / poslední položku; extend = označit rozsah.
    /// Společné pro všechny režimy zobrazení (Home/End, ⌥↑/⌥↓).
    func moveCursorToEdge(first: Bool, extend: Bool) {
        guard !panel.rows.isEmpty else { return }
        panel.endQuickSearch()
        let target = first ? 0 : panel.rows.count - 1
        if extend {
            panel.setMarkRange(from: panel.cursor, to: target, true)
        }
        panel.setCursor(target)
    }

    /// Nový adresář: mřížka zahodí miniatury předchozího.
    func directoryChanged() {
        gridView.clearThumbnails()
        // Sloupec Velikost se v novém adresáři vrátí na výchozí šířku
        // (a podle potřeby se znovu rozšíří při překreslení).
        sizeColumn?.width = Self.sizeColumnWidth
    }

    /// Výchozí šířka sloupce Velikost.
    private static let sizeColumnWidth: CGFloat = 80

    /// Sloupec Velikost tabulky.
    private var sizeColumn: NSTableColumn? {
        tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ColumnID.size))
    }

    /// Rozšíří sloupec Velikost, aby se do něj vešlo celé nejdelší číslo
    /// (velké soubory i spočítané velikosti adresářů); nikdy ho nezužuje.
    func fitSizeColumn() {
        guard let column = sizeColumn else { return }
        // Nejdelší text má největší hodnota (číslice mají v písmu stejnou šířku);
        // měří se tučným písmem označených řádků, plus okraje buňky.
        let largest = panel.rows.map { $0.item.isDir ? panel.dirSize(of: $0.item) ?? 0 : $0.item.size }.max() ?? 0
        let text = formatExactSize(largest) as NSString
        let needed = ceil(text.size(withAttributes: [.font: boldListFont]).width) + 10
        if needed > column.width {
            column.width = needed
        }
    }

    /// Cílový řádek pro směrovou klávesu podle rozvržení režimu
    /// (nil = klávesa v tomto režimu kurzorem nehýbe, např. ←/→ v Podrobném).
    func target(from cursor: Int, key: NavigationKey) -> Int? {
        if !viewMode.usesTable {
            return gridView.target(from: cursor, key: key)
        }
        let pageSize = max(1, Int(scrollView.contentView.bounds.height / tableView.rowHeight) - 1)
        switch key {
        case .up: return cursor - 1
        case .down: return cursor + 1
        case .pageUp: return cursor - pageSize
        case .pageDown: return cursor + pageSize
        case .left, .right: return nil
        }
    }

    // MARK: - Aktualizace z modelu

    /// Úplné překreslení (nový výpis, hromadné označení).
    func reloadTable() {
        if viewMode.usesTable {
            fitSizeColumn()
            tableView.reloadData()
        } else {
            gridView.relayout()
        }
        refreshAppearance()
    }

    /// Překreslí jen dané řádky (pohyb kurzoru, označení jedné položky).
    func refreshRows(_ indexes: [Int]) {
        let valid = indexes.filter { $0 >= 0 && $0 < panel.rows.count }
        guard !valid.isEmpty else { return }
        if !viewMode.usesTable {
            gridView.refresh(valid)
            return
        }
        tableView.reloadData(forRowIndexes: IndexSet(valid), columnIndexes: IndexSet(0..<tableView.numberOfColumns))
        for row in valid {
            if let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) as? SalRowView {
                configure(rowView, row: row)
            }
        }
    }

    /// Otevře menu disků u tlačítka na řádku adresáře (⌥F1 / ⌥F2).
    func showDriveMenu() {
        directoryLine.onDriveButton?(directoryLine.driveButton)
    }

    /// Posune tabulku, aby byl kurzor vidět.
    func scrollCursorVisible() {
        guard panel.cursor >= 0, panel.cursor < panel.rows.count else { return }
        if viewMode.usesTable {
            tableView.scrollRowToVisible(panel.cursor)
        } else {
            gridView.scrollToIndex(panel.cursor)
        }
    }

    /// Nové barevné schéma: pozadí tabulky a všechny položky (řádek adresáře
    /// přebarví refreshAppearance v reloadTable).
    func applyColorScheme() {
        applyBackgroundColor()
        reloadTable()
    }

    /// Pozadí tabulky a plochy pod posledním řádkem podle schématu.
    private func applyBackgroundColor() {
        tableView.backgroundColor = PanelColors.current.itemBackground
        scrollView.backgroundColor = PanelColors.current.itemBackground
    }

    /// Aktivní/neaktivní vzhled (řádek adresáře, kurzor).
    func refreshAppearance() {
        directoryLine.isActive = panel.isActive
        gridView.needsDisplay = true
        tableView.enumerateAvailableRowViews { rowView, row in
            if let rowView = rowView as? SalRowView {
                self.configure(rowView, row: row)
            }
        }
        refreshRows([panel.cursor])
    }

    /// Indikátor řazení v záhlaví sloupce.
    func updateSortIndicator() {
        let sortColumn: String
        switch panel.sortKey {
        case .name: sortColumn = ColumnID.name
        case .ext: sortColumn = ColumnID.ext
        case .size: sortColumn = ColumnID.size
        case .time: sortColumn = ColumnID.date
        }
        let image = NSImage(systemSymbolName: panel.sortAscending ? "chevron.up" : "chevron.down",
                            accessibilityDescription: nil)
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(column.identifier.rawValue == sortColumn ? image : nil, in: column)
        }
    }

    /// Nastaví stav vykreslení řádku (kurzor, aktivní panel).
    private func configure(_ rowView: SalRowView, row: Int) {
        rowView.isCursor = row == panel.cursor
        rowView.isMarked = panel.isMarked(row: row)
        rowView.panelActive = panel.isActive
        rowView.needsDisplay = true
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        panel.rows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = SalRowView()
        configure(rowView, row: row)
        return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < panel.rows.count, let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileCellView)
            ?? FileCellView(withIcon: identifier.rawValue == ColumnID.name, identifier: identifier)
        let entry = panel.rows[row]
        let item = entry.item

        // Barva textu podle schématu (kurzor, označení, skryté ztlumeně).
        let onCursor = row == panel.cursor && panel.isActive
        let marked = panel.isMarked(row: row)
        let color = PanelColors.current.text(marked: marked, onActiveCursor: onCursor,
                                             hidden: item.isHidden && !entry.isParent)

        var text = ""
        var alignment = NSTextAlignment.left
        switch identifier.rawValue {
        case ColumnID.name:
            text = entry.baseName
            cell.iconView?.image = icon(for: entry)
        case ColumnID.ext:
            text = entry.ext
        case ColumnID.type:
            text = typeDescription(for: entry)
        case ColumnID.size:
            alignment = .right
            // Adresář ukazuje velikost spočítanou přes ⌥F10, jinak „DIR“.
            if entry.isParent {
                text = "UP-DIR"
            } else if item.isDir {
                text = panel.dirSize(of: item).map(formatExactSize) ?? "DIR"
            } else {
                text = formatExactSize(item.size)
            }
        case ColumnID.date:
            text = entry.isParent ? "" : formatDay(item.mtime)
        case ColumnID.time:
            text = entry.isParent ? "" : formatTime(item.mtime)
        case ColumnID.attr:
            text = entry.isParent ? "" : attributes(of: item)
        default:
            break
        }
        cell.textLabel.stringValue = text
        cell.textLabel.alignment = alignment
        cell.textLabel.textColor = color
        cell.textLabel.font = marked ? boldListFont : listFont
        return cell
    }

    /// Klik do záhlaví mění řazení (opakovaný klik obrací pořadí).
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        switch tableColumn.identifier.rawValue {
        case ColumnID.name: panel.setSort(.name)
        case ColumnID.ext: panel.setSort(.ext)
        case ColumnID.size: panel.setSort(.size)
        case ColumnID.date, ColumnID.time: panel.setSort(.time)
        default: break
        }
        panel.delegate?.panelWantsActivation(panel)
    }

    /// Ikona položky: systémová ikona podle přípony (cache), „..“ šipka nahoru.
    func icon(for row: Row) -> NSImage? {
        row.isParent ? parentIcon : listIcon(for: row.item)
    }
}

/// Označí v editoru jméno bez přípony (jako Salamander při přejmenování).
/// - Parameters:
///   - name: jméno v editoru
///   - editor: editor textového pole
///   - wholeName: označit celé jméno (adresář)
func selectBaseName(of name: String, in editor: NSText, wholeName: Bool = false) {
    let base = wholeName ? name : splitExtension(name).base
    editor.selectedRange = NSRange(location: 0, length: (base as NSString).length)
}

/// Atributy ve stylu Salamandera (R = jen pro čtení, H = skrytý, L = odkaz,
/// E = šifrovaná položka archivu); sdílí panel i okno hledání.
func attributes(of item: Item) -> String {
    var text = ""
    if item.isReadonly { text += "R" }
    if item.isHidden { text += "H" }
    if item.isLink { text += "L" }
    if item.isEncrypted { text += "E" }
    return text
}

/// Ikona položky seznamu: adresář / odkaz na adresář, soubor podle přípony (cache).
func listIcon(for item: Item) -> NSImage {
    if item.isDir {
        return item.isLink ? folderLinkIcon : folderIcon
    }
    let ext = splitExtension(item.name).ext.lowercased()
    if let cached = iconCache[ext] {
        return cached
    }
    let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
    let image = NSWorkspace.shared.icon(for: type)
    image.size = NSSize(width: 16, height: 16)
    iconCache[ext] = image
    return image
}

// Sdílená písma a ikony seznamu.
let listFont = NSFont.systemFont(ofSize: 12)
let boldListFont = NSFont.boldSystemFont(ofSize: 12)
private var iconCache: [String: NSImage] = [:]
private let folderIcon: NSImage = {
    let image = NSWorkspace.shared.icon(for: .folder)
    image.size = NSSize(width: 16, height: 16)
    return image
}()
private let folderLinkIcon: NSImage = {
    let image = NSWorkspace.shared.icon(for: .aliasFile)
    image.size = NSSize(width: 16, height: 16)
    return image
}()
private let parentIcon: NSImage? = {
    let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    let image = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "..")?
        .withSymbolConfiguration(config)
    return image
}()

/// Buňka tabulky: volitelná ikona + text.
final class FileCellView: NSTableCellView {
    let textLabel = NSTextField(labelWithString: "")
    private(set) var iconView: NSImageView?

    init(withIcon: Bool, identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.font = listFont
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.cell?.truncatesLastVisibleLine = true
        addSubview(textLabel)
        var constraints = [
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        // Sloupec jména má ikonu vlevo od textu.
        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            addSubview(image)
            iconView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                textLabel.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            ]
        } else {
            constraints.append(textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
        textField = textLabel
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }
}

/// Řádek tabulky: pozadí podle schématu (označené položky mohou mít vlastní)
/// a kurzor (výplň v aktivním panelu, tečkovaný rámeček v neaktivním).
final class SalRowView: NSTableRowView {
    var isCursor = false
    var isMarked = false
    var panelActive = false

    override func drawBackground(in dirtyRect: NSRect) {
        let colors = PanelColors.current
        colors.background(marked: isMarked).setFill()
        bounds.fill()
        guard isCursor else { return }
        colors.drawCursor(in: bounds.insetBy(dx: 1, dy: 0.5), active: panelActive, marked: isMarked)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Výběr tabulky se nepoužívá – kurzor kreslí drawBackground.
    }
}

/// Tabulka panelu: veškeré klávesy a kliky řídí panel (žádný NSTableView výběr).
final class SalTableView: NSTableView {
    weak var owner: PanelView?
    /// Řádek, od kterého se počítá Shift+klik.
    private var anchorRow = 0

    override var acceptsFirstResponder: Bool { true }

    /// ⌘A (Označit › Označit vše, akce selectAll:) = příkaz Označit vše (rozhoduje hlavní okno).
    override func selectAll(_ sender: Any?) {
        owner?.performFromMenu(.selectAll)
    }

    // Úpravy › Kopírovat / Vyjmout / Vložit (akce copy:/cut:/paste: přes responder
    // chain) = schránka souborů panelu.
    @objc func copy(_ sender: Any?) {
        owner?.performFromMenu(.clipboardCopy)
    }

    @objc func cut(_ sender: Any?) {
        owner?.performFromMenu(.clipboardCut)
    }

    @objc func paste(_ sender: Any?) {
        owner?.performFromMenu(.clipboardPaste)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { owner?.handleBecameFirstResponder() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        owner.handleKeyDown(event, in: self)
    }

    override func doCommand(by selector: Selector) {
        if owner?.handleCommand(selector) != true {
            super.doCommand(by: selector)
        }
    }

    /// Rozpracované tažení (místo stisku myši).
    private var dragStart = PanelDragStart()

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let index = row >= 0 ? row : nil
        dragStart.begin(index: index, event: event)
        owner.handleClick(index: index, event: event, anchor: &anchorRow, in: self)
    }

    /// Tažení myší ze řádku položky = přetažení souborů do jiné aplikace.
    override func mouseDragged(with event: NSEvent) {
        if let index = dragStart.indexToDrag(event) {
            owner?.beginFileDrag(index: index, event: event, in: self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return owner?.handleContextMenu(index: row >= 0 ? row : nil, in: self)
    }
}

/// Klávesy editačního pole přejmenování: Enter potvrdí, Escape zruší.
extension PanelView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renameField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            finishInlineRename(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishInlineRename(commit: false)
            return true
        default:
            return false
        }
    }

    /// Ztráta fokusu (klik jinam) přejmenování potvrdí, jako v Salamanderu.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === renameField else { return }
        finishInlineRename(commit: true)
    }
}

/// Příjem souborů přetažených z jiné aplikace do adresáře panelu.
extension PanelView {
    /// Operace pro tažení nad panelem: kopie, s ⌘ přesun (jako Finder); prázdná,
    /// když panel tažení nepřijme.
    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        // Tažení z panelu MicroCommanderu (i z jiného okna) se nepřijímá, do
        // archivu zapisovat nelze.
        guard !(sender.draggingSource is PanelView), panel.location.vfs.writable else { return [] }
        let hasFiles = dragContent.hasFiles
        // Přislíbené soubory zapisuje zdrojová aplikace sama – jen na lokální disk.
        guard hasFiles || (dragContent.hasPromises && panel.localDirectory != nil) else { return [] }
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        // Se stisknutým ⌘ nabízí zdroj jen „generic“ – soubory se přesunou.
        if hasFiles && mask.contains(.generic) { return .generic }
        if hasFiles && mask.contains(.move) { return .move }
        return []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        dragContent = (FileClipboard.hasFiles(in: pasteboard),
                       pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil))
        return dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    /// Puštění souborů nad panelem: soubory z disku převezme hlavní okno
    /// (kopírování / přesun s průběhem a dotazem na přepsání), přislíbené
    /// soubory zapíše zdrojová aplikace přímo do adresáře panelu.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let operation = dropOperation(for: sender)
        guard !operation.isEmpty else { return false }
        let pasteboard = sender.draggingPasteboard
        let paths = FileClipboard.paths(from: pasteboard)
        if !paths.isEmpty {
            let move = operation != .copy
            // Operaci spustit až po skončení tažení – dialog nebo průběh by
            // jinak držel zdrojovou aplikaci uprostřed přetahování.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inputHandler?.panelView(self, dropFiles: paths, move: move)
            }
            return true
        }
        guard let directory = panel.localDirectory,
              let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        for receiver in receivers {
            // Blok se volá pro každý doručený soubor: kurzor se postaví na nový
            // soubor, chybu zdrojové aplikace ukáže hlášení. Panel se obnoví jednou
            // za celou dávku (chvíli po posledním souboru), ne po každém souboru.
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: .main) { [weak self] url, error in
                guard let self else { return }
                if let error {
                    PromptDialog.show(title: "Přetažení souboru", message: error.localizedDescription, over: self.window)
                    return
                }
                self.panel.focus(name: url.lastPathComponent)
                let reload = #selector(self.reloadAfterPromisedFiles)
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: reload, object: nil)
                self.perform(reload, with: nil, afterDelay: 0.3)
            }
        }
        return true
    }

    /// Obnoví panel po doručení přislíbených souborů (odložené volání z performDragOperation).
    @objc private func reloadAfterPromisedFiles() {
        panel.reload()
    }
}

/// Přetahování souborů z panelu: ven z aplikace kopie/odkaz/přesun podle cíle
/// (Finder, Zprávy, Mail…); mezi panely aplikace se nepřetahuje.
extension PanelView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic, .move] : []
    }

    /// Po přesunu (např. do Koše) se panel obnoví.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.contains(.move) || operation.contains(.delete) {
            panel.reload()
        }
    }
}

/// Stav zahájení tažení myší společný pro tabulku i mřížku panelu: tažení
/// začne až po posunu o několik bodů, aby běžný klik/dvojklik fungoval dál.
struct PanelDragStart {
    /// Řádek pod stiskem myši; po zahájení tažení nil (jedno tažení na stisk).
    private var index: Int?
    private var location = NSPoint.zero

    /// Stisk tlačítka myši nad položkou (nil = mimo položky).
    mutating func begin(index: Int?, event: NSEvent) {
        self.index = event.clickCount == 1 && !event.modifierFlags.contains(.shift) ? index : nil
        location = event.locationInWindow
    }

    /// Řádek k přetažení, jakmile se myš posune dost daleko (jen jednou za stisk).
    mutating func indexToDrag(_ event: NSEvent) -> Int? {
        guard let index else { return nil }
        let distance = hypot(event.locationInWindow.x - location.x, event.locationInWindow.y - location.y)
        guard distance >= 4 else { return nil }
        self.index = nil
        return index
    }
}

/// Řádek adresáře: tlačítko disku, cesta (klik = úprava), volné místo vpravo.
final class DirectoryLineView: NSView, NSTextFieldDelegate {
    let driveButton = NSButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let freeLabel = NSTextField(labelWithString: "")
    private let editField = NSTextField()

    var onDriveButton: ((NSButton) -> Void)?
    var onActivate: (() -> Void)?
    var onPathEntered: ((String) -> Void)?
    var onEditCancelled: (() -> Void)?

    /// Aktivní panel má zvýrazněný řádek adresáře (barva akcentu).
    var isActive = false {
        didSet { updateColors() }
    }

    /// Text cesty.
    var path: String = "" {
        didSet { pathLabel.stringValue = path }
    }

    /// Cesta nabízená k úpravě (cesta ve VFS panelu). Zobrazený text ji u
    /// archivu a serveru doplňuje o popisek, který do zadávané cesty nepatří.
    var editablePath: String = ""

    /// Text volného místa (prázdný = nezobrazovat).
    var freeSpace: String = "" {
        didSet { freeLabel.stringValue = freeSpace }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        driveButton.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Disk")
        driveButton.imagePosition = .imageOnly
        driveButton.bezelStyle = .accessoryBarAction
        driveButton.isBordered = false
        driveButton.target = self
        driveButton.action = #selector(driveClicked(_:))
        driveButton.toolTip = "Změnit disk (⌥F1 / ⌥F2)"

        pathLabel.font = NSFont.boldSystemFont(ofSize: 12)
        pathLabel.lineBreakMode = .byTruncatingHead
        freeLabel.font = NSFont.systemFont(ofSize: 11)
        freeLabel.alignment = .right

        editField.font = NSFont.systemFont(ofSize: 12)
        editField.isHidden = true
        editField.delegate = self
        editField.focusRingType = .none
        editField.bezelStyle = .squareBezel

        for view in [driveButton, pathLabel, freeLabel, editField] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        freeLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            driveButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            driveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            driveButton.widthAnchor.constraint(equalToConstant: 20),
            pathLabel.leadingAnchor.constraint(equalTo: driveButton.trailingAnchor, constant: 3),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            freeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pathLabel.trailingAnchor, constant: 8),
            freeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            freeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            editField.leadingAnchor.constraint(equalTo: driveButton.trailingAnchor, constant: 1),
            editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            editField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Barvy podle aktivity a schématu (titulek aktivního/neaktivního panelu).
    private func updateColors() {
        needsDisplay = true
        let colors = PanelColors.current
        let text = isActive ? colors.activeCaptionText : colors.inactiveCaptionText
        pathLabel.textColor = text
        freeLabel.textColor = text
        driveButton.contentTintColor = text
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// Pozadí kreslíme v draw(), aby dynamické systémové barvy sledovaly vzhled
    /// (CGColor ve vrstvě by se při přepnutí světlý/tmavý režim neaktualizovala).
    override func draw(_ dirtyRect: NSRect) {
        let colors = PanelColors.current
        let background = isActive ? colors.activeCaptionBackground : colors.inactiveCaptionBackground
        background.setFill()
        bounds.fill()
    }

    /// Klik na řádek: aktivuje panel; dvojklik začne úpravu cesty.
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if event.clickCount >= 2 {
            beginEditing()
        }
    }

    /// Pravé tlačítko na řádku adresáře: kopírovat cestu do schránky nebo ji
    /// upravit (jako kontextové menu cesty v Salamanderu).
    override func menu(for event: NSEvent) -> NSMenu? {
        onActivate?()
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Kopírovat cestu do schránky", action: #selector(copyPathClicked(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let change = NSMenuItem(title: "Změnit adresář…", action: #selector(changePathClicked(_:)), keyEquivalent: "")
        change.target = self
        menu.addItem(change)
        return menu
    }

    @objc private func copyPathClicked(_ sender: Any?) {
        copyTextToPasteboard(path)
    }

    @objc private func changePathClicked(_ sender: Any?) {
        beginEditing()
    }

    /// Zobrazí editační pole s cestou (Shift+F7 / ⌘G, dvojklik).
    func beginEditing() {
        editField.stringValue = editablePath
        editField.isHidden = false
        pathLabel.isHidden = true
        freeLabel.isHidden = true
        window?.makeFirstResponder(editField)
        editField.currentEditor()?.selectAll(nil)
    }

    /// Ukončí úpravu cesty a vrátí popisek.
    private func endEditing() {
        editField.isHidden = true
        pathLabel.isHidden = false
        freeLabel.isHidden = false
    }

    /// Enter potvrdí cestu, Escape úpravu zruší.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let text = editField.stringValue
            endEditing()
            onPathEntered?(text)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endEditing()
            onEditCancelled?()
            return true
        }
        return false
    }

    /// Ztráta fokusu (klik jinam) úpravu zruší.
    func controlTextDidEndEditing(_ obj: Notification) {
        if !editField.isHidden {
            endEditing()
        }
    }

    @objc private func driveClicked(_ sender: NSButton) {
        onActivate?()
        onDriveButton?(sender)
    }
}

/// Informační řádek pod panelem (položka pod kurzorem, souhrn označení).
final class InfoLineView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String = "" {
        didSet { label.stringValue = text }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Horní dělicí čára (oddělení od tabulky).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
