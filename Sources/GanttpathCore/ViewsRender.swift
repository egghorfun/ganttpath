// The four non-Gantt views as drawing items: network diagram, timeline summary, critical-path rows and S-curve.
// Port of views.js. The toolbars and KPI boxes around them are built by the app; this is what goes on the canvas
// (and into image and PDF exports).

import Foundation

/// JS `s.length > n ? s.slice(0, max(1, n - 1)) + '…' : s` (lengths in UTF-16 units, as in JavaScript).
public func truncJS(_ s: String, _ n: Int) -> String {
    let u = Array(s.utf16)
    if u.count <= n { return s }
    return String(decoding: u.prefix(max(1, n - 1)), as: UTF16.self) + "…"
}

/// Places a view can be clicked (drawing coordinates).
public struct ViewHit: Sendable {
    public var uid: Int
    public var x: Double, y: Double, w: Double, h: Double
    public func contains(_ px: Double, _ py: Double) -> Bool { px >= x && px <= x + w && py >= y && py <= y + h }
}

public struct ViewDrawing: Sendable {
    public var drawing: Drawing
    public var hits: [ViewHit]
    public static let empty = ViewDrawing(drawing: Drawing(width: 0, height: 0), hits: [])
}

// MARK: - network diagram

public func networkDrawing(_ p: Project, _ sc: ScheduleResult, layout lay: NetworkLayout, theme: Theme, showCritical: Bool = true,
                           selected: Set<Int> = [], font: String = "system") -> ViewDrawing {
    let pad: Double = 20
    let W = lay.width + pad * 2, H = lay.height + pad * 2
    var items: [DrawItem] = []
    var heads: [DrawItem] = []
    func c(_ k: String) -> RGBA { theme.c[k] ?? .black }
    let muted = TextStyle(size: 9.5, color: theme.muted, font: font)
    for e in lay.edges {
        let (col, w, dash): (RGBA, Double, [Double]) = e.conflict ? (c("conflict"), 2, [5, 3]) : e.critical && showCritical ? (c("critical"), 2, []) : (c("arrow"), 1.3, [])
        items.append(D.poly(e.points, stroke: Stroke(col, w, dash: dash)))
        let (ex, ey) = e.points[e.points.count - 1]
        heads.append(D.poly([(ex, ey), (ex - 7, ey - 3.5), (ex - 7, ey + 3.5)], fill: col, closed: true))
        let lagText = formatLag(e.lag)
        if e.type != "FS" || !lagText.isEmpty {
            let (ax, ay) = e.points[0]
            items.append(D.text(e.type + lagText, ax + 4, ay - 3, muted))
        }
    }
    items += heads
    var hits: [ViewHit] = []
    let fmt = Fmt(p, sc)
    let bgHex = theme.bg.hexString
    for n in lay.nodes {
        let t = p.tasks[n.index], r = sc.tasks[n.index]
        let bad = r.hasConflict, crit = !bad && showCritical && r.critical, near = !bad && !crit && showCritical && r.nearCritical
        var fill = theme.bg
        var stroke = Stroke(theme.gridStrong, 1)
        if selected.contains(t.uid) { fill = theme.sel }
        if crit { stroke = Stroke(c("critical"), 2) }
        if near { stroke = Stroke(c("near"), 2) }
        if bad { stroke = Stroke(c("conflict"), 2.5); fill = .hex(mixColor(theme.cHex["conflict"] ?? "#dc2626", 8, bgHex)) }
        let hdFill: RGBA = crit ? .hex(mixColor(theme.cHex["critical"] ?? "#dc2626", 20, bgHex)) : theme.headerBg
        var g: [DrawItem] = []
        g.append(D.rect(0, 0, n.w, n.h, fill: fill, stroke: stroke, r: 5))
        g.append(.path([.move(0.5, 16), .line(n.w - 0.5, 16), .line(n.w - 0.5, 5.5), .quad(n.w - 0.5, 0.5, n.w - 5.5, 0.5), .line(5.5, 0.5), .quad(0.5, 0.5, 0.5, 5.5), .close], fill: hdFill, stroke: nil))
        let dim = TextStyle(size: 10.5, color: theme.muted, font: font)
        g.append(D.text("\(r.id)\(r.isSummary ? "  Summary" : r.isMilestone ? "  ◆ Milestone" : "")", 7, 12, dim))
        var right = dim; right.anchor = .end
        g.append(D.text(r.wbs, n.w - 7, 12, right))
        let name = TextStyle(size: 11, bold: true, italic: t.nameItalic, underline: t.nameUnderline, color: theme.text, font: font)
        g.append(D.text((r.hasConflict ? "⚠ " : "") + truncJS(t.name.isEmpty ? "(unnamed)" : t.name, r.hasConflict ? 22 : 25), 7, 31, name))
        let dates = r.isMilestone ? fmt.datePlain(r.startStamp) : "\(fmt.datePlain(r.startStamp)) → \(fmt.datePlain(r.finishStamp))"
        g.append(D.text(dates, 7, 47, dim))
        let slack = r.totalSlackMin == nil ? "" : "Slack \(fmt.span(r.totalSlackMin))"
        g.append(D.text(fmt.dur(r) + (slack.isEmpty ? "" : "   " + slack), 7, 59, dim))
        items.append(.group(dx: n.x, dy: n.y, scale: 1, g))
        hits.append(ViewHit(uid: t.uid, x: n.x + pad, y: n.y + pad, w: n.w, h: n.h))
    }
    return ViewDrawing(drawing: Drawing(width: W, height: H, background: theme.bg, items: [.group(dx: pad, dy: pad, scale: 1, items)]), hits: hits)
}

