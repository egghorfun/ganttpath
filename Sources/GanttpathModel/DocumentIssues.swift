// Scheduling conflicts per row, for the tooltip shown when the pointer rests on a row or bar (like the indicator tooltip
// in Microsoft Project), and the labels used by the Scheduling Conflicts list.

import Foundation
import GanttpathCore

/// Names of the conflict types, as shown in the conflicts list and in tooltips.
public let CONFLICT_TYPE_LABEL = ["link": "Broken link", "constraint": "Constraint", "deadline": "Deadline", "calendar": "Calendar",
                                  "slack": "Negative slack", "cycle": "Circular"]

extension DocumentModel {
    /// The task's own conflicts and, for a summary, the conflicts of the tasks below it (task index, conflict).
    public func issues(index i: Int) -> (own: [Conflict], below: [Conflict]) {
        guard i >= 0 && i < project.tasks.count else { return ([], []) }
        let own = sched.conflicts.filter { $0.index == i }
        let lv = project.tasks[i].level
        var k = i + 1
        while k < project.tasks.count && project.tasks[k].level > lv { k += 1 }
        let below = sched.conflicts.filter { $0.index > i && $0.index < k }
        return (own, below)
    }

    /// The text for the tooltip of a task, or nil when the task has no problem.
    public func issueTip(index i: Int) -> String? {
        let (own, below) = issues(index: i)
        if own.isEmpty && below.isEmpty { return nil }
        let t = project.tasks[i]
        var lines = ["\(i + 1)  \(t.name.isEmpty ? "(unnamed)" : t.name)"]
        if !own.isEmpty {
            lines.append(own.count == 1 ? "⚠ This task has a scheduling conflict:" : "⚠ This task has \(own.count) scheduling conflicts:")
            for c in own { lines.append("•  \(CONFLICT_TYPE_LABEL[c.type] ?? c.type): \(c.message)") }
        }
        if !below.isEmpty {
            let n = Set(below.map { $0.index }).count
            lines.append(n == 1 ? "⚠ 1 task below this summary has a scheduling conflict:" : "⚠ \(n) tasks below this summary have scheduling conflicts:")
            for c in below.prefix(8) {
                let name = project.tasks[c.index].name
                lines.append("•  \(c.index + 1) \(name.isEmpty ? "(unnamed)" : name) (\(CONFLICT_TYPE_LABEL[c.type] ?? c.type)): \(c.message)")
            }
            if below.count > 8 { lines.append("…and \(below.count - 8) more. Open the Scheduling Conflicts pane to see them all.") }
        }
        return lines.joined(separator: "\n")
    }

    /// The tooltip for a row of the table (a position in `rows`), or nil.
    public func issueTip(row pos: Int) -> String? {
        guard pos >= 0 && pos < rows.count, let i = rows[pos].index else { return nil }
        return issueTip(index: i)
    }

    /// The tooltip for a point of the table or chart body (rows start at y = 0), or nil.
    public func issueTip(y: Double) -> String? {
        guard y >= 0 else { return nil }
        return issueTip(row: Int((y / ROW_H).rounded(.down)))
    }
}
