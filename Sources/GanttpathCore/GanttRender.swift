// The Gantt chart as drawing items: the two-row time-scale header and the body (bars, links, labels, baselines,
// today / status lines, progress line, roll-ups). Port of chartsvg.js; the screen, PDF and image export all draw these.

import Foundation

public let ROW_H: Double = 26
public let HEADER_H: Double = 44
let BAR_H: Double = 14
let BAR_Y: Double = 3

/// Pixels per day for each zoom step, and the one shown as "100%".
public let ZOOM_LEVELS: [Double] = [1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48]
public let ZOOM_BASE_PX: Double = 12

/// Zoom percentage shown in the toolbar for a pixels-per-day value.
public func zoomPercent(_ px: Double) -> Int { Int(jsRound(px / ZOOM_BASE_PX * 100)) }

// MARK: - time scale

enum TierUnit { case year, month, week, day, dayLetter }

func tiersFor(_ px: Double) -> (TierUnit, TierUnit) {
    if px >= 28 { return (.month, .dayLetter) }
    if px >= 14 { return (.month, .day) }
    if px >= 5 { return (.month, .week) }
    return (.year, .month)
}

func monthStartDn(_ dn: Int) -> Int { let (y, m, _) = dnToYmd(dn); return ymdToDnPlain(y, m, 1) }
func nextMonthDn(_ dn: Int) -> Int { let (y, m, _) = dnToYmd(dn); return m == 12 ? ymdToDnPlain(y + 1, 1, 1) : ymdToDnPlain(y, m + 1, 1) }
func yearStartDn(_ dn: Int) -> Int { ymdToDnPlain(dnToYmd(dn).y, 1, 1) }
func nextYearDn(_ dn: Int) -> Int { ymdToDnPlain(dnToYmd(dn).y + 1, 1, 1) }
func weekStartDn(_ dn: Int, _ mondayFirst: Bool) -> Int { let d = dow(dn); return dn - (mondayFirst ? (d + 6) % 7 : d) }

/// Day number of a calendar date without the Date.UTC two-digit-year quirk (the chart only ever meets 4-digit years,
/// but month stepping must never jump a century).
func ymdToDnPlain(_ y: Int, _ m: Int, _ d: Int) -> Int {
    // days from civil (Howard Hinnant)
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

/// Boundaries [from, to) of one tier unit covering [a, b].
func segments(_ unit: TierUnit, _ a: Int, _ b: Int, _ mondayFirst: Bool) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    switch unit {
    case .year: var s = yearStartDn(a); while s <= b { let e = nextYearDn(s); out.append((s, e)); s = e }
    case .month: var s = monthStartDn(a); while s <= b { let e = nextMonthDn(s); out.append((s, e)); s = e }
    case .week: var s = weekStartDn(a, mondayFirst); while s <= b { out.append((s, s + 7)); s += 7 }
    case .day, .dayLetter: var s = a; while s <= b { out.append((s, s + 1)); s += 1 }
    }
    return out
}

func tierLabel(_ unit: TierUnit, _ s: Int, _ w: Double) -> String {
    let (y, m, day) = dnToYmd(s)
    func p2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
    switch unit {
    case .year: return w >= 34 ? String(y) : ""
    case .month:
        if w >= 110 { return "\(MONTHS_LONG[m - 1]) \(y)" }
        if w >= 62 { return "\(MONTHS[m - 1]) \(y)" }
        if w >= 30 { return MONTHS[m - 1] }
        return ""
    case .week: return w >= 62 ? "\(p2(day)) \(MONTHS[m - 1])" : w >= 22 ? p2(day) : ""
    case .day, .dayLetter: return String(day)
    }
}

/// Chart width in pixels for a day range.
public func chartWidth(_ originDn: Int, _ endDn: Int, _ px: Double) -> Double { (Double(endDn - originDn) * px).rounded(.up) }

