// Recurring calendar exceptions of MS Project files: each rule of MPXJ's test project
// junit/data/generated/calendar-recurring-exceptions/calendar-recurring-exceptions-project2016-mpp14.mpp (as MPXJ writes it to
// MS Project XML) must give exactly the number of dates MS Project stored, from its first date to the end date MS Project
// stored. The rule parameters below are copied from that file.

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct RecurrenceTests {
    // name, Type, FromDate, ToDate, EnteredByOccurrences, Occurrences, Period, DaysOfWeek, MonthItem, MonthPosition, Month, MonthDay
    static let rules: [(String, Int, String, String, Bool, Int, Int, Int, Int, Int, Int, Int)] = [
        ("Daily 2", 7, "2000-02-01", "2000-02-10", true, 4, 3, 0, 0, 0, 0, 1),
        ("Daily 3", 7, "2000-03-01", "2000-03-21", true, 5, 5, 0, 0, 0, 0, 1),
        ("Daily 4", 7, "2000-04-01", "2000-05-06", true, 6, 7, 0, 0, 0, 0, 1),
        ("Weekly 1 Monday", 6, "2001-01-01", "2001-01-15", true, 3, 1, 2, 0, 0, 0, 1),
        ("Weekly 2 Tuesday", 6, "2001-01-02", "2001-02-13", true, 4, 2, 4, 0, 0, 0, 1),
        ("Weekly 3 Wednesday", 6, "2001-01-03", "2001-03-28", true, 5, 3, 8, 0, 0, 0, 1),
        ("Weekly 4 Thursday", 6, "2001-01-04", "2001-05-24", true, 6, 4, 16, 0, 0, 0, 1),
        ("Weekly 5 Friday", 6, "2001-01-05", "2001-08-03", true, 7, 5, 32, 0, 0, 0, 1),
        ("Weekly 6 Saturday", 6, "2001-01-06", "2001-10-27", true, 8, 6, 64, 0, 0, 0, 1),
        ("Weekly 7 Sunday", 6, "2001-02-18", "2002-03-17", true, 9, 7, 1, 0, 0, 0, 1),
        ("Monthly Relative 6", 5, "2002-01-05", "2006-02-04", true, 8, 7, 0, 9, 0, 0, 1),
        ("Monthly Relative 1", 5, "2002-01-07", "2002-05-06", true, 3, 2, 0, 4, 0, 0, 1),
        ("Monthly Relative 2", 5, "2002-01-08", "2002-10-08", true, 4, 3, 0, 5, 1, 0, 1),
        ("Monthly Relative 7", 5, "2002-01-13", "2007-05-13", true, 9, 8, 0, 3, 1, 0, 1),
        ("Monthly Relative 3", 5, "2002-01-16", "2003-05-21", true, 5, 4, 0, 6, 2, 0, 1),
        ("Monthly Relative 4", 5, "2002-01-24", "2004-02-26", true, 6, 5, 0, 7, 3, 0, 1),
        ("Monthly Relative 5", 5, "2002-01-25", "2005-01-28", true, 7, 6, 0, 8, 4, 0, 1),
        ("Monthly Absolute 1", 4, "2003-01-01", "2003-05-01", true, 3, 2, 0, 0, 0, 0, 1),
        ("Monthly Absolute 2", 4, "2003-01-04", "2005-02-04", true, 6, 5, 0, 0, 0, 0, 4),
        ("Yearly Relative 1", 3, "2004-03-02", "2007-03-06", true, 4, 1, 0, 5, 0, 2, 1),
        ("Yearly Relative 2", 3, "2004-04-14", "2008-04-09", true, 5, 1, 0, 6, 1, 3, 1),
        ("Yearly Relative 3", 3, "2004-05-20", "2009-05-21", true, 6, 1, 0, 7, 2, 4, 1),
        ("Yearly Absolute 1", 2, "2005-02-01", "2007-02-01", true, 3, 1, 0, 0, 0, 1, 1),
        ("Yearly Absolute 2", 2, "2005-03-02", "2008-03-02", true, 4, 1, 0, 0, 0, 2, 2),
        ("Yearly Absolute 3", 2, "2005-04-03", "2009-04-03", true, 5, 1, 0, 0, 0, 3, 3),
        ("Recurring Working", 5, "2010-01-02", "2010-03-06", true, 3, 1, 0, 9, 0, 0, 1),
    ]

    @Test func everyRuleOfTheMSProjectFileGivesItsDates() {
        for (name, type, from, to, byOcc, occ, period, dows, item, pos, month, mday) in Self.rules {
            let r = RecurringException(type: type, fromDn: parseISO(from)!, toDn: parseISO(to)!, occurrences: byOcc ? occ : nil, period: period,
                                       daysOfWeek: dows, monthItem: item, monthPosition: pos, month: month, monthDay: mday)
            let dates = expandRecurringException(r)
            #expect(dates.count == occ, "\(name): \(dates.map(toISO))")
            #expect(dates.first.map(toISO) == from, "\(name): first \(dates.first.map(toISO) ?? "-")")
            #expect(dates.last.map(toISO) == to, "\(name): last \(dates.last.map(toISO) ?? "-")")
            #expect(dates == dates.sorted() && Set(dates).count == dates.count, "\(name)")
        }
    }

    @Test func spotChecks() {
        // every 2nd week on Tuesday: 2, 16, 30 January, 13 February 2001
        let w = RecurringException(type: 6, fromDn: parseISO("2001-01-02")!, toDn: parseISO("2001-02-13")!, occurrences: 4, period: 2, daysOfWeek: 4)
        #expect(expandRecurringException(w).map(toISO) == ["2001-01-02", "2001-01-16", "2001-01-30", "2001-02-13"])
        // the last Friday of every 6th month from January 2002
        let m = RecurringException(type: 5, fromDn: parseISO("2002-01-25")!, toDn: parseISO("2003-07-31")!, period: 6, monthItem: 8, monthPosition: 4)
        #expect(expandRecurringException(m).map(toISO) == ["2002-01-25", "2002-07-26", "2003-01-31", "2003-07-25"])
        // day 31 of every month falls on the last day of shorter months
        let d = RecurringException(type: 4, fromDn: parseISO("2027-01-31")!, toDn: parseISO("2027-04-30")!, monthDay: 31)
        #expect(expandRecurringException(d).map(toISO) == ["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30"])
        // Christmas every year, until an end date (not by a count)
        let y = RecurringException(type: 2, fromDn: parseISO("2026-12-25")!, toDn: parseISO("2029-12-31")!, month: 11, monthDay: 25)
        #expect(expandRecurringException(y).map(toISO) == ["2026-12-25", "2027-12-25", "2028-12-25", "2029-12-25"])
        // the first weekday of each month
        let fw = RecurringException(type: 5, fromDn: parseISO("2026-08-01")!, toDn: parseISO("2026-11-30")!, monthItem: 1, monthPosition: 0)
        #expect(expandRecurringException(fw).map(toISO) == ["2026-08-03", "2026-09-01", "2026-10-01", "2026-11-02"])
        // a limit stops an endless rule
        let every = RecurringException(type: 7, fromDn: 0, toDn: 100_000)
        #expect(expandRecurringException(every, limit: 50).count == 50)
    }

    static func xml(_ exceptions: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Project xmlns="http://schemas.microsoft.com/project">
          <Name>Recurring</Name><StartDate>2026-01-05T08:00:00</StartDate><CalendarUID>1</CalendarUID><WeekStartDay>1</WeekStartDay>
          <MinutesPerDay>480</MinutesPerDay><MinutesPerWeek>2400</MinutesPerWeek>
          <Calendars><Calendar><UID>1</UID><Name>Standard</Name><IsBaseCalendar>1</IsBaseCalendar><BaseCalendarUID>-1</BaseCalendarUID>
            <WeekDays>
              <WeekDay><DayType>1</DayType><DayWorking>0</DayWorking></WeekDay>
              <WeekDay><DayType>2</DayType><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes></WeekDay>
              <WeekDay><DayType>3</DayType><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes></WeekDay>
              <WeekDay><DayType>4</DayType><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes></WeekDay>
              <WeekDay><DayType>5</DayType><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes></WeekDay>
              <WeekDay><DayType>6</DayType><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime><WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime></WorkingTimes></WeekDay>
              <WeekDay><DayType>7</DayType><DayWorking>0</DayWorking></WeekDay>
            </WeekDays>
            <Exceptions>\(exceptions)</Exceptions>
          </Calendar></Calendars>
          <Tasks>
            <Task><UID>0</UID><ID>0</ID><Name>Recurring</Name><OutlineLevel>0</OutlineLevel><Summary>1</Summary></Task>
            <Task><UID>1</UID><ID>1</ID><Name>Work</Name><OutlineLevel>1</OutlineLevel><Start>2026-01-05T08:00:00</Start><Finish>2026-02-27T17:00:00</Finish><Duration>PT320H0M0S</Duration><DurationFormat>7</DurationFormat></Task>
          </Tasks>
        </Project>
        """
    }

    @Test func importTurnsRecurringExceptionsIntoDates() throws {
        // every Monday for 3 weeks (by count), the 2nd Friday of each month until an end date, and a plain 2-day range
        let r = try importMSPDI(Self.xml("""
            <Exception><EnteredByOccurrences>1</EnteredByOccurrences><TimePeriod><FromDate>2026-01-12T00:00:00</FromDate><ToDate>2026-01-26T23:59:59</ToDate></TimePeriod><Occurrences>3</Occurrences><Name>Monday stand-down</Name><Type>6</Type><Period>1</Period><DaysOfWeek>2</DaysOfWeek><DayWorking>0</DayWorking></Exception>
            <Exception><EnteredByOccurrences>0</EnteredByOccurrences><TimePeriod><FromDate>2026-01-09T00:00:00</FromDate><ToDate>2026-03-31T23:59:59</ToDate></TimePeriod><Occurrences>1</Occurrences><Name>Maintenance Friday</Name><Type>5</Type><Period>1</Period><MonthItem>8</MonthItem><MonthPosition>1</MonthPosition><DayWorking>0</DayWorking></Exception>
            <Exception><EnteredByOccurrences>0</EnteredByOccurrences><TimePeriod><FromDate>2026-02-16T00:00:00</FromDate><ToDate>2026-02-17T23:59:59</ToDate></TimePeriod><Occurrences>1</Occurrences><Name>Chinese New Year</Name><Type>1</Type><DayWorking>0</DayWorking></Exception>
            """))
        let cal = try #require(r.project.calendars.first)
        let ex = cal.exceptions.map { "\($0.name) \($0.from)...\($0.to ?? $0.from)" }
        #expect(ex.contains("Monday stand-down 2026-01-12...2026-01-12"))
        #expect(ex.contains("Monday stand-down 2026-01-19...2026-01-19"))
        #expect(ex.contains("Monday stand-down 2026-01-26...2026-01-26"))
        #expect(ex.filter { $0.hasPrefix("Monday stand-down") }.count == 3)
        // the 2nd Friday: 9 January, 13 February, 13 March; not one block from January to March
        #expect(ex.filter { $0.hasPrefix("Maintenance Friday") } == ["Maintenance Friday 2026-01-09...2026-01-09", "Maintenance Friday 2026-02-13...2026-02-13",
                                                                    "Maintenance Friday 2026-03-13...2026-03-13"])
        #expect(ex.contains("Chinese New Year 2026-02-16...2026-02-17"))
        #expect(cal.exceptions.allSatisfy { !$0.working })
        let notes = r.report.notes.map { $0.text }
        #expect(notes.contains { $0.contains("2 recurring exceptions (Monday stand-down, Maintenance Friday) imported as 6 dated exceptions") }, "\(notes)")
        #expect(!notes.contains { $0.contains("not imported") })
    }

    @Test func recurringWorkingDaysKeepTheirHours() throws {
        let r = try importMSPDI(Self.xml("""
            <Exception><EnteredByOccurrences>1</EnteredByOccurrences><TimePeriod><FromDate>2026-01-03T00:00:00</FromDate><ToDate>2026-03-07T23:59:59</ToDate></TimePeriod><Occurrences>3</Occurrences><Name>Saturday shift</Name><Type>5</Type><Period>1</Period><MonthItem>9</MonthItem><MonthPosition>0</MonthPosition><DayWorking>1</DayWorking><WorkingTimes><WorkingTime><FromTime>09:00:00</FromTime><ToTime>13:00:00</ToTime></WorkingTime></WorkingTimes></Exception>
            """))
        let ex = try #require(r.project.calendars.first).exceptions
        #expect(ex.map { $0.from } == ["2026-01-03", "2026-02-07", "2026-03-07"])
        #expect(ex.allSatisfy { $0.working && $0.periods == [[540, 780]] })
    }
}
