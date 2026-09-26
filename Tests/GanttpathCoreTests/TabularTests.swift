// Ported from test/tabular.test.js, test/holidays.test.js, test/templates.test.js and test/engine-reference.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

private func T(_ s: String) -> SheetValue? { .text(s) }
private func N(_ n: Double) -> SheetValue? { .number(n) }
private func sheetRows(_ rows: [[Cell]]) -> [[SheetValue?]] {
    rows.map { $0.map { c -> SheetValue? in
        switch c {
        case .empty: return nil
        case .text(let s), .styled(let s, _): return .text(s)
        case .number(let n), .styledNumber(let n, _): return .number(n)
        case .bool(let b): return .bool(b)
        case .date(let d): return .text(toISO(d))
        }
    } }
}

@Suite struct TabularTests {
    @Test func durationTextParsing() {
        let s = defaultSettings("2026-01-01")
        func pd(_ v: SheetValue?) -> [String]? { parseDurationText(v, s).map { [jsNumberString(Double($0.min) / 480), $0.unit] } }
        #expect(pd(T("5")) == ["5", "d"])
        #expect(pd(T("5 days")) == ["5", "d"])
        #expect(pd(T("2w")) == ["10", "w"])
        #expect(pd(T("1 mo")) == ["20", "mo"])
        #expect(pd(T("16h")) == ["2", "h"])
        #expect(pd(T("3 days?")) == ["3", "d"])
        #expect(pd(T("90m")) == ["0.1875", "m"])
        #expect(pd(T("1.5 hrs")) == ["0.1875", "h"])
        #expect(pd(T("abc")) == nil)
        #expect(pd(T("")) == nil)
        #expect(pd(N(0)) == ["0", "d"])
        #expect(parseDurationText(.number(2.5), s)!.min == 1200)
    }

    @Test func csvQuotingDelimitersBOM() {
        let text = writeCsv([["a", "b,c", "d\"e"], ["x\ny", "", " pad "]])
        #expect(text.unicodeScalars.first == "\u{FEFF}")
        let r = parseCsv(text)
        #expect(r.delimiter == ",")
        #expect(r.rows == [["a", "b,c", "d\"e"], ["x\ny", "", " pad "]])
        #expect(parseCsv("a;b;c\r\n1;2;3\r\n").rows == [["a", "b", "c"], ["1", "2", "3"]])
        #expect(parseCsv("a\tb\n1\t2").rows == [["a", "b"], ["1", "2"]])
    }

    private func pick(_ s: Session) -> [String] {
        s.sched.tasks.enumerated().map { (i, r) in
            let preds = s.project.tasks[i].preds.map { p in "\(s.project.tasks.firstIndex { $0.uid == p.uid } ?? -1)\(p.type)\(p.lag.v)\(p.lag.u)" }
            return "\(s.project.tasks[i].name)|\(r.wbs)|\(r.start ?? "")|\(r.finish ?? "")|\(r.duration)|\(preds)"
        }
    }

