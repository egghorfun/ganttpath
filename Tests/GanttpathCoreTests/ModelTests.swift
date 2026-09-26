// Ported from test/model.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

func fresh() -> Session { Session(newProject(name: "T", startDate: "2026-10-05")) }
func names(_ s: Session) -> [String] { s.project.tasks.map { $0.name } }
func wbsOf(_ s: Session) -> [String] { s.sched.tasks.map { $0.wbs } }
@discardableResult
func add(_ s: Session, _ name: String, _ level: Int, days: Double? = nil, configure: @escaping (inout Task) -> Void = { _ in }) -> Int {
    let r = s.run("Add") { p, _ in insertTask(&p, p.tasks.count, level: level, name: name, durationDays: days, configure: configure).uid }
    #expect(r.ok, "\(r.error ?? "")")
    return r.value!
}
func obj(_ pairs: (String, JSON)...) -> JSONObject { JSONObject(pairs) }

@Suite struct ModelTests {
    @Test func insertIndentOutdentKeepWBSNumbersRight() {
        let s = fresh()
        let a = add(s, "A", 1), b = add(s, "B", 1), c = add(s, "C", 1); add(s, "D", 1)
        #expect(wbsOf(s) == ["1", "2", "3", "4"])
        s.run("Indent") { p, _ in indentTasks(&p, [b]) }
        #expect(wbsOf(s) == ["1", "1.1", "2", "3"])
        #expect(s.sched.tasks[0].isSummary)
        s.run("Indent") { p, _ in indentTasks(&p, [c]) }   // C becomes sibling of B (level 2)
        #expect(wbsOf(s) == ["1", "1.1", "1.2", "2"])
        s.run("Indent") { p, _ in indentTasks(&p, [c]) }   // C under B
        #expect(wbsOf(s) == ["1", "1.1", "1.1.1", "2"])
        s.run("Indent") { p, _ in indentTasks(&p, [a]) }   // first row cannot be indented
        #expect(wbsOf(s) == ["1", "1.1", "1.1.1", "2"])
        s.run("Outdent") { p, _ in outdentTasks(&p, [c]) }
        #expect(wbsOf(s) == ["1", "1.1", "1.2", "2"])
        // outdent B: the sibling below (C) becomes B's child, as in MS Project
        s.run("Outdent") { p, _ in outdentTasks(&p, [b]) }
        #expect(wbsOf(s) == ["1", "2", "2.1", "3"])
    }

    @Test func indentOutdentMoveTheWholeSubtreeDeleteRemovesDescendantsAndLinks() {
        let s = fresh()
        add(s, "A", 1); let b = add(s, "B", 2), c = add(s, "C", 3), d = add(s, "D", 1)
        s.run("Link") { p, _ in try addLink(&p, c, d) }
        s.run("Outdent") { p, _ in outdentTasks(&p, [b]) }
        #expect(s.project.tasks.map { $0.level } == [1, 1, 2, 1])
        s.run("Indent") { p, _ in indentTasks(&p, [b]) }
        #expect(s.project.tasks.map { $0.level } == [1, 2, 3, 1])
        s.run("Delete") { p, _ in deleteTasks(&p, [b]) }
        #expect(names(s) == ["A", "D"])
        #expect(s.project.tasks[1].preds.isEmpty)
    }

    @Test func moveTasksReordersAndReparentsBlocks() {
        let s = fresh()
        let a = add(s, "A", 1), b = add(s, "B", 2), c = add(s, "C", 1), d = add(s, "D", 1)
        s.run("Move") { p, _ in try moveTasks(&p, [d], beforeUid: a, level: 1) }
        #expect(names(s) == ["D", "A", "B", "C"])
        s.run("Move") { p, _ in try moveTasks(&p, [c], beforeUid: b, level: 2) }
        #expect(names(s) == ["D", "A", "C", "B"])
        #expect(wbsOf(s) == ["1", "2", "2.1", "2.2"])
        s.run("Move") { p, _ in try moveTasks(&p, [a], beforeUid: nil, level: 1) }
        #expect(names(s) == ["D", "A", "C", "B"])
        let first = s.project.tasks[0].uid
        s.run("Move") { p, _ in try moveTasks(&p, [a], beforeUid: first, level: 1) }
        #expect(names(s) == ["A", "C", "B", "D"])
        #expect(s.project.tasks.map { $0.level } == [1, 2, 2, 1])
        let second = s.project.tasks[1].uid
        let r = s.run("Bad") { p, _ in try moveTasks(&p, [a], beforeUid: second, level: 2) }
        #expect(!r.ok)
    }

