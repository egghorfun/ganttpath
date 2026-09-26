// gpcli - a command-line tool around GanttpathCore.
//
//   gpcli schedule <project.json|.gpath> [...]      print {project, sched} as JSON (the project after normalizing and scheduling)
//   gpcli schedule-dir <in-dir> <out-dir>           the same for every .json file of a folder, one output file each
//   gpcli ops <script.json>                         run a list of model commands (see Ops.swift) and print the results
//
// The output uses the same field names as the JavaScript app, so the two can be compared value by value.

import Foundation
import GanttpathCore

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func readText(_ path: String) -> String {
    guard let d = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return String(decoding: d, as: UTF8.self)
}

/// Accepts a bare project object or a .gpath envelope ({format, project}).
func loadProjectJSON(_ text: String) throws -> Project {
    let j = try JSONParser.parse(text)
    if let o = j.object, o["format"] != nil, let p = o["project"] { return try Project.from(json: p) }
    return try Project.from(json: j)
}

func scheduleOutput(_ text: String) -> JSON {
    do {
        var p = try loadProjectJSON(text)
        let s = scheduleAndApply(&p)
        return .object(JSONObject([("project", p.json), ("sched", s.json)]))
    } catch {
        return .object(JSONObject([("error", .string("\(error)"))]))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: gpcli schedule|schedule-dir|ops ...") }
switch cmd {
case "schedule":
    for f in args.dropFirst() { print(JSONWriter.stringify(scheduleOutput(readText(f)))) }
case "schedule-dir":
    guard args.count >= 3 else { fail("usage: gpcli schedule-dir <in> <out>") }
    let inDir = args[1], outDir = args[2]
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
    for f in files {
        let out = JSONWriter.stringify(scheduleOutput(readText(inDir + "/" + f)))
        _ = FileManager.default.createFile(atPath: outDir + "/" + f, contents: out.data(using: .utf8))
    }
    print("\(files.count) file(s)")
case "view-dir":
    guard args.count >= 3 else { fail("usage: gpcli view-dir <in> <out>") }
    viewDir(args[1], args[2])
case "ops":
    guard args.count >= 2 else { fail("usage: gpcli ops <script.json>") }
    do {
        let script = try JSONParser.parse(readText(args[1]))
        print(JSONWriter.stringify(try runOpsScript(script)))
    } catch { fail("\(error)") }
case "ops-dir":
    guard args.count >= 3 else { fail("usage: gpcli ops-dir <in> <out>") }
    let inDir = args[1], outDir = args[2]
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
    for f in files {
        let out: JSON
        do { out = try runOpsScript(try JSONParser.parse(readText(inDir + "/" + f))) } catch { out = .object(JSONObject([("crash", .string("\(error)"))])) }
        _ = FileManager.default.createFile(atPath: outDir + "/" + f, contents: JSONWriter.stringify(out).data(using: .utf8))
    }
    print("\(files.count) file(s)")
case "export-dir":
    // gpcli export-dir <xml|csv|xlsx> <in> <out>: export every project (fixed clock, so files are comparable)
    guard args.count >= 4 else { fail("usage: gpcli export-dir <fmt> <in> <out>") }
    let fmt = args[1], inDir = args[2], outDir = args[3]
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    for f in files {
        do {
            let p = try loadProjectJSON(readText(inDir + "/" + f))
            let out = try exportProject(fmt, p, now: now)
            _ = FileManager.default.createFile(atPath: outDir + "/" + f.replacingOccurrences(of: ".json", with: out.ext), contents: out.data)
            _ = FileManager.default.createFile(atPath: outDir + "/" + f.replacingOccurrences(of: ".json", with: ".notes.json"),
                                           contents: JSONWriter.stringify(.array(out.notes.map { .string($0) })).data(using: .utf8))
        } catch { _ = FileManager.default.createFile(atPath: outDir + "/" + f.replacingOccurrences(of: ".json", with: ".error"), contents: "\(error)".data(using: .utf8)) }
    }
    print("\(files.count) file(s)")
case "import-dir":
    // gpcli import-dir <in> <out>: open every .xml/.csv/.xlsx file, write {project, report}
    guard args.count >= 3 else { fail("usage: gpcli import-dir <in> <out>") }
    let inDir = args[1], outDir = args[2]
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?.filter { $0.hasSuffix(".xml") || $0.hasSuffix(".csv") || $0.hasSuffix(".xlsx") }.sorted() ?? []
    for f in files {
        var out: JSON
        do {
            let r = try importFile(inDir + "/" + f)
            guard case .imported(let res, let source, let kind) = r else { fail("unexpected") }
            out = .object(JSONObject([("project", res.project.json), ("report", res.report.json), ("source", .string(source)), ("sourceKind", .string(kind))]))
        } catch { out = .object(JSONObject([("error", .string("\(error)"))])) }
        _ = FileManager.default.createFile(atPath: outDir + "/" + f + ".json", contents: JSONWriter.stringify(out).data(using: .utf8))
    }
    print("\(files.count) file(s)")
default:
    fail("unknown command \(cmd)")
}
