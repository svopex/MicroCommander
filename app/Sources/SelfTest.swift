// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vývojářský self-test UI (SAL_SELFTEST=1): posílá do aplikace skutečné
// klávesové události (přes frontu událostí, tedy i přes monitory a modální
// dialogy) a ověřuje navigaci, označování, Tab, dialogy bez zamrznutí,
// kopírování F5 a mazání ⇧F8 nad dočasným adresářem. Výsledek vypíše a skončí.

import AppKit

/// Spouštěč self-testu nad hlavním oknem.
final class UISelfTest {
    private let controller: MainWindowController
    private var failures: [String] = []
    private let root: String
    /// Obnoví uživatelské volby uložené před testem.
    private var restoreSettings: (() -> Void)?

    init(controller: MainWindowController) {
        self.controller = controller
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sal-selftest-\(getpid())")
    }

    /// Připraví dočasné adresáře src (3 soubory) a dst.
    private func prepareFiles() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: root)
        try? fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.log"] {
            fm.createFile(atPath: root + "/src/" + name, contents: Data("obsah \(name)\n".utf8))
        }
    }

    /// Zařadí stisk klávesy do fronty událostí okna.
    private func key(_ keyCode: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = [], to target: NSWindow? = nil) {
        // Cíl = zadané okno, otevřený modální alert / sheet, jinak hlavní okno (aplikace
        // spuštěná z terminálu nemusí být aktivní, keyWindow proto nelze použít).
        guard let window = target ?? NSApp.modalWindow ?? controller.window?.attachedSheet ?? controller.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func check(_ condition: Bool, _ message: String) {
        print((condition ? "OK   " : "FAIL ") + message)
        if !condition { failures.append(message) }
    }

    /// Pole pro heslo v otevřeném modálním dialogu (nil = žádný dotaz na heslo).
    private func modalSecureField() -> NSSecureTextField? {
        guard let content = NSApp.modalWindow?.contentView else { return nil }
        return findSubview(of: content, type: NSSecureTextField.self)
    }

    /// Obsahuje otevřený modální dialog popisek s daným textem?
    private func modalHasText(_ text: String) -> Bool {
        guard let content = NSApp.modalWindow?.contentView else { return false }
        return allSubviews(of: content).contains { ($0 as? NSTextField)?.stringValue == text }
    }

    /// Rekurzivní hledání prvního podřízeného pohledu daného typu.
    private func findSubview<T: NSView>(of view: NSView, type: T.Type) -> T? {
        allSubviews(of: view).lazy.compactMap { $0 as? T }.first
    }

    /// Všechny podřízené pohledy (do hloubky).
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Okno není v modálním stavu (žádný visící sheet/alert).
    private var windowFree: Bool {
        controller.window?.attachedSheet == nil && NSApp.modalWindow == nil
    }

    /// Spustí krok, jakmile je připraven (dotazování po 0,1 s, max. 5 s).
    /// Používá časovač run loopu v režimu .common (včetně modálních dialogů) –
    /// bloky hlavní fronty GCD by neběžely, když je modální dialog otevřený
    /// zevnitř jiného bloku hlavní fronty (fronta je sériová).
    private func runSteps(_ steps: [(ready: () -> Bool, action: () -> Void)], index: Int, waited: Double) {
        guard index < steps.count else { return }
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            if steps[index].ready() || waited >= 5 {
                steps[index].action()
                self.runSteps(steps, index: index + 1, waited: 0)
            } else {
                self.runSteps(steps, index: index, waited: waited + 0.1)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Kroky testu s prodlevou (každý krok čeká na zpracování předchozích událostí).
    func run() {
        // Řádkové bufferování – výpis je vidět i při přesměrování do roury/souboru.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Test mění uložené volby (režimy zobrazení, skryté soubory) – po skončení je vrátíme.
        let defaults = UserDefaults.standard
        let savedSettings = ["showHiddenFiles", "viewModeLeft", "viewModeRight", "selectAllIncludesDirs", "keyBindings",
                             "findArchives"]
            .map { ($0, defaults.object(forKey: $0)) }
        restoreSettings = {
            for (key, value) in savedSettings {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            // Test končí okamžitým exit() – změny předvoleb se musí zapsat hned,
            // jinak by se (hlavně odstranění klíče) nemusely stihnout uložit.
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
        // Test počítá s výchozími klávesovými zkratkami (uživatelské se po testu vrátí).
        if defaults.object(forKey: "keyBindings") != nil { KeyBindings.overrides = [:] }
        prepareFiles()
        var steps: [(ready: () -> Bool, action: () -> Void)] = []
        var copiedBefore = false
        let left = { self.controller.leftPanel }
        let right = { self.controller.rightPanel }

        // 1) Panely do testovacích adresářů.
        steps.append((ready: { true }, action: {
            left().changePath(self.root + "/src")
            right().changePath(self.root + "/dst")
        }))
        // 2) Pohyb kurzoru a označení mezerou.
        steps.append((ready: { left().rows.count == 4 && !left().isLoading && !right().isLoading }, action: {
            self.check(left().rows.count == 4, "levý panel: „..“ + 3 soubory (\(left().rows.count))")
            self.check(left().cursor == 0, "kurzor na „..“")
            self.key(KeyCode.down, String(UnicodeScalar(NSDownArrowFunctionKey)!))
            self.key(KeyCode.space, " ")
        }))
        steps.append((ready: { !left().markedItems.isEmpty }, action: {
            self.check(left().markedItems.map(\.name) == ["a.txt"], "Space označí a.txt (\(left().markedItems.map(\.name)))")
            self.check(left().cursor == 2, "Space posune kurzor (\(left().cursor))")
            self.key(KeyCode.tab, "\t")
        }))
        // 3) Tab přepíná panely.
        steps.append((ready: { self.controller.activePanel === right() }, action: {
            self.check(self.controller.activePanel === right(), "Tab aktivuje pravý panel")
            self.key(KeyCode.tab, "\t")
        }))
        steps.append((ready: { self.controller.activePanel === left() }, action: {
            self.check(self.controller.activePanel === left(), "druhý Tab vrátí levý panel")
            // 4) F7 otevře dialog, Escape ho zavře – okno nesmí zůstat zamrzlé.
            self.key(KeyCode.functionKeys[6], KeyCode.functionKeyString(7))
        }))
        steps.append((ready: { NSApp.modalWindow != nil }, action: {
            self.check(NSApp.modalWindow != nil, "F7 otevře dialog nového adresáře")
            self.key(KeyCode.escape, "\u{1b}")
        }))
        steps.append((ready: { self.windowFree }, action: {
            self.check(self.windowFree, "po F7 + Escape okno není blokované")
            self.key(KeyCode.up, String(UnicodeScalar(NSUpArrowFunctionKey)!))
        }))
        steps.append((ready: { left().cursor == 1 }, action: {
            self.check(left().cursor == 1, "klávesy po dialogu fungují (\(left().cursor))")
            // 5) Rychlé hledání „c“ skočí na c.log.
            self.key(8, "c")
        }))
        steps.append((ready: { left().currentItem?.name == "c.log" }, action: {
            self.check(left().currentItem?.name == "c.log", "rychlé hledání „c“ → c.log (\(left().currentItem?.name ?? "-"))")
            self.key(KeyCode.escape, "\u{1b}")
            // 6) F5 zkopíruje označený a.txt do pravého panelu (Enter potvrdí cíl).
            self.key(KeyCode.functionKeys[4], KeyCode.functionKeyString(5))
        }))
        steps.append((ready: { NSApp.modalWindow != nil }, action: {
            self.check(NSApp.modalWindow != nil, "F5 otevře dialog s cílem")
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: { self.windowFree && FileManager.default.fileExists(atPath: self.root + "/dst/a.txt") && !right().isLoading }, action: {
            let copied = FileManager.default.fileExists(atPath: self.root + "/dst/a.txt")
            self.check(copied, "F5 zkopíroval a.txt do dst")
            self.check(self.windowFree, "po kopírování progress sheet zmizel")
            self.check(left().markedItems.isEmpty, "po kopírování se označení zrušilo")
            // 7) Ve druhém panelu ⇧F8 trvale smaže a.txt (Enter potvrdí; F8 by
            // soubor přesunul do koše uživatele).
            self.key(KeyCode.tab, "\t")
        }))
        steps.append((ready: { self.controller.activePanel === right() }, action: {
            copiedBefore = FileManager.default.fileExists(atPath: self.root + "/dst/a.txt")
            right().focus(name: "a.txt")
            self.key(KeyCode.functionKeys[7], KeyCode.functionKeyString(8), .shift)
        }))
        steps.append((ready: { NSApp.modalWindow != nil }, action: {
            self.check(NSApp.modalWindow != nil, "⇧F8 otevře potvrzení mazání")
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: { self.windowFree && !FileManager.default.fileExists(atPath: self.root + "/dst/a.txt") }, action: {
            let gone = !FileManager.default.fileExists(atPath: self.root + "/dst/a.txt")
            self.check(gone && copiedBefore, "⇧F8 trvale smazal a.txt v dst")
            self.check(self.windowFree, "po mazání okno není blokované")
            // 8) Backspace jde nahoru a kurzor se postaví na adresář, ze kterého jsme přišli.
            self.key(KeyCode.backspace, "\u{7f}")
        }))
        steps.append((ready: { right().location.path == self.root && !right().isLoading }, action: {
            self.check(right().location.path == self.root, "Backspace → nadřazený adresář")
            self.check(right().currentItem?.name == "dst", "kurzor na „dst“ po návratu (\(right().currentItem?.name ?? "-"))")
            // 9) Ctrl+F6 řadí podle velikosti, ⌘U prohodí panely.
            self.key(KeyCode.functionKeys[5], KeyCode.functionKeyString(6), [.control])
            self.key(32, "u", [.command])
        }))
        steps.append((ready: { self.controller.leftPanel.location.path == self.root }, action: {
            // Po ⌘U je vlevo původně pravý panel (stojí v kořeni testu), vpravo src.
            self.check(self.controller.leftPanel.location.path == self.root
                       && self.controller.rightPanel.location.path.hasSuffix("/src"), "⌘U prohodil panely")
            // 10) ⌃F otevře okno Vyhledat soubory a adresáře, Enter hledá, Escape zavře.
            self.controller.focusActivePanel()
            self.key(3, "f", [.control])
        }))
        let findWindow = { FindWindowController.windows.last }
        steps.append((ready: { findWindow()?.window?.isVisible == true }, action: {
            self.check(findWindow()?.window?.title == "Vyhledat soubory a adresáře", "⌃F otevře okno hledání")
            // Název je „*.*“ nebo poslední maska – nastavíme vše a spustíme Najít Enterem.
            if let window = findWindow()?.window,
               let combo = window.initialFirstResponder as? NSComboBox ?? (window.firstResponder as? NSTextView)?.delegate as? NSComboBox {
                combo.stringValue = "*.*"
            }
            self.key(KeyCode.returnKey, "\r", to: findWindow()?.window)
        }))
        steps.append((ready: { (findWindow()?.foundCount ?? 0) >= 5 && findWindow()?.isSearching == false }, action: {
            self.check((findWindow()?.foundCount ?? 0) >= 5, "hledání najde položky testovacího adresáře")
            // 10b) Hledat v archivech: položky uvnitř ZIP se najdou a jdou ukázat v panelu.
            try? FileManager.default.createDirectory(atPath: self.root + "/arch", withIntermediateDirectories: true)
            try? corePackZip(src: Vfs.localDisk, srcDir: self.root + "/src", names: ["a.txt", "b.txt"],
                             dest: self.root + "/arch/hledani.zip", state: ProgressState())
            findWindow()?.searchInArchives()
        }))
        let archivePanel = { self.controller.activePanel }
        steps.append((ready: { findWindow()?.isSearching == false && (findWindow()?.foundInArchivesCount ?? 0) > 0 }, action: {
            self.check(findWindow()?.foundInArchivesCount == 2, "hledání v archivech najde obě položky uvnitř ZIP")
            self.check(findWindow()?.showArchiveItem(named: "b.txt") == true, "položku nalezenou v archivu jde ukázat")
        }))
        steps.append((ready: { archivePanel().location.vfs.kind == SAL_VFS_ZIP && !archivePanel().isLoading }, action: {
            self.check(archivePanel().location.path == "/" && archivePanel().currentItem?.name == "b.txt",
                       "Ukázat z hledání: panel je v archivu s kurzorem na položce")
            archivePanel().goUp()
        }))
        steps.append((ready: { archivePanel().location.vfs.kind == SAL_VFS_LOCAL && !archivePanel().isLoading }, action: {
            self.check(archivePanel().location.path == self.root + "/arch"
                       && archivePanel().currentItem?.name == "hledani.zip", "„..“ z archivu vede zpět na jeho soubor")
            // Úklid: panel zpět do kořene testu, pomocný archiv pryč.
            try? FileManager.default.removeItem(atPath: self.root + "/arch")
            archivePanel().changePath(self.root)
        }))
        steps.append((ready: { archivePanel().location.path == self.root && !archivePanel().isLoading }, action: {
            // Ukázat přeneslo fokus do hlavního okna – Escape patří oknu hledání.
            findWindow()?.window?.makeKeyAndOrderFront(nil)
            self.key(KeyCode.escape, "\u{1b}", to: findWindow()?.window)
        }))
        steps.append((ready: { FindWindowController.windows.isEmpty && self.windowFree }, action: {
            self.check(FindWindowController.windows.isEmpty, "Escape zavře okno hledání")
            // 11) F11 otevře připojení FTP/SFTP, Escape ho zavře.
            self.key(KeyCode.functionKeys[10], KeyCode.functionKeyString(11))
        }))
        steps.append((ready: { self.controller.window?.attachedSheet != nil }, action: {
            self.check(self.controller.window?.attachedSheet != nil, "F11 otevře připojení FTP/SFTP")
            self.key(KeyCode.escape, "\u{1b}")
        }))
        // 11a) Změna atributů (jádro dialogu ⌘F2): jen pro čtení, skrytý a datum změny,
        // pak zpět na původní stav.
        steps.append((ready: { self.windowFree }, action: {
            let path = self.root + "/src/a.txt"
            let date = Date(timeIntervalSince1970: 1_000_000_000)
            var changes = AttributeChanges()
            changes.readonly = true
            changes.hidden = true
            changes.modified = date
            try? applyAttributeChanges(changes, to: [path], state: ProgressState())
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isHiddenKey, .contentModificationDateKey])
            let writable = FileManager.default.isWritableFile(atPath: path)
            self.check(!writable && values?.isHidden == true && values?.contentModificationDate == date,
                       "změna atributů: jen pro čtení, skrytý, datum změny")
            // Soubor jen pro čtení, mění se jen Skrytý: musí zůstat jen pro čtení.
            try? applyAttributeChanges(AttributeChanges(hidden: false), to: [path], state: ProgressState())
            let hiddenAfter = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isHiddenKey]))?.isHidden
            self.check(hiddenAfter == false && !FileManager.default.isWritableFile(atPath: path),
                       "změna atributů: jen Skrytý u souboru jen pro čtení")
            try? applyAttributeChanges(AttributeChanges(readonly: false), to: [path], state: ProgressState())
            self.check(FileManager.default.isWritableFile(atPath: path), "změna atributů: vrácení zápisu")
        }))
        // 11d) Rozpoznání shell skriptů pro Enter (spustit v Terminalu): spustitelný
        // soubor se shebangem shellu ano, bez +x, bez shebangu nebo Python ne.
        steps.append((ready: { self.windowFree }, action: {
            let fm = FileManager.default
            let cases: [(String, String, Bool, Bool)] = [
                ("s1.sh", "#!/bin/bash\necho a\n", true, true),
                ("s2", "#!/usr/bin/env zsh\necho a\n", true, true),
                ("s3.sh", "#!/bin/sh\n", false, false),
                ("s4.sh", "echo bez shebangu\n", true, false),
                ("s5", "#!/usr/bin/env python3\nprint(1)\n", true, false),
                ("s6", "#!/bin/bash\r\necho crlf\r\n", true, true),
            ]
            var results: [String] = []
            for (name, text, executable, expected) in cases {
                let path = self.root + "/" + name
                fm.createFile(atPath: path, contents: Data(text.utf8),
                              attributes: [.posixPermissions: executable ? 0o755 : 0o644])
                if isShellScript(atPath: path) != expected { results.append(name) }
                try? fm.removeItem(atPath: path)
            }
            self.check(results.isEmpty, "rozpoznání shell skriptů pro Enter (chybně: \(results))")
        }))
        // 11c) ⌘A s vypnutou volbou „i adresáře“ označí jen soubory, druhé ⌘A označení zruší.
        steps.append((ready: { self.windowFree }, action: {
            Settings.markingIncludesDirs = false
            try? FileManager.default.createDirectory(atPath: self.root + "/src/podadresar", withIntermediateDirectories: true)
            self.controller.activate(left())
            left().changePath(self.root + "/src")
        }))
        steps.append((ready: { left().items.contains { $0.name == "podadresar" } && !left().isLoading }, action: {
            self.controller.focusActivePanel()
            self.key(0, "a", [.command])
        }))
        steps.append((ready: { !left().marked.isEmpty }, action: {
            let marked = left().marked
            self.check(marked == ["a.txt", "b.txt", "c.log"], "⌘A označí jen soubory (\(marked.sorted()))")
            self.key(0, "a", [.command])
        }))
        steps.append((ready: { left().marked.isEmpty }, action: {
            self.check(true, "druhé ⌘A zruší označení")
            // Invertovat s vypnutou volbou: jen soubory; se zapnutou i adresáře.
            self.controller.perform(.invertMarks)
            self.check(left().marked == ["a.txt", "b.txt", "c.log"], "Invertovat bez adresářů (\(left().marked.sorted()))")
            left().markAll(false)
            Settings.markingIncludesDirs = true
            self.controller.perform(.invertMarks)
            self.check(left().marked.contains("podadresar"), "Invertovat i s adresáři")
            left().markAll(false)
            try? FileManager.default.removeItem(atPath: self.root + "/src/podadresar")
            left().reload()
        }))
        steps.append((ready: { !left().items.contains { $0.name == "podadresar" } && !left().isLoading }, action: {}))
        // 11b) F2 přejmenuje položku přímo v panelu (bez dialogu): c.log → renamed.log
        // (pak zpět, další kroky počítají s původními soubory).
        steps.append((ready: { self.windowFree }, action: {
            self.controller.activate(self.controller.leftPanel)
            self.controller.leftPanel.changePath(self.root + "/src", focus: "c.log")
        }))
        steps.append((ready: { self.controller.leftPanel.currentItem?.name == "c.log" && !self.controller.leftPanel.isLoading }, action: {
            self.key(KeyCode.functionKeys[1], KeyCode.functionKeyString(2))
        }))
        let renameEditing = { () -> Bool in
            guard let editor = self.controller.window?.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField else { return false }
            return field.superview is SalTableView || field.superview is FileGridView
        }
        steps.append((ready: renameEditing, action: {
            self.check(self.controller.window?.attachedSheet == nil && NSApp.modalWindow == nil,
                       "F2 přejmenuje v panelu bez dialogu")
            // Předvybraný je základ jména bez přípony – napsané jméno ho nahradí.
            for char in "renamed" { self.key(0, String(char)) }
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: { FileManager.default.fileExists(atPath: self.root + "/src/renamed.log") }, action: {
            self.check(!FileManager.default.fileExists(atPath: self.root + "/src/c.log"),
                       "přejmenování v panelu: c.log → renamed.log")
            try? FileManager.default.moveItem(atPath: self.root + "/src/renamed.log", toPath: self.root + "/src/c.log")
            self.controller.leftPanel.reload()
        }))
        // 12) Home/End, ⌥↑/⌥↓, skryté soubory (⌃H) a režimy zobrazení (⌥1/⌥3/⌥2).
        steps.append((ready: { self.windowFree }, action: {
            FileManager.default.createFile(atPath: self.root + "/src/.skryty", contents: Data())
            if !self.controller.showHiddenFiles { self.controller.toggleHiddenFiles() }
            self.controller.activate(self.controller.leftPanel)
            self.controller.leftPanel.changePath(self.root + "/src")
        }))
        let panelL = { self.controller.leftPanel }
        steps.append((ready: { panelL().rows.count == 5 && !panelL().isLoading }, action: {
            self.key(KeyCode.end, String(UnicodeScalar(NSEndFunctionKey)!), [.function])
        }))
        steps.append((ready: { panelL().cursor == panelL().rows.count - 1 }, action: {
            self.check(panelL().cursor == 4, "End → poslední položka (\(panelL().cursor))")
            self.key(KeyCode.home, String(UnicodeScalar(NSHomeFunctionKey)!), [.function])
        }))
        steps.append((ready: { panelL().cursor == 0 }, action: {
            self.check(panelL().cursor == 0, "Home → první položka")
            self.key(KeyCode.down, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.option])
        }))
        steps.append((ready: { panelL().cursor == 4 }, action: {
            self.check(panelL().cursor == 4, "⌥↓ → poslední položka")
            self.key(KeyCode.up, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.option])
        }))
        steps.append((ready: { panelL().cursor == 0 }, action: {
            self.check(panelL().cursor == 0, "⌥↑ → první položka")
            self.key(4, "h", [.control])
        }))
        steps.append((ready: { panelL().rows.count == 4 }, action: {
            self.check(!panelL().rows.contains { $0.item.name == ".skryty" }, "⌃H skryje soubory s tečkou")
            self.key(4, "h", [.control])
        }))
        steps.append((ready: { panelL().rows.count == 5 }, action: {
            self.check(panelL().rows.contains { $0.item.name == ".skryty" }, "⌃H znovu zobrazí skryté soubory")
            self.key(KeyCode.digits[0], "1", [.option])
        }))
        let viewL = { panelL().view }
        steps.append((ready: { viewL()?.viewMode == .brief }, action: {
            self.check(viewL()?.viewMode == .brief, "⌥1 → Stručný režim")
            self.check(self.controller.window?.firstResponder === viewL()?.gridView, "fokus přešel na mřížku")
            self.key(KeyCode.right, String(UnicodeScalar(NSRightArrowFunctionKey)!), [.function])
        }))
        steps.append((ready: { panelL().cursor == 4 }, action: {
            // Všech 5 položek je v prvním sloupci → → skočí na poslední.
            self.check(panelL().cursor == 4, "→ ve Stručném režimu přeskočí sloupec (\(panelL().cursor))")
            self.key(KeyCode.digits[2], "3", [.option])
        }))
        steps.append((ready: { viewL()?.viewMode == .icons }, action: {
            self.check(viewL()?.viewMode == .icons, "⌥3 → režim Ikony")
            self.key(KeyCode.left, String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.function])
        }))
        steps.append((ready: { panelL().cursor == 3 }, action: {
            self.check(panelL().cursor == 3, "← v Ikonách = předchozí položka")
            self.key(KeyCode.digits[5], "6", [.option])
        }))
        steps.append((ready: { viewL()?.viewMode == .types }, action: {
            let typeColumn = viewL()?.tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(ColumnID.type))
            self.check(typeColumn?.isHidden == false, "⌥6 → Typy se sloupcem Typ")
            self.key(KeyCode.digits[1], "2", [.option])
        }))
        steps.append((ready: { viewL()?.viewMode == .detailed }, action: {
            self.check(self.controller.window?.firstResponder === viewL()?.tableView, "⌥2 → Podrobný, fokus v tabulce")
            try? FileManager.default.removeItem(atPath: self.root + "/src/.skryty")
        }))

        // 12) Zaheslovaný ZIP (AES-256): Enter otevře archiv, F5 → cíl → chybné heslo →
        //     správné heslo → soubor rozbalený v druhém panelu.
        steps.append((ready: { self.windowFree }, action: {
            try? corePackZip(src: Vfs.localDisk, srcDir: self.root + "/src", names: ["b.txt"],
                             dest: self.root + "/tajne.zip", encryption: .aes256("Heslo-123"), state: ProgressState())
            try? FileManager.default.removeItem(atPath: self.root + "/dst/b.txt")
            self.controller.activate(self.controller.leftPanel)
            self.controller.leftPanel.changePath(self.root, focus: "tajne.zip")
            self.controller.rightPanel.changePath(self.root + "/dst")
        }))
        steps.append((ready: { self.controller.leftPanel.currentItem?.name == "tajne.zip" }, action: {
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: {
            self.controller.leftPanel.location.vfs.kind == SAL_VFS_ZIP && !self.controller.leftPanel.isLoading
        }, action: {
            let panel = self.controller.leftPanel
            let item = panel.items.first { $0.name == "b.txt" }
            self.check(item?.isEncrypted == true, "položka v AES archivu má příznak šifrování")
            panel.focus(name: "b.txt")
            self.key(KeyCode.functionKeys[4], KeyCode.functionKeyString(5))
        }))
        steps.append((ready: { NSApp.modalWindow != nil }, action: {
            // Dialog s cílem kopírování.
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: { self.modalSecureField() != nil }, action: {
            self.check(true, "před kopírováním ze zaheslovaného archivu se zobrazí dotaz na heslo")
            self.modalSecureField()?.stringValue = "spatne"
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: { self.modalSecureField() != nil && self.modalHasText("Chybné heslo") }, action: {
            self.check(true, "chybné heslo → nový dotaz „Chybné heslo“")
            self.modalSecureField()?.stringValue = "Heslo-123"
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: {
            self.windowFree && FileManager.default.fileExists(atPath: self.root + "/dst/b.txt")
        }, action: {
            let text = try? String(contentsOfFile: self.root + "/dst/b.txt", encoding: .utf8)
            self.check(text == "obsah b.txt\n", "soubor z AES archivu rozbalen se správným obsahem")
        }))
        steps.append((ready: { self.windowFree }, action: {
            self.check(self.windowFree, "okno na konci testu volné")
            try? FileManager.default.removeItem(atPath: self.root)
            self.restoreSettings?()
            print(self.failures.isEmpty ? "SELFTEST: vše OK" : "SELFTEST: \(self.failures.count) chyb")
            fflush(stdout)
            exit(self.failures.isEmpty ? 0 : 1)
        }))

        // Každý krok čeká, až platí jeho podmínka (operace jádra, výpisy i modální
        // dialogy běží asynchronně); po 5 s se krok provede i tak a kontroly selžou.
        runSteps(steps, index: 0, waited: 0)
    }
}

/// Kontrola Home/End bez zobrazení okna (SAL_KEYCHECK=1): aplikace se neaktivuje
/// a nekrade fokus. Pro každý režim zobrazení pošle panelu Home/End jako klávesu,
/// ⌥↑/⌥↓ a jako systémový příkaz začátek/konec dokumentu a ověří polohu kurzoru.
final class UIKeyCheck {
    private let controller: MainWindowController
    private var failures = 0

    init(controller: MainWindowController) {
        self.controller = controller
    }

    /// Syntetická klávesová událost (nikam se neposílá, předá se přímo panelu).
    private func event(_ keyCode: UInt16, _ scalar: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        let chars = String(UnicodeScalar(scalar)!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    private func check(_ condition: Bool, _ message: String) {
        print((condition ? "OK   " : "FAIL ") + message)
        if !condition { failures += 1 }
    }

    /// Vlastní klávesové zkratky (Nastavení › Klávesnice): Prohodit panely na ⌘K,
    /// F5 (Kopírovat) na ⌃F11 – staré klávesy přestanou platit, nové fungují,
    /// lišta F-kláves a menu se přizpůsobí. Uložené zkratky se nakonec vrátí.
    private func checkKeyBindings() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "keyBindings")
        defer {
            if let saved { defaults.set(saved, forKey: "keyBindings") } else { defaults.removeObject(forKey: "keyBindings") }
            KeyBindings.reload()
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        }
        KeyBindings.overrides = [
            KeyBindings.name(of: .swap): [.char("k", keyCode: 40, .command)],
            KeyBindings.name(of: .copy): [.function(11, .control)],
        ]
        let cmdK = event(40, Int(("k" as UnicodeScalar).value), [.command])
        let cmdU = event(32, Int(("u" as UnicodeScalar).value), [.command])
        let f5 = event(KeyCode.functionKeys[4], NSF5FunctionKey, [])
        let ctrlF11 = event(KeyCode.functionKeys[10], NSF11FunctionKey, [.control])
        check(KeyBindings.command(for: cmdK) == .swap && KeyBindings.command(for: cmdU) == nil,
              "vlastní zkratka: ⌘K = Prohodit panely, ⌘U už nic")
        check(KeyBindings.command(for: ctrlF11) == .copy && KeyBindings.command(for: f5) == nil,
              "vlastní zkratka: ⌃F11 = Kopírovat, F5 už nic")
        check(FunctionKeyBar.entries(for: .control)[10] == .copy && FunctionKeyBar.entries(for: .plain)[4] == nil,
              "lišta F-kláves podle vlastních zkratek")
        let swapItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(MainWindowController.menuCommand(_:))
                && $0.tag == MainWindowController.menuCommandIndex(.swap) }
        check(swapItem?.keyEquivalent == "k" && swapItem?.keyEquivalentModifierMask == .command,
              "menu ukazuje vlastní zkratku (\(swapItem?.keyEquivalent ?? "-"))")
        // V textovém poli se ⌘C (kopírování textu) příkazu nepřiřadí.
        let cmdC = event(8, Int(("c" as UnicodeScalar).value), [.command])
        KeyBindings.overrides = [KeyBindings.name(of: .refresh): [.char("c", keyCode: 8, .command)]]
        check(KeyBindings.command(for: cmdC) == .refresh && KeyBindings.command(for: cmdC, textEditing: true) == nil,
              "⌘C v textovém poli zůstane kopírování textu")
    }

    /// Nastavení v souboru (Nastavení › Uložit do souboru… / Načíst ze souboru…)
    /// a Obnovit vše: snímek projde souborem JSON beze změny, dialog ho ukáže
    /// a vrátí stejný, chybějící volby jsou výchozí, cizí a novější soubor se
    /// odmítne a nepřiřaditelné zkratky se zahodí. Uložené předvolby se nemění
    /// (pracuje se jen se snímky a s rozpracovanými hodnotami dialogu).
    private func checkSettingsFile() {
        let file = URL(fileURLWithPath: TempFiles.newPath(suffix: ".json"))
        defer { try? FileManager.default.removeItem(at: file) }

        // Snímek odlišný od výchozího ve všech volbách.
        var custom = SettingsSnapshot()
        custom.savePanelPaths = false
        custom.showHiddenFiles = true
        custom.markingIncludesDirs = false
        custom.showMiddleBar = true
        custom.colorScheme = .norton
        custom.keyBindings = [
            KeyBindings.name(of: .swap): [.char("k", keyCode: 40, .command)],
            KeyBindings.name(of: .editPlaces): [.function(12, .control)],
        ]
        try? custom.write(to: file)
        check((try? SettingsSnapshot.read(from: file)) == custom && custom != SettingsSnapshot.defaults, "nastavení projde souborem JSON beze změny")

        // Dialog: načtený snímek se ukáže ve všech stránkách a Obnovit vše vrátí výchozí.
        let dialog = SettingsWindowController()
        dialog.draft = custom
        check(dialog.draft == custom, "dialog Nastavení ukáže hodnoty načtené ze souboru")
        dialog.draft = .defaults
        check(dialog.draft == SettingsSnapshot.defaults, "Obnovit vše nastaví v dialogu výchozí hodnoty")

        /// Zapíše text jako soubor nastavení a zkusí ho načíst.
        func read(_ json: String) -> Result<SettingsSnapshot, Error> {
            try? json.write(to: file, atomically: true, encoding: .utf8)
            return Result { try SettingsSnapshot.read(from: file) }
        }
        let format = SettingsSnapshot.fileFormat
        // Jen značka formátu a jedna volba – zbytek výchozí.
        var expected = SettingsSnapshot.defaults
        expected.showMiddleBar = true
        check((try? read(#"{"format": "\#(format)", "showMiddleBar": true}"#).get()) == expected,
              "chybějící volby v souboru dostanou výchozí hodnoty")
        // Cizí JSON a novější verze formátu.
        let foreignRejected = if case .failure(SettingsFileError.notSettings) = read(#"{"showMiddleBar": true}"#) { true } else { false }
        check(foreignRejected, "cizí soubor JSON se jako nastavení odmítne")
        let newerRejected = if case .failure(SettingsFileError.newerVersion) = read(#"{"format": "\#(format)", "version": 99}"#) { true } else { false }
        check(newerRejected, "soubor z novější verze se odmítne")
        // Značka formátu sedí, ale volba má špatný typ.
        let corruptedRejected = if case .failure(SettingsFileError.corrupted) = read(#"{"format": "\#(format)", "showMiddleBar": "ano"}"#) { true } else { false }
        check(corruptedRejected, "poškozený soubor nastavení se odmítne")
        // Ručně upravený soubor: neznámý příkaz, vyhrazená klávesa (⌘1) a písmeno
        // bez modifikátoru se nepřevezmou, platná zkratka ano.
        var edited = SettingsSnapshot.defaults
        edited.keyBindings = [
            "neznamyPrikaz": [.function(5)],
            KeyBindings.name(of: .swap): [.code(KeyCode.digits[0], key: "1", .command), .char("x", keyCode: 7, []),
                                          .function(11, .option)],
        ]
        // Zápis filtr obchází (ten je jen při čtení) – soubor obsahuje i neplatné zkratky.
        try? edited.write(to: file)
        check((try? SettingsSnapshot.read(from: file))?.keyBindings == [KeyBindings.name(of: .swap): [.function(11, .option)]],
              "ze souboru se převezmou jen přiřaditelné zkratky známých příkazů")
    }

    /// Informace o jednotce: ⌘F1 i ⌃F1 spouští příkaz, údaje o kořenovém svazku
    /// dávají smysl a dialog je ukáže (název svazku, kapacita v bajtech).
    private func checkDriveInfo() {
        let cmdF1 = event(KeyCode.functionKeys[0], NSF1FunctionKey, [.command])
        let ctrlF1 = event(KeyCode.functionKeys[0], NSF1FunctionKey, [.control])
        let plainF1 = event(KeyCode.functionKeys[0], NSF1FunctionKey, [])
        check(KeyBindings.command(for: cmdF1) == .driveInfo && KeyBindings.command(for: ctrlF1) == .driveInfo
              && KeyBindings.command(for: plainF1) == .help, "⌘F1 / ⌃F1 = Informace o jednotce, F1 zůstává nápověda")
        guard let info = VolumeInfo.load(path: NSTemporaryDirectory()) else {
            check(false, "informace o jednotce: údaje o svazku se načtou")
            return
        }
        check(info.capacity > 0 && info.free <= info.capacity && info.used + info.free == info.capacity
              && info.blockSize > 0 && info.blockCount * info.blockSize == info.capacity
              && info.mountPoint.hasPrefix("/") && !info.fileSystem.isEmpty,
              "informace o jednotce: kapacita, místo a bloky sedí (\(info.mountPoint), \(info.fileSystem))")
        check(VolumeInfo.load(path: "/neexistuje-\(getpid())") == nil, "informace o jednotce: neexistující cesta → nic")
        // Dialog obsahuje název svazku a kapacitu v bajtech.
        let dialog = DriveInfoDialog(info: info)
        var texts: [String] = []
        func collect(_ view: NSView) {
            if let field = view as? NSTextField { texts.append(field.stringValue) }
            view.subviews.forEach(collect)
        }
        if let content = dialog.window?.contentView { collect(content) }
        check(texts.contains(info.name) && texts.contains(formatExactSize(info.capacity) + " bajtů"),
              "dialog Informace o jednotce ukazuje název svazku a kapacitu")
    }

    func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Testovací adresář s podadresářem (aby první položka byla „..“).
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("sal-keycheck-\(getpid())/sub")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 500 souborů – ve Stručném režimu vznikne mnoho sloupců s vodorovným posunem.
        for index in 1...500 {
            FileManager.default.createFile(atPath: dir + "/soubor\(index).txt", contents: Data())
        }
        // Okno rozvržené na běžnou velikost (bez zobrazení), aby panely měly skutečné rozměry.
        if let window = controller.window {
            window.setContentSize(NSSize(width: 1200, height: 760))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let panel = controller.leftPanel
        panel.changePath(dir)
        poll(until: { panel.rows.count == 501 && !panel.isLoading }) {
            guard let view = panel.view else { return }
            let last = panel.rows.count - 1
            self.check(panel.rows.first?.isParent == true, "první položka je „..“")
            for mode in ViewMode.allCases {
                view.viewMode = mode
                guard let handler = view.inputHandler else { return }
                let responder = view.focusView
                // Home/End jako klávesa (fn+←/→ dává stejné kódy 115/119).
                panel.setCursor(20)
                _ = handler.panelView(view, keyDown: self.event(KeyCode.home, NSHomeFunctionKey, [.function]))
                self.check(panel.cursor == 0, "\(mode.title): Home → „..“ (\(panel.cursor))")
                _ = handler.panelView(view, keyDown: self.event(KeyCode.end, NSEndFunctionKey, [.function]))
                self.check(panel.cursor == last, "\(mode.title): End → poslední (\(panel.cursor))")
                // ⌥↑ / ⌥↓.
                _ = handler.panelView(view, keyDown: self.event(KeyCode.up, NSUpArrowFunctionKey, [.option, .function]))
                self.check(panel.cursor == 0, "\(mode.title): ⌥↑ → „..“")
                _ = handler.panelView(view, keyDown: self.event(KeyCode.down, NSDownArrowFunctionKey, [.option, .function]))
                self.check(panel.cursor == last, "\(mode.title): ⌥↓ → poslední")
                // Skutečná cesta události: okno → first responder (jako při stisku klávesy).
                if let window = self.controller.window {
                    window.makeFirstResponder(responder)
                    let viaWindow = { (code: UInt16, scalar: Int) -> NSEvent in
                        let chars = String(UnicodeScalar(scalar)!)
                        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                    }
                    panel.setCursor(20)
                    // Nejdřív zkratky menu (jako NSApplication.sendEvent), pak okno.
                    let home = viaWindow(KeyCode.home, NSHomeFunctionKey)
                    if NSApp.mainMenu?.performKeyEquivalent(with: home) != true { window.sendEvent(home) }
                    self.check(panel.cursor == 0, "\(mode.title): Home přes okno (\(String(describing: type(of: window.firstResponder!)))) → „..“ (\(panel.cursor))")
                    let end = viaWindow(KeyCode.end, NSEndFunctionKey)
                    if NSApp.mainMenu?.performKeyEquivalent(with: end) != true { window.sendEvent(end) }
                    self.check(panel.cursor == last, "\(mode.title): End přes okno → poslední (\(panel.cursor))")
                    self.check(self.cursorVisible(view), "\(mode.title): po End je kurzor vidět (obsah posunut)")
                    // Volitelný snímek stavu po End ve Stručném režimu (kontrola posunu okem).
                    if mode == .brief, let path = ProcessInfo.processInfo.environment["SAL_KEYCHECK_SNAPSHOT"] {
                        window.displayIfNeeded()
                        self.controller.saveSnapshot(to: path)
                    }
                    let homeAgain = viaWindow(KeyCode.home, NSHomeFunctionKey)
                    window.sendEvent(homeAgain)
                    self.check(panel.cursor == 0 && self.cursorVisible(view), "\(mode.title): po Home je „..“ vidět")
                }
                // Systémové příkazy (přemapované klávesy) na pohledu s fokusem.
                panel.setCursor(20)
                responder.doCommand(by: #selector(NSResponder.scrollToBeginningOfDocument(_:)))
                self.check(panel.cursor == 0, "\(mode.title): příkaz začátek dokumentu → „..“")
                responder.doCommand(by: #selector(NSResponder.scrollToEndOfDocument(_:)))
                self.check(panel.cursor == last, "\(mode.title): příkaz konec dokumentu → poslední")
            }
            self.checkDriveChooser()
            self.checkServerProfiles()
            self.probeMenuPeriod(dir: dir)
            self.checkKeyBindings()
            self.checkSettingsFile()
            self.checkDriveInfo()
            self.checkSameDir(dir: dir, then: {
                self.checkTerminal(dir: dir, then: {
                    self.checkFileClipboard(dir: dir, then: { self.checkPanelDrop(dir: dir, then: { self.finish(dir: dir) }) })
                })
            })
        }
    }

    /// Vestavěný terminál: shell jde za adresářem aktivního panelu, „cd“ v shellu
    /// přesune panel, po příkazu se panel obnoví a ⌘F12 přepíná terminál mezi
    /// jedním řádkem a celým oknem. Běží se skutečným shellem uživatele.
    private func checkTerminal(dir: String, then done: @escaping () -> Void) {
        let panel = controller.leftPanel
        let terminal = controller.terminalPane
        let subdir = "terminal-test"
        controller.activate(panel)
        panel.changePath(dir)
        // Panel → shell: nečinný shell přejde do adresáře aktivního panelu.
        poll(until: { terminal.isShellIdle && terminal.isShellDirectory(dir) }) {
            self.check(terminal.isShellDirectory(dir), "terminál: shell přešel do adresáře aktivního panelu")
            // Vlastní „cd“ po sobě nenechá na obrazovce příkaz ani jeho zbytky.
            self.check(!terminal.screenText.contains("printf"), "terminál: vložené cd po sobě smaže svůj řádek")
            // Shell → panel: po „cd“ v shellu jde panel za ním.
            // Mezera na začátku: testovací příkaz nepatří do historie shellu uživatele.
            self.check(terminal.run(" mkdir \(subdir) && cd \(subdir)", in: dir), "terminál: příkaz jde spustit v nečinném shellu")
            self.poll(until: { panel.location.path == dir + "/" + subdir && !panel.isLoading }) {
                self.check(panel.location.path == dir + "/" + subdir, "terminál: po cd v shellu jde panel za ním (\(panel.location.path))")
                // Panel zpět nahoru: shell ho následuje, kurzor je na vytvořeném adresáři.
                panel.goUp()
                self.poll(until: { terminal.isShellIdle && terminal.isShellDirectory(dir) && !panel.isLoading }) {
                    self.check(terminal.isShellDirectory(dir), "terminál: shell jde za panelem zpět do nadřazeného adresáře")
                    self.check(panel.currentItem?.name == subdir, "terminál: adresář vytvořený v shellu je v panelu vidět")
                    self.checkTerminalLayout(then: done)
                }
            }
        }
    }

    /// ⌘F12: terminál přes celou plochu pod nástrojovou lištou a zpět na jeden řádek.
    private func checkTerminalLayout(then done: @escaping () -> Void) {
        let terminal = controller.terminalPane
        let content = controller.window?.contentView
        let snapshot = ProcessInfo.processInfo.environment["SAL_TERMINAL_SNAPSHOT"]
        content?.layoutSubtreeIfNeeded()
        let lineHeight = terminal.frame.height
        check(lineHeight > 8 && lineHeight < 30, "terminál: pod panely je jeden řádek (\(lineHeight) b.)")
        // Volitelné snímky okna v obou režimech (kontrola vzhledu okem).
        if let snapshot {
            controller.window?.displayIfNeeded()
            controller.saveSnapshot(to: snapshot + "-radek.png")
        }
        let cmdF12 = event(KeyCode.functionKeys[11], NSF12FunctionKey, [.command])
        check(controller.command(forKey: cmdF12) == .terminalFull, "terminál: ⌘F12 = terminál na celé okno")
        controller.perform(.terminalFull)
        content?.layoutSubtreeIfNeeded()
        check(terminal.isExpanded && terminal.frame.height > 300 && controller.leftPanel.view?.isHiddenOrHasHiddenAncestor == true,
              "terminál: ⌘F12 roztáhne terminál a skryje panely (\(terminal.frame.height) b.)")
        // Roztažený terminál si nechává klávesy příkazů nad panely (F5 patří programu v něm).
        let f5 = event(KeyCode.functionKeys[4], NSF5FunctionKey, [])
        check(controller.command(forKey: f5) == nil && controller.command(forKey: cmdF12) == .terminalFull,
              "terminál: v roztaženém terminálu F5 není příkaz, ⌘F12 ano")
        if let snapshot {
            controller.window?.displayIfNeeded()
            controller.saveSnapshot(to: snapshot + "-cele-okno.png")
        }
        controller.perform(.terminalFull)
        content?.layoutSubtreeIfNeeded()
        check(!terminal.isExpanded && terminal.frame.height == lineHeight && controller.leftPanel.view?.isHiddenOrHasHiddenAncestor == false,
              "terminál: druhé ⌘F12 vrátí jeden řádek a panely")
        check(controller.command(forKey: f5) == .copy, "terminál: po návratu je F5 zase Kopírovat")
        // Lišta F-kláves: ⌘F12 je vidět jen ve vrstvě ⌘ – s ⌃ F12 terminál nepřepíná.
        check(FunctionKeyBar.entries(for: .command)[11] == .terminalFull && FunctionKeyBar.entries(for: .control)[11] == nil,
              "lišta F-kláves: Terminál je na F12 jen s ⌘, ne s ⌃")
        checkTerminalTabs(lineHeight: lineHeight, snapshot: snapshot)
        done()
    }

    /// Záložky terminálu: s jedinou záložkou lišta záložek není, druhá záložka ji
    /// přidá, ⌥⌘→ / ⌥⌘← přepínají a zavření záložky vrátí původní vzhled.
    /// - Parameters:
    ///   - lineHeight: výška terminálu s jedinou záložkou (jeden řádek)
    ///   - snapshot: začátek cesty volitelného snímku okna se dvěma záložkami
    private func checkTerminalTabs(lineHeight: CGFloat, snapshot: String?) {
        let terminal = controller.terminalPane
        let content = controller.window?.contentView
        let cmdT = event(17, Int(("t" as UnicodeScalar).value), [.command])
        let next = event(KeyCode.right, NSRightArrowFunctionKey, [.command, .option])
        check(controller.command(forKey: cmdT) == .terminalNewTab && controller.command(forKey: next) == .terminalNextTab,
              "záložky terminálu: ⌘T = nová záložka, ⌥⌘→ = další záložka")
        check(terminal.tabCount == 1, "záložky terminálu: na začátku je jediná záložka bez lišty")
        controller.perform(.terminalNewTab)
        content?.layoutSubtreeIfNeeded()
        check(terminal.tabCount == 2 && terminal.frame.height == lineHeight + TerminalTabBar.height,
              "záložky terminálu: druhá záložka přidá lištu záložek (\(terminal.frame.height) b.)")
        // Volitelný snímek okna se dvěma záložkami.
        if let snapshot {
            controller.window?.displayIfNeeded()
            controller.saveSnapshot(to: snapshot + "-zalozky.png")
        }
        controller.perform(.terminalNextTab)
        controller.perform(.terminalCloseTab)
        content?.layoutSubtreeIfNeeded()
        check(terminal.tabCount == 1 && terminal.frame.height == lineHeight,
              "záložky terminálu: po zavření záložky zmizí lišta a zůstane jeden řádek")
        controller.perform(.terminalCloseTab)
        check(terminal.tabCount == 1, "záložky terminálu: jedinou záložku zavřít nejde")
    }

    /// Přenos do panelu (vložení, puštění taženého souboru) doběhl: soubor je
    /// v cílovém adresáři, dialog průběhu je zavřený a panel ho má načtený.
    private func transferFinished(_ name: String, in panel: PanelController, directory: String) -> Bool {
        FileManager.default.fileExists(atPath: directory + "/" + name) && controller.window?.attachedSheet == nil
            && !panel.isLoading && panel.rowIndex(named: name) != nil
    }

    /// Schránka souborů a přetažení do panelu: zkratky ⌘C/⌘X/⌘V, položky
    /// kontextového menu, registrace panelu pro přetažení, čtení souborů ze
    /// schránky a vložení do adresáře panelu – kopie z více adresářů, duplikát
    /// v témže adresáři a přesun. Systémové schránky se kontrola nedotkne
    /// (čte se z vlastní pojmenované schránky, vkládá se přímo).
    private func checkFileClipboard(dir: String, then done: @escaping () -> Void) {
        let panel = controller.rightPanel
        guard let view = panel.view, let handler = view.inputHandler else { done(); return }
        let fm = FileManager.default

        // Zkratky: v panelu schránka souborů, v textovém poli zůstávají textu.
        let cmdC = event(8, Int(("c" as UnicodeScalar).value), [.command])
        let cmdX = event(7, Int(("x" as UnicodeScalar).value), [.command])
        let cmdV = event(9, Int(("v" as UnicodeScalar).value), [.command])
        check(KeyBindings.command(for: cmdC) == .clipboardCopy && KeyBindings.command(for: cmdX) == .clipboardCut
              && KeyBindings.command(for: cmdV) == .clipboardPaste,
              "schránka: ⌘C / ⌘X / ⌘V v panelu = kopírovat / vyjmout / vložit soubory")
        check(KeyBindings.command(for: cmdC, textEditing: true) == nil && KeyBindings.command(for: cmdV, textEditing: true) == nil,
              "schránka: v textovém poli ⌘C / ⌘V zůstávají textu")
        // Kontextové menu panelu (tag položky = index příkazu).
        let tags = handler.panelView(view, menuForRow: -1)?.items
            .filter { $0.action == #selector(MainWindowController.menuCommand(_:)) }.map(\.tag) ?? []
        check([Command.clipboardCopy, .clipboardCut, .clipboardPaste].allSatisfy { tags.contains(MainWindowController.menuCommandIndex($0)) },
              "schránka: kontextové menu panelu nabízí Kopírovat / Vyjmout / Vložit")
        check(view.registeredDraggedTypes.contains(.fileURL), "přetažení: panel přijímá soubory z jiné aplikace")
        // Tažení ven: změna klávesy vloží do fronty událostí umělé pohnutí myší se
        // stavem kláves; smyčka tažení si ho z fronty vyzvedne (jako AppKit: maska
        // tažení myší, režim sledování).
        let nudge = DragModifierWatcher.nudgeEvents(flags: .maskAlternate)
        check(nudge.count == 2 && nudge.allSatisfy { $0.type == .leftMouseDragged && $0.modifierFlags.contains(.option) }
              && nudge.first?.cgEvent?.location.x == (nudge.last?.cgEvent?.location.x ?? 0) + 1,
              "přetažení: změna klávesy vytvoří dvě události tažení (o bod vedle a zpět) se stavem kláves")
        if let first = nudge.first { NSApp.postEvent(first, atStart: true) }
        let queued = NSApp.nextEvent(matching: .leftMouseDragged, until: .distantPast, inMode: .eventTracking, dequeue: true)
        check(queued?.modifierFlags.contains(.option) == true && queued?.cgEvent?.flags.contains(.maskAlternate) == true,
              "přetažení: umělou událost lze vyzvednout z fronty událostí aplikace")
        // Trvalé mazání: ⇧F8 i ⌘F8; koš se nabízí jen tam, kde ho svazek má.
        let cmdF8 = event(KeyCode.functionKeys[7], NSF8FunctionKey, [.command])
        let shiftF8 = event(KeyCode.functionKeys[7], NSF8FunctionKey, [.shift])
        check(KeyBindings.command(for: cmdF8) == .deletePermanent && KeyBindings.command(for: shiftF8) == .deletePermanent,
              "mazání: ⌘F8 i ⇧F8 = smazat trvale")
        check(Vfs.localDisk.hasTrash(for: dir) && !Vfs.localDisk.hasTrash(for: "/neexistujici-svazek/adresar")
              && deleteConfirmation(items: [], vfs: .localDisk, dirs: [dir, "/neexistujici-svazek/adresar"],
                                    toTrash: true, verb: "smazat").trashDirs == [dir],
              "mazání: koš se použije jen v adresáři na svazku, který ho má")

        // Zdrojové soubory ve dvou adresářích a prázdný cílový adresář.
        let base = (dir as NSString).deletingLastPathComponent
        let (first, second, target) = (base + "/paste-a", base + "/paste-b", base + "/paste-dst")
        for directory in [first, second, target] {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        for path in [first + "/one.txt", first + "/three.txt", second + "/two.txt"] {
            fm.createFile(atPath: path, contents: Data("obsah".utf8))
        }

        // Čtení souborů ze schránky: jen odkazy na soubory, text se nepočítá.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sal-keycheck-\(getpid())"))
        pasteboard.clearContents()
        pasteboard.setString("text", forType: .string)
        check(!FileClipboard.hasFiles(in: pasteboard) && FileClipboard.paths(from: pasteboard).isEmpty,
              "schránka: text ve schránce nejsou soubory")
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: first + "/one.txt") as NSURL, URL(fileURLWithPath: second + "/two.txt") as NSURL])
        // Cesty se porovnávají podle jmen (dočasný adresář má na disku i delší podobu /private/…).
        let pasted = FileClipboard.paths(from: pasteboard)
        check(FileClipboard.hasFiles(in: pasteboard) && pasted.map(lastComponent) == ["one.txt", "two.txt"],
              "schránka: soubory ze schránky se přečtou jako cesty (\(pasted.count))")
        pasteboard.releaseGlobally()

        func pasteFinished(_ name: String) -> Bool { transferFinished(name, in: panel, directory: target) }
        controller.activate(panel)
        panel.changePath(target)
        poll(until: { panel.location.path == target && !panel.isLoading }) {
            // Kopie ze dvou zdrojových adresářů najednou.
            self.controller.importFiles([first + "/one.txt", second + "/two.txt"], into: panel, move: false)
            self.poll(until: { pasteFinished("one.txt") && pasteFinished("two.txt") }) {
                self.check(pasteFinished("one.txt") && pasteFinished("two.txt") && fm.fileExists(atPath: first + "/one.txt"),
                           "vložení: zkopíruje soubory z více adresářů, zdroj zůstává")
                self.check(panel.currentItem?.name == "one.txt", "vložení: kurzor je na první vložené položce (\(panel.currentItem?.name ?? "-"))")
                // Kopie do adresáře, kde soubor už leží, vytvoří duplikát – i když
                // cesta ze schránky vede přes symbolický odkaz na týž adresář.
                let alias = base + "/paste-odkaz"
                try? fm.createSymbolicLink(atPath: alias, withDestinationPath: target)
                self.controller.importFiles([alias + "/one.txt"], into: panel, move: false)
                self.poll(until: { pasteFinished("one kopie.txt") }) {
                    self.check(pasteFinished("one kopie.txt"), "vložení: kopie do téhož adresáře vytvoří „one kopie.txt“")
                    // Přesun (vložení po Vyjmout, přetažení na stejném svazku nebo s ⌘).
                    self.controller.importFiles([first + "/three.txt"], into: panel, move: true)
                    self.poll(until: { pasteFinished("three.txt") }) {
                        self.check(pasteFinished("three.txt") && !fm.fileExists(atPath: first + "/three.txt"),
                                   "vložení: přesun soubor ze zdroje odebere")
                        done()
                    }
                }
            }
        }
    }

    /// Tažení myší mezi panely podle zvyklostí macOS: panel odmítne tažení ze
    /// sebe sama, do druhého panelu na stejném svazku soubor přesune a s ⌥
    /// (systém pak z nabízených operací nechá jen kopii) zkopíruje, s ⌘ (zbude
    /// jen „generic“) přesune. Tažení zastupuje FakeDraggingInfo s vlastní schránkou.
    private func checkPanelDrop(dir: String, then done: @escaping () -> Void) {
        let source = controller.leftPanel
        let target = controller.rightPanel
        guard let sourceView = source.view, let targetView = target.view else { done(); return }
        let fm = FileManager.default
        let base = (dir as NSString).deletingLastPathComponent
        let (from, to) = (base + "/drag-src", base + "/drag-dst")
        for directory in [from, to] {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        for name in ["kopie.txt", "presun.txt"] {
            fm.createFile(atPath: from + "/" + name, contents: Data("obsah".utf8))
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sal-keycheck-drag-\(getpid())"))

        /// Tažení souboru ze zdrojového panelu s danými nabízenými operacemi.
        func drag(_ name: String, operations: NSDragOperation) -> FakeDraggingInfo {
            pasteboard.clearContents()
            pasteboard.writeObjects([URL(fileURLWithPath: from + "/" + name) as NSURL])
            return FakeDraggingInfo(source: sourceView, pasteboard: pasteboard, operations: operations)
        }
        func dropFinished(_ name: String) -> Bool { transferFinished(name, in: target, directory: to) }
        source.changePath(from)
        target.changePath(to)
        poll(until: { source.location.path == from && target.location.path == to && !source.isLoading && !target.isLoading }) {
            // Nabídka zdroje bez klávesy (viz PanelView – NSDraggingSource).
            let offered = PanelView.offeredDragOperations
            self.check(sourceView.draggingEntered(drag("kopie.txt", operations: offered)).isEmpty,
                       "tažení mezi panely: panel nepřijme tažení ze sebe sama")
            // S ⌥ zbude z nabídky jen kopie.
            let copy = drag("kopie.txt", operations: .copy)
            self.check(targetView.draggingEntered(copy) == .copy && targetView.performDragOperation(copy),
                       "tažení mezi panely: s ⌥ druhý panel nabídne kopii")
            self.poll(until: { dropFinished("kopie.txt") }) {
                self.check(dropFinished("kopie.txt") && fm.fileExists(atPath: from + "/kopie.txt"),
                           "tažení mezi panely: s ⌥ se soubor zkopíruje, zdroj zůstává")
                // S ⌘ zbude jen „generic“ → přesun (i na jiný svazek).
                self.check(targetView.draggingEntered(drag("presun.txt", operations: .generic)) == .generic,
                           "tažení mezi panely: s ⌘ druhý panel nabídne přesun")
                // Bez klávesy na stejném svazku přesun.
                let move = drag("presun.txt", operations: offered)
                self.check(targetView.draggingEntered(move) == .move && targetView.performDragOperation(move),
                           "tažení mezi panely: bez klávesy druhý panel na stejném svazku nabídne přesun")
                self.poll(until: { dropFinished("presun.txt") }) {
                    self.check(dropFinished("presun.txt") && !fm.fileExists(atPath: from + "/presun.txt"),
                               "tažení mezi panely: bez klávesy se soubor přesune")
                    pasteboard.releaseGlobally()
                    done()
                }
            }
        }
    }

    /// ⌃⇧. (druhý panel do aktuálního adresáře) a ⌃. (obráceně), i uvnitř ZIP archivu.
    private func checkSameDir(dir: String, then done: @escaping () -> Void) {
        let left = controller.leftPanel
        let right = controller.rightPanel
        guard let view = left.view, let handler = view.inputHandler else { done(); return }
        controller.activate(left)
        right.changePath("/")
        // Česká klávesnice: ⇧ + klávesa tečky dává znak „:“ – zkratka se musí poznat podle kódu klávesy.
        // ⌃. = poslat adresář do druhého panelu, ⌃⇧. = převzít adresář z druhého panelu.
        let otherToCurrent = event(47, Int(("." as UnicodeScalar).value), [.control])
        let currentToOther = event(47, Int((":" as UnicodeScalar).value), [.control, .shift])
        poll(until: { right.location.path == "/" && !right.isLoading }) {
            _ = handler.panelView(view, keyDown: otherToCurrent)
            self.poll(until: { right.location.path == dir && !right.isLoading }) {
                self.check(right.location.path == dir, "⌃. → druhý panel v adresáři aktivního (\(right.location.path))")
                self.check(self.controller.activePanel === left, "⌃. → aktivní panel zůstává")
                // Obráceně: druhý panel jinam, ⌃. přenese aktivní panel tam.
                right.changePath("/")
                self.poll(until: { right.location.path == "/" && !right.isLoading }) {
                    _ = handler.panelView(view, keyDown: currentToOther)
                    self.poll(until: { left.location.path == "/" && !left.isLoading }) {
                        self.check(left.location.path == "/", "⌃⇧. → aktivní panel v adresáři druhého")
                        self.checkSameDirArchive(dir: dir, handler: handler, view: view, otherToCurrent: otherToCurrent, then: done)
                    }
                }
            }
        }
    }

    /// Uvnitř ZIP: ⌃⇧. předá druhému panelu archiv i zanoření („..“ vede ven z archivu).
    private func checkSameDirArchive(dir: String, handler: PanelInputHandler, view: PanelView,
                                     otherToCurrent: NSEvent, then done: @escaping () -> Void) {
        let left = controller.leftPanel
        let right = controller.rightPanel
        let zipPath = (dir as NSString).appendingPathComponent("archiv.zip")
        try? corePackZip(src: Vfs.localDisk, srcDir: dir, names: ["soubor1.txt"], dest: zipPath, state: ProgressState())
        guard let zip = Vfs.openZip(path: zipPath) else { done(); return }
        left.changePath(dir)
        poll(until: { left.location.path == dir && !left.isLoading }) {
            left.navigate(Location(vfs: zip, path: "/"), nested: true, focus: "archiv.zip")
            self.poll(until: { left.location.vfs === zip && !left.isLoading }) {
                _ = handler.panelView(view, keyDown: otherToCurrent)
                self.poll(until: { right.location.vfs === zip && !right.isLoading }) {
                    self.check(right.location.vfs === zip, "⌃. v archivu → druhý panel ve stejném ZIP")
                    self.check(right.canGoUp, "druhý panel má v archivu „..“")
                    right.goUp()
                    self.poll(until: { right.location.vfs.kind == SAL_VFS_LOCAL && !right.isLoading }) {
                        self.check(right.location.path == dir && right.currentItem?.name == "archiv.zip",
                                   "„..“ v druhém panelu vede ven z archivu na archiv.zip")
                        self.checkShowArchiveItem(dir: dir, zipPath: zipPath, then: done)
                    }
                }
            }
        }
    }

    /// Ukázat položku nalezenou uvnitř archivu (okno Hledat s volbou Hledat
    /// v archivech): panel stojící jinde vstoupí do archivu s kurzorem na
    /// položce a „..“ vede zpět k souboru archivu.
    private func checkShowArchiveItem(dir: String, zipPath: String, then done: @escaping () -> Void) {
        let panel = controller.rightPanel
        guard let zip = Vfs.openArchive(path: zipPath) else {
            check(false, "archiv pro kontrolu Ukázat jde otevřít")
            done()
            return
        }
        panel.changePath("/")
        panel.showArchiveItem(zip, archivePath: zipPath, path: "/soubor1.txt")
        poll(until: { panel.location.vfs === zip && !panel.isLoading }) {
            self.check(panel.location.path == "/" && panel.currentItem?.name == "soubor1.txt",
                       "Ukázat položku z archivu: panel je v archivu s kurzorem na položce")
            panel.goUp()
            self.poll(until: { panel.location.vfs.kind == SAL_VFS_LOCAL && !panel.isLoading }) {
                self.check(panel.location.path == dir && panel.currentItem?.name == "archiv.zip",
                           "„..“ z archivu ukázané položky vede zpět na archiv.zip")
                done()
            }
        }
    }

    /// Zkratky s tečkou v monitoru kláves (běží před menu): podle kódu klávesy,
    /// pro všechny varianty znaků, které klávesnice mohou poslat.
    private func probeMenuPeriod(dir: String) {
        let variants: [(String, String, NSEvent.ModifierFlags, Command)] = [
            ("⌃. (znak .)", ".", [.control], .sameDirOther),
            ("⌘. (znak .)", ".", [.command], .sameDirOther),
            ("⌃⇧. (znak „.“)", ".", [.control, .shift], .sameDir),
            ("⌃⇧. (znak „:“ – česká klávesnice)", ":", [.control, .shift], .sameDir),
            ("⌃⇧. (znak „>“ – US)", ">", [.control, .shift], .sameDir),
            ("⌘⇧. (jako ⌃⇧.)", ":", [.command, .shift], .sameDir),
        ]
        for (label, chars, flags, expected) in variants {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 47)!
            let command = KeyBindings.command(for: event)
            self.check(command == expected, "monitor kláves: \(label) → \(String(describing: command))")
        }
        // ⌃H přes hlavní menu přepne skryté soubory (a druhé ⌃H je vrátí).
        // Uloženou uživatelskou volbu po testu vrátíme přesně (i když chyběla).
        let domain = Bundle.main.bundleIdentifier ?? "com.github.svopex.microcommander"
        let savedHidden = UserDefaults.standard.persistentDomain(forName: domain)?["showHiddenFiles"]
        defer {
            var persistent = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            persistent["showHiddenFiles"] = savedHidden
            UserDefaults.standard.setPersistentDomain(persistent, forName: domain)
        }
        let before = controller.showHiddenFiles
        let ctrlH = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                                     windowNumber: 0, context: nil, characters: "\u{8}",
                                     charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4)!
        _ = NSApp.mainMenu?.performKeyEquivalent(with: ctrlH)
        self.check(controller.showHiddenFiles != before, "⌃H přes menu přepne skryté soubory")
        _ = NSApp.mainMenu?.performKeyEquivalent(with: ctrlH)
        self.check(controller.showHiddenFiles == before, "druhé ⌃H vrátí původní stav")
    }

    /// Úklid a výsledek kontroly.
    private func finish(dir: String) {
        do {
            // Volitelný snímek dialogu připojení (hodnoty dodají argumenty -connect…).
            if let path = ProcessInfo.processInfo.environment["SAL_CONNECT_SNAPSHOT"] {
                self.writeSnapshot(ConnectWindowController(owner: self.controller), to: path)
            }
            // Volitelný snímek okna Nastavení.
            if let path = ProcessInfo.processInfo.environment["SAL_SETTINGS_SNAPSHOT"] {
                self.writeSnapshot(SettingsWindowController(), to: path)
            }
            // Volitelný snímek dialogu „Upravit nabídku disků“.
            if let path = ProcessInfo.processInfo.environment["SAL_PLACES_SNAPSHOT"] {
                self.writeSnapshot(PlacesWindowController(), to: path)
            }
            try? FileManager.default.removeItem(atPath: (dir as NSString).deletingLastPathComponent)
            print(self.failures == 0 ? "KEYCHECK: vše OK" : "KEYCHECK: \(self.failures) chyb")
            exit(self.failures == 0 ? 0 : 1)
        }
    }

    /// Uloží snímek okna dialogu do PNG (vykreslení mimo obrazovku).
    /// Světlý vzhled: mimo obrazovku se pozadí okna nekreslí (bílý text by nebyl vidět).
    /// Bere kontroler, aby žil po celou dobu snímku (tabulky mají delegáta slabě).
    private func writeSnapshot(_ controller: NSWindowController, to path: String) {
        let window = controller.window
        window?.appearance = NSAppearance(named: .aqua)
        // Tabulky vytvoří buňky až při rozvržení a vykreslení – vynutit před snímkem.
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        if let view = window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        withExtendedLifetime(controller) {}
    }

    /// Leží řádek s kurzorem ve viditelné části panelu?
    private func cursorVisible(_ view: PanelView) -> Bool {
        view.layoutSubtreeIfNeeded()
        let visible = view.scrollView.contentView.bounds
        let cursorRect = view.viewMode.usesTable
            ? view.tableView.rect(ofRow: view.panel.cursor)
            : view.gridView.rect(for: view.panel.cursor)
        return visible.contains(cursorRect.insetBy(dx: 1, dy: 1)) || visible.intersection(cursorRect).width >= cursorRect.width - 2
    }

    /// Nabídka disků (bez zobrazení okna): ↑/↓ cyklí přes konec, Home/End, číslice, Escape.
    private func checkDriveChooser() {
        let entries = (1...4).map { DriveChooser.Entry(title: "Disk \($0)", detail: "/d\($0)", icon: nil) }
        var chosen: Int?
        let chooser = DriveChooser(entries: entries, selected: 3) { chosen = $0 }
        self.check(chooser.selectedIndex == 3, "nabídka disků: výchozí řádek = aktuální disk")
        _ = chooser.handleKey(event(KeyCode.down, NSDownArrowFunctionKey, [.function]))
        self.check(chooser.selectedIndex == 0, "nabídka disků: ↓ na posledním → první řádek (\(chooser.selectedIndex))")
        _ = chooser.handleKey(event(KeyCode.up, NSUpArrowFunctionKey, [.function]))
        self.check(chooser.selectedIndex == 3, "nabídka disků: ↑ na prvním → poslední řádek (\(chooser.selectedIndex))")
        _ = chooser.handleKey(event(KeyCode.up, NSUpArrowFunctionKey, [.function]))
        self.check(chooser.selectedIndex == 2, "nabídka disků: ↑ uprostřed → předchozí řádek")
        _ = chooser.handleKey(event(KeyCode.home, NSHomeFunctionKey, [.function]))
        self.check(chooser.selectedIndex == 0, "nabídka disků: Home → první")
        _ = chooser.handleKey(event(KeyCode.end, NSEndFunctionKey, [.function]))
        self.check(chooser.selectedIndex == 3, "nabídka disků: End → poslední")
        _ = chooser.handleKey(event(KeyCode.digits[1], Int(("2" as UnicodeScalar).value), []))
        self.check(chosen == 1, "nabídka disků: číslice 2 vybere druhý disk")
        var keypadChoice: Int?
        let keypad = DriveChooser(entries: entries, selected: 0) { keypadChoice = $0 }
        // Kód 85 = „3“ na numerické klávesnici.
        _ = keypad.handleKey(event(85, Int(("3" as UnicodeScalar).value), [.numericPad]))
        self.check(keypadChoice == 2, "nabídka disků: 3 na numerické klávesnici vybere třetí položku")
        var cancelledChoice: Int?
        let other = DriveChooser(entries: entries, selected: 0) { cancelledChoice = $0 }
        _ = other.handleKey(event(KeyCode.escape, 0x1b, []))
        _ = other.handleKey(event(KeyCode.returnKey, 0x0d, []))
        self.check(cancelledChoice == nil, "nabídka disků: Escape zavře bez výběru")
        // Změna pořadí: ⌥↓ / ⌥↑ přesouvají disk, poslední položka (FTP) se nehýbe.
        var moves: [(Int, Int)] = []
        let reorder = DriveChooser(entries: entries, selected: 0, movableGroups: [0..<3]) { _ in }
        reorder.onMove = { moves.append(($0, $1)) }
        _ = reorder.handleKey(event(KeyCode.down, NSDownArrowFunctionKey, [.option, .function]))
        self.check(moves.count == 1 && moves[0] == (0, 1) && reorder.selectedIndex == 1,
                   "nabídka disků: ⌥↓ posune disk dolů (výběr jde s ním)")
        _ = reorder.handleKey(event(KeyCode.up, NSUpArrowFunctionKey, [.option, .function]))
        self.check(moves.count == 2 && moves[1] == (1, 0) && reorder.selectedIndex == 0,
                   "nabídka disků: ⌥↑ posune disk nahoru")
        _ = reorder.handleKey(event(KeyCode.up, NSUpArrowFunctionKey, [.option, .function]))
        self.check(moves.count == 2, "nabídka disků: první disk výš neposune")
        reorder.select(3)
        _ = reorder.handleKey(event(KeyCode.up, NSUpArrowFunctionKey, [.option, .function]))
        self.check(moves.count == 2, "nabídka disků: „FTP/SFTP servery…“ se nepřesouvá")
        // Zkratky míst ⌘0–⌘9: jen se samotným ⌘, horní řada i numerická klávesnice.
        self.check(KeyCode.commandDigit(event(KeyCode.digitZero, Int(("0" as UnicodeScalar).value), [.command])) == 0,
                   "zkratka místa: ⌘0")
        self.check(KeyCode.commandDigit(event(KeyCode.digits[2], Int(("3" as UnicodeScalar).value), [.command])) == 3,
                   "zkratka místa: ⌘3 (horní řada)")
        self.check(KeyCode.commandDigit(event(91, Int(("8" as UnicodeScalar).value), [.command, .numericPad])) == 8,
                   "zkratka místa: ⌘8 na numerické klávesnici")
        self.check(KeyCode.commandDigit(event(KeyCode.digits[0], Int(("1" as UnicodeScalar).value), [.option])) == nil
                   && KeyCode.commandDigit(event(KeyCode.digits[0], Int(("1" as UnicodeScalar).value), [.command, .shift])) == nil,
                   "zkratka místa: ⌥1 ani ⌘⇧1 nejsou zkratka místa")
        // Pořadí míst: uložené klíče první, nová místa na konec, neexistující se přeskočí.
        let natural = ["a", "b", "c"].map { Place(key: $0, kind: .folder, title: $0, detail: "/" + $0, icon: nil) }
        let ordered = PlaceStore.ordered(natural, saved: ["c", "x", "a"]).map(\.key)
        self.check(ordered == ["c", "a", "b"], "nabídka disků: uložené pořadí, nové místo na konec (\(ordered))")
        // Výchozí pořadí (jen pokud uživatel ještě nic neuložil): Domů první.
        if UserDefaults.standard.object(forKey: "placesOrder") == nil {
            self.check(PlaceStore.allPlaces().first?.detail == NSHomeDirectory(), "výchozí pořadí disků: Domů první")
        }
        // Volitelný snímek skutečné nabídky (vykreslení mimo obrazovku, bez zobrazení okna).
        if let path = ProcessInfo.processInfo.environment["SAL_CHOOSER_SNAPSHOT"] {
            let items = MainWindowController.driveChooserItems()
            let snapshot = DriveChooser(entries: items.map(\.entry), selected: 1,
                                        movableGroups: MainWindowController.driveChooserGroups(items)) { _ in }
            // Okno mimo obrazovku se samo nerozvrhne – vynutit layout před snímkem.
            snapshot.window?.contentView?.layoutSubtreeIfNeeded()
            snapshot.tableView.layoutSubtreeIfNeeded()
            snapshot.window?.displayIfNeeded()
            if let view = snapshot.window?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Uložené servery: zobrazovaný název, adresa, potřeba hesla a převod do/z JSON
    /// (bez zápisu do UserDefaults a Klíčenky).
    private func checkServerProfiles() {
        var ftp = ServerProfile()
        ftp.host = "ftp.example.org"
        self.check(ftp.displayName == "anonymous@ftp.example.org", "server: název bez vyplnění = uživatel@server")
        self.check(ftp.urlString == "ftp://anonymous@ftp.example.org", "server: výchozí port se v adrese vynechá")
        self.check(!ftp.needsSecret, "server: anonymní FTP heslo nevyžaduje")
        var sftp = ftp
        sftp.name = "  Produkce "
        sftp.isSftp = true
        sftp.port = 2222
        sftp.user = "deploy"
        sftp.auth = .agent
        self.check(sftp.displayName == "Produkce", "server: vlastní název (bez mezer okolo)")
        self.check(sftp.urlString == "sftp://deploy@ftp.example.org:2222", "server: jiný port je v adrese")
        self.check(!sftp.needsSecret, "server: ssh-agent heslo nevyžaduje")
        sftp.auth = .password
        self.check(sftp.needsSecret, "server: SFTP s heslem heslo vyžaduje")
        ftp.isSftp = false
        ftp.auth = .keyFile
        self.check(ftp.effectiveAuth == .password, "server: FTP ověřuje vždy heslem")
        let list = [ftp, sftp]
        let decoded = (try? JSONEncoder().encode(list)).flatMap { try? JSONDecoder().decode([ServerProfile].self, from: $0) }
        self.check(decoded == list, "server: seznam se uloží a načte beze změny (JSON)")
    }

    /// Počká (časovač run loopu) na splnění podmínky, max. 10 s.
    private func poll(until condition: @escaping () -> Bool, waited: Double = 0, then action: @escaping () -> Void) {
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            if condition() || waited >= 10 {
                action()
            } else {
                self.poll(until: condition, waited: waited + 0.1, then: action)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Zástupné tažení pro kontrolu příjmu souborů v panelu (UIKeyCheck): nese jen
/// zdroj, schránku a nabízené operace, zbytek rozhraní je prázdný.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingSource: Any?
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation

    /// - Parameters:
    ///   - source: pohled, ze kterého se táhne
    ///   - pasteboard: schránka s taženými soubory
    ///   - operations: operace nabízené zdrojem (po zúžení klávesami)
    init(source: Any?, pasteboard: NSPasteboard, operations: NSDragOperation) {
        draggingSource = source
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = operations
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    // NSObject má tuto (zastaralou) metodu neformálně deklarovanou – proto override.
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
