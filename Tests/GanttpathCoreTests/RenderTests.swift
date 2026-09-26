// Drawing of the Gantt chart and the other views (platform-neutral part), and the table column definitions.

import Foundation
import Testing
@testable import GanttpathCore

private func sched(_ p: inout Project) -> ScheduleResult { scheduleAndApply(&p) }

/// Every text of a Gantt body, placed with the default measurer.
private func bodyTexts(_ p: Project, _ s: ScheduleResult, px: Double, opts: GanttOptions = GanttOptions(), viewWidth: Double = 800) -> (texts: [PlacedText], width: Double) {
    let rows = buildRows(p, s).rows
    let lay = ganttLayout(project: p, sched: s, rows: rows, px: px, viewWidth: viewWidth, opts: opts)
    let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: rows.count - 1, px: px, originDn: lay.originDn, endDn: lay.endDn,
                         posOf: positions(rows), opts: opts, theme: .light)
    return (placedTexts(body.drawing.items, HelveticaMeasurer()), body.drawing.width)
}

@Suite struct LabelReachTests {
    // Port of test/chartsvg.test.js (1.3.4: "the right side at end of project, the words are cut off").
    func reach(_ names: [String], milestone: Bool = false, conflict: Bool = false, hide: Bool = false, opts: GanttOptions = GanttOptions()) -> Double {
        var p = mk(names.map { TL(dur: milestone ? 0 : 1, name: $0) })
        if hide { p.tasks[0].hideBar = true }
        if conflict { p.tasks[0].constraint = Constraint(type: "MSO", date: "2026-10-10") } // a Saturday: a calendar conflict
        let s = sched(&p)
        if conflict { #expect(s.tasks[0].hasConflict) }
        return maxLabelReach(buildRows(p, s).rows, p, s, parseISO("2026-10-01")!, 12, opts)
    }

    @Test func aLongerNameReachesFurther() {
        #expect(reach(["A much, much longer task name that runs on and on"]) > reach(["A"]))
    }
    @Test func aMilestoneWithANameReachesPastItsPoint() {
        let r = reach(["Final acceptance certificate"], milestone: true)
        #expect(r > 12 * 4 + 12 + 100)
    }
    @Test func labelsOffGiveNoReachWithoutConflicts() {
        var o = GanttOptions(); o.showLabels = false
        #expect(reach(["Some task"], opts: o) == 0)
    }
    @Test func aConflictStillReservesRoomForTheWarningGlyph() {
        var o = GanttOptions(); o.showLabels = false
        let glyphOnly = reach(["Some task"], conflict: true, opts: o)
        let withName = reach(["Some task"], conflict: true)
        #expect(glyphOnly > 0)
        #expect(withName > glyphOnly)
    }
    @Test func aHiddenBarReachesNothing() {
        #expect(reach(["A task nobody can see the bar of, but with a very long name indeed"], hide: true) == 0)
    }
    @Test func noRowsReachNothing() {
        let p = mk([])
        #expect(maxLabelReach([], p, schedule(p), 0, 12, GanttOptions()) == 0)
    }

    /// Checklist step 52: at every zoom level the chart is wide enough for the last task's name (nothing is cut at the right edge).
    @Test func noLabelRunsPastTheChartAtAnyZoom() {
        var p = mk([TL(dur: 20), TL(dur: 5, preds: "1"), TL(dur: 0, preds: "2", name: "Final acceptance certificate issued to the client and signed")])
        p.tasks[1].name = "Commissioning and handover of the complete pump station with all its documentation"
        let s = sched(&p)
        for px in ZOOM_LEVELS {
            let (texts, width) = bodyTexts(p, s, px: px)
            #expect(!texts.isEmpty)
            for t in texts { #expect(t.right <= width, "\(t.text) ends at \(t.right), chart is \(width) wide (px \(px))") }
        }
    }
}

@Suite struct GanttDrawingTests {
    @Test func headerTiersFollowTheZoom() {
        let o = parseISO("2026-01-05")!
        func labels(_ px: Double) -> [String] {
            ganttHeader(originDn: o, endDn: o + 60, px: px, theme: .light).items.compactMap { if case .text(let s, _, _, _, _) = $0 { return s }; return nil }
        }
        #expect(labels(1.5).contains("2026"))               // year / month
        #expect(labels(12).contains("12 Jan"))              // month / week (weeks start on Monday)
        #expect(labels(6).contains("12"))                   // narrower weeks: day number only
        #expect(labels(16).contains("January 2026"))        // month / day
        #expect(labels(32).contains("7 W"))                 // day with its weekday letter
        #expect(zoomPercent(12) == 100)
        #expect(zoomPercent(48) == 400)
    }

    @Test func barsLinksAndStatesOfTheSampleProject() throws {
        let session = samplePumpStation()
        let p = session.project, s = session.sched
        let rows = buildRows(p, s).rows
        let lay = ganttLayout(project: p, sched: s, rows: rows, px: 12, viewWidth: 1000, opts: GanttOptions())
        let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: rows.count - 1, px: 12, originDn: lay.originDn, endDn: lay.endDn,
                             posOf: positions(rows), opts: GanttOptions(), theme: .light)
        #expect(body.hits.bars.count == p.tasks.count)
        #expect(body.hits.links.count == s.links.count)
        #expect(body.drawing.height == Double(rows.count) * ROW_H)
        // every bar lies inside the chart
        for b in body.hits.bars { #expect(b.x1 >= 0 && b.x2 <= body.drawing.width) }
        // the SVG is well-formed XML
        let svg = SVGWriter.svg(body.drawing)
        let root = try parseXml(svg)
        #expect(root.name == "svg")
    }

    @Test func conflictBarsGetTheHatchAndWarningGlyph() {
        var p = mk([TL(dur: 2, c: "MSO", cd: "2026-10-10")])
        let s = sched(&p)
        let rows = buildRows(p, s).rows
        let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: 0, px: 12, originDn: parseISO("2026-09-28")!, endDn: parseISO("2026-11-30")!,
                             posOf: positions(rows), opts: GanttOptions(), theme: .light)
        let hasClip = body.drawing.items.contains { if case .clip = $0 { return true }; return false }
        #expect(hasClip)
        #expect(placedTexts(body.drawing.items, HelveticaMeasurer()).contains { $0.text == "⚠" })
    }

    @Test func progressLineNeedsAStatusDate() {
        var p = mk([TL(dur: 5, pct: 50), TL(dur: 5, preds: "1")])
        p.settings.statusDate = "2026-10-07"
        let s = sched(&p)
        let rows = buildRows(p, s).rows
        var o = ganttOptions(for: p, today: nil); o.progressLine = true
        let body = ganttBody(project: p, sched: s, rows: rows, first: 0, last: 1, px: 12, originDn: parseISO("2026-09-28")!, endDn: parseISO("2026-11-30")!,
                             posOf: positions(rows), opts: o, theme: .light)
        let lines = body.drawing.items.filter { if case .path(_, nil, let st?) = $0 { return st.width == 1.6 }; return false }
        #expect(lines.count == 1)
    }
}

@Suite struct ColumnTests {
    func ctx(_ p: Project, _ i: Int = 0, viewActive: Bool = false) -> CellContext {
        CellContext(project: p, sched: schedule(p), index: i, viewActive: viewActive)
    }
    func col(_ p: Project, _ id: String) -> ColumnDef { allColumns(p, schedule(p)).first { $0.id == id }! }
    func commit(_ p: inout Project, _ id: String, _ text: String, _ i: Int = 0) throws {
        let change = try col(p, id).commit!(text, ctx(p, i))
        try change(&p, schedule(p))
    }

