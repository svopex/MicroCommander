// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// End-to-end smoke test FFI vrstvy: projde open_local → list → copy
// (local→local) → move → mkdir → rename → delete → find → pack ZIP a ověří výsledky.
// Spustí se přes `make smoke`; nevyžaduje GUI, ověřuje vazbu Swift↔Rust jádro.

import Foundation
import microcommander

func expect(_ condition: Bool, _ message: String) {
    if condition {
        print("OK   \(message)")
    } else {
        print("FAIL \(message)")
        exit(1)
    }
}

func run() throws {
    // Dočasné adresáře pro test.
    let base = NSTemporaryDirectory() + "sal-ffi-smoke-\(getpid())"
    let srcDir = base + "/src"
    let dstDir = base + "/dst"
    try FileManager.default.createDirectory(atPath: srcDir + "/pod", withIntermediateDirectories: true)
    try "obsah a".write(toFile: srcDir + "/a.txt", atomically: true, encoding: .utf8)
    try "obsah b".write(toFile: srcDir + "/pod/b.txt", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: dstDir, withIntermediateDirectories: true)

    // Otevření dvou lokálních VFS.
    guard let src = Vfs.openLocal(root: srcDir), let dst = Vfs.openLocal(root: dstDir) else {
        print("FAIL otevření lokálních VFS")
        exit(1)
    }
    expect(src.kind == SAL_VFS_LOCAL, "src.kind == SAL_VFS_LOCAL")
    expect(src.writable, "src.writable")

    // Výpis zdrojového adresáře.
    let items = try src.list("/")
    expect(items.contains { $0.name == "a.txt" && $0.isDir == false }, "list obsahuje a.txt")
    expect(items.contains { $0.name == "pod" && $0.isDir }, "list obsahuje pod")

    // Kopírování a.txt i podadresáře (rekurzivně) přes FFI.
    let state = ProgressState()
    try coreCopy(src: src, srcDir: "/", names: ["a.txt", "pod"], dst: dst, dstDir: "/",
                 overwrite: .ask, state: state)
    expect(dst.exists("/a.txt"), "kopie a.txt existuje v cíli")
    expect(dst.exists("/pod/b.txt"), "kopie pod/b.txt existuje v cíli")

    // Obsah zkopírovaného souboru odpovídá.
    let copied = try String(contentsOfFile: dstDir + "/pod/b.txt", encoding: .utf8)
    expect(copied == "obsah b", "obsah kopie odpovídá")

    // Přesun v rámci jednoho VFS celého disku – tak ho volá aplikace (oba panely
    // sdílejí lokální VFS s kořenem „/“): soubor i adresář musí změnit místo.
    let disk = Vfs.openLocal(root: nil)!
    let moveDir = base + "/presun"
    try FileManager.default.createDirectory(atPath: moveDir, withIntermediateDirectories: true)
    try coreMove(src: disk, srcDir: dstDir, names: ["a.txt", "pod"], dst: disk, dstDir: moveDir,
                 overwrite: .ask, state: state)
    expect(!dst.exists("/a.txt") && !dst.exists("/pod"), "přesun odebral položky ze zdroje")
    expect(FileManager.default.fileExists(atPath: moveDir + "/pod/b.txt"), "přesun položky doručil do cíle")
    // Přesun do téhož adresáře jádro odmítne (dřív „Přepsat“ soubor smazalo).
    do {
        try coreMove(src: disk, srcDir: moveDir, names: ["a.txt"], dst: disk, dstDir: moveDir,
                     overwrite: .overwrite, state: state)
        expect(false, "přesun do téhož adresáře musí selhat")
    } catch {
        expect(FileManager.default.fileExists(atPath: moveDir + "/a.txt"), "přesun do téhož adresáře nic nesmazal")
    }
    // Zpět do cíle – další kroky testu počítají s kopií v dst.
    try coreMove(src: disk, srcDir: moveDir, names: ["a.txt", "pod"], dst: disk, dstDir: dstDir,
                 overwrite: .ask, state: state)
    expect(dst.exists("/a.txt") && dst.exists("/pod/b.txt"), "přesun zpět proběhl")

    // Mkdir přes FFI.
    try dst.mkdir("/novy")
    expect(dst.isDir("/novy"), "mkdir vytvořil adresář")

    // Rename přes FFI.
    try dst.rename(dir: "/", oldName: "novy", newName: "prejmenovany")
    expect(dst.exists("/prejmenovany"), "rename přejmenoval adresář")
    // Přejmenování na jméno existující položky ji nesmí nahradit.
    do {
        try dst.rename(dir: "/", oldName: "prejmenovany", newName: "a.txt")
        expect(false, "rename na existující jméno musí selhat")
    } catch {
        expect((error as? CoreError)?.isExistsConflict == true && dst.isDir("/prejmenovany"),
               "rename existující položku nenahradil")
    }

    // Mazání přes FFI (rekurzivně).
    try coreDelete(vfs: dst, dir: "/", names: ["prejmenovany", "pod", "a.txt"], state: state)
    let afterDelete = try dst.list("/")
    expect(afterDelete.isEmpty, "po smazání je cíl prázdný")

    // Hledání podle masky přes FFI.
    let collector = FindCollector()
    let findState = ProgressState()
    try coreFind(vfs: src, root: "/", mask: "*.txt", includeDirs: false,
                 state: findState, collector: collector)
    let found = collector.snapshot()
    expect(found.count == 2, "hledání *.txt našlo 2 soubory, našlo \(found.count)")

    // Balení do ZIP přes FFI a otevření archivu jako VFS.
    let zipPath = base + "/archiv.zip"
    try corePackZip(src: src, srcDir: "/", names: ["a.txt", "pod"], dest: zipPath, state: state)
    expect(FileManager.default.fileExists(atPath: zipPath), "ZIP archiv vytvořen")
    expect(probeArchive(path: zipPath) == SAL_VFS_ZIP, "probe rozpoznal ZIP")
    guard let zipVfs = Vfs.openZip(path: zipPath) else {
        print("FAIL otevření ZIP archivu")
        exit(1)
    }
    let zipItems = try zipVfs.list("/")
    expect(zipItems.contains { $0.name == "a.txt" }, "ZIP výpis obsahuje a.txt")
    expect(zipItems.contains { $0.name == "pod" && $0.isDir }, "adresář v ZIP je ve výpisu adresářem")

    // Zaheslovaný ZIP (AES-256) přes FFI: bez hesla / chybné heslo / správné heslo.
    let aesPath = base + "/tajne.zip"
    try corePackZip(src: src, srcDir: "/", names: ["a.txt", "pod"], dest: aesPath,
                    encryption: .aes256("Tajne-heslo"), state: state)
    guard let aesVfs = Vfs.openZip(path: aesPath) else {
        print("FAIL otevření AES ZIP archivu")
        exit(1)
    }
    expect(aesVfs.hasEncrypted, "AES ZIP hlásí šifrované položky")
    let aesItems = try aesVfs.list("/pod")
    expect(aesItems.first?.isEncrypted == true, "položka pod/b.txt má příznak šifrování")
    let aesOut = base + "/aes-out"
    try FileManager.default.createDirectory(atPath: aesOut, withIntermediateDirectories: true)
    // Cíl přes VFS celého disku (aesOut je absolutní cesta).
    // Kopie ze šifrovaného archivu: postupně bez hesla, se špatným a se správným.
    func copyFromAes() -> CoreError? {
        do {
            try coreCopy(src: aesVfs, srcDir: "/pod", names: ["b.txt"], dst: disk, dstDir: aesOut,
                         overwrite: .overwrite, state: ProgressState())
            return nil
        } catch {
            return error as? CoreError
        }
    }
    expect(copyFromAes()?.isPasswordRequired == true, "kopie bez hesla → SAL_ERR_PASSWORD_REQUIRED")
    aesVfs.setPassword("spatne")
    expect(copyFromAes()?.isBadPassword == true, "chybné heslo → SAL_ERR_BAD_PASSWORD")
    aesVfs.setPassword("Tajne-heslo")
    let finalError = copyFromAes()
    expect(finalError == nil, "správné heslo → kopie proběhla \(finalError?.localizedDescription ?? "")")
    let decrypted = try? String(contentsOfFile: aesOut + "/b.txt", encoding: .utf8)
    expect(decrypted == "obsah b", "dešifrovaný obsah odpovídá")

    // Kompatibilita: archiv musí rozbalit i libarchive (bsdtar) – nezávislá implementace AES.
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/bsdtar") {
        let external = base + "/bsdtar-out"
        try FileManager.default.createDirectory(atPath: external, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-xf", aesPath, "--passphrase", "Tajne-heslo", "-C", external]
        try process.run()
        process.waitUntilExit()
        let content = try? String(contentsOfFile: external + "/pod/b.txt", encoding: .utf8)
        expect(process.terminationStatus == 0 && content == "obsah b", "bsdtar (libarchive) rozbalil AES-256 archiv")

        // Opačný směr: archiv zašifrovaný libarchive (AES-256 i ZipCrypto) čte naše jádro.
        for (method, label) in [("aes256", "AES-256"), ("traditional", "ZipCrypto")] {
            let foreign = base + "/foreign-\(method).zip"
            let create = Process()
            create.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            create.arguments = ["--format", "zip", "--options", "zip:encryption=\(method)",
                                "--passphrase", "Cizi-heslo", "-cf", foreign, "-C", srcDir, "a.txt"]
            try create.run()
            create.waitUntilExit()
            guard create.terminationStatus == 0, let foreignVfs = Vfs.openZip(path: foreign) else {
                expect(false, "bsdtar vytvořil \(label) archiv")
                continue
            }
            foreignVfs.setPassword("Cizi-heslo")
            let out = base + "/foreign-out-\(method)"
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try coreCopy(src: foreignVfs, srcDir: "/", names: ["a.txt"], dst: disk, dstDir: out,
                         overwrite: .overwrite, state: ProgressState())
            let text = try? String(contentsOfFile: out + "/a.txt", encoding: .utf8)
            expect(foreignVfs.hasEncrypted && text == "obsah a", "jádro přečetlo \(label) archiv z bsdtar")
        }
    }

    // SFTP přes FFI proti dočasnému sshd (jen když ho spustil tests/sftp_test.sh).
    let environment = ProcessInfo.processInfo.environment
    if let portText = environment["SAL_TEST_SSH_PORT"], let port = UInt16(portText),
       let keys = environment["SAL_TEST_SSH_KEYDIR"] {
        let user = NSUserName()
        expect(sshKeyEncrypted(path: keys + "/id_pass") == true, "FFI: klíč s heslem rozpoznán jako šifrovaný")
        expect(sshKeyEncrypted(path: keys + "/id_plain") == false, "FFI: klíč bez hesla není šifrovaný")
        expect(sshKeyEncrypted(path: keys + "/neexistuje") == nil, "FFI: neexistující klíč = nil")
        do {
            let sftp = try Vfs.connectSftpKey(host: "127.0.0.1", port: port, user: user, keyPath: keys + "/id_pass",
                                              passphrase: "tajne-heslo", timeout: 10)
            expect(sftp.kind == SAL_VFS_SFTP, "FFI: SFTP klíčem s heslem připojeno")
            expect((try? sftp.list("/"))?.isEmpty == false, "FFI: výpis domovského adresáře přes SFTP")
        } catch {
            expect(false, "FFI: SFTP klíčem selhalo: \(error.localizedDescription)")
        }
        do {
            _ = try Vfs.connectSftpKey(host: "127.0.0.1", port: port, user: user, keyPath: keys + "/id_other",
                                       passphrase: "", timeout: 10)
            expect(false, "FFI: neautorizovaný klíč se nesmí přihlásit")
        } catch {
            expect(error.localizedDescription.contains("odmítl"), "FFI: neautorizovaný klíč → „server klíč odmítl“")
        }
        if environment["SAL_TEST_SSH_AGENT_SOCK"] != nil {
            setenv("SSH_AUTH_SOCK", environment["SAL_TEST_SSH_AGENT_SOCK"]!, 1)
            let agent = try? Vfs.connectSftpAgent(host: "127.0.0.1", port: port, user: user, timeout: 10)
            expect(agent != nil, "FFI: SFTP přes ssh-agent připojeno")
        }
    }

    // Uklid.
    try? FileManager.default.removeItem(atPath: base)
    print("SMOKE TEST OK")
}

do {
    try run()
} catch {
    print("FAIL výjimka: \(error)")
    exit(1)
}
