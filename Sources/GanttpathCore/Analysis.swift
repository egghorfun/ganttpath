// S-curve, standard reports, network-diagram layout and version comparison.

import Foundation

// MARK: - S-curve
// Cumulative % complete over time for the planned (baseline), forecast (current schedule) and actual progress.
// Each task contributes its weight (default: its duration in working days; milestones default to 0) spread evenly over its
// working days. The ACTUAL curve is an approximation: Ganttpath stores the current % complete, not a history, so progress is
// assumed to have advanced in a straight line from the actual start to the status date.

/// fraction (0..1) of a task's working days that have elapsed by the END of day dn
func fractionDone(_ cal: Cal, _ sDn: Int, _ fDn: Int, _ dn: Int) -> Double {
    if dn < sDn { return 0 }
    if dn >= fDn { return 1 }
    let total = cal.count(sDn, fDn)
    if total <= 0 { return dn >= sDn ? 1 : 0 }
    return min(1, Double(cal.count(sDn, dn)) / Double(total))
}

public struct SCurveStatus: Equatable, Sendable {
    public var statusDate: String
    public var planned: Double?
    public var earned: Double
    public var forecast: Double
    public var spi: Double?
    public var variance: Double?
}

public struct SCurve: Equatable, Sendable {
    public var dates: [String]
    public var planned: [Double?]
    public var forecast: [Double]
    public var actual: [Double?]
    public var totalWeight: Double
    public var status: SCurveStatus?
    public var hasBaseline: Bool
}

public func computeSCurve(_ project: Project, _ sched: ScheduleResult, baseline: Int = 0, statusDate: String? = nil, maxPoints: Int = 240) -> SCurve {
    struct Item { var w: Double; var cal: Cal; var pct: Double; var fs: Int; var ff: Int; var bs: Int?; var bf: Int?; var aS: Int?; var aF: Int? }
    var items: [Item] = []
    for (i, t) in project.tasks.enumerated() {
        let r = sched.tasks[i]
        if r.isSummary || r.start == nil || r.inactive { continue }
        let w = t.weight ?? r.duration
        if !(w > 0) { continue }
        let b = baseline >= 0 && baseline < t.baselines.count ? t.baselines[baseline] : nil
        items.append(Item(w: w, cal: calendarOf(project, t), pct: r.pct / 100, fs: parseISO(r.start)!, ff: parseISO(r.finish) ?? parseISO(r.start)!,
                          bs: b.flatMap { parseISO($0.start) }, bf: b.flatMap { parseISO($0.finish) },
                          aS: nonEmpty(t.actualStart).flatMap(parseISO), aF: nonEmpty(t.actualFinish).flatMap(parseISO)))
    }
    let total = items.reduce(0.0) { $0 + $1.w }
    if items.isEmpty || total <= 0 { return SCurve(dates: [], planned: [], forecast: [], actual: [], totalWeight: 0, status: nil, hasBaseline: false) }
    let hasBaseline = items.contains { $0.bs != nil }
    let status = nonEmpty(statusDate).flatMap(parseISO)
    var lo = Int.max, hi = Int.min
    for x in items {
        lo = min(lo, x.fs, x.bs ?? Int.max, x.aS ?? Int.max)
        hi = max(hi, x.ff, x.bf ?? Int.min, x.aF ?? Int.min)
    }
    if let s = status { lo = min(lo, s); hi = max(hi, s) }
    let span = hi - lo + 1
    let step = max(1, Int((Double(span) / Double(maxPoints)).rounded(.up)))
    var days: [Int] = []
    var d = lo
    while d <= hi { days.append(d); d += step }
    if days.last != hi { days.append(hi) }
    var planned: [Double?] = [], forecast: [Double] = [], actual: [Double?] = []
    for d in days {
        var p = 0.0, f = 0.0, a = 0.0
        for x in items {
            // (a baseline start without a finish counts as a one-day span: JavaScript compares with null as 0)
            if let bs = x.bs { p += x.w * fractionDone(x.cal, bs, x.bf ?? 0, d) }
            f += x.w * fractionDone(x.cal, x.fs, x.ff, d)
            if let s = status, d <= s {
                // completed share as of day d: ramps linearly from the actual start to the status date up to the current %
                var share = 0.0
                if let af = x.aF { share = d >= af ? 1 : x.aS != nil ? fractionDone(x.cal, x.aS!, af, d) : 0 }
                else if let aS = x.aS, x.pct > 0 {
                    let end = max(s, aS)
                    share = x.pct * fractionDone(x.cal, aS, end, d)
                }
                a += x.w * share
            }
        }
        planned.append(hasBaseline ? (p / total) * 100 : nil)
        forecast.append((f / total) * 100)
        actual.append(status != nil && d <= status! ? (a / total) * 100 : nil)
    }
    var stat: SCurveStatus? = nil
    if let s = status {
        var p = 0.0, e = 0.0, f = 0.0
        for x in items {
            if let bs = x.bs { p += x.w * fractionDone(x.cal, bs, x.bf ?? 0, s) }
            f += x.w * fractionDone(x.cal, x.fs, x.ff, s)
            e += x.w * x.pct
        }
        let pl: Double? = hasBaseline ? (p / total) * 100 : nil
        let earned = (e / total) * 100
        stat = SCurveStatus(statusDate: toISO(s), planned: pl, earned: earned, forecast: (f / total) * 100,
                            spi: (pl ?? 0) != 0 ? earned / pl! : nil, variance: pl.map { earned - $0 })
    }
    return SCurve(dates: days.map(toISO), planned: planned, forecast: forecast, actual: actual, totalWeight: total, status: stat, hasBaseline: hasBaseline)
}