/// Two-row time-scale header.
public func ganttHeader(originDn: Int, endDn: Int, px: Double, mondayFirst: Bool = true, nonWorking: ((Int) -> Bool)? = nil,
                        theme: Theme, font: String = "system") -> Drawing {
    let width = chartWidth(originDn, endDn, px)
    var items: [DrawItem] = [D.rect(0, 0, width, HEADER_H, fill: theme.headerBg)]
    let half = HEADER_H / 2
    let line = Stroke(theme.gridStrong, 1)
    let top = TextStyle(size: 11, bold: true, color: theme.text, font: font)
    let (topU, botU) = tiersFor(px)
    for (s, e) in segments(topU, originDn, endDn, mondayFirst) {
        let x = Double(s - originDn) * px, w = Double(e - s) * px
        items.append(D.line(x, 0, x, half, line))
        let vis = min(x + w, width) - max(x, 0)
        let lab = tierLabel(topU, s, vis)
        if !lab.isEmpty { items.append(D.text(lab, max(x, 0) + 5, half - 7, top)) }
    }
    let bot: TierUnit = botU == .dayLetter ? .day : botU
    var sub = TextStyle(size: 10, color: theme.muted, font: font)
    if bot == .day { sub.anchor = .middle }
    for (s, e) in segments(bot, originDn, endDn, mondayFirst) {
        let x = Double(s - originDn) * px, w = Double(e - s) * px
        if bot == .day, let nw = nonWorking, nw(s) { items.append(D.rect(x, half, w, half, fill: theme.nonwork)) }
        items.append(D.line(x, half, x, HEADER_H, line))
        var lab = tierLabel(bot, s, w)
        if botU == .dayLetter { lab += " " + String(Array("SMTWTFS")[dow(s)]) }
        lab = jsTrim(lab)
        if !lab.isEmpty { items.append(D.text(lab, x + (bot == .day ? w / 2 : 4), HEADER_H - 7, sub)) }
    }
    items.append(D.line(0, half, width, half, line))
    items.append(D.line(0, HEADER_H - 0.5, width, HEADER_H - 0.5, line))
    return Drawing(width: width, height: HEADER_H, items: items)
}

// MARK: - bars

public struct BarGeom: Equatable, Sendable {
    public enum Kind: String, Sendable { case task, summary, milestone }
    public var kind: Kind
    public var x1: Double
    public var x2: Double
    /// Milestones: where the diamond sits and where its duration (if any) ends.
    public var x: Double
    public var endX: Double
}

/// Where a task's bar sits (x in pixels from originDn); nil when the task has no dates.
public func barGeom(_ r: ScheduledTask?, _ originDn: Int, _ px: Double) -> BarGeom? {
    guard let r = r, let s = parseISO(r.start), let f = parseISO(r.finish) else { return nil }
    let x1 = (Double(s) + (r.startFrac ?? 0) - Double(originDn)) * px
    let x2 = (Double(f) + (r.finishFrac ?? 1) - Double(originDn)) * px
    if r.isSummary { return BarGeom(kind: .summary, x1: x1, x2: x2, x: x1, endX: x2) }
    if r.isMilestone { return BarGeom(kind: .milestone, x1: x1, x2: x1, x: x1, endX: r.duration == 0 ? x1 : x2) }
    return BarGeom(kind: .task, x1: x1, x2: max(x2, x1 + 2), x: x1, endX: max(x2, x1 + 2))
}

public enum BarState: String, Sendable { case inactive, conflict, critical, near, custom, normal }

public func barState(_ t: Task, _ r: ScheduledTask, showCritical: Bool) -> BarState {
    if r.inactive { return .inactive }
    if r.hasConflict || r.childConflict { return .conflict }
    if showCritical && r.critical { return .critical }
    if showCritical && r.nearCritical { return .near }
    return t.color != nil && !r.isSummary && !r.isMilestone ? .custom : .normal
}

/// What the chart shows. Mirrors chartOptions() of the JS app.
public struct GanttOptions: Sendable {
    public var showBaseline: Int = -1
    /// A second baseline to compare with the shown one (-1 none); drawn as a second thin bar in the "baseline2" colour.
    public var compareBaseline: Int = -1
    /// The compared baseline when it is in use (a baseline is shown and the compared one is another one).
    public var comparing: Int? { showBaseline >= 0 && compareBaseline >= 0 && compareBaseline != showBaseline ? compareBaseline : nil }
    public var showCritical = true
    public var showLabels = true
    public var showLinks = true
    public var statusDn: Int? = nil
    public var todayDn: Int? = nil
    public var selected: Set<Int> = []
    public var linkSel: String? = nil
    public var progressLine = false
    public var mondayFirst = true
    public var font = "system"
    public init() {}
}

