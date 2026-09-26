// The toolbar's line icons (icons.js): 16x16, stroked with the text colour, 1.5 px wide, round ends. The SVG shapes are
// read here into plain segments so the Mac app draws exactly the same icons.

import Foundation

public enum IconSeg: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case close
}

public enum Icons {
    /// SVG elements of each icon (icons.js P).
    public static let source: [String: String] = [
        "new": #"<path d="M4 1.5h5l3 3V14.5H4z"/><path d="M9 1.5v3h3M8 7.5v4M6 9.5h4"/>"#,
        "open": #"<path d="M1.5 4.5h4l1.5 1.5h7v7.5h-12.5z"/>"#,
        "save": #"<path d="M2.5 2.5h9l2 2v9h-11z"/><path d="M5 2.5v3.5h5V2.5M5 13.5v-4h6v4"/>"#,
        "undo": #"<path d="M5.5 3 2.5 6l3 3"/><path d="M2.5 6H10a3.5 3.5 0 0 1 0 7H6"/>"#,
        "redo": #"<path d="M10.5 3l3 3-3 3"/><path d="M13.5 6H6a3.5 3.5 0 0 0 0 7h4"/>"#,
        "add": #"<path d="M8 3v10M3 8h10"/>"#,
        "summary": #"<path d="M2 3.5h12M2 8h8M2 12.5h8"/><path d="M12.5 7l2 2-2 2"/>"#,
        "delete": #"<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.7 8.5h5.6l.7-8.5"/>"#,
        "indent": #"<path d="M2 3h12M7 6.5h7M7 10h7M2 13.5h12M2.5 6.5l2.5 1.75L2.5 10z"/>"#,
        "outdent": #"<path d="M2 3h12M7 6.5h7M7 10h7M2 13.5h12M5 6.5 2.5 8.25 5 10z"/>"#,
        "up": #"<path d="M8 13V3M4 7l4-4 4 4"/>"#,
        "down": #"<path d="M8 3v10M4 9l4 4 4-4"/>"#,
        "link": #"<path d="M6.5 9.5a2.5 2.5 0 0 0 3.5 0l2.5-2.5a2.5 2.5 0 0 0-3.5-3.5L8 4.5"/><path d="M9.5 6.5a2.5 2.5 0 0 0-3.5 0L3.5 9a2.5 2.5 0 0 0 3.5 3.5L8 11.5"/>"#,
        "unlink": #"<path d="M6.5 9.5a2.5 2.5 0 0 0 3.5 0l2.5-2.5a2.5 2.5 0 0 0-3.5-3.5"/><path d="M9.5 6.5a2.5 2.5 0 0 0-3.5 0L3.5 9a2.5 2.5 0 0 0 3.5 3.5M2 2l12 12"/>"#,
        "milestone": #"<path d="M8 2l5 6-5 6-5-6z"/>"#,
        "auto": #"<circle cx="8" cy="8" r="5.5"/><path d="M8 4.5V8l2.5 1.5"/>"#,
        "manual": #"<path d="M9.5 2.5l4 4-2 .5-2.5 2.5-.5 3-2-2-4 4M7 5l4 4"/>"#,
        "zoomIn": #"<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14M5 7h4M7 5v4"/>"#,
        "zoomOut": #"<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14M5 7h4"/>"#,
        "fit": #"<path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>"#,
        "today": #"<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/><circle cx="8" cy="10.5" r="1.2"/>"#,
        "baseline": #"<path d="M2 5h9M2 8h12M2 11h7"/>"#,
        "critical": #"<path d="M3.5 14V2.5M3.5 3h8l-2 2.5 2 2.5h-8"/>"#,
        "filter": #"<path d="M2 3h12l-4.5 5.5V13l-3-1.5V8.5z"/>"#,
        "sort": #"<path d="M4.5 3v10M2 10.5 4.5 13 7 10.5M11.5 13V3M9 5.5 11.5 3 14 5.5"/>"#,
        "group": #"<path d="M2 3.5h12M4 7h10M4 10.5h10M2 14h12"/>"#,
        "search": #"<circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14"/>"#,
        "warn": #"<path d="M8 2 1.5 13.5h13z"/><path d="M8 6.5v3.5M8 11.7v.1"/>"#,
        "moon": #"<path d="M13 9.5A5.5 5.5 0 1 1 6.5 3 4.5 4.5 0 0 0 13 9.5z"/>"#,
        "sun": #"<circle cx="8" cy="8" r="2.8"/><path d="M8 1.5v1.8M8 12.7v1.8M1.5 8h1.8M12.7 8h1.8M3.4 3.4l1.3 1.3M11.3 11.3l1.3 1.3M12.6 3.4l-1.3 1.3M4.7 11.3l-1.3 1.3"/>"#,
        "panel": #"<rect x="2" y="2.5" width="12" height="11" rx="1.5"/><path d="M10 2.5v11"/>"#,
        "settings": #"<circle cx="8" cy="8" r="2"/><path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M12.6 3.4l-1.4 1.4M4.8 11.2l-1.4 1.4"/>"#,
        "calendar": #"<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/>"#,
        "tag": #"<path d="M2 8.5V2.5h6l6 6-6 6z"/><circle cx="5" cy="5.2" r="1"/>"#,
        "export": #"<path d="M8 2v8M4.5 6.5 8 10l3.5-3.5M2.5 11v3h11v-3"/>"#,
        "history": #"<path d="M2.5 8a5.5 5.5 0 1 0 1.6-3.9M2 2v3h3"/><path d="M8 5v3.2l2 1.2"/>"#,
        "columns": #"<rect x="2" y="2.5" width="12" height="11" rx="1.5"/><path d="M6 2.5v11M10 2.5v11"/>"#,
        "template": #"<rect x="2.5" y="2" width="11" height="12" rx="1.5"/><path d="M5 5.5h6M5 8h6M5 10.5h4"/>"#,
        "close": #"<path d="M4 4l8 8M12 4l-8 8"/>"#,
        "more": #"<circle cx="3.5" cy="8" r="1"/><circle cx="8" cy="8" r="1"/><circle cx="12.5" cy="8" r="1"/>"#,
        "chevron": #"<path d="M4 6l4 4 4-4"/>"#,
    ]

