// Task information panel (right side): edits the selected task with the same rules as the table cells (inspector.js).

import SwiftUI
import AppKit
import GanttpathCore
import GanttpathModel

struct InspectorView: View {
    @Environment(AppState.self) private var state

    static let FIELDS: [(String, [String])] = [
        ("General", ["name", "mode", "duration", "start", "finish"]),
        ("Progress", ["pct", "actualStart", "actualFinish", "weight"]),
        ("Logic", ["preds", "constraint", "constraintDate", "deadline"]),
        ("Other", ["calendar", "tags", "notes"]),
        ("Task settings", ["priority", "taskType"]),
    ]
    static let FLAG_ROWS: [(String, String, String)] = [
        ("inactive", "Inactive", "Keeps its dates, takes no part in the schedule: links ignored, left out of summaries and the project finish."),
        ("onTimeline", "Display on Timeline", "Show this task on the Timeline view."),
        ("hideBar", "Hide task bar", "Do not draw the bar on the Gantt chart."),
        ("rollup", "Roll up Gantt bar to summary", "Draw the bar on its summary task when that summary is collapsed."),
    ]

    var body: some View {
        let m = state.model
        let uids = m.selectedUids
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if uids.isEmpty {
                    Text("Task information").font(.headline)
                    Text("Select a task to see and edit its details here. Double-click a bar or a row number to open this panel.").foregroundStyle(.secondary)
                    projectSummary(m)
                } else if uids.count > 1 {
                    MultiInspector(uids: uids)
                } else if let c = m.context(uids[0]) {
                    single(m, c)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: state.theme.panel.ns))
    }

    private func heading(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11 * state.uiScale, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 10)
    }

    @ViewBuilder private func single(_ m: DocumentModel, _ c: CellContext) -> some View {
        let t = c.t, r = c.r
        let cols = Dictionary(uniqueKeysWithValues: allColumns(m.project, m.sched).map { ($0.id, $0) })
        let bad = Color(nsColor: (state.theme.c["conflict"] ?? .black).ns)
        Text("\(r.id)  \(r.isSummary ? "Summary task" : r.isMilestone ? "Milestone" : "Task")").font(.headline)
        Text("WBS \(r.wbs)").foregroundStyle(.secondary)
        if r.inactive {
            Note(text: "Inactive: this task keeps its dates and takes no part in the schedule. Untick \"Inactive\" to change its dates or links.", color: .secondary)
        }
        ForEach(Array(r.conflicts.enumerated()), id: \.offset) { _, cf in Note(text: "⚠ " + cf.message, color: bad) }
        ForEach(Self.FIELDS.indices, id: \.self) { fi in
            let title = Self.FIELDS[fi].0, ids = Self.FIELDS[fi].1
            heading(title)
            ForEach(ids, id: \.self) { id in
                if let col = cols[id] { FieldView(col: col, uid: t.uid).id("\(t.uid)-\(id)-\(m.revision)") }
            }
            if title == "General" {
                NameStyleButtons(task: t)
                if !r.isSummary {
                    Toggle("Milestone (show this task as a milestone diamond)", isOn: Binding(get: { t.milestone && t.dur > 0 }, set: { v in
                        m.run("Milestone") { d, _ in try setMilestone(&d, t.uid, v) }
                    })).disabled(t.dur == 0).help(t.dur == 0 ? "Duration 0 is always a milestone" : "")
                    MonthPicker(uid: t.uid)
                }
            }
            if title == "Task settings" {
                ForEach(Self.FLAG_ROWS.indices, id: \.self) { k in
                    let key = Self.FLAG_ROWS[k].0, label = Self.FLAG_ROWS[k].1, tip = Self.FLAG_ROWS[k].2
                    let off = r.isSummary && (key == "inactive" || key == "rollup")
                    let on = key == "inactive" ? t.inactive : key == "onTimeline" ? t.onTimeline : key == "hideBar" ? t.hideBar : t.rollup
                    Toggle(label, isOn: Binding(get: { on }, set: { v in m.run("Edit \(label)") { d, _ in try setTaskFlag(&d, t.uid, key, v) } }))
                        .disabled(off).help(off ? "Not for a summary task" : tip)
                }
            }
        }
        heading("Bar colour")
        HStack {
            SwatchPicker(value: t.color ?? "#2563EB", dark: state.isDark) { hex in m.run("Bar colour") { d, _ in try setColor(&d, [t.uid], hex) } }
            Button("Default") { m.run("Bar colour") { d, _ in try setColor(&d, [t.uid], nil) } }.controlSize(.small)
        }
        let custom = allColumns(m.project, m.sched).filter { $0.custom }
        if !custom.isEmpty {
            heading("Custom columns")
            ForEach(custom, id: \.id) { col in FieldView(col: col, uid: t.uid).id("\(t.uid)-\(col.id)-\(m.revision)") }
        }
        heading("Schedule")
        let f = m.fmt
        let bn = m.showBaseline >= 0 ? m.showBaseline : 0
        let b = t.baselines[bn]
        let succ = m.sched.links.filter { $0.pIndex == c.index }.map { L in "\(uidToIdMap(m.project)(L.uid).map(String.init) ?? "")\(L.type)" }.joined(separator: ", ")
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            kv("Early start / finish", "\(f.date(r.startStamp))  →  \(f.date(r.finishStamp))")
            kv("Late start / finish", r.lateStart != nil ? "\(f.date(rowLateStart(r)))  →  \(f.date(rowLateFinish(r)))" : "")
            kv("Total slack", r.totalSlackMin == nil ? "" : f.span(r.totalSlackMin))
            kv("Free slack", r.freeSlackMin == nil ? "" : f.span(r.freeSlackMin))
            kv("Critical", r.inactive ? "Inactive" : r.critical ? "Yes" : r.nearCritical ? "Near critical" : "No",
               color: r.critical ? Color(nsColor: (state.theme.c["critical"] ?? .black).ns) : nil)
            kv("Successors", succ)
            kv(BASELINE_NAMES[bn], b.map { "\(f.date($0.start))  →  \(f.date($0.finish))" } ?? "not set")
        }
    }

    private func kv(_ k: String, _ v: String, color: Color? = nil) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(color ?? Color.primary).fontWeight(color != nil ? .semibold : .regular).textSelection(.enabled)
        }
    }

    @ViewBuilder private func projectSummary(_ m: DocumentModel) -> some View {
        let f = m.fmt
        let crit = m.sched.tasks.filter { $0.critical && !$0.isSummary }.count
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            kv("Tasks", String(m.project.tasks.count))
            kv("Start", f.date(m.sched.projectStart))
            kv("Finish", f.date(m.sched.projectFinish))
            kv("Critical tasks", String(crit))
            kv("Conflicts", String(m.sched.conflictCount), color: m.sched.conflictCount > 0 ? Color(nsColor: (state.theme.c["conflict"] ?? .black).ns) : nil)
        }
        .padding(.top, 8)
    }
}

