// Ganttpath for macOS: the app, its single window, the menu bar, autosave and quitting (main.cjs and app.js of the
// JavaScript app). The window's content is ContentView; all editing goes through GanttpathModel.DocumentModel.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GanttpathCore
import GanttpathModel

/// Dialogs shown as sheets over the window.
enum Sheet: Identifiable, Equatable {
    case start, newProject, settings, calendars, baselines, reports, tagsAndColumns, columnsToShow, colours
    case pageSettings, headerFooter, insertTemplate, saveTemplate, importReport, versions, help, about
    case insertSeveral, slackFilter(atMost: Bool)
    var id: String {
        switch self {
        case .slackFilter(let m): return "slack\(m)"
        default: return String(describing: self)
        }
    }
}

@MainActor
@Observable
final class AppState {
    let prefs: PrefsStore
    let model: DocumentModel
    var prefsVersion = 0            // bumped when preferences change, so views reading them update
    var sheet: Sheet? = nil
    var alert: (title: String, message: String)? = nil
    var systemDark = false
    @ObservationIgnored var autosaveTimer: Timer? = nil
    @ObservationIgnored var gantt: GanttPaneController? = nil

    static let supportDir: String = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return base + "/Ganttpath"
    }()
    static let documentsFolder: String = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path + "/Ganttpath"
    }()

    init() {
        prefs = PrefsStore(file: Self.supportDir + "/preferences.json", defaultFolder: Self.documentsFolder)
        let env = AppEnvironment(templatesDir: Self.supportDir + "/templates", mpp: AppState.mppConverter(), http: AppState.httpGet)
        model = DocumentModel(env: env)
        CoreWidth.measurer = CoreTextMeasurer.shared
        model.apply(prefs: prefs.prefs)
        let store = prefs
        model.onPrefsChange = { [weak self] fn in
            store.update(fn)
            self?.prefsVersion += 1
        }
        applyAppearance()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: AUTOSAVE_INTERVAL, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.model.autosaveTick(prefs: store) }
        }
    }

    func updatePrefs(_ fn: (inout Prefs) -> Void) {
        prefs.update(fn)
        prefsVersion += 1
    }

    var p: Prefs { _ = prefsVersion; return prefs.prefs }
    var uiScale: Double { max(0.5, min(2.5, p.zoomPercent / 100)) }
    var font: String { p.fontFamily }
    var isDark: Bool { p.theme == "dark" || (p.theme == "auto" && systemDark) }
    var theme: Theme { p.theme(dark: isDark) }

    func applyAppearance() {
        switch prefs.prefs.theme {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp?.appearance = NSAppearance(named: .darkAqua)
        default: NSApp?.appearance = nil
        }
    }

    /// View > Toggle Dark Mode: auto -> the opposite of what is showing -> auto.
    func cycleTheme() {
        let next: String
        switch p.theme {
        case "auto": next = systemDark ? "light" : "dark"
        default: next = "auto"
        }
        updatePrefs { $0.theme = next }
        applyAppearance()
    }

    func setTextSize(_ pct: Double) { updatePrefs { $0.zoomPercent = max(50, min(250, pct.rounded())) } }

    // MARK: outside world

    /// The bundled MPXJ reader (Contents/Resources/bin/mpxj-convert), or the one named by MPPJS_BINARY.
    static func mppBinary() -> String? {
        if let e = ProcessInfo.processInfo.environment["MPPJS_BINARY"], FileManager.default.isExecutableFile(atPath: e) { return e }
        if let r = Bundle.main.resourcePath, FileManager.default.isExecutableFile(atPath: r + "/bin/mpxj-convert") { return r + "/bin/mpxj-convert" }
        return nil
    }

    static func mppConverter() -> (@Sendable (String) throws -> String)? {
        guard let bin = mppBinary() else { return nil }
        return { mppPath in
            let out = NSTemporaryDirectory() + "ganttpath-mpp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).xml"
            defer { try? FileManager.default.removeItem(atPath: out) }
            // downloaded apps carry a quarantine flag that can stop a helper program from starting
            let x = Process()
            x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            x.arguments = ["-d", "com.apple.quarantine", bin]
            try? x.run(); x.waitUntilExit()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = [mppPath, out]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch {
                throw FileError("The built-in .mpp reader could not start (\(error.localizedDescription)). In MS Project use File > Save As > \"XML Format (*.xml)\" and open that XML file instead.")
            }
            let deadline = Date().addingTimeInterval(90)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { p.terminate(); throw FileError("Reading the .mpp file took too long and was stopped.") }
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationStatus != 0 {
                let last = msg.split(separator: "\n").last.map(String.init) ?? ""
                throw FileError("The .mpp file could not be read\(last.isEmpty ? "" : ": \(last)"). In MS Project use File > Save As > \"XML Format (*.xml)\" and open that XML file instead.")
            }
            guard let d = FileManager.default.contents(atPath: out) else { throw FileError("The .mpp reader wrote no file.") }
            return String(decoding: d, as: UTF8.self)
        }
    }

    static let httpGet: HTTPGet = { url in
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    // MARK: files

    func newProjectCommand() {
        model.saveIfDirty(prefs: prefs)
        sheet = .newProject
    }

    func openCommand() {
        model.saveIfDirty(prefs: prefs)
        let panel = NSOpenPanel()
        panel.title = "Open or import a project"
        panel.directoryURL = URL(fileURLWithPath: p.folder)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["gpath", "mpp", "xml", "xlsx", "csv"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { open(url.path) }
    }

    @discardableResult
    func open(_ path: String) -> Bool {
        let ok = model.open(path: path, prefs: prefs)
        prefsVersion += 1
        if ok && model.importReport != nil { sheet = .importReport }
        return ok
    }

    func saveCommand() { model.saveCommand(prefs: prefs); prefsVersion += 1 }

    func saveInAnotherFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder for this project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: p.folder)
        if panel.runModal() == .OK, let url = panel.url { model.saveCommand(folder: url.path, prefs: prefs); prefsVersion += 1 }
    }

    /// A Save panel; returns the chosen path.
    func askSavePath(_ name: String, _ ext: String, title: String = "Export") -> String? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = sanitizeName(name) + ext
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let t = UTType(filenameExtension: String(ext.dropFirst())) { panel.allowedContentTypes = [t] }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func exportFile(_ format: String) {
        let ext = format == "xml" ? ".xml" : format == "xlsx" ? ".xlsx" : ".csv"
        guard let path = askSavePath(model.project.name, ext) else { return }
        model.export(format, to: path)
        if format == "xml", let out = try? model.exportData("xml"), !out.notes.isEmpty {
            alert = ("Export finished", "Saved \(path)\n\n" + out.notes.map { "• \($0)" }.joined(separator: "\n"))
        }
    }

    // MARK: PDF and pictures

    var printContext: PrintContext {
        var c = PrintContext()
        c.page = p.pageSettings
        c.view = model.view
        c.columnIds = model.columnIds
        c.gantt = model.ganttOptions
        c.gantt.selected = []
        c.gantt.linkSel = nil
        c.measurer = CoreTextMeasurer.shared
        return c
    }

    /// The picture of the Network, Timeline or S-curve view as shown (light colours, like the PDF).
    var diagramForExport: Drawing? {
        let m = model
        let theme = p.theme(dark: false)
        switch m.tab {
        case .network: return ViewSettings.shared.networkDrawing(m, theme: theme)?.drawing
        case .timeline: return ViewSettings.shared.timelineDrawing(m, theme: theme, width: 1200)?.drawing
        case .scurve: return ViewSettings.shared.scurveDrawing(m, theme: theme)?.0.drawing
        default: return nil
        }
    }

    func exportPDF() {
        let m = model
        let pages: [PrintedPage]
        let names: [ViewTab: String] = [.network: "NetworkDiagram", .timeline: "TimelineSummary", .scurve: "SCurve", .cpm: "CriticalPath"]
        switch m.tab {
        case .gantt: pages = ganttPrintPages(m.project, m.sched, printContext)
        case .cpm: pages = cpmPrintPages(m.project, m.sched, ViewSettings.shared.cpm, printContext)
        default: pages = diagramForExport.map { [diagramPrintPage(m.project, m.sched, $0, printContext)] } ?? []
        }
        if pages.isEmpty { m.say(m.tab == .gantt ? "There are no tasks to print." : "There is nothing to print."); return }
        let paper = p.pageSettings.normalized.paper
        let base = m.tab == .gantt ? "\(m.project.name)_\(paper)" : "\(m.project.name)_\(names[m.tab]!)_\(paper)"
        guard let path = askSavePath(base, ".pdf", title: "Export PDF") else { return }
        writePDF(pages, to: path)
    }

    func exportReportPDF(_ key: String) {
        let pages = reportPrintPages(key, model.project, model.sched, printContext)
        if pages.isEmpty { model.say("There is nothing to print for this report."); return }
        let def = REPORT_DEFS.first { $0.key == key }
        let name = "\(model.project.name)_\((def?.name ?? key).replacingOccurrences(of: " ", with: ""))_\(p.pageSettings.normalized.paper)"
        guard let path = askSavePath(name, ".pdf", title: "Export PDF") else { return }
        writePDF(pages, to: path)
    }

    func writePDF(_ pages: [PrintedPage], to path: String) {
        guard let data = ImageExport.pdf(pages.map { $0.drawing }, title: model.project.name) else { alert = ("The PDF could not be built", ""); return }
        do { try data.write(to: URL(fileURLWithPath: path)); model.say("PDF saved to \((path as NSString).lastPathComponent)", .info, 5) }
        catch { alert = ("The PDF could not be saved", error.localizedDescription) }
    }

    func exportImage(png: Bool) {
        guard let d = diagramForExport else {
            model.say("Image export is only available for the Network Diagram, Timeline Summary and S-Curve views.")
            return
        }
        let names: [ViewTab: String] = [.network: "NetworkDiagram", .timeline: "TimelineSummary", .scurve: "SCurve"]
        guard let path = askSavePath("\(model.project.name)_\(names[model.tab] ?? "View")", png ? ".png" : ".svg", title: "Export Image") else { return }
        let data: Data? = png ? ImageExport.png(d, scale: 2) : SVGWriter.svg(d, measurer: CoreTextMeasurer.shared).data(using: .utf8)
        guard let out = data else { alert = ("The image could not be saved", ""); return }
        do { try out.write(to: URL(fileURLWithPath: path)); model.say("\(png ? "PNG" : "SVG") saved to \((path as NSString).lastPathComponent)", .info, 5) }
        catch { alert = ("The image could not be saved", error.localizedDescription) }
    }

    // MARK: edit menu

    /// True when a text field of the window is being typed in: the Edit menu then works on that text.
    var editingText: Bool {
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        return r is NSText || r is NSTextView
    }

    func editCut() { if editingText || model.tab != .gantt { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) } else { tableCopy(cut: true) } }
    func editCopy() { if editingText || model.tab != .gantt { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { tableCopy(cut: false) } }
    func editPaste() { if editingText || model.tab != .gantt { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } else { tablePaste() } }
    func editUndo() { if editingText { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undo() } }
    func editRedo() { if editingText { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { model.redo() } }

    func tableCopy(cut: Bool) {
        guard let text = model.copy(cut: cut) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(text.prefix(5_000_000)), forType: .string)
    }
    func tablePaste() {
        let text = NSPasteboard.general.string(forType: .string) ?? model.clip?.text ?? ""
        if !model.paste(text) { model.say("There is nothing to paste.", .info, 2) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState?
    var pendingOpen: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            guard let s = state else { pendingOpen += urls.map { $0.path }; return }
            for u in urls {
                s.model.saveIfDirty(prefs: s.prefs)
                s.open(u.path)
                if s.sheet == .start { s.sheet = nil }
            }
        }
    }

    /// Quitting saves a final version of a changed project first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if let s = state { s.model.saveIfDirty(prefs: s.prefs) }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GanttpathApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var state = AppState()

    var body: some Scene {
        Window("Ganttpath", id: "main") {
            ContentView()
                .environment(state)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    delegate.state = state
                    let pending = delegate.pendingOpen
                    delegate.pendingOpen = []
                    if SmokeTest.dir != nil { SmokeTest.run(state) }
                    else if let f = pending.first { state.open(f) } else { state.sheet = .start }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(state: state) }
    }
}
