// The open project and everything the window shows about it: selection, table cursor, view settings, clipboard, file state
// and messages. Port of the JavaScript app's state.js and actions.js. The SwiftUI views read this model and call its
// commands; nothing here depends on a UI framework, so it is tested on Linux as well.

import Foundation
import Observation
import GanttpathCore

public enum ViewTab: String, CaseIterable, Sendable {
    case gantt, network, timeline, cpm, scurve
    public var title: String {
        switch self {
        case .gantt: return "Gantt chart"
        case .network: return "Network diagram"
        case .timeline: return "Timeline summary"
        case .cpm: return "Critical path"
        case .scurve: return "S-curve"
        }
    }
}

public enum SelMode: Sendable { case rows, cells }

public struct Toast: Equatable, Sendable {
    public enum Kind: String, Sendable { case info, error }
    public var id: Int
    public var message: String
    public var kind: Kind
    public var seconds: Double
}

/// What was last copied or cut in the table.
public struct ClipState: Sendable {
    public enum Kind: Sendable { case rows, cells }
    public var kind: Kind
    public var cut: Bool
    public var text: String
    public var data: TaskClip? = nil
    public var uids: [Int]
    public var colIds: [String] = []
    public var uidSet: Set<Int> { Set(uids) }
}

public struct FileState: Sendable {
    public var folder: String? = nil
    public var name: String? = nil
    public var path: String? = nil
    public var lastSavedAt: Date? = nil
    public var lastAutoAt: Date? = nil
    public var autoRevision = -1
    public init() {}
}

/// Things the view layer reacts to (scrolling, focusing an editor, opening a panel).
public enum ModelEvent: Equatable, Sendable {
    case focusName(Int)
    case scrollTo(Int)
    case gotoTask(Int)
    case openInspector
    case scrollToStart
}

/// Where files go and how the outside world is reached. The Mac app fills this in; tests use a temporary folder.
public struct AppEnvironment: Sendable {
    public var templatesDir: String
    public var mpp: (@Sendable (String) throws -> String)?
    public var http: HTTPGet?
    public var now: @Sendable () -> Date
    public var today: @Sendable () -> Int
    public init(templatesDir: String, mpp: (@Sendable (String) throws -> String)? = nil, http: HTTPGet? = nil,
                now: @escaping @Sendable () -> Date = { Date() }, today: @escaping @Sendable () -> Int = { todayDn() }) {
        self.templatesDir = templatesDir; self.mpp = mpp; self.http = http; self.now = now; self.today = today
    }
}

@MainActor
@Observable
public final class DocumentModel {
    // project
    @ObservationIgnored public let session: Session
    public private(set) var project: Project
    public private(set) var sched: ScheduleResult
    public private(set) var revision = 0
    public private(set) var dirty = false
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var undoLabel: String? = nil
    public private(set) var redoLabel: String? = nil

    // rows of the table (after search, filter, sort and grouping)
    public private(set) var built = BuiltRows(rows: [], matched: [], active: false, flat: false)
    public private(set) var posOf: [Int: Int] = [:]

    // selection
    public var selection: Set<Int> = []
    public var anchor: Int? = nil
    public var cursorUid: Int? = nil
    public var cursorCol = "name"
    public var anchorCol = "name"
    public var selMode: SelMode = .cells
    public var linkSel: String? = nil
    public var clip: ClipState? = nil

    // view
    public var view = ViewState() { didSet { rebuildRows() } }
    public var tab: ViewTab = .gantt
    public var px: Double = ZOOM_BASE_PX
    public var showBaseline = -1
    public var showCritical = true
    public var showLabels = true
    public var showLinks = true
    public var progressLine = false
    public var inspectorOpen = false
    public var conflictsOpen = false
    public var columnIds: [String]? = nil
    public var colWidths: [String: Double] = [:]
    public var tableWidth: Double? = nil

