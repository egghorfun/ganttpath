// PDF pages as drawings: the Gantt printout (table + chart), a diagram view on one page, the critical path table and the
// standard reports, each with the project's header and footer. Port of print.js. Pages are in CSS pixels (96 per inch);
// the Mac app paints each page into a PDF context (1 px = 0.75 pt).

import Foundation

public struct Paper: Sendable { public var w: Double; public var h: Double; public var scale: Double }

/// ISO landscape sheets at 96 dpi, and the zoom applied to what is drawn on them.
public let PAPER: [String: Paper] = [
    "A4": Paper(w: 1123, h: 794, scale: 0.8), "A3": Paper(w: 1587, h: 1123, scale: 1.1), "A2": Paper(w: 2244, h: 1587, scale: 1.55),
    "A1": Paper(w: 3178, h: 2244, scale: 2.2), "A0": Paper(w: 4492, h: 3178, scale: 3.1),
]
public let PAPER_SIZES = ["A4", "A3", "A2", "A1", "A0"]
public let DEFAULT_MARGIN_MM: Double = 6
public let MIN_MARGIN_MM: Double = 3, MAX_MARGIN_MM: Double = 40

public struct PageSettings: Equatable, Sendable {
    public var paper = "A4"
    public var marginMM: Double = DEFAULT_MARGIN_MM
    public init(paper: String = "A4", marginMM: Double = DEFAULT_MARGIN_MM) { self.paper = paper; self.marginMM = marginMM }
    /// Saved values with safe defaults (JS pageSettings()).
    public var normalized: PageSettings {
        PageSettings(paper: PAPER[paper] != nil ? paper : "A4",
                     marginMM: marginMM.isFinite && marginMM >= MIN_MARGIN_MM && marginMM <= MAX_MARGIN_MM ? marginMM : DEFAULT_MARGIN_MM)
    }
}

/// Everything a printout depends on besides the project: the view on screen and the moment of printing.
public struct PrintContext: Sendable {
    public var page = PageSettings()
    public var view = ViewState()
    public var columnIds: [String]? = nil
    public var gantt = GanttOptions()
    public var now = Date()
    public var timeZone = TimeZone.current
    public var measurer: TextMeasurer = HelveticaMeasurer()
    public init() {}
}

public struct PrintedPage: Sendable {
    public var drawing: Drawing
}

// MARK: - header and footer

let LEGEND: [(String, String)] = [("task", "Task"), ("critical", "Critical path"), ("near", "Near critical"), ("conflict", "Conflict")]

/// "8" not "8.00".
func numStr(_ n: Double) -> String { jsNumberString(jsRound(n * 100) / 100) }

struct HFCtx {
    var p: Project
    var todayStr: String
    var stamp: String
    var rangeStr: String
    var statusStr: String
    var withLegend: Bool
    var showBaseline: Int
    var pages: Int
    var pg: Int
}

enum HFContent { case text(String), logo(Data), legend }

func resolveHFLine(_ line: HFLine, _ c: HFCtx) -> HFContent? {
    let s = c.p.settings
    switch line.field {
    case "text": return line.text.isEmpty ? nil : .text(line.text)
    case "title": return c.p.name.isEmpty ? nil : .text(c.p.name)
    case "docnum": return s.documentNumber.isEmpty ? nil : .text(s.documentNumber)
    case "date": return .text(c.todayStr)
    case "printed": return .text("Printed \(c.stamp)")
    case "range": return c.rangeStr.isEmpty ? nil : .text(c.rangeStr)
    case "status": return c.statusStr.isEmpty ? nil : .text("Status date \(c.statusStr)")
    case "page": return .text("Page \(c.pg + 1) of \(c.pages)")
    case "logo": return s.logoDataUrl.flatMap(dataFromDataURL).map { .logo($0) }
    case "legend": return c.withLegend ? .legend : nil
    case "hoursday": return .text("\(numStr(s.hoursPerDay))h/day")
    case "hoursweek": return .text("\(numStr(s.hoursPerWeek))h/week")
    case "daysmonth": return .text("\(numStr(s.daysPerMonth))d/month")
    default: return nil
    }
}

