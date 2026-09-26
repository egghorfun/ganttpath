// The schedule result as JSON, with the same field names as the JavaScript app's schedule() result.
// Used by the gpcli tool (cross-checks against the JavaScript app) and handy for debugging.

import Foundation

private func opt(_ v: Int?) -> JSON { v.map { .number(Double($0)) } ?? .null }
private func opt(_ v: Double?) -> JSON { v.map { .number($0) } ?? .null }
private func opt(_ v: String?) -> JSON { v.map { .string($0) } ?? .null }

extension Conflict {
    public var json: JSON {
        .object(JSONObject([("index", JSON(index)), ("uid", JSON(uid)), ("type", .string(type)), ("message", .string(message))]))
    }
}

extension Lag {
    public var json: JSON { .object(JSONObject([("v", .number(v)), ("u", .string(u))])) }
}

extension ScheduledTask {
    public var json: JSON {
        var o = JSONObject()
        o["index"] = JSON(index); o["uid"] = JSON(uid); o["id"] = JSON(id); o["wbs"] = .string(wbs); o["parent"] = JSON(parent)
        o["children"] = .array(children.map { JSON($0) })
        o["isSummary"] = .bool(isSummary); o["isManual"] = .bool(isManual); o["inactive"] = .bool(inactive)
        o["hideBar"] = .bool(hideBar); o["rollup"] = .bool(rollup); o["onTimeline"] = .bool(onTimeline)
        o["priority"] = JSON(priority); o["taskType"] = .string(taskType); o["isMilestone"] = .bool(isMilestone)
        o["start"] = opt(start); o["finish"] = opt(finish); o["startMin"] = opt(startMin); o["finishMin"] = opt(finishMin)
        o["startStamp"] = opt(startStamp); o["finishStamp"] = opt(finishStamp); o["timed"] = .bool(timed)
        o["startFrac"] = opt(startFrac); o["finishFrac"] = opt(finishFrac); o["startTick"] = opt(startTick); o["finishTick"] = opt(finishTick)
        o["duration"] = .number(duration); o["durationMin"] = JSON(durationMin); o["durUnit"] = .string(durUnit)
        o["lateStart"] = opt(lateStart); o["lateFinish"] = opt(lateFinish); o["lateStartMin"] = opt(lateStartMin); o["lateFinishMin"] = opt(lateFinishMin)
        o["totalSlack"] = opt(totalSlack); o["freeSlack"] = opt(freeSlack); o["totalSlackMin"] = opt(totalSlackMin); o["freeSlackMin"] = opt(freeSlackMin)
        o["critical"] = .bool(critical); o["nearCritical"] = .bool(nearCritical); o["pct"] = .number(pct)
        o["conflicts"] = .array(conflicts.map { $0.json }); o["hasConflict"] = .bool(hasConflict); o["childConflict"] = .bool(childConflict)
        return .object(o)
    }
}

extension ScheduleResult {
    public var json: JSON {
        var o = JSONObject()
        o["tasks"] = .array(tasks.map { $0.json })
        o["projectStart"] = opt(projectStart)
        o["projectFinish"] = opt(projectFinish)
        o["conflicts"] = .array(conflicts.map { $0.json })
        o["conflictCount"] = JSON(conflictCount)
        o["links"] = .array(links.map { l in
            .object(JSONObject([("predUid", JSON(l.predUid)), ("uid", JSON(l.uid)), ("pIndex", JSON(l.pIndex)), ("tIndex", JSON(l.tIndex)),
                                ("type", .string(l.type)), ("lag", l.lag.json), ("conflict", .bool(l.conflict))]))
        })
        o["cycles"] = .array(cycles.map { JSON($0) })
        o["calendarInvalid"] = .bool(calendarInvalid)
        o["dayMin"] = JSON(dayMin)
        o["weekMin"] = JSON(weekMin)
        return .object(o)
    }
}

extension ImportReport {
    /// The report with the JavaScript app's field names: { stats, compare: { compared, matched, differences, differenceCount } | null, notes }.
    public var json: JSON {
        var o = JSONObject()
        o["stats"] = .object(JSONObject(stats.sorted { $0.key < $1.key }.map { ($0.key, JSON($0.value)) }))
        if hasCompare {
            o["compare"] = .object(JSONObject([
                ("compared", JSON(compared ?? 0)), ("matched", JSON(matched ?? 0)),
                ("differences", .array(differences.map { d in .object(JSONObject([("id", JSON(d.id)), ("name", .string(d.name)), ("file", .string(d.file)), ("ganttpath", .string(d.ganttpath))])) })),
                ("differenceCount", JSON(differenceCount)),
            ]))
        } else { o["compare"] = .null }
        o["notes"] = .array(notes.map { .object(JSONObject([("level", .string($0.level)), ("text", .string($0.text))])) })
        return .object(o)
    }
}
