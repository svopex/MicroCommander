// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Swift obálka nad C ABI jádra salcore (core/include/microcommander.h).
// Poskytuje bezpečné Swift API: třída Vfs (handle + list), Item, operace
// s progresem a zrušením. Volání jádra bez zamykání – jádro je thread-safe
// na úrovni jednoho handle (FTP/SFTP si serializace řeší samy).

import Foundation
import microcommander

// Konstanty z microcommander.h – C makra (#define) se do Swiftu neimportují,
// proto je deklarujeme přímo (hodnoty musí odpovídat hlavičce).
let SAL_OK: Int32 = 0
let SAL_ERR_CANCELLED: Int32 = 1
let SAL_ERR_GENERIC: Int32 = -1
let SAL_ERR_NOT_FOUND: Int32 = -2
let SAL_ERR_EXISTS: Int32 = -3
let SAL_ERR_NOT_EMPTY: Int32 = -4
let SAL_ERR_PERMISSION: Int32 = -5
let SAL_ERR_PASSWORD_REQUIRED: Int32 = -7
let SAL_ERR_BAD_PASSWORD: Int32 = -8
let SAL_VFS_LOCAL: Int32 = 1
let SAL_VFS_ZIP: Int32 = 2
let SAL_VFS_TAR: Int32 = 3
let SAL_VFS_FTP: Int32 = 4
let SAL_VFS_SFTP: Int32 = 5
let SAL_FLAG_DIR: UInt32 = 1
let SAL_FLAG_LINK: UInt32 = 2
let SAL_FLAG_HIDDEN: UInt32 = 4
let SAL_FLAG_READONLY: UInt32 = 8
let SAL_FLAG_ENCRYPTED: UInt32 = 16
let SAL_OVERWRITE_ASK: Int32 = 0
let SAL_OVERWRITE_OVERWRITE: Int32 = 1
let SAL_OVERWRITE_SKIP: Int32 = 2
let SAL_FIND_SUBDIRS: UInt32 = 1
let SAL_FIND_INCLUDE_DIRS: UInt32 = 2
let SAL_FIND_CONTENT: UInt32 = 4
let SAL_FIND_CASE: UInt32 = 8
let SAL_FIND_WHOLE_WORDS: UInt32 = 16
let SAL_FIND_REGEX: UInt32 = 32
let SAL_FIND_HEX: UInt32 = 64
let SAL_FIND_NAME_CONTAINS: UInt32 = 128

/// Jedna položka výpisu adresáře.
struct Item {
    let name: String
    let size: UInt64
    let mtime: Int64
    let flags: UInt32

    var isDir: Bool { flags & UInt32(SAL_FLAG_DIR) != 0 }
    var isLink: Bool { flags & UInt32(SAL_FLAG_LINK) != 0 }
    var isHidden: Bool { flags & UInt32(SAL_FLAG_HIDDEN) != 0 }
    var isReadonly: Bool { flags & UInt32(SAL_FLAG_READONLY) != 0 }
    var isEncrypted: Bool { flags & SAL_FLAG_ENCRYPTED != 0 }
}

/// Chyba jádra: numerický kód + text.
enum CoreError: LocalizedError {
    case code(Int32, String)

    var errorDescription: String? {
        switch self {
        case .code(let code, let message):
            if code == SAL_ERR_EXISTS {
                return "\(message) (cíl už existuje)"
            }
            return message.isEmpty ? "Chyba jádra (\(code))." : message
        }
    }

    /// Chybí heslo k šifrované položce archivu?
    var isPasswordRequired: Bool {
        if case .code(let code, _) = self, code == SAL_ERR_PASSWORD_REQUIRED { return true }
        return false
    }

    /// Bylo zadané heslo k archivu chybné?
    var isBadPassword: Bool {
        if case .code(let code, _) = self, code == SAL_ERR_BAD_PASSWORD { return true }
        return false
    }

    /// Je to konflikt existujícího cíle (UI se pak ptá na přepsání)?
    var isExistsConflict: Bool {
        if case .code(let code, _) = self, code == SAL_ERR_EXISTS { return true }
        return false
    }
}

