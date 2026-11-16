import SwiftUI

struct RecentItem: Identifiable {
    var file: BookFile
    var date: Date
    var fromWeb: Bool
    var id: String { file.path }
}

struct HomeView: View {
    @ObservedObject private var store = ReadingStore.shared
    @ObservedObject private var sync = SyncCenter.shared
    @ObservedObject private var catalog = Catalog.shared
    @ObservedObject private var downloads = Downloads.shared
    @State private var showSettings = false

    private var recent: [RecentItem] {
        var map: [String: RecentItem] = [:]
        for s in store.states.values {
            let f = catalog.byPath[s.path] ?? s.file
            map[s.path] = RecentItem(file: f, date: s.lastOpened, fromWeb: false)
        }
        let byId = Dictionary(sync.webDocs.values.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for w in sync.webSessions {
            guard let id = w.documentId, let doc = byId[id], let f = catalog.byPath[doc.path] else { continue }
            if let e = map[doc.path], e.date >= w.startedAt { continue }
            map[doc.path] = RecentItem(file: f, date: w.startedAt, fromWeb: map[doc.path] == nil)
        }
        return map.values.sorted { $0.date > $1.date }
    }

    private var downloaded: [BookFile] {
        _ = downloads.revision
        let ids = downloads.downloadedIds()
        return catalog.files.filter { ids.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    IndexingBanner()
                    let items = recent
                    if let first = items.first {
                        ContinueCard(file: first.file, fromWeb: first.fromWeb)
                            .padding(.horizontal)
                    } else {
                        EmptyHome()
                    }
                    StatsStrip()
                        .padding(.horizontal)
                    if items.count > 1 {
                        section("최근 읽은 책") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(items.dropFirst().prefix(30)) { BookTile(file: $0.file) }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    let finished = store.states.values.filter(\.finished)
                    if !downloaded.isEmpty {
                        section("기기에 받은 책 \(downloaded.count)") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(downloaded) { BookTile(file: $0) }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    if !finished.isEmpty {
                        section("다 읽은 책 \(finished.count)") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(finished.sorted { $0.lastOpened > $1.lastOpened }) { BookTile(file: catalog.byPath[$0.path] ?? $0.file) }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("지금 읽기")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: sync.online ? "gearshape" : "gearshape.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    SyncBadge()
                }
            }
            .refreshable {
                await sync.refresh(force: true)
                catalog.refresh()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.bold)).padding(.horizontal)
            content()
        }
    }
}

struct SyncBadge: View {
    @ObservedObject private var sync = SyncCenter.shared
    var body: some View {
        HStack(spacing: 4) {
            if sync.refreshing { ProgressView().scaleEffect(0.6) }
            else { Circle().fill(sync.online ? Color.green : Color.gray).frame(width: 7, height: 7) }
            Text(sync.online ? "웹 연동" : "오프라인").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct EmptyHome: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 44)).foregroundStyle(.orange)
            Text("아직 읽은 책이 없어요").font(.headline)
            Text("아래 '서재'나 '기출'에서 책을 골라 보세요").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct ContinueCard: View {
    let file: BookFile
    let fromWeb: Bool
    @ObservedObject private var store = ReadingStore.shared

    var body: some View {
        let s = store.existing(file.path)
        Button { Opener.shared.open(file) } label: {
            HStack(alignment: .top, spacing: 16) {
                BookCover(file: file, width: 104)
                VStack(alignment: .leading, spacing: 8) {
                    Text(fromWeb ? "웹에서 읽던 책" : "이어 읽기").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(SyncCenter.shared.webDoc(file.path)?.title ?? file.title).font(.title3.weight(.bold)).lineLimit(3).foregroundStyle(.primary)
                    Text(file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let s, s.percent > 0 {
                        ProgressView(value: min(1, s.percent / 100)).tint(.orange)
                        Text(s.kind == .pdf ? "\(s.page)쪽 / \(s.pageCount)쪽 · \(Int(s.percent))%" : "\(s.page)장 · \(Int(s.percent))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Label("계속 읽기", systemImage: "book.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.orange, in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                LinearGradient(colors: [Color.orange.opacity(0.16), Color.orange.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StatsStrip: View {
    @ObservedObject private var store = ReadingStore.shared
    var body: some View {
        let today = store.days[ReadingStore.dayKey()]
        let week = (0..<7).reduce(0.0) { acc, i in acc + (store.days[ReadingStore.dayKey(Date().addingTimeInterval(Double(-i) * 86400))]?.seconds ?? 0) }
        HStack(spacing: 10) {
            stat("오늘", (today?.seconds ?? 0).minutesText, "clock")
            stat("오늘 본 쪽", "\(Set(today?.pages.map { $0.split(separator: "#").first.map(String.init) ?? "" } ?? []).count)권 · \(today?.pages.count ?? 0)", "doc.text")
            stat("이번 주", week.minutesText, "calendar")
            stat("연속", "\(store.streak)일", "flame")
        }
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(.orange)
            Text(value).font(.footnote.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
