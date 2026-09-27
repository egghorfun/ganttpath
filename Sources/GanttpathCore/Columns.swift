// Table column definitions: what each column shows, how it is edited and how an edit is applied. Port of columns.js
// and the formatting helpers of util.js. An editable column has `edit` and `commit(text, ctx)`, which returns the change
// to run through Session.run, or throws ModelError(message) when the typed text cannot be understood.

import Foundation

// MARK: - display formatting (util.js)

/// Formatting that depends on the open project (date format, weekday setting) and its schedule (whether any task shows a time).
public struct Fmt: Sendable {
    public var settings: Settings
    public var timesShown: Bool
    public init(_ p: Project, _ sched: ScheduleResult?) {
        settings = p.settings
        timesShown = sched?.tasks.contains { $0.timed } ?? false
    }
    public var dateFormat: String { settings.dateFormat.isEmpty ? "DD-MMM-YYYY" : settings.dateFormat }
    /// Characters in the widest date the format can produce (a Wednesday in September), for sizing date columns.
    public var dateTextLen: Int {
        (settings.showWeekday ? 4 : 0) + formatDate(parseStamp("2026-09-30")!.dn, dateFormat).count + (timesShown ? 6 : 0)
    }
    /// Width of a date column.
    public var dateW: Double { max(96, jsRound(Double(dateTextLen) * 7 + 23)) }
    /// "30-Oct-2026 13:00": as typed and edited, no weekday.
    public func datePlain(_ stamp: String?) -> String {
        guard let s = stamp, !s.isEmpty, let st = parseStamp(s) else { return "" }
        return formatDate(st.dn, dateFormat) + (st.min.map { " \(fmtHM($0))" } ?? "")
    }
    /// "Fri 30-Oct-2026" (weekday unless switched off), plus the time when the stamp has one.
    public func date(_ stamp: String?) -> String {
        guard let s = stamp, !s.isEmpty, let st = parseStamp(s) else { return "" }
        return (settings.showWeekday ? "\(DOW_SHORT[dow(st.dn)]) " : "") + formatDate(st.dn, dateFormat) + (st.min.map { " \(fmtHM($0))" } ?? "")
    }
    public func dur(_ r: ScheduledTask) -> String { formatDuration(r.durationMin, r.durUnit, settings) }
    public func span(_ min: Int?) -> String { formatSpan(min, settings) }
    public func parseStampText(_ text: String) -> Stamp? { parseDateTimeInput(text, dateFormat) }
}

public func stampOf(_ iso: String?, _ min: Int?) -> String? {
    guard let iso = iso else { return nil }
    guard let m = min, let st = parseStamp(iso) else { return iso }
    return toStamp(st.dn, m)
}
public func rowLateStart(_ r: ScheduledTask) -> String? { r.timed ? stampOf(r.lateStart, r.lateStartMin) : r.lateStart }
public func rowLateFinish(_ r: ScheduledTask) -> String? { r.timed ? stampOf(r.lateFinish, r.lateFinishMin) : r.lateFinish }

public func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? one : many ?? one + "s")" }

/// Text of a JSON value as JS String(v) gives it.
func jsText(_ v: JSON?) -> String {
    guard let v = v else { return "" }
    switch v {
    case .null: return ""
    default: return v.jsString
    }
}

// MARK: - columns

public struct CellContext {
    public var project: Project
    public var sched: ScheduleResult
    public var index: Int
    public var fmt: Fmt
    /// Baseline chosen in the toolbar (-1 none).
    public var showBaseline: Int
    /// A second baseline to compare with the shown one (-1 none).
    public var compareBaseline: Int = -1
    /// Whether a sort, group, filter or search is active (a WBS edit needs the full outline).
    public var viewActive: Bool
    public var t: Task { project.tasks[index] }
    public var r: ScheduledTask { sched.tasks[index] }
    public var uid: Int { t.uid }
    public init(project: Project, sched: ScheduleResult, index: Int, fmt: Fmt? = nil, showBaseline: Int = -1, viewActive: Bool = false,
                compareBaseline: Int = -1) {
        self.project = project; self.sched = sched; self.index = index
        self.fmt = fmt ?? Fmt(project, sched); self.showBaseline = showBaseline; self.viewActive = viewActive
        self.compareBaseline = compareBaseline
    }
}