    @Test func typedDurationsDatesAndPercentages() throws {
        var p = mk([TL(dur: 2), TL(dur: 1, preds: "1")])
        try commit(&p, "duration", "6h")
        #expect(p.tasks[0].dur == 360)
        try commit(&p, "duration", "month")
        #expect(p.tasks[0].durUnit == "mo" || p.tasks[0].dur > 360)
        try commit(&p, "pct", "50%", 1)
        #expect(p.tasks[1].pct == 50)
        try commit(&p, "start", "12-Oct-2026", 1)
        #expect(p.tasks[1].constraint.type == "SNET")
        try commit(&p, "start", "", 1)
        #expect(p.tasks[1].constraint.type == "ASAP")
        #expect(throws: ModelError.self) { try commit(&p, "start", "not a date", 1) }
        #expect(throws: ModelError.self) { try commit(&p, "duration", "abc") }
        #expect(throws: ModelError.self) { try commit(&p, "pct", "lots") }
    }

    @Test func errorMessagesSayWhatToType() {
        let p = mk([TL(dur: 2)])
        do { _ = try col(p, "start").commit!("32-Foo-2026", ctx(p)); Issue.record("no error") } catch {
            #expect("\(error)".contains("is not a date. Try 05-Oct-2026, or with a time 05-Oct-2026 13:00."))
        }
    }

