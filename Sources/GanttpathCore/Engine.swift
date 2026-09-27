// Scheduling engine: MS Project style forward/backward pass at working-minute resolution.
//
// TIME MODEL. Every moment is an integer "tick" = dayNumber * 1440 + minuteOfDay (see Calendar.swift). Working time is a line of
// working minutes per calendar; a task of D working minutes that starts at working minute p finishes at working minute p + D.
// The end of one working period and the start of the next are the same working minute but different ticks: a task that finishes
// Friday 17:00 leaves a milestone on Friday 17:00 (date Friday), while a task that starts after it starts Monday 08:00.
// Durations are stored in working minutes; a "day" is the project's Hours-per-day setting (MS Project's rule), which is separate
// from the working hours of the calendars. Lead/lag is applied in working time using the SUCCESSOR's calendar (MS Project rule).
// Dates typed without a time mean the start (for starts) or the end (for finishes) of that working day.

import Foundation

public let CONSTRAINTS = ["ASAP", "ALAP", "MSO", "MFO", "SNET", "SNLT", "FNET", "FNLT"]
public let CONSTRAINT_NAMES = [
    "ASAP": "As Soon As Possible",
    "ALAP": "As Late As Possible",
    "MSO": "Must Start On",
    "MFO": "Must Finish On",
    "SNET": "Start No Earlier Than",
    "SNLT": "Start No Later Than",
    "FNET": "Finish No Earlier Than",
    "FNLT": "Finish No Later Than",
]
public let CONSTRAINT_NEEDS_DATE = ["ASAP": false, "ALAP": false, "MSO": true, "MFO": true, "SNET": true, "SNLT": true, "FNET": true, "FNLT": true]

public func summaryFlags(_ tasks: [Task]) -> [Bool] {
    tasks.indices.map { i in i + 1 < tasks.count && tasks[i + 1].level > tasks[i].level }
}

/// Outline numbers ("1", "1.1", "1.1.2") for every task, based on outline levels.
public func computeWBS(_ tasks: [Task]) -> [String] {
    var counters: [Int] = []
    var out: [String] = []
    out.reserveCapacity(tasks.count)
    for t in tasks {
        let lv = max(1, t.level)
        if counters.count > lv { counters.removeLast(counters.count - lv) }
        while counters.count < lv { counters.append(0) }
        counters[lv - 1] += 1
        out.append(counters.prefix(lv).map(String.init).joined(separator: "."))
    }
    return out
}

public func parentIndexes(_ tasks: [Task]) -> [Int] {
    var stack: [Int] = []
    var parents = Array(repeating: -1, count: tasks.count)
    for i in tasks.indices {
        while let last = stack.last, tasks[last].level >= tasks[i].level { stack.removeLast() }
        parents[i] = stack.last ?? -1
        stack.append(i)
    }
    return parents
}

/// A lag as working (or elapsed) minutes. Elapsed lags count calendar time; all others count working time of the successor's calendar.
func lagMinutes(_ lag: Lag, _ predMin: Int, _ dayMin: Int, _ weekMin: Int) -> (n: Int, elapsed: Bool) {
    let v = lag.v
    if v == 0 || v.isNaN { return (0, false) }
    switch lag.u {
    case "%":
        let x = (v / 100) * Double(predMin)
        let r = jsRound(abs(x))
        return (x < 0 ? -Int(r) : Int(r), false)
    case "w": return (jsRoundInt(v * Double(weekMin)), false)
    case "h": return (jsRoundInt(v * 60), false)
    case "m": return (jsRoundInt(v), false)
    case "ed": return (jsRoundInt(v * 1440), true)
    case "eh": return (jsRoundInt(v * 60), true)
    case "em": return (jsRoundInt(v), true)
    case "ew": return (jsRoundInt(v * 10080), true)
    default: return (jsRoundInt(v * Double(dayMin)), false)
    }
}

public struct Conflict: Equatable, Sendable {
    public var index: Int
    public var uid: Int
    public var type: String
    public var message: String
}

public struct ScheduledTask: Equatable, Sendable {
    public var index: Int
    public var uid: Int
    public var id: Int
    public var wbs: String
    public var parent: Int
    public var children: [Int]
    public var isSummary: Bool
    public var isManual: Bool
    public var inactive: Bool
    public var hideBar: Bool
    public var rollup: Bool
    public var onTimeline: Bool
    public var priority: Int
    public var taskType: String
    public var isMilestone: Bool
    public var start: String?
    public var finish: String?
    public var startMin: Int?
    public var finishMin: Int?
    public var startStamp: String?
    public var finishStamp: String?
    public var timed: Bool
    public var startFrac: Double?
    public var finishFrac: Double?
    public var startTick: Int?
    public var finishTick: Int?
    public var duration: Double
    public var durationMin: Int
    public var durUnit: String
    public var lateStart: String?
    public var lateFinish: String?
    public var lateStartMin: Int?
    public var lateFinishMin: Int?
    public var totalSlack: Double?
    public var freeSlack: Double?
    public var totalSlackMin: Int?
    public var freeSlackMin: Int?
    public var critical: Bool
    public var nearCritical: Bool
    public var pct: Double
    public var conflicts: [Conflict]
    public var hasConflict: Bool
    public var childConflict: Bool
}

