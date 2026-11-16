import SwiftUI
import PDFKit
import UIKit

final class ShelfPDFView: PDFView {
    var onHighlight: ((HighlightColor) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let s = currentSelection?.string, !s.isEmpty else { return }
        let actions = HighlightColor.allCases.map { c in
            UIAction(title: "형광펜", image: UIImage(systemName: "circle.fill")?.withTintColor(c.uiColor, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.onHighlight?(c)
            }
        }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [actions[0]]), atStartOfMenu: .root)
    }
}

/// Hosts PDFView plus a blend-mode overlay used for the sepia / dark page themes.
final class PDFHostView: UIView {
    let pdfView = ShelfPDFView()
    let overlay = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        pdfView.frame = bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(pdfView)
        overlay.frame = bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        overlay.isHidden = true
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class PDFReaderModel: ReaderModel, PDFDocumentDelegate {
    let document: PDFDocument
    let host = PDFHostView()
    var pdfView: ShelfPDFView { host.pdfView }
    private var observers: [NSObjectProtocol] = []
    private var drawn: [String: [(PDFPage, PDFAnnotation)]] = [:]
    private var outline: [TocEntry] = []
    private var tap: UITapGestureRecognizer?
    private var swipes: [UISwipeGestureRecognizer] = []
    private var layout: PDFLayout = .paged
    private var pendingHits: [SearchHit] = []

    init?(file: BookFile, url: URL, state: ReadingState) {
        guard let doc = PDFDocument(url: url) else { return nil }
        document = doc
        super.init(file: file, state: state)
        doc.delegate = self
        outline = Self.flatten(doc.outlineRoot, doc: doc)
        configure()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    private static func flatten(_ root: PDFOutline?, doc: PDFDocument) -> [TocEntry] {
        guard let root else { return [] }
        var out: [TocEntry] = []
        func walk(_ node: PDFOutline, _ depth: Int) {
            for i in 0..<node.numberOfChildren {
                guard let c = node.child(at: i) else { continue }
                let page = c.destination?.page.map { doc.index(for: $0) + 1 } ?? 0
                if let label = c.label, !label.isEmpty, page > 0 {
                    out.append(TocEntry(label: label, depth: depth, page: page, pageLabel: "\(page)"))
                }
                if out.count < 2000 { walk(c, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    private func configure() {
        pdfView.document = document
        pdfView.backgroundColor = .systemGray5
        pdfView.pageShadowsEnabled = true
        pdfView.displaysPageBreaks = true
        pdfView.onHighlight = { [weak self] c in self?.addHighlight(c) }
        if state.pageCount == 0 { state.pageCount = document.pageCount }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pageChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = self.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.selectionActive = !s.isEmpty
                if !s.isEmpty { self.activeHighlightId = nil }
            }
        })

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.delegate = TapDelegate.shared
        pdfView.addGestureRecognizer(tap)
        self.tap = tap
        for dir in [UISwipeGestureRecognizer.Direction.left, .right] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(onSwipe(_:)))
            s.direction = dir
            s.delegate = TapDelegate.shared
            s.isEnabled = false
            pdfView.addGestureRecognizer(s)
            swipes.append(s)
        }
        applyLayout(AppSettings.shared.pdfLayout, keepPage: false)
        applyAppearance()
        redrawHighlights()
    }

    override func didAppear() {
        let target = max(1, min(state.page, document.pageCount))
        if let page = document.page(at: target - 1) { pdfView.go(to: page) }
        pageChanged()
        // Let our single tap wait for PDFView's own double tap (zoom).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.chainDoubleTaps() }
    }

    private func chainDoubleTaps() {
        guard let tap else { return }
        func walk(_ v: UIView) {
            for g in v.gestureRecognizers ?? [] where g !== tap {
                if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
            }
            v.subviews.forEach(walk)
        }
        walk(pdfView)
    }

    func applyLayout(_ l: PDFLayout, keepPage: Bool = true) {
        let current = pdfView.currentPage
        layout = l
        switch l {
        case .paged:
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            pdfView.displaysAsBook = false
            pdfView.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 14])
        case .vertical:
            pdfView.usePageViewController(false, withViewOptions: nil)
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.displaysAsBook = false
        case .twoUp:
            pdfView.usePageViewController(false, withViewOptions: nil)
            pdfView.displayMode = .twoUp
            pdfView.displayDirection = .horizontal
            pdfView.displaysAsBook = true
        }
        swipes.forEach { $0.isEnabled = l == .twoUp }
        pdfView.autoScales = true
        pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit * 0.5
        pdfView.maxScaleFactor = 6
        if keepPage, let current { pdfView.go(to: current) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.chainDoubleTaps() }
    }

