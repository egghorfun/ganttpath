// A self-check the build machine runs: with GP_SMOKE_DIR set, the app opens GP_SMOKE_FILE, shows every tab, saves a picture
// of the window for each (drawn by AppKit, no screen-recording permission needed), exports the Gantt PDF and a network PNG,
// writes a report and quits. Not used in normal use.

import AppKit
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
            try? report.joined(separator: "\n").write(toFile: dir + "/report.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        state.sheet = nil
        if let f = ProcessInfo.processInfo.environment["GP_SMOKE_FILE"] {
            log("open \(f): \(state.open(f))")
            state.sheet = nil
        }
        let m = state.model
        log("tasks \(m.project.tasks.count), conflicts \(m.sched.conflictCount), finish \(m.sched.projectFinish ?? "-")")
        let steps: [(String, () -> Void)] = [
            ("gantt", { m.tab = .gantt; m.selectOnly(m.project.tasks.count > 2 ? m.project.tasks[2].uid : nil) }),
            ("inspector", { m.inspectorOpen = true }),
            ("conflicts", { m.inspectorOpen = false; m.conflictsOpen = true }),
            ("network", { m.conflictsOpen = false; m.tab = .network }),
            ("timeline", { m.tab = .timeline }),
            ("cpm", { m.tab = .cpm }),
            ("scurve", { m.tab = .scurve }),
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
                let ok = snapshot(dir + "/\(String(format: "%02d", i + 1))-\(steps[i].0).png")
                log("snapshot \(steps[i].0): \(ok)")
                step(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { step(0) }
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