/// Bytes of a data: URL (base64), or nil.
public func dataFromDataURL(_ url: String) -> Data? {
    guard url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
    let meta = url[url.startIndex..<comma]
    let body = String(url[url.index(after: comma)...])
    if meta.hasSuffix(";base64") { return Data(base64Encoded: body, options: .ignoreUnknownCharacters) }
    return body.removingPercentEncoding?.data(using: .utf8)
}

/// Pixel size of a PNG or JPEG image, read from its header.
public func imagePixelSize(_ d: Data) -> (w: Double, h: Double)? {
    let b = [UInt8](d)
    if b.count > 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 {
        func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        return (Double(be32(16)), Double(be32(20)))
    }
    if b.count > 4 && b[0] == 0xFF && b[1] == 0xD8 {
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6]), w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return (Double(w), Double(h))
            }
            i += 2 + len
        }
    }
    return nil
}

func usedHFLines(_ box: HFBox) -> Int { max(1, box.lines.filter { $0.field != "none" }.count) }

struct HFGeometry { var titleH: Double; var footH: Double }
func hfGeometry(_ hf: HeaderFooter) -> HFGeometry {
    let hMax = max(hf.header.left.size, hf.header.center.size, hf.header.right.size, 10)
    let fMax = max(hf.footer.left.size, hf.footer.center.size, hf.footer.right.size, 10)
    let hL = max(usedHFLines(hf.header.left), usedHFLines(hf.header.center), usedHFLines(hf.header.right))
    let fL = max(usedHFLines(hf.footer.left), usedHFLines(hf.footer.center), usedHFLines(hf.footer.right))
    return HFGeometry(titleH: jsRound(Double(hL) * hMax * 1.3) + 8, footH: jsRound(Double(fL) * fMax * 1.3) + 6)
}

/// Legend items (task colours, milestone, baseline) laid out from x at baseline y; returns the items and the width used.
func legendItems(_ theme: Theme, _ x0: Double, _ y: Double, _ size: Double, _ color: RGBA, _ font: String, _ showBaseline: Int, _ m: TextMeasurer) -> [DrawItem] {
    var items: [DrawItem] = []
    var x = x0
    let st = TextStyle(size: size, color: color, font: font)
    var entries: [(String, String)] = LEGEND
    entries.append(("ms", "Milestone"))
    if showBaseline >= 0 && showBaseline < BASELINE_NAMES.count { entries.append(("base", BASELINE_NAMES[showBaseline])) }
    for (k, label) in entries {
        let midY = y - size * 0.35
        switch k {
        case "ms":
            let c = theme.c["summary"] ?? .black
            items.append(D.poly([(x + 6.4, midY - 6.4), (x + 12.8, midY), (x + 6.4, midY + 6.4), (x, midY)], fill: c, closed: true))
            x += 12.8 + 4
        case "base":
            items.append(D.rect(x, midY - 2, 14, 4, fill: theme.c["baseline"], r: 2)); x += 18
        default:
            items.append(D.rect(x, midY - 4, 14, 8, fill: theme.c[k], r: 2)); x += 18
        }
        items.append(D.text(label, x, y, st))
        x += m.width(label, st) + 14
    }
    return items
}

