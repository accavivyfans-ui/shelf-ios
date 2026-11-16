import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

/// NAS account kept in the Keychain. The share link stays read-only; uploads and deletes use this login.
enum NasKeychain {
    private static let service = "com.personal.shelf.nas"

    static func load() -> (account: String, password: String)? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let item = out as? [String: Any],
              let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        return (account, password)
    }

    static func save(account: String, password: String) {
        clear()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(password.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

enum NasError: LocalizedError {
    case notLoggedIn, login(Int), api(Int, String?), http(Int), task(String)
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "NAS 계정으로 로그인해야 올리거나 지울 수 있어요."
        case .login(let c):
            switch c {
            case 400: return "아이디나 비밀번호가 틀렸어요."
            case 401: return "비활성화된 계정이에요."
            case 402: return "이 계정은 권한이 없어요."
            case 403, 404, 406: return "2단계 인증이 켜져 있어 로그인하지 못했어요."
            case 407: return "로그인 시도가 많아 NAS가 이 IP를 막았어요. 잠시 뒤 다시 해 주세요."
            default: return "로그인 실패 (\(c))"
            }
        case .api(let c, let m): return "NAS 작업 실패 (\(c)\(m.map { ": \($0)" } ?? ""))"
        case .http(let c): return "NAS 연결 오류 (HTTP \(c))"
        case .task(let m): return m
        }
    }
}

/// Logged-in Synology Drive calls: upload into a folder and move files to the Drive recycle bin.
/// Formats verified against the NAS (DSM Drive): upload takes raw multipart fields
/// path="id:<folder>/<name>", type=file, conflict_action=version; delete returns an async task.
actor NasClient {
    static let shared = NasClient()

    private var sid: String?
    private let session: URLSession

    init() {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = HTTPCookieStorage()
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: c)
    }

    private func base() async throws -> URL {
        guard let s = await AppSettings.shared.share else { throw DriveError.noShare }
        return s.base.appendingPathComponent("webapi/entry.cgi")
    }

    func logout() { sid = nil }

    /// Logs in with the given account (or the saved one) and returns the session id.
    @discardableResult
    func login(account: String? = nil, password: String? = nil) async throws -> String {
        let creds: (String, String)
        if let account, let password { creds = (account, password) }
        else if let saved = NasKeychain.load() { creds = (saved.account, saved.password) }
        else { throw NasError.notLoggedIn }
        let json = try await post([
            "api": "SYNO.API.Auth", "version": "6", "method": "login",
            "account": creds.0, "passwd": creds.1, "session": "SynologyDrive", "format": "sid",
        ])
        guard json["success"] as? Bool == true, let s = (json["data"] as? [String: Any])?["sid"] as? String else {
            throw NasError.login(Self.code(json))
        }
        sid = s
        return s
    }

    private func currentSid() async throws -> String {
        if let sid { return sid }
        return try await login()
    }

    private static func code(_ json: [String: Any]) -> Int { (json["error"] as? [String: Any])?["code"] as? Int ?? -1 }
    private static func message(_ json: [String: Any]) -> String? {
        ((json["error"] as? [String: Any])?["errors"] as? [String: Any])?["message"] as? String
    }
    /// 105/106/107/119: session missing, expired or kicked out → log in again once.
    private static func isSessionError(_ c: Int) -> Bool { [105, 106, 107, 119].contains(c) }

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: try await base())
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = params.map { "\($0.key)=\($0.value.formEncoded)" }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw NasError.http(h.statusCode) }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func call(_ params: [String: String], retry: Bool = true) async throws -> [String: Any] {
        var p = params
        p["_sid"] = try await currentSid()
        let json = try await post(p)
        if json["success"] as? Bool == true { return json["data"] as? [String: Any] ?? [:] }
        let c = Self.code(json)
        if retry, Self.isSessionError(c) { sid = nil; return try await call(params, retry: false) }
        throw NasError.api(c, Self.message(json))
    }

    /// Uploads a local file into the Drive folder `folderId` as `name`. Returns the new file's id and size.
    func upload(file: URL, name: String, folderId: String, progress: @escaping @Sendable (Double) -> Void, retry: Bool = true) async throws -> DriveItem {
        let s = try await currentSid()
        var comps = URLComponents(url: try await base(), resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "api", value: "SYNO.SynologyDrive.Files"), .init(name: "method", value: "upload"),
                            .init(name: "version", value: "2"), .init(name: "_sid", value: s)]
        let boundary = "shelf-" + UUID().uuidString
        let body = FileManager.default.temporaryDirectory.appendingPathComponent(boundary)
        defer { try? FileManager.default.removeItem(at: body) }
        try Self.writeMultipart(to: body, boundary: boundary, fields: [
            ("path", "id:\(folderId)/\(name)"), ("type", "file"), ("conflict_action", "version"),
        ], file: file)

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgress(progress)
        let (data, resp) = try await session.upload(for: req, fromFile: body, delegate: delegate)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw NasError.http(h.statusCode) }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard json["success"] as? Bool == true, let d = json["data"] as? [String: Any], let id = d["file_id"] as? String else {
            let c = Self.code(json)
            if retry, Self.isSessionError(c) {
                sid = nil
                return try await upload(file: file, name: name, folderId: folderId, progress: progress, retry: false)
            }
            throw NasError.api(c, Self.message(json))
        }
        return DriveItem(id: id, name: d["name"] as? String ?? name, isDir: false,
                         size: (d["size"] as? NSNumber)?.int64Value ?? 0, modified: (d["modified_time"] as? NSNumber)?.intValue ?? 0)
    }

    private static func writeMultipart(to url: URL, boundary: String, fields: [(String, String)], file: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        var head = ""
        for (k, v) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        // The server names the file from `path`; keep the part's filename ASCII.
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// Moves files to the Drive recycle bin (recoverable from Synology Drive) and waits for the task.
    func delete(ids: [String]) async throws {
        let files = "[" + ids.map { "id:\($0)".jsonQuoted }.joined(separator: ",") + "]"
        let d = try await call(["api": "SYNO.SynologyDrive.Files", "method": "delete", "version": "2",
                                "files": files, "permanent": "false"])
        guard let task = d["async_task_id"] as? String else { return }
        for _ in 0..<120 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let t = try await call(["api": "SYNO.SynologyDrive.Tasks", "method": "get", "version": "1", "task_id": task.jsonQuoted])
            if t["status"] as? String == "finished" {
                if let errs = (t["result"] as? [String: Any])?["errors"] as? [Any], !errs.isEmpty {
                    throw NasError.task("일부 파일을 지우지 못했어요.")
                }
                return
            }
        }
        throw NasError.task("NAS에서 삭제가 오래 걸리고 있어요. 잠시 뒤 목록을 새로고침해 보세요.")
    }

    /// Lists a folder with the login (used to find folder ids the cached index doesn't have).
    func listFolders(_ id: String) async throws -> [DriveItem] {
        let d = try await call(["api": "SYNO.SynologyDrive.Files", "method": "list", "version": "2",
                                "path": "id:\(id)".jsonQuoted, "offset": "0", "limit": "1000"])
        return (d["items"] as? [[String: Any]] ?? []).compactMap { it in
            guard let fid = it["file_id"] as? String, let name = it["name"] as? String, (it["type"] as? String) == "dir" else { return nil }
            return DriveItem(id: fid, name: name, isDir: true, size: 0, modified: 0)
        }
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ r: @escaping @Sendable (Double) -> Void) { report = r }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - App-side state for uploads and deletes

