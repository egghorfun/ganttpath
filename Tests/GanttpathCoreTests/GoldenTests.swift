// Cross-check against the JavaScript app, version 1.3.6.
//
// The fixtures js136-*.json.z hold inputs and the exact output the JavaScript Ganttpath 1.3.6 produced for them (compressed with
// DEFLATE): random projects that exercise every scheduling feature (and malformed input), random scripts of 40 editing commands,
// MS Project XML exports, and imports of XML / CSV / Excel files. The Swift app must give the same values. Fields a JavaScript object
// leaves out and the Swift one writes as null count as equal; everything else must match exactly.

import Foundation
import Testing
@testable import GanttpathCore

private func loadGolden(_ name: String) throws -> [JSON] {
    let z = FileManager.default.contents(atPath: fixture(name))!
    let raw = try inflateRaw(Array(z))
    return try JSONParser.parse(String(decoding: raw, as: UTF8.self)).array!
}

/// Differences between two JSON values; missing and null are the same, numbers may differ by float noise only.
func jsonDiff(_ a: JSON, _ b: JSON, _ path: String = "", _ out: inout [String], ignore: Set<String> = []) {
    if out.count > 10 { return }
    switch (a, b) {
    case (.object(let x), .object(let y)):
        let keys = Set(x.keys).union(y.keys)
        for k in keys.sorted() where !ignore.contains(k) {
            let va = x[k] ?? .null, vb = y[k] ?? .null
            jsonDiff(va, vb, "\(path).\(k)", &out, ignore: ignore)
        }
    case (.array(let x), .array(let y)):
        if x.count != y.count { out.append("\(path): length \(x.count) vs \(y.count)"); return }
        for i in x.indices { jsonDiff(x[i], y[i], "\(path)[\(i)]", &out, ignore: ignore) }
    case (.number(let x), .number(let y)):
        if x != y && abs(x - y) > 1e-9 * max(1, abs(x), abs(y)) { out.append("\(path): \(x) vs \(y)") }
    default:
        if a != b { out.append("\(path): \(JSONWriter.stringify(a).prefix(120)) vs \(JSONWriter.stringify(b).prefix(120))") }
    }
}

@Suite struct GoldenJS136Tests {
    @Test func scheduleOfRandomProjectsMatchesTheJavaScriptApp() throws {
        let cases = try loadGolden("js136-schedule.json.z")
        #expect(cases.count == 150)
        var bad = 0
        for c in cases {
            let input = c["input"]!
            var p = try Project.from(json: input)
            let s = scheduleAndApply(&p)
            let got = JSON.object(JSONObject([("project", p.json), ("sched", s.json)]))
            var diff: [String] = []
            jsonDiff(c["expected"]!, got, "", &diff)
            if !diff.isEmpty { bad += 1; Issue.record("\(c["name"]!.string!): \(diff.prefix(5))") }
        }
        #expect(bad == 0)
    }

    @Test func randomEditingScriptsMatchTheJavaScriptApp() throws {
        let cases = try loadGolden("js136-ops.json.z")
        #expect(cases.count == 100)
        var bad = 0, steps = 0
        for c in cases {
            let got = try runOpsScript(c["input"]!)
            steps += got["steps"]!.array!.count
            var diff: [String] = []
            jsonDiff(c["expected"]!, got, "", &diff)
            if !diff.isEmpty { bad += 1; Issue.record("\(c["name"]!.string!): \(diff.prefix(5))") }
        }
        #expect(bad == 0)
        #expect(steps >= 4000)
    }

    @Test func msProjectXMLExportIsByteForByteTheSame() throws {
        let cases = try loadGolden("js136-export-xml.json.z")
        #expect(cases.count == 60)
        // the JavaScript files were written with a fixed clock: 1790000000 s after 1970, local time of the machine that made them (UTC)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for c in cases {
            let p = try Project.from(json: c["input"]!)
            let out = try exportProject("xml", p, now: now)
            var xml = String(decoding: out.data, as: UTF8.self)
            // CurrentDate is the local time of the exporting machine; compare it separately
            let expected = c["expected"]!.string!
            let cd = /<CurrentDate>[^<]*<\/CurrentDate>/
            xml = xml.replacing(cd, with: "<CurrentDate/>")
            let exp = expected.replacing(cd, with: "<CurrentDate/>")
            #expect(xml == exp, "\(c["name"]!.string!)")
            #expect(out.notes == c["notes"]!.array!.map { $0.string! }, "\(c["name"]!.string!) notes")
        }
    }

    @Test func importsOfXMLCSVAndExcelMatchTheJavaScriptApp() throws {
        let cases = try loadGolden("js136-import.json.z")
        #expect(cases.count >= 100)
        let dir = tempDir("gp-golden")
        var bad = 0
        for c in cases {
            let name = c["name"]!.string!
            let path = (dir as NSString).appendingPathComponent(name)
            if let b64 = c["inputBase64"]?.string { FileManager.default.createFile(atPath: path, contents: Data(base64Encoded: b64)) }
            else { FileManager.default.createFile(atPath: path, contents: Data(c["input"]!.string!.utf8)) }
            let got: JSON
            do {
                guard case .imported(let res, let source, let kind) = try importFile(path) else { Issue.record("\(name): not an import"); continue }
                got = .object(JSONObject([("project", res.project.json), ("report", res.report.json), ("source", .string(source)), ("sourceKind", .string(kind))]))
            } catch { got = .object(JSONObject([("error", .string("\(error)"))])) }
            var diff: [String] = []
            jsonDiff(c["expected"]!, got, "", &diff)
            if !diff.isEmpty { bad += 1; Issue.record("\(name): \(diff.prefix(5))") }
        }
        #expect(bad == 0)
    }
}
