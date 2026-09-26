// Ported from test/hours.test.js (Ganttpath 1.3.6): hour-based planning, working hours in calendars, "Hours per day".

import Foundation
import Testing
@testable import GanttpathCore

private let H = 60
private let WEEK = MON_FRI
private func at(_ iso: String, _ hhmm: String) -> Int {
    let dn = parseISO(iso)!
    let p = hhmm.split(separator: ":").map { Int($0)! }
    return dn * 1440 + p[0] * 60 + p[1]
}
private func show(_ t: Int) -> String { let dn = floorDiv(t, 1440); return "\(toISO(dn)) \(fmtHM(t - dn * 1440))" }

/// A task for the hour tests: `min` working minutes (or `d` days of Hours per day).
private struct HT {
    var min: Int? = nil
    var d: Double? = nil
    var unit = "d"
    var preds: [Pred] = []
    var mode = "auto"
}

private func mkH(_ list: [HT], hoursPerDay: Double = 8, hoursPerWeek: Double = 40, hours: [[RawPeriod]]? = nil,
                 exceptions: [CalException] = [], start: String = "2026-10-05") -> Project {
    var s = defaultSettings(start)
    s.hoursPerDay = hoursPerDay; s.hoursPerWeek = hoursPerWeek
    var p = Project(name: "h", settings: s, calendars: [CalendarDef(id: "std", name: "Standard", workWeek: WEEK, hours: hours, exceptions: exceptions)])
    p.tasks = list.enumerated().map { (i, x) in
        var t = Task(uid: i + 1)
        t.name = "T\(i + 1)"
        t.dur = x.min ?? jsRoundInt((x.d ?? 1) * hoursPerDay * 60)
        t.durUnit = x.unit
        t.preds = x.preds
        t.mode = x.mode
        return t
    }
    return p
}
private func runH(_ list: [HT], hoursPerDay: Double = 8, hours: [[RawPeriod]]? = nil, exceptions: [CalException] = [], start: String = "2026-10-05") -> ScheduleResult {
    schedule(mkH(list, hoursPerDay: hoursPerDay, hours: hours, exceptions: exceptions, start: start))
}

@Suite struct HoursTests {
    @Test func workingMinutesAndMomentsRoundTrip() {
        let c = Cal(defaultCalendarDef())
        let fri = parseISO("2026-10-30")!
        #expect(c.minutesOf(fri) == 480)
        #expect(c.midx(fri + 3) - c.midx(fri) == 480) // Friday to Monday: one working day
        let p = c.posOf(at("2026-10-30", "17:00"))
        #expect(show(c.finishAt(p)) == "2026-10-30 17:00") // work that stopped
        #expect(show(c.startAt(p)) == "2026-11-02 08:00")  // work that resumes
        #expect(show(c.normStart(at("2026-10-30", "12:00"))) == "2026-10-30 13:00")
        #expect(show(c.normFinish(at("2026-10-30", "12:30"))) == "2026-10-30 12:00")
        #expect(show(c.normStart(at("2026-10-31", "10:00"))) == "2026-11-02 08:00") // Saturday
        #expect(show(c.normFinish(at("2026-11-01", "23:00"))) == "2026-10-30 17:00") // Sunday
        // every working minute maps back to itself, for a calendar with odd hours, a short Saturday and a special day
        let wk: [RawPeriod] = [[420, 690], [750, 1140]]
        let odd = Cal(CalendarDef(id: "x", name: "x", workWeek: [false, true, true, true, true, true, true],
                                  hours: [[], wk, wk, wk, wk, [[420, 690], [750, 1080]], [[480, 720]]],
                                  exceptions: [exc("2026-12-24", working: true, periods: [[480, 600]]), exc("2026-12-25")]))
        var pos = 0
        while pos < 200000 {
            #expect(odd.posOf(odd.startAt(pos)) == pos, "startAt(\(pos))")
            #expect(odd.posOf(odd.finishAt(pos)) == pos, "finishAt(\(pos))")
            #expect(odd.finishAt(pos) <= odd.startAt(pos))
            pos += 977
        }
        #expect(odd.minutesOf(parseISO("2026-12-24")!) == 120)
        #expect(!odd.isWorking(parseISO("2026-12-25")!))
    }

    @Test func hourTasksSkipLunchAndTheNextTaskCarriesOn() {
        let r = runH([HT(min: 6 * H, unit: "h"), HT(min: 4 * H, unit: "h", preds: [Pred(uid: 1)])])
        #expect(stamps(r, 1) == ["2026-10-05T08:00", "2026-10-05T15:00"])
        // 2 h left on Monday (15:00-17:00) and 2 h on Tuesday morning
        #expect(stamps(r, 2) == ["2026-10-05T15:00", "2026-10-06T10:00"])
        #expect(r.tasks[0].timed)
        #expect(r.tasks[0].durationMin == 360)
        #expect(r.tasks[0].duration == 0.75) // days of 8 h
    }