/// One header or footer row: three boxes side by side (left, centre, right), lines stacked from `top`.
/// `alignBottom`: the row sits on `top` as its bottom edge instead (the footer).
func hfRow(_ sec: HFSection, _ c: HFCtx, x: Double, y top: Double, width: Double, scaleMul: Double, alignBottom: Bool,
           theme: Theme, m: TextMeasurer) -> [DrawItem] {
    let gap: Double = 8
    let boxW = (width - gap * 2) / 3
    struct Line { var content: HFContent; var h: Double }
    var boxes: [(HFBox, TextStyle.Anchor, [Line])] = []
    var rowH: Double = 0
    for (box, anchor) in [(sec.left, TextStyle.Anchor.start), (sec.center, .middle), (sec.right, .end)] {
        let size = jsRound(box.size * scaleMul)
        var lines: [Line] = []
        for l in box.lines {
            guard let content = resolveHFLine(l, c) else { continue }
            var h = size * 1.3
            if case .logo = content { h = max(h, jsRound(28 * scaleMul)) }
            lines.append(Line(content: content, h: h))
        }
        rowH = max(rowH, lines.reduce(0) { $0 + $1.h })
        boxes.append((box, anchor, lines))
    }
    let y0 = alignBottom ? top - rowH : top
    var items: [DrawItem] = []
    for (k, (box, anchor, lines)) in boxes.enumerated() {
        let bx = x + Double(k) * (boxW + gap)
        let size = jsRound(box.size * scaleMul)
        let color = RGBA(hex: box.color) ?? RGBA.hex(HF_DEFAULT_COLOR)
        var st = TextStyle(size: size, color: color, anchor: anchor, font: box.font)
        var y = y0
        for l in lines {
            switch l.content {
            case .text(let s):
                let tx = anchor == .start ? bx : anchor == .middle ? bx + boxW / 2 : bx + boxW
                st.anchor = anchor
                items.append(.clip(x: bx, y: y, w: boxW, h: l.h, [D.text(s, tx, y + (l.h - size) / 2 + size * 0.8, st, maxWidth: boxW)]))
            case .logo(let data):
                let maxH = jsRound(28 * scaleMul)
                var w = maxH, h = maxH
                if let sz = imagePixelSize(data), sz.h > 0 { h = min(maxH, sz.h); w = sz.w * h / sz.h }
                w = min(w, boxW)
                let lx = anchor == .start ? bx : anchor == .middle ? bx + (boxW - w) / 2 : bx + boxW - w
                items.append(.image(data, x: lx, y: y, w: w, h: h))
            case .legend:
                let li = legendItems(theme, 0, 0, size, color, box.font, c.showBaseline, m)
                let width = legendWidth(size, box.font, c.showBaseline, m, st)
                let lx = anchor == .start ? bx : anchor == .middle ? bx + (boxW - width) / 2 : bx + boxW - width
                items.append(.clip(x: bx, y: y, w: boxW, h: l.h, [.group(dx: lx, dy: y + (l.h - size) / 2 + size * 0.8, scale: 1, li)]))
            }
            y += l.h
        }
    }
    return items
}

func legendWidth(_ size: Double, _ font: String, _ showBaseline: Int, _ m: TextMeasurer, _ st0: TextStyle) -> Double {
    var st = st0; st.anchor = .start; st.size = size; st.font = font
    var w: Double = 0
    for (_, label) in LEGEND { w += 18 + m.width(label, st) + 14 }
    w += 16.8 + m.width("Milestone", st) + 14
    if showBaseline >= 0 && showBaseline < BASELINE_NAMES.count { w += 18 + m.width(BASELINE_NAMES[showBaseline], st) + 14 }
    return w - 14
}

func printStamps(_ ctx: PrintContext, _ fmt: Fmt) -> (today: String, stamp: String) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = ctx.timeZone
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: ctx.now)
    let iso = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    let today = fmt.date(iso)
    return (today, "\(today) \(String(format: "%02d:%02d", c.hour!, c.minute!))")
}

func rangeText(_ sc: ScheduleResult, _ fmt: Fmt) -> String {
    sc.projectStart != nil ? "\(fmt.date(sc.projectStart)) → \(fmt.date(sc.projectFinish))" : ""
}

/// Page frame shared by every printout: page size, logical size, margin, header and footer geometry.
struct PageFrame {
    var cfg: Paper
    var margin: Double
    var footGap: Double
    var LW: Double, LH: Double
    var contentW: Double
    var hf: HFGeometry
    init(_ p: Project, _ ps: PageSettings) {
        let s = ps.normalized
        cfg = PAPER[s.paper]!
        margin = jsRound((s.marginMM / 25.4 * 96) / cfg.scale)
        footGap = min(8, margin)
        LW = (cfg.w / cfg.scale).rounded(.down); LH = (cfg.h / cfg.scale).rounded(.down)
        contentW = LW - margin * 2
        hf = hfGeometry(p.settings.headerFooter)
    }
    /// A page: `inner` in logical coordinates (already offset by the margin), plus header and footer.
    func page(_ p: Project, _ c: HFCtx, _ inner: [DrawItem], theme: Theme, m: TextMeasurer) -> Drawing {
        var logical: [DrawItem] = []
        logical.append(.clip(x: margin, y: margin, w: contentW, h: hf.titleH,
                             hfRow(p.settings.headerFooter.header, c, x: margin, y: margin, width: contentW, scaleMul: 1, alignBottom: false, theme: theme, m: m)))
        logical.append(.clip(x: 0, y: 0, w: LW, h: LH, [.group(dx: margin, dy: margin + hf.titleH + 4, scale: 1, inner)]))
        let foot = hfRow(p.settings.headerFooter.footer, c, x: margin * cfg.scale, y: cfg.h - (margin - footGap) * cfg.scale,
                         width: cfg.w - 2 * margin * cfg.scale, scaleMul: cfg.scale, alignBottom: true, theme: theme, m: m)
        return Drawing(width: cfg.w, height: cfg.h, background: .white, items: [.group(dx: 0, dy: 0, scale: cfg.scale, logical)] + foot)
    }
}

