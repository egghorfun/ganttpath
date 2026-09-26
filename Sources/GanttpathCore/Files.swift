// Saving, versions and autosaves on disk; opening and exporting every supported file type; user templates.
//
// Rules (agreed with the user):
//  * Every manual Save writes a NEW file  <Name>_<YYYY-MM-DD_HHmm>.gpath  - existing files are never overwritten.
//  * On exit, if there are unsaved changes, a final version is saved the same way (no question asked).
//  * Autosaves go to an "Autosaves" folder beside the project, only when something changed, and only the newest 20 are kept.
//    Manual and final saves are never deleted.

import Foundation

public let EXT = ".gpath"
public let AUTOSAVE_DIR = "Autosaves"
public let AUTOSAVE_KEEP = 20
public let AUTOSAVE_INTERVAL: TimeInterval = 5 * 60
public let FORMAT = "ganttpath"
public let APP_VERSION = "1.3.6"

public struct FileError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ d: String) { description = d }
}

private func basename(_ p: String) -> String { (p as NSString).lastPathComponent }
private func dirname(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
private func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }

/// "_2026-09-20_1405", "_2026-09-20_140502", "-2", "_auto" at the end of a file name.
func stripStamp(_ n: String) -> String {
    // /_(\d{4}-\d{2}-\d{2})_(\d{4})(\d{2})?(?:-(\d+))?(_auto)?$/
    guard let m = n.firstMatch(of: /_(\d{4}-\d{2}-\d{2})_(\d{4})(\d{2})?(?:-(\d+))?(_auto)?$/.asciiOnlyDigits()) else { return n }
    return String(n[..<m.range.lowerBound])
}

/// Project family name without any trailing timestamp: "Plant_2026-09-20_1405" -> "Plant".
public func familyName(_ fileOrName: String?) -> String {
    let raw = fileOrName ?? ""
    var n = raw.hasSuffix(EXT) ? String(basename(raw).dropLast(EXT.count)) : raw // only strip a folder when it is really a file path
    n = stripStamp(n)
    let s = sanitizeName(n)
    return s.isEmpty ? "Project" : s
}

public func sanitizeName(_ name: String?) -> String {
    var s = String((name ?? "").unicodeScalars.map { u -> Character in
        ("\\/:*?\"<>|".unicodeScalars.contains(u) || u.value < 0x20) ? "_" : Character(u)
    })
    // collapse white space
    var out = ""
    var ws = false
    for u in s.unicodeScalars {
        if jsWhitespace.contains(u) { if !ws { out += " " }; ws = true } else { out.unicodeScalars.append(u); ws = false }
    }
    s = jsTrim(out)
    while s.hasPrefix(".") { s.removeFirst() }
    return String(String(s.utf16.prefix(80)) ?? s)
}

public func envelope(_ project: Project, kind: String = "manual", app: String = "Ganttpath", version: String = APP_VERSION, now: Date = Date()) -> JSON {
    .object(JSONObject([("format", .string(FORMAT)), ("schema", JSON(SCHEMA)), ("app", .string(app)), ("version", .string(version)),
                        ("savedAt", .string(ISO8601DateFormatter.jsString(now))), ("kind", .string(kind)), ("project", project.json)]))
}

func atomicWrite(_ file: String, _ data: Data) throws {
    let tmp = "\(file).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000))"
    guard FileManager.default.createFile(atPath: tmp, contents: data) else { throw FileError("Could not write \(file)") }
    // rename is atomic on the same volume: a crash never leaves a half-written project
    if rename(tmp, file) != 0 { try? FileManager.default.removeItem(atPath: tmp); throw FileError("Could not write \(file)") }
}

func uniquePath(_ dir: String, _ base: String, _ suffix: String = "") throws -> String {
    var file = join(dir, "\(base)\(suffix)\(EXT)")
    if !FileManager.default.fileExists(atPath: file) { return file }
    for n in 2..<1000 {
        file = join(dir, "\(base)-\(n)\(suffix)\(EXT)")
        if !FileManager.default.fileExists(atPath: file) { return file }
    }
    throw FileError("Could not find a free file name")
}

