// Start screen, new project (with the public holiday review), project settings, working calendars and baselines (dlg-project.js).

import SwiftUI
import AppKit
import GanttpathCore
import GanttpathModel

/// Shows the right dialog for a sheet.
struct SheetHost: View {
    @Environment(AppState.self) private var state
    let sheet: Sheet
    var body: some View {
        Group {
            switch sheet {
            case .start: StartScreen()
            case .newProject: NewProjectDialog()
            case .settings: SettingsDialog()
            case .calendars: CalendarsDialog()
            case .baselines: BaselinesDialog()
            case .reports: ReportsDialog()
            case .tagsAndColumns: TagsColumnsDialog()
            case .columnsToShow: ColumnsDialog()
            case .colours: ColoursDialog()
            case .pageSettings: PageSettingsDialog()
            case .headerFooter: HeaderFooterDialog()
            case .insertTemplate: InsertTemplateDialog()
            case .saveTemplate: PromptDialog(title: "Save as template", label: "Template name", initial: state.model.project.name, ok: "Save") { state.model.saveAsTemplate(name: $0) }
            case .importReport: ImportReportDialog()
            case .versions: VersionsDialog()
            case .help: HelpDialog()
            case .about: AboutDialog()
            case .insertSeveral:
                PromptDialog(title: "Insert blank rows below the selected row", label: "How many rows", initial: "5", ok: "Insert") { v in
                    guard let n = Int(jsTrim(v)), n >= 1, n <= 500 else { state.model.say("Enter a whole number from 1 to 500.", .error); return }
                    state.model.insertRows(below: true, count: n)
                }
            case .slackFilter(let atMost):
                let m = state.model
                PromptDialog(title: atMost ? "Show tasks with total slack of at most (days)" : "Show tasks with total slack of at least (days)", label: "Days",
                             initial: jsNumberString((atMost ? m.view.filter.slackMax : m.view.filter.slackMin) ?? (atMost ? 5 : 10)), ok: "OK") { v in
                    let n = jsNumberFromString(jsTrim(v))
                    if !n.isFinite { m.say("Enter a number.", .error); return }
                    if atMost { m.view.filter.slackMax = n } else { m.view.filter.slackMin = n }
                }
            }
        }
        .font(.system(size: 13 * state.uiScale))
    }
}

/// A dialog frame: title, content, and buttons at the bottom right.
struct DialogFrame<Content: View, Buttons: View>: View {
    let title: String
    var width: CGFloat = 560
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.title3.weight(.semibold)).padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 8)
            ScrollView { VStack(alignment: .leading, spacing: 10) { content() }.padding(.horizontal, 18).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading) }
            Divider()
            HStack(spacing: 8) { Spacer(); buttons() }.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: width)
        .frame(minHeight: 200, maxHeight: 760)
    }
}

struct PromptDialog: View {
    @Environment(AppState.self) private var state
    let title: String
    let label: String
    let initial: String
    let ok: String
    let action: (String) -> Void
    @State private var text = ""
    var body: some View {
        DialogFrame(title: title, width: 420) {
            TextField(label, text: $text).textFieldStyle(.roundedBorder).onSubmit(done)
        } buttons: {
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button(ok, action: done).keyboardShortcut(.defaultAction)
        }
        .onAppear { text = initial }
    }
    private func done() { state.sheet = nil; action(text) }
}

// MARK: - start screen

