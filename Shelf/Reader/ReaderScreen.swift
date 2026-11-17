import SwiftUI
import UIKit

/// Downloads, merges web progress, tracks reading time and hosts the right engine.
@MainActor
final class ReaderSession: ObservableObject {
    enum Phase { case loading, ready(ReaderModel), failed(String) }

    let file: BookFile
    @Published var phase: Phase = .loading
    @Published var webSessionId: String?
    private var activeSince: Date?

    init(file: BookFile) { self.file = file }

    var model: ReaderModel? { if case .ready(let m) = phase { return m }; return nil }

    func open() async {
        guard case .loading = phase else { return }
        do {
            let url = try await Downloads.shared.fetch(file)
            let merged = await SyncCenter.shared.merge(file)
            var state = merged.state
            state.title = SyncCenter.shared.webDoc(file.path)?.title ?? file.title
            state.size = file.size
            let model: ReaderModel?
            switch file.kind {
            case .pdf: model = PDFReaderModel(file: file, url: url, state: state)
            case .epub: model = EpubReaderModel(file: file, url: url, state: state)
            case nil: model = nil
            }
            guard let model else {
                try? FileManager.default.removeItem(at: url)
                phase = .failed("파일을 열 수 없어요. 손상됐을 수 있어요 — 다시 받아 볼게요.")
                return
            }
            model.remoteJump = merged.remoteJump
            ReadingStore.shared.put(model.state)
            if Covers.shared.image(for: file) == nil { Covers.shared.request(file) }
            phase = .ready(model)
            resume()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func resume() {
        guard activeSince == nil else { return }
        activeSince = Date()
        Task { webSessionId = await SyncCenter.shared.startSession(file.path) }
    }

    func pause() {
        if let since = activeSince { ReadingStore.shared.logTime(Date().timeIntervalSince(since)) }
        activeSince = nil
        if let id = webSessionId {
            let pages = model.map { Set($0.visited.map { $0 / 1000 }).count } ?? 0
            SyncCenter.shared.finishSession(id, pages: pages)
            webSessionId = nil
        }
        model?.visited = []
        let path = file.path
        Task { await SyncCenter.shared.pushProgress(path) }
        ReadingStore.shared.saveNow()
    }
}

struct ReaderScreen: View {
    let file: BookFile
    @StateObject private var session: ReaderSession
    @ObservedObject private var downloads = Downloads.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(file: BookFile) {
        self.file = file
        _session = StateObject(wrappedValue: ReaderSession(file: file))
    }

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                LoadingBook(file: file, progress: downloads.progress[file.id]) { downloads.cancel(file); dismiss() }
            case .failed(let msg):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(msg).multilineTextAlignment(.center)
                    HStack {
                        Button("닫기") { dismiss() }.buttonStyle(.bordered)
                        Button("다시 시도") { session.phase = .loading; Task { await session.open() } }.buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            case .ready(let model):
                ReaderBody(model: model, session: session)
            }
        }
        .task { await session.open() }
        .onChange(of: scenePhase) { p in
            if p == .active { session.resume() } else { session.pause() }
        }
        .onDisappear { session.pause() }
    }
}

