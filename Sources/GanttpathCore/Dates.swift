// Date helpers. A "day number" (dn) is the integer count of days since 1970-01-01 (UTC).
// All project dates are stored as ISO strings 'YYYY-MM-DD' and converted to day numbers for arithmetic,
// which avoids time-zone and daylight-saving problems entirely.

import Foundation

public let MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
public let MONTHS_LONG = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
public let DOW_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
public let DOW_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

@inline(__always) func floorDiv(_ a: Int, _ b: Int) -> Int { let q = a / b; return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q }
@inline(__always) func floorMod(_ a: Int, _ b: Int) -> Int { let r = a % b; return r != 0 && ((r < 0) != (b < 0)) ? r + b : r }

/// Days since 1970-01-01 for a proleptic Gregorian date. Month and day may overflow like JavaScript's Date.UTC.
/// Like Date.UTC, a year from 0 to 99 means 1900 + year.
public func ymdToDn(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    var y = y0
    if y >= 0 && y <= 99 { y += 1900 }
    // normalise the month
    let mm = m - 1
    y += floorDiv(mm, 12)
    let mon = floorMod(mm, 12) + 1
    return daysFromCivil(y, mon, 1) + (d - 1)
}

/// Howard Hinnant's days_from_civil.
func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = floorDiv(y, 400)
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

public func dnToYmd(_ dn: Int) -> (y: Int, m: Int, d: Int) {
    let z = dn + 719468
    let era = floorDiv(z, 146097)
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

@inline(__always) func isAsciiDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }

/// ISO 'YYYY-MM-DD' (optionally followed by anything, e.g. a time) -> day number, or nil if invalid.
public func parseISO(_ s: String?) -> Int? {
    guard let s = s else { return nil }
    var u = s.utf8.makeIterator()
    var b = [UInt8]()
    b.reserveCapacity(10)
    for _ in 0..<10 { guard let c = u.next() else { return nil }; b.append(c) }
    guard isAsciiDigit(b[0]), isAsciiDigit(b[1]), isAsciiDigit(b[2]), isAsciiDigit(b[3]), b[4] == 45,
          isAsciiDigit(b[5]), isAsciiDigit(b[6]), b[7] == 45, isAsciiDigit(b[8]), isAsciiDigit(b[9]) else { return nil }
    let y = Int(b[0] - 48) * 1000 + Int(b[1] - 48) * 100 + Int(b[2] - 48) * 10 + Int(b[3] - 48)
    let mo = Int(b[5] - 48) * 10 + Int(b[6] - 48)
    let d = Int(b[8] - 48) * 10 + Int(b[9] - 48)
    if mo < 1 || mo > 12 || d < 1 || d > 31 { return nil }
    let dn = ymdToDn(y, mo, d)
    let back = dnToYmd(dn)
    if back.y != y || back.m != mo || back.d != d { return nil }
    return dn
}

@inline(__always) func pad(_ n: Int, _ w: Int = 2) -> String {
    let s = String(n)
    return s.count >= w ? s : String(repeating: "0", count: w - s.count) + s
}

public func toISO(_ dn: Int) -> String {
    let (y, m, d) = dnToYmd(dn)
    return "\(pad(y, 4))-\(pad(m))-\(pad(d))"
}

/// Day of week, 0 = Sunday ... 6 = Saturday. (1970-01-01 was a Thursday.)
@inline(__always) public func dow(_ dn: Int) -> Int { floorMod(dn + 4, 7) }

public func todayDn() -> Int {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    return ymdToDn(c.year!, c.month!, c.day!)
}

// A date format is a pattern of tokens: YYYY YY (year), MMMM MMM MM M (month), DD D (day); anything else is copied as it is.
public let DATE_FORMATS = [
    "DD-MMM-YYYY", "DD/MM/YYYY", "MM/DD/YYYY", "YYYY-MM-DD",
    "DD-MMM-YY", "DD MMM YYYY", "DD MMMM YYYY", "MMM DD, YYYY", "MMMM DD, YYYY",
    "DD.MM.YYYY", "DD/MM/YY", "MM/DD/YY", "D/M/YYYY", "M/D/YYYY", "YYYY/MM/DD", "YYYY.MM.DD", "YY-MM-DD",
]

