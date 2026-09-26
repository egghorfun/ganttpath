// The Gantt tab: task table on the left, chart on the right, one shared vertical scroll (gantt.js).
// Both sides are AppKit views that paint drawings from GanttpathModel / GanttpathCore; only the rows on screen are drawn.

import AppKit
import SwiftUI
import GanttpathCore
import GanttpathModel

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What the SwiftUI side and the menu bar ask the Gantt pane to do.
@MainActor
final class GanttPaneController {
    weak var view: GanttPaneView?
    func scrollToToday() { view?.scrollToToday() }
    func fitProject() { view?.fitProject() }
    func zoomBy(_ dir: Int) { view?.zoomBy(dir) }
    func scrollTo(uid: Int) { view?.scrollTo(uid: uid) }
}

struct GanttPane: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> GanttPaneView {
        let v = GanttPaneView(state: state)
        let c = GanttPaneController()
        c.view = v
        state.gantt = c
        return v
    }
    func updateNSView(_ nsView: GanttPaneView, context: Context) { nsView.refresh() }
}

final class GanttPaneView: FlippedView {
    let state: AppState
    var model: DocumentModel { state.model }
    let tableHeader: TableHeaderView
    let tableScroll = NSScrollView()
    let tableBody: TableBodyView
    let splitter: SplitterView
    let chartHeader: ChartHeaderView
    let chartScroll = NSScrollView()
    let chartBody: ChartBodyView
    var layoutInfo: ChartLayout? = nil
    private var syncing = false

    var scale: Double { state.uiScale }
    var theme: Theme { state.theme }

