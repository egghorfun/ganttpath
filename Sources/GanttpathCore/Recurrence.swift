// Recurring calendar exceptions of MS Project XML (MSPDI), as written by MS Project and by MPXJ from .mpp files.
//
//   Type 1  a plain range of days (FromDate to ToDate)
//   Type 7  every Period days
//   Type 6  every Period weeks, on the days in DaysOfWeek (Sunday = 1, Monday = 2, Tuesday = 4 ... Saturday = 64)
//   Type 5  every Period months, on the MonthPosition-th MonthItem of the month
//   Type 4  every Period months, on day MonthDay
//   Type 3  every year, in Month, on the MonthPosition-th MonthItem
//   Type 2  every year, on Month / MonthDay
//
// Month is 0 for January. MonthPosition is 0 to 3 for the first to the fourth, 4 for the last. MonthItem is 0 for a day,
// 1 for a weekday (Monday to Friday), 2 for a weekend day, 3 to 9 for Sunday to Saturday.
// The recurrence stops after Occurrences dates when EnteredByOccurrences is set, and never goes past ToDate.

public struct RecurringException: Equatable, Sendable {
    public var type: Int
    public var fromDn: Int
    public var toDn: Int
    public var occurrences: Int?
    public var period: Int
    public var daysOfWeek: Int
    public var monthItem: Int
    public var monthPosition: Int
    public var month: Int
    public var monthDay: Int

    public init(type: Int, fromDn: Int, toDn: Int, occurrences: Int? = nil, period: Int = 1, daysOfWeek: Int = 0,
                monthItem: Int = 0, monthPosition: Int = 0, month: Int = 0, monthDay: Int = 1) {
        self.type = type; self.fromDn = fromDn; self.toDn = toDn; self.occurrences = occurrences; self.period = max(1, period)
        self.daysOfWeek = daysOfWeek; self.monthItem = monthItem; self.monthPosition = monthPosition; self.month = month; self.monthDay = monthDay
    }

    /// True for the types that repeat (all but a plain range).
    public var repeats: Bool { type >= 2 && type <= 7 }
}

/// The days of month `m` (1-12) of year `y` that match `item`, in order.
private func monthItemDays(_ y: Int, _ m: Int, _ item: Int) -> [Int] {
    let first = ymdToDn(y, m, 1), last = ymdToDn(y, m + 1, 1) - 1
    return (first...last).filter { dn in
        let w = dow(dn)
        switch item {
        case 0: return true
        case 1: return w >= 1 && w <= 5
        case 2: return w == 0 || w == 6
        case 3...9: return w == item - 3
        default: return false
        }
    }
}

/// The MonthPosition-th (0 to 3, or 4 for the last) day of month `m` of year `y` matching `item`.
private func nthInMonth(_ y: Int, _ m: Int, _ item: Int, _ position: Int) -> Int? {
    let days = monthItemDays(y, m, item)
    if days.isEmpty { return nil }
    if position >= 4 { return days.last }
    return position < days.count ? days[max(0, position)] : nil
}

/// Day `d` of month `m` of year `y`, or the last day of the month when it has fewer days.
private func clampedDay(_ y: Int, _ m: Int, _ d: Int) -> Int {
    let len = ymdToDn(y, m + 1, 1) - ymdToDn(y, m, 1)
    return ymdToDn(y, m, min(max(1, d), len))
}

/// The dates (day numbers) of a recurring exception, oldest first, at most `limit` of them.
/// `weekStart` is the project's first day of the week (0 = Sunday), used to count weeks for "every n weeks".
public func expandRecurringException(_ r: RecurringException, weekStart: Int = 0, limit: Int = 2000) -> [Int] {
    var out: [Int] = []
    let maxCount = min(limit, r.occurrences ?? limit)
    func add(_ dn: Int) -> Bool {
        if dn < r.fromDn { return true }
        if dn > r.toDn || out.count >= maxCount { return false }
        out.append(dn)
        return out.count < maxCount
    }
    let (fy, fm, _) = dnToYmd(r.fromDn)
    switch r.type {
    case 7:
        var d = r.fromDn
        while add(d) { d += r.period }
    case 6:
        guard r.daysOfWeek & 0x7f != 0 else { return [] }
        let week0 = r.fromDn - floorMod(dow(r.fromDn) - weekStart, 7)
        var d = r.fromDn
        while d <= r.toDn && out.count < maxCount {
            let weekIndex = floorDiv(d - week0, 7)
            if weekIndex % r.period == 0 && r.daysOfWeek & (1 << dow(d)) != 0 { if !add(d) { break } }
            d += 1
        }
    case 5, 4:
        var k = 0
        while true {
            let (y, m) = (fy + floorDiv(fm - 1 + k * r.period, 12), floorMod(fm - 1 + k * r.period, 12) + 1)
            if ymdToDn(y, m, 1) > r.toDn { break }
            let day = r.type == 5 ? nthInMonth(y, m, r.monthItem, r.monthPosition) : clampedDay(y, m, r.monthDay)
            if let dn = day, !add(dn) { break }
            k += 1
        }
    case 3, 2:
        var y = fy
        while ymdToDn(y, r.month + 1, 1) <= r.toDn {
            let day = r.type == 3 ? nthInMonth(y, r.month + 1, r.monthItem, r.monthPosition) : clampedDay(y, r.month + 1, r.monthDay)
            if let dn = day, !add(dn) { break }
            y += 1
        }
    default:
        break
    }
    return out
}
