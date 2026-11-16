import SwiftUI
import WebKit
import UIKit

/// Serves files straight out of the EPUB zip at shelfbook://book/<path>.
@MainActor
final class EpubSchemeHandler: NSObject, WKURLSchemeHandler {
    let book: EpubBook
    init(book: EpubBook) { self.book = book }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        path = path.removingPercentEncoding ?? path
        guard let data = book.zip.read(path) else {
            task.didFailWithError(NSError(domain: "shelf", code: 404))
            return
        }
        var mime = book.mime(path)
        // Chapters are parsed as HTML: forgiving of the small XHTML errors many books have.
        if mime.contains("xhtml") || mime.contains("html") { mime = "text/html" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime + (mime.hasPrefix("text/") ? "; charset=utf-8" : ""), "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: EpubReaderModel?
    init(_ t: EpubReaderModel) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}

final class EpubWebView: WKWebView {
    var onHighlight: ((HighlightColor) -> Void)?
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        let a = UIAction(title: "형광펜", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.onHighlight?(.sand) }
        builder.insertChild(UIMenu(title: "", options: .displayInline, children: [a]), atStartOfMenu: .root)
    }
}

@MainActor
final class EpubReaderModel: ReaderModel, WKNavigationDelegate, UIScrollViewDelegate {
    let book: EpubBook
    let webView: EpubWebView
    private let handler: EpubSchemeHandler
    private(set) var chapter = 0
    private(set) var pages = 1
    private(set) var pageInChapter = 0
    private var pending: Pending = .ratio(0)
    private var ready = false
    private var lastWidth: CGFloat = 0
    private var entries: [TocEntry] = []
    private var pendingFind: (String, Int)?

    enum Pending {
        case ratio(Double)
        case last
        case fragment(String)
        case find(String, Int)
    }

