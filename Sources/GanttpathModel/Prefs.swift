// User preferences (the JavaScript app's preferences.json): kept in a JSON file in the app's support folder.
// Unknown keys are kept, so a newer or older version of the app never loses a setting.

import Foundation
import GanttpathCore

public struct Prefs: Equatable, Sendable {
    public var folder: String
    public var recents: [String] = []
    /// Overall text size of the window, in percent (View > Text Size).
    public var zoomPercent: Double = 100
    public var fontFamily = "system"
    /// auto | light | dark
    public var theme = "auto"
    public var px: Double? = nil
    public var columns: [String]? = nil
    public var colWidths: [String: Double] = [:]
    public var tableWidth: Double? = nil
    public var showBaseline: Int? = nil
    public var inspectorOpen = false
    public var progressLine = false
    public var pageSettings = PageSettings()
    /// User colours: ["light": [key: hex], "dark": [key: hex]].
    public var colors: [String: [String: String]] = [:]
    public var country: String? = nil
    public var downloadHolidays = true
    public var dateFormat: String? = nil
    public var extra = JSONObject()

    public init(folder: String) { self.folder = folder }

    public static let ZOOM_PRESETS: [Double] = [50, 75, 90, 100, 110, 125, 150, 175, 200, 250]
    public static let FONT_KEYS = FONTS.map { $0.key }

    public static func from(json: JSON?, defaultFolder: String) -> Prefs {
        var p = Prefs(folder: defaultFolder)
        guard let o = json?.object else { return p }
        var extra = o
        func take(_ k: String) -> JSON? { let v = o[k]; extra[k] = nil; return v }
        if let s = take("folder")?.string, !s.isEmpty { p.folder = s }
        if let a = take("recents")?.array { p.recents = a.compactMap { $0.string } }
        if let n = take("zoomPercent")?.number, n.isFinite { p.zoomPercent = n }
        if let f = take("fontFamily")?.string, FONT_KEYS.contains(f) { p.fontFamily = f }
        if let t = take("theme")?.string, ["auto", "light", "dark"].contains(t) { p.theme = t }
        if let n = take("px")?.number, n.isFinite, n > 0 { p.px = n }
        if let a = take("columns")?.array { p.columns = a.compactMap { $0.string } }
        if let w = take("colWidths")?.object { for (k, v) in w.pairs { if let n = v.number, n.isFinite { p.colWidths[k] = n } } }
        if let n = take("tableWidth")?.number, n.isFinite { p.tableWidth = n }
        if let n = take("showBaseline")?.number, n.isFinite { p.showBaseline = Int(n) }
        if let b = take("inspectorOpen")?.bool { p.inspectorOpen = b }
        if let b = take("progressLine")?.bool { p.progressLine = b }
        if let ps = take("pageSettings")?.object {
            p.pageSettings = PageSettings(paper: ps["paper"]?.string ?? "A4", marginMM: ps["marginMM"]?.number ?? DEFAULT_MARGIN_MM).normalized
        }
        if let c = take("colors")?.object {
            for (theme, v) in c.pairs { if let m = v.object { var d: [String: String] = [:]; for (k, x) in m.pairs { if let s = x.string { d[k] = s } }; p.colors[theme] = d } }
        }
        if let s = take("country")?.string { p.country = s }
        if let b = take("downloadHolidays")?.bool { p.downloadHolidays = b }
        if let s = take("dateFormat")?.string { p.dateFormat = s }
        p.extra = extra
        return p
    }

    public var json: JSON {
        var o = JSONObject()
        o["folder"] = .string(folder)
        o["recents"] = .array(recents.map { .string($0) })
        o["zoomPercent"] = .number(zoomPercent)
        o["fontFamily"] = .string(fontFamily)
        o["theme"] = .string(theme)
        if let px = px { o["px"] = .number(px) }
        o["columns"] = columns.map { .array($0.map { .string($0) }) } ?? .null
        var w = JSONObject()
        for k in colWidths.keys.sorted() { w[k] = .number(colWidths[k]!) }
        o["colWidths"] = .object(w)
        if let t = tableWidth { o["tableWidth"] = .number(t) }
        if let b = showBaseline { o["showBaseline"] = .number(Double(b)) }
        o["inspectorOpen"] = .bool(inspectorOpen)
        o["progressLine"] = .bool(progressLine)
        o["pageSettings"] = .object(JSONObject([("paper", .string(pageSettings.paper)), ("marginMM", .number(pageSettings.marginMM))]))
        var c = JSONObject()
        for theme in colors.keys.sorted() {
            var m = JSONObject()
            for k in colors[theme]!.keys.sorted() { m[k] = .string(colors[theme]![k]!) }
            c[theme] = .object(m)
        }
        o["colors"] = .object(c)
        if let s = country { o["country"] = .string(s) }
        o["downloadHolidays"] = .bool(downloadHolidays)
        if let s = dateFormat { o["dateFormat"] = .string(s) }
        for (k, v) in extra.pairs where o[k] == nil { o[k] = v }
        return .object(o)
    }

    /// Theme with the user's colours for light or dark mode.
    public func theme(dark: Bool) -> Theme { Theme(dark: dark, overrides: colors[dark ? "dark" : "light"] ?? [:]) }

    /// Remember a file at the top of Open Recent (at most 10).
    public mutating func remember(_ file: String) {
        recents = [file] + recents.filter { $0 != file }
        if recents.count > 10 { recents.removeLast(recents.count - 10) }
    }
}

/// Reads and writes the preferences file.
public final class PrefsStore: @unchecked Sendable {
    public let file: String
    public private(set) var prefs: Prefs
    public init(file: String, defaultFolder: String) {
        self.file = file
        var json: JSON? = nil
        if let d = FileManager.default.contents(atPath: file) { json = try? JSONParser.parse(String(decoding: d, as: UTF8.self)) }
        prefs = Prefs.from(json: json, defaultFolder: defaultFolder)
    }
    public func update(_ fn: (inout Prefs) -> Void) {
        fn(&prefs)
        save()
    }
    public func save() {
        let dir = (file as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let text = JSONWriter.stringify(prefs.json, indent: 2)
        // write to a temporary file first so a crash never leaves half a preferences file
        let tmp = file + ".tmp"
        if FileManager.default.createFile(atPath: tmp, contents: text.data(using: .utf8)) {
            _ = try? FileManager.default.removeItem(atPath: file)
            try? FileManager.default.moveItem(atPath: tmp, toPath: file)
        }
    }
}
