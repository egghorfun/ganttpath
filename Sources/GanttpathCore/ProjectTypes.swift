// The project data model as Swift types, and their conversion to and from the JSON of a .gpath file.
//
// Project shape (schema 2):
//   { schema, name, nextUid, settings{...}, calendars[], tags[], customColumns[], tasks[] }
// Task shape:
//   { uid, name, level, mode:'auto'|'manual', dur (working minutes), durUnit ('m'|'h'|'d'|'w'|'mo': the unit it is shown in),
//     start, finish, milestone, constraint{type,date}, deadline,
//     preds[{uid,type,lag{v,u}}], pct, actualStart, actualFinish, calendarId, weight, baselines[6 or 11], tags[], color,
//     custom{}, notes, collapsed, ... }
// Dates are 'YYYY-MM-DD' (a whole day) or 'YYYY-MM-DDTHH:MM' (a moment, used when a time matters).
// Reading is forgiving in the same way as the JavaScript app's normalizeProject(); fields this version does not know are kept
// and written back unchanged, so a file survives a round trip through either app.

import Foundation

public struct Pred: Equatable, Hashable, Sendable {
    public var uid: Int
    public var type: String
    public var lag: Lag
    public init(uid: Int, type: String = "FS", lag: Lag = .zero) { self.uid = uid; self.type = type; self.lag = lag }
}

public struct Constraint: Equatable, Sendable {
    public var type: String
    public var date: String?
    public init(type: String, date: String? = nil) { self.type = type; self.date = date }
    public static let asap = Constraint(type: "ASAP", date: nil)
    /// The constraint as the scheduler reads it ('' means ASAP).
    public var effectiveType: String { type.isEmpty ? "ASAP" : type }
}

public struct Baseline: Equatable, Sendable {
    public var start: String?
    public var finish: String?
    public var duration: Double?
    public var dur: Int?
    public var extra = JSONObject()
    public init(start: String?, finish: String?, duration: Double?, dur: Int?) {
        self.start = start; self.finish = finish; self.duration = duration; self.dur = dur
    }
}

public struct Tag: Equatable, Sendable {
    public var name: String
    public var color: String
    public init(name: String, color: String = "#64748B") { self.name = name; self.color = color }
}

public struct CustomColumn: Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: String // text | number | date | flag | list
    public var options: [String]
    public init(id: String, name: String, type: String = "text", options: [String] = []) {
        self.id = id; self.name = name; self.type = type; self.options = options
    }
}

public struct Task: Equatable, Sendable {
    public var uid: Int
    public var name: String = "New task"
    public var level: Int = 1
    public var mode: String = "auto"
    public var dur: Int = 480
    public var durUnit: String = "d"
    public var start: String? = nil
    public var finish: String? = nil
    public var milestone: Bool = false
    public var constraint: Constraint = .asap
    public var deadline: String? = nil
    public var preds: [Pred] = []
    public var pct: Double = 0
    public var actualStart: String? = nil
    public var actualFinish: String? = nil
    public var calendarId: String? = nil
    public var weight: Double? = nil
    public var priority: Int = 500
    public var taskType: String = "fixedUnits"
    public var inactive: Bool = false
    public var onTimeline: Bool = false
    public var hideBar: Bool = false
    public var rollup: Bool = false
    public var baselines: [Baseline?] = Array(repeating: nil, count: BASELINE_COUNT)
    public var tags: [String] = []
    public var color: String? = nil
    public var custom = JSONObject()
    public var notes: String = ""
    public var collapsed: Bool = false
    public var nameBold: Bool = false
    public var nameItalic: Bool = false
    public var nameUnderline: Bool = false
    public var extra = JSONObject()

    public init(uid: Int) { self.uid = uid }

    /// One of the true/false fields by name (TASK_FLAGS and NAME_STYLE_FLAGS).
    public func flag(_ key: String) -> Bool {
        switch key {
        case "inactive": return inactive
        case "onTimeline": return onTimeline
        case "hideBar": return hideBar
        case "rollup": return rollup
        case "nameBold": return nameBold
        case "nameItalic": return nameItalic
        case "nameUnderline": return nameUnderline
        case "milestone": return milestone
        case "collapsed": return collapsed
        default: return false
        }
    }
    public mutating func setFlag(_ key: String, _ on: Bool) {
        switch key {
        case "inactive": inactive = on
        case "onTimeline": onTimeline = on
        case "hideBar": hideBar = on
        case "rollup": rollup = on
        case "nameBold": nameBold = on
        case "nameItalic": nameItalic = on
        case "nameUnderline": nameUnderline = on
        case "milestone": milestone = on
        case "collapsed": collapsed = on
        default: break
        }
    }
}

