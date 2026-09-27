// Microsoft Project XML (MSPDI) import and export.
//
// Element order follows the MSPDI schema as embedded in MPXJ's generated classes (the same order MS Project itself writes),
// so Project can open the file without complaint. Durations are written in working minutes (PT..H..M..S) and the project's
// "Hours per day" / "Hours per week" become MinutesPerDay / MinutesPerWeek (8 h and 40 h by default, DaysPerMonth = 20).
// Calendar working times (the hours of each weekday) are written and read as MS Project's WorkingTimes.

import Foundation

let MIN_PER_DAY = 480
let MIN_PER_WEEK = 2400

// DurationFormat / LagFormat codes: 3 min, 5 hour, 7 day, 9 week, 11 month (elapsed: 4, 6, 8, 10, 12; "estimated" values add 32)
let FORMAT_OF_UNIT = ["m": 3, "h": 5, "d": 7, "w": 9, "mo": 11, "em": 4, "eh": 6, "ed": 8, "ew": 10, "emo": 12]
let UNIT_OF_FORMAT = [3: "m", 4: "em", 5: "h", 6: "eh", 7: "d", 8: "ed", 9: "w", 10: "ew", 11: "mo", 12: "emo"]
let CONSTRAINT_TO_CODE = ["ASAP": 0, "ALAP": 1, "MSO": 2, "MFO": 3, "SNET": 4, "SNLT": 5, "FNET": 6, "FNLT": 7]
let CODE_TO_CONSTRAINT = [0: "ASAP", 1: "ALAP", 2: "MSO", 3: "MFO", 4: "SNET", 5: "SNLT", 6: "FNET", 7: "FNLT"]
let LINK_TO_CODE = ["FF": 0, "FS": 1, "SF": 2, "SS": 3]
let CODE_TO_LINK = [0: "FF", 1: "FS", 2: "SF", 3: "SS"]
// LagFormat codes (MS Project / MPXJ): 3 min, 4 elapsed min, 5 hour, 6 elapsed hour, 7 day, 8 elapsed day,
// 9 week, 10 elapsed week, 11 month, 12 elapsed month, 19 percent, 20 elapsed percent
let ELAPSED_FORMATS: Set<Int> = [4, 6, 8, 10, 12, 20]

// MARK: - schema order (from MSPDI / MPXJ)
let ORDER_PROJECT = "SaveVersion UID Name GUID Title Subject Category Company Manager Author CreationDate Revision LastSaved ScheduleFromStart StartDate FinishDate FYStartDate CriticalSlackLimit CurrencyDigits CurrencySymbol CurrencyCode CurrencySymbolPosition CalendarUID DefaultStartTime DefaultFinishTime MinutesPerDay MinutesPerWeek DaysPerMonth DefaultTaskType DefaultFixedCostAccrual DefaultStandardRate DefaultOvertimeRate DurationFormat WorkFormat EditableActualCosts HonorConstraints EarnedValueMethod InsertedProjectsLikeSummary MultipleCriticalPaths NewTasksEffortDriven NewTasksEstimated SplitsInProgressTasks SpreadActualCost SpreadPercentComplete TaskUpdatesResource FiscalYearStart WeekStartDay MoveCompletedEndsBack MoveRemainingStartsBack MoveRemainingStartsForward MoveCompletedEndsForward BaselineForEarnedValue AutoAddNewResourcesAndTasks StatusDate CurrentDate MicrosoftProjectServerURL Autolink NewTaskStartDate NewTasksAreManual DefaultTaskEVMethod ProjectExternallyEdited ExtendedCreationDate ActualsInSync RemoveFileProperties AdminProject BaselineCalendar UpdateManuallyScheduledTasksWhenEditingLinks KeepTaskOnNearestWorkingTimeWhenMadeAutoScheduled OutlineCodes WBSMasks ExtendedAttributes Calendars Tasks Resources Assignments".split(separator: " ").map(String.init)
let ORDER_TASK = "UID GUID ID Name Active Manual Type IsNull CreateDate Contact WBS WBSLevel OutlineNumber OutlineLevel Priority Start Finish Duration DurationFormat Work Stop Resume ResumeValid EffortDriven Recurring OverAllocated Estimated Milestone Summary DisplayAsSummary Critical IsSubproject IsSubprojectReadOnly SubprojectName ExternalTask ExternalTaskProject EarlyStart EarlyFinish LateStart LateFinish StartVariance FinishVariance WorkVariance FreeSlack TotalSlack StartSlack FinishSlack FixedCost FixedCostAccrual PercentComplete PercentWorkComplete Cost OvertimeCost OvertimeWork ActualStart ActualFinish ActualDuration ActualCost ActualOvertimeCost ActualWork ActualOvertimeWork RegularWork RemainingDuration RemainingCost RemainingWork RemainingOvertimeCost RemainingOvertimeWork ACWP CV ConstraintType CalendarUID ConstraintDate Deadline LevelAssignments LevelingCanSplit LevelingDelay LevelingDelayFormat PreLeveledStart PreLeveledFinish Hyperlink HyperlinkAddress HyperlinkSubAddress IgnoreResourceCalendar Notes HideBar Rollup BCWS BCWP PhysicalPercentComplete EarnedValueMethod PredecessorLink ActualWorkProtected ActualOvertimeWorkProtected ExtendedAttribute Baseline OutlineCode IsPublished StatusManager CommitmentStart CommitmentFinish CommitmentType StartText FinishText DurationText ManualStart ManualFinish ManualDuration TimephasedData Project".split(separator: " ").map(String.init)

/// One element value: text, or a writer callback for repeating/nested elements.
enum XV {
    case s(String)
    case f((XmlOut) -> Void)
}

/// Write values in schema order; unknown names are a bug.
func emitBody(_ out: XmlOut, _ wrapper: String, _ order: [String], _ values: [String: XV]) {
    for name in values.keys where !order.contains(name) { preconditionFailure("MSPDI writer bug: unknown element \(name) in \(wrapper)") }
    for name in order {
        guard let v = values[name] else { continue }
        switch v {
        case .s(let s): out.el(name, s)
        case .f(let fn): fn(out)
        }
    }
}
func emit(_ out: XmlOut, _ wrapper: String, _ order: [String], _ values: [String: XV]) {
    out.open(wrapper)
    emitBody(out, wrapper, order, values)
    out.close(wrapper)
}

func hhmmss(_ min: Int) -> String { "\(fmtHM(min)):00" }
/// working minutes -> PT..H..M..S
func minDur(_ min: Int) -> String { "PT\(floorDiv(min, 60))H\(jsNumberString(jsRound(Double(min % 60))))M0S" }
func slackTenths(_ min: Int) -> String { String(min * 10) }
/// a stored date or moment ('YYYY-MM-DD' or 'YYYY-MM-DDTHH:MM') as an XML date-time; a plain date gets the default time
func stampXml(_ stamp: String?, _ defaultT: String) -> String? {
    guard let st = parseStamp(stamp ?? "") else { return nil }
    return "\(toISO(st.dn))T\(st.min == nil ? defaultT : hhmmss(st.min!))"
}
func localStamp(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    return "\(c.year!)-\(pad(c.month!))-\(pad(c.day!))T\(pad(c.hour!)):\(pad(c.minute!)):\(pad(c.second!))"
}

func lagToXml(_ lag: Lag, _ dayMin: Int, _ weekMin: Int) -> (String, Int) {
    let v = lag.v.isNaN ? 0 : lag.v
    func r(_ x: Double) -> String { jsNumberString(jsRound(x)) }
    switch lag.u {
    case "%": return (r(v), 19)
    case "w": return (r(v * Double(weekMin) * 10), 9)
    case "h": return (r(v * 60 * 10), 5)
    case "m": return (r(v * 10), 3)
    case "ed": return (r(v * 1440 * 10), 8)
    case "eh": return (r(v * 60 * 10), 6)
    case "em": return (r(v * 10), 4)
    case "ew": return (r(v * 10080 * 10), 10)
    default: return (r(v * Double(dayMin) * 10), 7)
    }
}

