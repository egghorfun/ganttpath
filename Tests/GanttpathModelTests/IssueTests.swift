// The message log (messages stay after the toast fades; errors wait for OK) and the tooltips of rows with conflicts.

import Foundation
import Testing
@testable import GanttpathModel
@testable import GanttpathCore

@MainActor
@Suite struct IssueTests {
    /// A task at level 2 or deeper that finishes after the project start, and its summary.
    func leafWithParent(_ m: DocumentModel) -> (leaf: Int, parent: Int) {
        let t = m.project.tasks
        let leaf = t.indices.first { i in
            t[i].level >= 2 && !(m.sched.tasks[i].isSummary) && (m.sched.tasks[i].finish ?? "") > "2026-10-07"
        }!
        let parent = (0..<leaf).last { t[$0].level < t[leaf].level }!
        return (leaf, parent)
    }

    @Test func noTipWithoutConflicts() {
        let (m, _, _) = makeModel()
        #expect(m.sched.conflicts.isEmpty)
        for pos in m.rows.indices { #expect(m.issueTip(row: pos) == nil) }
        #expect(m.issueTip(y: -1) == nil)
        #expect(m.issueTip(row: m.rows.count) == nil) // the "add a task" row
    }

    @Test func tipOnTheTaskAndItsSummary() throws {
        let (m, _, _) = makeModel()
        let (leaf, parent) = leafWithParent(m)
        let uid = m.project.tasks[leaf].uid
        _ = m.run("Deadline") { d, _ in try setDeadline(&d, uid, "2026-10-05") }
        #expect(m.sched.conflicts.contains { $0.index == leaf && $0.type == "deadline" })

        let pos = try #require(m.rows.firstIndex { $0.index == leaf })
        let tip = try #require(m.issueTip(row: pos))
        let name = m.project.tasks[leaf].name
        #expect(tip.hasPrefix("\(leaf + 1)  \(name)\n⚠ This task has a scheduling conflict:\n•  Deadline: Finishes after its deadline (05-Oct-2026)"))
        // the same through a point: anywhere in the row's height
        #expect(m.issueTip(y: Double(pos) * ROW_H + 1) == tip)
        #expect(m.issueTip(y: Double(pos + 1) * ROW_H - 0.5) == tip)

        let ppos = try #require(m.rows.firstIndex { $0.index == parent })
        let ptip = try #require(m.issueTip(row: ppos))
        let n = Set(m.issues(index: parent).below.map { $0.index }).count
        #expect(n >= 1)
        #expect(ptip.contains(n == 1 ? "⚠ 1 task below this summary has a scheduling conflict:" : "⚠ \(n) tasks below this summary have scheduling conflicts:"), "\(ptip)")
        #expect(ptip.contains("•  \(leaf + 1) \(name) (Deadline): Finishes after its deadline"))
        #expect(!ptip.contains("This task has"))

        // the app gives a tooltip area to the rows whose task is flagged; exactly those rows have a tip
        for p in m.rows.indices {
            guard let i = m.rows[p].index else { #expect(m.issueTip(row: p) == nil); continue }
            #expect((m.sched.tasks[i].hasConflict || m.sched.tasks[i].childConflict) == (m.issueTip(row: p) != nil), "row \(p + 1)")
        }
        // rows without a problem have no tip
        for p in m.rows.indices where p != pos {
            if let i = m.rows[p].index, m.issues(index: i).own.isEmpty && m.issues(index: i).below.isEmpty { #expect(m.issueTip(row: p) == nil) }
        }
        // clearing the deadline clears the tip
        _ = m.run("Deadline") { d, _ in try setDeadline(&d, uid, nil) }
        #expect(m.issueTip(row: pos) == nil)
        #expect(m.issueTip(row: ppos) == nil)
    }

    @Test func messagesAreKeptInTheLog() {
        let (m, _, _) = makeModel()
        m.selectOnly(m.uid(2))
        m.say("Saved")
        #expect(m.toast?.message == "Saved")
        #expect(m.pendingError == nil)
        m.dismissToast(m.toast!.id)
        #expect(m.toast == nil)
        #expect(m.log.count == 1) // the message is still in the log after the toast fades
        #expect(m.log[0].kind == .info && m.log[0].uid == m.uid(2) && m.log[0].taskLabel == "2  \(m.t[1].name)")
    }

    @Test func errorsWaitForOK() {
        let (m, _, _) = makeModel()
        m.selectOnly(m.uid(3))
        #expect(!m.commitEdit(uid: m.uid(3), col: "duration", text: "abc"))
        let e = m.pendingError
        #expect(e != nil && e!.kind == .error)
        #expect(m.toast == nil) // not a toast that fades
        #expect(m.errorCount == 1)
        #expect(m.log.last == e)
        #expect(m.logText.contains("\tError\t3  \(m.t[2].name)\t"))
        m.pendingError = nil
        #expect(m.log.count == 1) // acknowledging keeps it in the log
        m.showIssues(.messages)
        #expect(m.conflictsOpen && m.issuesTab == .messages)
        m.clearLog()
        #expect(m.log.isEmpty && m.errorCount == 0)
    }

    @Test func logIsLimited() {
        let (m, _, _) = makeModel()
        for k in 0..<(DocumentModel.LOG_LIMIT + 5) { m.say("m\(k)") }
        #expect(m.log.count == DocumentModel.LOG_LIMIT)
        #expect(m.log.first?.message == "m5")
    }
}
