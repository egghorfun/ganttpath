// A small vector drawing model shared by the screen, PDF and image exports.
//
// Every chart (Gantt chart, time scale, network diagram, timeline summary, S-curve) and every printed page is built by pure
// functions in GanttpathCore as a list of DrawItems in a y-down coordinate system (like SVG and the screen). The Mac app paints
// the list with CoreGraphics (screen, PDF, PNG); the same list turns into an SVG file here. Because the building is plain Swift,
// the content of every chart and page is tested on any platform.

import Foundation

// MARK: - Colours

public struct RGBA: Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// "#RRGGBB" (or "RRGGBB"); nil when it cannot be read.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        self.init(Double((n >> 16) & 255) / 255, Double((n >> 8) & 255) / 255, Double(n & 255) / 255, 1)
    }
    public static func hex(_ s: String) -> RGBA { RGBA(hex: s) ?? RGBA(0, 0, 0) }

    public var hexString: String {
        func c(_ v: Double) -> String { let n = max(0, min(255, Int((v * 255).rounded()))); return String(format: "%02X", n) }
        return "#\(c(r))\(c(g))\(c(b))"
    }
    public func alpha(_ x: Double) -> RGBA { RGBA(r, g, b, a * x) }
    public static let clear = RGBA(0, 0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let black = RGBA(0, 0, 0)
}

/// Blends a colour toward black by f (0-1), like the JavaScript app's darken().
public func darken(_ hex: String, _ f: Double) -> String {
    guard let c = RGBA(hex: hex) else { return hex }
    func ch(_ v: Double) -> String { String(format: "%02x", max(0, Int(jsRound(v * 255 * (1 - f))))) }
    return "#\(ch(c.r))\(ch(c.g))\(ch(c.b))"
}
/// Blends a colour toward white by f (0-1), like the JavaScript app's lighten().
public func lighten(_ hex: String, _ f: Double) -> String {
    guard let c = RGBA(hex: hex) else { return hex }
    func ch(_ v: Double) -> String { let n = v * 255; return String(format: "%02x", min(255, Int(jsRound(n + (255 - n) * f)))) }
    return "#\(ch(c.r))\(ch(c.g))\(ch(c.b))"
}
/// color-mix(in srgb, a pct%, b): a plain per-channel linear blend.
public func mixColor(_ a: String, _ pctA: Double, _ b: String) -> String {
    let ca = RGBA(hex: a) ?? .black, cb = RGBA(hex: b) ?? .black
    let f = max(0, min(100, pctA)) / 100
    func ch(_ x: Double, _ y: Double) -> String { String(format: "%02x", Int(jsRound((x * 255) * f + (y * 255) * (1 - f)))) }
    return "#\(ch(ca.r, cb.r))\(ch(ca.g, cb.g))\(ch(ca.b, cb.b))"
}

// MARK: - Theme (the JavaScript app's theme.js)

public let COLOR_KEYS = ["task", "summary", "critical", "conflict", "near", "today", "arrow", "baseline", "status", "progressline"]
public let PALETTE: [String: [String: String]] = [
    "light": ["task": "#2563EB", "summary": "#1E293B", "critical": "#C62828", "conflict": "#D6007D", "near": "#D97706", "today": "#0891B2", "arrow": "#64748B", "baseline": "#94A3B8", "status": "#7C3AED", "progressline": "#15803D"],
    "dark": ["task": "#6EA8FF", "summary": "#CBD5E1", "critical": "#FF6B6B", "conflict": "#FF4FC3", "near": "#FFB84D", "today": "#22D3EE", "arrow": "#94A3B8", "baseline": "#64748B", "status": "#A78BFA", "progressline": "#4ADE80"],
]
public let COLOR_LABELS: [String: String] = [
    "task": "Normal task bar", "summary": "Summary and milestone", "critical": "Critical path", "conflict": "Conflict (magenta)", "near": "Near-critical",
    "today": "Today line", "arrow": "Link arrows", "baseline": "Baseline bar", "status": "Status date line", "progressline": "Progress line",
]
/// A curated, print-safe palette used everywhere a colour must be chosen (schedule colours, tag colours, header/footer).
/// Conflict uses magenta (not a shade of red) so it stays visually distinct from the red critical path on screen and in print.
public let STANDARD_SWATCHES: [(hex: String, name: String)] = [
    ("#C62828", "Red"), ("#D6007D", "Magenta"), ("#DB2777", "Pink"), ("#9333EA", "Purple"), ("#7C3AED", "Violet"),
    ("#4338CA", "Indigo"), ("#2563EB", "Blue"), ("#0891B2", "Cyan"), ("#0D9488", "Teal"), ("#059669", "Emerald"),
    ("#16A34A", "Green"), ("#65A30D", "Lime"), ("#CA8A04", "Yellow"), ("#D97706", "Amber"), ("#EA580C", "Orange"),
    ("#92400E", "Brown"), ("#0F172A", "Near-black"), ("#1E293B", "Slate"), ("#475569", "Grey"), ("#94A3B8", "Light grey"),
]
/// Brighter tints of the same swatches, for pickers used against a dark background.
public let STANDARD_SWATCHES_DARK: [(hex: String, name: String)] = STANDARD_SWATCHES.map { (lighten($0.hex, 0.35).uppercased(), $0.name) }

