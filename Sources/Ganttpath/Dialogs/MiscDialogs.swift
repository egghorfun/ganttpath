// Other dialogs (dlg-misc.js and print.js): standard reports, tags and custom columns, columns to show, colours, page settings,
// header and footer, templates, import report, version history and compare, help and about.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GanttpathCore
import GanttpathModel

// MARK: - standard reports

struct ReportsDialog: View {
    @Environment(AppState.self) private var state
    @State private var key = "critical"
    var body: some View {
        let m = state.model
        let def = REPORT_DEFS.first { $0.key == key }!
        let rows = reportRows(key, m.project, m.sched, today: m.env.today())
        let cols = REPORT_COLUMNS[key] ?? []
        let fmt = m.fmt
        DialogFrame(title: "Standard Reports", width: 760) {
            LabeledField("Report") {
                Picker("", selection: $key) { ForEach(REPORT_DEFS, id: \.key) { Text($0.name).tag($0.key) } }.labelsHidden()
            }
            Text(def.blurb).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                KpiRow(items: [(String(rows.count), rows.count == 1 ? "task" : "tasks", false)])
                if key == "slipping" && !hasAnyBaseline(m.project) { Text(" — no baseline has been saved for this project yet (Project ▸ Baselines…)").foregroundStyle(.secondary) }
            }
            if rows.isEmpty { Text("No tasks match this report right now.").foregroundStyle(.secondary) } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { ForEach(cols.indices, id: \.self) { Text(cols[$0].title).bold() } }
                        Divider()
                        ForEach(rows.indices, id: \.self) { i in
                            let rr = rows[i]
                            let t = m.project.tasks[rr.row.index]
                            GridRow {
                                ForEach(cols.indices, id: \.self) { c in Text(reportCellText(cols[c].id, rr, t, fmt)).lineLimit(1) }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                m.selectOnly(t.uid); m.tab = .gantt; state.sheet = nil
                                DispatchQueue.main.async { state.gantt?.view?.scrollToTaskBar(uid: t.uid) }
                            }
                        }
                    }.padding(6)
                }
                .frame(maxHeight: 320)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
        } buttons: {
            Button("Export PDF…") { state.exportReportPDF(key) }
            Button("Close") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - tags and custom columns

struct TagsColumnsDialog: View {
    @Environment(AppState.self) private var state
    @State private var tagName = ""
    @State private var colName = ""
    @State private var colType = "text"
    @State private var colOptions = ""
    @State private var confirmDelete: CustomColumn? = nil

    var body: some View {
        let m = state.model
        let p = m.project
        DialogFrame(title: "Tags and custom columns", width: 640) {
            Text("Tags").font(.headline)
            if p.tags.isEmpty { Text("No tags yet.").foregroundStyle(.secondary) }
            ForEach(p.tags, id: \.name) { tg in
                HStack {
                    SwatchPicker(value: tg.color, dark: state.isDark) { hex in
                        m.run("Tag colour") { d, _ in if let k = d.tags.firstIndex(where: { $0.name == tg.name }) { d.tags[k].color = hex } }
                    }
                    Text(tg.name).frame(minWidth: 160, alignment: .leading)
                    Text(plural(p.tasks.filter { $0.tags.contains(tg.name) }.count, "task")).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) { m.run("Delete tag") { d, _ in removeTag(&d, tg.name) } }.controlSize(.small)
                }
            }
            HStack {
                TextField("New tag, e.g. Long lead", text: $tagName).textFieldStyle(.roundedBorder).onSubmit(addTag)
                Button("Add tag", action: addTag)
            }
            Text("Custom columns").font(.headline).padding(.top, 10)
            if p.customColumns.isEmpty { Text("No custom columns yet.").foregroundStyle(.secondary) }
            ForEach(p.customColumns, id: \.id) { c in
                HStack {
                    Text(c.name).frame(minWidth: 160, alignment: .leading)
                    Text(c.type == "list" ? "list: \(c.options.joined(separator: ", "))" : c.type).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) { confirmDelete = c }.controlSize(.small)
                }
            }
            HStack {
                TextField("Column name, e.g. Discipline", text: $colName).textFieldStyle(.roundedBorder).onSubmit(addColumn)
                Picker("", selection: $colType) {
                    Text("Text").tag("text"); Text("Number").tag("number"); Text("Date").tag("date"); Text("Yes / blank").tag("flag"); Text("List of choices").tag("list")
                }.labelsHidden().fixedSize()
                TextField("Choices, separated by commas (for a list)", text: $colOptions).textFieldStyle(.roundedBorder).onSubmit(addColumn)
            }
            Button("Add column", action: addColumn)
        } buttons: {
            Button("Close") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
        .alert("Delete column?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let c = confirmDelete {
                    m.run("Delete column") { d, _ in removeCustomColumn(&d, c.id) }
                    if let ids = m.columnIds { m.columnIds = ids.filter { $0 != "custom:\(c.id)" }; let v = m.columnIds; state.updatePrefs { $0.columns = v } }
                }
                confirmDelete = nil
            }
        } message: { Text("Remove \"\(confirmDelete?.name ?? "")\" and its values from all tasks?") }
    }

    private func addTag() {
        let nm = jsTrim(tagName)
        if nm.isEmpty { return }
        let r = state.model.run("New tag") { d, _ in try GanttpathCore.addTag(&d, nm, DocumentModel.TAG_COLORS[d.tags.count % DocumentModel.TAG_COLORS.count]) }
        if r.ok { tagName = "" }
    }

    private func addColumn() {
        let m = state.model
        let nm = jsTrim(colName)
        if nm.isEmpty { return }
        let options = colType == "list" ? colOptions.split(separator: ",").map { jsTrim(String($0)) }.filter { !$0.isEmpty } : []
        if colType == "list" && options.isEmpty { m.say("Type at least one choice, separated by commas.", .error); return }
        let type = colType
        let r = m.run("New column") { d, _ in try addCustomColumn(&d, name: nm, type: type, options: options) }
        if let id = r.value {
            m.columnIds = (m.columnIds ?? DEFAULT_COLUMNS) + ["custom:\(id)"]
            let v = m.columnIds
            state.updatePrefs { $0.columns = v }
            colName = ""; colOptions = ""
            m.say("Column \"\(nm)\" added and shown in the table.", .info, 2.5)
        }
    }
}