/// Otevřený souborový systém (lokální, archiv, FTP, SFTP).
final class Vfs {
    /// C handle z jádra (nesmí být nikdy NULL).
    let ptr: UnsafeMutablePointer<SalVfs>
    /// Popisek pro titulek panelu (vyplněný při vytvoření).
    let label: String

    private init(ptr: UnsafeMutablePointer<SalVfs>, label: String) {
        self.ptr = ptr
        self.label = label
    }

    deinit {
        sal_vfs_close(ptr)
    }

    // Vytvoření handle z výstupu open/connect funkcí + načtení popisku.
    private static func wrap(_ raw: UnsafeMutablePointer<SalVfs>?) -> Vfs? {
        guard let raw else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        _ = sal_vfs_label(raw, &buffer, 1024)
        let label = String(cString: buffer)
        return Vfs(ptr: raw, label: label)
    }

    /// Lokální disk; root nil = celý disk.
    static func openLocal(root: String?) -> Vfs? {
        if let root {
            return root.withCString { wrap(sal_open_local($0)) }
        }
        return wrap(sal_open_local(nil))
    }

    /// ZIP archiv jako VFS.
    static func openZip(path: String) -> Vfs? {
        path.withCString { wrap(sal_open_zip($0)) }
    }

    /// TAR / TAR.GZ archiv jako VFS.
    static func openTar(path: String) -> Vfs? {
        path.withCString { wrap(sal_open_tar($0)) }
    }

    /// Připojení FTP; hodí chybu s textem od jádra.
    static func connectFtp(host: String, port: UInt16, user: String,
                           password: String, timeout: Double) throws -> Vfs {
        var err = [CChar](repeating: 0, count: 1024)
        let raw = host.withCString { hostC -> UnsafeMutablePointer<SalVfs>? in
            user.withCString { userC in
                password.withCString { passC in
                    sal_connect_ftp(hostC, port, userC, passC, timeout, &err, 1024)
                }
            }
        }
        guard let raw else {
            throw CoreError.code(SAL_ERR_GENERIC, String(cString: err))
        }
        return wrap(raw)!
    }

    /// Připojení SFTP; hodí chybu s textem od jádra.
    static func connectSftp(host: String, port: UInt16, user: String,
                            password: String, timeout: Double) throws -> Vfs {
        var err = [CChar](repeating: 0, count: 1024)
        let raw = host.withCString { hostC -> UnsafeMutablePointer<SalVfs>? in
            user.withCString { userC in
                password.withCString { passC in
                    sal_connect_sftp(hostC, port, userC, passC, timeout, &err, 1024)
                }
            }
        }
        guard let raw else {
            throw CoreError.code(SAL_ERR_GENERIC, String(cString: err))
        }
        return wrap(raw)!
    }

    /// Připojení SFTP soukromým klíčem ze souboru (passphrase prázdná = klíč bez hesla).
    static func connectSftpKey(host: String, port: UInt16, user: String, keyPath: String,
                               passphrase: String, timeout: Double) throws -> Vfs {
        var err = [CChar](repeating: 0, count: 1024)
        let raw = host.withCString { hostC -> UnsafeMutablePointer<SalVfs>? in
            user.withCString { userC in
                keyPath.withCString { keyC in
                    passphrase.withCString { passC in
                        sal_connect_sftp_key(hostC, port, userC, keyC, passC, timeout, &err, 1024)
                    }
                }
            }
        }
        guard let raw else {
            throw CoreError.code(SAL_ERR_GENERIC, String(cString: err))
        }
        return wrap(raw)!
    }

    /// Připojení SFTP klíči ze ssh-agenta.
    static func connectSftpAgent(host: String, port: UInt16, user: String, timeout: Double) throws -> Vfs {
        var err = [CChar](repeating: 0, count: 1024)
        let raw = host.withCString { hostC -> UnsafeMutablePointer<SalVfs>? in
            user.withCString { userC in
                sal_connect_sftp_agent(hostC, port, userC, timeout, &err, 1024)
            }
        }
        guard let raw else {
            throw CoreError.code(SAL_ERR_GENERIC, String(cString: err))
        }
        return wrap(raw)!
    }

