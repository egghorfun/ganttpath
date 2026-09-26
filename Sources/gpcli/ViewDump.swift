// `gpcli view-dir`: viewCheckJSON for every project of a folder.

import Foundation
import GanttpathCore

func viewDir(_ inDir: String, _ outDir: String) {
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: inDir))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
    for (k, f) in files.enumerated() {
        let out: JSON
        do { out = viewCheckJSON(try loadProjectJSON(readText(inDir + "/" + f)), k) } catch { out = .object(JSONObject([("error", .string("\(error)"))])) }
        _ = FileManager.default.createFile(atPath: outDir + "/" + f, contents: JSONWriter.stringify(out).data(using: .utf8))
    }
    print("\(files.count) file(s)")
}