public struct Theme: Equatable, Sendable {
    public var dark: Bool
    public var bg, panel, border, text, muted, headerBg, grid, gridStrong, nonwork, holiday, rowAlt, sel, accent, accentText, danger: RGBA
    /// schedule colours (task, summary, critical, conflict, near, today, arrow, baseline, status, progressline) and their darker edges
    public var c: [String: RGBA]
    public var cDark: [String: RGBA]
    public var cHex: [String: String]

    /// The light or dark theme, with the user's colour choices (Project > Colours) applied on top.
    public init(dark: Bool, overrides: [String: String] = [:]) {
        self.dark = dark
        if dark {
            bg = .hex("#0F172A"); panel = .hex("#131E36"); border = .hex("#26334D"); text = .hex("#E2E8F0"); muted = .hex("#94A3B8")
            headerBg = .hex("#182339"); grid = .hex("#1F2B44"); gridStrong = .hex("#33415C")
            nonwork = RGBA(148 / 255, 163 / 255, 184 / 255, 0.09); holiday = RGBA(148 / 255, 163 / 255, 184 / 255, 0.15)
            rowAlt = .hex("#16233B"); sel = RGBA(110 / 255, 168 / 255, 255 / 255, 0.20); accent = .hex("#6EA8FF"); accentText = .hex("#0B1220"); danger = .hex("#FF6B6B")
        } else {
            bg = .hex("#FFFFFF"); panel = .hex("#F8FAFC"); border = .hex("#E2E8F0"); text = .hex("#0F172A"); muted = .hex("#64748B")
            headerBg = .hex("#F1F5F9"); grid = .hex("#E8EDF3"); gridStrong = .hex("#CBD5E1")
            nonwork = RGBA(100 / 255, 116 / 255, 139 / 255, 0.10); holiday = RGBA(100 / 255, 116 / 255, 139 / 255, 0.16)
            rowAlt = .hex("#F1F5F9"); sel = RGBA(37 / 255, 99 / 255, 235 / 255, 0.14); accent = .hex("#2563EB"); accentText = .hex("#FFFFFF"); danger = .hex("#C62828")
        }
        var pal = PALETTE[dark ? "dark" : "light"]!
        for (k, v) in overrides where pal[k] != nil && RGBA(hex: v) != nil { pal[k] = v }
        cHex = pal
        var c: [String: RGBA] = [:], cd: [String: RGBA] = [:]
        for (k, v) in pal { c[k] = .hex(v); cd[k] = .hex(darken(v, 0.22)) }
        self.c = c; self.cDark = cd
    }
    public static let light = Theme(dark: false)
    public static let dark = Theme(dark: true)
}

// MARK: - Fonts and text measurement

/// The eight fonts offered in View > Font (all ship with macOS). Keys are what the preferences and project files store.
public let FONTS: [(key: String, label: String)] = [
    ("system", "System Default (San Francisco)"), ("helvetica", "Helvetica Neue"), ("arial", "Arial"), ("georgia", "Georgia"),
    ("times", "Times New Roman"), ("verdana", "Verdana"), ("menlo", "Menlo (monospace)"), ("courier", "Courier New (monospace)"),
]

