// Working calendars: which days are worked, and during which hours.
//
// A calendar definition (stored in the project file):
//   { id, name,
//     workWeek: [Sun,Mon,Tue,Wed,Thu,Fri,Sat] booleans,
//     hours:    optional, 7 lists (Sun..Sat) of working periods [[startMin, endMin], ...] in minutes since midnight.
//               A working weekday without a list uses DEFAULT_PERIODS (08:00-12:00 and 13:00-17:00 = 8 hours),
//     exceptions: [{ from:'YYYY-MM-DD', to:'YYYY-MM-DD', working:false, name, periods? }] }
// An exception with working:false is a holiday / non-working period; working:true is an extra working day whose hours are
// `periods` (or the calendar's usual hours when none are given). A later exception overrides an earlier one on the same day.
//
// The Cal class answers questions in O(log n) by counting from a fixed origin (1970-01-01):
//   idx(dn)   = number of working DAYS strictly before day dn          nth(k) = the k-th working day (0-based)
//   midx(dn)  = number of working MINUTES strictly before day dn
// A moment is a "tick": dayNumber * 1440 + minuteOfDay (0..1440). Working time is a line of minutes; posOf(tick) is the working
// minute a tick sits on, and startAt(pos) / finishAt(pos) turn a working minute back into a tick. The end of one working period
// and the start of the next are the same working minute, so startAt() gives the later of the two (the moment work resumes) and
// finishAt() the earlier (the moment work stopped).

import Foundation

public let WEEK_PRESETS: [(String, [Bool])] = [
    ("Mon-Fri", [false, true, true, true, true, true, false]),
    ("Mon-Sat", [false, true, true, true, true, true, true]),
    ("Mon-Sun", [true, true, true, true, true, true, true]),
    ("Sun-Thu", [true, true, true, true, true, false, false]),
]
public let MON_FRI: [Bool] = [false, true, true, true, true, true, false]

/// A working period [startMinute, endMinute).
public struct Period: Equatable, Hashable, Sendable {
    public var s: Int
    public var e: Int
    public init(_ s: Int, _ e: Int) { self.s = s; self.e = e }
}

public let DEFAULT_PERIODS: [Period] = [Period(480, 720), Period(780, 1020)]
public let DAY_MIN = 1440

/// A period as stored in a file: two numbers (kept as read, cleaned by normPeriods).
public typealias RawPeriod = [Double]

/// Clean a list of periods: numbers only, inside the day, longer than zero, sorted, overlaps merged. Returns [] when nothing is left.
public func normPeriods(_ list: [RawPeriod]?) -> [Period] {
    guard let list = list else { return [] }
    var a: [Period] = []
    for p in list {
        guard p.count >= 2 else { continue }
        let s = p[0], e = p[1]
        if !s.isFinite || !e.isFinite { continue }
        let s2 = Int(max(0, min(Double(DAY_MIN), jsRound(s)))), e2 = Int(max(0, min(Double(DAY_MIN), jsRound(e))))
        if e2 > s2 { a.append(Period(s2, e2)) }
    }
    a.sort { $0.s < $1.s } // stable in Swift 5+, like Array.prototype.sort
    var out: [Period] = []
    for p in a {
        if let last = out.last, p.s <= last.e { out[out.count - 1].e = max(last.e, p.e) } else { out.append(p) }
    }
    return out
}

public func normPeriods(_ list: [Period]) -> [Period] { normPeriods(list.map { [Double($0.s), Double($0.e)] }) }

public func periodsMinutes(_ periods: [Period]) -> Int { periods.reduce(0) { $0 + ($1.e - $1.s) } }

func hm(_ m: Int) -> String { "\(pad(m / 60)):\(pad(m % 60))" }

/// [[480,720],[780,1020]] -> "08:00-12:00, 13:00-17:00"
public func formatPeriods(_ periods: [Period]?) -> String {
    (periods ?? []).map { "\(hm($0.s))-\(hm($0.e))" }.joined(separator: ", ")
}

