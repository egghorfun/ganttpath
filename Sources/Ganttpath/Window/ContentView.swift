// The window: toolbar, tabs, the active view, the task panel on the right, the conflicts list, the status bar and messages
// (app.js buildToolbar / updateStatus, conflicts.js).

import SwiftUI
import AppKit
import GanttpathCore
import GanttpathModel

struct ContentView: View {
    @Environment(AppState.self) private var state
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let m = state.model
        let t = state.theme
        VStack(spacing: 0) {
            ToolbarView()
            TabsView()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Group {
                        switch m.tab {
                        case .gantt: GanttPane(state: state)
                        case .network: NetworkTab()
                        case .timeline: TimelineTab()
                        case .cpm: CpmTab()
                        case .scurve: SCurveTab()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if m.conflictsOpen { ConflictsList().frame(maxHeight: 220) }
                }
                if m.inspectorOpen {
                    Divider()
                    InspectorView().frame(width: 330 * state.uiScale)
                }
            }
            StatusBar()
        }
        .background(Color(nsColor: t.bg.ns))
        .font(.system(size: 13 * state.uiScale))
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(item: Binding(get: { state.sheet }, set: { state.sheet = $0 })) { s in
            SheetHost(sheet: s).environment(state)
        }
        .alert(state.alert?.title ?? "", isPresented: Binding(get: { state.alert != nil }, set: { if !$0 { state.alert = nil } })) {
            Button("OK") { state.alert = nil }
        } message: { Text(state.alert?.message ?? "") }
        .onAppear { state.systemDark = scheme == .dark }
        .onChange(of: scheme) { _, v in state.systemDark = v == .dark }
        .navigationTitle(m.windowTitle)
        .background(WindowEdited(dirty: m.dirty))
    }
}

/// The dot in the window's close button when there are unsaved changes.
struct WindowEdited: NSViewRepresentable {
    let dirty: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { v.window?.isDocumentEdited = dirty }
    }
}

// MARK: - toolbar

