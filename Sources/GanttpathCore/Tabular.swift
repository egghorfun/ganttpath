// Spreadsheet-style import/export shared by Excel (.xlsx) and CSV.
//
//   projectToTable(project, sched) -> (headers, rows)
//   tableToProject(rows, options)  -> (project, report)        (rows: 2-D array, first row = headers)

import Foundation

let BASE_HEADERS = [
    "ID", "WBS", "Outline Level", "Task Name", "Mode", "Duration", "Start", "Finish", "Predecessors",
    "Constraint", "Constraint Date", "Deadline", "% Complete", "Actual Start", "Actual Finish", "Milestone", "Summary",
    "Calendar", "Total Slack (days)", "Free Slack (days)", "Critical", "Baseline Start", "Baseline Finish", "Weight", "Tags", "Notes",
    "Priority", "Task Type", "Inactive", "Display on Timeline", "Hide Task Bar", "Roll Up Gantt Bar",
]

/// A stored date or moment as a cell: a real Excel date for a whole day, text 'YYYY-MM-DD HH:MM' when a time matters.
func dnOrNull(_ iso: String?) -> Cell {
    guard let st = parseStamp(iso ?? "") else { return .empty }
    return st.min == nil ? .date(st.dn) : .text("\(toISO(st.dn)) \(fmtHM(st.min!))")
}
private func num(_ v: Double?) -> Cell { v.map { .number($0) } ?? .empty }

public struct Table { public var headers: [String]; public var rows: [[Cell]] }

public func projectToTable(_ project: Project, _ sched: ScheduleResult) -> Table {
    let uidToId = uidToIdMap(project)
    func calName(_ id: String?) -> String { nonEmpty(id).map { i in project.calendars.first { $0.id == i }?.name ?? "" } ?? "" }
    let headers = BASE_HEADERS + project.customColumns.map { $0.name }
    let rows: [[Cell]] = project.tasks.enumerated().map { (i, t) in
        let r = sched.tasks[i]
        let b0 = t.baselines.first ?? nil
        var base: [Cell] = [
            .number(Double(i + 1)), .text(r.wbs), .number(Double(t.level)), .text(t.name),
            .text(r.isSummary ? "Summary" : t.mode == "manual" ? "Manual" : "Auto"),
            r.durUnit == "d" || r.isSummary ? .number(jsRound(r.duration * 100) / 100) : .text(formatDuration(r.durationMin, r.durUnit, project.settings)),
            dnOrNull(r.startStamp), dnOrNull(r.finishStamp),
            .text(formatPredecessors(t.preds, uidToId)),
            .text(r.isSummary ? "" : (CONSTRAINT_NAMES[t.constraint.type.isEmpty ? "ASAP" : t.constraint.type] ?? "")),
            dnOrNull(t.constraint.date), dnOrNull(t.deadline),
            .number(jsRound(r.pct)), dnOrNull(t.actualStart), dnOrNull(t.actualFinish),
            .text(r.isMilestone ? "Yes" : ""), .text(r.isSummary ? "Yes" : ""),
            .text(calName(t.calendarId)),
            num(r.totalSlack), num(r.freeSlack), .text(r.critical ? "Yes" : "No"),
            dnOrNull(b0?.start), dnOrNull(b0?.finish),
            num(t.weight), .text(t.tags.joined(separator: "; ")), .text(t.notes),
            .number(Double(t.priority)), .text(TASK_TYPE_NAMES[t.taskType] ?? TASK_TYPE_NAMES["fixedUnits"]!),
            .text(t.inactive ? "Yes" : ""), .text(t.onTimeline ? "Yes" : ""), .text(t.hideBar ? "Yes" : ""), .text(t.rollup ? "Yes" : ""),
        ]
        for c in project.customColumns {
            let v = t.custom[c.id]
            if c.type == "date" { base.append(dnOrNull(v?.string)) }
            else if c.type == "flag" { base.append(.text((v?.truthy ?? false) ? "Yes" : "")) }
            else {
                switch v {
                case .string(let s)?: base.append(.text(s))
                case .number(let n)?: base.append(.number(n))
                case .bool(let b)?: base.append(.bool(b))
                default: base.append(.empty)
                }
            }
        }
        return base
    }
    return Table(headers: headers, rows: rows)
}

let DAY_ABBR = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