// MARK: - Header and footer of printed pages

public struct HFLine: Equatable, Sendable {
    public var field: String
    public var text: String
    public init(field: String = "none", text: String = "") { self.field = field; self.text = text }
}

public struct HFBox: Equatable, Sendable {
    public var lines: [HFLine]
    public var font: String
    public var size: Double
    public var color: String
    public init(lines: [HFLine], font: String, size: Double, color: String) { self.lines = lines; self.font = font; self.size = size; self.color = color }
}

public struct HFSection: Equatable, Sendable {
    public var left: HFBox
    public var center: HFBox
    public var right: HFBox
    public subscript(_ key: String) -> HFBox {
        get { key == "left" ? left : key == "center" ? center : right }
        set { if key == "left" { left = newValue } else if key == "center" { center = newValue } else { right = newValue } }
    }
}

public struct HeaderFooter: Equatable, Sendable {
    public var header: HFSection
    public var footer: HFSection
}

// MARK: - Settings

public struct Settings: Equatable, Sendable {
    public var startDate: String
    public var statusDate: String? = nil
    public var dateFormat: String = "DD-MMM-YYYY"
    public var honorConstraints: Bool = true
    public var criticalSlackDays: Double = 0
    public var nearCriticalDays: Double = 2
    public var newTasksAuto: Bool = true
    public var country: String = "SG"
    public var defaultCalendarId: String = "std"
    public var weekStartsMonday: Bool = true
    public var pickerStartsSunday: Bool = true
    public var showWeekday: Bool = true
    public var hoursPerDay: Double = 8
    public var hoursPerWeek: Double = 40
    public var daysPerMonth: Double = 20
    public var documentNumber: String = ""
    public var logoDataUrl: String? = nil
    public var headerFooter: HeaderFooter = defaultHeaderFooter()
    public var extra = JSONObject()

    public init(startDate: String) { self.startDate = startDate }
}

// MARK: - Project

public struct Project: Equatable, Sendable {
    public var schema: Int = SCHEMA
    public var name: String = "Untitled project"
    public var nextUid: Int = 1
    public var settings: Settings
    public var calendars: [CalendarDef]
    public var tags: [Tag] = []
    public var customColumns: [CustomColumn] = []
    public var tasks: [Task] = []
    public var extra = JSONObject()

    public init(name: String, settings: Settings, calendars: [CalendarDef]) {
        self.name = name; self.settings = settings; self.calendars = calendars
    }
}

// MARK: - JSON -> model

private func str(_ v: JSON?) -> String? {
    guard let v = v else { return nil }
    switch v {
    case .string(let s): return s
    default: return nil
    }
}
/// A stored date field: a string, or nil. (Anything else in a hand-edited file is treated as no date.)
private func dateField(_ v: JSON?) -> String? { str(v) }
private func numOrNil(_ v: JSON?) -> Double? { v?.number }
private func truthy(_ v: JSON?) -> Bool { v?.truthy ?? false }
/// JavaScript's `x | 0` (ToInt32).
func toInt32(_ d: Double) -> Int {
    guard d.isFinite else { return 0 }
    let t = d < 0 ? (-d).rounded(.down) * -1 : d.rounded(.down)
    let m = t.truncatingRemainder(dividingBy: 4294967296)
    var u = m < 0 ? m + 4294967296 : m
    if u >= 2147483648 { u -= 4294967296 }
    return Int(u)
}

private func rawPeriods(_ v: JSON?) -> [RawPeriod]? {
    guard let a = v?.array else { return nil }
    return a.compactMap { p -> RawPeriod? in
        if let pa = p.array { return pa.count >= 2 ? [pa[0].jsNumber, pa[1].jsNumber] : [] }
        if let po = p.object { return [(po["from"] ?? .null).jsNumber, (po["to"] ?? .null).jsNumber] }
        return []
    }
}

private func periodsJSON(_ p: [RawPeriod]) -> JSON { .array(p.map { .array($0.map { .number($0) }) }) }

