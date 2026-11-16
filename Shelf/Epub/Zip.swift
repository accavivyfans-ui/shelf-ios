import Foundation
import Compression

/// Minimal read-only ZIP archive (stored + deflate), enough for EPUB files.
final class ZipArchive {
    struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localOffset: Int
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    private var lowercased: [String: String] = [:]

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        data = d
        guard parse() else { return nil }
    }

    private func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    private func parse() -> Bool {
        let n = data.count
        guard n > 22 else { return false }
        var eocd = -1
        var i = n - 22
        let lower = max(0, n - 22 - 65_535)
        while i >= lower {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return false }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4B50 else { break }
            let flags = u16(p + 8)
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20)
            let usize = u32(p + 24)
            let nameLen = u16(p + 28)
            let extraLen = u16(p + 30)
            let commentLen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nameLen <= n else { break }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLen))
            let name = (flags & 0x800 != 0 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: csize, size: usize, localOffset: local)
            lowercased[name.lowercased()] = name
            p += 46 + nameLen + extraLen + commentLen
        }
        return !entries.isEmpty
    }

    func entry(_ name: String) -> Entry? {
        if let e = entries[name] { return e }
        if let real = lowercased[name.lowercased()] { return entries[real] }
        return nil
    }

    func read(_ name: String) -> Data? {
        guard let e = entry(name) else { return nil }
        let p = e.localOffset
        guard p + 30 <= data.count, u32(p) == 0x0403_4B50 else { return nil }
        let start = p + 30 + u16(p + 26) + u16(p + 28)
        guard start + e.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8: return Self.inflate(raw, expected: e.size)
        default: return nil
        }
    }

    func text(_ name: String) -> String? {
        guard let d = read(name) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }

    /// Raw DEFLATE (COMPRESSION_ZLIB in Apple's API is raw deflate without a header).
    static func inflate(_ input: Data, expected: Int) -> Data? {
        if expected == 0 { return Data() }
        if input.isEmpty { return nil }
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        if written < expected { out.count = written }
        return out
    }
}
