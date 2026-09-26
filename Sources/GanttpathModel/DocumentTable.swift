// The task table: cell editing, keyboard, clipboard (rows and cells), sorting by a heading and dragging rows.
// Port of gantt.js (table part) and clipboard.js.

import Foundation
import GanttpathCore

public enum TableKey: Equatable, Sendable {
    case up, down, left, right, home, end, pageUp, pageDown, tab, enter, f2, escape, delete, character(String)
}

public struct KeyMods: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyMods(rawValue: 1)
    public static let command = KeyMods(rawValue: 2)
    public static let option = KeyMods(rawValue: 4)
}

/// What the table should do after a key: nothing, or start editing a cell (with the typed character).
public enum KeyOutcome: Equatable, Sendable {
    case unhandled
    case handled
    case beginEdit(uid: Int, col: String, initial: String?)
}

extension DocumentModel {
    public func column(_ id: String) -> ColumnDef? { columns.first { $0.id == id } }

    // MARK: clicking

    /// A press on a cell. Pressing the row number (ID) or WBS selects whole rows; any other cell selects cells.
    public func pressCell(uid: Int, col: String, mods: KeyMods) {
        let keepAnchor = mods.contains(.shift) ? anchorCol : nil
        cursorUid = uid
        cursorCol = col
        anchorCol = keepAnchor ?? col
        selMode = col == "id" || col == "wbs" ? .rows : .cells
        if mods.contains(.shift) { setSelection(extendSelection(to: uid)) }
        else if mods.contains(.command) {
            var next = selection
            if next.contains(uid) { next.remove(uid) } else { next.insert(uid) }
            setSelection(Array(next), anchor: uid)
        } else if !selection.contains(uid) || selection.count == 1 || col != "id" {
            setSelection([uid], anchor: uid)
        }
    }

    /// Clicking a heading sorts by it: ascending, then descending, then no sort.
    public func headingClicked(_ colId: String) {
        guard let c = column(colId), let field = c.sortField else { return }
        if let cur = view.sort, cur.field == field {
            if cur.dir == "asc" { var s = cur; s.dir = "desc"; view.sort = s } else { view.sort = nil }
        } else {
            view.sort = ViewSort(field: field, dir: "asc", keepOutline: view.sort?.keepOutline ?? true)
        }
    }

    public func setColumnWidth(_ id: String, _ w: Double) {
        colWidths[id] = max(36, w.rounded())
        let widths = colWidths
        setPrefs { $0.colWidths = widths }
    }

    public func setColumnShown(_ id: String, _ shown: Bool) {
        columnIds = columnIdsAfter(project, current: columnIds, id, shown: shown)
        let ids = columnIds
        setPrefs { $0.columns = ids }
    }
    public func resetColumns() { columnIds = nil; setPrefs { $0.columns = nil } }

    // MARK: editing

    /// Why a cell cannot be edited, or nil when it can.
    public func editBlockReason(uid: Int, col colId: String) -> String? {
        guard let col = column(colId), let c = context(uid) else { return "" }
        guard let e = col.edit else { return "\(col.title) is calculated and cannot be edited here." }
        if e.disabled(c) {
            if c.r.inactive && col.id != "inactive" { return "This task is inactive: it keeps its dates and takes no part in the schedule. Make it active again to change them (right-click the row, or use the Inactive column)." }
            if col.id == "inactive" && c.r.isSummary { return "A summary task cannot be made inactive. Make its sub-tasks inactive instead." }
            if ["duration", "start", "finish", "pct"].contains(col.id) { return "A summary task takes its dates, duration and progress from its sub-tasks." }
            return "\(col.title) cannot be edited for this task."
        }
        return nil
    }