struct TBButton: View {
    let symbol: String
    var label: String? = nil
    let help: String
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                if let l = label { Text(l) }
            }
            .padding(.horizontal, 6).frame(height: 24)
            .background(on ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct ToolbarView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let m = state.model
        let has = !m.selection.isEmpty
        let onGantt = m.tab == .gantt
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                group {
                    TBButton(symbol: "doc.badge.plus", label: "New", help: "New project (⌘N)") { state.newProjectCommand() }
                    TBButton(symbol: "folder", label: "Open", help: "Open or import (⌘O)") { state.openCommand() }
                    TBButton(symbol: "square.and.arrow.down", label: "Save", help: "Save a new dated version (⌘S)") { state.saveCommand() }
                    Menu {
                        exportMenu
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                        .menuStyle(.borderlessButton).fixedSize().help("Export to MS Project XML, Excel, CSV or PDF")
                }
                group {
                    TBButton(symbol: "arrow.uturn.backward", help: m.canUndo ? "Undo \(m.undoLabel ?? "") (⌘Z)" : "Nothing to undo") { m.undo() }.disabled(!m.canUndo)
                    TBButton(symbol: "arrow.uturn.forward", help: m.canRedo ? "Redo \(m.redoLabel ?? "") (⇧⌘Z)" : "Nothing to redo") { m.redo() }.disabled(!m.canRedo)
                }
                group {
                    TBButton(symbol: "plus", label: "Task", help: "Add a task below the selection (⌘I)") { m.addTask() }.disabled(!onGantt)
                    TBButton(symbol: "rectangle.stack.badge.plus", label: "Summary", help: "Add a summary task") { m.addTask(summary: true) }.disabled(!onGantt)
                    TBButton(symbol: "trash", help: "Delete selected task(s)") { m.deleteSelected() }.disabled(!has || !onGantt)
                    TBButton(symbol: "increase.indent", help: "Indent (⌥⇧→)") { m.indent() }.disabled(!has || !onGantt)
                    TBButton(symbol: "decrease.indent", help: "Outdent (⌥⇧←)") { m.outdent() }.disabled(!has || !onGantt)
                    TBButton(symbol: "arrow.up", help: "Move up (⌥⇧↑)") { m.moveUp() }.disabled(!has || !onGantt)
                    TBButton(symbol: "arrow.down", help: "Move down (⌥⇧↓)") { m.moveDown() }.disabled(!has || !onGantt)
                }
                group {
                    TBButton(symbol: "link", label: "Link", help: "Link selected tasks, Finish-to-Start") { m.linkSelected("FS") }.disabled(m.selection.count < 2 || !onGantt)
                    TBButton(symbol: "link.badge.plus", help: "Unlink selected tasks") { m.unlinkSelected() }.disabled(!has || !onGantt)
                    TBButton(symbol: "diamond", help: "Toggle milestone") { m.toggleMilestone() }.disabled(!has || !onGantt)
                    TBButton(symbol: "wand.and.stars", label: "Auto", help: "Schedule selected tasks automatically") { m.setSelectedMode("auto") }.disabled(!has || !onGantt)
                    TBButton(symbol: "hand.raised", label: "Manual", help: "Schedule selected tasks manually (keep their dates)") { m.setSelectedMode("manual") }.disabled(!has || !onGantt)
                }
                group {
                    TBButton(symbol: "minus.magnifyingglass", help: "Zoom out timeline (⌘-)") { state.gantt?.zoomBy(-1) }.disabled(!onGantt)
                    Button(m.zoomPercentText) { state.gantt?.view?.setZoom(ZOOM_BASE_PX) }
                        .buttonStyle(.borderless).disabled(!onGantt)
                        .help("Current timeline zoom: \(m.zoomPercentText) (100% is the default day scale). Click to reset to 100%.")
                    TBButton(symbol: "plus.magnifyingglass", help: "Zoom in timeline (⌘+)") { state.gantt?.zoomBy(1) }.disabled(!onGantt)
                    TBButton(symbol: "arrow.left.and.right", help: "Fit the whole project in the window") { state.gantt?.fitProject() }.disabled(!onGantt)
                    TBButton(symbol: "calendar", label: "Today", help: "Scroll to today (⌘T)") { state.gantt?.scrollToToday() }.disabled(!onGantt)
                    Picker("", selection: Binding(get: { m.showBaseline }, set: { v in m.showBaseline = v; state.updatePrefs { $0.showBaseline = v } })) {
                        Text("No baseline").tag(-1)
                        ForEach(0..<BASELINE_COUNT, id: \.self) { i in Text(BASELINE_NAMES[i]).tag(i) }
                    }
                    .labelsHidden().fixedSize().help("Baseline shown under the bars")
                    Menu { viewMenu } label: { Label("View", systemImage: "eye") }.menuStyle(.borderlessButton).fixedSize()
                        .help("Critical path, labels, arrows, progress line, expand or collapse")
                }
                group {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find task…", text: $search)
                            .textFieldStyle(.plain).frame(width: 150)
                            .focused($searchFocused)
                            .onChange(of: search) { _, v in m.view.search = v }
                            .onExitCommand { search = ""; m.view.search = "" }
                    }
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                    Menu { FilterMenu() } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("Show only some tasks")
                    Menu { SortMenu() } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("Sort the table")
                    Menu { GroupMenu() } label: { Label("Group", systemImage: "square.stack.3d.up") }
                        .menuStyle(.borderlessButton).fixedSize().help("Group the table")
                    Menu { ColumnsMenu() } label: { Label("Columns", systemImage: "tablecells") }
                        .menuStyle(.borderlessButton).fixedSize().help("Show or hide table columns (or right-click a column heading)")
                    if isFiltering(m.view) || m.view.sort != nil || m.view.group != nil {
                        TBButton(symbol: "xmark.circle", label: "Clear", help: "Remove search, filter, sort and group") { m.view = ViewState(); search = "" }
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    if m.dirty { Circle().fill(Color(nsColor: (state.theme.c["near"] ?? .black).ns)).frame(width: 7, height: 7).help("Unsaved changes") }
                    Text(m.project.name).fontWeight(.semibold).lineLimit(1)
                }
                group {
                    TBButton(symbol: "exclamationmark.triangle", label: "\(m.sched.conflictCount)",
                             help: m.sched.conflictCount > 0 ? "\(plural(m.sched.conflictCount, "conflict")) - click to list them" : "No conflicts", on: m.conflictsOpen) { m.conflictsOpen.toggle() }
                        .foregroundStyle(m.sched.conflictCount > 0 ? Color(nsColor: (state.theme.c["conflict"] ?? .black).ns) : Color.primary)
                    Menu { ProjectMenu() } label: { Label("Project", systemImage: "gearshape") }.menuStyle(.borderlessButton).fixedSize()
                        .help("Project settings, calendars, baselines, columns, colours, templates")
                    TBButton(symbol: "sidebar.right", help: "Task information panel (⌥⌘I)", on: m.inspectorOpen) {
                        m.inspectorOpen.toggle(); let v = m.inspectorOpen; state.updatePrefs { $0.inspectorOpen = v }
                    }
                    TBButton(symbol: state.isDark ? "sun.max" : "moon", help: "Light or dark mode (⇧⌘D)") { state.cycleTheme() }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .background(Color(nsColor: state.theme.panel.ns))
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searchFocused = true }
        .onChange(of: m.view.search) { _, v in if v != search { search = v } }
    }

    @ViewBuilder private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 2) { c() }
        Divider().frame(height: 20)
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