/// Extra sheets that make an Excel export re-importable without losing calendars and settings.
public func projectInfoSheets(_ project: Project) -> (projectRows: [[Cell]], calRows: [[Cell]]) {
    let S = project.settings
    let defCal = project.calendars.first { $0.id == S.defaultCalendarId } ?? project.calendars[0]
    let projectRows: [[Cell]] = [
        [.text("Setting"), .text("Value")],
        [.text("Project name"), .text(project.name)],
        [.text("Project start"), dnOrNull(S.startDate)],
        [.text("Status date"), dnOrNull(S.statusDate)],
        [.text("Project calendar"), .text(defCal.name)],
        [.text("Country (holidays)"), .text(S.country)],
        [.text("Critical slack (days)"), .number(S.criticalSlackDays)],
        [.text("Hours per day"), .number(S.hoursPerDay)],
        [.text("Hours per week"), .number(S.hoursPerWeek)],
        [.text("Days per month"), .number(S.daysPerMonth)],
        [.text("Honour constraint dates"), .text(S.honorConstraints == false ? "No" : "Yes")],
    ]
    var calRows: [[Cell]] = [[.text("Calendar"), .text("Kind"), .text("From"), .text("To"), .text("Detail")]]
    for c in project.calendars {
        let cal = Cal(c)
        calRows.append([.text(c.name), .text("Work week"), .empty, .empty, .text(c.workWeek.enumerated().compactMap { $0.element ? DAY_ABBR[$0.offset] : nil }.joined(separator: ", "))])
        for (i, w) in c.workWeek.enumerated() where w && i < 7 { calRows.append([.text(c.name), .text("Hours"), .empty, .empty, .text("\(DAY_ABBR[i]): \(formatPeriods(cal.weekPeriods[i]))")]) }
        for e in c.exceptions {
            let per = e.working && !(e.periods ?? []).isEmpty ? " (hours: \(formatPeriods(normPeriodsKeepOrder(e.periods!))))" : ""
            calRows.append([.text(c.name), .text(e.working ? "Working day" : "Non-working"), dnOrNull(e.from), dnOrNull(nonEmpty(e.to) ?? e.from), .text(e.name + per)])
        }
    }
    return (projectRows, calRows)
}

/// The periods exactly as stored (the JavaScript app prints e.periods as they are in the file).
func normPeriodsKeepOrder(_ p: [RawPeriod]) -> [Period] {
    p.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }.map { Period(Int($0[0]), Int($0[1])) }
}

/// Table cells -> plain strings for CSV.
public func tableToCsvRows(_ table: Table) -> [[String]] {
    [table.headers] + table.rows.map { $0.map { $0.csvText } }
}

// MARK: - import

let ALIASES: [(String, [String])] = [
    ("id", ["id", "task id", "no", "no.", "#", "row", "row id", "activity id", "item"]),
    ("wbs", ["wbs", "wbs code", "outline number", "outline no"]),
    ("level", ["outline level", "level", "lvl", "indent", "outline"]),
    ("name", ["task name", "name", "activity", "activity name", "task", "description", "title", "activity description"]),
    ("mode", ["mode", "task mode", "scheduling", "scheduling mode", "schedule mode"]),
    ("duration", ["duration", "duration (days)", "dur", "days", "original duration", "planned duration", "dur (days)"]),
    ("start", ["start", "start date", "planned start", "begin", "early start"]),
    ("finish", ["finish", "finish date", "end", "end date", "planned finish", "early finish"]),
    ("preds", ["predecessors", "predecessor", "preds", "depends on", "dependencies", "dependency"]),
    ("ctype", ["constraint", "constraint type"]),
    ("cdate", ["constraint date"]),
    ("deadline", ["deadline"]),
    ("pct", ["% complete", "percent complete", "pct", "progress", "% done", "complete", "% comp"]),
    ("astart", ["actual start"]),
    ("afinish", ["actual finish"]),
    ("milestone", ["milestone"]),
    ("summary", ["summary"]),
    ("calendar", ["calendar", "task calendar"]),
    ("tags", ["tags", "tag"]),
    ("notes", ["notes", "comments", "remarks", "note"]),
    ("weight", ["weight"]),
    ("priority", ["priority"]),
    ("taskType", ["task type"]),
    ("inactive", ["inactive"]),
    ("onTimeline", ["display on timeline", "on timeline"]),
    ("hideBar", ["hide task bar", "hide bar"]),
    ("rollup", ["roll up gantt bar", "roll up", "rollup"]),
]
// read-only columns from our own export: recognised so they are not turned into custom columns
let ALIAS_IGNORE: Set<String> = ["total slack (days)", "free slack (days)", "critical", "baseline start", "baseline finish", "total slack", "free slack", "slack"]