public func formatDate(_ dn: Int?, _ fmt: String? = "DD-MMM-YYYY") -> String {
    guard let dn = dn else { return "" }
    let (y, m, d) = dnToYmd(dn)
    let f = DATE_FORMATS.contains(fmt ?? "") ? fmt! : "DD-MMM-YYYY"
    var out = ""
    var i = f.startIndex
    let tokens = ["YYYY", "YY", "MMMM", "MMM", "MM", "M", "DD", "D"]
    outer: while i < f.endIndex {
        for t in tokens where f[i...].hasPrefix(t) {
            switch t {
            case "YYYY": out += pad(y, 4)
            case "YY": out += pad(floorMod(y, 100))
            case "MMMM": out += MONTHS_LONG[m - 1]
            case "MMM": out += MONTHS[m - 1]
            case "MM": out += pad(m)
            case "M": out += String(m)
            case "DD": out += pad(d)
            default: out += String(d)
            }
            i = f.index(i, offsetBy: t.count)
            continue outer
        }
        out.append(f[i])
        i = f.index(after: i)
    }
    return out
}

/// True when a numeric date such as 05/10/2026 is read month first under this format (MM/DD/YYYY, M/D/YYYY, MM/DD/YY).
func monthFirst(_ fmt: String?) -> Bool {
    let f = fmt ?? ""
    // /^M{1,2}(?!M)/
    if f.hasPrefix("MMM") { return false }
    return f.hasPrefix("M")
}
/// True when a format starts with the year (YYYY-MM-DD, YY-MM-DD): a 2-digit first number is then the year.
func yearFirst(_ fmt: String?) -> Bool { (fmt ?? "").hasPrefix("Y") }

public func formatDateWithDow(_ dn: Int, _ fmt: String?) -> String {
    "\(DOW_SHORT[dow(dn)]) \(formatDate(dn, fmt))"
}

nonisolated(unsafe) private let leadingWeekday = /^(?:sun|mon|tue|wed|thu|fri|sat)[a-z]*\.?[\s,]+/.ignoresCase().asciiOnlyDigits()
nonisolated(unsafe) private let reYMD = /^(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})$/.asciiOnlyDigits()
nonisolated(unsafe) private let reDMonY = /^(\d{1,2})[\s\-\/.]([A-Za-z]{3,9})[\s\-\/.,]*(\d{2,4})$/.asciiOnlyDigits()
nonisolated(unsafe) private let reMonDY = /^([A-Za-z]{3,9})[\s\-\/.]*(\d{1,2})[\s,\-\/.]+(\d{2,4})$/.asciiOnlyDigits()
nonisolated(unsafe) private let reYYMD = /^(\d{2})[-\/.](\d{1,2})[-\/.](\d{1,2})$/.asciiOnlyDigits()
nonisolated(unsafe) private let reNumeric = /^(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{2,4})$/.asciiOnlyDigits()
nonisolated(unsafe) private let reIsoPrefix = /^\d{4}-\d{1,2}-\d{1,2}/.asciiOnlyDigits()

@inline(__always) func asciiInt(_ s: Substring) -> Int {
    var v = 0
    for c in s.utf8 { v = v * 10 + Int(c) - 48 }
    return v
}

/// Trim like JavaScript's String.prototype.trim.
public func jsTrim(_ s: String) -> String { s.trimmingCharacters(in: jsWhitespace) }

