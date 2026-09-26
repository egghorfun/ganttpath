// The Gantt chart: time-scale header and the body (bars, links), with dragging: move, resize, % complete, link, and
// clicking links. Esc gives a drag up (gantt.js chart part).

import AppKit
import SwiftUI
import GanttpathCore
import GanttpathModel

final class ChartHeaderView: FlippedView, PaneChild {
    weak var pane: GanttPaneView?

    override func draw(_ dirtyRect: NSRect) {
        guard let p = pane, let l = p.layoutInfo, let ctx = NSGraphicsContext.current?.cgContext else { return }
        p.theme.headerBg.ns.setFill()
        bounds.fill()
        let s = p.scale
        let wcal = projectCalendar(p.model.project)
        let d = ganttHeader(originDn: l.originDn, endDn: l.endDn, px: l.px, mondayFirst: p.model.project.settings.weekStartsMonday,
                            nonWorking: { !wcal.isWorking($0) }, theme: p.theme, font: p.state.font)
        ctx.saveGState()
        ctx.translateBy(x: -(p.chartScroll.contentView.bounds.origin.x), y: 0)
        ctx.scaleBy(x: s, y: s)
        CGRenderer.draw(d.items, in: ctx)
        ctx.restoreGState()
    }
}

final class ChartBodyView: FlippedView, PaneChild {
    weak var pane: GanttPaneView?
    override var acceptsFirstResponder: Bool { true }

    enum Drag {
        case move(uid: Int, bar: GanttHit.Bar, startX: Double, days: Int)
        case resize(uid: Int, bar: GanttHit.Bar, startX: Double, finishDn: Int?, newX2: Double)
        case pct(uid: Int, pct: Double?)
        case link(uid: Int, end: String, from: CGPoint, to: CGPoint, target: (uid: Int, end: String, bar: GanttHit.Bar)?)
    }
    private var drag: Drag? = nil
    private var active = false
    private var tip: String? = nil
    private var pointer: NSPoint = .zero
    private var downPoint: NSPoint = .zero
    private var sliceTop = 0

    private var model: DocumentModel? { pane?.model }
    private var scale: Double { pane?.scale ?? 1 }

    /// Rows drawn (and hit-tested) for a rectangle of the view.
    private func rowRange(_ r: NSRect) -> (Int, Int)? {
        guard let m = model, !m.rows.isEmpty else { return nil }
        let s = scale
        let first = max(0, Int((Double(r.minY) / s / ROW_H).rounded(.down)) - 1)
        let last = min(m.rows.count - 1, Int((Double(r.maxY) / s / ROW_H).rounded(.up)) + 1)
        return first <= last ? (first, last) : nil
    }