func writeCalendar(_ out: XmlOut, _ def: CalendarDef, _ uid: Int) {
    let cal = Cal(def)
    func workTimes(_ o: XmlOut, _ periods: [Period]) {
        o.open("WorkingTimes")
        for p in periods { o.open("WorkingTime").el("FromTime", hhmmss(p.s)).el("ToTime", p.e >= 1440 ? "00:00:00" : hhmmss(p.e)).close("WorkingTime") }
        o.close("WorkingTimes")
    }
    struct E { var lo: Int; var hi: Int; var working: Bool; var name: String; var periods: [Period] }
    let exc: [E] = def.exceptions.compactMap { e in
        guard let f = parseISO(e.from), let t = parseISO(nonEmpty(e.to) ?? e.from) else { return nil }
        return E(lo: min(f, t), hi: max(f, t), working: e.working, name: e.name, periods: e.working ? normPeriods(e.periods) : [])
    }
    out.open("Calendar")
    out.el("UID", uid).el("Name", def.name).el("IsBaseCalendar", 1).el("IsBaselineCalendar", 0).el("BaseCalendarUID", -1)
    out.open("WeekDays")
    for d in 0..<7 {
        let working = cal.week[d]
        out.open("WeekDay").el("DayType", d + 1).el("DayWorking", working ? 1 : 0)
        if working { workTimes(out, cal.weekPeriods[d]) }
        out.close("WeekDay")
    }
    for e in exc {
        out.open("WeekDay").el("DayType", 0).el("DayWorking", e.working ? 1 : 0)
        out.open("TimePeriod").el("FromDate", "\(toISO(e.lo))T00:00:00").el("ToDate", "\(toISO(e.hi))T23:59:59").close("TimePeriod")
        if e.working { workTimes(out, e.periods.isEmpty ? cal.stdPeriods : e.periods) }
        out.close("WeekDay")
    }
    out.close("WeekDays")
    if !exc.isEmpty {
        out.open("Exceptions")
        for e in exc {
            out.open("Exception").el("EnteredByOccurrences", 0)
            out.open("TimePeriod").el("FromDate", "\(toISO(e.lo))T00:00:00").el("ToDate", "\(toISO(e.hi))T23:59:59").close("TimePeriod")
            out.el("Occurrences", 1)
            if !e.name.isEmpty { out.el("Name", e.name) }
            out.el("Type", 1).el("DayWorking", e.working ? 1 : 0)
            if e.working { workTimes(out, e.periods.isEmpty ? cal.stdPeriods : e.periods) }
            out.close("Exception")
        }
        out.close("Exceptions")
    }
    out.close("Calendar")
}

public struct ExportResult { public var xml: String; public var notes: [String] }

/// Build MS Project XML from a project and its computed schedule.
public func exportMSPDI(_ project: Project, _ sched: ScheduleResult, now: Date = Date()) -> ExportResult {
    let S = project.settings
    let T = project.tasks
    let rows = sched.tasks
    let out = XmlOut()
    out.raw("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>")
    out.raw("<Project xmlns=\"http://schemas.microsoft.com/project\">")
    out.depth = 1
    // calendars get sequential UIDs (1..n); the project calendar's UID goes in CalendarUID
    var calUid: [String: Int] = [:]
    for (i, c) in project.calendars.enumerated() { calUid[c.id] = i + 1 }
    let defaultCalUid = calUid[S.defaultCalendarId] ?? 1
    let dayMin = dayMinOf(S), weekMin = weekMinOf(S)
    let projCalDef = project.calendars.first { $0.id == S.defaultCalendarId } ?? project.calendars[0]
    let projCal = Cal(projCalDef)
    // the usual start and end of a working day (Monday's, or the first working weekday's) are MS Project's default start and finish times
    let usual = projCal.weekPeriods.first { !$0.isEmpty } ?? DEFAULT_PERIODS
    let dayStartT = hhmmss(usual[0].s), dayEndT = usual[usual.count - 1].e >= 1440 ? "23:59:00" : hhmmss(usual[usual.count - 1].e)
    let projStart = nonEmpty(S.startDate) ?? rows.first?.start
    let projFinish = sched.projectFinish ?? projStart
    var header: [String: XV] = [:]
    func put(_ k: String, _ v: String?) { if let v = v { header[k] = .s(v) } }
    func put(_ k: String, _ v: Int) { header[k] = .s(String(v)) }
    put("SaveVersion", 14)
    put("Name", "\(project.name.isEmpty ? "Project" : project.name).xml")
    put("Title", project.name.isEmpty ? "Project" : project.name)
    put("ScheduleFromStart", 1)
    put("StartDate", stampXml(projStart, dayStartT))
    put("FinishDate", stampXml(projFinish, dayEndT))
    put("FYStartDate", 1)
    put("CriticalSlackLimit", jsNumberString(jsRound(S.criticalSlackDays)))
    put("CurrencyDigits", 2)
    put("CurrencySymbol", "$")
    put("CurrencySymbolPosition", 0)
    put("CalendarUID", defaultCalUid)
    put("DefaultStartTime", dayStartT)
    put("DefaultFinishTime", dayEndT)
    put("MinutesPerDay", dayMin)
    put("MinutesPerWeek", weekMin)
    put("DaysPerMonth", jsNumberString(jsRound(monthDaysOf(S))))
    put("DefaultTaskType", 0)
    put("DefaultFixedCostAccrual", 2)
    put("DurationFormat", 7)
    put("WorkFormat", 2)
    put("EditableActualCosts", 0)
    put("HonorConstraints", S.honorConstraints == false ? 0 : 1)
    put("EarnedValueMethod", 0)
    put("InsertedProjectsLikeSummary", 0)
    put("MultipleCriticalPaths", 0)
    put("NewTasksEffortDriven", 0)
    put("NewTasksEstimated", 1)
    put("SplitsInProgressTasks", 1)
    put("SpreadActualCost", 0)
    put("SpreadPercentComplete", 0)
    put("TaskUpdatesResource", 1)
    put("FiscalYearStart", 0)
    put("WeekStartDay", 1)
    put("MoveCompletedEndsBack", 0)
    put("MoveRemainingStartsBack", 0)
    put("MoveRemainingStartsForward", 0)
    put("MoveCompletedEndsForward", 0)
    put("BaselineForEarnedValue", 0)
    put("AutoAddNewResourcesAndTasks", 1)
    if let sd = nonEmpty(S.statusDate) { put("StatusDate", stampXml(sd, dayStartT)) }
    put("CurrentDate", localStamp(now))
    put("MicrosoftProjectServerURL", 1)
    put("Autolink", 1)
    put("NewTaskStartDate", 0)
    put("NewTasksAreManual", S.newTasksAuto == false ? 1 : 0)
    put("DefaultTaskEVMethod", 0)
    put("ProjectExternallyEdited", 0)
    put("ActualsInSync", 0)
    put("RemoveFileProperties", 0)
    put("AdminProject", 0)
    let fields = planCustomFields(project)
    header["ExtendedAttributes"] = .f { o in
        if fields.written.isEmpty { o.empty("ExtendedAttributes"); return }
        o.open("ExtendedAttributes")
        for f in fields.written {
            o.open("ExtendedAttribute").el("FieldID", f.fieldId).el("FieldName", f.fieldName)
            if f.col.name != f.fieldName { o.el("Alias", f.col.name) }
            o.close("ExtendedAttribute")
        }
        o.close("ExtendedAttributes")
    }
    header["Calendars"] = .f { o in
        o.open("Calendars")
        for (i, c) in project.calendars.enumerated() { writeCalendar(o, c, i + 1) }
        o.close("Calendars")
    }
    header["Tasks"] = .f { o in
        o.open("Tasks")
        // Task UID 0 is MS Project's "project summary" row
        if rows.contains(where: { $0.start != nil }) {
            let totalMin = !sched.tasks.isEmpty ? countProjectMinutes(projCal, projStart, projFinish) : 0
            let pctAll = overallPercent(rows, dayMin)
            let minStart = rows.reduce("9999-12-31") { m, r in (r.start != nil && r.start! < m) ? r.start! : m }
            var v: [String: XV] = [:]
            func pv(_ k: String, _ s: String?) { if let s = s { v[k] = .s(s) } }
            func pv(_ k: String, _ n: Int) { v[k] = .s(String(n)) }
            pv("UID", 0); pv("ID", 0); pv("Name", project.name.isEmpty ? "Project" : project.name); pv("Active", 1); pv("Manual", 0); pv("Type", 1); pv("IsNull", 0)
            pv("WBS", "0"); pv("OutlineNumber", "0"); pv("OutlineLevel", 0); pv("Priority", 500)
            pv("Start", stampXml(minStart, dayStartT))
            pv("Finish", stampXml(projFinish, dayEndT))
            pv("Duration", minDur(totalMin)); pv("DurationFormat", 7)
            pv("ResumeValid", 0); pv("EffortDriven", 0); pv("Recurring", 0); pv("OverAllocated", 0); pv("Estimated", 0); pv("Milestone", 0); pv("Summary", 1)
            pv("Critical", rows.contains { $0.critical && !$0.isSummary } ? 1 : 0)
            pv("IsSubproject", 0); pv("IsSubprojectReadOnly", 0); pv("ExternalTask", 0)
            pv("FixedCostAccrual", 3); pv("PercentComplete", jsNumberString(jsRound(pctAll))); pv("PercentWorkComplete", 0)
            pv("ConstraintType", 0); pv("CalendarUID", -1); pv("LevelAssignments", 1); pv("LevelingCanSplit", 1); pv("LevelingDelay", 0); pv("LevelingDelayFormat", 8)
            pv("IgnoreResourceCalendar", 0); pv("HideBar", 0); pv("Rollup", 0); pv("PhysicalPercentComplete", 0); pv("EarnedValueMethod", 0)
            emit(o, "Task", ORDER_TASK, v)
        }
        for (i, t) in T.enumerated() { writeTask(o, project, t, rows[i], i, calUid, dayMin, weekMin, dayStartT, dayEndT, fields.written) }
        o.close("Tasks")
    }
    emitBody(out, "Project", ORDER_PROJECT, header)
    out.depth = 0
    out.raw("</Project>")
    let xml = out.toString()
    var notes: [String] = []
    let tagged = project.tasks.filter { !$0.tags.isEmpty }.count
    let custom = project.customColumns.count
    let colours = project.tasks.filter { nonEmpty($0.color) != nil }.count
    let weights = project.tasks.filter { $0.weight != nil }.count
    if tagged > 0 { notes.append("Tags on \(tagged) task(s) are not written to the MS Project file.") }
    if custom > 0 && !fields.skipped.isEmpty {
        notes.append("\(plural(fields.skipped.count, "custom column")) could not be written, as MS Project has no free field of that kind left: \(fields.skipped.joined(separator: ", ")).")
    }
    if colours > 0 { notes.append("Custom task colours (\(colours) task(s)) are not written to the MS Project file.") }
    if weights > 0 { notes.append("S-curve weights (\(weights) task(s)) are not written to the MS Project file.") }
    return ExportResult(xml: xml, notes: notes)
}