// MARK: - timeline

public enum TimelineMilestones: String, Sendable { case top, all, none }

public struct TimelineData: Sendable {
    public struct Bar: Sendable { public var uid: Int; public var wbs: String; public var name: String; public var sDn: Int; public var fDn: Int; public var sIso: String; public var fIso: String; public var critical: Bool; public var conflict: Bool; public var pct: Double }
    public struct Milestone: Sendable { public var uid: Int; public var name: String; public var iso: String; public var dn: Int; public var conflict: Bool }
    public var bars: [Bar] = []
    public var milestones: [Milestone] = []
    public var lo = Int.max
    public var hi = Int.min
}

public func timelineData(_ p: Project, _ sc: ScheduleResult, milestones: TimelineMilestones) -> TimelineData {
    var d = TimelineData()
    let hasSummary = sc.tasks.contains { $0.isSummary && p.tasks[$0.index].level == 1 }
    for (i, t) in p.tasks.enumerated() {
        let r = sc.tasks[i]
        guard let s = r.start, let f = r.finish, !s.isEmpty, !f.isEmpty, !r.inactive, let sDn = parseISO(s), let fDn = parseISO(f) else { continue }
        let asked = t.onTimeline
        if r.isMilestone {
            if !asked && milestones == .none { continue }
            if !asked && milestones == .top && t.level > 2 { continue }
            d.milestones.append(.init(uid: t.uid, name: t.name.isEmpty ? "(unnamed)" : t.name, iso: s, dn: sDn, conflict: r.hasConflict))
            d.lo = min(d.lo, sDn); d.hi = max(d.hi, sDn)
            continue
        }
        if asked || (t.level == 1 && (hasSummary ? r.isSummary : true)) {
            d.bars.append(.init(uid: t.uid, wbs: r.wbs, name: t.name.isEmpty ? "(unnamed)" : t.name, sDn: sDn, fDn: fDn, sIso: s, fIso: f,
                                critical: r.critical, conflict: r.hasConflict || r.childConflict, pct: r.pct))
            d.lo = min(d.lo, sDn); d.hi = max(d.hi, fDn)
        }
    }
    // stable sort by day (JS Array.prototype.sort is stable)
    d.milestones = d.milestones.enumerated().sorted { $0.element.dn != $1.element.dn ? $0.element.dn < $1.element.dn : $0.offset < $1.offset }.map { $0.element }
    return d
}

