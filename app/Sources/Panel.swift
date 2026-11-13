// SPDX-FileCopyrightText: 2026 Open Samandarin Authors
// SPDX-License-Identifier: GPL-2.0-or-later

// Model jednoho panelu souborového manažeru ve stylu Salamandera:
// lokace (VFS + cesta), výpis s řádkem „..“, kurzor oddělený od označení,
// řazení podle sloupců, rychlé hledání a historie (zpět/vpřed, zanoření do archivu).

import AppKit

/// Lokace panelu: otevřený VFS + aktuální cesta v něm.
struct Location {
    let vfs: Vfs
    var path: String
}

/// Identifikátory sloupců tabulky (pořadí jako v Salamanderu).
enum ColumnID {
    static let name = "name"
    static let ext = "ext"
    static let type = "type"
    static let size = "size"
    static let date = "date"
    static let time = "time"
    static let attr = "attr"
}

/// Klíč řazení panelu (Ctrl+F3..F6 v Salamanderu).
enum SortKey {
    case name, ext, size, time
}

/// Jeden řádek panelu: položka výpisu nebo řádek „..“ (nadřazený adresář).
struct Row {
    let item: Item
    let isParent: Bool

    /// Jméno bez přípony (u adresářů celé jméno).
    var baseName: String {
        if isParent || item.isDir { return item.name }
        let parts = splitExtension(item.name)
        return parts.base
    }

    /// Přípona bez tečky (u adresářů prázdná).
    var ext: String {
        if isParent || item.isDir { return "" }
        return splitExtension(item.name).ext
    }
}

/// Rozdělí jméno souboru na základ a příponu (".bashrc" nemá příponu).
func splitExtension(_ name: String) -> (base: String, ext: String) {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
        return (name, "")
    }
    let base = String(name[..<dot])
    let ext = String(name[name.index(after: dot)...])
    return (base, ext)
}

/// Rozhraní panelu → hlavní okno (překreslení stavových prvků, chyby).
protocol PanelDelegate: AnyObject {
    func panelDidReload(_ panel: PanelController)
    func panelStateChanged(_ panel: PanelController)
    func panelWantsActivation(_ panel: PanelController)
    func panel(_ panel: PanelController, failedWithPath path: String, error: Error)
}

/// Kontroler jednoho panelu (levý/pravý).
final class PanelController: NSObject {
    /// Aktuální lokace (VFS + cesta).
    private(set) var location: Location
    /// Lokace „pod“ archivem/FTP – návrat přes „..“ na kořeni.
    private(set) var parentLocations: [(location: Location, focus: String)] = []
    /// Historie pro Alt+←/Alt+→.
    private var backStack: [Location] = []
    private var forwardStack: [Location] = []

    /// Výpis aktuálního adresáře (bez „..“).
    private(set) var items: [Item] = []
    /// Zobrazené řádky (setříděné, případně s „..“ na začátku).
    private(set) var rows: [Row] = []
    /// Počítadlo změn seznamu řádků (mřížka podle něj pozná, kdy znovu měřit jména).
    private(set) var rowsGeneration = 0
    /// Index řádku s kurzorem.
    private(set) var cursor: Int = 0
    /// Jména označených položek.
    private(set) var marked: Set<String> = []
    /// Řazení.
    private(set) var sortKey: SortKey = .name
    private(set) var sortAscending = true
    /// Zobrazovat skryté soubory.
    var showHidden = true {
        didSet { rebuildRows(keepFocus: true) }
    }
    /// Text rychlého hledání (nil = neaktivní).
    private(set) var quickSearch: String?
    /// Probíhá načítání výpisu.
    private(set) var isLoading = false

    /// Lokace, jejíž výpis je právě zobrazen (rozlišení obnovení vs. změny adresáře).
    private weak var loadedVfs: Vfs?
    private var loadedPath = ""

    /// Jméno, na které se má po načtení postavit kurzor (návrat z podadresáře).
    private var pendingFocus: String?
    /// Je panel aktivní (zdrojový)?
    var isActive = false

    weak var delegate: PanelDelegate?
    /// Pohled, který panel zobrazuje (tabulka) – nastavuje PanelView.
    weak var view: PanelView?

    init(location: Location) {
        self.location = location
        super.init()
    }

    // MARK: - Navigace

