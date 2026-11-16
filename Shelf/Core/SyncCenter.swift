import Foundation
import SwiftUI

/// Keeps local reading state and the StudyOS web app in step.
@MainActor
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    @Published private(set) var online = false
    @Published private(set) var webDocs: [String: WebDoc] = [:]
    @Published private(set) var webSessions: [WebSession] = []
    @Published private(set) var refreshing = false
    @Published var lastError: String?
    @Published private(set) var lastSync: Date?

    private var progressTasks: [String: Task<Void, Never>] = [:]
    private let client = StudyOSClient.shared

    private init() {
        Task {
            webDocs = await client.allDocs()
            webSessions = await client.webSessions()
        }
    }

    func webDoc(_ path: String) -> WebDoc? { webDocs[path] }

    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        online = await client.isOnline(force: true)
        guard online else { return }
        let stale = (await client.catalogDate ?? .distantPast) < Date().addingTimeInterval(force ? -1 : -3 * 3600)
        if stale || webDocs.isEmpty {
            do {
                try await client.refreshCatalog()
                webDocs = await client.allDocs()
                webSessions = await client.webSessions()
            } catch { lastError = error.localizedDescription }
        }
        await flushAll()
        lastSync = Date()
    }

    // MARK: Opening a book

    struct OpenResult {
        var state: ReadingState
        var remoteJump: RemoteProgress?
    }

    /// Merges the web's progress and highlights into the local state.
    func merge(_ file: BookFile) async -> OpenResult {
        let store = ReadingStore.shared
        var s = store.state(for: file)
        s.lastOpened = Date()
        store.put(s)
        guard let doc = webDocs[file.path] else { return OpenResult(state: s, remoteJump: nil) }
        online = await client.isOnline()
        guard online, let remote = try? await client.remoteState(docId: doc.id) else { return OpenResult(state: s, remoteJump: nil) }

        var jump: RemoteProgress?
        if let rp = remote.progress, rp.position != s.syncedPosition, rp.position != s.position {
            let localDirty = s.updated > (s.syncedAt ?? .distantPast) && s.updated != .distantPast
            if !localDirty {
                apply(rp, to: &s)
            } else {
                jump = rp
            }
            s.syncedPosition = rp.position
        }

        // Highlights and bookmarks: web is the source of truth for anything it already has.
        let remoteIds = Set(remote.highlights.map(\.id))
        s.highlights.removeAll { $0.serverId != nil && !remoteIds.contains($0.serverId!) && !$0.deleted }
        s.bookmarks.removeAll { $0.serverId != nil && !remoteIds.contains($0.serverId!) && !$0.deleted }
        for h in remote.highlights {
            if h.color == "bookmark" {
                if let i = s.bookmarks.firstIndex(where: { $0.serverId == h.id }) {
                    s.bookmarks[i].page = h.page ?? s.bookmarks[i].page
                } else {
                    s.bookmarks.append(Bookmark(serverId: h.id, page: h.page ?? 1, label: h.exact))
                }
            } else if let i = s.highlights.firstIndex(where: { $0.serverId == h.id }) {
                s.highlights[i].comment = h.comment
                s.highlights[i].color = h.color
            } else {
                s.highlights.append(Highlight(serverId: h.id, page: h.page ?? 1, exact: h.exact, prefix: h.prefix, suffix: h.suffix, startOffset: h.startOffset, color: h.color, comment: h.comment))
            }
        }
        store.put(s)
        await pushAnnotations(file.path)
        return OpenResult(state: store.existing(file.path) ?? s, remoteJump: jump)
    }

    func apply(_ rp: RemoteProgress, to s: inout ReadingState) {
        if s.kind == .pdf {
            s.page = rp.page ?? Int(rp.position) ?? s.page
            s.ratio = 0
        } else {
            let parts = rp.position.split(separator: ":")
            if parts.count == 3, parts[0] == "ch", let ch = Int(parts[1]), let r = Double(parts[2]) {
                s.page = ch + 1
                s.ratio = r
            }
        }
        s.percent = rp.percent
        s.syncedAt = Date()
        s.updated = Date()
    }

    // MARK: Pushing

    func progressChanged(_ path: String) {
        progressTasks[path]?.cancel()
        progressTasks[path] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.pushProgress(path)
        }
    }

    func pushProgress(_ path: String) async {
        guard let s = ReadingStore.shared.existing(path), let doc = webDocs[path] else { return }
        guard s.position != s.syncedPosition || s.updated > (s.syncedAt ?? .distantPast) else { return }
        do {
            try await client.saveProgress(docId: doc.id, position: s.position, page: s.page, percent: s.percent)
            ReadingStore.shared.update(path) { $0.syncedPosition = s.position; $0.syncedAt = Date() }
            online = true
        } catch StudyOSError.offline {
            online = false
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pushAnnotations(_ path: String) async {
        guard let doc = webDocs[path], let s = ReadingStore.shared.existing(path) else { return }
        guard await client.isOnline() else { return }
        let unit = s.kind == .pdf ? "쪽" : "장"
        for h in s.highlights {
            do {
                if h.deleted {
                    if let sid = h.serverId { try await client.deleteHighlight(docId: doc.id, id: sid) }
                    ReadingStore.shared.update(path) { $0.highlights.removeAll { $0.id == h.id } }
                } else if h.serverId == nil {
                    let sid = try await client.createHighlight(docId: doc.id, page: h.page, exact: h.exact, prefix: h.prefix, suffix: h.suffix, startOffset: h.startOffset, color: h.color)
                    if let sid {
                        ReadingStore.shared.update(path) { st in
                            if let i = st.highlights.firstIndex(where: { $0.id == h.id }) { st.highlights[i].serverId = sid }
                        }
                        if !h.comment.isEmpty { try await client.updateHighlight(docId: doc.id, id: sid, comment: h.comment) }
                    }
                }
            } catch { lastError = error.localizedDescription }
        }
        for b in s.bookmarks {
            do {
                if b.deleted {
                    if let sid = b.serverId { try await client.deleteHighlight(docId: doc.id, id: sid) }
                    ReadingStore.shared.update(path) { $0.bookmarks.removeAll { $0.id == b.id } }
                } else if b.serverId == nil {
                    let sid = try await client.createHighlight(docId: doc.id, page: b.page, exact: "\(b.page)\(unit)", prefix: "", suffix: "", startOffset: nil, color: "bookmark")
                    if let sid {
                        ReadingStore.shared.update(path) { st in
                            if let i = st.bookmarks.firstIndex(where: { $0.id == b.id }) { st.bookmarks[i].serverId = sid }
                        }
                    }
                }
            } catch { lastError = error.localizedDescription }
        }
    }

    func pushComment(_ path: String, highlightId: String) async {
        guard let doc = webDocs[path], let h = ReadingStore.shared.existing(path)?.highlights.first(where: { $0.id == highlightId }), let sid = h.serverId else { return }
        try? await client.updateHighlight(docId: doc.id, id: sid, comment: h.comment)
    }

    func flushAll() async {
        for s in ReadingStore.shared.states.values where webDocs[s.path] != nil {
            await pushProgress(s.path)
            if s.highlights.contains(where: { $0.serverId == nil || $0.deleted }) || s.bookmarks.contains(where: { $0.serverId == nil || $0.deleted }) {
                await pushAnnotations(s.path)
            }
        }
    }

    // MARK: Sessions

    func startSession(_ path: String) async -> String? {
        guard let doc = webDocs[path] else { return nil }
        return await client.startSession(docId: doc.id, bookId: doc.bookId)
    }

    func finishSession(_ id: String, pages: Int) {
        Task { await client.finishSession(id, pagesRead: pages) }
    }

    func scanWebLibrary() async -> String {
        guard let any = webDocs.values.first else { return "웹 문서 목록이 아직 없어요" }
        do {
            let msg = try await client.scanLibrary(docId: any.id)
            try? await client.refreshCatalog()
            webDocs = await client.allDocs()
            return msg
        } catch { return error.localizedDescription }
    }

    // Web reading time for today (from the last export).
    var webSecondsToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return webSessions.filter { $0.startedAt >= start }.reduce(0) { $0 + $1.focusSeconds }
    }
}