    /// Druh VFS (pro rozhodování UI – např. zakázání zápisu do archivu).
    var kind: Int32 { sal_vfs_kind(ptr) }

    /// Podporuje zápis (archivy ne).
    var writable: Bool { sal_vfs_writable(ptr) != 0 }

    /// Heslo zadané pro šifrované položky (nil = zatím nezadáno).
    private(set) var password: String?

    /// Obsahuje VFS šifrované položky (zaheslovaný archiv)?
    var hasEncrypted: Bool { sal_vfs_has_encrypted(ptr) != 0 }

    /// Nastaví heslo pro čtení šifrovaných položek (předá ho jádru).
    func setPassword(_ newPassword: String?) {
        password = newPassword
        if let newPassword {
            _ = newPassword.withCString { sal_vfs_set_password(ptr, $0) }
        } else {
            _ = sal_vfs_set_password(ptr, nil)
        }
    }

    /// Reálná cesta na disku pro cestu ve VFS; nil u archivů a vzdálených VFS.
    /// Lokální VFS s omezeným kořenem má kořen v popisku (viz local.rs label()).
    func realPath(_ path: String) -> String? {
        guard kind == SAL_VFS_LOCAL else { return nil }
        if label == "/" || label.isEmpty {
            return path
        }
        return path == "/" ? label : label + path
    }

    /// Výpis adresáře; chybu vrací jako CoreError.
    func list(_ path: String) throws -> [Item] {
        var itemsPtr: UnsafeMutablePointer<SalItem>? = nil
        var count: Int = 0
        var err = [CChar](repeating: 0, count: 1024)
        let code = path.withCString { pathC in
            sal_vfs_list(ptr, pathC, &itemsPtr, &count, &err, 1024)
        }
        guard code == SAL_OK else {
            throw CoreError.code(code, String(cString: err))
        }
        guard let base = itemsPtr else { return [] }
        var items: [Item] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            let raw = base[index]
            items.append(Item(
                name: String(cString: raw.name),
                size: raw.size,
                mtime: raw.mtime,
                flags: raw.flags
            ))
        }
        sal_free_items(base, count)
        return items
    }

    /// Je položka adresářem?
    func isDir(_ path: String) -> Bool {
        var out: Int32 = 0
        var err = [CChar](repeating: 0, count: 1024)
        let code = path.withCString { sal_vfs_is_dir(ptr, $0, &out, &err, 1024) }
        return code == SAL_OK && out != 0
    }

    /// Existuje položka?
    func exists(_ path: String) -> Bool {
        var out: Int32 = 0
        var err = [CChar](repeating: 0, count: 1024)
        let code = path.withCString { sal_vfs_exists(ptr, $0, &out, &err, 1024) }
        return code == SAL_OK && out != 0
    }

    /// Volné místo (nil = nelze zjistit).
    func freeSpace(_ path: String) -> Int64? {
        let value = path.withCString { sal_vfs_free_space(ptr, $0) }
        return value < 0 ? nil : value
    }

    func mkdir(_ path: String) throws {
        var err = [CChar](repeating: 0, count: 1024)
        let code = path.withCString { sal_mkdir(ptr, $0, &err, 1024) }
        guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
    }

    func rename(dir: String, oldName: String, newName: String) throws {
        var err = [CChar](repeating: 0, count: 1024)
        let code = dir.withCString { dirC in
            oldName.withCString { oldC in
                newName.withCString { newC in
                    sal_rename(ptr, dirC, oldC, newC, &err, 1024)
                }
            }
        }
        guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
    }
}

// ---------------------------------------------------------------------------
// Progress + cancel předávané přes C callback
// ---------------------------------------------------------------------------

/// Stav běžící operace: progres a příznak zrušení.
final class ProgressState {
    private let lock = NSLock()
    private var cancelledFlag = false
    private var done: UInt64 = 0
    private var total: UInt64 = 0