    /// Start editing: returns the text to put in the editor, or nil (a message says why not).
    public func beginEdit(uid: Int, col: String) -> String? {
        if let why = editBlockReason(uid: uid, col: col) { if !why.isEmpty { say(why, .info, 3.5) }; return nil }
        cursorUid = uid; cursorCol = col; anchorCol = col
        guard let c = context(uid), let e = column(col)?.edit else { return nil }
        return e.raw(c)
    }

    /// Apply a typed value. Returns true when the editor can close (false: the message tells what is wrong, the editor stays).
    @discardableResult
    public func commitEdit(uid: Int, col colId: String, text: String, original: String? = nil) -> Bool {
        guard let col = column(colId), let c = context(uid), let e = col.edit else { return true }
        if let o = original, text == o, e.kind != .select { return true }
        let change: Change
        do { change = try col.commit!(text, c) } catch { say(messageOf(error), .error); return false }
        let startBefore = colId == "preds" ? c.r.start : nil
        let r = session.run("Edit \(col.title)", change)
        if let err = r.error { say(err, .error); return false }
        if colId == "start" || colId == "finish" { noteConstraint(uid: uid, col: colId, text: text) }
        if colId == "preds" { notePredecessors(uid: uid, text: text, startBefore: startBefore) }
        if colId == "wbs" { noteWbs(uid: uid, text: text) }
        return true
    }

    /// Where the cursor goes after an edit ends with Enter (down/up) or Tab (right/left).
    public func moveAfterEdit(uid: Int, col: String, move: TableKey) {
        let o = order
        guard let pos = o.firstIndex(of: uid) else { return }
        switch move {
        case .down, .up:
            let k = pos + (move == .down ? 1 : -1)
            if k >= 0 && k < o.count { cursorCol = col; anchorCol = col; selectOnly(o[k]); emit(.scrollTo(o[k])) }
        case .right, .left:
            let ids = columns.filter { $0.edit != nil }.map { $0.id }
            let ci = ids.firstIndex(of: col) ?? 0
            cursorUid = uid
            cursorCol = ids[min(ids.count - 1, max(0, ci + (move == .right ? 1 : -1)))]
            anchorCol = cursorCol
        default: break
        }
    }

    func messageOf(_ e: Error) -> String { (e as? ModelError)?.message ?? "\(e)" }

    private func noteWbs(uid: Int, text: String) {
        let res = wbsResultBox.take()
        selectOnly(uid)
        emit(.scrollTo(uid))
        guard let r = res, !r.same else { return }
        let typed = jsTrim(text)
        var msg = "Moved\(r.moved > 1 ? " with its \(plural(r.moved - 1, "sub-task"))" : ""): it is now \(r.wbs)"
        if r.wbs != typed { msg += " (not \(typed): the rows that moved were above the new parent, so the numbers after them shifted up)" }
        msg += "."
        if r.removedLinks > 0 { msg += " \(plural(r.removedLinks, "link")) between a summary and its own sub-task \(r.removedLinks == 1 ? "was" : "were") removed." }
        say(msg, .info, r.wbs != typed ? 7 : 3.2)
    }

    /// After predecessors were typed and the start did not move: say why, so the edit does not look ignored.
    private func notePredecessors(uid: Int, text: String, startBefore: String?) {
        guard let i = index(of: uid), !jsTrim(text).isEmpty else { return }
        let t = project.tasks[i], r = sched.tasks[i]
        if r.start != startBefore { return }
        let id = i + 1
        if r.isSummary { say("Row \(id) is a summary task: its dates come from its sub-tasks, so its links do not move it.", .info, 6); return }
        if t.inactive { say("Row \(id) is inactive, so its links are ignored until it is made active.", .info, 6); return }
        if t.mode == "manual" { say("Row \(id) is manually scheduled, so its dates do not follow its predecessors (the links are kept). Set Task Mode to \"Auto scheduled\" to let them move it.", .info, 8); return }
        let cn = t.constraint
        if cn.type != "ASAP" {
            say("Row \(id) did not move: its constraint \"\(CONSTRAINT_NAMES[cn.type] ?? cn.type)\(cn.date.map { " \(fmt.date($0))" } ?? "")\" still decides its dates. Change it in the Constraint column to let the links decide.", .info, 8)
            return
        }
        let ps = String(project.settings.startDate.prefix(10))
        if let s = r.start, String(s.prefix(10)) == ps, t.preds.contains(where: { $0.lag.v < 0 }) {
            say("Row \(id) starts on the project start date (\(fmt.date(ps))): Ganttpath does not schedule a task before it. Move the project start earlier under Project settings if it should start sooner.", .info, 8)
        }
    }