struct Note: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1))
            .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
    }
}

/// One field of the panel, edited like its table cell: typed text is applied with Enter or when leaving the field.
struct FieldView: View {
    @Environment(AppState.self) private var state
    let col: ColumnDef
    let uid: Int
    @State private var text = ""
    @State private var loaded = false
    @State private var showPicker = false

    var body: some View {
        let m = state.model
        if let e = col.edit, let c = m.context(uid) {
            let disabled = e.disabled(c)
            VStack(alignment: .leading, spacing: 2) {
                Text(col.title).font(.system(size: 11.5 * state.uiScale)).foregroundStyle(.secondary)
                switch e.kind {
                case .tags:
                    HStack {
                        ForEach(c.t.tags, id: \.self) { tg in
                            let info = m.project.tags.first { $0.name == tg }
                            HStack(spacing: 4) {
                                Circle().fill(Color(nsColor: RGBA.hex(info?.color ?? "#64748B").ns)).frame(width: 8, height: 8)
                                Text(tg)
                            }.padding(.horizontal, 6).padding(.vertical, 1).overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
                        }
                        Button("Edit tags…") { showPicker = true }.controlSize(.small)
                            .popover(isPresented: $showPicker) { TagsPopoverView(uids: [uid]).environment(state) }
                    }
                case .select:
                    Picker("", selection: Binding(get: { e.raw(c) }, set: { v in _ = m.commitEdit(uid: uid, col: col.id, text: v) })) {
                        let opts = e.options(m.project)
                        ForEach(opts.indices, id: \.self) { k in Text(opts[k].label.isEmpty ? " " : opts[k].label).tag(opts[k].value) }
                    }
                    .labelsHidden().disabled(disabled)
                case .text, .date:
                    HStack(spacing: 4) {
                        if col.id == "notes" {
                            TextEditor(text: $text).frame(minHeight: 60).disabled(disabled)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                            Button("Apply") { apply(e.raw(c)) }.controlSize(.small).disabled(disabled || text == e.raw(c))
                        } else {
                            TextField("", text: $text)
                                .textFieldStyle(.roundedBorder)
                                .disabled(disabled)
                                .onSubmit { apply(e.raw(c)) }
                                .help(e.hint ?? "")
                        }
                        if e.kind == .date {
                            Button { showPicker = true } label: { Image(systemName: "calendar") }
                                .buttonStyle(.borderless).disabled(disabled)
                                .popover(isPresented: $showPicker) {
                                    DatePickerView(value: m.fmt.parseStampText(text)?.dn, today: m.env.today(), cal: calendarOf(m.project, c.t),
                                                   sundayFirst: m.project.settings.pickerStartsSunday, theme: state.theme, clearable: e.clearable,
                                                   onPick: { dn in text = m.fmt.datePlain(toISO(dn)); showPicker = false; apply(e.raw(c)) },
                                                   onClear: { text = ""; showPicker = false; apply(e.raw(c)) })
                                }
                        }
                    }
                    if let h = e.hint, !disabled { Text(h).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .onAppear { if !loaded { text = e.raw(c); loaded = true } }
        }
    }

    private func apply(_ original: String) {
        if text == original { return }
        if !state.model.commitEdit(uid: uid, col: col.id, text: text) { text = original }
    }
}

struct NameStyleButtons: View {
    @Environment(AppState.self) private var state
    var task: GanttpathCore.Task? = nil
    var body: some View {
        let m = state.model
        HStack(spacing: 4) {
            Text("Name style").foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { task?.nameBold ?? false }, set: { _ in m.toggleSelectedNameStyle("nameBold") })) { Text("B").bold() }
                .toggleStyle(.button).help("Bold (⌘B)")
            Toggle(isOn: Binding(get: { task?.nameItalic ?? false }, set: { _ in m.toggleSelectedNameStyle("nameItalic") })) { Text("I").italic() }
                .toggleStyle(.button).help("Italic")
            Toggle(isOn: Binding(get: { task?.nameUnderline ?? false }, set: { _ in m.toggleSelectedNameStyle("nameUnderline") })) { Text("U").underline() }
                .toggleStyle(.button).help("Underline (⌘U)")
        }
    }
}

/// "Cover a whole month (working days)".
struct MonthPicker: View {
    @Environment(AppState.self) private var state
    let uid: Int
    @State private var year = 2026
    @State private var month = 1
    var body: some View {
        let m = state.model
        HStack {
            Text("Cover a whole month").foregroundStyle(.secondary)
            Picker("", selection: $month) { ForEach(1...12, id: \.self) { Text(MONTHS[$0 - 1]).tag($0) } }.labelsHidden().fixedSize()
            Stepper(String(year), value: $year, in: 1990...2100).fixedSize()
            Button("Set") { m.run("Month task") { d, _ in try setMonthTask(&d, uid, ymdToDn(year, month, 1)) } }.controlSize(.small)
        }
        .help("Set the task to cover a whole calendar month (working days)")
        .onAppear {
            let dn = m.index(of: uid).flatMap { parseISO(m.sched.tasks[$0].start) } ?? m.env.today()
            let ymd = dnToYmd(dn)
            year = ymd.y; month = ymd.m
        }
    }
}

struct MultiInspector: View {
    @Environment(AppState.self) private var state
    let uids: [Int]
    @State private var showTags = false
    var body: some View {
        let m = state.model
        Text("\(uids.count) tasks selected").font(.headline)
        NameStyleButtons()
        Text("SCHEDULING").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        HStack { Button("Automatic") { m.setSelectedMode("auto") }; Button("Manual") { m.setSelectedMode("manual") } }
        Text("STRUCTURE").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        HStack { Button("Indent") { m.indent() }; Button("Outdent") { m.outdent() } }
        HStack { Button("Link (FS)") { m.linkSelected("FS") }; Button("Unlink") { m.unlinkSelected() } }
        Text("TASK SETTINGS").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        HStack { Button("Make inactive") { m.setSelectedFlag("inactive", true) }; Button("Make active") { m.setSelectedFlag("inactive", false) } }
        HStack { Button("Hide bars") { m.setSelectedFlag("hideBar", true) }; Button("Show bars") { m.setSelectedFlag("hideBar", false) } }
        HStack { Button("Add to Timeline") { m.setSelectedFlag("onTimeline", true) }; Button("Remove from Timeline") { m.setSelectedFlag("onTimeline", false) } }
        HStack { Button("Roll up bars") { m.setSelectedFlag("rollup", true) }; Button("Stop rolling up") { m.setSelectedFlag("rollup", false) } }
        Text("BAR COLOUR").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        HStack {
            SwatchPicker(value: "#2563EB", dark: state.isDark) { hex in m.setColor(hex) }
            Button("Default colour") { m.setColor(nil) }
        }
        Text("TAGS").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        Button("Edit tags…") { showTags = true }.popover(isPresented: $showTags) { TagsPopoverView(uids: uids).environment(state) }
        let idx = uids.compactMap { m.index(of: $0) }
        let leaves = idx.filter { !m.sched.tasks[$0].isSummary }
        let total = leaves.reduce(0) { $0 + m.sched.tasks[$1].durationMin }
        Text("TOTALS").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        Grid(alignment: .leading) {
            GridRow { Text("Tasks").foregroundStyle(.secondary); Text(String(uids.count)) }
            GridRow { Text("Work items").foregroundStyle(.secondary); Text(String(leaves.count)) }
            GridRow { Text("Sum of durations").foregroundStyle(.secondary); Text(m.fmt.span(total)) }
        }
        .controlSize(.small)
    }
}

// MARK: - popovers

/// Tags for one or more tasks: tick boxes, and a field to add a new tag.
struct TagsPopoverView: View {
    @Environment(AppState.self) private var state
    let uids: [Int]
    @State private var newName = ""
    var body: some View {
        let m = state.model
        let tasks = uids.compactMap { taskByUid(m.project, $0) }
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags for \(uids.count) task\(uids.count == 1 ? "" : "s")").font(.headline)
            if m.project.tags.isEmpty { Text("No tags yet. Type a name below to create one.").foregroundStyle(.secondary) }
            ForEach(m.project.tags, id: \.name) { tg in
                let n = tasks.filter { $0.tags.contains(tg.name) }.count
                Toggle(isOn: Binding(get: { n == tasks.count && n > 0 }, set: { v in m.setTag(tg.name, on: v, for: uids) })) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: RGBA.hex(tg.color).ns)).frame(width: 9, height: 9)
                        Text(tg.name + (n > 0 && n < tasks.count ? "  (some)" : ""))
                    }
                }
            }
            HStack {
                TextField("New tag name", text: $newName).onSubmit(add)
                Button("Add", action: add)
            }
        }
        .padding(12).frame(width: 260)
    }
    private func add() { if state.model.addTagAndApply(newName, to: uids) { newName = "" } }
}