public typealias Change = (inout Project, ScheduleResult) throws -> Void

public struct ColumnEdit {
    public enum Kind: String, Sendable { case text, date, select, tags }
    public var kind: Kind
    public var prose = false
    public var noPaste = false
    public var clearable = true
    public var hint: String? = nil
    public var raw: (CellContext) -> String
    public var options: (Project) -> [(value: String, label: String)] = { _ in [] }
    public var disabled: (CellContext) -> Bool = { _ in false }
}

public struct ColumnDef {
    public enum Align: String, Sendable { case left, right, center }
    public var id: String
    public var title: String
    public var width: Double = 100
    public var align: Align = .left
    public var sortField: String? = nil
    public var hint: String? = nil
    public var isDate = false
    public var custom = false
    public var text: (CellContext) -> String
    /// Style class: "neg", "crit", "faint", "badge-sum", "badge-manual", "badge-auto" or "".
    public var cls: (CellContext) -> String = { _ in "" }
    public var tooltip: ((CellContext) -> String)? = nil
    public var edit: ColumnEdit? = nil
    public var commit: ((String, CellContext) throws -> Change)? = nil
    /// Set by the WBS column's change when it runs.
    public var editable: Bool { edit != nil }
}

let LOCKED_WHEN_INACTIVE: Set<String> = ["mode", "duration", "start", "finish", "preds", "pct", "constraint", "constraintDate", "calendar", "actualStart", "actualFinish"]
func needsDate(_ type: String) -> Bool { !(type == "ASAP" || type == "ALAP") }

func dateOrThrow(_ text: String, _ fmt: Fmt) throws -> String {
    guard let r = fmt.parseStampText(text) else {
        let ex = formatDate(parseISO("2026-10-05"), fmt.dateFormat)
        throw ModelError("\"\(text)\" is not a date. Try \(ex), or with a time \(ex) 13:00.")
    }
    return toStamp(r.dn, r.min)
}

func numberOrThrow(_ text: String, _ what: String) throws -> Double {
    var s = text
    if let r = s.range(of: "%") { s.replaceSubrange(r, with: "") }
    let v = jsNumberFromString(jsTrim(s))
    if !v.isFinite { throw ModelError("\(what) must be a number") }
    return v
}

/// Receives the result of the last WBS edit (the table shows a message from it).
public final class WbsResultBox: @unchecked Sendable {
    public var last: WbsResult?
    public init() {}
    public func take() -> WbsResult? { defer { last = nil }; return last }
}
public let wbsResultBox = WbsResultBox()

func trimmed(_ s: String) -> String { jsTrim(s) }