    private func noteConstraint(uid: Int, col: String, text: String) {
        guard let i = index(of: uid) else { return }
        let t = project.tasks[i]
        guard !jsTrim(text).isEmpty, let typed = fmt.parseStampText(text)?.dn else { return }
        let dayOff = !calendarOf(project, t).isWorking(typed)
        if t.mode == "auto" {
            let c = t.constraint
            say("Automatic task: \(CONSTRAINT_NAMES[c.type] ?? c.type) \(fmt.date(c.date)) was set.\(dayOff ? " That day is a day off, so the task starts on the next working day." : "") Use the Constraint column to change it.", .info, 3.8)
        } else if dayOff {
            let r = sched.tasks[i]
            say("\(fmt.date(toISO(typed))) is a day off. The task \(col == "start" ? "starts on the next working day, \(fmt.date(r.start))" : "finishes on the last working day before it, \(fmt.date(r.finish))").", .info, 4.5)
        }
    }

    /// The row at the bottom of the table: typing a name there adds a task at the end.
    @discardableResult
    public func addTaskAtEnd(name: String) -> Int? {
        let n = jsTrim(name)
        if n.isEmpty { return nil }
        let level = project.tasks.last?.level ?? 1
        let r = run("Add task") { d, _ in insertTask(&d, d.tasks.count, level: level, name: n, durationDays: 1).uid }
        if let uid = r.value { selectOnly(uid); emit(.scrollTo(uid)) }
        return r.value
    }

    /// Columns between where the block selection began and the cursor column.
    public var blockColumns: (from: Int, to: Int)? {
        let ids = columns.map { $0.id }
        guard let b = ids.firstIndex(of: cursorCol) else { return nil }
        let a = ids.firstIndex(of: anchorCol) ?? b
        return (min(a, b), max(a, b))
    }

    /// Empty the selected cells where a cell can be emptied.
    public func clearCells() {
        guard let (lo, hi) = blockColumns else { return }
        let cols = Array(columns[lo...hi])
        var changes: [Change] = []
        var labels: [String] = []
        do {
            for col in cols where col.edit != nil && col.commit != nil && isEmptiable(col) {
                for uid in selectedUids {
                    guard let c = context(uid), !col.edit!.disabled(c) else { continue }
                    changes.append(try col.commit!("", c))
                    if !labels.contains(col.title) { labels.append(col.title) }
                }
            }
        } catch { say(messageOf(error), .error); return }
        if !changes.isEmpty { run("Clear \(labels.joined(separator: ", "))") { d, s in for f in changes { try f(&d, s) } } }
    }

    // MARK: keyboard