/// Options for a project as the app shows it by default.
public func ganttOptions(for p: Project, today: Int? = todayDn()) -> GanttOptions {
    var o = GanttOptions()
    o.statusDn = parseISO(p.settings.statusDate)
    o.todayDn = today
    o.mondayFirst = p.settings.weekStartsMonday
    return o
}

func labelStyle(_ t: Task, _ theme: Theme, _ font: String, inactive: Bool) -> TextStyle {
    TextStyle(size: 11, bold: t.nameBold, italic: t.nameItalic, underline: t.nameUnderline, strike: inactive,
              color: inactive ? theme.muted : theme.text, font: font)
}

/// How far right (px from originDn) the furthest task / milestone name reaches. 0 when labels are off and nothing is in conflict.
public func maxLabelReach(_ rows: [RowItem], _ project: Project, _ sched: ScheduleResult, _ originDn: Int, _ px: Double,
                          _ opts: GanttOptions, measurer: TextMeasurer = HelveticaMeasurer()) -> Double {
    var mx: Double = 0
    for row in rows {
        guard let i = row.index, i < project.tasks.count, i < sched.tasks.count else { continue }
        let t = project.tasks[i], r = sched.tasks[i]
        if r.hideBar { continue }
        guard let g = barGeom(r, originDn, px) else { continue }
        let isConflict = barState(t, r, showCritical: opts.showCritical) == .conflict
        if !opts.showLabels && !isConflict { continue }
        var lx = g.kind == .milestone ? g.x + 12 : g.x2 + (r.isSummary ? 6 : 16)
        if isConflict { lx += 16 }
        var reach = lx
        if opts.showLabels && !t.name.isEmpty { reach += measurer.width(t.name, labelStyle(t, .light, opts.font, inactive: false)) }
        else if isConflict { reach += 14 }
        if reach > mx { mx = reach }
    }
    return mx
}

/// First and last day of the chart (JS computeLayout).
public func ganttLayout(project p: Project, sched sc: ScheduleResult, rows: [RowItem], px: Double, viewWidth: Double,
                        opts: GanttOptions, previousOrigin: Int? = nil, measurer: TextMeasurer = HelveticaMeasurer()) -> (originDn: Int, endDn: Int) {
    var lo = parseISO(sc.projectStart) ?? parseISO(p.settings.startDate) ?? todayDn()
    var hi = sc.projectFinish != nil ? (parseISO(sc.projectFinish) ?? lo + 30) : lo + 30
    for n in [opts.showBaseline, opts.comparing ?? -1] where n >= 0 {
        for t in p.tasks {
            guard n < t.baselines.count, let b = t.baselines[n] else { continue }
            if let s = parseISO(b.start), s < lo { lo = s }
            if let f = parseISO(b.finish), f > hi { hi = f }
        }
    }
    let back = p.settings.weekStartsMonday ? (dow(lo) + 6) % 7 : dow(lo)
    var originDn = lo - back - 7
    if let prev = previousOrigin, prev <= originDn, prev > originDn - 400 { originDn = prev }
    let vw = viewWidth > 0 ? viewWidth : 800
    var endDn = max(hi + 45, originDn + Int((vw / px).rounded(.up)) + 2)
    let reach = maxLabelReach(rows, p, sc, originDn, px, opts, measurer: measurer)
    let needed = originDn + Int((reach / px).rounded(.up)) + 1
    if needed > endDn { endDn = needed }
    return (originDn, endDn)
}

// MARK: - links

struct LinkRoute { var pts: [(Double, Double)]; var head: [(Double, Double)]; var mid: [(Double, Double)] }