/// Forgiving date parser for typed input. Accepts ISO, DD-MMM-YYYY, "5 Oct 26", "Oct 5 2026",
/// and numeric d/m/y or m/d/y according to `fmt`; a leading weekday name is ignored. Returns a day number or nil.
public func parseDateInput(_ str: String?, _ fmt: String? = "DD-MMM-YYYY") -> Int? {
    guard let str = str else { return nil }
    var s = jsTrim(str)
    // A leading weekday ("Fri 30-Oct-2026", "Friday, 30 Oct 2026") is allowed and ignored: the date itself decides the day.
    if let m = s.prefixMatch(of: leadingWeekday) { s = String(s[m.range.upperBound...]) }
    if s.isEmpty { return nil }
    if let iso = parseISO(s), s.prefixMatch(of: reIsoPrefix) != nil { return iso }
    func fixYear(_ y: Int) -> Int { y < 100 ? (y >= 70 ? 1900 + y : 2000 + y) : y }
    if let m = s.wholeMatch(of: reYMD) { return validYmd(asciiInt(m.1), asciiInt(m.2), asciiInt(m.3)) }
    if let m = s.wholeMatch(of: reDMonY) {
        let mo = monthIndex(String(m.2))
        if mo > 0 { return validYmd(fixYear(asciiInt(m.3)), mo, asciiInt(m.1)) }
    }
    if let m = s.wholeMatch(of: reMonDY) {
        let mo = monthIndex(String(m.1))
        if mo > 0 { return validYmd(fixYear(asciiInt(m.3)), mo, asciiInt(m.2)) }
    }
    if yearFirst(fmt) {
        if let m = s.wholeMatch(of: reYYMD) { return validYmd(fixYear(asciiInt(m.1)), asciiInt(m.2), asciiInt(m.3)) }
    }
    if let m = s.wholeMatch(of: reNumeric) {
        let a = asciiInt(m.1), b = asciiInt(m.2), y = fixYear(asciiInt(m.3))
        return monthFirst(fmt) ? validYmd(y, a, b) : validYmd(y, b, a)
    }
    return nil
}

func monthIndex(_ name: String) -> Int {
    let k = String(name.prefix(3)).lowercased()
    if let i = MONTHS.firstIndex(where: { $0.lowercased() == k }) { return i + 1 }
    return 0
}

func validYmd(_ y: Int, _ m: Int, _ d: Int) -> Int? {
    if m < 1 || m > 12 || d < 1 || d > 31 { return nil }
    let dn = ymdToDn(y, m, d)
    let b = dnToYmd(dn)
    return b.y == y && b.m == m && b.d == d ? dn : nil
}

// MARK: - times of day
// A "stamp" is a date with an optional time of day: 'YYYY-MM-DD' (whole day) or 'YYYY-MM-DDTHH:MM'. Times are minutes since
// midnight (0..1440; 1440 = 24:00 = the end of the day).

/// minutes since midnight -> 'HH:MM' (1440 -> '24:00').
public func fmtHM(_ min: Int) -> String {
    let m = max(0, min)
    return "\(pad(floorDiv(m, 60))):\(pad(m % 60))"
}

nonisolated(unsafe) private let reHM = /^(\d{1,2}):(\d{2})(?::\d{2})?(am|pm)?$/.asciiOnlyDigits()
nonisolated(unsafe) private let reHAP = /^(\d{1,2})(am|pm)$/.asciiOnlyDigits()

/// 'HH:MM', 'H:MM', '1:30 pm', '1pm', '24:00' -> minutes since midnight, or nil.
public func parseHM(_ text: String?) -> Int? {
    let s = String(jsTrim(text ?? "").lowercased().unicodeScalars.filter { !jsWhitespace.contains($0) })
    var h: Int, mi: Int, ap: String?
    if let m = s.wholeMatch(of: reHM) {
        h = asciiInt(m.1); mi = asciiInt(m.2); ap = m.3.map(String.init)
    } else if let m = s.wholeMatch(of: reHAP) {
        h = asciiInt(m.1); mi = 0; ap = String(m.2)
    } else { return nil }
    if mi > 59 { return nil }
    if let ap = ap { if h < 1 || h > 12 { return nil }; h = (h % 12) + (ap == "pm" ? 12 : 0) }
    if h > 24 || (h == 24 && mi > 0) { return nil }
    return h * 60 + mi
}

public struct Stamp: Equatable, Sendable {
    public var dn: Int
    public var min: Int?
    public init(dn: Int, min: Int?) { self.dn = dn; self.min = min }
}

