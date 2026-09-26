// Ported from test/sample.test.js (Ganttpath 1.3.6).
// The sample project shipped to the user: every number below was worked out by hand (working days Mon-Fri, one example holiday on
// 09-Nov-2026) BEFORE running the engine, so this is an independent check of the scheduler, not a snapshot of its output.
// These are tables A-D of the test checklist (page 10).

import Foundation
import Testing
@testable import GanttpathCore

// id: [start, finish, duration, totalSlack, freeSlack, critical]   (free slack of summary rows is not part of the hand check)
private let HAND: [Int: (String, String, Double, Double, Double?, Bool)] = [
    1: ("2026-10-05", "2026-10-28", 18, 7, nil, false),
    2: ("2026-10-05", "2026-10-07", 3, 7, 0, false),
    3: ("2026-10-08", "2026-10-14", 5, 7, 0, false),
    4: ("2026-10-19", "2026-10-22", 4, 7, 0, false),
    5: ("2026-10-21", "2026-10-28", 6, 7, 0, false),
    6: ("2026-10-22", "2026-10-28", 5, 7, 7, false),
    7: ("2026-10-05", "2026-11-06", 25, 0, nil, true),
    8: ("2026-10-05", "2026-10-06", 2, 0, 0, true),
    9: ("2026-10-07", "2026-10-27", 15, 0, 0, true),
    10: ("2026-10-28", "2026-11-03", 5, 0, 0, true),
    11: ("2026-11-04", "2026-11-06", 3, 0, 0, true),
    12: ("2026-10-26", "2026-11-13", 14, 0, nil, true),
    13: ("2026-10-26", "2026-10-27", 2, 8, 8, false),
    14: ("2026-11-10", "2026-11-13", 4, 0, 0, true),
    15: ("2026-11-13", "2026-11-13", 0, 0, 0, true),
]

