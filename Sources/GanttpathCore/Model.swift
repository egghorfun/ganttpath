// Project data model and editing commands.
//
// Every command mutates the project it is given and throws ModelError for anything the user must be told about
// (the Session wrapper turns that into a message and leaves the project untouched). Commands never schedule; the Session
// runs the scheduler after each command.
// Only the first task-level fields are stored; WBS numbers and summary status are always derived from the outline.

import Foundation

public let SCHEMA = 2 // 2: durations are stored in working minutes (dur) instead of whole days
public let BASELINE_COUNT = 11 // Baseline + Baseline 1..10, as in MS Project
public let BASELINE_NAMES = ["Baseline"] + (1...10).map { "Baseline \($0)" }

public struct ModelError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public func defaultSettings(_ startDate: String) -> Settings { Settings(startDate: startDate) }

// MARK: - PDF header / footer (Project > Header and Footer...)
// Modelled on MS Project's own Page Setup > Header/Footer tabs: a Left, Center and Right box for each of the header and
// footer, each up to 3 lines, each line either empty, custom text, or one inserted field. Font, size and colour are set
// once per box (not per line), matching how a Word/Project header section is one run of formatting.
public let HF_FIELDS = ["none", "text", "title", "docnum", "page", "date", "printed", "range", "status", "logo", "legend", "hoursday", "hoursweek", "daysmonth"]
public let HF_FIELD_LABELS: [String: String] = [
    "none": "(empty)", "text": "Custom text", "title": "Project Title", "docnum": "Document Number", "page": "Page number",
    "date": "Date", "printed": "Printed date and time", "range": "Project date range", "status": "Status date", "logo": "Company logo", "legend": "Conflict legend",
    "hoursday": "Hours per day", "hoursweek": "Hours per week", "daysmonth": "Days per month",
]
let HF_MIN_SIZE = 6.0, HF_MAX_SIZE = 24.0
public let HF_DEFAULT_COLOR = "#475569" // matches the "Grey" standard swatch, so the colour picker shows it selected by default
func blankHFBox(_ size: Double = 10) -> HFBox { HFBox(lines: [HFLine(), HFLine(), HFLine()], font: "system", size: size, color: HF_DEFAULT_COLOR) }

public func defaultHeaderFooter() -> HeaderFooter {
    var header = HFSection(left: blankHFBox(14), center: blankHFBox(), right: blankHFBox())
    header.left.lines[0] = HFLine(field: "title")
    header.right.lines[0] = HFLine(field: "logo")
    var footer = HFSection(left: blankHFBox(), center: blankHFBox(), right: blankHFBox())
    footer.left.lines[0] = HFLine(field: "legend")
    footer.center.lines = [HFLine(field: "range"), HFLine(field: "status"), HFLine(field: "printed")]
    footer.right.lines[0] = HFLine(field: "page")
    return HeaderFooter(header: header, footer: footer)
}

func normHFLine(_ l: JSON?) -> HFLine {
    let o = l?.object ?? JSONObject()
    let f = o["field"]?.string ?? ""
    return HFLine(field: HF_FIELDS.contains(f) ? f : "none", text: String((o["text"]?.string ?? "").utf16.prefix(200)) ?? "")
}
func isHexColor(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return u.count == 7 && u[0] == UInt8(ascii: "#") && u[1...].allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102) }
}
func normHFBox(_ b: JSON?) -> HFBox {
    let o = b?.object ?? JSONObject()
    var lines = (o["lines"]?.array ?? []).prefix(3).map { normHFLine($0) }
    while lines.count < 3 { lines.append(HFLine()) }
    let size = (o["size"] ?? .null).jsNumber
    let color = o["color"]?.string ?? ""
    return HFBox(lines: lines, font: o["font"]?.string ?? "system",
                 size: size.isFinite && size >= HF_MIN_SIZE && size <= HF_MAX_SIZE && o["size"] != nil && !(o["size"]!.isNull) ? size : 10,
                 color: isHexColor(color) ? color : HF_DEFAULT_COLOR)
}
public func normalizeHeaderFooter(_ hf: JSON?) -> HeaderFooter {
    let src = hf?.object ?? JSONObject()
    let h = src["header"]?.object.map { JSON.object($0) }
    let f = src["footer"]?.object.map { JSON.object($0) }
    return HeaderFooter(
        header: HFSection(left: normHFBox(h?["left"]), center: normHFBox(h?["center"]), right: normHFBox(h?["right"])),
        footer: HFSection(left: normHFBox(f?["left"]), center: normHFBox(f?["center"]), right: normHFBox(f?["right"])))
}
public func normalizeHeaderFooter(_ hf: HeaderFooter) -> HeaderFooter { normalizeHeaderFooter(hf.json) }

public let LOGO_MAX_CHARS = 2_800_000 // a data: URL this long is roughly a 2 MB image after base64 overhead

public func newProject(name: String = "Untitled project", startDate: String? = nil, country: String = "SG", calendars: [CalendarDef]? = nil) -> Project {
    let sd = startDate ?? toISO(todayDn())
    var s = defaultSettings(sd)
    s.country = country
    return Project(name: name, settings: s, calendars: (calendars?.isEmpty == false) ? calendars! : [defaultCalendarDef("Standard")])
}

/// A new task with the next uid. `durationDays` is accepted as a shorthand for `dur` (minutes), like the JavaScript app's `duration`.
public func blankTask(_ p: inout Project, level: Int = 1, name: String = "New task", durationDays: Double? = nil, dur: Int? = nil,
                      configure: (inout Task) -> Void = { _ in }) -> Task {
    let uid = p.nextUid
    p.nextUid += 1
    var t = Task(uid: uid)
    t.name = name
    t.level = level
    t.mode = p.settings.newTasksAuto == false ? "manual" : "auto"
    t.dur = dur ?? jsRoundInt((durationDays ?? 1) * Double(dayMinOf(p.settings)))
    configure(&t)
    return t
}

public let TASK_TYPES = ["fixedUnits", "fixedDuration", "fixedWork"]
public let TASK_TYPE_NAMES = ["fixedUnits": "Fixed Units", "fixedDuration": "Fixed Duration", "fixedWork": "Fixed Work"]
/// True/false fields of a task: out of the schedule, on the timeline view, no bar on the Gantt chart, bar rolled up to the summary.
public let TASK_FLAGS = ["inactive", "onTimeline", "hideBar", "rollup"]
/// True/false fields controlling how a task's Name is drawn: bold, italic, underline.
public let NAME_STYLE_FLAGS = ["nameBold", "nameItalic", "nameUnderline"]
public let PRIORITY_DEFAULT = 500