    @Test func wbsEditsNeedTheFullOutline() {
        let p = mk([TL(dur: 1), TL(dur: 1)])
        #expect(throws: ModelError.self) { _ = try col(p, "wbs").commit!("1.1", ctx(p, 1, viewActive: true)) }
    }

    @Test func inactiveTasksAreLockedAndWeekdaysCanBeHidden() {
        var p = mk([TL(dur: 1)])
        p.tasks[0].inactive = true
        let c = ctx(p)
        #expect(col(p, "duration").edit!.disabled(c))
        #expect(!col(p, "name").edit!.disabled(c))
        #expect(col(p, "start").text(c).hasPrefix("Mon "))
        p.settings.showWeekday = false
        #expect(col(p, "start").text(ctx(p)) == "05-Oct-2026")
    }

    @Test func visibleColumnsDefaultAndNameCannotBeHidden() {
        let p = mk([TL(dur: 1)])
        #expect(visibleColumns(p, nil, ids: nil).map { $0.id } == DEFAULT_COLUMNS)
        let ids = columnIdsAfter(p, current: nil, "name", shown: false)
        #expect(ids.contains("name"))
        let more = columnIdsAfter(p, current: nil, "deadline", shown: true)
        #expect(more.contains("deadline") && more.firstIndex(of: "deadline")! > more.firstIndex(of: "totalSlack")!)
    }
}

@Suite struct OtherViewTests {
    @Test func networkTimelineAndSCurveOfTheSample() throws {
        let session = samplePumpStation()
        var p = session.project
        let s = session.sched
        let lay = layoutNetwork(p, s)
        let net = networkDrawing(p, s, layout: lay, theme: .light)
        #expect(net.hits.count == lay.nodes.count)
        #expect(try parseXml(SVGWriter.svg(net.drawing)).name == "svg")
        let tl = try #require(timelineDrawing(p, s, theme: .light, today: nil))
        #expect(!tl.hits.isEmpty)
        #expect(try parseXml(SVGWriter.svg(tl.drawing)).name == "svg")
        // no text of the timeline runs past its right edge
        for t in placedTexts(tl.drawing.items, HelveticaMeasurer()) { #expect(t.right <= tl.drawing.width + 0.5, "\(t.text)") }
        try setBaseline(&p, 0, s)
        p.settings.statusDate = s.projectStart
        let s2 = schedule(p)
        let data = computeSCurve(p, s2, baseline: 0, statusDate: p.settings.statusDate)
        let (sc, geo) = try #require(scurveDrawing(p, data, baseline: 0, theme: .dark, today: nil))
        #expect(sc.drawing.width == 980)
        #expect(geo.nearest(geo.ml + 1) == 0)
        #expect(scurveKpis(data).count == 5)
        #expect(scurveTip(p, data, 0).contains("Forecast"))
    }

    @Test func criticalPathRowsSortAndFilter() {
        var p = mk([TL(dur: 3), TL(dur: 1), TL(dur: 2, preds: "1")])
        let s = sched(&p)
        var st = CpmState()
        st.filter = .critical
        #expect(cpmRows(p, s, st).map { $0.index } == [0, 2])
        st.filter = .all; st.sort = "duration"; st.desc = true
        #expect(cpmRows(p, s, st).map { $0.index } == [0, 2, 1])
        #expect(wbsKey("1.10.2") == "00001.00010.00002")
        #expect(cpmKpis(p, s)[0].0 == "2")
    }

    @Test func truncationCountsLikeJavaScript() {
        #expect(truncJS("abcdef", 6) == "abcdef")
        #expect(truncJS("abcdefg", 6) == "abcde…")
        #expect(truncJS("abc", 1) == "a…")
    }
}

@Suite struct PrintTests {
    func bigProject(_ n: Int) -> (Project, ScheduleResult) {
        var list: [TL] = []
        for i in 0..<n { list.append(TL(dur: Double(1 + i % 5), preds: i > 0 && i % 7 != 0 ? "\(i)" : "", level: i % 10 == 0 ? 1 : 2, name: "Task number \(i + 1) with a fairly long descriptive name")) }
        var p = mk(list)
        p.settings.statusDate = "2026-11-02"
        let s = scheduleAndApply(&p)
        return (p, s)
    }
    func texts(_ pg: PrintedPage) -> [PlacedText] { placedTexts(pg.drawing.items, HelveticaMeasurer()) }