// MARK: - Standard reports
// Critical Tasks, Late Tasks, Slipping Tasks and Milestone Report - Ganttpath's own reading of four well-known Microsoft Project
// reference reports, built only from data this app actually tracks. Microsoft Project's own "Late Tasks" filter is driven by its
// Status field, a proprietary, timephased (day-by-day planned-vs-actual) calculation - this app tracks one flat % Complete per task,
// not a day-by-day history, so it cannot reproduce that. "Late" here is instead a plain, disclosed date comparison.

public struct ReportDef: Sendable {
    public let key: String
    public let name: String
    public let blurb: String
}

public let REPORT_DEFS: [ReportDef] = [
    ReportDef(key: "critical", name: "Critical Tasks",
              blurb: "Tasks on the critical path: total slack at or below the project’s Critical Slack Days setting (Project ▸ Project settings). The same flag used by the Critical Path view and the Gantt bars."),
    ReportDef(key: "late", name: "Late Tasks",
              blurb: "Incomplete tasks whose current Finish is already before the status date (or before today, if no status date is set). A plain date comparison - see the note above about how this differs from Microsoft Project’s own Status field."),
    ReportDef(key: "slipping", name: "Slipping Tasks",
              blurb: "Incomplete tasks whose current Finish is later than their saved Baseline Finish. Tasks with no baseline saved are left out - there is nothing to compare against."),
    ReportDef(key: "milestones", name: "Milestone Report",
              blurb: "Every milestone, each read as Complete, Late or Upcoming against the status date (or today)."),
    ReportDef(key: "baselines", name: "Baseline Changes",
              blurb: "Tasks whose start or finish differs between the baseline shown and the compared baseline (choose both under Project ▸ Baselines). Shifts are in working time; positive means later in the compared baseline. Tasks saved in only one of the two baselines are listed as added or dropped."),
]

/// The date "Late Tasks" and the milestone status are measured against: the project's status date if one is set, otherwise today.
public func referenceDn(_ pr: Project, today: Int = todayDn()) -> Int {
    nonEmpty(pr.settings.statusDate).flatMap(parseISO) ?? today
}

public struct ReportRow: Sendable {
    public var row: ScheduledTask
    public var lateDays: Int? = nil
    public var baselineFinish: String? = nil
    public var slipDays: Int? = nil
    public var milestoneStatus: String? = nil
    // Baseline Changes: the two baselines' dates, the shifts in working minutes, and what changed
    public var baseStart: String? = nil
    public var compareStart: String? = nil
    public var compareFinish: String? = nil
    public var startShift: Int? = nil
    public var finishShift: Int? = nil
    public var change: String? = nil
}

