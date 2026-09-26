// Helpers for the model tests: a project made the way the JavaScript UI tests make one (New Project with the first template).

import Foundation
import Testing
@testable import GanttpathModel
@testable import GanttpathCore

func tempDir() -> String {
    let d = NSTemporaryDirectory() + "gp-model-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

@MainActor
func makeModel(tasks: Bool = true) -> (DocumentModel, PrefsStore, String) {
    let dir = tempDir()
    let env = AppEnvironment(templatesDir: dir + "/templates", now: { Date(timeIntervalSince1970: 1_790_000_000) }, today: { parseISO("2026-09-21")! })
    let m = DocumentModel(env: env)
    let store = PrefsStore(file: dir + "/preferences.json", defaultFolder: dir + "/Ganttpath")
    m.onPrefsChange = { fn in store.update(fn) }
    if tasks {
        let p = try! makeNewProject(name: "Clip", startDn: parseISO("2026-10-05")!, country: "SG", dateFormat: "DD-MMM-YYYY",
                                    holidays: nil, template: BUILTIN_TEMPLATES[0])
        m.load(p, dirty: true)
    }
    return (m, store, dir)
}

extension DocumentModel {
    func uid(_ row: Int) -> Int { project.tasks[row - 1].uid }
    /// A click on a cell of row `row` (1-based, as the ID column shows).
    func click(_ row: Int, _ col: String, _ mods: KeyMods = []) { pressCell(uid: uid(row), col: col, mods: mods) }
    var t: [Task] { project.tasks }
}