    private func body(_ first: Int, _ last: Int) -> GanttBody? {
        guard let p = pane, let l = p.layoutInfo else { return nil }
        let m = p.model
        let wcal = projectCalendar(m.project)
        var o = m.ganttOptions
        o.font = p.state.font
        return ganttBody(project: m.project, sched: m.sched, rows: m.rows, first: first, last: last, px: l.px, originDn: l.originDn, endDn: l.endDn,
                         posOf: m.posOf, opts: o, theme: p.theme, nonWorking: { !wcal.isWorking($0) })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let p = pane, let ctx = NSGraphicsContext.current?.cgContext else { return }
        p.theme.bg.ns.setFill()
        dirtyRect.fill()
        let s = p.scale
        guard let rr = rowRange(dirtyRect), let b = body(rr.0, rr.1) else { return }
        let first = rr.0
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 0, y: Double(first) * ROW_H)
        CGRenderer.draw(b.drawing.items, in: ctx)
        ctx.restoreGState()
        drawDragFeedback(ctx, p)
    }

    private func drawDragFeedback(_ ctx: CGContext, _ p: GanttPaneView) {
        guard let d = drag, active else { return }
        let s = p.scale
        let accent = p.theme.accent
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.setStrokeColor(accent.cg)
        ctx.setLineWidth(2)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        switch d {
        case .move(_, let bar, _, let days):
            let dx = Double(days) * (p.layoutInfo?.px ?? 1)
            let top = bar.y
            if bar.kind == .milestone {
                let x = bar.x1 + dx, mid = top + ROW_H / 2
                ctx.addLines(between: [CGPoint(x: x, y: mid - 8), CGPoint(x: x + 8, y: mid), CGPoint(x: x, y: mid + 8), CGPoint(x: x - 8, y: mid), CGPoint(x: x, y: mid - 8)])
            } else {
                ctx.addRect(CGRect(x: bar.x1 + dx, y: top + 3, width: bar.x2 - bar.x1, height: 14))
            }
            ctx.strokePath()
        case .resize(_, let bar, _, _, let newX2):
            ctx.addRect(CGRect(x: bar.x1, y: bar.y + 3, width: max(2, newX2 - bar.x1), height: 14))
            ctx.strokePath()
        case .link(_, _, let from, let to, let target):
            ctx.move(to: from); ctx.addLine(to: to)
            ctx.strokePath()
            if let t = target {
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setLineWidth(3)
                ctx.addRect(CGRect(x: t.bar.x1 - 2, y: t.bar.y + 1, width: max(4, t.bar.x2 - t.bar.x1 + 4), height: 18))
                ctx.strokePath()
            }
        case .pct: break
        }
        ctx.restoreGState()
        if let t = tip { drawTip(t, at: pointer, in: ctx, theme: p.theme) }
    }

    /// Hits of the rows around the visible area, in chart coordinates (y from the first row of the table).
    private func visibleHits() -> GanttHit? {
        guard let rr = rowRange(visibleRect), let b = body(rr.0, rr.1) else { return nil }
        let first = rr.0
        var h = b.hits
        let dy = Double(first) * ROW_H
        for i in h.bars.indices { h.bars[i].y += dy }
        for i in h.links.indices { h.links[i].pts = h.links[i].pts.map { ($0.0, $0.1 + dy) } }
        return h
    }

    private func logical(_ e: NSEvent) -> (Double, Double) {
        let pt = convert(e.locationInWindow, from: nil)
        return (Double(pt.x) / scale, Double(pt.y) / scale)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        guard let p = pane, let l = p.layoutInfo, let hits = visibleHits() else { return }
        let m = p.model
        window?.makeFirstResponder(self)
        let (x, y) = logical(event)
        let press = m.hitTest(x: x, y: y, layout: l, hits: hits)
        downPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            switch press {
            case .link(let key): showLinkEditor(key, at: downPoint)
            case .bar, .resizeHandle, .pctHandle, .linkHandle: m.openInspector()
            default: break
            }
            return
        }
        m.pressChart(press, mods: event.keyMods)
        func bar(_ uid: Int) -> GanttHit.Bar? { hits.bars.first { $0.uid == uid } }
        active = false
        switch press {
        case .linkHandle(let uid, let end):
            guard let b = bar(uid) else { return }
            let from = CGPoint(x: end == "s" ? b.x1 : b.x2, y: b.y + ROW_H / 2)
            drag = .link(uid: uid, end: end, from: from, to: from, target: nil)
        case .pctHandle(let uid):
            drag = .pct(uid: uid, pct: nil)
        case .resizeHandle(let uid):
            guard let b = bar(uid) else { return }
            drag = .resize(uid: uid, bar: b, startX: x, finishDn: nil, newX2: b.x2)
        case .bar(let uid, _):
            guard let b = bar(uid), !b.isSummary, !b.inactive else { return }
            drag = .move(uid: uid, bar: b, startX: x, days: 0)
        default:
            drag = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pane, let l = p.layoutInfo, let d = drag else { return }
        let m = p.model
        let (x, y) = logical(event)
        pointer = convert(event.locationInWindow, from: nil)
        switch d {
        case .move(let uid, let bar, let startX, _):
            if !active && abs(x - startX) * scale < 4 { return }
            active = true
            let days = m.moveDays(dx: x - startX)
            drag = .move(uid: uid, bar: bar, startX: startX, days: days)
            tip = m.moveTip(uid: uid, days: days)
        case .resize(let uid, let bar, let startX, _, _):
            if !active && abs(x - startX) * scale < 3 { return }
            active = true
            if let r = m.resizeTarget(uid: uid, dx: x - startX), let s = parseISO(m.sched.tasks[m.index(of: uid)!].start) {
                let newX2 = l.x(of: Double(r.finishDn + 1))
                drag = .resize(uid: uid, bar: bar, startX: startX, finishDn: r.finishDn, newX2: max(l.x(of: Double(s)) + 2, newX2))
                tip = r.tip
            }
        case .pct(let uid, _):
            active = true
            let v = m.pctAt(uid: uid, x: x, layout: l)
            drag = .pct(uid: uid, pct: v)
            tip = v.map { "\(Int($0))% complete" }
        case .link(let uid, let end, let from, _, _):
            if !active && hypot(x - Double(from.x), y - Double(from.y)) * scale < 4 && hypot(pointer.x - downPoint.x, pointer.y - downPoint.y) < 4 { return }
            active = true
            var target: (uid: Int, end: String, bar: GanttHit.Bar)? = nil
            if let hits = visibleHits(), let b = hits.bars.first(where: { y >= $0.y && y < $0.y + ROW_H && x >= $0.x1 - 18 && x <= $0.x2 + 18 && $0.uid != uid }) {
                target = (b.uid, m.linkTargetEnd(bar: b, x: x), b)
            }
            drag = .link(uid: uid, end: end, from: from, to: CGPoint(x: x, y: y), target: target)
            if let t = target { let type = linkTypeFor(from: end, to: t.end); tip = "\(type): \(LINK_TYPE_NAMES[type] ?? type)" } else { tip = nil }
        }
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let p = pane, let d = drag else { return }
        let m = p.model
        let was = active
        drag = nil; active = false; tip = nil
        needsDisplay = true
        guard was else { return }
        switch d {
        case .move(let uid, _, _, let days): m.commitMove(uid: uid, days: days)
        case .resize(let uid, _, _, let fin, _): if let f = fin { m.commitResize(uid: uid, finishDn: f) }
        case .pct(let uid, let pct): if let v = pct { m.commitPct(uid: uid, pct: v) }
        case .link(let uid, let end, _, _, let target): if let t = target { m.commitLinkDrag(from: uid, fromEnd: end, to: t.uid, toEnd: t.end) }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let m = model else { return }
        if event.keyCode == 53, drag != nil, active {
            let what: String
            switch drag! { case .move: what = "Move"; case .resize: what = "Resize"; case .pct: what = "Change"; case .link: what = "Link" }
            drag = nil; active = false; tip = nil; needsDisplay = true
            m.say("\(what) cancelled.", .info, 1.5)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, let key = m.linkSel { m.deleteLink(key); return }
        // everything else behaves as in the table
        pane?.tableBody.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            guard let p = pane else { return }
            let x = Double(convert(event.locationInWindow, from: nil).x - p.chartScroll.contentView.bounds.origin.x)
            if event.scrollingDeltaY != 0 { p.zoomBy(event.scrollingDeltaY > 0 ? 1 : -1, focusX: x) }
            return
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let p = pane, let l = p.layoutInfo, let hits = visibleHits() else { return nil }
        let m = p.model
        let (x, y) = logical(event)
        let pt = convert(event.locationInWindow, from: nil)
        switch m.hitTest(x: x, y: y, layout: l, hits: hits) {
        case .link(let key):
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Edit link…") { [weak self] in self?.showLinkEditor(key, at: pt) })
            menu.addItem(ClosureMenuItem("Delete link") { m.deleteLink(key) })
            return menu
        case .bar(let uid, _), .resizeHandle(let uid), .pctHandle(let uid), .linkHandle(let uid, _):
            if !m.selection.contains(uid) { m.selectOnly(uid) }
            return rowContextMenu(p.state, at: event, in: self)
        case .empty: return nil
        }
    }

    // MARK: popovers

    func showLinkEditor(_ key: String, at pt: NSPoint) {
        guard let p = pane else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: LinkEditorView(key: key, close: { [weak pop] in pop?.close() }).environment(p.state))
        pop.show(relativeTo: NSRect(x: pt.x, y: pt.y, width: 1, height: 1), of: self, preferredEdge: .maxY)
    }

    func showTags(uids: [Int], at pt: NSPoint) {
        guard let p = pane else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: TagsPopoverView(uids: uids).environment(p.state))
        pop.show(relativeTo: NSRect(x: pt.x, y: pt.y, width: 1, height: 1), of: self, preferredEdge: .maxY)
    }
}