// MARK: - table drawing helpers

struct PrintCell { var text: String; var style: TextStyle; var indent: Double = 0 }

func tableHeader(_ titles: [(String, ColumnDef.Align)], _ lefts: [Double], _ widths: [Double], theme: Theme) -> [DrawItem] {
    let total = widths.reduce(0, +)
    var items: [DrawItem] = [D.rect(0, 0, total, HEADER_H, fill: theme.headerBg)]
    for (i, (t, align)) in titles.enumerated() {
        var st = TextStyle(size: 10.5, bold: true, color: theme.text)
        let x: Double
        switch align { case .right: st.anchor = .end; x = lefts[i] + widths[i] - 5; case .center: st.anchor = .middle; x = lefts[i] + widths[i] / 2; case .left: x = lefts[i] + 5 }
        items.append(.clip(x: lefts[i], y: 0, w: widths[i], h: HEADER_H, [D.text(t, x, HEADER_H - 9, st)]))
        items.append(D.line(lefts[i] + widths[i] - 0.5, 0, lefts[i] + widths[i] - 0.5, HEADER_H, Stroke(theme.grid, 1)))
    }
    items.append(D.line(0, 0.5, total, 0.5, Stroke(theme.gridStrong, 1)))
    items.append(D.line(0, HEADER_H - 0.5, total, HEADER_H - 0.5, Stroke(theme.gridStrong, 1)))
    return items
}

func tableRow(_ y: Double, _ cells: [PrintCell], _ aligns: [ColumnDef.Align], _ lefts: [Double], _ widths: [Double], bg: RGBA?, theme: Theme) -> [DrawItem] {
    let total = widths.reduce(0, +)
    var items: [DrawItem] = []
    if let bg = bg { items.append(D.rect(0, y, total, ROW_H - 1, fill: bg)) }
    for (i, c) in cells.enumerated() {
        let pad: Double = 5
        let inner = widths[i] - pad * 2 - c.indent
        var st = c.style
        let x: Double
        switch aligns[i] { case .right: st.anchor = .end; x = lefts[i] + widths[i] - pad; case .center: st.anchor = .middle; x = lefts[i] + widths[i] / 2; case .left: st.anchor = .start; x = lefts[i] + pad + c.indent }
        if !c.text.isEmpty { items.append(.clip(x: lefts[i], y: y, w: widths[i], h: ROW_H - 1, [D.text(c.text, x, y + 17, st, maxWidth: max(0, inner))])) }
        items.append(D.line(lefts[i] + widths[i] - 0.5, y, lefts[i] + widths[i] - 0.5, y + ROW_H - 1, Stroke(theme.grid, 1)))
    }
    items.append(D.line(0, y + ROW_H - 0.5, total, y + ROW_H - 0.5, Stroke(theme.grid, 1)))
    return items
}

// MARK: - Gantt printout