    /// Zruší běžící operaci (z UI tlačítka).
    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    /// Byla operace zrušena?
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    /// Aktuální stav progresu pro zobrazení.
    func snapshot() -> (done: UInt64, total: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (done, total)
    }

    /// Aktualizace průběhu z pracovního vlákna (C callback i operace ve Swiftu);
    /// false = požadavek zrušení.
    @discardableResult
    func update(done: UInt64, total: UInt64) -> Bool {
        lock.lock()
        self.done = done
        self.total = total
        let cancel = cancelledFlag
        lock.unlock()
        return !cancel
    }
}

/// Sestaví C strukturu SalProgress napojenou na state.
func makeProgress(_ state: ProgressState) -> SalProgress {
    let user = Unmanaged.passUnretained(state).toOpaque()
    let callback: @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int32 = { user, done, total in
        guard let user else { return 1 }
        let state = Unmanaged<ProgressState>.fromOpaque(user).takeUnretainedValue()
        return state.update(done: done, total: total) ? 1 : 0
    }
    return SalProgress(on_progress: callback, user: user)
}

/// Převod seznamu jmen na C pole ukazatelů platné po dobu body.
func withNameArray<R>(_ names: [String],
                      _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>, Int) -> R) -> R {
    // C řetězce alokované strdup; uvolní se po dokončení volání jádra.
    let buffers: [UnsafeMutablePointer<CChar>] = names.map { strdup($0)! }
    var pointerArray = buffers.map { UnsafePointer<CChar>?($0) }
    defer {
        for ptr in buffers { free(ptr) }
    }
    return pointerArray.withUnsafeMutableBufferPointer { buffer in
        body(buffer.baseAddress!, names.count)
    }
}

// ---------------------------------------------------------------------------
// Operace jádra (copy/move/delete/find/pack) s progresem a zrušením
// ---------------------------------------------------------------------------

/// Režim přepsání (odpovídá SAL_OVERWRITE_*).
enum OverwriteMode {
    case ask
    case overwrite
    case skip

    var raw: Int32 {
        switch self {
        case .ask: return SAL_OVERWRITE_ASK
        case .overwrite: return SAL_OVERWRITE_OVERWRITE
        case .skip: return SAL_OVERWRITE_SKIP
        }
    }
}

/// C signatura přenosu (sal_copy / sal_move mají stejné parametry).
private typealias CoreTransferFunction = (
    UnsafeMutablePointer<SalVfs>?, UnsafePointer<CChar>?, UnsafePointer<UnsafePointer<CChar>?>?, Int,
    UnsafeMutablePointer<SalVfs>?, UnsafePointer<CChar>?, Int32, UnsafePointer<SalProgress>?,
    UnsafeMutablePointer<CChar>?, Int
) -> Int32

/// Společné volání přenosu položek mezi dvěma VFS (kopírování/přesun).
private func coreTransfer(_ function: CoreTransferFunction, src: Vfs, srcDir: String, names: [String],
                          dst: Vfs, dstDir: String, overwrite: OverwriteMode, state: ProgressState) throws {
    var err = [CChar](repeating: 0, count: 1024)
    var progress = makeProgress(state)
    let code = srcDir.withCString { srcDirC in
        dstDir.withCString { dstDirC in
            withNameArray(names) { namesPtr, count in
                withUnsafePointer(to: &progress) { progressPtr in
                    function(src.ptr, srcDirC, namesPtr, count, dst.ptr, dstDirC,
                             overwrite.raw, progressPtr, &err, 1024)
                }
            }
        }
    }
    guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
}

/// Kopírování položek mezi dvěma VFS.
func coreCopy(src: Vfs, srcDir: String, names: [String], dst: Vfs, dstDir: String,
              overwrite: OverwriteMode, state: ProgressState) throws {
    try coreTransfer(sal_copy, src: src, srcDir: srcDir, names: names, dst: dst, dstDir: dstDir,
                     overwrite: overwrite, state: state)
}