/// Repair anything a hand-edited or imported file might have got wrong, so the rest of the app can rely on the shape.
/// `uidValid[i]` false marks a task whose uid was not an integer in the file.
public func normalizeProject(_ p: inout Project, uidValid: [Bool]? = nil) {
    p.schema = max(p.schema, SCHEMA)
    if p.name.isEmpty { p.name = "Untitled project" }
    p.settings.documentNumber = String(String(p.settings.documentNumber.utf16.prefix(200)) ?? "")
    if let l = p.settings.logoDataUrl, !(l.hasPrefix("data:image/") && l.utf16.count <= LOGO_MAX_CHARS) { p.settings.logoDataUrl = nil }
    if p.calendars.isEmpty { p.calendars = [defaultCalendarDef("Standard")] }
    if !p.calendars.contains(where: { $0.id == p.settings.defaultCalendarId }) { p.settings.defaultCalendarId = p.calendars[0].id }
    var maxUid = 0
    var seen = Set<Int>()
    for i in p.tasks.indices {
        let ok = uidValid.map { i < $0.count ? $0[i] : true } ?? true
        if !ok || seen.contains(p.tasks[i].uid) { maxUid += 1; p.tasks[i].uid = maxUid + 1000000 } // re-key clashes far from real uids
        seen.insert(p.tasks[i].uid)
        maxUid = max(maxUid, p.tasks[i].uid)
    }
    for i in p.tasks.indices {
        var t = p.tasks[i]
        t.level = max(1, t.level)
        if t.mode != "manual" { t.mode = "auto" }
        t.dur = max(0, t.dur)
        if !isDurationUnit(t.durUnit) { t.durUnit = "d" }
        t.preds = t.preds.filter { seen.contains($0.uid) && $0.uid != t.uid }
        t.pct = min(100, max(0, t.pct.isNaN ? 0 : t.pct))
        if t.baselines.count > BASELINE_COUNT { t.baselines = Array(t.baselines.prefix(BASELINE_COUNT)) }
        while t.baselines.count < BASELINE_COUNT { t.baselines.append(nil) }
        t.priority = min(1000, max(0, t.priority))
        if !TASK_TYPES.contains(t.taskType) { t.taskType = "fixedUnits" }
        p.tasks[i] = t
    }
    p.nextUid = max(p.nextUid, maxUid + 1)
    normalizeOutline(&p)
}

// MARK: - lookups
public func indexOfUid(_ p: Project, _ uid: Int?) -> Int {
    guard let uid = uid else { return -1 }
    return p.tasks.firstIndex { $0.uid == uid } ?? -1
}
public func taskByUid(_ p: Project, _ uid: Int) -> Task? { p.tasks.first { $0.uid == uid } }
@discardableResult
func needIndex(_ p: Project, _ uid: Int) throws -> Int {
    let i = indexOfUid(p, uid)
    if i < 0 { throw ModelError("That task no longer exists") }
    return i
}
public func idToUidMap(_ p: Project) -> (Int) -> Int? {
    let tasks = p.tasks
    return { id in id >= 1 && id <= tasks.count ? tasks[id - 1].uid : nil }
}
public func uidToIdMap(_ p: Project) -> (Int) -> Int? {
    var m: [Int: Int] = [:]
    for (i, t) in p.tasks.enumerated() { m[t.uid] = i + 1 }
    return { m[$0] }
}
public func calendarDefOf(_ p: Project, _ task: Task?) -> CalendarDef {
    if let id = task?.calendarId, !id.isEmpty, let d = p.calendars.first(where: { $0.id == id }) { return d }
    return p.calendars.first { $0.id == p.settings.defaultCalendarId } ?? p.calendars[0]
}
public func calendarOf(_ p: Project, _ task: Task?) -> Cal {
    if let t = task, isElapsedUnit(t.durUnit) { return ELAPSED_CAL }
    return Cal(calendarDefOf(p, task))
}
/// The round-the-clock calendar of elapsed-duration tasks.
public let ELAPSED_CAL = Cal(ELAPSED_CALENDAR)
public func projectCalendar(_ p: Project) -> Cal { calendarOf(p, nil) }

/// Index just after the last descendant of task i.
public func subtreeEnd(_ p: Project, _ i: Int) -> Int {
    let lv = p.tasks[i].level
    var j = i + 1
    while j < p.tasks.count && p.tasks[j].level > lv { j += 1 }
    return j
}
public func isSummaryAt(_ p: Project, _ i: Int) -> Bool {
    i >= 0 && i + 1 < p.tasks.count && p.tasks[i + 1].level > p.tasks[i].level
}
public func descendantsOf(_ p: Project, _ i: Int) -> [Int] { Array((i + 1)..<subtreeEnd(p, i)) }
public func ancestorsOf(_ p: Project, _ i: Int) -> [Int] {
    let par = parentIndexes(p.tasks)
    var out: [Int] = []
    var a = par[i]
    while a >= 0 { out.append(a); a = par[a] }
    return out
}

/// Outline invariants: the first row is level 1 and no row is more than one level deeper than the row above.
public func normalizeOutline(_ p: inout Project) {
    var prev = 0
    for i in p.tasks.indices {
        p.tasks[i].level = min(max(1, p.tasks[i].level), prev + 1)
        prev = p.tasks[i].level
    }
}

/// Selected uids -> indexes of the top-most selected rows (a selected row inside another selected row's subtree is ignored).
func topSelected(_ p: Project, _ uids: [Int]) -> [Int] {
    let set = Set(uids)
    var idx: [Int] = []
    var skipUntil = -1
    for i in p.tasks.indices {
        if i < skipUntil { continue }
        if set.contains(p.tasks[i].uid) { idx.append(i); skipUntil = subtreeEnd(p, i) }
    }
    return idx
}

// MARK: - outline editing
/// Insert a new task at `index` (0..n). It takes the level of the row it is inserted above (or the row above at the end).
@discardableResult
public func insertTask(_ p: inout Project, _ index: Int, level: Int? = nil, name: String = "New task", durationDays: Double? = nil, dur: Int? = nil,
                       configure: (inout Task) -> Void = { _ in }) -> Task {
    let n = p.tasks.count
    let at = max(0, min(index, n))
    let lv = level ?? (at < n ? p.tasks[at].level : n > 0 ? p.tasks[n - 1].level : 1)
    let t = blankTask(&p, level: lv, name: name, durationDays: durationDays, dur: dur, configure: configure)
    p.tasks.insert(t, at: at)
    normalizeOutline(&p)
    return p.tasks[at]
}

@discardableResult
public func deleteTasks(_ p: inout Project, _ uids: [Int]) -> Int {
    let idx = topSelected(p, uids)
    if idx.isEmpty { return 0 }
    var kill = Set<Int>()
    for i in idx { for j in i..<subtreeEnd(p, i) { kill.insert(p.tasks[j].uid) } }
    p.tasks.removeAll { kill.contains($0.uid) }
    for i in p.tasks.indices { p.tasks[i].preds.removeAll { kill.contains($0.uid) } }
    normalizeOutline(&p)
    return kill.count
}

