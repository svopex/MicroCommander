// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Režimy zobrazení panelu podle Salamandera (⌥1–⌥6): Stručný, Podrobný,
// Ikony, Miniatury, Dlaždice, Typy. Podrobný a Typy kreslí NSTableView
// (PanelView), ostatní režimy kreslí FileGridView – vlastní mřížka s kurzorem
// odděleným od označení, stejnými barvami a ovládáním jako tabulka.

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Režim zobrazení panelu (hodnota = číslo zkratky ⌥1–⌥6).
enum ViewMode: Int, CaseIterable {
    case brief = 1
    case detailed = 2
    case icons = 3
    case thumbnails = 4
    case tiles = 5
    case types = 6

    /// Název v menu (jako v Salamanderu).
    var title: String {
        switch self {
        case .brief: return tr("Stručný")
        case .detailed: return tr("Podrobný")
        case .icons: return tr("Ikony")
        case .thumbnails: return tr("Miniatury")
        case .tiles: return tr("Dlaždice")
        case .types: return tr("Typy")
        }
    }

    /// Kreslí se tabulkou se sloupci (jinak mřížkou)?
    var usesTable: Bool {
        self == .detailed || self == .types
    }
}

/// Směr pohybu kurzoru (klávesy) – cíl se počítá podle rozvržení režimu.
enum NavigationKey {
    case up, down, left, right, pageUp, pageDown
}

/// Popis typu souboru pro režimy Typy a Dlaždice (lokalizovaný systémem, cache).
func typeDescription(for row: Row) -> String {
    if row.isParent { return "" }
    if row.item.isDir { return tr("Složka") }
    let ext = row.ext.lowercased()
    if let cached = typeDescriptionCache[ext] { return cached }
    let description = (ext.isEmpty ? nil : UTType(filenameExtension: ext))?.localizedDescription
        ?? (ext.isEmpty ? tr("Soubor") : tr("Soubor %@", ext.uppercased()))
    typeDescriptionCache[ext] = description
    return description
}

private var typeDescriptionCache: [String: String] = [:]

/// Mřížka položek pro režimy Stručný / Ikony / Miniatury / Dlaždice.
final class FileGridView: NSView {
    weak var owner: PanelView?
    /// Aktuální režim (jen mřížkové režimy).
    var mode: ViewMode = .brief {
        didSet { relayout() }
    }

