// A small JSON value type with ordered object keys, plus a parser and a writer that follow JavaScript's JSON.parse /
// JSON.stringify exactly (number formatting included). Ganttpath files are JSON written by the original JavaScript app,
// so reading and writing them the same way keeps files interchangeable and makes the two apps directly comparable.

import Foundation

public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }

    /// JavaScript truthiness (`!!value`).
    public var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// JavaScript `Number(value)`.
    public var jsNumber: Double {
        switch self {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s): return jsNumberFromString(s)
        case .array(let a):
            if a.isEmpty { return 0 }
            if a.count == 1 { return a[0].jsNumber }
            return .nan
        case .object: return .nan
        }
    }

    /// JavaScript `String(value)`.
    public var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return jsNumberString(n)
        case .string(let s): return s
        case .array(let a): return a.map { $0.isNull ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    public subscript(key: String) -> JSON? {
        get { object?[key] }
    }

    public init(_ s: String?) { self = s.map { .string($0) } ?? .null }
    public init(_ n: Int) { self = .number(Double(n)) }
    public init(_ n: Double) { self = .number(n) }
    public init(_ b: Bool) { self = .bool(b) }
}

/// An object whose keys keep their insertion order, like a JavaScript object with string keys.
public struct JSONObject: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var dict: [String: JSON] = [:]

    public init() {}
    public init(_ pairs: [(String, JSON)]) { for (k, v) in pairs { self[k] = v } }

    public subscript(key: String) -> JSON? {
        get { dict[key] }
        set {
            if let v = newValue {
                if dict[key] == nil { keys.append(key) }
                dict[key] = v
            } else if dict[key] != nil {
                dict[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }
    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var pairs: [(String, JSON)] { keys.map { ($0, dict[$0]!) } }
    public func has(_ key: String) -> Bool { dict[key] != nil }

    public static func == (a: JSONObject, b: JSONObject) -> Bool { a.keys == b.keys && a.dict == b.dict }
}

// MARK: - JavaScript number semantics

/// JavaScript `Number(string)`: trims white space; "" is 0; hex/binary/octal prefixes; "Infinity"; otherwise decimal or NaN.
public func jsNumberFromString(_ raw: String) -> Double {
    let s = raw.trimmingCharacters(in: jsWhitespace)
    if s.isEmpty { return 0 }
    let lower = s.lowercased()
    if lower.hasPrefix("0x") || lower.hasPrefix("0b") || lower.hasPrefix("0o") {
        let radix = lower.hasPrefix("0x") ? 16 : lower.hasPrefix("0b") ? 2 : 8
        let digits = s.dropFirst(2)
        if digits.isEmpty { return .nan }
        var v: Double = 0
        for ch in digits {
            guard let d = ch.hexDigitValue, d < radix else { return .nan }
            v = v * Double(radix) + Double(d)
        }
        return v
    }
    if s == "Infinity" || s == "+Infinity" { return .infinity }
    if s == "-Infinity" { return -.infinity }
    // StrDecimalLiteral: [+-] digits [. digits] [e [+-] digits]
    let chars = Array(s.utf8)
    var p = 0
    if p < chars.count, chars[p] == UInt8(ascii: "+") || chars[p] == UInt8(ascii: "-") { p += 1 }
    var sawDigit = false
    while p < chars.count, chars[p] >= 48, chars[p] <= 57 { p += 1; sawDigit = true }
    if p < chars.count, chars[p] == UInt8(ascii: ".") {
        p += 1
        while p < chars.count, chars[p] >= 48, chars[p] <= 57 { p += 1; sawDigit = true }
    }
    if !sawDigit { return .nan }
    if p < chars.count, chars[p] == UInt8(ascii: "e") || chars[p] == UInt8(ascii: "E") {
        p += 1
        if p < chars.count, chars[p] == UInt8(ascii: "+") || chars[p] == UInt8(ascii: "-") { p += 1 }
        var expDigit = false
        while p < chars.count, chars[p] >= 48, chars[p] <= 57 { p += 1; expDigit = true }
        if !expDigit { return .nan }
    }
    if p != chars.count { return .nan }
    return Double(s) ?? .nan
}

/// JavaScript `parseFloat(string)`: the longest leading decimal literal, NaN when there is none.
public func jsParseFloat(_ raw: String) -> Double {
    let s = raw.drop(while: { $0.unicodeScalars.allSatisfy { jsWhitespace.contains($0) } })
    if s.hasPrefix("Infinity") || s.hasPrefix("+Infinity") { return .infinity }
    if s.hasPrefix("-Infinity") { return -.infinity }
    let chars = Array(s.utf8)
    var p = 0
    if p < chars.count, chars[p] == UInt8(ascii: "+") || chars[p] == UInt8(ascii: "-") { p += 1 }
    var sawDigit = false
    while p < chars.count, chars[p] >= 48, chars[p] <= 57 { p += 1; sawDigit = true }
    var end = p
    if p < chars.count, chars[p] == UInt8(ascii: ".") {
        var q = p + 1
        var frac = false
        while q < chars.count, chars[q] >= 48, chars[q] <= 57 { q += 1; frac = true }
        if frac || sawDigit { end = q; sawDigit = sawDigit || frac }
    }
    if !sawDigit { return .nan }
    if end < chars.count, chars[end] == UInt8(ascii: "e") || chars[end] == UInt8(ascii: "E") {
        var q = end + 1
        if q < chars.count, chars[q] == UInt8(ascii: "+") || chars[q] == UInt8(ascii: "-") { q += 1 }
        var expDigit = false
        while q < chars.count, chars[q] >= 48, chars[q] <= 57 { q += 1; expDigit = true }
        if expDigit { end = q }
    }
    let text = String(decoding: chars[0..<end], as: UTF8.self)
    return Double(text) ?? .nan
}

let jsWhitespace: CharacterSet = {
    var cs = CharacterSet.whitespacesAndNewlines
    cs.insert(charactersIn: "\u{FEFF}\u{00A0}\u{2028}\u{2029}")
    return cs
}()

/// JavaScript `Math.round`: halves go up (towards +infinity).
@inline(__always)
public func jsRound(_ x: Double) -> Double {
    if !x.isFinite { return x }
    let f = x.rounded(.down)
    return x - f >= 0.5 ? f + 1 : f
}

/// `Math.round` to an Int (for values that are finite and fit).
@inline(__always)
public func jsRoundInt(_ x: Double) -> Int { Int(jsRound(x)) }

/// JavaScript `Number.prototype.toString()` (and `String(n)`), e.g. 5 -> "5", 0.75 -> "0.75", 1e21 -> "1e+21".
public func jsNumberString(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
    if x == 0 { return "0" }
    if x < 0 { return "-" + jsNumberString(-x) }
    // Swift's description is the shortest round-trip form too; take its digits and exponent and lay them out the JS way.
    let d = x.description
    var mantissa = d
    var exp = 0
    if let e = d.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = String(d[d.startIndex..<e])
        exp = Int(d[d.index(after: e)...]) ?? 0
    }
    var intPart = mantissa
    var fracPart = ""
    if let dot = mantissa.firstIndex(of: ".") {
        intPart = String(mantissa[mantissa.startIndex..<dot])
        fracPart = String(mantissa[mantissa.index(after: dot)...])
    }
    var digits = intPart + fracPart
    // value = 0.digits * 10^n  where n = len(intPart) + exp, after removing leading zeros
    var n = intPart.count + exp
    while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); n -= 1 }
    while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
    let k = digits.count
    if k <= n && n <= 21 {
        return digits + String(repeating: "0", count: n - k)
    }
    if 0 < n && n <= 21 {
        let idx = digits.index(digits.startIndex, offsetBy: n)
        return String(digits[..<idx]) + "." + String(digits[idx...])
    }
    if -6 < n && n <= 0 {
        return "0." + String(repeating: "0", count: -n) + digits
    }
    let e = n - 1
    let sign = e < 0 ? "-" : "+"
    let first = String(digits.prefix(1))
    let rest = String(digits.dropFirst())
    return first + (rest.isEmpty ? "" : "." + rest) + "e" + sign + String(abs(e))
}

