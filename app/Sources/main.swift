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

    /// Položka menu: titulek a příkaz; zkratku dodá KeyBindings (Nastavení › Klávesnice).
    private typealias Entry = (title: String, command: Command)?

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

        // Standardní Úpravy – nutné pro ⌘C/⌘V/⌘X v textových polích
        // (⌘A / vybrat vše je v menu Označit › Označit vše).
        let editMenu = NSMenu(title: "Úpravy")
        editMenu.addItem(withTitle: "Zpět", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Vyjmout", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopírovat", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Vložit", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        // Cesta aktuálního adresáře aktivního panelu (Ctrl+Alt+Insert v Salamanderu).
        editMenu.addItem(makeItem(("Kopírovat cestu adresáře", .copyDirPath), controller))

        let fileEntries: [Entry] = [
            ("Zobrazit", .view),
            ("Upravit", .edit),
            ("Nový soubor…", .newFile),
            nil,
            ("Kopírovat…", .copy),
            ("Přesunout…", .move),
            ("Přejmenovat…", .rename),
            ("Změnit atributy…", .changeAttributes),
            ("Vlastnosti…", .properties),
            ("Oprávnění…", .permissions),
            ("Smazat…", .delete),
            ("Nový adresář…", .mkdir),
            nil,
            ("Zabalit do ZIP…", .pack),
            ("Rozbalit…", .unpack),
            ("Spočítat velikost", .calcSize),
        ]
        addSubmenu(makeMenu("Soubory", fileEntries, controller), title: "Soubory", to: mainMenu)
        addSubmenu(editMenu, title: "Úpravy", to: mainMenu)

        let markEntries: [Entry] = [
            ("Zrušit označení", .unselectAll),
            ("Označit podle masky…", .selectMask),
            ("Odznačit podle masky…", .unselectMask),
            ("Invertovat označení (Num *)", .invertMarks),
            nil,
            ("Porovnat adresáře", .compare),
        ]
        let markMenu = makeMenu("Označit", markEntries, controller)
        // ⌘A přes responder chain (cíl nil): v panelu označí vše (selectAll: →
        // příkaz Označit vše), v textových polích a dialozích vybere text.
        let selectAllItem = markMenu.insertItem(withTitle: "Označit vše", action: #selector(NSText.selectAll(_:)),
                                                keyEquivalent: "", at: 0)
        AppDelegate.applyShortcut(to: selectAllItem)
        addSubmenu(markMenu, title: "Označit", to: mainMenu)

        let commandEntries: [Entry] = [
            ("Vyhledat soubory a adresáře…", .find),
            ("Terminál v adresáři", .terminal),
            nil,
            ("FTP/SFTP servery…", .connect),
            ("Odpojit / zavřít archiv", .disconnect),
            nil,
            ("Nápověda ke klávesám", .help),
        ]
        addSubmenu(makeMenu("Příkazy", commandEntries, controller), title: "Příkazy", to: mainMenu)

        let panelEntries: [Entry] = [
            ("Zpět", .back),
            ("Vpřed", .forward),
            ("Nadřazený adresář", .up),
            ("Kořenový adresář", .root),
            ("Domovský adresář", .home),
            ("Změnit adresář…", .changeDir),
            ("Poslat adresář do druhého panelu", .sameDirOther),
            ("Převzít adresář z druhého panelu", .sameDir),
            nil,
            ("Disk v levém panelu…", .driveLeft),
            ("Disk v pravém panelu…", .driveRight),
            ("Upravit nabídku disků…", .editPlaces),
            nil,
            ("Řadit podle jména", .sortName),
            ("Řadit podle přípony", .sortExt),
            ("Řadit podle času", .sortTime),
            ("Řadit podle velikosti", .sortSize),
            nil,
            ("Obnovit", .refresh),
            ("Prohodit panely", .swap),
        ]
        addSubmenu(makeMenu("Panel", panelEntries, controller), title: "Panel", to: mainMenu)

        // Zobrazení – režimy panelu jako v Salamanderu (Alt+1..6 → ⌥1..⌥6) a skryté soubory.
        let viewEntries: [Entry] = [
            ("Stručný", .viewBrief),
            ("Podrobný", .viewDetailed),
            ("Ikony", .viewIcons),
            ("Miniatury", .viewThumbnails),
            ("Dlaždice", .viewTiles),
            ("Typy", .viewTypes),
            nil,
            ("Zobrazovat skryté soubory", .toggleHidden),
        ]
        addSubmenu(makeMenu("Zobrazení", viewEntries, controller), title: "Zobrazení", to: mainMenu)

        NSApplication.shared.mainMenu = mainMenu
        // Změna zkratek v Nastavení › Klávesnice se hned projeví v menu.
        NotificationCenter.default.addObserver(forName: KeyBindings.changed, object: nil, queue: .main) { _ in
            AppDelegate.applyShortcuts(to: mainMenu)
        }
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
    ///   - entry: titulek a příkaz (zkratku dodá KeyBindings)
    ///   - controller: hlavní okno, které příkaz provede
    private func makeItem(_ entry: (title: String, command: Command), _ controller: MainWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(MainWindowController.menuCommand(_:)),
                              keyEquivalent: "")
        item.tag = MainWindowController.menuCommandIndex(entry.command)
        item.target = controller
        AppDelegate.applyShortcut(to: item)
        return item
    }

    /// Zkratka položky menu podle KeyBindings: příkaz z tagu (položky příkazů)
    /// nebo Označit vše (akce selectAll: přes responder chain).
    static func applyShortcut(to item: NSMenuItem) {
        let command: Command
        if item.action == #selector(MainWindowController.menuCommand(_:)) {
            command = MainWindowController.menuCommands[item.tag]
        } else if item.action == #selector(NSText.selectAll(_:)) {
            command = .selectAll
        } else {
            return
        }
        let shortcut = KeyBindings.menuShortcut(for: command)
        item.keyEquivalent = shortcut?.menuKey ?? ""
        item.keyEquivalentModifierMask = shortcut?.menuModifiers ?? []
    }

    /// Po změně zkratek v Nastavení obnoví zkratky všech položek hlavního menu.
    static func applyShortcuts(to menu: NSMenu) {
        for item in menu.items {
            applyShortcut(to: item)
            if let submenu = item.submenu { applyShortcuts(to: submenu) }
        }
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