func leaves(_ sc: ScheduleResult) -> [ScheduledTask] { sc.tasks.filter { !$0.isSummary && !$0.inactive } }

public func criticalTasksRows(_ sc: ScheduleResult) -> [ReportRow] { leaves(sc).filter { $0.critical }.map { ReportRow(row: $0) } }

public func lateTasksRows(_ pr: Project, _ sc: ScheduleResult, today: Int = todayDn()) -> [ReportRow] {
    let ref = referenceDn(pr, today: today)
    return leaves(sc).compactMap { r in
        if r.pct >= 100 { return nil }
        guard let fin = parseISO(r.finish), fin < ref else { return nil }
        return ReportRow(row: r, lateDays: ref - fin)
    }
}

public func slippingTasksRows(_ pr: Project, _ sc: ScheduleResult, baselineIndex: Int = 0) -> [ReportRow] {
    leaves(sc).compactMap { r in
        if r.pct >= 100 { return nil }
        let bl = pr.tasks[r.index].baselines
        let b = baselineIndex >= 0 && baselineIndex < bl.count ? bl[baselineIndex] : nil
        guard let baseFin = b.flatMap({ parseISO($0.finish) }), let fin = parseISO(r.finish), fin > baseFin else { return nil }
        return ReportRow(row: r, baselineFinish: b!.finish, slipDays: fin - baseFin)
    }
}

public func milestoneRows(_ pr: Project, _ sc: ScheduleResult, today: Int = todayDn()) -> [ReportRow] {
    let ref = referenceDn(pr, today: today)
    return sc.tasks.filter { !$0.isSummary && !$0.inactive && $0.isMilestone }.map { r in
        let complete = r.pct >= 100
        let fin = parseISO(r.finish)
        let status = complete ? "Complete" : (fin != nil && fin! < ref ? "Late" : "Upcoming")
        return ReportRow(row: r, milestoneStatus: status)
    }
}

/// Tasks that differ between baseline `base` and baseline `compare` (see the "baselines" report).
public func baselineChangeRows(_ pr: Project, _ sc: ScheduleResult, base: Int, compare: Int) -> [ReportRow] {
    guard base >= 0, compare >= 0, base != compare, base < BASELINE_COUNT, compare < BASELINE_COUNT else { return [] }
    return leaves(sc).compactMap { r in
        let t = pr.tasks[r.index]
        let a = t.baselines[base], b = t.baselines[compare]
        if a == nil && b == nil { return nil }
        var row = ReportRow(row: r, baselineFinish: a?.finish, baseStart: a?.start, compareStart: b?.start, compareFinish: b?.finish)
        guard let a = a else { row.change = "Added in \(BASELINE_NAMES[compare])"; return row }
        guard let b = b else { row.change = "Not in \(BASELINE_NAMES[compare])"; return row }
        let x = CellContext(project: pr, sched: sc, index: r.index)
        row.startShift = baselineShift(x, a, b, start: true)
        row.finishShift = baselineShift(x, a, b, start: false)
        if (row.startShift ?? 0) == 0 && (row.finishShift ?? 0) == 0 { return nil }
        let f = row.finishShift ?? 0, s = row.startShift ?? 0
        row.change = f > 0 ? "Finishes later" : f < 0 ? "Finishes earlier" : s > 0 ? "Starts later" : "Starts earlier"
        return row
    }
}

/// Whether any baseline has been saved anywhere in the project.
public func hasAnyBaseline(_ pr: Project) -> Bool { pr.tasks.contains { $0.baselines.contains { $0 != nil } } }

public func reportRows(_ key: String, _ pr: Project, _ sc: ScheduleResult, baselineIndex: Int = 0, compareIndex: Int = -1, today: Int = todayDn()) -> [ReportRow] {
    switch key {
    case "critical": return criticalTasksRows(sc)
    case "late": return lateTasksRows(pr, sc, today: today)
    case "slipping": return slippingTasksRows(pr, sc, baselineIndex: baselineIndex)
    case "milestones": return milestoneRows(pr, sc, today: today)
    case "baselines": return baselineChangeRows(pr, sc, base: baselineIndex, compare: compareIndex)
    default: return []
    }
}