@MainActor
final class NasOps: ObservableObject {
    static let shared = NasOps()

    @Published private(set) var account: String? = NasKeychain.load()?.account
    @Published var showLogin = false
    @Published var pendingDelete: BookFile?
    @Published private(set) var uploads: [Upload] = []
    @Published var message: String?
    /// One file picker for the whole app (a picker inside a toolbar button never reports the chosen files).
    @Published var picking = false
    private(set) var pickTarget = ""

    func pickFiles(into folder: String) {
        guard loggedIn else { showLogin = true; return }
        pickTarget = folder
        picking = true
    }

    func picked(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): upload(urls, to: pickTarget)
        case .failure(let e): message = "파일을 열지 못했어요: \(e.localizedDescription)"
        }
    }

    struct Upload: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var progress: Double = 0
        var failed: String?
    }

    var loggedIn: Bool { account != nil }

    func login(account: String, password: String) async throws {
        try await NasClient.shared.login(account: account, password: password)
        NasKeychain.save(account: account, password: password)
        self.account = account
    }

    func logout() {
        NasKeychain.clear()
        account = nil
        Task { await NasClient.shared.logout() }
    }

    /// Uploads picked files (security-scoped URLs from the Files picker) into a books-relative folder.
    func upload(_ urls: [URL], to folder: String) {
        guard loggedIn else { showLogin = true; return }
        if urls.isEmpty { message = "선택한 파일이 없어요." }
        for url in urls {
            let name = url.lastPathComponent
            var item = Upload(name: name)
            // Copy now, while the picker's permission is valid (it can end once the picker is gone).
            let scoped = url.startAccessingSecurityScopedResource()
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            var copy: URL?
            do {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    throw NasError.task("이 EPUB은 폴더 형태라 올릴 수 없어요. 책 앱이 아닌 다른 곳에서 받은 .epub 파일을 골라 주세요.")
                }
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                let target = local.appendingPathComponent(name)
                try FileManager.default.copyItem(at: url, to: target)
                copy = target
            } catch {
                item.failed = error.localizedDescription
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
            uploads.append(item)
            guard let copy else { continue }
            let id = item.id
            Task {
                defer { try? FileManager.default.removeItem(at: local) }
                do {
                    let folderId = try await Catalog.shared.folderId(for: folder)
                    let done = try await NasClient.shared.upload(file: copy, name: name, folderId: folderId) { p in
                        Task { @MainActor in NasOps.shared.setProgress(id, p) }
                    }
                    let path = folder.isEmpty ? done.name : folder + "/" + done.name
                    Catalog.shared.insert(BookFile(id: done.id, path: path, size: done.size, modified: done.modified))
                    uploads.removeAll { $0.id == id }
                    message = "‘\(done.name)’ 올렸어요."
                } catch {
                    if let i = uploads.firstIndex(where: { $0.id == id }) { uploads[i].failed = error.localizedDescription }
                    if case NasError.notLoggedIn = error { showLogin = true }
                }
            }
        }
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        if let i = uploads.firstIndex(where: { $0.id == id }) { uploads[i].progress = p }
    }

    func dismissUpload(_ u: Upload) { uploads.removeAll { $0.id == u.id } }

    func requestDelete(_ f: BookFile) {
        guard loggedIn else { showLogin = true; return }
        pendingDelete = f
    }

    func delete(_ f: BookFile) {
        Task {
            do {
                try await NasClient.shared.delete(ids: [f.id])
                Downloads.shared.delete(f)
                ReadingStore.shared.forget(f.path)
                Catalog.shared.remove(ids: [f.id])
                message = "‘\(f.name)’ 지웠어요. Synology Drive 휴지통에서 되살릴 수 있어요."
            } catch {
                message = error.localizedDescription
                if case NasError.notLoggedIn = error { showLogin = true }
            }
        }
    }
}

