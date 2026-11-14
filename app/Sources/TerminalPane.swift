// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Vestavěný terminál hlavního okna (na místě dřívější příkazové řádky): login
// shell uživatele v pseudoterminálu, vykreslený emulátorem SwiftTerm.
// Terminál má stále velikost celé plochy okna pod nástrojovou lištou; v režimu
// jednoho řádku je z něj vidět jen řádek s kurzorem (zbytek ořízne pohled
// relace), v režimu celého okna (⌘F12) celý. Shell tak má pořád stejné rozměry
// a výstup příkazů spuštěných z řádku je po přepnutí vidět celý.
//
// Adresář shellu sleduje aktivní panel (do nečinného shellu s prázdným řádkem
// se napíše „cd“) a naopak – po „cd“ v terminálu okno přesune aktivní panel.
//
// Terminálů může být víc v záložkách (⌘T): TerminalSession je jeden shell,
// TerminalPane drží záložky a ukazuje vybranou. Lišta záložek je vidět jen
// při dvou a více záložkách – jediná záložka vypadá jako terminál bez záložek.

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

/// Jedna relace terminálu (záložka): ořezový pohled s terminálem SwiftTerm
/// a shellem uvnitř.
final class TerminalSession: NSView, LocalProcessTerminalViewDelegate {
    /// Terminál se shellem (cíl fokusu klávesnice).
    let terminalView = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))

    /// Uživatel změnil adresář shellu (cd) – okno přesune aktivní panel.
    var onDirectoryChanged: ((String) -> Void)?
    /// Doběhl příkaz spuštěný uživatelem – okno znovu načte panely.
    var onCommandFinished: (() -> Void)?
    /// Shell skončil (exit, ⌃D). Co dál – nový shell (restartShell), nebo
    /// zavření záložky – rozhodne ten, kdo relaci drží.
    var onShellExited: (() -> Void)?
    /// Změnil se název relace (adresář shellu) – lišta záložek se překreslí.
    var onTitleChanged: (() -> Void)?
    /// Adresář pro nově spouštěný shell (adresář aktivního panelu).
    var startDirectory: (() -> String?)?

    /// Výška pohledu v režimu jednoho řádku (= výška řádku terminálu).
    private var lineHeightConstraint: NSLayoutConstraint!
    /// Svislý posun terminálu uvnitř pohledu (řádek s kurzorem nahoru).
    private var topConstraint: NSLayoutConstraint!
    /// Terminál je roztažený na celé okno (⌘F12); jinak je vidět jeden řádek.
    private var isExpanded = false

    /// Adresář shellu při jeho posledním klidu (prázdný = shell se ještě nespustil).
    private var shellDirectory = "" {
        didSet { if shellDirectory != oldValue { onTitleChanged?() } }
    }
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
        // Kurzor trvale svítí (neblikající blok).
        terminalView.getTerminal().setCursorStyle(.steadyBlock)
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
            lineHeightConstraint,
        ])
        applyExpandedAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Sváže výšku terminálu s výškou plochy, kterou zabírá v režimu celého okna
    /// (terminál ji má pořád, i když je z něj vidět jen jeden řádek).
    /// - Parameter expandedHeight: výška plochy roztaženého terminálu
    func bind(expandedHeight: NSLayoutDimension) {
        terminalView.heightAnchor.constraint(equalTo: expandedHeight).isActive = true
    }

    /// Název relace na záložce: jméno adresáře shellu („~“ = domovský adresář).
    var title: String {
        if shellDirectory.isEmpty { return "shell" }
        return shellDirectory == NSHomeDirectory() ? "~" : lastComponent(shellDirectory)
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
        // Roztažená relace vyplní plochu, kterou jí dá nadřazený pohled.
        lineHeightConstraint.isActive = !expanded
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

    /// Spustí nový shell po skončení předchozího (rozhodnutí z onShellExited).
    func restartShell() {
        startShell()
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

    /// Ukončí shell (zavření okna nebo záložky); nový se už nespustí.
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
        // Skrytá záložka se neposouvá – polohu dopočítá rozvržení po jejím výběru.
        if !isHidden {
            updatePosition()
        }
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

    /// Shell skončil: ohlásí se to (nový shell nebo zavření záložky rozhodne
    /// onShellExited); jen shell, který skončil hned po startu, počká na
    /// klávesu (nespouští se dokola).
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
        }
    }
}