    init(state: AppState) {
        self.state = state
        tableHeader = TableHeaderView()
        tableBody = TableBodyView()
        splitter = SplitterView()
        chartHeader = ChartHeaderView()
        chartBody = ChartBodyView()
        super.init(frame: .zero)
        for v in [tableHeader, tableBody, splitter, chartHeader, chartBody] as [PaneChild] { v.pane = self }
        for (s, doc) in [(tableScroll, tableBody as NSView), (chartScroll, chartBody as NSView)] {
            s.documentView = doc
            s.hasVerticalScroller = s === chartScroll
            s.hasHorizontalScroller = true
            s.autohidesScrollers = true
            s.drawsBackground = false
            s.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: s.contentView)
            addSubview(s)
        }
        addSubview(tableHeader); addSubview(splitter); addSubview(chartHeader)
        model.onEvent = { [weak self] e in self?.handle(e) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: model changes

    /// Re-read the model and redraw; asks to be called again whenever anything it read changes.
    func refresh() {
        withObservationTracking {
            _ = model.revision; _ = model.built.rows.count; _ = model.selection; _ = model.cursorUid; _ = model.cursorCol; _ = model.anchorCol
            _ = model.px; _ = model.view; _ = model.clip?.text; _ = model.linkSel; _ = model.columnIds; _ = model.colWidths; _ = model.tableWidth
            _ = model.showBaseline; _ = model.showCritical; _ = model.showLabels; _ = model.showLinks; _ = model.progressLine; _ = model.selMode
            _ = state.prefsVersion; _ = state.systemDark
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        relayout()
        for v in [tableHeader, tableBody, chartHeader, chartBody] as [NSView] { v.needsDisplay = true }
    }

    func relayout() {
        let s = scale
        let total = bounds.width > 0 ? bounds.width : 1200
        let content = model.tableContentWidth
        let want = model.tableWidth ?? min(content + 2, (total * 0.55).rounded())
        let tw = max(180, min(want, total - 240))
        let hh = HEADER_H * s
        tableHeader.frame = NSRect(x: 0, y: 0, width: tw, height: hh)
        tableScroll.frame = NSRect(x: 0, y: hh, width: tw, height: max(0, bounds.height - hh))
        splitter.frame = NSRect(x: tw, y: 0, width: 5, height: bounds.height)
        chartHeader.frame = NSRect(x: tw + 5, y: 0, width: max(0, total - tw - 5), height: hh)
        chartScroll.frame = NSRect(x: tw + 5, y: hh, width: max(0, total - tw - 5), height: max(0, bounds.height - hh))
        let prevOrigin = layoutInfo?.originDn
        let l = model.chartLayout(viewWidth: chartScroll.contentSize.width / s, previous: layoutInfo)
        layoutInfo = l
        let rowsH = (Double(model.rows.count + 1) * ROW_H + 60) * s
        tableBody.frame.size = NSSize(width: max(content * s, tw), height: max(rowsH, tableScroll.contentSize.height))
        chartBody.frame.size = NSSize(width: l.width * s, height: max(rowsH, chartScroll.contentSize.height))
        if let p = prevOrigin, p != l.originDn {
            // the chart grew to the left: keep the same days on screen
            var o = chartScroll.contentView.bounds.origin
            o.x += Double(p - l.originDn) * l.px * s
            chartScroll.contentView.scroll(to: o)
            chartScroll.reflectScrolledClipView(chartScroll.contentView)
        }
    }

    override func layout() { super.layout(); relayout() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); relayout() }

    @objc func scrolled(_ n: Notification) {
        if syncing { return }
        syncing = true
        defer { syncing = false }
        if (n.object as? NSClipView) === chartScroll.contentView {
            var o = tableScroll.contentView.bounds.origin
            o.y = chartScroll.contentView.bounds.origin.y
            tableScroll.contentView.scroll(to: o)
            tableScroll.reflectScrolledClipView(tableScroll.contentView)
        } else {
            var o = chartScroll.contentView.bounds.origin
            o.y = tableScroll.contentView.bounds.origin.y
            chartScroll.contentView.scroll(to: o)
            chartScroll.reflectScrolledClipView(chartScroll.contentView)
        }
        tableHeader.needsDisplay = true
        chartHeader.needsDisplay = true
    }

    // MARK: scrolling commands

    func scrollTo(uid: Int) {
        model.reveal(uid)
        relayout()
        guard let i = model.index(of: uid), let pos = model.posOf[i] else { return }
        let s = scale
        let y = Double(pos) * ROW_H * s, rh = ROW_H * s
        let visible = chartScroll.contentView.bounds
        var o = visible.origin
        if y < visible.minY { o.y = max(0, y - rh) }
        else if y + rh > visible.maxY - 20 { o.y = y - visible.height + rh * 2 + 20 }
        else { return }
        chartScroll.contentView.scroll(to: o)
        chartScroll.reflectScrolledClipView(chartScroll.contentView)
    }

    func scrollToTaskBar(uid: Int) {
        scrollTo(uid: uid)
        guard let i = model.index(of: uid), let s = parseISO(model.sched.tasks[i].start), let l = layoutInfo else { return }
        let x = l.x(of: Double(s)) * scale
        let vis = chartScroll.contentView.bounds
        if x < vis.minX || x > vis.maxX - 100 {
            chartScroll.contentView.scroll(to: NSPoint(x: max(0, x - vis.width / 3), y: vis.origin.y))
            chartScroll.reflectScrolledClipView(chartScroll.contentView)
        }
    }

    func scrollToToday() {
        guard let l = layoutInfo else { return }
        let x = l.x(of: Double(model.env.today())) * scale
        let vis = chartScroll.contentView.bounds
        chartScroll.contentView.scroll(to: NSPoint(x: max(0, x - vis.width / 3), y: vis.origin.y))
        chartScroll.reflectScrolledClipView(chartScroll.contentView)
    }

    func scrollToStart() {
        chartScroll.contentView.scroll(to: .zero)
        chartScroll.reflectScrolledClipView(chartScroll.contentView)
    }

    /// Change the day width keeping the day under `focusX` (px from the left of the chart view; the middle when nil) in place.
    func setZoom(_ px: Double, focusX: Double? = nil) {
        guard let l = layoutInfo else { model.setZoom(px); return }
        let s = scale
        let vis = chartScroll.contentView.bounds
        let fx = focusX ?? vis.width / 2
        let dnAt = l.day(at: (vis.minX + fx) / s)
        model.setZoom(px)
        relayout()
        guard let nl = layoutInfo else { return }
        chartScroll.contentView.scroll(to: NSPoint(x: max(0, nl.x(of: dnAt) * s - fx), y: vis.origin.y))
        chartScroll.reflectScrolledClipView(chartScroll.contentView)
        needsDisplayAll()
    }

    func zoomBy(_ dir: Int, focusX: Double? = nil) { setZoom(model.zoomStep(dir), focusX: focusX) }

    func fitProject() {
        guard let px = model.fitPx(viewWidth: chartScroll.contentSize.width / scale), let s = parseISO(model.sched.projectStart) else { return }
        setZoom(px)
        guard let l = layoutInfo else { return }
        chartScroll.contentView.scroll(to: NSPoint(x: max(0, l.x(of: Double(s - 3)) * scale), y: chartScroll.contentView.bounds.origin.y))
        chartScroll.reflectScrolledClipView(chartScroll.contentView)
    }

    func needsDisplayAll() { for v in [tableHeader, tableBody, chartHeader, chartBody] as [NSView] { v.needsDisplay = true } }

    // MARK: model events

    func handle(_ e: ModelEvent) {
        switch e {
        case .scrollTo(let uid): DispatchQueue.main.async { self.scrollTo(uid: uid) }
        case .focusName(let uid):
            DispatchQueue.main.async {
                self.scrollTo(uid: uid)
                self.tableBody.beginEdit(uid: uid, col: "name", initial: nil)
            }
        case .gotoTask(let uid):
            model.tab = .gantt
            DispatchQueue.main.async { self.scrollToTaskBar(uid: uid) }
        case .scrollToStart: DispatchQueue.main.async { self.scrollToStart() }
        case .openInspector: break
        }
    }
}

/// The views inside the pane know their pane.
protocol PaneChild: AnyObject { var pane: GanttPaneView? { get set } }

// MARK: - toast-like tip while dragging

func drawTip(_ text: String, at p: NSPoint, in ctx: CGContext, theme: Theme) {
    let st = TextStyle(size: 12, color: theme.accentText)
    let w = CoreTextMeasurer.shared.width(text, st)
    let r = CGRect(x: p.x + 14, y: p.y + 16, width: w + 16, height: 22)
    ctx.saveGState()
    ctx.setFillColor(theme.accent.cg)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    CGRenderer.drawText(text, x: r.minX + 8, y: r.minY + 15, style: st, ctx)
}

extension NSEvent {
    var keyMods: KeyMods {
        var m: KeyMods = []
        if modifierFlags.contains(.shift) { m.insert(.shift) }
        if modifierFlags.contains(.command) { m.insert(.command) }
        if modifierFlags.contains(.option) { m.insert(.option) }
        return m
    }
}

// MARK: - splitter

final class SplitterView: NSView, PaneChild {
    weak var pane: GanttPaneView?
    private var startX: CGFloat = 0
    private var startW: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let p = pane else { return }
        p.theme.gridStrong.ns.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startW = frame.minX
    }
    override func mouseDragged(with event: NSEvent) {
        guard let p = pane else { return }
        let w = max(180, min(p.bounds.width - 200, (startW + event.locationInWindow.x - startX).rounded()))
        p.model.tableWidth = Double(w)
    }
    override func mouseUp(with event: NSEvent) {
        guard let p = pane, let w = p.model.tableWidth else { return }
        p.state.updatePrefs { $0.tableWidth = w }
    }
}