nonisolated(unsafe) private let rePeriodHM = /^(\d{1,2}):(\d{2})(am|pm)?$/.asciiOnlyDigits()
nonisolated(unsafe) private let rePeriodH = /^(\d{1,2})(am|pm)?$/.asciiOnlyDigits()
nonisolated(unsafe) private let rePeriodSplit = /\s*(?:-|–|—|to)\s*/.ignoresCase().asciiOnlyDigits()

/// "08:00-12:00, 13:00-17:00" (also "8-12, 1pm-5pm") -> periods, or nil when the text cannot be read. Empty text = no working time.
public func parsePeriods(_ text: String?) -> [Period]? {
    let s = jsTrim(text ?? "")
    if s.isEmpty { return [] }
    func one(_ t: String) -> Int? {
        let x = String(jsTrim(t).lowercased().unicodeScalars.filter { !jsWhitespace.contains($0) })
        var h: Int, mi: Int, ap: String?
        if let m = x.wholeMatch(of: rePeriodHM) {
            h = asciiInt(m.1); mi = asciiInt(m.2); ap = m.3.map(String.init)
        } else if let m = x.wholeMatch(of: rePeriodH) {
            h = asciiInt(m.1); mi = 0; ap = m.2.map(String.init)
        } else { return nil }
        if mi > 59 { return nil }
        if let ap = ap { if h < 1 || h > 12 { return nil }; h = (h % 12) + (ap == "pm" ? 12 : 0) }
        if h > 24 || (h == 24 && mi > 0) { return nil }
        return h * 60 + mi
    }
    var out: [RawPeriod] = []
    for part in s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == ";" }) {
        let bits = String(part).split(separator: rePeriodSplit, omittingEmptySubsequences: false)
        if bits.count != 2 { return nil }
        guard let a = one(String(bits[0])), let b = one(String(bits[1])), b > a else { return nil }
        out.append([Double(a), Double(b)])
    }
    return normPeriods(out)
}

// MARK: - Calendar definition (as stored in the project file)

public struct CalException: Equatable, Sendable {
    public var from: String
    public var to: String?
    public var working: Bool
    public var name: String
    public var periods: [RawPeriod]?
    public var origin: String?
    public var extra = JSONObject()

    public init(from: String, to: String?, working: Bool, name: String, periods: [RawPeriod]? = nil, origin: String? = nil) {
        self.from = from; self.to = to; self.working = working; self.name = name; self.periods = periods; self.origin = origin
    }
}

public struct CalendarDef: Equatable, Sendable {
    public var id: String
    public var name: String
    public var workWeek: [Bool]
    public var hours: [[RawPeriod]]?
    public var exceptions: [CalException]
    public var extra = JSONObject()

    public init(id: String, name: String, workWeek: [Bool], hours: [[RawPeriod]]? = nil, exceptions: [CalException] = []) {
        self.id = id; self.name = name; self.workWeek = workWeek; self.hours = hours; self.exceptions = exceptions
    }
}

public func defaultCalendarDef(_ name: String = "Standard") -> CalendarDef {
    CalendarDef(id: "std", name: name, workWeek: MON_FRI, exceptions: [])
}

let HI = 400000 // upper search bound for day searches (~1100 years after 1970), far beyond any project

public final class Cal: @unchecked Sendable {
    public let def: CalendarDef
    public let stdPeriods: [Period]
    public let exc: [Int: [Period]]  // dn -> periods ([] = non-working)
    public let invalid: Bool
    public let week: [Bool]
    public let weekPeriods: [[Period]]
    public let weekMin: [Int]
    public let perWeek: Int
    public let perWeekMin: Int
    let cum: [Int]
    let cumM: [Int]
    let excDays: [Int]
    let excCum: [Int]
    let excCumM: [Int]