/// Tlačítko lišty záložek terminálu: číslo a název relace s křížkem pro
/// zavření, nebo „+“ pro novou záložku. Vzhled má společný s lištou F-kláves.
final class TerminalTabButton: NSView {
    private let isSelected: Bool
    private let closable: Bool
    /// Text záložky (tlačítko se nemění, lišta ho při změně vytvoří znovu).
    private let label: NSAttributedString
    /// Klik na záložku (mimo křížek).
    var onClick: (() -> Void)?
    /// Klik na křížek.
    var onClose: (() -> Void)?

    /// Šířka plochy křížku na pravém okraji záložky.
    private static let closeWidth: CGFloat = 18
    /// Nejvyšší šířka záložky (delší název se zkrátí).
    private static let maximumWidth: CGFloat = 220

    /// - Parameters:
    ///   - number: tučný text před názvem (pořadí záložky, u tlačítka nové záložky „+“)
    ///   - title: název relace
    ///   - isSelected: vybraná záložka
    ///   - closable: kreslit křížek pro zavření
    init(number: String, title: String, isSelected: Bool, closable: Bool) {
        self.isSelected = isSelected
        self.closable = closable
        label = barButtonLabel(prefix: number, title: title, color: isSelected ? .white : .labelColor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    override var intrinsicContentSize: NSSize {
        let width = ceil(label.size().width) + 14 + (closable ? Self.closeWidth : 0)
        return NSSize(width: min(width, Self.maximumWidth), height: NSView.noIntrinsicMetric)
    }

    /// Podklad, text (dlouhý se zkrátí) a křížek.
    override func draw(_ dirtyRect: NSRect) {
        drawBarButtonBackground(in: bounds, highlighted: isSelected)
        let size = label.size()
        let textWidth = bounds.width - 12 - (closable ? Self.closeWidth : 0)
        label.draw(with: NSRect(x: 6, y: (bounds.height - size.height) / 2, width: textWidth, height: size.height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if closable {
            let cross = NSAttributedString(string: "×", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: isSelected ? NSColor.white : NSColor.secondaryLabelColor,
            ])
            let crossSize = cross.size()
            cross.draw(at: NSPoint(x: bounds.maxX - Self.closeWidth + (Self.closeWidth - crossSize.width) / 2 - 2,
                                   y: (bounds.height - crossSize.height) / 2))
        }
    }

    /// Leží bod v ploše křížku?
    private func isOnClose(_ event: NSEvent) -> Bool {
        closable && convert(event.locationInWindow, from: nil).x >= bounds.maxX - Self.closeWidth
    }

    /// Stisk začal na křížku (zavření platí, jen když na něm myš i skončí).
    private var pressedOnClose = false

    override func mouseDown(with event: NSEvent) {
        pressedOnClose = isOnClose(event)
    }

    /// Klik platí, jen když se myš pustí nad tlačítkem (jako u lišty F-kláves):
    /// na křížku zavře záložku, jinde ji vybere.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if pressedOnClose && isOnClose(event) {
            onClose?()
        } else if !pressedOnClose {
            onClick?()
        }
    }
}

/// Lišta záložek terminálu (vidět jen při dvou a více záložkách).
final class TerminalTabBar: NSView {
    /// Výška lišty.
    static let height: CGFloat = 20

    /// Výběr záložky (index), zavření záložky (index) a nová záložka.
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Přestaví lištu: záložky s pořadím a názvem a na konci tlačítko „+“.
    /// - Parameters:
    ///   - titles: názvy relací v pořadí záložek
    ///   - selected: index vybrané záložky
    func setTabs(_ titles: [String], selected: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, title) in titles.enumerated() {
            let button = TerminalTabButton(number: "\(index + 1)", title: title, isSelected: index == selected, closable: true)
            button.toolTip = "Terminál \(index + 1): \(title)"
            button.onClick = { [weak self] in self?.onSelect?(index) }
            button.onClose = { [weak self] in self?.onClose?(index) }
            stack.addArrangedSubview(button)
        }
        let add = TerminalTabButton(number: "+", title: "", isSelected: false, closable: false)
        add.toolTip = "Nová záložka terminálu"
        add.onClick = { [weak self] in self?.onAdd?() }
        stack.addArrangedSubview(add)
    }
}