// MARK: - Network diagram layout
// Boxes for tasks arranged in columns by logical depth, rows chosen to keep links short.

public enum NetworkScope: Equatable, Sendable { case all, critical, summary(Int) }

public struct NetworkNode: Equatable, Sendable {
    public var uid: Int, index: Int, col: Int, row: Int
    public var x: Double, y: Double, w: Double, h: Double
}
public struct NetworkEdge: Equatable, Sendable {
    public var from: Int, to: Int
    public var type: String
    public var lag: Lag
    public var conflict: Bool
    public var critical: Bool
    public var points: [(Double, Double)]
    public static func == (a: NetworkEdge, b: NetworkEdge) -> Bool {
        a.from == b.from && a.to == b.to && a.type == b.type && a.lag == b.lag && a.conflict == b.conflict && a.critical == b.critical
            && a.points.map { [$0.0, $0.1] } == b.points.map { [$0.0, $0.1] }
    }
}
public struct NetworkLayout: Equatable, Sendable {
    public var nodes: [NetworkNode]
    public var edges: [NetworkEdge]
    public var width: Double, height: Double
    public var truncated: Bool
    public var total: Int
}

public func layoutNetwork(_ project: Project, _ sched: ScheduleResult, scope: NetworkScope = .all, includeSummaries: Bool = false,
                          boxW: Double = 170, boxH: Double = 64, gapX: Double = 60, gapY: Double = 24, maxNodes: Int = 1500) -> NetworkLayout {
    let T = project.tasks
    let parent = parentIndexes(T)
    var idx: [Int: Int] = [:]
    for (i, t) in T.enumerated() { idx[t.uid] = i }
    var inScope: (Int) -> Bool = { _ in true }
    switch scope {
    case .all: break
    case .critical: inScope = { sched.tasks[$0].critical && !sched.tasks[$0].isSummary }
    case .summary(let uid):
        let root = idx[uid] ?? -99
        var under = Set<Int>()
        for i in T.indices { var p = parent[i]; while p >= 0 { if p == root { under.insert(i); break }; p = parent[p] } }
        inScope = { under.contains($0) }
    }
    var wanted: [Int] = []
    for i in T.indices {
        if sched.tasks[i].isSummary && !includeSummaries { continue }
        if sched.tasks[i].inactive { continue } // inactive tasks take no part in the network
        if inScope(i) { wanted.append(i) }
    }
    let truncated = wanted.count > maxNodes
    let nodesIdx = truncated ? Array(wanted.prefix(maxNodes)) : wanted
    let inSet = Set(nodesIdx)
    var edges: [NetworkEdge] = []
    for L in sched.links where inSet.contains(L.pIndex) && inSet.contains(L.tIndex) {
        edges.append(NetworkEdge(from: L.predUid, to: L.uid, type: L.type, lag: L.lag, conflict: L.conflict,
                                 critical: sched.tasks[L.pIndex].critical && sched.tasks[L.tIndex].critical, points: []))
    }
    // depth (column) = longest chain of predecessors; cycles are cut by a visit guard
    var preds: [Int: [Int]] = [:]
    for i in nodesIdx { preds[i] = [] }
    for e in edges { preds[idx[e.to]!]!.append(idx[e.from]!) }
    var col: [Int: Int] = [:]
    var state: [Int: Int] = [:]
    for i in nodesIdx.sorted() {
        var stack = [i]
        while let cur = stack.last {
            if col[cur] != nil { stack.removeLast(); continue }
            var ready = true, d = 0
            for p in preds[cur]! {
                if let cp = col[p] { d = max(d, cp + 1) }
                else if state[p] != 1 { ready = false; stack.append(p) }
            }
            state[cur] = 1
            if ready { col[cur] = d; stack.removeLast() }
        }
    }
    // rows: process columns left to right, place each node near the average row of its predecessors
    var byCol: [Int: [Int]] = [:]
    for i in nodesIdx { byCol[col[i] ?? 0, default: []].append(i) }
    var row: [Int: Int] = [:]
    let maxCol = max(0, byCol.keys.max() ?? 0)
    for c in 0...maxCol {
        var list = byCol[c] ?? []
        func bary(_ i: Int) -> Double {
            let ps = preds[i]!.filter { row[$0] != nil }
            return ps.isEmpty ? .infinity : Double(ps.reduce(0) { $0 + row[$1]! }) / Double(ps.count)
        }
        let bv = Dictionary(uniqueKeysWithValues: list.map { ($0, bary($0)) })
        list.sort { a, b in
            let x = bv[a]!, y = bv[b]!
            if x.isInfinite && y.isInfinite { return a < b } // Infinity - Infinity is NaN, treated as a tie
            if x != y { return x < y }
            return a < b
        }
        var next = 0
        for i in list {
            let b = bv[i]!
            let want = b.isFinite ? max(next, Int(jsRound(b))) : next
            row[i] = want
            next = want + 1
        }
    }
    let nodes = nodesIdx.map { i -> NetworkNode in
        let c = col[i] ?? 0, r = row[i] ?? 0
        return NetworkNode(uid: T[i].uid, index: i, col: c, row: r, x: Double(c) * (boxW + gapX), y: Double(r) * (boxH + gapY), w: boxW, h: boxH)
    }
    var pos: [Int: NetworkNode] = [:]
    for nd in nodes { pos[nd.uid] = nd }
    for k in edges.indices {
        let a = pos[edges[k].from]!, b = pos[edges[k].to]!
        let x1 = a.x + a.w, y1 = a.y + a.h / 2, x2 = b.x, y2 = b.y + b.h / 2
        let mx = x1 + gapX / 2
        edges[k].points = b.x > a.x + a.w - 1
            ? [(x1, y1), (mx, y1), (mx, y2), (x2, y2)]
            : [(x1, y1), (x1 + 12, y1), (x1 + 12, a.y + a.h + gapY / 2), (x2 - 12, a.y + a.h + gapY / 2), (x2 - 12, y2), (x2, y2)]
    }
    let width = nodes.map { $0.x + $0.w }.max() ?? 0
    let height = nodes.map { $0.y + $0.h }.max() ?? 0
    return NetworkLayout(nodes: nodes, edges: edges, width: width, height: height, truncated: truncated, total: wanted.count)
}