/// Save a new timestamped version. kind: 'manual' | 'final' | 'auto'. Returns the full path written.
@discardableResult
public func saveVersion(_ dir: String, _ projectName: String?, _ project: Project, kind: String = "manual", now: Date = Date(), version: String = APP_VERSION) throws -> String {
    let fam = familyName(nonEmpty(projectName) ?? project.name)
    let target = kind == "auto" ? join(dir, AUTOSAVE_DIR) : dir
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
    var stamp = stampFromDate(now)
    var base = "\(fam)_\(stamp)"
    let suffix = kind == "auto" ? "_auto" : ""
    // two saves inside the same minute: use seconds in the name, then a counter
    if FileManager.default.fileExists(atPath: join(target, "\(base)\(suffix)\(EXT)")) { stamp = stampFromDate(now, withSeconds: true); base = "\(fam)_\(stamp)" }
    let file = try uniquePath(target, base, suffix)
    try atomicWrite(file, Data((JSONWriter.stringify(envelope(project, kind: kind, version: version, now: now)) + "\n").utf8))
    if kind == "auto" { pruneAutosaves(dir, fam) }
    return file
}

func stampToTime(_ name: String) -> Date? {
    let n = name.hasSuffix(EXT) ? String(name.dropLast(EXT.count)) : name
    guard let m = n.firstMatch(of: /_(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})(\d{2})?(?:-(\d+))?(_auto)?$/.asciiOnlyDigits()) else { return nil }
    var c = DateComponents()
    c.year = Int(m.1); c.month = Int(m.2); c.day = Int(m.3); c.hour = Int(m.4); c.minute = Int(m.5); c.second = m.6.flatMap { Int($0) } ?? 0
    return Calendar.current.date(from: c)
}

public struct VersionInfo: Equatable, Sendable {
    public var path: String, file: String, kind: String
    public var time: Date
    public var size: Int
}

