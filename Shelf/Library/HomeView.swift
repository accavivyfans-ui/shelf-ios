import SwiftUI

struct RecentItem: Identifiable {
    var file: BookFile
    var date: Date
    var fromWeb: Bool
    var id: String { file.path }
}

/// "읽는 중" tab: what I'm reading now, as a list.
struct HomeView: View {
    @ObservedObject private var store = ReadingStore.shared
    @ObservedObject private var sync = SyncCenter.shared
    @ObservedObject private var catalog = Catalog.shared
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

    var body: some View {
        let items = recent
        let reading = items.filter { store.existing($0.file.path)?.finished != true }
        let finished = items.filter { store.existing($0.file.path)?.finished == true }
        NavigationStack {
            List {
                Section {
                    IndexingBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    StatsStrip()
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    if let first = reading.first {
                        ContinueCard(file: first.file, fromWeb: first.fromWeb)
                            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                            .listRowBackground(Color.clear)
                    }
                }
                if reading.isEmpty {
                    Section { EmptyHome().listRowBackground(Color.clear) }
                } else {
                    Section("읽는 중 \(reading.count)권") {
                        ForEach(reading) { item in
                            BookRow(file: item.file, subtitle: subtitle(item))
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { store.forget(item.file.path) } label: { Label("빼기", systemImage: "minus.circle") }
                                    Button { store.update(item.file.path) { $0.finished = true } } label: { Label("다 읽음", systemImage: "checkmark") }.tint(.green)
                                }
                        }
                    }
                }
                if !finished.isEmpty {
                    Section("다 읽은 책 \(finished.count)권") {
                        ForEach(finished) { item in
                            BookRow(file: item.file, subtitle: subtitle(item))
                                .swipeActions(edge: .trailing) {
                                    Button { store.update(item.file.path) { $0.finished = false } } label: { Label("다시 읽기", systemImage: "arrow.uturn.backward") }.tint(.orange)
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("읽는 중")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarLeading) { SyncBadge() }
            }
            .refreshable {
                await sync.refresh(force: true)
                catalog.refresh()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func subtitle(_ item: RecentItem) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        var s = f.string(from: item.date)
        if item.fromWeb { s += " · 웹에서 읽음" }
        if let st = store.existing(item.file.path), st.percent > 0 {
            s += st.kind == .pdf ? " · \(st.page)/\(st.pageCount)쪽" : " · \(st.page)장"
        }
        return s
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
