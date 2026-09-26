// Ported from test/calendar.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct CalendarTests {
    @Test func datesISORoundTripWeekdayFormats() {
        let dn = parseISO("2026-09-20")!
        #expect(toISO(dn) == "2026-09-20")
        #expect(dow(dn) == 0) // Sunday
        #expect(dow(parseISO("2026-10-05")!) == 1) // Monday
        #expect(dow(parseISO("1970-01-01")!) == 4) // Thursday
        #expect(formatDate(dn) == "20-Sep-2026")
        #expect(formatDate(dn, "DD/MM/YYYY") == "20/09/2026")
        #expect(parseISO("2026-02-30") == nil)
        #expect(parseDateInput("20-Sep-2026") == dn)
        #expect(parseDateInput("20 sep 26") == dn)
        #expect(parseDateInput("Sep 20 2026") == dn)
        #expect(parseDateInput("20/09/2026", "DD/MM/YYYY") == dn)
        #expect(parseDateInput("09/20/2026", "MM/DD/YYYY") == dn)
        #expect(parseDateInput("garbage") == nil)
        #expect(toISO(addMonthsDn(parseISO("2026-01-31")!, 1)) == "2026-02-28")
        #expect(toISO(endOfMonthDn(parseISO("2026-02-10")!)) == "2026-02-28")
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 20; c.hour = 14; c.minute = 5
        #expect(stampFromDate(Calendar.current.date(from: c)!) == "2026-09-20_1405")
    }

    func naiveIdx(_ cal: Cal, _ dn: Int) -> Int { var c = 0; for d in 0..<dn where cal.isWorking(d) { c += 1 }; return c }

    @Test func monFriBasics() {
        let cal = Cal(CalendarDef(id: "x", name: "x", workWeek: MON_FRI))
        let fri = parseISO("2026-10-02")!, mon = parseISO("2026-10-05")!
        #expect(cal.isWorking(fri))
        #expect(!cal.isWorking(fri + 1))
        #expect(cal.next(fri + 1) == mon)
        #expect(cal.prev(mon - 1) == fri)
        #expect(cal.shift(mon, 5) == parseISO("2026-10-12"))
        #expect(cal.shift(mon, -1) == fri)
        #expect(cal.count(mon, parseISO("2026-10-09")!) == 5)
        #expect(cal.count(fri, mon) == 2)
    }

    @Test func holidaysAndExtraWorkingDays() {
        let cal = Cal(CalendarDef(id: "x", name: "x", workWeek: MON_FRI, exceptions: [
            exc("2026-10-12", name: "Holiday"), exc("2026-10-10", working: true, name: "Extra Saturday"),
        ]))
        #expect(!cal.isWorking(parseISO("2026-10-12")!))
        #expect(cal.isWorking(parseISO("2026-10-10")!))
        // Mon 5 Oct + 5 working days: Tue6 Wed7 Thu8 Fri9 Sat10(extra) -> 5th is Sat 10 Oct
        #expect(toISO(cal.shift(parseISO("2026-10-05")!, 5)) == "2026-10-10")
        // next working day after Sat 10 is Tue 13 (Mon 12 is a holiday)
        #expect(toISO(cal.shift(parseISO("2026-10-10")!, 1)) == "2026-10-13")
    }

    @Test func matchesBruteForceOnRandomCalendars() {
        var seed = 12345
        func rnd() -> Double { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return Double(seed) / Double(0x7fffffff) }
        for trial in 0..<40 {
            var week = (0..<7).map { _ in rnd() < 0.6 }
            if !week.contains(true) { week[1] = true }
            var exceptions: [CalException] = []
            let base = parseISO("2026-01-01")!
            for _ in 0..<25 {
                let s = base + Int(rnd() * 900)
                let e = s + Int(rnd() * 3)
                exceptions.append(CalException(from: toISO(s), to: toISO(e), working: rnd() < 0.25, name: ""))
            }
            let cal = Cal(CalendarDef(id: "x", name: "x", workWeek: week, exceptions: exceptions))
            if cal.invalid { continue }
            for _ in 0..<40 {
                let dn = base + Int(rnd() * 1000)
                #expect(cal.idx(dn) == naiveIdx(cal, dn), "idx mismatch trial \(trial)")
                let n = Int((rnd() * 60).rounded(.down)) - 20
                let start = cal.next(dn)
                var d = start, left = abs(n)
                while left > 0 { d += n > 0 ? 1 : -1; if cal.isWorking(d) { left -= 1 } }
                #expect(cal.shift(start, n) == d, "shift mismatch trial \(trial)")
                #expect(cal.isWorking(cal.nth(cal.idx(dn))))
            }
        }
    }

    @Test func noWorkingDaysFallsBackToMonFriAndIsFlagged() {
        let cal = Cal(CalendarDef(id: "x", name: "x", workWeek: [false, false, false, false, false, false, false]))
        #expect(cal.invalid)
        #expect(cal.isWorking(parseISO("2026-10-05")!))
    }

    @Test func everyDateFormatReadsBackForEveryDayOfALeapYear() {
        #expect(DATE_FORMATS.count >= 15)
        for f in DATE_FORMATS {
            for dn in parseISO("2028-01-01")!...parseISO("2028-12-31")! {
                let t = formatDate(dn, f)
                #expect(parseDateInput(t, f) == dn, "\(f): \(t)")
                #expect(parseDateInput("\(DOW_SHORT[dow(dn)]) \(t)", f) == dn, "\(f) with weekday: \(t)")
            }
        }
        #expect(formatDate(parseISO("2026-10-05")!, "MMMM DD, YYYY") == "October 05, 2026")
        #expect(formatDate(parseISO("2026-10-05")!, "M/D/YYYY") == "10/5/2026")
        #expect(formatDate(parseISO("2026-10-05")!, "unknown format") == "05-Oct-2026")
    }

    @Test func jsNumberFormattingMatchesJavaScript() {
        #expect(jsNumberString(5) == "5")
        #expect(jsNumberString(0.75) == "0.75")
        #expect(jsNumberString(-2.5) == "-2.5")
        #expect(jsNumberString(1e21) == "1e+21")
        #expect(jsNumberString(1e-7) == "1e-7")
        #expect(jsNumberString(123456789012345680000) == "123456789012345680000")
        #expect(jsNumberString(0.1 + 0.2) == "0.30000000000000004")
        #expect(jsRound(-2.5) == -2)
        #expect(jsRound(2.5) == 3)
        #expect(jsRound(0.49999999999999994) == 0)
        #expect(jsNumberFromString(" 12 ") == 12)
        #expect(jsNumberFromString("").isZero)
        #expect(jsNumberFromString("1.") == 1)
        #expect(jsNumberFromString("0x1A") == 26)
        #expect(jsNumberFromString("12px").isNaN)
        #expect(jsParseFloat("12px") == 12)
        #expect(jsParseFloat(".5%") == 0.5)
    }
}
