// Project templates: a built-in turnkey engineering project and user-saved templates.
// A template stores structure, durations, links and constraints but no calendar dates
// (dated constraints are kept as an offset in calendar days from the project start).

import Foundation

public let TEMPLATE_FORMAT = "ganttpath-template"

public struct TemplateRow: Equatable, Sendable {
    public var level: Int
    public var name: String
    public var duration: Double // working days of the project (0 = milestone)
    public var preds: [(row: Int, type: String, lag: Lag)]
    public var milestone = false
    public var manual = false
    public var constraint: (type: String, offset: Int?)? = nil
    public var deadlineOffset: Int? = nil
    public var notes: String? = nil
    public var tags: [String]? = nil
    public var weight: Double? = nil
    public var priority: Int? = nil
    public var taskType: String? = nil
    public var onTimeline = false
    public var hideBar = false
    public var rollup = false

    public init(level: Int, name: String, duration: Double, preds: [(row: Int, type: String, lag: Lag)] = []) {
        self.level = level; self.name = name; self.duration = duration; self.preds = preds
    }

    public static func == (a: TemplateRow, b: TemplateRow) -> Bool {
        a.level == b.level && a.name == b.name && a.duration == b.duration
            && a.preds.map { "\($0.row)\($0.type)\($0.lag.v)\($0.lag.u)" } == b.preds.map { "\($0.row)\($0.type)\($0.lag.v)\($0.lag.u)" }
            && a.milestone == b.milestone && a.manual == b.manual && a.constraint?.type == b.constraint?.type && a.constraint?.offset == b.constraint?.offset
            && a.deadlineOffset == b.deadlineOffset && a.notes == b.notes && a.tags == b.tags && a.weight == b.weight && a.priority == b.priority
            && a.taskType == b.taskType && a.onTimeline == b.onTimeline && a.hideBar == b.hideBar && a.rollup == b.rollup
    }
}

public struct ProjectTemplate: Equatable, Sendable {
    public var id: String
    public var builtin: Bool
    public var name: String
    public var description: String
    public var rows: [TemplateRow]
    public var tags: [Tag] = []
    public var createdAt: String? = nil
}

// level | name | duration (working days; 0 = milestone) | predecessors (row numbers in this list)
private let TURNKEY = """
1|Project initiation & planning|0|
2|Contract award / letter of intent received|0|
2|Project kick-off meeting|2|2
2|Project execution plan & baseline schedule|15|3
2|Project procedures & QA/QC plan|10|3
2|Kick-off complete|0|4,5
1|Engineering & design|0|
2|Design basis & P&IDs|20|6
2|Process design & equipment datasheets|20|8
2|Layout & general arrangement|15|8
2|Civil & structural design|25|10
2|Mechanical design|25|9
2|Electrical & instrumentation design|25|9
2|Piping design & isometrics|25|10,12
2|Client review & comments|15|11,12,13,14
2|Design revision & approval|15|15
2|Issued for construction (IFC)|0|16
1|Procurement|0|
2|Long-lead item requisitions|10|9
2|Bid & tender for long-lead equipment|25|19
2|Bid evaluation & purchase orders|15|20
2|Bulk material requisitions|10|16
2|Bulk material purchase orders|20|22
2|Vendor drawing review|20|21
2|Long-lead purchase orders placed|0|21
1|Fabrication & manufacturing|0|
2|Long-lead equipment manufacturing|90|24,25
2|Skid / module fabrication|60|24,25
2|Bulk materials manufacturing|40|23
2|Factory acceptance tests (FAT)|10|27,28
2|Ready for shipment|0|30
1|Logistics & delivery|0|
2|Packing & export documentation|10|31,29
2|Freight to site|30|33
2|Import clearance & inland transport|10|34
2|Materials delivered to site|0|35
1|Site preparation & civil works|0|
2|Mobilisation & site establishment|10|17
2|Site survey & setting out|5|38
2|Excavation & earthworks|15|39
2|Foundations & concrete works|30|40
2|Structural steel erection|20|41
2|Civil works complete|0|42
1|Installation|0|
2|Equipment installation & setting|25|36,43
2|Piping installation|30|45SS+10d
2|Electrical installation & cabling|30|45SS+10d
2|Instrumentation installation|20|46SS+10d
2|Insulation, painting & fireproofing|15|46
2|Mechanical completion|0|46,47,48,49
1|Pre-commissioning|0|
2|Punch-listing & rectification|10|50
2|Hydrotest & pressure testing|10|52
2|Electrical & instrument loop checks|10|52
2|Flushing, cleaning & leak testing|8|53
1|Commissioning|0|
2|Utilities commissioning|5|54,55
2|Equipment run tests|8|57
2|System commissioning|10|58
2|Performance test & guarantee run|10|59
2|Performance test accepted|0|60
1|Handover & close-out|0|
2|As-built drawings & O&M manuals|15|50
2|Operator training|5|59
2|Taking-over certificate / provisional acceptance|0|61,63,64
2|Project close-out report & lessons learned|10|65
1|Warranty (defects liability period)|0|
2|Defects liability period|260|65
2|Final acceptance certificate|0|68,66
"""