/// Insert `count` blank tasks at row index `index` (before the row now there; at the end when index is past the last row), all at
/// outline level `level` (default: the level of the row they are inserted before). Returns the new uids in order.
public func insertRows(_ p: inout Project, _ index: Int, _ count: Double, level: Int? = nil) -> [Int] {
    let c = count.isFinite ? Int(count.rounded(.down)) : 1
    let n = max(1, min(500, c == 0 ? 1 : c))
    let at = max(0, min(index, p.tasks.count))
    let lv = level ?? (at < p.tasks.count ? p.tasks[at].level : p.tasks.isEmpty ? 1 : p.tasks[p.tasks.count - 1].level)
    var out: [Int] = []
    for k in 0..<n { out.append(insertTask(&p, at + k, level: lv).uid) }
    return out
}

/// A copy of selected rows with their sub-tasks, for pasting later.
public struct TaskClip: Equatable, Sendable {
    public var rows: [Task]
    public var baseLevel: Int
    public init(rows: [Task], baseLevel: Int) { self.rows = rows; self.baseLevel = baseLevel }
}

/// Copy of the selected rows with their sub-tasks. Links to rows outside the copy are not kept by pasteTasks.
public func copyTasks(_ p: Project, _ uids: [Int]) -> TaskClip? {
    let idx = topSelected(p, uids)
    if idx.isEmpty { return nil }
    var rows: [Task] = []
    for i in idx { for j in i..<subtreeEnd(p, i) { rows.append(p.tasks[j]) } }
    return TaskClip(rows: rows, baseLevel: p.tasks[idx[0]].level)
}

/// Paste rows made by copyTasks as new tasks before the row `beforeUid` (at the end when nil), starting at outline level `level`.
/// The copies get new uids, keep the links among themselves only, and start with no progress and no baselines.
public func pasteTasks(_ p: inout Project, _ clip: TaskClip?, beforeUid: Int?, level: Int? = nil) throws -> [Int] {
    guard let clip = clip, !clip.rows.isEmpty else { throw ModelError("There is nothing to paste") }
    let at = beforeUid == nil ? p.tasks.count : indexOfUid(p, beforeUid)
    if at < 0 { throw ModelError("The row to paste before no longer exists") }
    let above: Task? = at > 0 ? p.tasks[at - 1] : nil
    let base = max(1, min(level ?? (above?.level ?? 1), above.map { $0.level + 1 } ?? 1))
    var map: [Int: Int] = [:]
    var copies: [Task] = clip.rows.map { src in
        var c = src
        c.uid = p.nextUid
        p.nextUid += 1
        map[src.uid] = c.uid
        c.level = max(1, src.level - clip.baseLevel + base)
        c.baselines = Array(repeating: nil, count: BASELINE_COUNT)
        c.actualStart = nil; c.actualFinish = nil; c.pct = 0
        return c
    }
    for k in copies.indices {
        copies[k].preds = copies[k].preds.filter { map[$0.uid] != nil }.map { var x = $0; x.uid = map[$0.uid]!; return x }
    }
    p.tasks.insert(contentsOf: copies, at: at)
    normalizeOutline(&p)
    sanitizeLinks(&p)
    return copies.map { $0.uid }
}

/// Remove links that are illegal in an outline: between a summary and one of its own sub-tasks. Returns how many were removed.
@discardableResult
public func sanitizeLinks(_ p: inout Project) -> Int {
    let par = parentIndexes(p.tasks)
    var idxOf: [Int: Int] = [:]
    for (i, t) in p.tasks.enumerated() { idxOf[t.uid] = i }
    var removed = 0
    for j in p.tasks.indices {
        var anc = Set<Int>()
        var a = par[j]
        while a >= 0 { anc.insert(a); a = par[a] }
        let before = p.tasks[j].preds.count
        p.tasks[j].preds = p.tasks[j].preds.filter { x in
            guard let i = idxOf[x.uid], i != j else { return false }
            if anc.contains(i) { return false } // predecessor is one of my summaries
            // predecessor is a descendant of mine (I am a summary)
            var b = par[i]
            while b >= 0 { if b == j { return false }; b = par[b] }
            return true
        }
        removed += before - p.tasks[j].preds.count
    }
    return removed
}

func shiftSubtree(_ p: inout Project, _ i: Int, _ delta: Int) {
    let end = subtreeEnd(p, i) // measured before any level changes
    for j in i..<end { p.tasks[j].level += delta }
}

public struct OutlineResult: Equatable { public var changed: Int; public var removedLinks: Int }

@discardableResult
public func indentTasks(_ p: inout Project, _ uids: [Int]) -> OutlineResult {
    var done = 0
    let idx = topSelected(p, uids)
    // process from the top; re-evaluate against the live outline each time
    for i0 in idx {
        let i = indexOfUid(p, i0 < p.tasks.count ? p.tasks[i0].uid : nil)
        if i <= 0 { continue }
        if p.tasks[i].level > p.tasks[i - 1].level { continue } // already as deep as allowed
        shiftSubtree(&p, i, +1)
        done += 1
    }
    let removedLinks = sanitizeLinks(&p)
    return OutlineResult(changed: done, removedLinks: removedLinks)
}

@discardableResult
public func outdentTasks(_ p: inout Project, _ uids: [Int]) -> OutlineResult {
    let idx = topSelected(p, uids)
    var done = 0
    for i in idx {
        if p.tasks[i].level <= 1 { continue }
        shiftSubtree(&p, i, -1)
        done += 1
    }
    normalizeOutline(&p)
    let removedLinks = sanitizeLinks(&p)
    return OutlineResult(changed: done, removedLinks: removedLinks)
}

public struct MoveResult: Equatable { public var moved: Int; public var removedLinks: Int }

/// Move the selected rows (with their sub-tasks) so they sit immediately before the row with uid `beforeUid`
/// (nil = the end). `level` is the outline level the moved rows should have at the destination.
@discardableResult
public func moveTasks(_ p: inout Project, _ uids: [Int], beforeUid: Int?, level: Int?) throws -> MoveResult {
    let idx = topSelected(p, uids)
    if idx.isEmpty { return MoveResult(moved: 0, removedLinks: 0) }
    var moving = Set<Int>()
    for i in idx { for j in i..<subtreeEnd(p, i) { moving.insert(j) } }
    let destIndex = beforeUid == nil ? p.tasks.count : indexOfUid(p, beforeUid)
    if destIndex < 0 { throw ModelError("Drop position no longer exists") }
    if moving.contains(destIndex) { throw ModelError("A row cannot be moved inside itself") }
    // blocks in original order
    let blocks = idx.map { Array(p.tasks[$0..<subtreeEnd(p, $0)]) }
    var rest = p.tasks.enumerated().filter { !moving.contains($0.offset) }.map { $0.element }
    // destination in the "rest" array
    let restDest = beforeUid == nil ? rest.count : (rest.firstIndex { $0.uid == beforeUid } ?? -1)
    let above: Task? = restDest > 0 ? rest[restDest - 1] : nil
    let maxLevel = above.map { $0.level + 1 } ?? 1
    let wanted = level ?? (above?.level ?? 1)
    let newLevel = max(1, min(wanted, maxLevel))
    var flat: [Task] = []
    for b in blocks {
        let delta = newLevel - b[0].level
        for var t in b { t.level += delta; flat.append(t) }
    }
    // JavaScript's splice with -1 inserts before the last element
    let insertAt = restDest < 0 ? max(0, rest.count - 1) : restDest
    rest.insert(contentsOf: flat, at: insertAt)
    p.tasks = rest
    normalizeOutline(&p)
    let removedLinks = sanitizeLinks(&p)
    return MoveResult(moved: flat.count, removedLinks: removedLinks)
}

