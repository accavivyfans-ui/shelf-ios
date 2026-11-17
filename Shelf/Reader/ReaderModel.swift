import Foundation
import SwiftUI

struct TocEntry: Identifiable, Hashable {
    var id = UUID()
    var label: String
    var depth: Int
    var page: Int          // PDF page (1-based) or chapter+1
    var fragment: String?
    var pageLabel: String
}

struct SearchHit: Identifiable {
    var id = UUID()
    var page: Int
    var snippet: String
    var payload: Any?
}

/// State and actions shared by the PDF and EPUB readers; the chrome only talks to this.
@MainActor
class ReaderModel: NSObject, ObservableObject {
    let file: BookFile
    @Published var state: ReadingState
    @Published var chromeVisible = true
    @Published var selectionActive = false
    @Published var activeHighlightId: String?
    @Published var remoteJump: RemoteProgress?
    @Published var searchHits: [SearchHit] = []
    @Published var searching = false
    @Published var toast: String?

    /// Pages seen in this sitting, sent to the web as pagesRead.
    var visited: Set<Int> = []

    init(file: BookFile, state: ReadingState) {
        self.file = file
        self.state = state
        super.init()
    }

    // Overridden by the engines.
    var toc: [TocEntry] { [] }
    var pageText: String { "" }
    var detailText: String { "" }
    var canTwoUp: Bool { false }
    var progressFraction: Double { state.percent / 100 }
    func next() {}
    func prev() {}
    func go(_ entry: TocEntry) {}
    func go(page: Int) {}
    func go(fraction: Double) {}
    /// Where a scrub to `fraction` would land, shown live while dragging the slider.
    func scrubLabel(_ fraction: Double) -> String { "\(Int(fraction * 100))%" }
    func go(_ hit: SearchHit) {}
    func search(_ q: String) {}
    func cancelSearch() {}
    func addHighlight(_ color: HighlightColor) {}
    func copySelection() {}
    func clearSelection() {}
    func selectedText() -> String { "" }
    func redrawHighlights() {}
    func applyAppearance() {}
    func applyRemote(_ rp: RemoteProgress) {}
    var currentBookmark: Bookmark? { nil }
    func toggleBookmark() {}
    func goBookmark(_ b: Bookmark) { go(page: b.page) }
    func goHighlight(_ h: Highlight) { go(page: h.page) }
    func didAppear() {}

    // MARK: Shared bookkeeping

    func record(page: Int, pageCount: Int, ratio: Double = 0, percent: Double) {
        let newPercent = (percent * 10).rounded() / 10
        let changed = page != state.page || abs(ratio - state.ratio) > 0.0001 || pageCount != state.pageCount || abs(newPercent - state.percent) > 0.05
        ReadingStore.shared.logPage(state.path, page * 1000 + Int(ratio * 100))
        state.page = page
        state.pageCount = pageCount
        state.ratio = ratio
        state.percent = (percent * 10).rounded() / 10
        if state.percent >= 99 { state.finished = true }
        visited.insert(page * 1000 + Int(ratio * 100))
        guard changed else { return }
        state.updated = Date()
        state.lastOpened = Date()
        ReadingStore.shared.put(state)
        SyncCenter.shared.progressChanged(state.path)
    }

    func saveAnnotations() {
        var s = ReadingStore.shared.existing(state.path) ?? state
        s.highlights = state.highlights
        s.bookmarks = state.bookmarks
        ReadingStore.shared.put(s)
        let path = state.path
        Task { await SyncCenter.shared.pushAnnotations(path); self.reloadAnnotationIds() }
    }

    /// Picks up server ids assigned while syncing.
    func reloadAnnotationIds() {
        guard let s = ReadingStore.shared.existing(state.path) else { return }
        state.highlights = s.highlights
        state.bookmarks = s.bookmarks
    }

    var activeHighlight: Highlight? {
        guard let id = activeHighlightId else { return nil }
        return state.highlights.first { $0.id == id }
    }

