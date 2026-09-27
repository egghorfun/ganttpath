// Eleven baselines and comparing two of them: a second bar in the chart, columns with the compared dates and the shifts, and
// the Baseline Changes report.

import Foundation
import Testing
@testable import GanttpathCore

@Suite struct BaselineCompareTests {
    /// A: 4 days, B: 2 days, C: 3 days. Baseline 1 is saved, then A becomes 6 days and D is added, then Baseline 3 is saved
    /// without C.
    func project() -> Session {
        let s = fresh()
        let a = add(s, "A", 1, days: 4)
        add(s, "B", 1, days: 2)
        let c = add(s, "C", 1, days: 3)
        s.run("BL1") { p, sc in try setBaseline(&p, 1, sc) }
        s.run("Longer") { p, _ in try setDurationDays(&p, a, 6) }
        add(s, "D", 1, days: 1)
        s.run("BL3") { p, sc in try setBaseline(&p, 3, sc) }
        s.run("Drop C") { p, _ in try clearBaseline(&p, 3, [c]) }
        return s
    }

    @Test func columnsShowTheComparedBaselineAndTheShift() throws {
        let s = project()
        let ids = allColumns(s.project, s.sched).map { $0.id }
        for id in ["cmpBaselineStart", "cmpBaselineFinish", "baselineStartShift", "baselineFinishShift"] { #expect(ids.contains(id)) }
        let cols = Dictionary(uniqueKeysWithValues: allColumns(s.project, s.sched).map { ($0.id, $0) })
        func cell(_ id: String, _ row: Int, show: Int = 1, compare: Int = 3) -> String {
            cols[id]!.text(CellContext(project: s.project, sched: s.sched, index: row, showBaseline: show, compareBaseline: compare))
        }
        // A: Baseline 1 finishes 8 Oct, Baseline 3 finishes 12 Oct (6 working days from Monday 5 Oct): 2 days later
        #expect(cell("baselineFinish", 0) == "Thu 08-Oct-2026")
        #expect(cell("cmpBaselineFinish", 0) == "Mon 12-Oct-2026")
        #expect(cell("baselineFinishShift", 0) == "2d")
        #expect(cell("baselineStartShift", 0) == "0d")
        // the other way round the shift is negative
        #expect(cell("baselineFinishShift", 0, show: 3, compare: 1) == "-2d")
        // B did not move
        #expect(cell("baselineFinishShift", 1) == "0d")
        // C is not in Baseline 3; D is not in Baseline 1
        #expect(cell("cmpBaselineFinish", 2) == "" && cell("baselineFinishShift", 2) == "")
        #expect(cell("baselineFinish", 3) == "" && cell("cmpBaselineFinish", 3) != "")
        // no comparison: the columns are empty
        #expect(cell("cmpBaselineFinish", 0, compare: -1) == "" && cell("baselineFinishShift", 0, compare: -1) == "")
        #expect(cell("cmpBaselineFinish", 0, compare: 1) == "") // comparing a baseline with itself shows nothing
    }

    @Test func reportListsWhatMovedBetweenTheTwo() {
        let s = project()
        let rows = reportRows("baselines", s.project, s.sched, baselineIndex: 1, compareIndex: 3)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { (s.project.tasks[$0.row.index].name, $0) })
        #expect(Set(byName.keys) == ["A", "C", "D"]) // B did not move
        #expect(byName["A"]?.finishShift == 2 * 480 && byName["A"]?.change == "Finishes later")
        #expect(byName["C"]?.change == "Not in Baseline 3")
        #expect(byName["D"]?.change == "Added in Baseline 3")
        let fmt = Fmt(s.project, s.sched)
        let cols = REPORT_COLUMNS["baselines"]!.map { $0.id }
        let a = byName["A"]!
        #expect(cols.map { reportCellText($0, a, s.project.tasks[a.row.index], fmt) } ==
                ["1", "A", "Mon 05-Oct-2026", "Thu 08-Oct-2026", "Mon 05-Oct-2026", "Mon 12-Oct-2026", "0d", "+2d", "Finishes later"])
        // nothing to compare
        #expect(reportRows("baselines", s.project, s.sched, baselineIndex: 1, compareIndex: -1).isEmpty)
        #expect(reportRows("baselines", s.project, s.sched, baselineIndex: 1, compareIndex: 1).isEmpty)
        #expect(REPORT_DEFS.contains { $0.key == "baselines" && $0.name == "Baseline Changes" })
    }

    @Test func chartDrawsTheComparedBaselineUnderTheShownOne() {
        var p = project().project
        let s = scheduleAndApply(&p)
        let rows = buildRows(p, s).rows
        func svg(_ show: Int, _ compare: Int) -> String {
            var o = GanttOptions(); o.showBaseline = show; o.compareBaseline = compare
            let lay = ganttLayout(project: p, sched: s, rows: rows, px: 20, viewWidth: 800, opts: o)
            let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: rows.count - 1, px: 20, originDn: lay.originDn, endDn: lay.endDn,
                                 posOf: positions(rows), opts: o, theme: .light)
            return SVGWriter.svg(body.drawing)
        }
        func count(_ hay: String, _ needle: String) -> Int { hay.components(separatedBy: needle).count - 1 }
        let teal = PALETTE["light"]!["baseline2"]!, grey = PALETTE["light"]!["baseline"]!
        let one = svg(1, -1), both = svg(1, 3)
        #expect(count(one, teal) == 0)
        #expect(count(one, grey) == 3)       // A, B and C have Baseline 1; D was added later
        #expect(count(both, grey) == count(one, grey))
        #expect(count(both, teal) == 3)      // A, B, D are in Baseline 3; C is not
        #expect(svg(1, 1) == one)            // a baseline compared with itself draws nothing more
        #expect(svg(-1, 3).contains(teal) == false)
        #expect(PALETTE["dark"]!["baseline2"] != nil && COLOR_LABELS["baseline2"] != nil)
    }
}