    @Test func linksAreRefusedWithAMessage() {
        let s = fresh()
        let a = add(s, "A", 1), b = add(s, "B", 2), c = add(s, "C", 1), d = add(s, "D", 1)
        #expect(!s.run("L") { p, _ in try addLink(&p, a, a) }.ok)
        #expect(s.run("L") { p, _ in try addLink(&p, a, b) }.error!.lowercased().contains("summary"))
        #expect(s.run("L") { p, _ in try addLink(&p, b, a) }.error!.lowercased().contains("summary"))
        #expect(s.run("L") { p, _ in try addLink(&p, c, d) }.ok)
        let r = s.run("L") { p, _ in try addLink(&p, d, c) }
        #expect(!r.ok)
        #expect(r.error!.contains("circular"))
        #expect(s.project.tasks[3].preds.count == 1)
        let e = add(s, "E", 1)
        #expect(s.run("L") { p, _ in try addLink(&p, d, e) }.ok)
        #expect(!s.run("L") { p, _ in try addLink(&p, e, c) }.ok)
        s.run("L") { p, _ in try addLink(&p, c, d, "SS", Lag(v: 2, u: "d")) }
        #expect(s.project.tasks[3].preds == [Pred(uid: c, type: "SS", lag: Lag(v: 2, u: "d"))])
        // indenting a task under its own predecessor summary drops the now-illegal link and reports it
        let s2 = fresh()
        let x = add(s2, "X", 1), y = add(s2, "Y", 1)
        s2.run("L") { p, _ in try addLink(&p, x, y) }
        let res = s2.run("Indent") { p, _ in indentTasks(&p, [y]) }
        #expect(res.value?.removedLinks == 1)
        #expect(s2.project.tasks[1].preds.isEmpty)
    }

    @Test func typedDatesFollowMSProject() {
        let s = fresh()
        let a = add(s, "A", 1, days: 3)
        s.run("Start") { p, _ in try setStart(&p, a, "2026-10-14") }
        #expect(s.project.tasks[0].constraint == Constraint(type: "SNET", date: "2026-10-14"))
        #expect(s.sched.tasks[0].start == "2026-10-14")
        #expect(s.sched.tasks[0].finish == "2026-10-16")
        s.run("Finish") { p, _ in try setFinish(&p, a, "2026-10-20") }
        #expect(s.project.tasks[0].constraint == Constraint(type: "FNET", date: "2026-10-20"))
        #expect(s.sched.tasks[0].finish == "2026-10-20")
        let m = add(s, "M", 1, days: 3) { $0.mode = "manual"; $0.start = "2026-10-06"; $0.finish = "2026-10-08" }
        s.run("Start") { p, _ in try setStart(&p, m, "2026-10-12") }
        #expect([s.project.tasks[1].start, s.project.tasks[1].finish] == ["2026-10-12", "2026-10-14"])
        s.run("Finish") { p, _ in try setFinish(&p, m, "2026-10-20") }
        #expect(s.project.tasks[1].dur / 480 == 7)
        s.run("Dur") { p, _ in try setDurationDays(&p, m, 2) }
        #expect([s.project.tasks[1].start, s.project.tasks[1].finish] == ["2026-10-12", "2026-10-13"])
        #expect(!s.run("Bad") { p, _ in try setFinish(&p, m, "2026-10-01") }.ok)
    }

    @Test func manualDatesTypedOnADayOffMoveToAWorkingDay() {
        let s = fresh()
        let m = add(s, "M", 1, days: 3) { $0.mode = "manual"; $0.start = "2026-10-06"; $0.finish = "2026-10-08" }
        s.run("Start") { p, _ in try setStart(&p, m, "2026-10-10") } // Saturday -> Monday 12-Oct
        #expect([s.project.tasks[0].start, s.project.tasks[0].finish] == ["2026-10-12", "2026-10-14"])
        s.run("Finish") { p, _ in try setFinish(&p, m, "2026-10-17") } // Saturday -> Friday 16-Oct
        #expect(s.project.tasks[0].finish == "2026-10-16")
        #expect(s.project.tasks[0].dur / 480 == 5)
        #expect([s.sched.tasks[0].start, s.sched.tasks[0].finish] == ["2026-10-12", "2026-10-16"])
    }