// MARK: - Compare two versions of a project (matching tasks by uid)

public struct CompareChange: Equatable, Sendable {
    public var field: String, label: String, from: String, to: String
    public var derived: Bool
}
public struct CompareTask: Equatable, Sendable {
    public var status: String // added | removed | changed
    public var uid: Int, id: Int, wbs: String, name: String
    public var changes: [CompareChange]
    public var onlyDerived: Bool
}
public struct CompareNote: Equatable, Sendable { public var label: String, from: String, to: String }
public struct CompareSummary: Equatable, Sendable {
    public var added: Int, removed: Int, changed: Int, rescheduled: Int, unchanged: Int
    public var identical: Bool
    public var listed: Int
}
public struct CompareResult: Equatable, Sendable {
    public var summary: CompareSummary
    public var tasks: [CompareTask]
    public var notes: [CompareNote]
}

private let COMPARE_FIELDS: [(String, String)] = [
    ("name", "Name"), ("wbs", "WBS"), ("mode", "Mode"), ("duration", "Duration (days)"), ("start", "Start"), ("finish", "Finish"),
    ("preds", "Predecessors"), ("constraint", "Constraint"), ("deadline", "Deadline"), ("pct", "% Complete"), ("calendar", "Calendar"),
    ("milestone", "Milestone"), ("tags", "Tags"), ("notes", "Notes"), ("weight", "Weight"), ("critical", "Critical"), ("totalSlack", "Total slack (days)"),
]
/// Fields that only change because something else changed (dates, slack, WBS numbers) are listed but flagged as "derived".
private let COMPARE_DERIVED: Set<String> = ["wbs", "critical", "totalSlack"]