    /// Přejde na novou lokaci. Nový VFS (archiv, FTP) se zanoří:
    /// původní lokace se uloží a „..“ na kořeni se do ní vrátí.
    func navigate(_ newLocation: Location, nested: Bool = false, focus: String? = nil) {
        backStack.append(location)
        forwardStack.removeAll()
        if nested {
            parentLocations.append((location, focus ?? ""))
        } else if newLocation.vfs !== location.vfs {
            // Skok na jiný disk ruší zanoření (archivy/FTP se zavřou).
            parentLocations.removeAll()
        }
        location = newLocation
        pendingFocus = nil
        marked.removeAll()
        reload()
    }

    /// Jde do cesty ve stejném VFS.
    func changePath(_ path: String, focus: String? = nil) {
        backStack.append(location)
        forwardStack.removeAll()
        location.path = path
        pendingFocus = focus
        marked.removeAll()
        reload()
    }

    /// Nadřazený adresář; na kořeni archivu/FTP se vrátí do původní lokace.
    func goUp() {
        if location.path != "/" {
            let focus = lastComponent(location.path)
            changePath(parentPath(location.path), focus: focus)
        } else if let previous = parentLocations.popLast() {
            backStack.append(location)
            location = previous.location
            pendingFocus = previous.focus
            marked.removeAll()
            reload()
        }
    }

    /// Zavře všechna zanořená VFS (archivy, FTP) a vrátí se na disk (F12).
    func closeNested() {
        guard let base = parentLocations.first else { return }
        parentLocations.removeAll()
        backStack.append(location)
        location = base.location
        pendingFocus = base.focus
        marked.removeAll()
        reload()
    }

    /// Převezme lokaci jiného panelu včetně zanoření (archiv, FTP/SFTP): oba
    /// panely pak sdílejí stejný VFS a „..“ na kořeni vede ven stejně jako v druhém
    /// panelu. Kurzor se postaví na položku, na které stojí druhý panel.
    func adoptLocation(of other: PanelController) {
        guard other !== self else { return }
        backStack.append(location)
        forwardStack.removeAll()
        location = other.location
        parentLocations = other.parentLocations
        pendingFocus = other.currentItem?.name
        marked.removeAll()
        reload()
    }

    /// Kořen aktuálního VFS (Ctrl+\).
    func goRoot() {
        guard location.path != "/" else { return }
        changePath("/")
    }

    /// Lze jít nahoru (zobrazuje se „..“)?
    var canGoUp: Bool {
        location.path != "/" || !parentLocations.isEmpty
    }