// MARK: - columns to show

struct ColumnsDialog: View {
    @Environment(AppState.self) private var state
    @State private var shown: Set<String> = []
    var body: some View {
        let m = state.model
        let cols = allColumns(m.project, m.sched)
        DialogFrame(title: "Columns to show", width: 420) {
            Text("Choose the columns of the task table. Columns appear in the order listed. Drag a column edge in the table header to resize it.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(cols, id: \.id) { c in
                    Toggle(c.id == "name" ? "\(c.title) (always shown)" : c.title, isOn: Binding(get: { shown.contains(c.id) || c.id == "name" }, set: { v in
                        if v { shown.insert(c.id) } else { shown.remove(c.id) }
                    })).disabled(c.id == "name")
                }
            }
        } buttons: {
            Button("Reset to default") { m.resetColumns(); state.sheet = nil }
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Show") {
                m.columnIds = cols.filter { shown.contains($0.id) || $0.id == "name" }.map { $0.id }
                let v = m.columnIds
                state.updatePrefs { $0.columns = v }
                state.sheet = nil
            }.keyboardShortcut(.defaultAction)
        }
        .onAppear { shown = Set(m.columns.map { $0.id }) }
    }
}

// MARK: - colours

struct ColoursDialog: View {
    @Environment(AppState.self) private var state
    @State private var before: [String: [String: String]] = [:]
    var body: some View {
        let p = state.p
        DialogFrame(title: "Schedule colours", width: 520) {
            Text("Conflicts are magenta and the critical path is red by default, so the two are never confused on screen or in print. Changes show immediately and apply to the whole app, the PDF and the network diagram.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Element").bold(); Text("Light mode").bold(); Text("Dark mode").bold() }
                ForEach(COLOR_KEYS, id: \.self) { key in
                    GridRow {
                        Text(COLOR_LABELS[key] ?? key)
                        ForEach(["light", "dark"], id: \.self) { theme in
                            SwatchPicker(value: p.colors[theme]?[key] ?? PALETTE[theme]![key]!, dark: theme == "dark") { hex in
                                state.updatePrefs { $0.colors[theme, default: [:]][key] = hex }
                            }
                        }
                    }
                }
            }
        } buttons: {
            Button("Reset to defaults") { state.updatePrefs { $0.colors = [:] } }
            Button("Cancel") { let b = before; state.updatePrefs { $0.colors = b }; state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Save") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
        .onAppear { before = state.p.colors }
    }
}

// MARK: - page settings

