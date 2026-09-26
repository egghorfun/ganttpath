// Public holidays: bundled verified data, a download provider, and a review step before anything changes a calendar.
//
// Bundled data is the offline fallback and is always available. Downloaded data comes from Nager.Date (date.nager.at, free public API):
//   GET https://date.nager.at/api/v3/PublicHolidays/{year}/{countryCode}
//   -> [{ date:'2026-01-01', localName, name, countryCode, fixed, global, counties, launchYear, types:['Public'] }]
// Nothing is applied automatically: fetchHolidays() only returns a proposal; diffHolidays() shows what would change and the user accepts it.

import Foundation

public struct BundledCountry: Sendable {
    public let name: String
    public let source: String
    public let note: String
    public let years: [Int: [(String, String)]]
}

// --- Singapore, verified against the Ministry of Manpower's published lists (see `source`)
public let BUNDLED: [String: BundledCountry] = [
    "SG": BundledCountry(
        name: "Singapore",
        source: "Singapore Ministry of Manpower: \"Public Holidays for 2026\" dataset (data.gov.sg) and press release \"Public Holidays for 2027\" (18 Jun 2026)",
        note: "Hari Raya Puasa and Hari Raya Haji depend on the sighting of the moon; the authorities can still adjust them.",
        years: [
            2026: [
                ("2026-01-01", "New Year's Day"),
                ("2026-02-17", "Chinese New Year"),
                ("2026-02-18", "Chinese New Year"),
                ("2026-03-21", "Hari Raya Puasa"),
                ("2026-04-03", "Good Friday"),
                ("2026-05-01", "Labour Day"),
                ("2026-05-27", "Hari Raya Haji"),
                ("2026-05-31", "Vesak Day"),
                ("2026-06-01", "Vesak Day (in lieu)"),
                ("2026-08-09", "National Day"),
                ("2026-08-10", "National Day (in lieu)"),
                ("2026-11-08", "Deepavali"),
                ("2026-11-09", "Deepavali (in lieu)"),
                ("2026-12-25", "Christmas Day"),
            ],
            2027: [
                ("2027-01-01", "New Year's Day"),
                ("2027-02-06", "Chinese New Year"),
                ("2027-02-07", "Chinese New Year"),
                ("2027-02-08", "Chinese New Year (in lieu)"),
                ("2027-03-10", "Hari Raya Puasa"),
                ("2027-03-26", "Good Friday"),
                ("2027-05-01", "Labour Day"),
                ("2027-05-17", "Hari Raya Haji"),
                ("2027-05-20", "Vesak Day"),
                ("2027-08-09", "National Day"),
                ("2027-10-28", "Deepavali"),
                ("2027-12-25", "Christmas Day"),
            ],
        ]),
]