func linkRoute(_ a: BarGeom, _ b: BarGeom, _ type: String, _ ay: Double, _ by: Double, _ rowH: Double) -> LinkRoute {
    let fromEnd = type == "FS" || type == "FF"
    let toStart = type == "FS" || type == "SS"
    let x0 = fromEnd ? a.x2 : a.x1
    let x1 = toStart ? b.x1 : b.x2
    let s0 = x0 + (fromEnd ? 9 : -9)
    let s1 = x1 + (toStart ? -9 : 9)
    let yMid = ay + (by >= ay ? 1 : -1) * (rowH / 2)
    var pts: [(Double, Double)]
    switch type {
    case "FS":
        pts = s0 <= s1 ? [(x0, ay), (s0, ay), (s0, by), (x1, by)] : [(x0, ay), (s0, ay), (s0, yMid), (s1, yMid), (s1, by), (x1, by)]
    case "SS": let xv = min(s0, s1); pts = [(x0, ay), (xv, ay), (xv, by), (x1, by)]
    case "FF": let xv = max(s0, s1); pts = [(x0, ay), (xv, ay), (xv, by), (x1, by)]
    default: pts = [(x0, ay), (s0, ay), (s0, yMid), (s1, yMid), (s1, by), (x1, by)]
    }
    let head: [(Double, Double)] = toStart ? [(x1, by), (x1 - 6, by - 3.5), (x1 - 6, by + 3.5)] : [(x1, by), (x1 + 6, by - 3.5), (x1 + 6, by + 3.5)]
    return LinkRoute(pts: pts, head: head, mid: middlePath(pts, 8))
}

/// The part of a link line clear of both bars (what a click on the arrow hits).
public func middlePath(_ pts: [(Double, Double)], _ trim: Double) -> [(Double, Double)] {
    guard pts.count >= 4 else { return [] }
    var p = Array(pts[1..<(pts.count - 1)])
    func sgn(_ v: Double) -> Double { v > 0 ? 1 : v < 0 ? -1 : 0 }
    func cut(_ i: Int, _ j: Int) -> Bool {
        let len = abs(p[j].0 - p[i].0) + abs(p[j].1 - p[i].1)
        if len < 4 { return false }
        let t = min(trim, len * 0.3)
        p[i].0 += sgn(p[j].0 - p[i].0) * t; p[i].1 += sgn(p[j].1 - p[i].1) * t
        return true
    }
    if !cut(0, 1) { return [] }
    if !cut(p.count - 1, p.count - 2) { return [] }
    return p
}

/// For each summary: the hidden-able sub-tasks that roll up their bar onto it.
public func rollupsOf(_ project: Project, _ sched: ScheduleResult) -> [Int: [Int]]? {
    let T = project.tasks
    guard T.contains(where: { $0.rollup }) else { return nil }
    let parent = parentIndexes(T)
    var map: [Int: [Int]] = [:]
    for i in 0..<T.count where i < sched.tasks.count {
        let r = sched.tasks[i]
        if !T[i].rollup || r.isSummary || r.inactive { continue }
        var a = parent[i]
        while a >= 0 { map[a, default: []].append(i); a = parent[a] }
    }
    return map
}

// MARK: - body

/// Clickable places in a rendered body slice, in the slice's own coordinates.
public struct GanttHit: Sendable {
    public struct Bar: Sendable {
        public var uid: Int, index: Int, kind: BarGeom.Kind, x1: Double, x2: Double, y: Double
        public var inactive: Bool, isSummary: Bool, pct: Double
    }
    public struct Link: Sendable { public var key: String; public var index: Int; public var pts: [(Double, Double)] }
    public var bars: [Bar] = []
    public var links: [Link] = []
}

public struct GanttBody: Sendable {
    public var drawing: Drawing
    public var hits: GanttHit
}