    func setColor(_ color: HighlightColor, for id: String) {
        guard let i = state.highlights.firstIndex(where: { $0.id == id }) else { return }
        // The web has no colour update, so re-create the highlight there.
        var h = state.highlights[i]
        if h.serverId != nil {
            var old = h
            old.deleted = true
            state.highlights[i] = old
            h.id = UUID().uuidString
            h.serverId = nil
            h.color = color.rawValue
            state.highlights.append(h)
            activeHighlightId = h.id
        } else {
            state.highlights[i].color = color.rawValue
        }
        redrawHighlights()
        saveAnnotations()
    }

    func setComment(_ text: String, for id: String) {
        guard let i = state.highlights.firstIndex(where: { $0.id == id }) else { return }
        state.highlights[i].comment = text
        let s = state
        var stored = ReadingStore.shared.existing(s.path) ?? s
        stored.highlights = s.highlights
        ReadingStore.shared.put(stored)
        let path = s.path
        Task {
            if s.highlights[i].serverId == nil { await SyncCenter.shared.pushAnnotations(path) }
            await SyncCenter.shared.pushComment(path, highlightId: id)
        }
    }

    func deleteHighlight(_ id: String) {
        guard let i = state.highlights.firstIndex(where: { $0.id == id }) else { return }
        state.highlights[i].deleted = true
        if activeHighlightId == id { activeHighlightId = nil }
        redrawHighlights()
        saveAnnotations()
    }

    func deleteBookmark(_ id: String) {
        guard let i = state.bookmarks.firstIndex(where: { $0.id == id }) else { return }
        state.bookmarks[i].deleted = true
        saveAnnotations()
    }

    func showToast(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == s { toast = nil }
        }
    }

    static func anchorContext(_ text: NSString, _ range: NSRange) -> (exact: String, prefix: String, suffix: String) {
        let exact = text.substring(with: range)
        let pStart = max(0, range.location - 32)
        let prefix = text.substring(with: NSRange(location: pStart, length: range.location - pStart))
        let end = range.location + range.length
        let suffix = text.substring(with: NSRange(location: end, length: min(32, text.length - end)))
        return (exact, prefix, suffix)
    }

    /// Finds a text-quote anchor in page text, tolerating whitespace differences between
    /// PDF.js (web) and PDFKit text extraction.
    static func locate(_ h: Highlight, in text: String) -> NSRange? {
        let ns = text as NSString
        guard !h.exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ns.length > 0 else { return nil }
        var candidates: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: h.exact, options: [], range: search)
            if r.location == NSNotFound { break }
            candidates.append(r)
            let next = r.location + 1
            search = NSRange(location: next, length: ns.length - next)
        }
        if candidates.isEmpty {
            let chars = h.exact.filter { !$0.isWhitespace }.prefix(600)
            let pattern = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
            if let re = try? NSRegularExpression(pattern: pattern) {
                candidates = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            }
        }
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        func squash(_ s: String) -> String { s.filter { !$0.isWhitespace } }
        let pre = squash(h.prefix)
        let suf = squash(h.suffix)
        func score(_ r: NSRange) -> Int {
            let before = squash(ns.substring(with: NSRange(location: max(0, r.location - 64), length: r.location - max(0, r.location - 64))))
            let afterStart = r.location + r.length
            let after = squash(ns.substring(with: NSRange(location: afterStart, length: min(64, ns.length - afterStart))))
            var a = 0
            while a < pre.count, a < before.count, pre[pre.index(pre.endIndex, offsetBy: -1 - a)] == before[before.index(before.endIndex, offsetBy: -1 - a)] { a += 1 }
            var b = 0
            while b < suf.count, b < after.count, suf[suf.index(suf.startIndex, offsetBy: b)] == after[after.index(after.startIndex, offsetBy: b)] { b += 1 }
            return a + b
        }
        return candidates.max { l, r in
            let sl = score(l), sr = score(r)
            if sl != sr { return sl < sr }
            let o = h.startOffset ?? 0
            return abs(l.location - o) > abs(r.location - o)
        }
    }
}
