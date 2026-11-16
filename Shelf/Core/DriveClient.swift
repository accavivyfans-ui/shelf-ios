import Foundation

struct DriveItem: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var isDir: Bool
    var size: Int64
    var modified: Int
}

enum DriveError: LocalizedError {
    case noShare, noToken, api(Int), http(Int)
    var errorDescription: String? {
        switch self {
        case .noShare: return "공유 링크가 설정되지 않았어요."
        case .noToken: return "공유 링크에 접속하지 못했어요. 링크가 만료됐는지 확인해 주세요."
        case .api(let c): return "NAS 응답 오류 (\(c))"
        case .http(let c): return "NAS 연결 오류 (HTTP \(c))"
        }
    }
}

/// Talks to a Synology Drive public share link with the same sharing token the web UI uses.
actor DriveClient {
    static let shared = DriveClient()

    private var token: String?
    private var tokenShare: ShareLink?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    private func share() async throws -> ShareLink {
        guard let s = await AppSettings.shared.share else { throw DriveError.noShare }
        return s
    }

    func currentToken() async throws -> String {
        let s = try await share()
        if let token, tokenShare == s { return token }
        return try await refreshToken(s)
    }

    private func refreshToken(_ s: ShareLink) async throws -> String {
        let (_, response) = try await session.data(from: s.pageURL)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 { throw DriveError.http(http.statusCode) }
        let cookies = session.configuration.httpCookieStorage?.cookies(for: s.pageURL) ?? []
        var found = cookies.first(where: { $0.name == "drive-sharing-\(s.sharing)" })?.value
        if found == nil, let http = response as? HTTPURLResponse, let header = http.value(forHTTPHeaderField: "Set-Cookie") {
            let key = "drive-sharing-\(s.sharing)="
            if let r = header.range(of: key) {
                found = String(header[r.upperBound...].prefix { $0 != ";" && $0 != "," })
            }
        }
        guard let t = found, !t.isEmpty else { throw DriveError.noToken }
        token = t
        tokenShare = s
        return t
    }

    private func call(_ params: [String: String], retry: Bool = true) async throws -> [String: Any] {
        let s = try await share()
        let t = try await currentToken()
        var all = params
        all["sharing_token"] = t.jsonQuoted
        var req = URLRequest(url: s.base.appendingPathComponent("webapi/entry.cgi"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = all.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            if retry { token = nil; return try await call(params, retry: false) }
            throw DriveError.http(http.statusCode)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if json["success"] as? Bool == true { return json["data"] as? [String: Any] ?? [:] }
        let code = (json["error"] as? [String: Any])?["code"] as? Int ?? -1
        if retry { token = nil; return try await call(params, retry: false) }
        throw DriveError.api(code)
    }

    /// Lists a folder. `path` is "id:<file_id>" or nil for the share root.
    func list(_ id: String?) async throws -> [DriveItem] {
        let s = try await share()
        let path = id.map { "id:\($0)" } ?? "link:\(s.permanent)"
        var out: [DriveItem] = []
        var offset = 0
        while true {
            let data = try await call([
                "api": "SYNO.SynologyDrive.Files", "method": "list", "version": "2",
                "path": path.jsonQuoted, "offset": "\(offset)", "limit": "1000",
                "sort_by": "\"name\"", "sort_direction": "\"asc\"",
            ])
            let items = data["items"] as? [[String: Any]] ?? []
            for it in items {
                guard let fid = it["file_id"] as? String, let name = it["name"] as? String else { continue }
                let size = (it["size"] as? NSNumber)?.int64Value ?? 0
                let mod = (it["modified_time"] as? NSNumber)?.intValue ?? 0
                out.append(DriveItem(id: fid, name: name, isDir: (it["type"] as? String) == "dir", size: size, modified: mod))
            }
            offset += items.count
            let total = (data["total"] as? NSNumber)?.intValue ?? offset
            if items.isEmpty || offset >= total { break }
        }
        return out
    }

    func downloadURL(id: String, name: String) async throws -> URL {
        let s = try await share()
        let t = try await currentToken()
        let safeName = name.formEncoded
        let q = [
            "api=SYNO.SynologyDrive.Files", "method=download", "version=2",
            "files=" + "[\("id:\(id)".jsonQuoted)]".formEncoded,
            "sharing_token=" + t.jsonQuoted.formEncoded,
        ].joined(separator: "&")
        guard let url = URL(string: s.base.absoluteString + "/webapi/entry.cgi/" + safeName + "?" + q) else { throw DriveError.noShare }
        return url
    }

    func invalidateToken() { token = nil }
}