private struct LoadingBook: View {
    let file: BookFile
    let progress: Double?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            BookCover(file: file, width: 150)
            Text(file.title).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            if let p = progress {
                VStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 220)
                    Text("내려받는 중 \(Int(p * 100))% · \(file.sizeText)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            Button("취소", action: cancel).buttonStyle(.bordered)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Reader layout

struct ReaderBody: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject var session: ReaderSession
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: ReaderSheet?
    @State private var companion: BookFile?
    @State private var noteDraft = ""
    @State private var editingNote = false
    @State private var scrubbing: Double?

    enum ReaderSheet: String, Identifiable { case contents, settings, search; var id: String { rawValue } }

    private var pdf: PDFReaderModel? { model as? PDFReaderModel }
    private var epub: EpubReaderModel? { model as? EpubReaderModel }
    private var theme: ReaderTheme { settings.theme }

    var body: some View {
        ZStack {
            theme.paper.opacity(epub != nil ? 1 : 0).ignoresSafeArea()
            Group {
                if let pdf { PDFHost(model: pdf).ignoresSafeArea() }
                if let epub { EpubHost(model: epub).ignoresSafeArea() }
            }

            if !model.chromeVisible {
                VStack {
                    Spacer()
                    Text(model.pageText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(theme.isDark ? Color.white.opacity(0.45) : Color.black.opacity(0.4))
                        .padding(.bottom, 4)
                }
                .allowsHitTesting(false)
            }

            if model.chromeVisible { chrome.transition(.opacity) }

            VStack {
                Spacer()
                if model.selectionActive { SelectionBar(model: model, note: { startNote(forSelection: true) }) }
                else if let h = model.activeHighlight { HighlightBar(model: model, highlight: h, note: { noteDraft = h.comment; editingNote = true }) }
            }
            .padding(.bottom, model.chromeVisible ? 120 : 24)
            .animation(.spring(response: 0.3), value: model.selectionActive)

            if let jump = model.remoteJump { remoteBanner(jump) }
            if let t = model.toast {
                Text(t).font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!model.chromeVisible)
        .preferredColorScheme(theme.isDark ? .dark : nil)
        .onAppear {
            model.didAppear()
            UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(item: $sheet) { s in
            switch s {
            case .contents: ContentsSheet(model: model)
            case .settings: AppearanceSheet(model: model).presentationDetents(epub != nil ? [.height(520), .large] : [.height(360)])
            case .search: SearchSheet(model: model)
            }
        }
        .fullScreenCover(item: $companion) { f in ReaderScreen(file: f) }
        .alert("메모", isPresented: $editingNote) {
            TextField("메모", text: $noteDraft, axis: .vertical)
            Button("저장") { if let id = model.activeHighlightId { model.setComment(noteDraft, for: id) } }
            Button("취소", role: .cancel) {}
        }
    }

    private func startNote(forSelection: Bool) {
        model.addHighlight(.sand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if let last = model.state.highlights.last(where: { !$0.deleted }) {
                model.activeHighlightId = last.id
                noteDraft = ""
                editingNote = true
            }
        }
    }

    private var answerFile: BookFile? {
        Catalog.shared.answer(for: model.file) ?? Catalog.shared.question(for: model.file)
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 14) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                Button { sheet = .contents } label: { Image(systemName: "list.bullet") }
                Spacer()
                VStack(spacing: 1) {
                    Text(model.state.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    if SyncCenter.shared.webDoc(model.file.path) != nil {
                        Label(SyncCenter.shared.online ? "웹과 동기화" : "오프라인 · 나중에 동기화", systemImage: SyncCenter.shared.online ? "checkmark.icloud" : "icloud.slash")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 180)
                Spacer()
                if let a = answerFile {
                    Button { companion = a } label: {
                        Text(Catalog.shared.answer(for: model.file) != nil ? "정답" : "문제").font(.footnote.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Button { sheet = .search } label: { Image(systemName: "magnifyingglass") }
                Button { sheet = .settings } label: { Image(systemName: "textformat.size") }.accessibilityLabel("보기 설정")
                Button { model.toggleBookmark() } label: {
                    Image(systemName: model.currentBookmark != nil ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(model.currentBookmark != nil ? Color.red : Color.primary)
                }
            }
            .font(.body)
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)

            Spacer()

            // Bottom bar
            VStack(spacing: 8) {
                Slider(value: Binding(get: { scrubbing ?? model.progressFraction }, set: { scrubbing = $0 }), in: 0...1, onEditingChanged: { editing in
                    if !editing, let s = scrubbing { model.go(fraction: s); scrubbing = nil }
                })
                .tint(.accentColor)
                .overlay(alignment: .top) {
                    if let s = scrubbing {
                        GeometryReader { geo in
                            Text(model.scrubLabel(s))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.thickMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                                .fixedSize()
                                .position(x: min(max(geo.size.width * s, 70), geo.size.width - 70), y: -24)
                        }
                        .allowsHitTesting(false)
                    }
                }
                HStack {
                    Text(scrubbing.map { model.scrubLabel($0) } ?? model.pageText).font(.caption.monospacedDigit())
                    Spacer()
                    Text("\(Int(model.progressFraction * 100))% · \(model.detailText)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(.regularMaterial)
        }
    }

    private func remoteBanner(_ jump: RemoteProgress) -> some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("웹에서 더 읽은 위치가 있어요").font(.subheadline.weight(.semibold))
                    Text(model.file.kind == .pdf ? "\(jump.page ?? 0)쪽 · \(Int(jump.percent))%" : "\(Int(jump.percent))% 위치").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("이동") { model.applyRemote(jump); model.remoteJump = nil }.buttonStyle(.borderedProminent).controlSize(.small)
                Button { model.remoteJump = nil } label: { Image(systemName: "xmark").font(.caption) }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 14)
            .padding(.top, 64)
            Spacer()
        }
    }
}

// MARK: - Selection & highlight bars

private struct SelectionBar: View {
    @ObservedObject var model: ReaderModel
    var note: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            ForEach(HighlightColor.allCases) { c in
                Button { model.addHighlight(c) } label: {
                    Circle().fill(c.color).frame(width: 26, height: 26).overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                }
            }
            Divider().frame(height: 24)
            Button(action: note) { Image(systemName: "note.text.badge.plus") }
            Button { model.copySelection() } label: { Image(systemName: "doc.on.doc") }
        }
        .font(.title3)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

private struct HighlightBar: View {
    @ObservedObject var model: ReaderModel
    let highlight: Highlight
    var note: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            if !highlight.comment.isEmpty {
                Text(highlight.comment).font(.footnote).lineLimit(3).frame(maxWidth: 280, alignment: .leading)
            }
            HStack(spacing: 14) {
                ForEach(HighlightColor.allCases) { c in
                    Button { model.setColor(c, for: highlight.id) } label: {
                        Circle().fill(c.color).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.primary, lineWidth: highlight.tint == c ? 2 : 0))
                    }
                }
                Divider().frame(height: 24)
                Button(action: note) { Image(systemName: "note.text") }
                Button { UIPasteboard.general.string = highlight.exact; model.showToast("복사했어요") } label: { Image(systemName: "doc.on.doc") }
                Button(role: .destructive) { model.deleteHighlight(highlight.id) } label: { Image(systemName: "trash") }
            }
            .font(.title3)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }
}

// MARK: - Contents (TOC, pages, bookmarks, highlights)

struct ContentsSheet: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("목차").tag(0)
                    if model is PDFReaderModel { Text("페이지").tag(1) }
                    Text("책갈피").tag(2)
                    Text("메모").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()
                switch tab {
                case 1: if let pdf = model as? PDFReaderModel { PageGrid(model: pdf) { dismiss() } }
                case 2: bookmarks
                case 3: highlights
                default: tocList
                }
            }
            .navigationTitle(model.state.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private var tocList: some View {
        Group {
            if model.toc.isEmpty {
                empty("목차가 없는 책이에요", "list.bullet")
            } else {
                ScrollViewReader { proxy in
                    List(model.toc) { e in
                        Button {
                            model.go(e)
                            dismiss()
                        } label: {
                            HStack {
                                Text(e.label).font(e.depth == 0 ? .body.weight(.medium) : .subheadline)
                                    .foregroundStyle(current(e) ? Color.accentColor : Color.primary)
                                    .padding(.leading, CGFloat(min(e.depth, 4)) * 14)
                                Spacer()
                                Text(e.pageLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .id(e.id)
                    }
                    .listStyle(.plain)
                    .onAppear {
                        if let c = model.toc.last(where: { $0.page <= model.state.page }) { proxy.scrollTo(c.id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func current(_ e: TocEntry) -> Bool {
        model.toc.last(where: { $0.page <= model.state.page })?.id == e.id
    }

    private var bookmarks: some View {
        Group {
            let list = model.state.liveBookmarks.sorted { ($0.page, $0.ratio) < ($1.page, $1.ratio) }
            if list.isEmpty {
                empty("책갈피가 없어요\n읽는 중 오른쪽 위 🔖 버튼으로 꽂을 수 있어요", "bookmark")
            } else {
                List {
                    ForEach(list) { b in
                        Button {
                            model.goBookmark(b)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "bookmark.fill").foregroundStyle(.red)
                                Text(b.label)
                                Spacer()
                                Text(b.created, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in idx.map { list[$0].id }.forEach(model.deleteBookmark) }
                }
                .listStyle(.plain)
            }
        }
    }

    private var highlights: some View {
        Group {
            let list = model.state.liveHighlights.sorted { ($0.page, $0.startOffset ?? 0) < ($1.page, $1.startOffset ?? 0) }
            if list.isEmpty {
                empty("형광펜과 메모가 없어요\n글자를 길게 눌러 선택하면 칠할 수 있어요", "highlighter")
            } else {
                List {
                    ForEach(list) { h in
                        Button {
                            model.goHighlight(h)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(h.tint.color).frame(width: 4)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(h.exact).font(.subheadline).lineLimit(4).foregroundStyle(.primary)
                                    if !h.comment.isEmpty {
                                        Text(h.comment).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    Text(model.file.kind == .pdf ? "\(h.page)쪽" : "\(h.page)장").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .onDelete { idx in idx.map { list[$0].id }.forEach(model.deleteHighlight) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func empty(_ text: String, _ icon: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PageGrid: View {
    let model: PDFReaderModel
    var done: () -> Void
    private let cols = [GridItem(.adaptive(minimum: 96), spacing: 14)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: cols, spacing: 18) {
                    ForEach(1...max(1, model.document.pageCount), id: \.self) { n in
                        Button {
                            model.go(page: n)
                            done()
                        } label: {
                            VStack(spacing: 4) {
                                PageThumb(model: model, page: n)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(n == model.state.page ? Color.accentColor : .clear, lineWidth: 3))
                                HStack(spacing: 2) {
                                    if model.state.liveBookmarks.contains(where: { $0.page == n }) { Image(systemName: "bookmark.fill").foregroundStyle(.red) }
                                    Text("\(n)")
                                }
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .id(n)
                    }
                }
                .padding()
            }
            .onAppear { proxy.scrollTo(model.state.page, anchor: .center) }
        }
    }
}

private struct PageThumb: View {
    let model: PDFReaderModel
    let page: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() } else { Rectangle().fill(Color(.secondarySystemBackground)) }
        }
        .frame(height: 130)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .task {
            image = model.thumbnail(page, size: CGSize(width: 180, height: 260))
        }
    }
}

// MARK: - Appearance

struct AppearanceSheet: View {
    @ObservedObject var model: ReaderModel
    @ObservedObject private var s = AppSettings.shared
    @State private var brightness = Double(UIScreen.main.brightness)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "sun.min")
                    Slider(value: $brightness, in: 0.05...1)
                        .onChange(of: brightness) { UIScreen.main.brightness = CGFloat($0) }
                    Image(systemName: "sun.max")
                }
                HStack(spacing: 12) {
                    ForEach(ReaderTheme.allCases) { t in
                        Button {
                            s.theme = t
                            model.applyAppearance()
                        } label: {
                            VStack(spacing: 6) {
                                Circle().fill(t.paper).frame(width: 46, height: 46)
                                    .overlay(Text("가").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(t.ink))
                                    .overlay(Circle().stroke(s.theme == t ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: s.theme == t ? 3 : 1))
                                Text(t.label).font(.caption2).foregroundStyle(.primary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                if let pdf = model as? PDFReaderModel {
                    Picker("보기", selection: Binding(get: { s.pdfLayout }, set: { s.pdfLayout = $0; pdf.applyLayout($0) })) {
                        ForEach(PDFLayout.allCases) { l in Label(l.label, systemImage: l.icon).tag(l) }
                    }
                    .pickerStyle(.segmented)
                }
                if model is EpubReaderModel {
                    HStack {
                        Button { s.epubFontSize = max(12, s.epubFontSize - 1); model.applyAppearance() } label: { Text("가").font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 40) }
                        Divider().frame(height: 26)
                        Text("\(Int(s.epubFontSize))").font(.callout.monospacedDigit()).frame(width: 36)
                        Divider().frame(height: 26)
                        Button { s.epubFontSize = min(34, s.epubFontSize + 1); model.applyAppearance() } label: { Text("가").font(.system(size: 24)).frame(maxWidth: .infinity, minHeight: 40) }
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    Picker("글꼴", selection: Binding(get: { s.epubFont }, set: { s.epubFont = $0; model.applyAppearance() })) {
                        ForEach(EpubFont.allCases) { f in Text(f.label).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("줄 간격").font(.subheadline)
                        Slider(value: Binding(get: { s.epubLineHeight }, set: { s.epubLineHeight = $0 }), in: 1.2...2.4, step: 0.1, onEditingChanged: { e in if !e { model.applyAppearance() } })
                    }
                    HStack {
                        Text("여백").font(.subheadline)
                        Slider(value: Binding(get: { s.epubMargin }, set: { s.epubMargin = $0 }), in: 8...56, step: 4, onEditingChanged: { e in if !e { model.applyAppearance() } })
                    }
                    Picker("정렬", selection: Binding(get: { s.epubJustify }, set: { s.epubJustify = $0; model.applyAppearance() })) {
                        Text("양쪽 정렬").tag(true)
                        Text("왼쪽 정렬").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: Binding(get: { s.epubKeepWords }, set: { s.epubKeepWords = $0; model.applyAppearance() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("단어 단위로 줄바꿈")
                            Text(s.epubKeepWords ? "단어가 잘리지 않지만 양쪽 정렬이면 띄어쓰기가 벌어질 수 있어요" : "글자 단위로 줄을 바꿔 띄어쓰기 폭이 고르게 유지돼요")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("띄어쓰기").font(.subheadline)
                        Slider(value: Binding(get: { s.epubWordSpacing }, set: { s.epubWordSpacing = $0 }), in: -0.2...0.4, step: 0.05, onEditingChanged: { e in if !e { model.applyAppearance() } })
                    }
                    HStack {
                        Text("글자 간격").font(.subheadline)
                        Slider(value: Binding(get: { s.epubLetterSpacing }, set: { s.epubLetterSpacing = $0 }), in: -0.05...0.1, step: 0.01, onEditingChanged: { e in if !e { model.applyAppearance() } })
                    }
                    if s.epubWordSpacing != 0 || s.epubLetterSpacing != 0 {
                        Button("간격 기본값으로") { s.epubWordSpacing = 0; s.epubLetterSpacing = 0; model.applyAppearance() }
                            .font(.subheadline)
                    }
                }
                Toggle("가장자리 탭으로 넘기기", isOn: $s.tapToTurn)
                Toggle("화면 꺼짐 방지", isOn: Binding(get: { s.keepAwake }, set: { s.keepAwake = $0; UIApplication.shared.isIdleTimerDisabled = $0 }))
            }
            .padding(20)
        }
    }
}

// MARK: - Search

struct SearchSheet: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if model.searching { HStack { ProgressView(); Text("찾는 중… \(model.searchHits.count)개") } }
                ForEach(model.searchHits) { hit in
                    Button {
                        model.go(hit)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.file.kind == .pdf ? "\(hit.page)쪽" : "\(hit.page)장").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                            Text(hit.snippet).font(.subheadline).lineLimit(3).foregroundStyle(.primary)
                        }
                    }
                }
                if !model.searching, model.searchHits.isEmpty, !query.isEmpty {
                    Text("결과가 없어요").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "책 안에서 찾기")
            .onSubmit(of: .search) { model.search(query) }
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { model.cancelSearch(); dismiss() } } }
        }
    }
}
