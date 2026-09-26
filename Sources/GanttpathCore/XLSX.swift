// Minimal .xlsx reader/writer built on Zip.swift and XML.swift.
// Read: first worksheet (or one picked by name) as a 2-D array; date-formatted numbers become 'YYYY-MM-DD' strings.
// Write: one or more sheets with a bold header row, real Excel dates, column widths, frozen header, autofilter.

import Foundation

let EPOCH_1900 = 25569 // days from 1899-12-30 to 1970-01-01

public func colName(_ i: Int) -> String {
    var s = ""
    var n = i + 1
    while n > 0 { s = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + s; n = (n - 1) / 26 }
    return s
}
func colIndex(_ ref: String) -> Int {
    let letters = ref.prefix { $0 >= "A" && $0 <= "Z" }
    var n = 0
    for ch in (letters.isEmpty ? "A" : letters).unicodeScalars { n = n * 26 + Int(ch.value) - 64 }
    return n - 1
}

/// A spreadsheet cell as written.
public enum Cell: Equatable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    case date(Int)                              // a day number: written as a real Excel date
    case styled(String, style: String)          // style: header | wrap | red | bold
    case styledNumber(Double, style: String)

    /// The cell as plain text for CSV (dates as YYYY-MM-DD), like the JavaScript app's tableToCsvRows().
    public var csvText: String {
        switch self {
        case .empty: return ""
        case .text(let s), .styled(let s, _): return s
        case .number(let n), .styledNumber(let n, _): return jsNumberString(n)
        case .bool(let b): return b ? "true" : "false"
        case .date(let dn): return toISO(dn)
        }
    }
}

public struct Sheet {
    public var name: String
    public var rows: [[Cell]]
    public var widths: [Double]? = nil
    public var freeze = true
    public init(name: String, rows: [[Cell]], widths: [Double]? = nil, freeze: Bool = true) {
        self.name = name; self.rows = rows; self.widths = widths; self.freeze = freeze
    }
}

public func writeXlsx(_ sheets: [Sheet], title: String = "Ganttpath", now: Date = Date()) -> [UInt8] {
    let STYLE = ["default": 0, "header": 1, "date": 2, "wrap": 3, "red": 4, "bold": 5]
    func sheetXml(_ k: Int, _ sh: Sheet) -> String {
        var rowsXml: [String] = []
        for (r, row) in sh.rows.enumerated() {
            var cells = ""
            for (c, cell) in row.enumerated() {
                let ref = "\(colName(c))\(r + 1)"
                switch cell {
                case .empty: continue
                case .text(let s):
                    if s.isEmpty { continue }
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXml(s))</t></is></c>"
                case .number(let n): cells += "<c r=\"\(ref)\"><v>\(n.isFinite ? jsNumberString(n) : "0")</v></c>"
                case .bool(let b): cells += "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .date(let dn): cells += "<c r=\"\(ref)\" s=\"\(STYLE["date"]!)\"><v>\(dn + EPOCH_1900)</v></c>"
                case .styled(let s, let style):
                    cells += "<c r=\"\(ref)\" s=\"\(STYLE[style] ?? 0)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escapeXml(s))</t></is></c>"
                case .styledNumber(let n, let style): cells += "<c r=\"\(ref)\" s=\"\(STYLE[style] ?? 0)\"><v>\(jsNumberString(n))</v></c>"
                }
            }
            rowsXml.append("<row r=\"\(r + 1)\">\(cells)</row>")
        }
        let ncol = max(1, sh.rows.map { $0.count }.max() ?? 1)
        let cols = (sh.widths ?? []).enumerated().map { "<col min=\"\($0.offset + 1)\" max=\"\($0.offset + 1)\" width=\"\(jsNumberString($0.element))\" customWidth=\"1\"/>" }.joined()
        let header = sh.rows.count > 1
        let frozen = header && sh.freeze
        return """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"\(k == 0 ? " tabSelected=\"1\"" : "")>\(frozen ? "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>" : "")</sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/>\(cols.isEmpty ? "" : "<cols>\(cols)</cols>")<sheetData>\(rowsXml.joined())</sheetData>\(frozen ? "<autoFilter ref=\"A1:\(colName(ncol - 1))\(sh.rows.count)\"/>" : "")<pageMargins left="0.5" right="0.5" top="0.75" bottom="0.75" header="0.3" footer="0.3"/><pageSetup orientation="landscape" fitToHeight="0"/></worksheet>
"""
    }
    let styles = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="dd\\-mmm\\-yyyy"/></numFmts><fonts count="3"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font><font><sz val="11"/><color rgb="FFC62828"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE2E8F0"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