    @Test func summaryTasksCannotBeEditedDirectly() {
        let s = fresh()
        let a = add(s, "A", 1); add(s, "B", 2)
        let sc = s.sched
        #expect(!s.run("x") { p, _ in try setDurationDays(&p, a, 3) }.ok)
        #expect(!s.run("x") { p, _ in try setStart(&p, a, "2026-10-06") }.ok)
        #expect(!s.run("x") { p, _ in try setPercent(&p, a, 50, sc) }.ok)
        #expect(!s.run("x") { p, _ in try setMilestone(&p, a, true) }.ok)
    }

    @Test func percentCompleteRecordsActualsLikeMSProject() {
        let s = fresh()
        let a = add(s, "A", 1, days: 5)
        add(s, "B", 1, days: 2) { $0.preds = [Pred(uid: 1)] }
        s.run("Pct") { p, sc in try setPercent(&p, a, 40, sc) }
        #expect(s.project.tasks[0].actualStart == "2026-10-05")
        #expect(s.project.tasks[0].actualFinish == nil)
        s.run("Pct") { p, sc in try setPercent(&p, a, 100, sc) }
        #expect(s.project.tasks[0].actualFinish == "2026-10-09")
        #expect(!s.sched.tasks[0].critical)
        #expect(s.sched.tasks[1].critical)
        s.run("Pct") { p, sc in try setPercent(&p, a, 0, sc) }
        #expect(s.project.tasks[0].actualStart == nil)
        #expect(!s.run("Bad") { p, sc in try setPercent(&p, a, 101, sc) }.ok)
    }

    @Test func monthShortcutFillsTheCalendarMonth() {
        let s = fresh()
        let a = add(s, "Oct", 1) { $0.mode = "manual"; $0.start = "2026-10-05"; $0.finish = "2026-10-05" }
        s.run("Month") { p, _ in try setMonthTask(&p, a, parseISO("2026-10-15")!) }
        #expect(s.project.tasks[0].start == "2026-10-01")
        #expect(s.project.tasks[0].finish == "2026-10-30")
        #expect(s.project.tasks[0].dur / 480 == 22)
        let b = add(s, "Nov", 1)
        s.run("Month") { p, _ in try setMonthTask(&p, b, parseISO("2026-11-10")!) }
        #expect(s.sched.tasks[1].start == "2026-11-02")
        #expect(s.sched.tasks[1].finish == "2026-11-30")
    }

    @Test func baselinesSixSlots() {
        let s = fresh()
        add(s, "A", 1, days: 4)
        s.run("BL") { p, sc in try setBaseline(&p, 0, sc) }
        s.run("BL5") { p, sc in try setBaseline(&p, 5, sc) }
        #expect(s.project.tasks[0].baselines[0] == Baseline(start: "2026-10-05", finish: "2026-10-08", duration: 4, dur: 1920))
        #expect(s.project.tasks[0].baselines.count == 6)
        s.run("Clear") { p, _ in try clearBaseline(&p, 0) }
        #expect(s.project.tasks[0].baselines[0] == nil)
        #expect(!s.run("Bad") { p, sc in try setBaseline(&p, 6, sc) }.ok)
    }

    @Test func undoRedo50StepsAndFailedEditsLeaveNoTrace() {
        let s = fresh()
        for i in 0..<60 { add(s, "T\(i)", 1) }
        #expect(s.project.tasks.count == 60)
        var n = 0
        while s.undo() { n += 1 }
        #expect(n == 50)
        #expect(s.project.tasks.count == 10)
        #expect(!s.history.canUndo)
        s.redo(); s.redo()
        #expect(s.project.tasks.count == 12)
        add(s, "X", 1)
        #expect(!s.history.canRedo)
        let before = s.json(); let depth = s.history.undoStack.count
        #expect(!s.run("Bad") { p, _ in try setDuration(&p, p.tasks[0].uid, DurationSpec(min: -1, unit: "d")) }.ok)
        #expect(s.json() == before)
        #expect(s.history.undoStack.count == depth)
        // an edit that changes nothing is not an undo step
        s.run("Same") { p, _ in try setName(&p, p.tasks[0].uid, p.tasks[0].name) }
        #expect(s.history.undoStack.count == depth)
    }