    @Test func excelRoundTrip() throws {
        let s = richProject()
        let table = projectToTable(s.project, s.sched)
        let info = projectInfoSheets(s.project)
        let buf = writeXlsx([Sheet(name: "Tasks", rows: [table.headers.map { Cell.text($0) }] + table.rows),
                             Sheet(name: "Project", rows: info.projectRows), Sheet(name: "Calendars", rows: info.calRows)])
        let sheets = try readXlsx(buf)
        let rows = sheets[0].rows
        #expect(rows[0][3] == .text("Task Name"))
        #expect(rows.count == s.project.tasks.count + 1)
        if case .text(let d)? = rows[2][6] { #expect(parseISO(d) != nil && d.count == 10) } else { Issue.record("date cell is not an ISO text") }
        var o = TableImportOptions(); o.projectSheet = sheets[1].rows; o.calendarSheet = sheets[2].rows
        let r = try tableToProject(rows, o)
        let s2 = Session(r.project)
        #expect(pick(s2) == pick(s))
        #expect(!r.report.notes.isEmpty)
        func t(_ n: String) -> Task { s2.project.tasks.first { $0.name == n }! }
        #expect(t("SNET+deadline").constraint == Constraint(type: "SNET", date: "2026-11-02"))
        #expect(t("SNET+deadline").deadline == "2026-11-30")
        #expect(t("MFO").constraint == Constraint(type: "MFO", date: "2026-11-13"))
        #expect(t("Done").actualFinish == "2026-10-08")
        #expect(t("A").notes == "a & b <c>")
        #expect(info.projectRows.first { $0.first == .text("Days per month") } == [.text("Days per month"), .number(20)])
        #expect(s2.project.settings.daysPerMonth == 20)
    }

    @Test func excelRoundTripNonDefaultDaysPerMonth() throws {
        let s = richProject()
        s.run("dpm") { p, _ in try updateSettings(&p, JSONObject([("daysPerMonth", JSON(21.5))])) }
        let table = projectToTable(s.project, s.sched)
        let info = projectInfoSheets(s.project)
        #expect(info.projectRows.first { $0.first == .text("Days per month") } == [.text("Days per month"), .number(21.5)])
        let buf = writeXlsx([Sheet(name: "Tasks", rows: [table.headers.map { Cell.text($0) }] + table.rows),
                             Sheet(name: "Project", rows: info.projectRows), Sheet(name: "Calendars", rows: info.calRows)])
        let sheets = try readXlsx(buf)
        var o = TableImportOptions(); o.projectSheet = sheets[1].rows; o.calendarSheet = sheets[2].rows
        #expect(try tableToProject(sheets[0].rows, o).project.settings.daysPerMonth == 21.5)
    }

    @Test func csvExportCarriesProjectSettings() throws {
        let s = richProject()
        s.run("dpm") { p, _ in try updateSettings(&p, JSONObject([("hoursPerDay", JSON(10)), ("hoursPerWeek", JSON(50)), ("daysPerMonth", JSON(18))])) }
        let table = projectToTable(s.project, s.sched)
        let info = projectInfoSheets(s.project)
        let text = writeCsv(tableToCsvRows(table) + [[], ["# Project Settings"]] + info.projectRows.map { $0.map { $0.csvText } })
        let rows = parseCsv(text).rows.map { $0.map { Optional(SheetValue.text($0)) } }
        var o = TableImportOptions(); o.startDate = s.project.settings.startDate
        let r = try tableToProject(rows, o)
        #expect(r.project.tasks.count == s.project.tasks.count, "the settings block was not imported as extra tasks")
        #expect(r.project.settings.hoursPerDay == 10)
        #expect(r.project.settings.hoursPerWeek == 50)
        #expect(r.project.settings.daysPerMonth == 18)
        #expect(!r.report.notes.isEmpty)
    }

    @Test func csvWithoutASettingsBlockStillImports() throws {
        let r = try tableToProject([[T("Task Name"), T("Duration")], [T("A"), T("5d")]])
        #expect(r.project.tasks.count == 1)
        #expect(r.project.settings.daysPerMonth == 20)
    }

    @Test func csvRoundTrip() throws {
        let s = richProject()
        s.run("std") { p, _ in
            try upsertCalendar(&p, CalendarDef(id: "std", name: "Standard", workWeek: MON_FRI))
            for i in p.tasks.indices { p.tasks[i].calendarId = nil }
        }
        let text = writeCsv(tableToCsvRows(projectToTable(s.project, s.sched)))
        let rows = parseCsv(text).rows.map { $0.map { Optional(SheetValue.text($0)) } }
        var o = TableImportOptions(); o.startDate = s.project.settings.startDate
        let s2 = Session(try tableToProject(rows, o).project)
        #expect(s2.sched.tasks.map { "\($0.start ?? "")|\($0.finish ?? "")" } == s.sched.tasks.map { "\($0.start ?? "")|\($0.finish ?? "")" })
    }

    @Test func messySpreadsheetFromElsewhere() throws {
        let rows: [[SheetValue?]] = [
            [T("Project schedule - exported 2026")],
            [],
            [T("No."), T("Activity"), T("WBS"), T("Duration"), T("Start Date"), T("Predecessors"), T("Responsible"), T("% Complete")],
            [N(10), T("Engineering"), T("1"), nil, nil, T(""), T(""), T("")],
            [N(11), T("Design"), T("1.1"), T("10 days"), T("2026-10-05"), T(""), T("Anna"), N(0.5)],
            [N(12), T("Review"), T("1.2"), T("2w"), nil, T("11"), T("Bob"), T("")],
            [N(13), T("Approve"), T("1.3"), N(0), nil, T("12FS+2d"), T(""), T("")],
            [N(14), T("Procurement"), T("2"), nil, nil, T(""), T(""), T("")],
            [N(15), T("Order"), T("2.1"), T("5"), T("05/10/2026"), T("13, 99"), T(""), T("")],
        ]
        var o = TableImportOptions(); o.dateFormat = "DD/MM/YYYY"
        let r = try tableToProject(rows, o)
        let t = r.project.tasks
        #expect(t.map { $0.level } == [1, 2, 2, 2, 1, 2])
        #expect(t.map { Double($0.dur) / 480 } == [22, 10, 10, 0, 5, 5])
        #expect(t[1].pct == 50)
        #expect(t[2].preds.map { "\($0.uid)\($0.type)" } == ["\(t[1].uid)FS"])
        #expect(t[3].preds[0].lag == Lag(v: 2, u: "d"))
        #expect(t[5].preds.map { $0.uid } == [t[3].uid])
        #expect(r.report.notes.contains { $0.text.contains("No task with ID 99") })
        #expect(r.project.customColumns.count == 1)
        #expect(r.project.customColumns[0].name == "Responsible")
        #expect(t[1].custom[r.project.customColumns[0].id] == .string("Anna"))
        #expect(r.project.settings.startDate == "2026-10-05")
        #expect(t[1].constraint.type == "ASAP")
        let s = Session(r.project)
        #expect(dates(s.sched, 2) == ["2026-10-05", "2026-10-16"])
        #expect(dates(s.sched, 3) == ["2026-10-19", "2026-10-30"])
        #expect(s.sched.tasks[0].isSummary)
    }

    @Test func importOptionsManualDatesCyclesAndMissingNameColumn() throws {
        var o = TableImportOptions(); o.datesAs = "manual"
        let r = try tableToProject([[T("Name"), T("Start"), T("Finish")], [T("A"), T("2026-10-05"), T("2026-10-09")], [T("B"), T("2026-10-12"), T("2026-10-14")]], o)
        #expect(r.project.tasks.map { "\($0.mode)|\($0.start!)|\($0.finish!)|\($0.dur / 480)" } == ["manual|2026-10-05|2026-10-09|5", "manual|2026-10-12|2026-10-14|3"])
        let cyc = try tableToProject([[T("ID"), T("Name"), T("Predecessors")], [N(1), T("A"), T("2")], [N(2), T("B"), T("1")]])
        #expect(Session(cyc.project).sched.cycles.isEmpty)
        #expect(cyc.report.notes.contains { $0.text.lowercased().contains("circular") })
        do { _ = try tableToProject([[T("Foo"), T("Bar")], [N(1), N(2)]]); Issue.record("should fail") } catch { #expect("\(error)".contains("No task name column")) }
    }

    @Test func xlsxReaderDatesNumbersStyledTextAndBadInput() throws {
        let buf = writeXlsx([Sheet(name: "S", rows: [[.text("d"), .text("n")], [.date(20000), .number(5)], [.text("x"), .styled("y", style: "bold")]])])
        let r = try readXlsx(buf)[0].rows
        #expect(r[1][0] == .text(toISO(20000)))
        #expect(r[1][1] == .number(5))
        #expect(r[2][1] == .text("y"))
        do { _ = try readXlsx(Array("not a zip".utf8)); Issue.record("should fail") } catch { #expect("\(error)".contains("Not a valid")) }
    }

    @Test func deflateAndInflateRoundTripOnAssortedData() throws {
        var rnd = SystemRandomNumberGenerator()
        let samples: [[UInt8]] = [
            [], Array("a".utf8), Array(String(repeating: "abcabcabd", count: 5000).utf8),
            (0..<70000).map { _ in UInt8.random(in: 0...255, using: &rnd) },
            (0..<70000).map { UInt8($0 % 7) },
        ]
        for s in samples {
            let c = deflateRaw(s)
            #expect(try inflateRaw(c) == s)
        }
    }
}

@Suite struct HolidayTests {
    private let DAY = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    @Test func bundledSingaporeDataMatchesMOMWeekdays() {
        let published = [
            "2026-01-01": "Thursday", "2026-02-17": "Tuesday", "2026-02-18": "Wednesday", "2026-03-21": "Saturday", "2026-04-03": "Friday",
            "2026-05-01": "Friday", "2026-05-27": "Wednesday", "2026-05-31": "Sunday", "2026-06-01": "Monday", "2026-08-09": "Sunday",
            "2026-08-10": "Monday", "2026-11-08": "Sunday", "2026-11-09": "Monday", "2026-12-25": "Friday",
            "2027-01-01": "Friday", "2027-02-06": "Saturday", "2027-02-07": "Sunday", "2027-02-08": "Monday", "2027-03-10": "Wednesday",
            "2027-03-26": "Friday", "2027-05-01": "Saturday", "2027-05-17": "Monday", "2027-05-20": "Thursday", "2027-08-09": "Monday",
            "2027-10-28": "Thursday", "2027-12-25": "Saturday",
        ]
        let all = BUNDLED["SG"]!.years[2026]! + BUNDLED["SG"]!.years[2027]!
        #expect(all.count == 14 + 12)
        #expect(published.count == all.count)
        for (d, _) in all { #expect(DAY[weekdayOf(d)!] == published[d], "\(d)") }
        let b = bundledHolidays("SG", [2026, 2027, 2028])
        #expect(b.years == [2026, 2027])
        #expect(b.items.count == 26)
        #expect(bundledHolidays("XX", [2026]).items.isEmpty)
    }

    @Test func countryListIsSortedAndContainsSingapore() {
        #expect(COUNTRIES.contains { $0.0 == "SG" })
        let names = COUNTRIES.map { $0.1 }
        #expect(names == names.sorted { $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending })
    }

    private let sample = #"[{"date":"2026-01-01","localName":"New Year's Day","name":"New Year's Day","countryCode":"XX","fixed":true,"global":true,"counties":null,"launchYear":null,"types":["Public"]},{"date":"2026-03-17","localName":"Regional","name":"Regional","countryCode":"XX","global":false,"counties":["XX-A"],"types":["Public"]},{"date":"2026-05-01","localName":"Tag der Arbeit","name":"Labour Day","countryCode":"XX","global":true,"types":["Public"]},{"date":"2026-06-01","localName":"Observance","name":"Observance","countryCode":"XX","global":true,"types":["Observance"]},{"date":"garbage","name":"x"}]"#

    @Test func nagerReplyParsingKeepsNationwidePublicHolidaysOnly() throws {
        let items = try parseNager(try JSONParser.parse(sample), "XX")
        #expect(items.map { $0.from } == ["2026-01-01", "2026-05-01"])
        #expect(items[1].name == "Labour Day (Tag der Arbeit)")
        #expect(items[0].origin == "holiday:XX")
        #expect(throws: HolidayError.self) { try parseNager(try JSONParser.parse(#"{"error":1}"#), "XX") }
    }

    @Test func fetchHolidaysHandlesSuccess404AndNetworkFailures() async {
        let body = Data(sample.utf8)
        final class Box: @unchecked Sendable { var calls: [String] = [] }
        let box = Box()
        let fake: HTTPGet = { url in
            box.calls.append(url.absoluteString)
            if url.absoluteString.contains("/2026/") { return (200, body) }
            if url.absoluteString.contains("/2027/") { return (404, Data("{}".utf8)) }
            throw URLError(.notConnectedToInternet)
        }
        let r = await fetchHolidays("XX", [2026, 2027, 2028], get: fake)
        #expect(r.years == [2026])
        #expect(r.items.count == 2)
        #expect(r.errors.count == 2)
        #expect(box.calls[0].hasSuffix("date.nager.at/api/v3/PublicHolidays/2026/XX"))
    }

    @Test func reviewDiffAndApply() throws {
        var cal = CalendarDef(id: "c", name: "c", workWeek: MON_FRI, exceptions: [
            CalException(from: "2026-01-01", to: "2026-01-01", working: false, name: "New Year's Day", origin: "holiday:XX"),
            CalException(from: "2026-02-02", to: "2026-02-02", working: false, name: "Old auto entry", origin: "holiday:XX"),
            CalException(from: "2026-05-01", to: "2026-05-01", working: false, name: "My own note"),
            CalException(from: "2028-01-01", to: "2028-01-01", working: false, name: "Other year", origin: "holiday:XX"),
        ])
        let proposal = try parseNager(try JSONParser.parse(sample), "XX")
        let d = diffHolidays(cal, proposal, "XX", [2026])
        #expect(d.added.isEmpty)
        #expect(d.removed.count == 1)
        #expect(d.removed[0].name == "Old auto entry")
        #expect(d.skipped.count == 1)
        #expect(d.unchanged.count == 1)
        applyHolidayProposal(&cal, proposal, "XX", [2026])
        let names = cal.exceptions.map { $0.name }
        #expect(names.contains("My own note"))
        #expect(names.contains("Other year"))
        #expect(!names.contains("Old auto entry"))
        #expect(cal.exceptions.filter { $0.from == "2026-05-01" }.count == 1)
    }

    @Test func projectYearsSpan() { #expect(projectYears("2026-09-20", 3) == [2026, 2027, 2028]) }
}

@Suite struct TemplateTests {
    @Test func builtInTurnkeyTemplateSchedulesCleanly() {
        let tpl = BUILTIN_TEMPLATES.first { $0.id == "turnkey-engineering" }!
        #expect(tpl.rows.count > 60)
        let s = Session(newProject(name: "T", startDate: "2026-10-05"))
        let r = s.run("tpl") { p, _ in try applyTemplate(&p, tpl) }
        #expect(r.ok, "\(r.error ?? "")")
        #expect(s.project.tasks.count == tpl.rows.count)
        #expect(s.sched.cycles.isEmpty)
        #expect(s.sched.conflictCount == 0)
        #expect(s.sched.tasks[0].start == "2026-10-05")
        #expect(s.project.tasks.filter { $0.level == 1 }.count == 11)
        #expect(s.sched.tasks.enumerated().filter { s.project.tasks[$0.offset].level == 1 }.allSatisfy { $0.element.isSummary })
        let last = s.sched.tasks.last!
        #expect(last.finish == s.sched.projectFinish)
        #expect(last.critical)
        let noPred = s.project.tasks.enumerated().filter { !s.sched.tasks[$0.offset].isSummary && $0.element.preds.isEmpty }.map { $0.element.name }
        #expect(noPred == ["Contract award / letter of intent received"])
        let y = Int(s.sched.projectFinish!.prefix(4))!
        #expect(y >= 2029 && y <= 2030, "finish year \(y)")
    }

    @Test func aUserTemplateKeepsStructureButNoDates() throws {
        let s = richProject()
        let tpl = projectToTemplate(s.project, "Mine")
        let json = JSONWriter.stringify(tpl.json)
        #expect(json.range(of: #"2026-1\d-\d\d"#, options: .regularExpression) == nil, "no calendar dates stored")
        #expect(tpl.json["rows"]?.array?[0].object?.has("pct") == false)
        let s2 = Session(newProject(name: "New", startDate: "2027-03-01"))
        let back = try ProjectTemplate.from(json: try JSONParser.parse(json))
        s2.run("tpl") { p, _ in try applyTemplate(&p, back) }
        #expect(s2.project.tasks.count == s.project.tasks.count)
        func t(_ n: String) -> Task { s2.project.tasks.first { $0.name == n }! }
        #expect(t("B").preds[0].lag.v == 2)
        #expect(t("D").preds.count == 2)
        #expect(s.project.tasks.first { $0.name == "SNET+deadline" }!.constraint.date == "2026-11-02")
        #expect(t("SNET+deadline").constraint.date == "2027-03-29")
        #expect(t("SNET+deadline").deadline == "2027-04-26")
        #expect(t("Done").pct == 0)
        #expect(t("Done").actualStart == nil)
        #expect(s2.sched.cycles.isEmpty)
    }

    @Test func badTemplateFilesAreRejected() {
        #expect(throws: ModelError.self) { try ProjectTemplate.from(json: .object(JSONObject())) }
        #expect(throws: ModelError.self) { try ProjectTemplate.from(json: try JSONParser.parse(#"{"format":"ganttpath-template","rows":[]}"#)) }
    }
}

@Suite struct ReferenceTests {
    /// Differential test: the engine must reproduce the dates, slack and critical flags MS Project stored in a real client file.
    @Test(.enabled(if: privateFixture("awwtp_reference.json") != nil, "needs GP_PRIVATE_FIXTURES with the user's real MS Project file"))
    func engineMatchesMSProjectOnTheReal195TaskFile() throws {
        let ref = try JSONParser.parse(String(decoding: FileManager.default.contents(atPath: privateFixture("awwtp_reference.json")!)!, as: UTF8.self))
        let CMAP = ["AS_SOON_AS_POSSIBLE": "ASAP", "AS_LATE_AS_POSSIBLE": "ALAP", "MUST_START_ON": "MSO", "MUST_FINISH_ON": "MFO",
                    "START_NO_EARLIER_THAN": "SNET", "START_NO_LATER_THAN": "SNLT", "FINISH_NO_EARLIER_THAN": "FNET", "FINISH_NO_LATER_THAN": "FNLT"]
        let rows = ref["tasks"]!.array!.filter { $0["id"]?.number != 0 }
        func d10(_ v: JSON?) -> JSON { v?.string.map { .string(String($0.prefix(10))) } ?? .null }
        let tasks: [JSON] = rows.map { t in
            .object(JSONObject([
                ("uid", t["uid"]!), ("name", t["name"]!), ("level", t["level"]!),
                ("mode", .string(t["mode"]?.string == "MANUALLY_SCHEDULED" ? "manual" : "auto")),
                ("duration", t["summary"]?.truthy == true ? .number(0) : t["duration"]!),
                ("start", d10(t["start"])), ("finish", d10(t["finish"])),
                ("constraint", .object(JSONObject([("type", .string(CMAP[t["constraint"]?.string ?? ""] ?? "ASAP")), ("date", d10(t["constraintDate"]))]))),
                ("deadline", d10(t["deadline"])),
                ("preds", .array((t["preds"]?.array ?? []).map { p in
                    .object(JSONObject([("uid", p["uid"]!), ("type", p["type"]!), ("lag", .object(JSONObject([("v", p["lag"]!), ("u", p["lagUnits"]!)])))]))
                })),
                ("pct", t["pct"] ?? .number(0)), ("actualStart", d10(t["actualStart"])), ("actualFinish", d10(t["actualFinish"])),
            ]))
        }
        let pj = JSON.object(JSONObject([
            ("settings", .object(JSONObject([("startDate", d10(ref["projectStart"])), ("honorConstraints", .bool(true)), ("criticalSlackDays", .number(0)), ("defaultCalendarId", .string("std"))]))),
            ("calendars", .array([CalendarDef(id: "std", name: "Standard", workWeek: MON_FRI).json])),
            ("tasks", .array(tasks)),
        ]))
        let r = schedule(try Project.from(json: pj))
        var byUid: [Int: JSON] = [:]
        for t in ref["tasks"]!.array! { byUid[Int(t["uid"]!.number!)] = t }
        var leaves = 0
        for row in r.tasks {
            let t = byUid[row.uid]!
            #expect(row.start == String(t["start"]!.string!.prefix(10)), "start of task \(row.id)")
            #expect(row.finish == String(t["finish"]!.string!.prefix(10)), "finish of task \(row.id)")
            #expect(row.critical == t["critical"]!.truthy, "critical flag of task \(row.id)")
            #expect(row.totalSlack == t["totalSlack"]!.number, "total slack of row \(row.id)")
            #expect(row.freeSlack == t["freeSlack"]!.number, "free slack of row \(row.id)")
            if row.isSummary { #expect(row.lateFinish == String(t["lateFinish"]!.string!.prefix(10)), "late finish of summary \(row.id)") }
            else { leaves += 1 }
        }
        #expect(leaves == 180)
        #expect(r.projectFinish == "2032-03-24")
    }
}
