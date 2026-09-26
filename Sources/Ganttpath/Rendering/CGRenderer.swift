// Paints GanttpathCore drawings with CoreGraphics and CoreText: the same code draws the screen, the PDF pages and PNG images.
// Drawings use y-down coordinates (like SVG); the caller hands a context whose y axis already points down (a flipped NSView,
// or a PDF / bitmap context flipped with `flipped(_:height:)`).

import AppKit
import CoreText
import ImageIO
import GanttpathCore

// MARK: - fonts

enum Fonts {
    /// PostScript names of the eight fonts offered in View > Font (all ship with macOS).
    static let names: [String: String] = [
        "helvetica": "HelveticaNeue", "arial": "ArialMT", "georgia": "Georgia", "times": "TimesNewRomanPSMT",
        "verdana": "Verdana", "menlo": "Menlo-Regular", "courier": "CourierNewPSMT",
    ]

    static func ctFont(_ st: TextStyle) -> CTFont {
        let base: CTFont
        if let name = names[st.font] {
            base = CTFontCreateWithName(name as CFString, CGFloat(st.size), nil)
        } else {
            base = NSFont.systemFont(ofSize: CGFloat(st.size)) as CTFont
        }
        var traits: CTFontSymbolicTraits = []
        if st.bold { traits.insert(.traitBold) }
        if st.italic { traits.insert(.traitItalic) }
        if traits.isEmpty { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, CGFloat(st.size), nil, traits, traits) ?? base
    }

    static func nsFont(_ key: String, size: CGFloat, bold: Bool = false) -> NSFont {
        let st = TextStyle(size: Double(size), bold: bold, font: key)
        return ctFont(st) as NSFont
    }
}

/// Text widths from CoreText, so layout (label reach, ellipsis, print columns) matches what is drawn.
final class CoreTextMeasurer: TextMeasurer, @unchecked Sendable {
    static let shared = CoreTextMeasurer()
    private let cache = NSCache<NSString, NSNumber>()
    private let lock = NSLock()
    private var fonts: [TextStyle: CTFont] = [:]

    func font(_ st: TextStyle) -> CTFont {
        var key = st
        key.color = .black; key.anchor = .start; key.underline = false; key.strike = false
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[key] { return f }
        let f = Fonts.ctFont(st)
        fonts[key] = f
        return f
    }

    func width(_ text: String, _ style: TextStyle) -> Double {
        if text.isEmpty { return 0 }
        let k = "\(style.font)|\(style.size)|\(style.bold)|\(style.italic)|\(text)" as NSString
        if let v = cache.object(forKey: k) { return v.doubleValue }
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(style)])
        let line = CTLineCreateWithAttributedString(attr)
        let w = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        cache.setObject(NSNumber(value: w), forKey: k)
        return w
    }
}

// MARK: - painting

extension RGBA {
    var cg: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var ns: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
}

enum CGRenderer {
    /// Paint a whole drawing (background first).
    static func draw(_ d: Drawing, in ctx: CGContext, measurer: CoreTextMeasurer = .shared) {
        if let bg = d.background {
            ctx.setFillColor(bg.cg)
            ctx.fill(CGRect(x: 0, y: 0, width: d.width, height: d.height))
        }
        draw(d.items, in: ctx, measurer: measurer)
    }

    static func draw(_ items: [DrawItem], in ctx: CGContext, measurer: CoreTextMeasurer = .shared) {
        for it in items { draw(it, ctx, measurer) }
    }

    private static func apply(_ s: Stroke, _ ctx: CGContext) {
        ctx.setStrokeColor(s.color.cg)
        ctx.setLineWidth(CGFloat(s.width))
        ctx.setLineDash(phase: 0, lengths: s.dash.map { CGFloat($0) })
        ctx.setLineJoin(s.roundJoin ? .round : .miter)
        ctx.setLineCap(.butt)
    }

