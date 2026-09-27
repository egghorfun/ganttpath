// Ported from test/clipboard.test.js, test/reports.test.js and test/views.test.js (Ganttpath 1.3.6).

import Foundation
import Testing
@testable import GanttpathCore

private func clipProject() throws -> Project {
    var p = newProject(name: "T", startDate: "2026-10-05")
    for (n, l) in [("Phase A", 1), ("A1", 2), ("A2", 2), ("Phase B", 1), ("B1", 2), ("Loose", 1)] { insertTask(&p, p.tasks.count, level: l, name: n) }
    func u(_ n: String) -> Int { p.tasks.first { $0.name == n }!.uid }
    try addLink(&p, u("A1"), u("A2"), "FS")     // inside the phase
    try addLink(&p, u("A2"), u("B1"), "FS")     // out of the phase
    try addLink(&p, u("Loose"), u("A1"), "SS")  // into the phase
    return p
}
private func pnames(_ p: Project) -> [String] { p.tasks.map { $0.name } }
private func uidOf(_ p: Project, _ n: String) -> Int { p.tasks.first { $0.name == n }!.uid }

@Suite struct ClipboardTests {
    @Test func parseTSVReadsWhatExcelWrites() {
        #expect(parseTSV("") == [])
        #expect(parseTSV("a") == [["a"]])
        #expect(parseTSV("a\tb\nc\td\n") == [["a", "b"], ["c", "d"]])
        #expect(parseTSV("a\tb\r\nc\td\r\n") == [["a", "b"], ["c", "d"]])
        #expect(parseTSV("a\t\tc") == [["a", "", "c"]])
        #expect(parseTSV("a\t") == [["a", ""]])
        #expect(parseTSV("a\n\nb") == [["a"], [""], ["b"]])
        #expect(parseTSV("\"x\ty\"\t\"line1\nline2\"\t\"say \"\"hi\"\"\"") == [["x\ty", "line1\nline2", "say \"hi\""]])
        #expect(parseTSV("5\"\tb") == [["5\"", "b"]])
        #expect(parseTSV("\"unfinished\tb") == [["unfinished\tb"]])
    }