    public func key(_ key: TableKey, _ mods: KeyMods = []) -> KeyOutcome {
        let o = order
        let curPos = cursorUid.flatMap { o.firstIndex(of: $0) }
        let colIds = columns.map { $0.id }
        let cmd = mods.contains(.command)
        func moveRow(_ d: Int, _ extend: Bool) {
            if o.isEmpty { return }
            if !extend { anchorCol = cursorCol }
            let k = curPos == nil ? (d > 0 ? 0 : o.count - 1) : min(o.count - 1, max(0, curPos! + d))
            let uid = o[k]
            cursorUid = uid
            if extend { setSelection(extendSelection(to: uid)) } else { selectOnly(uid) }
            emit(.scrollTo(uid))
        }
        func moveCol(_ d: Int, _ extend: Bool) {
            let ci = colIds.firstIndex(of: cursorCol) ?? 0
            cursorCol = colIds[min(colIds.count - 1, max(0, ci + d))]
            if extend { selMode = .cells } else { anchorCol = cursorCol }
        }
        let alt = mods.contains(.option), shift = mods.contains(.shift)
        switch key {
        case .down where !alt && !cmd: moveRow(1, shift); return .handled
        case .up where !alt && !cmd: moveRow(-1, shift); return .handled
        case .right where !alt && !cmd: moveCol(1, shift); return .handled
        case .left where !alt && !cmd: moveCol(-1, shift); return .handled
        case .home where cmd: moveRow(-1_000_000, false); return .handled
        case .end where cmd: moveRow(1_000_000, false); return .handled
        case .pageDown: moveRow(15, shift); return .handled
        case .pageUp: moveRow(-15, shift); return .handled
        case .tab: moveCol(shift ? -1 : 1, false); return .handled
        case .enter, .f2:
            if let u = cursorUid { return .beginEdit(uid: u, col: cursorCol, initial: nil) }
            return .unhandled
        case .escape:
            if let c = clip, c.cut { clip = nil; return .handled } // Esc gives up a Cut
            if !selection.isEmpty { setSelection([]); return .handled }
            return .unhandled
        case .delete:
            if selection.isEmpty { return .unhandled }
            if cmd || cursorCol == "id" || cursorCol == "wbs" { deleteSelected(); return .handled }
            clearCells(); return .handled
        case .character(let ch):
            let lower = ch.lowercased()
            if cmd && lower == "a" { selMode = .rows; setSelection(o, anchor: anchor); return .handled }
            if cmd && lower == "b" { if selection.isEmpty { return .unhandled }; toggleSelectedNameStyle("nameBold"); return .handled }
            if cmd && lower == "u" { if selection.isEmpty { return .unhandled }; toggleSelectedNameStyle("nameUnderline"); return .handled }
            if let u = cursorUid, !cmd, !alt, ch.count == 1, let col = column(cursorCol), let e = col.edit, e.kind == .text || e.kind == .date {
                return .beginEdit(uid: u, col: cursorCol, initial: ch)
            }
            return .unhandled
        default: return .unhandled
        }
    }

    // MARK: clipboard (clipboard.js)

    /// The text a cell holds when copied: the editing text when there is one, else what is shown.
    public func cellText(_ col: ColumnDef, _ c: CellContext) -> String { col.edit.map { $0.raw(c) } ?? col.text(c) }

    private func rowsToText(_ uids: [Int], _ cols: [ColumnDef]) -> String {
        toTSV(uids.compactMap { u in context(u).map { c in cols.map { cellText($0, c) } } })
    }

    /// Copy or Cut. Returns the text for the system clipboard, or nil when there is nothing to copy.
    @discardableResult
    public func copy(cut: Bool) -> String? {
        if selection.isEmpty { return nil }
        let cols = columns
        if selMode == .rows {
            guard let data = copyTasks(project, selectedUids) else { return nil }
            let uids = data.rows.map { $0.uid }
            let text = rowsToText(uids, cols)
            clip = ClipState(kind: .rows, cut: cut, text: text, data: data, uids: uids)
            say(cut ? "\(plural(uids.count, "row")) cut. Select where they go and press ⌘V (Esc gives up)." : "\(plural(uids.count, "row")) copied. Select a row and press ⌘V to paste below it.", .info, 2.6)
            return text
        }
        let uids = order.filter { selection.contains($0) }
        guard !uids.isEmpty, let (lo, hi) = blockColumns else { return nil }
        let block = Array(cols[lo...hi])
        let text = rowsToText(uids, block)
        clip = ClipState(kind: .cells, cut: cut, text: text, uids: uids, colIds: block.map { $0.id })
        say("\(plural(uids.count * block.count, "cell")) \(cut ? "cut" : "copied").\(cut ? " Click where they go and press ⌘V (Esc gives up)." : "")", .info, 2.2)
        return text
    }

