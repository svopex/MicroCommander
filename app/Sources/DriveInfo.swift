// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Informace o jednotce (⌘F1 / ⌃F1, v Salamanderu Ctrl+F1): svazek, na kterém
// leží adresář panelu – název, přípojný bod, zařízení, typ, využité a volné
// místo s koláčovým grafem, bloky a systém souborů s příznaky.

import AppKit

/// Údaje o svazku (připojeném souborovém systému).
struct VolumeInfo {
    /// Název svazku.
    var name: String
    /// Přípojný bod (adresář, kam je svazek připojený).
    var mountPoint: String
    /// Zařízení nebo síťový zdroj svazku (např. /dev/disk3s1, //uživatel@server/sdílení).
    var device: String
    /// UUID svazku (prázdné, pokud ho souborový systém nemá).
    var uuid: String
    /// Slovní popis typu (interní disk, síťová jednotka…).
    var type: String
    /// Kapacita, volné a využité místo v bajtech.
    var capacity: UInt64
    var free: UInt64
    var used: UInt64 { capacity >= free ? capacity - free : 0 }
    /// Velikost bloku v bajtech, počet bloků a počet volných bloků.
    var blockSize: UInt64
    var blockCount: UInt64
    var freeBlocks: UInt64
    /// Název systému souborů (např. „APFS (apfs)“).
    var fileSystem: String
    /// Příznaky systému souborů (slovně).
    var flags: [String]

    /// Načte údaje o svazku, na kterém leží daná cesta.
    /// - Parameter path: cesta na lokálním disku
    /// - Returns: údaje, nil když svazek nelze zjistit (cesta neexistuje apod.)
    static func load(path: String) -> VolumeInfo? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        // Pole pevné délky ze struktury statfs (C řetězce) převedeme na String.
        func string<Field>(_ field: Field) -> String {
            withUnsafeBytes(of: field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        let mountPoint = string(stats.f_mntonname)
        let device = string(stats.f_mntfromname)
        let typeName = string(stats.f_fstypename)

        // Vlastnosti svazku z Foundation (název, UUID, typ, podporované funkce).
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeUUIDStringKey,
            .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsLocalKey,
            .volumeIsReadOnlyKey, .volumeIsEncryptedKey, .volumeIsJournalingKey,
            .volumeSupportsCaseSensitiveNamesKey, .volumeSupportsCasePreservedNamesKey,
            .volumeSupportsCompressionKey, .volumeSupportsHardLinksKey, .volumeSupportsSymbolicLinksKey,
            .volumeSupportsSparseFilesKey, .volumeSupportsFileCloningKey, .volumeSupportsExtendedSecurityKey,
        ]
        let values = try? URL(fileURLWithPath: mountPoint).resourceValues(forKeys: keys)

        // Typ: síťová jednotka se pozná podle příznaku MNT_LOCAL, ostatní podle
        // vlastností svazku (interní / výměnný / externí).
        let isLocal = values?.volumeIsLocal ?? (stats.f_flags & UInt32(MNT_LOCAL) != 0)
        let type: String
        if !isLocal {
            type = "síťová jednotka"
        } else if values?.volumeIsInternal == true {
            type = "interní disk"
        } else if values?.volumeIsRemovable == true || values?.volumeIsEjectable == true {
            type = "výměnný disk"
        } else {
            type = "externí disk"
        }

        // Příznaky: jen ty, které svazek opravdu má (nil = neznámé, vynechá se).
        var flags: [String] = []
        let readOnly = values?.volumeIsReadOnly ?? (stats.f_flags & UInt32(MNT_RDONLY) != 0)
        if readOnly { flags.append("jen pro čtení") }
        if let caseSensitive = values?.volumeSupportsCaseSensitiveNames {
            flags.append(caseSensitive ? "rozlišuje malá a velká písmena v názvech" : "nerozlišuje malá a velká písmena v názvech")
        }
        let optionalFlags: [(Bool?, String)] = [
            (values?.volumeSupportsCasePreservedNames, "zachovává malá a velká písmena v názvech"),
            (values?.volumeIsEncrypted, "šifrovaný"),
            (values?.volumeIsJournaling, "žurnálovaný"),
            (values?.volumeSupportsCompression, "podporuje zhuštěné soubory"),
            (values?.volumeSupportsSparseFiles, "podporuje řídké soubory"),
            (values?.volumeSupportsFileCloning, "podporuje klonování souborů"),
            (values?.volumeSupportsHardLinks, "podporuje pevné odkazy"),
            (values?.volumeSupportsSymbolicLinks, "podporuje symbolické odkazy"),
            (values?.volumeSupportsExtendedSecurity, "podporuje seznamy oprávnění (ACL)"),
        ]
        flags += optionalFlags.filter { $0.0 == true }.map(\.1)

        // Název systému souborů: lokalizovaný popis + interní jméno (liší-li se).
        var fileSystem = typeName
        if let description = values?.volumeLocalizedFormatDescription, !description.isEmpty,
           description.lowercased() != typeName.lowercased() {
            fileSystem = "\(description) (\(typeName))"
        }

        // Místo: volné = bloky dostupné běžnému uživateli (stejně jako řádek
        // adresáře), využité = kapacita − volné.
        let blockSize = UInt64(stats.f_bsize)
        return VolumeInfo(name: values?.volumeName ?? (mountPoint as NSString).lastPathComponent,
                          mountPoint: mountPoint, device: device, uuid: values?.volumeUUIDString ?? "",
                          type: type, capacity: UInt64(stats.f_blocks) * blockSize,
                          free: UInt64(stats.f_bavail) * blockSize, blockSize: blockSize,
                          blockCount: UInt64(stats.f_blocks), freeBlocks: UInt64(stats.f_bfree),
                          fileSystem: fileSystem, flags: flags)
    }
}

