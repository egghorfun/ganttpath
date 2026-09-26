// Ported from test/wbs-edit.test.js and test/taskinfo.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

private func mkw(_ spec: [(String, Int)]) -> Project {
    var p = newProject(name: "t", startDate: "2026-10-05")
    for (n, l) in spec { insertTask(&p, p.tasks.count, level: l, name: n) }
    return p
}
private func view(_ p: Project) -> String { zip(computeWBS(p.tasks), p.tasks).map { "\($0.0) \($0.1.name)" }.joined(separator: ", ") }
private func u(_ p: Project, _ n: String) -> Int { p.tasks.first { $0.name == n }!.uid }
// 1 A, 1.1 B, 1.2 C, 2 D, 2.1 E, 3 F, 4 G
private func base() -> Project { mkw([("A", 1), ("B", 2), ("C", 2), ("D", 1), ("E", 2), ("F", 1), ("G", 1)]) }

@Suite struct WbsEditTests {
    @Test func aLeafGetsANewLevel() throws {
        var p = base()
        let r = try setWbs(&p, u(p, "G"), "2.1.1")
        #expect(r.wbs == "2.1.1")
        #expect(view(p) == "1 A, 1.1 B, 1.2 C, 2 D, 2.1 E, 2.1.1 G, 3 F")
        #expect(schedule(p).tasks[p.tasks.firstIndex { $0.name == "E" }!].isSummary)
    }

    @Test func thePlaceAmongTheSubTasks() throws {
        var p = base(); _ = try setWbs(&p, u(p, "F"), "1.1"); #expect(view(p) == "1 A, 1.1 F, 1.2 B, 1.3 C, 2 D, 2.1 E, 3 G")
        p = base(); _ = try setWbs(&p, u(p, "F"), "1.2"); #expect(view(p) == "1 A, 1.1 B, 1.2 F, 1.3 C, 2 D, 2.1 E, 3 G")
        p = base(); _ = try setWbs(&p, u(p, "F"), "1.3"); #expect(view(p) == "1 A, 1.1 B, 1.2 C, 1.3 F, 2 D, 2.1 E, 3 G")
    }

    @Test func subTasksGoWithTheTask() throws {
        var p = base(); let r = try setWbs(&p, u(p, "D"), "1.1.1")
        #expect(r.moved == 2); #expect(view(p) == "1 A, 1.1 B, 1.1.1 D, 1.1.1.1 E, 1.2 C, 2 F, 3 G")
        p = base(); _ = try setWbs(&p, u(p, "B"), "4"); #expect(view(p) == "1 A, 1.1 C, 2 D, 2.1 E, 3 F, 4 B, 5 G")
        p = base(); _ = try setWbs(&p, u(p, "B"), "1"); #expect(view(p) == "1 B, 2 A, 2.1 C, 3 D, 3.1 E, 4 F, 5 G")
    }

    @Test func reorderingInsideTheSameParent() throws {
        var p = base(); _ = try setWbs(&p, u(p, "C"), "1.1"); #expect(view(p) == "1 A, 1.1 C, 1.2 B, 2 D, 2.1 E, 3 F, 4 G")
        p = base(); let before = view(p); let r = try setWbs(&p, u(p, "F"), "3"); #expect(r.same); #expect(view(p) == before)
    }

    @Test func theParentIsTheTaskShowingTheTypedNumberNow() throws {
        var p = base()
        let r = try setWbs(&p, u(p, "A"), "3.1")
        #expect(view(p) == "1 D, 1.1 E, 2 F, 2.1 A, 2.1.1 B, 2.1.2 C, 3 G")
        #expect(r.wbs == "2.1"); #expect(r.moved == 3)
    }

