import SwiftUI
import UIKit

/// Opens a book full screen from anywhere.
@MainActor
final class Opener: ObservableObject {
    static let shared = Opener()
    @Published var file: BookFile?
    /// An active search bar blocks our full-screen reader, so close it first.
    func open(_ f: BookFile) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        if let search = Self.activeSearch(window?.rootViewController) {
            search.isActive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.file = f }
            return
        }
        file = f
    }

    private static func activeSearch(_ vc: UIViewController?) -> UISearchController? {
        guard let vc else { return nil }
        if let s = vc as? UISearchController, s.isActive { return s }
        if let s = vc.navigationItem.searchController, s.isActive { return s }
        for c in vc.children { if let s = activeSearch(c) { return s } }
        return activeSearch(vc.presentedViewController)
    }
}

struct BookCover: View {
    let file: BookFile
    var width: CGFloat = 110
    @ObservedObject private var covers = Covers.shared

    var body: some View {
        let img = covers.image(for: file)
        ZStack {
            if let img {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                GeneratedCover(title: SyncCenter.shared.webDoc(file.path)?.title ?? file.title, subtitle: subtitle)
            }
        }
        .frame(width: width, height: width * 1.38)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 3)
        .onAppear { if img == nil { covers.request(file) } }
    }

    private var subtitle: String {
        if let p = Exams.parse(file) { return p.session }
        return file.folderName.replacingOccurrences(of: "_", with: " ")
    }
}

struct ProgressLine: View {
    let state: ReadingState?
    var body: some View {
        if let s = state, s.percent > 0 {
            if s.finished {
                Label("다 읽음", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
            } else {
                HStack(spacing: 4) {
                    ProgressView(value: min(1, s.percent / 100)).frame(width: 40).tint(.orange)
                    Text("\(Int(s.percent))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(" ").font(.caption2)
        }
    }
}

struct BookTile: View {
    let file: BookFile
    var width: CGFloat = 108
    @ObservedObject private var store = ReadingStore.shared
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        Button { Opener.shared.open(file) } label: {
            VStack(alignment: .leading, spacing: 5) {
                BookCover(file: file, width: width)
                    .overlay(alignment: .bottomTrailing) { badge.padding(4) }
                Text(SyncCenter.shared.webDoc(file.path)?.title ?? file.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .leading)
                ProgressLine(state: store.existing(file.path))
            }
        }
        .buttonStyle(.plain)
        .contextMenu { BookMenu(file: file) }
    }

    @ViewBuilder private var badge: some View {
        if let p = downloads.progress[file.id] {
            ProgressView(value: p).progressViewStyle(.circular).scaleEffect(0.7)
                .padding(3).background(.thinMaterial, in: Circle())
        } else if downloads.isDownloaded(file) {
            Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.white, .black.opacity(0.5))
        }
    }
}

struct BookRow: View {
    let file: BookFile
    var subtitle: String?
    @ObservedObject private var store = ReadingStore.shared
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        Button { Opener.shared.open(file) } label: {
            HStack(spacing: 12) {
                BookCover(file: file, width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(SyncCenter.shared.webDoc(file.path)?.title ?? file.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                    Text(subtitle ?? file.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 8) {
                        ProgressLine(state: store.existing(file.path))
                        Text(file.sizeText).font(.caption2).foregroundStyle(.tertiary)
                        if let p = downloads.progress[file.id] { ProgressView(value: p).frame(width: 40) }
                        else if downloads.isDownloaded(file) { Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { BookMenu(file: file) }
    }
}

struct BookMenu: View {
    let file: BookFile
    var body: some View {
        Button { Opener.shared.open(file) } label: { Label("읽기", systemImage: "book") }
        if Downloads.shared.isDownloaded(file) {
            Button(role: .destructive) { Downloads.shared.delete(file) } label: { Label("다운로드 삭제", systemImage: "trash") }
        } else {
            Button { Task { _ = try? await Downloads.shared.fetch(file) } } label: { Label("미리 받아두기", systemImage: "arrow.down.circle") }
        }
        if let a = Catalog.shared.answer(for: file) {
            Button { Opener.shared.open(a) } label: { Label("정답·해설 열기", systemImage: "checkmark.seal") }
        }
        if ReadingStore.shared.existing(file.path) != nil {
            Button(role: .destructive) { ReadingStore.shared.forget(file.path) } label: { Label("최근 목록에서 빼기", systemImage: "clock.arrow.circlepath") }
        }
        Divider()
        Button(role: .destructive) { NasOps.shared.requestDelete(file) } label: { Label("NAS에서 삭제", systemImage: "trash.slash") }
    }
}

struct Chips<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Button { selection = item } label: {
                            Text(label(item))
                                .font(.subheadline.weight(selection == item ? .semibold : .regular))
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(selection == item ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                .foregroundStyle(selection == item ? Color.white : Color.primary)
                        }
                        .id(item)
                    }
                }
                .padding(.horizontal)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}

struct IndexingBanner: View {
    @ObservedObject var catalog = Catalog.shared
    var body: some View {
        if catalog.indexing {
            HStack(spacing: 10) {
                ProgressView()
                Text(catalog.files.isEmpty ? "서재를 정리하는 중… 폴더 \(catalog.indexedFolders)개" : "서재 목록 갱신 중… \(catalog.indexedFolders)").font(.footnote)
                Spacer()
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        } else if let e = catalog.error {
            HStack {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text(e).font(.footnote)
                Spacer()
                Button("다시") { catalog.refresh() }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }
}

extension Double {
    var minutesText: String {
        let m = Int(self / 60)
        if m < 60 { return "\(m)분" }
        return "\(m / 60)시간 \(m % 60)분"
    }
}