/// All saved versions of a project family (manual, final, autosaves), newest first.
public func listVersions(_ dir: String, _ projectName: String?) -> [VersionInfo] {
    let fam = familyName(projectName)
    var out: [VersionInfo] = []
    func scan(_ folder: String, _ isAuto: Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for n in names {
            if !n.hasSuffix(EXT) || n.contains(".tmp-") { continue }
            if familyName(n) != fam { continue }
            let full = join(folder, n)
            guard let attr = try? FileManager.default.attributesOfItem(atPath: full) else { continue }
            let t = stampToTime(n) ?? (attr[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            out.append(VersionInfo(path: full, file: n, kind: isAuto || n.contains("_auto") ? "auto" : "manual", time: t, size: (attr[.size] as? Int) ?? 0))
        }
    }
    scan(dir, false)
    scan(join(dir, AUTOSAVE_DIR), true)
    return out.sorted { $0.time != $1.time ? $0.time > $1.time : $0.path > $1.path }
}

/// Delete autosaves beyond the newest AUTOSAVE_KEEP. Manual and final saves are never touched.
@discardableResult
public func pruneAutosaves(_ dir: String, _ projectName: String?, keep: Int = AUTOSAVE_KEEP) -> [String] {
    let autos = listVersions(dir, projectName).filter { $0.kind == "auto" && basename(dirname($0.path)) == AUTOSAVE_DIR }
    var removed: [String] = []
    for v in autos.dropFirst(keep) { if (try? FileManager.default.removeItem(atPath: v.path)) != nil { removed.append(v.path) } }
    return removed
}

public struct LoadedProject: Sendable {
    public var project: Project
    public var savedAt: String?, kind: String?, version: String?, schema: Int?
}

/// Read and validate a project file. Throws FileError with a plain-language message.
public func loadProjectFile(_ file: String) throws -> LoadedProject {
    guard let d = FileManager.default.contents(atPath: file) else { throw FileError("Cannot read the file: \(file)") }
    return try parseProjectText(String(decoding: d, as: UTF8.self))
}

public func parseProjectText(_ text: String) throws -> LoadedProject {
    let obj: JSON
    do { obj = try JSONParser.parse(text) } catch { throw FileError("This file is damaged or is not a Ganttpath project (it cannot be read as JSON).") }
    guard let o = obj.object, o["format"]?.string == FORMAT, let pj = o["project"], pj.truthy else { throw FileError("This is not a Ganttpath project file.") }
    if let sch = o["schema"]?.number, sch > Double(SCHEMA) {
        throw FileError("This file was saved by a newer version of Ganttpath (file format \(jsNumberString(sch))). Please update the app.")
    }
    do {
        let p = try Project.from(json: pj)
        return LoadedProject(project: p, savedAt: o["savedAt"]?.string, kind: o["kind"]?.string, version: o["version"]?.string, schema: o["schema"]?.number.map { Int($0) })
    } catch let e as ModelError { throw FileError(e.message) }
}

// MARK: - import / export of every supported file type

public let IMPORT_EXTS = [".gpath", ".mpp", ".xml", ".xlsx", ".csv", ".txt"]

public enum OpenedFile {
    case gpath(LoadedProject)
    case imported(ImportResult, source: String, sourceKind: String)
    public var project: Project {
        switch self { case .gpath(let l): return l.project; case .imported(let r, _, _): return r.project }
    }
}

/// Runs the MPXJ converter (mpxj-convert <in> <out.xml>) and returns the XML text. Supplied by the app (a Process on macOS).
public typealias MppConverter = (String) throws -> String

func baseName(_ file: String) -> String {
    let b = basename(file)
    if let dot = b.lastIndex(of: "."), dot != b.startIndex { return String(b[..<dot]) }
    return b
}

/// Open any supported file.
public func importFile(_ file: String, options: TableImportOptions = TableImportOptions(), mpp: MppConverter? = nil) throws -> OpenedFile {
    let ext = "." + (file as NSString).pathExtension.lowercased()
    if ext == ".gpath" { return .gpath(try loadProjectFile(file)) }
    let name = baseName(file)
    guard let data = FileManager.default.contents(atPath: file) else { throw FileError("Cannot read the file: \(file)") }
    switch ext {
    case ".xml":
        let r = try importMSPDI(String(decoding: data, as: UTF8.self), fileName: basename(file))
        return .imported(r, source: basename(file), sourceKind: "MS Project XML")
    case ".mpp":
        guard let conv = mpp else {
            throw FileError("The built-in .mpp reader was not found. In MS Project use File > Save As > \"XML Format (*.xml)\" and open that XML file instead.")
        }
        var r = try importMSPDI(try conv(file), fileName: basename(file))
        r.report.notes.insert(ImportNote(level: "info", text: "The .mpp file was read with the built-in MPXJ reader and then scheduled by Ganttpath."), at: 0)
        return .imported(r, source: basename(file), sourceKind: "MS Project .mpp")
    case ".xlsx":
        let sheets = try readXlsx(Array(data))
        func find(_ n: String) -> ReadSheet? { sheets.first { $0.name.lowercased() == n } }
        guard let tasks = find("tasks") ?? sheets.first else { throw FileError("The workbook has no sheets") }
        var o = options
        o.name = name
        o.projectSheet = find("project")?.rows
        o.calendarSheet = find("calendars")?.rows
        var r = try tableToProject(tasks.rows, o)
        if r.project.name.isEmpty || r.project.name == "Untitled project" { r.project.name = name }
        return .imported(r, source: basename(file), sourceKind: "Excel workbook")
    case ".csv", ".txt":
        let rows = parseCsv(String(decoding: data, as: UTF8.self)).rows.map { $0.map { Optional(SheetValue.text($0)) } }
        var o = options
        o.name = name
        var r = try tableToProject(rows, o)
        if r.project.name.isEmpty || r.project.name == "Untitled project" { r.project.name = name }
        return .imported(r, source: basename(file), sourceKind: "CSV file")
    default:
        throw FileError("Ganttpath cannot open \"\(ext == "." ? "this" : ext)\" files. Supported: \(IMPORT_EXTS.joined(separator: ", "))")
    }
}

/// Sheet with column widths that fit the content (so dates never show as ###) and a bold header row.
func niceSheet(_ name: String, _ rows: [[Cell]], _ headerRow: Bool) -> Sheet {
    func len(_ c: Cell) -> Int {
        switch c {
        case .empty: return 0
        case .date: return 12
        case .text(let s), .styled(let s, _): return s.utf16.count
        case .number(let n), .styledNumber(let n, _): return jsNumberString(n).count
        case .bool(let b): return b ? 4 : 5
        }
    }
    let ncol = max(1, rows.map { $0.count }.max() ?? 1)
    var widths: [Double] = []
    for c in 0..<ncol {
        var w = 0
        for (i, r) in rows.enumerated() { w = max(w, (c < r.count ? len(r[c]) : 0) + (headerRow && i == 0 ? 3 : 0)) }
        widths.append(Double(min(60, max(8, w + 2))))
    }
    let out = headerRow ? rows.enumerated().map { (i, r) in i == 0 ? r.map { cell -> Cell in
        switch cell { case .text(let s): return .styled(s, style: "header"); case .number(let n): return .styledNumber(n, style: "header"); default: return .styled(cell.csvText, style: "header") }
    } : r } : rows
    return Sheet(name: name, rows: out, widths: widths)
}

public struct ExportOutput { public var data: Data; public var ext: String; public var notes: [String] }

/// Export the project. format: 'xml' | 'xlsx' | 'csv'. The schedule is recomputed here so exports never depend on what the window last drew.
public func exportProject(_ format: String, _ projectIn: Project, now: Date = Date()) throws -> ExportOutput {
    var project = projectIn
    normalizeProject(&project)
    let sched = scheduleAndApply(&project)
    if format == "xml" {
        let r = exportMSPDI(project, sched, now: now)
        return ExportOutput(data: Data(r.xml.utf8), ext: ".xml", notes: r.notes)
    }
    let table = projectToTable(project, sched)
    if format == "csv" {
        let info = projectInfoSheets(project)
        let rows = tableToCsvRows(table) + [[], ["# Project Settings"]] + info.projectRows.map { $0.map { $0.csvText } }
        return ExportOutput(data: Data(writeCsv(rows).utf8), ext: ".csv",
                            notes: ["Project settings (hours/day, hours/week, days/month, etc.) are included after the tasks, read back in on import. CSV still cannot carry calendars, holidays or baselines - use Excel or MS Project XML for those."])
    }
    if format == "xlsx" {
        let info = projectInfoSheets(project)
        let bytes = writeXlsx([
            niceSheet("Tasks", [table.headers.map { Cell.text($0) }] + table.rows, true),
            niceSheet("Project", info.projectRows, false),
            niceSheet("Calendars", info.calRows, false),
        ], title: project.name, now: now)
        return ExportOutput(data: Data(bytes), ext: ".xlsx", notes: [])
    }
    throw FileError("Unknown export format: \(format)")
}

// MARK: - user templates

let TEMPLATE_EXT = ".gptemplate"

public func listUserTemplates(_ dir: String) -> [(file: String, template: ProjectTemplate)] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    var out: [(file: String, template: ProjectTemplate)] = []
    for n in names where n.hasSuffix(TEMPLATE_EXT) {
        guard let d = FileManager.default.contents(atPath: join(dir, n)), let j = try? JSONParser.parse(data: d), let t = try? ProjectTemplate.from(json: j) else { continue }
        out.append((n, t))
    }
    return out.sorted { $0.template.name.localizedCompare($1.template.name) == .orderedAscending }
}

@discardableResult
public func saveUserTemplate(_ dir: String, _ template: ProjectTemplate) throws -> String {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var safe = String(template.name.unicodeScalars.map { u -> Character in ("\\/:*?\"<>|".unicodeScalars.contains(u) || u.value < 0x20) ? "_" : Character(u) })
    safe = String(jsTrim(safe).prefix(60))
    let file = join(dir, (safe.isEmpty ? "Template" : safe) + TEMPLATE_EXT)
    guard FileManager.default.createFile(atPath: file, contents: Data((JSONWriter.stringify(template.json) + "\n").utf8)) else { throw FileError("Could not save the template") }
    return file
}

public func deleteUserTemplate(_ dir: String, _ fileName: String) throws {
    let base = basename(fileName)
    if !base.hasSuffix(TEMPLATE_EXT) { throw FileError("Not a template file") }
    try FileManager.default.removeItem(atPath: join(dir, base))
}
