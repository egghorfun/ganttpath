// Runs a script of model commands through a Session, the way the app's window does, and reports every result.
// Script: { "project": {...}, "steps": [ { "op": "setDuration", ... }, ... ] }
// Output: { "steps": [ { ok, error?, result? } ], "project": {...}, "sched": {...}, "undo": n, "redo": n }
// The same scripts were run through the JavaScript app 1.3.6; its results are kept in Tests/GanttpathCoreTests/Fixtures/js136-ops.json.z.

import Foundation

public struct OpsError: Error, CustomStringConvertible { public let description: String }

private func i(_ v: JSON?) -> Int? { v?.number.map { Int($0) } }
private func ints(_ v: JSON?) -> [Int] { (v?.array ?? []).compactMap { $0.number.map { Int($0) } } }
private func s(_ v: JSON?) -> String? { v?.string }
private func lag(_ v: JSON?) -> Lag {
    guard let o = v?.object else { return .zero }
    return Lag(v: (o["v"] ?? .null).jsNumber, u: o["u"]?.string ?? "d")
}

public func runOpsScript(_ script: JSON) throws -> JSON {
    guard let o = script.object, let pj = o["project"] else { throw OpsError(description: "script needs a project") }
    let session = Session(try Project.from(json: pj))
    var outSteps: [JSON] = []
    var clip: TaskClip? = nil
    for step in o["steps"]?.array ?? [] {
        let a = step.object ?? JSONObject()
        let op = a["op"]?.string ?? ""
        func record<T>(_ r: RunResult<T>, _ conv: (T) -> JSON = { _ in .null }) {
            var so = JSONObject()
            so["ok"] = .bool(r.ok)
            if let e = r.error { so["error"] = .string(e) }
            if r.unchanged { so["unchanged"] = .bool(true) }
            if let v = r.value { let j = conv(v); if !j.isNull { so["result"] = j } }
            outSteps.append(.object(so))
        }
        switch op {
        case "undo": outSteps.append(.object(JSONObject([("ok", .bool(session.undo()))])))
        case "redo": outSteps.append(.object(JSONObject([("ok", .bool(session.redo()))])))
        case "insertTask":
            record(session.run(op) { p, _ in insertTask(&p, i(a["index"]) ?? 0, level: i(a["level"])).uid }) { JSON($0) }
        case "deleteTasks":
            record(session.run(op) { p, _ in deleteTasks(&p, ints(a["uids"])) }) { JSON($0) }
        case "insertRows":
            record(session.run(op) { p, _ in insertRows(&p, i(a["index"]) ?? 0, (a["count"] ?? .null).jsNumber, level: i(a["level"])) }) { .array($0.map { JSON($0) }) }
        case "copy":
            clip = copyTasks(session.project, ints(a["uids"]))
            outSteps.append(.object(JSONObject([("ok", .bool(true)), ("result", JSON(clip?.rows.count ?? 0))])))
        case "paste":
            let c = clip
            record(session.run(op) { p, _ in try pasteTasks(&p, c, beforeUid: i(a["beforeUid"]), level: i(a["level"])) }) { .array($0.map { JSON($0) }) }
        case "indent":
            record(session.run(op) { p, _ in indentTasks(&p, ints(a["uids"])) }) { .object(JSONObject([("changed", JSON($0.changed)), ("removedLinks", JSON($0.removedLinks))])) }
        case "outdent":
            record(session.run(op) { p, _ in outdentTasks(&p, ints(a["uids"])) }) { .object(JSONObject([("changed", JSON($0.changed)), ("removedLinks", JSON($0.removedLinks))])) }
        case "moveTasks":
            record(session.run(op) { p, _ in try moveTasks(&p, ints(a["uids"]), beforeUid: i(a["beforeUid"]), level: i(a["level"])) }) {
                .object(JSONObject([("moved", JSON($0.moved)), ("removedLinks", JSON($0.removedLinks))]))
            }
        case "setWbs":
            record(session.run(op) { p, _ in try setWbs(&p, i(a["uid"]) ?? -1, s(a["code"])) }) {
                .object(JSONObject([("moved", JSON($0.moved)), ("wbs", .string($0.wbs)), ("removedLinks", JSON($0.removedLinks)), ("same", .bool($0.same))]))
            }
        case "toggleCollapse":
            record(session.run(op) { p, _ in try toggleCollapse(&p, i(a["uid"]) ?? -1, a["value"]?.bool) })
        case "addLink":
            record(session.run(op) { p, _ in try addLink(&p, i(a["pred"]) ?? -1, i(a["succ"]) ?? -1, s(a["type"]) ?? "FS", lag(a["lag"])) })
        case "removeLink":
            record(session.run(op) { p, _ in try removeLink(&p, i(a["pred"]) ?? -1, i(a["succ"]) ?? -1) })
        case "setPredecessorsText":
            record(session.run(op) { p, _ in
                let r = parsePredecessors(s(a["text"]), idToUidMap(p))
                if !r.errors.isEmpty { throw ModelError(r.errors.joined(separator: "; ")) }
                try setPredecessors(&p, i(a["uid"]) ?? -1, r.preds)
            })
        case "setName": record(session.run(op) { p, _ in try setName(&p, i(a["uid"]) ?? -1, s(a["name"])) })
        case "setDurationText":
            record(session.run(op) { p, _ in
                let uid = i(a["uid"]) ?? -1
                let t = taskByUid(p, uid)
                _ = t
                guard let d = parseDuration(s(a["text"]), p.settings, "d") else { throw ModelError("Cannot read that duration") }
                try setDuration(&p, uid, d)
            })
        case "setStart": record(session.run(op) { p, _ in try setStart(&p, i(a["uid"]) ?? -1, s(a["value"])) })
        case "setFinish": record(session.run(op) { p, _ in try setFinish(&p, i(a["uid"]) ?? -1, s(a["value"])) })
        case "setConstraint": record(session.run(op) { p, _ in try setConstraint(&p, i(a["uid"]) ?? -1, s(a["type"]) ?? "", s(a["date"])) })
        case "setDeadline": record(session.run(op) { p, _ in try setDeadline(&p, i(a["uid"]) ?? -1, s(a["value"])) })
        case "setMode": record(session.run(op) { p, sc in try setMode(&p, i(a["uid"]) ?? -1, s(a["mode"]) ?? "", sc) })
        case "setMilestone": record(session.run(op) { p, _ in try setMilestone(&p, i(a["uid"]) ?? -1, a["on"]?.truthy ?? false) })
        case "setMonthTask": record(session.run(op) { p, _ in try setMonthTask(&p, i(a["uid"]) ?? -1, i(a["dn"]) ?? 0) })
        case "setPercent": record(session.run(op) { p, sc in try setPercent(&p, i(a["uid"]) ?? -1, (a["pct"] ?? .null).jsNumber, sc) })
        case "setActualDates": record(session.run(op) { p, _ in try setActualDates(&p, i(a["uid"]) ?? -1, s(a["start"]), s(a["finish"])) })
        case "setTaskCalendar": record(session.run(op) { p, _ in try setTaskCalendar(&p, i(a["uid"]) ?? -1, s(a["cal"])) })
        case "setWeight": record(session.run(op) { p, _ in try setWeight(&p, i(a["uid"]) ?? -1, s(a["value"])) })
        case "setPriority": record(session.run(op) { p, _ in try setPriority(&p, i(a["uid"]) ?? -1, s(a["value"]) ?? "") })
        case "setTaskType": record(session.run(op) { p, _ in try setTaskType(&p, i(a["uid"]) ?? -1, s(a["type"]) ?? "") })
        case "setTaskFlag": record(session.run(op) { p, _ in try setTaskFlag(&p, i(a["uid"]) ?? -1, s(a["key"]) ?? "", a["on"]?.truthy ?? false) })
        case "setNotes": record(session.run(op) { p, _ in try setNotes(&p, i(a["uid"]) ?? -1, s(a["text"])) })
        case "setNameStyleFlag": record(session.run(op) { p, _ in try setNameStyleFlag(&p, i(a["uid"]) ?? -1, s(a["key"]) ?? "", a["on"]?.truthy ?? false) })
        case "moveBarTo": record(session.run(op) { p, _ in try moveBarTo(&p, i(a["uid"]) ?? -1, i(a["dn"]) ?? 0, i(a["min"])) })
        case "resizeBarTo": record(session.run(op) { p, sc in try resizeBarTo(&p, i(a["uid"]) ?? -1, i(a["dn"]) ?? 0, sc) })
        case "setBaseline": record(session.run(op) { p, sc in try setBaseline(&p, i(a["n"]) ?? 0, sc, a["uids"].map { ints($0) }) })
        case "clearBaseline": record(session.run(op) { p, _ in try clearBaseline(&p, i(a["n"]) ?? 0, a["uids"].map { ints($0) }) })
        case "addTag": record(session.run(op) { p, _ in try addTag(&p, s(a["name"]), s(a["color"]) ?? "#64748B") })
        case "removeTag": record(session.run(op) { p, _ in removeTag(&p, s(a["name"]) ?? "") })
        case "setTaskTags": record(session.run(op) { p, _ in try setTaskTags(&p, ints(a["uids"]), on: (a["on"]?.array ?? []).compactMap { $0.string }, off: (a["off"]?.array ?? []).compactMap { $0.string }) })
        case "addCustomColumn": record(session.run(op) { p, _ in try addCustomColumn(&p, id: s(a["id"]), name: s(a["name"]), type: s(a["type"]) ?? "text") }) { .string($0) }
        case "removeCustomColumn": record(session.run(op) { p, _ in removeCustomColumn(&p, s(a["id"]) ?? "") })
        case "setCustomValue": record(session.run(op) { p, _ in try setCustomValue(&p, i(a["uid"]) ?? -1, s(a["col"]) ?? "", a["value"] ?? .null) })
        case "upsertCalendar":
            record(session.run(op) { p, _ in
                guard let d = CalendarDef.from(json: a["def"] ?? .null) else { throw ModelError("bad calendar") }
                return try upsertCalendar(&p, d)
            }) { .string($0) }
        case "removeCalendar": record(session.run(op) { p, _ in try removeCalendar(&p, s(a["id"]) ?? "") })
        case "updateSettings": record(session.run(op) { p, _ in try updateSettings(&p, a["patch"]?.object ?? JSONObject()) })
        case "setAllModes": record(session.run(op) { p, sc in try setAllModes(&p, s(a["mode"]) ?? "", sc) })
        case "applyTemplate":
            record(session.run(op) { p, _ in
                guard let t = BUILTIN_TEMPLATES.first(where: { $0.id == s(a["id"]) }) else { throw ModelError("no template") }
                return try applyTemplate(&p, t, startDate: s(a["startDate"])).count
            }) { JSON($0) }
        default:
            throw OpsError(description: "unknown op \(op)")
        }
    }
    return .object(JSONObject([
        ("steps", .array(outSteps)), ("project", session.project.json), ("sched", session.sched.json),
        ("undo", JSON(session.history.undoStack.count)), ("redo", JSON(session.history.redoStack.count)),
    ]))
}