/// The timeline view at `zoom` (1 = fit `availWidth`). Nil-drawing when there is nothing to draw.
public func timelineDrawing(_ p: Project, _ sc: ScheduleResult, milestones mode: TimelineMilestones = .top, zoom: Double = 1, availWidth: Double = 1000,
                            theme: Theme, showCritical: Bool = true, today: Int? = todayDn(), font: String = "system") -> ViewDrawing? {
    let data = timelineData(p, sc, milestones: mode)
    if data.bars.isEmpty && data.milestones.isEmpty { return nil }
    let fmt = Fmt(p, sc)
    let availW = max(600, availWidth - 2)
    let labelW: Double = 230
    let lo = data.lo, hi = data.hi
    let originDn = lo - 7
    let RIGHT: Double = 200
    let px = max(0.5, ((availW - labelW - RIGHT) / Double(hi + 14 - originDn)) * zoom)
    let endDn = hi + 14 + Int((RIGHT / px).rounded(.up))
    let W = labelW + (Double(endDn - originDn) * px).rounded(.up) + 12
    let wcal = projectCalendar(p)
    func c(_ k: String) -> RGBA { theme.c[k] ?? .black }

    var laneEnd: [Double] = []
    struct Placed { var m: TimelineData.Milestone; var cx: Double; var lane: Int; var label: String }
    var placed: [Placed] = []
    for m in data.milestones {
        let cx = Double(m.dn - originDn) * px
        let label = "\(m.name)  \(fmt.datePlain(m.iso))"
        let wLab = Double(label.utf16.count) * 5.9 + 18
        var lane = laneEnd.firstIndex { $0 < cx - 8 } ?? -1
        if lane < 0 { lane = laneEnd.count; laneEnd.append(0) }
        laneEnd[lane] = cx + wLab
        placed.append(Placed(m: m, cx: cx, lane: lane, label: label))
    }
    let LANE_H: Double = 19
    let msH: Double = placed.isEmpty ? 0 : Double(max(1, laneEnd.count)) * LANE_H + 14
    let ROWH: Double = 30
    let bodyTop = HEADER_H + msH
    let H = bodyTop + Double(data.bars.count) * ROWH + 16
    var items: [DrawItem] = []
    let hdr = ganttHeader(originDn: originDn, endDn: endDn, px: px, mondayFirst: p.settings.weekStartsMonday, nonWorking: { !wcal.isWorking($0) }, theme: theme, font: font)
    items.append(.group(dx: labelW, dy: 0, scale: 1, hdr.items))
    items.append(D.rect(0, 0, labelW, HEADER_H, fill: theme.headerBg))
    items.append(D.line(0, HEADER_H - 0.5, labelW, HEADER_H - 0.5, Stroke(theme.gridStrong, 1)))
    items.append(D.text("Summary task", 10, HEADER_H - 12, TextStyle(size: 11, bold: true, color: theme.text, font: font)))
    // month grid lines
    var grid: [PathOp] = []
    var dn = monthStartDn(originDn)
    var i = 0
    while i < 400 && dn <= endDn {
        if dn >= originDn { let x = labelW + Double(dn - originDn) * px; grid += [.move(x, HEADER_H), .line(x, H)] }
        dn = nextMonthDn(dn); i += 1
    }
    if !grid.isEmpty { items.append(.path(grid, fill: nil, stroke: Stroke(theme.gridStrong.alpha(0.6), 1))) }
    if let t0 = today, t0 >= originDn, t0 <= endDn { let x = labelW + (Double(t0) + 0.5 - Double(originDn)) * px; items.append(D.line(x, HEADER_H, x, H, Stroke(c("today"), 1.5))) }
    if let sd = parseISO(p.settings.statusDate), sd >= originDn, sd <= endDn { let x = labelW + (Double(sd) + 1 - Double(originDn)) * px; items.append(D.line(x, HEADER_H, x, H, Stroke(c("status"), 1.5, dash: [5, 3]))) }
    var hits: [ViewHit] = []
    let text = TextStyle(size: 11, color: theme.text, font: font)
    if !placed.isEmpty {
        items.append(D.text("Milestones", 10, HEADER_H + 15, TextStyle(size: 10, color: theme.muted, font: font)))
        for m in placed {
            let cx = labelW + m.cx, cy = HEADER_H + 10 + Double(m.lane) * LANE_H + 7
            let col = m.m.conflict ? c("conflict") : c("summary")
            items.append(D.poly([(cx, cy - 6.5), (cx + 6.5, cy), (cx, cy + 6.5), (cx - 6.5, cy)], fill: col, closed: true))
            let s = (m.m.conflict ? "⚠ " : "") + m.label
            items.append(D.text(s, cx + 10, cy + 4, text))
            hits.append(ViewHit(uid: m.m.uid, x: cx - 7, y: cy - 7, w: 17 + Double(s.utf16.count) * 6, h: 14))
        }
        items.append(D.line(0, bodyTop - 3.5, W, bodyTop - 3.5, Stroke(theme.grid, 1)))
    }
    for (k, b) in data.bars.enumerated() {
        let y = bodyTop + Double(k) * ROWH
        let x1 = labelW + Double(b.sDn - originDn) * px, x2 = labelW + Double(b.fDn + 1 - originDn) * px
        let col = b.conflict ? c("conflict") : showCritical && b.critical ? c("critical") : c("task")
        items.append(D.text(truncJS(b.wbs + "  " + b.name, 34), 10, y + ROWH / 2 + 4, TextStyle(size: 11, bold: true, color: theme.text, font: font)))
        items.append(D.rect(x1, y + 6, max(3, x2 - x1), ROWH - 12, fill: col, r: 3))
        if b.pct > 0 { items.append(D.rect(x1, y + ROWH - 10, max(0, (x2 - x1) * b.pct / 100), 4, fill: RGBA(0, 0, 0, 0.35), r: 1)) }
        items.append(D.text("\(fmt.datePlain(b.sIso)) → \(fmt.datePlain(b.fIso))", x2 + 6, y + ROWH / 2 + 4, TextStyle(size: 10.5, color: theme.muted, font: font)))
        items.append(D.line(0, y + ROWH - 0.5, W, y + ROWH - 0.5, Stroke(theme.grid, 1)))
        hits.append(ViewHit(uid: b.uid, x: 0, y: y, w: W, h: ROWH))
    }
    return ViewDrawing(drawing: Drawing(width: W, height: H, background: theme.bg, items: items), hits: hits)
}