public struct WbsResult: Equatable { public var moved: Int; public var wbs: String; public var removedLinks: Int; public var same: Bool }

/// Give a task (with its sub-tasks) the WBS number `code`, e.g. "4.7.1": it becomes the 1st sub-task of the task that now shows 4.7 (a task
/// that had no sub-tasks becomes a summary), and the outline follows. The last number is the place among the sub-tasks that stay:
/// 4.7.2 goes after the first one, the next free number goes at the end. "6" puts it on the top level as number 6.
/// The parent is looked up by the numbers shown now, so what is typed is what is on the screen.
public func setWbs(_ p: inout Project, _ uid: Int, _ code: String?) throws -> WbsResult {
    let i = indexOfUid(p, uid)
    if i < 0 { throw ModelError("That task no longer exists") }
    let text = jsTrim(code ?? "")
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.allSatisfy({ $0.count >= 1 && $0.count <= 6 && $0.utf8.allSatisfy(isAsciiDigit) }) else {
        throw ModelError("A WBS number is numbers separated by dots, like 4.7.1")
    }
    var nums = parts.map { Int($0)! }
    if nums.contains(where: { $0 < 1 }) { throw ModelError("WBS numbers start at 1 (for example 4.7.1, not 4.0.1)") }
    let wbs = computeWBS(p.tasks)
    if wbs[i] == nums.map(String.init).joined(separator: ".") { return WbsResult(moved: 0, wbs: wbs[i], removedLinks: 0, same: true) }
    let end = subtreeEnd(p, i)
    let k = nums.removeLast()
    let prefix = nums.map(String.init).joined(separator: ".")
    var pi = -1 // index of the new parent (-1 = the top level)
    if !prefix.isEmpty {
        pi = wbs.firstIndex(of: prefix) ?? -1
        if pi < 0 { throw ModelError("There is no task \(prefix), so \(text) cannot be placed under it") }
        if pi >= i && pi < end { throw ModelError("A task cannot be moved inside itself") }
    }
    let parentLevel = pi < 0 ? 0 : p.tasks[pi].level
    let from = pi + 1, to = pi < 0 ? p.tasks.count : subtreeEnd(p, pi)
    var kids: [Int] = []
    if from < to { for j in from..<to where p.tasks[j].level == parentLevel + 1 && !(j >= i && j < end) { kids.append(j) } }
    if k > kids.count + 1 {
        let where_ = !prefix.isEmpty ? "\(prefix) has \(kids.count) sub-task\(kids.count == 1 ? "" : "s")" : "The top level has \(kids.count) task\(kids.count == 1 ? "" : "s")"
        throw ModelError("\(where_), so the next free number is \(!prefix.isEmpty ? "\(prefix)." : "")\(kids.count + 1)")
    }
    var beforeUid: Int? = nil
    if k <= kids.count { beforeUid = p.tasks[kids[k - 1]].uid }
    else {
        var j = to
        while j >= i && j < end { j = end }
        beforeUid = j < p.tasks.count ? p.tasks[j].uid : nil
    }
    let r = try moveTasks(&p, [uid], beforeUid: beforeUid, level: parentLevel + 1)
    let at = indexOfUid(p, uid)
    for a in ancestorsOf(p, at) { p.tasks[a].collapsed = false } // the moved task must not end up hidden inside a collapsed summary
    return WbsResult(moved: r.moved, wbs: computeWBS(p.tasks)[at], removedLinks: r.removedLinks, same: false)
}

public func toggleCollapse(_ p: inout Project, _ uid: Int, _ value: Bool? = nil) throws {
    let i = try needIndex(p, uid)
    p.tasks[i].collapsed = value ?? !p.tasks[i].collapsed
}

// MARK: - links
/// Would adding link pred -> succ create a circular chain (following links and summary inheritance)? Uses the real scheduler.
func wouldCycle(_ p: Project, _ predUid: Int, _ succUid: Int, _ type: String, _ lag: Lag) -> Bool {
    let before = schedule(p).cycles.count
    var trial = p
    if let si = trial.tasks.firstIndex(where: { $0.uid == succUid }) {
        trial.tasks[si].preds.removeAll { $0.uid == predUid }
        trial.tasks[si].preds.append(Pred(uid: predUid, type: type, lag: lag))
    }
    return schedule(trial).cycles.count > before
}

/// Returns an error message, or nil if the link is allowed.
public func checkLink(_ p: Project, _ predUid: Int, _ succUid: Int, _ type: String = "FS", _ lag: Lag = .zero) -> String? {
    if predUid == succUid { return "A task cannot depend on itself" }
    let i = indexOfUid(p, predUid), j = indexOfUid(p, succUid)
    if i < 0 || j < 0 { return "That task no longer exists" }
    if ancestorsOf(p, j).contains(i) { return "A sub-task cannot be linked to its own summary task" }
    if ancestorsOf(p, i).contains(j) { return "A summary task cannot be linked to one of its own sub-tasks" }
    if wouldCycle(p, predUid, succUid, type, lag) { return "This link would create a circular dependency" }
    return nil
}

/// Add (or replace) the link pred -> succ.
public func addLink(_ p: inout Project, _ predUid: Int, _ succUid: Int, _ type: String = "FS", _ lag: Lag = .zero) throws {
    if let err = checkLink(p, predUid, succUid, type, lag) { throw ModelError(err) }
    let s = try needIndex(p, succUid)
    p.tasks[s].preds.removeAll { $0.uid == predUid }
    p.tasks[s].preds.append(Pred(uid: predUid, type: type, lag: Lag(v: lag.v.isNaN ? 0 : lag.v, u: lag.u.isEmpty ? "d" : lag.u)))
}

public func removeLink(_ p: inout Project, _ predUid: Int, _ succUid: Int) throws {
    let s = try needIndex(p, succUid)
    p.tasks[s].preds.removeAll { $0.uid == predUid }
}

/// Replace all predecessors of a task (used when the Predecessors cell is edited).
public func setPredecessors(_ p: inout Project, _ succUid: Int, _ preds: [Pred]) throws {
    let s = try needIndex(p, succUid)
    let old = p.tasks[s].preds
    p.tasks[s].preds = []
    for x in preds {
        if let err = checkLink(p, x.uid, succUid, x.type, x.lag) {
            p.tasks[s].preds = old
            throw ModelError(err)
        }
        p.tasks[s].preds.append(Pred(uid: x.uid, type: x.type.isEmpty ? "FS" : x.type, lag: x.lag))
    }
}