    @Test func toTSVQuotesOnlyWhatNeedsIt() {
        let rows = [["Task", "Duration"], ["Pour \"slab\"", "5d"], ["a\tb", "two\nlines"], ["", "x"]]
        let text = toTSV(rows)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false)[1] == "\"Pour \"\"slab\"\"\"\t5d")
        #expect(parseTSV(text) == rows)
        #expect(toTSV([["a", "b"]]) == "a\tb")
    }

    @Test func insertRowsAtTheLevelOfTheRowBelow() throws {
        var p = try clipProject()
        let before = uidOf(p, "A2")
        let uids = insertRows(&p, 2, 3)
        #expect(uids.count == 3)
        #expect(pnames(p) == ["Phase A", "A1", "New task", "New task", "New task", "A2", "Phase B", "B1", "Loose"])
        #expect(p.tasks[2..<5].map { $0.level } == [2, 2, 2])
        #expect(p.tasks[5].uid == before)
        #expect(insertRows(&p, 999, 1).count == 1)
        #expect(p.tasks.last!.level == 1)
        #expect(insertRows(&p, 0, 0).count == 1)
        #expect(insertRows(&p, 0, 9999).count == 500)
    }

    @Test func copyAndPasteOfRows() throws {
        var p = try clipProject()
        p.tasks[1].pct = 50
        let clip = copyTasks(p, [uidOf(p, "Phase A")])!
        #expect(clip.rows.map { $0.name } == ["Phase A", "A1", "A2"])
        let beforeCount = p.tasks.count
        let uids = try pasteTasks(&p, clip, beforeUid: nil, level: 1)
        #expect(p.tasks.count == beforeCount + 3)
        #expect(Array(pnames(p).suffix(3)) == ["Phase A", "A1", "A2"])
        #expect(Set(p.tasks.map { $0.uid }).count == p.tasks.count)
        let pa = p.tasks[p.tasks.count - 3], a1 = p.tasks[p.tasks.count - 2], a2 = p.tasks[p.tasks.count - 1]
        #expect(a2.preds.map { "\($0.uid)\($0.type)" } == ["\(a1.uid)FS"])
        #expect(a1.preds.isEmpty)
        #expect(a1.pct == 0)
        #expect(uids == [pa.uid, a1.uid, a2.uid])
        #expect(p.tasks[1].pct == 50)
        #expect(p.tasks[2].preds.count == 1)
        #expect(p.tasks[4].preds.count == 1)
        #expect(p.tasks[4].preds[0].uid == p.tasks[2].uid)
    }

    @Test func pastingKeepsShapeAndNeverGoesDeeperThanOneBelow() throws {
        var p = try clipProject()
        let clip = copyTasks(p, [uidOf(p, "Phase B")])
        _ = try pasteTasks(&p, clip, beforeUid: uidOf(p, "Loose"), level: 2)
        let i = p.tasks.count - 3
        #expect(p.tasks[i..<(i + 2)].map { "\($0.name)|\($0.level)" } == ["Phase B|2", "B1|3"])
        var p2 = try clipProject()
        let clip2 = copyTasks(p2, [uidOf(p2, "Loose")])
        _ = try pasteTasks(&p2, clip2, beforeUid: nil, level: 5)
        #expect(p2.tasks.last!.level == 2)
        do { _ = try pasteTasks(&p, nil, beforeUid: nil, level: 1); Issue.record("should fail") } catch let e as ModelError { #expect(e.message.lowercased().contains("nothing to paste")) }
    }

    @Test func copyTasksOfASummaryAndItsChild() throws {
        let p = try clipProject()
        #expect(copyTasks(p, [uidOf(p, "A1"), uidOf(p, "Phase A")])!.rows.map { $0.name } == ["Phase A", "A1", "A2"])
        #expect(copyTasks(p, [uidOf(p, "Loose"), uidOf(p, "A2")])!.rows.map { $0.name } == ["A2", "Loose"])
        #expect(copyTasks(p, []) == nil)
    }

    @Test func cutThenPasteKeepsEveryLink() throws {
        var p = try clipProject()
        try moveTasks(&p, [uidOf(p, "Phase A")], beforeUid: nil, level: 1)
        #expect(pnames(p) == ["Phase B", "B1", "Loose", "Phase A", "A1", "A2"])
        let a2 = p.tasks.first { $0.name == "A2" }!, b1 = p.tasks.first { $0.name == "B1" }!, a1 = p.tasks.first { $0.name == "A1" }!
        #expect(b1.preds.map { $0.uid } == [a2.uid])
        #expect(a1.preds.map { $0.uid } == [uidOf(p, "Loose")])
    }

    @Test func runGroupIsOneUndoStep() throws {
        let s = Session(try clipProject())
        let n0 = s.project.tasks.count
        let out = s.runGroup("Paste cells") { () -> [Bool] in
            let r1 = s.run("Paste cells") { d, _ in insertRows(&d, d.tasks.count, 2, level: 1) }
            let r2 = s.run("Paste cells") { d, _ in for u in r1.value! { try setName(&d, u, "N\(u)") } }
            return [r1.ok, r2.ok]
        }
        #expect(out == [true, true])
        #expect(s.project.tasks.count == n0 + 2)
        #expect(s.project.tasks.last!.name.hasPrefix("N"))
        #expect(s.history.undoStack.count == 1)
        s.undo()
        #expect(s.project.tasks.count == n0)
        s.redo()
        #expect(s.project.tasks.count == n0 + 2)
        let before = s.history.undoStack.count
        s.runGroup("nothing") { s.run("nothing") { _, _ in } }
        #expect(s.history.undoStack.count == before)
    }
}

private func reportProject() -> (Session, (String, Double, [Pred]) -> Int) {
    let s = Session(newProject(name: "R", startDate: "2026-09-21")) // a Monday
    let add: (String, Double, [Pred]) -> Int = { name, days, preds in
        s.run("a") { p, _ in insertTask(&p, p.tasks.count, level: 1, name: name, durationDays: days) { $0.preds = preds }.uid }.value!
    }
    return (s, add)
}