    /// Zpět v historii (Alt+←).
    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        switchTo(previous)
    }

    /// Vpřed v historii (Alt+→).
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        switchTo(next)
    }

    /// Přepnutí lokace z historie (bez úpravy zásobníků historie).
    private func switchTo(_ target: Location) {
        // Pokud se historie vrací mimo zanořené VFS, zanoření zahodíme.
        if target.vfs !== location.vfs, !parentLocations.contains(where: { $0.location.vfs === target.vfs }) {
            if target.vfs.kind == SAL_VFS_LOCAL { parentLocations.removeAll() }
        }
        location = target
        marked.removeAll()
        reload()
    }

    /// Přejde na cestu zadanou uživatelem (v aktuálním VFS; "~" = domov na lokálním disku).
    func goToTypedPath(_ typed: String) {
        var path = typed.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        // Na lokálním disku rozbalíme "~" a relativní cesty vůči aktuální.
        if location.vfs.kind == SAL_VFS_LOCAL, path.hasPrefix("~") {
            path = (path as NSString).expandingTildeInPath
        }
        if !path.hasPrefix("/") {
            path = joinPath(location.path, path)
        }
        changePath(normalizePath(path))
    }

    /// Obnoví výpis na pozadí; kurzor a označení zůstanou na stejných jménech.
    func reload() {
        let vfs = location.vfs
        let path = location.path
        // Kurzor se drží na stejném jménu jen při obnovení téhož adresáře;
        // v jiném adresáři začíná na začátku (nebo na požadovaném jménu).
        let sameLocation = loadedVfs === vfs && loadedPath == path
        let focusName = pendingFocus ?? (sameLocation ? currentRow?.item.name : nil)
        isLoading = true
        delegate?.panelStateChanged(self)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try vfs.list(path) }
            DispatchQueue.main.async {
                guard let self, self.location.vfs === vfs, self.location.path == path else { return }
                self.isLoading = false
                switch result {
                case .success(let listed):
                    self.items = listed
                    // Označení necháme jen u jmen, která stále existují.
                    let names = Set(listed.map(\.name))
                    self.marked = self.marked.intersection(names)
                    self.pendingFocus = focusName
                    if !sameLocation {
                        self.cursor = 0
                        self.view?.directoryChanged()
                    }
                    self.loadedVfs = vfs
                    self.loadedPath = path
                    self.rebuildRows(keepFocus: true)
                    self.delegate?.panelDidReload(self)
                case .failure(let error):
                    self.items = []
                    self.loadedVfs = nil
                    self.rebuildRows(keepFocus: false)
                    self.delegate?.panelDidReload(self)
                    self.delegate?.panel(self, failedWithPath: path, error: error)
                }
            }
        }
    }

    // MARK: - Řádky a řazení

    /// Sestaví řádky z výpisu (filtr skrytých, řazení, „..“) a obnoví tabulku.
    private func rebuildRows(keepFocus: Bool) {
        let focusName = keepFocus ? (pendingFocus ?? currentRow?.item.name) : nil
        pendingFocus = nil

        let visible = showHidden ? items : items.filter { !$0.isHidden }
        let sorted = visible.sorted(by: compareItems)
        var newRows: [Row] = []
        if canGoUp {
            newRows.append(Row(item: Item(name: "..", size: 0, mtime: 0, flags: SAL_FLAG_DIR), isParent: true))
        }
        newRows += sorted.map { Row(item: $0, isParent: false) }
        rows = newRows
        rowsGeneration += 1

        // Kurzor na zapamatované jméno, jinak na začátek.
        if let focusName, let index = rows.firstIndex(where: { !$0.isParent && $0.item.name == focusName }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
            if !keepFocus { cursor = 0 }
        }
        view?.reloadTable()
        view?.scrollCursorVisible()
        delegate?.panelStateChanged(self)
    }

    /// Porovnání dvou položek podle aktuálního řazení (adresáře vždy první, podle jména).
    private func compareItems(_ lhs: Item, _ rhs: Item) -> Bool {
        if lhs.isDir != rhs.isDir {
            return lhs.isDir
        }
        let byName = lhs.name.localizedStandardCompare(rhs.name)
        // Adresáře řadíme vždy podle jména (jako Salamander), soubory podle klíče.
        if lhs.isDir {
            return sortAscending ? byName == .orderedAscending : byName == .orderedDescending
        }
        var result: ComparisonResult
        switch sortKey {
        case .name:
            result = byName
        case .ext:
            result = splitExtension(lhs.name).ext.localizedStandardCompare(splitExtension(rhs.name).ext)
            if result == .orderedSame { result = byName }
        case .size:
            result = lhs.size == rhs.size ? byName : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .time:
            result = lhs.mtime == rhs.mtime ? byName : (lhs.mtime < rhs.mtime ? .orderedAscending : .orderedDescending)
        }
        return sortAscending ? result == .orderedAscending : result == .orderedDescending
    }

    /// Nastaví řazení; opakovaná volba stejného klíče obrací pořadí.
    func setSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        rebuildRows(keepFocus: true)
        view?.updateSortIndicator()
    }

    // MARK: - Kurzor a označení

    /// Řádek pod kurzorem.
    var currentRow: Row? {
        cursor >= 0 && cursor < rows.count ? rows[cursor] : nil
    }

    /// Položka pod kurzorem (bez „..“).
    var currentItem: Item? {
        guard let row = currentRow, !row.isParent else { return nil }
        return row.item
    }

    /// Položky pro operaci: označené, jinak položka pod kurzorem (jako Salamander).
    var operationItems: [Item] {
        marked.isEmpty ? (currentItem.map { [$0] } ?? []) : markedItems
    }

    /// Označené položky (v pořadí řádků).
    var markedItems: [Item] {
        // Bez označení žádný průchod řádky (volá se při každém pohybu kurzoru).
        guard !marked.isEmpty else { return [] }
        return rows.filter { !$0.isParent && marked.contains($0.item.name) }.map(\.item)
    }

    /// Přesune kurzor (s omezením na rozsah) a překreslí dotčené řádky.
    func setCursor(_ index: Int) {
        guard !rows.isEmpty else { return }
        let clamped = max(0, min(index, rows.count - 1))
        let old = cursor
        cursor = clamped
        view?.refreshRows([old, clamped])
        view?.scrollCursorVisible()
        delegate?.panelStateChanged(self)
    }

    /// Je řádek označen?
    func isMarked(row: Int) -> Bool {
        guard row >= 0, row < rows.count, !rows[row].isParent else { return false }
        return marked.contains(rows[row].item.name)
    }

    /// Nastaví označení řádku („..“ označit nelze).
    func setMark(row: Int, _ on: Bool) {
        guard row >= 0, row < rows.count, !rows[row].isParent else { return }
        let name = rows[row].item.name
        if on { marked.insert(name) } else { marked.remove(name) }
        view?.refreshRows([row])
        delegate?.panelStateChanged(self)
    }

    /// Přepne označení řádku.
    func toggleMark(row: Int) {
        setMark(row: row, !isMarked(row: row))
    }

    /// Označí/odznačí rozsah řádků (Shift+klik).
    func setMarkRange(from: Int, to: Int, _ on: Bool) {
        let range = min(from, to)...max(from, to)
        for row in range where row >= 0 && row < rows.count && !rows[row].isParent {
            if on { marked.insert(rows[row].item.name) } else { marked.remove(rows[row].item.name) }
        }
        view?.reloadTable()
        delegate?.panelStateChanged(self)
    }

    /// Označí/odznačí položky odpovídající masce (Num +/-); dirs = i adresáře.
    func markByMask(_ mask: String, select: Bool, includeDirs: Bool) {
        for row in rows where !row.isParent {
            if row.item.isDir && !includeDirs { continue }
            if maskMatches(mask, name: row.item.name) {
                if select { marked.insert(row.item.name) } else { marked.remove(row.item.name) }
            }
        }
        view?.reloadTable()
        delegate?.panelStateChanged(self)
    }

    /// Označí všechny položky / zruší všechna označení.
    func markAll(_ on: Bool) {
        if on {
            marked = Set(rows.filter { !$0.isParent }.map(\.item.name))
        } else {
            marked.removeAll()
        }
        view?.reloadTable()
        delegate?.panelStateChanged(self)
    }

    /// Invertuje označení souborů (Num *); adresáře jen s includeDirs.
    func invertMarks(includeDirs: Bool) {
        for row in rows where !row.isParent {
            if row.item.isDir && !includeDirs { continue }
            if marked.contains(row.item.name) { marked.remove(row.item.name) } else { marked.insert(row.item.name) }
        }
        view?.reloadTable()
        delegate?.panelStateChanged(self)
    }

    /// Nastaví označení přesně na zadaná jména (porovnání adresářů).
    func setMarked(_ names: Set<String>) {
        marked = names
        view?.reloadTable()
        delegate?.panelStateChanged(self)
    }

    /// Postaví kurzor na položku daného jména (pokud existuje).
    func focus(name: String) {
        if let index = rows.firstIndex(where: { !$0.isParent && $0.item.name == name }) {
            setCursor(index)
        } else {
            pendingFocus = name
        }
    }

    // MARK: - Rychlé hledání

    /// Přidá znak do rychlého hledání a skočí na první položku s prefixem.
    func quickSearchType(_ text: String) {
        let candidate = (quickSearch ?? "") + text
        if let index = findPrefix(candidate) {
            quickSearch = candidate
            setCursor(index)
        } else if quickSearch == nil {
            // Nic nenalezeno ani pro první znak – rychlé hledání nezačne.
            NSSound.beep()
        } else {
            NSSound.beep()
        }
        delegate?.panelStateChanged(self)
    }

    /// Smaže poslední znak rychlého hledání.
    func quickSearchBackspace() {
        guard var text = quickSearch else { return }
        text.removeLast()
        quickSearch = text.isEmpty ? nil : text
        if let quickSearch, let index = findPrefix(quickSearch) {
            setCursor(index)
        }
        delegate?.panelStateChanged(self)
    }

    /// Ukončí rychlé hledání.
    func endQuickSearch() {
        guard quickSearch != nil else { return }
        quickSearch = nil
        delegate?.panelStateChanged(self)
    }

    /// Skok na další položku s prefixem rychlého hledání (šipka dolů během hledání).
    func quickSearchNext(forward: Bool) {
        guard let quickSearch, !rows.isEmpty else { return }
        let count = rows.count
        for offset in 1..<count {
            let index = (cursor + (forward ? offset : count - offset)) % count
            if rows[index].item.name.lowercased().hasPrefix(quickSearch.lowercased()) {
                setCursor(index)
                return
            }
        }
    }

    /// Index první položky (od kurzoru) se jménem začínajícím prefixem.
    private func findPrefix(_ prefix: String) -> Int? {
        let lower = prefix.lowercased()
        guard !rows.isEmpty else { return nil }
        // Nejprve od aktuálního řádku dál, pak od začátku (jako Salamander).
        let order = Array(cursor..<rows.count) + Array(0..<cursor)
        return order.first { !rows[$0].isParent && rows[$0].item.name.lowercased().hasPrefix(lower) }
    }

    // MARK: - Pomocné

    /// Reálná cesta na lokálním disku pro položku (nil u archivů a FTP).
    func localPath(of name: String) -> String? {
        location.vfs.realPath(joinPath(location.path, name))
    }

    /// Text řádku adresáře (VFS + cesta).
    var displayPath: String {
        let vfs = location.vfs
        if vfs.kind == SAL_VFS_LOCAL {
            return vfs.realPath(location.path) ?? location.path
        }
        // Archiv / FTP: „popisek:cesta“, zanořený archiv s cestou nadřazené lokace.
        if let parent = parentLocations.last, parent.location.vfs.kind == SAL_VFS_LOCAL,
           vfs.kind == SAL_VFS_ZIP || vfs.kind == SAL_VFS_TAR {
            let archive = joinPath(parent.location.vfs.realPath(parent.location.path) ?? parent.location.path,
                                   parent.focus)
            return archive + (location.path == "/" ? "" : location.path)
        }
        return vfs.label + "  " + location.path
    }
}

