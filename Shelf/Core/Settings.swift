import Foundation
import SwiftUI

/// A Synology Drive public share link: http://host:port/d/s/<permanent>/<sharing>
struct ShareLink: Codable, Equatable {
    var base: URL
    var permanent: String
    var sharing: String

    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, let scheme = url.scheme else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "s"), i > 0, parts[i - 1] == "d", parts.count >= i + 3 else { return nil }
        permanent = parts[i + 1]
        sharing = parts[i + 2]
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = url.port
        guard let b = c.url else { return nil }
        base = b
    }

    var pageURL: URL { base.appendingPathComponent("d/s/\(permanent)/\(sharing)") }
    var text: String { pageURL.absoluteString }
}

enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case light, sepia, gray, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .light: return "밝게"; case .sepia: return "세피아"; case .gray: return "차분하게"; case .dark: return "어둡게" }
    }
    var paper: Color {
        switch self {
        case .light: return Color(red: 1, green: 1, blue: 1)
        case .sepia: return Color(red: 0.97, green: 0.93, blue: 0.84)
        case .gray: return Color(red: 0.36, green: 0.36, blue: 0.38)
        case .dark: return Color(red: 0.07, green: 0.07, blue: 0.08)
        }
    }
    var ink: Color {
        switch self {
        case .light: return .black
        case .sepia: return Color(red: 0.31, green: 0.22, blue: 0.12)
        case .gray: return Color(white: 0.92)
        case .dark: return Color(white: 0.86)
        }
    }
    var css: (bg: String, fg: String, link: String) {
        switch self {
        case .light: return ("#ffffff", "#141414", "#1f5fbf")
        case .sepia: return ("#f8eed7", "#4f3820", "#8a4b12")
        case .gray: return ("#5c5c61", "#ececec", "#9cc4ff")
        case .dark: return ("#121214", "#dcdcdc", "#8ab4f8")
        }
    }
    var isDark: Bool { self == .gray || self == .dark }
}

enum PDFLayout: String, Codable, CaseIterable, Identifiable {
    case paged, vertical, twoUp
    var id: String { rawValue }
    var label: String {
        switch self { case .paged: return "넘기기"; case .vertical: return "스크롤"; case .twoUp: return "두 쪽" }
    }
    var icon: String {
        switch self { case .paged: return "book.pages"; case .vertical: return "scroll"; case .twoUp: return "book" }
    }
}

enum EpubFont: String, Codable, CaseIterable, Identifiable {
    case publisher, myungjo, gothic
    var id: String { rawValue }
    var label: String {
        switch self { case .publisher: return "원본"; case .myungjo: return "명조"; case .gothic: return "고딕" }
    }
    var css: String {
        switch self {
        case .publisher: return ""
        case .myungjo: return "'AppleMyungjo', 'Nanum Myeongjo', serif"
        case .gothic: return "-apple-system, 'Apple SD Gothic Neo', sans-serif"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var share: ShareLink? { didSet { save() } }
    @Published var studyOSAddress: String { didSet { save() } }
    @Published var syncEnabled: Bool { didSet { save() } }
    @Published var theme: ReaderTheme { didSet { save() } }
    @Published var pdfLayout: PDFLayout { didSet { save() } }
    @Published var tapToTurn: Bool { didSet { save() } }
    @Published var keepAwake: Bool { didSet { save() } }
    @Published var epubFont: EpubFont { didSet { save() } }
    @Published var epubFontSize: Double { didSet { save() } }
    @Published var epubLineHeight: Double { didSet { save() } }
    @Published var epubMargin: Double { didSet { save() } }
    @Published var gridStyle: Bool { didSet { save() } }

    private var loading = true

    private init() {
        if let data = d.data(forKey: "share"), let s = try? JSONDecoder().decode(ShareLink.self, from: data) { share = s }
        else { share = ProcessInfo.processInfo.environment["SHELF_SHARE"].flatMap { ShareLink(string: $0) } }
        studyOSAddress = d.string(forKey: "studyOS") ?? "http://100.84.240.95:3000"
        syncEnabled = ProcessInfo.processInfo.environment["SHELF_NOSYNC"] != nil ? false : (d.object(forKey: "sync") as? Bool ?? true)
        theme = ReaderTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .light
        pdfLayout = PDFLayout(rawValue: d.string(forKey: "pdfLayout") ?? "") ?? .paged
        tapToTurn = d.object(forKey: "tapToTurn") as? Bool ?? true
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        epubFont = EpubFont(rawValue: d.string(forKey: "epubFont") ?? "") ?? .myungjo
        epubFontSize = d.object(forKey: "epubFontSize") as? Double ?? 18
        epubLineHeight = d.object(forKey: "epubLineHeight") as? Double ?? 1.7
        epubMargin = d.object(forKey: "epubMargin") as? Double ?? 24
        gridStyle = d.object(forKey: "gridStyle") as? Bool ?? true
        loading = false
    }

    private func save() {
        guard !loading else { return }
        if let share, let data = try? JSONEncoder().encode(share) { d.set(data, forKey: "share") } else { d.removeObject(forKey: "share") }
        d.set(studyOSAddress, forKey: "studyOS")
        d.set(syncEnabled, forKey: "sync")
        d.set(theme.rawValue, forKey: "theme")
        d.set(pdfLayout.rawValue, forKey: "pdfLayout")
        d.set(tapToTurn, forKey: "tapToTurn")
        d.set(keepAwake, forKey: "keepAwake")
        d.set(epubFont.rawValue, forKey: "epubFont")
        d.set(epubFontSize, forKey: "epubFontSize")
        d.set(epubLineHeight, forKey: "epubLineHeight")
        d.set(epubMargin, forKey: "epubMargin")
        d.set(gridStyle, forKey: "gridStyle")
    }

    var studyOSURL: URL? {
        var s = studyOSAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

enum Paths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var books: URL {
        let u = support.appendingPathComponent("Books", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            var v = u
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? v.setResourceValues(values)
        }
        return u
    }
    static var covers: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

extension String {
    /// Percent-encodes everything except unreserved characters (RFC 3986) for query/form values.
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
    var jsonQuoted: String {
        let data = try? JSONSerialization.data(withJSONObject: [self])
        guard let data, let s = String(data: data, encoding: .utf8) else { return "\"\(self)\"" }
        return String(s.dropFirst().dropLast())
    }
}
