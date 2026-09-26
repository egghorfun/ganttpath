// Where the toolbar's groups go. Kept apart from SwiftUI so it can be tested anywhere.
//
// Row 1 holds the main groups (file, edit, tasks, links, timeline) and, at its right edge, the trailing group (conflicts,
// Project, task panel, light/dark). The search/filter group always starts row 2. When the window is too narrow the main groups
// wrap, and the trailing group moves to the right end of the last row (or a row of its own when it does not fit there).

public enum ToolbarRole: Sendable { case main, trailing, secondLine }

/// Rows of (item index, x) for items of the given widths and roles in a toolbar `width` wide.
public func arrangeToolbar(widths: [Double], roles: [ToolbarRole], width: Double, spacing: Double) -> [[(index: Int, x: Double)]] {
    precondition(widths.count == roles.count)
    func flow(_ items: [Int]) -> [[(index: Int, x: Double)]] {
        var rows: [[(index: Int, x: Double)]] = []
        var x = 0.0
        for i in items {
            if rows.isEmpty || (!rows[rows.count - 1].isEmpty && x + widths[i] > width) { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, x))
            x += widths[i] + spacing
        }
        return rows
    }
    func used(_ row: [(index: Int, x: Double)]) -> Double { row.last.map { $0.x + widths[$0.index] } ?? 0 }

    let main = widths.indices.filter { roles[$0] == .main }
    let trailing = widths.indices.filter { roles[$0] == .trailing }
    let second = widths.indices.filter { roles[$0] == .secondLine }
    var rows = flow(main)
    let mainRows = rows.count
    rows += flow(second)
    if trailing.isEmpty { return rows }

    let tw = trailing.map { widths[$0] }.reduce(0, +) + spacing * Double(trailing.count - 1)
    func place(on r: Int?) {
        var x = max(0, width - tw)
        var block: [(index: Int, x: Double)] = []
        for i in trailing { block.append((i, x)); x += widths[i] + spacing }
        if let r = r { rows[r] += block } else { rows.append(block) }
    }
    func fits(_ r: Int) -> Bool { used(rows[r]) + spacing + tw <= width }
    if mainRows == 1 && fits(0) { place(on: 0) }
    else if let last = rows.indices.last, fits(last) { place(on: last) }
    else { place(on: nil) }
    return rows
}