private func compareSnapshot(_ project: Project, _ sched: ScheduleResult) -> [(uid: Int, index: Int, level: Int, fields: [String: String])] {
    let uidToId = uidToIdMap(project)
    return project.tasks.enumerated().map { (i, t) in
        let r = sched.tasks[i]
        let cal = nonEmpty(t.calendarId).map { id in project.calendars.first { $0.id == id }?.name ?? "" } ?? ""
        var cons = ""
        if !r.isSummary && !t.constraint.type.isEmpty && t.constraint.type != "ASAP" {
            cons = "\(CONSTRAINT_NAMES[t.constraint.type] ?? "undefined")\(nonEmpty(t.constraint.date).map { " " + $0 } ?? "")"
        }
        let f: [String: String] = [
            "name": t.name, "wbs": r.wbs, "mode": r.isSummary ? "Summary" : t.mode == "manual" ? "Manual" : "Auto",
            "duration": jsNumberString(jsRound(r.duration * 100) / 100), "start": r.startStamp ?? "", "finish": r.finishStamp ?? "",
            "preds": formatPredecessors(t.preds, uidToId), "constraint": cons, "deadline": t.deadline ?? "",
            "pct": jsNumberString(jsRound(r.pct)), "calendar": cal, "milestone": r.isMilestone ? "Yes" : "", "tags": t.tags.joined(separator: "; "),
            "critical": r.critical ? "Yes" : "", "totalSlack": r.totalSlack.map(jsNumberString) ?? "", "notes": t.notes,
            "weight": t.weight.map(jsNumberString) ?? "",
        ]
        return (t.uid, i, t.level, f)
    }
}

public func compareProjects(_ a: Project, _ b: Project, dateFormat: String = "DD-MMM-YYYY") -> CompareResult {
    let sa = schedule(a), sb = schedule(b)
    let A = compareSnapshot(a, sa), B = compareSnapshot(b, sb)
    var aByUid: [Int: (uid: Int, index: Int, level: Int, fields: [String: String])] = [:]
    for x in A { aByUid[x.uid] = x }
    let bUids = Set(B.map { $0.uid })
    func fmt(_ field: String, _ v: String) -> String {
        if (field == "start" || field == "finish" || field == "deadline"), v.count >= 10, let dn = parseISO(v) {
            return formatDate(dn, dateFormat) + (v.count >= 16 ? " \(v.dropFirst(11).prefix(5))" : "")
        }
        return v
    }
    var tasks: [CompareTask] = []
    for tb in B {
        let bw = tb.fields["wbs"]!, bn = tb.fields["name"]!
        guard let ta = aByUid[tb.uid] else {
            tasks.append(CompareTask(status: "added", uid: tb.uid, id: tb.index + 1, wbs: bw, name: bn, changes: [], onlyDerived: false)); continue
        }
        var changes: [CompareChange] = []
        for (f, label) in COMPARE_FIELDS where ta.fields[f]! != tb.fields[f]! {
            changes.append(CompareChange(field: f, label: label, from: fmt(f, ta.fields[f]!), to: fmt(f, tb.fields[f]!), derived: COMPARE_DERIVED.contains(f)))
        }
        if ta.level != tb.level { changes.append(CompareChange(field: "level", label: "Outline level", from: String(ta.level), to: String(tb.level), derived: false)) }
        if !changes.isEmpty {
            tasks.append(CompareTask(status: "changed", uid: tb.uid, id: tb.index + 1, wbs: bw, name: bn, changes: changes, onlyDerived: changes.allSatisfy { $0.derived }))
        }
    }
    for ta in A where !bUids.contains(ta.uid) {
        tasks.append(CompareTask(status: "removed", uid: ta.uid, id: ta.index + 1, wbs: ta.fields["wbs"]!, name: ta.fields["name"]!, changes: [], onlyDerived: false))
    }
    tasks = tasks.enumerated().sorted { $0.element.id != $1.element.id ? $0.element.id < $1.element.id : $0.offset < $1.offset }.map { $0.element }

    var notes: [CompareNote] = []
    if sa.projectFinish != sb.projectFinish { notes.append(CompareNote(label: "Project finish", from: fmt("finish", sa.projectFinish ?? ""), to: fmt("finish", sb.projectFinish ?? ""))) }
    if sa.projectStart != sb.projectStart { notes.append(CompareNote(label: "Project start", from: fmt("start", sa.projectStart ?? ""), to: fmt("start", sb.projectStart ?? ""))) }
    if a.tasks.count != b.tasks.count { notes.append(CompareNote(label: "Number of tasks", from: String(a.tasks.count), to: String(b.tasks.count))) }
    func critCount(_ s: ScheduleResult) -> Int { s.tasks.filter { $0.critical && !$0.isSummary }.count }
    if critCount(sa) != critCount(sb) { notes.append(CompareNote(label: "Critical tasks", from: String(critCount(sa)), to: String(critCount(sb)))) }
    if sa.conflictCount != sb.conflictCount { notes.append(CompareNote(label: "Conflicts", from: String(sa.conflictCount), to: String(sb.conflictCount))) }
    func calSig(_ p: Project) -> String {
        p.calendars.map { c in "\(c.name)|\(c.workWeek)|" + c.exceptions.map { "\($0.from),\($0.to ?? ""),\($0.working)" }.joined(separator: ";") }.joined(separator: "#")
    }
    if calSig(a) != calSig(b) { notes.append(CompareNote(label: "Calendars / holidays", from: "changed", to: "")) }
    if a.name != b.name { notes.append(CompareNote(label: "Project name", from: a.name, to: b.name)) }
    let listedTasks = tasks.filter { $0.status != "changed" || !$0.onlyDerived }
    let listedUids = Set(tasks.map { $0.uid })
    let summary = CompareSummary(
        added: tasks.filter { $0.status == "added" }.count,
        removed: tasks.filter { $0.status == "removed" }.count,
        changed: tasks.filter { $0.status == "changed" && !$0.onlyDerived }.count,
        rescheduled: tasks.filter { $0.status == "changed" && $0.onlyDerived }.count,
        unchanged: B.filter { !listedUids.contains($0.uid) }.count,
        identical: tasks.isEmpty && notes.isEmpty,
        listed: listedTasks.count)
    return CompareResult(summary: summary, tasks: tasks, notes: notes)
}