// MARK: - critical path table

public enum CpmFilter: String, Sendable, CaseIterable { case all, critical, near, conflict }

public struct CpmState: Equatable, Sendable {
    public var filter: CpmFilter = .all
    public var sort = "id"
    public var desc = false
    public var summaries = false
    public init() {}
}

public struct CpmColumn: Sendable {
    public var id: String
    public var title: String
    public var numeric: Bool
}

public let CPM_COLS: [CpmColumn] = [
    .init(id: "id", title: "ID", numeric: true), .init(id: "wbs", title: "WBS", numeric: false), .init(id: "name", title: "Task Name", numeric: false),
    .init(id: "duration", title: "Duration", numeric: true), .init(id: "es", title: "Early Start", numeric: false), .init(id: "ef", title: "Early Finish", numeric: false),
    .init(id: "ls", title: "Late Start", numeric: false), .init(id: "lf", title: "Late Finish", numeric: false), .init(id: "ts", title: "Total Slack", numeric: true),
    .init(id: "fs", title: "Free Slack", numeric: true), .init(id: "status", title: "Status", numeric: false),
]

public func cpmText(_ col: String, _ r: ScheduledTask, _ t: Task, _ fmt: Fmt) -> String {
    switch col {
    case "id": return String(r.id)
    case "wbs": return r.wbs
    case "name": return t.name
    case "duration": return fmt.dur(r)
    case "es": return fmt.date(r.startStamp)
    case "ef": return fmt.date(r.finishStamp)
    case "ls": return fmt.date(rowLateStart(r))
    case "lf": return fmt.date(rowLateFinish(r))
    case "ts": return fmt.span(r.totalSlackMin)
    case "fs": return fmt.span(r.freeSlackMin)
    case "status": return r.inactive ? "Inactive" : r.hasConflict ? "⚠ Conflict" : r.critical ? "Critical" : r.nearCritical ? "Near critical" : ""
    default: return ""
    }
}

