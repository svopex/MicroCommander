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

    /// Záznam historie: lokace i se zanořením, ve kterém ležela (návrat do
    /// archivu či na server obnoví i cestu ven přes „..“).
    private struct HistoryEntry {
        let location: Location
        let parents: [(location: Location, focus: String)]
    }

    /// Historie pro Alt+←/Alt+→ (nejvýš `historyLimit` kroků zpět).
    private var backStack: [HistoryEntry] = []
    private var forwardStack: [HistoryEntry] = []
    private static let historyLimit = 100

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

    /// Aktuální lokace jako záznam historie.
    private var currentEntry: HistoryEntry {
        HistoryEntry(location: location, parents: parentLocations)
    }

    /// Zapíše aktuální lokaci do historie před přechodem jinam (nový krok
    /// ruší historii vpřed; nejstarší kroky nad limit se zahazují).
    private func pushHistory() {
        backStack.append(currentEntry)
        if backStack.count > PanelController.historyLimit {
            backStack.removeFirst(backStack.count - PanelController.historyLimit)
        }
        forwardStack.removeAll()
    }

    /// Po zavření archivu nebo odpojení serveru vyřadí z historie kroky, které
    /// do zavřeného VFS vedou. Historie drží VFS naživu – bez toho by spojení
    /// se serverem zůstalo otevřené i po odpojení (F12).
    private func dropClosedFromHistory() {
        forwardStack.removeAll()
        let open = [location.vfs] + parentLocations.map(\.location.vfs)
        backStack.removeAll { entry in
            let used = [entry.location.vfs] + entry.parents.map(\.location.vfs)
            return !used.allSatisfy { vfs in open.contains { $0 === vfs } }
        }
    }

    /// Přejde na novou lokaci. Nový VFS (archiv, FTP) se zanoří:
    /// původní lokace se uloží a „..“ na kořeni se do ní vrátí.
    func navigate(_ newLocation: Location, nested: Bool = false, focus: String? = nil) {
        pushHistory()
        // Skok do jiného VFS bez zanoření ruší zanoření (archivy/FTP se zavřou).
        let leavesNested = !nested && newLocation.vfs !== location.vfs
        if nested {
            parentLocations.append((location, focus ?? ""))
        } else if leavesNested {
            parentLocations.removeAll()
        }
        location = newLocation
        if leavesNested {
            dropClosedFromHistory()
        }
        pendingFocus = nil
        marked.removeAll()
        reload()
    }

    /// Jde do cesty ve stejném VFS.
    func changePath(_ path: String, focus: String? = nil) {
        pushHistory()
        location.path = path
        pendingFocus = focus
        marked.removeAll()
        reload()
    }

    /// Nadřazený adresář; na kořeni archivu/FTP se vrátí do původní lokace
    /// (archiv se tím zavře, server odpojí).
    func goUp() {
        if location.path != "/" {
            let focus = lastComponent(location.path)
            changePath(parentPath(location.path), focus: focus)
        } else if let previous = parentLocations.popLast() {
            leaveNested(to: previous)
        }
    }

    /// Zavře všechna zanořená VFS (archivy, FTP) a vrátí se na disk (F12).
    func closeNested() {
        guard let base = parentLocations.first else { return }
        parentLocations.removeAll()
        leaveNested(to: base)
    }

    /// Návrat ze zavíraného VFS do lokace, ze které se do něj vešlo
    /// (`parentLocations` už zavírané úrovně neobsahují).
    private func leaveNested(to parent: (location: Location, focus: String)) {
        location = parent.location
        pendingFocus = parent.focus
        marked.removeAll()
        dropClosedFromHistory()
        reload()
    }

    /// Převezme lokaci jiného panelu včetně zanoření (archiv, FTP/SFTP): oba
    /// panely pak sdílejí stejný VFS a „..“ na kořeni vede ven stejně jako v druhém
    /// panelu. Kurzor se postaví na položku, na které stojí druhý panel.
    func adoptLocation(of other: PanelController) {
        guard other !== self else { return }
        pushHistory()
        location = other.location
        parentLocations = other.parentLocations
        dropClosedFromHistory()
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
        forwardStack.append(currentEntry)
        restore(previous)
    }

    /// Vpřed v historii (Alt+→).
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentEntry)
        restore(next)
    }

    /// Přepnutí na krok historie (lokace i její zanoření; zásobníky historie
    /// upravuje volající).
    private func restore(_ entry: HistoryEntry) {
        location = entry.location
        parentLocations = entry.parents
        marked.removeAll()
        reload()
    }

    /// Přejde na cestu zadanou uživatelem (v aktuálním VFS; "~" = domov na lokálním disku).
    func goToTypedPath(_ typed: String) {
        let path = typed.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        changePath(resolveTypedPath(path, in: location))
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

    /// Označí/odznačí položky odpovídající masce (Num +/-). Masku vyhodnocuje
    /// jádro – platí stejná pravidla jako při hledání; chybná maska hodí chybu.
    /// - Parameters:
    ///   - mask: skupina masek (`*.txt;*.md`, vyloučení za `|`)
    ///   - select: označit (jinak odznačit)
    ///   - includeDirs: použít masku i na adresáře
    func markByMask(_ mask: String, select: Bool, includeDirs: Bool) throws {
        let names = Array(markAllTargets(includeDirs: includeDirs))
        let matches = try coreMaskSelect(mask: mask, names: names)
        let matched = zip(names, matches).filter(\.1).map(\.0)
        if select { marked.formUnion(matched) } else { marked.subtract(matched) }
        markingChanged()
    }

    /// Označí všechny položky včetně adresářů / zruší všechna označení.
    func markAll(_ on: Bool) {
        if on {
            marked.formUnion(markAllTargets(includeDirs: true))
        } else {
            marked.removeAll()
        }
        markingChanged()
    }

    /// ⌘A: je-li už vše (adresáře jen s includeDirs) označené, zruší celé
    /// označení (vždy včetně adresářů), jinak vše označí (dříve označené zůstanou).
    func toggleMarkAll(includeDirs: Bool) {
        let targets = markAllTargets(includeDirs: includeDirs)
        if targets.isEmpty || !targets.isSubset(of: marked) {
            marked.formUnion(targets)
        } else {
            marked.removeAll()
        }
        markingChanged()
    }

    /// Po změně označení: překreslit panel a oznámit stav (informační řádek).
    private func markingChanged() {
        view?.reloadTable()
        delegate?.panelStateChanged(self)
    }

    /// Jména položek pro „označit vše“ (bez „..“, adresáře jen s includeDirs).
    private func markAllTargets(includeDirs: Bool) -> Set<String> {
        Set(rows.filter { !$0.isParent && (includeDirs || !$0.item.isDir) }.map(\.item.name))
    }

    /// Invertuje označení souborů (Num *); adresáře jen s includeDirs.
    func invertMarks(includeDirs: Bool) {
        marked.formSymmetricDifference(markAllTargets(includeDirs: includeDirs))
        markingChanged()
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
        } else {
            // Žádná shoda: znak se nepřidá (pro první znak hledání ani nezačne).
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
            // Řádek „..“ se rychlým hledáním nehledá (stejně jako ve findPrefix).
            if !rows[index].isParent, rows[index].item.name.lowercased().hasPrefix(quickSearch.lowercased()) {
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

    /// Nejbližší adresář na lokálním disku: adresář panelu, v archivu či na
    /// FTP lokální adresář, ze kterého se vešlo; nil, když žádný není.
    var nearestLocalPath: String? {
        // realPath vrací cestu jen pro lokální VFS (jinak nil).
        let locations = [location] + parentLocations.reversed().map(\.location)
        return locations.lazy.compactMap { $0.vfs.realPath($0.path) }.first
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

/// Cesta zadaná uživatelem (změna adresáře, cíl kopírování…) jako normalizovaná
/// cesta ve VFS: absolutní, nebo relativní k `location`; na lokálním disku se
/// rozvine „~“.
/// - Parameters:
///   - typed: zadaný text
///   - location: lokace, ke které se vztahují relativní cesty
func resolveTypedPath(_ typed: String, in location: Location) -> String {
    var path = typed
    if location.vfs.kind == SAL_VFS_LOCAL, path.hasPrefix("~") {
        path = (path as NSString).expandingTildeInPath
    }
    return normalizePath(path.hasPrefix("/") ? path : joinPath(location.path, path))
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