func parseDsl(_ text: String) -> [TemplateRow] {
    var rows: [TemplateRow] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if jsTrim(String(line)).isEmpty { continue }
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let r = parsePredecessors(f.count > 3 ? f[3] : "", { $0 >= 1 ? $0 : nil })
        precondition(r.errors.isEmpty, "Built-in template error in \"\(f[1])\": \(r.errors.joined(separator: "; "))")
        rows.append(TemplateRow(level: Int(f[0])!, name: f[1], duration: Double(f[2])!, preds: r.preds.map { ($0.uid, $0.type, $0.lag) }))
    }
    return rows
}

public let BUILTIN_TEMPLATES: [ProjectTemplate] = [
    ProjectTemplate(
        id: "turnkey-engineering", builtin: true,
        name: "Turnkey engineering project",
        description: "Initiation, engineering, procurement, fabrication, logistics, site and civil works, installation, pre-commissioning, commissioning, handover and warranty. Durations are typical starting points to edit.",
        rows: parseDsl(TURNKEY)),
    ProjectTemplate(id: "blank", builtin: true, name: "Blank project", description: "One empty task to start from.",
                    rows: [TemplateRow(level: 1, name: "New task", duration: 1)]),
]

/// Build a template from an open project: drops dates, progress, actuals, baselines and colours.
public func projectToTemplate(_ project: Project, _ name: String?, _ description: String = "") -> ProjectTemplate {
    var uidToRow: [Int: Int] = [:]
    for (i, t) in project.tasks.enumerated() { uidToRow[t.uid] = i + 1 }
    let start = parseISO(project.settings.startDate)
    let rows: [TemplateRow] = project.tasks.enumerated().map { (i, t) in
        let isSummary = i + 1 < project.tasks.count && project.tasks[i + 1].level > t.level
        var row = TemplateRow(level: t.level, name: t.name,
                              duration: isSummary ? 0 : jsRound((Double(t.dur) / Double(dayMinOf(project.settings))) * 1000) / 1000,
                              preds: t.preds.filter { uidToRow[$0.uid] != nil }.map { (uidToRow[$0.uid]!, $0.type, $0.lag) })
        if t.milestone { row.milestone = true }
        if t.mode == "manual" { row.manual = true }
        let c = t.constraint
        if c.type != "ASAP" {
            let d = parseISO(c.date)
            let off: Int? = (d != nil && start != nil) ? d! - start! : nil
            if !(off == nil && c.type != "ALAP") { row.constraint = (c.type, off) }
        }
        if let dl = nonEmpty(t.deadline), let s = start, let d = parseISO(dl) { row.deadlineOffset = d - s }
        if !t.notes.isEmpty { row.notes = t.notes }
        if !t.tags.isEmpty { row.tags = t.tags }
        if let w = t.weight { row.weight = w }
        if t.priority != 500 { row.priority = t.priority }
        if t.taskType != "fixedUnits" { row.taskType = t.taskType }
        row.onTimeline = t.onTimeline; row.hideBar = t.hideBar; row.rollup = t.rollup
        return row
    }
    let nm = jsTrim(name ?? "")
    return ProjectTemplate(id: "user-\(base36Now())", builtin: false, name: nm.isEmpty ? "My template" : nm, description: description, rows: rows,
                           tags: project.tags, createdAt: ISO8601DateFormatter.jsString(Date()))
}

/// Create task objects for a template and append them to project.tasks (uses the project's uid counter). Returns the new tasks.
@discardableResult
public func applyTemplate(_ project: inout Project, _ template: ProjectTemplate, startDate: String? = nil) throws -> [Task] {
    if template.rows.isEmpty { throw ModelError("This is not a Ganttpath template file.") }
    let startIso = nonEmpty(startDate) ?? project.settings.startDate
    guard let start = parseISO(startIso) else { throw ModelError("Choose a project start date first") }
    var created: [Task] = []
    for r in template.rows {
        let manualDefault = project.settings.newTasksAuto == false
        var t = blankTask(&project, level: r.level, name: r.name, durationDays: r.duration) { t in
            t.mode = r.manual ? "manual" : manualDefault ? "manual" : "auto"
            t.milestone = r.milestone
            t.notes = r.notes ?? ""
            t.tags = r.tags ?? []
            t.weight = r.weight
            if let p = r.priority { t.priority = p }
            if let tt = r.taskType { t.taskType = tt }
            t.onTimeline = r.onTimeline; t.hideBar = r.hideBar; t.rollup = r.rollup
        }
        if let c = r.constraint {
            let needsDate = !(c.type == "ASAP" || c.type == "ALAP")
            t.constraint = Constraint(type: c.type, date: needsDate && c.offset != nil ? toISO(start + c.offset!) : nil)
        }
        if let d = r.deadlineOffset { t.deadline = toISO(start + d) }
        if t.mode == "manual" { t.start = toISO(start); t.finish = toISO(start) }
        created.append(t)
    }
    for (i, r) in template.rows.enumerated() {
        created[i].preds = r.preds.filter { $0.row >= 1 && $0.row <= created.count && $0.row - 1 != i }
            .map { Pred(uid: created[$0.row - 1].uid, type: $0.type.isEmpty ? "FS" : $0.type, lag: $0.lag) }
    }
    for tg in template.tags where !project.tags.contains(where: { $0.name == tg.name }) { project.tags.append(tg) }
    project.tasks.append(contentsOf: created)
    return created
}