    private static func draw(_ item: DrawItem, _ ctx: CGContext, _ m: CoreTextMeasurer) {
        switch item {
        case .rect(let x, let y, let w, let h, let r, let fill, let stroke):
            let rect = CGRect(x: x, y: y, width: max(0, w), height: max(0, h))
            let rr = CGFloat(min(r, min(abs(w), abs(h)) / 2))
            let path = rr > 0 ? CGPath(roundedRect: rect, cornerWidth: rr, cornerHeight: rr, transform: nil) : CGPath(rect: rect, transform: nil)
            paint(path, fill: fill, stroke: stroke, ctx)
        case .path(let ops, let fill, let stroke):
            let p = CGMutablePath()
            for op in ops {
                switch op {
                case .move(let x, let y): p.move(to: CGPoint(x: x, y: y))
                case .line(let x, let y): p.addLine(to: CGPoint(x: x, y: y))
                case .quad(let cx, let cy, let x, let y): p.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
                case .close: p.closeSubpath()
                }
            }
            paint(p, fill: fill, stroke: stroke, ctx)
        case .circle(let cx, let cy, let r, let fill, let stroke):
            paint(CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r), transform: nil), fill: fill, stroke: stroke, ctx)
        case .text(let s, let x, let y, let st, let maxW):
            let t = maxW.map { fitText(s, st, $0, m) } ?? s
            if t.isEmpty { return }
            drawText(t, x: x, y: y, style: st, ctx, m)
        case .image(let data, let x, let y, let w, let h):
            guard let src = CGImageSourceCreateWithData(data as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
            // keep the aspect ratio, centred in the box
            let iw = Double(img.width), ih = Double(img.height)
            let s = min(w / max(1, iw), h / max(1, ih))
            let dw = iw * s, dh = ih * s
            let rect = CGRect(x: x + (w - dw) / 2, y: y + (h - dh) / 2, width: dw, height: dh)
            ctx.saveGState()
            // images draw bottom-up: flip locally
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
        case .clip(let x, let y, let w, let h, let inner):
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x, y: y, width: max(0, w), height: max(0, h)))
            for i in inner { draw(i, ctx, m) }
            ctx.restoreGState()
        case .group(let dx, let dy, let s, let inner):
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(dx), y: CGFloat(dy))
            if s != 1 { ctx.scaleBy(x: CGFloat(s), y: CGFloat(s)) }
            for i in inner { draw(i, ctx, m) }
            ctx.restoreGState()
        }
    }

    private static func paint(_ p: CGPath, fill: RGBA?, stroke: Stroke?, _ ctx: CGContext) {
        if let f = fill, f.a > 0 {
            ctx.addPath(p)
            ctx.setFillColor(f.cg)
            ctx.fillPath()
        }
        if let s = stroke, s.color.a > 0, s.width > 0 {
            ctx.addPath(p)
            apply(s, ctx)
            ctx.strokePath()
        }
    }

    /// Text with its baseline at y, in a y-down context.
    static func drawText(_ t: String, x: Double, y: Double, style st: TextStyle, _ ctx: CGContext, _ m: CoreTextMeasurer = .shared) {
        let font = m.font(st)
        let attr = NSAttributedString(string: t, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): st.color.cg,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let w = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        let left = st.anchor == .start ? x : st.anchor == .middle ? x - w / 2 : x - w
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1) // glyphs upright in a y-down context
        ctx.textPosition = CGPoint(x: left, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        if st.underline || st.strike {
            let lw = max(0.6, st.size / 14)
            ctx.saveGState()
            ctx.setStrokeColor(st.color.cg)
            ctx.setLineWidth(CGFloat(lw))
            ctx.setLineDash(phase: 0, lengths: [])
            if st.underline {
                let uy = y + st.size * 0.12
                ctx.move(to: CGPoint(x: left, y: uy)); ctx.addLine(to: CGPoint(x: left + w, y: uy))
            }
            if st.strike {
                let sy = y - st.size * 0.3
                ctx.move(to: CGPoint(x: left, y: sy)); ctx.addLine(to: CGPoint(x: left + w, y: sy))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

// MARK: - files

enum ImageExport {
    /// PNG bytes of a drawing at `scale` times its size (2 keeps it sharp when placed into a document).
    static func png(_ d: Drawing, scale: Double = 2) -> Data? {
        let w = max(1, min(8000, Int((d.width * scale).rounded()))), h = max(1, min(8000, Int((d.height * scale).rounded())))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        CGRenderer.draw(d, in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])
    }

    /// A PDF with one page per drawing. Drawings are in CSS pixels (96 per inch): 1 px = 0.75 pt.
    static func pdf(_ pages: [Drawing], title: String) -> Data? {
        guard let first = pages.first else { return nil }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(x: 0, y: 0, width: first.width * 0.75, height: first.height * 0.75)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Ganttpath"]
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return nil }
        for d in pages {
            var pageBox = CGRect(x: 0, y: 0, width: d.width * 0.75, height: d.height * 0.75)
            let boxData = NSData(bytes: &pageBox, length: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pageBox.height)
            ctx.scaleBy(x: 0.75, y: -0.75)
            CGRenderer.draw(d, in: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}