/// "1.10.2" -> "00001.00010.00002" so WBS numbers sort in outline order.
public func wbsKey(_ w: String) -> String {
    w.split(separator: ".", omittingEmptySubsequences: false).map { s in String(repeating: "0", count: max(0, 5 - s.utf16.count)) + s }.joined(separator: ".")
}

enum CpmKey { case n(Double), s(String) }
func cpmLess(_ a: CpmKey, _ b: CpmKey) -> Int {
    switch (a, b) {
    case (.n(let x), .n(let y)): return x < y ? -1 : x > y ? 1 : 0
    case (.s(let x), .s(let y)): return x.utf16.lexicographicallyPrecedes(y.utf16) ? -1 : y.utf16.lexicographicallyPrecedes(x.utf16) ? 1 : 0
    default: return 0
    }
}

/// The Critical Path rows, filtered and sorted exactly like the on-screen table (and its PDF export).
public func cpmRows(_ p: Project, _ sc: ScheduleResult, _ st: CpmState) -> [ScheduledTask] {
    var list = sc.tasks.filter { st.summaries || !$0.isSummary }
    switch st.filter {
    case .critical: list = list.filter { $0.critical }
    case .near: list = list.filter { $0.critical || $0.nearCritical }
    case .conflict: list = list.filter { $0.hasConflict || $0.childConflict }
    case .all: break
    }
    let col = CPM_COLS.contains { $0.id == st.sort } ? st.sort : "id"
    func key(_ r: ScheduledTask) -> CpmKey {
        switch col {
        case "id": return .n(Double(r.id))
        case "wbs": return .s(wbsKey(r.wbs))
        case "name": return .s(p.tasks[r.index].name.lowercased())
        case "duration": return .n(Double(r.durationMin))
        case "es": return .s(r.startStamp ?? "")
        case "ef": return .s(r.finishStamp ?? "")
        case "ls": return .s(rowLateStart(r) ?? "")
        case "lf": return .s(rowLateFinish(r) ?? "")
        case "ts": return .n(r.totalSlackMin.map(Double.init) ?? .infinity)
        case "fs": return .n(r.freeSlackMin.map(Double.init) ?? .infinity)
        default: return .n(Double(r.inactive ? 4 : r.hasConflict ? 0 : r.critical ? 1 : r.nearCritical ? 2 : 3))
        }
    }
    let keys = Dictionary(uniqueKeysWithValues: list.map { ($0.index, key($0)) })
    let sign = st.desc ? -1 : 1
    return list.sorted { a, b in
        var c = cpmLess(keys[a.index]!, keys[b.index]!)
        if c == 0 { c = a.index < b.index ? -1 : a.index > b.index ? 1 : 0 }
        return c * sign < 0
    }
}

/// The KPI boxes above the critical path table: (value, label, bad).
public func cpmKpis(_ p: Project, _ sc: ScheduleResult) -> [(String, String, Bool)] {
    let fmt = Fmt(p, sc)
    let leaves = sc.tasks.filter { !$0.isSummary }
    let d0 = fmt.date(sc.projectStart), d1 = fmt.date(sc.projectFinish)
    return [(String(leaves.filter { $0.critical }.count), "critical tasks", false), (String(leaves.filter { $0.nearCritical }.count), "near critical", false),
            (String(sc.conflictCount), sc.conflictCount == 1 ? "conflict" : "conflicts", sc.conflictCount > 0),
            (d0.isEmpty ? "-" : d0, "project start", false), (d1.isEmpty ? "-" : d1, "project finish", false)]
}

// MARK: - S-curve