public struct TextStyle: Equatable, Hashable, Sendable {
    public enum Anchor: String, Sendable { case start, middle, end }
    public var size: Double = 11
    public var bold = false
    public var italic = false
    public var underline = false
    public var strike = false
    public var color: RGBA = .black
    public var anchor: Anchor = .start
    public var font: String = "system"
    public init(size: Double = 11, bold: Bool = false, italic: Bool = false, underline: Bool = false, strike: Bool = false,
                color: RGBA = .black, anchor: Anchor = .start, font: String = "system") {
        self.size = size; self.bold = bold; self.italic = italic; self.underline = underline; self.strike = strike
        self.color = color; self.anchor = anchor; self.font = font
    }
}

/// How wide a text draws. The Mac app supplies one that asks CoreText; this default uses Helvetica's published metrics, which
/// are close to San Francisco's and good enough for layout on platforms without the Mac's fonts (tests).
public protocol TextMeasurer: Sendable {
    func width(_ text: String, _ style: TextStyle) -> Double
}

public struct HelveticaMeasurer: TextMeasurer {
    public init() {}
    // AFM advance widths (1/1000 em) of Helvetica and Helvetica-Bold for ASCII 32...126.
    static let regular: [Int] = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]
    static let bold: [Int] = [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584]
    public func width(_ text: String, _ style: TextStyle) -> Double {
        let table = style.bold ? HelveticaMeasurer.bold : HelveticaMeasurer.regular
        var w = 0
        for u in text.unicodeScalars {
            let v = Int(u.value)
            if v >= 32 && v <= 126 { w += table[v - 32] }
            else if v >= 0x2E80 { w += 1000 } // CJK and other wide scripts
            else { w += 556 }
        }
        let mono = style.font == "menlo" || style.font == "courier"
        if mono { return Double(text.unicodeScalars.count) * 600 * style.size / 1000 }
        return Double(w) * style.size / 1000
    }
}

// MARK: - Items

public enum PathOp: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    /// Quadratic curve with control point (cx, cy) to (x, y).
    case quad(Double, Double, Double, Double)
    case close
}

public struct Stroke: Equatable, Sendable {
    public var color: RGBA
    public var width: Double
    public var dash: [Double]
    public var roundJoin: Bool
    public init(_ color: RGBA, _ width: Double = 1, dash: [Double] = [], roundJoin: Bool = false) {
        self.color = color; self.width = width; self.dash = dash; self.roundJoin = roundJoin
    }
}

public indirect enum DrawItem: Equatable, Sendable {
    case rect(x: Double, y: Double, w: Double, h: Double, r: Double, fill: RGBA?, stroke: Stroke?)
    case path([PathOp], fill: RGBA?, stroke: Stroke?)
    case circle(cx: Double, cy: Double, r: Double, fill: RGBA?, stroke: Stroke?)
    /// Text drawn with its baseline at y. `maxWidth`: cut with "…" when it would be wider.
    case text(String, x: Double, y: Double, style: TextStyle, maxWidth: Double?)
    /// An image (PNG or JPEG bytes) scaled into the box, keeping its aspect ratio.
    case image(Data, x: Double, y: Double, w: Double, h: Double)
    /// Items drawn only inside the clip rectangle.
    case clip(x: Double, y: Double, w: Double, h: Double, [DrawItem])
    /// Items moved by (dx, dy) and scaled by s.
    case group(dx: Double, dy: Double, scale: Double, [DrawItem])
}

public struct Drawing: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var background: RGBA?
    public var items: [DrawItem]
    public init(width: Double, height: Double, background: RGBA? = nil, items: [DrawItem] = []) {
        self.width = width; self.height = height; self.background = background; self.items = items
    }
}