    /// Paste `text` from the system clipboard. Returns false when there was nothing to paste.
    @discardableResult
    public func paste(_ text: String) -> Bool {
        func norm(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            while t.hasSuffix("\n") { t.removeLast() }
            return t
        }
        let own = clip.flatMap { norm($0.text) == norm(text) ? $0 : nil }
        if let c = own, c.kind == .rows { pasteRows(c); return true }
        if jsTrim(norm(text)).isEmpty && !(own?.kind == .cells) { return false }
        pasteCells(text, own)
        return true
    }

    /// Where pasted rows go: below the last selected row (with its sub-tasks), at its level; at the end when nothing is selected.
    private func rowTarget() -> (beforeUid: Int?, level: Int) {
        let sel = selectedIndexes
        guard let last = sel.last else { return (nil, project.tasks.last?.level ?? 1) }
        let at = subtreeEnd(project, last)
        return (at < project.tasks.count ? project.tasks[at].uid : nil, project.tasks[last].level)
    }

    private func pasteRows(_ c: ClipState) {
        let (beforeUid, level) = rowTarget()
        if c.cut {
            if !outlinePlain { say("Clear the sort, group, filter or search first: rows can only be moved in the full outline."); return }
            if selectedIndexes.contains(where: { c.uidSet.contains(project.tasks[$0].uid) }) { say("Select a row outside the rows you cut, then paste.", .info, 3.5); return }
            let r = run("Move rows") { d, _ in try moveTasks(&d, c.uids, beforeUid: beforeUid, level: level) }
            guard let res = r.value else { return }
            clip = nil
            let still = c.uids.filter { index(of: $0) != nil }
            setSelection(still, anchor: c.uids.first)
            selMode = .rows
            say(res.moved > 0 ? "\(plural(res.moved, "row")) moved. All links were kept." : "Those rows no longer exist.", .info, 2.2)
            if res.removedLinks > 0 { say("\(plural(res.removedLinks, "link")) between a summary and its own sub-task \(res.removedLinks == 1 ? "was" : "were") removed.") }
            return
        }
        let r = run("Paste rows") { d, _ in try pasteTasks(&d, c.data, beforeUid: beforeUid, level: level) }
        guard let uids = r.value else { return }
        setSelection(uids, anchor: uids.first)
        selMode = .rows
        if let f = uids.first { emit(.scrollTo(f)) }
        say("\(plural(uids.count, "row")) pasted.", .info, 1.8)
    }

    /// A select-list column accepts the stored value or the label shown, in any case.
    private func selectValue(_ col: ColumnDef, _ text: String) throws -> String {
        let t = jsTrim(text).lowercased()
        let opts = col.edit!.options(project)
        if let hit = opts.first(where: { $0.value.lowercased() == t || $0.label.lowercased() == t }) { return hit.value }
        throw ModelError("\"\(text)\" is not one of: \(opts.map { $0.label.isEmpty ? "(empty)" : $0.label }.joined(separator: ", "))")
    }