// MARK: - field edits
let CONSTRAINT_SET: Set<String> = ["ASAP", "ALAP", "MSO", "MFO", "SNET", "SNLT", "FNET", "FNLT"]

public func setName(_ p: inout Project, _ uid: Int, _ name: String?) throws {
    let i = try needIndex(p, uid)
    p.tasks[i].name = name ?? ""
}

// ---- working-time helpers for manual tasks (their start and finish are typed dates that follow their duration)
/// The moment a task can start at when `st` is typed as its start: the first working moment at or after it.
func startTickOf(_ cal: Cal, _ st: Stamp, _ pc: Cal? = nil) -> Int {
    if cal === ELAPSED_CAL, let pc = pc { return elapsedTick(pc, st, finish: false) }
    return cal.normStart(st.dn * DAY_MIN + (st.min ?? 0))
}
/// For an elapsed-duration task a date without a time means the start (or the end) of that day's working time in the project
/// calendar - 08:00 or 17:00 with the usual hours, as MS Project places elapsed tasks. A time given is kept as it is.
public func elapsedTick(_ pc: Cal, _ st: Stamp, finish: Bool) -> Int {
    if let m = st.min { return st.dn * DAY_MIN + m }
    if finish { return pc.dayEnd(st.dn) ?? (st.dn * DAY_MIN + (pc.stdPeriods.last?.e ?? 1020)) }
    return pc.dayStart(st.dn) ?? (st.dn * DAY_MIN + (pc.stdPeriods.first?.s ?? 480))
}
/// The moment a task can finish at when `st` is typed as its finish: without a time, the end of that working day.
func finishTickOf(_ cal: Cal, _ st: Stamp, _ pc: Cal? = nil) -> Int {
    if cal === ELAPSED_CAL, let pc = pc { return elapsedTick(pc, st, finish: true) }
    return cal.normFinish(st.min == nil ? (st.dn + 1) * DAY_MIN : st.dn * DAY_MIN + st.min!)
}
/// Stored text for a tick: a date, or a date and time when the time matters.
func stampOfTick(_ tick: Int, _ isFinish: Bool, _ timed: Bool) -> String {
    let dn = floorDiv(isFinish ? tick - 1 : tick, DAY_MIN)
    return timed ? toStamp(dn, tick - dn * DAY_MIN) : toISO(dn)
}
func isTimed(_ cal: Cal, _ t: Task, _ s: Int, _ f: Int) -> Bool {
    if t.durUnit == "h" || t.durUnit == "m" { return true }
    let sd = floorDiv(s, DAY_MIN), fd = floorDiv(f - 1, DAY_MIN)
    return !(cal.onBoundary(sd, s - sd * DAY_MIN) && cal.onBoundary(fd, f - fd * DAY_MIN))
}

/// Manual task: set its start (a typed date or moment) and recalculate its finish from its duration.
public func placeManual(_ p: inout Project, _ i: Int, _ st: Stamp) {
    let t = p.tasks[i]
    let cal = calendarOf(p, t)
    let d = taskMin(t, p.settings)
    if d == 0 { p.tasks[i].start = toStamp(st.dn, st.min); p.tasks[i].finish = p.tasks[i].start; return }
    let s = startTickOf(cal, st, projectCalendar(p))
    let f = cal.finishAt(cal.posOf(s) + d)
    let timed = isTimed(cal, t, s, f)
    p.tasks[i].start = stampOfTick(s, false, timed)
    p.tasks[i].finish = stampOfTick(f, true, timed)
}

func stampOrThrow(_ text: String?, _ what: String = "date") throws -> Stamp {
    guard let text = text, let st = parseStamp(text) else { throw ModelError("Not a valid \(what)") }
    if text.contains("T") && st.min == nil { throw ModelError("Not a valid \(what)") }
    return st
}

/// Set a duration: working minutes and the unit to show them in (as read by parseDuration()). Manual tasks keep their start and
/// get a new finish; summary tasks cannot be edited. Duration 0 makes a milestone (as in MS Project).
public func setDuration(_ p: inout Project, _ uid: Int, _ spec: DurationSpec) throws {
    let i = indexOfUid(p, uid)
    try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("A summary task takes its duration from its sub-tasks") }
    let min = spec.min
    var unit = p.tasks[i].durUnit.isEmpty ? "d" : p.tasks[i].durUnit
    if isDurationUnit(spec.unit) { unit = spec.unit }
    if min < 0 { throw ModelError("Duration must be zero or more working time") }
    p.tasks[i].dur = min
    p.tasks[i].durUnit = unit
    if min == 0 { p.tasks[i].milestone = false } // a zero-duration task is already a milestone; the flag is for tasks with duration
    if p.tasks[i].mode == "manual", let st = parseStamp(p.tasks[i].start) { placeManual(&p, i, st) }
}

/// Set a duration given in days of the project ("Hours per day" long).
public func setDurationDays(_ p: inout Project, _ uid: Int, _ days: Double) throws {
    let m = days * Double(dayMinOf(p.settings))
    guard m.isFinite else { throw ModelError("Duration must be zero or more working time") }
    let i = indexOfUid(p, uid)
    try needIndex(p, uid)
    try setDuration(&p, uid, DurationSpec(min: jsRoundInt(m), unit: p.tasks[i].durUnit))
}

/// Type a start date (or date and time). MS Project rule (Microsoft "Start fields" help): on an automatically scheduled task this
/// sets a Start No Earlier Than constraint at that date. On a manual task it moves the task, keeping its duration.
public func setStart(_ p: inout Project, _ uid: Int, _ iso: String?) throws {
    let i = indexOfUid(p, uid)
    try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("A summary task takes its dates from its sub-tasks") }
    let st = try stampOrThrow(iso)
    if p.tasks[i].mode == "manual" { placeManual(&p, i, st) }
    else { p.tasks[i].constraint = Constraint(type: "SNET", date: toStamp(st.dn, st.min)) }
}

/// Type a finish date (or date and time). MS Project rule (Microsoft "Finish (task field)" help): on an automatically scheduled task
/// this sets a Finish No Earlier Than constraint at that date. On a manual task the duration is recalculated.
public func setFinish(_ p: inout Project, _ uid: Int, _ iso: String?) throws {
    let i = indexOfUid(p, uid)
    try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("A summary task takes its dates from its sub-tasks") }
    let fin = try stampOrThrow(iso)
    if p.tasks[i].mode != "manual" { p.tasks[i].constraint = Constraint(type: "FNET", date: toStamp(fin.dn, fin.min)); return }
    let t = p.tasks[i]
    let cal = calendarOf(p, t)
    let st = parseStamp(t.start) ?? Stamp(dn: fin.dn, min: nil)
    if fin.dn < st.dn { throw ModelError("Finish cannot be before start") }
    let s = startTickOf(cal, st, projectCalendar(p))
    if taskMin(t, p.settings) == 0 && fin.dn == st.dn { p.tasks[i].finish = t.start; return }
    var f = finishTickOf(cal, fin, projectCalendar(p))
    var d = cal.posOf(f) - cal.posOf(s)
    if d <= 0 {
        if fin.min != nil { throw ModelError("Finish cannot be before start") }
        // a finish typed on a day off before any work has been done means one day of work from the start
        d = dayMinOf(p.settings)
        f = cal.finishAt(cal.posOf(s) + d)
    }
    p.tasks[i].dur = d
    let timed = isTimed(cal, p.tasks[i], s, f)
    p.tasks[i].start = stampOfTick(s, false, timed)
    p.tasks[i].finish = stampOfTick(f, true, timed)
}

