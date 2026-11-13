// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Barevná schémata panelů podle Konfigurace › Panely › Barvy Salamandera
// (SalamanderColors, ExplorerColors, NortonColors, NavigatorColors
// v salamdr1.cpp) a k nim macOS schémata se systémovými barvami.

import AppKit

/// Barevné schéma panelů (uložené v UserDefaults pod svým rawValue).
enum PanelColorScheme: String, CaseIterable {
    case macSystem, macDark, salamander, explorer, norton, navigator

    /// Výchozí schéma bez uložené volby: systémové barvy, světlý/tmavý podle macOS.
    static let defaultScheme = PanelColorScheme.macSystem

    /// Název v Nastavení (jména schémat převzatá ze Salamandera).
    var title: String {
        switch self {
        case .macDark: return "macOS – tmavé"
        case .macSystem: return "macOS – podle systému"
        case .salamander: return "Open Salamander"
        case .explorer: return "Windows Explorer"
        case .norton: return "Norton Commander"
        case .navigator: return "DOS Navigator"
        }
    }

    /// Vzhled celé aplikace: tmavé schéma vynutí tmavý režim, systémové sleduje
    /// macOS, klasická schémata ze Salamandera mají světlé okolí jako ve Windows.
    var appearance: NSAppearance? {
        switch self {
        case .macDark: return NSAppearance(named: .darkAqua)
        case .macSystem: return nil
        default: return NSAppearance(named: .aqua)
        }
    }

    /// Barvy schématu (hotové konstanty, při kreslení se nic nesestavuje).
    var colors: PanelColors {
        switch self {
        case .macDark, .macSystem: return .system
        case .salamander: return .salamander
        case .explorer: return .explorer
        case .norton: return .norton
        case .navigator: return .navigator
        }
    }
}

/// Barva z 8bitových složek RGB (hodnoty jako v tabulkách Salamandera).
private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
}

/// Barvy panelu jednoho schématu (význam podle položek ITEM_*, FOCUS_*
/// a *_CAPTION_* Salamandera). „Kurzor“ = FOCUSED, „označená“ = SELECTED.
struct PanelColors {
    /// Barvy aktuálního schématu; nastavuje Settings.applyAppearance (start
    /// a změna schématu), kreslení panelů je jen čte.
    static var current = PanelColors.system

    // Text položek: běžná, označená, pod kurzorem, označená pod kurzorem.
    let itemText: NSColor
    let markedText: NSColor
    let cursorText: NSColor
    let cursorMarkedText: NSColor
    // Pozadí položek ve stejném členění.
    let itemBackground: NSColor
    let markedBackground: NSColor
    let cursorBackground: NSColor
    let cursorMarkedBackground: NSColor
    // Rámeček kurzoru v aktivním panelu (běžná / označená položka); průhledná
    // barva = bez rámečku.
    let cursorFrame: NSColor
    let cursorMarkedFrame: NSColor
    // Kurzor v neaktivním panelu: tečkovaný rámeček – barva teček a mezer mezi
    // nimi (pero FOCUS_FG_INACTIVE_* / FOCUS_BK_INACTIVE_*, běžná / označená).
    let inactiveFrame: NSColor
    let inactiveMarkedFrame: NSColor
    let inactiveFrameGap: NSColor
    let inactiveMarkedFrameGap: NSColor
    // Řádek adresáře (titulek panelu) aktivního a neaktivního panelu.
    let activeCaptionText: NSColor
    let activeCaptionBackground: NSColor
    let inactiveCaptionText: NSColor
    let inactiveCaptionBackground: NSColor
    /// Skrytá položka a druhotný text (typ, velikost v Dlaždicích) mimo kurzor.
    let hiddenText: NSColor

