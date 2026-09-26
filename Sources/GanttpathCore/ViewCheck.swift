// Table cell texts, Gantt chart geometry, critical-path rows and timeline data of a project as JSON, in the shape the
// JavaScript comparison script writes, so the Swift and JavaScript apps can be compared value by value (gpcli view-dir
// and the golden tests use it). `k` picks the view options, varied from project to project.

import Foundation

private func num(_ v: Double) -> JSON { .number(v) }

private func linkD(_ pts: [(Double, Double)]) -> String {
    var d = "M\(jsNumberString(pts[0].0)) \(jsNumberString(pts[0].1))"
    for i in 1..<pts.count { d += pts[i].1 == pts[i - 1].1 ? "H\(jsNumberString(pts[i].0))" : "V\(jsNumberString(pts[i].1))" }
    return d
}

private func textsOf(_ items: [DrawItem]) -> [(String, Double, Double)] {
    var out: [(String, Double, Double)] = []
    for it in items {
        switch it {
        case .text(let s, let x, let y, _, _): if !s.isEmpty { out.append((s, x, y)) }
        case .clip(_, _, _, _, let inner), .group(_, _, _, let inner): out += textsOf(inner)
        default: break
        }
    }
    return out
}

public func viewCheckJSON(_ input: Project, _ k: Int) -> JSON {
    do {
        var p = input
        let s = scheduleAndApply(&p)
        let showBaseline = (k % 3) - 1
        let cols = allColumns(p, s)
        let fmt = Fmt(p, s)
        var table: [JSON] = []
        for i in p.tasks.indices {
            let x = CellContext(project: p, sched: s, index: i, fmt: fmt, showBaseline: showBaseline)
            table.append(.array(cols.map { c in
                .array([.string(c.text(x)), .string(c.cls(x)), c.edit.map { .string($0.raw(x)) } ?? .null, .bool(c.edit?.disabled(x) ?? false)])
            }))
        }
        // chart
        let px = ZOOM_LEVELS[k % ZOOM_LEVELS.count]
        let rows = buildRows(p, s, ViewState()).rows
        let posOf = positions(rows)
        let lo = parseISO(s.projectStart) ?? parseISO(p.settings.startDate)!
        let hi = s.projectFinish != nil ? parseISO(s.projectFinish)! : lo + 30
        let mon = p.settings.weekStartsMonday
        let originDn = lo - (mon ? (dow(lo) + 6) % 7 : dow(lo)) - 7
        let endDn = hi + 45
        let wcal = projectCalendar(p)
        var o = GanttOptions()
        o.showBaseline = showBaseline; o.showCritical = k % 4 != 1; o.showLabels = k % 5 != 2
        o.statusDn = parseISO(p.settings.statusDate); o.todayDn = 20600
        o.progressLine = o.statusDn != nil && k % 2 == 0; o.mondayFirst = mon
        let theme = Theme.light
        let head = ganttHeader(originDn: originDn, endDn: endDn, px: px, mondayFirst: mon, nonWorking: { !wcal.isWorking($0) }, theme: theme)
        var bars: [JSON] = [], links: [JSON] = []
        var pl: JSON = .null
        var nw = 0
        if !rows.isEmpty {
            let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: rows.count - 1, px: px, originDn: originDn, endDn: endDn,
                                 posOf: posOf, opts: o, theme: theme, nonWorking: { !wcal.isWorking($0) })
            let texts = textsOf(body.drawing.items)
            let rolls = rollupsOf(p, s)
            for b in body.hits.bars {
                let t = p.tasks[b.index], r = s.tasks[b.index]
                var st: JSON = .null
                if b.kind != .summary {
                    let v = barState(t, r, showCritical: o.showCritical)
                    st = .string(b.kind == .milestone && v == .custom ? "normal" : v.rawValue)
                }
                var roll = 0
                if b.kind == .summary, let rl = rolls?[b.index] {
                    for kk in rl where posOf[kk] == nil && barGeom(s.tasks[kk], originDn, px) != nil { roll += 1 }
                }
                var hasBase = false
                if showBaseline >= 0, let bl = t.baselines[showBaseline], parseISO(bl.start) != nil, parseISO(bl.finish) != nil { hasBase = true }
                let mine = texts.filter { $0.2 >= b.y && $0.2 < b.y + ROW_H }
                bars.append(.array([num(Double(b.uid)), .string(b.kind.rawValue), num(b.x1), num(b.x2), num(b.y), st, num(Double(roll)), .bool(hasBase),
                                    .array(mine.map { .array([.string($0.0), num($0.1), num($0.2)]) })]))
            }
            for L in body.hits.links {
                let li = s.links[L.index]
                let crit = o.showCritical && s.tasks[li.pIndex].critical && s.tasks[li.tIndex].critical
                let cls = li.conflict ? "link link-bad" : crit ? "link link-crit" : "link"
                links.append(.array([.string(L.key), .string(cls), .string(linkD(L.pts))]))
            }
            for it in body.drawing.items {
                if case .rect(_, _, _, _, _, let fill, _) = it, fill == theme.nonwork { nw += 1 }
                if case .path(let ops, nil, let stroke?) = it, stroke.width == 1.6 {
                    pl = .string(ops.compactMap { op -> String? in
                        if case .move(let x, let y) = op { return "\(jsNumberString(x)),\(jsNumberString(y))" }
                        if case .line(let x, let y) = op { return "\(jsNumberString(x)),\(jsNumberString(y))" }
                        return nil
                    }.joined(separator: " "))
                }
            }
        }
        let chart = JSONObject([
            ("px", num(px)), ("originDn", num(Double(originDn))), ("endDn", num(Double(endDn))),
            ("head", .array(textsOf(head.items).map { .array([.string($0.0), num($0.1), num($0.2)]) })),
            ("bars", .array(bars)), ("links", .array(links)), ("pl", pl), ("nw", num(Double(nw))),
            ("opts", .object(JSONObject([("showBaseline", num(Double(o.showBaseline))), ("showCritical", .bool(o.showCritical)),
                                         ("showLabels", .bool(o.showLabels)), ("progressLine", .bool(o.progressLine))]))),
        ])
        var cst = CpmState()
        cst.filter = [CpmFilter.all, .critical, .near, .conflict][k % 4]
        cst.sort = CPM_COLS[k % CPM_COLS.count].id
        cst.desc = k % 2 == 1
        cst.summaries = k % 3 == 0
        let cpm: [JSON] = cpmRows(p, s, cst).map { r in .array([num(Double(r.index))] + CPM_COLS.map { .string(cpmText($0.id, r, p.tasks[r.index], fmt)) }) }
        let tl = timelineData(p, s, milestones: [TimelineMilestones.top, .all, .none][k % 3])
        let tlJSON = JSONObject([
            ("bars", .array(tl.bars.map { .array([num(Double($0.uid)), .string($0.wbs), .string($0.name), num(Double($0.sDn)), num(Double($0.fDn)), .bool($0.critical), .bool($0.conflict), num($0.pct)]) })),
            ("milestones", .array(tl.milestones.map { .array([num(Double($0.uid)), .string($0.name), num(Double($0.dn)), .bool($0.conflict)]) })),
        ])
        return .object(JSONObject([
            ("cpm", .array(cpm)), ("tl", .object(tlJSON)),
            ("cols", .array(cols.map { .array([.string($0.id), num($0.width)]) })),
            ("table", .array(table)), ("chart", .object(chart)),
        ]))
    }
}

