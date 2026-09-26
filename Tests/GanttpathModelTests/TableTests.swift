// Copy, cut, paste, insert and delete rows and cells; keyboard; cell editing.
// Port of the JavaScript app's browser tests (test/ui-clipboard.test.mjs and parts of ui-checklist / ui-wbs), run on the model.

import Foundation
import Testing
@testable import GanttpathModel
@testable import GanttpathCore

@MainActor
@Suite struct ClipboardTests {
    @Test func copyBlockOfCellsAndPasteFurtherDown() {
        let (m, _, _) = makeModel()
        let t0 = m.t
        m.click(3, "duration"); m.click(5, "duration", .shift)
        let txt = m.copy(cut: false)
        #expect(txt == [3, 4, 5].map { "\(jsNumberString(Double(t0[$0 - 1].dur) / 480))d" }.joined(separator: "\n"))
        m.click(10, "duration")
        #expect(m.paste(txt!))
        #expect([10, 11, 12].map { m.t[$0 - 1].dur } == [3, 4, 5].map { t0[$0 - 1].dur })
        #expect(m.log.last!.message.contains("3 cells pasted"))
        m.undo()
        #expect(m.t.map { $0.dur } == t0.map { $0.dur }, "one undo puts all three back")
    }

    @Test func twoColumnsAreTabSeparated() {
        let (m, _, _) = makeModel()
        m.click(3, "name"); m.click(4, "duration", .shift)
        let lines = m.copy(cut: false)!.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)
        #expect(lines[0].split(separator: "\t", omittingEmptySubsequences: false).first.map(String.init) == m.t[2].name)
    }

    @Test func cellsFromExcelAreTypedAsIfEntered() {
        let (m, _, _) = makeModel()
        let t0 = m.t
        m.click(3, "name")
        m.paste("Excavate trench\t4d\nBackfill\t6h\n")
        #expect(m.t[2].name == "Excavate trench" && m.t[2].dur == 4 * 480)
        #expect(m.t[3].name == "Backfill" && m.t[3].dur == 360 && m.t[3].durUnit == "h")
        #expect(m.t.count == t0.count)
        m.undo()
        #expect(m.t[2].name == t0[2].name && m.t[3].name == t0[3].name)
    }

    @Test func badValuesAreReportedAndSkipped() {
        let (m, _, _) = makeModel()
        let t0 = m.t
        m.click(3, "name")
        m.paste("Good name\tsoon\nSecond name\t2d\n")
        #expect(m.t[2].name == "Good name" && m.t[2].dur == t0[2].dur && m.t[3].dur == 960)
        let msg = m.log.last!.message
        #expect(msg.contains("not accepted") && msg.contains("Duration of row 3") && msg.contains("not a duration"), "\(msg)")
    }

    @Test func pastingPastTheLastRowAddsTasks() {
        let (m, _, _) = makeModel()
        let n0 = m.t.count
        m.click(n0, "name")
        m.paste("Last one\nExtra 1\nExtra 2")
        #expect(m.t.count == n0 + 2)
        #expect(m.t.suffix(3).map { $0.name } == ["Last one", "Extra 1", "Extra 2"])
        #expect(m.log.last!.message.contains("2 new tasks added at the end"))
        m.undo()
        #expect(m.t.count == n0, "one undo step removes the new rows too")
    }

    @Test func oneValueFillsTheBlockAndDeleteEmptiesWhatCanBeEmptied() {
        let (m, _, _) = makeModel()
        m.setColumnShown("notes", true)
        m.click(3, "notes"); m.click(5, "notes", .shift)
        m.paste("check on site")
        #expect([3, 4, 5].map { m.t[$0 - 1].notes } == ["check on site", "check on site", "check on site"])
        #expect(m.t[5].notes == "")
        m.click(3, "notes"); m.click(4, "notes", .shift)
        #expect(m.key(.delete) == .handled)
        #expect(m.t[2].notes == "" && m.t[3].notes == "" && m.t[4].notes == "check on site")
        let d3 = m.t[2].dur
        m.click(3, "duration")
        _ = m.key(.delete)
        #expect(m.t[2].dur == d3, "a duration cannot be emptied")
    }

    @Test func deleteClearsPredecessorsAndDeletesRowsOnTheIdColumn() {
        let (m, _, _) = makeModel()
        m.click(3, "preds")
        m.paste("2")
        #expect(m.t[2].preds.count == 1)
        m.click(3, "preds")
        _ = m.key(.delete)
        #expect(m.t[2].preds.isEmpty)
        let n = m.t.count, gone = m.uid(6)
        m.click(6, "id")
        _ = m.key(.delete)
        #expect(m.t.count < n && !m.t.contains { $0.uid == gone })
        m.undo()
        #expect(m.t.count == n)
    }

    @Test func cutAndPasteCellsMovesValuesInOneUndoStep() {
        let (m, _, _) = makeModel()
        m.setColumnShown("notes", true)
        m.click(3, "notes"); m.click(4, "notes", .shift)
        m.paste("first\nsecond")
        m.click(3, "notes"); m.click(4, "notes", .shift)
        let text = m.copy(cut: true)!
        m.click(10, "notes")
        m.paste(text)
        #expect([m.t[2].notes, m.t[3].notes, m.t[9].notes, m.t[10].notes] == ["", "", "first", "second"])
        #expect(m.clip == nil, "a cut can be pasted once")
        m.undo()
        #expect([m.t[2].notes, m.t[3].notes, m.t[9].notes, m.t[10].notes] == ["first", "second", "", ""])
    }

    @Test func shiftArrowsWidenTheBlockAndAwkwardValuesSurvive() {
        let (m, _, _) = makeModel()
        m.setColumnShown("notes", true)
        m.click(3, "name")
        _ = m.key(.right, .shift)
        _ = m.key(.down, .shift)
        let rows = m.copy(cut: false)!.split(separator: "\n")
        #expect(rows.count == 2 && rows[0].split(separator: "\t").count == 2)
        m.click(3, "notes")
        m.paste("\"line one\nline two\twith a tab\"\t")
        #expect(m.t[2].notes == "line one\nline two\twith a tab")
    }

    @Test func cutAndPasteRowsMovesThemWithTheirLinks() {
        let (m, _, _) = makeModel()
        let t0 = m.t
        let uid6 = t0[5].uid
        m.click(6, "id")
        _ = m.copy(cut: true)
        #expect(m.key(.escape) == .handled && m.clip == nil, "Esc gives the cut up")
        m.click(6, "id")
        let text = m.copy(cut: true)!
        m.click(3, "id")
        m.paste(text)
        #expect(m.t.count == t0.count && m.t[3].uid == uid6)
        for t in t0 { #expect(m.t.first { $0.uid == t.uid }!.preds.map { $0.uid } == t.preds.map { $0.uid }) }
        m.undo()
        #expect(m.t.map { $0.name } == t0.map { $0.name })
    }

    @Test func cutRowsCannotBePastedInsideThemselves() {
        let (m, _, _) = makeModel()
        m.click(1, "id")
        let text = m.copy(cut: true)!
        m.click(3, "id")
        m.paste(text)
        #expect(m.log.last!.message.lowercased().contains("outside the rows you cut"))
    }

    @Test func copyAndPasteRowsMakesNewTasksBelow() {
        let (m, _, _) = makeModel()
        let t0 = m.t
        #expect(t0[6].level == 1)
        m.click(1, "id")
        let text = m.copy(cut: false)!
        m.click(6, "id")
        m.paste(text)
        #expect(m.t.count == t0.count + 6)
        #expect(m.t[6..<12].map { $0.name } == t0[0..<6].map { $0.name })
        #expect(m.t[6..<12].allSatisfy { n in !t0.contains { $0.uid == n.uid } })
        #expect(m.log.last!.message.contains("6 rows pasted"))
    }

    @Test func insertRowsAboveBelowAndDelete() {
        let (m, _, _) = makeModel()
        let n = m.t.count
        m.click(3, "id")
        let above = m.insertRows(below: false)!
        #expect(above.count == 1 && m.t[2].uid == above[0])
        m.click(4, "id")
        let many = m.insertRows(below: true, count: 3)!
        #expect(many.count == 3 && m.t.count == n + 4)
        m.deleteSelected()
        #expect(m.t.count == n + 1)
    }
}