    /// Výška řádku buněk a počet řádků ve sloupci (počítá relayout()).
    private var rowHeight: CGFloat = 17
    private var rowsPerColumn = 1
    /// Levé okraje sloupců mřížky, poslední prvek je pravý okraj posledního
    /// sloupce (počet = columns + 1). Ve Stručném režimu má každý sloupec vlastní
    /// šířku, v ostatních režimech jsou okraje rovnoměrné.
    private var columnEdges: [CGFloat] = [0, 0]
    private var columns: Int { columnEdges.count - 1 }
    /// Řádek, od kterého se počítá Shift+klik.
    private var anchorRow = 0
    /// Šířky jmen všech položek (Stručný režim) a generace řádků, pro kterou platí –
    /// měření textu je drahé, opakuje se jen při novém seznamu, ne při označení.
    private var nameWidths: [CGFloat] = []
    private var measuredGeneration = -1
    /// Stručný režim: celkový vodorovný okraj buňky kolem jména (ikona vlevo,
    /// mezera vpravo) – relayout i nameRect musí počítat se stejnou hodnotou.
    private static let briefNameMargin: CGFloat = 28
    /// Miniatury podle cesty (načítané asynchronně přes Quick Look).
    private var thumbnails: [String: NSImage] = [:]
    private var pendingThumbnails: Set<String> = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { owner?.handleBecameFirstResponder() }
        return accepted
    }

    // MARK: - Rozvržení

    /// Spočítá rozměry buněk a velikost obsahu podle režimu a viditelné plochy.
    func relayout() {
        guard let owner else { return }
        let rows = owner.panel.rows
        // Viditelná plocha včetně posuvníku, který se v daném režimu zobrazí
        // (jinak by ho posuvník po objevení zakryl – useknutý řádek/sloupec).
        let scroll = owner.scrollView
        let visible = NSScrollView.contentSize(
            forFrameSize: scroll.frame.size,
            horizontalScrollerClass: mode == .brief ? NSScroller.self : nil,
            verticalScrollerClass: mode == .brief ? nil : NSScroller.self,
            borderType: scroll.borderType,
            controlSize: .regular,
            scrollerStyle: scroll.scrollerStyle)
        switch mode {
        case .brief:
            // Sloupce jmen tekoucí shora dolů, každý široký podle nejdelšího jména
            // v něm (jako Salamander – jména se nezkracují). Měří se tučným písmem,
            // aby se jméno nezkrátilo ani po označení.
            if measuredGeneration != owner.panel.rowsGeneration {
                measuredGeneration = owner.panel.rowsGeneration
                let attributes: [NSAttributedString.Key: Any] = [.font: boldListFont]
                nameWidths = rows.map { ceil(($0.item.name as NSString).size(withAttributes: attributes).width) }
            }
            rowHeight = 17
            // Překryvný vodorovný posuvník leží přes spodek obsahu – místo pro něj
            // vyhradíme, aby nezakrýval poslední řádek sloupců.
            let overlayReserve: CGFloat = scroll.scrollerStyle == .overlay
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) + 2 : 0
            rowsPerColumn = max(1, Int((visible.height - overlayReserve) / rowHeight))
            let columnCount = max(1, (rows.count + rowsPerColumn - 1) / rowsPerColumn)
            // Šířka sloupce = nejdelší jméno ve sloupci + okraje + 2 pt rezervy,
            // nejvýš šířka panelu (delší jméno se zkrátí), nejméně 110 pt
            // (i pro prázdný seznam). Okraje sloupců se sčítají zleva.
            var edges: [CGFloat] = [0]
            edges.reserveCapacity(columnCount + 1)
            for column in 0..<columnCount {
                let start = column * rowsPerColumn
                let longest = nameWidths[start..<min(start + rowsPerColumn, nameWidths.count)].max() ?? 0
                edges.append(edges[column] + max(min(longest + Self.briefNameMargin + 2, visible.width), 110))
            }
            columnEdges = edges
            setFrameSize(NSSize(width: max(visible.width, edges[columnCount]), height: visible.height))
        case .icons, .thumbnails, .tiles:
            // Řádkově uspořádaná mřížka (počet sloupců podle šířky).
            let cellSize: NSSize
            switch mode {
            case .icons: cellSize = NSSize(width: 92, height: 70)
            case .thumbnails: cellSize = NSSize(width: 124, height: 126)
            default: cellSize = NSSize(width: 250, height: 52)
            }
            rowHeight = cellSize.height
            // Rovnoměrné okraje sloupců (stejně široké buňky).
            let columnCount = max(1, Int(visible.width / cellSize.width))
            columnEdges = (0...columnCount).map { CGFloat($0) * cellSize.width }
            rowsPerColumn = max(1, (rows.count + columnCount - 1) / columnCount)
            setFrameSize(NSSize(width: visible.width, height: max(visible.height, CGFloat(rowsPerColumn) * rowHeight)))
        default:
            break
        }
        needsDisplay = true
    }

    /// Obdélník buňky pro index položky.
    func rect(for index: Int) -> NSRect {
        let column: Int
        let row: Int
        if mode == .brief {
            column = index / rowsPerColumn
            row = index % rowsPerColumn
        } else {
            column = index % columns
            row = index / columns
        }
        // Vodorovná poloha a šířka podle okrajů sloupců (omezeno na existující
        // sloupce – index ze starého seznamu před relayoutem nesmí spadnout).
        let edge = max(0, min(column, columns - 1))
        return NSRect(x: columnEdges[edge], y: CGFloat(row) * rowHeight,
                      width: columnEdges[edge + 1] - columnEdges[edge], height: rowHeight)
    }

    /// Sloupec pod vodorovnou souřadnicí x (může být za posledním sloupcem).
    private func column(atX x: CGFloat) -> Int {
        // Binární hledání posledního levého okraje ≤ x (sloupců mohou být stovky);
        // za pravým okrajem posledního sloupce vrací columns (tj. mimo položky).
        var low = 0
        var high = columns
        while low < high {
            let middle = (low + high + 1) / 2
            if columnEdges[middle] <= x { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Obdélník jména položky v buňce podle režimu (kreslení i přejmenování v panelu).
    func nameRect(for index: Int) -> NSRect {
        let cell = rect(for: index)
        switch mode {
        case .icons, .thumbnails:
            let side: CGFloat = mode == .icons ? 32 : 92
            return NSRect(x: cell.minX + 4, y: cell.minY + side + 6, width: cell.width - 8, height: 28)
        case .tiles:
            return NSRect(x: cell.minX + 52, y: cell.minY + 4, width: cell.width - 58, height: 16)
        default:
            return NSRect(x: cell.minX + 24, y: cell.minY + 1,
                          width: cell.width - Self.briefNameMargin, height: 15)
        }
    }

    /// Index položky pod bodem (nil = prázdné místo).
    func index(at point: NSPoint) -> Int? {
        guard let owner, point.x >= 0, point.y >= 0 else { return nil }
        let column = column(atX: point.x)
        let row = Int(point.y / rowHeight)
        let index: Int
        if mode == .brief {
            guard row < rowsPerColumn else { return nil }
            index = column * rowsPerColumn + row
        } else {
            guard column < columns else { return nil }
            index = row * columns + column
        }
        return index < owner.panel.rows.count ? index : nil
    }

    /// Cílový index pro směrovou klávesu (Stručný: sloupce, ostatní: řádky mřížky).
    func target(from cursor: Int, key: NavigationKey) -> Int {
        let visibleRect = owner?.scrollView.contentView.bounds ?? bounds
        if mode == .brief {
            // Ve Stručném režimu ←/→ přeskakují sloupec, PgUp/PgDn viditelnou stránku
            // sloupců (počet sloupců celých v zobrazené oblasti, sloupce mají různé šířky).
            let visibleColumns = max(1, zip(columnEdges, columnEdges.dropFirst()).count {
                $0.0 >= visibleRect.minX - 0.5 && $0.1 <= visibleRect.maxX + 0.5
            })
            switch key {
            case .up: return cursor - 1
            case .down: return cursor + 1
            case .left: return cursor - rowsPerColumn
            case .right: return cursor + rowsPerColumn
            case .pageUp: return cursor - rowsPerColumn * visibleColumns
            case .pageDown: return cursor + rowsPerColumn * visibleColumns
            }
        }
        let visibleRows = max(1, Int(visibleRect.height / rowHeight))
        switch key {
        case .up: return cursor - columns
        case .down: return cursor + columns
        case .left: return cursor - 1
        case .right: return cursor + 1
        case .pageUp: return cursor - columns * visibleRows
        case .pageDown: return cursor + columns * visibleRows
        }
    }

    /// Posune obsah, aby byla položka vidět.
    func scrollToIndex(_ index: Int) {
        guard let owner, index >= 0, index < owner.panel.rows.count else { return }
        scrollToVisible(rect(for: index))
    }

    /// Překreslí buňky daných indexů.
    func refresh(_ indexes: [Int]) {
        for index in indexes {
            setNeedsDisplay(rect(for: index))
        }
    }

    // MARK: - Kreslení

    override func draw(_ dirtyRect: NSRect) {
        PanelColors.current.itemBackground.setFill()
        dirtyRect.fill()
        guard let owner else { return }
        let panel = owner.panel
        // Kreslíme jen buňky v překreslované oblasti (rozsah spočítaný z mřížky,
        // ne průchod všemi položkami – kurzor překresluje jedinou buňku).
        for index in indexes(in: dirtyRect) {
            drawCell(panel.rows[index], index: index, in: rect(for: index), panel: panel)
        }
    }

    /// Indexy položek, jejichž buňky zasahují do obdélníku.
    private func indexes(in area: NSRect) -> [Int] {
        guard let count = owner?.panel.rows.count, count > 0 else { return [] }
        let firstColumn = max(0, column(atX: area.minX))
        let lastColumn = column(atX: area.maxX)
        let firstRow = max(0, Int(area.minY / rowHeight))
        let lastRow = Int(area.maxY / rowHeight)
        var result: [Int] = []
        for column in firstColumn...max(firstColumn, lastColumn) {
            for row in firstRow...max(firstRow, lastRow) {
                // Stručný: sloupce shora dolů; ostatní: řádky zleva doprava.
                let index: Int
                if mode == .brief {
                    guard row < rowsPerColumn else { continue }
                    index = column * rowsPerColumn + row
                } else {
                    guard column < columns else { continue }
                    index = row * columns + column
                }
                if index < count { result.append(index) }
            }
        }
        return result
    }

    /// Jedna buňka: kurzor (výplň/rámeček), ikona nebo miniatura, texty.
    private func drawCell(_ row: Row, index: Int, in cell: NSRect, panel: PanelController) {
        let onCursor = index == panel.cursor
        let active = panel.isActive
        let marked = panel.isMarked(row: index)
        let highlight = cell.insetBy(dx: 2, dy: 1)

        // Označená položka může mít vlastní pozadí schématu (např. Windows Explorer).
        let colors = PanelColors.current
        if marked {
            colors.markedBackground.setFill()
            NSBezierPath(roundedRect: highlight, xRadius: 4, yRadius: 4).fill()
        }
        // Kurzor: v aktivním panelu výplň, v neaktivním tečkovaný rámeček.
        if onCursor {
            colors.drawCursor(in: highlight, cornerRadius: 4, active: active, marked: marked)
        }

        // Barva textu stejně jako v tabulce (označení, skryté ztlumeně).
        let color = colors.text(marked: marked, onActiveCursor: onCursor && active,
                                hidden: row.item.isHidden && !row.isParent)
        // Druhotný text: na kurzoru ztlumená barva jména, jinak barva skrytých položek.
        let secondary = onCursor && active ? color.withAlphaComponent(0.8) : colors.hiddenText
        let font = marked ? boldListFont : listFont
        let image = owner?.icon(for: row)

        switch mode {
        case .brief:
            // Ikona 16 px + jméno na jednom řádku.
            image?.draw(in: NSRect(x: cell.minX + 4, y: cell.minY + 0.5, width: 16, height: 16),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawText(row.item.name, in: nameRect(for: index), font: font, color: color, alignment: .left)
        case .icons, .thumbnails:
            // Velká ikona / miniatura nahoře, jméno pod ní na střed (dva řádky).
            let side: CGFloat = mode == .icons ? 32 : 92
            var picture = image
            if mode == .thumbnails, !row.isParent, !row.item.isDir, let thumbnail = thumbnail(for: row) {
                picture = thumbnail
            }
            let imageRect = fitted(picture?.size ?? NSSize(width: side, height: side),
                                   in: NSRect(x: cell.midX - side / 2, y: cell.minY + 4, width: side, height: side))
            picture?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawText(row.item.name, in: nameRect(for: index), font: font, color: color, alignment: .center, lines: 2)
        case .tiles:
            // Ikona 40 px vlevo, vpravo jméno, typ a velikost/datum.
            image?.draw(in: NSRect(x: cell.minX + 6, y: cell.minY + 6, width: 40, height: 40),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let textX = cell.minX + 52
            let width = cell.width - 58
            drawText(row.item.name, in: nameRect(for: index), font: font, color: color, alignment: .left)
            drawText(typeDescription(for: row), in: NSRect(x: textX, y: cell.minY + 20, width: width, height: 14),
                     font: NSFont.systemFont(ofSize: 11), color: secondary, alignment: .left)
            if !row.isParent {
                // Adresář jen se spočítanou velikostí (⌥F10), jinak bez velikosti.
                let bytes = row.item.isDir ? owner?.panel.dirSize(of: row.item) : row.item.size
                let size = bytes.map { formatSize($0) + ", " } ?? ""
                drawText(size + formatDay(row.item.mtime) + " " + formatTime(row.item.mtime),
                         in: NSRect(x: textX, y: cell.minY + 34, width: width, height: 14),
                         font: NSFont.systemFont(ofSize: 11), color: secondary, alignment: .left)
            }
        default:
            break
        }
    }

    /// Text do obdélníku (zkracování na konci, volitelně víc řádků).
    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment, lines: Int = 1) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        // Jeden řádek se zkracuje, víc řádků se zalamuje (poslední se zkrátí).
        style.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let options: NSString.DrawingOptions = lines > 1 ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine] : [.usesLineFragmentOrigin]
        (text as NSString).draw(with: rect, options: options, attributes: attributes)
    }

    /// Obdélník se zachováním poměru stran obrázku (na střed cílové plochy).
    private func fitted(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        // Ikony jsou vícerozlišovací, zvětšení i zmenšení je bezztrátové.
        let scale = min(box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    /// Miniatura souboru na lokálním disku (Quick Look, asynchronně; nil = zatím ikona).
    private func thumbnail(for row: Row) -> NSImage? {
        guard let owner, let path = owner.panel.localPath(of: row.item.name) else { return nil }
        if let cached = thumbnails[path] { return cached }
        guard !pendingThumbnails.contains(path) else { return nil }
        pendingThumbnails.insert(path)
        let scale = window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 92, height: 92),
                                                   scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingThumbnails.remove(path)
                if let image = representation?.nsImage {
                    self.thumbnails[path] = image
                    self.needsDisplay = true
                }
            }
        }
        return nil
    }

    /// Při změně adresáře se miniatury zahodí (šetření paměti).
    func clearThumbnails() {
        thumbnails.removeAll()
        pendingThumbnails.removeAll()
    }

    // MARK: - Vstup (společná logika v PanelView)

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        owner.handleKeyDown(event, in: self)
    }

    override func doCommand(by selector: Selector) {
        if owner?.handleCommand(selector) != true {
            super.doCommand(by: selector)
        }
    }

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

    /// Rozpracované tažení (místo stisku myši).
    private var dragStart = PanelDragStart()

    override func mouseDown(with event: NSEvent) {
        let index = index(at: convert(event.locationInWindow, from: nil))
        dragStart.begin(index: index, event: event)
        owner?.handleClick(index: index, event: event, anchor: &anchorRow, in: self)
    }

    /// Tažení myší z položky = přetažení souborů do druhého panelu nebo jiné aplikace.
    override func mouseDragged(with event: NSEvent) {
        if let index = dragStart.indexToDrag(event) {
            owner?.beginFileDrag(index: index, event: event, in: self, undoMarkToggle: dragStart.toggledMark)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.handleContextMenu(index: index(at: convert(event.locationInWindow, from: nil)), in: self)
    }
}