    override var canTwoUp: Bool { true }

    private func pageChanged() {
        guard let p = pdfView.currentPage else { return }
        let n = document.index(for: p) + 1
        let count = max(1, document.pageCount)
        record(page: n, pageCount: count, percent: Double(n) / Double(count) * 100)
    }

    override var pageText: String { "\(state.page) / \(max(state.pageCount, document.pageCount))" }
    override var detailText: String {
        let left = max(0, document.pageCount - state.page)
        return left == 0 ? "마지막 쪽" : "\(left)쪽 남음"
    }
    override var progressFraction: Double { Double(state.page) / Double(max(1, document.pageCount)) }
    override var toc: [TocEntry] { outline }

    override func next() {
        if layout == .vertical {
            pdfView.goToNextPage(nil)
        } else if pdfView.canGoToNextPage {
            pdfView.goToNextPage(nil)
        }
    }

    override func prev() {
        if pdfView.canGoToPreviousPage { pdfView.goToPreviousPage(nil) }
    }

    override func go(page: Int) {
        guard let p = document.page(at: max(0, min(document.pageCount - 1, page - 1))) else { return }
        pdfView.go(to: p)
    }

    override func go(_ entry: TocEntry) { go(page: entry.page) }

    override func go(fraction: Double) {
        go(page: Int((fraction * Double(document.pageCount)).rounded(.up)).clamped(1, document.pageCount))
    }