public func setConstraint(_ p: inout Project, _ uid: Int, _ type: String, _ iso: String?) throws {
    let i = try needIndex(p, uid)
    if !CONSTRAINT_SET.contains(type) { throw ModelError("Unknown constraint type") }
    let needsDate = !(type == "ASAP" || type == "ALAP")
    var date: String? = nil
    if needsDate {
        guard let st = parseStamp(iso ?? "") else { throw ModelError("This constraint needs a date") }
        date = toStamp(st.dn, st.min)
    }
    p.tasks[i].constraint = Constraint(type: type, date: date)
}

public func setDeadline(_ p: inout Project, _ uid: Int, _ iso: String?) throws {
    let i = try needIndex(p, uid)
    guard let iso = iso, !iso.isEmpty else { p.tasks[i].deadline = nil; return }
    let st = try stampOrThrow(iso)
    p.tasks[i].deadline = toStamp(st.dn, st.min)
}

public func setMode(_ p: inout Project, _ uid: Int, _ mode: String, _ sched: ScheduleResult?) throws {
    let i = try needIndex(p, uid)
    if mode != "auto" && mode != "manual" { throw ModelError("Unknown scheduling mode") }
    if mode == p.tasks[i].mode { return }
    if mode == "manual" {
        // freeze the dates currently shown, so switching to manual does not move the task
        if let s = sched, i < s.tasks.count, s.tasks[i].start != nil {
            p.tasks[i].start = s.tasks[i].startStamp
            p.tasks[i].finish = s.tasks[i].finishStamp
        }
    }
    p.tasks[i].mode = mode
}

public func setMilestone(_ p: inout Project, _ uid: Int, _ on: Bool) throws {
    let i = try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("A summary task cannot be a milestone") }
    p.tasks[i].milestone = on
}

/// "Month" shortcut: the task covers the whole calendar month containing `dnInMonth` (working days only).
public func setMonthTask(_ p: inout Project, _ uid: Int, _ dnInMonth: Int) throws {
    let i = try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("A summary task takes its dates from its sub-tasks") }
    let cal = calendarOf(p, p.tasks[i])
    let first = cal.next(startOfMonthDn(dnInMonth))
    let last = cal.prev(endOfMonthDn(dnInMonth))
    p.tasks[i].dur = max(cal.minutesOf(first), cal.midx(last + 1) - cal.midx(first)) // every working minute of the month
    p.tasks[i].durUnit = "d"
    if p.tasks[i].mode == "manual" { p.tasks[i].start = toISO(first); p.tasks[i].finish = toISO(last) }
    else { p.tasks[i].constraint = Constraint(type: "SNET", date: toISO(first)) }
}

/// Set % complete. Follows MS Project's habit: progress above 0 records an actual start (the scheduled start), 100 records an
/// actual finish (the scheduled finish); lowering the value removes what no longer applies.
public func setPercent(_ p: inout Project, _ uid: Int, _ pct: Double, _ sched: ScheduleResult?) throws {
    let i = try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("A summary task takes its progress from its sub-tasks") }
    let v = jsRound(pct)
    if !v.isFinite || v < 0 || v > 100 { throw ModelError("% complete must be between 0 and 100") }
    let r: ScheduledTask? = sched.flatMap { i < $0.tasks.count ? $0.tasks[i] : nil }
    p.tasks[i].pct = v
    if v > 0 && (p.tasks[i].actualStart ?? "").isEmpty { p.tasks[i].actualStart = nonEmpty(r?.startStamp) ?? nonEmpty(p.tasks[i].start) }
    if v >= 100 { if (p.tasks[i].actualFinish ?? "").isEmpty { p.tasks[i].actualFinish = nonEmpty(r?.finishStamp) ?? nonEmpty(p.tasks[i].finish) } }
    else { p.tasks[i].actualFinish = nil }
    if v == 0 { p.tasks[i].actualStart = nil; p.tasks[i].actualFinish = nil }
}

@inline(__always) func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

public func setActualDates(_ p: inout Project, _ uid: Int, _ startIso: String?, _ finishIso: String?) throws {
    let i = try needIndex(p, uid)
    let sIn = nonEmpty(startIso), fIn = nonEmpty(finishIso)
    let s = sIn.flatMap { parseStamp($0) }, f = fIn.flatMap { parseStamp($0) }
    if (sIn != nil && s == nil) || (fIn != nil && f == nil) { throw ModelError("Not a valid date") }
    if let s = s, let f = f, f.dn * DAY_MIN + (f.min ?? DAY_MIN) < s.dn * DAY_MIN + (s.min ?? 0) { throw ModelError("Actual finish cannot be before actual start") }
    p.tasks[i].actualStart = s.map { toStamp($0.dn, $0.min) }
    p.tasks[i].actualFinish = f.map { toStamp($0.dn, $0.min) }
    if f != nil { p.tasks[i].pct = 100 }
    else if p.tasks[i].pct >= 100 { p.tasks[i].pct = 99 }
}

public func setTaskCalendar(_ p: inout Project, _ uid: Int, _ calId: String?) throws {
    let i = try needIndex(p, uid)
    if let c = nonEmpty(calId), !p.calendars.contains(where: { $0.id == c }) { throw ModelError("Unknown calendar") }
    p.tasks[i].calendarId = nonEmpty(calId)
}

public func setWeight(_ p: inout Project, _ uid: Int, _ w: String?) throws {
    let i = try needIndex(p, uid)
    guard let w = w, !w.isEmpty else { p.tasks[i].weight = nil; return }
    let v = jsNumberFromString(w)
    if !v.isFinite || v < 0 { throw ModelError("Weight must be zero or more") }
    p.tasks[i].weight = v
}

public func setColor(_ p: inout Project, _ uids: [Int], _ color: String?) throws {
    for uid in uids { let i = try needIndex(p, uid); p.tasks[i].color = nonEmpty(color) }
}

/// Priority 0 to 1000 (MS Project: 500 is the normal priority). It is kept, shown, sorted and exchanged; it changes no date because there is no resource levelling.
public func setPriority(_ p: inout Project, _ uid: Int, _ v: String) throws {
    let s = jsTrim(v)
    let n = jsNumberFromString(s)
    if s.isEmpty || !n.isFinite || n < 0 || n > 1000 { throw ModelError("Priority must be a number from 0 to 1000 (500 is normal)") }
    let i = try needIndex(p, uid)
    p.tasks[i].priority = jsRoundInt(n)
}

