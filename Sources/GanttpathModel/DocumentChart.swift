// The Gantt chart: time range, zoom, and what dragging a bar does (move, resize, % complete, link). Port of gantt.js (chart part).
// The view reports pointer positions in chart coordinates (x from the left edge of the chart, y from the first row).

import Foundation
import GanttpathCore

public struct ChartLayout: Equatable, Sendable {
    public var originDn: Int
    public var endDn: Int
    public var px: Double
    public var width: Double { chartWidth(originDn, endDn, px) }
    public func x(of dn: Double) -> Double { (dn - Double(originDn)) * px }
    public func day(at x: Double) -> Double { Double(originDn) + x / px }
}

public enum ChartPress: Equatable, Sendable {
    case bar(uid: Int, kind: BarGeom.Kind)
    case resizeHandle(uid: Int)
    case pctHandle(uid: Int)
    case linkHandle(uid: Int, end: String)
    case link(key: String)
    case empty(row: Int?)
}

public func linkTypeFor(from: String, to: String) -> String { from == "f" ? (to == "s" ? "FS" : "FF") : (to == "s" ? "SS" : "SF") }
public let LINK_TYPE_NAMES = ["FS": "Finish-to-Start", "SS": "Start-to-Start", "FF": "Finish-to-Finish", "SF": "Start-to-Finish"]

/// Distance from a point to a polyline (for clicking link arrows). Like an SVG stroke with flat ends, a point beyond the end
/// of a segment does not count as near it.
public func distanceToPolyline(_ x: Double, _ y: Double, _ pts: [(Double, Double)]) -> Double {
    var best = Double.infinity
    for i in 1..<max(1, pts.count) {
        let (ax, ay) = pts[i - 1], (bx, by) = pts[i]
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        if len2 == 0 { continue }
        let t = ((x - ax) * dx + (y - ay) * dy) / len2
        if t < 0 || t > 1 { continue }
        let px = ax + t * dx, py = ay + t * dy
        best = min(best, ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot())
    }
    return best
}

extension DocumentModel {
    /// First and last day of the chart for a view `viewWidth` pixels wide, keeping the previous origin while editing.
    public func chartLayout(viewWidth: Double, previous: ChartLayout?) -> ChartLayout {
        let l = ganttLayout(project: project, sched: sched, rows: rows, px: px, viewWidth: viewWidth, opts: ganttOptions,
                            previousOrigin: previous?.originDn)
        return ChartLayout(originDn: l.originDn, endDn: l.endDn, px: px)
    }

    // MARK: zoom

    public var zoomPercentText: String { "\(zoomPercent(px))%" }

    /// The next zoom step in or out (dir > 0: in).
    public func zoomStep(_ dir: Int) -> Double {
        let idx = ZOOM_LEVELS.firstIndex { $0 >= px - 1e-6 }
        var i = idx ?? ZOOM_LEVELS.count - 1
        if abs(ZOOM_LEVELS[i] - px) > 1e-6 && dir < 0 { i = max(0, i - 1) }
        else { i = min(ZOOM_LEVELS.count - 1, max(0, i + (dir > 0 ? 1 : -1))) }
        return ZOOM_LEVELS[i]
    }

    /// Set the day width (clamped to 1...64 px). Returns the day that should stay under `focusX` so the view can keep it there.
    public func setZoom(_ newPx: Double) {
        let next = min(64, max(1, newPx))
        if abs(next - px) < 1e-6 { return }
        px = next
        let v = next
        setPrefs { $0.px = v }
    }

    /// Day width that shows the whole project in `viewWidth` pixels.
    public func fitPx(viewWidth: Double) -> Double? {
        guard let s = parseISO(sched.projectStart), let f = parseISO(sched.projectFinish) else { return nil }
        let span = Double(f - s + 14)
        return min(48, max(1.5, (viewWidth - 40) / span))
    }

    // MARK: pressing the chart

    /// What is under a point of the chart body (rows start at y = 0). Handles are only there for tasks that can be dragged.
    public func hitTest(x: Double, y: Double, layout: ChartLayout, hits: GanttHit) -> ChartPress {
        let rowPos = Int((y / ROW_H).rounded(.down))
        // the middle of a link (clear of both bars) lies above the bars, as on the JavaScript chart
        for L in hits.links {
            let mid = middlePath(L.pts, 8)
            if mid.count >= 2 && distanceToPolyline(x, y, mid) <= 4.5 { return .link(key: L.key) }
        }
        // then bars (and their handles), then the rest of the links
        for b in hits.bars where y >= b.y && y < b.y + ROW_H {
            let mid = b.y + ROW_H / 2
            let left = b.x1, right = b.x2
            let hOff: Double = b.kind == .milestone ? 14 : 10
            if !b.isSummary && !b.inactive {
                if abs(x - (left - hOff)) <= 5.5 && abs(y - mid) <= 5.5 { return .linkHandle(uid: b.uid, end: "s") }
                if abs(x - (right + hOff)) <= 5.5 && abs(y - mid) <= 5.5 { return .linkHandle(uid: b.uid, end: "f") }
            }
            if b.kind == .task && !b.inactive {
                let w = right - left
                let by = b.y + 3
                if w > 24 {
                    let px = left + w * min(100, b.pct) / 100
                    if abs(x - px) <= 5 && y >= by + 14 - 1 && y <= by + 14 + 6 { return .pctHandle(uid: b.uid) }
                }
                if w > 14 && x >= right - 6 && x <= right && y >= by && y <= by + 14 { return .resizeHandle(uid: b.uid) }
            }
            if x >= left - 18 && x <= right + 18 { return .bar(uid: b.uid, kind: b.kind) }
        }
        var best: (String, Double)? = nil
        for L in hits.links {
            let d = distanceToPolyline(x, y, L.pts)
            if d <= 4.5 && (best == nil || d < best!.1) { best = (L.key, d) }
        }
        if let b = best { return .link(key: b.0) }
        return .empty(row: rowPos >= 0 && rowPos < rows.count ? rowPos : nil)
    }