func checkSample(_ sess: Session, _ label: String) {
    let rows = sess.sched.tasks
    #expect(rows.count == 15, "\(label)")
    guard rows.count == 15 else { return }
    for (id, h) in HAND.sorted(by: { $0.key < $1.key }) {
        let r = rows[id - 1]
        let msg = "\(label) row \(id) \(sess.project.tasks[id - 1].name)"
        #expect(r.start == h.0, "\(msg) start")
        #expect(r.finish == h.1, "\(msg) finish")
        #expect(r.duration == h.2, "\(msg) duration")
        #expect(r.totalSlack == h.3, "\(msg) total slack")
        if let fs = h.4 { #expect(r.freeSlack == fs, "\(msg) free slack") }
        #expect(r.critical == h.5, "\(msg) critical")
    }
    #expect(sess.sched.conflicts.isEmpty, "\(label) conflicts")
}

@Suite struct SampleTests {
    @Test func engineAgreesWithTheHandCalculation() { checkSample(samplePumpStation(), "built") }

    @Test func sampleFileOnDiskAgreesWithTheHandCalculation() throws {
        let file = try loadProjectFile(fixture("Ganttpath_Sample_Pump_Station.gpath"))
        checkSample(Session(file.project), "file")
    }

    @Test func msProjectXMLExportReimportsWithTheSameDates() throws {
        let s = samplePumpStation()
        let out = try exportProject("xml", s.project)
        let tmp = (tempDir("gp-sample") as NSString).appendingPathComponent("x.xml")
        FileManager.default.createFile(atPath: tmp, contents: out.data)
        let r = try importFile(tmp)
        checkSample(Session(r.project), "xml")
    }

    // Excavate 7d -> days 4-10 = 08..16-Oct; Foundations (FS+2d) days 13-16 = 21..26-Oct; Steel (SS+2d) days 15-20 = 23..30-Oct;
    // Piping (FF) days 16-20 = 26..30-Oct; the equipment chain still decides the finish (13-Nov) so those four rows keep 5 days of slack.
    @Test func whatIfExcavateTakes7Days() {
        let s = samplePumpStation()
        s.run("dur") { p, _ in try setDurationDays(&p, p.tasks[2].uid, 7) }
        let r = s.sched.tasks
        #expect([r[2].start, r[2].finish] == ["2026-10-08", "2026-10-16"])
        #expect([r[3].start, r[3].finish] == ["2026-10-21", "2026-10-26"])
        #expect([r[4].start, r[4].finish] == ["2026-10-23", "2026-10-30"])
        #expect([r[5].start, r[5].finish] == ["2026-10-26", "2026-10-30"])
        for i in [2, 3, 4, 5] { #expect(r[i].totalSlack == 5) }
        #expect(r[14].finish == "2026-11-13")
        s.undo()
        checkSample(s, "after undo")
    }

    // Deadline 10-Nov-2026 on Handover: the late finish of the equipment chain moves from day 29 to day 26, so its slack is -3 and every
    // other row (2-6 had 7, Permit had 8) loses 3 days. Handover breaks its deadline; the five tasks that drive it carry the negative slack.
    @Test func whatIfDeadlineOnHandover() {
        let s = samplePumpStation()
        s.run("dl") { p, _ in try setDeadline(&p, p.tasks[14].uid, "2026-11-10") }
        let r = s.sched.tasks
        for i in [7, 8, 9, 10, 13, 14] { #expect(r[i].totalSlack == -3, "row \(i + 1)") }
        for i in [1, 2, 3, 4, 5] { #expect(r[i].totalSlack == 4, "row \(i + 1)") }
        #expect(r[12].totalSlack == 5)
        #expect(s.sched.conflicts.map { $0.index + 1 }.sorted() == [8, 9, 10, 11, 14, 15])
        let c15 = s.sched.conflicts.first { $0.index == 14 }!
        #expect(c15.type == "deadline")
        #expect(c15.message.contains("10-Nov-2026"))
    }

    // Lag: Commissioning depends on Install pump with FS+2d. Install pump ends day 25 (06-Nov); +2 working days of lag (09-Nov is a
    // holiday) -> starts day 28 = 12-Nov; 4 days = 12, 13, 16, 17-Nov. Handover follows on 17-Nov.
    @Test func whatIfTwoDaysOfLag() {
        let s = samplePumpStation()
        s.run("lag") { p, _ in
            let ins = p.tasks[10].uid
            try setPredecessors(&p, p.tasks[13].uid, p.tasks[13].preds.map { $0.uid == ins ? Pred(uid: $0.uid, type: $0.type, lag: Lag(v: 2, u: "d")) : $0 })
        }
        let r = s.sched.tasks
        #expect([r[13].start, r[13].finish] == ["2026-11-12", "2026-11-17"])
        #expect([r[14].start, r[14].finish] == ["2026-11-17", "2026-11-17"])
    }

    // Tables E and F of the checklist (page 11).
    // Table E - Standard calendar changed to 07:00-13:00, 14:00-20:00 (12 hours a day).
    @Test func tableETwelveHourCalendar() throws {
        let s = samplePumpStation()
        let per: [RawPeriod] = [[420, 780], [840, 1200]]
        s.run("cal") { p, _ in
            var c = p.calendars[0]
            c.hours = (0..<7).map { c.workWeek[$0] ? per : [] }
            return try upsertCalendar(&p, c)
        }
        let r = s.sched.tasks
        #expect(stamps(s.sched, 2) == ["2026-10-05", "2026-10-06"])
        #expect(stamps(s.sched, 3) == ["2026-10-07T07:00", "2026-10-12T11:00"])
        #expect(stamps(s.sched, 4) == ["2026-10-13T16:00", "2026-10-16T11:00"])
        #expect(stamps(s.sched, 8) == ["2026-10-05T07:00", "2026-10-06T11:00"])
        #expect(stamps(s.sched, 11) == ["2026-10-23T16:00", "2026-10-27T16:00"])
        #expect(stamps(s.sched, 14) == ["2026-10-27T16:00", "2026-10-30T11:00"])
        #expect(stamps(s.sched, 15) == ["2026-10-30T11:00", "2026-10-30T11:00"])
        #expect(!r[1].timed) // Mobilise shows no time
        #expect(r[2].timed)  // Excavate shows both times
    }

    // Table F - Excavate made inactive.
    @Test func tableFExcavateInactive() {
        let s = samplePumpStation()
        s.run("inactive") { p, _ in try setTaskFlag(&p, p.tasks[2].uid, "inactive", true) }
        #expect(dates(s.sched, 3) == ["2026-10-08", "2026-10-14"])
        #expect(dates(s.sched, 4) == ["2026-10-05", "2026-10-08"])
        #expect(dates(s.sched, 5) == ["2026-10-07", "2026-10-14"])
        #expect(dates(s.sched, 6) == ["2026-10-08", "2026-10-14"])
        #expect(dates(s.sched, 1) == ["2026-10-05", "2026-10-14"])
        #expect(s.sched.tasks[0].duration == 8)
        #expect(dates(s.sched, 15) == ["2026-11-13", "2026-11-13"])
        s.run("active") { p, _ in try setTaskFlag(&p, p.tasks[2].uid, "inactive", false) }
        checkSample(s, "active again")
    }
}
