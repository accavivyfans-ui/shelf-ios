import Foundation

/// A document the StudyOS web app knows about, keyed by its path inside the books folder.
struct WebDoc: Codable, Hashable {
    var id: String
    var bookId: String?
    var kind: String
    var title: String
    var path: String
    var pageCount: Int?
    var coverFile: String?
    var subject: String?
    var level: String?
    var status: String?
}

struct RemoteProgress: Equatable {
    var position: String
    var page: Int?
    var percent: Double
}

struct RemoteHighlight {
    var id: String
    var page: Int?
    var exact: String
    var prefix: String
    var suffix: String
    var startOffset: Int?
    var color: String
    var comment: String
}

struct RemoteState {
    var progress: RemoteProgress?
    var highlights: [RemoteHighlight]
}

struct WebSession: Codable, Hashable {
    var documentId: String?
    var startedAt: Date
    var focusSeconds: Int
    var pagesRead: Int
}

enum StudyOSError: LocalizedError {
    case offline, noAction(String), failed(String)
    var errorDescription: String? {
        switch self {
        case .offline: return "StudyOS 서버에 연결할 수 없어요 (Tailscale 확인)."
        case .noAction(let n): return "웹 앱에서 \(n) 기능을 찾지 못했어요."
        case .failed(let m): return m
        }
    }
}

