// The toolbar, laid out like the JavaScript app's (app.js buildToolbar, styles.css #toolbar): groups of 28-px buttons with a line
// icon and a short label, a thin line after each group, wrapping onto a second row when the window is narrow; the project name
// and the right-hand group are pushed to the end of their row.

import SwiftUI
import AppKit
import GanttpathCore
import GanttpathModel

// MARK: - icons

/// One of the original line icons, stroked in the current foreground colour.
struct GPIcon: View {
    let name: String
    var size: CGFloat = 16
    var body: some View {
        IconShape(name: name)
            .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct IconShape: Shape {
    let name: String
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 16
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var path = Path()
        for seg in Icons.segments(name) {
            switch seg {
            case .move(let x, let y): path.move(to: p(x, y))
            case .line(let x, let y): path.addLine(to: p(x, y))
            case .cubic(let a, let b, let c, let d, let e, let f): path.addCurve(to: p(e, f), control1: p(a, b), control2: p(c, d))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

// MARK: - buttons

/// .tb-btn: 28 px high, 8 px side padding, rounded; a light fill and edge while the pointer is over it; faded when disabled.
struct TBButtonStyle: ButtonStyle {
    let theme: Theme
    var on = false
    var warn = false
    func makeBody(configuration: Configuration) -> some View {
        TBButtonBody(configuration: configuration, theme: theme, on: on, warn: warn)
    }
}

private struct TBButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let theme: Theme
    let on: Bool
    let warn: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        let conflict = Color(nsColor: (theme.c["conflict"] ?? .black).ns)
        let accent = Color(nsColor: theme.accent.ns)
        let fg: Color = on ? accent : warn ? conflict : Color(nsColor: theme.text.ns)
        let fill: Color = on ? accent.opacity(0.16) : configuration.isPressed && enabled ? Color(nsColor: theme.grid.ns) : hover && enabled ? Color(nsColor: theme.headerBg.ns) : .clear
        let edge: Color = on ? accent.opacity(0.45) : warn ? conflict : hover && enabled ? Color(nsColor: theme.border.ns) : .clear
        configuration.label
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(edge, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.38)
            .onHover { hover = $0 }
    }
}

/// Icon (and label) of a toolbar button.
struct TBLabel: View {
    let icon: String?
    var label: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let i = icon { GPIcon(name: i) }
            if let l = label { Text(l).font(.system(size: 12)).lineLimit(1).fixedSize() }
        }
    }
}

struct TB: View {
    @Environment(AppState.self) private var state
    let icon: String
    var label: String? = nil
    let help: String
    var on = false
    var warn = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { TBLabel(icon: icon, label: label) }
            .buttonStyle(TBButtonStyle(theme: state.theme, on: on, warn: warn))
            .help(help)
    }
}

/// A toolbar button that opens a menu (the JavaScript app's dropdowns), drawn exactly like the other buttons.
struct TBMenu<Items: View>: View {
    @Environment(AppState.self) private var state
    let icon: String
    var label: String? = nil
    let help: String
    var on = false
    @ViewBuilder let items: () -> Items
    var body: some View {
        Menu { items() } label: { TBLabel(icon: icon, label: label) }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(TBButtonStyle(theme: state.theme, on: on))
            .fixedSize()
            .help(help)
    }
}

// MARK: - wrapping layout

private struct ToolbarSlotKey: LayoutValueKey { static let defaultValue = ToolbarSlot.main }

extension View {
    /// Where a group goes in the toolbar (see arrangeToolbar): row 1 (the default), the right edge of row 1, or row 2.
    func toolbarSlot(_ r: ToolbarSlot) -> some View { layoutValue(key: ToolbarSlotKey.self, value: r) }
}

