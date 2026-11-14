// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vstupní bod aplikace: NSApplication + AppDelegate s hlavním menu.
// Tenké UI nad jádrem salcore – bez pluginů (viz README.md).

import AppKit
import microcommander

/// Delegát aplikace: hlavní okna a menu (položky volají příkazy aktivního okna).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Delegát běžící aplikace.
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// Otevřená hlavní okna (⌘N přidá další; každé má vlastní panely a terminál).
    private(set) var windowControllers: [MainWindowController] = []
    /// Naposledy aktivní hlavní okno – cíl příkazů z menu, i když má fokus
    /// jiné okno aplikace (Hledat, prohlížeč).
    weak var activeController: MainWindowController?
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
        // Zbytky dočasných kopií po dřívějším pádu aplikace – na pozadí, mazání
        // velkých rozbalených souborů nesmí zdržet start.
        DispatchQueue.global(qos: .utility).async { TempFiles.removeStale() }
        // Vzhled podle barevného schématu ještě před vytvořením okna.
        Settings.applyAppearance()
        let controller = MainWindowController()
        windowControllers = [controller]
        activeController = controller
        buildMenu()
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

    /// Při ukončení se uloží adresáře panelů aktivního okna a smažou dočasné
    /// kopie souborů rozbalených z archivů a serverů.
    func applicationWillTerminate(_ notification: Notification) {
        activeController?.savePanelPaths()
        TempFiles.removeCreated()
    }

    // MARK: - Okna

    /// ⌘N – otevře další hlavní okno ve stejných adresářích jako zdrojové okno.
    /// - Parameter source: okno, ze kterého příkaz přišel (nil = aktivní okno)
    func openNewWindow(from source: MainWindowController? = nil) {
        let controller = MainWindowController(openedFrom: source ?? activeController)
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusActivePanel()
    }

    /// Hlavní okno se zavírá: příkazy z menu převezme jiné okno a kontroler se
    /// přestane držet – až po doběhnutí zavírání (volá se z windowWillClose,
    /// kontroler nesmí zaniknout uprostřed něj).
    func windowClosed(_ controller: MainWindowController) {
        if activeController === controller || activeController == nil {
            activeController = windowControllers.last { $0 !== controller }
        }
        DispatchQueue.main.async { [weak self] in
            self?.windowControllers.removeAll { $0 === controller }
        }
    }

    /// Nabídka ikony v Docku: nové okno.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Nové okno", action: #selector(newWindowFromDock(_:)), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func newWindowFromDock(_ sender: Any?) {
        openNewWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu

    /// Je položka menu příkazem Nové okno? Ten jediný nepotřebuje hlavní okno
    /// (aplikaci může držet naživu jen okno Hledat nebo prohlížeč).
    private func opensNewWindow(_ item: NSMenuItem) -> Bool {
        item.tag == MainWindowController.menuCommandIndex(.newWindow)
    }

    /// Položka menu s příkazem: provede ho naposledy aktivní hlavní okno.
    @objc func menuCommand(_ sender: NSMenuItem) {
        if let controller = activeController {
            controller.menuCommand(sender)
        } else if opensNewWindow(sender) {
            openNewWindow()
        }
    }

    /// Dostupnost a zaškrtnutí položek příkazů určuje aktivní hlavní okno.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(menuCommand(_:)) else { return true }
        return activeController?.validateMenuItem(menuItem) ?? opensNewWindow(menuItem)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Položka menu: titulek a příkaz; zkratku dodá KeyBindings (Nastavení › Klávesnice).
    private typealias Entry = (title: String, command: Command)?

    /// Sestaví hlavní menu podle Salamandera (Soubory, Příkazy, Panel, Označit,
    /// Zobrazení) a menu Okno.
    private func buildMenu() {
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
        editMenu.addItem(makeItem(("Kopírovat cestu adresáře", .copyDirPath)))

        let fileEntries: [Entry] = [
            ("Nové okno", .newWindow),
            nil,
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
            ("Smazat trvale…", .deletePermanent),
            ("Nový adresář…", .mkdir),
            nil,
            ("Zabalit do ZIP…", .pack),
            ("Rozbalit…", .unpack),
            ("Spočítat velikost", .calcSize),
        ]
        addSubmenu(makeMenu("Soubory", fileEntries), title: "Soubory", to: mainMenu)
        addSubmenu(editMenu, title: "Úpravy", to: mainMenu)

        let markEntries: [Entry] = [
            ("Zrušit označení", .unselectAll),
            ("Označit podle masky…", .selectMask),
            ("Odznačit podle masky…", .unselectMask),
            ("Invertovat označení (Num *)", .invertMarks),
            nil,
            ("Porovnat adresáře", .compare),
        ]
        let markMenu = makeMenu("Označit", markEntries)
        // ⌘A přes responder chain (cíl nil): v panelu označí vše (selectAll: →
        // příkaz Označit vše), v textových polích a dialozích vybere text.
        let selectAllItem = markMenu.insertItem(withTitle: "Označit vše", action: #selector(NSText.selectAll(_:)),
                                                keyEquivalent: "", at: 0)
        AppDelegate.applyShortcut(to: selectAllItem)
        addSubmenu(markMenu, title: "Označit", to: mainMenu)

        let commandEntries: [Entry] = [
            ("Vyhledat soubory a adresáře…", .find),
            ("Terminál na celé okno", .terminalFull),
            ("Nová záložka terminálu", .terminalNewTab),
            ("Zavřít záložku terminálu", .terminalCloseTab),
            ("Další záložka terminálu", .terminalNextTab),
            ("Předchozí záložka terminálu", .terminalPreviousTab),
            ("Terminal.app v adresáři", .terminal),
            nil,
            ("FTP/SFTP servery…", .connect),
            ("Odpojit / zavřít archiv", .disconnect),
            nil,
            ("Nápověda ke klávesám", .help),
        ]
        addSubmenu(makeMenu("Příkazy", commandEntries), title: "Příkazy", to: mainMenu)

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
            ("Informace o jednotce…", .driveInfo),
            nil,
            ("Řadit podle jména", .sortName),
            ("Řadit podle přípony", .sortExt),
            ("Řadit podle času", .sortTime),
            ("Řadit podle velikosti", .sortSize),
            nil,
            ("Obnovit", .refresh),
            ("Prohodit panely", .swap),
        ]
        addSubmenu(makeMenu("Panel", panelEntries), title: "Panel", to: mainMenu)

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
        addSubmenu(makeMenu("Zobrazení", viewEntries), title: "Zobrazení", to: mainMenu)

        // Okno – nové okno (⌘N) a standardní položky; macOS sem sám doplňuje
        // seznam otevřených oken.
        let windowMenu = makeMenu("Okno", [("Nové okno", .newWindow)])
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimalizovat", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zavřít okno", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(windowMenu, title: "Okno", to: mainMenu)
        NSApplication.shared.windowsMenu = windowMenu

        NSApplication.shared.mainMenu = mainMenu
        // Změna zkratek v Nastavení › Klávesnice se hned projeví v menu.
        NotificationCenter.default.addObserver(forName: KeyBindings.changed, object: nil, queue: .main) { _ in
            AppDelegate.applyShortcuts(to: mainMenu)
        }
    }

    /// Sestaví menu z popisů (tag položky = index příkazu).
    private func makeMenu(_ title: String, _ entries: [Entry]) -> NSMenu {
        let menu = NSMenu(title: title)
        for entry in entries {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            menu.addItem(makeItem(entry))
        }
        return menu
    }

    /// Položka menu volající příkaz aktivního hlavního okna (tag = index
    /// příkazu). Cílem je delegát aplikace, který příkaz předá oknu – oken může
    /// být víc a položka nesmí být svázaná s jedním z nich.
    /// - Parameter entry: titulek a příkaz (zkratku dodá KeyBindings)
    private func makeItem(_ entry: (title: String, command: Command)) -> NSMenuItem {
        let item = NSMenuItem(title: entry.title, action: #selector(menuCommand(_:)), keyEquivalent: "")
        item.tag = MainWindowController.menuCommandIndex(entry.command)
        item.target = self
        AppDelegate.applyShortcut(to: item)
        return item
    }

    /// Zkratka položky menu podle KeyBindings: příkaz z tagu (položky příkazů)
    /// nebo Označit vše (akce selectAll: přes responder chain).
    static func applyShortcut(to item: NSMenuItem) {
        let command: Command
        if item.action == #selector(menuCommand(_:)) {
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
        // O aplikaci: samostatné okno uprostřed obrazovky (nezávisí na hlavním okně).
        let version = String(cString: sal_version())
        PromptDialog.show(title: "MicroCommander",
                          message: "Dvoupanelový správce souborů pro macOS.\nJádro salcore v\(version) (Rust).\nPřepis Open Salamanderu (bez pluginů).",
                          icon: NSApp.applicationIconImage, over: nil)
    }
}

// Vytvoření a spuštění aplikace (bez Main.storyboard).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Kontrola kláves běží bez ikony v Docku (nekrade fokus).
app.setActivationPolicy(ProcessInfo.processInfo.environment["SAL_KEYCHECK"] != nil ? .prohibited : .regular)
app.run()
