// Predecessor text syntax, MS Project style:  "3", "3FS+2d", "5SS-25%", "4FF-1w", "6SF", "2FS+3ed"
// A predecessor is { uid, type: 'FS'|'SS'|'FF'|'SF', lag: { v: number, u: 'd'|'w'|'%'|'ed' } }
//   d  = working days (lead when negative; a day is the project's Hours per day)
//   w  = weeks (Hours per week, 40 hours by default = 5 working days, as in MS Project)
//   h  = working hours,  m = working minutes
//   %  = percentage of the predecessor's duration
//   ed = elapsed (calendar) days, eh = elapsed hours, em = elapsed minutes, ew = elapsed weeks

import Foundation

public let LINK_TYPES = ["FS", "SS", "FF", "SF"]
public let LINK_NAMES = [
    "FS": "Finish-to-Start",
    "SS": "Start-to-Start",
    "FF": "Finish-to-Finish",
    "SF": "Start-to-Finish",
]

public struct Lag: Equatable, Hashable, Sendable {
    public var v: Double
    public var u: String
    public init(v: Double, u: String) { self.v = v; self.u = u }
    public static let zero = Lag(v: 0, u: "d")
}

public func noLag() -> Lag { .zero }

private let lagUnits: [String] = ["%", "ed", "edays", "elapsed", "eh", "ehrs", "ehours", "em", "emin", "emins", "ew", "d", "day", "days",
                                  "w", "wk", "wks", "week", "weeks", "h", "hr", "hrs", "hour", "hours", "m", "min", "mins", "minute", "minutes"]

/// Parse a lag string such as "+2d", "-25%", "3 days", "1w", "2ed". Returns a Lag or nil if invalid.
public func parseLag(_ text: String?) -> Lag? {
    let s = String(jsTrim(text ?? "").lowercased().unicodeScalars.filter { !jsWhitespace.contains($0) })
    if s == "" || s == "+" || s == "-" { return noLag() }
    // /^([+-]?\d*\.?\d+)(unit)?$/
    let u = Array(s.utf8)
    var p = 0
    if p < u.count, u[p] == UInt8(ascii: "+") || u[p] == UInt8(ascii: "-") { p += 1 }
    let signEnd = p
    while p < u.count, isAsciiDigit(u[p]) || u[p] == UInt8(ascii: ".") { p += 1 }
    let numBody = String(decoding: u[signEnd..<p], as: UTF8.self)
    let numText = String(decoding: u[0..<p], as: UTF8.self)
    let unitText = String(decoding: u[p...], as: UTF8.self)
    guard isNumberLiteral(numBody) else { return nil }
    guard unitText.isEmpty || lagUnits.contains(unitText) else { return nil }
    let v = jsParseFloat(numText)
    if !v.isFinite { return nil }
    let unit = unitText.isEmpty ? "d" : unitText
    if unit == "%" { return Lag(v: v, u: "%") }
    if unit == "ed" || unit == "edays" || unit == "elapsed" { return Lag(v: v, u: "ed") }
    if unit.hasPrefix("eh") { return Lag(v: v, u: "eh") }
    if unit.hasPrefix("em") { return Lag(v: v, u: "em") }
    if unit == "ew" { return Lag(v: v, u: "ew") }
    if unit.hasPrefix("w") { return Lag(v: v, u: "w") }
    if unit.hasPrefix("h") { return Lag(v: v, u: "h") }
    if unit.hasPrefix("m") { return Lag(v: v, u: "m") }
    return Lag(v: v, u: "d")
}

public func formatLag(_ lag: Lag?) -> String {
    guard let lag = lag, lag.v != 0, !lag.v.isNaN else { return "" }
    let sign = lag.v < 0 ? "-" : "+"
    let a = abs(lag.v)
    let num = a == a.rounded() ? jsNumberString(a) : jsNumberString(jsRound(a * 100) / 100)
    return "\(sign)\(num)\(lag.u == "d" ? "d" : lag.u)"
}

public struct PredParse {
    public var preds: [Pred]
    public var errors: [String]
}

/// Parse a predecessor list typed as text. `idToUid(id)` maps a row ID (1-based row number) to a task uid,
/// or returns nil if there is no such row.
public func parsePredecessors(_ text: String?, _ idToUid: (Int) -> Int?) -> PredParse {
    var preds: [Pred] = []
    var errors: [String] = []
    let parts = (text ?? "").split(omittingEmptySubsequences: false, whereSeparator: { $0 == ";" || $0 == "," })
        .map { jsTrim(String($0)) }.filter { !$0.isEmpty }
    for part in parts {
        // /^(\d+)\s*(FS|SS|FF|SF)?\s*(.*)$/i
        let u = Array(part.utf8)
        var p = 0
        while p < u.count, isAsciiDigit(u[p]) { p += 1 }
        if p == 0 { errors.append("Cannot read \"\(part)\""); continue }
        let idText = String(decoding: u[0..<p], as: UTF8.self)
        var q = p
        while q < u.count, isJSSpace(u[q]) { q += 1 }
        var type = "FS"
        if q + 1 < u.count {
            let two = String(decoding: u[q..<(q + 2)], as: UTF8.self).uppercased()
            if LINK_TYPES.contains(two) { type = two; q += 2; while q < u.count, isJSSpace(u[q]) { q += 1 } }
        }
        let rest = String(decoding: u[q...], as: UTF8.self)
        let id = Int(idText) ?? Int.max
        guard let uid = idToUid(id) else { errors.append("No task with ID \(idText)"); continue }
        guard let lag = parseLag(rest) else { errors.append("Cannot read lag \"\(rest)\" in \"\(part)\""); continue }
        if preds.contains(where: { $0.uid == uid }) { errors.append("Task \(idText) is listed more than once"); continue }
        preds.append(Pred(uid: uid, type: type, lag: lag))
    }
    return PredParse(preds: preds, errors: errors)
}

@inline(__always) func isJSSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D }

/// Format predecessors for display. `uidToId(uid)` returns the row ID.
public func formatPredecessors(_ preds: [Pred]?, _ uidToId: (Int) -> Int?) -> String {
    (preds ?? []).compactMap { p -> String? in
        guard let id = uidToId(p.uid) else { return nil }
        let lag = formatLag(p.lag)
        return "\(id)\(p.type == "FS" && lag.isEmpty ? "" : p.type)\(lag)"
    }.joined(separator: ", ")
}