// MARK: - template files (.gptemplate: JSON)

extension ProjectTemplate {
    public var json: JSON {
        var o = JSONObject()
        o["format"] = .string(TEMPLATE_FORMAT)
        o["id"] = .string(id)
        o["builtin"] = .bool(builtin)
        o["name"] = .string(name)
        o["description"] = .string(description)
        o["rows"] = .array(rows.map { r in
            var ro = JSONObject()
            ro["level"] = JSON(r.level); ro["name"] = .string(r.name); ro["duration"] = .number(r.duration)
            ro["preds"] = .array(r.preds.map { .object(JSONObject([("row", JSON($0.row)), ("type", .string($0.type)), ("lag", $0.lag.json)])) })
            if r.milestone { ro["milestone"] = .bool(true) }
            if r.manual { ro["manual"] = .bool(true) }
            if let c = r.constraint { ro["constraint"] = .object(JSONObject([("type", .string(c.type)), ("offset", c.offset.map { JSON($0) } ?? .null)])) }
            if let d = r.deadlineOffset { ro["deadlineOffset"] = JSON(d) }
            if let n = r.notes { ro["notes"] = .string(n) }
            if let t = r.tags { ro["tags"] = .array(t.map { .string($0) }) }
            if let w = r.weight { ro["weight"] = .number(w) }
            if let p = r.priority { ro["priority"] = JSON(p) }
            if let tt = r.taskType { ro["taskType"] = .string(tt) }
            if r.onTimeline { ro["onTimeline"] = .bool(true) }
            if r.hideBar { ro["hideBar"] = .bool(true) }
            if r.rollup { ro["rollup"] = .bool(true) }
            return .object(ro)
        })
        o["tags"] = .array(tags.map { .object(JSONObject([("name", .string($0.name)), ("color", .string($0.color))])) })
        if let c = createdAt { o["createdAt"] = .string(c) }
        return .object(o)
    }

    /// Validate a template loaded from disk.
    public static func from(json: JSON) throws -> ProjectTemplate {
        guard let o = json.object, o["format"]?.string == TEMPLATE_FORMAT, let rowsJ = o["rows"]?.array, !rowsJ.isEmpty else {
            throw ModelError("This is not a Ganttpath template file.")
        }
        let rows: [TemplateRow] = rowsJ.map { rj in
            let ro = rj.object ?? JSONObject()
            let preds: [(row: Int, type: String, lag: Lag)] = (ro["preds"]?.array ?? []).compactMap { pj in
                guard let po = pj.object, let row = po["row"]?.number else { return nil }
                var lag = Lag.zero
                if let lo = po["lag"]?.object { lag = Lag(v: (lo["v"] ?? .null).jsNumber.isNaN ? 0 : (lo["v"] ?? .null).jsNumber, u: lo["u"]?.string ?? "d") }
                return (Int(row), po["type"]?.string ?? "FS", lag)
            }
            var r = TemplateRow(level: Int((ro["level"] ?? .null).jsNumber.isFinite ? (ro["level"] ?? .null).jsNumber : 1),
                                name: ro["name"].map { $0.string ?? $0.jsString } ?? "",
                                duration: { let d = (ro["duration"] ?? .null).jsNumber; return d.isFinite ? d : 0 }(), preds: preds)
            r.milestone = ro["milestone"]?.truthy ?? false
            r.manual = ro["manual"]?.truthy ?? false
            if let c = ro["constraint"]?.object { r.constraint = (c["type"]?.string ?? "ASAP", c["offset"]?.number.map { Int($0) }) }
            r.deadlineOffset = ro["deadlineOffset"]?.number.map { Int($0) }
            r.notes = ro["notes"]?.string
            r.tags = ro["tags"]?.array?.map { $0.string ?? $0.jsString }
            r.weight = ro["weight"]?.number
            r.priority = ro["priority"]?.number.map { Int($0) }
            r.taskType = ro["taskType"]?.string
            r.onTimeline = ro["onTimeline"]?.truthy ?? false
            r.hideBar = ro["hideBar"]?.truthy ?? false
            r.rollup = ro["rollup"]?.truthy ?? false
            return r
        }
        return ProjectTemplate(id: o["id"]?.string ?? "user", builtin: false, name: o["name"]?.string ?? "Template",
                               description: o["description"]?.string ?? "", rows: rows,
                               tags: (o["tags"]?.array ?? []).compactMap { t in t.object.map { Tag(name: $0["name"]?.string ?? "", color: $0["color"]?.string ?? "#64748B") } },
                               createdAt: o["createdAt"]?.string)
    }
}

extension ISO8601DateFormatter {
    /// Date.prototype.toISOString(): 2026-09-20T15:30:00.000Z
    public static func jsString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