struct PageSettingsDialog: View {
    @Environment(AppState.self) private var state
    @State private var paper = "A4"
    @State private var margin = ""
    @State private var docNum = ""
    @State private var logo: String? = nil
    var body: some View {
        let m = state.model
        DialogFrame(title: "Page Settings", width: 460) {
            LabeledField("Paper size") { Picker("", selection: $paper) { ForEach(PAPER_SIZES, id: \.self) { Text("\($0) landscape").tag($0) } }.labelsHidden() }
            LabeledField("Margin (mm)") { TextField("", text: $margin).textFieldStyle(.roundedBorder) }
            LabeledField("Document Number") { TextField("e.g. F10E-CWR-DAT-001", text: $docNum).textFieldStyle(.roundedBorder) }
            Text("Typed once here. To print it, add the \"Document Number\" field to the header or footer in Project ▸ Header and Footer… - it then repeats on every page, like a Microsoft Project header field.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledField("Company logo") {
                HStack {
                    Button("Choose image…", action: chooseLogo)
                    if logo != nil { Button("Remove logo") { logo = nil } }
                }
                if let l = logo, let d = dataFromDataURL(l), let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 40).padding(3).background(Color.white)
                }
            }
            Text("Used by Export > PDF. The PDF is always full-colour vector output; there is no separate resolution setting to choose.").foregroundStyle(.secondary)
        } buttons: {
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let mm = max(MIN_MARGIN_MM, min(MAX_MARGIN_MM, jsRound(Double(jsTrim(margin)) ?? DEFAULT_MARGIN_MM)))
                let ps = PageSettings(paper: paper, marginMM: mm)
                state.updatePrefs { $0.pageSettings = ps }
                let patch = JSONObject([("documentNumber", .string(docNum)), ("logoDataUrl", logo.map { .string($0) } ?? .null)])
                if m.run("Page settings", { d, _ in try updateSettings(&d, patch) }).ok { state.sheet = nil }
            }.keyboardShortcut(.defaultAction)
        }
        .onAppear {
            let ps = state.p.pageSettings.normalized
            paper = ps.paper; margin = jsNumberString(ps.marginMM)
            docNum = m.project.settings.documentNumber
            logo = m.project.settings.logoDataUrl
        }
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if data.count > 2_000_000 { state.model.say("That image is too large (please use one under about 2 MB).", .error); return }
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        logo = "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

// MARK: - header and footer