/// Number.prototype.toFixed: rounds the exact binary value, ties away from zero (for values below 1e21).
public func jsToFixed(_ v: Double, _ digits: Int) -> String {
    if !v.isFinite || abs(v) >= 1e21 { return jsNumberString(v) }
    if v == 0 { return digits == 0 ? "0" : "0." + String(repeating: "0", count: digits) }
    let neg = v < 0
    // exact decimal expansion (enough digits for any double of this size to be exact or decided)
    let full = String(format: "%.100f", abs(v))
    let parts = full.split(separator: ".")
    var intDigits = Array(parts[0]).map { Int($0.asciiValue! - 48) }
    let frac = Array(parts[1]).map { Int($0.asciiValue! - 48) }
    var keep = Array(frac.prefix(digits))
    let roundUp = frac.count > digits && frac[digits] >= 5
    if roundUp {
        var i = keep.count - 1
        var carry = 1
        while carry > 0 && i >= 0 { keep[i] += 1; if keep[i] == 10 { keep[i] = 0; i -= 1 } else { carry = 0 } }
        if carry > 0 {
            var j = intDigits.count - 1
            while carry > 0 && j >= 0 { intDigits[j] += 1; if intDigits[j] == 10 { intDigits[j] = 0; j -= 1 } else { carry = 0 } }
            if carry > 0 { intDigits.insert(1, at: 0) }
        }
    }
    var out = intDigits.map(String.init).joined()
    if digits > 0 { out += "." + keep.map(String.init).joined() }
    return (neg ? "-" : "") + out
}

public func scurveKpis(_ data: SCurve) -> [(String, String, Bool)] {
    guard let s = data.status else { return [] }
    func pct(_ v: Double?) -> String { v.map { "\(jsToFixed($0, 1))%" } ?? "-" }
    return [(pct(s.planned), "planned by status date", false), (pct(s.earned), "complete (weighted)", false), (pct(s.forecast), "forecast by status date", false),
            (s.spi.map { jsToFixed($0, 2) } ?? "-", "schedule performance index", false),
            (s.variance.map { "\($0 >= 0 ? "+" : "")\(jsToFixed($0, 1)) pts" } ?? "-", "ahead (+) or behind (−)", (s.variance ?? 0) < -0.05)]
}

public struct SCurveGeometry: Sendable {
    public var ml: Double = 52, pw: Double = 980 - 52 - 22, mt: Double = 18, ph: Double = 440 - 18 - 42
    public var d0: Int, d1: Int
    public var dns: [Int]
    public func xs(_ dn: Double) -> Double { ml + ((dn - Double(d0)) / Double(max(1, d1 - d0))) * pw }
    public func ys(_ v: Double) -> Double { mt + ph - (v / 100) * ph }
    /// Index of the point nearest to x (for the hover read-out).
    public func nearest(_ x: Double) -> Int? {
        if x < ml || x > ml + pw || dns.isEmpty { return nil }
        let dn = Double(d0) + ((x - ml) / pw) * Double(d1 - d0)
        var k = 0
        for i in dns.indices where abs(Double(dns[i]) - dn) < abs(Double(dns[k]) - dn) { k = i }
        return k
    }
}

