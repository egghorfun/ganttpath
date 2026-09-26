// Minimal ZIP reader/writer (enough for .xlsx), with its own DEFLATE compressor and decompressor (RFC 1951),
// so it needs no system library and behaves the same on macOS and Linux.

import Foundation

private let CRC_TABLE: [UInt32] = (0..<256).map { n -> UInt32 in
    var c = UInt32(n)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

public func crc32(_ data: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = CRC_TABLE[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

public struct ZipError: Error, CustomStringConvertible { public let description: String }

// MARK: - Inflate

private struct Huffman {
    var counts = [UInt16](repeating: 0, count: 16)
    var symbols: [UInt16]
    init(lengths: [UInt8]) {
        symbols = [UInt16](repeating: 0, count: lengths.count)
        for l in lengths { counts[Int(l)] += 1 }
        counts[0] = 0
        var offs = [UInt16](repeating: 0, count: 16)
        for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
        for (s, l) in lengths.enumerated() where l != 0 { symbols[Int(offs[Int(l)])] = UInt16(s); offs[Int(l)] += 1 }
    }
}

private struct BitReader {
    let d: [UInt8]
    var pos = 0
    var bitBuf: UInt32 = 0
    var bitCnt = 0
    init(_ d: [UInt8]) { self.d = d }
    mutating func need(_ n: Int) throws {
        while bitCnt < n {
            guard pos < d.count else { throw ZipError(description: "Damaged compressed data") }
            bitBuf |= UInt32(d[pos]) << UInt32(bitCnt)
            pos += 1
            bitCnt += 8
        }
    }
    mutating func bits(_ n: Int) throws -> Int {
        if n == 0 { return 0 }
        try need(n)
        let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
        bitBuf >>= UInt32(n)
        bitCnt -= n
        return v
    }
    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = Int(h.counts[len])
            if code - count < first { return Int(h.symbols[index + (code - first)]) }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw ZipError(description: "Damaged compressed data")
    }
}

private let LBASE: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
private let LEXT: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
private let DBASE: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
private let DEXT: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
private let CL_ORDER: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

private let fixedLit: Huffman = {
    var l = [UInt8](repeating: 8, count: 288)
    for i in 144..<256 { l[i] = 9 }
    for i in 256..<280 { l[i] = 7 }
    return Huffman(lengths: l)
}()
private let fixedDist = Huffman(lengths: [UInt8](repeating: 5, count: 30))

/// Decompress raw DEFLATE data.
public func inflateRaw(_ input: [UInt8], maxOutput: Int = 512 * 1024 * 1024) throws -> [UInt8] {
    var br = BitReader(input)
    var out: [UInt8] = []
    out.reserveCapacity(input.count * 4)
    var last = 0
    repeat {
        last = try br.bits(1)
        let type = try br.bits(2)
        if type == 0 {
            br.bitBuf = 0; br.bitCnt = 0
            guard br.pos + 4 <= input.count else { throw ZipError(description: "Damaged compressed data") }
            let len = Int(input[br.pos]) | Int(input[br.pos + 1]) << 8
            br.pos += 4
            guard br.pos + len <= input.count else { throw ZipError(description: "Damaged compressed data") }
            out.append(contentsOf: input[br.pos..<(br.pos + len)])
            br.pos += len
        } else if type == 1 || type == 2 {
            var lit = fixedLit, dist = fixedDist
            if type == 2 {
                let hlit = try br.bits(5) + 257, hdist = try br.bits(5) + 1, hclen = try br.bits(4) + 4
                var cl = [UInt8](repeating: 0, count: 19)
                for k in 0..<hclen { cl[CL_ORDER[k]] = UInt8(try br.bits(3)) }
                let clh = Huffman(lengths: cl)
                var lens = [UInt8]()
                while lens.count < hlit + hdist {
                    let sym = try br.decode(clh)
                    if sym < 16 { lens.append(UInt8(sym)) }
                    else if sym == 16 {
                        guard let prev = lens.last else { throw ZipError(description: "Damaged compressed data") }
                        for _ in 0..<(3 + (try br.bits(2))) { lens.append(prev) }
                    } else if sym == 17 { for _ in 0..<(3 + (try br.bits(3))) { lens.append(0) } }
                    else { for _ in 0..<(11 + (try br.bits(7))) { lens.append(0) } }
                }
                lit = Huffman(lengths: Array(lens[0..<hlit]))
                dist = Huffman(lengths: Array(lens[hlit..<(hlit + hdist)]))
            }
            while true {
                let sym = try br.decode(lit)
                if sym < 256 { out.append(UInt8(sym)) }
                else if sym == 256 { break }
                else {
                    let li = sym - 257
                    guard li < 29 else { throw ZipError(description: "Damaged compressed data") }
                    let len = LBASE[li] + (try br.bits(LEXT[li]))
                    let ds = try br.decode(dist)
                    guard ds < 30 else { throw ZipError(description: "Damaged compressed data") }
                    let d = DBASE[ds] + (try br.bits(DEXT[ds]))
                    guard d <= out.count else { throw ZipError(description: "Damaged compressed data") }
                    let start = out.count - d
                    for k in 0..<len { out.append(out[start + k]) }
                }
                if out.count > maxOutput { throw ZipError(description: "File is too large to open safely") }
            }
        } else { throw ZipError(description: "Damaged compressed data") }
    } while last == 0
    return out
}

// MARK: - Deflate (LZ77 with hash chains + fixed Huffman codes)

private struct BitWriter {
    var out: [UInt8] = []
    var buf: UInt32 = 0
    var cnt = 0
    mutating func put(_ v: Int, _ n: Int) {
        buf |= UInt32(v) << UInt32(cnt)
        cnt += n
        while cnt >= 8 { out.append(UInt8(buf & 0xFF)); buf >>= 8; cnt -= 8 }
    }
    /// Huffman codes are sent most significant bit first.
    mutating func putRev(_ code: Int, _ n: Int) {
        var r = 0
        for k in 0..<n { r |= ((code >> k) & 1) << (n - 1 - k) }
        put(r, n)
    }
    mutating func flush() { if cnt > 0 { out.append(UInt8(buf & 0xFF)); buf = 0; cnt = 0 } }
}

private func putLit(_ w: inout BitWriter, _ sym: Int) {
    if sym < 144 { w.putRev(0x30 + sym, 8) }
    else if sym < 256 { w.putRev(0x190 + sym - 144, 9) }
    else if sym < 280 { w.putRev(sym - 256, 7) }
    else { w.putRev(0xC0 + sym - 280, 8) }
}

/// Compress to raw DEFLATE data.
public func deflateRaw(_ data: [UInt8]) -> [UInt8] {
    var w = BitWriter()
    w.put(1, 1) // final block
    w.put(1, 2) // fixed Huffman
    let n = data.count
    let HBITS = 15, HSIZE = 1 << 15, WIN = 32768, MAXCHAIN = 64
    var head = [Int](repeating: -1, count: HSIZE)
    var prev = [Int](repeating: -1, count: WIN)
    func hash(_ i: Int) -> Int { ((Int(data[i]) << 10) ^ (Int(data[i + 1]) << 5) ^ Int(data[i + 2])) & ((1 << HBITS) - 1) }
    func insert(_ i: Int) {
        guard i + 2 < n else { return }
        let h = hash(i)
        prev[i & (WIN - 1)] = head[h]
        head[h] = i
    }
    var i = 0
    while i < n {
        var bestLen = 0, bestDist = 0
        if i + 2 < n {
            var cand = head[hash(i)]
            var chain = 0
            while cand >= 0 && i - cand <= WIN - 1 && chain < MAXCHAIN {
                var l = 0
                while l < 258 && i + l < n && data[cand + l] == data[i + l] { l += 1 }
                if l > bestLen { bestLen = l; bestDist = i - cand; if l == 258 { break } }
                let nx = prev[cand & (WIN - 1)]
                if nx >= cand { break }
                cand = nx
                chain += 1
            }
        }
        if bestLen >= 3 {
            var li = 28
            while LBASE[li] > bestLen { li -= 1 }
            putLit(&w, 257 + li)
            w.put(bestLen - LBASE[li], LEXT[li])
            var di = 29
            while DBASE[di] > bestDist { di -= 1 }
            w.putRev(di, 5)
            w.put(bestDist - DBASE[di], DEXT[di])
            for k in 0..<bestLen { insert(i + k) }
            i += bestLen
        } else {
            putLit(&w, Int(data[i]))
            insert(i)
            i += 1
        }
    }
    putLit(&w, 256)
    w.flush()
    return w.out
}

// MARK: - ZIP container

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }

public struct ZipEntry {
    public var name: String
    public var data: [UInt8]
    public init(name: String, data: [UInt8]) { self.name = name; self.data = data }
    public init(name: String, text: String) { self.name = name; self.data = Array(text.utf8) }
}

/// files -> zip bytes
public func zipFiles(_ files: [ZipEntry], now: Date = Date()) -> [UInt8] {
    var chunks: [UInt8] = []
    var central: [UInt8] = []
    var offset = 0
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
    let dosTime = (c.hour! << 11) | (c.minute! << 5) | (c.second! >> 1)
    let dosDate = ((c.year! - 1980) << 9) | (c.month! << 5) | c.day!
    for f in files {
        let name = Array(f.name.utf8)
        let raw = f.data
        let comp = deflateRaw(raw)
        let useDeflate = comp.count < raw.count
        let data = useDeflate ? comp : raw
        let crc = crc32(raw)
        var lh: [UInt8] = []
        lh += le32(0x04034B50); lh += le16(20); lh += le16(0x0800); lh += le16(useDeflate ? 8 : 0)
        lh += le16(dosTime); lh += le16(dosDate); lh += le32(crc); lh += le32(UInt32(data.count)); lh += le32(UInt32(raw.count))
        lh += le16(name.count); lh += le16(0)
        chunks += lh; chunks += name; chunks += data
        var ch: [UInt8] = []
        ch += le32(0x02014B50); ch += le16(20); ch += le16(20); ch += le16(0x0800); ch += le16(useDeflate ? 8 : 0)
        ch += le16(dosTime); ch += le16(dosDate); ch += le32(crc); ch += le32(UInt32(data.count)); ch += le32(UInt32(raw.count))
        ch += le16(name.count); ch += le16(0); ch += le16(0); ch += le16(0); ch += le16(0); ch += le32(0); ch += le32(UInt32(offset))
        central += ch; central += name
        offset += lh.count + name.count + data.count
    }
    var end: [UInt8] = []
    end += le32(0x06054B50); end += le16(0); end += le16(0); end += le16(files.count); end += le16(files.count)
    end += le32(UInt32(central.count)); end += le32(UInt32(offset)); end += le16(0)
    return chunks + central + end
}

/// Read a zip into name -> bytes. Supports stored and deflated entries.
public func unzip(_ buf: [UInt8], maxTotal: Int = 512 * 1024 * 1024) throws -> [String: [UInt8]] {
    func u16(_ p: Int) throws -> Int { guard p + 2 <= buf.count else { throw ZipError(description: "Not a valid .xlsx/.zip file") }; return Int(buf[p]) | Int(buf[p + 1]) << 8 }
    func u32(_ p: Int) throws -> Int {
        guard p + 4 <= buf.count else { throw ZipError(description: "Not a valid .xlsx/.zip file") }
        return Int(buf[p]) | Int(buf[p + 1]) << 8 | Int(buf[p + 2]) << 16 | Int(buf[p + 3]) << 24
    }
    var eocd = -1
    if buf.count >= 22 {
        var i = buf.count - 22
        let stop = max(0, buf.count - 65557)
        while i >= stop { if try u32(i) == 0x06054B50 { eocd = i; break }; i -= 1 }
    }
    if eocd < 0 { throw ZipError(description: "Not a valid .xlsx/.zip file") }
    let count = try u16(eocd + 10)
    var p = try u32(eocd + 16)
    var out: [String: [UInt8]] = [:]
    var total = 0
    for _ in 0..<count {
        if try u32(p) != 0x02014B50 { throw ZipError(description: "Damaged zip directory") }
        let method = try u16(p + 10)
        let csize = try u32(p + 20)
        let usize = try u32(p + 24)
        let nlen = try u16(p + 28), elen = try u16(p + 30), clen = try u16(p + 32)
        let lho = try u32(p + 42)
        guard p + 46 + nlen <= buf.count else { throw ZipError(description: "Damaged zip directory") }
        let name = String(decoding: buf[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
        p += 46 + nlen + elen + clen
        if name.hasSuffix("/") { continue }
        total += usize
        if total > maxTotal { throw ZipError(description: "File is too large to open safely") }
        let lnlen = try u16(lho + 26), lelen = try u16(lho + 28)
        let start = lho + 30 + lnlen + lelen
        guard start + csize <= buf.count else { throw ZipError(description: "Damaged zip file") }
        let raw = Array(buf[start..<(start + csize)])
        if method == 0 { out[name] = raw }
        else if method == 8 { out[name] = try inflateRaw(raw, maxOutput: maxTotal) }
        else { throw ZipError(description: "Unsupported zip compression method \(method)") }
    }
    return out
}
