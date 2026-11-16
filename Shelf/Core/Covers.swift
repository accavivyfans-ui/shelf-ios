import Foundation
import UIKit
import SwiftUI

/// Reads byte ranges of a remote file synchronously, for CGPDFDocument's data provider.
/// Only used off the main thread; caches 256 KB blocks and gives up after a budget.
final class RangeReader {
    let url: URL
    let size: Int
    private let block = 256 * 1024
    private var cache: [Int: Data] = [:]
    private var fetched = 0
    private let budget: Int
    private(set) var failed = false

    init(url: URL, size: Int, budget: Int = 6 * 1024 * 1024) {
        self.url = url
        self.size = size
        self.budget = budget
    }

    private func blockData(_ index: Int) -> Data? {
        if let d = cache[index] { return d }
        if failed || fetched > budget { failed = true; return nil }
        let start = index * block
        let end = min(size, start + block) - 1
        guard start <= end else { return nil }
        var req = URLRequest(url: url)
        req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 20
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 206 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        guard let d = result, d.count == end - start + 1 else { failed = true; return nil }
        fetched += d.count
        cache[index] = d
        return d
    }

    func read(into buffer: UnsafeMutableRawPointer, at position: Int, count: Int) -> Int {
        var copied = 0
        var pos = position
        while copied < count, pos < size {
            guard let d = blockData(pos / block) else { return copied }
            let offset = pos % block
            let n = min(count - copied, d.count - offset)
            if n <= 0 { break }
            d.withUnsafeBytes { raw in
                buffer.advanced(by: copied).copyMemory(from: raw.baseAddress!.advanced(by: offset), byteCount: n)
            }
            copied += n
            pos += n
        }
        return copied
    }

    func makeDocument() -> CGPDFDocument? {
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let r = Unmanaged<RangeReader>.fromOpaque(info).takeUnretainedValue()
                return r.read(into: buffer, at: Int(position), count: count)
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<RangeReader>.fromOpaque(info).release()
            })
        let info = Unmanaged.passRetained(self).toOpaque()
        guard let provider = CGDataProvider(directInfo: info, size: off_t(size), callbacks: &callbacks) else {
            Unmanaged<RangeReader>.fromOpaque(info).release()
            return nil
        }
        return CGPDFDocument(provider)
    }
}

enum PDFThumb {
    static func render(_ doc: CGPDFDocument, page index: Int = 1, width: CGFloat = 360) -> UIImage? {
        guard let page = doc.page(at: index) else { return nil }
        var box = page.getBoxRect(.cropBox)
        if box.isEmpty { box = page.getBoxRect(.mediaBox) }
        let rotation = page.rotationAngle % 360
        let rotated = rotation == 90 || rotation == 270
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = width / pageSize.width
        let size = CGSize(width: width, height: min(width * 2.2, pageSize.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let c = ctx.cgContext
            c.translateBy(x: 0, y: size.height)
            c.scaleBy(x: 1, y: -1)
            let t = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: CGSize(width: width, height: pageSize.height * scale)), rotate: 0, preserveAspectRatio: true)
            c.concatenate(t)
            c.drawPDFPage(page)
        }
    }
}

/// Book covers: web cover → downloaded file → first page over HTTP ranges → generated cover.
@MainActor
final class Covers: ObservableObject {
    static let shared = Covers()

    private var memory = NSCache<NSString, UIImage>()
    private var inflight: Set<String> = []
    private var failed: Set<String> = []
    @Published private(set) var revision = 0
    private let remoteQueue = DispatchQueue(label: "covers.remote", qos: .utility, attributes: .concurrent)
    private let remoteSlots = DispatchSemaphore(value: 3)

    private func diskURL(_ id: String) -> URL { Paths.covers.appendingPathComponent("\(id).jpg") }

    func image(for f: BookFile) -> UIImage? {
        if let m = memory.object(forKey: f.id as NSString) { return m }
        if let d = try? Data(contentsOf: diskURL(f.id)), let img = UIImage(data: d) {
            memory.setObject(img, forKey: f.id as NSString)
            return img
        }
        return nil
    }

    func request(_ f: BookFile) {
        guard image(for: f) == nil, !inflight.contains(f.id), !failed.contains(f.id) else { return }
        inflight.insert(f.id)
        Task {
            let img = await produce(f)
            inflight.remove(f.id)
            if let img {
                memory.setObject(img, forKey: f.id as NSString)
                if let data = img.jpegData(compressionQuality: 0.8) { try? data.write(to: diskURL(f.id)) }
                revision += 1
            } else {
                failed.insert(f.id)
            }
        }
    }

    func store(_ img: UIImage, for f: BookFile) {
        memory.setObject(img, forKey: f.id as NSString)
        if let data = img.jpegData(compressionQuality: 0.8) { try? data.write(to: diskURL(f.id)) }
        failed.remove(f.id)
        revision += 1
    }

    private func produce(_ f: BookFile) async -> UIImage? {
        if let doc = SyncCenter.shared.webDoc(f.path), let url = await StudyOSClient.shared.coverURL(doc), SyncCenter.shared.online,
           let fetched = try? await URLSession.shared.data(from: url), (fetched.1 as? HTTPURLResponse)?.statusCode == 200, let img = UIImage(data: fetched.0) {
            return img
        }
        let local = Downloads.shared.localURL(f)
        if FileManager.default.fileExists(atPath: local.path) {
            if f.kind == .pdf {
                return await Task.detached(priority: .utility) { () -> UIImage? in
                    guard let doc = CGPDFDocument(local as CFURL) else { return nil }
                    return PDFThumb.render(doc)
                }.value
            } else if f.kind == .epub {
                return await Task.detached(priority: .utility) { EpubBook.coverImage(at: local) }.value
            }
        }
        guard f.kind == .pdf, f.size > 0, f.size < 400_000_000, let url = try? await DriveClient.shared.downloadURL(id: f.id, name: f.name) else { return nil }
        let size = Int(f.size)
        let queue = remoteQueue
        let slots = remoteSlots
        return await withCheckedContinuation { cont in
            queue.async {
                slots.wait()
                defer { slots.signal() }
                let reader = RangeReader(url: url, size: size)
                let img = reader.makeDocument().flatMap { PDFThumb.render($0) }
                cont.resume(returning: img)
            }
        }
    }
}

/// A generated cover for books without artwork, styled by subject.
struct GeneratedCover: View {
    var title: String
    var subtitle: String

    private var palette: (Color, Color) {
        let colors: [(Color, Color)] = [
            (Color(red: 0.16, green: 0.32, blue: 0.55), Color(red: 0.10, green: 0.20, blue: 0.38)),
            (Color(red: 0.55, green: 0.22, blue: 0.20), Color(red: 0.38, green: 0.13, blue: 0.12)),
            (Color(red: 0.20, green: 0.45, blue: 0.36), Color(red: 0.11, green: 0.29, blue: 0.23)),
            (Color(red: 0.45, green: 0.33, blue: 0.58), Color(red: 0.28, green: 0.19, blue: 0.40)),
            (Color(red: 0.70, green: 0.48, blue: 0.18), Color(red: 0.48, green: 0.30, blue: 0.09)),
            (Color(red: 0.25, green: 0.27, blue: 0.31), Color(red: 0.14, green: 0.15, blue: 0.18)),
        ]
        let h = abs(subtitle.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
        return colors[h % colors.count]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [palette.0, palette.1], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.white.opacity(0.12)).frame(width: 5).padding(.leading, 7)
            VStack(alignment: .leading, spacing: 6) {
                Text(subtitle)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(5)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .padding([.top, .trailing], 10)
        }
    }
}
