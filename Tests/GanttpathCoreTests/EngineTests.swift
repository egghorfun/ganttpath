// Ported from test/engine.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct EngineTests {
    @Test func fsChainWorkingDaysSlackAndCriticalPath() {
        let r = run([TL(dur: 5), TL(dur: 5, preds: "1"), TL(dur: 3)])
        #expect(dates(r, 1) == ["2026-10-05", "2026-10-09"])
        #expect(dates(r, 2) == ["2026-10-12", "2026-10-16"])
        #expect(dates(r, 3) == ["2026-10-05", "2026-10-07"])
        #expect(r.tasks[0].totalSlack == 0); #expect(r.tasks[0].critical)
        #expect(r.tasks[1].critical)
        #expect(r.tasks[2].totalSlack == 7); #expect(!r.tasks[2].critical)
        #expect(r.tasks[2].freeSlack == 7)
        #expect(r.projectFinish == "2026-10-16")
        #expect(r.conflictCount == 0)
    }

    @Test func parallelBranchesSlackFreeSlackNearCritical() {
        let r = run([TL(dur: 5), TL(dur: 3), TL(dur: 2, preds: "1,2")])
        #expect(r.tasks[1].totalSlack == 2)
        #expect(r.tasks[1].freeSlack == 2)
        #expect(!r.tasks[1].critical)
        #expect(r.tasks[1].nearCritical)
        #expect(r.tasks[1].lateFinish == "2026-10-09")
        #expect(dates(r, 3) == ["2026-10-12", "2026-10-13"])
    }

    @Test func lagAndLead() {
        var r = run([TL(dur: 2), TL(dur: 1, preds: "1FS+2d")])
        #expect(dates(r, 2) == ["2026-10-09", "2026-10-09"])
        r = run([TL(dur: 2), TL(dur: 1, preds: "1FS-1d")])
        #expect(dates(r, 2) == ["2026-10-06", "2026-10-06"])
        r = run([TL(dur: 5), TL(dur: 2, preds: "1SS+2d")])
        #expect(dates(r, 2) == ["2026-10-07", "2026-10-08"])
        r = run([TL(dur: 5), TL(dur: 2, preds: "1FF")])
        #expect(dates(r, 2) == ["2026-10-08", "2026-10-09"])
        r = run([TL(dur: 5), TL(dur: 2, preds: "1FF+1d")])
        #expect(dates(r, 2) == ["2026-10-09", "2026-10-12"])
        r = run([TL(dur: 2, c: "SNET", cd: "2026-10-12"), TL(dur: 3, preds: "1SF")])
        #expect(dates(r, 2) == ["2026-10-07", "2026-10-09"])
        r = run([TL(dur: 10), TL(dur: 1, preds: "1FS+50%")])
        #expect(dates(r, 2) == ["2026-10-26", "2026-10-26"])
        r = run([TL(dur: 5), TL(dur: 1, preds: "1FS+1w")])
        #expect(dates(r, 2) == ["2026-10-19", "2026-10-19"])
        r = run([TL(dur: 5), TL(dur: 1, preds: "1FS+2ed")])
        #expect(dates(r, 2) == ["2026-10-12", "2026-10-12"]) // Fri + 2 elapsed days = Sun -> Monday
        r = run([TL(dur: 1), TL(dur: 1, preds: "1FS+1ed")])
        #expect(dates(r, 2) == ["2026-10-07", "2026-10-07"]) // Mon + 1 elapsed day -> Wed
        #expect(r.conflictCount == 0)
    }

    @Test func milestonesTakeTheDateOfTheirPredecessorFinish() {
        let r = run([TL(dur: 5), TL(dur: 0, preds: "1"), TL(dur: 2, preds: "2"), TL(dur: 0)])
        #expect(dates(r, 2) == ["2026-10-09", "2026-10-09"])
        #expect(r.tasks[1].isMilestone)
        #expect(dates(r, 3) == ["2026-10-12", "2026-10-13"])
        #expect(dates(r, 4) == ["2026-10-05", "2026-10-05"])
    }

    @Test func holidaysAreSkipped() {
        let r = run([TL(dur: 5, c: "SNET", cd: "2026-10-07")], exceptions: [exc("2026-10-12")])
        #expect(dates(r, 1) == ["2026-10-07", "2026-10-14"])
    }

    @Test func monSatCalendarAndTaskCalendar() {
        var r = run([TL(dur: 6)], week: [false, true, true, true, true, true, true])
        #expect(dates(r, 1) == ["2026-10-05", "2026-10-10"])
        let six = CalendarDef(id: "six", name: "Six", workWeek: [false, true, true, true, true, true, true])
        r = run([TL(dur: 6, cal: "six"), TL(dur: 1, preds: "1")], cals: [six])
        #expect(dates(r, 1) == ["2026-10-05", "2026-10-10"])
        #expect(dates(r, 2) == ["2026-10-12", "2026-10-12"])
    }

    @Test func constraints() {
        var r = run([TL(dur: 2, c: "SNET", cd: "2026-10-14")])
        #expect(dates(r, 1) == ["2026-10-14", "2026-10-15"])
        r = run([TL(dur: 2, c: "SNET", cd: "2026-10-10")]) // Saturday -> Monday
        #expect(dates(r, 1) == ["2026-10-12", "2026-10-13"])
        r = run([TL(dur: 3, c: "MFO", cd: "2026-10-16")])
        #expect(dates(r, 1) == ["2026-10-14", "2026-10-16"])
        r = run([TL(dur: 2, c: "FNET", cd: "2026-10-16")])
        #expect(dates(r, 1) == ["2026-10-15", "2026-10-16"])
        // MSO earlier than predecessor allows: constraint wins, link flagged
        let list = [TL(dur: 20), TL(dur: 2, preds: "1", c: "MSO", cd: "2026-10-14")]
        r = run(list)
        #expect(dates(r, 2) == ["2026-10-14", "2026-10-15"])
        #expect(r.tasks[1].conflicts.contains { $0.type == "link" })
        #expect(r.links[0].conflict)
        // honour switched off: dependencies win, a conflict note is still raised
        r = run(list, honor: false)
        #expect(dates(r, 2) == ["2026-11-02", "2026-11-03"])
        #expect(r.tasks[1].conflicts.contains { $0.type == "constraint" })
        // SNLT that predecessors make impossible
        r = run([TL(dur: 5), TL(dur: 1, preds: "1", c: "SNLT", cd: "2026-10-08")])
        #expect(dates(r, 2) == ["2026-10-12", "2026-10-12"])
        #expect(r.tasks[1].conflicts.contains { $0.type == "constraint" })
        #expect(r.tasks[1].totalSlack! < 0)
        // FNLT met -> no conflict, slack limited by the constraint
        r = run([TL(dur: 3, c: "FNLT", cd: "2026-10-16"), TL(dur: 15)])
        #expect(r.conflictCount == 0)
        #expect(r.tasks[0].totalSlack == 7)
        // deadline missed
        r = run([TL(dur: 5, deadline: "2026-10-07")])
        #expect(r.tasks[0].conflicts.contains { $0.type == "deadline" })
        #expect(r.tasks[0].totalSlack == -2)
        // MSO on a weekend
        r = run([TL(dur: 1, c: "MSO", cd: "2026-10-10")])
        #expect(r.tasks[0].conflicts.contains { $0.type == "calendar" })
    }

    @Test func alapPushesATaskToItsLateStart() {
        let r = run([TL(dur: 2, c: "ALAP"), TL(dur: 10), TL(dur: 1, preds: "1,2")])
        #expect(dates(r, 1) == ["2026-10-15", "2026-10-16"])
        #expect(r.tasks[0].totalSlack == 0)
        #expect(dates(r, 3) == ["2026-10-19", "2026-10-19"])
    }

    @Test func manualTasksKeepTheirDates() {
        var r = run([TL(dur: 5), TL(dur: 3, mode: "manual", start: "2026-10-12", finish: "2026-10-14"), TL(dur: 1, preds: "2")])
        #expect(dates(r, 2) == ["2026-10-12", "2026-10-14"])
        #expect(dates(r, 3) == ["2026-10-15", "2026-10-15"])
        r = run([TL(dur: 5), TL(dur: 3, preds: "1", mode: "manual", start: "2026-10-07", finish: "2026-10-09")])
        #expect(dates(r, 2) == ["2026-10-07", "2026-10-09"])
        #expect(r.tasks[1].conflicts.contains { $0.type == "link" })
    }

    @Test func completedTasksHaveNoSlackAndUseActualDates() {
        let r = run([TL(dur: 5, pct: 100, aS: "2026-10-06", aF: "2026-10-12"), TL(dur: 2, preds: "1")])
        #expect(dates(r, 1) == ["2026-10-06", "2026-10-12"])
        #expect(!r.tasks[0].critical)
        #expect(r.tasks[0].totalSlack == 0)
        #expect(dates(r, 2) == ["2026-10-13", "2026-10-14"])
        #expect(r.tasks[1].critical)
    }

    @Test func summaryTasks() {
        var list = [
            TL(level: 1, name: "Phase"),         // 1  -> 1
            TL(dur: 4, level: 2),                // 2  -> 1.1
            TL(level: 2, name: "Z"),             // 3  -> 1.2 (summary)
            TL(dur: 3, level: 3),                // 4  -> 1.2.1
            TL(dur: 2, preds: "4", level: 3),    // 5  -> 1.2.2
            TL(dur: 1, preds: "5", level: 1),    // 6  -> 2
        ]
        list[2].preds = "2"
        let r = run(list)
        #expect(r.tasks.map { $0.wbs } == ["1", "1.1", "1.2", "1.2.1", "1.2.2", "2"])
        #expect(r.tasks.map { $0.isSummary } == [true, false, true, false, false, false])
        #expect(dates(r, 2) == ["2026-10-05", "2026-10-08"])
        #expect(dates(r, 4) == ["2026-10-09", "2026-10-13"])
        #expect(dates(r, 5) == ["2026-10-14", "2026-10-15"])
        #expect(dates(r, 3) == ["2026-10-09", "2026-10-15"])
        #expect(r.tasks[2].duration == 5)
        #expect(dates(r, 1) == ["2026-10-05", "2026-10-15"])
        #expect(dates(r, 6) == ["2026-10-16", "2026-10-16"])
        #expect(r.tasks[0].critical)
        let lv = [1, 2, 2, 3, 1, 2].map { l -> Task in var t = Task(uid: 0); t.level = l; return t }
        #expect(computeWBS(lv) == ["1", "1.1", "1.2", "1.2.1", "2", "2.1"])
    }

    @Test func circularDependenciesAreDetected() {
        let r = run([TL(dur: 1, preds: "2"), TL(dur: 1, preds: "1"), TL(dur: 2)])
        #expect(r.cycles.count == 2)
        #expect(r.conflicts.contains { $0.type == "cycle" })
        #expect(dates(r, 3) == ["2026-10-05", "2026-10-06"])
    }

    @Test func applyScheduleWritesBackAutoAndSummaryDatesOnly() {
        var p = mk([TL(dur: 2), TL(dur: 3, mode: "manual", start: "2026-10-12", finish: "2026-10-14")])
        applySchedule(&p, schedule(p))
        #expect(p.tasks[0].start == "2026-10-05")
        #expect(p.tasks[1].start == "2026-10-12")
    }

    @Test func performance2000Tasks() {
        var list: [TL] = []
        var seed = 7
        func rnd() -> Double { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return Double(seed) / Double(0x7fffffff) }
        for ph in 0..<20 {
            list.append(TL(level: 1, name: "Phase \(ph)"))
            for k in 0..<99 {
                let id = list.count + 1
                let preds = k > 0 ? "\(id - 1)" : ph > 0 ? "\(id - 2)" : ""
                let extra = k > 3 && rnd() < 0.3 ? ",\(id - 2 - Int(rnd() * 3))SS+1d" : ""
                var p = preds + extra
                if p.hasPrefix(",") { p.removeFirst() }
                list.append(TL(dur: Double(1 + Int(rnd() * 20)), preds: p, level: 2))
            }
        }
        let t0 = Date()
        let r = run(list)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("  2000 tasks scheduled in \(Int(ms)) ms")
        #expect(r.tasks.count == 2000)
        #expect(ms < 1500, "too slow: \(ms)")
        #expect(r.cycles.isEmpty)
    }
}