struct StartScreen: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let recents = state.p.recents
        DialogFrame(title: "Ganttpath", width: 560) {
            Text("Recent").foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if recents.isEmpty { Text("No recent projects yet.").foregroundStyle(.secondary).padding(8) }
                ForEach(recents, id: \.self) { path in
                    let exists = FileManager.default.fileExists(atPath: path)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                    let when = (attrs?[.modificationDate] as? Date).map { stampText($0) }
                    Button {
                        state.sheet = nil
                        state.open(path)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(familyName(path)).fontWeight(.semibold)
                            Text(exists ? [DocumentModel.projectFolder(of: path), when].compactMap { $0 }.joined(separator: "  ·  ")
                                        : "\(DocumentModel.projectFolder(of: path))  ·  not found – it may have been moved or deleted")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!exists).help(path)
                    Divider()
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        } buttons: {
            Button("Open…") { state.sheet = nil; DispatchQueue.main.async { state.openCommand(); if state.model.file.path == nil && state.model.importReport == nil { state.sheet = .start } } }
            Button("New Project…") { state.sheet = .newProject }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - new project

struct NewProjectDialog: View {
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var startText = ""
    @State private var country = "SG"
    @State private var download = true
    @State private var templateId = BUILTIN_TEMPLATES[0].id
    @State private var busy = false
    @State private var review: HolidayProposal? = nil
    @State private var choice = "down"
    @State private var years: [Int] = []

    var fmt: String { state.p.dateFormat ?? "DD-MMM-YYYY" }
    var templates: [ProjectTemplate] { state.model.templates().map { $0.template } }

    var body: some View {
        if let r = review { reviewView(r) } else { form }
    }

    private var form: some View {
        let dn = parseDateInput(startText, fmt)
        let t = templates.first { $0.id == templateId }
        return DialogFrame(title: "New project") {
            LabeledField("Project name") { TextField("e.g. Wastewater Treatment Plant", text: $name).textFieldStyle(.roundedBorder) }
            LabeledField("Project start date (\(fmt))") {
                TextField("", text: $startText).textFieldStyle(.roundedBorder)
                Text(dn == nil ? "Not a valid date" : "\(DOW_LONG[dow(dn!)]) - \(dow(dn!) == 0 || dow(dn!) == 6 ? "weekend: the first task will start on the next working day" : "working day")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledField("Country for public holidays") {
                Picker("", selection: $country) { ForEach(COUNTRIES.indices, id: \.self) { k in Text(COUNTRIES[k].1).tag(COUNTRIES[k].0) } }.labelsHidden()
            }
            Toggle("Download the latest public holidays (built-in data is used when offline)", isOn: $download)
            LabeledField("Start from") {
                Picker("", selection: $templateId) { ForEach(templates, id: \.id) { Text("\($0.name)\($0.builtin ? "" : " (mine)")").tag($0.id) } }.labelsHidden()
                if let t = t { Text("\(t.description) (\(t.rows.count) rows)").font(.caption).foregroundStyle(.secondary) }
            }
            Text("The working week is Monday to Friday. You can change it, add site holidays and create other calendars under Project > Working Calendars and Holidays.")
                .font(.caption).foregroundStyle(.secondary)
        } buttons: {
            Button("Cancel") { state.sheet = state.model.project.tasks.isEmpty && state.model.file.path == nil ? .start : nil }.keyboardShortcut(.cancelAction)
            Button(busy ? "Preparing holidays…" : "Create project") { create() }.keyboardShortcut(.defaultAction).disabled(busy)
        }
        .onAppear {
            startText = formatDate(nextMonday(state.model.env.today()), fmt)
            country = state.p.country ?? "SG"
            download = state.p.downloadHolidays
        }
    }

    private func create() {
        guard let dn = parseDateInput(startText, fmt) else { state.model.say("Enter the start date like \(formatDate(state.model.env.today(), fmt))", .error); return }
        busy = true
        let ys = projectYears(toISO(dn), 5)
        let c = country, dl = download
        _Concurrency.Task { @MainActor in
            let prop = await holidayProposal(country: c, years: ys, download: dl, http: AppState.httpGet)
            busy = false
            years = ys
            choice = prop.downloaded != nil ? "down" : !prop.bundled.items.isEmpty ? "built" : "none"
            review = prop
        }
    }

    private func reviewView(_ r: HolidayProposal) -> some View {
        HolidayReview(country: country, proposal: r, existing: nil, choice: $choice) {
            review = nil
        } accept: { set in
            let dn = parseDateInput(startText, fmt)!
            do {
                let p = try makeNewProject(name: name, startDn: dn, country: country, dateFormat: fmt, holidays: set, template: templates.first { $0.id == templateId })
                state.updatePrefs { $0.country = country; $0.downloadHolidays = download }
                state.model.load(p, dirty: !p.tasks.isEmpty)
                state.sheet = nil
                if !p.tasks.isEmpty { state.model.say("New project created from the template. Save it with ⌘S.", .info, 3.5) }
            } catch { state.model.say("\(error)", .error) }
        }
    }
}

struct LabeledField<C: View>: View {
    let label: String
    @ViewBuilder let content: () -> C
    init(_ label: String, @ViewBuilder content: @escaping () -> C) { self.label = label; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Review of public holidays before anything changes: downloaded, built-in, or none; with the differences to a calendar.
struct HolidayReview: View {
    @Environment(AppState.self) private var state
    let country: String
    let proposal: HolidayProposal
    let existing: CalendarDef?
    @Binding var choice: String
    let cancel: () -> Void
    let accept: (HolidaySet?) -> Void

    var body: some View {
        let chosen: HolidaySet? = choice == "down" ? proposal.downloaded : choice == "built" ? proposal.bundled : nil
        DialogFrame(title: existing == nil ? "Review public holidays" : "Update public holidays - \(countryName(country))", width: 640) {
            if let e = proposal.error {
                Note(text: "Could not download the latest holidays: \(e)\(proposal.bundled.items.isEmpty ? "" : " The built-in data is offered instead.")", color: .orange)
            }
            if proposal.downloaded == nil && proposal.bundled.items.isEmpty {
                Text("No holiday data is available for \(countryName(country)) right now. The project will start with weekends only. You can add holidays later under Project > Working Calendars and Holidays.")
            } else {
                Text("Public holidays for \(countryName(country)). Nothing changes until you accept.")
                Picker("", selection: $choice) {
                    if let d = proposal.downloaded { Text("Downloaded holidays (\(d.source ?? ""))").tag("down") }
                    if !proposal.bundled.items.isEmpty { Text("Built-in holidays").tag("built") }
                    Text("Add no holidays").tag("none")
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if let s = chosen {
                    if let n = s.note { Note(text: n, color: .accentColor) }
                    Text("Source: \(s.source ?? "")").foregroundStyle(.secondary)
                    let rows: [(String, String, String)] = {
                        if let cal = existing {
                            let d = diffHolidays(cal, s.items, country, s.years)
                            return d.added.map { ("Add", $0.from, $0.name) } + d.removed.map { ("Remove", $0.from, $0.name) } + d.renamed.map { ("Rename", $0.to.from, "\($0.from.name) → \($0.to.name)") }
                        }
                        return s.items.map { ("", $0.from, $0.name) }
                    }()
                    if let cal = existing {
                        let d = diffHolidays(cal, s.items, country, s.years)
                        Text("\(plural(d.added.count, "holiday")) to add, \(d.removed.count) to remove, \(d.renamed.count) to rename, \(d.unchanged.count) unchanged\(d.skipped.isEmpty ? "" : ", \(d.skipped.count) skipped (you already have an entry for that date)").")
                    } else {
                        Text("\(plural(s.items.count, "holiday")) for \(s.years.map(String.init).joined(separator: ", ")):")
                    }
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                            ForEach(rows.indices, id: \.self) { i in
                                GridRow { Text(rows[i].0); Text(state.model.fmt.date(rows[i].1)); Text(rows[i].2) }
                            }
                        }.padding(6)
                    }
                    .frame(maxHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                } else {
                    Text("No holidays will be added.").foregroundStyle(.secondary)
                }
            }
        } buttons: {
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button("Accept") { accept(chosen) }.keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - project settings

struct SettingsDialog: View {
    @Environment(AppState.self) private var state
    @State private var s = defaultSettings("2026-01-01")
    @State private var name = ""
    @State private var start = ""
    @State private var status = ""
    @State private var prevFmt = ""
    @State private var crit = ""
    @State private var near = ""
    @State private var hpd = ""
    @State private var hpw = ""
    @State private var dpm = ""

    var body: some View {
        let m = state.model
        let cal = m.project.calendars.first { $0.id == s.defaultCalendarId }.map { Cal($0) }
        let avg = cal.map { jsNumberString(jsRound($0.avgDayMin / 60 * 100) / 100) } ?? "?"
        DialogFrame(title: "Project settings") {
            LabeledField("Project name") { TextField("", text: $name).textFieldStyle(.roundedBorder) }
            HStack {
                LabeledField("Project start date") { TextField("", text: $start).textFieldStyle(.roundedBorder) }
                LabeledField("Status date") { TextField("Used by the progress line and S-curve", text: $status).textFieldStyle(.roundedBorder) }
            }
            HStack {
                LabeledField("Date format") {
                    Picker("", selection: $s.dateFormat) {
                        ForEach(DATE_FORMATS, id: \.self) { f in Text("\(f)   (\(formatDate(parseISO("2026-10-05"), f)))").tag(f) }
                    }.labelsHidden()
                    .onChange(of: s.dateFormat) { _, nf in
                        // the date fields always show the format chosen here
                        for field in [0, 1] {
                            let txt = field == 0 ? start : status
                            if let dn = parseDateInput(txt, prevFmt) { if field == 0 { start = formatDate(dn, nf) } else { status = formatDate(dn, nf) } }
                        }
                        prevFmt = nf
                    }
                }
                LabeledField("Project calendar") {
                    Picker("", selection: $s.defaultCalendarId) { ForEach(m.project.calendars, id: \.id) { Text($0.name).tag($0.id) } }.labelsHidden()
                }
            }
            HStack {
                LabeledField("Critical when total slack is at most (days)") { TextField("", text: $crit).textFieldStyle(.roundedBorder) }
                LabeledField("Near-critical range (days above that)") { TextField("", text: $near).textFieldStyle(.roundedBorder) }
            }
            HStack {
                LabeledField("Hours per day (length of \"1d\")") { TextField("", text: $hpd).textFieldStyle(.roundedBorder) }
                LabeledField("Hours per week (length of \"1w\")") { TextField("", text: $hpw).textFieldStyle(.roundedBorder) }
            }
            LabeledField("Days per month (length of \"1mo\")") { TextField("", text: $dpm).textFieldStyle(.roundedBorder) }
            Text("\"Hours per day\" is what \"1 day\" means when you type or read a duration (5d = 5 x \(hpd) h of work). It is not the working time of the calendar: the selected calendar works \(avg) h on an average working day. If the calendar has longer days than \"Hours per day\", the same task takes fewer calendar days, as in MS Project. \"Days per month\" is what \"1mo\" means (1mo = \(dpm)d) - a flat number of working days used for every month, not the real length of the calendar month it falls in, exactly like MS Project's own \"Days per Month\" setting.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LabeledField("Country of the public holidays") {
                Picker("", selection: $s.country) { ForEach(COUNTRIES.indices, id: \.self) { k in Text(COUNTRIES[k].1).tag(COUNTRIES[k].0) } }.labelsHidden()
            }
            Toggle("Honour constraint dates (Must Start On / Must Finish On win over dependencies, as in MS Project)", isOn: $s.honorConstraints)
            Toggle("New tasks are scheduled automatically", isOn: $s.newTasksAuto)
            Toggle("Weeks in the Gantt chart, Timeline and print start on Monday (untick: Sunday)", isOn: $s.weekStartsMonday)
            Toggle("Popup calendar starts the week on Sunday (untick: Monday)", isOn: $s.pickerStartsSunday)
            Toggle("Show the weekday with every date (Fri 30-Oct-2026)", isOn: $s.showWeekday)
        } buttons: {
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            s = m.project.settings
            name = m.project.name
            start = m.fmt.datePlain(s.startDate)
            status = m.fmt.datePlain(s.statusDate)
            prevFmt = s.dateFormat
            crit = jsNumberString(s.criticalSlackDays); near = jsNumberString(s.nearCriticalDays)
            hpd = jsNumberString(s.hoursPerDay); hpw = jsNumberString(s.hoursPerWeek); dpm = jsNumberString(s.daysPerMonth)
        }
    }

    private func save() {
        let m = state.model
        guard let sd = parseDateInput(start, s.dateFormat) else { m.say("Project start date is not a valid date.", .error); return }
        let st = jsTrim(status).isEmpty ? nil : parseDateInput(status, s.dateFormat)
        if !jsTrim(status).isEmpty && st == nil { m.say("Status date is not a valid date.", .error); return }
        let patch = JSONObject([
            ("startDate", .string(toISO(sd))), ("statusDate", st.map { .string(toISO($0)) } ?? .null), ("dateFormat", .string(s.dateFormat)),
            ("honorConstraints", .bool(s.honorConstraints)), ("criticalSlackDays", .string(crit)), ("nearCriticalDays", .string(near)),
            ("hoursPerDay", .string(hpd)), ("hoursPerWeek", .string(hpw)), ("daysPerMonth", .string(dpm)), ("newTasksAuto", .bool(s.newTasksAuto)),
            ("weekStartsMonday", .bool(s.weekStartsMonday)), ("pickerStartsSunday", .bool(s.pickerStartsSunday)), ("showWeekday", .bool(s.showWeekday)),
            ("defaultCalendarId", .string(s.defaultCalendarId)), ("country", .string(s.country)),
        ])
        let nm = jsTrim(name)
        let r = m.run("Project settings") { d, _ in
            if !nm.isEmpty { d.name = nm }
            try updateSettings(&d, patch)
        }
        if r.ok {
            let f = s.dateFormat
            state.updatePrefs { $0.dateFormat = f }
            state.sheet = nil
        }
    }
}

// MARK: - calendars

struct CalendarsDialog: View {
    @Environment(AppState.self) private var state
    @State private var cals: [CalendarDef] = []
    @State private var removed: [String] = []
    @State private var defId = ""
    @State private var sel = ""
    @State private var review: HolidayProposal? = nil
    @State private var reviewChoice = "down"
    @State private var busy = false
    @State private var allHours = ""

    static let ORDER = [1, 2, 3, 4, 5, 6, 0]
    static let PRESETS: [(String, [Bool])] = WEEK_PRESETS

    var body: some View {
        if let r = review, let i = cals.firstIndex(where: { $0.id == sel }) {
            HolidayReview(country: state.model.project.settings.country, proposal: r, existing: cals[i], choice: $reviewChoice) {
                review = nil
            } accept: { set in
                if let s = set { applyHolidayProposal(&cals[i], s.items, state.model.project.settings.country, s.years) }
                review = nil
                state.model.say("Holidays updated in this dialog. Press Save to apply them to the schedule.", .info, 4.5)
            }
        } else { editor }
    }

    private var editor: some View {
        DialogFrame(title: "Working calendars and holidays", width: 980) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    List(selection: Binding(get: { sel }, set: { if let v = $0 { sel = v } })) {
                        ForEach(cals, id: \.id) { c in
                            HStack { Text(c.name); Spacer(); if c.id == defId { Text("project").font(.caption).foregroundStyle(.secondary) } }.tag(c.id)
                        }
                    }
                    .frame(width: 200, height: 300)
                    HStack {
                        Button("New") { add(nil) }
                        Button("Copy") { if let c = cals.first(where: { $0.id == sel }) { add(c) } }
                        Button("Delete", role: .destructive, action: delete)
                    }.controlSize(.small)
                }
                if let i = cals.firstIndex(where: { $0.id == sel }) { calendarEditor(i) }
            }
        } buttons: {
            Button("Cancel") { state.sheet = nil }.keyboardShortcut(.cancelAction)
            Button("Save", action: save).keyboardShortcut(.defaultAction)
        }
        .onAppear {
            let p = state.model.project
            cals = p.calendars
            defId = p.settings.defaultCalendarId
            sel = defId
        }
    }

    private func uid() -> String {
        var n = 1
        while cals.contains(where: { $0.id == "cal\(n)" }) || removed.contains("cal\(n)") || state.model.project.calendars.contains(where: { $0.id == "cal\(n)" }) { n += 1 }
        return "cal\(n)"
    }
    private func add(_ from: CalendarDef?) {
        var c = from ?? CalendarDef(id: "", name: "New calendar", workWeek: MON_FRI)
        c.id = uid()
        if from != nil { c.name = "\(c.name) (copy)" }
        cals.append(c)
        sel = c.id
    }
    private func delete() {
        if cals.count <= 1 { state.model.say("At least one calendar is required.", .error); return }
        if sel == defId { state.model.say("Choose another project calendar before deleting this one.", .error); return }
        removed.append(sel)
        cals.removeAll { $0.id == sel }
        sel = defId
    }

    private func hoursOf(_ c: CalendarDef, _ d: Int) -> [Period] {
        guard c.workWeek[d] else { return [] }
        if let h = c.hours, h.count == 7, !h[d].isEmpty { return normPeriods(h[d]) }
        return DEFAULT_PERIODS
    }
    private func fmtH(_ min: Int) -> String { "\(jsNumberString(jsRound(Double(min) / 60 * 100) / 100)) h" }

    @ViewBuilder private func calendarEditor(_ i: Int) -> some View {
        let c = cals[i]
        let m = state.model
        VStack(alignment: .leading, spacing: 8) {
            LabeledField("Calendar name") { TextField("", text: $cals[i].name).textFieldStyle(.roundedBorder) }
            Text("Working days").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack {
                ForEach(Self.ORDER, id: \.self) { d in
                    Toggle(DOW_SHORT[d], isOn: Binding(get: { cals[i].workWeek[d] }, set: { cals[i].workWeek[d] = $0; fixHours(i) }))
                }
            }
            HStack {
                Menu("Apply preset…") {
                    ForEach(Self.PRESETS.indices, id: \.self) { k in Button(Self.PRESETS[k].0) { cals[i].workWeek = Self.PRESETS[k].1; fixHours(i) } }
                }.fixedSize()
                Button(c.id == defId ? "This is the project calendar" : "Use as project calendar") { defId = c.id }.disabled(c.id == defId)
            }
            Text("Working hours").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Day").bold(); Text("Working periods (24-hour clock)").bold(); Text("Hours").bold() }
                ForEach(Self.ORDER, id: \.self) { d in
                    GridRow {
                        Text(DOW_LONG[d])
                        PeriodsField(text: c.workWeek[d] ? formatPeriods(hoursOf(c, d)) : "", enabled: c.workWeek[d]) { per in
                            ensureHours(i)
                            cals[i].hours![d] = per.map { [Double($0.s), Double($0.e)] }
                        }
                        Text(c.workWeek[d] ? fmtH(periodsMinutes(hoursOf(c, d))) : "")
                    }
                }
            }
            HStack {
                TextField("08:00-12:00, 13:00-17:00", text: $allHours).frame(width: 190)
                Button("Apply to all working days") {
                    guard let per = parsePeriods(allHours), !per.isEmpty else { m.say("Could not read the working periods. Use a form such as 08:00-12:00, 13:00-17:00", .error, 5); return }
                    ensureHours(i)
                    for d in Self.ORDER where cals[i].workWeek[d] { cals[i].hours![d] = per.map { [Double($0.s), Double($0.e)] } }
                }.controlSize(.small)
            }
            Text("Working time in a normal week: \(fmtH(Self.ORDER.reduce(0) { $0 + periodsMinutes(hoursOf(c, $1)) }))").font(.caption).foregroundStyle(.secondary)
            Text("Holidays and exceptions").font(.system(size: 11.5)).foregroundStyle(.secondary)
            ExceptionsTable(exceptions: $cals[i].exceptions)
            HStack {
                Button("Add a day off or working day") {
                    let d = toISO(m.env.today())
                    cals[i].exceptions.append(CalException(from: d, to: d, working: false, name: "Site holiday"))
                }
                Button(busy ? "Looking for holidays…" : "Update public holidays…") { updateHolidays() }.disabled(busy)
            }.controlSize(.small)
            Text("Tasks use the project calendar unless a task is given another one. Lag uses the successor task’s calendar. Working hours decide when work happens; the project setting “Hours per day” only decides how long “1d” is.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { allHours = formatPeriods(stdHours(c)) }
    }

    private func stdHours(_ c: CalendarDef) -> [Period] {
        for d in Self.ORDER where c.workWeek[d] { if let h = c.hours, h.count == 7, !h[d].isEmpty { return normPeriods(h[d]) } }
        return DEFAULT_PERIODS
    }
    private func ensureHours(_ i: Int) {
        if let h = cals[i].hours, h.count == 7 { return }
        cals[i].hours = (0..<7).map { d in cals[i].workWeek[d] ? DEFAULT_PERIODS.map { [Double($0.s), Double($0.e)] } : [] }
    }
    /// After the working days change: a new working day gets the standard hours, a day off gets none.
    private func fixHours(_ i: Int) {
        guard let h = cals[i].hours, h.count == 7 else { return }
        let std = stdHours(cals[i]).map { [Double($0.s), Double($0.e)] }
        var nh = h
        for d in Self.ORDER { nh[d] = cals[i].workWeek[d] ? (h[d].isEmpty ? std : h[d]) : [] }
        cals[i].hours = nh
    }

    private func updateHolidays() {
        let m = state.model
        let country = m.project.settings.country
        let years = projectYears(m.project.settings.startDate, 5)
        busy = true
        m.say("Looking for the latest public holidays…", .info, 2)
        _Concurrency.Task { @MainActor in
            let prop = await holidayProposal(country: country, years: years, download: true, http: AppState.httpGet)
            busy = false
            reviewChoice = prop.downloaded != nil ? "down" : !prop.bundled.items.isEmpty ? "built" : "none"
            review = prop
        }
    }

    private func save() {
        let list = cals, gone = removed, def = defId
        let r = state.model.run("Calendars") { p, _ in
            for c in list { try upsertCalendar(&p, c) }
            p.settings.defaultCalendarId = def
            for id in gone where id != def && p.calendars.contains(where: { $0.id == id }) { try removeCalendar(&p, id) }
        }
        if r.ok { state.sheet = nil }
    }
}

/// A text field for working periods ("08:00-12:00, 13:00-17:00"), checked when the user leaves it.
struct PeriodsField: View {
    @Environment(AppState.self) private var state
    let text: String
    let enabled: Bool
    let onChange: ([Period]) -> Void
    @State private var value = ""
    var body: some View {
        TextField(enabled ? "08:00-12:00, 13:00-17:00" : "day off", text: $value)
            .frame(width: 250).disabled(!enabled)
            .help("Write each working period as start-end, separated by commas. Examples: 08:00-17:00   or   08:00-12:00, 13:00-17:00   or   6-12, 1pm-7pm")
            .onSubmit(apply)
            .onAppear { value = text }
            .onChange(of: text) { _, v in value = v }
    }
    private func apply() {
        guard let per = parsePeriods(value) else { state.model.say("Could not read the working periods. Use a form such as 08:00-12:00, 13:00-17:00", .error, 5); value = text; return }
        if per.isEmpty { state.model.say("A working day needs at least one working period. Untick the day to make it a day off.", .error, 5); value = text; return }
        onChange(per)
        value = formatPeriods(per)
    }
}

struct ExceptionsTable: View {
    @Environment(AppState.self) private var state
    @Binding var exceptions: [CalException]
    var body: some View {
        let order = exceptions.indices.sorted { exceptions[$0].from < exceptions[$1].from }
        let fmt = state.model.fmt
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow { Text("From").bold(); Text("To").bold(); Text("Type").bold(); Text("Hours on a working day").bold(); Text("Name").bold(); Text("") }
                if order.isEmpty {
                    GridRow { Text("No holidays or special days. Add one below, or use \"Update public holidays\".").foregroundStyle(.secondary).gridCellColumns(6) }
                }
                ForEach(order, id: \.self) { i in
                    GridRow {
                        DateTextField(iso: exceptions[i].from) { iso in
                            exceptions[i].from = iso
                            if (exceptions[i].to ?? "") < iso { exceptions[i].to = iso }
                            exceptions[i].origin = nil
                        }
                        DateTextField(iso: exceptions[i].to ?? exceptions[i].from) { iso in
                            exceptions[i].to = iso
                            if iso < exceptions[i].from { exceptions[i].from = iso }
                            exceptions[i].origin = nil
                        }
                        Picker("", selection: Binding(get: { exceptions[i].working }, set: { v in
                            exceptions[i].working = v
                            if !v { exceptions[i].periods = nil }
                            exceptions[i].origin = nil
                        })) { Text("Non-working").tag(false); Text("Working").tag(true) }.labelsHidden().frame(width: 120)
                        PeriodsCell(ex: $exceptions[i])
                        HStack {
                            TextField("", text: $exceptions[i].name).frame(width: 140)
                            if exceptions[i].origin != nil { Text("auto").font(.caption).padding(.horizontal, 5).overlay(Capsule().stroke(Color(nsColor: .separatorColor))).help("Added by the holiday update") }
                        }
                        Button { exceptions.remove(at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove")
                    }
                }
            }
            .padding(6)
        }
        .frame(height: 220)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .id(fmt.dateFormat)
    }
}

struct PeriodsCell: View {
    @Environment(AppState.self) private var state
    @Binding var ex: CalException
    @State private var text = ""
    var body: some View {
        TextField("usual hours", text: $text)
            .frame(width: 116).disabled(!ex.working)
            .help("Leave empty to use the usual working hours. Fill in for a short day, for example 08:00-12:00.")
            .onAppear { text = ex.working ? formatPeriods(ex.periods.map { normPeriods($0) }) : "" }
            .onSubmit {
                guard let per = parsePeriods(text) else {
                    state.model.say("Could not read the working periods. Use a form such as 08:00-12:00", .error, 5)
                    text = formatPeriods(ex.periods.map { normPeriods($0) }); return
                }
                ex.periods = per.isEmpty ? nil : per.map { [Double($0.s), Double($0.e)] }
                text = per.isEmpty ? "" : formatPeriods(per)
                ex.origin = nil
            }
    }
}

/// A date typed in the project's date format, stored as an ISO date.
struct DateTextField: View {
    @Environment(AppState.self) private var state
    let iso: String
    let onChange: (String) -> Void
    @State private var text = ""
    var body: some View {
        TextField("", text: $text).frame(width: 110)
            .onAppear { text = state.model.fmt.datePlain(iso) }
            .onSubmit {
                guard let dn = parseDateInput(text, state.model.project.settings.dateFormat) else { state.model.say("Not a valid date", .error); text = state.model.fmt.datePlain(iso); return }
                onChange(toISO(dn))
            }
    }
}

// MARK: - baselines

struct BaselinesDialog: View {
    @Environment(AppState.self) private var state
    @State private var confirm: (Int, Bool)? = nil   // (baseline, clear?) waiting for "are you sure"

    var body: some View {
        let m = state.model
        let p = m.project
        DialogFrame(title: "Baselines", width: 780) {
            Text("A baseline is a snapshot of the schedule to measure progress against. There are six: Baseline and Baseline 1 to 5. The chart shows the selected one as a thin bar under each task.")
            Picker("", selection: Binding(get: { m.showBaseline }, set: { v in m.showBaseline = v; state.updatePrefs { $0.showBaseline = v } })) {
                Text("Do not show a baseline").tag(-1)
                ForEach(0..<BASELINE_COUNT, id: \.self) { n in
                    let count = p.tasks.filter { $0.baselines[n] != nil }.count
                    Text("Show \(BASELINE_NAMES[n])").tag(n).disabled(count == 0)
                }
            }.pickerStyle(.radioGroup).labelsHidden()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text("Baseline").bold(); Text("Tasks saved").bold(); Text("").gridCellColumns(3) }
                ForEach(0..<BASELINE_COUNT, id: \.self) { n in
                    let count = p.tasks.filter { $0.baselines[n] != nil }.count
                    GridRow {
                        Text(BASELINE_NAMES[n])
                        Text(count > 0 ? "\(count) of \(p.tasks.count)" : "not set")
                        Button("Save whole project") { if count > 0 { confirm = (n, false) } else { m.setBaseline(n, selectedOnly: false) } }
                        Button("Save selected") { m.setBaseline(n, selectedOnly: true) }
                        Button("Clear", role: .destructive) { confirm = (n, true) }.disabled(count == 0)
                    }
                    .controlSize(.small)
                }
            }
        } buttons: {
            Button("Close") { state.sheet = nil }.keyboardShortcut(.defaultAction)
        }
        .alert(confirm.map { $0.1 ? "Clear baseline?" : "Overwrite \(BASELINE_NAMES[$0.0])?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Cancel", role: .cancel) { confirm = nil }
            Button(confirm?.1 == true ? "Clear" : "Overwrite", role: .destructive) {
                if let c = confirm { if c.1 { m.clearBaseline(c.0, selectedOnly: false) } else { m.setBaseline(c.0, selectedOnly: false) } }
                confirm = nil
            }
        } message: {
            if let c = confirm {
                let count = p.tasks.filter { $0.baselines[c.0] != nil }.count
                Text(c.1 ? "Remove \(BASELINE_NAMES[c.0]) from all tasks?" : "\(BASELINE_NAMES[c.0]) already holds \(count) task(s). Saving replaces those dates with the current schedule.")
            }
        }
    }
}