/// Vestavěný terminál hlavního okna: jedna nebo více relací (záložek), z nichž
/// je vidět vybraná. Oknu nabízí rozhraní jednoho terminálu – volání předává
/// vybrané relaci.
final class TerminalPane: NSView {
    /// Uživatel změnil adresář shellu ve vybrané záložce (cd) – okno přesune aktivní panel.
    var onDirectoryChanged: ((String) -> Void)?
    /// Doběhl příkaz spuštěný uživatelem (v kterékoli záložce) – okno znovu načte panely.
    var onCommandFinished: (() -> Void)?
    /// Skončil shell jediné záložky a spouští se nový – okno opustí režim celého okna.
    var onShellExited: (() -> Void)?
    /// Adresář pro nově spouštěný shell (adresář aktivního panelu).
    var startDirectory: (() -> String?)?

    /// Terminál je roztažený na celé okno (⌘F12); jinak je vidět jeden řádek.
    private(set) var isExpanded = false

    /// Relace v pořadí záložek (vždy aspoň jedna) a index vybrané.
    private var sessions: [TerminalSession] = []
    private var selectedIndex = 0
    private let tabBar = TerminalTabBar()
    /// Výška lišty záložek (0 = lišta skrytá, záložka je jen jedna).
    private var tabBarHeight: NSLayoutConstraint!
    /// Plocha, kterou má relace při terminálu roztaženém na celé okno: plocha
    /// okna pro terminál bez lišty záložek. Tuto výšku mají terminály všech relací.
    private let sessionArea = NSLayoutGuide()
    /// Výška sessionArea = plocha okna pro terminál − výška lišty záložek.
    private var sessionAreaHeight: NSLayoutConstraint?
    /// Adresář aktivního panelu, o který okno požádalo naposledy – dostane ho
    /// i záložka vybraná později.
    private var panelDirectory: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addLayoutGuide(sessionArea)
        tabBar.isHidden = true
        tabBar.onSelect = { [weak self] index in self?.selectTab(index, focus: true) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onAdd = { [weak self] in self?.addTab() }
        addSubview(tabBar)
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBarHeight,
        ])
        sessions = [makeSession()]
    }

    required init?(coder: NSCoder) {
        fatalError("Není podporováno")
    }

    /// Vybraná relace.
    private var current: TerminalSession { sessions[selectedIndex] }

    /// Počet záložek.
    var tabCount: Int { sessions.count }

    // MARK: - Záložky

    /// Vytvoří relaci, napojí ji na okno a vloží pod lištu záložek.
    private func makeSession() -> TerminalSession {
        let session = TerminalSession()
        session.startDirectory = { [weak self] in self?.startDirectory?() }
        // Panel vede jen vybraná záložka; „cd“ v záložce na pozadí ho nepřesouvá.
        session.onDirectoryChanged = { [weak self, weak session] directory in
            guard let self, let session, session === self.current else { return }
            self.onDirectoryChanged?(directory)
        }
        session.onCommandFinished = { [weak self] in self?.onCommandFinished?() }
        session.onTitleChanged = { [weak self] in self?.updateTabBar() }
        session.onShellExited = { [weak self, weak session] in
            guard let self, let session else { return }
            self.shellExited(in: session)
        }
        addSubview(session)
        NSLayoutConstraint.activate([
            session.leadingAnchor.constraint(equalTo: leadingAnchor),
            session.trailingAnchor.constraint(equalTo: trailingAnchor),
            session.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            session.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        session.bind(expandedHeight: sessionArea.heightAnchor)
        session.setExpanded(isExpanded)
        session.applyColors()
        return session
    }

    /// ⌘T – nová záložka s vlastním shellem v adresáři aktivního panelu;
    /// dostane fokus.
    func addTab() {
        sessions.append(makeSession())
        selectTab(sessions.count - 1, focus: true)
    }

    /// Zavře vybranou záložku (jediná záložka zavřít nejde).
    func closeCurrentTab() {
        closeTab(at: selectedIndex)
    }

    /// Vybere sousední záložku (dokola).
    /// - Parameter offset: +1 další, −1 předchozí
    func selectAdjacentTab(offset: Int) {
        guard sessions.count > 1 else { return }
        selectTab(DriveChooser.wrappedIndex(selectedIndex, delta: offset, count: sessions.count), focus: hasFocus)
    }

    /// Ukáže záložku s daným indexem; ostatní relace běží dál na pozadí.
    /// - Parameters:
    ///   - index: index záložky
    ///   - focus: předat vybrané relaci fokus klávesnice
    private func selectTab(_ index: Int, focus: Bool) {
        guard sessions.indices.contains(index) else { return }
        selectedIndex = index
        for (sessionIndex, session) in sessions.enumerated() {
            session.isHidden = sessionIndex != index
        }
        // Záložka na pozadí se neposouvala na řádek s kurzorem – dopočítá to rozvržení.
        current.needsLayout = true
        updateTabBar()
        // Vybraný shell jde za adresářem aktivního panelu jako jediný terminál.
        if let panelDirectory {
            current.requestDirectory(panelDirectory)
        }
        if focus {
            current.focus()
        }
    }

    /// Zavře záložku: ukončí její shell a vybere sousední. Poslední záložka zůstává.
    private func closeTab(at index: Int) {
        guard sessions.count > 1, sessions.indices.contains(index) else { return }
        let session = sessions[index]
        // Fokus zůstane v terminálu, pokud v něm byl (v roztaženém terminálu vždy).
        let keepFocus = hasFocus || isExpanded
        session.shutdown()
        session.removeFromSuperview()
        sessions.remove(at: index)
        let selected = index < selectedIndex ? selectedIndex - 1 : min(selectedIndex, sessions.count - 1)
        selectTab(selected, focus: keepFocus)
    }

    /// Shell relace skončil (exit, ⌃D): záložka, která není jediná, se zavře;
    /// jediná dostane nový shell a okno se o tom dozví.
    private func shellExited(in session: TerminalSession) {
        if sessions.count > 1 {
            // Zavření až po doběhnutí oznámení o konci procesu, ze kterého se volá.
            DispatchQueue.main.async { [weak self] in
                guard let self, let index = self.sessions.firstIndex(where: { $0 === session }) else { return }
                self.closeTab(at: index)
            }
        } else {
            onShellExited?()
            session.restartShell()
        }
    }

    /// Lišta záložek podle počtu relací: s jedinou záložkou není vidět a nezabírá
    /// místo, jinak ukáže pořadí a názvy relací.
    private func updateTabBar() {
        let visible = sessions.count > 1
        let height = visible ? TerminalTabBar.height : 0
        if tabBarHeight.constant != height {
            tabBarHeight.constant = height
            tabBar.isHidden = !visible
            sessionAreaHeight?.constant = -height
        }
        if visible {
            tabBar.setTabs(sessions.map(\.title), selected: selectedIndex)
        }
    }

    // MARK: - Rozhraní pro okno

    /// Sváže výšku terminálů s výškou plochy, kterou zabírají v režimu celého okna.
    /// - Parameter expandedHeight: výška plochy okna pro roztažený terminál
    func bind(expandedHeight: NSLayoutDimension) {
        let constraint = sessionArea.heightAnchor.constraint(equalTo: expandedHeight, constant: -tabBarHeight.constant)
        constraint.isActive = true
        sessionAreaHeight = constraint
    }

    /// Přepne mezi jedním řádkem a celým oknem (rozložení okna mění kontroler).
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        sessions.forEach { $0.setExpanded(expanded) }
    }

    /// Barvy terminálů podle barevného schématu panelů.
    func applyColors() {
        sessions.forEach { $0.applyColors() }
    }

    /// Ukončí shelly všech záložek (zavření okna).
    func shutdown() {
        sessions.forEach { $0.shutdown() }
    }

    /// Požádá vybraný terminál o přechod do adresáře aktivního panelu.
    func requestDirectory(_ directory: String) {
        panelDirectory = directory
        current.requestDirectory(directory)
    }

    /// Má vybraný terminál fokus klávesnice?
    var hasFocus: Bool { current.hasFocus }
    /// Je na řádku vybraného shellu rozepsaný text?
    var hasPendingInput: Bool { current.hasPendingInput }
    /// Je vybraný shell nečinný (čeká na příkaz)?
    var isShellIdle: Bool { current.isShellIdle }
    /// Text obrazovky vybraného terminálu (pro kontrolu v testech).
    var screenText: String { current.screenText }

    /// Předá vybranému terminálu fokus klávesnice.
    func focus() { current.focus() }
    /// Zaznamená klávesu předávanou vybranému terminálu.
    func noteKey(_ event: NSEvent) { current.noteKey(event) }
    /// Vloží text na řádek vybraného shellu.
    func insert(_ text: String) { current.insert(text) }
    /// Smaže rozepsaný řádek vybraného shellu.
    func clearInput() { current.clearInput() }
    /// Je vybraný shell v daném adresáři?
    func isShellDirectory(_ directory: String) -> Bool { current.isShellDirectory(directory) }

    /// Spustí příkaz ve vybraném shellu v daném adresáři.
    /// - Returns: false, když v terminálu běží jiný program nebo je na řádku rozepsaný text
    func run(_ command: String, in directory: String) -> Bool { current.run(command, in: directory) }
}
