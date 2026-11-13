// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vykreslí ikonu aplikace (1024×1024 PNG) ve stylu Salamandera: tmavá macOS
// dlaždice, oranžový lesklý disk a bílá stylizovaná tlapka mloka.
// Použití: swift tools/make-icon.swift <výstup.png>
// (sadu velikostí a .icns z PNG sestaví `make icon`).

import AppKit

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let space = CGColorSpaceCreateDeviceRGB()

/// Barva ze složek 0–255.
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Lineární nebo radiální gradient ze dvou a více barev.
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Nelze vytvořit kontext")
}

// Dlaždice podle mřížky ikon macOS: 824×824 se zaoblením ~185 uprostřed plátna,
// pod ní měkký stín.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(30, 33, 38))
ctx.fillPath()
ctx.restoreGState()

// Tmavý svislý gradient dlaždice (nahoře světlejší).
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(58, 63, 72), rgb(22, 24, 28)], [0, 1]),
                       start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// Oranžový disk se světlým okrajem (prsten) a stínem.
let center = CGPoint(x: 512, y: 512)
let ringRadius: CGFloat = 352
let discRadius: CGFloat = 326
let ringRect = CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2)
let discRect = CGRect(x: center.x - discRadius, y: center.y - discRadius, width: discRadius * 2, height: discRadius * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0, 0, 0, 0.5))
ctx.addEllipse(in: ringRect)
ctx.setFillColor(rgb(235, 236, 238))
ctx.fillPath()
ctx.restoreGState()
// Prsten s jemným gradientem (kovový vzhled).
ctx.saveGState()
ctx.addEllipse(in: ringRect)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(255, 255, 255), rgb(170, 174, 182)], [0, 1]),
                       start: CGPoint(x: 0, y: center.y + ringRadius), end: CGPoint(x: 0, y: center.y - ringRadius), options: [])
ctx.restoreGState()
// Disk: radiální gradient od světle žluté vlevo nahoře k sytě oranžové na okraji.
ctx.saveGState()
ctx.addEllipse(in: discRect)
ctx.clip()
ctx.drawRadialGradient(gradient([rgb(255, 214, 92), rgb(247, 158, 18), rgb(204, 102, 0)], [0, 0.55, 1]),
                       startCenter: CGPoint(x: center.x - 110, y: center.y + 130), startRadius: 0,
                       endCenter: center, endRadius: discRadius, options: [.drawsAfterEndLocation])
ctx.restoreGState()

// Tlapka mloka: dlaň (elipsa) a pět prstů – zakřivené tahy s kulatými polštářky.
// Souřadnice v systému s počátkem uprostřed disku, tlapka míří vpravo nahoru.
// Části se nakonec sjednotí do jednoho obrysu (jinak by se překryvy při
// vyplňování vyrušily a vznikly by díry).
let palmCenter = CGPoint(x: center.x - 30, y: center.y - 60)
var footParts: [CGPath] = [CGPath(ellipseIn: CGRect(x: palmCenter.x - 160, y: palmCenter.y - 140, width: 320, height: 280),
                                  transform: nil)]

// Prst: úhel (stupně, 0 = vpravo, proti směru hodin), délka, ohyb a velikost polštářku.
struct Toe {
    let angle: CGFloat
    let length: CGFloat
    let bend: CGFloat
    let pad: CGFloat
}
let toes = [
    Toe(angle: 172, length: 222, bend: -24, pad: 58),
    Toe(angle: 124, length: 262, bend: -20, pad: 64),
    Toe(angle: 80, length: 285, bend: 18, pad: 68),
    Toe(angle: 37, length: 255, bend: 22, pad: 64),
    Toe(angle: -8, length: 215, bend: 24, pad: 58),
]
let toeWidth: CGFloat = 100
for toe in toes {
    let radians = toe.angle * .pi / 180
    let direction = CGPoint(x: cos(radians), y: sin(radians))
    let normal = CGPoint(x: -direction.y, y: direction.x)
    let start = CGPoint(x: palmCenter.x + direction.x * 60, y: palmCenter.y + direction.y * 60)
    let end = CGPoint(x: palmCenter.x + direction.x * toe.length, y: palmCenter.y + direction.y * toe.length)
    // Kontrolní bod uprostřed posunutý kolmo – prst se mírně ohýbá.
    let control = CGPoint(x: (start.x + end.x) / 2 + normal.x * toe.bend, y: (start.y + end.y) / 2 + normal.y * toe.bend)
    let stroke = CGMutablePath()
    stroke.move(to: start)
    stroke.addQuadCurve(to: end, control: control)
    footParts.append(stroke.copy(strokingWithWidth: toeWidth, lineCap: .round, lineJoin: .round, miterLimit: 1))
    // Polštářek na konci prstu (širší než prst).
    footParts.append(CGPath(ellipseIn: CGRect(x: end.x - toe.pad, y: end.y - toe.pad, width: toe.pad * 2, height: toe.pad * 2),
                            transform: nil))
}
let foot = footParts.dropFirst().reduce(footParts[0]) { $0.union($1) }

// Stín tlapky na disku, pak bílá výplň s jemným gradientem.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 10, height: -16), blur: 18, color: rgb(120, 50, 0, 0.55))
ctx.addPath(foot)
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(foot)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(255, 255, 255), rgb(226, 228, 232)], [0, 1]),
                       start: CGPoint(x: 0, y: center.y + 360), end: CGPoint(x: 0, y: center.y - 300), options: [])
ctx.restoreGState()

// Lesk v horní části disku (průhledná elipsa).
ctx.saveGState()
ctx.addEllipse(in: discRect)
ctx.clip()
let glossRect = CGRect(x: center.x - 250, y: center.y + 90, width: 500, height: 270)
ctx.addEllipse(in: glossRect)
ctx.clip()
ctx.drawLinearGradient(gradient([rgb(255, 255, 255, 0.38), rgb(255, 255, 255, 0)], [0, 1]),
                       start: CGPoint(x: 0, y: glossRect.maxY), end: CGPoint(x: 0, y: glossRect.minY), options: [])
ctx.restoreGState()

// Zápis PNG.
guard let image = ctx.makeImage() else { fatalError("Nelze vytvořit obrázek") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Nelze zakódovat PNG") }
try data.write(to: URL(fileURLWithPath: outputPath))
print("Ikona: \(outputPath)")