func countProjectMinutes(_ cal: Cal, _ s: String?, _ f: String?) -> Int {
    // working minutes between project start and finish in the project calendar, for the project summary row
    guard let a = parseISO(s), let b = parseISO(f), b >= a else { return 0 }
    return cal.midx(b + 1) - cal.midx(a)
}

func overallPercent(_ rows: [ScheduledTask], _ dayMin: Int) -> Double {
    var w = 0.0, a = 0.0
    for r in rows where !r.isSummary {
        let wt = Double(r.durationMin == 0 ? dayMin : r.durationMin)
        w += wt; a += wt * r.pct
    }
    return w != 0 ? a / w : 0
}

let TYPE_TO_CODE = ["fixedUnits": 0, "fixedDuration": 1, "fixedWork": 2]
let CODE_TO_TYPE = ["fixedUnits", "fixedDuration", "fixedWork"]

func writeTask(_ o: XmlOut, _ project: Project, _ t: Task, _ r: ScheduledTask, _ i: Int, _ calUid: [String: Int],
               _ dayMin: Int, _ weekMin: Int, _ dayStartT: String, _ dayEndT: String, _ fields: [ExportField] = []) {
    let isSummary = r.isSummary
    let manual = r.isManual
    let milestone = r.isMilestone
    let hasEarly = r.start != nil
    // the moments as calculated (a whole-day task starts at the start of a working day and finishes at the end of one)
    let startX: String? = hasEarly ? "\(r.start!)T\(hhmmss(r.startMin!))" : nil
    let finishX: String? = hasEarly ? "\(r.finish!)T\(hhmmss(r.finishMin! >= 1440 ? 1439 : r.finishMin!))" : nil
    let dur = r.durationMin
    let pct = Int(jsRound(r.pct))
    let actualMin: Int? = isSummary ? nil : jsRoundInt(Double(dur * pct) / 100)
    let cons = t.constraint.type.isEmpty ? "ASAP" : t.constraint.type
    let consNeedsDate = !(cons == "ASAP" || cons == "ALAP")
    let consFinishBased = cons == "MFO" || cons == "FNET" || cons == "FNLT"
    let slack = r.totalSlackMin
    let calId = nonEmpty(t.calendarId).flatMap { calUid[$0] }
    let fmt = FORMAT_OF_UNIT[r.durUnit] ?? 7
    var v: [String: XV] = [:]
    func pv(_ k: String, _ s: String?) { if let s = s { v[k] = .s(s) } }
    func pv(_ k: String, _ n: Int) { v[k] = .s(String(n)) }
    pv("UID", t.uid); pv("ID", i + 1); pv("Name", t.name); pv("Active", t.inactive && !isSummary ? 0 : 1); pv("Manual", manual ? 1 : 0)
    pv("Type", isSummary ? 1 : (TYPE_TO_CODE[t.taskType] ?? 0)); pv("IsNull", 0)
    pv("WBS", r.wbs); pv("OutlineNumber", r.wbs); pv("OutlineLevel", t.level); pv("Priority", t.priority)
    pv("Start", startX); pv("Finish", finishX)
    pv("Duration", minDur(dur)); pv("DurationFormat", fmt)
    pv("ResumeValid", 0); pv("EffortDriven", 0); pv("Recurring", 0); pv("OverAllocated", 0); pv("Estimated", 0)
    pv("Milestone", milestone ? 1 : 0); pv("Summary", isSummary ? 1 : 0); pv("Critical", r.critical ? 1 : 0)
    pv("IsSubproject", 0); pv("IsSubprojectReadOnly", 0); pv("ExternalTask", 0)
    pv("EarlyStart", startX)
    pv("EarlyFinish", finishX)
    pv("LateStart", r.lateStart != nil ? "\(r.lateStart!)T\(hhmmss(r.lateStartMin!))" : startX)
    pv("LateFinish", r.lateFinish != nil ? "\(r.lateFinish!)T\(hhmmss(r.lateFinishMin! >= 1440 ? 1439 : r.lateFinishMin!))" : finishX)
    pv("TotalSlack", slack.map(slackTenths))
    pv("StartSlack", slack.map(slackTenths))
    pv("FinishSlack", slack.map(slackTenths))
    pv("FixedCostAccrual", 3)
    pv("PercentComplete", pct)
    pv("PercentWorkComplete", pct)
    pv("ActualStart", nonEmpty(t.actualStart) != nil && !isSummary ? stampXml(t.actualStart, dayStartT) : nil)
    pv("ActualFinish", nonEmpty(t.actualFinish) != nil && !isSummary ? stampXml(t.actualFinish, dayEndT) : nil)
    pv("ActualDuration", !isSummary && pct > 0 ? minDur(actualMin!) : nil)
    pv("RemainingDuration", !isSummary && !milestone && pct < 100 ? minDur(dur - actualMin!) : nil)
    pv("ConstraintType", CONSTRAINT_TO_CODE[cons] ?? 0)
    pv("CalendarUID", calId ?? -1)
    pv("ConstraintDate", consNeedsDate && nonEmpty(t.constraint.date) != nil ? stampXml(t.constraint.date, consFinishBased ? dayEndT : dayStartT) : nil)
    pv("Deadline", nonEmpty(t.deadline) != nil ? stampXml(t.deadline, dayEndT) : nil)
    pv("LevelAssignments", 1); pv("LevelingCanSplit", 1); pv("LevelingDelay", 0); pv("LevelingDelayFormat", 8)
    pv("IgnoreResourceCalendar", 0)
    pv("Notes", t.notes.isEmpty ? nil : t.notes)
    pv("HideBar", t.hideBar ? 1 : 0); pv("Rollup", isSummary || t.rollup ? 1 : 0); pv("PhysicalPercentComplete", 0); pv("EarnedValueMethod", 0)
    // predecessor links and baselines are repeating elements, written by callbacks at their schema position
    let uids = Set(project.tasks.map { $0.uid })
    let links = t.preds.filter { uids.contains($0.uid) }
    if !links.isEmpty {
        v["PredecessorLink"] = .f { out in
            for p in links {
                let lag = lagToXml(p.lag, dayMin, weekMin)
                out.open("PredecessorLink").el("PredecessorUID", p.uid).el("Type", LINK_TO_CODE[p.type] ?? 1).el("CrossProject", 0)
                    .el("LinkLag", lag.0).el("LagFormat", lag.1).close("PredecessorLink")
            }
        }
    }
    // custom columns, in the MS Project fields planCustomFields chose
    let ext: [(ExportField, String)] = fields.compactMap { f in customFieldValue(f, t.custom[f.col.id], project.settings, dayStartT).map { (f, $0) } }
    if !ext.isEmpty {
        v["ExtendedAttribute"] = .f { out in
            for (f, value) in ext {
                out.open("ExtendedAttribute").el("FieldID", f.fieldId).el("Value", value)
                if f.kind == "duration" { out.el("DurationFormat", 7) }
                out.close("ExtendedAttribute")
            }
        }
    }
    let bls = t.baselines.enumerated().compactMap { (n, b) in b.map { (b: $0, n: n) } }
    if !bls.isEmpty {
        v["Baseline"] = .f { out in
            for (b, n) in bls {
                let bmin = b.dur ?? jsRoundInt((b.duration ?? 0) * Double(dayMin))
                let zero = bmin == 0
                out.open("Baseline").el("Number", n).el("Start", stampXml(b.start, dayStartT)).el("Finish", stampXml(b.finish, zero ? dayStartT : dayEndT))
                    .el("Duration", minDur(bmin)).el("DurationFormat", 7).close("Baseline")
            }
        }
    }
    if manual {
        pv("ManualStart", startX)
        pv("ManualFinish", finishX)
        pv("ManualDuration", minDur(dur))
    }
    emit(o, "Task", ORDER_TASK, v)
}

