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

    /// Zobrazovat svislou lištu příkazů mezi panely; výchozí ne = jen úzký
    /// dělicí pruh jako v Salamanderu.
    static var showMiddleBar: Bool {
        get { UserDefaults.standard.bool(forKey: middleBarKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: middleBarKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}

/// Okno Nastavení (jedno pro celou aplikaci, otevírá se z menu ⌘,).
final class SettingsWindowController: NSWindowController {
    /// Jediná instance (okno se při dalším otevření jen přenese dopředu).
    private static var shared: SettingsWindowController?

    private let middleBarCheckbox = NSButton(checkboxWithTitle: "Zobrazovat lištu příkazů mezi panely",
                                             target: nil, action: nil)

    /// Zobrazí okno Nastavení (vytvoří ho při prvním otevření).
    static func show() {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        controller.refresh()
        controller.showWindow(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
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

    /// Skupina „Vzhled“: zaškrtávátko a vysvětlivka pod ním.
    private func buildLayout() {
        let heading = NSTextField(labelWithString: "Vzhled")
        heading.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        middleBarCheckbox.target = self
        middleBarCheckbox.action = #selector(middleBarToggled(_:))
        let note = NSTextField(wrappingLabelWithString:
            "Svislá lišta s ikonami operací (kopírovat, přesunout, smazat…) mezi levým a pravým panelem. "
            + "Vypnutá lišta zůstane jen jako úzký dělicí pruh.")
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, middleBarCheckbox, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: middleBarCheckbox)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            note.widthAnchor.constraint(equalToConstant: 400),
        ])
        window?.contentView = content
    }

    /// Načte aktuální hodnoty voleb do ovládacích prvků.
    private func refresh() {
        middleBarCheckbox.state = Settings.showMiddleBar ? .on : .off
    }

    @objc private func middleBarToggled(_ sender: NSButton) {
        Settings.showMiddleBar = sender.state == .on
    }
}