    override func applyRemote(_ rp: RemoteProgress) {
        go(page: rp.page ?? Int(rp.position) ?? state.page)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        let loc = g.location(in: pdfView)
        if selectionActive {
            pdfView.clearSelection()
            selectionActive = false
            return
        }
        if let page = pdfView.page(for: loc, nearest: false) {
            let pt = pdfView.convert(loc, to: page)
            if let a = page.annotations.first(where: { ($0.userName ?? "").hasPrefix("shelf:") && $0.bounds.insetBy(dx: -2, dy: -2).contains(pt) }) {
                activeHighlightId = String(a.userName!.dropFirst(6))
                chromeVisible = false
                return
            }
        }
        if activeHighlightId != nil { activeHighlightId = nil; return }
        let x = loc.x / max(1, pdfView.bounds.width)
        let zoomed = pdfView.scaleFactor > pdfView.scaleFactorForSizeToFit * 1.05
        if AppSettings.shared.tapToTurn, layout != .vertical, !zoomed, x < 0.22 || x > 0.78 {
            if x < 0.22 { prev() } else { next() }
            if chromeVisible { chromeVisible = false }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
    }

    @objc private func onSwipe(_ g: UISwipeGestureRecognizer) {
        guard pdfView.scaleFactor <= pdfView.scaleFactorForSizeToFit * 1.05 else { return }
        if g.direction == .left { next() } else { prev() }
    }

    // MARK: Appearance

    override func applyAppearance() {
        let theme = AppSettings.shared.theme
        let o = host.overlay
        switch theme {
        case .light:
            o.isHidden = true
            pdfView.backgroundColor = UIColor(white: 0.92, alpha: 1)
        case .sepia:
            o.isHidden = false
            o.backgroundColor = UIColor(red: 0.98, green: 0.92, blue: 0.78, alpha: 1)
            o.layer.compositingFilter = "multiplyBlendMode"
            pdfView.backgroundColor = UIColor(red: 0.93, green: 0.89, blue: 0.80, alpha: 1)
        case .gray:
            o.isHidden = false
            o.backgroundColor = UIColor(white: 0.86, alpha: 1)
            o.layer.compositingFilter = "differenceBlendMode"
            pdfView.backgroundColor = UIColor(white: 0.56, alpha: 1)
        case .dark:
            o.isHidden = false
            o.backgroundColor = .white
            o.layer.compositingFilter = "differenceBlendMode"
            pdfView.backgroundColor = UIColor(white: 0.93, alpha: 1)
        }
    }

    // MARK: Highlights

    override func redrawHighlights() {
        for (_, list) in drawn { for (page, a) in list { page.removeAnnotation(a) } }
        drawn = [:]
        for h in state.highlights where !h.deleted {
            guard let page = document.page(at: h.page - 1), let text = page.string,
                  let range = Self.locate(h, in: text), let sel = page.selection(for: range) else { continue }
            var list: [(PDFPage, PDFAnnotation)] = []
            for line in sel.selectionsByLine() {
                let b = line.bounds(for: page)
                guard b.width > 0, b.height > 0 else { continue }
                let a = PDFAnnotation(bounds: b.insetBy(dx: -1, dy: -0.5), forType: .highlight, withProperties: nil)
                a.color = h.tint.uiColor.withAlphaComponent(0.42)
                a.userName = "shelf:" + h.id
                if !h.comment.isEmpty { a.contents = h.comment }
                page.addAnnotation(a)
                list.append((page, a))
            }
            drawn[h.id] = list
        }
    }

    override func selectedText() -> String { pdfView.currentSelection?.string ?? "" }

    override func copySelection() {
        UIPasteboard.general.string = selectedText()
        clearSelection()
        showToast("복사했어요")
    }

    override func clearSelection() {
        pdfView.clearSelection()
        selectionActive = false
    }

    override func addHighlight(_ color: HighlightColor) {
        guard let sel = pdfView.currentSelection else { return }
        var added: Highlight?
        for page in sel.pages {
            guard let text = page.string else { continue }
            let ns = text as NSString
            let n = sel.numberOfTextRanges(on: page)
            guard n > 0 else { continue }
            let first = sel.range(at: 0, on: page)
            let last = sel.range(at: n - 1, on: page)
            guard first.location != NSNotFound, last.location != NSNotFound else { continue }
            let range = NSRange(location: first.location, length: min(ns.length, last.location + last.length) - first.location)
            guard range.length > 0 else { continue }
            let ctx = Self.anchorContext(ns, range)
            guard !ctx.exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let h = Highlight(page: document.index(for: page) + 1, exact: ctx.exact, prefix: ctx.prefix, suffix: ctx.suffix, startOffset: range.location, color: color.rawValue)
            state.highlights.append(h)
            added = h
        }
        clearSelection()
        redrawHighlights()
        saveAnnotations()
        if added != nil { showToast("형광펜을 칠했어요") }
    }

    override func goHighlight(_ h: Highlight) {
        go(page: h.page)
        if let a = drawn[h.id]?.first { pdfView.go(to: a.1.bounds, on: a.0) }
    }

    // MARK: Bookmarks

    override var currentBookmark: Bookmark? {
        state.bookmarks.first { !$0.deleted && $0.page == state.page }
    }

    override func toggleBookmark() {
        if let b = currentBookmark {
            deleteBookmark(b.id)
            showToast("책갈피를 뺐어요")
        } else {
            state.bookmarks.append(Bookmark(page: state.page, label: "\(state.page)쪽"))
            saveAnnotations()
            showToast("책갈피를 꽂았어요")
        }
    }

    // MARK: Search

    override func search(_ q: String) {
        document.cancelFindString()
        searchHits = []
        pendingHits = []
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        document.beginFindString(query, withOptions: [.caseInsensitive])
    }

    override func cancelSearch() {
        document.cancelFindString()
        searching = false
    }

    nonisolated func didMatchString(_ instance: PDFSelection) {
        Task { @MainActor in
            guard let page = instance.pages.first, self.searchHits.count + self.pendingHits.count < 500 else { return }
            let ctx = instance.copy() as! PDFSelection
            ctx.extendForLineBoundaries()
            let snippet = (ctx.string ?? "").replacingOccurrences(of: "\n", with: " ")
            self.pendingHits.append(SearchHit(page: self.document.index(for: page) + 1, snippet: String(snippet.prefix(160)), payload: instance))
            if self.pendingHits.count >= 20 { self.searchHits += self.pendingHits; self.pendingHits = [] }
        }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        Task { @MainActor in
            self.searchHits += self.pendingHits
            self.pendingHits = []
            self.searching = false
        }
    }

    override func go(_ hit: SearchHit) {
        guard let sel = hit.payload as? PDFSelection else { go(page: hit.page); return }
        pdfView.go(to: sel)
        sel.color = UIColor.systemYellow.withAlphaComponent(0.6)
        pdfView.highlightedSelections = [sel]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.pdfView.highlightedSelections = nil }
    }

    // MARK: Thumbnails

    func thumbnail(_ page: Int, size: CGSize) -> UIImage? {
        document.page(at: page - 1)?.thumbnail(of: size, for: .cropBox)
    }
}

final class TapDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = TapDelegate()
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}

struct PDFHost: UIViewRepresentable {
    let model: PDFReaderModel
    func makeUIView(context: Context) -> PDFHostView { model.host }
    func updateUIView(_ uiView: PDFHostView, context: Context) {}
}

struct PDFScrubber: UIViewRepresentable {
    let model: PDFReaderModel
    func makeUIView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = model.pdfView
        v.layoutMode = .horizontal
        v.thumbnailSize = CGSize(width: 22, height: 30)
        v.backgroundColor = .clear
        return v
    }
    func updateUIView(_ uiView: PDFThumbnailView, context: Context) {}
}