// MARK: - import

func hoursFromDuration(_ s: String?) -> Double? {
    guard let s = s else { return nil }
    // /^P(?:(\d+)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$/
    let u = Array(jsTrim(s).utf8)
    var p = 0
    guard p < u.count, u[p] == UInt8(ascii: "P") else { return nil }
    p += 1
    func num(allowDot: Bool) -> (Double, Int)? {
        var q = p
        while q < u.count, isAsciiDigit(u[q]) { q += 1 }
        if q == p { return nil }
        if allowDot, q < u.count, u[q] == UInt8(ascii: ".") {
            var r = q + 1
            while r < u.count, isAsciiDigit(u[r]) { r += 1 }
            if r > q + 1 { q = r }
        }
        return (Double(String(decoding: u[p..<q], as: UTF8.self)) ?? 0, q)
    }
    var days = 0.0, h = 0.0, m = 0.0, sec = 0.0
    if let (v, q) = num(allowDot: false), q < u.count, u[q] == UInt8(ascii: "D") { days = v; p = q + 1 }
    if p < u.count {
        guard u[p] == UInt8(ascii: "T") else { return nil }
        p += 1
        if let (v, q) = num(allowDot: true), q < u.count, u[q] == UInt8(ascii: "H") { h = v; p = q + 1 }
        if let (v, q) = num(allowDot: true), q < u.count, u[q] == UInt8(ascii: "M") { m = v; p = q + 1 }
        if let (v, q) = num(allowDot: true), q < u.count, u[q] == UInt8(ascii: "S") { sec = v; p = q + 1 }
    }
    if p != u.count { return nil }
    return days * 24 + h + m / 60 + sec / 3600
}
func dateOnly(_ s: String?) -> String? {
    guard let s = s, s.utf8.count >= 10 else { return nil }
    let b = Array(s.utf8.prefix(10))
    guard isAsciiDigit(b[0]), isAsciiDigit(b[1]), isAsciiDigit(b[2]), isAsciiDigit(b[3]), b[4] == 45, isAsciiDigit(b[5]), isAsciiDigit(b[6]), b[7] == 45, isAsciiDigit(b[8]), isAsciiDigit(b[9]) else { return nil }
    return String(decoding: b, as: UTF8.self)
}
/// Number(s) for a present, non-empty text; `d` otherwise (or when not a finite number).
func xnum(_ s: String?, _ d: Double? = nil) -> Double? {
    guard let s = s, !s.isEmpty else { return d }
    let v = jsNumberFromString(s)
    return v.isFinite ? v : d
}
func xbool(_ s: String?) -> Bool { s == "1" || s == "true" }

func timeMinutes(_ s: String?) -> Int {
    // /^(\d{1,2}):(\d{2})/
    let u = Array((s ?? "").utf8)
    var p = 0, h = 0
    while p < u.count, p < 2, isAsciiDigit(u[p]) { h = h * 10 + Int(u[p] - 48); p += 1 }
    guard p >= 1 else { return 0 }
    guard p + 2 < u.count, u[p] == UInt8(ascii: ":"), isAsciiDigit(u[p + 1]), isAsciiDigit(u[p + 2]) else { return 0 }
    return h * 60 + Int(u[p + 1] - 48) * 10 + Int(u[p + 2] - 48)
}

/// The WorkingTimes of a WeekDay / Exception element as periods in minutes ("00:00" as an end means midnight).
func workingPeriods(_ el: XmlNode?) -> [Period] {
    var out: [RawPeriod] = []
    for tm in kids(kid(el, "WorkingTimes"), "WorkingTime") {
        let a = timeMinutes(tm.kidText("FromTime"))
        var b = timeMinutes(tm.kidText("ToTime"))
        if b == 0 && a > 0 { b = 1440 }
        if b > a { out.append([Double(a), Double(b)]) }
    }
    return normPeriods(out)
}

public struct ImportNote: Equatable, Sendable { public var level: String; public var text: String }
public struct ImportDifference: Equatable, Sendable { public var id: Int; public var name: String; public var file: String; public var ganttpath: String }
public struct ImportReport: Sendable {
    public var stats: [String: Int]
    public var compared: Int?
    public var matched: Int?
    public var differences: [ImportDifference]
    public var differenceCount: Int
    public var notes: [ImportNote]
    public var hasCompare: Bool
}
public struct ImportResult: Sendable { public var project: Project; public var report: ImportReport }

private struct CalInfo {
    var uid: Int, name: String, isBase: Bool, baseUid: Int
    var week: [Bool?], hours: [[Period]?]
    var exceptions: [(from: String, to: String, working: Bool, name: String, periods: [Period])]
    var recurring: [(name: String, dates: Int)]
    var truncated: [String]
}