/// Fixed Units, Fixed Duration or Fixed Work. It only changes how work is spread over resources, so with no resources it changes no date.
public func setTaskType(_ p: inout Project, _ uid: Int, _ type: String) throws {
    if !TASK_TYPES.contains(type) { throw ModelError("Task type must be Fixed Units, Fixed Duration or Fixed Work") }
    let i = try needIndex(p, uid)
    p.tasks[i].taskType = type
}

/// One of the true/false fields in TASK_FLAGS. Only a task without sub-tasks can be made inactive.
public func setTaskFlag(_ p: inout Project, _ uid: Int, _ key: String, _ on: Bool) throws {
    if !TASK_FLAGS.contains(key) { throw ModelError("Unknown task setting: \(key)") }
    let i = indexOfUid(p, uid)
    if i < 0 { throw ModelError("That task no longer exists") }
    if key == "inactive" && on && isSummaryAt(p, i) { throw ModelError("A summary task cannot be made inactive. Make its sub-tasks inactive instead.") }
    p.tasks[i].setFlag(key, on)
}

public func setNotes(_ p: inout Project, _ uid: Int, _ text: String?) throws {
    let i = try needIndex(p, uid)
    p.tasks[i].notes = text ?? ""
}

/// One of the true/false fields in NAME_STYLE_FLAGS: how the task's Name is drawn (bold, italic, underline).
public func setNameStyleFlag(_ p: inout Project, _ uid: Int, _ key: String, _ on: Bool) throws {
    if !NAME_STYLE_FLAGS.contains(key) { throw ModelError("Unknown name style: \(key)") }
    let i = try needIndex(p, uid)
    p.tasks[i].setFlag(key, on)
}

/// CSS text for a task's Name style flags (bold/italic/underline), or '' when none are set.
public func nameStyleCss(_ t: Task) -> String {
    var s = ""
    if t.nameBold { s += "font-weight:700;" }
    if t.nameItalic { s += "font-style:italic;" }
    if t.nameUnderline { s += "text-decoration:underline;" }
    return s
}

// MARK: - drag and drop helpers
/// Bar moved to a new start day. Auto: Start No Earlier Than at that day (as MS Project). Manual: shift, keeping duration.
public func moveBarTo(_ p: inout Project, _ uid: Int, _ newStartDn: Int, _ minuteOfDay: Int? = nil) throws {
    try setStart(&p, uid, minuteOfDay == nil ? toISO(newStartDn) : toStamp(newStartDn, minuteOfDay))
}

/// Right edge of the bar dragged to `newFinishDn`: the duration becomes the working time from the current start to the end of that day.
public func resizeBarTo(_ p: inout Project, _ uid: Int, _ newFinishDn: Int, _ sched: ScheduleResult?) throws {
    let i = indexOfUid(p, uid)
    try needIndex(p, uid)
    if isSummaryAt(p, i) { throw ModelError("Summary bars cannot be resized") }
    let t = p.tasks[i]
    let r: ScheduledTask? = sched.flatMap { i < $0.tasks.count ? $0.tasks[i] : nil }
    guard let st = parseStamp(nonEmpty(r?.startStamp) ?? nonEmpty(r?.start) ?? t.start) else { throw ModelError("Task has no start date yet") }
    let cal = calendarOf(p, t)
    let s = r?.startTick ?? startTickOf(cal, st, projectCalendar(p))
    let f = cal === ELAPSED_CAL ? elapsedTick(projectCalendar(p), Stamp(dn: newFinishDn, min: nil), finish: true) : cal.normFinish((newFinishDn + 1) * DAY_MIN)
    let d = max(0, cal.posOf(f) - cal.posOf(s))
    try setDuration(&p, uid, DurationSpec(min: d == 0 && t.milestone ? dayMinOf(p.settings) : d, unit: t.durUnit.isEmpty ? "d" : t.durUnit))
}

// MARK: - baselines
/// Save the current schedule as baseline `n` (0 = "Baseline", 1..5) for the given uids (all tasks when nil).
public func setBaseline(_ p: inout Project, _ n: Int, _ sched: ScheduleResult, _ uids: [Int]? = nil) throws {
    if !(n >= 0 && n < BASELINE_COUNT) { throw ModelError("Baseline number must be 0 to 10") }
    let only = uids.map(Set.init)
    for i in p.tasks.indices {
        if let o = only, !o.contains(p.tasks[i].uid) { continue }
        guard i < sched.tasks.count, sched.tasks[i].start != nil else { continue }
        let r = sched.tasks[i]
        p.tasks[i].baselines[n] = Baseline(start: r.startStamp, finish: r.finishStamp, duration: r.duration, dur: r.durationMin)
    }
}

public func clearBaseline(_ p: inout Project, _ n: Int, _ uids: [Int]? = nil) throws {
    if !(n >= 0 && n < BASELINE_COUNT) { throw ModelError("Baseline number must be 0 to 10") }
    let only = uids.map(Set.init)
    for i in p.tasks.indices where only == nil || only!.contains(p.tasks[i].uid) { p.tasks[i].baselines[n] = nil }
}

// MARK: - tags, custom columns, calendars, settings
public func addTag(_ p: inout Project, _ name: String?, _ color: String = "#64748B") throws {
    let nm = jsTrim(name ?? "")
    if nm.isEmpty { throw ModelError("Tag needs a name") }
    if p.tags.contains(where: { $0.name.lowercased() == nm.lowercased() }) { throw ModelError("That tag already exists") }
    p.tags.append(Tag(name: nm, color: color))
}
public func removeTag(_ p: inout Project, _ name: String) {
    p.tags.removeAll { $0.name == name }
    for i in p.tasks.indices { p.tasks[i].tags.removeAll { $0 == name } }
}
public func setTaskTags(_ p: inout Project, _ uids: [Int], on tagsOn: [String], off tagsOff: [String] = []) throws {
    for uid in uids {
        let i = try needIndex(p, uid)
        var list = p.tasks[i].tags
        var seen = Set<String>()
        list = list.filter { seen.insert($0).inserted } // a JavaScript Set keeps the first of equal values
        for x in tagsOn where !seen.contains(x) { list.append(x); seen.insert(x) }
        list.removeAll { tagsOff.contains($0) }
        p.tasks[i].tags = list
    }
}

func base36Now() -> String { String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) }

