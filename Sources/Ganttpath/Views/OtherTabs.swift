// Network diagram, timeline summary, critical path table and S-curve (views.js). Each is redrawn from the model when it changes.

import SwiftUI
import AppKit
import GanttpathCore
import GanttpathModel

/// Settings of the four views that are kept while the app runs (views.js V), and the drawings they show.
@MainActor
@Observable
final class ViewSettings {
    static let shared = ViewSettings()
    var networkScope = "all"         // all | critical | s:<uid>
    var networkSummaries = false
    var networkScale: Double = 1
    var timelineMilestones: TimelineMilestones = .top
    var timelineZoom: Double = 1
    var cpm = CpmState()
    var scurveBaseline: Int? = nil

    func zoom(_ tab: Tab, _ dir: Int) {
        if tab == .network { networkScale = max(0.25, min(3, networkScale * (dir > 0 ? 1.25 : 0.8))) }
        else if tab == .timeline { timelineZoom = max(1, min(12, timelineZoom * (dir > 0 ? 1.4 : 1 / 1.4))) }
    }

    func networkLayout(_ m: DocumentModel) -> NetworkLayout {
        let scope: NetworkScope = networkScope == "all" ? .all : networkScope == "critical" ? .critical : .summary(Int(networkScope.dropFirst(2)) ?? -1)
        return layoutNetwork(m.project, m.sched, scope: scope, includeSummaries: networkSummaries)
    }
    func networkDrawing(_ m: DocumentModel, theme: Theme) -> ViewDrawing? {
        let lay = networkLayout(m)
        if lay.nodes.isEmpty { return nil }
        return GanttpathCore.networkDrawing(m.project, m.sched, layout: lay, theme: theme, showCritical: m.showCritical, selected: m.selection)
    }
    func timelineDrawing(_ m: DocumentModel, theme: Theme, width: Double) -> ViewDrawing? {
        GanttpathCore.timelineDrawing(m.project, m.sched, milestones: timelineMilestones, zoom: timelineZoom, availWidth: width, theme: theme,
                                      showCritical: m.showCritical, today: m.env.today())
    }
    func scurveData(_ m: DocumentModel) -> (SCurve, Int) {
        let b = scurveBaseline ?? (m.showBaseline >= 0 ? m.showBaseline : 0)
        return (computeSCurve(m.project, m.sched, baseline: b, statusDate: m.project.settings.statusDate), b)
    }
    func scurveDrawing(_ m: DocumentModel, theme: Theme) -> (ViewDrawing, SCurveGeometry)? {
        let (data, b) = scurveData(m)
        return GanttpathCore.scurveDrawing(m.project, data, baseline: b, theme: theme, today: m.env.today())
    }
}

// MARK: - a drawing in a scroll view

/// Shows a drawing at `scale`, scrollable; reports clicks (in drawing coordinates) and the pointer for hover read-outs.
struct DrawingScrollView: NSViewRepresentable {
    let drawing: Drawing
    let scale: Double
    var onClick: ((CGPoint, Int) -> Void)? = nil
    var onHover: ((CGPoint?) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        s.documentView = DrawingNSView()
        return s
    }
    func updateNSView(_ s: NSScrollView, context: Context) {
        guard let v = s.documentView as? DrawingNSView else { return }
        v.drawing = drawing
        v.scale = scale
        v.onClick = onClick
        v.onHover = onHover
        v.frame.size = NSSize(width: drawing.width * scale, height: drawing.height * scale)
        v.needsDisplay = true
    }
}