// MARK: - Parser

public struct JSONError: Error, CustomStringConvertible {
    public let description: String
}

public enum JSONParser {
    public static func parse(_ text: String) throws -> JSON {
        var p = Parser(Array(text.utf8))
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        if p.i != p.b.count { throw JSONError(description: "Unexpected text after JSON at position \(p.i)") }
        return v
    }

    public static func parse(data: Data) throws -> JSON {
        try parse(String(decoding: data, as: UTF8.self))
    }

    private struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func skipWS() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        mutating func value(depth: Int) throws -> JSON {
            guard depth < 2000 else { throw JSONError(description: "JSON nested too deeply") }
            guard i < b.count else { throw JSONError(description: "Unexpected end of JSON input") }
            switch b[i] {
            case UInt8(ascii: "{"):
                i += 1
                var obj = JSONObject()
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                while true {
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw JSONError(description: "Expected a property name at position \(i)") }
                    let k = try string()
                    skipWS()
                    guard i < b.count, b[i] == UInt8(ascii: ":") else { throw JSONError(description: "Expected ':' at position \(i)") }
                    i += 1
                    skipWS()
                    let v = try value(depth: depth + 1)
                    // JSON.parse keeps the first position of a repeated key and the last value.
                    obj[k] = v
                    skipWS()
                    guard i < b.count else { throw JSONError(description: "Unexpected end of JSON input") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "}") { i += 1; return .object(obj) }
                    throw JSONError(description: "Expected ',' or '}' at position \(i)")
                }
            case UInt8(ascii: "["):
                i += 1
                var arr: [JSON] = []
                skipWS()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                while true {
                    skipWS()
                    arr.append(try value(depth: depth + 1))
                    skipWS()
                    guard i < b.count else { throw JSONError(description: "Unexpected end of JSON input") }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }
                    if b[i] == UInt8(ascii: "]") { i += 1; return .array(arr) }
                    throw JSONError(description: "Expected ',' or ']' at position \(i)")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try literal("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null"); return .null
            default:
                return .number(try number())
            }
        }

        mutating func literal(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= b.count, Array(b[i..<(i + u.count)]) == u else { throw JSONError(description: "Unexpected token at position \(i)") }
            i += u.count
        }

        mutating func number() throws -> Double {
            let start = i
            if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
            guard i < b.count, b[i] >= 48, b[i] <= 57 else { throw JSONError(description: "Unexpected token at position \(start)") }
            if b[i] == 48 { i += 1 } else { while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 } }
            if i < b.count, b[i] == UInt8(ascii: ".") {
                i += 1
                guard i < b.count, b[i] >= 48, b[i] <= 57 else { throw JSONError(description: "Bad number at position \(start)") }
                while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
            }
            if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
                i += 1
                if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
                guard i < b.count, b[i] >= 48, b[i] <= 57 else { throw JSONError(description: "Bad number at position \(start)") }
                while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
            }
            let text = String(decoding: b[start..<i], as: UTF8.self)
            guard let v = Double(text) else { throw JSONError(description: "Bad number at position \(start)") }
            return v
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= b.count else { throw JSONError(description: "Bad unicode escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = b[i]
                let d: UInt32
                switch c {
                case 48...57: d = UInt32(c - 48)
                case 65...70: d = UInt32(c - 55)
                case 97...102: d = UInt32(c - 87)
                default: throw JSONError(description: "Bad unicode escape")
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func string() throws -> String {
            i += 1 // opening quote
            var out = [UInt8]()
            while true {
                guard i < b.count else { throw JSONError(description: "Unterminated string in JSON") }
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { throw JSONError(description: "Bad control character in string literal at position \(i)") }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < b.count else { throw JSONError(description: "Unterminated string in JSON") }
                    let e = b[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if cp >= 0xD800 && cp <= 0xDBFF, i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                            let save = i
                            i += 2
                            let lo = try hex4()
                            if lo >= 0xDC00 && lo <= 0xDFFF {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                            } else { i = save }
                        }
                        // a lone surrogate cannot live in a Swift string: it becomes U+FFFD, as a browser would show it
                        let scalar = Unicode.Scalar(cp) ?? Unicode.Scalar(0xFFFD)!
                        out.append(contentsOf: Array(String(Character(scalar)).utf8))
                    default: throw JSONError(description: "Bad escaped character in JSON at position \(i - 1)")
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

// MARK: - Writer

public enum JSONWriter {
    /// JSON.stringify(value) — no white space.
    public static func stringify(_ v: JSON) -> String {
        var out = ""
        out.reserveCapacity(1024)
        write(v, into: &out, indent: nil, level: 0)
        return out
    }

    /// JSON.stringify(value, null, indent).
    public static func stringify(_ v: JSON, indent: Int) -> String {
        var out = ""
        write(v, into: &out, indent: String(repeating: " ", count: indent), level: 0)
        return out
    }

    private static func write(_ v: JSON, into out: inout String, indent: String?, level: Int) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.isFinite ? jsNumberString(n) : "null"
        case .string(let s): quote(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (k, x) in a.enumerated() {
                if k > 0 { out += "," }
                if let ind = indent { out += "\n" + String(repeating: ind, count: level + 1) }
                write(x, into: &out, indent: indent, level: level + 1)
            }
            if let ind = indent { out += "\n" + String(repeating: ind, count: level) }
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            var first = true
            for (k, x) in o.pairs {
                if !first { out += "," }
                first = false
                if let ind = indent { out += "\n" + String(repeating: ind, count: level + 1) }
                quote(k, into: &out)
                out += indent == nil ? ":" : ": "
                write(x, into: &out, indent: indent, level: level + 1)
            }
            if let ind = indent { out += "\n" + String(repeating: ind, count: level) }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}