@Suite struct ReportTests {
    @Test func reportDefsListTheFourStandardReports() {
        #expect(REPORT_DEFS.map { $0.key } == ["critical", "late", "slipping", "milestones", "baselines"]) // Baseline Changes added in 1.5
        for r in REPORT_DEFS { #expect(!r.name.isEmpty); #expect(!r.blurb.isEmpty) }
    }

    @Test func referenceDnIsTheStatusDateOrToday() {
        let (s, _) = reportProject()
        #expect(referenceDn(s.project) == todayDn())
        s.run("sd") { p, _ in try updateSettings(&p, JSONObject([("statusDate", .string("2026-12-25"))])) }
        #expect(referenceDn(s.project) == parseISO("2026-12-25"))
    }

    @Test func criticalTasks() {
        let (s, add) = reportProject()
        let a = add("A", 5, [])
        _ = add("B", 5, [Pred(uid: a)])
        _ = add("C", 2, [])
        let rows = criticalTasksRows(s.sched)
        #expect(rows.map { s.project.tasks[$0.row.index].name }.sorted() == ["A", "B"])
        #expect(rows.allSatisfy { $0.row.critical })
    }

    @Test func lateTasks() {
        let (s, add) = reportProject()
        let late = add("Late", 5, [])
        let done = add("Done", 5, [])
        _ = add("Future", 5, [Pred(uid: late)])
        s.run("pct") { p, sc in try setPercent(&p, done, 100, sc) }
        s.run("sd") { p, _ in try updateSettings(&p, JSONObject([("statusDate", .string("2026-10-01"))])) }
        let rows = lateTasksRows(s.project, s.sched)
        #expect(rows.map { s.project.tasks[$0.row.index].name } == ["Late"])
        let lateFinishDn = parseISO(s.sched.tasks[s.project.tasks.firstIndex { $0.uid == late }!].finish)!
        #expect(rows[0].lateDays == referenceDn(s.project) - lateFinishDn)
    }

    @Test func slippingTasks() {
        let (s, add) = reportProject()
        let slipped = add("Slipped", 5, [])
        _ = add("NoBaseline", 5, [])
        let completedLate = add("CompletedLate", 5, [])
        s.run("bl") { p, sc in try setBaseline(&p, 0, sc, [slipped, completedLate]) }
        s.run("stretch") { p, _ in try setDurationDays(&p, slipped, 8); try setDurationDays(&p, completedLate, 8) }
        s.run("pct") { p, sc in try setPercent(&p, completedLate, 100, sc) }
        #expect(hasAnyBaseline(s.project))
        let rows = slippingTasksRows(s.project, s.sched, baselineIndex: 0)
        #expect(rows.map { s.project.tasks[$0.row.index].name } == ["Slipped"])
        #expect(rows[0].slipDays! > 0)
    }

    @Test func slippingTasksWithNoBaselineAtAll() {
        let (s, add) = reportProject()
        _ = add("A", 5, [])
        #expect(!hasAnyBaseline(s.project))
        #expect(slippingTasksRows(s.project, s.sched, baselineIndex: 0).isEmpty)
    }

    @Test func milestoneReport() {
        let (s, add) = reportProject()
        let done = add("Shipped", 0, [])
        let overdue = add("Overdue", 0, [])
        let ahead = add("Ahead", 30, [Pred(uid: overdue)])
        _ = add("Ahead milestone", 0, [Pred(uid: ahead)])
        s.run("pct") { p, sc in try setPercent(&p, done, 100, sc) }
        s.run("sd") { p, _ in try updateSettings(&p, JSONObject([("statusDate", .string("2026-10-01"))])) }
        var byName: [String: String] = [:]
        for r in milestoneRows(s.project, s.sched) { byName[s.project.tasks[r.row.index].name] = r.milestoneStatus }
        #expect(byName["Shipped"] == "Complete")
        #expect(byName["Overdue"] == "Late")
        #expect(byName["Ahead milestone"] == "Upcoming")
    }

    @Test func reportRowsDispatchesByKey() {
        let (s, add) = reportProject()
        _ = add("A", 5, [])
        for key in ["critical", "late", "slipping", "milestones"] { _ = reportRows(key, s.project, s.sched) }
        #expect(reportRows("nonsense", s.project, s.sched).isEmpty)
    }
}

@Suite struct ViewTests {
    private func simple() -> (Session, Int, Int) {
        let s = Session(newProject(name: "S", startDate: "2026-10-05"))
        let a = s.run("a") { p, _ in insertTask(&p, 0, level: 1, name: "A", durationDays: 5).uid }.value!
        let b = s.run("a") { p, _ in insertTask(&p, 1, level: 1, name: "B", durationDays: 5) { $0.preds = [Pred(uid: a)] }.uid }.value!
        return (s, a, b)
    }

