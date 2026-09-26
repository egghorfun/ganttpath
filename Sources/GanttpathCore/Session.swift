// A Session owns the open project: the data, the computed schedule, undo/redo and the "unsaved changes" flag.
// The UI never edits the project directly; it calls session.run(label) { draft, sched in ... } which applies one or more
// model commands to a copy. The change is kept only if the closure succeeds; otherwise the project is left exactly as it was.
//
// Undo / redo keep whole-project snapshots (value copies of the project), like the JavaScript app's JSON snapshots.
// The history lives only in memory for the current session (it is not saved with the file).

import Foundation

public let UNDO_LIMIT = 50

public struct History: Sendable {
    public var limit: Int
    public var undoStack: [(label: String, project: Project)] = []
    public var redoStack: [(label: String, project: Project)] = []

    public init(limit: Int = UNDO_LIMIT) { self.limit = limit }

    /// Record the state before a change. Clears the redo branch.
    public mutating func record(_ label: String, _ before: Project) {
        undoStack.append((label, before))
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }
    /// Returns the project to restore, given the current one.
    public mutating func undo(_ current: Project) -> Project? {
        guard let e = undoStack.popLast() else { return nil }
        redoStack.append((e.label, current))
        return e.project
    }
    public mutating func redo(_ current: Project) -> Project? {
        guard let e = redoStack.popLast() else { return nil }
        undoStack.append((e.label, current))
        return e.project
    }
    public mutating func clear() { undoStack.removeAll(); redoStack.removeAll() }
}

public enum RunResult<T> {
    case ok(T, unchanged: Bool)
    case failed(String)

    public var ok: Bool { if case .ok = self { return true }; return false }
    public var error: String? { if case .failed(let e) = self { return e }; return nil }
    public var value: T? { if case .ok(let v, _) = self { return v }; return nil }
    public var unchanged: Bool { if case .ok(_, let u) = self { return u }; return false }
}

public final class Session {
    public private(set) var project: Project
    public private(set) var sched: ScheduleResult
    public var history = History()
    public private(set) var dirty = false
    public private(set) var revision = 0
    private var listeners: [UUID: (String, String?) -> Void] = [:]

    public init(_ project: Project) {
        var p = project
        normalizeProject(&p)
        self.sched = schedule(p)
        applySchedule(&p, sched)
        self.project = p
        revision = 1
    }

    /// Replace the open project (new file / open file). Clears undo history and the dirty flag.
    public func load(_ project: Project, dirty: Bool = false) {
        var p = project
        normalizeProject(&p)
        sched = schedule(p)
        applySchedule(&p, sched)
        self.project = p
        history.clear()
        self.dirty = dirty
        revision += 1
        emit("load")
    }

    @discardableResult
    public func on(_ fn: @escaping (String, String?) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = fn
        return id
    }
    public func off(_ id: UUID) { listeners[id] = nil }
    func emit(_ kind: String, _ info: String? = nil) { for fn in listeners.values { fn(kind, info) } }

    public func json() -> String { project.jsonString() }

    /// Apply an edit. `fn(&draft, sched)` mutates the draft using model commands and may return a value.
    @discardableResult
    public func run<T>(_ label: String, _ fn: (inout Project, ScheduleResult) throws -> T) -> RunResult<T> {
        let before = project
        var draft = project
        let result: T
        do {
            result = try fn(&draft, sched)
            normalizeProject(&draft)
        } catch let e as ModelError {
            return .failed(e.message)
        } catch {
            return .failed("\(error)")
        }
        if draft == before { return .ok(result, unchanged: true) }
        let s = schedule(draft)
        applySchedule(&draft, s)
        history.record(label, before)
        project = draft
        sched = s
        dirty = true
        revision += 1
        emit("change", label)
        return .ok(result, unchanged: false)
    }

    /// Several edits as ONE undo step: every run() made inside `fn` is merged into a single undo step (each run still sees the
    /// schedule the earlier ones produced). If nothing changed no step is recorded.
    public func runGroup<T>(_ label: String, _ fn: () throws -> T) rethrows -> T {
        let first = project
        let limit = history.limit
        history.limit = Int.max
        let startLen = history.undoStack.count
        defer {
            history.limit = limit
            if history.undoStack.count > startLen { history.undoStack.removeLast(history.undoStack.count - startLen) }
            if project != first {
                history.undoStack.append((label, first))
                while history.undoStack.count > limit { history.undoStack.removeFirst() }
                history.redoStack.removeAll()
            }
        }
        return try fn()
    }

    @discardableResult public func undo() -> Bool { restore(history.undo(project), "undo") }
    @discardableResult public func redo() -> Bool { restore(history.redo(project), "redo") }

    private func restore(_ p: Project?, _ kind: String) -> Bool {
        guard var restored = p else { return false }
        // Expanded/collapsed is a view setting, not an edit: undo/redo must not re-open or re-close rows the user has since changed.
        var shown: [Int: Bool] = [:]
        for t in project.tasks { shown[t.uid] = t.collapsed }
        for i in restored.tasks.indices { if let c = shown[restored.tasks[i].uid] { restored.tasks[i].collapsed = c } }
        sched = schedule(restored)
        applySchedule(&restored, sched)
        project = restored
        dirty = true
        revision += 1
        emit(kind)
        return true
    }

    public func markSaved() { dirty = false; emit("saved") }

    /// Expand or collapse a summary. This is a view setting, not an edit: it is saved with the file but is not an undo step
    /// (the JavaScript app's window changes the field directly).
    public func setCollapsed(_ uid: Int, _ collapsed: Bool) {
        guard let i = project.tasks.firstIndex(where: { $0.uid == uid }), project.tasks[i].collapsed != collapsed else { return }
        project.tasks[i].collapsed = collapsed
        revision += 1
        emit("view")
    }
}