    nonisolated(unsafe) private static var cache: [String: [IconSeg]] = [:]
    private static let lock = NSLock()

    /// The segments of an icon in its 16x16 box (empty for an unknown name).
    public static func segments(_ name: String) -> [IconSeg] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[name] { return c }
        let s = source[name].map(parseElements) ?? []
        cache[name] = s
        return s
    }

    // MARK: - reading the SVG

    static func attrs(_ tag: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var rest = tag
        while let eq = rest.firstIndex(of: "=") {
            let key = rest[rest.startIndex..<eq].split(separator: " ").last.map(String.init) ?? ""
            guard let q1 = rest[eq...].firstIndex(of: "\""), let q2 = rest[rest.index(after: q1)...].firstIndex(of: "\"") else { break }
            out[key] = String(rest[rest.index(after: q1)..<q2])
            rest = rest[rest.index(after: q2)...]
        }
        return out
    }

    static func parseElements(_ svg: String) -> [IconSeg] {
        var segs: [IconSeg] = []
        var rest = Substring(svg)
        while let lt = rest.firstIndex(of: "<"), let gt = rest[lt...].firstIndex(of: ">") {
            let tag = rest[rest.index(after: lt)..<gt]
            let a = attrs(tag)
            func n(_ k: String) -> Double { Double(a[k] ?? "") ?? 0 }
            if tag.hasPrefix("path") { segs += parsePath(a["d"] ?? "") }
            else if tag.hasPrefix("circle") { segs += ellipse(n("cx"), n("cy"), n("r")) }
            else if tag.hasPrefix("rect") { segs += roundedRect(n("x"), n("y"), n("width"), n("height"), n("rx")) }
            rest = rest[rest.index(after: gt)...]
        }
        return segs
    }

    /// Numbers of an SVG path (handles "-3.5", ".5", "2.5.5" and "1-2").
    static func tokens(_ d: String) -> [Any] {
        var out: [Any] = []
        var num = ""
        var sawDot = false, sawExp = false
        func flush() { if !num.isEmpty, let v = Double(num) { out.append(v) }; num = ""; sawDot = false; sawExp = false }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" { flush(); out.append(ch); continue }
            if ch == "," || ch == " " || ch == "\n" || ch == "\t" { flush(); continue }
            if ch == "-" || ch == "+" {
                if let last = num.last, last == "e" || last == "E" { num.append(ch); continue }
                flush(); num.append(ch); continue
            }
            if ch == "." { if sawDot || sawExp { flush() }; sawDot = true; num.append(ch); continue }
            if ch == "e" || ch == "E" { sawExp = true; num.append(ch); continue }
            num.append(ch)
        }
        flush()
        return out
    }

    static func parsePath(_ d: String) -> [IconSeg] {
        let t = tokens(d)
        var i = 0
        var segs: [IconSeg] = []
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        var cmd: Character = "M"
        func next() -> Double { let v = t[i] as! Double; i += 1; return v }
        func hasNum() -> Bool { i < t.count && t[i] is Double }
        while i < t.count {
            if let c = t[i] as? Character { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            switch cmd.uppercased().first! {
            case "M":
                var x = next(), y = next()
                if rel { x += cx; y += cy }
                cx = x; cy = y; sx = x; sy = y
                segs.append(.move(x, y))
                cmd = rel ? "l" : "L" // further pairs are lines
            case "L":
                var x = next(), y = next()
                if rel { x += cx; y += cy }
                cx = x; cy = y
                segs.append(.line(x, y))
            case "H":
                var x = next(); if rel { x += cx }
                cx = x
                segs.append(.line(cx, cy))
            case "V":
                var y = next(); if rel { y += cy }
                cy = y
                segs.append(.line(cx, cy))
            case "A":
                let rx = next(), ry = next(), rot = next(), large = next() != 0, sweep = next() != 0
                var x = next(), y = next()
                if rel { x += cx; y += cy }
                segs += arc(cx, cy, rx, ry, rot, large, sweep, x, y)
                cx = x; cy = y
            case "Z":
                segs.append(.close)
                cx = sx; cy = sy
            default:
                i += 1
            }
            if !hasNum() && i < t.count && !(t[i] is Character) { i += 1 }
        }
        return segs
    }

    /// An SVG elliptical arc as cubic curves (SVG spec, appendix F.6).
    static func arc(_ x1: Double, _ y1: Double, _ rx0: Double, _ ry0: Double, _ rotDeg: Double, _ large: Bool, _ sweep: Bool, _ x2: Double, _ y2: Double) -> [IconSeg] {
        if rx0 == 0 || ry0 == 0 { return [.line(x2, y2)] }
        let phi = rotDeg * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy
        var rx = abs(rx0), ry = abs(ry0)
        let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lam > 1 { rx *= lam.squareRoot(); ry *= lam.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
        let ccx = cp * cxp - sp * cyp + (x1 + x2) / 2, ccy = sp * cxp + cp * cyp + (y1 + y2) / 2
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dth > 0 { dth -= 2 * .pi } else if sweep && dth < 0 { dth += 2 * .pi }
        let n = max(1, Int((abs(dth) / (.pi / 2)).rounded(.up)))
        let step = dth / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out: [IconSeg] = []
        var th = th1
        for _ in 0..<n {
            let c1 = cos(th), s1 = sin(th), c2 = cos(th + step), s2 = sin(th + step)
            func pt(_ ex: Double, _ ey: Double) -> (Double, Double) { (ccx + cp * rx * ex - sp * ry * ey, ccy + sp * rx * ex + cp * ry * ey) }
            let p1 = pt(c1 - k * s1, s1 + k * c1), p2 = pt(c2 + k * s2, s2 - k * c2), p3 = pt(c2, s2)
            out.append(.cubic(p1.0, p1.1, p2.0, p2.1, p3.0, p3.1))
            th += step
        }
        return out
    }

    static func ellipse(_ cx: Double, _ cy: Double, _ r: Double) -> [IconSeg] {
        [.move(cx + r, cy)] + arc(cx + r, cy, r, r, 0, false, true, cx - r, cy) + arc(cx - r, cy, r, r, 0, false, true, cx + r, cy) + [.close]
    }

    static func roundedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> [IconSeg] {
        if r <= 0 { return [.move(x, y), .line(x + w, y), .line(x + w, y + h), .line(x, y + h), .close] }
        var s: [IconSeg] = [.move(x + r, y), .line(x + w - r, y)]
        s += arc(x + w - r, y, r, r, 0, false, true, x + w, y + r)
        s.append(.line(x + w, y + h - r))
        s += arc(x + w, y + h - r, r, r, 0, false, true, x + w - r, y + h)
        s.append(.line(x + r, y + h))
        s += arc(x + r, y + h, r, r, 0, false, true, x, y + h - r)
        s.append(.line(x, y + r))
        s += arc(x, y + r, r, r, 0, false, true, x + r, y)
        s.append(.close)
        return s
    }

    /// The icon as SVG path data (for checking it against the original).
    public static func pathData(_ name: String) -> String {
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        return segments(name).map { s in
            switch s {
            case .move(let x, let y): return "M\(f(x)) \(f(y))"
            case .line(let x, let y): return "L\(f(x)) \(f(y))"
            case .cubic(let a, let b, let c, let d, let e, let g): return "C\(f(a)) \(f(b)) \(f(c)) \(f(d)) \(f(e)) \(f(g))"
            case .close: return "Z"
            }
        }.joined()
    }
}
