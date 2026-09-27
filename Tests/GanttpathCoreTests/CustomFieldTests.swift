// MS Project custom fields (Text, Number, Flag, Date, Cost, Duration ...) are imported as Ganttpath custom columns.

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct CustomFieldTests {
    static func xml(defs: String, task1: String, task2: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Project xmlns="http://schemas.microsoft.com/project">
          <Name>Fields</Name><StartDate>2026-01-05T08:00:00</StartDate><CalendarUID>1</CalendarUID>
          <MinutesPerDay>480</MinutesPerDay><MinutesPerWeek>2400</MinutesPerWeek>
          <ExtendedAttributes>\(defs)</ExtendedAttributes>
          <Calendars><Calendar><UID>1</UID><Name>Standard</Name><IsBaseCalendar>1</IsBaseCalendar><BaseCalendarUID>-1</BaseCalendarUID>
            <WeekDays><WeekDay><DayType>1</DayType><DayWorking>0</DayWorking></WeekDay><WeekDay><DayType>7</DayType><DayWorking>0</DayWorking></WeekDay></WeekDays>
          </Calendar></Calendars>
          <Tasks>
            <Task><UID>0</UID><ID>0</ID><Name>Fields</Name><OutlineLevel>0</OutlineLevel><Summary>1</Summary></Task>
            <Task><UID>1</UID><ID>1</ID><Name>A</Name><OutlineLevel>1</OutlineLevel><Start>2026-01-05T08:00:00</Start><Finish>2026-01-06T17:00:00</Finish><Duration>PT16H0M0S</Duration><DurationFormat>7</DurationFormat>\(task1)</Task>
            <Task><UID>2</UID><ID>2</ID><Name>B</Name><OutlineLevel>1</OutlineLevel><Start>2026-01-05T08:00:00</Start><Finish>2026-01-05T17:00:00</Finish><Duration>PT8H0M0S</Duration><DurationFormat>7</DurationFormat>\(task2)</Task>
          </Tasks>
        </Project>
        """
    }
    static func ea(_ id: Int, _ v: String, _ extra: String = "") -> String { "<ExtendedAttribute><FieldID>\(id)</FieldID><Value>\(v)</Value>\(extra)</ExtendedAttribute>" }
    static func def(_ id: Int, _ name: String, alias: String? = nil) -> String {
        "<ExtendedAttribute><FieldID>\(id)</FieldID><FieldName>\(name)</FieldName>\(alias.map { "<Alias>\($0)</Alias>" } ?? "")</ExtendedAttribute>"
    }

    @Test func fieldsBecomeTypedColumns() throws {
        let defs = Self.def(188743731, "Text1", alias: "Contractor") + Self.def(188743767, "Number1") + Self.def(188743752, "Flag1", alias: "Long lead")
            + Self.def(188743945, "Date1") + Self.def(188743786, "Cost1") + Self.def(188743783, "Duration1") + Self.def(188743734, "Text2")
        let r = try importMSPDI(Self.xml(
            defs: defs,
            task1: Self.ea(188743731, "ACME Pte Ltd") + Self.ea(188743767, "12.5") + Self.ea(188743752, "1") + Self.ea(188743945, "2026-03-02T00:00:00")
                + Self.ea(188743786, "1500") + Self.ea(188743783, "PT12H0M0S", "<DurationFormat>7</DurationFormat>"),
            task2: Self.ea(188743731, "Other & Co") + Self.ea(188743752, "0") + Self.ea(188743945, "2026-04-01T09:30:00")))
        let cols = r.project.customColumns
        #expect(cols.map { $0.name } == ["Contractor", "Number1", "Long lead", "Date1", "Cost1", "Duration1"])
        #expect(cols.map { $0.type } == ["text", "number", "flag", "date", "number", "text"])
        let a = r.project.tasks[0].custom, b = r.project.tasks[1].custom
        #expect(a["ms188743731"] == .string("ACME Pte Ltd"))
        #expect(a["ms188743767"] == .number(12.5))
        #expect(a["ms188743752"] == .bool(true))
        #expect(a["ms188743945"] == .string("2026-03-02"))
        #expect(a["ms188743786"] == .number(1500))
        #expect(a["ms188743783"] == .string("1.5d"))
        #expect(b["ms188743731"] == .string("Other & Co"))
        #expect(b["ms188743752"] == nil) // a flag that is off is simply empty
        #expect(b["ms188743945"] == .string("2026-04-01"))
        let notes = r.report.notes.map { $0.text }
        #expect(notes.contains("6 custom fields imported as custom columns (Contractor, Number1, Long lead, Date1, Cost1, Duration1). Show them with Columns in the toolbar."), "\(notes)")
        #expect(notes.contains { $0.contains("time of day was left out (1 value(s))") })
        #expect(notes.contains("1 custom field definition with no values on any task was left out."))
        #expect(!notes.contains { $0.contains("not imported") })
        // the columns work like ones made in Ganttpath: they can be shown in the table
        let all = allColumns(r.project, nil).map { $0.title }
        #expect(all.contains("Contractor") && all.contains("Long lead"))
    }

    @Test func noFieldsNoColumns() throws {
        let r = try importMSPDI(Self.xml(defs: "", task1: "", task2: ""))
        #expect(r.project.customColumns.isEmpty)
        #expect(!r.report.notes.contains { $0.text.contains("custom") })
    }

    /// MS Project XML written by MPXJ from its own test .mpp files (junit/data/generated/...), when GP_MPXJ_XML points at a folder of them.
    @Test func mpxjSamples() throws {
        guard let dir = ProcessInfo.processInfo.environment["GP_MPXJ_XML"] else { return }
        func load(_ name: String) throws -> ImportResult { try importMSPDI(String(contentsOfFile: dir + "/" + name, encoding: .utf8)) }
        let text = try load("task-text-project2019-mpp14.xml")
        #expect(text.project.customColumns.count == 30 && text.project.customColumns.allSatisfy { $0.type == "text" })
        #expect(text.project.customColumns.first?.name == "Text1")
        let t1 = try #require(text.project.tasks.first { $0.name == "Text1" })
        #expect(t1.custom["ms188743731"] == .string("1"))
        let nums = try load("task-numbers-project2019-mpp14.xml")
        #expect(nums.project.customColumns.count == 20 && nums.project.customColumns.allSatisfy { $0.type == "number" })
        let flags = try load("task-flags-project2019-mpp14.xml")
        #expect(flags.project.customColumns.filter { $0.type == "flag" }.count >= 20, "\(flags.project.customColumns.map { $0.name })")
        let dates = try load("task-dates-project2019-mpp14.xml")
        #expect(dates.project.customColumns.count == 10 && dates.project.customColumns.allSatisfy { $0.type == "date" })
        #expect(dates.project.tasks.first { $0.name == "Date1" }?.custom["ms188743945"] == .string("2014-01-01"))
        let durs = try load("task-durations-project2019-mpp14.xml")
        #expect(durs.project.tasks.first { $0.name == "Duration1" }?.custom["ms188743783"] == .string("1d"))
        let rec = try load("calendar-recurring-exceptions-project2016-mpp14.xml")
        let std = try #require(rec.project.calendars.first { $0.name == "Standard" })
        // Daily 1 (a 3-day range) plus the dates of the 26 recurring rules, as counted by MS Project; two rules share 1 March 2003,
        // and MPXJ's own list of dated exceptions holds exactly these dates, so each day is there once and has its rule's name
        let occurrences = RecurrenceTests.rules.reduce(0) { $0 + $1.5 }
        #expect(std.exceptions.count == 1 + occurrences - 1, "\(std.exceptions.count)")
        #expect(std.exceptions.allSatisfy { !$0.name.isEmpty })
        #expect(std.exceptions.filter { $0.working }.map { $0.from } == ["2010-01-02", "2010-02-06", "2010-03-06"])
        #expect(rec.report.notes.contains { $0.text.contains("26 recurring exceptions") })
    }
}
