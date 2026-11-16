import Foundation
import SwiftUI

/// Downloads books into Application Support so they open instantly and work offline.
@MainActor
final class Downloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = Downloads()

    @Published private(set) var progress: [String: Double] = [:]   // fileId → 0…1
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var revision = 0

    private var session: URLSession!
    private var tasks: [Int: (BookFile, [CheckedContinuation<URL, Error>])] = [:]
    private var waiting: [String: [CheckedContinuation<URL, Error>]] = [:]

    override private init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func localURL(_ f: BookFile) -> URL {
        let ext = (f.name as NSString).pathExtension.lowercased()
        return Paths.books.appendingPathComponent("\(f.id).\(ext.isEmpty ? "bin" : ext)")
    }

    func isDownloaded(_ f: BookFile) -> Bool { FileManager.default.fileExists(atPath: localURL(f).path) }

    var downloadedBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.books, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func downloadedIds() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.books.path)) ?? []
        return Set(files.map { ($0 as NSString).deletingPathExtension })
    }

    func delete(_ f: BookFile) {
        try? FileManager.default.removeItem(at: localURL(f))
        revision += 1
    }

    func cancel(_ f: BookFile) {
        for (id, entry) in tasks where entry.0.id == f.id {
            session.getAllTasks { all in all.first { $0.taskIdentifier == id }?.cancel() }
        }
    }

    /// Returns the local file, downloading it first if needed.
    func fetch(_ f: BookFile) async throws -> URL {
        let dest = localURL(f)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        return try await withCheckedThrowingContinuation { cont in
            if waiting[f.id] != nil {
                waiting[f.id]?.append(cont)
                return
            }
            waiting[f.id] = [cont]
            progress[f.id] = 0
            failures[f.id] = nil
            Task {
                do {
                    let url = try await DriveClient.shared.downloadURL(id: f.id, name: f.name)
                    let task = self.session.downloadTask(with: url)
                    self.tasks[task.taskIdentifier] = (f, [])
                    task.resume()
                } catch {
                    self.finish(f, .failure(error))
                }
            }
        }
    }

    private func finish(_ f: BookFile, _ result: Result<URL, Error>) {
        progress[f.id] = nil
        if case .failure(let e) = result { failures[f.id] = e.localizedDescription }
        for c in waiting[f.id] ?? [] { c.resume(with: result) }
        waiting[f.id] = nil
        revision += 1
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let f = tasks[id]?.0 else { return }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : max(f.size, 1)
            progress[f.id] = min(1, Double(totalBytesWritten) / Double(total))
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        // The temporary file disappears when this method returns, so move it now.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: tmp)
        Task { @MainActor in
            guard let f = tasks[id]?.0 else { return }
            tasks[id] = nil
            let dest = localURL(f)
            guard status < 400, Self.looksValid(tmp, kind: f.kind) else {
                try? FileManager.default.removeItem(at: tmp)
                Task { await DriveClient.shared.invalidateToken() }
                finish(f, .failure(DriveError.http(status)))
                return
            }
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                finish(f, .success(dest))
            } catch {
                finish(f, .failure(error))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        Task { @MainActor in
            guard let f = tasks[id]?.0 else { return }
            tasks[id] = nil
            finish(f, .failure(error))
        }
    }

    private static func looksValid(_ url: URL, kind: BookKind?) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 5)) ?? Data()
        switch kind {
        case .pdf: return head.starts(with: Data("%PDF".utf8))
        case .epub: return head.starts(with: Data([0x50, 0x4B]))
        case nil: return true
        }
    }
}
