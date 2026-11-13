// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vstupní bod aplikace: NSApplication + AppDelegate s hlavním menu.
// Tenké UI nad jádrem salcore – bez pluginů (viz README.md).

import AppKit
import microcommander

/// Delegát aplikace: hlavní okno a menu (položky volají příkazy okna).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?
    /// Běžící self-test (drží se po dobu testu).
    var selfTest: UISelfTest?
    /// Běžící kontrola kláves bez okna.
    var keyCheck: UIKeyCheck?

    /// Automatický běh (self-test, kontrola kláves) – nemá přepisovat uživatelské
    /// stavy, např. uložené adresáře panelů.
    static let isAutomatedRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["SAL_SELFTEST"] != nil || environment["SAL_KEYCHECK"] != nil
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.migrateSettingsFromSalamander()
        let controller = MainWindowController()
        windowController = controller
        buildMenu(controller)
        // Kontrola kláves bez okna – neaktivuje aplikaci ani neukáže okno.
        if ProcessInfo.processInfo.environment["SAL_KEYCHECK"] != nil {
            let check = UIKeyCheck(controller: controller)
            keyCheck = check
            check.run()
            return
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusActivePanel()
        NSApp.activate(ignoringOtherApps: true)

        // Vývojářský snímek okna: SAL_SNAPSHOT=cesta.png uloží po startu PNG
        // obsahu okna (bez oprávnění k nahrávání obrazovky) – pro kontrolu vzhledu.
        if let snapshotPath = ProcessInfo.processInfo.environment["SAL_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                controller.saveSnapshot(to: snapshotPath)
            }
        }
        // Vývojářský self-test kláves a dialogů (viz SelfTest.swift).
        if ProcessInfo.processInfo.environment["SAL_SELFTEST"] != nil {
            let test = UISelfTest(controller: controller)
            selfTest = test
            test.run()
        }
    }

    /// Jednorázový převod nastavení z doby, kdy se aplikace jmenovala Salamander
    /// (jiný bundle identifier = jiná doména předvoleb). Přenese uživatelské volby
    /// a polohu okna; diagnostický záznam kláves (keyLog) záměrně ne.
    static func migrateSettingsFromSalamander() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromSalamander") else { return }
        defaults.set(true, forKey: "migratedFromSalamander")
        guard let old = defaults.persistentDomain(forName: "eu.krtkovo.salamander") else { return }
        for (key, value) in old where key != "keyLog" && defaults.object(forKey: key) == nil {
            // Poloha okna se ukládala pod starým jménem automatického ukládání.
            let newKey = key == "NSWindow Frame SalamanderMain"
                ? "NSWindow Frame " + MainWindowController.frameAutosaveName : key
            defaults.set(value, forKey: newKey)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Popis položky menu: titulek, příkaz, klávesa a modifikátory.
    private typealias Entry = (title: String, command: Command, key: String, modifiers: NSEvent.ModifierFlags)?

    /// F-klávesa jako keyEquivalent (zobrazení v menu; obsluhu dělá monitor okna).

    /// Sestaví hlavní menu podle Salamandera (Soubory, Příkazy, Panel, Označit, Zobrazení).
    private func buildMenu(_ controller: MainWindowController) {
        let mainMenu = NSMenu()

        // Aplikační menu.
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "O aplikaci MicroCommander", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Nastavení…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Skrýt MicroCommander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Ukončit MicroCommander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, title: "MicroCommander", to: mainMenu)

        // Standardní Úpravy – nutné pro ⌘C/⌘V/⌘X v textových polích (⌘A v panelu označí vše).
        let editMenu = NSMenu(title: "Úpravy")
        editMenu.addItem(withTitle: "Zpět", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Vyjmout", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopírovat", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Vybrat vše", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Cesta aktuálního adresáře aktivního panelu (Ctrl+Alt+Insert v Salamanderu).
        editMenu.addItem(makeItem(("Kopírovat cestu adresáře", .copyDirPath, "c", [.command, .option]), controller))

        let fileEntries: [Entry] = [
            ("Zobrazit", .view, KeyCode.functionKeyString(3), []),
            ("Upravit", .edit, KeyCode.functionKeyString(4), []),
            ("Nový soubor…", .newFile, KeyCode.functionKeyString(4), [.shift]),
            nil,
            ("Kopírovat…", .copy, KeyCode.functionKeyString(5), []),
            ("Přesunout…", .move, KeyCode.functionKeyString(6), []),
            ("Přejmenovat…", .rename, KeyCode.functionKeyString(2), []),
            ("Změnit atributy…", .changeAttributes, KeyCode.functionKeyString(2), [.command]),
            ("Vlastnosti…", .properties, "i", [.command]),
            ("Oprávnění…", .properties, "p", [.control]),
            ("Smazat…", .delete, KeyCode.functionKeyString(8), []),
            ("Nový adresář…", .mkdir, KeyCode.functionKeyString(7), []),
            nil,
            ("Zabalit do ZIP…", .pack, KeyCode.functionKeyString(5), [.option]),
            ("Rozbalit…", .unpack, KeyCode.functionKeyString(6), [.option]),
            ("Spočítat velikost", .calcSize, KeyCode.functionKeyString(10), [.option]),
        ]
        addSubmenu(makeMenu("Soubory", fileEntries, controller), title: "Soubory", to: mainMenu)
        addSubmenu(editMenu, title: "Úpravy", to: mainMenu)

        let markEntries: [Entry] = [
            ("Označit vše", .selectAll, "a", [.command]),
            ("Zrušit označení", .unselectAll, "d", [.command]),
            ("Označit podle masky…", .selectMask, "=", [.command]),
            ("Odznačit podle masky…", .unselectMask, "-", [.command]),
            ("Invertovat označení (Num *)", .invertMarks, "*", [.command]),
            nil,
            ("Porovnat adresáře", .compare, KeyCode.functionKeyString(10), [.control]),
        ]
        addSubmenu(makeMenu("Označit", markEntries, controller), title: "Označit", to: mainMenu)

        let commandEntries: [Entry] = [
            ("Vyhledat soubory a adresáře…", .find, "f", [.command]),
            ("Terminál v adresáři", .terminal, KeyCode.functionKeyString(9), []),
            nil,
            ("FTP/SFTP servery…", .connect, KeyCode.functionKeyString(11), []),
            ("Odpojit / zavřít archiv", .disconnect, KeyCode.functionKeyString(12), []),
            nil,
            ("Nápověda ke klávesám", .help, KeyCode.functionKeyString(1), []),
        ]
        addSubmenu(makeMenu("Příkazy", commandEntries, controller), title: "Příkazy", to: mainMenu)

        let panelEntries: [Entry] = [
            ("Zpět", .back, "[", [.command]),
            ("Vpřed", .forward, "]", [.command]),
            ("Nadřazený adresář", .up, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command]),
            ("Kořenový adresář", .root, "\\", [.command]),
            ("Domovský adresář", .home, "h", [.command, .shift]),
            ("Změnit adresář…", .changeDir, "g", [.command]),
            // Menu ukazuje ⌘ zkratky; ⌃ varianty fungují stejně (viz periodShortcutCommand).
            ("Poslat adresář do druhého panelu (také ⌃.)", .sameDirOther, ".", [.command]),
            ("Převzít adresář z druhého panelu (také ⌃⇧.)", .sameDir, ".", [.command, .shift]),
            nil,
            ("Disk v levém panelu…", .driveLeft, KeyCode.functionKeyString(1), [.option]),
            ("Disk v pravém panelu…", .driveRight, KeyCode.functionKeyString(2), [.option]),
            ("Upravit nabídku disků…", .editPlaces, "", []),
            nil,
            ("Řadit podle jména", .sortName, KeyCode.functionKeyString(3), [.control]),
            ("Řadit podle přípony", .sortExt, KeyCode.functionKeyString(4), [.control]),
            ("Řadit podle času", .sortTime, KeyCode.functionKeyString(5), [.control]),
            ("Řadit podle velikosti", .sortSize, KeyCode.functionKeyString(6), [.control]),
            nil,
            ("Obnovit", .refresh, "r", [.command]),
            ("Prohodit panely", .swap, "u", [.command]),
        ]
        addSubmenu(makeMenu("Panel", panelEntries, controller), title: "Panel", to: mainMenu)

        // Zobrazení – režimy panelu jako v Salamanderu (Alt+1..6 → ⌥1..⌥6) a skryté soubory.
        let viewEntries: [Entry] = [
            ("Stručný", .viewBrief, "1", [.option]),
            ("Podrobný", .viewDetailed, "2", [.option]),
            ("Ikony", .viewIcons, "3", [.option]),
            ("Miniatury", .viewThumbnails, "4", [.option]),
            ("Dlaždice", .viewTiles, "5", [.option]),
            ("Typy", .viewTypes, "6", [.option]),
            nil,
            ("Zobrazovat skryté soubory", .toggleHidden, "h", [.control]),
        ]
        addSubmenu(makeMenu("Zobrazení", viewEntries, controller), title: "Zobrazení", to: mainMenu)

        NSApplication.shared.mainMenu = mainMenu
    }

    /// Sestaví menu z popisů (cíl = okno, tag = index příkazu).
    private func makeMenu(_ title: String, _ entries: [Entry], _ controller: MainWindowController) -> NSMenu {
        let menu = NSMenu(title: title)
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            menu.addItem(makeItem(entry, controller))
        }
        return menu
    }

    /// Položka menu volající příkaz hlavního okna (tag = index příkazu).
    /// - Parameters:
    ///   - entry: titulek, příkaz, klávesa a modifikátory
    ///   - controller: hlavní okno, které příkaz provede
    private func makeItem(_ entry: (title: String, command: Command, key: String, modifiers: NSEvent.ModifierFlags),
                          _ controller: MainWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(MainWindowController.menuCommand(_:)),
                              keyEquivalent: entry.key)
        item.keyEquivalentModifierMask = entry.modifiers
        item.tag = MainWindowController.menuCommandIndex(entry.command)
        item.target = controller
        return item
    }

    private func addSubmenu(_ menu: NSMenu, title: String, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        mainMenu.addItem(item)
    }

    /// Okno Nastavení (⌘,).
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.show()
    }

    @objc func showAbout(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "MicroCommander"
        let version = String(cString: sal_version())
        alert.informativeText = "Dvoupanelový správce souborů pro macOS.\nJádro salcore v\(version) (Rust).\nPřepis Open Salamanderu (bez pluginů)."
        alert.runModal()
    }
}

// Vytvoření a spuštění aplikace (bez Main.storyboard).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Kontrola kláves běží bez ikony v Docku (nekrade fokus).
app.setActivationPolicy(ProcessInfo.processInfo.environment["SAL_KEYCHECK"] != nil ? .prohibited : .regular)
app.run()