/// Client for the user's StudyOS (Next.js) server. Progress and highlights go through the
/// same server actions the web reader calls; their ids are read from the web app's own
/// JavaScript, so a rebuilt web app keeps working.
actor StudyOSClient {
    static let shared = StudyOSClient()

    private let session: URLSession
    private var lastCheck: Date = .distantPast
    private var lastOnline = false
    private var actions: [String: String]
    private(set) var docs: [String: WebDoc] = [:]
    private(set) var sessions: [WebSession] = []
    private(set) var catalogDate: Date?

    private struct CatalogCache: Codable { var docs: [WebDoc]; var sessions: [WebSession]?; var date: Date }
    private var cacheURL: URL { Paths.support.appendingPathComponent("studyos-catalog.json") }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        actions = UserDefaults.standard.dictionary(forKey: "studyosActions") as? [String: String] ?? [:]
        if let data = try? Data(contentsOf: Paths.support.appendingPathComponent("studyos-catalog.json")),
           let c = try? JSONDecoder().decode(CatalogCache.self, from: data) {
            docs = Dictionary(c.docs.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            sessions = c.sessions ?? []
            catalogDate = c.date
        }
    }

    private func base() async -> URL? {
        guard await AppSettings.shared.syncEnabled else { return nil }
        return await AppSettings.shared.studyOSURL
    }

    func isOnline(force: Bool = false) async -> Bool {
        if !force, Date().timeIntervalSince(lastCheck) < 20 { return lastOnline }
        guard let base = await base() else { lastOnline = false; return false }
        var req = URLRequest(url: base.appendingPathComponent("api/health"))
        req.timeoutInterval = 4
        let ok = ((try? await session.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
        lastOnline = ok
        lastCheck = Date()
        return ok
    }

    func doc(for path: String) -> WebDoc? { docs[path] }
    func allDocs() -> [String: WebDoc] { docs }
    func webSessions() -> [WebSession] { sessions }

    func coverURL(_ doc: WebDoc) async -> URL? {
        guard let base = await base(), let c = doc.coverFile, !c.isEmpty else { return nil }
        return base.appendingPathComponent("api/covers/\(c)")
    }

    static func relativePath(_ external: String) -> String? {
        let p = external.replacingOccurrences(of: "\\", with: "/")
        if let r = p.range(of: "/books/") { return String(p[r.upperBound...]) }
        return nil
    }

    /// Downloads the web app's export (documents, books, sessions) and keeps a compact copy.
    func refreshCatalog() async throws {
        guard let base = await base(), await isOnline() else { throw StudyOSError.offline }
        var req = URLRequest(url: base.appendingPathComponent("api/export"))
        req.timeoutInterval = 90
        let (data, _) = try await session.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StudyOSError.failed("내보내기 형식이 달라요") }
        var books: [String: [String: Any]] = [:]
        for b in root["books"] as? [[String: Any]] ?? [] { if let id = b["id"] as? String { books[id] = b } }
        var out: [WebDoc] = []
        for d in root["documents"] as? [[String: Any]] ?? [] {
            guard let id = d["id"] as? String, let ext = d["externalPath"] as? String, let rel = Self.relativePath(ext) else { continue }
            let bookId = d["bookId"] as? String
            let b = bookId.flatMap { books[$0] }
            out.append(WebDoc(id: id, bookId: bookId, kind: d["kind"] as? String ?? "pdf", title: (b?["title"] as? String) ?? (d["title"] as? String) ?? rel,
                              path: rel, pageCount: d["pageCount"] as? Int, coverFile: b?["coverFile"] as? String,
                              subject: b?["subject"] as? String, level: b?["level"] as? String, status: b?["status"] as? String))
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var ss: [WebSession] = []
        for s in root["sessions"] as? [[String: Any]] ?? [] where (s["kind"] as? String) == "reading" {
            guard let started = (s["startedAt"] as? String).flatMap({ iso.date(from: $0) }) else { continue }
            ss.append(WebSession(documentId: s["documentId"] as? String, startedAt: started, focusSeconds: s["focusSeconds"] as? Int ?? 0, pagesRead: s["pagesRead"] as? Int ?? 0))
        }
        docs = Dictionary(out.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        sessions = ss
        catalogDate = Date()
        if let enc = try? JSONEncoder().encode(CatalogCache(docs: out, sessions: ss, date: Date())) { try? enc.write(to: cacheURL, options: .atomic) }
    }

    // MARK: Server actions

    private func discoverActions(docId: String) async throws {
        guard let base = await base() else { throw StudyOSError.offline }
        var scripts = Set<String>()
        for path in ["library/\(docId)", "settings", "library"] {
            guard let fetched = try? await session.data(from: base.appendingPathComponent(path)) else { continue }
            let page = String(decoding: fetched.0, as: UTF8.self)
            scripts.formUnion(Self.matches(page, #"/_next/static/[^"']+?\.js"#))
        }
        var found: [String: String] = [:]
        for s in scripts {
            guard let url = URL(string: base.absoluteString + s), let fetched = try? await session.data(from: url) else { continue }
            let text = String(decoding: fetched.0, as: UTF8.self)
            guard text.contains("createServerReference") else { continue }
            let re = try NSRegularExpression(pattern: #"createServerReference\)\("([0-9a-f]+)",[^"]{0,120}"(\w+Action)""#)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let a = Range(m.range(at: 1), in: text), let b = Range(m.range(at: 2), in: text) { found[String(text[b])] = String(text[a]) }
            }
        }
        guard !found.isEmpty else { throw StudyOSError.noAction("진도 저장") }
        actions = found
        UserDefaults.standard.set(found, forKey: "studyosActions")
    }

    private static func matches(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// Calls a Next.js server action and returns its `data` field.
    @discardableResult
    private func action(_ name: String, docId: String, args: [Any], retried: Bool = false) async throws -> Any? {
        guard let base = await base(), await isOnline() else { throw StudyOSError.offline }
        if actions[name] == nil { try await discoverActions(docId: docId) }
        guard let id = actions[name] else { throw StudyOSError.noAction(name) }
        var req = URLRequest(url: base.appendingPathComponent("library/\(docId)"))
        req.httpMethod = "POST"
        req.setValue(id, forHTTPHeaderField: "Next-Action")
        req.setValue("text/x-component", forHTTPHeaderField: "Accept")
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: args)
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(decoding: data, as: UTF8.self)
        var result: [String: Any]?
        for line in text.split(separator: "\n") where line.hasPrefix("1:") {
            result = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(2).utf8))) as? [String: Any]
        }
        if status != 200 || result == nil {
            if !retried {
                actions = [:]
                return try await action(name, docId: docId, args: args, retried: true)
            }
            throw StudyOSError.failed("웹 저장 실패 (\(status))")
        }
        if result?["ok"] as? Bool == false {
            throw StudyOSError.failed((result?["error"] as? String) ?? (result?["message"] as? String) ?? "웹 저장 실패")
        }
        return result?["data"]
    }

    func saveProgress(docId: String, position: String, page: Int, percent: Double) async throws {
        let p = (min(100, max(0, percent)) * 10).rounded() / 10
        try await action("saveReadingProgressAction", docId: docId, args: [docId, ["position": position, "page": max(1, page), "percent": p]])
    }

    func createHighlight(docId: String, page: Int, exact: String, prefix: String, suffix: String, startOffset: Int?, color: String) async throws -> String? {
        var input: [String: Any] = ["documentId": docId, "page": max(1, page), "exact": String(exact.prefix(5000)), "prefix": String(prefix.suffix(200)), "suffix": String(suffix.prefix(200)), "color": color]
        if let startOffset { input["startOffset"] = startOffset }
        let data = try await action("createHighlightAction", docId: docId, args: [input])
        return (data as? [String: Any])?["id"] as? String
    }

    func deleteHighlight(docId: String, id: String) async throws {
        try await action("deleteHighlightAction", docId: docId, args: [id])
    }

    func updateHighlight(docId: String, id: String, comment: String) async throws {
        try await action("updateHighlightAction", docId: docId, args: [id, String(comment.prefix(2000))])
    }

    /// Reads progress and highlights from the reader page's flight data.
    func remoteState(docId: String) async throws -> RemoteState {
        guard let base = await base(), await isOnline() else { throw StudyOSError.offline }
        let (data, _) = try await session.data(from: base.appendingPathComponent("library/\(docId)"))
        let html = String(decoding: data, as: UTF8.self)
        var flight = ""
        let re = try NSRegularExpression(pattern: #"self\.__next_f\.push\(\[1,("(?:[^"\\]|\\.)*")\]\)"#)
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let r = Range(m.range(at: 1), in: html),
                  let s = (try? JSONSerialization.jsonObject(with: Data(html[r].utf8), options: .fragmentsAllowed)) as? String else { continue }
            flight += s
        }
        var progress: RemoteProgress?
        if let obj = Self.jsonValue(after: "\"progress\":", in: flight) as? [String: Any], let pos = obj["position"] as? String {
            progress = RemoteProgress(position: pos, page: obj["page"] as? Int, percent: (obj["percent"] as? NSNumber)?.doubleValue ?? 0)
        }
        var hs: [RemoteHighlight] = []
        if let arr = Self.jsonValue(after: "\"highlights\":", in: flight) as? [[String: Any]] {
            for h in arr {
                guard let id = h["id"] as? String else { continue }
                hs.append(RemoteHighlight(id: id, page: h["page"] as? Int, exact: h["exact"] as? String ?? "", prefix: h["prefix"] as? String ?? "",
                                          suffix: h["suffix"] as? String ?? "", startOffset: h["startOffset"] as? Int,
                                          color: h["color"] as? String ?? "sand", comment: h["comment"] as? String ?? ""))
            }
        }
        return RemoteState(progress: progress, highlights: hs)
    }

    /// Parses the JSON value that follows `key` (first occurrence) by bracket matching.
    static func jsonValue(after key: String, in s: String) -> Any? {
        guard let r = s.range(of: key) else { return nil }
        let chars = Array(s[r.upperBound...].utf8.prefix(2_000_000))
        guard let first = chars.first else { return nil }
        if first == UInt8(ascii: "n") { return nil }
        guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        for (i, c) in chars.enumerated() {
            if inString {
                if escape { escape = false } else if c == UInt8(ascii: "\\") { escape = true } else if c == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 {
                    var text = String(decoding: chars[0...i], as: UTF8.self)
                    // React flight encodes undefined as "$undefined" and strings starting with $ as "$$…".
                    text = text.replacingOccurrences(of: "\"$undefined\"", with: "null")
                    return try? JSONSerialization.jsonObject(with: Data(text.utf8))
                }
            default: break
            }
        }
        return nil
    }

    // MARK: Reading sessions (feed the web's statistics)

    func startSession(docId: String, bookId: String?) async -> String? {
        guard let base = await base(), await isOnline() else { return nil }
        var req = URLRequest(url: base.appendingPathComponent("api/reading-sessions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["documentId": docId]
        if let bookId { body["bookId"] = bookId }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let fetched = try? await session.data(for: req) else { return nil }
        return ((try? JSONSerialization.jsonObject(with: fetched.0)) as? [String: Any])?["id"] as? String
    }

    func finishSession(_ id: String, pagesRead: Int) async {
        guard let base = await base() else { return }
        var req = URLRequest(url: base.appendingPathComponent("api/reading-sessions/\(id)/finish"))
        req.httpMethod = "POST"
        req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pagesRead": min(5000, max(0, pagesRead))])
        _ = try? await session.data(for: req)
    }

    func scanLibrary(docId: String) async throws -> String {
        let data = try await action("scanLibraryAction", docId: docId, args: [])
        if let d = data as? [String: Any] { return "새로 등록 \(d["added"] as? Int ?? 0)권" }
        return "완료"
    }
}