"""
    func sheetName(_ s: String) -> String {
        let cleaned = String(s.map { "\\/?*[]:".contains($0) ? " " : $0 })
        return escapeXml(String(String(cleaned.utf16.prefix(31)) ?? cleaned))
    }
    let overrides = sheets.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined()
    var files: [ZipEntry] = [
        ZipEntry(name: "[Content_Types].xml", text: """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\(overrides)<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
"""),
        ZipEntry(name: "_rels/.rels", text: """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
"""),
        ZipEntry(name: "docProps/core.xml", text: """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(escapeXml(title))</dc:title><dc:creator>Ganttpath</dc:creator></cp:coreProperties>
"""),
        ZipEntry(name: "xl/workbook.xml", text: """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheets.enumerated().map { "<sheet name=\"\(sheetName($0.element.name))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())</sheets></workbook>
"""),
        ZipEntry(name: "xl/_rels/workbook.xml.rels", text: """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheets.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())<Relationship Id="rId\(sheets.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
"""),
        ZipEntry(name: "xl/styles.xml", text: styles),
    ]
    for (k, s) in sheets.enumerated() { files.append(ZipEntry(name: "xl/worksheets/sheet\(k + 1).xml", text: sheetXml(k, s))) }
    return zipFiles(files, now: now)
}

// MARK: - read

func isDateFormat(_ id: Int, _ code: String?) -> Bool {
    if (14...22).contains(id) || (27...36).contains(id) || (45...47).contains(id) || (50...58).contains(id) { return true }
    guard let code = code else { return false }
    var c = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
    c = c.replacingOccurrences(of: "\\\\.", with: "", options: .regularExpression)
    c = c.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression).lowercased()
    let hasDMYHS = c.contains { "dmyhs".contains($0) }
    let startsGeneral = c.hasPrefix("general") || c.hasPrefix("0") || c.hasPrefix("#")
    return hasDMYHS && !startsGeneral && (c.contains("d") || c.contains("y"))
}

/// A value read from a sheet: text, number or boolean (nil = empty).
public enum SheetValue: Equatable, Sendable {
    case text(String)
    case number(Double)
    case bool(Bool)
    public var asString: String {
        switch self {
        case .text(let s): return s
        case .number(let n): return jsNumberString(n)
        case .bool(let b): return b ? "true" : "false"
        }
    }
}

public struct ReadSheet { public var name: String; public var rows: [[SheetValue?]] }

public func readXlsx(_ buf: [UInt8], sheetName: String? = nil) throws -> [ReadSheet] {
    let zip = try unzip(buf)
    func text(_ name: String) -> String? { zip[name].map { String(decoding: $0, as: UTF8.self) } }
    guard let wbXml = text("xl/workbook.xml") else { throw ZipError(description: "This does not look like an Excel (.xlsx) workbook") }
    let wb = try parseXml(wbXml)
    let d1904 = (wb.kid("workbookPr")?.attrs["date1904"] ?? "").lowercased()
    let date1904 = d1904 == "1" || d1904 == "true"
    let rels = try parseXml(text("xl/_rels/workbook.xml.rels") ?? "<Relationships/>")
    var relTarget: [String: String] = [:]
    for r in rels.kids("Relationship") { if let id = r.attrs["Id"] { relTarget[id] = r.attrs["Target"] } }
    // shared strings
    var sst: [String] = []
    if let ssXml = text("xl/sharedStrings.xml") {
        for si in try parseXml(ssXml).kids("si") {
            var parts: [String] = []
            func walk(_ n: XMLNode) { for c in n.children { if c.name == "t" { parts.append(c.text) } else if c.name == "r" { walk(c) } } }
            walk(si)
            sst.append(parts.joined())
        }
    }
    // styles -> which xf indexes are dates
    var dateXf = Set<Int>()
    if let stXml = text("xl/styles.xml") {
        let st = try parseXml(stXml)
        var fmts: [Int: String] = [:]
        for nf in kids(st.kid("numFmts"), "numFmt") { if let id = Int(nf.attrs["numFmtId"] ?? "") { fmts[id] = nf.attrs["formatCode"] } }
        for (i, xf) in kids(st.kid("cellXfs"), "xf").enumerated() {
            let id = Int(xf.attrs["numFmtId"] ?? "0") ?? 0
            if isDateFormat(id, fmts[id]) { dateXf.insert(i) }
        }
    }
    var out: [ReadSheet] = []
    for sn in kids(wb.kid("sheets"), "sheet") {
        guard let rid = sn.attrs["id"], var target = relTarget[rid] else { continue }
        if target.hasPrefix("/") { target.removeFirst() }
        if target.hasPrefix("xl/") { target.removeFirst(3) }
        target = "xl/" + target
        guard let sx = text(target) else { continue }
        let name = sn.attrs["name"] ?? ""
        if let want = sheetName, name != want { continue }
        let ws = try parseXml(sx)
        var rows: [[SheetValue?]] = []
        for row in kids(ws.kid("sheetData"), "row") {
            let rn = Int(row.attrs["r"] ?? "") ?? 0
            let r = (rn > 0 ? rn : rows.count + 1) - 1
            while rows.count <= r { rows.append([]) }
            var cIdx = 0
            for c in row.kids("c") {
                let ci = c.attrs["r"].map(colIndex) ?? cIdx
                cIdx = ci + 1
                let t = c.attrs["t"] ?? "n"
                let v = c.kid("v")?.text
                var val: SheetValue? = nil
                switch t {
                case "s": val = v.map { .text(Int($0).flatMap { $0 >= 0 && $0 < sst.count ? sst[$0] : nil } ?? "") }
                case "inlineStr":
                    if let isNode = c.kid("is") {
                        func collect(_ n: XMLNode) -> String { n.children.map { $0.name == "t" ? $0.text : $0.name == "r" ? collect($0) : "" }.joined() }
                        val = .text(collect(isNode))
                    } else { val = .text("") }
                case "str", "e": val = v.map { .text($0) }
                case "b": val = .bool(v == "1")
                case "d": val = v.flatMap { $0.isEmpty ? nil : .text(String($0.prefix(10))) }
                default:
                    if let v = v, !v.isEmpty {
                        let num = jsNumberFromString(v)
                        val = .number(num)
                        if dateXf.contains(Int(c.attrs["s"] ?? "0") ?? 0), num.isFinite, num > 0 {
                            let days = Int(num.rounded(.down)) - (date1904 ? EPOCH_1900 - 1462 : EPOCH_1900) + (!date1904 && num < 61 ? 1 : 0)
                            val = .text(toISO(days))
                        }
                    }
                }
                while rows[r].count <= ci { rows[r].append(nil) }
                rows[r][ci] = val
            }
        }
        out.append(ReadSheet(name: name, rows: rows))
    }
    if out.isEmpty { throw ZipError(description: sheetName != nil ? "Sheet \"\(sheetName!)\" not found" : "The workbook has no readable sheets") }
    return out
}