    @Test func wholeDayTasksStayDateOnly() {
        let r = runH([HT(d: 2), HT(min: 3 * H, unit: "h", preds: [Pred(uid: 1)]), HT(d: 1, preds: [Pred(uid: 2)])])
        #expect(!r.tasks[0].timed)
        #expect(stamps(r, 1) == ["2026-10-05", "2026-10-06"])
        #expect(stamps(r, 2) == ["2026-10-07T08:00", "2026-10-07T11:00"])
        #expect(r.tasks[2].timed)
        #expect(stamps(r, 3) == ["2026-10-07T11:00", "2026-10-08T11:00"])
        #expect(r.tasks[2].start == "2026-10-07")
        #expect(r.tasks[2].finish == "2026-10-08")
    }

    @Test func milestoneAfterATask() {
        let r = runH([HT(d: 5), HT(d: 0, preds: [Pred(uid: 1)])])
        #expect(dates(r, 2) == ["2026-10-09", "2026-10-09"])
        #expect(!r.tasks[1].timed)
        let q = runH([HT(min: 2 * H, unit: "h"), HT(d: 0, preds: [Pred(uid: 1)])])
        #expect(stamps(q, 2) == ["2026-10-05T10:00", "2026-10-05T10:00"])
    }

    @Test func lagsInDaysHoursMinutesAndElapsed() {
        func lagged(_ lag: Lag) -> ScheduleResult { runH([HT(d: 1), HT(d: 1, preds: [Pred(uid: 1, lag: lag)])]) }
        #expect(stamps(lagged(Lag(v: 1, u: "d")), 2) == ["2026-10-07", "2026-10-07"])
        #expect(stamps(lagged(Lag(v: 4, u: "h")), 2) == ["2026-10-06T13:00", "2026-10-07T12:00"])
        #expect(stamps(lagged(Lag(v: 30, u: "m")), 2) == ["2026-10-06T08:30", "2026-10-07T08:30"])
        #expect(stamps(lagged(Lag(v: 1, u: "ed")), 2)[0] == "2026-10-07") // Mon 17:00 + 24 clock hours = Tue 17:00, work resumes Wed 08:00
    }

    @Test func parseLagAndParseDuration() {
        #expect(parseLag("+4h") == Lag(v: 4, u: "h"))
        #expect(parseLag("-30min") == Lag(v: -30, u: "m"))
        #expect(parseLag("2eh") == Lag(v: 2, u: "eh"))
        #expect(parseLag("3ed") == Lag(v: 3, u: "ed"))
        var s = defaultSettings("2026-01-01"); s.hoursPerDay = 8; s.hoursPerWeek = 40
        #expect(parseDuration("6h", s) == DurationSpec(min: 360, unit: "h"))
        #expect(parseDuration("1.5 hrs", s) == DurationSpec(min: 90, unit: "h"))
        #expect(parseDuration("45m", s) == DurationSpec(min: 45, unit: "m"))
        #expect(parseDuration("0.5d", s) == DurationSpec(min: 240, unit: "d"))
        #expect(parseDuration("2w", s) == DurationSpec(min: 4800, unit: "w"))
        #expect(parseDuration("1mo", s) == DurationSpec(min: 9600, unit: "mo"))
        var s12 = s; s12.hoursPerDay = 12
        #expect(parseDuration("5d", s12) == DurationSpec(min: 3600, unit: "d"))
        #expect(parseDuration("abc", s) == nil)
        #expect(formatDuration(2400, "d", s) == "5d")
        #expect(formatDuration(2400, "d", s12) == "3.33d") // the same 40 hours shown in 12 h days
        #expect(formatDuration(360, "h", s) == "6h")
        #expect(formatSpan(960, s) == "2d")
        #expect(formatSpan(240, s) == "4h")
    }

    @Test func fortyHoursInATwelveHourDay() {
        let twelve: [[RawPeriod]] = (0..<7).map { _ in [[360, 720], [780, 1140]] } // 06:00-12:00 and 13:00-19:00
        let list = [HT(d: 5), HT(d: 5, preds: [Pred(uid: 1)])]
        let std = runH(list)
        #expect([std.tasks[0].finish, std.tasks[1].finish] == ["2026-10-09", "2026-10-16"])
        let long = runH(list, hours: twelve)
        #expect(long.tasks[0].durationMin == 2400) // still 40 working hours
        #expect(stamps(long, 1) == ["2026-10-05T06:00", "2026-10-08T10:00"]) // Mon, Tue, Wed 12 h each + 4 h on Thursday
        #expect(stamps(long, 2) == ["2026-10-08T10:00", "2026-10-13T15:00"])
        #expect(long.projectFinish == "2026-10-13")
    }