extension CalException {
    static func from(json: JSON) -> CalException? {
        guard let o = json.object else { return nil }
        var e = CalException(from: str(o["from"]) ?? "", to: str(o["to"]), working: truthy(o["working"]), name: str(o["name"]) ?? "",
                             periods: rawPeriods(o["periods"]), origin: str(o["origin"]))
        var extra = JSONObject()
        for (k, v) in o.pairs where !["from", "to", "working", "name", "periods", "origin"].contains(k) { extra[k] = v }
        e.extra = extra
        if o["to"] == nil { e.to = nil }
        return e
    }
    public var json: JSON {
        var o = JSONObject()
        o["from"] = .string(from)
        o["to"] = to.map { .string($0) } ?? .null
        o["working"] = .bool(working)
        o["name"] = .string(name)
        if let p = periods { o["periods"] = periodsJSON(p) }
        if let g = origin { o["origin"] = .string(g) }
        for (k, v) in extra.pairs { o[k] = v }
        return .object(o)
    }
}

extension CalendarDef {
    public static func from(json: JSON) -> CalendarDef? {
        guard let o = json.object else { return nil }
        var week = (o["workWeek"]?.array ?? []).map { $0.truthy }
        if o["workWeek"]?.array == nil { week = [] }
        var hours: [[RawPeriod]]? = nil
        if let h = o["hours"]?.array { hours = h.map { rawPeriods($0) ?? [] } }
        let exc = (o["exceptions"]?.array ?? []).compactMap { CalException.from(json: $0) }
        var d = CalendarDef(id: o["id"].map { $0.jsString } ?? "", name: str(o["name"]) ?? (o["name"]?.jsString ?? ""), workWeek: week, hours: hours, exceptions: exc)
        var extra = JSONObject()
        for (k, v) in o.pairs where !["id", "name", "workWeek", "hours", "exceptions"].contains(k) { extra[k] = v }
        d.extra = extra
        return d
    }
    public var json: JSON {
        var o = JSONObject()
        o["id"] = .string(id)
        o["name"] = .string(name)
        o["workWeek"] = .array(workWeek.map { .bool($0) })
        if let h = hours { o["hours"] = .array(h.map { periodsJSON($0) }) }
        o["exceptions"] = .array(exceptions.map { $0.json })
        for (k, v) in extra.pairs { o[k] = v }
        return .object(o)
    }
}

extension Baseline {
    static func from(json: JSON) -> Baseline? {
        guard let o = json.object else { return nil }
        var b = Baseline(start: str(o["start"]), finish: str(o["finish"]), duration: numOrNil(o["duration"]),
                         dur: numOrNil(o["dur"]).flatMap { $0.isFinite ? Int($0.rounded()) : nil })
        var extra = JSONObject()
        for (k, v) in o.pairs where !["start", "finish", "duration", "dur"].contains(k) { extra[k] = v }
        b.extra = extra
        return b
    }
    var json: JSON {
        var o = JSONObject()
        o["start"] = JSON(start)
        o["finish"] = JSON(finish)
        o["duration"] = duration.map { .number($0) } ?? .null
        o["dur"] = dur.map { .number(Double($0)) } ?? .null
        for (k, v) in extra.pairs { o[k] = v }
        return .object(o)
    }
}

private let taskKeys: Set<String> = ["uid", "name", "level", "mode", "dur", "duration", "durUnit", "start", "finish", "milestone", "constraint", "deadline",
                                     "preds", "pct", "actualStart", "actualFinish", "calendarId", "weight", "priority", "taskType", "inactive",
                                     "onTimeline", "hideBar", "rollup", "baselines", "tags", "color", "custom", "notes", "collapsed",
                                     "nameBold", "nameItalic", "nameUnderline"]

