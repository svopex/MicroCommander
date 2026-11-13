// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Nastavení aplikace (⌘,): volby vzhledu uložené v UserDefaults a okno
// Nastavení. Změna se hned projeví v hlavním okně (oznámení Settings.changed).

import AppKit

/// Volby aplikace v UserDefaults.
enum Settings {
    /// Oznámení o změně nastavení (hlavní okno se překreslí).
    static let changed = Notification.Name("MicroCommanderSettingsChanged")
    private static let middleBarKey = "showMiddleBar"
    private static let markDirsKey = "selectAllIncludesDirs"

    /// Zobrazovat svislou lištu příkazů mezi panely; výchozí ne = jen úzký
    /// dělicí pruh jako v Salamanderu.
    static var showMiddleBar: Bool {
        get { UserDefaults.standard.bool(forKey: middleBarKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: middleBarKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Označit vše (⌘A) a Invertovat označení (Num *) pracují i s adresáři;
    /// výchozí ano (bez uložené volby).
    /// Zrušení označení platí vždy i pro adresáře.
    static var markingIncludesDirs: Bool {
        get { UserDefaults.standard.object(forKey: markDirsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: markDirsKey) }
    }
}

/// Okno Nastavení (jedno pro celou aplikaci, otevírá se z menu ⌘,).
final class SettingsWindowController: NSWindowController {
    /// Jediná instance (okno se při dalším otevření jen přenese dopředu).
    private static var shared: SettingsWindowController?

    private let middleBarCheckbox = NSButton(checkboxWithTitle: "Zobrazovat lištu příkazů mezi panely",
                                             target: nil, action: nil)
    private let markDirsCheckbox = NSButton(checkboxWithTitle: "Označit vše (⌘A) a Invertovat označení i s adresáři",
                                              target: nil, action: nil)

    /// Zobrazí okno Nastavení (vytvoří ho při prvním otevření).
    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.refresh()
        controller.showWindow(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Nastavení"
        window.isReleasedWhenClosed = false
        // Na střed jen při vytvoření (posunuté okno zůstává, kde ho uživatel nechal).
        window.center()
        super.init(window: window)
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Skupiny „Vzhled“ a „Označování“: zaškrtávátka s vysvětlivkou pod nimi.
    private func buildLayout() {
        // Nadpis skupiny a šedá vysvětlivka (sdílený vzhled obou skupin).
        func heading(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 400).isActive = true
            return label
        }
        middleBarCheckbox.target = self
        middleBarCheckbox.action = #selector(middleBarToggled(_:))
        markDirsCheckbox.target = self
        markDirsCheckbox.action = #selector(markDirsToggled(_:))
        let middleBarNote = note("Svislá lišta s ikonami operací (kopírovat, přesunout, smazat…) mezi levým a pravým panelem. "
                                 + "Vypnutá lišta zůstane jen jako úzký dělicí pruh.")
        let markDirsNote = note("Výchozí je zapnuto. Bez zaškrtnutí ⌘A označí a Invertovat (Num *) invertuje jen soubory. "
                                + "Opakovaný stisk ⌘A zruší celé označení (vždy i adresáře).")

        let stack = NSStackView(views: [heading("Vzhled"), middleBarCheckbox, middleBarNote,
                                        heading("Označování"), markDirsCheckbox, markDirsNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: middleBarCheckbox)
        stack.setCustomSpacing(18, after: middleBarNote)
        stack.setCustomSpacing(4, after: markDirsCheckbox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
    }

    /// Načte aktuální hodnoty voleb do ovládacích prvků.
    private func refresh() {
        middleBarCheckbox.state = Settings.showMiddleBar ? .on : .off
        markDirsCheckbox.state = Settings.markingIncludesDirs ? .on : .off
    }

    @objc private func middleBarToggled(_ sender: NSButton) {
        Settings.showMiddleBar = sender.state == .on
    }

    @objc private func markDirsToggled(_ sender: NSButton) {
        Settings.markingIncludesDirs = sender.state == .on
    }
}
