// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Překlady uživatelského rozhraní: čeština (zdrojový jazyk) a angličtina.
//
// Zdrojové texty v kódu jsou česky a slouží zároveň jako klíče slovníku.
// Anglické překlady jsou v souborech app/Locales/en/*.json (český text →
// překlad), které Makefile kopíruje do Contents/Resources/Locales/en balíčku.
// Jazyk se určí jednou při startu (volba v Nastavení, jinak jazyk macOS) –
// změna se projeví po restartu aplikace.
//
// Pravidla pro texty:
// - uživatelský text: tr("Kopírovat"),
// - s hodnotami: tr("Smazat %@?", name) – formát String(format:), hodnoty jako
//   String (%@), v překladu lze měnit pořadí (%1$@, %2$@); ne interpolace "\(x)",
// - tvary podle počtu: plural(count, "soubor", "soubory", "souborů") (tvary se přeloží),
// - stejný český text s různými významy: trc("undo", "Zpět") – klíč slovníku "undo|Zpět"
//   (bez kontextu by „Zpět“ = vrátit úpravu kolidovalo se „Zpět“ = zpět v historii),
// - text v konstantě se přeloží až při zobrazení: tr(konstanta).
// Úplnost překladů kontroluje tools/i18n_check.py.

import Foundation

/// Jazyk rozhraní a anglický slovník.
enum Localization {
    /// Klíč v UserDefaults s volbou jazyka: "auto" (podle macOS), "cs" nebo "en".
    static let languageKey = "language"
    /// Volby jazyka pro Nastavení v pořadí nabídky (kód, popisek).
    static let choices: [(code: String, title: String)] = [
        ("auto", "Podle systému"),
        ("cs", "Čeština"),
        ("en", "English"),
    ]

    /// Uložená volba jazyka ("auto", když není nastavená nebo je neplatná).
    static var savedChoice: String {
        let value = UserDefaults.standard.string(forKey: languageKey) ?? "auto"
        return choices.contains { $0.code == value } ? value : "auto"
    }

    /// Jazyk tohoto běhu aplikace ("cs" / "en"), určený jednou při startu.
    /// Self-test a kontrola kláves běží vždy česky (hledají prvky podle českých
    /// popisků); proměnná prostředí SAL_LANG=cs/en volbu přebije (vývojářské snímky).
    static let current: String = {
        let environment = ProcessInfo.processInfo.environment
        if environment["SAL_SELFTEST"] != nil || environment["SAL_KEYCHECK"] != nil { return "cs" }
        if let forced = environment["SAL_LANG"], forced == "cs" || forced == "en" { return forced }
        let saved = savedChoice
        if saved != "auto" { return saved }
        // Podle systému: čeština, jen když ji macOS uvádí jako preferovaný jazyk,
        // jinak angličtina (srozumitelnější pro ostatní jazyky)
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("cs") ? "cs" : "en"
    }()

    /// Anglický slovník sloučený ze všech JSON souborů v Resources/Locales/en.
    static let english: [String: String] = {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Locales/en"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [:] }
        var words: [String: String] = [:]
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { continue }
            words.merge(dictionary) { _, new in new }
        }
        return words
    }()

    /// Nastaví jazyk rozhraní celému procesu: lokalizaci AppKitu (standardní
    /// položky menu, kontextová menu polí) i systémovým dialogům mimo proces
    /// (NSOpenPanel/NSSavePanel – Procházet…, export a import nastavení), které
    /// jazyk berou z AppleLanguages.
    /// Volá se jednou při startu před vytvořením NSApplication; Info.plist proto
    /// uvádí CFBundleLocalizations cs a en.
    /// Jen pro tento běh (volatilní doména argumentů, nic se neukládá); ostatní
    /// argumenty z příkazové řádky zůstávají. `current` se vyhodnotí dřív, než
    /// se AppleLanguages přepíše – volba „Podle systému“ čte skutečný jazyk macOS.
    static func applyToProcess() {
        let language = current
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [language]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}

/// Přeloží český text do jazyka rozhraní (bez překladu vrátí originál).
/// - Parameter text: český zdrojový text (klíč slovníku)
func tr(_ text: String) -> String {
    guard Localization.current == "en" else { return text }
    return Localization.english[text] ?? text
}

/// Přeloží formátovací řetězec a dosadí hodnoty (String(format:)).
/// - Parameters:
///   - format: český formát s %@ (případně %1$@ …) – klíč slovníku
///   - arguments: hodnoty k dosazení
func tr(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: tr(format), arguments: arguments)
}

/// Přeloží text s kontextem (stejný český text s různými významy).
/// Klíč slovníku je "kontext|text", bez něj se použije obyčejný překlad textu.
/// - Parameters:
///   - context: krátký anglický název kontextu, např. "undo"
///   - text: český zdrojový text
func trc(_ context: String, _ text: String) -> String {
    guard Localization.current == "en" else { return text }
    return Localization.english["\(context)|\(text)"] ?? tr(text)
}

/// Počet se správným tvarem slova: 1 soubor, 2–4 soubory, 5+ souborů (i 0 souborů).
/// Tvary se předávají česky a zvolený se přeloží (anglicky jednotné / množné číslo).
/// - Parameters:
///   - count: počet
///   - one: tvar pro 1
///   - few: tvar pro 2–4
///   - many: tvar pro 0 a 5+
func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let word = count == 1 ? one : (2...4).contains(count) ? few : many
    return "\(count) \(tr(word))"
}