    /// Vytvoří schéma; bez hiddenText se skrytý text odvodí prolnutím běžného
    /// textu s pozadím (klasická schémata Salamandera nemají vlastní barvu).
    init(itemText: NSColor, markedText: NSColor, cursorText: NSColor, cursorMarkedText: NSColor,
         itemBackground: NSColor, markedBackground: NSColor,
         cursorBackground: NSColor, cursorMarkedBackground: NSColor,
         cursorFrame: NSColor, cursorMarkedFrame: NSColor,
         inactiveFrame: NSColor, inactiveMarkedFrame: NSColor,
         inactiveFrameGap: NSColor, inactiveMarkedFrameGap: NSColor,
         activeCaptionText: NSColor, activeCaptionBackground: NSColor,
         inactiveCaptionText: NSColor, inactiveCaptionBackground: NSColor,
         hiddenText: NSColor? = nil) {
        self.itemText = itemText
        self.markedText = markedText
        self.cursorText = cursorText
        self.cursorMarkedText = cursorMarkedText
        self.itemBackground = itemBackground
        self.markedBackground = markedBackground
        self.cursorBackground = cursorBackground
        self.cursorMarkedBackground = cursorMarkedBackground
        self.cursorFrame = cursorFrame
        self.cursorMarkedFrame = cursorMarkedFrame
        self.inactiveFrame = inactiveFrame
        self.inactiveMarkedFrame = inactiveMarkedFrame
        self.inactiveFrameGap = inactiveFrameGap
        self.inactiveMarkedFrameGap = inactiveMarkedFrameGap
        self.activeCaptionText = activeCaptionText
        self.activeCaptionBackground = activeCaptionBackground
        self.inactiveCaptionText = inactiveCaptionText
        self.inactiveCaptionBackground = inactiveCaptionBackground
        self.hiddenText = hiddenText ?? itemText.blended(withFraction: 0.45, of: itemBackground) ?? itemText
    }

    /// Současný vzhled macOS – dynamické systémové barvy (sledují světlý/tmavý
    /// režim): kurzor bez rámečku, v neaktivním panelu jen tečkovaný rámeček.
    static let system = PanelColors(
        itemText: .labelColor, markedText: .systemRed,
        cursorText: .alternateSelectedControlTextColor,
        cursorMarkedText: NSColor(calibratedRed: 1, green: 0.86, blue: 0.35, alpha: 1),
        itemBackground: .controlBackgroundColor, markedBackground: .controlBackgroundColor,
        cursorBackground: .selectedContentBackgroundColor,
        cursorMarkedBackground: .selectedContentBackgroundColor,
        cursorFrame: .clear, cursorMarkedFrame: .clear,
        inactiveFrame: .secondaryLabelColor, inactiveMarkedFrame: .secondaryLabelColor,
        inactiveFrameGap: .clear, inactiveMarkedFrameGap: .clear,
        activeCaptionText: .white, activeCaptionBackground: .controlAccentColor,
        inactiveCaptionText: .labelColor,
        inactiveCaptionBackground: .unemphasizedSelectedContentBackgroundColor,
        hiddenText: .secondaryLabelColor)

    /// Open Salamander: bílé pozadí, označené červeně, kurzor světle šedý
    /// s černým rámečkem.
    static let salamander = PanelColors(
        itemText: .black, markedText: rgb(255, 0, 0),
        cursorText: .black, cursorMarkedText: rgb(255, 0, 0),
        itemBackground: .white, markedBackground: .white,
        cursorBackground: rgb(232, 232, 232), cursorMarkedBackground: rgb(232, 232, 232),
        cursorFrame: .black, cursorMarkedFrame: .black,
        inactiveFrame: rgb(128, 128, 128), inactiveMarkedFrame: rgb(128, 128, 128),
        inactiveFrameGap: .white, inactiveMarkedFrameGap: .white,
        activeCaptionText: .white, activeCaptionBackground: rgb(0, 0, 128),
        inactiveCaptionText: .white, inactiveCaptionBackground: rgb(128, 128, 128))

    /// Windows Explorer: označené položky bíle na tmavě modrém pozadí.
    static let explorer = PanelColors(
        itemText: .black, markedText: .white,
        cursorText: .black, cursorMarkedText: .white,
        itemBackground: .white, markedBackground: rgb(0, 0, 128),
        cursorBackground: rgb(232, 232, 232), cursorMarkedBackground: rgb(0, 0, 128),
        cursorFrame: .black, cursorMarkedFrame: rgb(255, 255, 0),
        inactiveFrame: rgb(128, 128, 128), inactiveMarkedFrame: rgb(0, 0, 128),
        inactiveFrameGap: .white, inactiveMarkedFrameGap: rgb(255, 255, 0),
        activeCaptionText: .white, activeCaptionBackground: rgb(0, 0, 128),
        inactiveCaptionText: .white, inactiveCaptionBackground: rgb(128, 128, 128))

