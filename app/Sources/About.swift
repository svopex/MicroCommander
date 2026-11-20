// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Okno O aplikaci: verze aplikace a jejích součástí, údaje o sestavení
// a o systému (macOS, Mac, procesor, paměť). Text jde zkopírovat do schránky
// – hodí se k hlášení chyb.

import AppKit
import microcommander
import SwiftTerm

/// Údaje pro okno O aplikaci.
enum AboutInfo {
    /// Webová stránka projektu (GitHub Pages z index.html v kořeni repozitáře).
    static let websiteURL = URL(string: "https://svopex.github.io/MicroCommander/")!
    /// Zdrojové kódy na GitHubu.
    static let sourceURL = URL(string: "https://github.com/svopex/MicroCommander")!
    /// Hlášení chyb a návrhů (issues na GitHubu).
    static let issuesURL = sourceURL.appendingPathComponent("issues")
    /// Web autora.
    static let authorURL = URL(string: "https://svopex.eu")!
    /// Kontaktní e-mail jako odkaz mailto:. Adresa je ve zdrojovém kódu obrácená
    /// a v base64, aby ji v repozitáři na GitHubu nenašli roboti; stejný řetězec
    /// je v data-email tlačítka Poslat e-mail v index.html (při změně upravit obojí).
    static let contactURL: URL = {
        let decoded = Data(base64Encoded: "dWUueGVwb3ZzQHJlZG5hbW1vY29yY2lt")
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return URL(string: "mailto:" + String(decoded.reversed()))!
    }()

    /// Hodnota z Info.plist aplikace (prázdné hodnoty = nil).
    /// - Parameter key: klíč v Info.plist
    private static func bundleValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { return nil }
        return value
    }

    /// Textová hodnota ze sysctl (např. model Macu, název procesoru).
    /// - Parameter name: název hodnoty sysctl
    private static func sysctlString(_ name: String) -> String? {
        // Nejdřív zjistit délku, pak načíst řetězec včetně koncové nuly.
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Celočíselná hodnota ze sysctl (nil, když hodnota v systému není).
    /// - Parameter name: název hodnoty sysctl
    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    /// Architektura, pro kterou je aplikace přeložená; u x86_64 na Apple
    /// Silicon i informace o běhu přes Rosettu (sysctl.proc_translated = 1).
    private static var architecture: String {
        #if arch(arm64)
        return "arm64 (Apple Silicon, nativně)"
        #else
        return sysctlInt("sysctl.proc_translated") == 1 ? "x86_64 (přes Rosettu)" : "x86_64 (Intel)"
        #endif
    }

    /// Verze macOS s číslem sestavení, např. „macOS 26.1 (sestavení 25B78)“.
    private static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
        // Číslo sestavení systému (kern.osversion), např. 25B78.
        if let build = sysctlString("kern.osversion") { text += " (sestavení \(build))" }
        return text
    }

    /// Text okna: popis, autor a oddíly Aplikace a Systém, řádky „Popis: hodnota“.
    static var text: String {
        let info = ProcessInfo.processInfo
        // Verze a číslo sestavení z Info.plist; commit a datum doplňuje Makefile.
        var version = bundleValue("CFBundleShortVersionString") ?? "?"
        if let build = bundleValue("CFBundleVersion") { version += " (sestavení \(build))" }
        var application = ["Verze: \(version)"]
        if let commit = bundleValue("MCBuildCommit") { application.append("Commit: \(commit)") }
        if let date = bundleValue("MCBuildDate") { application.append("Sestaveno: \(date)") }
        application += [
            "Architektura: \(architecture)",
            "Jádro: salcore \(String(cString: sal_version())) (Rust)",
            "Terminál: SwiftTerm \(SwiftTermBuildInfo.version)",
            "Nejstarší podporovaný systém: macOS \(bundleValue("LSMinimumSystemVersion") ?? "?")",
        ]

        var system = [systemVersion]
        // Model Macu (např. Mac16,1) a procesor (např. Apple M4).
        if let model = sysctlString("hw.model") { system.append("Mac: \(model)") }
        let cores = "\(info.activeProcessorCount) jader"
        system.append("Procesor: " + (sysctlString("machdep.cpu.brand_string").map { "\($0), \(cores)" } ?? cores))
        system.append("Paměť: \(formatSize(info.physicalMemory))")
        system.append("Jazyk: \(Locale.current.identifier)")
        system.append("Spuštěno: \(Bundle.main.bundlePath)")

        return "Dvoupanelový správce souborů pro macOS – přepis Open Salamanderu (bez pluginů).\n"
            + "Autor: © 2026 Svopex – \(authorURL.absoluteString)\n\n"
            + "Aplikace\n" + application.map { "  " + $0 }.joined(separator: "\n")
            + "\n\nSystém\n" + system.map { "  " + $0 }.joined(separator: "\n")
    }

    /// Zobrazí okno O aplikaci uprostřed obrazovky (nezávisle na hlavním okně);
    /// tlačítko Kopírovat informace dá text do schránky, tlačítka s odkazy
    /// otevřou web projektu, zdrojový kód a hlášení chyb na GitHubu, web autora
    /// a poštovního klienta s kontaktním e-mailem (adresa se v okně nezobrazuje).
    static func show() {
        let text = self.text
        let copyButton = 1
        let links = [
            DialogLink(title: "Webová stránka", symbol: "globe", url: websiteURL),
            DialogLink(title: "Zdrojový kód na GitHubu", symbol: "chevron.left.forwardslash.chevron.right", url: sourceURL),
            DialogLink(title: "Nahlásit chybu na GitHubu", symbol: "ladybug", url: issuesURL),
            DialogLink(title: "Web autora", symbol: "person.crop.circle", url: authorURL),
            DialogLink(title: "Poslat e-mail", symbol: "envelope", url: contactURL),
        ]
        if PromptDialog.show(title: "MicroCommander", message: text, icon: NSApp.applicationIconImage,
                             buttons: ["OK", "Kopírovat informace"], links: links, over: nil) == copyButton {
            copyTextToPasteboard("MicroCommander\n" + text)
        }
    }
}