private func parseCalendars(_ root: XmlNode, _ taskCalUids: Set<Int>, _ notes: inout [ImportNote], _ skipped: inout Int) -> [(uid: Int, def: CalendarDef)] {
    var list: [CalInfo] = []
    let weekStart = Int(xnum(root.kidText("WeekStartDay"), 0)!)
    for c in kids(kid(root, "Calendars"), "Calendar") {
        guard let uidD = xnum(c.kidText("UID")) else { continue }
        let uid = Int(uidD)
        var info = CalInfo(uid: uid, name: nonEmpty(c.kidText("Name")) ?? "Calendar \(uid)", isBase: xbool(c.kidText("IsBaseCalendar")),
                           baseUid: Int(xnum(c.kidText("BaseCalendarUID"), -1)!), week: Array(repeating: nil, count: 7),
                           hours: Array(repeating: nil, count: 7), exceptions: [], recurring: [], truncated: [])
        for wd in kids(c.kid("WeekDays"), "WeekDay") {
            let type = xnum(wd.kidText("DayType")).map { Int($0) }
            let working = wd.kidText("DayWorking")
            let periods = workingPeriods(wd)
            if let ty = type, ty >= 1 && ty <= 7 {
                if let w = working { info.week[ty - 1] = xbool(w) }
                if xbool(working) && !periods.isEmpty { info.hours[ty - 1] = periods }
            } else if type == 0 {
                let tp = wd.kid("TimePeriod")
                let from = dateOnly(kidText(tp, "FromDate")), to = dateOnly(kidText(tp, "ToDate"))
                if let f = from { info.exceptions.append((f, to ?? f, xbool(working), "", periods)) }
            }
        }
        for ex in kids(c.kid("Exceptions"), "Exception") {
            let tp = ex.kid("TimePeriod")
            let from = dateOnly(kidText(tp, "FromDate")), to = dateOnly(kidText(tp, "ToDate"))
            let byOcc = xbool(ex.kidText("EnteredByOccurrences"))
            let name = ex.kidText("Name") ?? ""
            let working = xbool(ex.kidText("DayWorking"))
            let periods = workingPeriods(ex)
            guard let f = from else { continue }
            if let k = info.exceptions.firstIndex(where: { $0.from == f && $0.to == (to ?? f) }) {
                if !name.isEmpty { info.exceptions[k].name = name }
                if !periods.isEmpty && info.exceptions[k].periods.isEmpty { info.exceptions[k].periods = periods }
                continue
            }
            let type = Int(xnum(ex.kidText("Type"), 1)!)
            let occ = Int(xnum(ex.kidText("Occurrences"), 1)!)
            if type >= 2 && type <= 7 && (occ > 1 || !byOcc), let fDn = parseISO(f), let tDn = parseISO(to ?? f) {
                // a recurring exception: one day off (or one day with other working hours) for each date it falls on
                let rule = RecurringException(type: type, fromDn: fDn, toDn: tDn, occurrences: byOcc ? occ : nil,
                                              period: Int(xnum(ex.kidText("Period"), 1)!), daysOfWeek: Int(xnum(ex.kidText("DaysOfWeek"), 0)!),
                                              monthItem: Int(xnum(ex.kidText("MonthItem"), 0)!), monthPosition: Int(xnum(ex.kidText("MonthPosition"), 0)!),
                                              month: Int(xnum(ex.kidText("Month"), 0)!), monthDay: Int(xnum(ex.kidText("MonthDay"), 1)!))
                let limit = 2000
                let dates = expandRecurringException(rule, weekStart: weekStart, limit: limit)
                for dn in dates {
                    // MPXJ (and older MS Project XML) also lists each date as a dated exception: give that one the name, keep one per day
                    let iso = toISO(dn)
                    if let k = info.exceptions.firstIndex(where: { $0.from == iso && $0.to == iso }) {
                        if info.exceptions[k].name.isEmpty { info.exceptions[k].name = name }
                        if !periods.isEmpty && info.exceptions[k].periods.isEmpty { info.exceptions[k].periods = periods }
                    } else {
                        info.exceptions.append((iso, iso, working, name, periods))
                    }
                }
                info.recurring.append((name.isEmpty ? f : name, dates.count))
                if dates.count >= limit && (byOcc ? occ > limit : true) { info.truncated.append(name.isEmpty ? f : name) }
                continue
            }
            info.exceptions.append((f, to ?? f, working, name, periods))
        }
        list.append(info)
    }
    // resolve inheritance from base calendars
    var byUid: [Int: CalInfo] = [:]
    for c in list where byUid[c.uid] == nil { byUid[c.uid] = c }
    for c in list { byUid[c.uid] = c } // a later duplicate wins, like Map
    var resolved: [Int: (week: [Bool], hours: [[Period]?], exceptions: [(from: String, to: String, working: Bool, name: String, periods: [Period])])] = [:]
    func resolve(_ c: CalInfo, _ seen: inout Set<Int>) -> (week: [Bool], hours: [[Period]?], exceptions: [(from: String, to: String, working: Bool, name: String, periods: [Period])]) {
        if let r = resolved[c.uid] { return r }
        seen.insert(c.uid)
        var week = c.week
        var hours = c.hours
        var exceptions = c.exceptions
        if c.baseUid != -1, let base = byUid[c.baseUid], !seen.contains(base.uid) {
            let b = resolve(base, &seen)
            week = week.enumerated().map { $0.element ?? b.week[$0.offset] }
            hours = hours.enumerated().map { $0.element ?? b.hours[$0.offset] }
            exceptions = b.exceptions + exceptions
        }
        let r = (week: week.map { $0 ?? false }, hours: hours, exceptions: exceptions)
        resolved[c.uid] = r
        return r
    }
    var out: [(uid: Int, def: CalendarDef)] = []
    for c in list {
        let isResourceCal = !c.isBase && !taskCalUids.contains(c.uid)
        if isResourceCal { skipped += 1; continue }
        var seen = Set<Int>()
        let r = resolve(c, &seen)
        if !c.recurring.isEmpty {
            let days = c.recurring.reduce(0) { $0 + $1.dates }
            let names = c.recurring.prefix(5).map { $0.name }.joined(separator: ", ") + (c.recurring.count > 5 ? ", ..." : "")
            notes.append(ImportNote(level: "info", text: "Calendar \"\(c.name)\": \(plural(c.recurring.count, "recurring exception")) (\(names)) imported as \(plural(days, "dated exception")), one for each day it falls on."))
        }
        if !c.truncated.isEmpty {
            notes.append(ImportNote(level: "warn", text: "Calendar \"\(c.name)\": recurring exception(s) \(c.truncated.prefix(5).joined(separator: ", ")) repeat more than 2,000 times; only the first 2,000 dates were imported."))
        }
        // keep the working hours only when they differ from the standard 08:00-12:00 and 13:00-17:00
        let hours: [[Period]] = (0..<7).map { d in r.week[d] ? ((r.hours[d]?.isEmpty == false) ? r.hours[d]! : DEFAULT_PERIODS) : [] }
        let custom = (0..<7).contains { r.week[$0] && hours[$0] != DEFAULT_PERIODS }
        let def = CalendarDef(id: "cal\(c.uid)", name: c.name, workWeek: r.week,
                              hours: custom ? hours.map { $0.map { [Double($0.s), Double($0.e)] } } : nil,
                              exceptions: r.exceptions.map { e in
                                  CalException(from: e.from, to: e.to, working: e.working, name: e.name,
                                               periods: e.working && !e.periods.isEmpty ? e.periods.map { [Double($0.s), Double($0.e)] } : nil)
                              })
        out.append((c.uid, def))
    }
    return out
}

/// Convert an MSPDI lag (LinkLag in tenths of a minute, or a plain number for percent) to a Lag.
func lagFromXml(_ raw: String?, _ format: String?, _ minPerDay: Double, _ minPerWeek: Double) -> Lag {
    let v = xnum(raw, 0)!
    if v == 0 { return Lag(v: 0, u: "d") }
    let f = Int(xnum(format, 7)!)
    if f == 19 || f == 20 { return Lag(v: v, u: "%") }
    let minutes = v / 10
    switch f > 20 ? f - 32 : f {
    case 3: return Lag(v: minutes, u: "m")
    case 4: return Lag(v: minutes, u: "em")
    case 5: return Lag(v: minutes / 60, u: "h")
    case 6: return Lag(v: minutes / 60, u: "eh")
    case 8, 12: return Lag(v: minutes / 1440, u: "ed")
    case 10: return Lag(v: minutes / 10080, u: "ew")
    case 9: return Lag(v: minutes / minPerWeek, u: "w")
    default: return Lag(v: minutes / minPerDay, u: "d") // days and months
    }
}

func trimNum(_ x: Double) -> Double { jsRound(x * 100) / 100 }