    public init(_ def: CalendarDef) {
        self.def = def
        var week = def.workWeek.count == 7 ? def.workWeek : MON_FRI
        // periods of each weekday
        func hoursOf(_ d: Int) -> [Period] {
            let own = normPeriods(def.hours.flatMap { d < $0.count ? $0[d] : nil })
            return own.isEmpty ? DEFAULT_PERIODS : own
        }
        // what an extra working day (an exception with working:true and no hours of its own) uses: the hours of the first working weekday
        var std: [Period]? = nil
        for d in [1, 2, 3, 4, 5, 6, 0] where week[d] { std = hoursOf(d); break }
        stdPeriods = std ?? DEFAULT_PERIODS
        var exc: [Int: [Period]] = [:]
        for e in def.exceptions {
            guard let a = parseISO(e.from), let b = parseISO((e.to?.isEmpty == false ? e.to : nil) ?? e.from) else { continue }
            let lo = min(a, b), hi = max(a, b)
            if hi - lo > 20000 { continue } // guard against absurd ranges
            var per: [Period] = []
            if e.working { per = normPeriods(e.periods); if per.isEmpty { per = stdPeriods } }
            for d in lo...hi { exc[d] = per }
        }
        self.exc = exc
        let hasWorkingExc = exc.values.contains { !$0.isEmpty }
        invalid = !week.contains(true) && !hasWorkingExc
        if invalid { week = MON_FRI } // never allow a calendar with no working days
        self.week = week
        weekPeriods = (0..<7).map { week[$0] ? hoursOf($0) : [] }
        weekMin = weekPeriods.map(periodsMinutes)
        perWeek = week.filter { $0 }.count
        perWeekMin = weekMin.reduce(0, +)
        // cumulative counts over the first r days of a 7-day cycle that starts at the epoch (a Thursday)
        var cum = [0], cumM = [0]
        for i in 0..<7 {
            cum.append(cum[i] + (week[(4 + i) % 7] ? 1 : 0))
            cumM.append(cumM[i] + weekMin[(4 + i) % 7])
        }
        self.cum = cum; self.cumM = cumM
        // Exception deltas relative to the plain weekly pattern
        var deltas: [(Int, Int, Int)] = []
        for (dn, per) in exc {
            let baseMin = weekMin[dow(dn)]
            let m = periodsMinutes(per)
            if m != baseMin { deltas.append((dn, (m > 0 ? 1 : 0) - (baseMin > 0 ? 1 : 0), m - baseMin)) }
        }
        deltas.sort { $0.0 < $1.0 }
        excDays = deltas.map { $0.0 }
        var ec = [0], ecm = [0]
        for (_, v, vm) in deltas { ec.append(ec[ec.count - 1] + v); ecm.append(ecm[ecm.count - 1] + vm) }
        excCum = ec; excCumM = ecm
    }

    // MARK: days
    /// Working periods of a day: [[startMin, endMin], ...] ([] on a day off).
    @inline(__always) public func periodsOf(_ dn: Int) -> [Period] {
        if let v = exc[dn] { return v }
        return weekPeriods[dow(dn)]
    }

    public func isWorking(_ dn: Int) -> Bool {
        if let v = exc[dn] { return !v.isEmpty }
        return week[dow(dn)]
    }

    /// Working minutes in day dn.
    public func minutesOf(_ dn: Int) -> Int { periodsMinutes(periodsOf(dn)) }

    /// Average working minutes of a working weekday (used only for explanations).
    public var avgDayMin: Double { perWeek > 0 ? Double(perWeekMin) / Double(perWeek) : 0 }