struct NasLoginView: View {
    @ObservedObject private var ops = NasOps.shared
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("아이디", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("비밀번호", text: $password).textContentType(.password)
                } footer: {
                    Text("서재에 책을 올리거나 지울 때만 쓰여요. 비밀번호는 이 아이폰의 키체인에만 저장돼요. 지운 파일은 Synology Drive 휴지통으로 가요.")
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Button {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { try await ops.login(account: account, password: password); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                } label: { HStack { Text("로그인"); if busy { Spacer(); ProgressView() } } }
                .disabled(account.isEmpty || password.isEmpty || busy)
            }
            .navigationTitle("NAS 로그인")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }
    }
}

/// Upload progress and results, pinned above the tab bar.
struct NasStatusBar: View {
    @ObservedObject private var ops = NasOps.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(ops.uploads) { u in
                HStack(spacing: 10) {
                    Image(systemName: u.failed == nil ? "arrow.up.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(u.failed == nil ? Color.orange : Color.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(u.name).font(.caption.weight(.medium)).lineLimit(1)
                        if let f = u.failed { Text(f).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                        else { ProgressView(value: u.progress) }
                    }
                    if u.failed != nil {
                        Button { ops.dismissUpload(u) } label: { Image(systemName: "xmark") }.font(.caption)
                    }
                }
            }
            if let m = ops.message {
                HStack {
                    Text(m).font(.caption).lineLimit(2)
                    Spacer()
                    Button { ops.message = nil } label: { Image(systemName: "xmark") }.font(.caption)
                }
                .task(id: m) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if ops.message == m { ops.message = nil }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, ops.uploads.isEmpty && ops.message == nil ? 0 : 10)
        .background {
            if !(ops.uploads.isEmpty && ops.message == nil) {
                RoundedRectangle(cornerRadius: 14).fill(.regularMaterial).shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 56)
        .animation(.default, value: ops.uploads)
        .animation(.default, value: ops.message)
    }
}

/// "올리기" toolbar button: Files picker for PDF/EPUB into `folder` (books-relative path).
struct UploadButton: View {
    let folder: String
    @ObservedObject private var ops = NasOps.shared

    var body: some View {
        Button { ops.pickFiles(into: folder) } label: { Image(systemName: "square.and.arrow.up") }
        .accessibilityLabel("이 폴더에 올리기")
    }
}
