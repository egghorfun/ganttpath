// Opening, saving, autosave, export, version history and templates (app.js "files" part and main.cjs file handlers).
// Every Save writes a new dated file next to the earlier ones; nothing is ever overwritten.

import Foundation
import GanttpathCore

extension DocumentModel {
    /// Replace the open project (new, opened or imported).
    public func load(_ p: Project, dirty: Bool = false, file f: FileState = FileState(), report: (ImportResult, String, String)? = nil) {
        session.load(p, dirty: dirty)
        var fs = f
        fs.lastAutoAt = nil
        fs.autoRevision = session.revision
        file = fs
        selection = []; anchor = nil
        cursorUid = nil; cursorCol = "name"; anchorCol = "name"
        view = ViewState()
        linkSel = nil
        importReport = report
        emit(.scrollToStart)
    }

    /// The folder a project file belongs to: autosaves live in an "Autosaves" folder inside it.
    public static func projectFolder(of file: String) -> String {
        let dir = (file as NSString).deletingLastPathComponent
        return (dir as NSString).lastPathComponent == AUTOSAVE_DIR ? (dir as NSString).deletingLastPathComponent : dir
    }

    /// Open or import a file. Returns true when a project was loaded. Errors are shown as a message.
    @discardableResult
    public func open(path: String, options: TableImportOptions = TableImportOptions(), prefs: PrefsStore? = nil) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { say("The file was not found: \(path)", .error); return false }
        let opened: OpenedFile
        do { opened = try importFile(path, options: options, mpp: env.mpp) } catch { say("Cannot open the file: \(error)", .error); return false }
        prefs?.update { $0.remember(path) }
        switch opened {
        case .gpath(let l):
            var f = FileState()
            f.folder = Self.projectFolder(of: path)
            f.name = familyName(path)
            f.path = path
            load(l.project, dirty: false, file: f)
            say("Opened \((path as NSString).lastPathComponent)", .info, 2.5)
        case .imported(let r, let source, let kind):
            var f = FileState()
            f.name = r.project.name
            load(r.project, dirty: true, file: f, report: (r, source, kind))
        }
        return true
    }

    /// Save a new dated version. kind: manual | auto | final. Returns the file written.
    @discardableResult
    public func save(kind: String = "manual", folder: String? = nil, prefs: PrefsStore) throws -> String {
        let dir = folder ?? file.folder ?? prefs.prefs.folder
        let now = env.now()
        let path = try saveVersion(dir, file.name ?? project.name, project, kind: kind, now: now)
        file.folder = dir
        if kind == "auto" {
            file.lastAutoAt = now
            file.autoRevision = revision
        } else {
            file.path = path
            file.lastSavedAt = now
            file.autoRevision = revision
            session.markSaved()
            prefs.update { p in
                p.remember(path)
                if folder == nil && self.file.folder == nil { p.folder = dir }
            }
        }
        return path
    }

    /// File > Save: a message says where the file went.
    public func saveCommand(folder: String? = nil, prefs: PrefsStore) {
        do {
            let path = try save(kind: "manual", folder: folder, prefs: prefs)
            say("Saved \((path as NSString).lastPathComponent)", .info, 3)
        } catch { say("The project could not be saved: \(error)", .error) }
    }

    /// Called every 5 minutes: saves an autosave copy when something changed since the last one.
    @discardableResult
    public func autosaveTick(prefs: PrefsStore) -> String? {
        if !dirty || revision == file.autoRevision || project.tasks.isEmpty { return nil }
        return try? save(kind: "auto", prefs: prefs)
    }

    /// Before quitting, opening another file or starting a new one: save what changed (only when there is something worth keeping).
    @discardableResult
    public func saveIfDirty(prefs: PrefsStore) -> String? {
        if dirty && (!project.tasks.isEmpty || file.path != nil) { return try? save(kind: "final", prefs: prefs) }
        return nil
    }

    // MARK: export

    /// Data and suggested file name of an export (xml, xlsx, csv).
    public func exportData(_ format: String) throws -> ExportOutput { try exportProject(format, project, now: env.now()) }

    /// Write an export to `url`, with a message listing the export notes.
    public func export(_ format: String, to path: String) {
        do {
            let out = try exportData(format)
            try out.data.write(to: URL(fileURLWithPath: path))
            let notes = out.notes.filter { !$0.isEmpty }
            say("Exported to \((path as NSString).lastPathComponent)\(notes.isEmpty ? "" : ". " + notes[0])", .info, 6)
        } catch { say("Export failed: \(error)", .error) }
    }

    // MARK: versions

    public func versions(prefs: PrefsStore) -> [VersionInfo] {
        listVersions(file.folder ?? prefs.prefs.folder, file.name ?? project.name)
    }

    /// Compare one saved version with the open project, or two saved versions (older first).
    public func compare(_ paths: [String], versions: [VersionInfo]) throws -> (CompareResult, String, String) {
        let items = try paths.map { p in (p, try loadProjectFile(p).project, versions.first { $0.path == p }?.time ?? Date(timeIntervalSince1970: 0)) }
        if items.count == 2 {
            let s = items.sorted { $0.2 < $1.2 }
            return (compareProjects(s[0].1, s[1].1, dateFormat: project.settings.dateFormat), stampText(s[0].2), stampText(s[1].2))
        }
        guard let one = items.first else { throw FileError("Choose a version first") }
        return (compareProjects(one.1, project, dateFormat: project.settings.dateFormat), stampText(one.2), "the open project")
    }

    // MARK: templates

    public func templates() -> [(file: String?, template: ProjectTemplate)] {
        BUILTIN_TEMPLATES.map { (nil, $0) } + listUserTemplates(env.templatesDir).map { (Optional($0.file), $0.template) }
    }

    public func saveAsTemplate(name: String) {
        let n = jsTrim(name)
        if n.isEmpty { return }
        do {
            let t = projectToTemplate(project, n, "Saved from \"\(project.name)\"")
            _ = try saveUserTemplate(env.templatesDir, t)
            say("Template \"\(n)\" saved. It appears in New project and Insert template. Dates, progress and baselines are not kept.", .info, 5)
        } catch { say("\(error)", .error) }
    }

    public func insertTemplate(_ t: ProjectTemplate) {
        let r = run("Insert template") { d, _ in try applyTemplate(&d, t, startDate: d.settings.startDate).count }
        if let n = r.value { say("\(plural(n, "row")) added from \"\(t.name)\".") }
    }
}

