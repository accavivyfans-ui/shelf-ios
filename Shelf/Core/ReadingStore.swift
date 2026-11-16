import Foundation
import SwiftUI
import UIKit

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case sand, sage, rose, sky
    var id: String { rawValue }
    var uiColor: UIColor {
        switch self {
        case .sand: return UIColor(red: 0.94, green: 0.78, blue: 0.32, alpha: 1)
        case .sage: return UIColor(red: 0.47, green: 0.72, blue: 0.42, alpha: 1)
        case .rose: return UIColor(red: 0.93, green: 0.48, blue: 0.55, alpha: 1)
        case .sky: return UIColor(red: 0.42, green: 0.65, blue: 0.92, alpha: 1)
        }
    }
    var color: Color { Color(uiColor) }
    var css: String {
        switch self {
        case .sand: return "rgba(240,199,82,0.45)"
        case .sage: return "rgba(120,184,107,0.42)"
        case .rose: return "rgba(237,122,140,0.40)"
        case .sky: return "rgba(107,166,235,0.40)"
        }
    }
}

/// A highlight in the same text-quote form the StudyOS web reader uses.
/// `page` is the 1-based PDF page, or chapter+1 for EPUB.
struct Highlight: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var serverId: String?
    var page: Int
    var exact: String
    var prefix: String = ""
    var suffix: String = ""
    var startOffset: Int?
    var color: String = HighlightColor.sand.rawValue
    var comment: String = ""
    var created: Date = Date()
    var deleted = false

    var tint: HighlightColor { HighlightColor(rawValue: color) ?? .sand }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var serverId: String?
    var page: Int          // PDF page or chapter+1
    var ratio: Double = 0  // EPUB position inside the chapter
    var label: String
    var created: Date = Date()
    var deleted = false
}

struct ReadingState: Codable, Identifiable {
    var path: String
    var fileId: String
    var title: String
    var kind: BookKind
    var size: Int64 = 0

    var page: Int = 1            // PDF page (1-based) / EPUB chapter+1
    var pageCount: Int = 0       // PDF pages / EPUB chapters
    var ratio: Double = 0        // EPUB ratio in chapter
    var percent: Double = 0
    var lastOpened: Date = Date()
    var updated: Date = .distantPast
    var finished = false

    var highlights: [Highlight] = []
    var bookmarks: [Bookmark] = []

    /// Position the server is known to hold, so remote changes can be told apart from ours.
    var syncedPosition: String?
    var syncedAt: Date?

    var id: String { path }

    var position: String {
        kind == .pdf ? String(page) : "ch:\(max(0, page - 1)):\((ratio * 1000).rounded() / 1000)"
    }

    var file: BookFile { BookFile(id: fileId, path: path, size: size, modified: 0) }
    var liveHighlights: [Highlight] { highlights.filter { !$0.deleted } }
    var liveBookmarks: [Bookmark] { bookmarks.filter { !$0.deleted } }
}

struct DayLog: Codable {
    var seconds: Double = 0
    var pages: Set<String> = []
}

@MainActor
final class ReadingStore: ObservableObject {
    static let shared = ReadingStore()

    @Published private(set) var states: [String: ReadingState] = [:]
    @Published private(set) var days: [String: DayLog] = [:]

    private var url: URL { Paths.support.appendingPathComponent("reading.json") }
    private var daysURL: URL { Paths.support.appendingPathComponent("days.json") }
    private var saveTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([String: ReadingState].self, from: data) { states = s }
        if let data = try? Data(contentsOf: daysURL), let d = try? JSONDecoder().decode([String: DayLog].self, from: data) { days = d }
    }

    func state(for file: BookFile) -> ReadingState {
        if var s = states[file.path] {
            if s.fileId != file.id { s.fileId = file.id }
            return s
        }
        return ReadingState(path: file.path, fileId: file.id, title: file.title, kind: file.kind ?? .pdf, size: file.size)
    }

    func existing(_ path: String) -> ReadingState? { states[path] }

    func update(_ path: String, _ change: (inout ReadingState) -> Void) {
        guard var s = states[path] else { return }
        change(&s)
        states[path] = s
        scheduleSave()
    }

    func put(_ s: ReadingState) {
        states[s.path] = s
        scheduleSave()
    }

    func forget(_ path: String) {
        states[path] = nil
        scheduleSave()
    }

    var recent: [ReadingState] {
        states.values.sorted { $0.lastOpened > $1.lastOpened }
    }

    // Reading time per day for the home screen.
    static func dayKey(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func logTime(_ seconds: Double) {
        guard seconds > 0, seconds < 4 * 3600 else { return }
        days[Self.dayKey(), default: DayLog()].seconds += seconds
        scheduleSave()
    }

    func logPage(_ path: String, _ page: Int) {
        let key = Self.dayKey()
        let id = "\(path)#\(page)"
        if days[key]?.pages.contains(id) == true { return }
        days[key, default: DayLog()].pages.insert(id)
        scheduleSave()
    }

    var streak: Int {
        var n = 0
        var d = Date()
        if (days[Self.dayKey(d)]?.seconds ?? 0) < 60 { d = d.addingTimeInterval(-86400) }
        while (days[Self.dayKey(d)]?.seconds ?? 0) >= 60 { n += 1; d = d.addingTimeInterval(-86400) }
        return n
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(states) { try? data.write(to: url, options: .atomic) }
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: daysURL, options: .atomic) }
    }
}
