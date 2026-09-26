// Saving, autosave, opening and importing, preferences, templates, and dragging on the chart.

import Foundation
import Testing
@testable import GanttpathModel
@testable import GanttpathCore

@MainActor
@Suite struct FileTests {
    @Test func saveCreatesDatedVersionsAndAutosaveOnlyWhenChanged() throws {
        let (m, store, dir) = makeModel()
        #expect(m.dirty)
        let p1 = try m.save(prefs: store)
        #expect(!m.dirty && m.file.path == p1 && FileManager.default.fileExists(atPath: p1))
        #expect(m.saveStatusText.hasPrefix("Saved "))
        #expect(store.prefs.recents.first == p1)
        #expect(m.autosaveTick(prefs: store) == nil, "nothing changed: no autosave")
        m.selectOnly(m.uid(3))
        m.toggleMilestone()
        let a = try #require(m.autosaveTick(prefs: store))
        #expect(a.contains("/\(AUTOSAVE_DIR)/"))
        #expect(m.saveStatusText.hasPrefix("Autosaved "))
        #expect(m.autosaveTick(prefs: store) == nil, "no second autosave for the same revision")
        #expect(m.dirty, "an autosave does not count as a save")
        let versions = m.versions(prefs: store)
        #expect(versions.count == 2)
        // compare the saved version with the open project
        let (cmp, _, lb) = try m.compare([p1], versions: versions)
        #expect(lb == "the open project" && cmp.summary.changed >= 1)
        _ = dir
    }

    @Test func openingAFileAndAnImport() throws {
        let (m, store, dir) = makeModel()
        let path = try m.save(prefs: store)
        let (m2, store2, _) = makeModel(tasks: false)
        #expect(m2.open(path: path, prefs: store2))
        #expect(m2.project.tasks.count == m.project.tasks.count && !m2.dirty)
        #expect(m2.file.folder == (path as NSString).deletingLastPathComponent)
        #expect(m2.file.name == "Clip")
        // an MS Project XML export opens as an import (unsaved, with a report)
        let xml = dir + "/Clip.xml"
        m.export("xml", to: xml)
        #expect(m2.open(path: xml, prefs: store2))
        #expect(m2.dirty && m2.importReport != nil)
        #expect(!m2.open(path: dir + "/missing.gpath"))
        #expect(m2.log.last!.kind == .error)
    }

    @Test func autosaveFolderBelongsToItsProjectFolder() {
        #expect(DocumentModel.projectFolder(of: "/a/b/Autosaves/x.gpath") == "/a/b")
        #expect(DocumentModel.projectFolder(of: "/a/b/x.gpath") == "/a/b")
    }

    @Test func prefsRoundTripAndKeepUnknownKeys() throws {
        let dir = tempDir()
        let file = dir + "/preferences.json"
        _ = FileManager.default.createFile(atPath: file, contents: ##"{"folder":"/x","zoomPercent":125,"fontFamily":"georgia","someFutureKey":[1,2],"colors":{"light":{"task":"#FF0000"}},"pageSettings":{"paper":"A9","marginMM":1}}"##.data(using: .utf8))
        let s = PrefsStore(file: file, defaultFolder: "/default")
        #expect(s.prefs.folder == "/x" && s.prefs.zoomPercent == 125 && s.prefs.fontFamily == "georgia")
        #expect(s.prefs.pageSettings == PageSettings(paper: "A4", marginMM: DEFAULT_MARGIN_MM), "bad page settings fall back to the defaults")
        #expect(s.prefs.theme(dark: false).cHex["task"] == "#FF0000")
        s.update { $0.remember("/f1"); $0.remember("/f2"); $0.remember("/f1") }
        let again = PrefsStore(file: file, defaultFolder: "/default")
        #expect(again.prefs.recents == ["/f1", "/f2"])
        #expect(again.prefs.extra["someFutureKey"] != nil)
        let fresh = PrefsStore(file: dir + "/none.json", defaultFolder: "/default")
        #expect(fresh.prefs.folder == "/default" && fresh.prefs.fontFamily == "system")
    }

    @Test func templatesSaveAndInsert() {
        let (m, _, _) = makeModel()
        m.saveAsTemplate(name: "Mine")
        let all = m.templates()
        #expect(all.contains { $0.template.name == "Mine" && $0.file != nil })
        let n = m.t.count
        m.insertTemplate(BUILTIN_TEMPLATES[1])
        #expect(m.t.count == n + 1)
    }

    @Test func newProjectWithBuiltInHolidays() async throws {
        let prop = await holidayProposal(country: "SG", years: [2026], download: false, http: nil)
        #expect(!prop.bundled.items.isEmpty && prop.downloaded == nil && prop.error == nil)
        let p = try makeNewProject(name: "  ", startDn: parseISO("2026-10-05")!, country: "SG", dateFormat: "DD/MM/YYYY", holidays: prop.bundled, template: nil)
        #expect(p.name == "New project" && p.settings.dateFormat == "DD/MM/YYYY" && !p.calendars[0].exceptions.isEmpty)
        #expect(nextMonday(parseISO("2026-09-21")!) == parseISO("2026-09-28")!) // a Monday gives the next one
        #expect(nextMonday(parseISO("2026-09-20")!) == parseISO("2026-09-21")!) // a Sunday gives the day after
    }
}

@MainActor
@Suite struct ChartTests {
    func layout(_ m: DocumentModel) -> (ChartLayout, GanttHit) {
        let l = m.chartLayout(viewWidth: 1200, previous: nil)
        let body = ganttBody(project: m.project, sched: m.sched, rows: m.rows, first: 0, last: m.rows.count - 1, px: m.px,
                             originDn: l.originDn, endDn: l.endDn, posOf: m.posOf, opts: m.ganttOptions, theme: .light)
        return (l, body.hits)
    }