    private func pasteCells(_ text: String, _ own: ClipState?) {
        let cols = columns
        let o = order
        let data = parseTSV(text)
        let cutCells = own.flatMap { $0.kind == .cells && $0.cut ? $0 : nil }
        if data.isEmpty { return }
        let blockUids = o.filter { selection.contains($0) }
        guard let first = blockUids.first, let (bFrom, bTo) = blockColumns else { say("Click the cell where the paste should start.", .info, 3); return }
        var startCol = bFrom
        if cols[startCol].id == "id" || cols[startCol].id == "wbs" {
            startCol = cols.firstIndex { $0.id == "name" } ?? cols.firstIndex { $0.edit != nil } ?? 0
        }
        let startRow = o.firstIndex(of: first)!
        let single = data.count == 1 && data[0].count == 1
        let fill = single && (blockUids.count > 1 || bTo > bFrom)
        struct Target { var row: Int; var col: Int; var value: String }
        var cells: [Target] = []
        var outside = 0
        if fill {
            for r in blockUids.indices { for c in bFrom...bTo { cells.append(Target(row: startRow + r, col: c, value: data[0][0])) } }
        } else {
            for (r, line) in data.enumerated() {
                for (c, v) in line.enumerated() {
                    if startCol + c >= cols.count { outside += 1; continue }
                    cells.append(Target(row: startRow + r, col: startCol + c, value: v))
                }
            }
        }
        if cells.isEmpty { say("Nothing to paste: the pasted columns lie beyond the last column of the table.", .info, 3.5); return }
        let newRows = max(0, (cells.map { $0.row }.max() ?? 0) - (o.count - 1))
        var pasted = 0, clearedSrc = 0, keptSrc = 0
        var notes: [String] = [], errors: [String] = []
        var failed = false, empty = false
        var uidAt = o
        session.runGroup(cutCells != nil ? "Move cells" : "Paste cells") {
            if newRows > 0 {
                let r = run("Paste cells") { d, _ -> [Int] in
                    let lv = d.tasks.last?.level ?? 1
                    return (0..<newRows).map { _ in insertTask(&d, d.tasks.count, level: lv, name: "New task").uid }
                }
                guard let add = r.value else { failed = true; return }
                uidAt += add
            }
            var changes: [Change] = []
            var done = Set<String>()
            for cell in cells {
                let col = cols[cell.col]
                guard cell.row < uidAt.count, let c = context(uidAt[cell.row]) else { continue }
                guard let e = col.edit, let commit = col.commit, !e.noPaste, !e.disabled(c) else { notes.append(col.title); continue }
                var v = cell.value
                if jsTrim(v).isEmpty && !isEmptiable(col) { continue } // an empty cell does not overwrite a value that cannot be emptied
                do {
                    if e.kind == .select { v = try selectValue(col, v) }
                    changes.append(try commit(v, c))
                    done.insert("\(c.uid):\(col.id)")
                    pasted += 1
                } catch { errors.append("\(col.title) of row \(c.index + 1): \(messageOf(error))") }
            }
            if let cc = cutCells {
                // empty the cells that were cut, unless something was pasted into them
                for uid in cc.uids {
                    for id in cc.colIds where !done.contains("\(uid):\(id)") {
                        guard let col = cols.first(where: { $0.id == id }), let c = context(uid), let e = col.edit, let commit = col.commit,
                              isEmptiable(col), !e.disabled(c) else { keptSrc += 1; continue }
                        if let f = try? commit("", c) { changes.append(f); clearedSrc += 1 } else { keptSrc += 1 }
                    }
                }
            }
            if changes.isEmpty { empty = true; return }
            let r2 = run(cutCells != nil ? "Move cells" : "Paste cells") { d, s in for f in changes { try f(&d, s) } }
            if !r2.ok { failed = true }
        }
        if failed { return }
        if empty && newRows > 0 { session.undo() } // nothing could be pasted: do not leave blank rows behind
        if cutCells != nil { clip = nil }
        pruneSelection()
        var parts: [String] = []
        if pasted > 0 { parts.append("\(plural(pasted, "cell")) pasted") }
        if newRows > 0 && !empty { parts.append("\(plural(newRows, "new task")) added at the end") }
        if !notes.isEmpty {
            var uniq: [String] = []
            for n in notes where !uniq.contains(n) { uniq.append(n) }
            parts.append("\(plural(notes.count, "cell")) skipped because \(uniq.joined(separator: ", ")) cannot be typed in there")
        }
        if outside > 0 { parts.append("\(plural(outside, "value")) skipped beyond the last column") }
        if keptSrc > 0 { parts.append("cut cells that cannot be emptied were left as they are (copied only)") }
        if !errors.isEmpty { parts.append("\(plural(errors.count, "value")) not accepted (\(errors[0])\(errors.count > 1 ? ", ..." : ""))") }
        let bad = !errors.isEmpty || (pasted == 0 && clearedSrc == 0)
        say(parts.isEmpty ? "Nothing was pasted." : parts.joined(separator: "; ") + ".", bad ? .error : .info, errors.isEmpty ? 3.2 : 7)
        if pasted > 0 {
            var rowsSel: [Int] = []
            for c in cells where c.row < uidAt.count {
                let u = uidAt[c.row]
                if index(of: u) != nil && !rowsSel.contains(u) { rowsSel.append(u) }
            }
            if let f = rowsSel.first { setSelection(rowsSel, anchor: f) }
        }
    }