/// Places the toolbar's groups in rows as arrangeToolbar decides, items centred in their row.
struct ToolbarRows: Layout {
    /// One per place the layout is used, so the smoke test can tell layout passes apart.
    final class Tag { let id: Int; init() { Self.next += 1; id = Self.next }; nonisolated(unsafe) static var next = 0 }
    func makeCache(subviews: Subviews) -> Tag { Tag() }
    /// The rows last placed (item indexes), for the smoke test.
    nonisolated(unsafe) static var lastRows: [[Int]] = []
    nonisolated(unsafe) static var lastInfo = ""
    nonisolated(unsafe) static var lastProposed = 0
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 2

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> ([[(index: Int, x: Double)]], [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let r = arrangeToolbar(widths: sizes.map { Double($0.width) }, roles: subviews.map { $0[ToolbarSlotKey.self] },
                               width: Double(width), spacing: Double(hSpacing))
        return (r, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Tag) -> CGSize {
        let width = proposal.width ?? 10_000
        Self.note("#\(cache.id) size \(proposal.width.map { String(Int($0)) } ?? "nil")")
        if let w = proposal.width, w.isFinite { Self.lastProposed = Int(w) }
        let (rs, sizes) = rows(width, subviews)
        let h = rs.reduce(CGFloat(0)) { $0 + ($1.map { sizes[$0.index].height }.max() ?? 0) } + vSpacing * CGFloat(max(0, rs.count - 1))
        return CGSize(width: proposal.width ?? rs.map { r in r.map { CGFloat($0.x) + sizes[$0.index].width }.max() ?? 0 }.max() ?? 0, height: h)
    }

    /// What SwiftUI asked of the layout, latest last (for the smoke test).
    nonisolated(unsafe) static var history: [String] = []
    static func note(_ s: String) {
        // with the window's and the hosting view's width at that moment, and the time, to tell passes apart
        let info = MainActor.assumeIsolated { () -> String in
            let ws = NSApp.windows.filter { $0.isVisible }.map { w in "\(Int(w.frame.width))/\(Int(w.contentView?.frame.width ?? -1))" }
            return ws.joined(separator: ",")
        }
        history.append("\(s) win \(info) t\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: 1000)))")
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Tag) {
        let (rs, sizes) = rows(bounds.width, subviews)
        Self.lastRows = rs.map { $0.map { $0.index } }
        Self.lastInfo = "placed in width \(Int(bounds.width)), item widths \(sizes.map { Int($0.width) })"
        Self.note("#\(cache.id) place \(Int(bounds.width))")
        var y = bounds.minY
        for row in rs {
            let rowH = row.map { sizes[$0.index].height }.max() ?? 0
            for (i, x) in row {
                subviews[i].place(at: CGPoint(x: bounds.minX + CGFloat(x), y: y + (rowH - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
            }
            y += rowH + vSpacing
        }
    }
}

/// .tb-group: its buttons 2 px apart, 8 px of room and a thin line after it (not after the last group).
struct TBGroup<C: View>: View {
    @Environment(AppState.self) private var state
    var last = false
    @ViewBuilder let content: () -> C
    var body: some View {
        HStack(spacing: 2) { content() }
            .padding(.trailing, last ? 0 : 8)
            .overlay(alignment: .trailing) {
                if !last { Rectangle().fill(Color(nsColor: state.theme.border.ns)).frame(width: 1) }
            }
            .padding(.trailing, last ? 0 : 4)
    }
}

// MARK: - the toolbar

struct ToolbarView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let m = state.model
        let t = state.theme
        let has = !m.selection.isEmpty
        let onGantt = m.tab == .gantt
        let n = m.sched.conflictCount
        ToolbarRows(hSpacing: 4, vSpacing: 2) {
            TBGroup {
                TB(icon: "new", label: "New", help: "New project (⌘N)") { state.newProjectCommand() }
                TB(icon: "open", label: "Open", help: "Open or import (⌘O)") { state.openCommand() }
                TB(icon: "save", label: "Save", help: "Save a new dated version (⌘S)") { state.saveCommand() }
                TBMenu(icon: "export", label: "Export", help: "Export to MS Project XML, Excel, CSV or PDF") { exportMenu }
            }
            TBGroup {
                TB(icon: "undo", help: m.canUndo ? "Undo \(m.undoLabel ?? "") (⌘Z)" : "Nothing to undo") { m.undo() }.disabled(!m.canUndo)
                TB(icon: "redo", help: m.canRedo ? "Redo \(m.redoLabel ?? "") (⇧⌘Z)" : "Nothing to redo") { m.redo() }.disabled(!m.canRedo)
            }
            TBGroup {
                TB(icon: "add", label: "Task", help: "Add a task below the selection (⌘I)") { m.addTask() }.disabled(!onGantt)
                TB(icon: "summary", label: "Summary", help: "Add a summary task") { m.addTask(summary: true) }.disabled(!onGantt)
                TB(icon: "delete", help: "Delete selected task(s) (Delete)") { m.deleteSelected() }.disabled(!has || !onGantt)
                TB(icon: "indent", help: "Indent (⌥⇧→)") { m.indent() }.disabled(!has || !onGantt)
                TB(icon: "outdent", help: "Outdent (⌥⇧←)") { m.outdent() }.disabled(!has || !onGantt)
                TB(icon: "up", help: "Move up (⌥⇧↑)") { m.moveUp() }.disabled(!has || !onGantt)
                TB(icon: "down", help: "Move down (⌥⇧↓)") { m.moveDown() }.disabled(!has || !onGantt)
            }
            TBGroup {
                TB(icon: "link", label: "Link", help: "Link selected tasks, Finish-to-Start") { m.linkSelected("FS") }.disabled(m.selection.count < 2 || !onGantt)
                TB(icon: "unlink", help: "Unlink selected tasks") { m.unlinkSelected() }.disabled(!has || !onGantt)
                TB(icon: "milestone", help: "Toggle milestone") { m.toggleMilestone() }.disabled(!has || !onGantt)
                TB(icon: "auto", label: "Auto", help: "Schedule selected tasks automatically") { m.setSelectedMode("auto") }.disabled(!has || !onGantt)
                TB(icon: "manual", label: "Manual", help: "Schedule selected tasks manually (keep their dates)") { m.setSelectedMode("manual") }.disabled(!has || !onGantt)
            }
            TBGroup {
                TB(icon: "zoomOut", help: "Zoom out timeline (⌘-)") { state.gantt?.zoomBy(-1) }.disabled(!onGantt)
                Button { state.gantt?.view?.setZoom(ZOOM_BASE_PX) } label: {
                    Text(m.zoomPercentText).font(.system(size: 12).monospacedDigit()).frame(minWidth: 28)
                }
                .buttonStyle(TBButtonStyle(theme: t)).disabled(!onGantt)
                .help("Current timeline zoom: \(m.zoomPercentText) (100% is the default day scale). Click to reset to 100%.")
                TB(icon: "zoomIn", help: "Zoom in timeline (⌘+)") { state.gantt?.zoomBy(1) }.disabled(!onGantt)
                TB(icon: "fit", help: "Fit the whole project in the window") { state.gantt?.fitProject() }.disabled(!onGantt)
                TB(icon: "today", label: "Today", help: "Scroll to today (⌘T)") { state.gantt?.scrollToToday() }.disabled(!onGantt)
                BaselineSelect()
                TBMenu(icon: "chevron", label: "View", help: "Critical path, labels, arrows, progress line, expand or collapse") { viewMenu }
            }
            TBGroup {
                HStack(spacing: 4) {
                    GPIcon(name: "search").foregroundStyle(Color(nsColor: t.text.ns))
                    TextField("", text: $search, prompt: Text("Find task…").foregroundColor(Color(nsColor: t.muted.ns)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: t.text.ns))
                        .frame(width: 150)
                        .focused($searchFocused)
                        .onChange(of: search) { _, v in m.view.search = v }
                        .onExitCommand { search = ""; m.view.search = "" }
                }
                .padding(.horizontal, 8).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: t.bg.ns)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: (searchFocused ? t.accent : t.border).ns), lineWidth: 1))
                TBMenu(icon: "filter", label: "Filter", help: "Show only some tasks", on: isFiltering(m.view)) { FilterMenu() }
                TBMenu(icon: "sort", label: "Sort", help: "Sort the table", on: m.view.sort != nil) { SortMenu() }
                TBMenu(icon: "group", label: "Group", help: "Group the table", on: m.view.group != nil) { GroupMenu() }
                TBMenu(icon: "columns", label: "Columns", help: "Show or hide table columns (or right-click a column heading)") { ColumnsMenu() }
                if isFiltering(m.view) || m.view.sort != nil || m.view.group != nil {
                    TB(icon: "close", label: "Clear", help: "Remove search, filter, sort and group") { m.view = ViewState(); search = "" }
                }
            }
            .toolbarSlot(.secondLine)
            TBGroup(last: true) {
                TB(icon: "warn", label: String(n), help: n > 0 ? "\(plural(n, "conflict")) - click to list them" : "No conflicts", on: m.conflictsOpen && m.issuesTab == .conflicts, warn: n > 0) {
                    if m.conflictsOpen && m.issuesTab == .conflicts { m.conflictsOpen = false } else { m.showIssues(.conflicts) }
                }
                TBMenu(icon: "settings", label: "Project", help: "Project settings, calendars, baselines, columns, colours, templates") { ProjectMenu() }
                TB(icon: "panel", help: "Task information panel (⌥⌘I)", on: m.inspectorOpen) {
                    m.inspectorOpen.toggle(); let v = m.inspectorOpen; state.updatePrefs { $0.inspectorOpen = v }
                }
                TB(icon: state.isDark ? "sun" : "moon", help: "Light or dark mode (⇧⌘D)") { state.cycleTheme() }
            }
            .toolbarSlot(.trailing)
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 5)
        .background(Color(nsColor: t.panel.ns))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: t.border.ns)).frame(height: 1) }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .onChange(of: m.view.search) { _, v in if v != search { search = v } }
    }

    @ViewBuilder private var exportMenu: some View {
        let m = state.model
        switch m.tab {
        case .network, .timeline, .scurve:
            Button("Image (PNG)…") { state.exportImage(png: true) }
            Button("Image (SVG)…") { state.exportImage(png: false) }
            Divider()
            Button("PDF…") { state.exportPDF() }
        case .cpm:
            Button("PDF…") { state.exportPDF() }
        case .gantt:
            Button("MS Project XML (.xml)…") { state.exportFile("xml") }
            Button("Excel workbook (.xlsx)…") { state.exportFile("xlsx") }
            Button("CSV (.csv)…") { state.exportFile("csv") }
            Divider()
            Button("PDF…") { state.exportPDF() }
        }
    }

    @ViewBuilder private var viewMenu: some View {
        let m = state.model
        Toggle("Show critical path in red", isOn: Binding(get: { m.showCritical }, set: { m.showCritical = $0 }))
        Toggle("Task names on the bars", isOn: Binding(get: { m.showLabels }, set: { m.showLabels = $0 }))
        Toggle("Link arrows", isOn: Binding(get: { m.showLinks }, set: { m.showLinks = $0 }))
        Toggle("Progress line (needs a status date)", isOn: Binding(get: { m.progressLine }, set: { v in
            m.progressLine = v
            state.updatePrefs { $0.progressLine = v }
            if v && m.project.settings.statusDate == nil { m.say("Set a Status date under Project settings to draw the progress line.", .info, 4.5) }
        }))
        Divider()
        Button("Expand all summary tasks") { m.collapseAll(false) }
        Button("Collapse all summary tasks") { m.collapseAll(true) }
    }
}

/// The "No baseline / Baseline / Baseline 1…" box (.tb-select): a bordered box with the choice and a small arrow.
struct BaselineSelect: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let t = state.theme
        Menu {
            Button("No baseline") { set(-1) }
            ForEach(0..<BASELINE_COUNT, id: \.self) { i in Button(BASELINE_NAMES[i]) { set(i) } }
        } label: {
            HStack(spacing: 6) {
                Text(m.showBaseline >= 0 ? BASELINE_NAMES[m.showBaseline] : "No baseline").font(.system(size: 13)).lineLimit(1).fixedSize()
                GPIcon(name: "chevron", size: 12)
            }
            .foregroundStyle(Color(nsColor: t.text.ns))
            .padding(.horizontal, 8).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: t.bg.ns)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: t.border.ns), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Baseline shown under the bars")
    }
    private func set(_ v: Int) { state.model.showBaseline = v; state.updatePrefs { $0.showBaseline = v } }
}