    @Test func sCurveMonotonicEndsAt100AndReflectsProgress() {
        let (s, a, _) = simple()
        s.run("bl") { p, sc in try setBaseline(&p, 0, sc) }
        s.run("pct") { p, sc in try setPercent(&p, a, 100, sc) }
        s.run("status") { p, _ in try updateSettings(&p, JSONObject([("statusDate", .string("2026-10-09"))])) }
        let c = computeSCurve(s.project, s.sched, baseline: 0, statusDate: "2026-10-09")
        #expect(c.hasBaseline)
        #expect(c.totalWeight == 10)
        let last = c.dates.count - 1
        #expect(abs(c.planned[last]! - 100) < 1e-9)
        #expect(abs(c.forecast[last] - 100) < 1e-9)
        for i in 1..<c.forecast.count { #expect(c.forecast[i] >= c.forecast[i - 1] - 1e-9); #expect(c.planned[i]! >= c.planned[i - 1]! - 1e-9) }
        #expect(abs(c.status!.earned - 50) < 1e-9)
        #expect(abs(c.status!.planned! - 50) < 1e-9)
        #expect(abs(c.status!.spi! - 1) < 1e-9)
        let iStatus = c.dates.firstIndex(of: "2026-10-09")!
        #expect(abs(c.actual[iStatus]! - 50) < 1e-9)
        #expect(c.actual[last] == nil)
    }

    @Test func sCurveWeightsOverrideDurations() {
        let (s, a, b) = simple()
        s.run("w") { p, _ in try setWeight(&p, a, "30"); try setWeight(&p, b, "10") }
        let c = computeSCurve(s.project, s.sched)
        #expect(c.totalWeight == 40)
        #expect(!c.hasBaseline)
        #expect(c.planned[0] == nil)
        let i = c.dates.firstIndex(of: "2026-10-07")!
        #expect(abs(c.forecast[i] - (30 * 0.6) / 40 * 100) < 1e-9)
    }

    @Test func filtersSearchSortAndGrouping() {
        let s = richProject()
        var r = buildRows(s.project, s.sched)
        #expect(r.rows.count == s.project.tasks.count)
        #expect(!r.active)
        s.run("c") { p, _ in try toggleCollapse(&p, p.tasks[0].uid, true) }
        r = buildRows(s.project, s.sched)
        #expect(r.rows.compactMap { $0.index }.map { s.project.tasks[$0].name }.joined(separator: "|") == "Phase 1|Phase 2|P2 task")
        var v = ViewState(); v.search = "month mile"
        r = buildRows(s.project, s.sched, v)
        #expect(r.rows.compactMap { $0.index }.map { s.project.tasks[$0].name } == ["Phase 1", "Month milestone"])
        #expect(isFiltering(v))
        var vc = ViewState(); vc.filter.critical = true
        r = buildRows(s.project, s.sched, vc)
        #expect(r.rows.compactMap { $0.index }.allSatisfy { s.sched.tasks[$0].critical || s.sched.tasks[$0].isSummary })
        s.run("c") { p, _ in try toggleCollapse(&p, p.tasks[0].uid, false) }
        var vs = ViewState(); vs.sort = ViewSort(field: "duration", dir: "desc")
        r = buildRows(s.project, s.sched, vs)
        let rowIdx = r.rows.compactMap { $0.index }
        #expect(s.project.tasks[rowIdx[0]].name.hasPrefix("Phase"))
        let phase2 = s.project.tasks.firstIndex { $0.name == "Phase 2" }!
        let durs = rowIdx.filter { s.project.tasks[$0].level == 2 && $0 < phase2 }.map { s.sched.tasks[$0].duration }
        #expect(durs == durs.sorted(by: >))
        var vg = ViewState(); vg.group = "status"
        r = buildRows(s.project, s.sched, vg)
        let headers = r.rows.compactMap { if case .group(let g, _) = $0 { return g } else { return nil } }
        #expect(headers == ["Complete", "Not started"])
        s.run("t") { p, _ in try addTag(&p, "Long lead"); try setTaskTags(&p, [p.tasks[1].uid], on: ["Long lead"]) }
        var vt = ViewState(); vt.filter.tags = ["Long lead"]
        r = buildRows(s.project, s.sched, vt)
        #expect(r.rows.compactMap { $0.index }.map { s.project.tasks[$0].name } == ["Phase 1", "A"])
    }

    @Test func networkLayoutColumnsFollowLogic() {
        let s = richProject()
        let L = layoutNetwork(s.project, s.sched)
        var pos: [Int: NetworkNode] = [:]
        for n in L.nodes { pos[n.uid] = n }
        #expect(L.nodes.count > 5)
        for e in L.edges {
            let a = pos[e.from]!, b = pos[e.to]!
            #expect(b.col > a.col, "successors sit to the right of predecessors")
            #expect(e.points[0].0 == a.x + a.w)
            #expect(e.points[e.points.count - 1].0 == b.x)
        }
        var seen = Set<String>()
        for n in L.nodes { let k = "\(n.col):\(n.row)"; #expect(!seen.contains(k), "overlap at \(k)"); seen.insert(k) }
        let crit = layoutNetwork(s.project, s.sched, scope: .critical)
        #expect(crit.nodes.allSatisfy { s.sched.tasks[$0.index].critical })
        let sub = layoutNetwork(s.project, s.sched, scope: .summary(s.project.tasks[0].uid))
        #expect(sub.nodes.count < L.nodes.count + 1)
    }

    @Test func networkLayoutOn1000TasksIsFast() {
        let s = Session(newProject(name: "Big", startDate: "2026-10-05"))
        s.run("big") { p, _ in
            var prev: Int? = nil
            for i in 0..<1000 {
                let t = insertTask(&p, p.tasks.count, level: 1, name: "T\(i)", durationDays: Double(1 + i % 7)) { t in
                    if let pr = prev, i % 5 != 0 { t.preds = [Pred(uid: pr)] }
                }
                prev = t.uid
            }
        }
        let t0 = Date()
        let L = layoutNetwork(s.project, s.sched)
        let ms = Date().timeIntervalSince(t0) * 1000
        print("  network layout of \(L.nodes.count) nodes in \(Int(ms)) ms")
        #expect(ms < 1000)
    }
}