    @inline(__always) func excBefore(_ dn: Int) -> Int {
        var lo = 0, hi = excDays.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if excDays[mid] < dn { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Number of working days strictly before dn.
    public func idx(_ dn: Int) -> Int {
        let w = floorDiv(dn, 7)
        let r = dn - 7 * w
        return w * perWeek + cum[r] + excCum[excBefore(dn)]
    }

    /// Number of working minutes strictly before day dn (i.e. before 00:00 of dn).
    public func midx(_ dn: Int) -> Int {
        let w = floorDiv(dn, 7)
        let r = dn - 7 * w
        return w * perWeekMin + cumM[r] + excCumM[excBefore(dn)]
    }

    /// Day number of the k-th (0-based) working day.
    public func nth(_ k: Int) -> Int {
        var lo = 0, hi = HI
        // smallest dn with idx(dn + 1) >= k + 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if idx(mid + 1) >= k + 1 { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// First working day on or after dn.
    public func next(_ dn: Int) -> Int { isWorking(dn) ? dn : nth(idx(dn)) }

    /// Last working day on or before dn.
    public func prev(_ dn: Int) -> Int { isWorking(dn) ? dn : nth(idx(dn) - 1) }

    /// dn moved by n working days (n may be negative). dn is first snapped to a working day (forward for n >= 0, backward for n < 0).
    public func shift(_ dn: Int, _ n: Int) -> Int {
        if n == 0 { return isWorking(dn) ? dn : next(dn) }
        let base = n > 0 ? next(dn) : prev(dn)
        return nth(idx(base) + n)
    }

    /// Number of working days in [a, b] inclusive (0 if b < a).
    public func count(_ a: Int, _ b: Int) -> Int {
        if b < a { return 0 }
        return idx(b + 1) - idx(a)
    }

    /// Signed working-day distance from a to b (working position difference).
    public func diff(_ a: Int, _ b: Int) -> Int { idx(b) - idx(a) }

    // MARK: moments
    /// Tick of the first working moment of day dn (nil on a day off).
    public func dayStart(_ dn: Int) -> Int? {
        let p = periodsOf(dn)
        return p.isEmpty ? nil : dn * DAY_MIN + p[0].s
    }

    /// Tick of the last working moment of day dn (nil on a day off).
    public func dayEnd(_ dn: Int) -> Int? {
        let p = periodsOf(dn)
        return p.isEmpty ? nil : dn * DAY_MIN + p[p.count - 1].e
    }

    /// The working minute a tick sits on (a tick in non-working time sits on the working minute just before it).
    public func posOf(_ tick: Int) -> Int {
        let dn = floorDiv(tick, DAY_MIN)
        let m = tick - dn * DAY_MIN
        var worked = 0
        for p in periodsOf(dn) {
            if m <= p.s { break }
            worked += min(m, p.e) - p.s
        }
        return midx(dn) + worked
    }

    /// True when the tick lies inside working time (period ends included).
    public func isWorkingMoment(_ tick: Int) -> Bool {
        let dn = floorDiv(tick, DAY_MIN)
        let m = tick - dn * DAY_MIN
        for p in periodsOf(dn) where m >= p.s && m <= p.e { return true }
        return false
    }

    /// The tick at which work that has used `pos` working minutes continues (the later of two equal moments).
    public func startAt(_ pos: Int) -> Int {
        var lo = 0, hi = HI
        while lo < hi { // smallest day whose end lies beyond pos
            let mid = (lo + hi) >> 1
            if midx(mid + 1) > pos { hi = mid } else { lo = mid + 1 }
        }
        var o = pos - midx(lo)
        for p in periodsOf(lo) {
            if o < p.e - p.s { return lo * DAY_MIN + p.s + o }
            o -= p.e - p.s
        }
        return lo * DAY_MIN
    }

    /// The tick at which work that has used `pos` working minutes stopped (the earlier of two equal moments).
    public func finishAt(_ pos: Int) -> Int {
        var lo = 0, hi = HI
        while lo < hi { // smallest day whose end reaches pos
            let mid = (lo + hi) >> 1
            if midx(mid + 1) >= pos { hi = mid } else { lo = mid + 1 }
        }
        var o = pos - midx(lo)
        for p in periodsOf(lo) {
            if o <= p.e - p.s { return lo * DAY_MIN + p.s + o }
            o -= p.e - p.s
        }
        return lo * DAY_MIN
    }

    /// True when the minute is the first start or the last end of work on day dn (a whole-day task begins and ends there).
    public func onBoundary(_ dn: Int, _ min: Int) -> Bool {
        let per = periodsOf(dn)
        if per.isEmpty { return min == 0 || min == DAY_MIN }
        return min == per[0].s || min == per[per.count - 1].e
    }

    /// First working moment at or after the tick.
    public func normStart(_ tick: Int) -> Int { startAt(posOf(tick)) }
    /// Last working moment at or before the tick.
    public func normFinish(_ tick: Int) -> Int { finishAt(posOf(tick)) }
    /// Working minutes from tick a to tick b (negative when b is earlier).
    public func minutesBetween(_ a: Int, _ b: Int) -> Int { posOf(b) - posOf(a) }
}
