// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Obsazené místo (⌥F10 / ⌃Q, v Salamanderu Alt+F10): výsledek počítání
// velikosti označených položek – umístění, položky, velikost v bajtech
// i zaokrouhleně a počty souborů a adresářů.

import AppKit

/// Výsledek počítání obsazeného místa.
struct OccupiedSpaceInfo {
    /// Nejvíc jmen položek v tooltipu dialogu.
    static let maxListedNames = 20

    /// Adresář panelu, ve kterém položky leží (text řádku adresáře).
    var location: String
    /// Počet měřených položek (označené, jinak položka pod kurzorem).
    var itemCount: Int
    /// Jména prvních položek (nejvýš maxListedNames).
    var itemNames: [String]
    /// Ikona položek (ikona položky, u více položek společná ikona).
    var icon: NSImage
    /// Celková velikost souborů v bajtech.
    var bytes: UInt64
    /// Počet souborů a adresářů (včetně měřených adresářů samotných).
    var files: Int
    var dirs: Int

    /// Sestaví výsledek pro položky panelu.
    /// - Parameters:
    ///   - panel: panel s měřenými položkami
    ///   - items: měřené položky (aspoň jedna)
    ///   - totals: spočítaná velikost a počty
    init(panel: PanelController, items: [Item], totals: (files: Int, dirs: Int, bytes: UInt64)) {
        location = panel.displayPath
        itemCount = items.count
        itemNames = items.prefix(OccupiedSpaceInfo.maxListedNames).map(\.name)
        bytes = totals.bytes
        files = totals.files
        dirs = totals.dirs
        // Ikona: u jedné položky na lokálním disku přímo ze souboru, v archivu
        // a na FTP ikona seznamu podle druhu; u více položek společná ikona.
        if items.count == 1, let item = items.first {
            icon = panel.localPath(of: item.name).map { NSWorkspace.shared.icon(forFile: $0) } ?? listIcon(for: item)
        } else {
            icon = NSImage(named: NSImage.multipleDocumentsName) ?? listIcon(for: items[0])
        }
    }
}

/// Dialog Obsazené místo (sheet nad hlavním oknem), jen pro čtení – stejně
/// rozvržený jako Informace o jednotce.
final class OccupiedSpaceDialog: InfoDialog {
    /// Sestaví dialog; zobrazuje se jako sheet (MainWindowController.presentSheet).
    /// - Parameter info: výsledek počítání
    init(info: OccupiedSpaceInfo) {
        super.init(title: "Obsazené místo", width: 520)
        buildContent(info)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Rozvržení: ikona s umístěním a položkami, pod čarou velikost a počty
    /// (čísla zarovnaná vpravo ve sloupci bajtů), dole tlačítko Zavřít.
    private func buildContent(_ info: OccupiedSpaceInfo) {
        // Sloupce stejné jako u řádku velikosti (InfoDialog.addSizeRow).
        let labelX: CGFloat = 70
        let valueX: CGFloat = 180
        let rowHeight: CGFloat = 24
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 16

        // Přidá řádek „popisek: hodnota“ (hodnota do dané šířky) a posune se na další.
        func addRow(_ label: String, _ value: NSTextField, width valueWidth: CGFloat) {
            content.place(NSTextField(labelWithString: label), NSRect(x: labelX, y: y, width: valueX - labelX - 8, height: 17))
            content.place(value, NSRect(x: valueX, y: y, width: valueWidth, height: 17))
            y += rowHeight
        }

        // Položky: ikona vlevo (sdílená ikona seznamu je malá, proto zvětšení),
        // vedle umístění a jméno, u více položek jejich počet.
        let icon = NSImageView(image: info.icon)
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.place(icon, NSRect(x: 18, y: y, width: 36, height: 36))
        let textWidth = width - valueX - 16
        addRow("Umístění:", makeValue(info.location), width: textWidth)
        if info.itemCount == 1 {
            addRow("Položka:", makeValue(info.itemNames[0]), width: textWidth)
        } else {
            // Jména více položek jsou v tooltipu (jen prvních pár).
            let itemsField = makeValue("\(info.itemCount) označené")
            let listed = info.itemNames.joined(separator: "\n")
            itemsField.toolTip = info.itemCount > info.itemNames.count ? listed + "\n…" : listed
            addRow("Položky:", itemsField, width: textWidth)
        }
        y = content.addSeparator(y: y)

        // Velikost a počty souborů a adresářů (vpravo ve sloupci bajtů).
        y = addSizeRow("Obsazené místo:", bytes: info.bytes, to: content, y: y)
        addRow("Souborů:", makeValue(formatExactSize(UInt64(info.files)), alignment: .right), width: 190)
        addRow("Adresářů:", makeValue(formatExactSize(UInt64(info.dirs)), alignment: .right), width: 190)
        y = content.addSeparator(y: y)

        finish(content: content, y: y)
    }
}