    // files and messages
    public var file = FileState()
    public var importReport: (ImportResult, String, String)? = nil
    public private(set) var toast: Toast? = nil
    @ObservationIgnored private var toastId = 0
    @ObservationIgnored public var onEvent: ((ModelEvent) -> Void)? = nil
    @ObservationIgnored public var onPrefsChange: ((inout Prefs) -> Void) -> Void = { _ in }
    @ObservationIgnored public let env: AppEnvironment

    public init(project: Project = newProject(name: "Untitled project"), env: AppEnvironment) {
        self.env = env
        session = Session(project)
        self.project = session.project
        self.sched = session.sched
        session.on { [weak self] kind, _ in
            MainActor.assumeIsolated { self?.sessionChanged(kind) }
        }
        sync()
        file.autoRevision = session.revision
    }

    /// Apply saved preferences to the view settings.
    public func apply(prefs p: Prefs) {
        if let v = p.px { px = v }
        columnIds = p.columns
        colWidths = p.colWidths
        tableWidth = p.tableWidth
        if let b = p.showBaseline { showBaseline = b }
        inspectorOpen = p.inspectorOpen
        progressLine = p.progressLine
    }

    func setPrefs(_ fn: @escaping (inout Prefs) -> Void) { onPrefsChange(fn) }

    // MARK: session events

    private func sessionChanged(_ kind: String) {
        if kind == "load", let c = clip, c.cut { clip = nil } // rows cut in another project cannot be moved into this one
        sync()
        if kind == "change" || kind == "undo" || kind == "redo" || kind == "load" { pruneSelection() }
    }

    private func sync() {
        project = session.project
        sched = session.sched
        revision = session.revision
        dirty = session.dirty
        canUndo = session.history.canUndo
        canRedo = session.history.canRedo
        undoLabel = session.history.undoLabel
        redoLabel = session.history.redoLabel
        rebuildRows()
    }

    private func rebuildRows() {
        built = buildRows(project, sched, view)
        posOf = positions(built.rows)
    }

    public var rows: [RowItem] { built.rows }
    /// Uids of the task rows shown, in table order.
    public var order: [Int] { built.rows.compactMap { $0.index.map { project.tasks[$0].uid } } }
    public var fmt: Fmt { Fmt(project, sched) }
    public var columns: [ColumnDef] { visibleColumns(project, sched, ids: columnIds, widths: colWidths) }
    public var tableContentWidth: Double { columns.reduce(0) { $0 + $1.width } }

    public func index(of uid: Int) -> Int? { let i = indexOfUid(project, uid); return i < 0 ? nil : i }
    public func context(_ uid: Int) -> CellContext? {
        guard let i = index(of: uid) else { return nil }
        return CellContext(project: project, sched: sched, index: i, fmt: fmt, showBaseline: showBaseline, viewActive: !outlinePlain)
    }

    /// True when rows are shown in the full, plain outline (no sort, group, filter or search): the only case where rows can move.
    public var outlinePlain: Bool {
        if view.sort != nil || view.group != nil { return false }
        if built.active && (built.flat || !view.search.isEmpty || view.filter != ViewFilter()) { return false }
        return true
    }

    public var ganttOptions: GanttOptions {
        var o = GanttOptions()
        o.showBaseline = showBaseline
        o.showCritical = showCritical
        o.showLabels = showLabels
        o.showLinks = showLinks
        o.statusDn = parseISO(project.settings.statusDate)
        o.todayDn = env.today()
        o.selected = selection
        o.linkSel = linkSel
        o.progressLine = progressLine && o.statusDn != nil
        o.mondayFirst = project.settings.weekStartsMonday
        return o
    }

    // MARK: messages

    public func say(_ message: String, _ kind: Toast.Kind = .info, _ seconds: Double = 4.2) {
        toastId += 1
        toast = Toast(id: toastId, message: message, kind: kind, seconds: kind == .error ? max(seconds, 7) : seconds)
    }
    public func dismissToast(_ id: Int) { if toast?.id == id { toast = nil } }
    func emit(_ e: ModelEvent) { onEvent?(e) }