final class DrawingNSView: FlippedView {
    var drawing = Drawing(width: 0, height: 0)
    var scale: Double = 1
    var onClick: ((CGPoint, Int) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        CGRenderer.draw(drawing, in: ctx)
        ctx.restoreGState()
    }
    private func logical(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }
    override func mouseDown(with event: NSEvent) { onClick?(logical(event), event.clickCount) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseMoved(with event: NSEvent) { onHover?(logical(event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}

struct ViewBar<C: View>: View {
    @ViewBuilder let content: () -> C
    var body: some View {
        HStack(spacing: 12) { content() }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Empty: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

// MARK: - network

struct NetworkTab: View {
    @Environment(AppState.self) private var state
    @Bindable private var vs = ViewSettings.shared

    var body: some View {
        let m = state.model
        let summaries = m.project.tasks.indices.filter { m.sched.tasks[$0].isSummary }
        VStack(spacing: 0) {
            ViewBar {
                Picker("Show", selection: $vs.networkScope) {
                    Text("All tasks").tag("all")
                    Text("Critical tasks only").tag("critical")
                    ForEach(summaries, id: \.self) { i in Text("Inside: \(m.sched.tasks[i].wbs) \(truncJS(m.project.tasks[i].name, 34))").tag("s:\(m.project.tasks[i].uid)") }
                }.fixedSize()
                Toggle("Include summary tasks", isOn: $vs.networkSummaries)
                Button("−") { vs.zoom(.network, -1) }.help("Zoom out (⌘-)")
                Button("+") { vs.zoom(.network, 1) }.help("Zoom in (⌘+)")
                Button("100%") { vs.networkScale = 1 }
                Text("Each box: ID, WBS, name, dates, duration and total slack. Click to select, double-click to show the task on the Gantt chart.")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            if m.project.tasks.isEmpty { Empty(text: "There are no tasks yet.") }
            else if let d = vs.networkDrawing(m, theme: state.theme) {
                let lay = vs.networkLayout(m)
                if lay.truncated {
                    Text("Showing the first 1500 of \(lay.total) tasks. Use \"Inside: …\" or \"Critical tasks only\" to narrow it down.").foregroundStyle(.orange)
                }
                DrawingScrollView(drawing: d.drawing, scale: vs.networkScale * state.uiScale, onClick: { pt, clicks in
                    guard let h = d.hits.first(where: { $0.contains(pt.x, pt.y) }) else { return }
                    m.selectOnly(h.uid)
                    if clicks >= 2 { m.tab = .gantt; DispatchQueue.main.async { state.gantt?.view?.scrollToTaskBar(uid: h.uid) } }
                })
            } else {
                Empty(text: vs.networkScope == "critical" ? "No critical tasks." : "Nothing to show for this choice.")
            }
        }
    }
}

// MARK: - timeline

struct TimelineTab: View {
    @Environment(AppState.self) private var state
    @Bindable private var vs = ViewSettings.shared

    var body: some View {
        let m = state.model
        VStack(spacing: 0) {
            ViewBar {
                Picker("Milestones", selection: $vs.timelineMilestones) {
                    Text("Top two outline levels").tag(TimelineMilestones.top)
                    Text("All milestones").tag(TimelineMilestones.all)
                    Text("None").tag(TimelineMilestones.none)
                }.fixedSize()
                Button("−") { vs.zoom(.timeline, -1) }
                Button("+") { vs.zoom(.timeline, 1) }
                Button("Fit") { vs.timelineZoom = 1 }
                Text("One bar for each top-level summary task. Click a bar to show it on the Gantt chart.").foregroundStyle(.secondary).lineLimit(1)
            }
            GeometryReader { geo in
                if let d = vs.timelineDrawing(m, theme: state.theme, width: geo.size.width / state.uiScale) {
                    DrawingScrollView(drawing: d.drawing, scale: state.uiScale, onClick: { pt, _ in
                        guard let h = d.hits.first(where: { $0.contains(pt.x, pt.y) }) else { return }
                        m.selectOnly(h.uid)
                        m.tab = .gantt
                        DispatchQueue.main.async { state.gantt?.view?.scrollToTaskBar(uid: h.uid) }
                    })
                } else {
                    Empty(text: "There is nothing to draw yet. Add tasks with dates first.")
                }
            }
        }
    }
}

// MARK: - critical path

struct CpmTab: View {
    @Environment(AppState.self) private var state
    @Bindable private var vs = ViewSettings.shared

    static let widths: [String: CGFloat] = ["id": 50, "wbs": 70, "name": 300, "duration": 80, "es": 130, "ef": 130, "ls": 130, "lf": 130, "ts": 90, "fs": 90, "status": 110]

    var body: some View {
        let m = state.model
        let t = state.theme
        let fmt = m.fmt
        let list = cpmRows(m.project, m.sched, vs.cpm)
        VStack(alignment: .leading, spacing: 0) {
            ViewBar {
                Picker("Show", selection: $vs.cpm.filter) {
                    Text("All tasks").tag(CpmFilter.all)
                    Text("Critical tasks").tag(CpmFilter.critical)
                    Text("Critical and near-critical").tag(CpmFilter.near)
                    Text("Tasks with conflicts").tag(CpmFilter.conflict)
                }.fixedSize()
                Toggle("Include summary tasks", isOn: $vs.cpm.summaries)
                Text("Critical means total slack of \(jsNumberString(m.project.settings.criticalSlackDays)) day(s) or less; near critical is up to \(jsNumberString(m.project.settings.nearCriticalDays)) more. Click a heading to sort, a row to open the task.")
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            KpiRow(items: cpmKpis(m.project, m.sched)).padding(.horizontal, 14)
            if list.isEmpty { Empty(text: "No tasks match this choice.") } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(list, id: \.index) { r in
                                let task = m.project.tasks[r.index]
                                Button {
                                    m.selectOnly(task.uid); m.tab = .gantt
                                    DispatchQueue.main.async { state.gantt?.view?.scrollToTaskBar(uid: task.uid) }
                                } label: {
                                    HStack(spacing: 0) {
                                        ForEach(CPM_COLS, id: \.id) { c in
                                            Text(cpmText(c.id, r, task, fmt))
                                                .lineLimit(1)
                                                .padding(.leading, c.id == "name" ? 8 + CGFloat(task.level - 1) * 14 : 8).padding(.trailing, 8)
                                                .frame(width: Self.widths[c.id] ?? 90, alignment: c.numeric ? .trailing : .leading)
                                        }
                                    }
                                    .fontWeight(r.isSummary ? .semibold : .regular)
                                    .foregroundStyle(r.hasConflict ? Color(nsColor: (t.c["conflict"] ?? .black).ns) : r.critical && m.showCritical ? Color(nsColor: (t.c["critical"] ?? .black).ns) : Color.primary)
                                    .frame(height: 24)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 0) {
                                ForEach(CPM_COLS, id: \.id) { c in
                                    Button {
                                        if vs.cpm.sort == c.id { vs.cpm.desc.toggle() } else { vs.cpm.sort = c.id; vs.cpm.desc = false }
                                    } label: {
                                        Text(c.title + (vs.cpm.sort == c.id ? (vs.cpm.desc ? " ▼" : " ▲") : ""))
                                            .fontWeight(.semibold)
                                            .padding(.horizontal, 8)
                                            .frame(width: Self.widths[c.id] ?? 90, alignment: c.numeric ? .trailing : .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .frame(height: 28)
                            .background(Color(nsColor: t.headerBg.ns))
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}

struct KpiRow: View {
    let items: [(String, String, Bool)]
    @Environment(AppState.self) private var state
    var body: some View {
        HStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[i].0).font(.system(size: 18 * state.uiScale, weight: .bold))
                        .foregroundStyle(items[i].2 ? Color(nsColor: (state.theme.c["conflict"] ?? .black).ns) : Color.primary)
                    Text(items[i].1).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(nsColor: state.theme.panel.ns), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - S-curve

struct SCurveTab: View {
    @Environment(AppState.self) private var state
    @Bindable private var vs = ViewSettings.shared
    @State private var hover: CGPoint? = nil

    var body: some View {
        let m = state.model
        let sc = vs.scurveData(m)
        let data = sc.0, b = sc.1
        VStack(alignment: .leading, spacing: 0) {
            ViewBar {
                Picker("Planned curve from", selection: Binding(get: { b }, set: { vs.scurveBaseline = $0 })) {
                    ForEach(0..<BASELINE_COUNT, id: \.self) { i in Text(BASELINE_NAMES[i]).tag(i) }
                }.fixedSize()
                Text(m.project.settings.statusDate.map { "Status date \(m.fmt.date($0))" } ?? "No status date set (Project → Project settings), so there is no actual curve.")
                    .foregroundStyle(.secondary)
            }
            if data.dates.isEmpty { Empty(text: "The S-curve needs tasks with dates and a duration or weight above zero.") } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if data.status != nil { KpiRow(items: scurveKpis(data)) }
                        if !data.hasBaseline {
                            Text("\(BASELINE_NAMES[b]) has not been set, so there is no planned curve. Set it under Project → Baselines.")
                                .padding(8).background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if let drawn = vs.scurveDrawing(m, theme: state.theme) {
                            let d = drawn.0, geo = drawn.1
                            ZStack(alignment: .topLeading) {
                                DrawingScrollView(drawing: d.drawing, scale: state.uiScale, onHover: { hover = $0 })
                                    .frame(width: d.drawing.width * state.uiScale, height: d.drawing.height * state.uiScale)
                                if let h = hover, let k = geo.nearest(h.x) {
                                    Path { p in
                                        let x = geo.xs(Double(geo.dns[k])) * state.uiScale
                                        p.move(to: CGPoint(x: x, y: geo.mt * state.uiScale)); p.addLine(to: CGPoint(x: x, y: (geo.mt + geo.ph) * state.uiScale))
                                    }.stroke(Color(nsColor: state.theme.gridStrong.ns))
                                    Text(scurveTip(m.project, data, k))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
                                        .offset(x: min(d.drawing.width * state.uiScale - 320, geo.xs(Double(geo.dns[k])) * state.uiScale + 10), y: 4)
                                }
                            }
                        }
                        Text("How this is calculated: each task counts by its Weight (set in the Weight column, default = its duration in working days, milestones 0) spread evenly over its working days. Planned uses the chosen baseline, Forecast uses the current schedule. The Actual curve is an approximation: Ganttpath keeps only the current % complete, not a history, so it assumes each task progressed in a straight line from its actual start to the status date.")
                            .foregroundStyle(.secondary).padding(8)
                            .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(14)
                }
            }
        }
    }
}