/// A cell value as read from a CSV (always text) or an Excel sheet (text, number, boolean or empty).
public typealias TableValue = SheetValue

func normText(_ v: TableValue?) -> String {
    guard let v = v else { return "" }
    return jsTrim(v.asString).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        .replacingOccurrences(of: "\u{0000}", with: "")
}
/// JavaScript's norm() collapses runs of white space into single spaces; leading/trailing space is removed by trim().
func normS(_ s: String?) -> String {
    let t = jsTrim(s ?? "").lowercased()
    var out = ""
    var inWS = false
    for u in t.unicodeScalars {
        if jsWhitespace.contains(u) { if !inWS { out += " "; inWS = true } } else { out.unicodeScalars.append(u); inWS = false }
    }
    return out
}
func normV(_ v: TableValue?) -> String { normS(v?.asString) }

let CONSTRAINT_BY_NAME: [String: String] = {
    var m: [String: String] = [:]
    for (k, v) in CONSTRAINT_NAMES { m[normS(v)] = k; m[normS(k)] = k }
    for (k, v) in ["as soon as possible": "ASAP", "as late as possible": "ALAP", "asap": "ASAP", "alap": "ALAP", "": "ASAP"] { m[k] = v }
    return m
}()

func yes(_ v: TableValue?) -> Bool {
    guard let v = v else { return false }
    if case .bool(true) = v { return true }
    let s = jsTrim(v.asString).lowercased()
    return ["y", "yes", "true", "1", "x", "✓"].contains(s)
}

/// "5", "5d", "5 days", "2w", "1 mo", "8h", "45m", "3 days?" -> (min, unit), or nil.
/// A plain number is days (a spreadsheet's "Duration" column holds days unless it says otherwise).
public func parseDurationText(_ v: TableValue?, _ settings: Settings) -> DurationSpec? {
    guard let v = v else { return nil }
    if case .number(let n) = v { return n.isFinite && n >= 0 ? DurationSpec(min: jsRoundInt(n * Double(dayMinOf(settings))), unit: "d") : nil }
    if case .text(let s) = v, s.isEmpty { return nil }
    var text = jsTrim(v.asString).lowercased()
    if text.hasSuffix("?") { text.removeLast() }
    // /(\d)\s*(ed|edays|eday)$/ -> '$1d'
    for suf in ["edays", "eday", "ed"] where text.hasSuffix(suf) {
        var head = String(text.dropLast(suf.count))
        while let l = head.unicodeScalars.last, jsWhitespace.contains(l) { head.unicodeScalars.removeLast() }
        if let l = head.last, l.isASCII && l.isNumber { text = head + "d" }
        break
    }
    return parseDuration(text, settings, "d")
}

/// Working minutes from a start to a finish given as dates (or moments) in calendar `cal`.
func spanMinutes(_ cal: Cal, _ a: String, _ b: String) -> Int {
    guard let sa = parseStamp(a), let sb = parseStamp(b) else { return 0 }
    let s = cal.normStart(sa.dn * 1440 + (sa.min ?? 0))
    let f = cal.normFinish(sb.min == nil ? (sb.dn + 1) * 1440 : sb.dn * 1440 + sb.min!)
    return max(0, cal.posOf(f) - cal.posOf(s))
}

/// A date cell with an optional time -> stamp ('YYYY-MM-DD' or 'YYYY-MM-DDTHH:MM'), or bad when it cannot be read.
func toIsoCell(_ v: TableValue?, _ dateFormat: String) -> (iso: String?, bad: Bool) {
    guard let v = v else { return (nil, false) }
    if case .text(let s) = v, s.isEmpty { return (nil, false) }
    if case .number = v { return (nil, true) }
    guard let r = parseDateTimeInput(v.asString, dateFormat) else { return (nil, true) }
    return (toStamp(r.dn, r.min), false)
}