extension Task {
    /// Read a task as the JavaScript normalizeProject() would leave it. `uid` is nil when the file's uid is not an integer.
    static func from(json: JSON, settings: Settings) -> (task: Task, uidOK: Bool) {
        let o = json.object ?? JSONObject()
        let uidNum = o["uid"]?.number
        let uidOK = uidNum.map { $0.isFinite && $0 == $0.rounded() && abs($0) < 9e15 } ?? false
        var t = Task(uid: uidOK ? Int(uidNum!) : 0)
        if let n = o["name"], !n.isNull { t.name = n.string ?? n.jsString } else { t.name = "" }
        let lv = toInt32((o["level"] ?? .null).jsNumber)
        t.level = max(1, lv == 0 ? 1 : lv)
        t.mode = str(o["mode"]) == "manual" ? "manual" : "auto"
        if let d = o["dur"]?.number, d.isFinite { t.dur = max(0, jsRoundInt(d)) }
        else {
            let days = (o["duration"] ?? .null).jsNumber
            t.dur = max(0, jsRoundInt((days.isNaN ? 0 : days) * Double(dayMinOf(settings))))
        }
        let du = str(o["durUnit"]) ?? ""
        t.durUnit = UNITS.contains(du) ? du : "d"
        t.start = dateField(o["start"])
        t.finish = dateField(o["finish"])
        t.milestone = truthy(o["milestone"])
        if let c = o["constraint"]?.object {
            let ty = c["type"].map { $0.isNull ? "" : ($0.string ?? $0.jsString) } ?? ""
            t.constraint = Constraint(type: ty, date: str(c["date"]))
        } else { t.constraint = .asap }
        t.deadline = dateField(o["deadline"])
        t.preds = (o["preds"]?.array ?? []).compactMap { p -> Pred? in
            guard let po = p.object, let u = po["uid"]?.number, u.isFinite, u == u.rounded() else { return nil }
            let ty = str(po["type"]).flatMap { $0.isEmpty ? nil : $0 } ?? "FS"
            var lag = Lag.zero
            if let lo = po["lag"]?.object {
                let v = (lo["v"] ?? .null).jsNumber
                lag = Lag(v: v.isNaN ? 0 : v, u: str(lo["u"]) ?? "d")
            }
            return Pred(uid: Int(u), type: ty, lag: lag)
        }
        let pc = (o["pct"] ?? .null).jsNumber
        t.pct = min(100, max(0, pc.isNaN ? 0 : pc))
        t.actualStart = dateField(o["actualStart"])
        t.actualFinish = dateField(o["actualFinish"])
        if let c = o["calendarId"], !c.isNull { t.calendarId = c.string ?? c.jsString } else { t.calendarId = nil }
        t.weight = numOrNil(o["weight"])
        t.priority = o["priority"].map(normPriority) ?? PRIORITY_DEFAULT // Number(undefined) is NaN: a missing priority is 500
        let tt = str(o["taskType"]) ?? ""
        t.taskType = TASK_TYPES.contains(tt) ? tt : "fixedUnits"
        for k in TASK_FLAGS + NAME_STYLE_FLAGS { t.setFlag(k, truthy(o[k])) }
        var bl: [Baseline?] = (o["baselines"]?.array ?? []).prefix(BASELINE_COUNT).map { Baseline.from(json: $0) }
        while bl.count < BASELINE_COUNT { bl.append(nil) }
        t.baselines = bl
        t.tags = (o["tags"]?.array ?? []).map { $0.string ?? $0.jsString }
        t.color = str(o["color"]).flatMap { $0.isEmpty ? nil : $0 }
        t.custom = o["custom"]?.object ?? JSONObject()
        t.notes = str(o["notes"]) ?? ""
        t.collapsed = truthy(o["collapsed"])
        var extra = JSONObject()
        for (k, v) in o.pairs where !taskKeys.contains(k) { extra[k] = v }
        t.extra = extra
        return (t, uidOK)
    }

    public var json: JSON {
        var o = JSONObject()
        o["uid"] = JSON(uid)
        o["name"] = .string(name)
        o["level"] = JSON(level)
        o["mode"] = .string(mode)
        o["dur"] = JSON(dur)
        o["durUnit"] = .string(durUnit)
        o["start"] = JSON(start)
        o["finish"] = JSON(finish)
        o["milestone"] = .bool(milestone)
        o["constraint"] = .object(JSONObject([("type", .string(constraint.type)), ("date", JSON(constraint.date))]))
        o["deadline"] = JSON(deadline)
        o["preds"] = .array(preds.map { p in
            .object(JSONObject([("uid", JSON(p.uid)), ("type", .string(p.type)),
                                ("lag", .object(JSONObject([("v", .number(p.lag.v)), ("u", .string(p.lag.u))])))]))
        })
        o["pct"] = .number(pct)
        o["actualStart"] = JSON(actualStart)
        o["actualFinish"] = JSON(actualFinish)
        o["calendarId"] = JSON(calendarId)
        o["weight"] = weight.map { .number($0) } ?? .null
        o["priority"] = JSON(priority)
        o["taskType"] = .string(taskType)
        o["inactive"] = .bool(inactive)
        o["onTimeline"] = .bool(onTimeline)
        o["hideBar"] = .bool(hideBar)
        o["rollup"] = .bool(rollup)
        // six slots as the JavaScript app wrote them; all eleven once Baseline 6 to 10 are used
        let used = (baselines.lastIndex { $0 != nil } ?? -1) + 1
        o["baselines"] = .array(baselines.prefix(max(6, used)).map { $0?.json ?? .null })
        o["tags"] = .array(tags.map { .string($0) })
        o["color"] = JSON(color)
        o["custom"] = .object(custom)
        o["notes"] = .string(notes)
        o["collapsed"] = .bool(collapsed)
        o["nameBold"] = .bool(nameBold)
        o["nameItalic"] = .bool(nameItalic)
        o["nameUnderline"] = .bool(nameUnderline)
        for (k, v) in extra.pairs { o[k] = v }
        return .object(o)
    }
}

