// A self-check the build machine runs: with GP_SMOKE_DIR set, the app opens GP_SMOKE_FILE, shows every tab, saves a picture
// of the window for each (drawn by AppKit, no screen-recording permission needed), exports the Gantt PDF and a network PNG,
// writes a report and quits. Not used in normal use.

import AppKit
import PDFKit
import SwiftUI
import GanttpathCore
import GanttpathModel

@MainActor
enum SmokeTest {
    static var dir: String? { ProcessInfo.processInfo.environment["GP_SMOKE_DIR"] }

    static func run(_ state: AppState) {
        guard let dir = dir else { return }
        var report: [String] = []
        func log(_ s: String) { report.append(s); print("SMOKE: \(s)") }
        func finish() {
            log("quitting")
            try? report.joined(separator: "\n").write(toFile: dir + "/report.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                print("SMOKE: the app did not quit within 10 s of being asked; exiting")
                exit(3)
            }
            NSApp.terminate(nil)
        }
        state.sheet = nil
        if let f = ProcessInfo.processInfo.environment["GP_SMOKE_FILE"] {
            log("open \(f): \(state.open(f))")
            state.sheet = nil
        }
        let m = state.model
        // toolbar items: 0-4 row-1 groups, 5 search/filter group, 6 right-hand group
        log("toolbar rows (expected [[0, 1, 2, 3, 4, 6], [5]] when wide enough): \(ToolbarRows.lastRows), \(ToolbarRows.lastInfo), gantt pane width \(Int(state.gantt?.view?.frame.width ?? -1)), window width \(Int(NSApp.windows.first { $0.isVisible }?.frame.width ?? 0))")
        log("tasks \(m.project.tasks.count), conflicts \(m.sched.conflictCount), finish \(m.sched.projectFinish ?? "-")")
        var madeConflict = false
        var savedFrame: NSRect? = nil
        let steps: [(String, () -> Void)] = [
            ("gantt", { m.tab = .gantt; m.selectOnly(m.project.tasks.count > 2 ? m.project.tasks[2].uid : nil) }),
            ("inspector", { m.inspectorOpen = true }),
            ("conflicts", { m.inspectorOpen = false; m.conflictsOpen = true }),
            ("row-tooltip", {
                m.conflictsOpen = false; m.tab = .gantt
                if m.sched.conflicts.isEmpty, let i = m.project.tasks.indices.last(where: { !m.sched.tasks[$0].isSummary && m.project.tasks[$0].level > 1 }),
                   let start = m.sched.projectStart {
                    // make a conflict to look at (undone in the next step)
                    let uid = m.project.tasks[i].uid
                    _ = m.run("Deadline") { d, _ in try setDeadline(&d, uid, start) }
                    madeConflict = true
                    log("made a deadline conflict on row \(i + 1): conflicts now \(m.sched.conflicts.count)")
                }
            }),
            ("error-box", {
                if madeConflict { m.undo(); madeConflict = false }
                m.say("Smoke test: an error message that must stay until OK is pressed.", .error) }),
            ("message-log", {
                // press "Show Message Log" on the box
                if let a = state.errorAlert, let parent = a.window.sheetParent { parent.endSheet(a.window, returnCode: .alertSecondButtonReturn) }
            }),
            ("narrow-toolbar", {
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
                    savedFrame = w.frame
                    w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: 700, height: w.frame.height), display: true)
                }
            }),
            ("restore-width", {
                if let f = savedFrame, let w = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) { w.setFrame(f, display: true) }
            }),
            ("network", { m.conflictsOpen = false; m.tab = .network }),
            ("timeline", { m.tab = .timeline }),
            ("cpm", { m.tab = .cpm }),
            ("scurve", { m.tab = .scurve }),
            ("zoom-scroll", { m.tab = .gantt; state.gantt?.view?.setZoom(48) }),
            ("dark", { m.tab = .gantt; state.updatePrefs { $0.theme = "dark" }; state.applyAppearance() }),
            ("settings-dialog", { state.updatePrefs { $0.theme = "light" }; state.applyAppearance(); state.sheet = .settings }),
            ("calendars-dialog", { state.sheet = .calendars }),
        ]
        func step(_ i: Int) {
            if i >= steps.count {
                state.sheet = nil
                // exports through the Mac painting code
                let pages = ganttPrintPages(m.project, m.sched, state.printContext)
                if let pdf = ImageExport.pdf(pages.map { $0.drawing }, title: m.project.name) {
                    try? pdf.write(to: URL(fileURLWithPath: dir + "/gantt.pdf"))
                    log("pdf pages \(pages.count), bytes \(pdf.count)")
                    if let doc = PDFDocument(data: pdf) {
                        let text = doc.string ?? ""
                        let names = m.project.tasks.prefix(5).map { $0.name }
                        log("pdf read back: \(doc.pageCount) page(s), size \(doc.page(at: 0).map { "\(Int($0.bounds(for: .mediaBox).width))x\(Int($0.bounds(for: .mediaBox).height)) pt" } ?? "-"), task names found \(names.filter { text.contains($0) }.count) of \(names.count), footer page number \(text.contains("Page 1 of"))")
                    }
                } else { log("pdf FAILED") }
                m.tab = .network
                if let d = state.diagramForExport, let png = ImageExport.png(d, scale: 2) {
                    try? png.write(to: URL(fileURLWithPath: dir + "/network.png"))
                    log("png bytes \(png.count)")
                } else { log("png FAILED") }
                // an edit, undo and a save through the model
                m.selectOnly(m.project.tasks.last?.uid)
                let n = m.project.tasks.count
                m.addTask(name: "Smoke test task")
                log("add task: \(m.project.tasks.count == n + 1)")
                m.undo()
                log("undo: \(m.project.tasks.count == n)")
                finish()
                return
            }
            steps[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if steps[i].0 == "zoom-scroll" {
                    // first without clipping (as the first build drew): the check must notice; then as built
                    if let h = state.gantt?.view?.chartHeader {
                        ChartHeaderView.testWithoutClipping = true; h.clipsToBounds = false
                        log("check sees the old overlap (expected false): \(tableHeaderStaysPut(state))")
                        ChartHeaderView.testWithoutClipping = false; h.clipsToBounds = true
                        state.gantt?.view?.scrollToStart()
                    }
                    log("table header unchanged while the chart scrolls (expected true): \(tableHeaderStaysPut(state))")
                }
                if steps[i].0 == "row-tooltip", let pane = state.gantt?.view {
                    pane.relayout()
                    let rows = pane.issueTipRows
                    let expected = m.rows.indices.filter { m.issueTip(row: $0) != nil }
                    log("rows with a conflict tooltip: \(rows.count), rows with conflicts: \(expected.count), same rows: \(rows == expected)")
                    if let pos = rows.first {
                        let pt = NSPoint(x: 40, y: (Double(pos) + 0.5) * ROW_H * pane.scale)
                        let text = pane.view(pane.tableBody, stringForToolTip: 0, point: pt, userData: nil)
                        log("tooltip of row \(pos + 1) (table): \(text.replacingOccurrences(of: "\n", with: " | "))")
                        let text2 = pane.view(pane.chartBody, stringForToolTip: 0, point: pt, userData: nil)
                        log("chart tooltip same as table: \(text2 == text && !text.isEmpty)")
                    }
                    if let clean = m.rows.indices.first(where: { !rows.contains($0) && m.rows[$0].index != nil }) {
                        let pt = NSPoint(x: 40, y: (Double(clean) + 0.5) * ROW_H * pane.scale)
                        log("row without conflict has no tooltip text: \(pane.view(pane.tableBody, stringForToolTip: 0, point: pt, userData: nil).isEmpty)")
                    }
                }
                if steps[i].0 == "narrow-toolbar" {
                    NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }?.contentView?.layoutSubtreeIfNeeded()
                    log("toolbar rows in a narrow window (right-hand group 6 last, on the search row or its own): \(ToolbarRows.lastRows), \(ToolbarRows.lastInfo), last width offered \(ToolbarRows.lastProposed), gantt pane width \(Int(state.gantt?.view?.frame.width ?? -1)), window width \(Int(NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }?.frame.width ?? 0))")
                }
                if steps[i].0 == "restore-width" {
                    log("toolbar layout calls around the resize: \(ToolbarRows.history.suffix(16))")
                    log("after widening again: toolbar last width offered \(ToolbarRows.lastProposed), rows \(ToolbarRows.lastRows), gantt pane width \(Int(state.gantt?.view?.frame.width ?? -1)), status bar width \(StatusBar.lastWidth); toolbar follows the window (offered width = status bar width - 20 px padding): \(ToolbarRows.lastProposed == StatusBar.lastWidth - 20)")
                }
                if steps[i].0 == "network" {
                    let w = NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }
                    w?.contentView?.layoutSubtreeIfNeeded()
                    w?.displayIfNeeded()
                    log("toolbar rows after restoring the width: \(ToolbarRows.lastRows), \(ToolbarRows.lastInfo), window \(w.map { "\($0.frame)" } ?? "-"), content \(w?.contentView.map { "\($0.frame)" } ?? "-")")
                }
                if steps[i].0 == "timeline" {
                    log("toolbar rows a step later: \(ToolbarRows.lastRows), \(ToolbarRows.lastInfo), last width offered \(ToolbarRows.lastProposed), gantt pane width \(Int(state.gantt?.view?.frame.width ?? -1))")
                }
                if steps[i].0 == "error-box" {
                    log("error box showing: \(state.errorAlert != nil), as a sheet: \(state.errorAlert?.window.sheetParent != nil), no fading toast: \(m.toast == nil), in log: \(m.log.last?.kind == .error)")
                }
                if steps[i].0 == "message-log" {
                    log("box closed: \(state.errorAlert == nil && m.pendingError == nil), message log open: \(m.conflictsOpen && m.issuesTab == .messages), entries \(m.log.count), errors \(m.errorCount)")
                }
                let path = dir + "/\(String(format: "%02d", i + 1))-\(steps[i].0).png"
                let ok = snapshot(path)
                log("snapshot \(steps[i].0): \(ok) \(ok ? analyse(path, state) : "")")
                step(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { step(0) }
    }

    /// What a picture holds: how much is not background, and how many pixels have the task, critical and conflict colours.
    static func analyse(_ path: String, _ state: AppState) -> String {
        guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "(unreadable)" }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return "(no bitmap)" }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func near(_ i: Int, _ c: RGBA) -> Bool {
            abs(Double(px[i]) - c.r * 255) < 14 && abs(Double(px[i + 1]) - c.g * 255) < 14 && abs(Double(px[i + 2]) - c.b * 255) < 14
        }
        let t = state.theme
        let bg0 = (px[0], px[1], px[2])
        var other = 0, task = 0, crit = 0, conflict = 0
        var colours = Set<UInt32>()
        var i = 0
        while i < w * h * 4 {
            if (px[i], px[i + 1], px[i + 2]) != bg0 { other += 1 }
            if let c = t.c["task"], near(i, c) { task += 1 }
            if let c = t.c["critical"], near(i, c) { crit += 1 }
            if let c = t.c["conflict"], near(i, c) { conflict += 1 }
            if i % 64 == 0 { colours.insert(UInt32(px[i]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i + 2])) }
            i += 4
        }
        return "\(w)x\(h), corner pixel \(bg0.0),\(bg0.1),\(bg0.2), not background \(other * 100 / max(1, w * h))%, colours \(colours.count), task-colour px \(task), critical px \(crit), conflict px \(conflict)"
    }

    /// Nothing of the chart may be drawn over the task table: the table's heading and first rows must look the same before and
    /// after the chart is scrolled sideways.
    static func tableHeaderStaysPut(_ state: AppState) -> Bool {
        guard let pane = state.gantt?.view else { return false }
        pane.layoutSubtreeIfNeeded()
        let region = NSRect(x: 0, y: 0, width: pane.tableScroll.frame.width, height: min(pane.bounds.height, pane.tableHeader.frame.height + 120))
        func grab() -> Data? {
            guard let rep = pane.bitmapImageRepForCachingDisplay(in: region) else { return nil }
            pane.cacheDisplay(in: region, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        let before = grab()
        var o = pane.chartScroll.contentView.bounds.origin
        o.x += 1500
        pane.chartScroll.contentView.scroll(to: o)
        pane.chartScroll.reflectScrolledClipView(pane.chartScroll.contentView)
        pane.displayIfNeeded()
        let after = grab()
        return before != nil && before == after
    }

    /// A picture of the key window (and of a sheet over it), drawn by AppKit.
    static func snapshot(_ path: String) -> Bool {
        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }) ?? NSApp.keyWindow,
              let view = win.contentView?.superview ?? win.contentView else { return false }
        var ok = save(view, path)
        if let sheet = win.attachedSheet, let sv = sheet.contentView {
            ok = save(sv, path.replacingOccurrences(of: ".png", with: "-sheet.png")) && ok
        }
        return ok
    }

    static func save(_ view: NSView, _ path: String) -> Bool {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