    @Test func zoomStepsAndFit() {
        let (m, _, _) = makeModel()
        #expect(m.zoomPercentText == "100%")
        m.setZoom(m.zoomStep(1)); #expect(m.px == 16)
        m.setZoom(m.zoomStep(-1)); #expect(m.px == 12)
        m.setZoom(10)
        #expect(m.zoomStep(-1) == 8 && m.zoomStep(1) == 16) // as in the JavaScript app: from between two steps, zooming in skips the next one
        let f = m.fitPx(viewWidth: 1000)!
        #expect(f >= 1.5 && f <= 48)
    }

    @Test func hitTestingBarsHandlesAndEmptyRows() {
        let (m, _, _) = makeModel()
        let (l, hits) = layout(m)
        let b = hits.bars.first { $0.kind == .task && $0.x2 - $0.x1 > 30 }!
        let mid = b.y + ROW_H / 2
        #expect(m.hitTest(x: (b.x1 + b.x2) / 2, y: mid, layout: l, hits: hits) == .bar(uid: b.uid, kind: .task))
        #expect(m.hitTest(x: b.x2 - 2, y: b.y + 8, layout: l, hits: hits) == .resizeHandle(uid: b.uid))
        #expect(m.hitTest(x: b.x2 + 10, y: mid, layout: l, hits: hits) == .linkHandle(uid: b.uid, end: "f"))
        if case .empty = m.hitTest(x: l.width - 2, y: mid, layout: l, hits: hits) {} else { Issue.record("far right of a row is empty") }
        m.pressChart(.bar(uid: b.uid, kind: .task), mods: [])
        #expect(m.selection == [b.uid])
    }

    @Test func draggingMovesResizesSetsProgressAndLinks() {
        let (m, _, _) = makeModel()
        let (l, hits) = layout(m)
        let b = hits.bars.first { $0.kind == .task && $0.x2 - $0.x1 > 30 }!
        let i = m.index(of: b.uid)!
        let s0 = parseISO(m.sched.tasks[i].start)!
        let days = m.moveDays(dx: 3 * m.px + 1)
        #expect(days == 3)
        #expect(m.moveTip(uid: b.uid, days: days).hasPrefix("Start no earlier than"))
        m.commitMove(uid: b.uid, days: days)
        #expect(m.project.tasks[i].constraint.type == "SNET" && parseISO(m.project.tasks[i].constraint.date)! == s0 + 3)
        let (_, hits2) = layout(m)
        let b2 = hits2.bars.first { $0.uid == b.uid }!
        let r = m.resizeTarget(uid: b.uid, dx: 7 * m.px)! // one week later: same weekday, five more working days
        #expect(r.tip.hasPrefix("Duration "))
        let d0 = m.project.tasks[i].dur
        m.commitResize(uid: b.uid, finishDn: r.finishDn)
        #expect(m.project.tasks[i].dur > d0)
        let pct = m.pctAt(uid: b.uid, x: b2.x1 + (b2.x2 - b2.x1) * 0.52, layout: l)!
        #expect(pct.truncatingRemainder(dividingBy: 5) == 0)
        m.commitPct(uid: b.uid, pct: 50)
        #expect(m.project.tasks[i].pct == 50)
        // link from the finish of one task to the start of a later one: FS
        let other = hits2.bars.last { $0.kind == .task && $0.uid != b.uid }!
        #expect(m.linkTargetEnd(bar: other, x: other.x1 + 1) == "s")
        m.commitLinkDrag(from: b.uid, fromEnd: "f", to: other.uid, toEnd: "s")
        #expect(m.project.tasks[m.index(of: other.uid)!].preds.contains { $0.uid == b.uid && $0.type == "FS" })
        #expect(m.linkSel == "\(b.uid)>\(other.uid)")
        #expect(linkTypeFor(from: "s", to: "f") == "SF")
    }
}