    @Test func hoursPerDayChangesOnlyNewlyTypedDurations() {
        let s = Session(newProject(name: "p", startDate: "2026-10-05"))
        s.run("add") { p, _ in insertTask(&p, 0, name: "A", durationDays: 5) }
        #expect(s.project.tasks[0].dur == 2400)
        s.run("hpd") { p, _ in try updateSettings(&p, JSONObject([("hoursPerDay", JSON(12))])) }
        #expect(s.project.tasks[0].dur == 2400, "stored hours do not change")
        #expect(s.sched.tasks[0].duration == 40.0 / 12)
        #expect(s.sched.tasks[0].finish == "2026-10-09", "the calendar still works 8 h a day, so 40 h is still 5 days")
        let uid = s.project.tasks[0].uid
        s.run("typed") { p, _ in try setDuration(&p, uid, parseDuration("5d", p.settings)!) }
        #expect(s.project.tasks[0].dur == 3600)
        #expect(s.sched.tasks[0].durationMin == 3600)
        #expect([s.sched.tasks[0].startStamp, s.sched.tasks[0].finishStamp] == ["2026-10-05T08:00", "2026-10-14T12:00"]) // 60 h in 8 h days = 7 days 4 h
    }

    @Test func specialHoursOnANamedDate() {
        let r = runH([HT(d: 1), HT(d: 1, preds: [Pred(uid: 1)])], exceptions: [exc("2026-12-24", working: true, name: "Christmas Eve", periods: [[480, 600]])], start: "2026-12-23")
        // Wed 23-Dec is a normal 8 h day; Thursday 24-Dec has only 2 h (08:00-10:00); the 8 h task then needs 6 h on Friday
        #expect(stamps(r, 1) == ["2026-12-23", "2026-12-23"])
        #expect(stamps(r, 2) == ["2026-12-24T08:00", "2026-12-25T15:00"])
        #expect(r.tasks[1].timed)
    }

    @Test func manualTasksKeepTypedTimes() throws {
        let s = Session(newProject(name: "p", startDate: "2026-10-05"))
        s.run("add") { p, _ in insertTask(&p, 0, name: "M", dur: 360) { $0.mode = "manual"; $0.durUnit = "h" } }
        let uid = s.project.tasks[0].uid
        s.run("start") { p, _ in try setStart(&p, uid, "2026-10-06T13:00") }
        #expect(s.project.tasks[0].start == "2026-10-06T13:00")
        #expect(s.project.tasks[0].finish == "2026-10-07T10:00") // 4 h (13:00-17:00) + 2 h
        s.run("dur") { p, _ in try setDuration(&p, uid, DurationSpec(min: 90, unit: "m")) }
        #expect(s.project.tasks[0].finish == "2026-10-06T14:30")
        s.run("fin") { p, _ in try setFinish(&p, uid, "2026-10-06T16:00") }
        #expect(s.project.tasks[0].dur == 180)
        var p = s.project
        #expect(throws: ModelError.self) { try setFinish(&p, uid, "2026-10-06T09:00") }
        do { try setFinish(&p, uid, "2026-10-06T09:00") } catch let e as ModelError { #expect(e.message.contains("before start")) }
    }

    @Test func filesFromBeforeHourPlanningAreConverted() throws {
        let old = try JSONParser.parse(#"{"schema":1,"name":"old","settings":{"startDate":"2026-10-05"},"calendars":[{"id":"std","name":"Standard","workWeek":[false,true,true,true,true,true,false],"exceptions":[]}],"tasks":[{"uid":1,"name":"A","level":1,"duration":3},{"uid":2,"name":"B","level":1,"duration":0}]}"#)
        let p = try Project.from(json: old)
        #expect(p.tasks.map { $0.dur } == [1440, 0])
        #expect(p.tasks.map { $0.durUnit } == ["d", "d"])
        #expect(p.tasks.allSatisfy { $0.json.object?.has("duration") == false })
        #expect(p.schema == SCHEMA)
        #expect(p.settings.hoursPerDay == 8)
    }

    @Test func calendarPeriodsTextInTextOut() {
        #expect(formatPeriods(DEFAULT_PERIODS) == "08:00-12:00, 13:00-17:00")
        #expect(parsePeriods("8-12, 1pm-5pm") == [Period(480, 720), Period(780, 1020)])
        #expect(parsePeriods("06:00-18:00") == [Period(360, 1080)])
        #expect(parsePeriods("") == [])
        #expect(parsePeriods("12-8") == nil)
        #expect(parsePeriods("abc") == nil)
    }

    @Test func savedCalendarsKeepTheirHours() {
        let s = Session(newProject(name: "p", startDate: "2026-10-05"))
        let long: [RawPeriod] = [[420, 720], [780, 1140]]
        let hours: [[RawPeriod]] = [[], long, long, long, long, [[420, 720]], []]
        s.run("cal") { p, _ in try upsertCalendar(&p, CalendarDef(id: "std", name: "Long", workWeek: WEEK, hours: hours)) }
        #expect(s.project.calendars[0].hours![5] == [[420, 720]])
        let bad = s.run("cal") { p, _ in try upsertCalendar(&p, CalendarDef(id: "std", name: "Bad", workWeek: WEEK, hours: [[], [], [], [], [], [], []])) }
        #expect(!bad.ok)
        #expect(bad.error?.contains("working period") == true)
    }
}
