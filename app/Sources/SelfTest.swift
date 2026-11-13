// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vývojářský self-test UI (SAL_SELFTEST=1): posílá do aplikace skutečné
// klávesové události (přes frontu událostí, tedy i přes monitory a modální
// dialogy) a ověřuje navigaci, označování, Tab, dialogy bez zamrznutí,
// kopírování F5 a mazání F8 nad dočasným adresářem. Výsledek vypíše a skončí.

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

    /// Řetězec F-klávesy (znak NSF1FunctionKey + n).

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
        let savedSettings = ["showHiddenFiles", "viewModeLeft", "viewModeRight"].map { ($0, defaults.object(forKey: $0)) }
        restoreSettings = {
            for (key, value) in savedSettings {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
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
            // 7) Ve druhém panelu F8 smaže a.txt (Enter potvrdí).
            self.key(KeyCode.tab, "\t")
        }))
        steps.append((ready: { self.controller.activePanel === right() }, action: {
            copiedBefore = FileManager.default.fileExists(atPath: self.root + "/dst/a.txt")
            right().focus(name: "a.txt")
            self.key(KeyCode.functionKeys[7], KeyCode.functionKeyString(8))
        }))
        steps.append((ready: { NSApp.modalWindow != nil }, action: {
            self.check(NSApp.modalWindow != nil, "F8 otevře potvrzení mazání")
            self.key(KeyCode.returnKey, "\r")
        }))
        steps.append((ready: { self.windowFree && !FileManager.default.fileExists(atPath: self.root + "/dst/a.txt") }, action: {
            let gone = !FileManager.default.fileExists(atPath: self.root + "/dst/a.txt")
            self.check(gone && copiedBefore, "F8 smazal a.txt v dst")
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
            let disk = Vfs.openLocal(root: nil)!
            try? corePackZip(src: disk, srcDir: self.root + "/src", names: ["b.txt"],
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

    func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Testovací adresář s podadresářem (aby první položka byla „..“) a 40 soubory.
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
            self.checkSameDir(dir: dir, then: { self.finish(dir: dir) })
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
        guard let disk = Vfs.openLocal(root: nil) else { done(); return }
        try? corePackZip(src: disk, srcDir: dir, names: ["soubor1.txt"], dest: zipPath, state: ProgressState())
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
                        done()
                    }
                }
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
            let command = controller.periodShortcutCommand(event)
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
        if UserDefaults.standard.object(forKey: "placesOrder") == nil && UserDefaults.standard.object(forKey: "driveOrder") == nil {
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