/// Koláčový graf využitého a volného místa.
private final class UsagePieView: NSView {
    static let usedColor = NSColor.systemBlue
    static let freeColor = NSColor.systemGreen

    /// Podíl volného místa (0–1).
    var freeFraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        // Celý kruh = využité místo, přes něj výseč volného místa od „12 hodin“
        // ve směru hodinových ručiček.
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        UsagePieView.usedColor.setFill()
        circle.fill()
        let fraction = min(max(freeFraction, 0), 1)
        guard fraction > 0 else { return }
        UsagePieView.freeColor.setFill()
        if fraction >= 1 {
            circle.fill()
            return
        }
        let wedge = NSBezierPath()
        wedge.move(to: center)
        wedge.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
        wedge.close()
        wedge.fill()
    }
}

/// Okno dialogu: Escape (i ⌘.) dialog zavře, i když nemá tlačítko Zrušit.
private final class DriveInfoWindow: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.escape {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Dialog Informace o jednotce (sheet nad hlavním oknem), jen pro čtení.
final class DriveInfoDialog: NSWindowController {
    private static let width: CGFloat = 600

    /// Sestaví dialog; zobrazuje se jako sheet (MainWindowController.presentSheet).
    /// - Parameter info: údaje o svazku
    init(info: VolumeInfo) {
        // Výška je jen výchozí – buildContent ji dopočítá podle obsahu.
        let window = DriveInfoWindow(contentRect: NSRect(x: 0, y: 0, width: DriveInfoDialog.width, height: 0),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Informace o jednotce"
        super.init(window: window)
        window.onCancel = { [weak self] in self?.close(nil) }
        buildContent(info)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Hodnota řádku: lze ji označit a zkopírovat; dlouhý text se zkrátí
    /// uprostřed a celý je v tooltipu.
    private func makeValue(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text
        return field
    }

    /// Rozvržení podle dialogu Salamandera: svazek, místo s grafem, bloky,
    /// systém souborů. Výška dialogu se dopočítá podle textu příznaků.
    private func buildContent(_ info: VolumeInfo) {
        let width = DriveInfoDialog.width
        // Sloupce popisků a hodnot, výška řádku.
        let labelX: CGFloat = 70
        let valueX: CGFloat = 230
        let valueWidth = width - valueX - 16
        let rowHeight: CGFloat = 24
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 16

        // Přidá řádek „popisek: hodnota“ (hodnota s danou výškou) a posune se na další.
        func addRow(_ label: String, _ value: NSTextField, height: CGFloat = 17) {
            content.place(NSTextField(labelWithString: label), NSRect(x: labelX, y: y, width: valueX - labelX - 8, height: 17))
            content.place(value, NSRect(x: valueX, y: y, width: valueWidth, height: height))
            y += max(rowHeight, height + 7)
        }
        func addRow(_ label: String, _ value: String) {
            addRow(label, makeValue(value))
        }

        // Vodorovná čára mezi oddíly.
        func addSeparator() {
            let line = NSBox(frame: NSRect(x: 12, y: y + 4, width: width - 24, height: 1))
            line.boxType = .separator
            content.addSubview(line)
            y += 18
        }

        // Svazek: ikona disku vlevo, vedle ní základní údaje.
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: info.mountPoint))
        content.place(icon, NSRect(x: 18, y: y, width: 36, height: 36))
        addRow("Název svazku:", info.name)
        addRow("Přípojný bod:", info.mountPoint)
        addRow("Zařízení:", info.device)
        addRow("UUID svazku:", info.uuid.isEmpty ? "–" : info.uuid)
        addRow("Typ:", info.type)
        addSeparator()

        // Místo: barevná značka (legenda grafu), popisek, bajty a zaokrouhlená
        // velikost zarovnané vpravo, vpravo koláčový graf.
        let spaceTop = y
        let spaceRows: [(String, UInt64, NSColor?)] = [
            ("Využité místo:", info.used, UsagePieView.usedColor),
            ("Volné místo:", info.free, UsagePieView.freeColor),
            ("Kapacita:", info.capacity, nil),
        ]
        for (label, bytes, color) in spaceRows {
            if let color {
                let swatch = NSBox(frame: NSRect(x: 34, y: y + 1, width: 16, height: 15))
                swatch.boxType = .custom
                swatch.borderWidth = 1
                swatch.borderColor = .separatorColor
                swatch.cornerRadius = 2
                swatch.fillColor = color
                content.addSubview(swatch)
            }
            content.place(NSTextField(labelWithString: label), NSRect(x: labelX, y: y, width: 110, height: 17))
            content.place(makeValue(formatExactSize(bytes) + " bajtů", alignment: .right),
                          NSRect(x: 180, y: y, width: 190, height: 17))
            content.place(makeValue(formatSize(bytes), alignment: .right), NSRect(x: 376, y: y, width: 90, height: 17))
            y += rowHeight
        }
        let pie = UsagePieView()
        pie.freeFraction = info.capacity > 0 ? CGFloat(info.free) / CGFloat(info.capacity) : 0
        pie.toolTip = String(format: "Volných %.1f %%", pie.freeFraction * 100)
        content.place(pie, NSRect(x: width - 16 - 76, y: spaceTop - 4, width: 76, height: 76))
        addSeparator()

        // Bloky (obdoba sektorů a clusterů ve Windows).
        addRow("Bajtů v bloku:", formatExactSize(info.blockSize))
        addRow("Počet bloků:", formatExactSize(info.blockCount))
        addRow("Volných bloků:", formatExactSize(info.freeBlocks))
        addSeparator()

        // Systém souborů a jeho příznaky (zalomený text, výška podle obsahu).
        addRow("Systém souborů:", info.fileSystem)
        let flagsField = NSTextField(wrappingLabelWithString: info.flags.isEmpty ? "–" : info.flags.joined(separator: ", "))
        flagsField.isSelectable = true
        let flagsHeight = ceil(flagsField.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: valueWidth, height: 10000)).height ?? 17)
        addRow("Příznaky:", flagsField, height: flagsHeight)
        addSeparator()

        // Tlačítko Zavřít (Enter; Escape řeší okno).
        let closeButton = NSButton(title: "Zavřít", target: self, action: #selector(close(_:)))
        closeButton.keyEquivalent = "\r"
        content.place(closeButton, NSRect(x: (width - 110) / 2, y: y, width: 110, height: 28))
        y += 28 + 16

        content.setFrameSize(NSSize(width: width, height: y))
        window?.setContentSize(NSSize(width: width, height: y))
        window?.contentView = content
        // Fokus na tlačítku, aby žádná hodnota nebyla po otevření označená.
        window?.initialFirstResponder = closeButton
    }

    /// Zavře sheet.
    @objc private func close(_ sender: Any?) {
        if let window { window.sheetParent?.endSheet(window) }
    }
}