/// Convenience builders.
public enum D {
    public static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, fill: RGBA? = nil, stroke: Stroke? = nil, r: Double = 0) -> DrawItem {
        .rect(x: x, y: y, w: w, h: h, r: r, fill: fill, stroke: stroke)
    }
    public static func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ s: Stroke) -> DrawItem {
        .path([.move(x1, y1), .line(x2, y2)], fill: nil, stroke: s)
    }
    public static func poly(_ pts: [(Double, Double)], fill: RGBA? = nil, stroke: Stroke? = nil, closed: Bool = false) -> DrawItem {
        var ops: [PathOp] = []
        for (k, p) in pts.enumerated() { ops.append(k == 0 ? .move(p.0, p.1) : .line(p.0, p.1)) }
        if closed { ops.append(.close) }
        return .path(ops, fill: fill, stroke: stroke)
    }
    public static func text(_ s: String, _ x: Double, _ y: Double, _ st: TextStyle, maxWidth: Double? = nil) -> DrawItem {
        .text(s, x: x, y: y, style: st, maxWidth: maxWidth)
    }
}

/// Cuts a text to fit `maxWidth`, ending with "…", the way CSS text-overflow: ellipsis does.
public func fitText(_ text: String, _ style: TextStyle, _ maxWidth: Double, _ m: TextMeasurer) -> String {
    if maxWidth <= 0 { return "" }
    if m.width(text, style) <= maxWidth { return text }
    var chars = Array(text)
    while !chars.isEmpty {
        chars.removeLast()
        let s = String(chars) + "…"
        if m.width(s, style) <= maxWidth { return s }
    }
    return ""
}

// MARK: - SVG

public enum SVGWriter {
    static func n(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return jsNumberString(r == 0 ? 0 : r)
    }
    static func color(_ c: RGBA) -> String { c.hexString }
    static func paint(_ attr: String, _ c: RGBA?) -> String {
        guard let c = c else { return " \(attr)=\"none\"" }
        var s = " \(attr)=\"\(color(c))\""
        if c.a < 1 { s += " \(attr)-opacity=\"\(n(c.a))\"" }
        return s
    }
    static func stroke(_ s: Stroke?) -> String {
        guard let s = s else { return " stroke=\"none\"" }
        var out = paint("stroke", s.color) + " stroke-width=\"\(n(s.width))\""
        if !s.dash.isEmpty { out += " stroke-dasharray=\"\(s.dash.map(n).joined(separator: " "))\"" }
        if s.roundJoin { out += " stroke-linejoin=\"round\"" }
        return out
    }
    static let fontFamily: [String: String] = [
        "system": "-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif", "helvetica": "'Helvetica Neue',Helvetica,Arial,sans-serif",
        "arial": "Arial,Helvetica,sans-serif", "georgia": "Georgia,'Times New Roman',serif", "times": "'Times New Roman',Georgia,serif",
        "verdana": "Verdana,Geneva,sans-serif", "menlo": "Menlo,Monaco,'Courier New',monospace", "courier": "'Courier New',Menlo,monospace",
    ]

    static func write(_ item: DrawItem, _ out: inout String, _ m: TextMeasurer, _ clipId: inout Int) {
        switch item {
        case .rect(let x, let y, let w, let h, let r, let fill, let s):
            out += "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(max(0, w)))\" height=\"\(n(max(0, h)))\""
            if r > 0 { out += " rx=\"\(n(r))\"" }
            out += paint("fill", fill) + stroke(s) + "/>"
        case .path(let ops, let fill, let s):
            var d = ""
            for op in ops {
                switch op {
                case .move(let x, let y): d += "M\(n(x)) \(n(y))"
                case .line(let x, let y): d += "L\(n(x)) \(n(y))"
                case .quad(let cx, let cy, let x, let y): d += "Q\(n(cx)) \(n(cy)) \(n(x)) \(n(y))"
                case .close: d += "Z"
                }
            }
            out += "<path d=\"\(d)\"" + paint("fill", fill) + stroke(s) + "/>"
        case .circle(let cx, let cy, let r, let fill, let s):
            out += "<circle cx=\"\(n(cx))\" cy=\"\(n(cy))\" r=\"\(n(r))\"" + paint("fill", fill) + stroke(s) + "/>"
        case .text(let str, let x, let y, let st, let maxW):
            let t = maxW.map { fitText(str, st, $0, m) } ?? str
            if t.isEmpty { return }
            out += "<text x=\"\(n(x))\" y=\"\(n(y))\" font-family=\"\(fontFamily[st.font] ?? fontFamily["system"]!)\" font-size=\"\(n(st.size))\""
            if st.bold { out += " font-weight=\"700\"" }
            if st.italic { out += " font-style=\"italic\"" }
            var deco: [String] = []
            if st.underline { deco.append("underline") }
            if st.strike { deco.append("line-through") }
            if !deco.isEmpty { out += " text-decoration=\"\(deco.joined(separator: " "))\"" }
            if st.anchor != .start { out += " text-anchor=\"\(st.anchor.rawValue)\"" }
            out += paint("fill", st.color) + " xml:space=\"preserve\">\(escapeXml(t))</text>"
        case .image(let data, let x, let y, let w, let h):
            let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
            out += "<image x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\" preserveAspectRatio=\"xMidYMid meet\" href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>"
        case .clip(let x, let y, let w, let h, let items):
            clipId += 1
            let id = "c\(clipId)"
            out += "<clipPath id=\"\(id)\"><rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\"/></clipPath><g clip-path=\"url(#\(id))\">"
            for it in items { write(it, &out, m, &clipId) }
            out += "</g>"
        case .group(let dx, let dy, let s, let items):
            out += "<g transform=\"translate(\(n(dx)) \(n(dy)))\(s != 1 ? " scale(\(n(s)))" : "")\">"
            for it in items { write(it, &out, m, &clipId) }
            out += "</g>"
        }
    }