    // MARK: dragging rows by their ID

    /// Where dragged rows would land with the pointer at `y` (px from the top of the rows) and moved sideways by `dx`.
    /// Returns the row they go before (nil = the end), their level and the position of the drop line (a row boundary).
    public func rowDropTarget(uids: [Int], grabbedUid: Int, y: Double, dx: Double, levelIndent: Double = 16) -> (beforeUid: Int?, level: Int, line: Int) {
        let p = project
        let rs = rows
        var k = Int((y / ROW_H).rounded())
        k = max(0, min(rs.count, k))
        let line = k
        var moving = Set<Int>()
        for u in uids { let i = indexOfUid(p, u); if i >= 0 { for j in i..<subtreeEnd(p, i) { moving.insert(p.tasks[j].uid) } } }
        var beforeUid: Int? = nil
        while k < rs.count {
            if let i = rs[k].index, !moving.contains(p.tasks[i].uid) { beforeUid = p.tasks[i].uid; break }
            k += 1
        }
        var above: Task? = nil
        var q = line - 1
        while q >= 0 {
            if let i = rs[q].index, !moving.contains(p.tasks[i].uid) { above = p.tasks[i]; break }
            q -= 1
        }
        let origLevel = taskByUid(p, grabbedUid)?.level ?? 1
        let maxLevel = above.map { $0.level + 1 } ?? 1
        let level = max(1, min(maxLevel, origLevel + Int((dx / levelIndent).rounded())))
        return (beforeUid, level, line)
    }

    public func dropRows(uids: [Int], beforeUid: Int?, level: Int) {
        if !outlinePlain {
            say(view.sort != nil || view.group != nil ? "Clear the sort or group first: rows can only be moved in the plain outline." : "Clear the filter or search first: rows can only be moved in the full outline.")
            return
        }
        let r = run("Move rows") { d, _ in try moveTasks(&d, uids, beforeUid: beforeUid, level: level) }
        if let res = r.value, res.removedLinks > 0 { say("\(res.removedLinks) link(s) between a summary and its own sub-task were removed.") }
    }

    // MARK: tags

    public static let TAG_COLORS = ["#2563EB", "#16A34A", "#D97706", "#9333EA", "#DB2777", "#0891B2", "#65A30D", "#EA580C"]

    public func setTag(_ name: String, on: Bool, for uids: [Int]) {
        run("Tag") { d, _ in try setTaskTags(&d, uids, on: on ? [name] : [], off: on ? [] : [name]) }
    }
    @discardableResult
    public func addTagAndApply(_ name: String, to uids: [Int]) -> Bool {
        let n = jsTrim(name)
        if n.isEmpty { return false }
        return run("New tag") { d, _ in
            try addTag(&d, n, Self.TAG_COLORS[d.tags.count % Self.TAG_COLORS.count])
            if !uids.isEmpty { try setTaskTags(&d, uids, on: [n]) }
        }.ok
    }
}