    /// Norton Commander: azurový text na tmavě modrém pozadí, označené žlutě,
    /// kurzor tyrkysový.
    static let norton = PanelColors(
        itemText: rgb(0, 255, 255), markedText: rgb(255, 255, 0),
        cursorText: .black, cursorMarkedText: rgb(255, 255, 0),
        itemBackground: rgb(0, 0, 128), markedBackground: rgb(0, 0, 128),
        cursorBackground: rgb(0, 128, 128), cursorMarkedBackground: rgb(0, 128, 128),
        cursorFrame: rgb(0, 128, 128), cursorMarkedFrame: rgb(0, 128, 128),
        inactiveFrame: rgb(0, 128, 128), inactiveMarkedFrame: rgb(0, 128, 128),
        inactiveFrameGap: rgb(0, 0, 128), inactiveMarkedFrameGap: rgb(0, 0, 128),
        activeCaptionText: .white, activeCaptionBackground: rgb(0, 0, 128),
        inactiveCaptionText: .white, inactiveCaptionBackground: rgb(128, 128, 128))

    /// DOS Navigator: bílý text na tmavě šedém pozadí, označené žlutě, kurzor
    /// tyrkysový.
    static let navigator = PanelColors(
        itemText: .white, markedText: rgb(255, 255, 0),
        cursorText: .black, cursorMarkedText: rgb(255, 255, 0),
        itemBackground: rgb(80, 80, 80), markedBackground: rgb(80, 80, 80),
        cursorBackground: rgb(0, 128, 128), cursorMarkedBackground: rgb(0, 128, 128),
        cursorFrame: rgb(0, 128, 128), cursorMarkedFrame: rgb(0, 128, 128),
        inactiveFrame: rgb(0, 128, 128), inactiveMarkedFrame: rgb(0, 128, 128),
        inactiveFrameGap: rgb(0, 0, 128), inactiveMarkedFrameGap: rgb(0, 0, 128),
        activeCaptionText: .white, activeCaptionBackground: rgb(0, 0, 128),
        inactiveCaptionText: .white, inactiveCaptionBackground: rgb(128, 128, 128))

    /// Barva textu položky.
    /// - Parameters:
    ///   - marked: položka je označená
    ///   - onActiveCursor: položka je pod kurzorem aktivního panelu
    ///   - hidden: skrytá položka (ztlumená barva)
    func text(marked: Bool, onActiveCursor: Bool, hidden: Bool) -> NSColor {
        if marked {
            return onActiveCursor ? cursorMarkedText : markedText
        }
        if onActiveCursor {
            return cursorText
        }
        return hidden ? hiddenText : itemText
    }

    /// Pozadí položky mimo kurzor (označené položky mohou mít vlastní pozadí).
    func background(marked: Bool) -> NSColor {
        marked ? markedBackground : itemBackground
    }

    /// Vykreslí kurzor: v aktivním panelu výplň a rámeček, v neaktivním jen
    /// tečkovaný rámeček (podle FOCUS_* barev). Rámeček leží o půl bodu uvnitř
    /// obdélníku, aby byla čára ostrá.
    /// - Parameters:
    ///   - rect: obdélník kurzoru
    ///   - cornerRadius: zaoblení rohů (0 = tabulka, mřížka zaobluje)
    ///   - active: panel je aktivní
    ///   - marked: položka pod kurzorem je označená
    func drawCursor(in rect: NSRect, cornerRadius: CGFloat = 0, active: Bool, marked: Bool) {
        if active {
            (marked ? cursorMarkedBackground : cursorBackground).setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = 1
        if active {
            (marked ? cursorMarkedFrame : cursorFrame).setStroke()
            path.stroke()
            return
        }
        // Mezery mezi tečkami: nejdřív plná čára barvou mezer, přes ni tečky.
        (marked ? inactiveMarkedFrameGap : inactiveFrameGap).setStroke()
        path.stroke()
        path.setLineDash([2, 2], count: 2, phase: 0)
        (marked ? inactiveMarkedFrame : inactiveFrame).setStroke()
        path.stroke()
    }
}
