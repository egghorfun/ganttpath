// `gpcli render <project.gpath|.json> <out-dir>`: every view and printout of a project as SVG files, for looking at them
// without the Mac app (the app paints the same drawings).

import Foundation
import GanttpathCore

func writeSVG(_ d: Drawing, _ path: String) {
    _ = FileManager.default.createFile(atPath: path, contents: SVGWriter.svg(d).data(using: .utf8))
}

func renderAll(_ file: String, _ outDir: String) throws {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    var p = try loadProjectJSON(readText(file))
    let s = scheduleAndApply(&p)
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let today = parseISO("2026-09-26")!
    for (name, theme) in [("light", Theme.light), ("dark", Theme.dark)] {
        let rows = buildRows(p, s).rows
        var o = ganttOptions(for: p, today: today)
        o.showBaseline = p.tasks.contains { $0.baselines[0] != nil } ? 0 : -1
        o.progressLine = o.statusDn != nil
        let lay = ganttLayout(project: p, sched: s, rows: rows, px: 12, viewWidth: 1200, opts: o)
        let head = ganttHeader(originDn: lay.originDn, endDn: lay.endDn, px: 12, mondayFirst: p.settings.weekStartsMonday, nonWorking: { !projectCalendar(p).isWorking($0) }, theme: theme)
        let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: rows.count - 1, px: 12, originDn: lay.originDn, endDn: lay.endDn,
                             posOf: positions(rows), opts: o, theme: theme, nonWorking: { !projectCalendar(p).isWorking($0) })
        writeSVG(Drawing(width: head.width, height: head.height + body.drawing.height, background: theme.bg,
                         items: head.items + [.group(dx: 0, dy: HEADER_H, scale: 1, body.drawing.items)]), "\(outDir)/gantt-\(name).svg")
        writeSVG(networkDrawing(p, s, layout: layoutNetwork(p, s), theme: theme).drawing, "\(outDir)/network-\(name).svg")
        if let tl = timelineDrawing(p, s, theme: theme, today: today) { writeSVG(tl.drawing, "\(outDir)/timeline-\(name).svg") }
        let data = computeSCurve(p, s, baseline: 0, statusDate: p.settings.statusDate)
        if let (sc, _) = scurveDrawing(p, data, baseline: 0, theme: theme, today: today) { writeSVG(sc.drawing, "\(outDir)/scurve-\(name).svg") }
    }
    var ctx = PrintContext()
    ctx.now = now
    ctx.timeZone = TimeZone(identifier: "UTC")!
    ctx.gantt = ganttOptions(for: p, today: today)
    for paper in ["A4", "A3"] {
        ctx.page = PageSettings(paper: paper)
        for (i, pg) in ganttPrintPages(p, s, ctx).enumerated() { writeSVG(pg.drawing, "\(outDir)/print-\(paper)-\(i + 1).svg") }
    }
    ctx.page = PageSettings(paper: "A4")
    for (i, pg) in cpmPrintPages(p, s, CpmState(), ctx).enumerated() { writeSVG(pg.drawing, "\(outDir)/cpm-A4-\(i + 1).svg") }
    for key in ["critical", "late", "slipping", "milestones"] {
        for (i, pg) in reportPrintPages(key, p, s, ctx, today: today).enumerated() { writeSVG(pg.drawing, "\(outDir)/report-\(key)-\(i + 1).svg") }
    }
    let net = networkDrawing(p, s, layout: layoutNetwork(p, s), theme: .light)
    writeSVG(diagramPrintPage(p, s, net.drawing, ctx).drawing, "\(outDir)/network-A4.svg")
    print((try? FileManager.default.contentsOfDirectory(atPath: outDir).sorted().joined(separator: "\n")) ?? "")
}
