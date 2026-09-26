// A small, dependency-free XML reader and writer helpers (enough for MS Project XML and Excel's XML parts).
// - No DOCTYPE/entity expansion beyond the five standard entities and numeric references (nothing to abuse).
// - Namespace prefixes are dropped: <ns:Task> is read as "Task".

import Foundation

public final class XmlNode {
    public let name: String
    public var attrs: [String: String]
    public var text: String
    public var children: [XmlNode]
    init(name: String, attrs: [String: String] = [:]) { self.name = name; self.attrs = attrs; self.text = ""; self.children = [] }

    public func kids(_ name: String) -> [XmlNode] { children.filter { $0.name == name } }
    public func kid(_ name: String) -> XmlNode? { children.first { $0.name == name } }
    /// The trimmed text of the first child with this name, or nil when there is none.
    public func kidText(_ name: String) -> String? { kid(name).map { jsTrim($0.text) } }
}

public func kids(_ node: XmlNode?, _ name: String) -> [XmlNode] { node?.kids(name) ?? [] }
public func kid(_ node: XmlNode?, _ name: String) -> XmlNode? { node?.kid(name) }
public func kidText(_ node: XmlNode?, _ name: String) -> String? { node?.kidText(name) }

private let ENT: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]

public func unescapeXml(_ s: Substring) -> String {
    guard s.contains("&") else { return String(s) }
    var out = ""
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let c = s[i]
        if c == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 12 {
            let body = s[s.index(after: i)..<semi]
            var rep: String? = nil
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                let hex = body.dropFirst(2)
                if !hex.isEmpty, hex.allSatisfy({ $0.isHexDigit }) {
                    rep = UInt32(hex, radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
                }
            } else if body.hasPrefix("#") {
                let dec = body.dropFirst()
                if !dec.isEmpty, dec.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    rep = UInt32(dec).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? ""
                }
            } else if !body.isEmpty, body.allSatisfy({ $0.isASCII && $0.isLetter }) {
                rep = ENT[String(body)] ?? String(s[i...semi])
            }
            if let r = rep { out += r; i = s.index(after: semi); continue }
        }
        out.append(c)
        i = s.index(after: i)
    }
    return out
}

public func escapeXml(_ s: String?) -> String {
    var out = ""
    for u in (s ?? "").unicodeScalars {
        let v = u.value
        // characters XML 1.0 cannot carry
        if (v <= 0x08) || v == 0x0B || v == 0x0C || (v >= 0x0E && v <= 0x1F) || v == 0xFFFE || v == 0xFFFF { continue }
        switch u {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        default: out.unicodeScalars.append(u)
        }
    }
    return out
}

public struct XMLError: Error, CustomStringConvertible { public let description: String }

func localName(_ s: Substring) -> String {
    if let c = s.firstIndex(of: ":") { return String(s[s.index(after: c)...]) }
    return String(s)
}

