// Elapsed durations (MS Project's emin, ehr, eday, ewk, emon): the task runs round the clock, weekends and holidays included.
// The dates MS Project calculated come from MPXJ's test file junit/data/DurationTest9.mpp (read with MPXJ): each elapsed task
// starts at the project start, Monday 13 March 2006 08:00, and finishes exactly its length later.

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct ElapsedTests {
    @Test func typingAndShowingElapsedDurations() {
        let s = newProject(name: "E", startDate: "2026-10-05").settings
        #expect(parseDuration("3ed", s) == DurationSpec(min: 3 * 1440, unit: "ed"))
        #expect(parseDuration("3 edays", s) == DurationSpec(min: 3 * 1440, unit: "ed"))
        #expect(parseDuration("36eh", s) == DurationSpec(min: 36 * 60, unit: "eh"))
        #expect(parseDuration("2ew", s) == DurationSpec(min: 2 * 7 * 1440, unit: "ew"))
        #expect(parseDuration("1emo", s) == DurationSpec(min: 30 * 1440, unit: "emo"))
        #expect(parseDuration("45em", s) == DurationSpec(min: 45, unit: "em"))
        #expect(parseDuration("3d", s) == DurationSpec(min: 3 * 480, unit: "d")) // working days are unchanged
        #expect(formatDuration(4320, "ed", s) == "3ed")
        #expect(formatDuration(2160, "ed", s) == "1.5ed")
        #expect(formatDuration(43200, "emo", s) == "1emo")
        // a task keeps an elapsed unit through a save
        var p = newProject(name: "E", startDate: "2026-10-05")
        _ = insertTask(&p, 0, level: 1, name: "Cure", configure: { $0.dur = 4320; $0.durUnit = "ed" })
        let back = try? Project.from(json: p.json)
        #expect(back?.tasks[0].durUnit == "ed" && back?.tasks[0].dur == 4320)
    }

    /// The five elapsed tasks of DurationTest9.mpp, with the durations and dates MS Project stored.
    static let msProject: [(name: String, unit: String, minutes: Int, start: String, finish: String)] = [
        ("Task 1el", "em", 1, "2006-03-13T08:00", "2006-03-13T08:01"),
        ("Task 2el", "eh", 60, "2006-03-13T08:00", "2006-03-13T09:00"),
        ("Task 3el", "ed", 1440, "2006-03-13T08:00", "2006-03-14T08:00"),
        ("Task 4el", "ew", 7 * 1440, "2006-03-13T08:00", "2006-03-20T08:00"),
        ("Task 5el", "emo", 30 * 1440, "2006-03-13T08:00", "2006-04-12T08:00"),
    ]

    @Test func scheduledAsMSProjectDoes() throws {
        var p = newProject(name: "E", startDate: "2006-03-13")
        for (k, e) in Self.msProject.enumerated() {
            _ = insertTask(&p, k, level: 1, name: e.name, configure: { $0.dur = e.minutes; $0.durUnit = e.unit })
        }
        let s = schedule(p)
        for (k, e) in Self.msProject.enumerated() {
            #expect(s.tasks[k].startStamp == e.start, "\(e.name) start")
            #expect(s.tasks[k].finishStamp == e.finish, "\(e.name) finish")
            #expect(formatDuration(s.tasks[k].durationMin, s.tasks[k].durUnit, p.settings) == "1\(e.unit)")
        }
    }

    @Test func linkedElapsedTaskRunsOverTheWeekend() throws {
        // A: 5 working days, Monday 5 to Friday 9 October 2026, finishing Friday 17:00.
        // B (FS, 3 elapsed days) runs from Friday 17:00 over the weekend to Monday 17:00 - MS Project's rule for elapsed durations,
        // "24 hours a day, 7 days a week", as it is documented (no MS Project file with a linked elapsed task was available to check).
        // C (FS, 1 working day) then starts at the next working moment, Tuesday 08:00.
        var p = newProject(name: "E", startDate: "2026-10-05")
        let a = insertTask(&p, 0, level: 1, name: "A", durationDays: 5).uid
        let b = insertTask(&p, 1, level: 1, name: "Cure", configure: { $0.dur = 3 * 1440; $0.durUnit = "ed" }).uid
        _ = insertTask(&p, 2, level: 1, name: "C", durationDays: 1)
        p.tasks[1].preds = [Pred(uid: a, type: "FS", lag: Lag(v: 0, u: "d"))]
        p.tasks[2].preds = [Pred(uid: b, type: "FS", lag: Lag(v: 0, u: "d"))]
        let s = schedule(p)
        #expect(s.tasks[0].finishStamp == "2026-10-09") // a whole working day: stored without a time (17:00)
        #expect(s.tasks[1].startStamp == "2026-10-09T17:00" && s.tasks[1].finishStamp == "2026-10-12T17:00")
        #expect(s.tasks[2].startStamp == "2026-10-13" && s.tasks[2].finishStamp == "2026-10-13") // Tuesday 08:00 to 17:00
        #expect(s.conflicts.isEmpty)
        #expect(s.tasks[0].critical && s.tasks[2].critical)
        // B could finish as late as Tuesday 08:00 without delaying C: 15 hours of slack, counted round the clock like its duration
        #expect(s.tasks[1].totalSlackMin == 15 * 60 && !s.tasks[1].critical)
        // a holiday on the Monday does not stop an elapsed task
        p.calendars[0].exceptions = [CalException(from: "2026-10-12", to: "2026-10-12", working: false, name: "Holiday")]
        let h = schedule(p)
        #expect(h.tasks[1].finishStamp == "2026-10-12T17:00")
        #expect(h.tasks[2].startStamp == "2026-10-13")
    }

    @Test func msProjectXMLRoundTrip() throws {
        var p = newProject(name: "E", startDate: "2026-10-05")
        _ = insertTask(&p, 0, level: 1, name: "Cure", configure: { $0.dur = 3 * 1440; $0.durUnit = "ed" })
        _ = insertTask(&p, 1, level: 1, name: "Soak", configure: { $0.dur = 36 * 60; $0.durUnit = "eh" })
        let xml = exportMSPDI(p, schedule(p)).xml
        let root = try parseXml(xml)
        let t = kids(root.kid("Tasks"), "Task").filter { $0.kidText("UID") != "0" }
        #expect(t.map { $0.kidText("Duration")! } == ["PT72H0M0S", "PT36H0M0S"])
        #expect(t.map { $0.kidText("DurationFormat")! } == ["8", "6"])
        #expect(t[0].kidText("Start") == "2026-10-05T08:00:00" && t[0].kidText("Finish") == "2026-10-08T08:00:00")
        let back = try importMSPDI(xml)
        #expect(back.project.tasks.map { $0.durUnit } == ["ed", "eh"])
        #expect(back.project.tasks.map { $0.dur } == [4320, 2160])
        #expect(back.report.matched == back.report.compared && back.report.compared == 2)
        #expect(back.report.notes.contains { $0.text.hasPrefix("2 task(s) have elapsed durations: they run round the clock") })
    }

    /// MPXJ's own reading of DurationTest9.mpp, when GP_MPXJ_XML points at a folder holding it as DurationTest9.xml.
    @Test func theRealMSProjectFile() throws {
        guard let dir = ProcessInfo.processInfo.environment["GP_MPXJ_XML"], FileManager.default.fileExists(atPath: dir + "/DurationTest9.xml") else { return }
        let r = try importMSPDI(String(contentsOfFile: dir + "/DurationTest9.xml", encoding: .utf8))
        // every task, working, estimated and elapsed, gets the dates MS Project calculated
        #expect(r.report.compared == 15 && r.report.matched == 15, "\(r.report.differences.map { "\($0.name): \($0.file) vs \($0.ganttpath)" })")
        let s = schedule(r.project)
        for e in Self.msProject {
            let k = try #require(r.project.tasks.firstIndex { $0.name == e.name })
            #expect(r.project.tasks[k].durUnit == e.unit)
            #expect(s.tasks[k].startStamp == e.start && s.tasks[k].finishStamp == e.finish, "\(e.name)")
        }
    }
}
