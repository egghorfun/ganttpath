// The toolbar's rows: project tools and the right-hand group on row 1, search and filters on row 2, wrapping when narrow.

import Testing
@testable import GanttpathModel

@Suite struct ToolbarArrangementTests {
    // five main groups, the search/filter group, the right-hand group
    let widths: [Double] = [200, 60, 300, 250, 400, 350, 150]
    let roles: [ToolbarRole] = [.main, .main, .main, .main, .main, .secondLine, .trailing]

    func layout(_ w: Double) -> [[Int]] {
        arrangeToolbar(widths: widths, roles: roles, width: w, spacing: 4).map { $0.map { $0.index } }
    }

    @Test func wideWindow() {
        // main groups use 1210 + 4*4 = 1226; with the right group 1226 + 4 + 150 = 1380
        let rows = arrangeToolbar(widths: widths, roles: roles, width: 2000, spacing: 4)
        #expect(rows.map { $0.map { $0.index } } == [[0, 1, 2, 3, 4, 6], [5]])
        #expect(rows[0].last!.x == 2000 - 150) // at the right edge of row 1
        #expect(rows[1][0].x == 0)             // search starts row 2
    }

    @Test func justFits() {
        #expect(layout(1380) == [[0, 1, 2, 3, 4, 6], [5]])
    }

    @Test func rightGroupWrapsToTheEndOfRow2() {
        // 1379: the right group no longer fits on row 1, but fits after search (350 + 4 + 150 <= 1379)
        let rows = arrangeToolbar(widths: widths, roles: roles, width: 1379, spacing: 4)
        #expect(rows.map { $0.map { $0.index } } == [[0, 1, 2, 3, 4], [5, 6]])
        #expect(rows[1].last!.x == 1379 - 150)
    }

    @Test func narrowWindowWrapsMainGroups() {
        // 800: main groups wrap onto two rows; the right group goes to the end of the search row
        #expect(layout(800) == [[0, 1, 2], [3, 4], [5, 6]])
    }

    @Test func veryNarrow() {
        // 400: nothing fits beside anything wider; the right group gets its own row
        #expect(layout(400) == [[0, 1], [2], [3], [4], [5], [6]])
    }
}