/// The Gantt printout: table and chart, as many pages as the rows need. Empty when there is nothing to print.
public func ganttPrintPages(_ p: Project, _ sc: ScheduleResult, _ ctx: PrintContext) -> [PrintedPage] {
    let theme = Theme.light
    let m = ctx.measurer
    let fr = PageFrame(p, ctx.page)
    let built = buildRows(p, sc, ctx.view)
    let rows = built.rows
    if rows.isEmpty { return [] }
    let posOf = positions(rows)
    let rowsPerPage = max(5, Int(((fr.LH - fr.margin * 2 - fr.hf.titleH - HEADER_H - fr.hf.footH) / ROW_H).rounded(.down)))
    let pages = (rows.count + rowsPerPage - 1) / rowsPerPage
    let fmt = Fmt(p, sc)

    // table columns: at most half of the page; the least important ones are left out rather than squeezed
    let budget = (fr.contentW * 0.5).rounded(.down)
    let dateW = jsRound(Double(fmt.dateTextLen) * 6.5 + 14)
    let PRINT_W: [String: Double] = ["id": 32, "wbs": 48, "mode": 58, "duration": 58, "start": dateW, "finish": dateW, "preds": 86, "pct": 70, "totalSlack": 74, "freeSlack": 70]
    let KEEP = ["name", "start", "finish", "duration", "id", "preds", "wbs", "totalSlack", "pct", "mode"]
    func rank(_ c: ColumnDef) -> Int { KEEP.firstIndex(of: c.id) ?? 50 }
    func widthOf(_ c: ColumnDef) -> Double { c.id == "name" ? 0 : PRINT_W[c.id] ?? (c.isDate ? dateW : min(c.width, 96)) }
    let NAME_MIN: Double = 150
    var cols = visibleColumns(p, sc, ids: ctx.columnIds)
    if !cols.contains(where: { $0.id == "name" }) { cols = allColumns(p, sc).filter { $0.id == "name" } + cols }
    func fits(_ l: [ColumnDef]) -> Bool { l.reduce(0) { $0 + widthOf($1) } + NAME_MIN <= budget }
    while !fits(cols) && cols.count > 1 {
        var worst = cols.first { $0.id != "name" } ?? cols[0]
        for c in cols where c.id != "name" && rank(c) >= rank(worst) { worst = c }
        if worst.id == "name" { break }
        cols.removeAll { $0.id == worst.id }
    }
    let fixed = cols.reduce(0) { $0 + widthOf($1) }
    let nameW = max(NAME_MIN, min(300, budget - fixed))
    let widths = cols.map { $0.id == "name" ? nameW : widthOf($0) }
    let tableW = widths.reduce(0, +)
    let chartW = fr.contentW - tableW - 6
    var lefts: [Double] = []
    var acc: Double = 0
    for w in widths { lefts.append(acc); acc += w }

    // time range: the whole project, squeezed to the chart width
    let opts = ctx.gantt
    var lo = parseISO(sc.projectStart) ?? parseISO(p.settings.startDate) ?? todayDn()
    var hi = sc.projectFinish != nil ? (parseISO(sc.projectFinish) ?? lo + 30) : lo + 30
    if opts.showBaseline >= 0 {
        for t in p.tasks {
            guard opts.showBaseline < t.baselines.count, let b = t.baselines[opts.showBaseline] else { continue }
            if let s = parseISO(b.start), s < lo { lo = s }
            if let f = parseISO(b.finish), f > hi { hi = f }
        }
    }
    let mon = p.settings.weekStartsMonday
    let originDn = lo - (mon ? (dow(lo) + 6) % 7 : dow(lo)) - 1
    func clampPx(_ v: Double) -> Double { max(0.35, min(14, v)) }
    var endDn = hi + 8
    var px = clampPx(chartW / Double(endDn - originDn))
    for _ in 0..<8 {
        let reach = maxLabelReach(rows, p, sc, originDn, px, opts, measurer: m)
        if reach <= chartW + 0.5 { break }
        let grownEnd = max(endDn + 1, Int((Double(originDn) + reach / px).rounded(.up)))
        let grownPx = clampPx(chartW / Double(grownEnd - originDn))
        if grownEnd == endDn || abs(grownPx - px) < 1e-6 { break }
        endDn = grownEnd; px = grownPx
    }
    let wcal = projectCalendar(p)
    let nonWorking: (Int) -> Bool = { !wcal.isWorking($0) }
    let chartHeader = ganttHeader(originDn: originDn, endDn: endDn, px: px, mondayFirst: mon, nonWorking: nonWorking, theme: theme, font: opts.font)

    let (todayStr, stamp) = printStamps(ctx, fmt)
    let sd = parseISO(p.settings.statusDate)
    let hc = HFCtx(p: p, todayStr: todayStr, stamp: stamp, rangeStr: rangeText(sc, fmt), statusStr: sd != nil ? fmt.date(p.settings.statusDate) : "",
                   withLegend: true, showBaseline: opts.showBaseline, pages: pages, pg: 0)
    var popts = opts
    popts.selected = []; popts.linkSel = nil
    popts.progressLine = opts.progressLine && sd != nil

    let titles = cols.map { ($0.title, $0.align) }
    let aligns = cols.map { $0.align }
    var out: [PrintedPage] = []
    for pg in 0..<pages {
        let first = pg * rowsPerPage
        let last = min(rows.count - 1, first + rowsPerPage - 1)
        var inner: [DrawItem] = tableHeader(titles, lefts, widths, theme: theme)
        for pos in first...last {
            let y = HEADER_H + Double(pos - first) * ROW_H
            switch rows[pos] {
            case .group(let name, let count):
                let st = TextStyle(size: 10.5, bold: true, color: theme.text)
                inner += tableRow(y, [PrintCell(text: "\(name) (\(count))", style: st)], [.left], [0], [tableW], bg: theme.rowAlt, theme: theme)
            case .task(let i):
                let t = p.tasks[i], r = sc.tasks[i]
                let cx = CellContext(project: p, sched: sc, index: i, fmt: fmt, showBaseline: opts.showBaseline)
                var cells: [PrintCell] = []
                for col in cols {
                    var st = TextStyle(size: 10.5, bold: r.isSummary, color: r.inactive ? theme.muted : theme.text, font: opts.font)
                    var text = col.text(cx)
                    var indent: Double = 0
                    if col.id == "name" {
                        indent = built.flat ? 0 : Double(t.level - 1) * 12
                        text = (r.hasConflict ? "⚠ " : "") + (r.isMilestone ? "◆ " : "") + text
                        st.strike = r.inactive
                    } else if r.inactive { st.strike = true }
                    if (col.id == "totalSlack" || col.id == "freeSlack") && (r.totalSlack ?? 0) < 0 { st.color = theme.c["conflict"] ?? st.color; st.bold = true }
                    cells.append(PrintCell(text: text, style: st, indent: indent))
                }
                inner += tableRow(y, cells, aligns, lefts, widths, bg: r.hasConflict ? RGBA(230 / 255, 0, 0, 0.08) : nil, theme: theme)
            }
        }
        inner.append(D.line(tableW - 0.5, 0, tableW - 0.5, HEADER_H + Double(last - first + 1) * ROW_H, Stroke(theme.gridStrong, 1)))
        let body = ganttBody(project: p, sched: sc, rows: rows, first: first, last: last, px: px, originDn: originDn, endDn: endDn,
                             posOf: posOf, opts: popts, theme: theme, nonWorking: nonWorking)
        let chartX = tableW + 6
        inner.append(.clip(x: chartX, y: 0, w: chartW, h: HEADER_H + body.drawing.height, [
            .group(dx: chartX, dy: 0, scale: 1, chartHeader.items),
            .group(dx: chartX, dy: HEADER_H, scale: 1, body.drawing.items),
        ]))
        var c = hc; c.pg = pg
        out.append(PrintedPage(drawing: fr.page(p, c, inner, theme: theme, m: m)))
    }
    return out
}

