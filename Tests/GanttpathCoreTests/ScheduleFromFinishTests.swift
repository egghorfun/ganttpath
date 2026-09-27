// Scheduling from the project finish date (MS Project's Project Information > Schedule from: Project Finish Date): tasks are placed
// back from the finish, new automatic tasks are As Late As Possible, and the project start is calculated.

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct ScheduleFromFinishTests {
    /// Must finish Friday 16 October 2026. A (3 days) -> B (2 days), both made while scheduling from the finish (so ALAP);
    /// C (1 day) is As Soon As Possible.
    func project() throws -> Project {
        var p = newProject(name: "F", startDate: "2026-10-01")
        try setScheduleFrom(&p, finish: true, finishDate: "2026-10-16")
        let a = insertTask(&p, 0, level: 1, name: "A", durationDays: 3).uid
        let b = insertTask(&p, 1, level: 1, name: "B", durationDays: 2).uid
        _ = insertTask(&p, 2, level: 1, name: "C", durationDays: 1, configure: { $0.constraint = .asap })
        p.tasks[1].preds = [Pred(uid: a)]
        _ = b
        return p
    }

    @Test func newTasksAreAsLateAsPossible() throws {
        let p = try project()
        #expect(p.tasks[0].constraint.type == "ALAP" && p.tasks[1].constraint.type == "ALAP")
        var q = newProject(name: "S", startDate: "2026-10-01")
        _ = insertTask(&q, 0, level: 1, name: "X", durationDays: 1)
        #expect(q.tasks[0].constraint.type != "ALAP") // scheduling from the start: unchanged
    }

    @Test func tasksArePlacedBackFromTheFinish() throws {
        let s = schedule(try project())
        // B ends on the finish date; A ends just before B starts; the project start is calculated: Monday 12 October
        #expect([s.tasks[1].start, s.tasks[1].finish] == ["2026-10-15", "2026-10-16"])
        #expect([s.tasks[0].start, s.tasks[0].finish] == ["2026-10-12", "2026-10-14"])
        #expect(s.projectStart == "2026-10-12" && s.projectFinish == "2026-10-16")
        #expect(s.tasks[0].totalSlackMin == 0 && s.tasks[1].totalSlackMin == 0 && s.tasks[0].critical && s.tasks[1].critical)
        // C, As Soon As Possible, starts with the project and has the rest of the time as slack
        #expect([s.tasks[2].start, s.tasks[2].finish] == ["2026-10-12", "2026-10-12"])
        #expect(s.tasks[2].totalSlackMin == 4 * 480 && !s.tasks[2].critical)
        #expect(s.conflicts.isEmpty)
    }

    @Test func aLaterFinishMovesEverythingAndATooEarlyOneShowsAConflict() throws {
        var p = try project()
        try setScheduleFrom(&p, finish: true, finishDate: "2026-10-23")
        let s = schedule(p)
        #expect([s.tasks[1].start, s.tasks[1].finish] == ["2026-10-22", "2026-10-23"])
        #expect(s.projectStart == "2026-10-19")
        // a task that cannot start before the 20th (Start No Earlier Than) pushes past the finish: negative slack, as in MS Project
        p.tasks[0].constraint = Constraint(type: "SNET", date: "2026-10-21")
        let t = schedule(p)
        #expect(t.tasks[1].finish == "2026-10-27")
        #expect((t.tasks[1].totalSlackMin ?? 0) < 0)
        #expect(t.conflicts.contains { $0.type == "slack" })
    }

    @Test func settingIsSavedAndClearedAndStartSchedulingIsUnchanged() throws {
        let p = try project()
        let back = try Project.from(json: p.json)
        #expect(back.settings.scheduleFromFinish && back.settings.finishDate == "2026-10-16")
        #expect(schedule(back).tasks.map { $0.finish } == schedule(p).tasks.map { $0.finish })
        var q = p
        try setScheduleFrom(&q, finish: false)
        #expect(!q.settings.scheduleFromFinish && q.settings.finishDate == nil)
        #expect(q.settings.json["scheduleFrom"] == nil && q.settings.json["finishDate"] == nil) // files scheduled from the start: as before
        #expect(throws: ModelError.self) { try setScheduleFrom(&q, finish: true, finishDate: "not a date") }
    }

    @Test func msProjectXMLRoundTrip() throws {
        let p = try project()
        let xml = exportMSPDI(p, schedule(p)).xml
        let root = try parseXml(xml)
        #expect(root.kidText("ScheduleFromStart") == "0")
        #expect(root.kidText("FinishDate") == "2026-10-16T17:00:00")
        #expect(root.kidText("StartDate") == "2026-10-12T08:00:00")
        let back = try importMSPDI(xml)
        #expect(back.project.settings.scheduleFromFinish && back.project.settings.finishDate == "2026-10-16")
        #expect(back.project.tasks.map { $0.constraint.type } == ["ALAP", "ALAP", "ASAP"])
        #expect(back.report.compared == 3 && back.report.matched == 3, "\(back.report.differences.map { "\($0.name): \($0.file) vs \($0.ganttpath)" })")
        #expect(back.report.notes.contains { $0.text.hasPrefix("This project is scheduled from its finish date, as in MS Project") })
    }

    /// MS Project's own files (mpp14header.mpp etc. in MPXJ's tests, read with MPXJ) are scheduled from Wednesday 23 August 2006 17:00.
    @Test func realMSProjectHeaderFile() throws {
        guard let dir = ProcessInfo.processInfo.environment["GP_MPXJ_XML"], FileManager.default.fileExists(atPath: dir + "/mpp14header.xml") else { return }
        let r = try importMSPDI(String(contentsOfFile: dir + "/mpp14header.xml", encoding: .utf8))
        // that file's working day is 08:35 to 17:35, so 17:00 is a time of its own and is kept
        #expect(r.project.settings.scheduleFromFinish && r.project.settings.finishDate == "2006-08-23T17:00")
    }
}