/// Parse XML text into a tree. Throws XMLError with a readable message on malformed input.
public func parseXml(_ source: String) throws -> XmlNode {
    // Work on unicode scalars so "\r\n" is two characters, like in JavaScript.
    let src = source.unicodeScalars
    var i = src.startIndex
    if src.first == "\u{FEFF}" { i = src.index(after: i) }
    let root = XmlNode(name: "#root")
    var stack = [root]
    func text(_ a: String.UnicodeScalarView.Index, _ b: String.UnicodeScalarView.Index) -> String {
        unescapeXml(Substring(src[a..<b]))
    }
    func find(_ needle: String, from: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index? {
        let nd = Array(needle.unicodeScalars)
        var j = from
        while j < src.endIndex {
            if src[j] == nd[0] {
                var k = j, m = 0
                while m < nd.count && k < src.endIndex && src[k] == nd[m] { k = src.index(after: k); m += 1 }
                if m == nd.count { return j }
            }
            j = src.index(after: j)
        }
        return nil
    }
    func startsWith(_ needle: String, at: String.UnicodeScalarView.Index) -> Bool {
        var k = at
        for u in needle.unicodeScalars {
            guard k < src.endIndex, src[k] == u else { return false }
            k = src.index(after: k)
        }
        return true
    }
    func adv(_ x: String.UnicodeScalarView.Index, _ n: Int) -> String.UnicodeScalarView.Index { src.index(x, offsetBy: n, limitedBy: src.endIndex) ?? src.endIndex }
    while i < src.endIndex {
        let cur = stack[stack.count - 1]
        guard let lt = src[i...].firstIndex(of: "<") else { cur.text += text(i, src.endIndex); break }
        if lt > i { cur.text += text(i, lt) }
        if startsWith("<!--", at: lt) {
            guard let e = find("-->", from: adv(lt, 4)) else { throw XMLError(description: "Unterminated comment") }
            i = adv(e, 3)
        } else if startsWith("<![CDATA[", at: lt) {
            guard let e = find("]]>", from: adv(lt, 9)) else { throw XMLError(description: "Unterminated CDATA") }
            cur.text += String(Substring(src[adv(lt, 9)..<e]))
            i = adv(e, 3)
        } else if startsWith("<?", at: lt) {
            guard let e = find("?>", from: adv(lt, 2)) else { throw XMLError(description: "Unterminated declaration") }
            i = adv(e, 2)
        } else if startsWith("<!", at: lt) {
            // DOCTYPE and friends: skipped, never interpreted
            var depth = 0
            var j = lt
            while j < src.endIndex {
                let c = src[j]
                if c == "<" { depth += 1 } else if c == ">" { depth -= 1; if depth == 0 { break } }
                j = src.index(after: j)
            }
            i = adv(j, 1)
        } else if adv(lt, 1) < src.endIndex && src[adv(lt, 1)] == "/" {
            guard let e = src[adv(lt, 2)...].firstIndex(of: ">") else { throw XMLError(description: "Unterminated closing tag") }
            let nm = localName(Substring(jsTrim(String(Substring(src[adv(lt, 2)..<e])))))
            let top = stack.popLast()
            if top == nil || top!.name != nm || stack.isEmpty { throw XMLError(description: "Mismatched closing tag </\(nm)>") }
            i = src.index(after: e)
        } else {
            // opening tag; find its end, honouring quoted attribute values
            var j = adv(lt, 1)
            var q: Unicode.Scalar? = nil
            while j < src.endIndex {
                let c = src[j]
                if let qq = q { if c == qq { q = nil } } else if c == "\"" || c == "'" { q = c } else if c == ">" { break }
                j = src.index(after: j)
            }
            if j >= src.endIndex { throw XMLError(description: "Unterminated tag") }
            var inner = String(Substring(src[adv(lt, 1)..<j]))
            let selfClose = inner.hasSuffix("/")
            if selfClose { inner.removeLast() }
            let innerU = Array(inner.unicodeScalars)
            let sp = innerU.firstIndex { CharacterSet.whitespacesAndNewlines.contains($0) }
            var nameText = ""; nameText.unicodeScalars.append(contentsOf: sp == nil ? innerU[...] : innerU[..<sp!])
            let node = XmlNode(name: localName(Substring(nameText)))
            if let sp = sp { node.attrs = parseAttrs(Array(innerU[sp...])) }
            cur.children.append(node)
            if !selfClose { stack.append(node) }
            i = src.index(after: j)
        }
    }
    if stack.count != 1 { throw XMLError(description: "Unclosed element <\(stack[stack.count - 1].name)>") }
    guard let top = root.children.first else { throw XMLError(description: "No XML content found") }
    return top
}

/// Attributes like /([^\s=]+)\s*=\s*("([^"]*)"|'([^']*)')/g
private func parseAttrs(_ s: [Unicode.Scalar]) -> [String: String] {
    var out: [String: String] = [:]
    var i = 0
    let ws = CharacterSet.whitespacesAndNewlines
    while i < s.count {
        // name
        while i < s.count && (ws.contains(s[i]) || s[i] == "=") { i += 1 }
        let ns = i
        while i < s.count && !ws.contains(s[i]) && s[i] != "=" { i += 1 }
        if ns == i { break }
        var name = ""; name.unicodeScalars.append(contentsOf: s[ns..<i])
        var j = i
        while j < s.count && ws.contains(s[j]) { j += 1 }
        guard j < s.count, s[j] == "=" else { continue }
        j += 1
        while j < s.count && ws.contains(s[j]) { j += 1 }
        guard j < s.count, s[j] == "\"" || s[j] == "'" else { i = j; continue }
        let q = s[j]
        guard let close = s[(j + 1)...].firstIndex(of: q) else { i = j + 1; continue }
        var v = ""; v.unicodeScalars.append(contentsOf: s[(j + 1)..<close])
        out[localName(Substring(name))] = unescapeXml(Substring(v))
        i = close + 1
    }
    return out
}

/// Tiny writer: builds indented XML text.
public final class XmlOut {
    var buf: [String] = []
    public var depth = 0
    let indent: String
    public init(indent: String = "    ") { self.indent = indent }
    @discardableResult public func raw(_ s: String) -> XmlOut { buf.append(s); return self }
    @discardableResult public func open(_ name: String) -> XmlOut { buf.append(String(repeating: indent, count: depth) + "<\(name)>"); depth += 1; return self }
    @discardableResult public func close(_ name: String) -> XmlOut { depth -= 1; buf.append(String(repeating: indent, count: depth) + "</\(name)>"); return self }
    /// nil value -> element skipped
    @discardableResult public func el(_ name: String, _ value: String?) -> XmlOut {
        guard let v = value else { return self }
        buf.append(String(repeating: indent, count: depth) + "<\(name)>\(escapeXml(v))</\(name)>")
        return self
    }
    @discardableResult public func el(_ name: String, _ value: Int?) -> XmlOut { el(name, value.map(String.init)) }
    @discardableResult public func empty(_ name: String) -> XmlOut { buf.append(String(repeating: indent, count: depth) + "<\(name)/>"); return self }
    public func toString() -> String { buf.joined(separator: "\n") + "\n" }
}