private func applyProjectInfo(_ project: inout Project, _ projectSheet: [[TableValue?]]?, _ calendarSheet: [[TableValue?]]?, _ dateFormat: String) -> (startDate: String?, name: String?, calendars: Int) {
    var info: (startDate: String?, name: String?, calendars: Int) = (nil, nil, 0)
    func cell(_ r: [TableValue?], _ i: Int) -> TableValue? { i < r.count ? r[i] : nil }
    if let cs = calendarSheet, cs.count > 1 {
        var order: [String] = []
        var defs: [String: (def: CalendarDef, hoursByDay: [Int: [Period]])] = [:]
        for r in cs.dropFirst() {
            let name = jsTrim(cell(r, 0)?.asString ?? "")
            if name.isEmpty { continue }
            if defs[name] == nil { order.append(name); defs[name] = (CalendarDef(id: "c\(order.count)", name: name, workWeek: MON_FRI), [:]) }
            let kind = normV(cell(r, 1))
            if kind == "work week" {
                let days = (cell(r, 4)?.asString ?? "").lowercased()
                defs[name]!.def.workWeek = DAY_ABBR.map { days.contains($0.lowercased()) }
            } else if kind == "hours" {
                let d = cell(r, 4)?.asString ?? ""
                // /^\s*([A-Za-z]{3})\s*:\s*(.*)$/
                let t = d.drop { $0.isWhitespace }
                if t.count >= 3, t.prefix(3).allSatisfy({ $0.isASCII && $0.isLetter }) {
                    var rest = t.dropFirst(3).drop { $0.isWhitespace }
                    if rest.first == ":" {
                        rest = rest.dropFirst().drop { $0.isWhitespace }
                        let di = DAY_ABBR.firstIndex { $0.lowercased() == t.prefix(3).lowercased() } ?? -1
                        if di >= 0, let per = parsePeriods(String(rest)), !per.isEmpty { defs[name]!.hoursByDay[di] = per }
                    }
                }
            } else if kind == "working day" || kind == "non-working" {
                let f = parseDateInput(cell(r, 2)?.asString ?? "", dateFormat)
                let tv = cell(r, 3) ?? cell(r, 2)
                let t = parseDateInput(tv?.asString ?? "", dateFormat)
                if let f = f {
                    var nm = cell(r, 4)?.asString ?? ""
                    var periods: [Period]? = nil
                    // /\s*\(hours: ([^)]*)\)\s*$/
                    if let open = nm.range(of: "(hours: ", options: .backwards), nm.hasSuffix(")") || jsTrim(nm).hasSuffix(")") {
                        let inner = nm[open.upperBound...].prefix { $0 != ")" }
                        let afterInner = nm[nm.index(open.upperBound, offsetBy: inner.count)...]
                        if afterInner.first == ")" && jsTrim(String(afterInner.dropFirst())).isEmpty {
                            let per = parsePeriods(String(inner))
                            periods = (per?.isEmpty ?? true) ? nil : per
                            var head = String(nm[..<open.lowerBound])
                            while let l = head.unicodeScalars.last, jsWhitespace.contains(l) { head.unicodeScalars.removeLast() }
                            nm = head
                        }
                    }
                    defs[name]!.def.exceptions.append(CalException(from: toISO(f), to: toISO(t ?? f), working: kind == "working day", name: nm,
                                                                   periods: periods.map { $0.map { [Double($0.s), Double($0.e)] } }))
                }
            }
        }
        for n in order {
            var d = defs[n]!
            if !d.hoursByDay.isEmpty {
                d.def.hours = (0..<7).map { i in d.def.workWeek[i] && d.hoursByDay[i] != nil ? d.hoursByDay[i]!.map { [Double($0.s), Double($0.e)] } : [] }
            }
            defs[n] = d
        }
        if !order.isEmpty { project.calendars = order.map { defs[$0]!.def }; info.calendars = order.count }
    }
    if let ps = projectSheet, ps.count > 1 {
        var kv: [String: TableValue?] = [:]
        for r in ps.dropFirst() { kv[normV(cell(r, 0))] = cell(r, 1) }
        func get(_ k: String) -> TableValue? { kv[k] ?? nil }
        if let nm = get("project name"), !(nm.asString.isEmpty), nm != .bool(false) { project.name = nm.asString; info.name = nm.asString }
        if let sd = parseDateInput(get("project start")?.asString ?? "", dateFormat) { project.settings.startDate = toISO(sd); info.startDate = toISO(sd) }
        if let st = parseDateInput(get("status date")?.asString ?? "", dateFormat) { project.settings.statusDate = toISO(st) }
        let cn = get("project calendar")
        let c = cn.flatMap { v in v.asString.isEmpty ? nil : project.calendars.first { $0.name == v.asString } }
        project.settings.defaultCalendarId = (c ?? project.calendars[0]).id
        if let country = get("country (holidays)"), !country.asString.isEmpty { project.settings.country = country.asString }
        func n(_ k: String) -> Double { get(k).map { v in if case .number(let x) = v { return x }; if case .bool(let b) = v { return b ? 1 : 0 }; return jsNumberFromString(v.asString) } ?? .nan }
        let hpd = n("hours per day"), hpw = n("hours per week"), dpm = n("days per month")
        if hpd.isFinite && hpd > 0 && hpd <= 24 { project.settings.hoursPerDay = hpd }
        if hpw.isFinite && hpw > 0 && hpw <= 168 { project.settings.hoursPerWeek = hpw }
        if dpm.isFinite && dpm > 0 && dpm <= 31 { project.settings.daysPerMonth = dpm }
        let cs = get("critical slack (days)") == nil ? Double.nan : n("critical slack (days)")
        if cs.isFinite && cs >= 0 { project.settings.criticalSlackDays = cs }
        if normV(get("honour constraint dates")) == "no" { project.settings.honorConstraints = false }
    }
    if !project.calendars.contains(where: { $0.id == project.settings.defaultCalendarId }) { project.settings.defaultCalendarId = project.calendars[0].id }
    return info
}