@MainActor
@Suite struct EditingTests {
    @Test func typingStartsAnEditAndEnterMovesDown() {
        let (m, _, _) = makeModel()
        m.click(3, "name")
        #expect(m.key(.character("X")) == .beginEdit(uid: m.uid(3), col: "name", initial: "X"))
        #expect(m.commitEdit(uid: m.uid(3), col: "name", text: "Xylophone"))
        #expect(m.t[2].name == "Xylophone")
        m.moveAfterEdit(uid: m.uid(3), col: "name", move: .down)
        #expect(m.cursorUid == m.uid(4) && m.selection == [m.uid(4)])
    }

    @Test func badTextKeepsTheEditorOpenWithAMessage() {
        let (m, _, _) = makeModel()
        #expect(!m.commitEdit(uid: m.uid(3), col: "duration", text: "abc"))
        #expect(m.log.last?.kind == .error)
        #expect(m.beginEdit(uid: m.uid(1), col: "duration") == nil, "a summary's duration cannot be edited")
        #expect(m.log.last!.message.contains("summary task takes its dates"))
        #expect(m.beginEdit(uid: m.uid(1), col: "totalSlack") == nil)
        #expect(m.log.last!.message.contains("calculated"))
    }

    @Test func typingAStartOnAnAutomaticTaskExplainsTheConstraint() {
        let (m, _, _) = makeModel()
        #expect(m.commitEdit(uid: m.uid(3), col: "start", text: "10-Oct-2026")) // a Saturday
        #expect(m.t[2].constraint.type == "SNET")
        #expect(m.log.last!.message.contains("Start No Earlier Than") && m.log.last!.message.contains("day off"))
    }