    @Test func everyPaperSizePaginatesAndKeepsTextOnThePage() throws {
        let (p, s) = bigProject(120)
        var ctx = PrintContext()
        ctx.timeZone = TimeZone(identifier: "UTC")!
        ctx.now = Date(timeIntervalSince1970: 1_790_000_000)
        var counts: [Int] = []
        for paper in PAPER_SIZES {
            ctx.page = PageSettings(paper: paper)
            let pages = ganttPrintPages(p, s, ctx)
            counts.append(pages.count)
            #expect(!pages.isEmpty)
            for (k, pg) in pages.enumerated() {
                #expect(pg.drawing.width == PAPER[paper]!.w && pg.drawing.height == PAPER[paper]!.h)
                let t = texts(pg)
                #expect(t.contains { $0.text == "Page \(k + 1) of \(pages.count)" }, "page number on \(paper) page \(k + 1)")
                for x in t where x.visibleRight > x.visibleLeft {
                    #expect(x.visibleLeft >= -0.5 && x.visibleRight <= pg.drawing.width + 0.5 && x.y <= pg.drawing.height, "\(paper): \(x.text) at \(x.visibleLeft)...\(x.visibleRight)")
                }
            }
        }
        // every size uses the same layout scaled up, so the number of pages stays about the same
        #expect(counts.allSatisfy { $0 >= 3 && $0 <= 5 }, "\(counts)")
    }

    @Test func headerFooterFieldsAreFilledIn() throws {
        var (p, s) = bigProject(3)
        p.settings.documentNumber = "DOC-42"
        p.settings.headerFooter.header.left.lines[0] = HFLine(field: "docnum")
        p.settings.headerFooter.header.right.lines[0] = HFLine(field: "hoursday")
        p.settings.headerFooter.footer.right.lines[1] = HFLine(field: "status")
        s = schedule(p)
        var ctx = PrintContext()
        ctx.timeZone = TimeZone(identifier: "UTC")!
        ctx.now = Date(timeIntervalSince1970: 1_790_000_000) // 21 Sep 2026 14:13 UTC
        let pg = try #require(ganttPrintPages(p, s, ctx).first)
        let all = texts(pg).map { $0.text }
        #expect(all.contains("DOC-42"))
        #expect(all.contains("8h/day"))
        #expect(all.contains("Status date Mon 02-Nov-2026"))
        #expect(all.contains("Printed Mon 21-Sep-2026 14:13"))
    }

    @Test func criticalPathReportsAndDiagramPages() throws {
        let session = samplePumpStation()
        let p = session.project, s = session.sched
        let ctx = PrintContext()
        let cpm = cpmPrintPages(p, s, CpmState(), ctx)
        #expect(cpm.count == 1)
        #expect(texts(cpm[0]).contains { $0.text.hasPrefix("Critical tasks: ") })
        let crit = reportPrintPages("critical", p, s, ctx)
        #expect(texts(crit[0]).contains { $0.text == "Critical Tasks" })
        #expect(reportPrintPages("nonsense", p, s, ctx).isEmpty)
        let net = networkDrawing(p, s, layout: layoutNetwork(p, s), theme: .light)
        let page = diagramPrintPage(p, s, net.drawing, ctx)
        for t in texts(page) { #expect(t.right <= page.drawing.width + 0.5) }
    }

    @Test func imageHeadersAreRead() {
        // 1x1 PNG
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        #expect(imagePixelSize(png)! == (1, 1))
        #expect(dataFromDataURL("data:image/png;base64,iVBORw0KGgo=") != nil)
        #expect(dataFromDataURL("not a url") == nil)
    }
}
