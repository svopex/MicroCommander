// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Uložené FTP/SFTP servery: model, úložiště v UserDefaults, hesla v Klíčence
// a připojení serveru v panelu (nabídka disků ⌥F1/⌥F2, správa serverů).

import AppKit
import Security

/// Způsob ověření (FTP vždy heslo; u SFTP heslo, soubor s klíčem nebo ssh-agent).
enum ServerAuth: Int, Codable {
    case password = 0, keyFile = 1, agent = 2
}

/// Uložený FTP/SFTP server. Heslo (u klíče heslo ke klíči) se v profilu nikdy
/// neukládá – jen volitelně v Klíčence pod `id`.
struct ServerProfile: Codable, Equatable {
    var id = UUID()
    /// Název v nabídce; prázdný = „uživatel@server“.
    var name = ""
    var isSftp = false
    var host = ""
    var port: UInt16 = 21
    var user = "anonymous"
    var auth = ServerAuth.password
    /// Cesta k soukromému klíči (může začínat „~“).
    var keyPath = ""
    /// Ukládat heslo / heslo ke klíči do Klíčenky.
    var savePassword = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, isSftp, host, port, user, auth, keyPath, savePassword
    }

    /// Dekódování odolné vůči chybějícím klíčům (pole přidaná v novější verzi
    /// dostanou výchozí hodnotu, uložené servery se neztratí).
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        isSftp = try values.decodeIfPresent(Bool.self, forKey: .isSftp) ?? false
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(UInt16.self, forKey: .port) ?? ServerProfile.defaultPort(sftp: isSftp)
        user = try values.decodeIfPresent(String.self, forKey: .user) ?? ""
        auth = try values.decodeIfPresent(ServerAuth.self, forKey: .auth) ?? .password
        keyPath = try values.decodeIfPresent(String.self, forKey: .keyPath) ?? ""
        savePassword = try values.decodeIfPresent(Bool.self, forKey: .savePassword) ?? false
    }

    /// Výchozí port protokolu.
    static func defaultPort(sftp: Bool) -> UInt16 { sftp ? 22 : 21 }

    /// Skutečně použité ověření (FTP umí jen heslo).
    var effectiveAuth: ServerAuth { isSftp ? auth : .password }

    /// Název pro nabídky a seznam serverů.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if host.isEmpty { return "Nový server" }
        return user.isEmpty ? host : "\(user)@\(host)"
    }

    /// Adresa ve tvaru URL (popis v nabídce); výchozí port se vynechá.
    var urlString: String {
        let scheme = isSftp ? "sftp" : "ftp"
        let userPart = user.isEmpty ? "" : user + "@"
        let portPart = port == ServerProfile.defaultPort(sftp: isSftp) ? "" : ":\(port)"
        return "\(scheme)://\(userPart)\(host)\(portPart)"
    }

    /// Cesta ke klíči s rozvinutou „~“.
    var expandedKeyPath: String {
        (keyPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
    }

    /// Potřebuje připojení tajný údaj? Anonymní FTP a ssh-agent ne,
    /// klíč jen tehdy, když je chráněný heslem.
    var needsSecret: Bool {
        switch effectiveAuth {
        case .password: return isSftp || user != "anonymous"
        case .keyFile: return sshKeyEncrypted(path: expandedKeyPath) == true
        case .agent: return false
        }
    }

    /// Připojí se k serveru (blokující – volat mimo hlavní vlákno).
    /// - Parameters:
    ///   - secret: heslo uživatele, u klíče heslo ke klíči (jinak se ignoruje)
    ///   - timeout: časový limit připojení v sekundách
    func connect(secret: String, timeout: Double = 15) throws -> Vfs {
        switch (isSftp, effectiveAuth) {
        case (false, _):
            return try Vfs.connectFtp(host: host, port: port, user: user, password: secret, timeout: timeout)
        case (true, .password):
            return try Vfs.connectSftp(host: host, port: port, user: user, password: secret, timeout: timeout)
        case (true, .keyFile):
            return try Vfs.connectSftpKey(host: host, port: port, user: user, keyPath: expandedKeyPath,
                                          passphrase: secret, timeout: timeout)
        case (true, .agent):
            return try Vfs.connectSftpAgent(host: host, port: port, user: user, timeout: timeout)
        }
    }
}

/// Seznam uložených serverů v UserDefaults (JSON pod klíčem „servers“).
enum ServerStore {
    private static let key = "servers"
    /// Klíče jediného serveru z dřívějšího dialogu připojení (jen pro převod).
    private static let legacyKeys = ["connectSftp", "connectHost", "connectPort", "connectUser", "connectAuth", "connectKey"]