// Countries offered in the "new project" dialog (ISO 3166-1 alpha-2).
public let COUNTRIES: [(String, String)] = [
    ("SG", "Singapore"), ("MY", "Malaysia"), ("ID", "Indonesia"), ("TH", "Thailand"), ("VN", "Vietnam"), ("PH", "Philippines"), ("TW", "Taiwan"),
    ("HK", "Hong Kong"), ("CN", "China"), ("JP", "Japan"), ("KR", "South Korea"), ("IN", "India"), ("BD", "Bangladesh"), ("LK", "Sri Lanka"),
    ("AE", "United Arab Emirates"), ("SA", "Saudi Arabia"), ("QA", "Qatar"), ("KW", "Kuwait"), ("OM", "Oman"), ("BH", "Bahrain"), ("EG", "Egypt"),
    ("TR", "Türkiye"), ("AU", "Australia"), ("NZ", "New Zealand"), ("GB", "United Kingdom"), ("IE", "Ireland"), ("DE", "Germany"), ("FR", "France"),
    ("NL", "Netherlands"), ("BE", "Belgium"), ("CH", "Switzerland"), ("AT", "Austria"), ("IT", "Italy"), ("ES", "Spain"), ("PT", "Portugal"),
    ("SE", "Sweden"), ("NO", "Norway"), ("DK", "Denmark"), ("FI", "Finland"), ("PL", "Poland"), ("CZ", "Czechia"), ("HU", "Hungary"), ("RO", "Romania"),
    ("GR", "Greece"), ("US", "United States"), ("CA", "Canada"), ("MX", "Mexico"), ("BR", "Brazil"), ("AR", "Argentina"), ("CL", "Chile"),
    ("CO", "Colombia"), ("PE", "Peru"), ("ZA", "South Africa"), ("NG", "Nigeria"), ("KE", "Kenya"), ("MA", "Morocco"),
].sorted { $0.1.compare($1.1, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }

public func countryName(_ code: String) -> String {
    BUNDLED[code]?.name ?? COUNTRIES.first { $0.0 == code }?.1 ?? code
}

func holidayTag(_ code: String) -> String { "holiday:\(code)" }

public struct HolidaySet: Sendable {
    public var items: [CalException]
    public var years: [Int]
    public var source: String?
    public var note: String?
    public var errors: [String] = []
}

/// Exception objects for a country's bundled holidays in the given years (empty list if none bundled).
public func bundledHolidays(_ code: String, _ years: [Int]) -> HolidaySet {
    guard let b = BUNDLED[code] else { return HolidaySet(items: [], years: [], source: nil, note: nil) }
    let covered = years.filter { b.years[$0] != nil }
    let items = covered.flatMap { y in b.years[y]!.map { CalException(from: $0.0, to: $0.0, working: false, name: $0.1, origin: holidayTag(code)) } }
    return HolidaySet(items: items, years: covered, source: b.source, note: b.note)
}

public struct HolidayError: Error, CustomStringConvertible { public let description: String }

/// Parse a Nager.Date response (array). Only nationwide public holidays are kept. Throws on an unexpected shape.
public func parseNager(_ json: JSON, _ code: String) throws -> [CalException] {
    guard let arr = json.array else { throw HolidayError(description: "Unexpected reply from the holiday service") }
    var items: [CalException] = []
    for h in arr {
        guard let o = h.object, let date = o["date"]?.string, parseISO(date) != nil else { continue }
        if o["global"] == .bool(false) { continue } // regional holidays are left out; the user can add them manually
        if let types = o["types"]?.array, !types.isEmpty, !types.contains(.string("Public")) { continue }
        let name = o["name"]?.string ?? ""
        let local = o["localName"]?.string ?? ""
        let text: String
        if !local.isEmpty && local != name { text = "\(name) (\(local))" }
        else { text = name.isEmpty ? "Public holiday" : name }
        let d = String(date.prefix(10))
        items.append(CalException(from: d, to: d, working: false, name: text, origin: holidayTag(code)))
    }
    return items
}

/// A minimal HTTP GET used by fetchHolidays: returns (status, body). The app passes URLSession; tests pass a fake.
public typealias HTTPGet = @Sendable (URL) async throws -> (Int, Data)

/// Download holidays for several years. Years that fail are reported in errors and left out.
public func fetchHolidays(_ code: String, _ years: [Int], get: HTTPGet, base: String = "https://date.nager.at/api/v3") async -> HolidaySet {
    var items: [CalException] = []
    var gotYears: [Int] = []
    var errors: [String] = []
    for y in years {
        do {
            let enc = code.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? code
            guard let url = URL(string: "\(base)/PublicHolidays/\(y)/\(enc)") else { errors.append("\(y): bad address"); continue }
            let (status, data) = try await get(url)
            if status == 404 || status == 204 { errors.append("\(y): the service has no data for \(countryName(code))"); continue }
            if !(200...299).contains(status) { errors.append("\(y): the service answered \(status)"); continue }
            let parsed = try parseNager(try JSONParser.parse(data: data), code)
            if parsed.isEmpty { errors.append("\(y): no holidays returned"); continue }
            items.append(contentsOf: parsed)
            gotYears.append(y)
        } catch {
            errors.append("\(y): \(error)")
        }
    }
    return HolidaySet(items: items, years: gotYears, source: "Nager.Date (date.nager.at)", note: nil, errors: errors)
}

func excKey(_ e: CalException) -> String { "\(e.from)|\(nonEmpty(e.to) ?? e.from)" }

public struct HolidayDiff: Sendable {
    public var added: [CalException] = []
    public var removed: [CalException] = []
    public var renamed: [(from: CalException, to: CalException)] = []
    public var unchanged: [CalException] = []
    public var skipped: [(CalException, String)] = []
}

/// Compare a calendar's automatically-added holidays with a proposal, for the review dialog.
/// Only exceptions with origin "holiday:<code>" inside the proposal's years are considered "managed"; everything the user typed is left alone.
public func diffHolidays(_ calendarDef: CalendarDef, _ proposal: [CalException], _ code: String, _ years: [Int]) -> HolidayDiff {
    let origin = holidayTag(code)
    func inYears(_ iso: String) -> Bool { years.contains(Int(iso.prefix(4)) ?? -1) }
    let current = calendarDef.exceptions.filter { $0.origin == origin && inYears($0.from) }
    var manual: [String: CalException] = [:]
    for e in calendarDef.exceptions where e.origin != origin { manual[excKey(e)] = e }
    var cur: [(String, CalException)] = []
    var curIdx: [String: Int] = [:]
    for e in current { let k = excKey(e); if let i = curIdx[k] { cur[i].1 = e } else { curIdx[k] = cur.count; cur.append((k, e)) } }
    var next: [(String, CalException)] = []
    var nextIdx: [String: Int] = [:]
    for e in proposal where inYears(e.from) { let k = excKey(e); if let i = nextIdx[k] { next[i].1 = e } else { nextIdx[k] = next.count; next.append((k, e)) } }
    var d = HolidayDiff()
    for (k, e) in next {
        if manual[k] != nil { d.skipped.append((e, "You already have an entry for this date")); continue }
        if let ci = curIdx[k] {
            let c = cur[ci].1
            if c.name != e.name { d.renamed.append((c, e)) } else { d.unchanged.append(e) }
        } else { d.added.append(e) }
    }
    for (k, e) in cur where nextIdx[k] == nil { d.removed.append(e) }
    return d
}

/// Apply an accepted proposal to a calendar definition.
public func applyHolidayProposal(_ calendarDef: inout CalendarDef, _ proposal: [CalException], _ code: String, _ years: [Int]) {
    let origin = holidayTag(code)
    func inYears(_ iso: String) -> Bool { years.contains(Int(iso.prefix(4)) ?? -1) }
    let manualKeys = Set(calendarDef.exceptions.filter { $0.origin != origin }.map(excKey))
    let keep = calendarDef.exceptions.filter { $0.origin != origin || !inYears($0.from) }
    let add = proposal.filter { inYears($0.from) && !manualKeys.contains(excKey($0)) }
    calendarDef.exceptions = (keep + add).enumerated().sorted { a, b in
        a.element.from != b.element.from ? a.element.from < b.element.from : a.offset < b.offset
    }.map { $0.element }
}

/// Years a new project should get holidays for: from the start year for `span` years.
public func projectYears(_ startIso: String, _ span: Int = 5) -> [Int] {
    var y = Int(startIso.prefix(4)) ?? 0
    if y == 0 { y = Calendar.current.component(.year, from: Date()) }
    return (0..<span).map { y + $0 }
}

public func weekdayOf(_ iso: String) -> Int? { parseISO(iso).map(dow) }
