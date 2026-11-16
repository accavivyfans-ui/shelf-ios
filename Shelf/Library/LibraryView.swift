import SwiftUI

/// Top level of the share as bookshelves, plus a raw folder view.
struct LibraryView: View {
    @ObservedObject private var catalog = Catalog.shared
    @ObservedObject private var settings = AppSettings.shared

    private var shelves: [(name: String, files: [BookFile])] {
        let groups = Dictionary(grouping: catalog.files.filter { $0.topFolder != "기출문제" && $0.topFolder != "기출정답" }, by: \.topFolder)
        let order = ["책", "고등교과서", "중등교과서"]
        return groups.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? 99, ib = order.firstIndex(of: b.key) ?? 99
            return ia != ib ? ia < ib : a.key < b.key
        }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    IndexingBanner()
                    let examCount = catalog.exams.count
                    if examCount > 0 {
                        NavigationLink { ExamFinderView() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "list.clipboard").font(.title2).foregroundStyle(.white)
                                    .frame(width: 50, height: 50).background(Color.indigo, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("기출문제 찾기").font(.headline).foregroundStyle(.primary)
                                    Text("수능·모의평가·학력평가 \(examCount)개 · 연도/과목별, 정답 바로 연결").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .padding(.horizontal)
                    }
                    ForEach(shelves, id: \.name) { shelf in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink { ShelfView(folder: shelf.name) } label: {
                                HStack {
                                    Text(shelf.name.replacingOccurrences(of: "_", with: " ")).font(.title3.weight(.bold)).foregroundStyle(.primary)
                                    Text("\(shelf.files.count)").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("모두 보기").font(.subheadline)
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }
                            .padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 16) {
                                    ForEach(shelf.files.prefix(24)) { BookTile(file: $0) }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    NavigationLink { FolderView(path: "") } label: {
                        Label("폴더 그대로 보기", systemImage: "folder").padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("서재")
            .refreshable { catalog.refresh() }
        }
    }
}

/// One shelf (top folder) as a grid with subject filters and sorting.
struct ShelfView: View {
    let folder: String
    @ObservedObject private var catalog = Catalog.shared
    @ObservedObject private var store = ReadingStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var subject = "전체"
    @State private var sort = 0
    @State private var query = ""

    private var files: [BookFile] {
        catalog.files.filter { $0.path.hasPrefix(folder + "/") }
    }

    private func subjectOf(_ f: BookFile) -> String {
        if let s = SyncCenter.shared.webDoc(f.path)?.subject, !s.isEmpty { return Subjects.infer(s) == "기타" ? s : Subjects.infer(s) }
        return Subjects.infer(f.title)
    }

    var body: some View {
        let all = files
        let subjects = ["전체"] + Subjects.order.filter { s in all.contains { subjectOf($0) == s } } + Array(Set(all.map(subjectOf)).subtracting(Subjects.order)).sorted()
        var shown = all.filter { subject == "전체" || subjectOf($0) == subject }
        if !query.isEmpty { shown = shown.filter { $0.title.localizedCaseInsensitiveContains(query) } }
        if sort == 1 { shown.sort { (store.existing($0.path)?.lastOpened ?? .distantPast) > (store.existing($1.path)?.lastOpened ?? .distantPast) } }
        if sort == 2 { shown.sort { $0.size < $1.size } }

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if subjects.count > 2 { Chips(items: subjects, selection: $subject) { $0 } }
                if settings.gridStyle {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16, alignment: .top)], spacing: 22) {
                        ForEach(shown) { BookTile(file: $0, width: 104) }
                    }
                    .padding(.horizontal)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(shown) { BookRow(file: $0) ; Divider() }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .searchable(text: $query, prompt: "이 서재에서 찾기")
        .navigationTitle(folder.replacingOccurrences(of: "_", with: " "))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("정렬", selection: $sort) {
                        Text("이름순").tag(0)
                        Text("최근 읽은 순").tag(1)
                        Text("작은 파일 먼저").tag(2)
                    }
                    Toggle(isOn: $settings.gridStyle) { Label("표지로 보기", systemImage: "square.grid.2x2") }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }
        }
    }
}

/// The share's folders as they are, built from the index.
struct FolderView: View {
    let path: String
    @ObservedObject private var catalog = Catalog.shared

    var body: some View {
        let prefix = path.isEmpty ? "" : path + "/"
        var dirs: [String: Int] = [:]
        var files: [BookFile] = []
        for f in catalog.files where f.path.hasPrefix(prefix) {
            let rest = f.path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { dirs[String(rest[..<slash]), default: 0] += 1 } else { files.append(f) }
        }
        let sortedDirs = dirs.keys.sorted { a, b in
            let an = a.first?.isNumber == true, bn = b.first?.isNumber == true
            if an && bn { return a.localizedStandardCompare(b) == .orderedDescending }
            if an != bn { return !an }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return List {
            ForEach(sortedDirs, id: \.self) { d in
                NavigationLink { FolderView(path: prefix + d) } label: {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.orange)
                        Text(d)
                        Spacer()
                        Text("\(dirs[d] ?? 0)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(files) { BookRow(file: $0, subtitle: $0.name) }
        }
        .listStyle(.plain)
        .navigationTitle(path.isEmpty ? "books" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SearchView: View {
    @ObservedObject private var catalog = Catalog.shared
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Text("제목, 과목, 연도, 폴더 이름으로 찾을 수 있어요. 여러 단어는 띄어 쓰세요.\n예) 2024 수능 국어 · 화학 정답 · 불편한 편의점")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    let results = catalog.search(query)
                    Section("\(results.count >= 300 ? "300+" : "\(results.count)")개") {
                        ForEach(results) { BookRow(file: $0) }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "모든 책과 시험지 검색")
            .navigationTitle("검색")
        }
    }
}
