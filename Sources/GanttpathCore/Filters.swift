// Which rows are shown, and in what order: collapse state, search, filters, sorting and grouping.

import Foundation

public struct ViewFilter: Equatable, Sendable {
    public var critical = false
    public var conflicts = false
    public var incomplete = false
    public var milestones = false
    public var summariesOnly = false
    public var mode: String? = nil // 'auto' | 'manual'
    public var tags: [String] = []
    public var slackMax: Double? = nil
    public var slackMin: Double? = nil
    public var statusBefore: String? = nil
    public var custom: [String: String] = [:]
    public init() {}
}

public struct ViewSort: Equatable, Sendable {
    public var field: String
    public var dir: String = "asc" // 'asc' | 'desc'
    public var keepOutline = true
    public init(field: String, dir: String = "asc", keepOutline: Bool = true) { self.field = field; self.dir = dir; self.keepOutline = keepOutline }
}

public struct ViewState: Equatable, Sendable {
    public var search = ""
    public var filter = ViewFilter()
    public var sort: ViewSort? = nil
    public var group: String? = nil // 'tag' | 'mode' | 'critical' | 'status' | 'calendar' | 'constraint' | 'custom:<id>'
    public init() {}
}

public func emptyView() -> ViewState { ViewState() }

public func isFiltering(_ view: ViewState) -> Bool {
    let f = view.filter
    return !jsTrim(view.search).isEmpty || f.critical || f.conflicts || f.incomplete || f.milestones || f.summariesOnly || f.mode != nil
        || !f.tags.isEmpty || f.slackMax != nil || f.slackMin != nil || f.custom.values.contains { !$0.isEmpty }
}

func statusOf(_ r: ScheduledTask) -> String { r.pct >= 100 ? "Complete" : r.pct > 0 ? "In progress" : "Not started" }

/// A sortable value: numbers sort as numbers, text as text (JavaScript's < on mixed values is avoided by keeping one kind per field).
public enum SortValue: Comparable, Sendable {
    case num(Double)
    case text(String)
    public static func < (a: SortValue, b: SortValue) -> Bool {
        switch (a, b) {
        case (.num(let x), .num(let y)): return x < y
        case (.text(let x), .text(let y)): return x < y
        case (.num, .text): return true
        case (.text, .num): return false
        }
    }
}

public func sortValue(_ project: Project, _ sched: ScheduleResult, _ i: Int, _ field: String) -> SortValue {
    let t = project.tasks[i], r = sched.tasks[i]
    switch field {
    case "id": return .num(Double(i + 1))
    case "wbs": return .text(r.wbs.split(separator: ".").map { String(repeating: "0", count: max(0, 6 - $0.count)) + $0 }.joined(separator: "."))
    case "name": return .text(t.name.lowercased())
    case "duration": return .num(r.duration)
    case "start": return .text(r.startStamp ?? "")
    case "finish": return .text(r.finishStamp ?? "")
    case "pct": return .num(r.pct)
    case "totalSlack": return .num(r.totalSlack ?? .infinity)
    case "freeSlack": return .num(r.freeSlack ?? .infinity)
    case "deadline": return .text(nonEmpty(t.deadline) ?? "9999")
    case "mode": return .text(r.isSummary ? "summary" : t.mode)
    case "priority": return .num(Double(r.priority))
    case "taskType": return .text(r.taskType)
    case "inactive": return .num(r.inactive ? 1 : 0)
    case "onTimeline": return .num(r.onTimeline ? 1 : 0)
    case "hideBar": return .num(r.hideBar ? 1 : 0)
    case "rollup": return .num(r.rollup ? 1 : 0)
    default:
        if field.hasPrefix("custom:") {
            let v = t.custom[String(field.dropFirst(7))]
            switch v {
            case .string(let s)?: return .text(s.lowercased())
            case .number(let n)?: return .num(n)
            case .bool(let b)?: return .num(b ? 1 : 0)
            default: return .text("")
            }
        }
        return .text("")
    }
}

func matchesSearch(_ project: Project, _ i: Int, _ r: ScheduledTask, _ text: String) -> Bool {
    let t = project.tasks[i]
    let q = jsTrim(text).lowercased()
    if q.isEmpty { return true }
    let hay = ([String(i + 1), r.wbs, t.name, t.notes, t.tags.joined(separator: " ")] + t.custom.pairs.map { $0.1.jsString })
        .joined(separator: "\u{0001}").lowercased()
    return q.split(whereSeparator: { $0.isWhitespace }).allSatisfy { hay.contains($0) }
}

func matchesFilter(_ project: Project, _ sched: ScheduleResult, _ i: Int, _ f: ViewFilter) -> Bool {
    let t = project.tasks[i], r = sched.tasks[i]
    if f.critical && !r.critical { return false }
    if f.conflicts && !(r.hasConflict || r.childConflict) { return false }
    if f.incomplete && r.pct >= 100 { return false }
    if f.milestones && !r.isMilestone { return false }
    if f.summariesOnly && !r.isSummary { return false }
    if let m = f.mode, r.isSummary || t.mode != m { return false }
    if !f.tags.isEmpty && !f.tags.contains(where: { t.tags.contains($0) }) { return false }
    if let mx = f.slackMax, !(r.totalSlack != nil && r.totalSlack! <= mx) { return false }
    if let mn = f.slackMin, !(r.totalSlack != nil && r.totalSlack! >= mn) { return false }
    if let sb = nonEmpty(f.statusBefore), !(r.finish != nil && r.finish! <= sb && r.pct < 100) { return false }
    for (id, v) in f.custom where !v.isEmpty {
        let have = t.custom[id].map { $0.isNull ? "" : $0.jsString } ?? ""
        if !have.lowercased().contains(v.lowercased()) { return false }
    }
    return true
}