    // MARK: running edits

    /// One undoable edit. Shows the error when it fails.
    @discardableResult
    public func run<T>(_ label: String, _ fn: (inout Project, ScheduleResult) throws -> T) -> RunResult<T> {
        let r = session.run(label, fn)
        if let e = r.error { say(e, .error) }
        return r
    }

    // MARK: selection

    public var selectedUids: [Int] { project.tasks.filter { selection.contains($0.uid) }.map { $0.uid } }
    public var selectedIndexes: [Int] { project.tasks.indices.filter { selection.contains(project.tasks[$0].uid) } }

    public func setSelection(_ uids: [Int], anchor a: Int?? = .none) {
        selection = Set(uids)
        if case .some(let v) = a { anchor = v }
    }
    public func selectOnly(_ uid: Int?) {
        selection = uid.map { [$0] } ?? []
        anchor = uid
        if let u = uid { cursorUid = u }
    }
    /// Rows from the anchor to `uid` in table order.
    public func extendSelection(to uid: Int) -> [Int] {
        let o = order
        guard let a = o.firstIndex(of: anchor ?? uid), let b = o.firstIndex(of: uid) else { return [uid] }
        return Array(o[min(a, b)...max(a, b)])
    }
    /// Keep only selected uids that still exist (after deletes / undo).
    @discardableResult
    public func pruneSelection() -> Bool {
        let have = Set(project.tasks.map { $0.uid })
        let before = selection
        selection = selection.filter { have.contains($0) }
        if let c = cursorUid, !have.contains(c) { cursorUid = nil }
        if let key = linkSel {
            let parts = key.split(separator: ">").compactMap { Int($0) }
            if parts.count != 2 || !have.contains(parts[0]) || !(taskByUid(project, parts[1])?.preds.contains { $0.uid == parts[0] } ?? false) { linkSel = nil }
        }
        return before != selection
    }

    // MARK: outline (actions.js)

    /// Add a task after the selection (as a sibling) or at the end. Returns the new uid.
    @discardableResult
    public func addTask(summary: Bool = false, name: String? = nil) -> Int? {
        let sel = selectedIndexes
        var at = project.tasks.count
        var level = project.tasks.last?.level ?? 1
        if let last = sel.last { at = subtreeEnd(project, last); level = project.tasks[last].level }
        let r = run(summary ? "Insert summary task" : "Insert task") { d, _ -> Int in
            let t = insertTask(&d, at, level: level, name: name ?? (summary ? "New summary" : "New task"), durationDays: 1)
            if summary { insertTask(&d, at + 1, level: level + 1, name: "New task", durationDays: 1) }
            return t.uid
        }
        guard let uid = r.value else { return nil }
        selectOnly(uid)
        emit(.focusName(uid))
        if isFiltering(view), let i = index(of: uid), !rows.contains(where: { $0.index == i }) {
            say("The new task is hidden by the current filter or search. Clear it to see the task.", .info, 5)
        }
        return uid
    }

    /// Blank rows above the first or below the last selected row; `count` defaults to the number of selected rows.
    @discardableResult
    public func insertRows(below: Bool = true, count: Int? = nil) -> [Int]? {
        let sel = selectedIndexes
        let n = max(1, min(500, count ?? sel.count))
        var at = project.tasks.count
        var level = project.tasks.last?.level ?? 1
        if !sel.isEmpty && !below { at = sel[0]; level = project.tasks[at].level }
        else if let last = sel.last { at = subtreeEnd(project, last); level = project.tasks[last].level }
        let r = run(n == 1 ? "Insert row" : "Insert \(n) rows") { d, _ in GanttpathCore.insertRows(&d, at, Double(n), level: level) }
        guard let uids = r.value else { return nil }
        setSelection(uids, anchor: uids.first)
        selMode = .rows
        if n == 1 { emit(.focusName(uids[0])) } else { say("\(plural(n, "row")) inserted.", .info, 1.8) }
        if isFiltering(view) {
            let shown = Set(rows.compactMap { $0.index })
            if !uids.contains(where: { u in index(of: u).map { shown.contains($0) } ?? false }) {
                say("The new rows are hidden by the current filter or search. Clear it to see them.", .info, 5)
            }
        }
        return uids
    }