public func builtinColumns(_ project: Project, _ sched: ScheduleResult?) -> [ColumnDef] {
    let fmt = Fmt(project, sched)
    let dateW = fmt.dateW
    var C: [ColumnDef] = []
    func baselineNo(_ x: CellContext) -> Int { x.showBaseline >= 0 ? x.showBaseline : 0 }

    C.append(ColumnDef(id: "id", title: "ID", width: 46, align: .right, sortField: "id", hint: "Row number. Use it when typing predecessors.",
                       text: { String($0.index + 1) }))
    C.append(ColumnDef(id: "wbs", title: "WBS", width: 64, sortField: "wbs",
                       hint: "Work breakdown structure number, always in step with the outline. To add a level, double-click it and type the number you want, e.g. 4.7.1: the task (with its sub-tasks) moves under task 4.7 and everything is renumbered. Indent and Outdent do the same step by step.",
                       text: { $0.r.wbs },
                       edit: ColumnEdit(kind: .text, noPaste: true, hint: "Type the number the task should have, e.g. 4.7.1 (under task 4.7, as its first sub-task)", raw: { $0.r.wbs }),
                       commit: { v, x in
                           if x.viewActive { throw ModelError("Clear the sort, group, filter or search first: rows can only be moved in the full outline.") }
                           let uid = x.uid
                           return { p, _ in wbsResultBox.last = try setWbs(&p, uid, v) }
                       }))
    C.append(ColumnDef(id: "mode", title: "Task Mode", width: 84, sortField: "mode",
                       hint: "Task Mode. Auto = Ganttpath works out the dates from the links, constraints and calendar. Manual = the task keeps the dates you type and links do not move it. Change it here, with the Auto / Manual toolbar buttons, or in the panel on the right.",
                       text: { $0.r.isSummary ? "Summary" : $0.t.mode == "manual" ? "Manual" : "Auto" },
                       cls: { $0.r.isSummary ? "badge-sum" : $0.t.mode == "manual" ? "badge-manual" : "badge-auto" },
                       tooltip: { $0.r.isSummary ? "Summary task: its dates come from its sub-tasks" : $0.t.mode == "manual" ? "Manually scheduled: keeps the dates you type; links do not move it" : "Auto scheduled: dates come from the links, constraints and calendar" },
                       edit: ColumnEdit(kind: .select, raw: { $0.t.mode }, options: { _ in [("auto", "Auto scheduled"), ("manual", "Manually scheduled")] }, disabled: { $0.r.isSummary }),
                       commit: { v, x in let uid = x.uid; return { p, s in try setMode(&p, uid, v, s) } }))
    C.append(ColumnDef(id: "name", title: "Task Name", width: 270, sortField: "name", text: { $0.t.name },
                       edit: ColumnEdit(kind: .text, prose: true, raw: { $0.t.name }),
                       commit: { v, x in let uid = x.uid; return { p, _ in try setName(&p, uid, v) } }))
    C.append(ColumnDef(id: "duration", title: "Duration", width: 74, align: .right, sortField: "duration", text: { $0.fmt.dur($0.r) },
                       edit: ColumnEdit(kind: .text, hint: "Type 5 or 5d for days, 6h for hours, 30m for minutes, 2w for weeks, 1mo for months. Add e for elapsed time that runs round the clock, weekends included: 3ed, 12eh, 2ew. Type 0 for a milestone. Type \"month\" to cover the whole month of the start date.",
                                        raw: { $0.fmt.dur($0.r) }, disabled: { $0.r.isSummary }),
                       commit: { v, x in
                           let uid = x.uid
                           if trimmed(v).lowercased() == "month" {
                               let dn = parseISO(x.r.start) ?? parseISO(x.project.settings.startDate) ?? todayDn()
                               return { p, _ in try setMonthTask(&p, uid, dn) }
                           }
                           guard let d = parseDuration(v, x.project.settings, "d") else {
                               throw ModelError("\"\(v)\" is not a duration. Type a number of days (5), hours (6h), minutes (30m), weeks (2w), months (1mo), elapsed time (3ed, 12eh) or \"month\".")
                           }
                           return { p, _ in try setDuration(&p, uid, d) }
                       }))
    func clearCons(_ type: String, _ uid: Int) -> Change {
        return { p, _ in
            let i = indexOfUid(p, uid)
            if i < 0 { throw ModelError("That task no longer exists") }
            if p.tasks[i].mode == "auto" && p.tasks[i].constraint.type == type { p.tasks[i].constraint = .asap }
        }
    }
    C.append(ColumnDef(id: "start", title: "Start", width: dateW, sortField: "start", isDate: true, text: { $0.fmt.date($0.r.startStamp) },
                       edit: ColumnEdit(kind: .date, hint: "Automatic task: sets \"Start No Earlier Than\". Manual task: moves the task. Add a time to plan by the hour, e.g. 30-Oct-2026 13:00.",
                                        raw: { $0.fmt.datePlain($0.r.startStamp) }, disabled: { $0.r.isSummary }),
                       commit: { v, x in
                           if trimmed(v).isEmpty { return clearCons("SNET", x.uid) }
                           let st = try dateOrThrow(v, x.fmt); let uid = x.uid
                           return { p, _ in try setStart(&p, uid, st) }
                       }))
    C.append(ColumnDef(id: "finish", title: "Finish", width: dateW, sortField: "finish", isDate: true, text: { $0.fmt.date($0.r.finishStamp) },
                       edit: ColumnEdit(kind: .date, hint: "Automatic task: sets \"Finish No Earlier Than\". Manual task: changes the duration. Add a time to plan by the hour.",
                                        raw: { $0.fmt.datePlain($0.r.finishStamp) }, disabled: { $0.r.isSummary }),
                       commit: { v, x in
                           if trimmed(v).isEmpty { return clearCons("FNET", x.uid) }
                           let st = try dateOrThrow(v, x.fmt); let uid = x.uid
                           return { p, _ in try setFinish(&p, uid, st) }
                       }))
    C.append(ColumnDef(id: "preds", title: "Predecessors", width: 120, text: { formatPredecessors($0.t.preds, uidToIdMap($0.project)) },
                       edit: ColumnEdit(kind: .text, hint: "Row IDs with type and lag, e.g. 3, 5SS+2d, 7FF-25%, 9FS+1w", raw: { formatPredecessors($0.t.preds, uidToIdMap($0.project)) }),
                       commit: { v, x in
                           let r = parsePredecessors(v, idToUidMap(x.project))
                           if let e = r.errors.first { throw ModelError(e) }
                           let uid = x.uid, preds = r.preds
                           return { p, _ in try setPredecessors(&p, uid, preds) }
                       }))
    C.append(ColumnDef(id: "succs", title: "Successors", width: 110, text: { x in
        let m = uidToIdMap(x.project)
        var out: [String] = []
        for L in x.sched.links where L.pIndex == x.index {
            let id = m(L.uid).map(String.init) ?? "undefined"
            let lag = L.lag.v != 0 ? "\(L.lag.v > 0 ? "+" : "")\(jsNumberString(L.lag.v))\(L.lag.u)" : ""
            out.append("\(id)\(L.type == "FS" && lag.isEmpty ? "" : L.type)\(lag)")
        }
        return out.joined(separator: ", ")
    }))
    C.append(ColumnDef(id: "pct", title: "% Complete", width: 96, align: .right, sortField: "pct", text: { "\(jsNumberString(jsRound($0.r.pct)))%" },
                       edit: ColumnEdit(kind: .text, raw: { jsNumberString(jsRound($0.r.pct)) }, disabled: { $0.r.isSummary }),
                       commit: { v, x in let n = try numberOrThrow(v, "% complete"); let uid = x.uid; return { p, s in try setPercent(&p, uid, n, s) } }))
    C.append(ColumnDef(id: "totalSlack", title: "Total Slack", width: 84, align: .right, sortField: "totalSlack",
                       text: { $0.r.totalSlackMin == nil ? "" : $0.fmt.span($0.r.totalSlackMin) },
                       cls: { ($0.r.totalSlackMin ?? 0) < 0 ? "neg" : "" }))
    C.append(ColumnDef(id: "freeSlack", title: "Free Slack", width: 84, align: .right, sortField: "freeSlack",
                       text: { $0.r.freeSlackMin == nil ? "" : $0.fmt.span($0.r.freeSlackMin) }))
    C.append(ColumnDef(id: "critical", title: "Critical", width: 62, align: .center, text: { $0.r.critical ? "Yes" : "" }, cls: { $0.r.critical ? "crit" : "" }))
    C.append(ColumnDef(id: "lateStart", title: "Late Start", width: dateW, isDate: true, text: { $0.fmt.date(rowLateStart($0.r)) }))
    C.append(ColumnDef(id: "lateFinish", title: "Late Finish", width: dateW, isDate: true, text: { $0.fmt.date(rowLateFinish($0.r)) }))
    C.append(ColumnDef(id: "constraint", title: "Constraint", width: 172, text: { $0.r.isSummary ? "" : CONSTRAINT_NAMES[$0.t.constraint.type] ?? "" },
                       edit: ColumnEdit(kind: .select, raw: { $0.t.constraint.type }, options: { _ in CONSTRAINTS.map { ($0, CONSTRAINT_NAMES[$0]!) } }, disabled: { $0.r.isSummary }),
                       commit: { v, x in
                           let uid = x.uid, rStart = x.r.start
                           return { p, _ in
                               let i = indexOfUid(p, uid)
                               if i < 0 { throw ModelError("That task no longer exists") }
                               let date = needsDate(v) ? (p.tasks[i].constraint.date ?? rStart ?? p.settings.startDate) : nil
                               try setConstraint(&p, uid, v, date)
                           }
                       }))
    C.append(ColumnDef(id: "constraintDate", title: "Constraint Date", width: dateW + 8, isDate: true,
                       text: { $0.r.isSummary || !needsDate($0.t.constraint.type) ? "" : $0.fmt.date($0.t.constraint.date) },
                       edit: ColumnEdit(kind: .date, clearable: false, raw: { $0.fmt.datePlain($0.t.constraint.date) }, disabled: { $0.r.isSummary || !needsDate($0.t.constraint.type) }),
                       commit: { v, x in
                           let st = try dateOrThrow(v, x.fmt); let uid = x.uid
                           return { p, _ in
                               let i = indexOfUid(p, uid)
                               if i < 0 { throw ModelError("That task no longer exists") }
                               try setConstraint(&p, uid, p.tasks[i].constraint.type, st)
                           }
                       }))
    C.append(ColumnDef(id: "deadline", title: "Deadline", width: dateW, sortField: "deadline", isDate: true, text: { $0.fmt.date($0.t.deadline) },
                       edit: ColumnEdit(kind: .date, hint: "A deadline never moves the task. It only turns red when the finish is later.", raw: { $0.fmt.datePlain($0.t.deadline) }),
                       commit: { v, x in
                           let uid = x.uid
                           if trimmed(v).isEmpty { return { p, _ in try setDeadline(&p, uid, nil) } }
                           let st = try dateOrThrow(v, x.fmt)
                           return { p, _ in try setDeadline(&p, uid, st) }
                       }))
    C.append(ColumnDef(id: "actualStart", title: "Actual Start", width: dateW, isDate: true, text: { $0.fmt.date($0.t.actualStart) },
                       edit: ColumnEdit(kind: .date, raw: { $0.fmt.datePlain($0.t.actualStart) }, disabled: { $0.r.isSummary }),
                       commit: { v, x in
                           let st = trimmed(v).isEmpty ? nil : try dateOrThrow(v, x.fmt); let uid = x.uid
                           return { p, _ in
                               let i = indexOfUid(p, uid)
                               if i < 0 { throw ModelError("That task no longer exists") }
                               try setActualDates(&p, uid, st, p.tasks[i].actualFinish)
                               if st != nil && p.tasks[i].pct == 0 { p.tasks[i].pct = 1 }
                           }
                       }))
    C.append(ColumnDef(id: "actualFinish", title: "Actual Finish", width: dateW, isDate: true, text: { $0.fmt.date($0.t.actualFinish) },
                       edit: ColumnEdit(kind: .date, raw: { $0.fmt.datePlain($0.t.actualFinish) }, disabled: { $0.r.isSummary }),
                       commit: { v, x in
                           let st = trimmed(v).isEmpty ? nil : try dateOrThrow(v, x.fmt); let uid = x.uid
                           return { p, _ in
                               let i = indexOfUid(p, uid)
                               if i < 0 { throw ModelError("That task no longer exists") }
                               let a = p.tasks[i].actualStart
                               try setActualDates(&p, uid, (a?.isEmpty == false) ? a : st, st)
                           }
                       }))
    C.append(ColumnDef(id: "calendar", title: "Calendar", width: 120,
                       text: { x in x.t.calendarId.flatMap { id in x.project.calendars.first { $0.id == id }?.name } ?? "" },
                       edit: ColumnEdit(kind: .select, raw: { $0.t.calendarId ?? "" }, options: { p in [("", "(project calendar)")] + p.calendars.map { ($0.id, $0.name) } }, disabled: { $0.r.isSummary }),
                       commit: { v, x in let uid = x.uid; return { p, _ in try setTaskCalendar(&p, uid, v.isEmpty ? nil : v) } }))
    C.append(ColumnDef(id: "priority", title: "Priority", width: 74, align: .right, sortField: "priority", text: { String($0.r.priority) },
                       edit: ColumnEdit(kind: .text, hint: "0 to 1000. 500 is normal. It is kept and exchanged with MS Project and Excel; it does not move any date because Ganttpath has no resource levelling.", raw: { String($0.r.priority) }),
                       commit: { v, x in let uid = x.uid; return { p, _ in try setPriority(&p, uid, v) } }))
    C.append(ColumnDef(id: "taskType", title: "Task Type", width: 108, sortField: "taskType", text: { TASK_TYPE_NAMES[$0.r.taskType] ?? TASK_TYPE_NAMES["fixedUnits"]! },
                       edit: ColumnEdit(kind: .select, hint: "Fixed Units, Fixed Duration or Fixed Work. It only matters when resources are used, so it changes no date here. It is kept and exchanged with MS Project.",
                                        raw: { $0.r.taskType.isEmpty ? "fixedUnits" : $0.r.taskType }, options: { _ in TASK_TYPES.map { ($0, TASK_TYPE_NAMES[$0]!) } }),
                       commit: { v, x in let uid = x.uid; return { p, _ in try setTaskType(&p, uid, v) } }))
    func flag(_ r: ScheduledTask, _ key: String) -> Bool {
        switch key { case "inactive": return r.inactive; case "onTimeline": return r.onTimeline; case "hideBar": return r.hideBar; default: return r.rollup }
    }
    func flagCol(_ id: String, _ title: String, _ width: Double, _ hint: String, _ disabled: ((CellContext) -> Bool)? = nil) {
        C.append(ColumnDef(id: id, title: title, width: width, align: .center, sortField: id, text: { flag($0.r, id) ? "Yes" : "No" }, cls: { flag($0.r, id) ? "" : "faint" },
                           edit: ColumnEdit(kind: .select, hint: hint, raw: { flag($0.r, id) ? "yes" : "" }, options: { _ in [("", "No"), ("yes", "Yes")] }, disabled: disabled ?? { _ in false }),
                           commit: { v, x in let uid = x.uid; return { p, _ in try setTaskFlag(&p, uid, id, v == "yes") } }))
    }
    flagCol("inactive", "Inactive", 70, "An inactive task stays in the plan but takes no part in the schedule: it keeps its dates, its links are ignored, and it is left out of summaries, the project finish and the S-curve.", { $0.r.isSummary })
    flagCol("onTimeline", "On Timeline", 84, "Show this task on the Timeline view.")
    flagCol("hideBar", "Hide Bar", 70, "Do not draw this task's bar on the Gantt chart (the row and its dates stay).")
    flagCol("rollup", "Roll Up Bar", 84, "Draw this task's bar on its summary task's bar (seen when the summary task is collapsed, as in MS Project).")
    C.append(ColumnDef(id: "weight", title: "Weight", width: 70, align: .right, text: { $0.t.weight.map(jsNumberString) ?? "" },
                       edit: ColumnEdit(kind: .text, hint: "S-curve weight. Empty = use the duration.", raw: { $0.t.weight.map(jsNumberString) ?? "" }),
                       commit: { v, x in let uid = x.uid; let w: String? = trimmed(v).isEmpty ? nil : v; return { p, _ in try setWeight(&p, uid, w) } }))
    C.append(ColumnDef(id: "tags", title: "Tags", width: 130, text: { $0.t.tags.joined(separator: ", ") },
                       edit: ColumnEdit(kind: .tags, raw: { $0.t.tags.joined(separator: ", ") })))
    C.append(ColumnDef(id: "notes", title: "Notes", width: 170, text: { collapseWhitespace($0.t.notes) },
                       edit: ColumnEdit(kind: .text, prose: true, raw: { $0.t.notes }),
                       commit: { v, x in let uid = x.uid; return { p, _ in try setNotes(&p, uid, v) } }))
    func bl(_ x: CellContext) -> Baseline? { let n = baselineNo(x); return n < x.t.baselines.count ? x.t.baselines[n] : nil }
    C.append(ColumnDef(id: "baselineStart", title: "Baseline Start", width: dateW + 4, isDate: true, text: { $0.fmt.date(bl($0)?.start) }))
    C.append(ColumnDef(id: "baselineFinish", title: "Baseline Finish", width: dateW + 4, isDate: true, text: { $0.fmt.date(bl($0)?.finish) }))
    C.append(ColumnDef(id: "startVar", title: "Start Variance", width: 96, align: .right,
                       text: { x in variance(x, bl(x), start: true).map { x.fmt.span($0) } ?? "" },
                       cls: { x in (variance(x, bl(x), start: true) ?? 0) > 0 ? "neg" : "" }))
    C.append(ColumnDef(id: "finishVar", title: "Finish Variance", width: 100, align: .right,
                       text: { x in variance(x, bl(x), start: false).map { x.fmt.span($0) } ?? "" },
                       cls: { x in (variance(x, bl(x), start: false) ?? 0) > 0 ? "neg" : "" }))
    // a second baseline compared with the shown one (Project > Baselines, or the toolbar's Baseline menu)
    func cmp(_ x: CellContext) -> Baseline? {
        let n = x.compareBaseline
        return n >= 0 && n != baselineNo(x) && n < x.t.baselines.count ? x.t.baselines[n] : nil
    }
    C.append(ColumnDef(id: "cmpBaselineStart", title: "Compared Baseline Start", width: dateW + 30, isDate: true, text: { $0.fmt.date(cmp($0)?.start) }))
    C.append(ColumnDef(id: "cmpBaselineFinish", title: "Compared Baseline Finish", width: dateW + 34, isDate: true, text: { $0.fmt.date(cmp($0)?.finish) }))
    C.append(ColumnDef(id: "baselineStartShift", title: "Baseline Start Shift", width: 120, align: .right,
                       text: { x in baselineShift(x, bl(x), cmp(x), start: true).map { x.fmt.span($0) } ?? "" },
                       cls: { x in (baselineShift(x, bl(x), cmp(x), start: true) ?? 0) > 0 ? "neg" : "" }))
    C.append(ColumnDef(id: "baselineFinishShift", title: "Baseline Finish Shift", width: 124, align: .right,
                       text: { x in baselineShift(x, bl(x), cmp(x), start: false).map { x.fmt.span($0) } ?? "" },
                       cls: { x in (baselineShift(x, bl(x), cmp(x), start: false) ?? 0) > 0 ? "neg" : "" }))
    // An inactive task is frozen: what shapes its dates cannot be edited until it is made active again.
    for k in C.indices where LOCKED_WHEN_INACTIVE.contains(C[k].id) {
        guard var e = C[k].edit else { continue }
        let was = e.disabled
        e.disabled = { x in x.r.inactive || was(x) }
        C[k].edit = e
    }
    return C
}