struct FilterMenu: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let f = m.view.filter
        Toggle("Critical tasks only", isOn: Binding(get: { f.critical }, set: { m.view.filter.critical = $0 }))
        Toggle("Tasks with conflicts only", isOn: Binding(get: { f.conflicts }, set: { m.view.filter.conflicts = $0 }))
        Toggle("Incomplete tasks only", isOn: Binding(get: { f.incomplete }, set: { m.view.filter.incomplete = $0 }))
        Toggle("Milestones only", isOn: Binding(get: { f.milestones }, set: { m.view.filter.milestones = $0 }))
        Toggle("Summary tasks only", isOn: Binding(get: { f.summariesOnly }, set: { m.view.filter.summariesOnly = $0 }))
        Toggle("Manually scheduled only", isOn: Binding(get: { f.mode == "manual" }, set: { m.view.filter.mode = $0 ? "manual" : nil }))
        Divider()
        Button(f.slackMax != nil ? "Total slack at most \(jsNumberString(f.slackMax!))d (change…)" : "Total slack at most…") { state.sheet = .slackFilter(atMost: true) }
        Button(f.slackMin != nil ? "Total slack at least \(jsNumberString(f.slackMin!))d (change…)" : "Total slack at least…") { state.sheet = .slackFilter(atMost: false) }
        if let st = m.project.settings.statusDate {
            Toggle("Late: should have finished by \(m.fmt.date(st))", isOn: Binding(get: { f.statusBefore != nil }, set: { m.view.filter.statusBefore = $0 ? st : nil }))
        }
        if !m.project.tags.isEmpty {
            Divider()
            ForEach(m.project.tags, id: \.name) { t in
                Toggle("Tag: \(t.name)", isOn: Binding(get: { f.tags.contains(t.name) }, set: { on in
                    if on { m.view.filter.tags.append(t.name) } else { m.view.filter.tags.removeAll { $0 == t.name } }
                }))
            }
        }
        Divider()
        Button("Clear all filters") { m.view.filter = ViewFilter(); m.view.search = "" }
    }
}

struct SortMenu: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let cur = m.view.sort
        ForEach(allColumns(m.project, m.sched).filter { $0.sortField != nil }, id: \.id) { c in
            Toggle(c.title, isOn: Binding(get: { cur?.field == c.sortField }, set: { _ in
                m.view.sort = ViewSort(field: c.sortField!, dir: cur?.field == c.sortField ? cur!.dir : "asc", keepOutline: cur?.keepOutline ?? true)
            }))
        }
        Divider()
        Toggle("Ascending", isOn: Binding(get: { cur != nil && cur!.dir != "desc" }, set: { _ in if var s = cur { s.dir = "asc"; m.view.sort = s } })).disabled(cur == nil)
        Toggle("Descending", isOn: Binding(get: { cur?.dir == "desc" }, set: { _ in if var s = cur { s.dir = "desc"; m.view.sort = s } })).disabled(cur == nil)
        Toggle("Keep the outline (sort inside each summary)", isOn: Binding(get: { cur == nil || cur!.keepOutline }, set: { v in if var s = cur { s.keepOutline = v; m.view.sort = s } })).disabled(cur == nil)
        Button("No sort") { m.view.sort = nil }.disabled(cur == nil)
    }
}

struct GroupMenu: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let opts: [(String?, String)] = [(nil, "No grouping"), ("tag", "Tag"), ("mode", "Scheduling mode"), ("critical", "Critical / near critical"), ("status", "Progress status"),
                                         ("calendar", "Calendar"), ("constraint", "Constraint type")] + m.project.customColumns.map { ("custom:\($0.id)", "Column: \($0.name)") }
        ForEach(opts.indices, id: \.self) { i in
            Toggle(opts[i].1, isOn: Binding(get: { m.view.group == opts[i].0 }, set: { _ in m.view.group = opts[i].0 }))
        }
    }
}

struct ColumnsMenu: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let shown = Set(m.columns.map { $0.id })
        ForEach(allColumns(m.project, m.sched), id: \.id) { c in
            Toggle(c.title, isOn: Binding(get: { shown.contains(c.id) }, set: { m.setColumnShown(c.id, $0) })).disabled(c.id == "name")
        }
        Divider()
        Button("Reset to the standard columns") { m.resetColumns() }
        Button("Columns to show…") { state.sheet = .columnsToShow }
    }
}