/// 'YYYY-MM-DD' or 'YYYY-MM-DDTHH:MM' (a space instead of the T is accepted) -> Stamp (min nil when there is no time), or nil.
public func parseStamp(_ s: String?) -> Stamp? {
    guard let s = s, let dn = parseISO(s) else { return nil }
    // /^\d{4}-\d{2}-\d{2}[T\s](\d{1,2}:\d{2})/
    let u = Array(s.utf8)
    guard u.count > 11 else { return Stamp(dn: dn, min: nil) }
    let sep = u[10]
    let isSpace = sep == 0x20 || sep == 0x09 || sep == 0x0A || sep == 0x0D || sep == 0x0B || sep == 0x0C
    guard sep == UInt8(ascii: "T") || isSpace else { return Stamp(dn: dn, min: nil) }
    var p = 11
    var h = 0, hd = 0
    while p < u.count, hd < 2, isAsciiDigit(u[p]) { h = h * 10 + Int(u[p] - 48); p += 1; hd += 1 }
    guard hd >= 1, p < u.count, u[p] == UInt8(ascii: ":") else { return Stamp(dn: dn, min: nil) }
    p += 1
    guard p + 1 < u.count, isAsciiDigit(u[p]), isAsciiDigit(u[p + 1]) else { return Stamp(dn: dn, min: nil) }
    let mi = Int(u[p] - 48) * 10 + Int(u[p + 1] - 48)
    // parseHM of "H:MM"
    // an unreadable time (parseHM gives null in the JavaScript app) leaves just the date
    if mi > 59 || h > 24 || (h == 24 && mi > 0) { return Stamp(dn: dn, min: nil) }
    return Stamp(dn: dn, min: h * 60 + mi)
}

public func toStamp(_ dn: Int, _ min: Int?) -> String {
    guard let min = min else { return toISO(dn) }
    return "\(toISO(dn))T\(fmtHM(min))"
}

nonisolated(unsafe) private let reTimeTail = /(?:^|[\sT])(\d{1,2}:\d{2}(?::\d{2})?\s*(?:[ap]m)?|\d{1,2}\s*[ap]m)\s*$/.ignoresCase().asciiOnlyDigits()

/// The time typed at the end of a date text ("13:00" in "30-Oct-2026 13:00"), or ''.
public func timeTail(_ text: String?) -> String {
    let s = jsTrim(text ?? "")
    guard let m = s.firstMatch(of: reTimeTail) else { return "" }
    return jsTrim(String(m.1))
}

/// Typed text with an optional time at the end ("30-Oct-2026 13:00", "Fri 30 Oct 2026 1:00 pm") -> Stamp or nil.
public func parseDateTimeInput(_ text: String?, _ fmt: String? = "DD-MMM-YYYY") -> Stamp? {
    let s = jsTrim(text ?? "")
    var datePart = s
    var min: Int? = nil
    if let m = s.firstMatch(of: reTimeTail) {
        guard let v = parseHM(String(m.1)) else { return nil }
        min = v
        datePart = jsTrim(String(s[s.startIndex..<m.range.lowerBound]))
    }
    guard let dn = parseDateInput(datePart, fmt) else { return nil }
    return Stamp(dn: dn, min: min)
}

public func formatDateTime(_ dn: Int, _ min: Int?, _ fmt: String? = "DD-MMM-YYYY") -> String {
    let d = formatDate(dn, fmt)
    guard let min = min else { return d }
    return "\(d) \(fmtHM(min))"
}

public func addMonthsDn(_ dn: Int, _ n: Int) -> Int {
    let (y, m, d) = dnToYmd(dn)
    let t = (y * 12 + (m - 1)) + n
    let ny = floorDiv(t, 12), nm = floorMod(t, 12) + 1
    let dim = dnToYmd(ymdToDn(ny, nm + 1, 1) - 1).d
    return ymdToDn(ny, nm, min(d, dim))
}

public func startOfMonthDn(_ dn: Int) -> Int {
    let (y, m, _) = dnToYmd(dn)
    return ymdToDn(y, m, 1)
}

public func endOfMonthDn(_ dn: Int) -> Int {
    let (y, m, _) = dnToYmd(dn)
    return ymdToDn(y, m + 1, 1) - 1
}

/// Local timestamp for filenames: YYYY-MM-DD_HHmm (and _HHmmss for seconds precision).
public func stampFromDate(_ dt: Date = Date(), withSeconds: Bool = false) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: dt)
    let base = "\(c.year!)-\(pad(c.month!))-\(pad(c.day!))_\(pad(c.hour!))\(pad(c.minute!))"
    return withSeconds ? base + pad(c.second!) : base
}
