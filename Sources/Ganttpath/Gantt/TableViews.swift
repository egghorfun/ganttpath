// The task table: headings (sort, resize, show / hide columns) and rows (select, edit in place, keyboard, drag rows, context menu).

import AppKit
import SwiftUI
import GanttpathCore
import GanttpathModel

// MARK: - headings

final class TableHeaderView: FlippedView, PaneChild {
    weak var pane: GanttPaneView?
    private var resizing: (id: String, startX: CGFloat, startW: Double)? = nil
    private var moved = false

    var scrollX: CGFloat { pane?.tableScroll.contentView.bounds.origin.x ?? 0 }

    override func draw(_ dirtyRect: NSRect) {
        guard let p = pane, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = p.scale
        p.theme.headerBg.ns.setFill()
        bounds.fill()
        ctx.saveGState()
        ctx.translateBy(x: -scrollX, y: 0)
        ctx.scaleBy(x: s, y: s)
        CGRenderer.draw(p.model.tableHeaderDrawing(theme: p.theme, font: p.state.font), in: ctx)
        ctx.restoreGState()
    }

    private func logicalX(_ e: NSEvent) -> Double { Double(convert(e.locationInWindow, from: nil).x + scrollX) / (pane?.scale ?? 1) }

    override func resetCursorRects() {
        guard let p = pane else { return }
        let g = TableGeometry(p.model.columns)
        for i in g.lefts.indices {
            let x = (g.lefts[i] + g.widths[i]) * p.scale - scrollX
            addCursorRect(NSRect(x: x - 3.5, y: 0, width: 7, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let p = pane else { return }
        let g = TableGeometry(p.model.columns)
        moved = false
        if let gi = g.grip(at: logicalX(event)) { resizing = (g.ids[gi], event.locationInWindow.x, g.widths[gi]) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let p = pane, let r = resizing else { return }
        moved = true
        p.model.colWidths[r.id] = max(36, (r.startW + Double(event.locationInWindow.x - r.startX) / p.scale).rounded())
    }
    override func mouseUp(with event: NSEvent) {
        guard let p = pane else { return }
        if let r = resizing {
            if moved, let w = p.model.colWidths[r.id] { p.model.setColumnWidth(r.id, w) }
            resizing = nil
            window?.invalidateCursorRects(for: self)
            return
        }
        let g = TableGeometry(p.model.columns)
        if let ci = g.column(at: logicalX(event)) { p.model.headingClicked(g.ids[ci]) }
    }

    /// Right-click on a heading: hide that column, or tick columns on and off.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let p = pane else { return nil }
        let g = TableGeometry(p.model.columns)
        let menu = NSMenu()
        if let ci = g.column(at: logicalX(event)), let col = p.model.column(g.ids[ci]), col.id != "name" {
            menu.addItem(ClosureMenuItem("Hide the \"\(col.title)\" column") { p.model.setColumnShown(col.id, false) })
            menu.addItem(.separator())
        }
        addColumnItems(to: menu, model: p.model) { p.state.sheet = .columnsToShow }
        return menu
    }
}

/// One tick box per column, then reset and the full dialog (columns.js columnMenuItems).
@MainActor
func addColumnItems(to menu: NSMenu, model m: DocumentModel, more: @escaping () -> Void) {
    let shown = Set(m.columns.map { $0.id })
    for c in allColumns(m.project, m.sched) {
        let item = ClosureMenuItem(c.title) { m.setColumnShown(c.id, !shown.contains(c.id)) }
        item.state = shown.contains(c.id) ? .on : .off
        if c.id == "name" { item.isEnabled = false; item.action = nil }
        menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem("Reset to the standard columns") { m.resetColumns() })
    menu.addItem(ClosureMenuItem("Columns to show…", more))
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, key: String = "", _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { run() }
}

// MARK: - rows

final class TableBodyView: FlippedView, PaneChild, NSTextFieldDelegate {
    weak var pane: GanttPaneView?
    private var editor: NSView? = nil
    private var editUid: Int? = nil
    private var editCol = ""
    private var editOriginal = ""
    private var adding = false
    private var busy = false
    private var datePopover: NSPopover? = nil
    // dragging rows by their ID
    private var rowDrag: (uids: [Int], grabbed: Int, start: NSPoint, active: Bool, target: (beforeUid: Int?, level: Int, line: Int)?)? = nil
    private var lastDragPoint: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }
    var model: DocumentModel? { pane?.model }
    var scale: Double { pane?.scale ?? 1 }

    override func draw(_ dirtyRect: NSRect) {
        guard let p = pane, let ctx = NSGraphicsContext.current?.cgContext else { return }
        p.theme.bg.ns.setFill()
        dirtyRect.fill()
        let s = p.scale
        let first = max(0, Int((Double(dirtyRect.minY) / s / ROW_H).rounded(.down)) - 1)
        let last = Int((Double(dirtyRect.maxY) / s / ROW_H).rounded(.up)) + 1
        let d = p.model.tableRowsDrawing(first: first, last: last, theme: p.theme, font: p.state.font)
        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: 0, y: Double(first) * ROW_H)
        CGRenderer.draw(d.items, in: ctx)
        ctx.restoreGState()
        // drop line and label while dragging rows
        if let rd = rowDrag, rd.active, let t = rd.target {
            p.theme.accent.ns.setFill()
            NSRect(x: Double(t.level - 1) * LEVEL_INDENT * s, y: Double(t.line) * ROW_H * s - 1.5, width: Double(bounds.width), height: 3).fill()
            let name = rd.uids.count == 1 ? (taskByUid(p.model.project, rd.uids[0])?.name ?? "") : "\(rd.uids.count) tasks"
            drawTip(name, at: lastDragPoint, in: ctx, theme: p.theme)
        }
    }

    private func point(_ e: NSEvent) -> (x: Double, y: Double) {
        let pt = convert(e.locationInWindow, from: nil)
        return (Double(pt.x) / scale, Double(pt.y) / scale)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        guard let m = model else { return }
        window?.makeFirstResponder(self)
        if editor != nil { commitEditor(move: nil) }
        let (x, y) = point(event)
        let hit = m.tableHit(x: x, y: y)
        if hit.pos == m.rows.count { beginAddRow(); return }
        guard hit.pos >= 0, hit.pos < m.rows.count, let i = m.rows[hit.pos].index else { return }
        let uid = m.project.tasks[i].uid
        if hit.twisty { m.toggleCollapse(uid); return }
        guard let col = hit.col else { return }
        if event.clickCount >= 2 {
            if col == "id" { m.openInspector() } else { beginEdit(uid: uid, col: col, initial: nil) }
            return
        }
        m.pressCell(uid: uid, col: col, mods: event.keyMods)
        if col == "id" {
            let uids = m.selection.contains(uid) ? m.selectedUids : [uid]
            rowDrag = (uids, uid, convert(event.locationInWindow, from: nil), false, nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m = model, var rd = rowDrag else { return }
        let pt = convert(event.locationInWindow, from: nil)
        lastDragPoint = pt
        if !rd.active {
            if hypot(pt.x - rd.start.x, pt.y - rd.start.y) < 5 { return }
            if !m.outlinePlain {
                m.say(m.view.sort != nil || m.view.group != nil ? "Clear the sort or group first: rows can only be moved in the plain outline." : "Clear the filter or search first: rows can only be moved in the full outline.")
                rowDrag = nil
                return
            }
            rd.active = true
        }
        rd.target = m.rowDropTarget(uids: rd.uids, grabbedUid: rd.grabbed, y: Double(pt.y) / scale, dx: Double(pt.x - rd.start.x) / scale)
        rowDrag = rd
        autoscroll(with: event) // near the top or bottom edge the rows scroll by themselves
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let m = model, let rd = rowDrag else { return }
        rowDrag = nil
        needsDisplay = true
        if rd.active, let t = rd.target { m.dropRows(uids: rd.uids, beforeUid: t.beforeUid, level: t.level) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let m = model, let p = pane else { return nil }
        let (x, y) = point(event)
        let hit = m.tableHit(x: x, y: y)
        guard hit.pos >= 0, hit.pos < m.rows.count, let i = m.rows[hit.pos].index else { return nil }
        let uid = m.project.tasks[i].uid
        if !m.selection.contains(uid) { m.selectOnly(uid) }
        return rowContextMenu(p.state, at: event, in: self)
    }

    // MARK: keyboard

    override func keyDown(with event: NSEvent) {
        guard let m = model else { return }
        if editor != nil { super.keyDown(with: event); return }
        if event.keyCode == 53, rowDrag?.active == true { rowDrag = nil; needsDisplay = true; m.say("Move cancelled.", .info, 1.5); return }
        guard let key = tableKey(event) else { super.keyDown(with: event); return }
        switch m.key(key, event.keyMods) {
        case .unhandled:
            if case .delete = key, let l = m.linkSel { m.deleteLink(l); return }
            super.keyDown(with: event)
        case .handled: break
        case .beginEdit(let uid, let col, let initial): beginEdit(uid: uid, col: col, initial: initial)
        }
    }

    func tableKey(_ e: NSEvent) -> TableKey? {
        switch e.keyCode {
        case 125: return .down
        case 126: return .up
        case 124: return .right
        case 123: return .left
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 48: return .tab
        case 36, 76: return .enter
        case 120: return .f2
        case 53: return .escape
        case 51, 117: return .delete
        default:
            guard let ch = e.charactersIgnoringModifiers, ch.count == 1, let u = ch.unicodeScalars.first, u.value >= 32, u.value != 127 else { return nil }
            return .character(e.modifierFlags.contains(.command) ? ch : (e.characters ?? ch))
        }
    }

    // MARK: editing in place

    private func cellRect(uid: Int, col: String) -> NSRect? {
        guard let m = model, let i = m.index(of: uid), let pos = m.posOf[i] else { return nil }
        let g = TableGeometry(m.columns)
        guard let ci = g.ids.firstIndex(of: col) else { return nil }
        let s = scale
        return NSRect(x: g.lefts[ci] * s, y: Double(pos) * ROW_H * s, width: g.widths[ci] * s, height: ROW_H * s)
    }

    func beginEdit(uid: Int, col: String, initial: String?) {
        guard let m = model, let p = pane else { return }
        if editor != nil { commitEditor(move: nil) }
        p.scrollTo(uid: uid)
        guard let raw = m.beginEdit(uid: uid, col: col), let colDef = m.column(col), let e = colDef.edit, let ctx = m.context(uid) else { return }
        guard let rect = cellRect(uid: uid, col: col) else { return }
        editUid = uid; editCol = col; editOriginal = raw; adding = false
        switch e.kind {
        case .tags:
            showTagsPopover(uids: [uid], at: rect)
            return
        case .select:
            let pop = NSPopUpButton(frame: NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 150), height: rect.height), pullsDown: false)
            let opts = e.options(m.project)
            for o in opts { pop.addItem(withTitle: o.label.isEmpty ? " " : o.label); pop.lastItem?.representedObject = o.value }
            if let k = opts.firstIndex(where: { $0.value == raw }) { pop.selectItem(at: k) }
            pop.target = self
            pop.action = #selector(selectChanged(_:))
            addSubview(pop)
            editor = pop
            window?.makeFirstResponder(pop)
            _ = ctx
        case .text, .date:
            let f = NSTextField(frame: NSRect(x: rect.minX, y: rect.minY, width: max(rect.width, 60 * scale), height: rect.height))
            f.stringValue = initial ?? raw
            f.font = Fonts.nsFont(p.state.font, size: 13 * scale)
            f.delegate = self
            f.focusRingType = .exterior
            f.isBezeled = true
            f.bezelStyle = .squareBezel
            if let hint = e.hint { f.toolTip = hint }
            addSubview(f)
            editor = f
            window?.makeFirstResponder(f)
            if let ed = f.currentEditor() {
                if initial == nil { ed.selectAll(nil) } else { ed.selectedRange = NSRange(location: (f.stringValue as NSString).length, length: 0) }
            }
            if e.kind == .date && initial == nil { showDatePicker(for: f, uid: uid, clearable: e.clearable) }
        }
    }

    @objc private func selectChanged(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? String else { return }
        commitValue(v, move: nil)
    }

    /// The row at the bottom: typing a name there adds a task (Enter adds and opens the next one).
    func beginAddRow() {
        guard let m = model, let p = pane else { return }
        let g = TableGeometry(m.columns)
        let ci = g.ids.firstIndex(of: "name") ?? 0
        let s = scale
        let f = NSTextField(frame: NSRect(x: g.lefts[ci] * s, y: Double(m.rows.count) * ROW_H * s, width: max(g.widths[ci], 200) * s, height: ROW_H * s))
        f.placeholderString = "New task name"
        f.font = Fonts.nsFont(p.state.font, size: 13 * s)
        f.delegate = self
        addSubview(f)
        editor = f
        adding = true
        window?.makeFirstResponder(f)
    }

    private func closeEditor() {
        datePopover?.close()
        datePopover = nil
        editor?.removeFromSuperview()
        editor = nil
        adding = false
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// Apply the typed value; the editor stays open with the message when the value is not accepted.
    func commitEditor(move: TableKey?) {
        guard let ed = editor, !busy else { return }
        if adding {
            let name = (ed as? NSTextField)?.stringValue ?? ""
            closeEditor()
            if let m = model, m.addTaskAtEnd(name: name) != nil, move == .down {
                DispatchQueue.main.async { self.beginAddRow() }
            }
            return
        }
        if let pop = ed as? NSPopUpButton {
            commitValue(pop.selectedItem?.representedObject as? String ?? editOriginal, move: move)
        } else if let f = ed as? NSTextField {
            commitValue(f.stringValue, move: move)
        }
    }

    private func commitValue(_ text: String, move: TableKey?) {
        guard let m = model, let uid = editUid else { closeEditor(); return }
        busy = true
        defer { busy = false }
        let isSelect = editor is NSPopUpButton
        let ok = m.commitEdit(uid: uid, col: editCol, text: text, original: isSelect ? nil : editOriginal)
        if !ok {
            if let f = editor as? NSTextField { window?.makeFirstResponder(f); f.currentEditor()?.selectAll(nil) }
            return
        }
        let col = editCol
        closeEditor()
        if col != "wbs", let mv = move { m.moveAfterEdit(uid: uid, col: col, move: mv) }
    }

    // NSTextFieldDelegate: Enter, Tab and Esc in the editor
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        switch sel {
        case #selector(NSResponder.insertNewline(_:)): commitEditor(move: shift ? .up : .down); return true
        case #selector(NSResponder.insertTab(_:)): commitEditor(move: .right); return true
        case #selector(NSResponder.insertBacktab(_:)): commitEditor(move: .left); return true
        case #selector(NSResponder.cancelOperation(_:)): closeEditor(); return true
        case #selector(NSResponder.moveDown(_:)):
            if editCol != "", let e = model?.column(editCol)?.edit, e.kind == .date, let f = editor as? NSTextField, let uid = editUid, datePopover == nil {
                showDatePicker(for: f, uid: uid, clearable: e.clearable); return true
            }
            return false
        default: return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // leaving the field (clicking elsewhere) applies what was typed, like the JavaScript app's blur
        guard editor != nil, !busy, datePopover == nil else { return }
        let reason = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if reason == NSTextMovement.other.rawValue { commitEditor(move: nil) }
    }

    // MARK: popups

    private func showDatePicker(for field: NSTextField, uid: Int, clearable: Bool) {
        guard let m = model, let p = pane, let i = m.index(of: uid) else { return }
        let cal = calendarOf(m.project, m.project.tasks[i])
        let current = m.fmt.parseStampText(field.stringValue)?.dn
        let pop = NSPopover()
        pop.behavior = .transient
        let view = DatePickerView(value: current, today: m.env.today(), cal: cal, sundayFirst: m.project.settings.pickerStartsSunday,
                                  theme: p.theme, clearable: clearable,
                                  onPick: { [weak self] dn in
                                      field.stringValue = m.fmt.datePlain(toISO(dn))
                                      self?.datePopover?.close()
                                      self?.datePopover = nil
                                      self?.commitEditor(move: nil)
                                  },
                                  onClear: { [weak self] in
                                      field.stringValue = ""
                                      self?.datePopover?.close()
                                      self?.datePopover = nil
                                      self?.commitEditor(move: nil)
                                  })
        pop.contentViewController = NSHostingController(rootView: view)
        pop.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
        datePopover = pop
    }

    func showTagsPopover(uids: [Int], at rect: NSRect) {
        guard let p = pane else { return }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: TagsPopoverView(uids: uids).environment(p.state))
        pop.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }
}

/// Right-click on rows or bars (gantt.js rowContextMenu).
@MainActor
func rowContextMenu(_ state: AppState, at event: NSEvent, in view: NSView) -> NSMenu {
    let m = state.model
    let n = m.selectedUids.count
    let s = m.sched
    let idx = m.selectedIndexes
    let anySummary = idx.contains { s.tasks[$0].isSummary }
    let leaves = idx.filter { !s.tasks[$0].isSummary }
    let allInactive = !leaves.isEmpty && leaves.allSatisfy { s.tasks[$0].inactive }
    let allManual = !idx.isEmpty && idx.allSatisfy { m.project.tasks[$0].mode == "manual" || s.tasks[$0].isSummary }
    let what = m.selMode == .rows ? (n > 1 ? "\(n) rows" : "row") : "cells"
    let menu = NSMenu()
    func add(_ t: String, _ enabled: Bool = true, checked: Bool = false, _ f: @escaping () -> Void) {
        let it = ClosureMenuItem(t, f)
        it.isEnabled = enabled
        if !enabled { it.action = nil }
        it.state = checked ? .on : .off
        menu.addItem(it)
    }
    add("Cut \(what)") { state.tableCopy(cut: true) }
    add("Copy \(what)") { state.tableCopy(cut: false) }
    add("Paste") { state.tablePaste() }
    menu.addItem(.separator())
    add(n > 1 ? "Insert \(n) rows above" : "Insert row above") { m.insertRows(below: false) }
    add(n > 1 ? "Insert \(n) rows below" : "Insert row below") { m.insertRows(below: true) }
    add("Insert several rows…") { state.sheet = .insertSeveral }
    add(n > 1 ? "Delete \(n) entire rows" : "Delete entire row") { m.deleteSelected() }
    menu.addItem(.separator())
    add("Insert summary task below") { m.addTask(summary: true) }
    add("Indent") { m.indent() }
    add("Outdent") { m.outdent() }
    add("Move up") { m.moveUp() }
    add("Move down") { m.moveDown() }
    menu.addItem(.separator())
    add("Link selected tasks (Finish-to-Start)", n >= 2) { m.linkSelected("FS") }
    add("Unlink selected tasks") { m.unlinkSelected() }
    menu.addItem(.separator())
    add("Toggle milestone", !leaves.isEmpty) { m.toggleMilestone() }
    add(allManual ? "Schedule automatically" : "Schedule manually", !(anySummary && idx.count == 1)) { m.setSelectedMode(allManual ? "auto" : "manual") }
    add("Tags…") {
        let uids = m.selectedUids
        let pt = view.convert(event.locationInWindow, from: nil)
        if let tb = view as? TableBodyView { tb.showTagsPopover(uids: uids, at: NSRect(x: pt.x, y: pt.y, width: 1, height: 1)) }
        else if let cb = view as? ChartBodyView { cb.showTags(uids: uids, at: pt) }
    }
    menu.addItem(.separator())
    add("Bold", checked: idx.allSatisfy { m.project.tasks[$0].nameBold }) { m.toggleSelectedNameStyle("nameBold") }
    add("Italic", checked: idx.allSatisfy { m.project.tasks[$0].nameItalic }) { m.toggleSelectedNameStyle("nameItalic") }
    add("Underline", checked: idx.allSatisfy { m.project.tasks[$0].nameUnderline }) { m.toggleSelectedNameStyle("nameUnderline") }
    menu.addItem(.separator())
    add(allInactive ? "Make active" : "Make inactive", !leaves.isEmpty) { m.setSelectedFlag("inactive", !allInactive) }
    let onTL = idx.allSatisfy { s.tasks[$0].onTimeline }, hidden = idx.allSatisfy { s.tasks[$0].hideBar }, rolled = idx.allSatisfy { s.tasks[$0].rollup }
    add("Display on Timeline", checked: onTL) { m.setSelectedFlag("onTimeline", !onTL) }
    add("Hide task bar", checked: hidden) { m.setSelectedFlag("hideBar", !hidden) }
    add("Roll up Gantt bar to summary", !leaves.isEmpty, checked: rolled) { m.setSelectedFlag("rollup", !rolled) }
    menu.addItem(.separator())
    add("Task information") { m.openInspector() }
    return menu
}
