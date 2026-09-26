// Shared helpers for the tests: small projects written the same way as in the JavaScript app's tests.

import Foundation
import Testing
@testable import GanttpathCore

/// One task of a test project: `dur` in days of 8 hours, `preds` as typed in the Predecessors column (row numbers).
struct TL {
    var dur: Double = 1
    var preds = ""
    var level = 1
    var mode = "auto"
    var start: String? = nil
    var finish: String? = nil
    var c = "ASAP"
    var cd: String? = nil
    var deadline: String? = nil
    var pct: Double = 0
    var cal: String? = nil
    var aS: String? = nil
    var aF: String? = nil
    var name: String? = nil
    var milestone = false
}

func mk(_ list: [TL], start: String = "2026-10-05", exceptions: [CalException] = [], honor: Bool = true, week: [Bool]? = nil,
        cals: [CalendarDef] = [], near: Double = 2, hoursPerDay: Double = 8, hours: [[RawPeriod]]? = nil) -> Project {
    var s = defaultSettings(start)
    s.honorConstraints = honor
    s.criticalSlackDays = 0
    s.nearCriticalDays = near
    s.defaultCalendarId = "std"
    s.hoursPerDay = hoursPerDay
    var std = CalendarDef(id: "std", name: "Standard", workWeek: week ?? MON_FRI, hours: hours, exceptions: exceptions)
    std.hours = hours
    var p = Project(name: "Test", settings: s, calendars: [std] + cals)
    p.tasks = list.enumerated().map { (i, x) in
        let r = parsePredecessors(x.preds, { $0 >= 1 && $0 <= list.count ? $0 : nil })
        var t = Task(uid: i + 1)
        t.name = x.name ?? "T\(i + 1)"
        t.level = x.level
        t.mode = x.mode
        t.dur = jsRoundInt(x.dur * hoursPerDay * 60)
        t.start = x.start; t.finish = x.finish
        t.constraint = Constraint(type: x.c, date: x.cd)
        t.deadline = x.deadline
        t.preds = r.preds
        t.pct = x.pct
        t.calendarId = x.cal
        t.actualStart = x.aS; t.actualFinish = x.aF
        t.milestone = x.milestone
        return t
    }
    p.nextUid = list.count + 1
    return p
}

func run(_ list: [TL], start: String = "2026-10-05", exceptions: [CalException] = [], honor: Bool = true, week: [Bool]? = nil,
         cals: [CalendarDef] = [], near: Double = 2) -> ScheduleResult {
    schedule(mk(list, start: start, exceptions: exceptions, honor: honor, week: week, cals: cals, near: near))
}

func dates(_ r: ScheduleResult, _ id: Int) -> [String?] { [r.tasks[id - 1].start, r.tasks[id - 1].finish] }
func stamps(_ r: ScheduleResult, _ id: Int) -> [String?] { [r.tasks[id - 1].startStamp, r.tasks[id - 1].finishStamp] }

/// The folder with the test fixtures (the sample project, reference files).
let fixturesDir: String = {
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return here.appendingPathComponent("Fixtures").path
}()
func fixture(_ name: String) -> String { (fixturesDir as NSString).appendingPathComponent(name) }
func readFixture(_ name: String) -> String { String(decoding: FileManager.default.contents(atPath: fixture(name)) ?? Data(), as: UTF8.self) }

/// A throwaway folder under the system's temporary folder.
func tempDir(_ tag: String = "gp") -> String {
    let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(tag)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func exc(_ from: String, _ to: String? = nil, working: Bool = false, name: String = "", periods: [RawPeriod]? = nil) -> CalException {
    CalException(from: from, to: to ?? from, working: working, name: name, periods: periods)
}

/// The JavaScript tests' richProject(): every kind of link, lag, constraint, a manual task, ALAP, MFO, a finished task,
/// two calendars (holiday, Christmas range, an extra working Saturday), baselines 0 and 3, a status date and critical slack 1.
func richProject() -> Session {
    let s = Session(newProject(name: "Rich & <test>", startDate: "2026-10-05"))
    s.run("cal") { p, _ in
        try upsertCalendar(&p, CalendarDef(id: "std", name: "Standard", workWeek: MON_FRI, exceptions: [
            exc("2026-10-12", name: "Holiday A"), exc("2026-12-24", "2026-12-28", name: "Xmas"), exc("2026-10-10", working: true, name: "Extra Sat"),
        ]))
    }
    s.run("cal") { p, _ in try upsertCalendar(&p, CalendarDef(id: "six", name: "Six day", workWeek: [false, true, true, true, true, true, true])) }
    @discardableResult
    func add(_ name: String, _ level: Int, _ days: Double? = nil, _ f: @escaping (inout Task) -> Void = { _ in }) -> Int {
        s.run("add") { p, _ in insertTask(&p, p.tasks.count, level: level, name: name, durationDays: days, configure: f).uid }.value!
    }
    func P(_ uid: Int, _ type: String, _ v: Double, _ u: String) -> Pred { Pred(uid: uid, type: type, lag: Lag(v: v, u: u)) }
    let ph = add("Phase 1", 1)
    let a = add("A", 2, 5) { $0.notes = "a & b <c>" }
    let b = add("B", 2, 3) { $0.preds = [P(a, "FS", 2, "d")] }
    let c = add("C", 2, 4) { $0.preds = [P(a, "SS", 50, "%")]; $0.calendarId = "six" }
    let d = add("D", 2, 2) { $0.preds = [P(b, "FF", 1, "w"), P(c, "SF", 2, "ed")] }
    add("Milestone", 2, 0) { $0.preds = [P(d, "FS", 0, "d")] }
    add("Month milestone", 2, 3) { $0.milestone = true }
    add("Manual", 2, 3) { $0.mode = "manual"; $0.start = "2026-10-20"; $0.finish = "2026-10-22" }
    add("SNET+deadline", 2, 2) { $0.constraint = Constraint(type: "SNET", date: "2026-11-02"); $0.deadline = "2026-11-30" }
    add("ALAP", 2, 2) { $0.constraint = Constraint(type: "ALAP", date: nil) }
    add("MFO", 2, 3) { $0.constraint = Constraint(type: "MFO", date: "2026-11-13") }
    add("Done", 2, 4) { $0.pct = 100; $0.actualStart = "2026-10-05"; $0.actualFinish = "2026-10-08" }
    add("Phase 2", 1)
    add("P2 task", 2, 6) { $0.preds = [P(ph, "FS", 0, "d")] }
    s.run("bl") { p, sc in try setBaseline(&p, 0, sc); try setBaseline(&p, 3, sc) }
    s.run("set") { p, _ in try updateSettings(&p, JSONObject([("statusDate", .string("2026-10-20")), ("criticalSlackDays", JSON(1))])) }
    return s
}

/// Private reference files (the user's real MS Project file), never stored in the repository. Set GP_PRIVATE_FIXTURES to the folder.
let privateFixtures: String? = ProcessInfo.processInfo.environment["GP_PRIVATE_FIXTURES"]
func privateFixture(_ name: String) -> String? {
    guard let d = privateFixtures else { return nil }
    let p = (d as NSString).appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: p) ? p : nil
}