// MARK: - new project and holidays

/// What the holiday review offers: downloaded data, the built-in data, and why a download failed.
public struct HolidayProposal: Sendable {
    public var downloaded: HolidaySet?
    public var bundled: HolidaySet
    public var error: String?
}

public func holidayProposal(country: String, years: [Int], download: Bool, http: HTTPGet?) async -> HolidayProposal {
    let bundled = bundledHolidays(country, years)
    var downloaded: HolidaySet? = nil
    var error: String? = nil
    if download, let http = http {
        let r = await fetchHolidays(country, years, get: http)
        if !r.items.isEmpty { downloaded = r }
        if !r.errors.isEmpty && downloaded == nil { error = r.errors[0] }
        else if !r.errors.isEmpty { error = "Some years could not be downloaded: \(r.errors.joined(separator: "; "))" }
    } else if download {
        error = "No network access"
    }
    return HolidayProposal(downloaded: downloaded, bundled: bundled, error: error)
}

/// The next Monday after `today` (the default start of a new project).
public func nextMonday(_ today: Int) -> Int { today + ((8 - dow(today)) % 7 == 0 ? 7 : (8 - dow(today)) % 7) }

/// A new project as the New Project dialog makes it.
public func makeNewProject(name: String, startDn: Int, country: String, dateFormat: String, holidays: HolidaySet?, template: ProjectTemplate?) throws -> Project {
    let nm = jsTrim(name).isEmpty ? "New project" : jsTrim(name)
    var p = newProject(name: nm, startDate: toISO(startDn), country: country)
    p.settings.dateFormat = dateFormat
    if let h = holidays { applyHolidayProposal(&p.calendars[0], h.items, country, h.years) }
    if let t = template, t.id != "blank" { _ = try applyTemplate(&p, t, startDate: toISO(startDn)) }
    return p
}