extension HFBox {
    var json: JSON {
        .object(JSONObject([
            ("lines", .array(lines.map { .object(JSONObject([("field", .string($0.field)), ("text", .string($0.text))])) })),
            ("font", .string(font)), ("size", .number(size)), ("color", .string(color)),
        ]))
    }
}
extension HFSection {
    var json: JSON { .object(JSONObject([("left", left.json), ("center", center.json), ("right", right.json)])) }
}
extension HeaderFooter {
    public var json: JSON { .object(JSONObject([("header", header.json), ("footer", footer.json)])) }
}

private let settingsKeys: Set<String> = ["startDate", "statusDate", "dateFormat", "honorConstraints", "criticalSlackDays", "nearCriticalDays",
                                         "newTasksAuto", "country", "defaultCalendarId", "weekStartsMonday", "pickerStartsSunday", "showWeekday",
                                         "hoursPerDay", "hoursPerWeek", "daysPerMonth", "documentNumber", "logoDataUrl", "headerFooter"]

extension Settings {
    /// `{ ...defaultSettings(start), ...fileSettings }`, then the checks normalizeProject() makes.
    static func from(json: JSON?) -> Settings {
        let o = json?.object ?? JSONObject()
        let sd = str(o["startDate"]).flatMap { $0.isEmpty ? nil : $0 } ?? toISO(todayDn())
        var s = defaultSettings(sd)
        if o.has("startDate") { s.startDate = str(o["startDate"]) ?? sd }
        if o.has("statusDate") { s.statusDate = str(o["statusDate"]).flatMap { $0.isEmpty ? nil : $0 } }
        if let v = str(o["dateFormat"]) { s.dateFormat = v }
        if let v = o["honorConstraints"] { s.honorConstraints = v != .bool(false) }
        if let v = o["criticalSlackDays"]?.number, v.isFinite { s.criticalSlackDays = v }
        if let v = o["nearCriticalDays"]?.number, v.isFinite { s.nearCriticalDays = v }
        if let v = o["newTasksAuto"] { s.newTasksAuto = v != .bool(false) }
        if let v = str(o["country"]) { s.country = v }
        if let v = o["defaultCalendarId"], !v.isNull { s.defaultCalendarId = v.string ?? v.jsString }
        if let v = o["weekStartsMonday"] { s.weekStartsMonday = v.truthy }
        if let v = o["pickerStartsSunday"] { s.pickerStartsSunday = v != .bool(false) }
        if let v = o["showWeekday"] { s.showWeekday = v != .bool(false) }
        if let v = o["hoursPerDay"] { let d = v.jsNumber; s.hoursPerDay = d.isFinite && d > 0 ? d : DEFAULT_HOURS_PER_DAY }
        if let v = o["hoursPerWeek"] { let d = v.jsNumber; s.hoursPerWeek = d.isFinite && d > 0 ? d : DEFAULT_HOURS_PER_WEEK }
        if let v = o["daysPerMonth"] { let d = v.jsNumber; s.daysPerMonth = d.isFinite && d > 0 ? d : DEFAULT_DAYS_PER_MONTH }
        s.documentNumber = String((str(o["documentNumber"]) ?? "").prefix(200))
        if let v = str(o["logoDataUrl"]), v.hasPrefix("data:image/"), v.utf16.count <= LOGO_MAX_CHARS { s.logoDataUrl = v } else { s.logoDataUrl = nil }
        // a file without the field keeps the defaults ({...defaultSettings(), ...file}); one that has it is cleaned up
        s.headerFooter = o.has("headerFooter") ? normalizeHeaderFooter(o["headerFooter"]) : defaultHeaderFooter()
        var extra = JSONObject()
        for (k, v) in o.pairs where !settingsKeys.contains(k) { extra[k] = v }
        s.extra = extra
        return s
    }