/// Diagonal white stripes over a bar (the "conflict" hatch).
func hatch(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> DrawItem {
    var lines: [DrawItem] = []
    let step = 6 * 2.0.squareRoot()
    var k = x - h
    let s = Stroke(RGBA(1, 1, 1, 0.8), 2)
    while k < x + w { lines.append(D.line(k, y + h, k + h, y, s)); k += step }
    return .clip(x: x, y: y, w: w, h: h, lines)
}

/// Body rows first...last. `posOf`: task index -> row position in `rows`.
public func ganttBody(project: Project, sched: ScheduleResult, rows: [RowItem], first: Int, last: Int, px: Double,
                      originDn: Int, endDn: Int, posOf: [Int: Int], opts: GanttOptions, theme: Theme,
                      nonWorking: ((Int) -> Bool)? = nil, rowH: Double = ROW_H) -> GanttBody {
    let width = chartWidth(originDn, endDn, px)
    let n = max(0, last - first + 1)
    let height = Double(n) * rowH
    var items: [DrawItem] = []
    var hits = GanttHit()
    let fo = Double(originDn)

    // non-working days
    if px >= 4, let nw = nonWorking {
        var runS: Int? = nil
        var dn = originDn
        while dn <= endDn {
            let w = nw(dn)
            if w && runS == nil { runS = dn }
            if (!w || dn == endDn), let s = runS {
                let e = w ? dn + 1 : dn
                items.append(D.rect(Double(s - originDn) * px, 0, Double(e - s) * px, height, fill: theme.nonwork))
                runS = nil
            }
            dn += 1
        }
    }
    for i in 0..<n {
        let pos = first + i
        guard pos < rows.count else { continue }
        let y = Double(i) * rowH
        switch rows[pos] {
        case .task(let idx): if opts.selected.contains(project.tasks[idx].uid) { items.append(D.rect(0, y, width, rowH, fill: theme.sel.alpha(0.85))) }
        case .group: items.append(D.rect(0, y, width, rowH, fill: theme.rowAlt))
        }
    }
    // vertical grid
    let (_, botU) = tiersFor(px)
    let bot: TierUnit = botU == .dayLetter ? .day : botU
    let step: TierUnit = bot == .day || bot == .week ? bot : .month
    let minor = Stroke(theme.grid.alpha(0.55), 1), major = Stroke(theme.gridStrong, 1)
    var vl: [PathOp] = [], vm: [PathOp] = []
    for (s, _) in segments(step, originDn, endDn, opts.mondayFirst) {
        let x = Double(s - originDn) * px
        if step == .day && px < 24 && dow(s) != (opts.mondayFirst ? 1 : 0) { continue }
        if step == .day { vl += [.move(x, 0), .line(x, height)] } else { vm += [.move(x, 0), .line(x, height)] }
    }
    if !vl.isEmpty { items.append(.path(vl, fill: nil, stroke: minor)) }
    if !vm.isEmpty { items.append(.path(vm, fill: nil, stroke: major)) }
    var hl: [PathOp] = []
    if n > 0 { for i in 1...n { let y = Double(i) * rowH - 0.5; hl += [.move(0, y), .line(width, y)] } }
    if !hl.isEmpty { items.append(.path(hl, fill: nil, stroke: Stroke(theme.grid, 1))) }

    var geomCache: [Int: BarGeom?] = [:]
    func geomAt(_ idx: Int) -> BarGeom? {
        if let g = geomCache[idx] { return g }
        let g = idx < sched.tasks.count ? barGeom(sched.tasks[idx], originDn, px) : nil
        geomCache[idx] = g
        return g
    }
    func c(_ k: String) -> RGBA { theme.c[k] ?? .black }
    func cd(_ k: String) -> RGBA { theme.cDark[k] ?? .black }

    if let td = opts.todayDn, td >= originDn, td <= endDn {
        let x = (Double(td) + 0.5 - fo) * px
        items.append(D.line(x, 0, x, height, Stroke(c("today"), 1.5)))
    }
    if let sd = opts.statusDn, sd >= originDn, sd <= endDn {
        let x = (Double(sd) + 1 - fo) * px
        items.append(D.line(x, 0, x, height, Stroke(c("status"), 1.5, dash: [5, 3])))
    }

    // links
    if opts.showLinks && !sched.links.isEmpty {
        for (li, L) in sched.links.enumerated() {
            guard let pa = posOf[L.pIndex], let pb = posOf[L.tIndex] else { continue }
            if max(pa, pb) < first - 1 || min(pa, pb) > last + 1 { continue }
            guard let ga = geomAt(L.pIndex), let gb = geomAt(L.tIndex) else { continue }
            let ay = Double(pa - first) * rowH + rowH / 2
            let by = Double(pb - first) * rowH + rowH / 2
            let route = linkRoute(ga, gb, L.type, ay, by, rowH)
            let crit = opts.showCritical && sched.tasks[L.pIndex].critical && sched.tasks[L.tIndex].critical
            let key = "\(L.predUid)>\(L.uid)"
            let (col, w, dash): (RGBA, Double, [Double]) =
                L.conflict ? (c("conflict"), 2, [4, 2]) : opts.linkSel == key ? (theme.accent, 2.5, []) : crit ? (c("critical"), 1.5, []) : (c("arrow"), 1.2, [])
            items.append(D.poly(route.pts, stroke: Stroke(col, w, dash: dash)))
            items.append(D.poly(route.head, fill: col, closed: true))
            hits.links.append(GanttHit.Link(key: key, index: li, pts: route.pts))
        }
    }

    // bars
    let rolls = rollupsOf(project, sched)
    for i in 0..<n {
        let pos = first + i
        guard pos < rows.count, let idx = rows[pos].index, idx < sched.tasks.count else { continue }
        let t = project.tasks[idx], r = sched.tasks[idx]
        guard let g = geomAt(idx) else { continue }
        if r.hideBar { continue }
        let y = Double(i) * rowH
        let st = barState(t, r, showCritical: opts.showCritical)
        let mid = y + rowH / 2
        let by = y + BAR_Y
        let bl: Baseline? = opts.showBaseline >= 0 && opts.showBaseline < t.baselines.count ? t.baselines[opts.showBaseline] : nil
        let done = r.pct >= 100 && !r.isSummary
        let pctC = min(100, r.pct) / 100

        // baseline under the bar
        if let cmp = opts.comparing {
            // two baselines: the shown one and, just under it, the compared one, each 3 px high
            let second: Baseline? = cmp < t.baselines.count ? t.baselines[cmp] : nil
            for (b, off, key) in [(bl, 18.0, "baseline"), (second, 22.0, "baseline2")] {
                guard let b = b, let bs = parseISO(b.start), let bf = parseISO(b.finish) else { continue }
                let top = y + off
                let bx = Double(bs - originDn) * px
                if g.kind == .milestone || b.duration == 0 {
                    items.append(D.poly([(bx, top), (bx + 3, top + 1.75), (bx, top + 3.5), (bx - 3, top + 1.75)], fill: c(key), closed: true))
                } else {
                    items.append(D.rect(bx, top, max(2, Double(bf + 1 - bs) * px), 3, fill: c(key), r: 1))
                }
            }
        } else if let bl = bl, let bs = parseISO(bl.start), let bf = parseISO(bl.finish) {
            let bx = Double(bs - originDn) * px
            if g.kind == .milestone || bl.duration == 0 {
                items.append(D.poly([(bx, y + 19), (bx + 4, y + 22.5), (bx, y + 26), (bx - 4, y + 22.5)], fill: c("baseline"), closed: true))
            } else {
                items.append(D.rect(bx, y + 19, max(2, Double(bf + 1 - bs) * px), 4, fill: c("baseline"), r: 1))
            }
        }
        switch g.kind {
        case .task:
            let w = g.x2 - g.x1
            var fill: RGBA?, stroke: Stroke?
            switch st {
            case .inactive: fill = nil; stroke = Stroke(theme.muted, 1, dash: [3, 2])
            case .custom: fill = .hex(t.color ?? "#888888"); stroke = Stroke(RGBA(0, 0, 0, 0.35), 1)
            case .critical: fill = c("critical"); stroke = Stroke(cd("critical"), 1)
            case .near: fill = c("near"); stroke = Stroke(cd("near"), 1)
            case .conflict: fill = c("conflict"); stroke = Stroke(cd("conflict"), 1)
            case .normal: fill = c("task"); stroke = Stroke(cd("task"), 1)
            }
            if r.isManual && st != .inactive { fill = fill?.alpha(0.55); stroke?.dash = [3, 2] }
            if done { fill = fill?.alpha(0.72); if var sk = stroke { sk.color = sk.color.alpha(0.72); stroke = sk } }
            items.append(D.rect(g.x1, by, w, BAR_H, fill: fill, stroke: stroke, r: 3))
            if st == .conflict { items.append(hatch(g.x1, by, w, BAR_H)) }
            if r.pct > 0 && !r.inactive { items.append(D.rect(g.x1, by + BAR_H - 5, max(0, w * pctC), 4, fill: RGBA(0, 0, 0, 0.42), r: 1)) }
        case .summary:
            let y0 = y + 5
            let fill = st == .conflict ? c("conflict") : opts.showCritical && r.critical ? c("critical") : c("summary")
            items.append(D.poly([(g.x1, y0), (g.x2, y0), (g.x2, y0 + 12), (g.x2 - 6, y0 + 6), (g.x1 + 6, y0 + 6), (g.x1, y0 + 12)], fill: fill, closed: true))
            if r.pct > 0 { items.append(D.rect(g.x1, y0 + 1, max(0, (g.x2 - g.x1) * pctC), 3, fill: RGBA(0, 0, 0, 0.42))) }
            if let rolled = rolls?[idx] {
                for k in rolled where posOf[k] == nil {
                    guard let gk = geomAt(k) else { continue }
                    let sk = barState(project.tasks[k], sched.tasks[k], showCritical: opts.showCritical)
                    let key = sk == .critical ? "critical" : sk == .conflict ? "conflict" : sk == .near ? "near" : "task"
                    if gk.kind == .milestone {
                        let mk = sk == .critical || sk == .conflict || sk == .near ? key : "summary"
                        items.append(D.poly([(gk.x, mid - 5), (gk.x + 5, mid), (gk.x, mid + 5), (gk.x - 5, mid)], fill: c(mk), stroke: Stroke(c(mk), 1), closed: true))
                    } else {
                        items.append(D.rect(gk.x1, mid - 4, max(2, gk.x2 - gk.x1), 8, fill: c(key), stroke: Stroke(theme.bg, 1), r: 2))
                    }
                }
            }
        case .milestone:
            let s = 7.5
            let pts = [(g.x, mid - s), (g.x + s, mid), (g.x, mid + s), (g.x - s, mid)]
            if st == .inactive { items.append(D.poly(pts, stroke: Stroke(theme.muted, 1), closed: true)) }
            else {
                let key = st == .critical ? "critical" : st == .conflict ? "conflict" : st == .near ? "near" : "summary"
                items.append(D.poly(pts, fill: c(key), stroke: Stroke(c(key), 1), closed: true))
            }
            // JS draws this "duration tail" as a path with only a fill, which paints nothing; kept invisible here too.
        }
        let left = g.kind == .milestone ? g.x : g.x1
        let right = g.kind == .milestone ? g.x : g.x2
        let lx = g.kind == .milestone ? g.x + 12 : g.x2 + (r.isSummary ? 6 : 16)
        let warn = TextStyle(size: 12, bold: true, color: c("conflict"), font: opts.font)
        if opts.showLabels {
            if st == .conflict {
                items.append(D.text("⚠", lx, mid + 4.5, warn))
                items.append(D.text(t.name, lx + 16, mid + 4, labelStyle(t, theme, opts.font, inactive: false)))
            } else if !t.name.isEmpty {
                items.append(D.text(t.name, lx, mid + 4, labelStyle(t, theme, opts.font, inactive: r.inactive)))
            }
        } else if st == .conflict {
            items.append(D.text("⚠", lx, mid + 4.5, warn))
        }
        hits.bars.append(GanttHit.Bar(uid: t.uid, index: idx, kind: g.kind, x1: left, x2: right, y: y, inactive: r.inactive, isSummary: r.isSummary, pct: r.pct))
    }

    // progress line
    if opts.progressLine, let sd = opts.statusDn, !rows.isEmpty {
        var pts: [(Double, Double)] = []
        let sx = (Double(sd) + 1 - fo) * px
        let lo = max(0, first - 1), hi = min(rows.count - 1, last + 1)
        if lo <= hi {
            for pos in lo...hi {
                guard let idx = rows[pos].index, idx < sched.tasks.count else { continue }
                let r = sched.tasks[idx]
                if r.isSummary { continue }
                guard let g = geomAt(idx) else { continue }
                let x: Double
                if r.pct >= 100 { x = sx } else if r.pct > 0 { x = g.x1 + (g.x2 - g.x1) * (r.pct / 100) } else { x = g.x1 < sx ? g.x1 : sx }
                pts.append((x, Double(pos - first) * rowH + rowH / 2))
            }
        }
        if pts.count > 1 { items.append(D.poly(pts, stroke: Stroke(c("progressline"), 1.6, roundJoin: true))) }
    }
    return GanttBody(drawing: Drawing(width: width, height: height, items: items), hits: hits)
}

/// Row position of every task index shown in `rows`.
public func positions(_ rows: [RowItem]) -> [Int: Int] {
    var m: [Int: Int] = [:]
    for (i, r) in rows.enumerated() { if let idx = r.index { m[idx] = i } }
    return m
}
