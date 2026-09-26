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
                    if m.conflictsOpen { IssuesPane().frame(height: 220 * state.uiScale) }
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
        .onChange(of: m.pendingError?.id) { _, _ in state.presentPendingError() }
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
        let t = state.theme
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(ViewTab.allCases, id: \.self) { tab in
                let active = m.tab == tab
                Button { m.tab = tab } label: {
                    Text(tab.title.prefix(1).uppercased() + tab.title.dropFirst())
                        .font(.system(size: 13, weight: active ? .semibold : .regular))
                        .foregroundStyle(Color(nsColor: (active ? t.text : t.muted).ns))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(active ? Color(nsColor: t.bg.ns) : Color.clear,
                                    in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                        .overlay {
                            if active {
                                UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
                                    .stroke(Color(nsColor: t.border.ns), lineWidth: 1)
                                    .padding(.bottom, -1)
                                    .mask(Rectangle().padding(.bottom, 1))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 4)
        // the line under the tabs is drawn behind them, so the open tab covers it (as on the JavaScript tabs)
        .background(alignment: .bottom) {
            ZStack(alignment: .bottom) {
                Color(nsColor: t.panel.ns)
                Rectangle().fill(Color(nsColor: t.border.ns)).frame(height: 1)
            }
        }
    }
}

struct StatusBar: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        let t = state.theme
        HStack(spacing: 14) {
            ForEach(Array(m.statusParts.enumerated()), id: \.offset) { _, p in
                let text = Text(p.text)
                    .foregroundStyle(p.style == "bad" ? Color(nsColor: (t.c["conflict"] ?? .black).ns) : p.style == "crit" ? Color(nsColor: (t.c["critical"] ?? .black).ns) : Color.secondary)
                    .fontWeight(p.style == "bad" ? .semibold : .regular)
                if p.text.contains("conflict") {
                    Button { m.showIssues(.conflicts) } label: { text.underline(p.style == "bad") }
                        .buttonStyle(.plain).help("Show the scheduling conflicts")
                } else { text }
            }
            Spacer()
            let errors = m.errorCount
            Button { m.showIssues(.messages) } label: {
                Text(errors > 0 ? "⚠ \(plural(errors, "error")) · Message Log" : "Message Log (\(m.log.count))")
                    .foregroundStyle(errors > 0 ? Color(nsColor: (t.c["conflict"] ?? .black).ns) : Color.secondary)
                    .underline()
            }
            .buttonStyle(.plain).help("Every message shown in this session")
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

/// The pane at the bottom of the window, with two tabs: the scheduling conflicts of the project, and the message log (every
/// message shown in this session, newest first). A row with a task goes to that task.
struct IssuesPane: View {
    @Environment(AppState.self) private var state
    static let TYPE_LABEL = CONFLICT_TYPE_LABEL

    func goTo(_ uid: Int) {
        let m = state.model
        guard m.index(of: uid) != nil else { m.say("That task is no longer in the project."); return }
        m.selectOnly(uid)
        m.tab = .gantt
        state.gantt?.view?.scrollToTaskBar(uid: uid)
    }

    var body: some View {
        let m = state.model
        let n = m.sched.conflicts.count
        let bad = Color(nsColor: (state.theme.c["conflict"] ?? .black).ns)
        VStack(spacing: 0) {
            Rectangle().fill(n > 0 || m.errorCount > 0 ? bad : Color.secondary.opacity(0.4)).frame(height: 2)
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { m.issuesTab }, set: { m.issuesTab = $0 })) {
                    Text(n > 0 ? "⚠ Scheduling Conflicts (\(n))" : "Scheduling Conflicts (0)").tag(IssuesTab.conflicts)
                    Text(m.errorCount > 0 ? "Message Log (\(m.log.count), \(plural(m.errorCount, "error")))" : "Message Log (\(m.log.count))").tag(IssuesTab.messages)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if m.issuesTab == .conflicts {
                    Text(n > 0 ? "Click a row to go to the task. Rest the pointer on a task with ⚠ to see its conflicts." : "All links, constraints and deadlines can be met.")
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(m.log.isEmpty ? "No messages yet." : "Newest first. Click a row to go to its task.").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if m.issuesTab == .messages {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(m.logText, forType: .string)
                    }.controlSize(.small).disabled(m.log.isEmpty)
                    Button("Clear") { m.clearLog() }.controlSize(.small).disabled(m.log.isEmpty)
                }
                Button("Close") { m.conflictsOpen = false }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if m.issuesTab == .conflicts {
                        ForEach(Array(m.sched.conflicts.enumerated()), id: \.offset) { _, cf in
                            if cf.index < m.project.tasks.count {
                                let t = m.project.tasks[cf.index]
                                Button { goTo(t.uid) } label: {
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
                    } else {
                        ForEach(m.log.reversed()) { e in
                            Button { if let u = e.uid { goTo(u) } } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(stampText(e.time)).foregroundStyle(.secondary).monospacedDigit().frame(width: 128, alignment: .leading)
                                    Text(e.kind == .error ? "⚠ ERROR" : "INFORMATION").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(e.kind == .error ? bad : Color.secondary).frame(width: 96, alignment: .leading)
                                    Text(e.taskLabel ?? "").lineLimit(1).frame(width: 220, alignment: .leading)
                                    Text(e.message)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(e.message)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: state.theme.panel.ns))
    }
}
