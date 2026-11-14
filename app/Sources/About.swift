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

    /// Text okna: oddíly Aplikace a Systém, řádky „Popis: hodnota“.
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

        return "Dvoupanelový správce souborů pro macOS – přepis Open Salamanderu (bez pluginů).\n\n"
            + "Aplikace\n" + application.map { "  " + $0 }.joined(separator: "\n")
            + "\n\nSystém\n" + system.map { "  " + $0 }.joined(separator: "\n")
    }

    /// Zobrazí okno O aplikaci uprostřed obrazovky (nezávisle na hlavním okně);
    /// tlačítko Kopírovat informace dá text do schránky.
    static func show() {
        let text = self.text
        let copyButton = 1
        if PromptDialog.show(title: "MicroCommander", message: text, icon: NSApp.applicationIconImage,
                             buttons: ["OK", "Kopírovat informace"], over: nil) == copyButton {
            copyTextToPasteboard("MicroCommander\n" + text)
        }
    }
}