    @Test func wbsEditMovesTheRowAndSaysWhere() {
        let (m, _, _) = makeModel()
        let uid = m.uid(3)
        #expect(m.commitEdit(uid: uid, col: "wbs", text: "2.1"))
        let i = m.index(of: uid)!
        #expect(m.sched.tasks[i].wbs == "2.1")
        #expect(m.log.last!.message.hasPrefix("Moved"))
        m.view.search = "a"
        #expect(!m.commitEdit(uid: uid, col: "wbs", text: "1.1"))
        #expect(m.log.last!.message.contains("Clear the sort, group, filter or search first"))
    }

    @Test func keyboardSelectAllBoldAndEscape() {
        let (m, _, _) = makeModel()
        m.click(2, "name")
        #expect(m.key(.character("a"), .command) == .handled)
        #expect(m.selection.count == m.order.count)
        m.selectOnly(m.uid(2))
        _ = m.key(.character("b"), .command)
        #expect(m.t[1].nameBold)
        #expect(m.key(.escape) == .handled && m.selection.isEmpty)
    }

    @Test func headingClicksCycleTheSort() {
        let (m, _, _) = makeModel()
        m.headingClicked("duration")
        #expect(m.view.sort?.field == "duration" && m.view.sort?.dir == "asc")
        m.headingClicked("duration")
        #expect(m.view.sort?.dir == "desc")
        m.headingClicked("duration")
        #expect(m.view.sort == nil)
    }

