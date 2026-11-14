// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vestavěný terminál hlavního okna (na místě dřívější příkazové řádky): login
// shell uživatele v pseudoterminálu, vykreslený emulátorem SwiftTerm.
// Terminál má stále velikost celé plochy okna pod nástrojovou lištou; v režimu
// jednoho řádku je z něj vidět jen řádek s kurzorem (zbytek ořízne tento
// pohled), v režimu celého okna (⌘F12) celý. Shell tak má pořád stejné rozměry
// a výstup příkazů spuštěných z řádku je po přepnutí vidět celý.
//
// Adresář shellu sleduje aktivní panel (do nečinného shellu s prázdným řádkem
// se napíše „cd“) a naopak – po „cd“ v terminálu okno přesune aktivní panel.

import AppKit
import Darwin
import SwiftTerm

/// Terminálový pohled se shellem; navíc hlásí zpracovaný výstup shellu
/// a vložení textu ze schránky.
final class ShellTerminalView: LocalProcessTerminalView {
    /// Po zpracování dávky výstupu (kurzor se mohl posunout, příkaz mohl doběhnout).
    var onOutput: (() -> Void)?
    /// Před vložením textu ze schránky (⌘V); parametrem je vkládaný text.
    var onPaste: ((String) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func paste(_ sender: Any) {
        onPaste?(NSPasteboard.general.string(forType: .string) ?? "")
        super.paste(sender)
    }
}

/// Integrace zsh ve vestavěném terminálu: soubor `.zshenv` v adresáři, na který
/// aplikace nastaví ZDOTDIR. Jiné shelly fungují bez integrace (adresář shellu
/// se pak čte jen z procesu a příkazy vložené aplikací řeší HISTCONTROL).
private enum ZshIntegration {
    /// Obsah `.zshenv`: vrátí původní ZDOTDIR, načte uživatelův `.zshenv`
    /// a přidá háček před promptem (historie bez vložených příkazů, OSC 7).
    private static let script = #"""
    # MicroCommander – integrace zsh ve vestavěném terminálu.
    # Soubor se generuje při spuštění terminálu, ruční úpravy se přepíšou.
    #
    # Zsh ho načte jako první díky ZDOTDIR nastavenému aplikací. Vrátí původní
    # ZDOTDIR (další soubory zsh se pak čtou z obvyklého místa), načte
    # uživatelův .zshenv a přidá háček volaný před každým promptem.
    if [[ -n "${MICROCOMMANDER_ZDOTDIR+x}" ]]; then
        export ZDOTDIR="$MICROCOMMANDER_ZDOTDIR"
        unset MICROCOMMANDER_ZDOTDIR
    else
        unset ZDOTDIR
    fi
    if [[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
        source "${ZDOTDIR:-$HOME}/.zshenv"
    fi
    if [[ -o interactive ]]; then
        _microcommander_precmd() {
            # Příkazy vložené aplikací (cd při změně adresáře panelu) začínají
            # mezerou a do historie nepatří.
            setopt HIST_IGNORE_SPACE
            # Aktuální adresář pro aplikaci (OSC 7): cesta se kóduje po bajtech
            # jako URL, stejně jako to dělá Terminal.app.
            local i ch hexch url_path='' LC_CTYPE=C LC_COLLATE=C LC_ALL= LANG=
            for ((i = 1; i <= ${#PWD}; ++i)); do
                ch="$PWD[i]"
                if [[ "$ch" == [/._~A-Za-z0-9-] ]]; then
                    url_path+="$ch"
                else
                    printf -v hexch '%02X' "'$ch"
                    url_path+="%$hexch"
                fi
            done
            printf '\e]7;file://%s%s\a' "$HOST" "$url_path"
        }
        typeset -ga precmd_functions
        precmd_functions+=(_microcommander_precmd)
    fi

    """#

    /// Adresář s integračním `.zshenv` (vytvoří ho a soubor zapíše, jen když
    /// se obsah liší); nil = soubor nejde zapsat, shell poběží bez integrace.
    static func directory() -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = support.appendingPathComponent("MicroCommander/zsh", isDirectory: true)
        let file = directory.appendingPathComponent(".zshenv")
        if (try? String(contentsOf: file, encoding: .utf8)) == script {
            return directory.path
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
            return directory.path
        } catch {
            return nil
        }
    }
}

/// Vestavěný terminál: ořezový pohled s terminálem SwiftTerm uvnitř.
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    /// Terminál se shellem (cíl fokusu klávesnice).
    let terminalView = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

    /// Uživatel změnil adresář shellu (cd) – okno přesune aktivní panel.
    var onDirectoryChanged: ((String) -> Void)?
    /// Doběhl příkaz spuštěný uživatelem – okno znovu načte panely.
    var onCommandFinished: (() -> Void)?
    /// Shell skončil (exit, ⌃D) a spouští se nový – okno opustí režim celého okna.
    var onShellExited: (() -> Void)?
    /// Adresář pro nově spouštěný shell (adresář aktivního panelu).
    var startDirectory: (() -> String?)?

    /// Výška pohledu v režimu jednoho řádku (= výška řádku terminálu).
    private(set) var lineHeightConstraint: NSLayoutConstraint!
    /// Svislý posun terminálu uvnitř pohledu (řádek s kurzorem nahoru).
    private var topConstraint: NSLayoutConstraint!
    /// Terminál je roztažený na celé okno (⌘F12); jinak je vidět jeden řádek.
    private(set) var isExpanded = false

    /// Adresář shellu při jeho posledním klidu (prázdný = shell se ještě nespustil).
    private var shellDirectory = ""
    /// Adresář, o který okno požádalo naposledy, nebo do kterého shell přešel
    /// sám – opakovaná žádost o tentýž adresář se ignoruje (neúspěšné „cd“ se
    /// tak nezkouší znovu při každém překreslení okna).
    private var requestedDirectory: String?
    /// Adresář panelu, do kterého se má shell přepnout, až to půjde.
    private var wantedDirectory: String?
    /// Adresář, který shell sám ohlásil (OSC 7) – logická cesta bez rozvinutí odkazů.
    private var reportedDirectory: String?
    /// Na řádku shellu je rozepsaný text (nelze do něj psát vlastní příkaz).
    private(set) var hasPendingInput = false
    /// Uživatel odeslal řádek Enterem a čeká se na návrat promptu.
    private var userCommandPending = false
    /// Aplikace napsala do shellu vlastní „cd“ a čeká se na návrat promptu.
    private var injectedCommandPending = false
    /// Během čekání na prompt běžel v popředí jiný proces než shell.
    private var sawForegroundProcess = false
    /// Čas posledního výstupu terminálu (čas od startu systému).
    private var lastOutput: TimeInterval = 0
    /// Je naplánovaná kontrola klidu shellu? (Vždy nejvýš jedna.)
    private var idleCheckScheduled = false
    /// Odložené přepnutí adresáře shellu (rychlá navigace v panelu pošle jen poslední).
    private var directorySync: DispatchWorkItem?
    /// Čas spuštění shellu (shell, který skončí hned, se nespouští dokola).
    private var startedAt = Date.distantPast
    /// Shell skončil hned po startu – nový spustí až další klávesa.
    private var waitsForRestart = false
    /// Okno se zavírá – skončený shell se už nenahrazuje novým.
    private var isShutDown = false

    /// Prodleva kontroly klidu po posledním výstupu terminálu.
    private static let idleCheckDelay: TimeInterval = 0.12
    /// Prodleva přepnutí adresáře shellu po změně adresáře panelu.
    private static let directorySyncDelay: TimeInterval = 0.3
    /// Shell, který doběhl dřív, se považuje za nespustitelný (chybný rc soubor…).
    private static let minimumShellLifetime: TimeInterval = 3
    /// Vodorovný okraj terminálu.
    private static let horizontalInset: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // Ořez: v režimu jednoho řádku terminál pohled přesahuje nahoru i dolů.
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true

        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        // ⌥ na české klávesnici píše znaky (@, #, [, ], {, }, |…), ne Meta.
        terminalView.optionAsMetaKey = false
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] in self?.outputArrived() }
        terminalView.onPaste = { [weak self] text in self?.notePaste(text) }
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)

        lineHeightConstraint = heightAnchor.constraint(equalToConstant: rowHeight)
        topConstraint = terminalView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            topConstraint,
        ])
        applyExpandedAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Sváže výšku terminálu s výškou plochy, kterou zabírá v režimu celého okna
    /// (terminál ji má pořád, i když je z něj vidět jen jeden řádek).
    /// - Parameter expandedHeight: výška plochy okna pro roztažený terminál
    func bind(expandedHeight: NSLayoutDimension) {
        terminalView.heightAnchor.constraint(equalTo: expandedHeight).isActive = true
    }

    // MARK: - Rozvržení a vzhled

    /// Výška jednoho řádku terminálu.
    private var rowHeight: CGFloat {
        let rows = max(terminalView.getTerminal().rows, 1)
        return terminalView.getOptimalFrameSize().height / CGFloat(rows)
    }

    override func layout() {
        super.layout()
        updatePosition()
        // Shell se spouští až s rozměry okna (jinak by dostal výchozích 80×25).
        if terminalView.frame.width > 0, terminalView.frame.height > 0 {
            startShellIfNeeded()
        }
    }

    /// Posune terminál tak, aby byl v režimu jednoho řádku vidět řádek s kurzorem;
    /// řádky se počítají shora (zbytek výšky nechává SwiftTerm dole).
    private func updatePosition() {
        let height = rowHeight
        if lineHeightConstraint.constant != height {
            lineHeightConstraint.constant = height
        }
        let terminal = terminalView.getTerminal()
        let cursorRow = max(0, min(terminal.buffer.y, terminal.rows - 1))
        let offset = isExpanded ? 0 : -CGFloat(cursorRow) * height
        if topConstraint.constant != offset {
            topConstraint.constant = offset
        }
    }

    /// Přepne mezi jedním řádkem a celým oknem (rozložení okna mění kontroler).
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        applyExpandedAppearance()
        // V jednom řádku je vidět konec výstupu, ne místo, kam se listovalo.
        if !expanded {
            terminalView.scroll(toPosition: 1)
        }
        updatePosition()
    }

    /// Posuvník terminálu je vidět jen v režimu celého okna. Jen se zprůhlední –
    /// skrytý by změnil šířku terminálu a počet sloupců při každém přepnutí.
    private func applyExpandedAppearance() {
        for case let scroller as NSScroller in terminalView.subviews {
            scroller.alphaValue = isExpanded ? 1 : 0
        }
    }

    /// Barvy terminálu podle barevného schématu panelů (pozadí a text položek).
    func applyColors() {
        // Dynamické systémové barvy se převádějí na pevné podle vzhledu okna.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let colors = PanelColors.current
            let background = colors.itemBackground.usingColorSpace(.sRGB) ?? .black
            let foreground = colors.itemText.usingColorSpace(.sRGB) ?? .white
            terminalView.nativeBackgroundColor = background
            terminalView.nativeForegroundColor = foreground
            layer?.backgroundColor = background.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: - Fokus a vstup

    /// Má terminál fokus klávesnice?
    var hasFocus: Bool {
        window?.firstResponder === terminalView
    }

    /// Předá terminálu fokus klávesnice.
    func focus() {
        if !hasFocus {
            window?.makeFirstResponder(terminalView)
        }
    }

    /// Zaznamená klávesu, kterou okno předává terminálu: podle ní se odhaduje,
    /// zda je na řádku shellu rozepsaný text a kdy uživatel odeslal příkaz.
    func noteKey(_ event: NSEvent) {
        // Shell, který skončil hned po startu, spustí znovu až další klávesa.
        if waitsForRestart {
            startShell()
            return
        }
        let modifiers = Shortcut.relevantModifiers(event.modifierFlags)
        // Zkratky s ⌘ (kopírování, menu) se shellu neposílají; vložení ze
        // schránky hlásí notePaste.
        if modifiers.contains(.command) { return }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.enter {
            noteLineSubmitted()
        } else if modifiers == .control, ["c", "d", "u"].contains(chars) {
            // ⌃C a ⌃U řádek zahodí, ⌃D na prázdném řádku ukončí shell.
            hasPendingInput = false
        } else {
            hasPendingInput = true
        }
    }

    /// Text ze schránky: víceřádkový se rovnou spustí, jinak zůstane rozepsaný.
    private func notePaste(_ text: String) {
        if text.contains("\n") || text.contains("\r") {
            noteLineSubmitted()
        } else if !text.isEmpty {
            hasPendingInput = true
        }
    }

    /// Uživatel odeslal řádek – po návratu promptu se znovu načtou panely.
    private func noteLineSubmitted() {
        hasPendingInput = false
        userCommandPending = true
    }

    /// Vloží text (jméno položky, cestu) na řádek shellu.
    func insert(_ text: String) {
        guard isRunning else { return }
        terminalView.send(txt: text)
        hasPendingInput = true
    }

    /// Smaže rozepsaný řádek shellu (Escape v panelu). Jen v nečinném shellu –
    /// běžícímu programu se řídicí znaky neposílají.
    func clearInput() {
        guard isShellIdle, hasPendingInput else { return }
        // ⌃E + ⌃U: konec řádku a smazání před kurzorem (zsh i bash smažou vše).
        terminalView.send([0x05, 0x15])
        hasPendingInput = false
        applyWantedDirectory()
    }

    /// Spustí příkaz v shellu v daném adresáři (Enter na skriptu v panelu).
    /// - Parameters:
    ///   - command: text příkazu
    ///   - directory: pracovní adresář (lokální cesta)
    /// - Returns: false, když v terminálu běží jiný program nebo je na řádku
    ///   rozepsaný text – příkaz se pak nespustí
    func run(_ command: String, in directory: String) -> Bool {
        guard isShellIdle, !hasPendingInput else { return false }
        let line = isSamePath(directory, shellDirectory) ? command : "cd \(shellQuote(directory)) && \(command)"
        // Shell přejde do adresáře panelu sám – odložené přepnutí už není potřeba.
        wantedDirectory = nil
        requestedDirectory = directory
        terminalView.send(txt: line + "\r")
        noteLineSubmitted()
        return true
    }

    // MARK: - Shell

    /// Běží shell?
    private var isRunning: Bool {
        terminalView.process?.running ?? false
    }

    /// Je shell nečinný (čeká na příkaz)? Pozná se podle toho, že skupinou
    /// procesů v popředí terminálu je shell sám – běžící příkaz má vlastní.
    var isShellIdle: Bool {
        guard let process = terminalView.process, process.running, process.childfd >= 0 else { return false }
        return tcgetpgrp(process.childfd) == process.shellPid
    }

    /// Login shell uživatele (proměnná SHELL, jinak záznam uživatele, jinak zsh).
    private static var userShell: String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    /// Locale pro shell, když ho prostředí aplikace nemá (spuštění z Finderu):
    /// jazyk a region systému, pokud takové locale v systému existuje, jinak
    /// en_US – vždy v UTF-8 (jinak se rozbije čeština ve jménech souborů).
    private static var defaultLocale: String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/" + candidate) {
                return candidate
            }
        }
        return "en_US.UTF-8"
    }

    /// Prostředí shellu: prostředí aplikace doplněné o typ terminálu, locale
    /// a integraci shellu.
    /// - Parameter shell: cesta spouštěného shellu
    private static func environment(for shell: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "MicroCommander"
        if environment["LANG"] == nil, environment["LC_ALL"] == nil {
            environment["LANG"] = defaultLocale
        }
        // bash: příkazy začínající mezerou (cd vložené aplikací) nejdou do historie.
        if environment["HISTCONTROL"] == nil {
            environment["HISTCONTROL"] = "ignoreboth"
        }
        // zsh: integrační .zshenv přes ZDOTDIR; původní hodnotu si skript vrátí.
        if lastComponent(shell) == "zsh", let directory = ZshIntegration.directory() {
            if let original = environment["ZDOTDIR"] {
                environment["MICROCOMMANDER_ZDOTDIR"] = original
            }
            environment["ZDOTDIR"] = directory
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    /// Spustí shell při prvním rozvržení okna (další spuštění řeší konec shellu).
    private func startShellIfNeeded() {
        if shellDirectory.isEmpty {
            startShell()
        }
    }

    /// Spustí login shell uživatele v adresáři aktivního panelu.
    private func startShell() {
        guard !isShutDown else { return }
        let shell = Self.userShell
        let directory = startDirectory?() ?? NSHomeDirectory()
        resetShellState()
        shellDirectory = directory
        requestedDirectory = directory
        startedAt = Date()
        // Login shell se pozná podle pomlčky na začátku argv[0] (jako v Terminal.app).
        terminalView.startProcess(executable: shell, args: [], environment: Self.environment(for: shell),
                                  execName: "-" + lastComponent(shell), currentDirectory: directory)
    }

    /// Stav sledování shellu do výchozí podoby (nový shell).
    private func resetShellState() {
        directorySync?.cancel()
        wantedDirectory = nil
        reportedDirectory = nil
        hasPendingInput = false
        userCommandPending = false
        injectedCommandPending = false
        sawForegroundProcess = false
        waitsForRestart = false
    }

    /// Ukončí shell (zavření okna); nový se už nespustí.
    func shutdown() {
        isShutDown = true
        resetShellState()
        let pid = isRunning ? terminalView.process.shellPid : 0
        terminalView.terminate()
        // terminate() zavře pseudoterminál a přestane sledovat konec procesu –
        // shell se proto sklidí tady, jinak by po něm do ukončení aplikace zůstal
        // zombie proces. Interaktivní shell končí na SIGHUP (SIGTERM ignoruje).
        if pid > 0 {
            kill(pid, SIGHUP)
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
            }
        }
    }

    // MARK: - Sledování shellu

    /// Výstup terminálu: posun na řádek s kurzorem a odložená kontrola klidu.
    private func outputArrived() {
        updatePosition()
        lastOutput = ProcessInfo.processInfo.systemUptime
        scheduleIdleCheck(after: Self.idleCheckDelay)
    }

    /// Naplánuje kontrolu klidu shellu. Naplánovaná je vždy nejvýš jedna: další
    /// výstup jen posune čas posledního výstupu a kontrola se po vypršení
    /// odloží o zbytek (při záplavě výstupu tak nevzniká časovač na každou dávku).
    /// - Parameter delay: za jak dlouho kontrolu provést
    private func scheduleIdleCheck(after delay: TimeInterval) {
        guard !idleCheckScheduled else { return }
        idleCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.idleCheckScheduled = false
            let quiet = ProcessInfo.processInfo.systemUptime - self.lastOutput
            if quiet < Self.idleCheckDelay {
                self.scheduleIdleCheck(after: Self.idleCheckDelay - quiet)
            } else {
                self.checkIdle()
            }
        }
    }

    /// Po utichnutí výstupu: je-li shell zpět u promptu, zjistí jeho adresář,
    /// ohlásí doběhnutí příkazu a provede odložené přepnutí adresáře.
    private func checkIdle() {
        guard isRunning else { return }
        guard isShellIdle else {
            sawForegroundProcess = true
            return
        }
        // Příkaz uživatele: odeslaný řádek nebo proces v popředí (i z vloženého textu).
        let userCommand = userCommandPending || sawForegroundProcess
        let injected = injectedCommandPending
        userCommandPending = false
        injectedCommandPending = false
        sawForegroundProcess = false
        if userCommand || injected {
            hasPendingInput = false
        }
        if let current = currentShellDirectory(), !isSamePath(current, shellDirectory) {
            shellDirectory = current
            // Změnu vlastním „cd“ panel nepotřebuje znát (sám ji vyvolal a mezitím
            // mohl jít jinam); po příkazu uživatele jde panel za shellem.
            if userCommand || !injected {
                wantedDirectory = nil
                requestedDirectory = current
                onDirectoryChanged?(current)
            }
        }
        if userCommand {
            onCommandFinished?()
        }
        applyWantedDirectory()
    }

    /// Aktuální adresář shellu: skutečný podle procesu; ohlásil-li shell stejné
    /// místo logickou cestou (OSC 7, např. přes symbolický odkaz), vrátí tu.
    private func currentShellDirectory() -> String? {
        guard let process = terminalView.process, let physical = Self.workingDirectory(of: process.shellPid) else {
            return nil
        }
        if let reported = reportedDirectory, isSamePath(reported, physical) {
            return reported
        }
        return physical
    }

    /// Pracovní adresář procesu (rozvinutá cesta z jádra systému).
    /// - Parameter pid: číslo procesu
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        // vip_path je pole znaků pevné délky ukončené nulou.
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Ukazují obě cesty na stejný adresář (po rozvinutí symbolických odkazů)?
    private func isSamePath(_ first: String, _ second: String) -> Bool {
        first == second || Self.canonicalPath(first) == Self.canonicalPath(second)
    }

    /// Cesta s rozvinutými symbolickými odkazy (neexistující cesta beze změny).
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Text obrazovky terminálu včetně historie výstupu (pro kontrolu v testech).
    var screenText: String {
        String(decoding: terminalView.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    // MARK: - Adresář panelu → shell

    /// Adresář shellu, jak ho aplikace zná (pro rozhodnutí, zda vkládat jména
    /// položek relativně, nebo celou cestou).
    func isShellDirectory(_ directory: String) -> Bool {
        isSamePath(directory, shellDirectory)
    }

    /// Požádá o přepnutí shellu do adresáře aktivního panelu. Provede se
    /// s krátkou prodlevou (při rychlé navigaci jen poslední adresář) a jen
    /// v nečinném shellu s prázdným řádkem; jinak počká na další klid.
    func requestDirectory(_ directory: String) {
        guard directory != requestedDirectory else { return }
        requestedDirectory = directory
        wantedDirectory = directory
        directorySync?.cancel()
        let sync = DispatchWorkItem { [weak self] in self?.applyWantedDirectory() }
        directorySync = sync
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.directorySyncDelay, execute: sync)
    }

    /// Přepne shell do požadovaného adresáře, pokud to právě jde.
    private func applyWantedDirectory() {
        guard let wanted = wantedDirectory, isRunning else { return }
        if isSamePath(wanted, shellDirectory) {
            wantedDirectory = nil
            return
        }
        // Do rozepsaného řádku ani běžícímu programu se nepíše; příkaz čekající
        // na prompt se nechá doběhnout (další pokus přijde s jeho výstupem).
        guard isShellIdle, !hasPendingInput, !userCommandPending, !injectedCommandPending,
              !sawForegroundProcess else { return }
        wantedDirectory = nil
        injectedCommandPending = true
        terminalView.send(txt: changeDirectoryLine(wanted))
    }

    /// Řádek, kterým aplikace přepne adresář shellu. Začíná mezerou (nejde do
    /// historie) a po úspěšném „cd“ po sobě smaže vlastní řádek, takže ve
    /// výstupu terminálu zůstane jen nový prompt.
    /// - Parameter directory: cílový adresář
    private func changeDirectoryLine(_ directory: String) -> String {
        let command = " cd " + shellQuote(directory)
        // Kurzor o řádek výš a smazání řádku – jen když se celý příkaz vejde na
        // jeden řádek terminálu (u zalomeného by smazání nesedělo); šířku jde
        // spolehlivě spočítat jen pro ASCII.
        let erase = " && printf '\\033[A\\033[K'"
        let terminal = terminalView.getTerminal()
        let fits = terminal.buffer.x + command.count + erase.count < terminal.cols
        let isASCII = command.unicodeScalars.allSatisfy(\.isASCII)
        return command + (fits && isASCII ? erase : "") + "\r"
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        updatePosition()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    /// OSC 7: shell ohlásil aktuální adresář jako URL `file://počítač/cesta`.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL, !url.path.isEmpty else { return }
        reportedDirectory = url.path
    }

    /// Shell skončil: spustí se nový; jen shell, který skončil hned po startu,
    /// počká na klávesu (nespouští se dokola).
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !isShutDown else { return }
        let lifetime = Date().timeIntervalSince(startedAt)
        resetShellState()
        if lifetime < Self.minimumShellLifetime {
            waitsForRestart = true
            terminalView.feed(text: "\r\n[Shell skončil hned po spuštění – další klávesa ho spustí znovu.]\r\n")
            updatePosition()
        } else {
            onShellExited?()
            startShell()
        }
    }
}