@discardableResult
public func addCustomColumn(_ p: inout Project, id: String? = nil, name: String?, type: String = "text", options: [String] = []) throws -> String {
    let nm = jsTrim(name ?? "")
    if nm.isEmpty { throw ModelError("Column needs a name") }
    let cid = nonEmpty(id) ?? "c\(base36Now())\(p.customColumns.count)"
    if p.customColumns.contains(where: { $0.id == cid }) { throw ModelError("Column id already used") }
    p.customColumns.append(CustomColumn(id: cid, name: nm, type: type, options: options))
    return cid
}
public func removeCustomColumn(_ p: inout Project, _ id: String) {
    p.customColumns.removeAll { $0.id == id }
    for i in p.tasks.indices { p.tasks[i].custom[id] = nil }
}
public func setCustomValue(_ p: inout Project, _ uid: Int, _ colId: String, _ value: JSON) throws {
    guard let col = p.customColumns.first(where: { $0.id == colId }) else { throw ModelError("Unknown column") }
    let i = try needIndex(p, uid)
    var v: JSON = value
    if col.type == "number" {
        if value == .string("") || value.isNull { v = .null }
        else { let n = value.jsNumber; if !n.isFinite { throw ModelError("Enter a number") }; v = .number(n) }
    } else if col.type == "date" {
        if value == .string("") || value.isNull { v = .null }
        else { guard let dn = parseISO(value.jsString) else { throw ModelError("Not a valid date") }; v = .string(toISO(dn)) }
    } else if col.type == "flag" { v = .bool(value.truthy) }
    else { v = value.isNull ? .string("") : .string(value.jsString) }
    if v.isNull || v == .string("") || v == .bool(false) { p.tasks[i].custom[colId] = nil } else { p.tasks[i].custom[colId] = v }
}

@discardableResult
public func upsertCalendar(_ p: inout Project, _ def: CalendarDef) throws -> String {
    let i = p.calendars.firstIndex { $0.id == def.id }
    let week = def.workWeek.count == 7 ? def.workWeek : MON_FRI
    var hours: [[RawPeriod]]? = nil
    if let h = def.hours, h.count == 7 {
        let hp = h.enumerated().map { (d, x) in week[d] ? normPeriods(x) : [] }
        if (0..<7).contains(where: { week[$0] && hp[$0].isEmpty }) { throw ModelError("Every working day needs at least one working period (for example 08:00-12:00)") }
        hours = hp.map { $0.map { [Double($0.s), Double($0.e)] } }
    }
    let exceptions: [CalException] = def.exceptions.filter { parseISO($0.from) != nil }.map { e in
        let per = e.working ? normPeriods(e.periods) : []
        return CalException(from: toISO(parseISO(e.from)!), to: toISO(parseISO(nonEmpty(e.to) ?? e.from) ?? parseISO(e.from)!), working: e.working, name: e.name,
                            periods: per.isEmpty ? nil : per.map { [Double($0.s), Double($0.e)] }, origin: nonEmpty(e.origin))
    }
    let nm = jsTrim(def.name.isEmpty ? "Calendar" : def.name)
    let clean = CalendarDef(id: nonEmpty(def.id) ?? "cal\(base36Now())", name: nm.isEmpty ? "Calendar" : nm, workWeek: week, hours: hours, exceptions: exceptions)
    if !clean.workWeek.contains(true) && !clean.exceptions.contains(where: { $0.working }) { throw ModelError("A calendar needs at least one working day") }
    if let i = i { p.calendars[i] = clean } else { p.calendars.append(clean) }
    return clean.id
}

public func removeCalendar(_ p: inout Project, _ id: String) throws {
    if p.calendars.count <= 1 { throw ModelError("At least one calendar is required") }
    if id == p.settings.defaultCalendarId { throw ModelError("The project calendar cannot be deleted; choose another project calendar first") }
    p.calendars.removeAll { $0.id == id }
    for i in p.tasks.indices where p.tasks[i].calendarId == id { p.tasks[i].calendarId = nil }
}

/// Change project settings. `patch` holds only the settings to change, with the same names and value kinds as the project file.
public func updateSettings(_ p: inout Project, _ patch: JSONObject) throws {
    var s = p.settings
    if let v = patch["startDate"] {
        guard parseISO(v.string) != nil else { throw ModelError("Not a valid project start date") }
        s.startDate = v.string!
    }
    if let v = patch["statusDate"] {
        if v.truthy {
            guard parseISO(v.string) != nil else { throw ModelError("Not a valid status date") }
            s.statusDate = v.string
        } else { s.statusDate = nil }
    }
    if let v = patch["criticalSlackDays"] {
        let n = v.jsNumber
        if !n.isFinite || n < 0 { throw ModelError("Critical slack must be zero or more days") }
        s.criticalSlackDays = n
    }
    if let v = patch["nearCriticalDays"] {
        let n = v.jsNumber
        if !n.isFinite || n < 0 { throw ModelError("Near-critical range must be zero or more days") }
        s.nearCriticalDays = n
    }
    if let v = patch["hoursPerDay"] {
        let n = v.jsNumber
        if !n.isFinite || n <= 0 || n > 24 { throw ModelError("Hours per day must be more than 0 and at most 24") }
        s.hoursPerDay = jsRound(n * 100) / 100
    }
    if let v = patch["hoursPerWeek"] {
        let n = v.jsNumber
        if !n.isFinite || n <= 0 || n > 168 { throw ModelError("Hours per week must be more than 0 and at most 168") }
        s.hoursPerWeek = jsRound(n * 100) / 100
    }
    if let v = patch["daysPerMonth"] {
        let n = v.jsNumber
        if !n.isFinite || n <= 0 || n > 31 { throw ModelError("Days per month must be more than 0 and at most 31") }
        s.daysPerMonth = jsRound(n * 100) / 100
    }
    if let v = patch["honorConstraints"] { s.honorConstraints = v.truthy }
    if let v = patch["newTasksAuto"] { s.newTasksAuto = v.truthy }
    if let v = patch["weekStartsMonday"] { s.weekStartsMonday = v.truthy }
    if let v = patch["pickerStartsSunday"] { s.pickerStartsSunday = v.truthy }
    if let v = patch["showWeekday"] { s.showWeekday = v.truthy }
    if let v = patch["dateFormat"] { s.dateFormat = v.string ?? v.jsString }
    if let v = patch["country"] { s.country = v.string ?? v.jsString }
    if let v = patch["defaultCalendarId"] { s.defaultCalendarId = v.string ?? v.jsString }
    if let v = patch["documentNumber"] { s.documentNumber = String(String((v.isNull ? "" : (v.string ?? v.jsString)).utf16.prefix(200)) ?? "") }
    if let v = patch["logoDataUrl"] {
        if v.isNull || v == .string("") { s.logoDataUrl = nil }
        else if let str = v.string, str.hasPrefix("data:image/"), str.utf16.count <= LOGO_MAX_CHARS { s.logoDataUrl = str }
        else { throw ModelError("That does not look like a usable image (PNG or JPEG, up to about 2 MB)") }
    }
    if let v = patch["headerFooter"] { s.headerFooter = normalizeHeaderFooter(v) }
    if !p.calendars.contains(where: { $0.id == s.defaultCalendarId }) { throw ModelError("Unknown project calendar") }
    p.settings = s
}

/// Convert every auto task to manual or the reverse (whole project). Used by the "Schedule mode" project setting.
public func setAllModes(_ p: inout Project, _ mode: String, _ sched: ScheduleResult?) throws {
    for i in p.tasks.indices {
        if isSummaryAt(p, i) { continue }
        try setMode(&p, p.tasks[i].uid, mode, sched)
    }
}