    @Test func rowDragTargetsAndMove() {
        let (m, _, _) = makeModel()
        let u = m.uid(3)
        // drop between rows 5 and 6, no sideways move: same level, before row 6
        let tg = m.rowDropTarget(uids: [u], grabbedUid: u, y: 5 * ROW_H, dx: 0)
        #expect(tg.beforeUid == m.uid(6) && tg.level == m.t[2].level)
        m.dropRows(uids: [u], beforeUid: tg.beforeUid, level: tg.level)
        #expect(m.t[4].uid == u)
        // dragging far right cannot go deeper than one level below the row above
        let deep = m.rowDropTarget(uids: [u], grabbedUid: u, y: 2 * ROW_H, dx: 200)
        #expect(deep.level == m.t[1].level + 1)
    }
}

@MainActor
@Suite struct ActionTests {
    @Test func addIndentOutdentMoveAndLink() {
        let (m, _, _) = makeModel()
        m.selectOnly(m.uid(2))
        let a = m.addTask()!
        #expect(m.t[2].uid == a && m.selection == [a])
        m.indent()
        #expect(m.t[2].level == m.t[1].level + 1)
        m.outdent()
        #expect(m.t[2].level == m.t[1].level)
        m.moveUp()
        #expect(m.t[1].uid == a)
        m.moveDown()
        #expect(m.t[2].uid == a)
        m.setSelection([m.uid(2), a])
        m.unlinkSelected()
        m.linkSelected()
        #expect(m.t[2].preds.contains { $0.uid == m.uid(2) })
        m.unlinkSelected()
        #expect(!m.t[2].preds.contains { $0.uid == m.uid(2) })
        let s = m.addTask(summary: true)!
        let i = m.index(of: s)!
        #expect(m.sched.tasks[i].isSummary && m.t[i + 1].level == m.t[i].level + 1)
    }

    @Test func milestoneFlagsStylesAndBaselines() {
        let (m, _, _) = makeModel()
        m.selectOnly(m.uid(3))
        m.toggleMilestone()
        #expect(m.t[2].dur == 0)
        m.toggleMilestone()
        #expect(m.t[2].dur == dayMinOf(m.project.settings))
        m.setSelectedFlag("hideBar", true)
        #expect(m.t[2].hideBar)
        m.selectOnly(m.uid(1))
        m.setSelectedFlag("inactive", true)
        #expect(!m.t[0].inactive, "a summary cannot be inactive")
        m.setSelection([m.uid(2), m.uid(3)])
        m.toggleSelectedNameStyle("nameItalic")
        #expect(m.t[1].nameItalic && m.t[2].nameItalic)
        m.toggleSelectedNameStyle("nameItalic")
        #expect(!m.t[1].nameItalic)
        m.setBaseline(0, selectedOnly: false)
        #expect(m.showBaseline == 0 && m.t.allSatisfy { $0.baselines[0] != nil })
        m.clearBaseline(0, selectedOnly: false)
        #expect(m.t.allSatisfy { $0.baselines[0] == nil })
    }

    @Test func collapsingIsNotAnUndoStep() {
        let (m, _, _) = makeModel()
        let before = m.canUndo
        let n = m.rows.count
        m.toggleCollapse(m.uid(1))
        #expect(m.rows.count < n)
        #expect(m.canUndo == before)
        m.collapseAll(false)
        #expect(m.rows.count == n)
        m.collapseAll(true)
        m.reveal(m.uid(3))
        #expect(m.posOf[2] != nil)
    }

    @Test func linkEditingAndDeleting() {
        let (m, _, _) = makeModel()
        let key = "\(m.uid(2))>\(m.uid(3))"
        #expect(m.t[2].preds.contains { $0.uid == m.uid(2) })
        #expect(m.editLink(key, type: "SS", lagText: "+2d"))
        #expect(m.t[2].preds.first { $0.uid == m.uid(2) }!.type == "SS")
        #expect(!m.editLink(key, type: "SS", lagText: "soon"))
        m.deleteLink(key)
        #expect(!m.t[2].preds.contains { $0.uid == m.uid(2) } && m.linkSel == nil)
    }
}