    @Test func dirtyFlagAndLoadReset() {
        let s = fresh()
        #expect(!s.dirty)
        add(s, "A", 1)
        #expect(s.dirty)
        s.markSaved()
        #expect(!s.dirty)
        s.undo()
        #expect(s.dirty)
    }

    @Test func calendarAndSettingsValidation() {
        let s = fresh()
        #expect(!s.run("c") { p, _ in try upsertCalendar(&p, CalendarDef(id: "x", name: "None", workWeek: [false, false, false, false, false, false, false])) }.ok)
        #expect(s.run("c") { p, _ in try upsertCalendar(&p, CalendarDef(id: "six", name: "Mon-Sat", workWeek: [false, true, true, true, true, true, true])) }.ok)
        #expect(!s.run("c") { p, _ in try removeCalendar(&p, "std") }.ok)
        let t = add(s, "A", 1, days: 6)
        s.run("c") { p, _ in try setTaskCalendar(&p, t, "six") }
        #expect(s.sched.tasks[0].finish == "2026-10-10")
        s.run("c") { p, _ in try removeCalendar(&p, "six") }
        #expect(s.project.tasks[0].calendarId == nil)
        #expect(!s.run("c") { p, _ in try updateSettings(&p, obj(("criticalSlackDays", JSON(-1)))) }.ok)
        #expect(s.run("c") { p, _ in try updateSettings(&p, obj(("criticalSlackDays", JSON(3)))) }.ok)
        #expect(s.project.settings.daysPerMonth == 20)
        for bad in [0.0, -5, 32] { #expect(!s.run("c") { p, _ in try updateSettings(&p, obj(("daysPerMonth", JSON(bad)))) }.ok) }
        #expect(s.run("c") { p, _ in try updateSettings(&p, obj(("daysPerMonth", JSON(22)))) }.ok)
        #expect(s.project.settings.daysPerMonth == 22)
    }

    @Test func documentNumberLogoAndHeaderFooterEditor() throws {
        let s = fresh()
        let hf0 = s.project.settings.headerFooter
        #expect(s.project.settings.documentNumber == "")
        #expect(s.project.settings.logoDataUrl == nil)
        #expect(hf0.header.left.lines[0].field == "title")
        #expect(hf0.header.right.lines[0].field == "logo")
        #expect(hf0.footer.left.lines[0].field == "legend")
        #expect(hf0.footer.center.lines.map { $0.field } == ["range", "status", "printed"])
        #expect(hf0.footer.right.lines[0].field == "page")

        #expect(s.run("d") { p, _ in try updateSettings(&p, obj(("documentNumber", .string("F10E-CWR-DAT-001")))) }.ok)
        #expect(s.project.settings.documentNumber == "F10E-CWR-DAT-001")
        #expect(s.run("d") { p, _ in try updateSettings(&p, obj(("documentNumber", .string(String(repeating: "x", count: 500))))) }.ok)
        #expect(s.project.settings.documentNumber.count == 200)
        s.undo(); s.undo()
        #expect(s.project.settings.documentNumber == "")

        #expect(!s.run("l") { p, _ in try updateSettings(&p, obj(("logoDataUrl", .string("not-an-image")))) }.ok)
        #expect(s.run("l") { p, _ in try updateSettings(&p, obj(("logoDataUrl", .string("data:image/png;base64,iVBORw0KGgo=")))) }.ok)
        #expect(s.project.settings.logoDataUrl == "data:image/png;base64,iVBORw0KGgo=")
        #expect(s.run("l") { p, _ in try updateSettings(&p, obj(("logoDataUrl", .null))) }.ok)
        #expect(s.project.settings.logoDataUrl == nil)

        let bad = try JSONParser.parse(#"{"header":{"left":{"lines":[{"field":"docnum","text":""},{"field":"bogus","text":""}],"font":"georgia","size":99,"color":"red"}},"footer":{}}"#)
        #expect(s.run("hf") { p, _ in try updateSettings(&p, obj(("headerFooter", bad))) }.ok)
        let hf1 = s.project.settings.headerFooter
        #expect(hf1.header.left.lines.count == 3)
        #expect(hf1.header.left.lines[0].field == "docnum")
        #expect(hf1.header.left.lines[1].field == "none")
        #expect(hf1.header.left.font == "georgia")
        #expect(hf1.header.left.size == 10)
        #expect(hf1.header.left.color == "#475569")
        #expect(hf1.header.center.lines[0].field == "none")
        #expect(hf1.footer.left.lines[0].field == "none")
        s.undo()
        #expect(s.project.settings.headerFooter.header.left.lines[0].field == "title")

        let long = try JSONParser.parse(#"{"header":{"left":{"lines":[{"field":"text","text":"\#(String(repeating: "x", count: 500))"}]}}}"#)
        #expect(s.run("hf2") { p, _ in try updateSettings(&p, obj(("headerFooter", long))) }.ok)
        #expect(s.project.settings.headerFooter.header.left.lines[0].text.count == 200)

        for f in ["hoursday", "hoursweek", "daysmonth"] { #expect(HF_FIELDS.contains(f) && HF_FIELD_LABELS[f] != nil) }
        let three = try JSONParser.parse(#"{"footer":{"left":{"lines":[{"field":"hoursday"},{"field":"hoursweek"},{"field":"daysmonth"}]}}}"#)
        #expect(s.run("hf3") { p, _ in try updateSettings(&p, obj(("headerFooter", three))) }.ok)
        #expect(s.project.settings.headerFooter.footer.left.lines.map { $0.field } == ["hoursday", "hoursweek", "daysmonth"])

        let old = try Project.from(json: try JSONParser.parse(#"{"tasks":[],"settings":{"startDate":"2026-10-05"}}"#))
        #expect(old.settings.headerFooter.footer.right.lines[0].field == "page")
        #expect(old.settings.documentNumber == "")
        #expect(old.settings.logoDataUrl == nil)
    }

    @Test func tagsAndCustomColumns() {
        let s = fresh()
        let a = add(s, "A", 1)
        s.run("t") { p, _ in try addTag(&p, "Long lead", "#D97706") }
        #expect(!s.run("t") { p, _ in try addTag(&p, "long lead") }.ok)
        s.run("t") { p, _ in try setTaskTags(&p, [a], on: ["Long lead"]) }
        #expect(s.project.tasks[0].tags == ["Long lead"])
        let cid = s.run("c") { p, _ in try addCustomColumn(&p, name: "Vendor", type: "text") }.value!
        s.run("c") { p, _ in try setCustomValue(&p, a, cid, .string("ACME")) }
        #expect(s.project.tasks[0].custom[cid] == .string("ACME"))
        s.run("t") { p, _ in removeTag(&p, "Long lead") }
        #expect(s.project.tasks[0].tags.isEmpty)
        s.run("c") { p, _ in removeCustomColumn(&p, cid) }
        #expect(!s.project.tasks[0].custom.has(cid))
    }

    @Test func normalizeProjectRepairsDamagedFiles() throws {
        let p = try Project.from(json: try JSONParser.parse(#"{"tasks":[{"uid":1,"level":5,"name":"a","preds":[{"uid":99,"type":"FS"},{"uid":1,"type":"FS"}]},{"uid":1,"level":0}]}"#))
        #expect(p.tasks[0].level == 1)
        #expect(p.tasks[0].preds.isEmpty)
        #expect(p.tasks[0].uid != p.tasks[1].uid)
        #expect(p.tasks[1].level == 1)
    }

    @Test func undoAndRedoKeepExpandedAndCollapsedSummaries() {
        let s = Session(newProject(name: "t", startDate: "2026-10-05"))
        let ph = s.run("a") { p, _ in insertTask(&p, 0, level: 1, name: "Phase").uid }.value!
        s.run("b") { p, _ in insertTask(&p, 1, level: 2, name: "Child", durationDays: 2) }
        s.run("edit") { p, _ in try setName(&p, p.tasks[1].uid, "Child 2") }
        s.setCollapsed(ph, true) // the window changes this directly: it is not an undo step
        s.undo()
        #expect(s.project.tasks[1].name == "Child")
        #expect(s.project.tasks[0].collapsed, "still collapsed after undo")
        s.redo()
        #expect(s.project.tasks[1].name == "Child 2")
        #expect(s.project.tasks[0].collapsed, "still collapsed after redo")
    }
}