    init?(file: BookFile, url: URL, state: ReadingState) {
        guard let b = EpubBook(url: url) else { return nil }
        book = b
        handler = EpubSchemeHandler(book: b)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: "shelfbook")
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.dataDetectorTypes = []
        let ucc = WKUserContentController()
        config.userContentController = ucc
        webView = EpubWebView(frame: .zero, configuration: config)
        super.init(file: file, state: state)
        ucc.add(WeakHandler(self), name: "shelf")
        ucc.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.scrollView.delegate = self
        webView.scrollView.isPagingEnabled = true
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceHorizontal = true
        webView.onHighlight = { [weak self] c in self?.addHighlight(c) }
        entries = b.toc.map { TocEntry(label: $0.label, depth: $0.depth, page: $0.chapter + 1, fragment: $0.fragment, pageLabel: "\($0.chapter + 1)장") }
        if entries.isEmpty { entries = b.chapters.map { TocEntry(label: $0.title, depth: 0, page: $0.index + 1, pageLabel: "\($0.index + 1)장") } }
        chapter = max(0, min(b.chapters.count - 1, state.page - 1))
        pending = .ratio(state.ratio)
        state.pageCount = b.chapters.count
        applyAppearance()
    }

    override func didAppear() { load(chapter) }

    private func load(_ index: Int) {
        guard book.chapters.indices.contains(index) else { return }
        chapter = index
        ready = false
        webView.alpha = 0
        let href = book.chapters[index].href.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        if let url = URL(string: "shelfbook://book/" + href) { webView.load(URLRequest(url: url)) }
    }

    // MARK: Messages from the page

    func receive(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready":
            pages = max(1, m["pages"] as? Int ?? 1)
            ready = true
            settle()
        case "page":
            if let p = m["page"] as? Int { show(page: p, animated: false) }
        case "tap":
            let x = m["x"] as? Double ?? 0.5
            handleTap(x)
        case "selection":
            let has = (m["has"] as? Bool) ?? false
            selectionActive = has
            if has { activeHighlightId = nil }
        case "mark":
            if let id = m["id"] as? String { activeHighlightId = id; chromeVisible = false }
        case "link":
            if let href = m["href"] as? String { follow(href) }
        default: break
        }
    }

    private func settle() {
        redrawHighlights()
        switch pending {
        case .ratio(let r):
            show(page: Int((r * Double(pages - 1)).rounded()), animated: false)
            reveal()
        case .last:
            show(page: pages - 1, animated: false)
            reveal()
        case .fragment(let f):
            js("shelf.pageOfFragment(\(f.jsonQuoted))") { [weak self] v in
                self?.show(page: (v as? Int) ?? 0, animated: false)
                self?.reveal()
            }
        case .find(let q, let n):
            js("shelf.find(\(q.jsonQuoted), \(n))") { [weak self] v in
                self?.show(page: (v as? Int) ?? 0, animated: false)
                self?.reveal()
            }
        }
        pending = .ratio(Double(pageInChapter) / Double(max(1, pages - 1)))
    }

    private func reveal() {
        UIView.animate(withDuration: 0.15) { self.webView.alpha = 1 }
    }

    private func show(page: Int, animated: Bool) {
        let p = page.clamped(0, pages - 1)
        let w = webView.scrollView.bounds.width
        webView.scrollView.setContentOffset(CGPoint(x: CGFloat(p) * w, y: 0), animated: animated)
        if !animated { pageSettled(p) }
    }

    private func pageSettled(_ p: Int) {
        pageInChapter = p
        let ratio = pages > 1 ? Double(p) / Double(pages - 1) : 0
        let count = max(1, book.chapters.count)
        record(page: chapter + 1, pageCount: count, ratio: ratio, percent: (Double(chapter) + min(1, ratio)) / Double(count) * 100)
        objectWillChange.send()
    }

    private func handleTap(_ x: Double) {
        if selectionActive { clearSelection(); return }
        if activeHighlightId != nil { activeHighlightId = nil; return }
        if AppSettings.shared.tapToTurn, x < 0.22 || x > 0.78 {
            if x < 0.22 { prev() } else { next() }
            if chromeVisible { chromeVisible = false }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
        }
    }

    private func follow(_ href: String) {
        if href.hasPrefix("http") { return }
        if href.hasPrefix("#") {
            js("shelf.pageOfFragment(\(String(href.dropFirst()).jsonQuoted))") { [weak self] v in self?.show(page: (v as? Int) ?? 0, animated: true) }
            return
        }
        guard let target = book.chapterIndex(forHref: href, relativeTo: book.chapters[chapter].href) else { return }
        let frag = href.contains("#") ? String(href.split(separator: "#").last ?? "") : nil
        pending = frag.map { .fragment($0) } ?? .ratio(0)
        load(target)
    }

    // MARK: Scrolling between pages and chapters

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        syncPageFromOffset()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        syncPageFromOffset()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let x = scrollView.contentOffset.x
        let maxX = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        if x > maxX + 40 { nextChapter() } else if x < -40 { prevChapter() }
    }

    private func syncPageFromOffset() {
        guard ready else { return }
        let w = max(1, webView.scrollView.bounds.width)
        pageSettled(Int((webView.scrollView.contentOffset.x / w).rounded()).clamped(0, pages - 1))
    }

    override func next() {
        if pageInChapter < pages - 1 { show(page: pageInChapter + 1, animated: true) } else { nextChapter() }
    }

    override func prev() {
        if pageInChapter > 0 { show(page: pageInChapter - 1, animated: true) } else { prevChapter() }
    }

    private func nextChapter() {
        guard chapter < book.chapters.count - 1 else { showToast("마지막 장이에요"); return }
        pending = .ratio(0)
        load(chapter + 1)
    }

    private func prevChapter() {
        guard chapter > 0 else { return }
        pending = .last
        load(chapter - 1)
    }

    func layoutChanged() {
        let w = webView.bounds.width
        guard w > 0, abs(w - lastWidth) > 1 else { return }
        lastWidth = w
        if ready {
            pending = .ratio(pages > 1 ? Double(pageInChapter) / Double(pages - 1) : 0)
            js("shelf.relayout()")
        }
    }

    // MARK: Navigation API

    override var toc: [TocEntry] { entries }
    override var pageText: String {
        "\(chapter + 1)장 · \(pageInChapter + 1)/\(pages)쪽"
    }
    override var detailText: String {
        let left = pages - 1 - pageInChapter
        return left == 0 ? "장의 마지막 쪽" : "이 장 \(left)쪽 남음"
    }
    override var progressFraction: Double {
        let ratio = pages > 1 ? Double(pageInChapter) / Double(pages - 1) : 0
        return (Double(chapter) + ratio) / Double(max(1, book.chapters.count))
    }

    override func go(_ entry: TocEntry) {
        pending = entry.fragment.map { .fragment($0) } ?? .ratio(0)
        load(entry.page - 1)
    }

    override func go(page: Int) {
        pending = .ratio(0)
        load(page - 1)
    }

    override func go(fraction: Double) {
        let count = Double(book.chapters.count)
        let pos = min(count - 0.0001, max(0, fraction * count))
        let ch = Int(pos)
        let r = pos - Double(ch)
        if ch == chapter, ready {
            show(page: Int((r * Double(pages - 1)).rounded()), animated: false)
        } else {
            pending = .ratio(r)
            load(ch)
        }
    }

    override func applyRemote(_ rp: RemoteProgress) {
        let parts = rp.position.split(separator: ":")
        guard parts.count == 3, let ch = Int(parts[1]), let r = Double(parts[2]) else { return }
        pending = .ratio(r)
        load(ch)
    }

    override func goBookmark(_ b: Bookmark) {
        pending = .ratio(b.ratio)
        load(b.page - 1)
    }

    override func goHighlight(_ h: Highlight) {
        pending = .ratio(0)
        if h.page - 1 == chapter, ready {
            js("shelf.pageOfMark(\(h.id.jsonQuoted))") { [weak self] v in self?.show(page: (v as? Int) ?? 0, animated: false) }
        } else {
            load(h.page - 1)
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.js("shelf.pageOfMark(\(h.id.jsonQuoted))") { [weak self] v in if let p = v as? Int { self?.show(page: p, animated: false) } }
            }
        }
    }

    // MARK: Appearance

    var styleJSON: String {
        let s = AppSettings.shared
        let c = s.theme.css
        let cfg: [String: Any] = [
            "bg": c.bg, "fg": c.fg, "link": c.link, "themed": s.theme != .light,
            "font": s.epubFont.css, "size": s.epubFontSize, "line": s.epubLineHeight, "margin": s.epubMargin,
            "top": 52, "bottom": 46,
        ]
        let d = (try? JSONSerialization.data(withJSONObject: cfg)) ?? Data("{}".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    override func applyAppearance() {
        let bg = UIColor(AppSettings.shared.theme.paper)
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        if ready {
            pending = .ratio(pages > 1 ? Double(pageInChapter) / Double(pages - 1) : 0)
            js("shelf.setStyle(\(styleJSON))")
        }
    }

    // MARK: Highlights

    override func redrawHighlights() {
        let list = state.highlights.filter { !$0.deleted && $0.page == chapter + 1 }.map {
            ["id": $0.id, "exact": $0.exact, "prefix": $0.prefix, "suffix": $0.suffix, "start": $0.startOffset ?? -1, "color": $0.tint.css] as [String: Any]
        }
        let d = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        js("shelf.highlight(\(String(decoding: d, as: UTF8.self)))")
    }

    override func addHighlight(_ color: HighlightColor) {
        js("shelf.anchor()") { [weak self] v in
            guard let self, let a = v as? [String: Any], let exact = a["exact"] as? String, !exact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let h = Highlight(page: self.chapter + 1, exact: exact, prefix: a["prefix"] as? String ?? "", suffix: a["suffix"] as? String ?? "", startOffset: a["start"] as? Int, color: color.rawValue)
            self.state.highlights.append(h)
            self.clearSelection()
            self.redrawHighlights()
            self.saveAnnotations()
            self.showToast("형광펜을 칠했어요")
        }
    }

    private var lastSelection = ""
    override func selectedText() -> String { lastSelection }

    override func copySelection() {
        js("window.getSelection().toString()") { [weak self] v in
            UIPasteboard.general.string = v as? String ?? ""
            self?.clearSelection()
            self?.showToast("복사했어요")
        }
    }

    override func clearSelection() {
        js("window.getSelection().removeAllRanges()")
        selectionActive = false
    }

    // MARK: Bookmarks

    override var currentBookmark: Bookmark? {
        state.bookmarks.first { b in
            guard !b.deleted, b.page == chapter + 1 else { return false }
            let p = Int((b.ratio * Double(pages - 1)).rounded())
            return p == pageInChapter
        }
    }

    override func toggleBookmark() {
        if let b = currentBookmark {
            deleteBookmark(b.id)
            showToast("책갈피를 뺐어요")
        } else {
            let ratio = pages > 1 ? Double(pageInChapter) / Double(pages - 1) : 0
            state.bookmarks.append(Bookmark(page: chapter + 1, ratio: ratio, label: "\(chapter + 1)장"))
            saveAnnotations()
            showToast("책갈피를 꽂았어요")
        }
    }

    // MARK: Search across chapters

    private var searchTask: Task<Void, Never>?

    override func search(_ q: String) {
        searchTask?.cancel()
        searchHits = []
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        let book = self.book
        searchTask = Task {
            let hits = await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
                var out: [SearchHit] = []
                for ch in book.chapters {
                    let text = book.plainText(ch.index) as NSString
                    var range = NSRange(location: 0, length: text.length)
                    var n = 0
                    while out.count < 400 {
                        let r = text.range(of: query, options: [.caseInsensitive], range: range)
                        if r.location == NSNotFound { break }
                        let s = max(0, r.location - 30)
                        let snippet = text.substring(with: NSRange(location: s, length: min(text.length - s, r.length + 70)))
                            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                        out.append(SearchHit(page: ch.index + 1, snippet: snippet, payload: (query, n)))
                        n += 1
                        let next = r.location + r.length
                        range = NSRange(location: next, length: text.length - next)
                    }
                }
                return out
            }.value
            guard !Task.isCancelled else { return }
            searchHits = hits
            searching = false
        }
    }

    override func cancelSearch() {
        searchTask?.cancel()
        searching = false
    }

    override func go(_ hit: SearchHit) {
        guard let t = hit.payload as? (String, Int) else { go(page: hit.page); return }
        let q = t.0, n = t.1
        if hit.page - 1 == chapter, ready {
            js("shelf.find(\(q.jsonQuoted), \(n))") { [weak self] v in self?.show(page: (v as? Int) ?? 0, animated: false) }
        } else {
            pending = .find(q, n)
            load(hit.page - 1)
        }
    }

    // MARK: Plumbing

    func js(_ code: String, _ done: ((Any?) -> Void)? = nil) {
        webView.evaluateJavaScript(code) { v, _ in done?(v) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url?.scheme == "shelfbook" && navigationAction.navigationType != .linkActivated
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastWidth = webView.bounds.width
        js("shelf.setStyle(\(styleJSON))")
    }

    // MARK: Injected script

    static let script = #"""
    (function(){
      if (window.shelf) return;
      var post = function(m){ try { window.webkit.messageHandlers.shelf.postMessage(m); } catch(e){} };
      var meta = document.createElement('meta');
      meta.name = 'viewport';
      meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
      (document.head || document.documentElement).appendChild(meta);
      var style = document.createElement('style');
      style.id = 'shelf-style';
      (document.head || document.documentElement).appendChild(style);
      var cfg = null;

      function css(c){
        var m = c.margin, W = window.innerWidth;
        var s = 'html{height:100vh !important;width:100vw !important;margin:0 !important;padding:' + c.top + 'px ' + m + 'px ' + c.bottom + 'px ' + m + 'px !important;box-sizing:border-box !important;' +
          'column-width:' + (W - 2*m) + 'px !important;column-gap:' + (2*m) + 'px !important;column-fill:auto !important;overflow:visible !important;-webkit-text-size-adjust:none !important;background:' + c.bg + ' !important;}' +
          'body{margin:0 !important;padding:0 !important;background:transparent !important;font-size:' + c.size + 'px !important;line-height:' + c.line + ' !important;word-break:keep-all;overflow-wrap:break-word;widows:2;orphans:2;-webkit-user-select:text;}' +
          'img,svg,video,image{max-width:100% !important;max-height:calc(100vh - ' + (c.top + c.bottom + 4) + 'px) !important;object-fit:contain;break-inside:avoid;height:auto;}' +
          'p,li,blockquote,dd{line-height:inherit !important;}' +
          'pre{white-space:pre-wrap;}' +
          'table{max-width:100%;}' +
          'mark[data-shelf]{color:inherit !important;border-radius:2px;padding:0 1px;}' +
          'mark.shelf-find{background:rgba(255,214,0,.7) !important;color:inherit !important;}';
        if (c.font) s += 'body,p,div,span,li,dd,dt,blockquote,td,th{font-family:' + c.font + ' !important;}';
        if (c.themed) s += 'html,body{color:' + c.fg + ' !important;}body *{color:' + c.fg + ' !important;background-color:transparent !important;border-color:' + c.fg + '44 !important;}a,a *{color:' + c.link + ' !important;}';
        else s += 'html{color:' + c.fg + ';}';
        return s;
      }

      function measure(){
        var W = window.innerWidth || 1;
        var sw = document.documentElement.scrollWidth;
        return Math.max(1, Math.round(sw / W));
      }

      function whenSettled(cb){
        var imgs = Array.prototype.slice.call(document.images || []);
        var waits = imgs.filter(function(i){ return !i.complete; }).map(function(i){
          return new Promise(function(r){ i.addEventListener('load', r); i.addEventListener('error', r); });
        });
        var fonts = (document.fonts && document.fonts.ready) ? document.fonts.ready : Promise.resolve();
        var timeout = new Promise(function(r){ setTimeout(r, 1200); });
        Promise.race([Promise.all(waits.concat([fonts])), timeout]).then(function(){
          requestAnimationFrame(function(){ requestAnimationFrame(cb); });
        });
      }

      function relayout(){
        if (!cfg) return;
        style.textContent = css(cfg);
        whenSettled(function(){ post({type:'ready', pages: measure()}); });
      }

      // Text offsets over body text, like the web reader's textOffset().
      function textNodes(){
        var out = [], w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), n;
        while ((n = w.nextNode())) out.push(n);
        return out;
      }
      function offsetOf(node, off){
        var total = 0, nodes = textNodes();
        for (var i = 0; i < nodes.length; i++) {
          if (nodes[i] === node) return total + off;
          total += nodes[i].textContent.length;
        }
        if (node.nodeType === 1) {
          var r = document.createRange(); r.setStart(document.body, 0); r.setEnd(node, off);
          return r.toString().length;
        }
        return total;
      }
      function rangeFor(start, end){
        var nodes = textNodes(), total = 0, r = document.createRange(), started = false;
        for (var i = 0; i < nodes.length; i++) {
          var len = nodes[i].textContent.length;
          if (!started && start <= total + len) { r.setStart(nodes[i], Math.max(0, start - total)); started = true; }
          if (started && end <= total + len) { r.setEnd(nodes[i], Math.max(0, end - total)); return r; }
          total += len;
        }
        return null;
      }
      function locate(h, text){
        var cands = [], i = text.indexOf(h.exact);
        while (i >= 0 && cands.length < 50) { cands.push([i, i + h.exact.length]); i = text.indexOf(h.exact, i + 1); }
        if (!cands.length) {
          var chars = h.exact.replace(/\s+/g, '').slice(0, 400).split('').map(function(ch){ return ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
          if (!chars.length) return null;
          var re = new RegExp(chars.join('\\s*'), 'g'), m;
          while ((m = re.exec(text)) && cands.length < 50) cands.push([m.index, m.index + m[0].length]);
        }
        if (!cands.length) return null;
        var sq = function(s){ return s.replace(/\s+/g, ''); };
        var pre = sq(h.prefix || ''), suf = sq(h.suffix || '');
        var best = null, bestScore = -1;
        cands.forEach(function(c){
          var before = sq(text.slice(Math.max(0, c[0] - 64), c[0])), after = sq(text.slice(c[1], c[1] + 64));
          var a = 0; while (a < pre.length && a < before.length && pre[pre.length-1-a] === before[before.length-1-a]) a++;
          var b = 0; while (b < suf.length && b < after.length && suf[b] === after[b]) b++;
          var score = (a + b) * 100000 - Math.abs(c[0] - (h.start >= 0 ? h.start : 0));
          if (score > bestScore) { bestScore = score; best = c; }
        });
        return best;
      }
      function unwrap(sel){
        Array.prototype.slice.call(document.querySelectorAll(sel)).forEach(function(m){
          var p = m.parentNode; while (m.firstChild) p.insertBefore(m.firstChild, m); p.removeChild(m); p.normalize();
        });
      }
      function wrap(range, make){
        var nodes = textNodes().filter(function(n){ return range.intersectsNode(n); });
        nodes.forEach(function(n){
          var s = n === range.startContainer ? range.startOffset : 0;
          var e = n === range.endContainer ? range.endOffset : n.textContent.length;
          if (e <= s) return;
          var mid = n.splitText(s); mid.splitText(e - s);
          var mark = make(); mid.parentNode.insertBefore(mark, mid); mark.appendChild(mid);
        });
      }
      function pageOfNode(node){
        var r = document.createRange(); r.selectNodeContents(node);
        var rect = r.getClientRects()[0] || (node.getBoundingClientRect ? node.getBoundingClientRect() : null);
        if (!rect) return 0;
        return Math.max(0, Math.floor((rect.left + window.scrollX + 1) / window.innerWidth));
      }

      window.shelf = {
        setStyle: function(c){ cfg = c; relayout(); },
        relayout: relayout,
        pageOfFragment: function(id){
          var el = document.getElementById(id) || document.querySelector('[name="' + id + '"]');
          return el ? pageOfNode(el) : 0;
        },
        pageOfMark: function(id){
          var el = document.querySelector('mark[data-shelf="' + id + '"]');
          return el ? pageOfNode(el) : 0;
        },
        anchor: function(){
          var sel = window.getSelection();
          if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
          var r = sel.getRangeAt(0);
          var text = document.body.textContent;
          var s = offsetOf(r.startContainer, r.startOffset), e = offsetOf(r.endContainer, r.endOffset);
          if (e <= s) return null;
          return { exact: text.slice(s, e), prefix: text.slice(Math.max(0, s - 32), s), suffix: text.slice(e, e + 32), start: s };
        },
        highlight: function(list){
          unwrap('mark[data-shelf]');
          var text = document.body.textContent;
          var found = [];
          list.forEach(function(h){ var c = locate(h, text); if (c) found.push([c, h]); });
          found.sort(function(a, b){ return b[0][0] - a[0][0]; });
          found.forEach(function(f){
            var r = rangeFor(f[0][0], f[0][1]); if (!r) return;
            wrap(r, function(){ var m = document.createElement('mark'); m.setAttribute('data-shelf', f[1].id); m.style.background = f[1].color; return m; });
          });
        },
        find: function(q, n){
          unwrap('mark.shelf-find');
          var text = document.body.textContent.toLowerCase(), ql = q.toLowerCase(), i = -1, k = 0;
          var plainIdx = text.indexOf(ql);
          i = plainIdx;
          while (i >= 0 && k < n) { i = text.indexOf(ql, i + 1); k++; }
          if (i < 0) i = plainIdx;
          if (i < 0) return 0;
          var r = rangeFor(i, i + q.length); if (!r) return 0;
          wrap(r, function(){ var m = document.createElement('mark'); m.className = 'shelf-find'; return m; });
          var el = document.querySelector('mark.shelf-find');
          setTimeout(function(){ unwrap('mark.shelf-find'); }, 2500);
          return el ? pageOfNode(el) : 0;
        }
      };

      var selTimer = null;
      document.addEventListener('selectionchange', function(){
        clearTimeout(selTimer);
        selTimer = setTimeout(function(){
          var s = window.getSelection();
          post({type:'selection', has: !!(s && !s.isCollapsed && s.toString().trim().length)});
        }, 120);
      });
      document.addEventListener('click', function(e){
        var a = e.target.closest ? e.target.closest('a[href]') : null;
        if (a) { e.preventDefault(); post({type:'link', href: a.getAttribute('href')}); return; }
        var m = e.target.closest ? e.target.closest('mark[data-shelf]') : null;
        var s = window.getSelection();
        if (s && !s.isCollapsed) return;
        if (m) { post({type:'mark', id: m.getAttribute('data-shelf')}); return; }
        post({type:'tap', x: e.clientX / window.innerWidth});
      }, true);
      window.addEventListener('resize', function(){ if (cfg) relayout(); });
    })();
    """#
}

final class EpubContainer: UIView {
    weak var model: EpubReaderModel?
    override func layoutSubviews() {
        super.layoutSubviews()
        model?.layoutChanged()
    }
}

struct EpubHost: UIViewRepresentable {
    let model: EpubReaderModel
    func makeUIView(context: Context) -> EpubContainer {
        let c = EpubContainer()
        c.model = model
        model.webView.frame = c.bounds
        model.webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        c.addSubview(model.webView)
        return c
    }
    func updateUIView(_ uiView: EpubContainer, context: Context) {}
}