/// Přesun položek mezi dvěma VFS.
func coreMove(src: Vfs, srcDir: String, names: [String], dst: Vfs, dstDir: String,
              overwrite: OverwriteMode, state: ProgressState) throws {
    try coreTransfer(sal_move, src: src, srcDir: srcDir, names: names, dst: dst, dstDir: dstDir,
                     overwrite: overwrite, state: state)
}

/// Mazání položek ve VFS.
func coreDelete(vfs: Vfs, dir: String, names: [String], state: ProgressState) throws {
    var err = [CChar](repeating: 0, count: 1024)
    var progress = makeProgress(state)
    let code = dir.withCString { dirC in
        withNameArray(names) { namesPtr, count in
            withUnsafePointer(to: &progress) { progressPtr in
                sal_delete(vfs.ptr, dirC, namesPtr, count, progressPtr, &err, 1024)
            }
        }
    }
    guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
}

/// Šifrování nově vytvářeného ZIP archivu (odpovídá SAL_ZIP_ENC_*).
enum ZipEncryption {
    case none
    /// WinZip AES-256 – doporučeno.
    case aes256(String)
    /// Tradiční ZipCrypto – slabé, jen kvůli kompatibilitě.
    case zipCrypto(String)

    var code: Int32 {
        switch self {
        case .none: return 0
        case .aes256: return 1
        case .zipCrypto: return 2
        }
    }

    var password: String {
        switch self {
        case .none: return ""
        case .aes256(let password), .zipCrypto(let password): return password
        }
    }
}

/// Vytvoření ZIP archivu z položek libovolného VFS (volitelně se šifrováním).
func corePackZip(src: Vfs, srcDir: String, names: [String], dest: String,
                 encryption: ZipEncryption = .none, state: ProgressState) throws {
    var err = [CChar](repeating: 0, count: 1024)
    var progress = makeProgress(state)
    let code = srcDir.withCString { srcDirC in
        dest.withCString { destC in
            withNameArray(names) { namesPtr, count in
                withUnsafePointer(to: &progress) { progressPtr in
                    encryption.password.withCString { passwordC in
                        sal_pack_zip_ex(src.ptr, srcDirC, namesPtr, count, destC,
                                        encryption.code, passwordC, progressPtr, &err, 1024)
                    }
                }
            }
        }
    }
    guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
}

/// Výsledek hledání – jedna položka.
struct FindResult {
    let path: String
    let item: Item
}

/// Sběrač výsledků hledání (thread-safe).
final class FindCollector {
    private let lock = NSLock()
    private var items: [FindResult] = []
    private var dir = ""

    func append(_ result: FindResult) {
        lock.lock()
        items.append(result)
        lock.unlock()
    }

    func snapshot() -> [FindResult] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// Výsledky od indexu `from` (přírůstkové čtení během hledání).
    func items(from index: Int) -> [FindResult] {
        lock.lock()
        defer { lock.unlock() }
        return index < items.count ? Array(items[index...]) : []
    }

    /// Právě prohledávaný adresář (pro stavový řádek dialogu Hledat).
    var currentDir: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return dir
        }
        set {
            lock.lock()
            dir = newValue
            lock.unlock()
        }
    }
}

/// Volby hledání odpovídající dialogu Find Salamandera.
struct FindSpec {
    /// Maska jmen (skupiny `;`, vyloučení `|`; bez * ? . = „obsahuje“).
    var mask: String
    /// Včetně podadresářů.
    var subdirs: Bool
    /// Hledaný obsah (nil = bez hledání v souboru); u HEX režimu už bajty.
    var content: [UInt8]?
    var caseSensitive: Bool
    var wholeWords: Bool
    var regex: Bool
    var hex: Bool
}

/// C callback hledání: každou nalezenou položku přidá do sběrače (`user` = FindCollector).
private let findFoundCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt64, Int64, UInt32) -> Void = { user, path, size, mtime, flags in
    guard let user, let path else { return }
    let collector = Unmanaged<FindCollector>.fromOpaque(user).takeUnretainedValue()
    let pathString = String(cString: path)
    let name = pathString.split(separator: "/").last.map(String.init) ?? pathString
    collector.append(FindResult(path: pathString, item: Item(name: name, size: size, mtime: mtime, flags: flags)))
}