    public var json: JSON {
        var o = JSONObject()
        o["startDate"] = .string(startDate)
        o["statusDate"] = JSON(statusDate)
        o["dateFormat"] = .string(dateFormat)
        o["honorConstraints"] = .bool(honorConstraints)
        o["criticalSlackDays"] = .number(criticalSlackDays)
        o["nearCriticalDays"] = .number(nearCriticalDays)
        o["newTasksAuto"] = .bool(newTasksAuto)
        o["country"] = .string(country)
        o["defaultCalendarId"] = .string(defaultCalendarId)
        o["weekStartsMonday"] = .bool(weekStartsMonday)
        o["pickerStartsSunday"] = .bool(pickerStartsSunday)
        o["showWeekday"] = .bool(showWeekday)
        o["hoursPerDay"] = .number(hoursPerDay)
        o["hoursPerWeek"] = .number(hoursPerWeek)
        o["daysPerMonth"] = .number(daysPerMonth)
        o["documentNumber"] = .string(documentNumber)
        o["logoDataUrl"] = JSON(logoDataUrl)
        o["headerFooter"] = headerFooter.json
        for (k, v) in extra.pairs { o[k] = v }
        return .object(o)
    }
}

extension Project {
    /// Read a project object (the "project" member of a .gpath file) and normalize it like the JavaScript app does.
    public static func from(json: JSON) throws -> Project {
        guard let o = json.object else { throw ModelError("Not a Ganttpath project") }
        let settings = Settings.from(json: o["settings"])
        var cals = (o["calendars"]?.array ?? []).compactMap { CalendarDef.from(json: $0) }
        if cals.isEmpty { cals = [defaultCalendarDef("Standard")] }
        var p = Project(name: "", settings: settings, calendars: cals)
        let fromSchema = o["schema"]?.number.flatMap { $0.isFinite ? Int($0) : nil } ?? 1
        p.schema = max(fromSchema == 0 ? 1 : fromSchema, SCHEMA)
        if let n = o["name"], n.truthy { p.name = n.string ?? n.jsString } else { p.name = "Untitled project" }
        p.tags = (o["tags"]?.array ?? []).compactMap { t in
            guard let to = t.object else { return nil }
            return Tag(name: to["name"].map { $0.string ?? $0.jsString } ?? "", color: str(to["color"]) ?? "#64748B")
        }
        p.customColumns = (o["customColumns"]?.array ?? []).compactMap { c in
            guard let co = c.object else { return nil }
            return CustomColumn(id: co["id"].map { $0.string ?? $0.jsString } ?? "", name: co["name"].map { $0.string ?? $0.jsString } ?? "",
                                type: str(co["type"]) ?? "text", options: (co["options"]?.array ?? []).map { $0.string ?? $0.jsString })
        }
        var uidOK: [Bool] = []
        p.tasks = (o["tasks"]?.array ?? []).map { tj in
            let r = Task.from(json: tj, settings: settings)
            uidOK.append(r.uidOK)
            return r.task
        }
        p.nextUid = o["nextUid"]?.number.flatMap { $0.isFinite && $0 >= 1 ? Int($0) : nil } ?? 1
        var extra = JSONObject()
        for (k, v) in o.pairs where !["schema", "name", "nextUid", "settings", "calendars", "tags", "customColumns", "tasks"].contains(k) { extra[k] = v }
        p.extra = extra
        normalizeProject(&p, uidValid: uidOK)
        return p
    }

    public var json: JSON {
        var o = JSONObject()
        o["schema"] = JSON(schema)
        o["name"] = .string(name)
        o["nextUid"] = JSON(nextUid)
        o["settings"] = settings.json
        o["calendars"] = .array(calendars.map { $0.json })
        o["tags"] = .array(tags.map { .object(JSONObject([("name", .string($0.name)), ("color", .string($0.color))])) })
        o["customColumns"] = .array(customColumns.map {
            .object(JSONObject([("id", .string($0.id)), ("name", .string($0.name)), ("type", .string($0.type)), ("options", .array($0.options.map { .string($0) }))]))
        })
        o["tasks"] = .array(tasks.map { $0.json })
        for (k, v) in extra.pairs { o[k] = v }
        return .object(o)
    }

    /// JSON.stringify(project)
    public func jsonString() -> String { JSONWriter.stringify(json) }
}

func normPriority(_ v: JSON) -> Int {
    let n = jsRound(v.jsNumber)
    return n.isFinite ? Int(min(1000, max(0, n))) : PRIORITY_DEFAULT
}