func collapseWhitespace(_ s: String) -> String {
    var out = ""
    var inWs = false
    for u in s.unicodeScalars {
        if jsWhitespace.contains(u) { if !inWs { out.unicodeScalars.append(" ") }; inWs = true }
        else { out.unicodeScalars.append(u); inWs = false }
    }
    return out
}

/// A baseline start (or finish) as a tick in the task's calendar.
func baselineTick(_ x: CellContext, _ b: Baseline, start: Bool) -> Int? {
    let cal = calendarOf(x.project, x.t)
    guard let st = parseStamp((start ? b.start : b.finish) ?? "") else { return nil }
    if let m = st.min { return st.dn * 1440 + m }
    return start ? cal.normStart(st.dn * 1440) : cal.normFinish((st.dn + 1) * 1440)
}

/// Working minutes from one baseline's start (or finish) to another's; positive = the compared baseline is later.
public func baselineShift(_ x: CellContext, _ from: Baseline?, _ to: Baseline?, start: Bool) -> Int? {
    guard let a = from, let b = to, let ta = baselineTick(x, a, start: start), let tb = baselineTick(x, b, start: start) else { return nil }
    let cal = calendarOf(x.project, x.t)
    return cal.posOf(tb) - cal.posOf(ta)
}

/// Working minutes between baseline and current start (or finish); positive = later than planned.
func variance(_ x: CellContext, _ b: Baseline?, start: Bool) -> Int? {
    guard let b = b, x.r.start != nil else { return nil }
    let cal = calendarOf(x.project, x.t)
    func tick(_ stamp: String?, _ end: Bool) -> Int? {
        guard let st = parseStamp(stamp ?? "") else { return nil }
        if let m = st.min { return st.dn * 1440 + m }
        return end ? cal.normFinish((st.dn + 1) * 1440) : cal.normStart(st.dn * 1440)
    }
    let base = start ? tick(b.start, false) : tick(b.finish, true)
    let now = start ? tick(x.r.startStamp, false) : tick(x.r.finishStamp, true)
    guard let a = base, let n = now else { return nil }
    return cal.posOf(n) - cal.posOf(a)
}