// MARK: - one diagram on a page

/// A diagram view (network, timeline, S-curve) scaled down to fit one page, with the header and footer.
public func diagramPrintPage(_ p: Project, _ sc: ScheduleResult, _ diagram: Drawing, _ ctx: PrintContext) -> PrintedPage {
    let theme = Theme.light
    let fr = PageFrame(p, ctx.page)
    let fmt = Fmt(p, sc)
    let contentH = fr.LH - fr.margin * 2 - fr.hf.titleH - fr.hf.footH - 6
    let (todayStr, stamp) = printStamps(ctx, fmt)
    let hc = HFCtx(p: p, todayStr: todayStr, stamp: stamp, rangeStr: rangeText(sc, fmt), statusStr: p.settings.statusDate != nil ? fmt.date(p.settings.statusDate) : "",
                   withLegend: false, showBaseline: -1, pages: 1, pg: 0)
    let s = min(1, fr.contentW / max(1, diagram.width), contentH / max(1, diagram.height))
    let w = diagram.width * s, h = diagram.height * s
    var inner: [DrawItem] = []
    let dx = (fr.contentW - w) / 2, dy = (contentH - h) / 2
    if let bg = diagram.background { inner.append(D.rect(dx, dy, w, h, fill: bg)) }
    inner.append(.group(dx: dx, dy: dy, scale: s, diagram.items))
    return PrintedPage(drawing: fr.page(p, hc, inner, theme: theme, m: ctx.measurer))
}