public struct TableImportOptions {
    public var dateFormat = "DD-MMM-YYYY"
    public var datesAs = "constraints" // 'constraints' | 'manual'
    public var importExtraColumns = true
    public var startDate: String? = nil
    public var name: String? = nil
    public var projectSheet: [[TableValue?]]? = nil
    public var calendarSheet: [[TableValue?]]? = nil
    public init() {}
}

/// datesAs 'constraints' (default): a task with a start date and no predecessors gets a Start No Earlier Than constraint; the rest
/// of the dates are calculated. 'manual': tasks with dates become manually scheduled tasks that keep exactly those dates.
public func tableToProject(_ rowsIn: [[TableValue?]], _ options: TableImportOptions = TableImportOptions()) throws -> ImportResult {
    let dateFormat = options.dateFormat, datesAs = options.datesAs, importExtraColumns = options.importExtraColumns
    var notes: [ImportNote] = []
    func note(_ level: String, _ text: String) { notes.append(ImportNote(level: level, text: text)) }
    var rows = rowsIn
    if rows.isEmpty { throw ModelError("The file is empty") }
    // A trailing "# Project Settings" block (written by Ganttpath's own CSV export, after a blank row) is settings, not
    // task rows: split it off before anything else. An XLSX import passes its settings separately (options.projectSheet).
    var projectSheet = options.projectSheet
    if let markerIdx = rows.firstIndex(where: { jsTrim(($0.first ?? nil)?.asString ?? "") == "# Project Settings" }) {
        if projectSheet == nil { projectSheet = Array(rows[(markerIdx + 1)...]) }
        rows = Array(rows[..<markerIdx])
    }
    if rows.isEmpty { throw ModelError("The file is empty") }
    func nonBlank(_ c: TableValue?) -> Bool { c != nil && !jsTrim(c!.asString).isEmpty }
    // header row = first row with at least two non-empty cells
    var hi = rows.firstIndex { $0.filter(nonBlank).count >= 2 } ?? -1
    if hi < 0 { hi = 0 }
    let headerRow = rows[hi].map(normV)
    var col: [String: Int] = [:]
    var colKeys: [String] = []
    var used = Set<Int>()
    for (key, names) in ALIASES {
        for nm in names {
            if let idx = headerRow.firstIndex(of: nm), !used.contains(idx), col[key] == nil { col[key] = idx; colKeys.append(key); used.insert(idx); break }
        }
    }
    for (i, h) in headerRow.enumerated() where ALIAS_IGNORE.contains(h) { used.insert(i) }
    if col["name"] == nil { throw ModelError("No task name column found. The first row needs a heading such as \"Task Name\" or \"Name\".") }
    let ignoredCols = headerRow.enumerated().filter { !$0.element.isEmpty && !used.contains($0.offset) }.map { $0.element }
    let data = rows[(hi + 1)...].filter { $0.contains(where: nonBlank) }
    func get(_ r: [TableValue?], _ key: String) -> TableValue?? {
        guard let c = col[key] else { return .none }        // column absent
        return .some(c < r.count ? r[c] : nil)             // present (value may be empty)
    }
    func val(_ r: [TableValue?], _ key: String) -> TableValue? { (get(r, key) ?? nil) }
    let startDate = options.startDate

    var project = newProject(name: options.name ?? "Imported project", startDate: startDate ?? "2026-01-01")
    let info = applyProjectInfo(&project, projectSheet, options.calendarSheet, dateFormat)
    let cal = Cal(project.calendars.first { $0.id == project.settings.defaultCalendarId } ?? project.calendars[0])
    var problems: [String] = []
    func problem(_ row: Int, _ text: String) { if problems.count < 30 { problems.append("Row \(hi + 2 + row): \(text)") } }

    // custom columns from the extra headings
    var extraIdx: [(i: Int, id: String)] = []
    if importExtraColumns {
        for (i, h) in headerRow.enumerated() {
            if h.isEmpty || used.contains(i) || ALIAS_IGNORE.contains(h) { continue }
            if extraIdx.count >= 20 { continue }
            let name = jsTrim(rows[hi][i]?.asString ?? "null")
            let id = "x\(extraIdx.count + 1)"
            project.customColumns.append(CustomColumn(id: id, name: name, type: "text", options: []))
            extraIdx.append((i, id))
        }
    }

    struct Rec { var t: Task; var r: [TableValue?]; var k: Int; var dur: DurationSpec?; var start: String?; var finish: String?; var milestone = false; var calName: String? }
    var idMap: [String: Int] = [:] // ID cell -> uid
    var built: [Rec] = []
    for (k, r) in data.enumerated() {
        let nameCell = val(r, "name")
        let name = nameCell.map { jsTrim($0.asString) } ?? ""
        var level = 1
        let lv = val(r, "level")
        let wbs = val(r, "wbs")
        let lvNum: Double = { guard let l = lv else { return .nan }; if case .number(let n) = l { return n }; if case .bool(let b) = l { return b ? 1 : 0 }; return l.asString.isEmpty ? .nan : jsNumberFromString(l.asString) }()
        if lv != nil && lvNum.isFinite { level = max(1, jsRoundInt(lvNum)) }
        else if let w = wbs, !jsTrim(w.asString).isEmpty {
            var s = jsTrim(w.asString)
            if s.hasSuffix(".") { s.removeLast() }
            level = s.split(separator: ".", omittingEmptySubsequences: false).count
        } else {
            let raw = nameCell?.asString ?? ""
            let lead = raw.unicodeScalars.prefix { jsWhitespace.contains($0) }.count
            if lead > 0 { level = 1 + lead / 2 }
        }
        var t = blankTask(&project, level: level, name: name)
        let idCell = val(r, "id")
        let idKey = (idCell == nil || idCell!.asString.isEmpty) ? String(built.count + 1) : jsTrim(idCell!.asString)
        if idMap[idKey] != nil { problem(k, "ID \(idKey) appears more than once; links to it may go to the wrong task") }
        idMap[idKey] = t.uid
        var rec = Rec(t: t, r: r, k: k, dur: nil, start: nil, finish: nil)
        t.mode = normV(val(r, "mode")) == "manual" ? "manual" : "auto"
        let durCell = val(r, "duration")
        let d = parseDurationText(durCell, project.settings)
        if let dc = durCell, !(dc.asString.isEmpty), d == nil { problem(k, "Cannot read duration \"\(dc.asString)\"") }
        rec.dur = d
        for key in ["start", "finish"] {
            let (iso, bad) = toIsoCell(val(r, key), dateFormat)
            if bad { problem(k, "Cannot read \(key) date \"\(val(r, key)?.asString ?? "")\"") }
            if key == "start" { rec.start = iso } else { rec.finish = iso }
        }
        if let pct = val(r, "pct"), !pct.asString.isEmpty {
            var v: Double
            if case .number(let n) = pct { v = n; if n > 0 && n <= 1 && n != n.rounded() { v = n * 100 } } // Excel percent cells
            else { v = jsParseFloat(pct.asString.replacingOccurrences(of: "%", with: "", options: [], range: pct.asString.range(of: "%"))) }
            if v.isFinite { t.pct = min(100, max(0, jsRound(v))) } else { problem(k, "Cannot read % complete \"\(pct.asString)\"") }
        }
        for (key, field) in [("astart", "actualStart"), ("afinish", "actualFinish"), ("deadline", "deadline")] {
            let (iso, bad) = toIsoCell(val(r, key), dateFormat)
            if bad { problem(k, "Cannot read \(key) \"\(val(r, key)?.asString ?? "")\"") }
            if let iso = iso {
                if field == "actualStart" { t.actualStart = iso } else if field == "actualFinish" { t.actualFinish = iso } else { t.deadline = iso }
            }
        }
        if col["ctype"] != nil {
            let ctype = normV(val(r, "ctype"))
            if let code = CONSTRAINT_BY_NAME[ctype] {
                let (iso, bad) = toIsoCell(val(r, "cdate"), dateFormat)
                if bad { problem(k, "Cannot read constraint date \"\(val(r, "cdate")?.asString ?? "")\"") }
                if code == "ASAP" || code == "ALAP" { t.constraint = Constraint(type: code, date: nil) }
                else if let iso = iso { t.constraint = Constraint(type: code, date: iso) }
                else { problem(k, "Constraint \"\(val(r, "ctype")?.asString ?? "")\" needs a date") }
            } else { problem(k, "Unknown constraint \"\(val(r, "ctype")?.asString ?? "undefined")\"") }
        }
        if yes(val(r, "milestone")) { rec.milestone = true }
        t.notes = val(r, "notes")?.asString ?? ""
        if let tagCell = val(r, "tags"), !tagCell.asString.isEmpty, tagCell != .bool(false), tagCell != .number(0) {
            let list = tagCell.asString.split(whereSeparator: { $0 == ";" || $0 == "," }).map { jsTrim(String($0)) }.filter { !$0.isEmpty }
            for tg in list where !project.tags.contains(where: { $0.name.lowercased() == tg.lowercased() }) { project.tags.append(Tag(name: tg)) }
            t.tags = list.map { tg in project.tags.first { $0.name.lowercased() == tg.lowercased() }!.name }
        }
        if let w = val(r, "weight"), !w.asString.isEmpty {
            let n: Double = { if case .number(let x) = w { return x }; if case .bool(let b) = w { return b ? 1 : 0 }; return jsNumberFromString(w.asString) }()
            if n.isFinite { t.weight = n }
        }
        if let pr = val(r, "priority"), !pr.asString.isEmpty {
            let n: Double = { if case .number(let x) = pr { return x }; if case .bool(let b) = pr { return b ? 1 : 0 }; return jsNumberFromString(pr.asString) }()
            if n.isFinite && n >= 0 && n <= 1000 { t.priority = jsRoundInt(n) } else { problem(k, "Priority must be a number from 0 to 1000, not \"\(pr.asString)\"") }
        }
        let tt = normV(val(r, "taskType"))
        if !tt.isEmpty {
            if let code = TASK_TYPES.first(where: { normS(TASK_TYPE_NAMES[$0]) == tt || normS($0) == tt }) { t.taskType = code }
            else { problem(k, "Unknown task type \"\(val(r, "taskType")?.asString ?? "")\" (use Fixed Units, Fixed Duration or Fixed Work)") }
        }
        for key in ["inactive", "onTimeline", "hideBar", "rollup"] where yes(val(r, key)) { t.setFlag(key, true) }
        if let calCell = val(r, "calendar"), !calCell.asString.isEmpty, calCell != .bool(false), calCell != .number(0) { rec.calName = jsTrim(calCell.asString) }
        for (i, id) in extraIdx {
            if i < r.count, let v = r[i], !jsTrim(v.asString).isEmpty { t.custom[id] = .string(v.asString) }
        }
        rec.t = t
        built.append(rec)
    }
    project.tasks = built.map { $0.t }
    normalizeProject(&project)
    let isSummary = summaryFlags(project.tasks)

    // predecessors
    var links = 0
    for (i, b) in built.enumerated() {
        guard let text = val(b.r, "preds"), !jsTrim(text.asString).isEmpty else { continue }
        let res = parsePredecessors(text.asString, { idMap[String($0)] })
        for e in res.errors { problem(b.k, "Predecessors: \(e)") }
        for p in res.preds {
            if p.uid == project.tasks[i].uid { problem(b.k, "A task cannot depend on itself"); continue }
            project.tasks[i].preds.append(p); links += 1
        }
    }

    // project start = the given start, else the earliest start date found in the file
    if startDate == nil && info.startDate == nil {
        let starts = built.compactMap { $0.start }.sorted()
        let any = !starts.isEmpty ? starts : built.compactMap { $0.finish }.sorted()
        if let first = any.first { project.settings.startDate = first }
    }
    if let sd = startDate { project.settings.startDate = sd }
    let projStartIso = project.settings.startDate

    // dates and durations
    var manualCount = 0, snet = 0
    for (i, b) in built.enumerated() {
        if isSummary[i] { project.tasks[i].dur = 0; continue }
        let dayMin = dayMinOf(project.settings)
        var dur: Int? = b.dur?.min
        if let du = b.dur { project.tasks[i].durUnit = du.unit }
        if dur == nil, let s = b.start, let f = b.finish { dur = max(dayMin, spanMinutes(cal, s, f)) }
        if dur == nil { dur = b.milestone ? 0 : dayMin }
        project.tasks[i].dur = dur!
        if b.milestone && dur! > 0 { project.tasks[i].milestone = true }
        if project.tasks[i].inactive && (b.start != nil || b.finish != nil) { // an inactive task keeps the dates it had
            project.tasks[i].start = b.start ?? b.finish
            if let f = b.finish { project.tasks[i].finish = f } else { placeManual(&project, i, parseStamp(project.tasks[i].start)!) }
            continue
        }
        let hasPreds = !project.tasks[i].preds.isEmpty
        if (datesAs == "manual" || project.tasks[i].mode == "manual") && (b.start != nil || b.finish != nil) && !isSummary[i] && (!hasPreds || project.tasks[i].mode == "manual") {
            let s = b.start ?? b.finish!
            project.tasks[i].mode = "manual"
            project.tasks[i].start = s
            if let f = b.finish { project.tasks[i].finish = f } else { placeManual(&project, i, parseStamp(s)!) }
            manualCount += 1
        } else if let s = b.start, !hasPreds, project.tasks[i].constraint.type == "ASAP", s > projStartIso {
            project.tasks[i].constraint = Constraint(type: "SNET", date: s); snet += 1
        } else if b.start == nil, let f = b.finish, !hasPreds, project.tasks[i].constraint.type == "ASAP", f > projStartIso {
            project.tasks[i].constraint = Constraint(type: "FNET", date: f); snet += 1
        }
    }

    // calendars named in the file that do not exist are ignored (reported)
    var unknownCals: [String] = []
    for (i, b) in built.enumerated() {
        guard let cn = b.calName else { continue }
        if let c = project.calendars.first(where: { $0.name.lowercased() == cn.lowercased() }) {
            project.tasks[i].calendarId = c.id == project.settings.defaultCalendarId ? nil : c.id
        } else if !unknownCals.contains(cn) { unknownCals.append(cn) }
    }

    project.settings.newTasksAuto = true

    // cycles cannot be saved into a schedule; drop the last link of any cycle and say so
    var s = schedule(project)
    var guardN = 0
    while !s.cycles.isEmpty && guardN < 50 {
        guardN += 1
        let cyc = Set(s.cycles)
        var removed = false
        for j in stride(from: project.tasks.count - 1, through: 0, by: -1) {
            let t = project.tasks[j]
            if !cyc.contains(t.uid) { continue }
            if let pi = t.preds.firstIndex(where: { cyc.contains($0.uid) }) {
                project.tasks[j].preds.remove(at: pi); links -= 1; removed = true
                problem(0, "A circular dependency involving \"\(t.name)\" was broken by removing one link")
                break
            }
        }
        if !removed { break }
        s = schedule(project)
    }
    applySchedule(&project, s)

    // report
    note("info", "\(project.tasks.count) task(s) and \(links) link(s) imported. Recognised columns: \(colKeys.joined(separator: ", ")).")
    if !extraIdx.isEmpty { note("info", "\(extraIdx.count) other column(s) were imported as custom text columns: \(extraIdx.map { e in project.customColumns.first { $0.id == e.id }!.name }.joined(separator: ", ")).") }
    if !ignoredCols.isEmpty && !importExtraColumns { note("info", "Columns not imported: \(ignoredCols.joined(separator: ", ")).") }
    if col["level"] == nil && col["wbs"] == nil { note("warn", "No outline level or WBS column found, so all tasks were imported at the same level. Add an \"Outline Level\" column to keep the hierarchy.") }
    if snet > 0 { note("info", "\(snet) task(s) without predecessors were given a Start No Earlier Than (or Finish No Earlier Than) constraint from their dates; all other dates are calculated from links and durations.") }
    if manualCount > 0 { note("info", "\(manualCount) task(s) were imported as manually scheduled tasks that keep their dates.") }
    if !unknownCals.isEmpty { note("warn", "Calendar name(s) not found and ignored: \(unknownCals.joined(separator: ", ")).") }
    if s.conflictCount > 0 { note("warn", "\(s.conflictCount) scheduling conflict(s) were found after import; see the Conflicts list.") }
    for p in problems { note("warn", p) }
    let report = ImportReport(stats: ["tasks": project.tasks.count, "links": links, "columns": col.count], compared: nil, matched: nil,
                              differences: [], differenceCount: 0, notes: notes, hasCompare: false)
    return ImportResult(project: project, report: report)
}