    /// A press that does not start a drag: select what was pressed.
    public func pressChart(_ what: ChartPress, mods: KeyMods) {
        switch what {
        case .link(let key):
            linkSel = key
        case .empty(let row):
            linkSel = nil
            if let r = row, let i = rows[r].index {
                let uid = project.tasks[i].uid
                cursorUid = uid
                if mods.contains(.shift) { setSelection(extendSelection(to: uid)) } else { selectOnly(uid) }
            } else { setSelection([]) }
        case .bar(let uid, _), .resizeHandle(let uid), .pctHandle(let uid), .linkHandle(let uid, _):
            linkSel = nil
            if mods.contains(.shift) { setSelection(extendSelection(to: uid)) }
            else if mods.contains(.command) {
                var next = selection
                if next.contains(uid) { next.remove(uid) } else { next.insert(uid) }
                setSelection(Array(next), anchor: uid)
            } else if !selection.contains(uid) { selectOnly(uid) }
            cursorUid = uid
        }
    }

    // MARK: drags

    /// Moving a bar by `dx` pixels: the whole days it moves.
    public func moveDays(dx: Double) -> Int { Int((dx / px).rounded()) }

    /// The tip shown while moving a bar.
    public func moveTip(uid: Int, days: Int) -> String {
        guard let i = index(of: uid), let s = parseISO(sched.tasks[i].start) else { return "" }
        let d = fmt.date(toISO(s + days))
        return project.tasks[i].mode == "manual" ? "Start \(d)" : "Start no earlier than \(d)"
    }

    /// Finish the move of a bar by `days` whole days.
    public func commitMove(uid: Int, days: Int) {
        guard days != 0, let i = index(of: uid), let s = parseISO(sched.tasks[i].start) else { return }
        let r = sched.tasks[i]
        let t = project.tasks[i]
        let oldC = t.constraint
        let res = run("Move task") { d, _ in try moveBarTo(&d, uid, s + days, r.timed ? r.startMin : nil) }
        if res.ok && t.mode == "auto", let nt = taskByUid(project, uid) {
            let replaced = oldC.type != "ASAP" && oldC.type != "SNET" ? " (replaces \(CONSTRAINT_NAMES[oldC.type] ?? oldC.type))" : ""
            say("Start No Earlier Than \(fmt.date(nt.constraint.date)) set\(replaced). Predecessor links can still hold the task later.", .info, 4.2)
        }
    }

    /// The new finish day while dragging the right end of a bar by `dx` pixels, and the tip text.
    public func resizeTarget(uid: Int, dx: Double) -> (finishDn: Int, tip: String)? {
        guard let i = index(of: uid), let s = parseISO(sched.tasks[i].start), let f = parseISO(sched.tasks[i].finish) else { return nil }
        let r = sched.tasks[i]
        let newFin = max(s, f + Int((dx / px).rounded()))
        let cal = calendarOf(project, project.tasks[i])
        let startTick = r.startTick ?? cal.normStart(s * 1440)
        let min = max(0, cal.posOf(cal.normFinish((newFin + 1) * 1440)) - cal.posOf(startTick))
        return (newFin, "Duration \(formatDuration(min, r.durUnit, project.settings)), finish \(fmt.date(toISO(newFin)))")
    }

    public func commitResize(uid: Int, finishDn: Int) {
        guard let i = index(of: uid), let f = parseISO(sched.tasks[i].finish), finishDn != f else { return }
        run("Resize task") { d, s in try resizeBarTo(&d, uid, finishDn, s) }
    }

    /// % complete for a pointer at `x` over a bar (steps of 5).
    public func pctAt(uid: Int, x: Double, layout: ChartLayout) -> Double? {
        guard let i = index(of: uid), let g = barGeom(sched.tasks[i], layout.originDn, layout.px), g.x2 > g.x1 else { return nil }
        return max(0, min(100, jsRound((x - g.x1) / (g.x2 - g.x1) * 100 / 5) * 5))
    }
    public func commitPct(uid: Int, pct: Double) {
        guard let i = index(of: uid), pct != jsRound(sched.tasks[i].pct) else { return }
        run("Set % complete") { d, s in try setPercent(&d, uid, pct, s) }
    }

    /// Which end of the target bar a link drag points at.
    public func linkTargetEnd(bar: GanttHit.Bar, x: Double) -> String {
        bar.kind == .milestone ? (x < bar.x1 ? "s" : "f") : (x < (bar.x1 + bar.x2) / 2 ? "s" : "f")
    }

    public func commitLinkDrag(from uid: Int, fromEnd: String, to target: Int, toEnd: String) {
        if uid == target { return }
        let type = linkTypeFor(from: fromEnd, to: toEnd)
        let idOf = uidToIdMap(project)
        let r = run("Link tasks") { d, _ in try addLink(&d, uid, target, type) }
        if r.ok {
            linkSel = "\(uid)>\(target)"
            say("Linked task \(idOf(uid).map(String.init) ?? "") to task \(idOf(target).map(String.init) ?? "") (\(type)). Double-click the arrow to change the type or add lag.", .info, 4.5)
        }
    }

    /// Double-clicking a bar or a row number opens the task panel.
    public func openInspector() {
        inspectorOpen = true
        setPrefs { $0.inspectorOpen = true }
        emit(.openInspector)
    }
}