/// Change the type or lag of a link, or delete it.
struct LinkEditorView: View {
    @Environment(AppState.self) private var state
    let key: String
    let close: () -> Void
    @State private var type = "FS"
    @State private var lag = ""
    var body: some View {
        let m = state.model
        let parts = key.split(separator: ">").compactMap { Int($0) }
        let idOf = uidToIdMap(m.project)
        VStack(alignment: .leading, spacing: 8) {
            if parts.count == 2 {
                Text("Link \(idOf(parts[0]).map(String.init) ?? "?") → \(idOf(parts[1]).map(String.init) ?? "?")").font(.headline)
                Picker("Type", selection: $type) {
                    ForEach(["FS", "SS", "FF", "SF"], id: \.self) { t in Text("\(t) - \(LINK_TYPE_NAMES[t]!)").tag(t) }
                }
                TextField("Lag (negative = lead), e.g. +2d, -25%, +1w, +3ed", text: $lag).onSubmit(apply)
                HStack {
                    Button("Delete link", role: .destructive) { close(); m.deleteLink(key) }
                    Spacer()
                    Button("Apply", action: apply).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12).frame(width: 300)
        .onAppear {
            if parts.count == 2, let succ = taskByUid(m.project, parts[1]), let l = succ.preds.first(where: { $0.uid == parts[0] }) {
                type = l.type; lag = formatLag(l.lag)
            }
        }
    }
    private func apply() { if state.model.editLink(key, type: type, lagText: lag) { close() } }
}

/// The popup calendar: weekends and holidays of the task's calendar are shaded (datepicker.js).
struct DatePickerView: View {
    let value: Int?
    let today: Int
    let cal: Cal
    let sundayFirst: Bool
    let theme: Theme
    let clearable: Bool
    let onPick: (Int) -> Void
    let onClear: () -> Void
    @State private var monthStart = 0

    var body: some View {
        let ymd = dnToYmd(monthStart == 0 ? (value ?? today) : monthStart)
        let first = ymdToDn(ymd.y, ymd.m, 1)
        let lead = sundayFirst ? dow(first) : (dow(first) + 6) % 7
        let days = endOfMonthDn(first) - first + 1
        let names = sundayFirst ? ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"] : ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
        VStack(spacing: 6) {
            HStack {
                Button { monthStart = addMonthsDn(first, -1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                Text("\(MONTHS_LONG[ymd.m - 1]) \(String(ymd.y))").fontWeight(.semibold)
                Spacer()
                Button { monthStart = addMonthsDn(first, 1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
            }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow { ForEach(names, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(width: 30) } }
                ForEach(0..<6, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let k = week * 7 + col - lead
                            if k >= 0 && k < days {
                                let dn = first + k
                                let off = !cal.isWorking(dn)
                                Button { onPick(dn) } label: {
                                    Text(String(k + 1))
                                        .frame(width: 30, height: 24)
                                        .background(dn == value ? Color.accentColor : off ? Color(nsColor: theme.nonwork.ns) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                        .foregroundStyle(dn == value ? Color.white : off ? Color.secondary : Color.primary)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(dn == today ? Color.accentColor : Color.clear))
                                }
                                .buttonStyle(.plain)
                                .help(off ? "Day off" : "")
                            } else {
                                Color.clear.frame(width: 30, height: 24)
                            }
                        }
                    }
                }
            }
            HStack {
                Button("Today") { onPick(today) }
                Spacer()
                if clearable { Button("Clear", action: onClear) }
            }
            .controlSize(.small)
        }
        .padding(10)
    }
}

/// Curated, print-safe colour swatches (dialogs.js swatchButton): no colour wheel, no hex entry.
struct SwatchPicker: View {
    let value: String
    let dark: Bool
    let onPick: (String) -> Void
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: RGBA.hex(value).ns)).frame(width: 26, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open) {
            let list = dark ? STANDARD_SWATCHES_DARK : STANDARD_SWATCHES
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 6), spacing: 6) {
                ForEach(list.indices, id: \.self) { i in
                    Button { onPick(list[i].hex); open = false } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: RGBA.hex(list[i].hex).ns)).frame(width: 26, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(list[i].hex.lowercased() == value.lowercased() ? Color.accentColor : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain).help(list[i].name)
                }
            }
            .padding(10)
        }
    }
}