public struct ScheduledLink: Equatable, Sendable {
    public var predUid: Int
    public var uid: Int
    public var pIndex: Int
    public var tIndex: Int
    public var type: String
    public var lag: Lag
    public var conflict: Bool
}

public struct ScheduleResult: Equatable, Sendable {
    public var tasks: [ScheduledTask]
    public var projectStart: String?
    public var projectFinish: String?
    public var conflicts: [Conflict]
    public var conflictCount: Int
    public var links: [ScheduledLink]
    public var cycles: [Int]
    public var calendarInvalid: Bool
    public var dayMin: Int
    public var weekMin: Int
}

private struct Link {
    var p: Int
    var t: Int
    var type: String
    var lag: Lag
    var inherited = false
}

/// Compute the schedule for a project. Pure: does not modify `project`.
public func schedule(_ project: Project) -> ScheduleResult {
    let T = project.tasks
    let n = T.count
    let settings = project.settings
    let honor = settings.honorConstraints != false
    let dayMin = dayMinOf(settings)
    let weekMin = weekMinOf(settings)
    let critLimit = (settings.criticalSlackDays.isFinite ? settings.criticalSlackDays : 0) * Double(dayMin) // in minutes
    let nearLimit = (settings.nearCriticalDays.isFinite ? settings.nearCriticalDays : 2) * Double(dayMin)

    // ---- calendars
    var calMap: [String: Cal] = [:]
    var calOrder: [Cal] = []
    for def in project.calendars {
        let c = Cal(def)
        if calMap[def.id] == nil { calOrder.append(c) } else if let k = calOrder.firstIndex(where: { $0.def.id == def.id }) { calOrder[k] = c }
        calMap[def.id] = c
    }
    let projCal: Cal = calMap[settings.defaultCalendarId] ?? calOrder.first ?? Cal(CalendarDef(id: "", name: "", workWeek: MON_FRI, exceptions: []))
    // ---- structure
    let isSummary = summaryFlags(T)
    // an elapsed-duration task runs round the clock (MS Project: 24 hours a day, 7 days a week, holidays included)
    let calOf: [Cal] = T.enumerated().map { i, t in
        if !isSummary[i] && isElapsedUnit(t.durUnit) { return ELAPSED_CAL }
        return (t.calendarId.flatMap { $0.isEmpty ? nil : calMap[$0] }) ?? projCal
    }
    // An inactive task stays in the plan but takes no part in the schedule (MS Project): its links are ignored, it keeps the dates it
    // had, it is not part of its summary task or of the project dates, and it has no slack and is never critical.
    let inactive = (0..<n).map { !isSummary[$0] && T[$0].inactive }
    let parent = parentIndexes(T)
    let wbs = computeWBS(T)
    var children = Array(repeating: [Int](), count: n)
    for i in 0..<n where parent[i] >= 0 { children[parent[i]].append(i) }
    var uidIndex: [Int: Int] = [:]
    for (i, t) in T.enumerated() { uidIndex[t.uid] = i } // a later duplicate wins, like Map.set
    func descendantsLeaf(_ i: Int, _ acc: inout [Int]) {
        for c in children[i] { if isSummary[c] { descendantsLeaf(c, &acc) } else { acc.append(c) } }
    }

    // ---- links
    // raw links (as the user defined them) for conflict checking / display
    var rawLinks: [Link] = []
    for j in 0..<n {
        for p in T[j].preds {
            guard let i = uidIndex[p.uid], i != j else { continue }
            if inactive[i] || inactive[j] { continue }
            rawLinks.append(Link(p: i, t: j, type: p.type.isEmpty ? "FS" : p.type, lag: p.lag))
        }
    }
    // scheduling links: a link INTO a summary task is inherited by its leaf descendants (start-based types only)
    var schedLinks: [Link] = []
    for L in rawLinks {
        if !isSummary[L.t] { schedLinks.append(L); continue }
        if L.type == "FS" || L.type == "SS" {
            var leaves: [Int] = []
            descendantsLeaf(L.t, &leaves)
            if leaves.contains(L.p) { continue } // a link from a task to its own summary is meaningless; ignore
            for d in leaves { schedLinks.append(Link(p: L.p, t: d, type: L.type, lag: L.lag, inherited: true)) }
        }
    }
    var inc = Array(repeating: [Link](), count: n) // incoming scheduling links per node
    var out = Array(repeating: [Link](), count: n) // outgoing scheduling links per node
    for L in schedLinks { inc[L.t].append(L); out[L.p].append(L) }

    // ---- topological order over nodes: link edges + child -> parent summary edges
    var indeg = Array(repeating: 0, count: n)
    var adj = Array(repeating: [Int](), count: n)
    for L in schedLinks { adj[L.p].append(L.t); indeg[L.t] += 1 }
    for i in 0..<n where parent[i] >= 0 { adj[i].append(parent[i]); indeg[parent[i]] += 1 }
    var order: [Int] = []
    order.reserveCapacity(n)
    do {
        var deg = indeg
        var q: [Int] = []
        for i in 0..<n where deg[i] == 0 { q.append(i) }
        var h = 0
        while h < q.count {
            let a = q[h]
            h += 1
            order.append(a)
            for b in adj[a] { deg[b] -= 1; if deg[b] == 0 { q.append(b) } }
        }
    }
    var inOrder = Array(repeating: false, count: n)
    for i in order { inOrder[i] = true }
    var cycleNodes: [Int] = []
    for i in 0..<n where !inOrder[i] { cycleNodes.append(i); order.append(i) }
    let cycleSet = Set(cycleNodes)

    // ---- tick helpers. A calendar c turns working minutes into ticks and back (see Calendar.swift).
    func normZero(_ c: Cal, _ t: Int) -> Int { c.isWorkingMoment(t) ? t : c.normStart(t) }
    func finishFromStart(_ c: Cal, _ s: Int, _ d: Int) -> Int { d > 0 ? c.finishAt(c.posOf(s) + d) : s }
    func startFromFinish(_ c: Cal, _ f: Int, _ d: Int) -> Int { d > 0 ? c.startAt(c.posOf(f) - d) : f }
    /// Latest working moment a task can start at, given a limit that may fall outside working time (day level, as MS Project shows it).
    /// (Before a calendar's first working day there is no such day; the JavaScript app then computes with null, which acts as 0.)
    func snapStartBack(_ c: Cal, _ t: Int) -> Int { c.isWorkingMoment(t) ? t : (c.dayStart(c.prev(floorDiv(t, DAY_MIN))) ?? 0) }
    func pos(_ c: Cal, _ t: Int) -> Int { c.posOf(t) }
    // A date typed without a time means the start of that working day (for a start) or the end of it (for a finish).
    // (For an elapsed task, on the round-the-clock calendar, that working day is the project calendar's: see elapsedTick.)
    func startDay(_ c: Cal, _ dn: Int) -> Int {
        if c === ELAPSED_CAL { return elapsedTick(projCal, Stamp(dn: dn, min: nil), finish: false) }
        return c.dayStart(dn) ?? dn * DAY_MIN
    }
    func endDay(_ c: Cal, _ dn: Int) -> Int {
        if c === ELAPSED_CAL { return elapsedTick(projCal, Stamp(dn: dn, min: nil), finish: true) }
        return c.dayEnd(dn) ?? (dn + 1) * DAY_MIN
    }
    /// First moment a task (or milestone) can start at when a date (or date and time) is required as its start.
    func startFromStamp(_ c: Cal, _ st: Stamp, _ zero: Bool) -> Int {
        if c === ELAPSED_CAL { return elapsedTick(projCal, st, finish: false) }
        let t = st.dn * DAY_MIN + (st.min ?? 0)
        return zero && st.min != nil ? normZero(c, t) : c.normStart(t)
    }
    /// Moment a task can finish at when a date (or date and time) is required as its finish.
    func finishFromStamp(_ c: Cal, _ st: Stamp, _ zero: Bool) -> Int {
        if c === ELAPSED_CAL { return elapsedTick(projCal, st, finish: !zero || st.min != nil) }
        guard let m = st.min else {
            if !zero { return c.normFinish((st.dn + 1) * DAY_MIN) }
            return c.isWorking(st.dn) ? c.dayEnd(st.dn)! : c.normStart((st.dn + 1) * DAY_MIN)
        }
        let t = st.dn * DAY_MIN + m
        return zero ? normZero(c, t) : c.normFinish(t)
    }
    /// Latest finish allowed by a "no later than" date: the last working moment at or before it.
    func finishCap(_ c: Cal, _ st: Stamp) -> Int {
        if c === ELAPSED_CAL { return elapsedTick(projCal, st, finish: true) }
        return c.normFinish(st.min == nil ? (st.dn + 1) * DAY_MIN : st.dn * DAY_MIN + st.min!)
    }
    func startRaw(_ c: Cal, _ st: Stamp) -> Int { st.min == nil ? startDay(c, st.dn) : st.dn * DAY_MIN + st.min! }
    /// shift a tick by a signed lag: working lags move along the working time of calendar c, elapsed lags along the clock
    func lagShift(_ c: Cal, _ t: Int, _ lag: Lag, _ predMin: Int, _ sign: Int, _ asFinish: Bool) -> Int {
        let (k, elapsed) = lagMinutes(lag, predMin, dayMin, weekMin)
        let nn = k * sign
        if nn == 0 { return t }
        if elapsed { return t + nn }
        let p = c.posOf(t) + nn
        return asFinish ? c.finishAt(p) : c.startAt(p)
    }

    // ---- result arrays
    var sT = [Int?](repeating: nil, count: n)   // early start tick
    var fT = [Int?](repeating: nil, count: n)   // early finish tick
    var dur = Array(repeating: 0, count: n)     // working minutes
    let isManual = (0..<n).map { !isSummary[$0] && (T[$0].mode == "manual" || inactive[$0]) }
    // (`!!parseISO(x)` in the JavaScript app: day 0, 1970-01-01, counts as no date)
    let isDone = (0..<n).map { !isSummary[$0] && (T[$0].pct >= 100 || (parseISO(T[$0].actualFinish) ?? 0) != 0) }
    var projStartSt = parseStamp(settings.startDate) ?? parseStamp(T.first(where: { !($0.start ?? "").isEmpty })?.start) ?? Stamp(dn: 0, min: nil)
    var projStartDn = projStartSt.dn
    // Scheduled from the finish date (MS Project): the project finish is fixed - the end of that working day, or the time given -
    // and the project start is calculated back from it (see after the first backward pass).
    let fixedFinishTick: Int? = settings.scheduleFromFinish ? parseStamp(settings.finishDate).map { st in
        projCal.normFinish(st.min == nil ? (st.dn + 1) * DAY_MIN : st.dn * DAY_MIN + st.min!)
    } : nil
    var pinned: [Int: Int] = [:] // ALAP pinning: index -> start tick

    // per-task parsed constraint/deadline/actuals (parsed once)
    let consType: [String] = T.map { $0.constraint.effectiveType }
    let consDate: [Stamp?] = T.map { parseStamp($0.constraint.date) }
    let deadline: [Stamp?] = T.map { parseStamp($0.deadline) }

    func requiredStart(_ j: Int, _ L: Link, _ c: Cal) -> Int? {
        // Start tick required on task j by link L (pred already scheduled)
        let p = L.p
        guard let sp = sT[p], let fp = fT[p] else { return nil }
        let pd = dur[p]
        let zero = dur[j] == 0
        let fin = L.type == "FS" || L.type == "FF"
        let ref = fin ? fp : sp
        let x = lagShift(c, ref, L.lag, pd, +1, fin)
        if L.type == "FS" || L.type == "SS" { return zero ? normZero(c, x) : c.normStart(x) }
        if zero { return normZero(c, x) }
        return startFromFinish(c, c.normFinish(x), dur[j])
    }

    func forward() {
        for i in 0..<n { sT[i] = nil; fT[i] = nil }
        for i in order {
            let t = T[i]
            let c = calOf[i]
            if isSummary[i] {
                var lo = Int.max, hi = Int.min
                var any = false
                for ch in children[i] {
                    guard let s = sT[ch], !inactive[ch] else { continue }
                    lo = min(lo, s); hi = max(hi, fT[ch]!); any = true
                }
                if !any { // every sub-task is inactive: the summary still spans them
                    for ch in children[i] {
                        guard let s = sT[ch] else { continue }
                        lo = min(lo, s); hi = max(hi, fT[ch]!); any = true
                    }
                }
                if !any { // empty / unscheduled summary
                    let s0 = projCal.normStart(projStartSt.dn * DAY_MIN + (projStartSt.min ?? 0))
                    sT[i] = s0; fT[i] = s0; dur[i] = 0
                } else {
                    sT[i] = lo; fT[i] = hi
                    dur[i] = max(0, projCal.posOf(hi) - projCal.posOf(lo))
                }
                continue
            }
            dur[i] = taskMin(t, settings)
            if isManual[i] {
                let st = parseStamp(t.start) ?? Stamp(dn: projStartDn, min: nil)
                let fs = parseStamp(t.finish) ?? st
                let s0 = st.min == nil ? startDay(c, st.dn) : st.dn * DAY_MIN + st.min!
                sT[i] = s0
                if dur[i] == 0 { fT[i] = s0 }
                else {
                    let f0 = fs.min == nil ? endDay(c, max(fs.dn, st.dn)) : fs.dn * DAY_MIN + fs.min!
                    fT[i] = max(f0, s0)
                }
                continue
            }
            // ---- auto task
            let zero = dur[i] == 0
            var s = startFromStamp(c, projStartSt, zero)
            for L in inc[i] {
                if cycleSet.contains(L.p) && cycleSet.contains(i) && sT[L.p] == nil { continue }
                if let r = requiredStart(i, L, c), r > s { s = r }
            }
            let cType = consType[i]
            if let cd = consDate[i] {
                if cType == "SNET" || (cType == "MSO" && !honor) {
                    let r = startFromStamp(c, cd, zero)
                    if r > s { s = r }
                } else if cType == "FNET" || (cType == "MFO" && !honor) {
                    let fr = finishFromStamp(c, cd, zero)
                    let r = zero ? fr : startFromFinish(c, fr, dur[i])
                    if r > s { s = r }
                } else if cType == "MSO" {
                    s = startFromStamp(c, cd, zero)
                } else if cType == "MFO" {
                    let fr = finishFromStamp(c, cd, zero)
                    s = zero ? fr : startFromFinish(c, fr, dur[i])
                }
            }
            if let pv = pinned[i], pv > s { s = pv }
            var f = finishFromStart(c, s, dur[i])
            // actual dates override scheduling (MS Project records what really happened)
            let aS = parseStamp(t.actualStart), aF = parseStamp(t.actualFinish)
            if let a = aS { s = startFromStamp(c, a, zero); f = finishFromStart(c, s, dur[i]) }
            if let a = aF {
                f = zero ? s : finishFromStamp(c, a, false)
                if aS == nil { s = startFromFinish(c, f, dur[i]) }
                else if dur[i] > 0 && f < s { f = finishFromStart(c, s, dur[i]) }
            }
            sT[i] = s; fT[i] = f
        }
    }

    forward()

    // ---- backward pass -> late dates, total slack
    var lfT = [Int?](repeating: nil, count: n), lsT = [Int?](repeating: nil, count: n)
    func backward() {
        var projFinishTick = Int.min
        for i in 0..<n where !isSummary[i] && !inactive[i] { if let f = fT[i], f > projFinishTick { projFinishTick = f } }
        if projFinishTick == Int.min { projFinishTick = projStartSt.dn * DAY_MIN + (projStartSt.min ?? 0) }
        if let fixed = fixedFinishTick { projFinishTick = fixed }
        lfT = [Int?](repeating: nil, count: n); lsT = [Int?](repeating: nil, count: n)
        for k in stride(from: order.count - 1, through: 0, by: -1) {
            let i = order[k]
            if isSummary[i] { continue }
            let c = calOf[i]
            let d = dur[i]
            let zero = d == 0
            var LF = zero ? normZero(c, projFinishTick) : c.normFinish(projFinishTick)
            // successor caps
            for L in out[i] {
                let j = L.t
                guard !isSummary[j], let lsj = lsT[j] else { continue }
                let cj = calOf[j]
                let cap: Int
                if L.type == "FS" {
                    let x = lagShift(cj, lsj, L.lag, d, -1, false)
                    cap = zero ? x : c.normFinish(x)
                } else if L.type == "FF" {
                    let x = lagShift(cj, lfT[j]!, L.lag, d, -1, true)
                    cap = zero ? x : c.normFinish(x)
                } else if L.type == "SS" {
                    let x = lagShift(cj, lsj, L.lag, d, -1, false)
                    cap = finishFromStart(c, zero ? x : snapStartBack(c, x), d)
                } else { // SF
                    let x = lagShift(cj, lfT[j]!, L.lag, d, -1, true)
                    cap = finishFromStart(c, zero ? x : snapStartBack(c, x), d)
                }
                if cap < LF { LF = cap }
            }
            // links whose predecessor is this leaf's ancestor summary act on all its children's finish (FS/FF only)
            var p = parent[i]
            while p >= 0 {
                for L in out[p] {
                    let j = L.t
                    guard !isSummary[j], let lsj = lsT[j] else { continue }
                    if L.type != "FS" && L.type != "FF" { continue }
                    let cj = calOf[j]
                    let x = L.type == "FS" ? lagShift(cj, lsj, L.lag, dur[p], -1, false) : lagShift(cj, lfT[j]!, L.lag, dur[p], -1, true)
                    let cap = zero ? x : c.normFinish(x)
                    if cap < LF { LF = cap }
                }
                p = parent[p]
            }
            // own limits
            if let dl = deadline[i] { let cap = finishCap(c, dl); if cap < LF { LF = cap } }
            let cType = consType[i]
            if let cd = consDate[i], !isManual[i] {
                if cType == "FNLT" || cType == "MFO" { let cap = finishCap(c, cd); if cap < LF { LF = cap } }
                else if cType == "SNLT" || cType == "MSO" {
                    let raw = startRaw(c, cd)
                    let cap = finishFromStart(c, zero ? raw : snapStartBack(c, raw), d)
                    if cap < LF { LF = cap }
                }
            }
            if isDone[i] { LF = fT[i]! } // a finished task cannot move: late dates equal its actual dates
            lfT[i] = LF
            lsT[i] = isDone[i] ? sT[i] : startFromFinish(c, LF, d)
        }
    }
    backward()

    // Scheduling from the finish: the project starts at the earliest late start, so the tasks that drive the finish have no slack;
    // then the early dates are worked out from that start (an As Soon As Possible task starts as early as the project allows).
    if let fixed = fixedFinishTick {
        var lo = Int.max
        for i in 0..<n where !isSummary[i] && !inactive[i] { if let v = lsT[i], v < lo { lo = v } }
        let startTick = lo == Int.max ? fixed : lo
        let dn = floorDiv(startTick, DAY_MIN)
        projStartSt = Stamp(dn: dn, min: startTick - dn * DAY_MIN)
        projStartDn = dn
        forward()
        backward()
    }

    // ALAP: pin as-late-as-possible tasks to their late start, then recompute
    var alap: [Int] = []
    for i in 0..<n {
        if isSummary[i] || isManual[i] { continue }
        if consType[i] == "ALAP", let ls = lsT[i], let s = sT[i], ls > s { alap.append(i) }
    }
    if !alap.isEmpty {
        for i in alap { pinned[i] = lsT[i]! }
        forward()
        backward()
    }

    // ---- slack, criticality
    var total = [Int?](repeating: nil, count: n)
    var free = [Int?](repeating: nil, count: n)
    var pct = Array(repeating: 0.0, count: n)
    for i in 0..<n where !isSummary[i] { pct[i] = min(100, max(0, T[i].pct.isNaN ? 0 : T[i].pct)) }
    // summary % complete: duration-weighted average of children (min weight 1 so milestones count)
    for k in stride(from: order.count - 1, through: 0, by: -1) {
        let i = order[k]
        if !isSummary[i] { continue }
        var w = 0.0, a = 0.0
        for ch in children[i] {
            if inactive[ch] { continue }
            let weight = Double(dur[ch] == 0 ? dayMin : dur[ch])
            w += weight; a += weight * pct[ch]
        }
        pct[i] = w != 0 ? jsRound((a / w) * 10) / 10 : 0
    }
    var critical = Array(repeating: false, count: n)
    var nearCritical = Array(repeating: false, count: n)
    for i in 0..<n {
        if isSummary[i] || inactive[i] { continue } // inactive: no slack, never critical
        let c = calOf[i]
        if isDone[i] { total[i] = 0; free[i] = 0; continue } // finished tasks: no slack, never critical (MS Project)
        let tot = pos(c, lfT[i]!) - pos(c, fT[i]!)
        total[i] = tot
        // free slack: smallest gap between this task and any successor; with no successor it equals total slack
        var fs = Int.max
        for L in out[i] {
            let j = L.t
            guard !isSummary[j], let sj = sT[j] else { continue }
            let cj = calOf[j]
            let fin = L.type == "FS" || L.type == "FF"
            let x = lagShift(cj, fin ? fT[i]! : sT[i]!, L.lag, dur[i], +1, fin)
            let gap: Int
            if L.type == "FS" || L.type == "SS" {
                let r = dur[j] == 0 ? normZero(cj, x) : cj.normStart(x)
                gap = pos(cj, sj) - pos(cj, r)
            } else {
                let r = dur[j] == 0 ? normZero(cj, x) : cj.normFinish(x)
                gap = pos(cj, fT[j]!) - pos(cj, r)
            }
            if gap < fs { fs = gap }
        }
        free[i] = fs == Int.max ? tot : min(fs, tot)
        critical[i] = Double(tot) <= critLimit
        nearCritical[i] = !critical[i] && Double(tot) <= critLimit + nearLimit
    }
    // Summary tasks. MS Project (checked against a real 195-task file, all 15 summary rows): total slack of a summary is the smaller of
    // its start slack (earliest child late start - summary start) and its finish slack (latest child late finish - summary finish);
    // once any part of it has started only the finish slack counts. Free slack shows the same value. Critical when any child is critical.
    var started = Array(repeating: false, count: n)
    var allDoneSummary = Array(repeating: false, count: n)
    for i in 0..<n where !isSummary[i] { started[i] = pct[i] > 0 || (parseISO(T[i].actualStart) ?? 0) != 0 || isDone[i] }
    for k in 0..<order.count {
        let i = order[k]
        if !isSummary[i] { continue }
        var crit = false, any = false, allDone = true, st = false
        var lfMax: Int? = nil, lsMin: Int? = nil
        for ch in children[i] {
            if inactive[ch] { continue }
            if critical[ch] { crit = true }
            if let v = lfT[ch], lfMax == nil || v > lfMax! { lfMax = v }
            if let v = lsT[ch], lsMin == nil || v < lsMin! { lsMin = v }
            if started[ch] { st = true }
            if !(isDone[ch] || (isSummary[ch] && allDoneSummary[ch])) { allDone = false }
            any = true
        }
        started[i] = st
        allDoneSummary[i] = any && allDone
        lfT[i] = lfMax; lsT[i] = lsMin
        let c = calOf[i]
        if !any || allDone || fT[i] == nil || lfMax == nil { total[i] = 0 }
        else {
            let fin = pos(c, lfMax!) - pos(c, fT[i]!)
            let sta = (lsMin != nil && sT[i] != nil) ? pos(c, lsMin!) - pos(c, sT[i]!) : fin
            total[i] = st ? fin : min(sta, fin)
        }
        free[i] = total[i]
        critical[i] = crit
    }

    // ---- conflicts
    var conflicts: [Conflict] = [] // {index, uid, type, message}
    var linkConflict = Set<String>()
    func add(_ i: Int, _ type: String, _ message: String, _ linkKey: String? = nil) {
        conflicts.append(Conflict(index: i, uid: T[i].uid, type: type, message: message))
        if let k = linkKey { linkConflict.insert(k) }
    }
    func idOf(_ i: Int) -> Int { i + 1 }
    for i in cycleNodes { add(i, "cycle", "Part of a circular dependency") }
    for L in rawLinks {
        let j = L.t, p = L.p
        if cycleSet.contains(j) && cycleSet.contains(p) { continue }
        guard let sj = sT[j], let sp = sT[p] else { continue }
        let c = calOf[j]
        let zero = dur[j] == 0
        let pd = dur[p]
        var ok = true
        let fin = L.type == "FS" || L.type == "FF"
        let ref = fin ? fT[p]! : sp
        let x = lagShift(c, ref, L.lag, pd, +1, fin)
        if L.type == "FS" || L.type == "SS" {
            let need = zero ? normZero(c, x) : c.normStart(x)
            ok = pos(c, sj) >= pos(c, need)
        } else {
            let need = zero ? normZero(c, x) : c.normFinish(x)
            ok = pos(c, fT[j]!) >= pos(c, need)
        }
        if !ok {
            let lagTxt = L.lag.v != 0 && !L.lag.v.isNaN ? "\(L.lag.v > 0 ? "+" : "")\(jsNumberString(L.lag.v))\(L.lag.u == "%" ? "%" : L.lag.u)" : ""
            let nm = T[p].name.isEmpty ? "unnamed" : T[p].name
            add(j, "link", "Breaks link \(idOf(p))\(L.type)\(lagTxt) (task \(idOf(p)): \(nm))", "\(T[p].uid)>\(T[j].uid)")
        }
    }
    for i in 0..<n {
        if isSummary[i] || inactive[i] { continue }
        let c = calOf[i]
        let cType = consType[i]
        if !isManual[i], let cd = consDate[i] {
            let zero = dur[i] == 0
            if cType == "MSO" || cType == "MFO" {
                if !c.isWorking(cd.dn) { add(i, "calendar", "\(CONSTRAINT_NAMES[cType]!) date is not a working day") }
            }
            let startOk = { pos(c, sT[i]!) <= pos(c, startFromStamp(c, cd, zero)) }
            let finOk = { pos(c, fT[i]!) <= pos(c, finishCap(c, cd)) }
            let wantStart = { pos(c, startFromStamp(c, cd, zero)) }
            let wantFinish = { pos(c, finishFromStamp(c, cd, zero)) }
            if cType == "SNLT" && !startOk() { add(i, "constraint", "Cannot start by the Start No Later Than date (predecessors push it later)") }
            if cType == "FNLT" && !finOk() { add(i, "constraint", "Cannot finish by the Finish No Later Than date (predecessors push it later)") }
            if cType == "MSO" && honor && pos(c, sT[i]!) != wantStart() { add(i, "constraint", "Start is not on the Must Start On date") }
            if cType == "MFO" && honor && pos(c, fT[i]!) != wantFinish() { add(i, "constraint", "Finish is not on the Must Finish On date") }
            if !honor && cType == "MSO" && pos(c, sT[i]!) != wantStart() { add(i, "constraint", "Dependencies override the Must Start On date") }
            if !honor && cType == "MFO" && pos(c, fT[i]!) != wantFinish() { add(i, "constraint", "Dependencies override the Must Finish On date") }
        }
        if let dl = deadline[i], !(pct[i] >= 100), pos(c, fT[i]!) > pos(c, finishCap(c, dl)) {
            add(i, "deadline", "Finishes after its deadline (\(formatDate(dl.dn, settings.dateFormat.isEmpty ? "DD-MMM-YYYY" : settings.dateFormat)))")
        }
        if !isManual[i], let tot = total[i], tot < 0,
           !conflicts.contains(where: { $0.index == i && ($0.type == "constraint" || $0.type == "deadline" || $0.type == "link") }) {
            add(i, "slack", "Negative slack (\(formatSpan(tot, settings))): a deadline or constraint further along its links cannot be met")
        }
    }
    // summary tasks: flag when any child is in conflict (so collapsed groups still show red)
    var childConflict = Array(repeating: false, count: n)
    for ci in Set(conflicts.map { $0.index }) { var p = parent[ci]; while p >= 0 { childConflict[p] = true; p = parent[p] } }

    // ---- assemble
    func splitS(_ t: Int) -> Stamp { let dn = floorDiv(t, DAY_MIN); return Stamp(dn: dn, min: t - dn * DAY_MIN) }
    func splitF(_ t: Int) -> Stamp { let dn = floorDiv(t - 1, DAY_MIN); return Stamp(dn: dn, min: t - dn * DAY_MIN) }
    /// fraction of the working time of a day that has passed at a minute of that day (nil on a day off)
    func frac(_ c: Cal, _ dn: Int, _ m: Int) -> Double? {
        var tot = 0, w = 0
        for p in c.periodsOf(dn) { tot += p.e - p.s; if m > p.s { w += min(m, p.e) - p.s } }
        return tot != 0 ? Double(w) / Double(tot) : nil
    }
    var byIndexConflicts = Array(repeating: [Conflict](), count: n)
    for cf in conflicts { byIndexConflicts[cf.index].append(cf) }
    func perDay(_ m: Int?) -> Double? { m.map { Double($0) / Double(dayMin) } }
    var rows: [ScheduledTask] = []
    rows.reserveCapacity(n)
    for i in 0..<n {
        let summary = isSummary[i]
        let s = sT[i], f = fT[i]
        let c = calOf[i]
        let sp = s.map(splitS)
        let fp: Stamp? = f.map { f == s ? sp! : splitF($0) }
        let unit = summary ? "d" : (T[i].durUnit.isEmpty ? "d" : T[i].durUnit)
        let timed = sp == nil ? false : (!summary && (unit == "h" || unit == "m")) || !(c.onBoundary(sp!.dn, sp!.min!) && c.onBoundary(fp!.dn, fp!.min!))
        let lsP = lsT[i].map(splitS)
        let lfP: Stamp? = lfT[i].map { lfT[i] == lsT[i] ? lsP! : splitF($0) }
        rows.append(ScheduledTask(
            index: i, uid: T[i].uid, id: i + 1, wbs: wbs[i], parent: parent[i], children: children[i],
            isSummary: summary, isManual: isManual[i] && !inactive[i], inactive: inactive[i],
            hideBar: T[i].hideBar, rollup: T[i].rollup, onTimeline: T[i].onTimeline,
            priority: T[i].priority, taskType: T[i].taskType.isEmpty ? "fixedUnits" : T[i].taskType,
            isMilestone: !summary && (dur[i] == 0 || T[i].milestone),
            start: sp.map { toISO($0.dn) }, finish: fp.map { toISO($0.dn) },
            startMin: sp?.min, finishMin: fp?.min,
            startStamp: sp.map { timed ? toStamp($0.dn, $0.min) : toISO($0.dn) },
            finishStamp: fp.map { timed ? toStamp($0.dn, $0.min) : toISO($0.dn) },
            timed: timed,
            startFrac: sp.map { frac(c, $0.dn, $0.min!) ?? 0 }, finishFrac: fp.map { frac(c, $0.dn, $0.min!) ?? 1 },
            startTick: s, finishTick: f,
            duration: Double(dur[i]) / Double(dayMin), durationMin: dur[i], durUnit: unit,
            lateStart: lsP.map { toISO($0.dn) }, lateFinish: lfP.map { toISO($0.dn) },
            lateStartMin: lsP?.min, lateFinishMin: lfP?.min,
            totalSlack: perDay(total[i]), freeSlack: perDay(free[i]), totalSlackMin: total[i], freeSlackMin: free[i],
            critical: critical[i], nearCritical: nearCritical[i], pct: pct[i],
            conflicts: byIndexConflicts[i], hasConflict: !byIndexConflicts[i].isEmpty, childConflict: childConflict[i]))
    }
    let links = rawLinks.map { L in
        ScheduledLink(predUid: T[L.p].uid, uid: T[L.t].uid, pIndex: L.p, tIndex: L.t, type: L.type, lag: L.lag,
                      conflict: linkConflict.contains("\(T[L.p].uid)>\(T[L.t].uid)"))
    }
    var pf: Int? = nil, ps: Int? = nil
    for r in rows {
        if r.inactive { continue }
        if let st = r.start, let d = parseISO(st) { if ps == nil || d < ps! { ps = d } }
        if let fn = r.finish, let d = parseISO(fn) { if pf == nil || d > pf! { pf = d } }
    }
    // scheduled from the finish: the project finishes on its finish date even when every task could end sooner
    if let fixed = fixedFinishTick { let d = floorDiv(fixed - 1, DAY_MIN); if pf == nil || d > pf! { pf = d }; if ps == nil { ps = floorDiv(projStartSt.dn * DAY_MIN, DAY_MIN) } }
    return ScheduleResult(
        tasks: rows, projectStart: ps.map(toISO), projectFinish: pf.map(toISO), conflicts: conflicts, conflictCount: conflicts.count,
        links: links, cycles: cycleNodes.map { T[$0].uid }, calendarInvalid: calOrder.contains { $0.invalid },
        dayMin: dayMin, weekMin: weekMin)
}

/// Write scheduled start/finish/duration for auto tasks and summaries back into the project (mutates).
public func applySchedule(_ project: inout Project, _ result: ScheduleResult) {
    for i in project.tasks.indices {
        guard i < result.tasks.count else { continue }
        let r = result.tasks[i]
        if project.tasks[i].mode != "manual" || r.isSummary {
            project.tasks[i].start = r.startStamp
            project.tasks[i].finish = r.finishStamp
        }
        if r.isSummary { project.tasks[i].dur = r.durationMin }
    }
}

@discardableResult
public func scheduleAndApply(_ project: inout Project) -> ScheduleResult {
    let r = schedule(project)
    applySchedule(&project, r)
    return r
}
