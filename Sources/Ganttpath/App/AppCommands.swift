// The menu bar: File, Edit, View, Project and Help, with the JavaScript app's shortcuts (main.cjs buildMenu).

import SwiftUI
import AppKit
import GanttpathCore
import GanttpathModel

struct AppCommands: Commands {
    let state: AppState

    private var m: DocumentModel { state.model }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Ganttpath") { state.sheet = .about }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { state.newProjectCommand() }.keyboardShortcut("n")
            Button("Open…") { state.openCommand() }.keyboardShortcut("o")
            Menu("Open Recent") {
                let recents = Array(state.p.recents.prefix(10))
                if recents.isEmpty { Button("No recent files") {}.disabled(true) }
                ForEach(recents, id: \.self) { f in
                    Button((f as NSString).lastPathComponent) { m.saveIfDirty(prefs: state.prefs); state.open(f) }
                }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { state.saveCommand() }.keyboardShortcut("s")
            Button("Save In Another Folder…") { state.saveInAnotherFolder() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Version History and Compare…") { state.sheet = .versions }
            Divider()
            Menu("Export") {
                switch m.tab {
                case .network, .timeline, .scurve:
                    Button("Image (PNG)…") { state.exportImage(png: true) }
                    Button("Image (SVG)…") { state.exportImage(png: false) }
                    Divider()
                    Button("PDF…") { state.exportPDF() }
                case .cpm:
                    Button("PDF…") { state.exportPDF() }
                case .gantt:
                    Button("MS Project XML…") { state.exportFile("xml") }
                    Button("Excel…") { state.exportFile("xlsx") }
                    Button("CSV…") { state.exportFile("csv") }
                    Button("PDF…") { state.exportPDF() }
                }
            }
            Button("Save Project as Template…") { state.sheet = .saveTemplate }
        }
        CommandGroup(replacing: .undoRedo) {
            Button(m.canUndo && m.undoLabel != nil ? "Undo \(m.undoLabel!)" : "Undo") { state.editUndo() }.keyboardShortcut("z")
            Button(m.canRedo && m.redoLabel != nil ? "Redo \(m.redoLabel!)" : "Redo") { state.editRedo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            // The table has its own clipboard (rows and blocks of cells); a text box being typed in gets the usual action.
            Button("Cut") { state.editCut() }.keyboardShortcut("x")
            Button("Copy") { state.editCopy() }.keyboardShortcut("c")
            Button("Paste") { state.editPaste() }.keyboardShortcut("v")
            Button("Select All") {
                if state.editingText { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                else { _ = m.key(.character("a"), .command) }
            }.keyboardShortcut("a")
            Divider()
            Button("Insert Task") { m.addTask() }.keyboardShortcut("i")
            Button("Insert Summary Task") { m.addTask(summary: true) }
            Button("Delete Task") { m.deleteSelected() }
            Button("Indent") { m.indent() }.keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
            Button("Outdent") { m.outdent() }.keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
            Button("Move Up") { m.moveUp() }.keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            Button("Move Down") { m.moveDown() }.keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            Divider()
            Button("Find…") { NotificationCenter.default.post(name: .focusSearch, object: nil) }.keyboardShortcut("f")
        }
        CommandGroup(after: .toolbar) {
            Button("Gantt Chart") { m.tab = .gantt }.keyboardShortcut("1")
            Button("Network Diagram") { m.tab = .network }.keyboardShortcut("2")
            Button("Timeline Summary") { m.tab = .timeline }.keyboardShortcut("3")
            Button("Critical Path (CPM)") { m.tab = .cpm }.keyboardShortcut("4")
            Button("S-Curve") { m.tab = .scurve }.keyboardShortcut("5")
            Divider()
            Button("Zoom In Timeline") { zoom(1) }.keyboardShortcut("+")
            Button("Zoom Out Timeline") { zoom(-1) }.keyboardShortcut("-")
            Button("Scroll to Today") { state.gantt?.scrollToToday() }.keyboardShortcut("t")
            Button("Fit Project in Window") { state.gantt?.fitProject() }
            Divider()
            Button(m.inspectorOpen ? "Hide Task Panel" : "Show Task Panel") {
                m.inspectorOpen.toggle(); let v = m.inspectorOpen; state.updatePrefs { $0.inspectorOpen = v }
            }.keyboardShortcut("i", modifiers: [.command, .option])
            Button(m.conflictsOpen && m.issuesTab == .conflicts ? "Hide Scheduling Conflicts" : "Show Scheduling Conflicts") {
                if m.conflictsOpen && m.issuesTab == .conflicts { m.conflictsOpen = false } else { m.showIssues(.conflicts) }
            }.keyboardShortcut("c", modifiers: [.command, .option])
            Button(m.conflictsOpen && m.issuesTab == .messages ? "Hide Message Log" : "Show Message Log") {
                if m.conflictsOpen && m.issuesTab == .messages { m.conflictsOpen = false } else { m.showIssues(.messages) }
            }.keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Progress Line", isOn: Binding(get: { m.progressLine }, set: { v in m.progressLine = v; state.updatePrefs { $0.progressLine = v } }))
            Button("Toggle Dark Mode") { state.cycleTheme() }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Menu("Text Size") {
                Button("Increase Text Size") { state.setTextSize(state.p.zoomPercent + 10) }.keyboardShortcut("=", modifiers: [.command, .shift])
                Button("Decrease Text Size") { state.setTextSize(state.p.zoomPercent - 10) }.keyboardShortcut("-", modifiers: [.command, .shift])
                Button("Actual Size (100%)") { state.setTextSize(100) }.keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                ForEach(Prefs.ZOOM_PRESETS, id: \.self) { pct in
                    Toggle("\(Int(pct))%", isOn: Binding(get: { state.p.zoomPercent == pct }, set: { _ in state.setTextSize(pct) }))
                }
            }
            Menu("Font") {
                ForEach(FONTS.indices, id: \.self) { i in
                    let key = FONTS[i].key
                    Toggle(FONTS[i].label, isOn: Binding(get: { state.p.fontFamily == key }, set: { _ in state.updatePrefs { $0.fontFamily = key } }))
                }
            }
        }
        CommandMenu("Project") {
            Button("Project Settings…") { state.sheet = .settings }
            Button("Working Calendars and Holidays…") { state.sheet = .calendars }
            Button("Baselines…") { state.sheet = .baselines }
            Button("Standard Reports…") { state.sheet = .reports }
            Button("Tags and Custom Columns…") { state.sheet = .tagsAndColumns }
            Button("Columns to Show…") { state.sheet = .columnsToShow }
            Button("Colours…") { state.sheet = .colours }
            Button("Page Settings…") { state.sheet = .pageSettings }
            Button("Header and Footer…") { state.sheet = .headerFooter }
            Divider()
            Button("Insert Template…") { state.sheet = .insertTemplate }
            Button("Import Report…") {
                if m.importReport != nil { state.sheet = .importReport } else { m.say("No import in this session.") }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts and Tips") { state.sheet = .help }
            Button("About Ganttpath") { state.sheet = .about }
        }
    }

    private func zoom(_ dir: Int) {
        if m.tab == .gantt { state.gantt?.zoomBy(dir) } else { ViewSettings.shared.zoom(m.tab, dir) }
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("GanttpathFocusSearch")
}