    /// A complete, self-contained SVG document (no CSS, no external references).
    public static func svg(_ d: Drawing, measurer: TextMeasurer = HelveticaMeasurer(), scale: Double = 1) -> String {
        let w = n(d.width * scale), h = n(d.height * scale)
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(n(d.width)) \(n(d.height))\">"
        if let bg = d.background { out += "<rect x=\"0\" y=\"0\" width=\"\(n(d.width))\" height=\"\(n(d.height))\"" + paint("fill", bg) + "/>" }
        var clipId = 0
        for it in d.items { write(it, &out, measurer, &clipId) }
        out += "</svg>\n"
        return out
    }
}

/// Every text an item list draws (after cutting to its max width), with its left and right edge and the clip rectangle it is
/// drawn inside (if any), for tests and for checking that nothing runs past the edge of a chart or page.
public struct PlacedText: Equatable, Sendable {
    public var text: String; public var left: Double; public var right: Double; public var y: Double; public var style: TextStyle
    /// Visible area (x, y, w, h) the text is clipped to, in the same coordinates.
    public var clip: [Double]? = nil
    /// The visible part's left and right edge (the whole text when not clipped).
    public var visibleLeft: Double { clip.map { max(left, $0[0]) } ?? left }
    public var visibleRight: Double { clip.map { min(right, $0[0] + $0[2]) } ?? right }
}

public func placedTexts(_ items: [DrawItem], _ m: TextMeasurer, dx: Double = 0, dy: Double = 0, scale: Double = 1, clip: [Double]? = nil) -> [PlacedText] {
    var out: [PlacedText] = []
    for it in items {
        switch it {
        case .text(let s, let x, let y, let st, let mw):
            let t = mw.map { fitText(s, st, $0, m) } ?? s
            if t.isEmpty { continue }
            let w = m.width(t, st)
            let left = st.anchor == .start ? x : st.anchor == .middle ? x - w / 2 : x - w
            out.append(PlacedText(text: t, left: dx + left * scale, right: dx + (left + w) * scale, y: dy + y * scale, style: st, clip: clip))
        case .clip(let x, let y, let w, let h, let items):
            var c = [dx + x * scale, dy + y * scale, w * scale, h * scale]
            if let o = clip { // intersection with the clip already in force
                let x0 = max(c[0], o[0]), y0 = max(c[1], o[1]), x1 = min(c[0] + c[2], o[0] + o[2]), y1 = min(c[1] + c[3], o[1] + o[3])
                c = [x0, y0, max(0, x1 - x0), max(0, y1 - y0)]
            }
            out += placedTexts(items, m, dx: dx, dy: dy, scale: scale, clip: c)
        case .group(let gx, let gy, let s, let items): out += placedTexts(items, m, dx: dx + gx * scale, dy: dy + gy * scale, scale: scale * s, clip: clip)
        default: continue
        }
    }
    return out
}
