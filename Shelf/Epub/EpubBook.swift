import Foundation
import UIKit

/// Tiny XML element tree built with XMLParser (namespaces folded to local names).
final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""
    weak var parent: XNode?

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    func all(_ local: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == local { out.append(c) }
            out.append(contentsOf: c.all(local))
        }
        return out
    }

    func first(_ local: String) -> XNode? { all(local).first }

    var fullText: String { text + children.map(\.fullText).joined() }

    func attr(_ local: String) -> String? {
        if let v = attrs[local] { return v }
        return attrs.first { $0.key.hasSuffix(":" + local) }?.value
    }

    static func parse(_ data: Data) -> XNode? {
        let b = Builder()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        p.delegate = b
        p.parse()
        return b.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let n = XNode(name: local, attrs: attributeDict)
            n.parent = stack.last
            if let top = stack.last { top.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

struct EpubChapter: Hashable {
    var index: Int
    var href: String
    var title: String
}

struct EpubTocItem: Hashable, Identifiable {
    var id = UUID()
    var label: String
    var chapter: Int
    var fragment: String?
    var depth: Int
}

/// An EPUB 2/3 book: spine, table of contents and resources, read straight from the zip.
/// Chapter numbering follows the StudyOS web reader (linear spine items only), so
/// "ch:<n>:<ratio>" positions mean the same thing on both sides.
final class EpubBook {
    let zip: ZipArchive
    let title: String
    let chapters: [EpubChapter]
    let toc: [EpubTocItem]
    private let types: [String: String]
    let coverHref: String?

    init?(url: URL) {
        guard let zip = ZipArchive(url: url) else { return nil }
        self.zip = zip
        guard let containerData = zip.read("META-INF/container.xml"), let container = XNode.parse(containerData),
              let opfPath = container.first("rootfile")?.attr("full-path"),
              let opfData = zip.read(opfPath), let opf = XNode.parse(opfData) else { return nil }

        var manifest: [String: (href: String, type: String, props: String)] = [:]
        var types: [String: String] = [:]
        for item in opf.all("item") {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            let full = EpubBook.resolve(base: opfPath, href)
            let type = item.attr("media-type") ?? ""
            manifest[id] = (full, type, item.attr("properties") ?? "")
            types[full] = type
        }
        self.types = types
        var spine: [String] = []
        for ref in opf.all("itemref") where ref.attr("linear") != "no" {
            if let m = ref.attr("idref").flatMap({ manifest[$0] }), m.type.contains("html") || m.type.contains("xml") { spine.append(m.href) }
        }
        guard !spine.isEmpty else { return nil }
        title = opf.first("title")?.fullText.trimmingCharacters(in: .whitespacesAndNewlines) ?? "EPUB"
        let index = Dictionary(spine.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        var toc: [EpubTocItem] = []
        func push(_ label: String, _ href: String, _ base: String, _ depth: Int) {
            let target = EpubBook.resolve(base: base, href)
            let clean = label.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard let ch = index[target], !clean.isEmpty else { return }
            let frag = href.contains("#") ? String(href.split(separator: "#", maxSplits: 1).last ?? "") : nil
            toc.append(EpubTocItem(label: clean, chapter: ch, fragment: frag, depth: depth))
        }
        if let nav = manifest.values.first(where: { $0.props.split(separator: " ").contains("nav") }), let d = zip.read(nav.href), let doc = XNode.parse(d) {
            let navs = doc.all("nav")
            let tocNav = navs.first { ($0.attr("type") ?? "").contains("toc") } ?? navs.first
            if let tocNav {
                for a in tocNav.all("a") {
                    var depth = 0
                    var p = a.parent
                    while let n = p, n !== tocNav { if n.name == "ol" { depth += 1 }; p = n.parent }
                    push(a.fullText, a.attr("href") ?? "", nav.href, max(0, depth - 1))
                }
            }
        }
        if toc.isEmpty {
            let ncxId = opf.first("spine")?.attr("toc")
            let ncx = ncxId.flatMap { manifest[$0] } ?? manifest.values.first { $0.type == "application/x-dtbncx+xml" }
            if let ncx, let d = zip.read(ncx.href), let doc = XNode.parse(d), let navMap = doc.first("navMap") {
                func walk(_ node: XNode, _ depth: Int) {
                    for point in node.children where point.name == "navPoint" {
                        let label = point.first("text")?.fullText ?? ""
                        let src = point.first("content")?.attr("src") ?? ""
                        push(label, src, ncx.href, depth)
                        walk(point, depth + 1)
                    }
                }
                walk(navMap, 0)
            }
        }
        self.toc = toc
        chapters = spine.enumerated().map { i, href in
            EpubChapter(index: i, href: href, title: toc.first { $0.chapter == i && $0.depth == 0 }?.label ?? toc.first { $0.chapter == i }?.label ?? "\(i + 1)장")
        }

        // Cover: EPUB 3 cover-image property, EPUB 2 <meta name="cover">, or an image named cover.
        var cover = manifest.values.first { $0.props.contains("cover-image") }?.href
        if cover == nil, let meta = opf.all("meta").first(where: { $0.attr("name") == "cover" }), let id = meta.attr("content") { cover = manifest[id]?.href }
        if cover == nil { cover = manifest.values.first { $0.type.hasPrefix("image/") && $0.href.lowercased().contains("cover") }?.href }
        coverHref = cover
    }

    static func resolve(base: String, _ href: String) -> String {
        let clean = (href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href)
            .split(separator: "?").first.map(String.init) ?? ""
        let decoded = clean.removingPercentEncoding ?? clean
        let dir = base.contains("/") ? String(base[..<base.lastIndex(of: "/")!]) + "/" : ""
        let joined = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : dir + decoded
        var out: [Substring] = []
        for part in joined.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = out.popLast() } else { out.append(part) }
        }
        return out.joined(separator: "/")
    }

    func mime(_ path: String) -> String {
        if let t = types[path], !t.isEmpty { return t }
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "xht": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    func chapterIndex(forHref href: String, relativeTo base: String) -> Int? {
        let target = EpubBook.resolve(base: base, href)
        return chapters.first { $0.href == target }?.index
    }

    /// Plain text of a chapter, for search.
    func plainText(_ index: Int) -> String {
        guard chapters.indices.contains(index), let html = zip.text(chapters[index].href) else { return "" }
        var s = html
        if let body = s.range(of: "<body", options: .caseInsensitive) { s = String(s[body.lowerBound...]) }
        s = s.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    static func coverImage(at url: URL) -> UIImage? {
        guard let book = EpubBook(url: url), let href = book.coverHref, let data = book.zip.read(href), let img = UIImage(data: data) else { return nil }
        let w: CGFloat = 360
        let h = img.size.height * w / max(1, img.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in img.draw(in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }
}
