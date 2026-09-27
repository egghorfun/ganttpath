// The task table as drawing items (the JavaScript app builds it from HTML and styles.css). Only the rows asked for are drawn,
// so a table of thousands of tasks stays fast; the Mac view paints these items like the chart.

import Foundation
import GanttpathCore

public let LEVEL_INDENT: Double = 16
let CELL_PAD: Double = 8
let TABLE_FONT: Double = 13

public struct TableGeometry: Sendable {
    public var lefts: [Double]
    public var widths: [Double]
    public var ids: [String]
    public var total: Double
    public init(_ cols: [ColumnDef]) {
        var l: [Double] = [], x: Double = 0
        for c in cols { l.append(x); x += c.width }
        lefts = l; widths = cols.map { $0.width }; ids = cols.map { $0.id }; total = x
    }
    /// Column under x, if any.
    public func column(at x: Double) -> Int? { lefts.indices.first { x >= lefts[$0] && x < lefts[$0] + widths[$0] } }
    /// The resize grip at the right edge of a heading (7 px wide).
    public func grip(at x: Double) -> Int? { lefts.indices.first { abs(x - (lefts[$0] + widths[$0])) <= 3.5 } }
}

func mix(_ a: RGBA, _ pctA: Double, _ b: RGBA) -> RGBA {
    let f = pctA / 100
    return RGBA(a.r * f + b.r * (1 - f), a.g * f + b.g * (1 - f), a.b * f + b.b * (1 - f), a.a * f + b.a * (1 - f))
}

extension DocumentModel {
    /// Column headings (HEADER_H tall).
    public func tableHeaderDrawing(theme: Theme, font: String = "system") -> Drawing {
        let cols = columns
        let g = TableGeometry(cols)
        var items: [DrawItem] = [D.rect(0, 0, g.total, HEADER_H, fill: theme.headerBg)]
        for (i, c) in cols.enumerated() {
            let x = g.lefts[i], w = g.widths[i]
            var st = TextStyle(size: 12, bold: true, color: theme.text, font: font)
            let sorted = view.sort != nil && c.sortField != nil && view.sort!.field == c.sortField
            let mark = sorted ? (view.sort!.dir == "desc" ? "▼" : "▲") : ""
            let markW: Double = sorted ? 12 : 0
            let inner = w - CELL_PAD * 2 - markW
            var tx: Double
            switch c.align { case .right: st.anchor = .end; tx = x + w - CELL_PAD - markW; case .center: st.anchor = .middle; tx = x + w / 2; case .left: tx = x + CELL_PAD }
            var cell: [DrawItem] = [D.text(c.title, tx, HEADER_H - 9, st, maxWidth: max(0, inner))]
            if sorted { cell.append(D.text(mark, x + w - CELL_PAD - 8, HEADER_H - 10, TextStyle(size: 9, color: theme.accent, font: font))) }
            items.append(.clip(x: x, y: 0, w: w, h: HEADER_H, cell))
            items.append(D.line(x + w - 0.5, 0, x + w - 0.5, HEADER_H, Stroke(theme.grid, 1)))
        }
        items.append(D.line(0, HEADER_H - 0.5, g.total, HEADER_H - 0.5, Stroke(theme.gridStrong, 1)))
        return Drawing(width: g.total, height: HEADER_H, items: items)
    }