// MARK: - table printouts (critical path, standard reports)

func tablePages(_ p: Project, _ sc: ScheduleResult, _ ctx: PrintContext, metaH: Double, meta: (Double) -> [DrawItem],
                titles: [String], widths: [Double], rows: [[PrintCell]], rowBg: [RGBA?]) -> [PrintedPage] {
    let theme = Theme.light
    let fr = PageFrame(p, ctx.page)
    let fmt = Fmt(p, sc)
    let rowsPerPage = max(5, Int(((fr.LH - fr.margin * 2 - fr.hf.titleH - metaH - HEADER_H - fr.hf.footH) / ROW_H).rounded(.down)))
    let pages = (rows.count + rowsPerPage - 1) / rowsPerPage
    let (todayStr, stamp) = printStamps(ctx, fmt)
    let hc = HFCtx(p: p, todayStr: todayStr, stamp: stamp, rangeStr: rangeText(sc, fmt), statusStr: p.settings.statusDate != nil ? fmt.date(p.settings.statusDate) : "",
                   withLegend: false, showBaseline: -1, pages: pages, pg: 0)
    var lefts: [Double] = []
    var acc: Double = 0
    for w in widths { lefts.append(acc); acc += w }
    let aligns = titles.map { _ in ColumnDef.Align.left }
    var out: [PrintedPage] = []
    for pg in 0..<pages {
        let first = pg * rowsPerPage
        let last = min(rows.count - 1, first + rowsPerPage - 1)
        var inner = meta(fr.contentW)
        var tbl = tableHeader(titles.map { ($0, .left) }, lefts, widths, theme: theme)
        for pos in first...last {
            tbl += tableRow(HEADER_H + Double(pos - first) * ROW_H, rows[pos], aligns, lefts, widths, bg: rowBg[pos], theme: theme)
        }
        inner.append(.group(dx: 0, dy: metaH, scale: 1, tbl))
        var c = hc; c.pg = pg
        out.append(PrintedPage(drawing: fr.page(p, c, inner, theme: theme, m: ctx.measurer)))
    }
    return out
}

/// The critical path table as shown (filter, sort, summaries), on as many pages as needed.
public func cpmPrintPages(_ p: Project, _ sc: ScheduleResult, _ st: CpmState, _ ctx: PrintContext) -> [PrintedPage] {
    let list = cpmRows(p, sc, st)
    if list.isEmpty { return [] }
    let theme = Theme.light
    let fr = PageFrame(p, ctx.page)
    let fmt = Fmt(p, sc)
    let FIXED_W: [String: Double] = ["id": 34, "wbs": 55, "duration": 62, "es": 74, "ef": 74, "ls": 74, "lf": 74, "ts": 62, "fs": 62, "status": 92]
    let fixedTotal = CPM_COLS.reduce(0) { $0 + ($1.id == "name" ? 0 : FIXED_W[$1.id] ?? 70) }
    let nameW = max(160, fr.contentW - fixedTotal)
    let widths = CPM_COLS.map { $0.id == "name" ? nameW : FIXED_W[$0.id] ?? 70 }
    let leaves = sc.tasks.filter { !$0.isSummary }
    let d0 = fmt.date(sc.projectStart), d1 = fmt.date(sc.projectFinish)
    let meta = "Critical tasks: \(leaves.filter { $0.critical }.count) · Near critical: \(leaves.filter { $0.nearCritical }.count) · Conflicts: \(sc.conflictCount) · Project \(d0.isEmpty ? "-" : d0) → \(d1.isEmpty ? "-" : d1)"
    var rows: [[PrintCell]] = [], bgs: [RGBA?] = []
    for r in list {
        let t = p.tasks[r.index]
        rows.append(CPM_COLS.map { c in
            var st = TextStyle(size: 10.5, bold: r.isSummary, color: theme.text)
            var text = cpmText(c.id, r, t, fmt)
            var indent: Double = 0
            if c.id == "name" { indent = Double(t.level - 1) * 12; text = (r.hasConflict ? "⚠ " : "") + text }
            if c.id == "status" && (r.hasConflict || r.critical) { st.color = theme.c["critical"] ?? st.color; st.bold = true }
            return PrintCell(text: text, style: st, indent: indent)
        })
        bgs.append(r.hasConflict ? RGBA(230 / 255, 0, 0, 0.08) : nil)
    }
    return tablePages(p, sc, ctx, metaH: 22, meta: { w in
        [.clip(x: 0, y: 0, w: w, h: 22, [D.text(meta, 0, 13, TextStyle(size: 11, color: theme.muted), maxWidth: w)])]
    }, titles: CPM_COLS.map { $0.title }, widths: widths, rows: rows, rowBg: bgs)
}

