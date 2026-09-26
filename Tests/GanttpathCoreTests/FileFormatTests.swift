// Ported from test/mspdi.test.js, test/persist.test.js and test/ops.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

private let ORDER: [String: [String]] = {
    let j = try! JSONParser.parse(readFixture("mspdi-order.json"))
    var out: [String: [String]] = [:]
    for (k, v) in j.object!.pairs { out[k] = v.array!.map { $0.string! } }
    return out
}()

private func checkOrder(_ node: XmlNode, _ order: [String], _ where_: String) {
    var last = -1
    for c in node.children {
        let idx = order.firstIndex(of: c.name) ?? -1
        #expect(idx >= 0, "\(where_): unexpected element <\(c.name)>")
        #expect(idx >= last, "\(where_): <\(c.name)> is out of schema order")
        last = idx
    }
}
@discardableResult
private func checkAllOrders(_ xml: String) throws -> XmlNode {
    let root = try parseXml(xml)
    #expect(root.name == "Project")
    checkOrder(root, ORDER["Project"]!, "Project")
    for cal in kids(root.kid("Calendars"), "Calendar") {
        checkOrder(cal, ORDER["Calendar"]!, "Calendar")
        for wd in kids(cal.kid("WeekDays"), "WeekDay") { checkOrder(wd, ORDER["WeekDay"]!, "WeekDay") }
        for ex in kids(cal.kid("Exceptions"), "Exception") { checkOrder(ex, ORDER["Exception"]!, "Exception") }
    }
    for t in kids(root.kid("Tasks"), "Task") {
        checkOrder(t, ORDER["Task"]!, "Task \(t.kid("UID")!.text)")
        for l in t.kids("PredecessorLink") { checkOrder(l, ORDER["Link"]!, "PredecessorLink") }
        for b in t.kids("Baseline") { checkOrder(b, ORDER["Baseline"]!, "Baseline") }
    }
    return root
}

private func localDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
    return Calendar.current.date(from: c)!
}

@Suite struct MSPDITests {
    @Test func exportedXMLFollowsTheSchemaOrderAndReimportsToTheSameProject() throws {
        let s = richProject()
        let xml = exportMSPDI(s.project, s.sched, now: localDate(2026, 9, 20, 12)).xml
        try checkAllOrders(xml)
        let r = try importMSPDI(xml)
        let s2 = Session(r.project)
        func pick(_ proj: Project, _ sc: ScheduleResult) -> [String] {
            proj.tasks.enumerated().map { (i, t) in
                let summary = sc.tasks[i].isSummary
                let cal = t.calendarId.flatMap { id in proj.calendars.first { $0.id == id }?.name } ?? "nil"
                return [String(t.uid), t.name, String(t.level), t.mode, String(summary ? 0 : t.dur), t.durUnit, String(t.milestone),
                        t.constraint.type, t.constraint.date ?? "nil", t.deadline ?? "nil", jsNumberString(summary ? 0 : t.pct), t.actualStart ?? "nil",
                        t.actualFinish ?? "nil", cal, t.notes, "\(t.preds)", "\(t.baselines)"].joined(separator: "|")
            }
        }
        #expect(pick(s2.project, s2.sched) == pick(s.project, s.sched))
        #expect(s2.project.name == s.project.name)
        #expect(s2.project.settings.statusDate == "2026-10-20")
        #expect(s2.project.settings.criticalSlackDays == 1)
        func sched(_ x: Session) -> [String] { x.sched.tasks.map { "\($0.start ?? "")|\($0.finish ?? "")|\($0.totalSlack ?? -999)|\($0.critical)" } }
        #expect(sched(s2) == sched(s))
        let std = s2.project.calendars.first { $0.name == "Standard" }!
        #expect(std.workWeek == MON_FRI)
        let ex = std.exceptions.map { "\($0.from)|\($0.to ?? "")|\($0.working)|\($0.name)" }.sorted()
        #expect(ex == ["2026-10-10|2026-10-10|true|Extra Sat", "2026-10-12|2026-10-12|false|Holiday A", "2026-12-24|2026-12-28|false|Xmas"].sorted())
        #expect(r.report.differenceCount == 0)
    }