    public func deleteSelected() {
        let uids = selectedUids
        if uids.isEmpty { return }
        let r = run(uids.count == 1 ? "Delete task" : "Delete tasks") { d, _ in deleteTasks(&d, uids) }
        if let n = r.value, !r.unchanged {
            pruneSelection()
            say("Deleted \(plural(n, "task")). Undo brings them back.", .info, 3)
        }
    }

    private func linkNote(_ n: Int) {
        if n > 0 { say("\(plural(n, "link")) between a summary and its own sub-task \(n == 1 ? "was" : "were") removed.") }
    }
    public func indent() {
        let uids = selectedUids
        if uids.isEmpty { return }
        if let r = run("Indent", { d, _ in indentTasks(&d, uids) }).value { linkNote(r.removedLinks) }
    }
    public func outdent() {
        let uids = selectedUids
        if uids.isEmpty { return }
        if let r = run("Outdent", { d, _ in outdentTasks(&d, uids) }).value { linkNote(r.removedLinks) }
    }

    private func movable() -> Bool {
        if view.sort != nil || view.group != nil { say("Clear the sort or group first: rows can only be moved in the plain outline."); return false }
        return true
    }
    public func moveUp() {
        guard movable() else { return }
        let idx = selectedIndexes
        guard let i = idx.first else { return }
        let lv = project.tasks[i].level
        var k = i - 1
        while k >= 0 && project.tasks[k].level > lv { k -= 1 }
        if k < 0 || project.tasks[k].level != lv { return }
        let before = project.tasks[k].uid, uids = selectedUids
        run("Move up") { d, _ in try moveTasks(&d, uids, beforeUid: before, level: lv) }
    }
    public func moveDown() {
        guard movable() else { return }
        let idx = selectedIndexes
        if idx.isEmpty { return }
        let p = project
        guard let lastTop = idx.filter({ i in !idx.contains { j in j < i && i < subtreeEnd(p, j) } }).last else { return }
        let e = subtreeEnd(p, lastTop)
        let lv = p.tasks[lastTop].level
        if e >= p.tasks.count || p.tasks[e].level != lv { return }
        let nextEnd = subtreeEnd(p, e)
        let before: Int? = nextEnd < p.tasks.count ? p.tasks[nextEnd].uid : nil
        let uids = selectedUids
        run("Move down") { d, _ in try moveTasks(&d, uids, beforeUid: before, level: lv) }
    }

    // MARK: links

