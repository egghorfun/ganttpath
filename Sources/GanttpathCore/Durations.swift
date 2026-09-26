// Durations and other spans of working time.
//
// MS Project way: a duration is stored as working MINUTES ("dur") plus the unit it is shown in ("durUnit"). The project has one
// "Hours per day" setting (default 8) that says how long a "day" is when a duration is typed or shown in days; it is separate
// from the working hours of the calendars. "Hours per week" (default 40) does the same for weeks, and "Days per month"
// (default 20, like MS Project's own field) does the same for months: one flat number of working days used for every month,
// wherever it falls in the calendar - not the actual (28-31 day) length of that particular month.

import Foundation

public let DEFAULT_HOURS_PER_DAY: Double = 8
public let DEFAULT_HOURS_PER_WEEK: Double = 40
public let DEFAULT_DAYS_PER_MONTH: Double = 20

public let UNITS = ["m", "h", "d", "w", "mo"]
public let UNIT_NAMES = ["m": "minutes", "h": "hours", "d": "days", "w": "weeks", "mo": "months"]

@inline(__always) func positiveOr(_ v: Double?, _ d: Double) -> Double {
    guard let v = v, v.isFinite, v > 0 else { return d }
    return v
}
/// Minutes in one "day" for durations (Hours per day x 60).
public func dayMinOf(_ s: Settings?) -> Int { jsRoundInt(positiveOr(s?.hoursPerDay, DEFAULT_HOURS_PER_DAY) * 60) }
/// Minutes in one "week" for durations (Hours per week x 60).
public func weekMinOf(_ s: Settings?) -> Int { jsRoundInt(positiveOr(s?.hoursPerWeek, DEFAULT_HOURS_PER_WEEK) * 60) }
/// Working days in one "month" for durations (the project's "Days per month" setting).
public func monthDaysOf(_ s: Settings?) -> Double { positiveOr(s?.daysPerMonth, DEFAULT_DAYS_PER_MONTH) }

/// Minutes in one unit.
public func unitMinutes(_ unit: String, _ s: Settings?) -> Double {
    switch unit {
    case "m": return 1
    case "h": return 60
    case "w": return Double(weekMinOf(s))
    case "mo": return monthDaysOf(s) * Double(dayMinOf(s))
    default: return Double(dayMinOf(s))
    }
}

/// Working minutes of a task (the stored `dur`).
public func taskMin(_ t: Task, _ s: Settings?) -> Int { max(0, t.dur) }

private let UNIT_WORDS: [(String, Set<String>)] = [
    ("mo", ["mo", "mos", "mon", "mons", "month", "months"]),
    ("w", ["w", "wk", "wks", "week", "weeks"]),
    ("d", ["d", "dy", "dys", "day", "days"]),
    ("h", ["h", "hr", "hrs", "hour", "hours"]),
    ("m", ["m", "min", "mins", "minute", "minutes"]),
]

public struct DurationSpec: Equatable, Sendable {
    public var min: Int
    public var unit: String
    public init(min: Int, unit: String) { self.min = min; self.unit = unit }
}

/// Read a typed duration: "5", "5d", "2 weeks", "1mo", "6h", "1.5 hrs", "45m". A bare number uses `defaultUnit` (days unless told).
/// Returns (min, unit) or nil. Only zero or positive values are valid.
public func parseDuration(_ text: String?, _ s: Settings?, _ defaultUnit: String = "d") -> DurationSpec? {
    let str = String(jsTrim(text ?? "").lowercased().unicodeScalars.filter { !jsWhitespace.contains($0) })
    if str.isEmpty { return nil }
    // /^(\d*\.?\d+)([a-z]*)$/
    let u = Array(str.utf8)
    var p = 0
    while p < u.count, isAsciiDigit(u[p]) || u[p] == UInt8(ascii: ".") { p += 1 }
    let numText = String(decoding: u[0..<p], as: UTF8.self)
    let rest = String(decoding: u[p...], as: UTF8.self)
    guard isNumberLiteral(numText), rest.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { return nil }
    let v = jsParseFloat(numText)
    if !v.isFinite || v < 0 { return nil }
    var unit = defaultUnit
    if !rest.isEmpty {
        guard let hit = UNIT_WORDS.first(where: { $0.1.contains(rest) }) else { return nil }
        unit = hit.0
    }
    return DurationSpec(min: jsRoundInt(v * unitMinutes(unit, s)), unit: unit)
}

/// \d*\.?\d+  — digits, optionally one dot, at least one digit after it.
func isNumberLiteral(_ s: String) -> Bool {
    let u = Array(s.utf8)
    if u.isEmpty { return false }
    guard let last = u.last, isAsciiDigit(last) else { return false }
    return u.filter { $0 == UInt8(ascii: ".") }.count <= 1
}

@inline(__always) public func round2(_ x: Double) -> Double { jsRound(x * 100) / 100 }
private let SUFFIX = ["m": "m", "h": "h", "d": "d", "w": "w", "mo": "mo"]

/// 2400, 'd' -> "5d"; 360, 'h' -> "6h"; 360, 'd' -> "0.75d".
public func formatDuration(_ min: Int?, _ unit: String?, _ s: Settings?) -> String {
    guard let min = min else { return "" }
    let u = UNITS.contains(unit ?? "") ? unit! : "d"
    return "\(jsNumberString(round2(Double(min) / unitMinutes(u, s))))\(SUFFIX[u]!)"
}

/// Number typed back into the editor: same as formatDuration.
public func durationEditText(_ min: Int?, _ unit: String?, _ s: Settings?) -> String { formatDuration(min, unit, s) }

/// A span such as slack: whole days as days ("3d"), less than a day in hours ("4h"), otherwise days with decimals ("2.5d").
public func formatSpan(_ min: Int?, _ s: Settings?) -> String {
    guard let min = min else { return "" }
    let dm = dayMinOf(s)
    if min == 0 { return "0d" }
    if min % dm == 0 { return "\(min / dm)d" }
    if abs(min) < dm { return "\(jsNumberString(round2(Double(min) / 60)))h" }
    return "\(jsNumberString(round2(Double(min) / Double(dm))))d"
}

/// Working minutes -> days of the project (may be fractional).
public func minToDays(_ min: Int?, _ s: Settings?) -> Double? {
    guard let min = min else { return nil }
    return Double(min) / Double(dayMinOf(s))
}
