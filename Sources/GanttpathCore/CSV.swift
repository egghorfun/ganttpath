// CSV reading and writing (RFC 4180 quoting; delimiter auto-detected on read).

import Foundation

public struct CSVResult { public var rows: [[String]]; public var delimiter: Character }

public func parseCsv(_ input: String) -> CSVResult {
    var scalars = Array(input.unicodeScalars)
    if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
    // detect delimiter from the first line, ignoring quoted text
    var firstLine: [Unicode.Scalar] = []
    var k = 0
    while k < scalars.count && scalars[k] != "\n" { firstLine.append(scalars[k]); k += 1 }
    if firstLine.last == "\r" { firstLine.removeLast() }
    // remove "..." runs (like /"[^"]*"/g)
    var stripped: [Unicode.Scalar] = []
    var q = 0
    while q < firstLine.count {
        if firstLine[q] == "\"", let close = firstLine[(q + 1)...].firstIndex(of: "\"") { q = close + 1; continue }
        stripped.append(firstLine[q]); q += 1
    }
    let order: [Unicode.Scalar] = [",", ";", "\t"]
    var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
    for ch in stripped where counts[ch] != nil { counts[ch]! += 1 }
    // Object.entries(...).sort by count desc, stable: the first delimiter in the order , ; tab wins a tie
    let best = order.enumerated().sorted { counts[$0.element]! != counts[$1.element]! ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset }.first!.element
    let delim: Unicode.Scalar = counts[best]! > 0 ? best : ","
    var rows: [[String]] = []
    var row: [String] = []
    var field = String.UnicodeScalarView()
    var inQ = false
    var i = 0
    let n = scalars.count
    while i < n {
        let c = scalars[i]
        if inQ {
            if c == "\"" {
                if i + 1 < n && scalars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                inQ = false; i += 1; continue
            }
            field.append(c); i += 1; continue
        }
        if c == "\"" && field.isEmpty { inQ = true; i += 1; continue }
        if c == delim { row.append(String(field)); field = String.UnicodeScalarView(); i += 1; continue }
        if c == "\r" || c == "\n" {
            if c == "\r" && i + 1 < n && scalars[i + 1] == "\n" { i += 1 }
            row.append(String(field)); field = String.UnicodeScalarView()
            rows.append(row); row = []; i += 1; continue
        }
        field.append(c); i += 1
    }
    if !field.isEmpty || !row.isEmpty { row.append(String(field)); rows.append(row) }
    while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
    return CSVResult(rows: rows, delimiter: Character(delim))
}

func csvQuote(_ s: String) -> String {
    let needs = s.unicodeScalars.contains { $0 == "\"" || $0 == "," || $0 == "\r" || $0 == "\n" }
        || (s.unicodeScalars.first.map { jsWhitespace.contains($0) } ?? false) || (s.unicodeScalars.last.map { jsWhitespace.contains($0) } ?? false)
    return needs ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
}

/// rows of text cells. Returns text with a UTF-8 BOM so Excel opens it correctly.
public func writeCsv(_ rows: [[String]]) -> String {
    "\u{FEFF}" + rows.map { $0.map(csvQuote).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}
