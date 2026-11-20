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
        // Jazyk chybových hlášek jádra podle jazyka rozhraní (určený při startu).
        sal_set_language(Localization.current)
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
        let item = menu.addItem(withTitle: tr("Nové okno"), action: #selector(newWindowFromDock(_:)), keyEquivalent: "")
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
        appMenu.addItem(withTitle: tr("O aplikaci MicroCommander"), action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Nastavení…"), action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr("Skrýt MicroCommander"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: tr("Ukončit MicroCommander"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, title: "MicroCommander", to: mainMenu)

        // Standardní Úpravy – nutné pro ⌘C/⌘V/⌘X v textových polích
        // (⌘A / vybrat vše je v menu Označit › Označit vše).
        let editMenu = NSMenu(title: tr("Úpravy"))
        // „Zpět“ je ve slovníku příkaz historie panelu (Back); v Úpravách jde
        // o vrácení úpravy (Undo), proto překlad s kontextem.
        let undoTitle = trc("undo", "Zpět")
        editMenu.addItem(withTitle: undoTitle, action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: tr("Vyjmout"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: tr("Kopírovat"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr("Vložit"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        // Cesta aktuálního adresáře aktivního panelu (Ctrl+Alt+Insert v Salamanderu).
        editMenu.addItem(makeItem((tr("Kopírovat cestu adresáře"), .copyDirPath)))

        let fileEntries: [Entry] = [
            (tr("Nové okno"), .newWindow),
            nil,
            (tr("Zobrazit"), .view),
            (tr("Upravit"), .edit),
            (tr("Zobrazit ve Finderu"), .revealInFinder),
            (tr("Nový soubor…"), .newFile),
            nil,
            (tr("Kopírovat…"), .copy),
            (tr("Přesunout…"), .move),
            (tr("Duplikovat"), .duplicate),
            (tr("Přejmenovat…"), .rename),
            (tr("Změnit atributy…"), .changeAttributes),
            (tr("Vlastnosti…"), .properties),
            (tr("Oprávnění…"), .permissions),
            (tr("Smazat…"), .delete),
            (tr("Smazat trvale…"), .deletePermanent),
            (tr("Nový adresář…"), .mkdir),
            nil,
            (tr("Zabalit do ZIP…"), .pack),
            (tr("Rozbalit…"), .unpack),
            (tr("Spočítat velikost"), .calcSize),
        ]
        addSubmenu(makeMenu(tr("Soubory"), fileEntries), title: tr("Soubory"), to: mainMenu)
        addSubmenu(editMenu, title: tr("Úpravy"), to: mainMenu)

        let markEntries: [Entry] = [
            (tr("Zrušit označení"), .unselectAll),
            (tr("Označit podle masky…"), .selectMask),
            (tr("Odznačit podle masky…"), .unselectMask),
            (tr("Invertovat označení (Num *)"), .invertMarks),
            nil,
            (tr("Porovnat adresáře"), .compare),
        ]
        let markMenu = makeMenu(tr("Označit"), markEntries)
        // ⌘A přes responder chain (cíl nil): v panelu označí vše (selectAll: →
        // příkaz Označit vše), v textových polích a dialozích vybere text.
        let selectAllItem = markMenu.insertItem(withTitle: tr("Označit vše"), action: #selector(NSText.selectAll(_:)),
                                                keyEquivalent: "", at: 0)
        AppDelegate.applyShortcut(to: selectAllItem)
        addSubmenu(markMenu, title: tr("Označit"), to: mainMenu)

        let commandEntries: [Entry] = [
            (tr("Vyhledat soubory a adresáře…"), .find),
            (tr("Terminál na celé okno"), .terminalFull),
            (tr("Nová záložka terminálu"), .terminalNewTab),
            (tr("Zavřít záložku terminálu"), .terminalCloseTab),
            (tr("Další záložka terminálu"), .terminalNextTab),
            (tr("Předchozí záložka terminálu"), .terminalPreviousTab),
            (tr("Terminal.app v adresáři"), .terminal),
            nil,
            (tr("FTP/SFTP servery…"), .connect),
            (tr("Odpojit / zavřít archiv"), .disconnect),
            nil,
            (tr("Nápověda ke klávesám"), .help),
        ]
        addSubmenu(makeMenu(tr("Příkazy"), commandEntries), title: tr("Příkazy"), to: mainMenu)

        let panelEntries: [Entry] = [
            (tr("Zpět"), .back),
            (tr("Vpřed"), .forward),
            (tr("Nadřazený adresář"), .up),
            (tr("Kořenový adresář"), .root),
            (tr("Domovský adresář"), .home),
            (tr("Změnit adresář…"), .changeDir),
            (tr("Poslat adresář do druhého panelu"), .sameDirOther),
            (tr("Převzít adresář z druhého panelu"), .sameDir),
            nil,
            (tr("Disk v levém panelu…"), .driveLeft),
            (tr("Disk v pravém panelu…"), .driveRight),
            (tr("Upravit nabídku disků…"), .editPlaces),
            (tr("Informace o jednotce…"), .driveInfo),
            nil,
            (tr("Řadit podle jména"), .sortName),
            (tr("Řadit podle přípony"), .sortExt),
            (tr("Řadit podle času"), .sortTime),
            (tr("Řadit podle velikosti"), .sortSize),
            nil,
            (tr("Obnovit"), .refresh),
            (tr("Prohodit panely"), .swap),
        ]
        addSubmenu(makeMenu(tr("Panel"), panelEntries), title: tr("Panel"), to: mainMenu)

        // Zobrazení – režimy panelu jako v Salamanderu (Alt+1..6 → ⌥1..⌥6) a skryté soubory.
        let viewEntries: [Entry] = [
            (tr("Stručný"), .viewBrief),
            (tr("Podrobný"), .viewDetailed),
            (tr("Ikony"), .viewIcons),
            (tr("Miniatury"), .viewThumbnails),
            (tr("Dlaždice"), .viewTiles),
            (tr("Typy"), .viewTypes),
            nil,
            (tr("Zobrazovat skryté soubory"), .toggleHidden),
        ]
        addSubmenu(makeMenu(tr("Zobrazení"), viewEntries), title: tr("Zobrazení"), to: mainMenu)

        // Okno – nové okno (⌘N) a standardní položky; macOS sem sám doplňuje
        // seznam otevřených oken.
        let windowMenu = makeMenu(tr("Okno"), [(tr("Nové okno"), .newWindow)])
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: tr("Minimalizovat"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: tr("Zavřít okno"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addSubmenu(windowMenu, title: tr("Okno"), to: mainMenu)
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
        // O aplikaci: verze, sestavení a systém (viz AboutInfo).
        AboutInfo.show()
    }
}

// Vytvoření a spuštění aplikace (bez Main.storyboard).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Kontrola kláves běží bez ikony v Docku (nekrade fokus).
app.setActivationPolicy(ProcessInfo.processInfo.environment["SAL_KEYCHECK"] != nil ? .prohibited : .regular)
app.run()