/// Columns of the four standard reports (reports-ui.js), shared by the dialog and the PDF.
public let REPORT_COLUMNS: [String: [(id: String, title: String)]] = [
    "critical": [("id", "ID"), ("wbs", "WBS"), ("name", "Task Name"), ("duration", "Duration"), ("start", "Start"), ("finish", "Finish"), ("slack", "Total Slack")],
    "late": [("id", "ID"), ("wbs", "WBS"), ("name", "Task Name"), ("finish", "Finish"), ("late", "Days Late"), ("pct", "% Complete")],
    "slipping": [("id", "ID"), ("wbs", "WBS"), ("name", "Task Name"), ("bfin", "Baseline Finish"), ("finish", "Finish"), ("slip", "Days Slipped"), ("pct", "% Complete")],
    "milestones": [("id", "ID"), ("name", "Milestone"), ("finish", "Date"), ("status", "Status")],
]

public func reportCellText(_ col: String, _ rr: ReportRow, _ t: Task, _ fmt: Fmt) -> String {
    let r = rr.row
    switch col {
    case "id": return String(r.id)
    case "wbs": return r.wbs
    case "name": return t.name
    case "duration": return fmt.dur(r)
    case "start": return fmt.date(r.start)
    case "finish": return fmt.date(r.finish)
    case "slack": return fmt.span(r.totalSlackMin)
    case "late": return "\(rr.lateDays.map(String.init) ?? "undefined")d"
    case "pct": return "\(jsNumberString(r.pct))%"
    case "bfin": return fmt.date(rr.baselineFinish)
    case "slip": return "\(rr.slipDays.map(String.init) ?? "undefined")d"
    case "status": return rr.milestoneStatus ?? ""
    default: return ""
    }
}

/// One standard report, with its name and definition above the table on every page.
public func reportPrintPages(_ key: String, _ p: Project, _ sc: ScheduleResult, _ ctx: PrintContext, baselineIndex: Int = 0, today: Int = todayDn()) -> [PrintedPage] {
    guard let def = REPORT_DEFS.first(where: { $0.key == key }), let cols = REPORT_COLUMNS[key] else { return [] }
    let list = reportRows(key, p, sc, baselineIndex: baselineIndex, today: today)
    if list.isEmpty { return [] }
    let theme = Theme.light
    let fr = PageFrame(p, ctx.page)
    let fmt = Fmt(p, sc)
    let nameIdx = cols.firstIndex { $0.id == "name" } ?? 0
    let colW = (fr.contentW / Double(cols.count)).rounded(.down)
    let widths = cols.indices.map { $0 == nameIdx ? fr.contentW - colW * Double(cols.count - 1) : colW }
    let rows: [[PrintCell]] = list.map { rr in cols.map { PrintCell(text: reportCellText($0.id, rr, p.tasks[rr.row.index], fmt), style: TextStyle(size: 10.5, color: theme.text)) } }
    return tablePages(p, sc, ctx, metaH: 34, meta: { w in
        [.clip(x: 0, y: 0, w: w, h: 34, [D.text(def.name, 0, 14, TextStyle(size: 13, bold: true, color: theme.text), maxWidth: w),
                                          D.text(def.blurb, 0, 29, TextStyle(size: 10.5, color: theme.muted), maxWidth: w)])]
    }, titles: cols.map { $0.title }, widths: widths, rows: rows, rowBg: rows.map { _ in nil })
}