struct HeaderFooterDialog: View {
    @Environment(AppState.self) private var state
    @State private var hf = defaultHeaderFooter()
    var body: some View {
        DialogFrame(title: "Header and Footer", width: 900) {
            Text("Shown on every page of Export > PDF, like Microsoft Project’s own Page Setup ▸ Header/Footer. Each box holds up to 3 lines; Document Number and the logo picture come from Page Settings.")
                .foregroundStyle(.secondary)
            Text("Header").font(.headline)
            HStack(alignment: .top) { box($hf.header.left, "Left"); box($hf.header.center, "Center"); box($hf.header.right, "Right") }
            Text("Footer").font(.headline)
            HStack(alignment: .top) { box($hf.footer.left, "Left"); box($hf.footer.center, "Center"); box($hf.footer.right, "Right") }
        } buttons: {
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Save") {
                let json = hf.json
                if state.model.run("Header and footer", { d, _ in try updateSettings(&d, JSONObject([("headerFooter", json)])) }).ok { state.sheet = nil }
            }.keyboardShortcut(.defaultAction)
        }
        .onAppear { hf = state.model.project.settings.headerFooter }
    }

    private func box(_ b: Binding<HFBox>, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            ForEach(b.wrappedValue.lines.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Picker("", selection: b.lines[i].field) { ForEach(HF_FIELDS, id: \.self) { Text(HF_FIELD_LABELS[$0] ?? $0).tag($0) } }.labelsHidden()
                    if b.wrappedValue.lines[i].field == "text" { TextField("Text", text: b.lines[i].text) }
                }
            }
            HStack(spacing: 6) {
                Picker("", selection: b.font) { ForEach(FONTS.indices, id: \.self) { Text(FONTS[$0].label).tag(FONTS[$0].key) } }.labelsHidden()
                Stepper("\(Int(b.wrappedValue.size))", value: b.size, in: 6...24, step: 1).fixedSize()
                SwatchPicker(value: b.wrappedValue.color, dark: false) { b.wrappedValue.color = $0 }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

// MARK: - templates

struct InsertTemplateDialog: View {
    @Environment(AppState.self) private var state
    @State private var chosen = 0
    @State private var list: [(file: String?, template: ProjectTemplate)] = []
    @State private var confirmDelete: Int? = nil
    var body: some View {
        DialogFrame(title: "Insert template", width: 620) {
            Text("The template rows are added at the end of the schedule. Dates are calculated from the project start date.")
            VStack(spacing: 0) {
                ForEach(list.indices, id: \.self) { i in
                    let t = list[i].template
                    HStack {
                        Text(t.name).fontWeight(.semibold).frame(minWidth: 210, alignment: .leading)
                        Text("\(t.rows.count) rows\(t.builtin ? " (built in)" : "")").foregroundStyle(.secondary)
                        Spacer()
                        if list[i].file != nil { Button("Delete", role: .destructive) { confirmDelete = i }.controlSize(.small) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(i == chosen ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { chosen = i }
                    Divider()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if chosen < list.count { Text(list[chosen].template.description).foregroundStyle(.secondary) }
        } buttons: {
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Insert") { if chosen < list.count { state.model.insertTemplate(list[chosen].template) }; state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
        .onAppear { list = state.model.templates() }
        .alert("Delete template?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let i = confirmDelete, let f = list[i].file { try? deleteUserTemplate(state.model.env.templatesDir, f); list = state.model.templates(); chosen = 0 }
                confirmDelete = nil
            }
        } message: { Text("Delete \"\(confirmDelete.map { list[$0].template.name } ?? "")\"?") }
    }
}

// MARK: - import report

struct ImportReportDialog: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let m = state.model
        DialogFrame(title: "Import report", width: 700) {
            if let ir = m.importReport {
                let rep = ir.0.report
                let source = ir.1, kind = ir.2
                Text("Opened \(source) (\(kind)).")
                KpiRow(items: importKpis(rep, m.project.tasks.count))
                if rep.hasCompare, let compared = rep.compared, compared > 0 {
                    let ok = rep.differenceCount == 0
                    Note(text: ok ? "Every automatically scheduled task got exactly the dates stored in the file (\(rep.matched ?? 0) of \(compared))."
                                  : "\(rep.differenceCount) of \(compared) tasks got different dates from the file. The file's own dates were not used.",
                         color: ok ? .accentColor : .orange)
                    if !ok {
                        ScrollView {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                                GridRow { Text("ID").bold(); Text("Task").bold(); Text("In the file").bold(); Text("Ganttpath").bold() }
                                ForEach(rep.differences.indices, id: \.self) { i in
                                    let d = rep.differences[i]
                                    GridRow { Text(String(d.id)); Text(d.name); Text(d.file); Text(d.ganttpath) }
                                }
                            }.padding(6)
                        }.frame(maxHeight: 180)
                    }
                }
                ForEach(rep.notes.indices, id: \.self) { i in
                    let n = rep.notes[i]
                    Note(text: n.text, color: n.level == "warn" ? .orange : n.level == "error" ? .red : .accentColor)
                }
            } else {
                Text("No import in this session.")
            }
        } buttons: {
            Button("OK") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The numbers at the top of the import report.
func importKpis(_ rep: ImportReport, _ taskCount: Int) -> [(String, String, Bool)] {
    var out: [(String, String, Bool)] = []
    out.append((String(rep.stats["tasks"] ?? taskCount), "tasks", false))
    let links: String = rep.stats["links"].map { String($0) } ?? ""
    out.append((links, "links", false))
    if let c = rep.stats["calendars"] { out.append((String(c), "calendars", false)) }
    if let mt = rep.stats["manualTasks"], mt > 0 { out.append((String(mt), "manual tasks", false)) }
    if rep.hasCompare, let c = rep.compared, c > 0 {
        out.append((String(c), "dates checked", false))
        out.append((String(rep.matched ?? 0), "same as file", false))
    }
    return out
}

// MARK: - versions

struct VersionsDialog: View {
    @Environment(AppState.self) private var state
    @State private var versions: [VersionInfo] = []
    @State private var selected: [String] = []
    @State private var result: (CompareResult, String, String)? = nil
    @State private var error: String? = nil

    var body: some View {
        let m = state.model
        let folder = m.file.folder
        DialogFrame(title: "Version history and compare", width: 860) {
            Text("Every Save creates a new file in \(folder ?? "your Ganttpath folder"); nothing is ever overwritten. Autosaves are kept in the Autosaves folder (last 20). Tick one version to compare it with the open project, or two versions to compare them.")
                .fixedSize(horizontal: false, vertical: true)
            if versions.isEmpty { Text("No saved versions of this project yet. Press Save (⌘S) to create one.").foregroundStyle(.secondary) } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow { Text(""); Text("When").bold(); Text("Kind").bold(); Text("File").bold() }
                        ForEach(versions.indices, id: \.self) { i in
                            let v = versions[i]
                            GridRow {
                                Toggle("", isOn: Binding(get: { selected.contains(v.path) }, set: { on in
                                    if on { selected.append(v.path); if selected.count > 2 { selected.removeFirst() } } else { selected.removeAll { $0 == v.path } }
                                })).labelsHidden()
                                Text(stampText(v.time))
                                Text(v.kind == "auto" ? "Autosave" : "Saved")
                                Text(v.file).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(6)
                }
                .frame(maxHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
            HStack {
                Button(selected.count == 2 ? "Compare the two" : "Compare with current") {
                    do { result = try m.compare(selected, versions: versions); error = nil } catch { self.error = "\(error)" }
                }.disabled(selected.isEmpty)
                Button("Open this version") {
                    let path = selected[0]
                    state.sheet = nil
                    m.saveIfDirty(prefs: state.prefs)
                    state.open(path)
                }.disabled(selected.count != 1)
                if let f = folder {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: versions.first?.path ?? f)]) }
                }
            }
            if let e = error { Note(text: e, color: .red) }
            if let r = result { CompareView(cmp: r.0, from: r.1, to: r.2) }
        } buttons: {
            Button("Close") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
        .onAppear { versions = m.versions(prefs: state.prefs) }
    }
}

struct CompareView: View {
    let cmp: CompareResult
    let from: String
    let to: String
    var body: some View {
        let s = cmp.summary
        VStack(alignment: .leading, spacing: 6) {
            Text("Changes from \(from) to \(to)").font(.headline)
            if s.identical { Note(text: "No differences.", color: .accentColor) } else {
                KpiRow(items: [(String(s.added), "added", false), (String(s.removed), "removed", false), (String(s.changed), "changed", false), (String(s.rescheduled), "only rescheduled", false)])
                ForEach(cmp.notes.indices, id: \.self) { i in
                    let n = cmp.notes[i]
                    Note(text: "\(n.label): \(n.from)\(n.to.isEmpty ? "" : " → \(n.to)")", color: .accentColor)
                }
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("ID").bold(); Text("Task").bold(); Text("Change").bold() }
                        ForEach(cmp.tasks.indices, id: \.self) { i in
                            let r = cmp.tasks[i]
                            GridRow(alignment: .top) {
                                Text(String(r.id)); Text(r.name)
                                VStack(alignment: .leading) {
                                    if r.status == "added" { Text("Added").foregroundStyle(.blue) }
                                    else if r.status == "removed" { Text("Removed").foregroundStyle(.red) }
                                    else {
                                        ForEach(r.changes.indices, id: \.self) { k in
                                            let c = r.changes[k]
                                            Text("\(c.label): \(c.from.isEmpty ? "(blank)" : c.from) → \(c.to.isEmpty ? "(blank)" : c.to)\(c.derived ? " (follows from other changes)" : "")")
                                                .opacity(c.derived ? 0.6 : 1)
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(6)
                }.frame(maxHeight: 260)
            }
        }
    }
}

// MARK: - help and about

struct HelpDialog: View {
    @Environment(AppState.self) private var state
    static let ROWS: [(String, String)] = [
        ("Save (creates a new dated file)", "⌘S"), ("Undo / Redo (50 steps)", "⌘Z / ⇧⌘Z"), ("Insert task below", "⌘I  or  type in the last row"), ("Delete task(s)", "Delete (with the ID column selected)"),
        ("Indent / Outdent", "⌥⇧→ / ⌥⇧←"), ("Move row up / down", "⌥⇧↑ / ⌥⇧↓"), ("Edit cell", "Enter, F2, double-click or just start typing"),
        ("Next cell / next row", "Tab / Enter"),
        ("Cut / Copy / Paste rows or cells", "⌘X / ⌘C / ⌘V"), ("Select a block of cells", "Shift+click, or Shift+arrow keys"), ("Delete entire rows", "⌘⌫  or  right-click > Delete entire row"), ("Insert rows above / below", "right-click the row"),
        ("Give up a drag or a Cut", "Esc"), ("Hide or show a column", "right-click a column heading, or the Columns button"), ("Find", "⌘F"), ("Zoom timeline", "⌘+ / ⌘-  or  ⌘ + mouse wheel"), ("Views", "⌘1 Gantt, ⌘2 Network, ⌘3 Timeline, ⌘4 CPM, ⌘5 S-curve"),
        ("Text size", "⇧⌘= / ⇧⌘- / ⇧⌘0"),
    ]
    static let TIPS = [
        "Task Mode: Auto = Ganttpath works out the dates from links, constraints and the calendar. Manual = the task keeps the dates you type and links do not move it. Summary tasks always take their dates from their sub-tasks.",
        "Every date shows its weekday (Fri 30-Oct-2026). Double-click a date cell, or press the calendar button next to a date field, to pick from a calendar; weekends and holidays are shaded, and the week starts on Sunday. You can also type the date; a weekday typed in front is ignored. Project > Project settings can switch the weekday off and start the popup week on Monday instead.",
        "Predecessors are typed with row IDs: 3, 5SS+2d, 7FF-25%, 9FS+1w. Lead is a negative lag. \"ed\" means elapsed calendar days.",
        "Typing a Start date on an automatic task sets \"Start No Earlier Than\"; typing a Finish sets \"Finish No Earlier Than\" (as MS Project does). Use manual scheduling to fix exact dates.",
        "Drag a bar to move it, drag its right end to change the duration, drag from the small circle at either end onto another bar to link.",
        "Drag a row by its ID number to reorder it or move it into another summary task; drag sideways to change its level. The table scrolls by itself when you drag to its top or bottom edge, and Esc gives the drag up.",
        "Rows or cells: pressing a row number selects whole rows, pressing any other cell selects cells. Copy of rows pastes new tasks below the selected row (with their sub-tasks; links among the copied rows stay, links to other rows do not; progress starts at 0). Cut of rows moves them when you paste and keeps every link. Copy of cells puts tab-separated text on the clipboard, so it can go into Excel, and text copied from Excel can be pasted into the table: each value is typed into its cell exactly as if you had typed it. A paste that reaches past the last row adds new tasks.",
        "Plan by the hour: type durations such as 6h or 30m, and dates with a time such as 30-Oct-2026 13:00. Times show only where they are needed. Project > Project settings has \"Hours per day\" (what 1d means, normally 8) and Project > Working calendars has the working hours of each weekday and short days for special dates. If the calendar works longer days than \"Hours per day\", the same task finishes sooner, as in MS Project.",
        "Task settings (right-click a row, the Task information panel, or show them as columns): Inactive keeps a task in the plan but takes it out of the schedule (it keeps its dates, its links are ignored, it is left out of summaries and the project finish, and its dates are locked until you make it active again). Hide task bar stops the bar being drawn. Roll up Gantt bar to summary draws the bar on its summary task while that summary is collapsed. Display on Timeline adds the task to the Timeline summary. Priority (0 to 1000) and Task Type are kept and exchanged with MS Project and Excel; with no resources they change no date.",
        "Everything that cannot be met is shown in red: broken links, constraints, deadlines, circular links and negative slack. Open the Conflicts list from the toolbar.",
        "Every save creates a new dated file. Autosave runs every 5 minutes when something changed, and quitting the app saves a final version.",
    ]
    var body: some View {
        DialogFrame(title: "Keyboard shortcuts and tips", width: 640) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(Self.ROWS.indices, id: \.self) { i in GridRow { Text(Self.ROWS[i].0); Text(Self.ROWS[i].1).foregroundStyle(.secondary) } }
            }
            Text("Good to know").font(.headline).padding(.top, 8)
            ForEach(Self.TIPS.indices, id: \.self) { i in
                HStack(alignment: .firstTextBaseline) { Text("•"); Text(Self.TIPS[i]).fixedSize(horizontal: false, vertical: true) }
            }
        } buttons: {
            Button("Close") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

struct AboutDialog: View {
    @Environment(AppState.self) private var state
    var body: some View {
        DialogFrame(title: "About Ganttpath", width: 480) {
            Text("Ganttpath \(APP_VERSION)").bold()
            Text("A simple, fast scheduling tool for engineering projects, following MS Project scheduling rules.")
            Text("Native macOS app (Swift and SwiftUI). \(AppState.mppBinary() != nil ? "Includes MPXJ (LGPL) as the .mpp reader." : "The .mpp reader is not included in this build: open MS Project files saved as XML.")")
                .foregroundStyle(.secondary)
        } buttons: {
            Button("OK") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
    }
}