/// Spojí adresář a jméno ve stylu VFS (kořen bez dvojitého lomítka).
func joinPath(_ dir: String, _ name: String) -> String {
    if dir == "/" || dir.isEmpty {
        return "/" + name
    }
    return dir.hasSuffix("/") ? dir + name : dir + "/" + name
}

/// Nadřazený adresář cesty (kořen zůstává "/").
func parentPath(_ path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    return parent.isEmpty ? "/" : parent
}

/// Poslední složka cesty.
func lastComponent(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

/// Normalizuje cestu (odstraní ".", "..", zdvojená lomítka).
func normalizePath(_ path: String) -> String {
    var parts: [Substring] = []
    for component in path.split(separator: "/") {
        if component == "." || component.isEmpty { continue }
        if component == ".." {
            if !parts.isEmpty { parts.removeLast() }
            continue
        }
        parts.append(component)
    }
    return "/" + parts.joined(separator: "/")
}

/// Jednoduchá maska ve stylu Salamandera pro označování (*, ?, skupiny oddělené ";").
/// Plnohodnotné masky (# a vyloučení „|“) má jádro – zde stačí pro výběr v panelu.
func maskMatches(_ mask: String, name: String) -> Bool {
    let groups = mask.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    return groups.contains { group in
        if group == "*" || group == "*.*" { return true }
        return wildcardMatch(Array(group.lowercased()), Array(name.lowercased()))
    }
}

/// Porovnání se zástupnými znaky * a ? (iterativní s návratem k poslední hvězdičce).
private func wildcardMatch(_ pattern: [Character], _ text: [Character]) -> Bool {
    var p = 0, t = 0
    var star = -1, mark = 0
    while t < text.count {
        if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
            p += 1; t += 1
        } else if p < pattern.count, pattern[p] == "*" {
            star = p; mark = t; p += 1
        } else if star >= 0 {
            p = star + 1; mark += 1; t = mark
        } else {
            return false
        }
    }
    while p < pattern.count, pattern[p] == "*" { p += 1 }
    return p == pattern.count
}

/// Naformátuje unixový čas na datum „d.M.yyyy“.
func formatDay(_ unixSeconds: Int64) -> String {
    guard unixSeconds > 0 else { return "" }
    return dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
}

/// Naformátuje unixový čas na čas „H:mm:ss“.
func formatTime(_ unixSeconds: Int64) -> String {
    guard unixSeconds > 0 else { return "" }
    return timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)))
}

// Formátovače sdílené (vytváření DateFormatteru je drahé).
private let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "d.M.yyyy"
    return formatter
}()

private let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "H:mm:ss"
    return formatter
}()

/// Velikost s mezerami po tisících (jako Salamander: „7 962“).
func formatExactSize(_ size: UInt64) -> String {
    groupedFormatter.string(from: NSNumber(value: size)) ?? "\(size)"
}

private let groupedFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = " "
    formatter.usesGroupingSeparator = true
    return formatter
}()