/// The S-curve chart (980 x 440). Nil when there is nothing to plot.
public func scurveDrawing(_ p: Project, _ data: SCurve, baseline: Int, theme: Theme, today: Int? = todayDn(), font: String = "system") -> (ViewDrawing, SCurveGeometry)? {
    if data.dates.isEmpty { return nil }
    let Wc: Double = 980, Hc: Double = 440
    let dns = data.dates.map { parseISO($0)! }
    let g = SCurveGeometry(d0: dns[0], d1: dns[dns.count - 1], dns: dns)
    let ml = g.ml, pw = g.pw, mt = g.mt, ph = g.ph
    func c(_ k: String) -> RGBA { theme.c[k] ?? .black }
    func r1(_ v: Double) -> Double { Double(jsToFixed(v, 1)) ?? v }
    func path(_ arr: [Double?]) -> [PathOp] {
        var ops: [PathOp] = []
        var pen = false
        for (i, v) in arr.enumerated() {
            guard let v = v else { pen = false; continue }
            let pt = (r1(g.xs(Double(dns[i]))), r1(g.ys(v)))
            ops.append(pen ? .line(pt.0, pt.1) : .move(pt.0, pt.1))
            pen = true
        }
        return ops
    }
    let fmt = Fmt(p, nil)
    var items: [DrawItem] = []
    let grid = Stroke(theme.grid, 1)
    var muted = TextStyle(size: 11, color: theme.muted, anchor: .end, font: font)
    for v in stride(from: 0.0, through: 100, by: 20) {
        items.append(D.line(ml, g.ys(v), ml + pw, g.ys(v), grid))
        items.append(D.text("\(Int(v))%", ml - 8, g.ys(v) + 4, muted))
    }
    let ticks = 7
    for i in 0...ticks {
        let dn = Int(jsRound(Double(g.d0) + Double((g.d1 - g.d0) * i) / Double(ticks)))
        let x = g.xs(Double(dn))
        items.append(D.line(x, mt, x, mt + ph, grid))
        muted.anchor = i == ticks ? .end : .middle
        items.append(D.text(formatDate(dn, fmt.dateFormat), x, mt + ph + 18, muted))
    }
    items.append(D.poly([(ml, mt), (ml, mt + ph), (ml + pw, mt + ph)], stroke: Stroke(theme.gridStrong, 1)))
    if let t = today, t >= g.d0, t <= g.d1 { let x = g.xs(Double(t) + 0.5); items.append(D.line(x, mt, x, mt + ph, Stroke(c("today"), 1.5))) }
    let statusDate = p.settings.statusDate
    if let sdn = parseISO(statusDate), sdn >= g.d0, sdn <= g.d1 { let x = g.xs(Double(sdn)); items.append(D.line(x, mt, x, mt + ph, Stroke(c("status"), 1.5, dash: [5, 3]))) }
    let planned = Stroke(c("arrow"), 2.2, dash: [6, 3]), forecast = Stroke(c("task"), 2.6), actual = Stroke(c("progressline"), 2.8)
    let status = Stroke(c("status"), 1.5, dash: [5, 3]), todayS = Stroke(c("today"), 1.5)
    if data.hasBaseline { items.append(.path(path(data.planned), fill: nil, stroke: planned)) }
    items.append(.path(path(data.forecast.map { Optional($0) }), fill: nil, stroke: forecast))
    if statusDate != nil { items.append(.path(path(data.actual), fill: nil, stroke: actual)) }
    var lx = ml + 10
    var legend: [(Stroke, String)] = [(forecast, "Forecast (current schedule)")]
    if data.hasBaseline { legend.append((planned, "Planned (\(BASELINE_NAMES[max(0, min(5, baseline))]))")) }
    if statusDate != nil { legend.append((actual, "Actual (approximate)")); legend.append((status, "Status date")) }
    legend.append((todayS, "Today"))
    let text = TextStyle(size: 11, color: theme.text, font: font)
    for (s, label) in legend {
        items.append(D.line(lx, mt + 14, lx + 22, mt + 14, s))
        items.append(D.text(label, lx + 28, mt + 18, text))
        lx += 40 + Double(label.utf16.count) * 6.2
    }
    return (ViewDrawing(drawing: Drawing(width: Wc, height: Hc, background: theme.bg, items: items), hits: []), g)
}

/// The hover read-out of the S-curve for point k.
public func scurveTip(_ p: Project, _ data: SCurve, _ k: Int) -> String {
    let fmt = Fmt(p, nil)
    func f(_ v: Double?) -> String { v.map { "\(jsToFixed($0, 1))%" } ?? "-" }
    var s = "\(fmt.date(data.dates[k]))   Forecast \(f(data.forecast[k]))"
    if data.hasBaseline { s += "   Planned \(f(data.planned[k]))" }
    if p.settings.statusDate != nil, let a = data.actual[k] { s += "   Actual \(f(a))" }
    return s
}