    @Test func numbersThatCannotBeUsedAreRefused() {
        var p = base(); let before = view(p)
        func bad(_ code: String, _ text: String) {
            do { _ = try setWbs(&p, u(p, "F"), code); Issue.record("\(code) should fail") } catch let e as ModelError { #expect(e.message.contains(text), "\(code): \(e.message)") } catch {}
            #expect(view(p) == before)
        }
        bad("banana", "numbers separated by dots")
        bad("1.", "numbers separated by dots")
        bad("", "numbers separated by dots")
        bad("1..2", "numbers separated by dots")
        bad("1.0", "start at 1")
        bad("9.1", "There is no task 9")
        bad("1.5", "1 has 2 sub-tasks, so the next free number is 1.3")
        bad("7", "top level has 3 tasks, so the next free number is 4")
        #expect(throws: ModelError.self) { try setWbs(&p, u(p, "A"), "1.1") }
        #expect(throws: ModelError.self) { try setWbs(&p, u(p, "A"), "1.2.1") }
    }

    @Test func linksAreKept() throws {
        var p = base()
        try addLink(&p, u(p, "B"), u(p, "F"))
        _ = try setWbs(&p, u(p, "F"), "1.3")
        #expect(p.tasks.first { $0.name == "F" }!.preds.map { $0.uid } == [u(p, "B")])
        var q = base(); try addLink(&q, u(q, "A"), u(q, "F"))
        let r = try setWbs(&q, u(q, "F"), "1.1")
        #expect(r.removedLinks == 1)
    }

    @Test func aCollapsedNewParentIsOpened() throws {
        var p = base()
        p.tasks[p.tasks.firstIndex { $0.name == "A" }!].collapsed = true
        _ = try setWbs(&p, u(p, "F"), "1.1")
        #expect(p.tasks.first { $0.name == "A" }!.collapsed == false)
    }
}

// A(5d) -> B(5d) -> C(5d), and a separate D(2d); Mon 5-Oct-2026, Mon-Fri, 8 h days
private func chain() throws -> Session {
    var p = newProject(name: "T", startDate: "2026-10-05")
    let a = insertTask(&p, 0, name: "A", durationDays: 5), b = insertTask(&p, 1, name: "B", durationDays: 5), c = insertTask(&p, 2, name: "C", durationDays: 5)
    insertTask(&p, 3, name: "D", durationDays: 2)
    try addLink(&p, a.uid, b.uid, "FS")
    try addLink(&p, b.uid, c.uid, "FS")
    return Session(p)
}
private func row(_ s: Session, _ n: String) -> ScheduledTask { s.sched.tasks[s.project.tasks.firstIndex { $0.name == n }!] }
private func uid(_ s: Session, _ n: String) -> Int { s.project.tasks.first { $0.name == n }!.uid }

@Suite struct TaskInfoTests {
    @Test func defaultsForNewTasksAndOldFiles() throws {
        var p = newProject(name: "x", startDate: "2026-10-05")
        let t = insertTask(&p, 0, name: "A")
        #expect(t.priority == 500)
        #expect(t.taskType == "fixedUnits")
        for k in TASK_FLAGS { #expect(t.flag(k) == false, "\(k)") }
        let old = try Project.from(json: try JSONParser.parse(#"{"settings":{"startDate":"2026-10-05"},"tasks":[{"uid":1,"name":"A","level":1}]}"#))
        #expect(old.tasks[0].priority == 500)
        #expect(old.tasks[0].taskType == "fixedUnits")
        #expect(!old.tasks[0].inactive)
        let rubbish = try Project.from(json: try JSONParser.parse(#"{"settings":{"startDate":"2026-10-05"},"tasks":[{"uid":1,"name":"A","level":1,"priority":5000,"taskType":"nonsense","hideBar":"yes"}]}"#))
        #expect(rubbish.tasks[0].priority == 1000)
        #expect(rubbish.tasks[0].taskType == "fixedUnits")
        #expect(rubbish.tasks[0].hideBar)
    }

    @Test func settersCheckTheirInput() throws {
        let s = try chain()
        let a = uid(s, "A")
        s.run("p") { p, _ in try setPriority(&p, a, "900") }
        #expect(s.project.tasks[0].priority == 900)
        for v in ["1001", "-1", "high", ""] { #expect(!s.run("p") { p, _ in try setPriority(&p, a, v) }.ok) }
        #expect(s.project.tasks[0].priority == 900)
        s.run("t") { p, _ in try setTaskType(&p, a, "fixedWork") }
        #expect(s.project.tasks[0].taskType == "fixedWork")
        #expect(!s.run("t") { p, _ in try setTaskType(&p, a, "fixedRubbish") }.ok)
        #expect(!s.run("f") { p, _ in try setTaskFlag(&p, a, "nonsense", true) }.ok)
        s.run("f") { p, _ in try setTaskFlag(&p, a, "hideBar", true) }
        #expect(s.project.tasks[0].hideBar)
        let before = s.sched.tasks.map { "\($0.start!)|\($0.finish!)" }
        s.run("p") { p, _ in try setPriority(&p, a, "100"); try setTaskType(&p, a, "fixedDuration") }
        #expect(s.sched.tasks.map { "\($0.start!)|\($0.finish!)" } == before)
    }

    @Test func anInactiveTaskKeepsItsDatesAndItsLinksAreIgnored() throws {
        let s = try chain()
        #expect([row(s, "B").start, row(s, "B").finish] == ["2026-10-12", "2026-10-16"])
        #expect([row(s, "C").start, row(s, "C").finish] == ["2026-10-19", "2026-10-23"])
        #expect(s.sched.projectFinish == "2026-10-23")
        #expect(s.run("inactive") { p, _ in try setTaskFlag(&p, uid(s, "B"), "inactive", true) }.ok)
        let b = row(s, "B")
        #expect(b.inactive)
        #expect([b.start, b.finish] == ["2026-10-12", "2026-10-16"])
        #expect(!b.critical)
        #expect(b.totalSlackMin == nil)
        #expect(!b.hasConflict)
        #expect([row(s, "C").start, row(s, "C").finish] == ["2026-10-05", "2026-10-09"])
        #expect(s.sched.links.isEmpty)
        #expect(s.sched.projectFinish == "2026-10-09")
        #expect(row(s, "A").critical)
        #expect(s.project.tasks[1].preds.count == 1)
        s.run("active") { p, _ in try setTaskFlag(&p, uid(s, "B"), "inactive", false) }
        #expect([row(s, "C").start, row(s, "C").finish] == ["2026-10-19", "2026-10-23"])
        #expect(!row(s, "B").inactive)
        #expect(s.sched.links.count == 2)
    }

    @Test func anInactiveTaskIsNotPartOfItsSummaryProjectSCurveOrNetwork() {
        var p = newProject(name: "T", startDate: "2026-10-05")
        insertTask(&p, 0, level: 1, name: "S"); insertTask(&p, 1, level: 2, name: "X", durationDays: 3); insertTask(&p, 2, level: 2, name: "Y", durationDays: 10)
        let s = Session(p)
        #expect(row(s, "S").finish == "2026-10-16")
        s.run("i") { d, _ in try setTaskFlag(&d, uid(s, "Y"), "inactive", true) }
        #expect(row(s, "S").finish == "2026-10-07")
        #expect(row(s, "S").durationMin == 3 * 480)
        #expect(s.sched.projectFinish == "2026-10-07")
        #expect(computeSCurve(s.project, s.sched).totalWeight == 3)
        #expect(layoutNetwork(s.project, s.sched).nodes.map { $0.uid } == [uid(s, "X")])
        s.run("pct") { d, sc in try setPercent(&d, uid(s, "X"), 100, sc) }
        #expect(row(s, "S").pct == 100)
        s.run("i2") { d, _ in try setTaskFlag(&d, uid(s, "X"), "inactive", true) }
        #expect(row(s, "S").finish == "2026-10-16")
    }

    @Test func aSummaryTaskCannotBeMadeInactive() {
        var p = newProject(name: "T", startDate: "2026-10-05")
        insertTask(&p, 0, level: 1, name: "S"); insertTask(&p, 1, level: 2, name: "X")
        let s = Session(p)
        let r = s.run("i") { d, _ in try setTaskFlag(&d, uid(s, "S"), "inactive", true) }
        #expect(!r.ok)
        #expect(r.error!.lowercased().contains("summary task cannot be made inactive"))
        s.run("i") { d, _ in try setTaskFlag(&d, uid(s, "X"), "inactive", true) }
        #expect(row(s, "X").inactive)
        s.undo()
        #expect(!row(s, "X").inactive)
    }

    @Test func msProjectXMLCarriesActivePriorityTypeHideBarRollup() throws {
        let s = try chain()
        s.run("all") { p, _ in
            try setTaskFlag(&p, uid(s, "B"), "inactive", true)
            try setPriority(&p, uid(s, "A"), "800")
            try setTaskType(&p, uid(s, "A"), "fixedWork")
            try setTaskType(&p, uid(s, "D"), "fixedDuration")
            try setTaskFlag(&p, uid(s, "D"), "hideBar", true)
            try setTaskFlag(&p, uid(s, "D"), "rollup", true)
            try setTaskFlag(&p, uid(s, "D"), "onTimeline", true)
        }
        let xml = exportMSPDI(s.project, s.sched).xml
        let root = try parseXml(xml)
        func val(_ n: String, _ tag: String) -> String? { kids(root.kid("Tasks"), "Task").first { $0.kid("Name")?.text == n }?.kid(tag)?.text }
        #expect(val("B", "Active") == "0")
        #expect(val("A", "Active") == "1")
        #expect(val("A", "Priority") == "800")
        #expect(val("A", "Type") == "2")
        #expect(val("D", "Type") == "1")
        #expect(val("D", "HideBar") == "1")
        #expect(val("D", "Rollup") == "1")
        #expect(val("C", "Rollup") == "0")
        let r = try importMSPDI(xml)
        func t(_ n: String) -> Task { r.project.tasks.first { $0.name == n }! }
        #expect(t("B").inactive)
        #expect(t("A").priority == 800)
        #expect(t("A").taskType == "fixedWork")
        #expect(t("D").taskType == "fixedDuration")
        #expect(t("D").hideBar)
        #expect(t("D").rollup)
        #expect(!t("C").rollup)
        #expect(t("B").start == "2026-10-12")
        let s2 = Session(r.project)
        #expect([row(s2, "B").start, row(s2, "B").finish] == ["2026-10-12", "2026-10-16"])
        #expect(row(s2, "C").start == "2026-10-05")
        #expect(r.report.notes.contains { $0.text.contains("inactive task") })
        #expect(!t("D").onTimeline) // not part of the MS Project XML format
    }

    @Test func excelAndCSVCarryTheSixSettings() throws {
        let s = try chain()
        s.run("all") { p, _ in
            try setTaskFlag(&p, uid(s, "B"), "inactive", true)
            try setPriority(&p, uid(s, "A"), "250")
            try setTaskType(&p, uid(s, "A"), "fixedDuration")
            try setTaskFlag(&p, uid(s, "D"), "hideBar", true)
            try setTaskFlag(&p, uid(s, "D"), "rollup", true)
            try setTaskFlag(&p, uid(s, "D"), "onTimeline", true)
        }
        let table = projectToTable(s.project, s.sched)
        for h in ["Priority", "Task Type", "Inactive", "Display on Timeline", "Hide Task Bar", "Roll Up Gantt Bar"] { #expect(table.headers.contains(h), "\(h)") }
        let info = projectInfoSheets(s.project)
        let bytes = writeXlsx([Sheet(name: "Tasks", rows: [table.headers.map { Cell.text($0) }] + table.rows), Sheet(name: "Project", rows: info.projectRows), Sheet(name: "Calendars", rows: info.calRows)])
        let back = try readXlsx(bytes)
        let rows = back.first { $0.name == "Tasks" }!.rows
        var o = TableImportOptions(); o.projectSheet = back[1].rows; o.calendarSheet = back[2].rows
        let r = try tableToProject(rows, o)
        func t(_ n: String) -> Task { r.project.tasks.first { $0.name == n }! }
        #expect(t("B").inactive)
        #expect(t("A").priority == 250)
        #expect(t("A").taskType == "fixedDuration")
        #expect([t("D").hideBar, t("D").rollup, t("D").onTimeline] == [true, true, true])
        #expect(t("C").priority == 500)
        let s2 = Session(r.project)
        #expect([row(s2, "B").start, row(s2, "B").finish] == ["2026-10-12", "2026-10-16"])
        var bad = rows
        let ci = bad[0].firstIndex { $0 == .text("Priority") }!
        while bad[1].count <= ci { bad[1].append(nil) }
        bad[1][ci] = .number(5000)
        let rb = try tableToProject(bad)
        #expect(rb.report.notes.contains { $0.text.contains("Priority must be a number from 0 to 1000") })
        #expect(tableToCsvRows(table)[0].contains("Roll Up Gantt Bar"))
    }

    @Test func nameStyleDefaultsSetterUndoAndCSS() throws {
        let s = try chain()
        let a = uid(s, "A")
        for k in NAME_STYLE_FLAGS { #expect(!s.project.tasks[0].flag(k), "\(k)") }
        #expect(nameStyleCss(s.project.tasks[0]) == "")
        #expect(!s.run("f") { p, _ in try setNameStyleFlag(&p, a, "nonsense", true) }.ok)
        s.run("style") { p, _ in
            try setNameStyleFlag(&p, a, "nameBold", true); try setNameStyleFlag(&p, a, "nameItalic", true); try setNameStyleFlag(&p, a, "nameUnderline", true)
        }
        let t = s.project.tasks[0]
        #expect(t.nameBold && t.nameItalic && t.nameUnderline)
        #expect(nameStyleCss(t) == "font-weight:700;font-style:italic;text-decoration:underline;")
        let before = s.sched.tasks.map { "\($0.start!)|\($0.finish!)" }
        s.undo()
        #expect(!s.project.tasks[0].nameBold)
        #expect(s.sched.tasks.map { "\($0.start!)|\($0.finish!)" } == before)
        let old = try Project.from(json: try JSONParser.parse(#"{"settings":{"startDate":"2026-10-05"},"tasks":[{"uid":1,"name":"Old","level":1}]}"#))
        for k in NAME_STYLE_FLAGS { #expect(!old.tasks[0].flag(k), "\(k)") }
    }

    @Test func templatesCarryPriorityTaskTypeAndDisplaySwitches() throws {
        let s = try chain()
        s.run("all") { p, _ in
            try setTaskFlag(&p, uid(s, "B"), "inactive", true)
            try setPriority(&p, uid(s, "A"), "700")
            try setTaskFlag(&p, uid(s, "D"), "hideBar", true)
        }
        let tpl = projectToTemplate(s.project, "Tpl")
        var p2 = newProject(name: "N", startDate: "2026-11-02")
        try applyTemplate(&p2, tpl)
        func t(_ n: String) -> Task { p2.tasks.first { $0.name == n }! }
        #expect(t("A").priority == 700)
        #expect(t("D").hideBar)
        #expect(!t("B").inactive)
        #expect(t("C").priority == 500)
    }
}