// MARK: - Tab-separated text, the way Excel and Numbers copy and paste cells

/// Read tab-separated text into rows of fields. Handles what Excel writes: a field that holds a tab, a line break or a quote is
/// wrapped in double quotes and a quote inside it is doubled. A single trailing line break does not make an extra row.
public func parseTSV(_ text: String?) -> [[String]] {
    let s = Array((text ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").unicodeScalars)
    if s.isEmpty { return [] }
    var rows: [[String]] = []
    var row: [String] = []
    var field = String.UnicodeScalarView()
    var i = 0
    let n = s.count
    func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
    func endRow() { endField(); rows.append(row); row = [] }
    while i < n {
        let ch = s[i]
        if ch == "\"" && field.isEmpty {
            // quoted field
            i += 1
            while i < n {
                if s[i] == "\"" {
                    if i + 1 < n && s[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    i += 1; break
                }
                field.append(s[i]); i += 1
            }
            // after the closing quote only a tab, a line break or the end is expected; anything else is kept as text
            while i < n && s[i] != "\t" && s[i] != "\n" { field.append(s[i]); i += 1 }
            continue
        }
        if ch == "\t" { endField(); i += 1; continue }
        if ch == "\n" { endRow(); i += 1; continue }
        field.append(ch); i += 1
    }
    if !field.isEmpty || !row.isEmpty { endRow() } // last line without a line break
    return rows
}

/// Rows of fields -> tab-separated text that spreadsheets read back into the same cells.
public func toTSV(_ rows: [[String]]) -> String {
    rows.map { r in
        r.map { v in v.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" || $0 == "\r\n" })
            ? "\"\(v.replacingOccurrences(of: "\"", with: "\"\""))\"" : v }.joined(separator: "\t")
    }.joined(separator: "\n")
}