/// Columns whose cell may be emptied (Delete key, or pasting an empty cell); the others always hold a value.
public let EMPTIABLE = ["start", "finish", "preds", "deadline", "weight", "notes", "actualStart", "actualFinish"]
public func isEmptiable(_ c: ColumnDef) -> Bool { EMPTIABLE.contains(c.id) || c.custom }
public let DEFAULT_COLUMNS = ["id", "wbs", "mode", "name", "duration", "start", "finish", "preds", "pct", "totalSlack"]
public func isCustomColumnId(_ id: String) -> Bool { id.hasPrefix("custom:") }

/// Built-in columns plus one per custom column of the project.
public func allColumns(_ project: Project, _ sched: ScheduleResult?) -> [ColumnDef] {
    var cols = builtinColumns(project, sched)
    let fmt = Fmt(project, sched)
    for c in project.customColumns {
        let isNum = c.type == "number", isDate = c.type == "date", isFlag = c.type == "flag", isList = c.type == "list"
        let cid = c.id
        let edit: ColumnEdit
        if isList {
            edit = ColumnEdit(kind: .select, raw: { jsText($0.t.custom[cid]) }, options: { _ in [("", "")] + c.options.map { ($0, $0) } })
        } else if isFlag {
            edit = ColumnEdit(kind: .select, raw: { ($0.t.custom[cid]?.truthy ?? false) ? "yes" : "" }, options: { _ in [("", ""), ("yes", "Yes")] })
        } else {
            edit = ColumnEdit(kind: isDate ? .date : .text, prose: !isDate && !isNum, raw: { x in isDate ? x.fmt.datePlain(x.t.custom[cid]?.string) : jsText(x.t.custom[cid]) })
        }
        cols.append(ColumnDef(id: "custom:\(cid)", title: c.name, width: isFlag ? 70 : isDate ? fmt.dateW : 120, align: isNum ? .right : isFlag ? .center : .left,
                              sortField: "custom:\(cid)", isDate: isDate, custom: true,
                              text: { x in
                                  let v = x.t.custom[cid]
                                  if isFlag { return (v?.truthy ?? false) ? "Yes" : "" }
                                  if isDate { return x.fmt.date(v?.string) }
                                  return jsText(v)
                              },
                              edit: edit,
                              commit: { v, x in
                                  let uid = x.uid
                                  if isDate && !trimmed(v).isEmpty {
                                      let st = try dateOrThrow(v, x.fmt)
                                      return { p, _ in try setCustomValue(&p, uid, cid, .string(String(st.prefix(10)))) }
                                  }
                                  if isFlag { return { p, _ in try setCustomValue(&p, uid, cid, .bool(v == "yes")) } }
                                  return { p, _ in try setCustomValue(&p, uid, cid, .string(v)) }
                              }))
    }
    return cols
}

/// The columns to show, in order, for the saved column list (nil or empty = the standard set), with saved widths.
public func visibleColumns(_ project: Project, _ sched: ScheduleResult?, ids: [String]?, widths: [String: Double] = [:]) -> [ColumnDef] {
    let all = allColumns(project, sched)
    let want = (ids?.isEmpty == false) ? ids! : DEFAULT_COLUMNS
    var byId: [String: ColumnDef] = [:]
    for c in all { byId[c.id] = c }
    var out = want.compactMap { byId[$0] }
    if out.isEmpty, let n = byId["name"] { out = [n] }
    return out.map { c in var c = c; if let w = widths[c.id] { c.width = w }; return c }
}

/// New saved column list after showing or hiding one column (the Task Name column cannot be hidden).
public func columnIdsAfter(_ project: Project, current: [String]?, _ id: String, shown: Bool) -> [String] {
    let all = allColumns(project, nil).map { $0.id }
    var cur = Set((current?.isEmpty == false) ? current! : DEFAULT_COLUMNS)
    if shown { cur.insert(id) } else if id != "name" { cur.remove(id) }
    return all.filter { cur.contains($0) || $0 == "name" }
}