/// Hledání podle masky; výsledky hromadí do předaného sběrače.
func coreFind(vfs: Vfs, root: String, mask: String, includeDirs: Bool,
              state: ProgressState, collector: FindCollector) throws {
    var err = [CChar](repeating: 0, count: 1024)
    var progress = makeProgress(state)

    let user = Unmanaged.passUnretained(collector).toOpaque()

    let code = root.withCString { rootC in
        mask.withCString { maskC in
            withUnsafePointer(to: &progress) { progressPtr in
                sal_find(vfs.ptr, rootC, maskC, includeDirs ? 1 : 0,
                         progressPtr, findFoundCallback, user, &err, 1024)
            }
        }
    }
    guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
}

/// Hledání s volbami dialogu Find v jednom výchozím adresáři.
/// - Parameters:
///   - vfs: prohledávaný souborový systém
///   - root: výchozí adresář (VFS cesta)
///   - spec: maska a volby hledání
///   - state: progress (zrušení hledání)
///   - collector: sběrač výsledků a právě prohledávaného adresáře
/// - Returns: počet přeskočených chyb (nečitelné adresáře/soubory)
@discardableResult
func coreFindEx(vfs: Vfs, root: String, spec: FindSpec, state: ProgressState,
                collector: FindCollector) throws -> UInt64 {
    var err = [CChar](repeating: 0, count: 1024)
    var progress = makeProgress(state)
    var errors: UInt64 = 0

    // Příznaky SAL_FIND_*; adresáře se hlásí vždy (při hledání v obsahu je jádro vynechá).
    var flags = SAL_FIND_INCLUDE_DIRS | SAL_FIND_NAME_CONTAINS
    if spec.subdirs { flags |= SAL_FIND_SUBDIRS }
    let content = spec.content ?? []
    if !content.isEmpty {
        flags |= SAL_FIND_CONTENT
        if spec.caseSensitive { flags |= SAL_FIND_CASE }
        if spec.wholeWords { flags |= SAL_FIND_WHOLE_WORDS }
        if spec.regex { flags |= SAL_FIND_REGEX }
        if spec.hex { flags |= SAL_FIND_HEX }
    }

    // C callback aktuálního adresáře pro stavový řádek (nálezy viz findFoundCallback).
    let user = Unmanaged.passUnretained(collector).toOpaque()
    let dirCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { user, path in
        guard let user, let path else { return }
        Unmanaged<FindCollector>.fromOpaque(user).takeUnretainedValue().currentDir = String(cString: path)
    }

    let code = root.withCString { rootC in
        spec.mask.withCString { maskC in
            content.withUnsafeBufferPointer { contentPtr in
                withUnsafePointer(to: &progress) { progressPtr in
                    sal_find_ex(vfs.ptr, rootC, maskC, flags, contentPtr.baseAddress, content.count,
                                progressPtr, findFoundCallback, dirCallback, user, &errors, &err, 1024)
                }
            }
        }
    }
    guard code == SAL_OK else { throw CoreError.code(code, String(cString: err)) }
    return errors
}

/// Detekce archivu podle obsahu souboru (pro otevírání Enterem).
/// Vrací SAL_VFS_ZIP / SAL_VFS_TAR / 0.
func probeArchive(path: String) -> Int32 {
    path.withCString { sal_probe_archive($0) }
}

/// Formátuje velikost do lidsky čitelné podoby (B/KB/MB/GB…).
func formatSize(_ size: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(size)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    if unit == 0 {
        return "\(size) B"
    }
    return String(format: "%.1f %@", value, units[unit])
}

/// Je soukromý klíč chráněný heslem? nil = soubor nelze přečíst.
func sshKeyEncrypted(path: String) -> Bool? {
    switch path.withCString({ sal_ssh_key_encrypted($0) }) {
    case 1: return true
    case 0: return false
    default: return nil
    }
}