public func importMSPDI(_ xmlText: String, fileName: String = "Imported project") throws -> ImportResult {
    let root: XmlNode
    do { root = try parseXml(xmlText) } catch { throw ModelError("Cannot read this XML file: \(error)") }
    if root.name != "Project" { throw ModelError("This is not an MS Project XML file (the top element is not <Project>).") }
    var notes: [ImportNote] = []
    var skippedCalendars = 0
    func note(_ level: String, _ text: String) { notes.append(ImportNote(level: level, text: text)) }

    let minPerDay = { let v = xnum(root.kidText("MinutesPerDay"), Double(MIN_PER_DAY))!; return v != 0 ? v : Double(MIN_PER_DAY) }()
    let minPerWeek = { let v = xnum(root.kidText("MinutesPerWeek"), Double(MIN_PER_WEEK))!; return v != 0 ? v : Double(MIN_PER_WEEK) }()
    let startBoundary = timeMinutes(nonEmpty(root.kidText("DefaultStartTime")) ?? "08:00")
    let endBoundaryRaw = nonEmpty(root.kidText("DefaultFinishTime")) ?? "17:00"
    let eb = timeMinutes(endBoundaryRaw)
    let endBoundary = eb != 0 ? eb : 1440
    /// a date-time from the file as a stored date: just the date when the time is the usual start or finish of a working day
    func stampOf(_ text: String?) -> String? {
        var t = text ?? ""
        // /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}).*$/ -> $1
        let u = Array(t.utf8)
        if u.count >= 16, dateOnly(t) != nil, u[10] == UInt8(ascii: "T"), isAsciiDigit(u[11]), isAsciiDigit(u[12]), u[13] == UInt8(ascii: ":"), isAsciiDigit(u[14]), isAsciiDigit(u[15]),
           !t.contains("\n") && !t.contains("\r") {
            t = String(decoding: u[0..<16], as: UTF8.self)
        }
        guard let st = parseStamp(t) else { return nil }
        if st.min == nil || st.min == startBoundary || st.min == endBoundary || st.min == 0 || st.min == 1439 { return toISO(st.dn) }
        return toStamp(st.dn, st.min)
    }
    let taskEls = kids(root.kid("Tasks"), "Task")
    var taskCalUids = Set<Int>()
    for te in taskEls { let cu = Int(xnum(te.kidText("CalendarUID"), -1)!); if cu != -1 { taskCalUids.insert(cu) } }
    let projCalUid = Int(xnum(root.kidText("CalendarUID"), -1)!)
    if projCalUid != -1 { taskCalUids.insert(projCalUid) }

    var cals = parseCalendars(root, taskCalUids, &notes, &skippedCalendars)
    let calIds = Set(cals.map { $0.def.id })
    var defaultCalId = "cal\(projCalUid)"
    if !calIds.contains(defaultCalId) {
        if !cals.isEmpty { defaultCalId = cals[0].def.id; note("warn", "The project calendar was not found in the file; the first calendar was used.") }
        else { let d = defaultCalendarDef("Standard"); cals.append((1, d)); defaultCalId = d.id; note("warn", "No calendars in the file; a standard Mon-Fri calendar was used.") }
    }

    let title = nonEmpty(root.kidText("Title")) ?? nonEmpty(root.kidText("Name")) ?? fileName.replacingOccurrences(of: "\\.[^.]+$", with: "", options: .regularExpression)
    let firstTask = taskEls.count > 1 ? taskEls[1] : taskEls.first
    let startDate = dateOnly(root.kidText("StartDate")) ?? toISO(parseISO(dateOnly(kidText(firstTask, "Start")) ?? "2026-01-01") ?? 0)
    var project = newProject(name: title, startDate: startDate)
    project.calendars = cals.map { $0.def }
    project.settings.defaultCalendarId = defaultCalId
    project.settings.hoursPerDay = jsRound((minPerDay / 60) * 100) / 100
    project.settings.hoursPerWeek = jsRound((minPerWeek / 60) * 100) / 100
    project.settings.daysPerMonth = xnum(root.kidText("DaysPerMonth"), DEFAULT_DAYS_PER_MONTH)!
    project.settings.statusDate = dateOnly(root.kidText("StatusDate"))
    project.settings.honorConstraints = root.kidText("HonorConstraints") != "0"
    project.settings.criticalSlackDays = max(0, xnum(root.kidText("CriticalSlackLimit"), 0)!)
    if root.kidText("ScheduleFromStart") == "0" { note("warn", "This project is scheduled from its finish date in MS Project. Ganttpath always schedules from the start date.") }

    // ---- tasks
    struct Row { var task: Task; var name: String; var fileStart: String?; var fileFinish: String?; var isSummary: Bool; var isManual: Bool }
    var rows: [Row] = []
    var seenUid = Set<Int>()
    var st = ["blank": 0, "inactive": 0, "crossLinks": 0, "badLinks": 0, "elapsedDurations": 0, "baselinesSkipped": 0, "badConstraints": 0,
              "links": 0, "baselines": 0, "manual": 0, "milestones": 0, "resourceAssignments": 0, "summaryConstraints": 0]
    var exInactive: [String] = [], exElapsed: [String] = []
    for te in taskEls {
        guard let uidD = xnum(te.kidText("UID")) else { continue }
        let uid = Int(uidD)
        let outlineLevel = Int(xnum(te.kidText("OutlineLevel"), 1)!)
        if uid == 0 && outlineLevel == 0 { continue } // the project summary row
        if xbool(te.kidText("IsNull")) || (te.kidText("Name") == nil && te.kidText("Start") == nil) { st["blank"]! += 1; continue }
        if seenUid.contains(uid) { continue }
        seenUid.insert(uid)
        let name = te.kidText("Name") ?? ""
        let isManual = xbool(te.kidText("Manual"))
        let isSummary = xbool(te.kidText("Summary"))
        if te.kidText("Active") == "0" && !isSummary { st["inactive"]! += 1; if exInactive.count < 5 { exInactive.append(name) } }
        let durFormat = Int(xnum(te.kidText("DurationFormat"), 7)!)
        let rawDur = te.kidText(isManual && nonEmpty(te.kidText("ManualDuration")) != nil ? "ManualDuration" : "Duration")
        let hours = hoursFromDuration(rawDur) ?? 0
        let dur = jsRoundInt(hours * 60) // working minutes, exactly as MS Project stores them
        let unit = UNIT_OF_FORMAT[durFormat > 20 ? durFormat - 32 : durFormat] ?? "d"
        if isElapsedUnit(unit) && !isSummary { st["elapsedDurations"]! += 1; if exElapsed.count < 5 { exElapsed.append(name) } }
        let milestoneFlag = xbool(te.kidText("Milestone"))
        let fileStart = dateOnly(te.kidText("Start"))
        let fileFinish = dateOnly(te.kidText("Finish"))
        var task = Task(uid: uid)
        task.name = name
        task.level = max(1, outlineLevel)
        task.mode = isManual && !isSummary ? "manual" : "auto"
        task.dur = isSummary ? 0 : dur
        task.durUnit = isSummary && isElapsedUnit(unit) ? "d" : unit
        task.milestone = milestoneFlag && dur > 0
        if task.mode == "manual" {
            st["manual"]! += 1
            task.start = stampOf(te.kidText("ManualStart")) ?? fileStart
            task.finish = stampOf(te.kidText("ManualFinish")) ?? fileFinish
            if nonEmpty(task.start) == nil { task.mode = "auto" }
        }
        if milestoneFlag || dur == 0 { st["milestones"]! += 1 }
        // constraint
        let ctype = Int(xnum(te.kidText("ConstraintType"), 0)!)
        let cname = CODE_TO_CONSTRAINT[ctype] ?? "ASAP"
        let cdate = stampOf(te.kidText("ConstraintDate"))
        if cname != "ASAP" && cname != "ALAP" && cdate == nil { st["badConstraints"]! += 1; task.constraint = .asap }
        else { task.constraint = Constraint(type: cname, date: cname == "ASAP" || cname == "ALAP" ? nil : cdate) }
        if isSummary && cname != "ASAP" { st["summaryConstraints"]! += 1 }
        task.deadline = stampOf(te.kidText("Deadline"))
        task.pct = min(100, max(0, xnum(te.kidText("PercentComplete"), 0)!))
        task.actualStart = stampOf(te.kidText("ActualStart"))
        task.actualFinish = stampOf(te.kidText("ActualFinish"))
        let cu = Int(xnum(te.kidText("CalendarUID"), -1)!)
        task.calendarId = cu != -1 && "cal\(cu)" != defaultCalId && calIds.contains("cal\(cu)") ? "cal\(cu)" : nil
        task.notes = te.kidText("Notes") ?? ""
        if !isSummary {
            // Active, Priority, Type, HideBar and Rollup are read as they are; a summary task always has Rollup = 1 in MS Project, which says nothing here
            task.inactive = te.kidText("Active") == "0"
            task.rollup = xbool(te.kidText("Rollup"))
            let ty = Int(xnum(te.kidText("Type"), 0)!)
            task.taskType = ty >= 0 && ty < CODE_TO_TYPE.count ? CODE_TO_TYPE[ty] : "fixedUnits"
            if task.inactive { task.start = stampOf(te.kidText("Start")) ?? fileStart; task.finish = stampOf(te.kidText("Finish")) ?? fileFinish } // it keeps the dates it had
        }
        task.hideBar = xbool(te.kidText("HideBar"))
        let pri = xnum(te.kidText("Priority"), 500)!
        task.priority = min(1000, max(0, jsRoundInt(pri)))
        // baselines
        task.baselines = Array(repeating: nil, count: BASELINE_COUNT)
        for b in te.kids("Baseline") {
            if xbool(b.kidText("Interim")) { continue }
            let n = Int(xnum(b.kidText("Number"), 0)!)
            guard let bs = stampOf(b.kidText("Start")), let bf = stampOf(b.kidText("Finish")) else { continue }
            if n < 0 || n >= BASELINE_COUNT { st["baselinesSkipped"]! += 1; continue }
            let bh = hoursFromDuration(b.kidText("Duration")) ?? 0
            task.baselines[n] = Baseline(start: bs, finish: bf, duration: trimNum((bh * 60) / minPerDay), dur: jsRoundInt(bh * 60))
            st["baselines"]! += 1
        }
        // links (uid targets are checked after all tasks are known)
        task.preds = []
        var badNow = 0
        for l in te.kids("PredecessorLink") {
            if xbool(l.kidText("CrossProject")) { st["crossLinks"]! += 1; continue }
            guard let pu = xnum(l.kidText("PredecessorUID")) else { badNow += 1; continue }
            let type = CODE_TO_LINK[Int(xnum(l.kidText("Type"), 1)!)] ?? "FS"
            task.preds.append(Pred(uid: Int(pu), type: type, lag: lagFromXml(l.kidText("LinkLag"), l.kidText("LagFormat"), minPerDay, minPerWeek)))
        }
        st["badLinks"]! += badNow
        rows.append(Row(task: task, name: name, fileStart: fileStart, fileFinish: fileFinish, isSummary: isSummary, isManual: isManual))
    }
    var tasks = rows.map { $0.task }
    let uids = Set(tasks.map { $0.uid })
    for k in tasks.indices {
        let before = tasks[k].preds.count
        tasks[k].preds = tasks[k].preds.filter { uids.contains($0.uid) && $0.uid != tasks[k].uid }
        st["badLinks"]! += before - tasks[k].preds.count
        st["links"]! += tasks[k].preds.count
    }
    project.tasks = tasks
    project.nextUid = max(1, (tasks.map { $0.uid + 1 }.max() ?? 1))
    normalizeProject(&project)

    // ---- custom fields (Text1-30, Number1-20, Flag1-20, Date, Cost, Duration, Start, Finish, Outline Code fields) as custom columns
    let extAttr = kids(root.kid("ExtendedAttributes"), "ExtendedAttribute")
    let custom = importCustomFields(extAttr, taskEls, keep: Set(project.tasks.map { $0.uid }), minPerDay: minPerDay, minPerWeek: minPerWeek)
    project.customColumns += custom.columns
    for k in project.tasks.indices {
        for (colId, v) in custom.values[project.tasks[k].uid] ?? [:] { project.tasks[k].custom[colId] = v }
    }

    // ---- assignments / resources (not carried over)
    let assign = kids(root.kid("Assignments"), "Assignment").filter { Int(xnum($0.kidText("ResourceUID"), -65535)!) != -65535 }
    st["resourceAssignments"] = assign.count
    let realResources = kids(root.kid("Resources"), "Resource").filter { Int(xnum($0.kidText("UID"), 0)!) != 0 }

    // ---- schedule with Ganttpath's engine and compare with the dates stored in the file
    let s = schedule(project)
    applySchedule(&project, s)
    var differences: [ImportDifference] = []
    var compared = 0, matched = 0
    for (i, r) in rows.enumerated() {
        if (r.isManual && r.task.mode == "manual") || r.task.inactive { continue } // identical by construction
        guard let fs = r.fileStart, let ff = r.fileFinish else { continue }
        compared += 1
        let row = s.tasks[i]
        if row.start == fs && row.finish == ff { matched += 1 }
        else { differences.append(ImportDifference(id: i + 1, name: r.name, file: "\(fs) to \(ff)", ganttpath: "\(row.start ?? "null") to \(row.finish ?? "null")")) }
    }

    // ---- report
    if st["resourceAssignments"]! > 0 || !realResources.isEmpty { note("info", "Resources are not supported: \(realResources.count) resource(s) and \(st["resourceAssignments"]!) assignment(s) were left out. Task dates and durations are kept.") }
    if !custom.columns.isEmpty {
        let names = custom.columns.prefix(8).map { $0.name }.joined(separator: ", ") + (custom.columns.count > 8 ? ", ..." : "")
        note("info", "\(plural(custom.columns.count, "custom field")) imported as custom column\(custom.columns.count == 1 ? "" : "s") (\(names)). Show \(custom.columns.count == 1 ? "it" : "them") with Columns in the toolbar.")
    }
    if custom.datesWithTime > 0 { note("info", "Custom date fields keep the date only; the time of day was left out (\(custom.datesWithTime) value(s)).") }
    if custom.unused > 0 { note("info", "\(plural(custom.unused, "custom field definition")) with no values on any task \(custom.unused == 1 ? "was" : "were") left out.") }
    if st["inactive"]! > 0 { note("info", "\(st["inactive"]!) inactive task(s) were imported as inactive: they keep their dates, take no part in the schedule and are shown struck through (e.g. \(exInactive.joined(separator: "; ")))." ) }
    if st["crossLinks"]! > 0 { note("warn", "\(st["crossLinks"]!) link(s) to other project files were skipped.") }
    if st["badLinks"]! > 0 { note("warn", "\(st["badLinks"]!) link(s) pointing at missing tasks were skipped.") }
    if st["elapsedDurations"]! > 0 { note("info", "\(st["elapsedDurations"]!) task(s) have elapsed durations: they run round the clock, weekends and holidays included, as in MS Project (e.g. \(exElapsed.joined(separator: "; "))).") }
    if st["baselinesSkipped"]! > 0 { note("info", "\(st["baselinesSkipped"]!) baseline(s) above Baseline 10 were skipped.") }
    if st["badConstraints"]! > 0 { note("warn", "\(st["badConstraints"]!) constraint(s) without a date were changed to As Soon As Possible.") }
    if st["summaryConstraints"]! > 0 { note("info", "\(st["summaryConstraints"]!) summary task(s) had their own constraint; summary tasks take their dates from their sub-tasks here, so it was ignored.") }
    if skippedCalendars > 0 { note("info", "\(skippedCalendars) resource calendar(s) were skipped.") }
    if s.conflictCount > 0 { note("warn", "\(s.conflictCount) scheduling conflict(s) were found after import; see the Conflicts list.") }
    if !differences.isEmpty { note("warn", "Ganttpath calculates different dates from the file for \(differences.count) of \(compared) automatically scheduled task(s). See the list below; the file's own stored dates were not used.") }

    let report = ImportReport(
        stats: ["tasks": tasks.count, "links": st["links"]!, "calendars": project.calendars.count, "baselines": st["baselines"]!, "manualTasks": st["manual"]!, "blankRowsSkipped": st["blank"]!],
        compared: compared, matched: matched, differences: Array(differences.prefix(50)), differenceCount: differences.count, notes: notes, hasCompare: true)
    return ImportResult(project: project, report: report)
}