    @Test func lagEncodingsMatchMPXJ() throws {
        let s = richProject()
        let root = try parseXml(exportMSPDI(s.project, s.sched).xml)
        let taskD = kids(root.kid("Tasks"), "Task").first { $0.kid("Name")?.text == "D" }!
        let links = taskD.kids("PredecessorLink").map { [$0.kid("Type")!.text, $0.kid("LinkLag")!.text, $0.kid("LagFormat")!.text] }
        #expect(links == [["0", "24000", "9"], ["2", "28800", "8"]]) // FF+1w, SF+2ed
    }

    @Test func specialCharactersSurviveAndMalformedInputGivesReadableErrors() {
        let s = richProject()
        let xml = exportMSPDI(s.project, s.sched).xml
        #expect(xml.contains("Rich &amp; &lt;test&gt;"))
        #expect(throws: ModelError.self) { try importMSPDI("<Project><Tasks></Project>") }
        do { _ = try importMSPDI("<Project><Tasks></Project>") } catch let e as ModelError { #expect(e.message.contains("Cannot read this XML")) } catch {}
        do { _ = try importMSPDI("<html></html>") } catch let e as ModelError { #expect(e.message.contains("not an MS Project XML")) } catch {}
    }

    @Test func daysPerMonthRoundTrips() throws {
        let s = richProject()
        s.run("dpm") { p, _ in try updateSettings(&p, JSONObject([("daysPerMonth", JSON(22))])) }
        let xml = exportMSPDI(s.project, s.sched).xml
        #expect(try parseXml(xml).kid("DaysPerMonth")?.text == "22")
        #expect(try importMSPDI(xml).project.settings.daysPerMonth == 22)
        let noField = xml.replacingOccurrences(of: "<DaysPerMonth>22</DaysPerMonth>", with: "")
        #expect(!noField.contains("DaysPerMonth"))
        #expect(try importMSPDI(noField).project.settings.daysPerMonth == 20)
    }

    @Test(.enabled(if: privateFixture("awwtp_mppjs.xml") != nil, "needs GP_PRIVATE_FIXTURES with the user's real MS Project file"))
    func realMSProjectFileReproducesEveryStoredDate() throws {
        let xml = String(decoding: FileManager.default.contents(atPath: privateFixture("awwtp_mppjs.xml")!)!, as: UTF8.self)
        let r = try importMSPDI(xml, fileName: "awwtp.xml")
        #expect(r.project.tasks.count == 195)
        #expect(r.report.stats["links"]! > 0)
        #expect(r.report.differenceCount == 0, "\(r.report.differences.prefix(5))")
        #expect(r.report.compared == 96 + 15)
        let s = Session(r.project)
        #expect(s.sched.projectFinish == "2032-03-24")
        let out = exportMSPDI(s.project, s.sched)
        try checkAllOrders(out.xml)
        let again = try importMSPDI(out.xml)
        #expect(again.report.differenceCount == 0)
        #expect(again.project.tasks.count == 195)
    }
}

@Suite struct PersistTests {
    @Test func familyNameStripsTimestampsAndUnsafeCharacters() {
        #expect(familyName("Plant_2026-09-20_1405.gpath") == "Plant")
        #expect(familyName("Plant_2026-09-20_140533.gpath") == "Plant")
        #expect(familyName("Plant_2026-09-20_1405_auto.gpath") == "Plant")
        #expect(familyName("Plant_2026-09-20_1405-2.gpath") == "Plant")
        #expect(familyName("A/B:C?") == "A_B_C_")
        #expect(familyName("") == "Project")
    }

    @Test func manualSavesNeverOverwrite() throws {
        let dir = tempDir()
        let s = richProject()
        let f1 = try saveVersion(dir, "Plant", s.project, now: localDate(2026, 9, 20, 14, 5, 10))
        #expect((f1 as NSString).lastPathComponent == "Plant_2026-09-20_1405.gpath")
        let f2 = try saveVersion(dir, "Plant", s.project, now: localDate(2026, 9, 20, 14, 5, 40)) // same minute
        #expect((f2 as NSString).lastPathComponent == "Plant_2026-09-20_140540.gpath")
        let f3 = try saveVersion(dir, "Plant", s.project, now: localDate(2026, 9, 20, 14, 5, 40)) // same second
        #expect((f3 as NSString).lastPathComponent == "Plant_2026-09-20_140540-2.gpath")
        let f4 = try saveVersion(dir, "Plant_2026-09-20_1405", s.project, now: localDate(2026, 9, 20, 15, 0, 0)) // opened a versioned file
        #expect((f4 as NSString).lastPathComponent == "Plant_2026-09-20_1500.gpath")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir)
        #expect(names.filter { $0.hasSuffix(".gpath") }.count == 4)
        #expect(names.filter { $0.contains(".tmp-") }.isEmpty)
        let l = try loadProjectFile(f1)
        #expect(l.project.tasks.count == s.project.tasks.count)
        #expect(l.kind == "manual")
    }

    @Test func autosavesSeparateFolderNewest20Kept() throws {
        let dir = tempDir()
        let s = richProject()
        let manual = try saveVersion(dir, "Plant", s.project, now: localDate(2026, 9, 1, 9))
        for i in 0..<27 { try saveVersion(dir, "Plant", s.project, kind: "auto", now: localDate(2026, 9, 2, 9, i * 2)) }
        let autos = try FileManager.default.contentsOfDirectory(atPath: (dir as NSString).appendingPathComponent(AUTOSAVE_DIR)).filter { $0.hasSuffix(".gpath") }
        #expect(autos.count == AUTOSAVE_KEEP)
        #expect(FileManager.default.fileExists(atPath: manual))
        #expect(!autos.contains { $0.contains("_0900_auto") })
        #expect(autos.contains { $0.contains("_0952_auto") })
        try saveVersion(dir, "Other", s.project, kind: "auto", now: localDate(2026, 9, 3, 9))
        #expect(pruneAutosaves(dir, "Plant").isEmpty)
        let versions = listVersions(dir, "Plant")
        #expect(versions.count == 1 + AUTOSAVE_KEEP)
        #expect(versions.filter { $0.kind == "manual" }.count == 1)
        #expect(versions[0].time >= versions[1].time)
    }

    @Test func loadingRejectsDamagedForeignAndNewerFiles() throws {
        func msg(_ t: String) -> String { do { _ = try parseProjectText(t); return "" } catch { return "\(error)" } }
        #expect(msg("{ nope").contains("damaged"))
        #expect(msg(#"{"hello":1}"#).contains("not a Ganttpath project"))
        #expect(msg(#"{"format":"ganttpath","schema":99,"project":{}}"#).contains("newer version"))
        let ok = try parseProjectText(#"{"format":"ganttpath","schema":1,"project":{"tasks":[{"uid":1,"name":"x","level":3}]}}"#)
        #expect(ok.project.tasks[0].level == 1)
    }

    @Test func compareTwoVersions() {
        let s = richProject()
        let before = s.project
        s.run("edit") { p, _ in
            let a = p.tasks.first { $0.name == "A" }!.uid
            try setDurationDays(&p, a, 8)
            let b = p.tasks.first { $0.name == "B" }!.uid
            try setName(&p, b, "B renamed")
            insertTask(&p, p.tasks.count, level: 1, name: "Brand new")
            deleteTasks(&p, [p.tasks.first { $0.name == "ALAP" }!.uid])
        }
        let after = s.project
        let r = compareProjects(before, after)
        #expect(r.summary.added == 1)
        #expect(r.summary.removed == 1)
        #expect(r.summary.changed >= 2)
        let a = r.tasks.first { $0.name == "A" }!
        #expect(a.changes.contains { $0.field == "duration" && $0.from == "5" && $0.to == "8" })
        #expect(r.tasks.first { $0.name == "B renamed" }!.changes.contains { $0.field == "name" })
        let d = r.tasks.first { $0.name == "D" }
        #expect(d != nil && d!.changes.contains { $0.field == "start" }, "a later A moves D")
        #expect(compareProjects(before, before).summary.identical)
    }

    @Test func sessionRoundTripThroughAFileKeepsEverything() throws {
        let dir = tempDir()
        let s = richProject()
        let f = try saveVersion(dir, "X", s.project)
        let s2 = Session(try loadProjectFile(f).project)
        #expect(s2.json() == s.json())
    }
}

@Suite struct OpsTests {
    private func dates(_ s: Session) -> [String] { s.sched.tasks.map { "\($0.start ?? "")|\($0.finish ?? "")" } }

    @Test func exportThenImportXMLExcelAndCSV() throws {
        let s = richProject()
        s.run("dpm") { p, _ in try updateSettings(&p, JSONObject([("daysPerMonth", JSON(19))])) }
        let dir = tempDir("gp-ops")
        for fmt in ["xml", "xlsx"] {
            let out = try exportProject(fmt, s.project)
            let file = (dir as NSString).appendingPathComponent("p\(out.ext)")
            FileManager.default.createFile(atPath: file, contents: out.data)
            let r = try importFile(file)
            guard case .imported = r else { Issue.record("\(fmt): not an import"); continue }
            let s2 = Session(r.project)
            #expect(names(s2) == names(s), "\(fmt)")
            #expect(dates(s2) == dates(s), "\(fmt): same dates")
            #expect(s2.project.settings.daysPerMonth == 19, "\(fmt): Days per month round-trips")
        }
        let csv = try exportProject("csv", s.project)
        #expect(!csv.notes.isEmpty)
        let file = (dir as NSString).appendingPathComponent("p.csv")
        FileManager.default.createFile(atPath: file, contents: csv.data)
        var o = TableImportOptions(); o.startDate = s.project.settings.startDate
        let r = try importFile(file, options: o)
        #expect(r.project.tasks.count == s.project.tasks.count, "the appended settings block is not read back as extra tasks")
        #expect(r.project.settings.daysPerMonth == 19)
        if case .imported(let res, _, _) = r { #expect(!res.report.notes.isEmpty) }
        // (fixed in the Swift version: the JavaScript 1.3.6 CSV export wrote "[object Object]" for the project start and status date)
        let text = String(decoding: csv.data, as: UTF8.self)
        #expect(text.contains("Project start,2026-10-05"))
        #expect(text.contains("Status date,2026-10-20"))
        #expect(!text.contains("[object Object]"))
        let r2 = try importFile(file)
        #expect(r2.project.settings.startDate == "2026-10-05")
        #expect(r2.project.settings.statusDate == "2026-10-20")
    }

    @Test func savedGpathOpensThroughTheSameEntryPoint() throws {
        let s = richProject()
        let dir = tempDir("gp-ops")
        let file = try saveVersion(dir, "Plant", s.project, kind: "manual", now: localDate(2026, 9, 20, 14, 5))
        let r = try importFile(file)
        guard case .gpath = r else { Issue.record("not a gpath"); return }
        #expect(r.project.tasks.count == s.project.tasks.count)
        let bad = (dir as NSString).appendingPathComponent("x.docx")
        FileManager.default.createFile(atPath: bad, contents: Data())
        do { _ = try importFile(bad); Issue.record("should fail") } catch { #expect("\(error)".contains("cannot open")) }
    }

    @Test func damagedAndForeignFilesGiveReadableErrors() {
        let dir = tempDir("gp-ops")
        func write(_ n: String, _ t: String) -> String { let f = (dir as NSString).appendingPathComponent(n); FileManager.default.createFile(atPath: f, contents: Data(t.utf8)); return f }
        func err(_ f: String) -> String? { do { _ = try importFile(f); return nil } catch { return "\(error)" } }
        #expect(err(write("bad.gpath", "{not json"))?.contains("damaged") == true)
        #expect(err(write("bad.xml", "<Foo/>"))?.contains("not an MS Project XML") == true)
        #expect(err(write("bad.xlsx", "PK-not-really")) != nil)
        #expect(err(write("empty.csv", ""))?.contains("empty") == true)
    }

    @Test func missingMppReaderGivesTheFallbackAdvice() {
        let dir = tempDir("gp-ops")
        let f = (dir as NSString).appendingPathComponent("x.mpp")
        FileManager.default.createFile(atPath: f, contents: Data("x".utf8))
        do { _ = try importFile(f, mpp: nil); Issue.record("should fail") } catch { #expect("\(error)".contains("Save As")) }
    }

    @Test func userTemplatesSaveListDelete() throws {
        let dir = tempDir("gp-ops")
        let s = richProject()
        let t = projectToTemplate(s.project, "My plant / v1", "x")
        let file = try saveUserTemplate(dir, t)
        #expect(FileManager.default.fileExists(atPath: file))
        let list = listUserTemplates(dir)
        #expect(list.count == 1)
        #expect(list[0].template.rows.count == s.project.tasks.count)
        try deleteUserTemplate(dir, list[0].file)
        #expect(listUserTemplates(dir).isEmpty)
        #expect(throws: FileError.self) { try deleteUserTemplate(dir, "../evil.txt") }
        #expect(BUILTIN_TEMPLATES.count >= 2)
    }
}