    public func linkSelected(_ type: String = "FS") {
        let uids = selectedUids
        if uids.count < 2 { say("Select two or more tasks to link them (they are linked in the order they appear)."); return }
        let r = run("Link tasks") { d, _ in for i in 1..<uids.count { try addLink(&d, uids[i - 1], uids[i], type) } }
        if r.ok { say("Linked \(uids.count) tasks (\(type)).", .info, 2.5) }
    }
    public func unlinkSelected() {
        let uids = selectedUids
        if uids.isEmpty { return }
        let set = Set(uids)
        let r = run("Unlink tasks") { d, _ -> Int in
            var removed = 0
            for k in d.tasks.indices {
                let before = d.tasks[k].preds.count
                if set.count == 1 {
                    if set.contains(d.tasks[k].uid) { d.tasks[k].preds = [] } else { d.tasks[k].preds.removeAll { set.contains($0.uid) } }
                } else {
                    let mine = set.contains(d.tasks[k].uid)
                    d.tasks[k].preds.removeAll { set.contains($0.uid) && mine }
                }
                removed += before - d.tasks[k].preds.count
            }
            if removed == 0 { throw ModelError("There are no links to remove between the selected tasks.") }
            return removed
        }
        if let n = r.value { say("\(plural(n, "link")) removed.", .info, 2.5) }
    }
    public func deleteLink(_ key: String) {
        let parts = key.split(separator: ">").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        linkSel = nil
        run("Delete link") { d, _ in try removeLink(&d, parts[0], parts[1]) }
    }
    /// Change the type or lag of a link (the link editor).
    @discardableResult
    public func editLink(_ key: String, type: String, lagText: String) -> Bool {
        let parts = key.split(separator: ">").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        guard let lag = parseLag(lagText) else { say("Lag can be typed like +2d, -25%, +1w or +3ed (elapsed days).", .error); return false }
        let r = run("Edit link") { d, _ in try addLink(&d, parts[0], parts[1], type, lag) }
        if r.ok { linkSel = key }
        return r.ok
    }

    // MARK: task properties

    public func setSelectedMode(_ mode: String) {
        let uids = selectedUids
        if uids.isEmpty { return }
        run(mode == "manual" ? "Set manual scheduling" : "Set automatic scheduling") { d, s in
            for u in uids { let i = indexOfUid(d, u); if !isSummaryAt(d, i) { try setMode(&d, u, mode, s) } }
        }
    }

    static let FLAG_LABELS: [String: (String, String)] = [
        "inactive": ("Make active", "Make inactive"), "onTimeline": ("Remove from Timeline", "Display on Timeline"),
        "hideBar": ("Show task bar", "Hide task bar"), "rollup": ("Stop rolling up Gantt bar", "Roll up Gantt bar to summary"),
    ]
    public func setSelectedFlag(_ key: String, _ on: Bool) {
        let uids = selectedUids
        guard !uids.isEmpty, let l = Self.FLAG_LABELS[key] else { return }
        run(on ? l.1 : l.0) { d, _ in
            for u in uids {
                if key == "inactive" && isSummaryAt(d, indexOfUid(d, u)) { continue } // a summary task cannot be inactive
                try setTaskFlag(&d, u, key, on)
            }
        }
    }

    static let NAME_STYLE_LABELS: [String: (String, String)] = ["nameBold": ("Remove bold", "Bold"), "nameItalic": ("Remove italic", "Italic"), "nameUnderline": ("Remove underline", "Underline")]
    public func toggleSelectedNameStyle(_ key: String) {
        let uids = selectedUids
        guard !uids.isEmpty, let l = Self.NAME_STYLE_LABELS[key] else { return }
        func has(_ t: Task) -> Bool { key == "nameBold" ? t.nameBold : key == "nameItalic" ? t.nameItalic : t.nameUnderline }
        let allOn = uids.allSatisfy { u in taskByUid(project, u).map(has) ?? false }
        let on = !allOn
        run(on ? l.1 : l.0) { d, _ in for u in uids { try setNameStyleFlag(&d, u, key, on) } }
    }

    public func toggleMilestone() {
        if selectedUids.isEmpty { return }
        let idx = selectedIndexes.filter { !sched.tasks[$0].isSummary }
        if idx.isEmpty { say("Summary tasks cannot be milestones."); return }
        let allMs = idx.allSatisfy { sched.tasks[$0].isMilestone }
        run(allMs ? "Clear milestone" : "Make milestone") { d, _ in
            for i in idx {
                if allMs {
                    if d.tasks[i].dur == 0 { d.tasks[i].dur = dayMinOf(d.settings); d.tasks[i].durUnit = "d" }
                    d.tasks[i].milestone = false
                } else {
                    try setDuration(&d, d.tasks[i].uid, DurationSpec(min: 0, unit: d.tasks[i].durUnit))
                }
            }
        }
    }