// MARK: - custom fields

/// MS Project custom fields as Ganttpath custom columns: the column is named after the field's alias (or its name, e.g. "Text1"),
/// and its type follows the field: Text and Outline Code as text, Number and Cost as numbers, Flag as a Yes flag, Date, Start and
/// Finish as dates, Duration as text such as "2d". Fields that no task has a value for are left out.
func importCustomFields(_ defs: [XmlNode], _ taskEls: [XmlNode], keep: Set<Int>, minPerDay: Double, minPerWeek: Double)
    -> (columns: [CustomColumn], values: [Int: [String: JSON]], datesWithTime: Int, unused: Int) {
    var order: [String] = []
    var info: [String: (name: String, alias: String?)] = [:]
    for d in defs {
        guard let id = nonEmpty(d.kidText("FieldID")), info[id] == nil else { continue }
        order.append(id)
        info[id] = (nonEmpty(d.kidText("FieldName")) ?? "Field \(id)", nonEmpty(d.kidText("Alias")))
    }
    func kind(_ fieldName: String) -> String {
        let base = fieldName.replacingOccurrences(of: "[0-9 ]", with: "", options: .regularExpression).lowercased()
        switch base {
        case "number", "cost": return "number"
        case "flag": return "flag"
        case "date", "start", "finish": return "date"
        case "duration": return "duration"
        default: return "text"
        }
    }
    var values: [Int: [String: JSON]] = [:]
    var used = Set<String>()
    var datesWithTime = 0
    for te in taskEls {
        guard let uidD = xnum(te.kidText("UID")), keep.contains(Int(uidD)) else { continue }
        let uid = Int(uidD)
        for ea in te.kids("ExtendedAttribute") {
            guard let id = nonEmpty(ea.kidText("FieldID")), let raw = nonEmpty(ea.kidText("Value")) else { continue }
            if info[id] == nil { order.append(id); info[id] = ("Field \(id)", nil) }
            let colId = "ms\(id)"
            let v: JSON?
            switch kind(info[id]!.name) {
            case "number":
                v = Double(raw).flatMap { $0.isFinite ? JSON.number($0) : nil }
            case "flag":
                v = (raw == "1" || raw.lowercased() == "true") ? .bool(true) : nil
            case "date":
                if let d = dateOnly(raw) {
                    v = .string(d)
                    let time = raw.count >= 16 ? String(raw.dropFirst(11).prefix(5)) : "00:00"
                    if time != "00:00" { datesWithTime += 1 }
                } else { v = nil }
            case "duration":
                let minutes = (hoursFromDuration(raw) ?? 0) * 60
                let unit = UNIT_OF_FORMAT[Int(xnum(ea.kidText("DurationFormat"), 7)!)] ?? "d"
                let per: Double = unit == "m" ? 1 : unit == "h" ? 60 : unit == "w" ? minPerWeek : unit == "mo" ? minPerDay * 20 : minPerDay
                v = .string("\(jsNumberString(trimNum(minutes / per)))\(unit == "mo" ? "mo" : unit)")
            default:
                v = .string(raw)
            }
            guard let val = v else { continue }
            values[uid, default: [:]][colId] = val
            used.insert(id)
        }
    }
    let columns: [CustomColumn] = order.filter { used.contains($0) }.map { id in
        let f = info[id]!
        let k = kind(f.name)
        return CustomColumn(id: "ms\(id)", name: f.alias ?? f.name, type: k == "duration" ? "text" : k)
    }
    return (columns, values, datesWithTime, order.filter { !used.contains($0) }.count)
}