    /// Table rows first...last (row positions; rows.count is the "add a task" row), drawn from y = first * ROW_H.
    public func tableRowsDrawing(first: Int, last: Int, theme: Theme, font: String = "system") -> Drawing {
        let cols = columns
        let g = TableGeometry(cols)
        let f = fmt
        let rs = rows
        var items: [DrawItem] = []
        let range = selMode == .cells ? blockColumns : nil
        let multi = (range.map { $0.to > $0.from } ?? false) || selection.count > 1
        let grid = Stroke(theme.grid, 1)
        let hi = min(last, rs.count)
        if first > hi { return Drawing(width: g.total, height: 0, items: []) }
        let top = Double(first) * ROW_H
        for pos in first...hi {
            let y = Double(pos) * ROW_H - top
            if pos == rs.count {
                let ni = g.ids.firstIndex(of: "name") ?? 0
                items.append(.clip(x: g.lefts[ni], y: y, w: g.widths[ni], h: ROW_H, [
                    D.text("Click here and type to add a task…", g.lefts[ni] + CELL_PAD, y + 17, TextStyle(size: TABLE_FONT, color: theme.muted, font: font))]))
                continue
            }
            switch rs[pos] {
            case .group(let name, let count):
                items.append(D.rect(0, y, g.total, ROW_H, fill: theme.rowAlt))
                let st = TextStyle(size: TABLE_FONT, bold: true, color: theme.text, font: font)
                let w = CoreWidth.estimate(name, st)
                items.append(.clip(x: 0, y: y, w: g.total, h: ROW_H, [D.text(name, CELL_PAD, y + 17, st),
                                                                  D.text(" (\(count))", CELL_PAD + w, y + 17, TextStyle(size: TABLE_FONT, color: theme.muted, font: font))]))
                items.append(D.line(0, y + ROW_H - 0.5, g.total, y + ROW_H - 0.5, grid))
            case .task(let i):
                let t = project.tasks[i], r = sched.tasks[i]
                let c = CellContext(project: project, sched: sched, index: i, fmt: f, showBaseline: showBaseline, viewActive: false, compareBaseline: compareBaseline)
                let sel = selection.contains(t.uid)
                let cutRow = clip.map { $0.cut && $0.kind == .rows && $0.uidSet.contains(t.uid) } ?? false
                var bg: RGBA? = nil
                if r.hasConflict { bg = sel ? mix(theme.c["conflict"] ?? .black, 14, theme.sel) : (theme.c["conflict"] ?? .black).alpha(0.09) }
                else if sel { bg = theme.sel }
                if let b = bg { items.append(D.rect(0, y, g.total, ROW_H - 1, fill: b)) }
                var rowItems: [DrawItem] = []
                for (ci, col) in cols.enumerated() {
                    let x = g.lefts[ci], w = g.widths[ci]
                    let cls = col.cls(c)
                    let inRange = sel && selMode == .cells && multi && range.map { ci >= $0.from && ci <= $0.to } ?? false
                    let cutCell = clip.map { $0.cut && $0.kind == .cells && $0.uidSet.contains(t.uid) && $0.colIds.contains(col.id) } ?? false
                    if inRange { rowItems.append(D.rect(x, y, w, ROW_H - 1, fill: theme.accent.alpha(0.16))) }
                    var st = TextStyle(size: TABLE_FONT, bold: r.isSummary, color: col.edit == nil ? mix(theme.text, 82, theme.muted) : theme.text, font: font)
                    switch cls {
                    case "neg": st.color = theme.c["conflict"] ?? st.color; st.bold = true
                    case "crit": st.color = theme.c["critical"] ?? st.color; st.bold = true
                    case "badge-manual": st.color = theme.c["near"] ?? st.color; st.bold = true
                    case "badge-sum": st.color = theme.muted; st.italic = true
                    case "faint": st.color = theme.muted.alpha(0.75)
                    default: break
                    }
                    if r.inactive { st.color = theme.muted }
                    var cell: [DrawItem] = []
                    if col.id == "name" {
                        var nx = x + CELL_PAD + (built.flat ? 4 : Double(t.level - 1) * LEVEL_INDENT + 4) - 4
                        if r.isSummary && !built.flat {
                            cell.append(D.text(t.collapsed ? "▸" : "▾", nx + 7, y + 17, TextStyle(size: 12, color: theme.muted, anchor: .middle, font: font)))
                        }
                        nx += 14
                        if r.hasConflict || r.childConflict {
                            let warn = TextStyle(size: 11, bold: true, color: (theme.c["conflict"] ?? .black).alpha(r.hasConflict ? 1 : 0.55), font: font)
                            cell.append(D.text("⚠", nx, y + 17, warn)); nx += 15
                        }
                        if r.isMilestone { cell.append(D.text("◆", nx, y + 17, TextStyle(size: 11, color: theme.c["summary"] ?? theme.text, font: font))); nx += 15 }
                        var ns = st
                        ns.bold = r.isSummary || t.nameBold
                        ns.italic = t.nameItalic
                        ns.underline = t.nameUnderline
                        if r.pct >= 100 && !r.isSummary { ns.color = theme.muted }
                        if r.inactive { ns.strike = true }
                        cell.append(D.text(col.text(c), nx, y + 17, ns, maxWidth: max(0, x + w - CELL_PAD - nx)))
                    } else {
                        let text = col.text(c)
                        if !text.isEmpty {
                            var tx = x + CELL_PAD
                            switch col.align { case .right: st.anchor = .end; tx = x + w - CELL_PAD; case .center: st.anchor = .middle; tx = x + w / 2; case .left: break }
                            cell.append(D.text(text, tx, y + 17, st, maxWidth: max(0, w - CELL_PAD * 2)))
                        }
                    }
                    rowItems.append(.clip(x: x, y: y, w: w, h: ROW_H - 1, cell))
                    if cutCell { rowItems.append(D.rect(x, y, w, ROW_H - 1, fill: theme.bg.alpha(0.45))) }
                    rowItems.append(D.line(x + w - 0.5, y, x + w - 0.5, y + ROW_H - 1, grid))
                    if cursorUid == t.uid && cursorCol == col.id {
                        rowItems.append(D.rect(x + 1, y + 1, w - 2, ROW_H - 3, stroke: Stroke(theme.accent, 2)))
                    }
                    if cutCell { rowItems.append(D.rect(x + 1.5, y + 1.5, w - 3, ROW_H - 4, stroke: Stroke(theme.accent, 1, dash: [3, 2]))) }
                }
                if cutRow {
                    // a row that is cut is shown faded, with a dashed outline
                    items.append(.group(dx: 0, dy: 0, scale: 1, rowItems))
                    items.append(D.rect(0, y, g.total, ROW_H - 1, fill: theme.bg.alpha(0.45)))
                    items.append(D.rect(1, y + 1.5, g.total - 2, ROW_H - 4, stroke: Stroke(theme.accent, 1, dash: [3, 2])))
                } else {
                    items += rowItems
                }
                items.append(D.line(0, y + ROW_H - 0.5, g.total, y + ROW_H - 0.5, grid))
            }
        }
        return Drawing(width: g.total, height: Double(hi - first + 1) * ROW_H, items: items)
    }

    /// Row position and column id under a point of the table body (y from the top of the first row).
    public func tableHit(x: Double, y: Double) -> (pos: Int, col: String?, twisty: Bool) {
        let pos = Int((y / ROW_H).rounded(.down))
        let g = TableGeometry(columns)
        guard let ci = g.column(at: x) else { return (pos, nil, false) }
        var twisty = false
        if g.ids[ci] == "name", pos >= 0, pos < rows.count, let i = rows[pos].index, sched.tasks[i].isSummary, !built.flat {
            let tx = g.lefts[ci] + CELL_PAD + Double(project.tasks[i].level - 1) * LEVEL_INDENT
            twisty = x >= tx - 2 && x <= tx + 16
        }
        return (pos, g.ids[ci], twisty)
    }
}

/// Measures a text where one is placed right after another (the group count after a group name). The Mac app sets its
/// CoreText measurer here at start-up.
public enum CoreWidth {
    nonisolated(unsafe) public static var measurer: TextMeasurer = HelveticaMeasurer()
    public static func estimate(_ s: String, _ st: TextStyle) -> Double { measurer.width(s, st) }
}