    public func setBaseline(_ n: Int, selectedOnly: Bool) {
        let uids: [Int]? = selectedOnly ? selectedUids : nil
        if selectedOnly && uids!.isEmpty { say("Select the tasks first, or choose \"whole project\"."); return }
        let r = run("Set \(BASELINE_NAMES[n])") { d, s in try GanttpathCore.setBaseline(&d, n, s, uids) }
        if r.ok {
            showBaseline = n
            setPrefs { $0.showBaseline = n }
            say("\(BASELINE_NAMES[n]) saved for \(uids.map { plural($0.count, "task") } ?? "the whole project").", .info, 2.8)
        }
    }
    public func clearBaseline(_ n: Int, selectedOnly: Bool) {
        let uids: [Int]? = selectedOnly ? selectedUids : nil
        run("Clear \(BASELINE_NAMES[n])") { d, _ in try GanttpathCore.clearBaseline(&d, n, uids) }
    }

    public func setColor(_ hex: String?) {
        let uids = selectedUids
        if uids.isEmpty { return }
        run("Bar colour") { d, _ in try GanttpathCore.setColor(&d, uids, hex) }
    }

    public func undo() { if !session.undo() { say("Nothing to undo.", .info, 1.5) } }
    public func redo() { if !session.redo() { say("Nothing to redo.", .info, 1.5) } }

    // MARK: expanding and collapsing (a view change: not an undo step)

    public func toggleCollapse(_ uid: Int, _ value: Bool? = nil) {
        guard let t = taskByUid(project, uid) else { return }
        session.setCollapsed(uid, value ?? !t.collapsed)
    }
    public func collapseAll(_ value: Bool) {
        let p = project
        for i in p.tasks.indices where isSummaryAt(p, i) { session.setCollapsed(p.tasks[i].uid, value) }
    }
    /// Expand the summaries above a task so its row is shown.
    public func reveal(_ uid: Int) {
        guard let i = index(of: uid), posOf[i] == nil else { return }
        for a in ancestorsOf(project, i) { session.setCollapsed(project.tasks[a].uid, false) }
    }

    // MARK: status bar and title

    public var statusParts: [(text: String, style: String)] {
        let leaves = sched.tasks.filter { !$0.isSummary }
        let crit = leaves.filter { $0.critical }.count
        let f = fmt
        var out: [(String, String)] = [
            (plural(project.tasks.count, "task"), ""),
            ("\(f.date(sched.projectStart).isEmpty ? "-" : f.date(sched.projectStart))  →  \(f.date(sched.projectFinish).isEmpty ? "-" : f.date(sched.projectFinish))", ""),
            ("\(crit) critical", crit > 0 ? "crit" : ""),
            (sched.conflictCount > 0 ? "⚠ \(plural(sched.conflictCount, "conflict"))" : "No conflicts", sched.conflictCount > 0 ? "bad" : ""),
        ]
        if !selection.isEmpty { out.append(("\(selection.count) selected", "")) }
        return out
    }

    public var saveStatusText: String {
        if dirty {
            if let a = file.lastAutoAt, file.autoRevision == revision { return "Autosaved \(clockTime(a))" }
            return "Unsaved changes"
        }
        if let s = file.lastSavedAt { return "Saved \(clockTime(s))" }
        return ""
    }

    public var windowTitle: String { "\(project.name)\(dirty ? " •" : "") - Ganttpath" }
}

/// "14:05" in local time.
public func clockTime(_ d: Date, _ tz: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.hour, .minute], from: d)
    return String(format: "%02d:%02d", c.hour!, c.minute!)
}
/// "21-Sep-2026 14:05" in local time.
public func stampText(_ d: Date, _ tz: TimeZone = .current) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
    return String(format: "%02d-%@-%d %02d:%02d", c.day!, MONTHS[c.month! - 1], c.year!, c.hour!, c.minute!)
}
