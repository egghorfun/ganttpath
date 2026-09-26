// The task table drawing: headings, rows, selection and cursor. Set GP_RENDER_DIR to also write the window as an SVG file.

import Foundation
import Testing
@testable import GanttpathModel
@testable import GanttpathCore

@MainActor
@Suite struct TableRenderTests {
    @Test func headingsRowsAndTheAddRow() throws {
        let (m, _, _) = makeModel()
        m.click(3, "duration"); m.click(5, "start", .shift)
        m.headingClicked("duration")
        let head = m.tableHeaderDrawing(theme: .light)
        let titles = placedTexts(head.items, HelveticaMeasurer()).map { $0.text }
        #expect(titles.contains("Task Name") && titles.contains("▲"))
        m.view.sort = nil
        let body = m.tableRowsDrawing(first: 0, last: m.rows.count, theme: .light)
        #expect(body.height == Double(m.rows.count + 1) * ROW_H)
        let texts = placedTexts(body.items, HelveticaMeasurer())
        #expect(texts.contains { $0.text == "Click here and type to add a task…" })
        #expect(texts.contains { $0.text == m.t[0].name })
        // nothing is drawn outside its cell
        let g = TableGeometry(m.columns)
        for t in texts where t.visibleRight > t.visibleLeft { #expect(t.visibleRight <= g.total + 0.5) }
        // a slice starts at its own first row
        let slice = m.tableRowsDrawing(first: 10, last: 12, theme: .dark)
        #expect(slice.height == 3 * ROW_H)
        #expect(m.tableHit(x: 5, y: 2 * ROW_H + 3).pos == 2)
        #expect(m.tableHit(x: 5, y: 3).col == "id")
    }

    @Test func writeTheWindowForLookingAtIt() throws {
        guard let dir = ProcessInfo.processInfo.environment["GP_RENDER_DIR"] else { return }
        let (m, _, _) = makeModel()
        m.setColumnShown("notes", true)
        m.click(3, "name"); m.click(5, "duration", .shift)
        m.selectOnly(m.uid(8)); m.cursorCol = "start"
        m.toggleCollapse(m.uid(20))
        m.linkSel = nil
        for (name, theme) in [("light", Theme.light), ("dark", Theme.dark)] {
            let head = m.tableHeaderDrawing(theme: theme)
            let body = m.tableRowsDrawing(first: 0, last: 30, theme: theme)
            let l = m.chartLayout(viewWidth: 900, previous: nil)
            let ch = ganttHeader(originDn: l.originDn, endDn: l.endDn, px: m.px, mondayFirst: true, nonWorking: { dow($0) == 0 || dow($0) == 6 }, theme: theme)
            let cb = ganttBody(project: m.project, sched: m.sched, rows: m.rows, first: 0, last: min(30, m.rows.count - 1), px: m.px, originDn: l.originDn, endDn: l.endDn,
                               posOf: m.posOf, opts: m.ganttOptions, theme: theme, nonWorking: { dow($0) == 0 || dow($0) == 6 })
            let tw = head.width
            let d = Drawing(width: tw + 4 + 900, height: HEADER_H + 31 * ROW_H, background: theme.bg, items: [
                .clip(x: 0, y: 0, w: tw, h: 2000, head.items + [.group(dx: 0, dy: HEADER_H, scale: 1, body.items)]),
                .clip(x: tw + 4, y: 0, w: 900, h: 2000, [.group(dx: tw + 4, dy: 0, scale: 1, ch.items), .group(dx: tw + 4, dy: HEADER_H, scale: 1, cb.drawing.items)]),
            ])
            try SVGWriter.svg(d).write(toFile: "\(dir)/window-\(name).svg", atomically: true, encoding: .utf8)
        }
    }
}