public enum RowItem: Equatable, Sendable {
    case task(Int)
    case group(String, count: Int)
    public var index: Int? { if case .task(let i) = self { return i }; return nil }
}

public struct BuiltRows: Sendable {
    public var rows: [RowItem]
    public var matched: Set<Int>
    public var active: Bool
    public var flat: Bool
}

public func buildRows(_ project: Project, _ sched: ScheduleResult, _ view: ViewState = ViewState()) -> BuiltRows {
    let n = project.tasks.count
    let parent = parentIndexes(project.tasks)
    let filtering = isFiltering(view)
    var matched = Set<Int>()
    if filtering {
        for i in 0..<n where matchesSearch(project, i, sched.tasks[i], view.search) && matchesFilter(project, sched, i, view.filter) { matched.insert(i) }
    }
    // rows to show: matches plus their ancestors (so the outline still makes sense)
    var show = Set<Int>()
    if filtering {
        for i in matched { show.insert(i); var p = parent[i]; while p >= 0 { show.insert(p); p = parent[p] } }
    }
    func isShown(_ i: Int) -> Bool { !filtering || show.contains(i) }
    // collapse: hide descendants of collapsed summaries, unless filtering (matches are always visible)
    var hiddenByCollapse = Array(repeating: false, count: n)
    if !filtering {
        for i in 0..<n { let p = parent[i]; if p >= 0 && (project.tasks[p].collapsed || hiddenByCollapse[p]) { hiddenByCollapse[i] = true } }
    }
    var order: [Int] = []
    let sort = view.sort.flatMap { $0.field.isEmpty ? nil : $0 }
    let dir = sort?.dir == "desc" ? -1 : 1
    let group = nonEmpty(view.group)
    var values: [Int: SortValue] = [:]
    func sv(_ i: Int) -> SortValue {
        if let v = values[i] { return v }
        let v = sortValue(project, sched, i, sort!.field)
        values[i] = v
        return v
    }
    func cmp(_ a: Int, _ b: Int) -> Bool {
        let x = sv(a), y = sv(b)
        let c = x < y ? -1 : y < x ? 1 : 0
        let d = dir * c
        return d != 0 ? d < 0 : a < b
    }
    if let s = sort, group == nil, s.keepOutline {
        // sort siblings within each parent, keep the outline structure
        var kids: [Int: [Int]] = [:]
        for i in 0..<n { kids[parent[i], default: []].append(i) }
        func walk(_ p: Int) {
            for i in (kids[p] ?? []).sorted(by: cmp) { order.append(i); walk(i) }
        }
        walk(-1)
    } else if sort != nil || group != nil {
        order = Array(0..<n)
        if sort != nil { order.sort(by: cmp) }
    } else { order = Array(0..<n) }

    let flat = group != nil || (sort != nil && sort!.keepOutline == false)
    var rows: [RowItem] = []
    if let g = group {
        var groups: [String: [Int]] = [:]
        var groupOrder: [String] = []
        for i in order {
            if !isShown(i) || (filtering && !matched.contains(i)) { continue }
            if sched.tasks[i].isSummary { continue } // grouped views list work items only
            for lb in groupLabel(project, sched, i, g) {
                if groups[lb] == nil { groupOrder.append(lb) }
                groups[lb, default: []].append(i)
            }
        }
        let keys = groupOrder.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for k in keys { rows.append(.group(k, count: groups[k]!.count)); for i in groups[k]! { rows.append(.task(i)) } }
    } else {
        for i in order {
            if !isShown(i) { continue }
            if !flat && hiddenByCollapse[i] { continue }
            rows.append(.task(i))
        }
    }
    return BuiltRows(rows: rows, matched: matched, active: filtering || sort != nil || group != nil, flat: flat)
}

func groupLabel(_ project: Project, _ sched: ScheduleResult, _ i: Int, _ group: String) -> [String] {
    let t = project.tasks[i], r = sched.tasks[i]
    switch group {
    case "tag": return t.tags.isEmpty ? ["(no tag)"] : t.tags
    case "mode": return [t.mode == "manual" ? "Manually scheduled" : "Automatically scheduled"]
    case "critical": return [r.critical ? "Critical" : r.nearCritical ? "Near critical" : "Not critical"]
    case "status": return [statusOf(r)]
    case "calendar":
        guard let id = nonEmpty(t.calendarId) else { return ["(project calendar)"] }
        return [project.calendars.first { $0.id == id }?.name ?? "(unknown)"]
    case "constraint": return [t.constraint.type.isEmpty ? "ASAP" : t.constraint.type]
    default:
        if group.hasPrefix("custom:") {
            let v = t.custom[String(group.dropFirst(7))]
            if v == nil || v == .string("") { return ["(blank)"] }
            return [v!.jsString]
        }
        return ["(all)"]
    }
}