// MARK: - custom fields in MS Project XML

/// MS Project's task custom fields: the FieldID of Text1 ... Text30 and so on, as MS Project writes them (read from MS Project
/// files with MPXJ). They are not evenly spaced.
public let MSP_TASK_FIELDS: [String: [Int]] = [
    "Text": [188743731, 188743734, 188743737, 188743740, 188743743, 188743746, 188743747, 188743748, 188743749, 188743750,
             188743997, 188743998, 188743999, 188744000, 188744001, 188744002, 188744003, 188744004, 188744005, 188744006,
             188744007, 188744008, 188744009, 188744010, 188744011, 188744012, 188744013, 188744014, 188744015, 188744016],
    "Number": [188743767, 188743768, 188743769, 188743770, 188743771, 188743982, 188743983, 188743984, 188743985, 188743986,
               188743987, 188743988, 188743989, 188743990, 188743991, 188743992, 188743993, 188743994, 188743995, 188743996],
    "Flag": [188743752, 188743753, 188743754, 188743755, 188743756, 188743757, 188743758, 188743759, 188743760, 188743761,
             188743972, 188743973, 188743974, 188743975, 188743976, 188743977, 188743978, 188743979, 188743980, 188743981],
    "Date": [188743945, 188743946, 188743947, 188743948, 188743949, 188743950, 188743951, 188743952, 188743953, 188743954],
    "Cost": [188743786, 188743787, 188743788, 188743938, 188743939, 188743940, 188743941, 188743942, 188743943, 188743944],
    "Duration": [188743783, 188743784, 188743785, 188743955, 188743956, 188743957, 188743958, 188743959, 188743960, 188743961],
]

/// A custom column and the MS Project field it is written to. `kind` is text, number, flag, date, cost or duration.
struct ExportField { var col: CustomColumn; var fieldId: Int; var fieldName: String; var kind: String }

/// Which MS Project field each custom column goes to. A column that came from an MS Project field (id "ms<FieldID>") goes back to
/// the same field; the others take the next free field of their kind: text and list columns Text, number Number, flag Flag, date
/// Date. Columns with no free field left are listed as skipped.
func planCustomFields(_ p: Project) -> (written: [ExportField], skipped: [String]) {
    var byId: [Int: (group: String, n: Int)] = [:]
    for (g, ids) in MSP_TASK_FIELDS { for (k, id) in ids.enumerated() { byId[id] = (g, k + 1) } }
    var used = Set<Int>()
    var out: [ExportField] = [], skipped: [String] = []
    var rest: [CustomColumn] = []
    for c in p.customColumns {
        if c.id.hasPrefix("ms"), let id = Int(c.id.dropFirst(2)), let f = byId[id], !used.contains(id) {
            used.insert(id)
            out.append(ExportField(col: c, fieldId: id, fieldName: "\(f.group)\(f.n)", kind: f.group.lowercased()))
        } else { rest.append(c) }
    }
    for c in rest {
        let group = c.type == "number" ? "Number" : c.type == "flag" ? "Flag" : c.type == "date" ? "Date" : "Text"
        guard let k = MSP_TASK_FIELDS[group]!.firstIndex(where: { !used.contains($0) }) else { skipped.append(c.name); continue }
        let id = MSP_TASK_FIELDS[group]![k]
        used.insert(id)
        out.append(ExportField(col: c, fieldId: id, fieldName: "\(group)\(k + 1)", kind: group.lowercased()))
    }
    return (out.sorted { $0.fieldId < $1.fieldId }, skipped)
}

/// A task's value of a custom column as MS Project XML text, or nil when it has none.
func customFieldValue(_ f: ExportField, _ v: JSON?, _ s: Settings, _ dayStartT: String) -> String? {
    guard let v = v, !v.isNull else { return nil }
    switch f.kind {
    case "number", "cost":
        let n = v.jsNumber
        return n.isFinite ? jsNumberString(n) : nil
    case "flag":
        return v.truthy ? "1" : nil
    case "date":
        return parseISO(v.jsString).map { "\(toISO($0))T\(dayStartT)" }
    case "duration":
        return parseDuration(v.jsString, s).map { minDur($0.min) }
    default:
        let text = v.jsString
        return text.isEmpty ? nil : text
    }
}
