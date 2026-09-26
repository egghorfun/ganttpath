// The toolbar icons are read from the original SVG shapes. GP_RENDER_DIR also writes them side by side with the originals.

import Foundation
import Testing
@testable import GanttpathModel

@Suite struct IconTests {
    @Test func everyIconIsReadAndStaysInsideItsBox() throws {
        for name in Icons.source.keys {
            let segs = Icons.segments(name)
            #expect(!segs.isEmpty, "\(name)")
            if case .move = segs[0] {} else { Issue.record("\(name) does not start with a move") }
            for s in segs {
                switch s {
                case .move(let x, let y), .line(let x, let y), .cubic(_, _, _, _, let x, let y):
                    #expect(x >= 0.5 && x <= 15.5 && y >= 0.5 && y <= 15.5, "\(name): \(x),\(y)")
                case .close: break
                }
            }
        }
        #expect(Icons.segments("nonsense").isEmpty)
        // relative commands, implicit lines after a move, numbers like ".7" and "8.5h5.6"
        #expect(Icons.segments("delete").contains(.line(5.2, 13)))
        #expect(Icons.segments("undo").prefix(3) == [.move(5.5, 3), .line(2.5, 6), .line(5.5, 9)])
    }

    @Test func writeIconSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["GP_RENDER_DIR"] else { return }
        let names = Icons.source.keys.sorted()
        var svg = "<svg xmlns='http://www.w3.org/2000/svg' width=\"\(names.count * 40 + 20)\" height=\"100\" style='background:#fff'>"
        for (i, n) in names.enumerated() {
            let x = 10 + i * 40
            svg += "<g transform='translate(\(x) 10) scale(2)' fill='none' stroke='#0F172A' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'>\(Icons.source[n]!)</g>"
            svg += "<g transform='translate(\(x) 55) scale(2)' fill='none' stroke='#C62828' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'><path d='\(Icons.pathData(n))'/></g>"
        }
        svg += "</svg>"
        try svg.write(toFile: dir + "/icons.svg", atomically: true, encoding: .utf8)
    }
}