    /// Načte servery; při prvním spuštění převezme poslední server ze starého dialogu.
    static func load() -> [ServerProfile] {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode([ServerProfile].self, from: data)) ?? []
        }
        return migrateLegacy()
    }

    /// Uloží servery.
    static func save(_ servers: [ServerProfile]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Převod jediného zapamatovaného serveru z dřívějšího dialogu připojení
    /// (klíče connectHost, connectPort…); bez něj vznikne prázdný seznam.
    private static func migrateLegacy() -> [ServerProfile] {
        let defaults = UserDefaults.standard
        var servers: [ServerProfile] = []
        if let host = defaults.string(forKey: "connectHost"), !host.isEmpty {
            var profile = ServerProfile()
            profile.isSftp = defaults.bool(forKey: "connectSftp")
            profile.host = host.trimmingCharacters(in: .whitespaces)
            profile.port = UInt16(defaults.string(forKey: "connectPort") ?? "") ?? ServerProfile.defaultPort(sftp: profile.isSftp)
            profile.user = defaults.string(forKey: "connectUser") ?? profile.user
            profile.auth = ServerAuth(rawValue: defaults.integer(forKey: "connectAuth")) ?? .password
            profile.keyPath = defaults.string(forKey: "connectKey") ?? ""
            servers.append(profile)
        }
        save(servers)
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
        return servers
    }
}

/// Hesla serverů v Klíčence (generic password, služba „MicroCommander FTP/SFTP“,
/// účet = UUID serveru).
enum ServerKeychain {
    private static let service = "MicroCommander FTP/SFTP"

    // Společná část dotazu pro jeden server.
    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    /// Uložené heslo serveru (nil = žádné).
    static func secret(for id: UUID) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Uloží (přepíše) heslo serveru: aktualizace existující položky, jinak nová.
    static func setSecret(_ secret: String, for id: UUID) {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(baseQuery(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var query = baseQuery(id)
        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = service
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Smaže heslo serveru (neexistující položka nevadí).
    static func removeSecret(for id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}

extension MainWindowController {
    /// Připojí uložený server v panelu (výběr z nabídky disků). Heslo vezme
    /// z Klíčenky, chybějící si vyžádá dialogem.
    func connect(server: ServerProfile, in panel: PanelController) {
        // Klíčenka se čte jen tehdy, když je heslo potřeba (agent, anonymní FTP ne).
        var secret = ""
        if server.needsSecret {
            secret = server.savePassword ? (ServerKeychain.secret(for: server.id) ?? "") : ""
            if secret.isEmpty {
                guard let entered = askSecret(for: server) else { return }
                secret = entered
            }
        }
        connect(server: server, secret: secret, in: panel)
    }

    /// Připojí server se zadaným heslem: na pozadí s dialogem průběhu,
    /// po úspěchu otevře server v panelu (Odpojit / F12 vrátí předchozí místo).
    func connect(server: ServerProfile, secret: String, in panel: PanelController) {
        // Zrušit zavře dialog hned; síťové volání doběhne na pozadí (max. timeout)
        // a spojení se zahodí.
        var connected: Vfs?
        beginProgress(title: "Připojuji k \(server.displayName)…", dismissOnCancel: true, operation: { _ in
            connected = try server.connect(secret: secret)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.endProgress()
            switch result {
            case .success:
                guard let vfs = connected else { return }
                panel.navigate(Location(vfs: vfs, path: "/"), nested: true, focus: panel.currentItem?.name)
                self.activate(panel)
            case .failure(let error):
                self.showConnectError(error, server: server, panel: panel)
            }
        })
    }

    /// Dotaz na heslo (u klíče heslo ke klíči); nil = zrušeno.
    private func askSecret(for server: ServerProfile) -> String? {
        let keyFile = server.effectiveAuth == .keyFile
        return askSecretText(
            title: keyFile ? "Heslo ke klíči" : "Heslo pro \(server.user)@\(server.host)",
            text: keyFile
                ? "Klíč \(server.keyPath) je chráněný heslem (server \(server.displayName))."
                : "Server \(server.displayName) (\(server.urlString)).",
            okTitle: "Připojit")
    }

    /// Chyba připojení s možností rovnou upravit nastavení serveru.
    private func showConnectError(_ error: Error, server: ServerProfile, panel: PanelController) {
        let alert = NSAlert()
        alert.messageText = "Připojení k \(server.displayName) se nezdařilo"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Upravit server…")
        if alert.runModal() == .alertSecondButtonReturn {
            ConnectWindowController.show(parent: self, panel: panel, selecting: server.id)
        } else {
            focusActivePanel()
        }
    }
}