struct ProjectMenu: View {
    @Environment(AppState.self) private var state
    var body: some View {
        Button("Project settings…") { state.sheet = .settings }
        Button("Working calendars and holidays…") { state.sheet = .calendars }
        Button("Baselines…") { state.sheet = .baselines }
        Button("Standard Reports…") { state.sheet = .reports }
        Button("Tags and custom columns…") { state.sheet = .tagsAndColumns }
        Button("Columns to show…") { state.sheet = .columnsToShow }
        Button("Colours…") { state.sheet = .colours }
        Button("Page Settings…") { state.sheet = .pageSettings }
        Button("Header and Footer…") { state.sheet = .headerFooter }
        Divider()
        Button("Insert template…") { state.sheet = .insertTemplate }
        Button("Save project as template…") { state.sheet = .saveTemplate }
        Button("Version history and compare…") { state.sheet = .versions }
        Button("Save in another folder…") { state.saveInAnotherFolder() }
        Divider()
        Button("Import report…") { state.sheet = .importReport }.disabled(state.model.importReport == nil)
        Button("Keyboard shortcuts and tips…") { state.sheet = .help }
        Button("About Ganttpath") { state.sheet = .about }
    }
}

// MARK: - tabs, status bar, messages

struct TabsView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        HStack(spacing: 2) {
            ForEach(ViewTab.allCases, id: \.self) { t in
                Button { m.tab = t } label: {
                    Text(t.title.prefix(1).uppercased() + t.title.dropFirst())
                        .fontWeight(m.tab == t ? .semibold : .regular)
                        .foregroundStyle(m.tab == t ? Color.primary : Color.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(m.tab == t ? Color(nsColor: state.theme.bg.ns) : Color.clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 4)
        .background(Color(nsColor: state.theme.panel.ns))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct StatusBar: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let t = state.theme
        HStack(spacing: 14) {
            ForEach(Array(m.statusParts.enumerated()), id: \.offset) { _, p in
                Text(p.text)
                    .foregroundStyle(p.style == "bad" ? Color(nsColor: (t.c["conflict"] ?? .black).ns) : p.style == "crit" ? Color(nsColor: (t.c["critical"] ?? .black).ns) : Color.secondary)
                    .fontWeight(p.style == "bad" ? .semibold : .regular)
            }
            Spacer()
            Text(m.saveStatusText).foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5 * state.uiScale))
        .padding(.horizontal, 12).frame(minHeight: 24)
        .background(Color(nsColor: t.panel.ns))
        .overlay(alignment: .top) { Divider() }
    }
}

struct ToastView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if let t = state.model.toast {
            Text(t.message)
                .foregroundStyle(.white)
                .fontWeight(t.kind == .error ? .medium : .regular)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(t.kind == .error ? Color(nsColor: (state.theme.c["conflict"] ?? .black).ns) : Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255),
                            in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 720)
                .padding(.bottom, 40)
                .onTapGesture { state.model.dismissToast(t.id) }
                .task(id: t.id) {
                    try? await _Concurrency.Task.sleep(nanoseconds: UInt64(t.seconds * 1_000_000_000))
                    state.model.dismissToast(t.id)
                }
                .transition(.opacity)
        }
    }
}

struct ConflictsList: View {
    @Environment(AppState.self) private var state
    static let TYPE_LABEL = ["link": "Broken link", "constraint": "Constraint", "deadline": "Deadline", "calendar": "Calendar", "slack": "Negative slack", "cycle": "Circular"]
    var body: some View {
        let m = state.model
        let n = m.sched.conflicts.count
        let bad = Color(nsColor: (state.theme.c["conflict"] ?? .black).ns)
        VStack(spacing: 0) {
            Rectangle().fill(bad).frame(height: 2)
            HStack(spacing: 10) {
                Text(n > 0 ? "⚠ \(plural(n, "conflict"))" : "No conflicts").fontWeight(.semibold).foregroundStyle(n > 0 ? bad : Color.primary)
                Text(n > 0 ? "Click a row to jump to the task." : "All links, constraints and deadlines can be met.").foregroundStyle(.secondary)
                Spacer()
                Button("Close") { m.conflictsOpen = false }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(m.sched.conflicts.enumerated()), id: \.offset) { _, cf in
                        if cf.index < m.project.tasks.count {
                            let t = m.project.tasks[cf.index]
                            Button {
                                m.selectOnly(t.uid)
                                m.tab = .gantt
                                state.gantt?.view?.scrollToTaskBar(uid: t.uid)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text((Self.TYPE_LABEL[cf.type] ?? cf.type).uppercased()).font(.system(size: 11, weight: .bold)).foregroundStyle(bad).frame(width: 118, alignment: .leading)
                                    Text("\(cf.index + 1)  \(t.name.isEmpty ? "(unnamed)" : t.name)").lineLimit(1).frame(width: 240, alignment: .leading)
                                    Text(cf.message)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: state.theme.panel.ns))
    }
}
