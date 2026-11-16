import SwiftUI

/// Top level of the share as a list of shelves.
struct LibraryView: View {
    @ObservedObject private var catalog = Catalog.shared

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
            List {
                if catalog.indexing || catalog.error != nil {
                    IndexingBanner().listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section("서재") {
                    ForEach(shelves, id: \.name) { shelf in
                        NavigationLink { ShelfView(folder: shelf.name) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: shelf.name == "책" ? "book.closed.fill" : "books.vertical.fill")
                                    .foregroundStyle(.orange).frame(width: 28)
                                Text(shelf.name.replacingOccurrences(of: "_", with: " "))
                                Spacer()
                                Text("\(shelf.files.count)권").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if catalog.exams.count > 0 {
                    Section("시험지") {
                        NavigationLink { ExamFinderView() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "list.clipboard").foregroundStyle(.indigo).frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("기출문제 찾기")
                                    Text("연도·과목별, 정답 바로 연결").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(catalog.exams.count)개").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink { FolderView(path: "") } label: {
                        Label("폴더 그대로 보기", systemImage: "folder")
                    }
                }
            }
            .listStyle(.insetGrouped)
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
                SearchField(text: $query, prompt: "이 서재에서 찾기").padding(.horizontal)
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
        .scrollDismissesKeyboard(.immediately)
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

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SearchView: View {
    @ObservedObject private var catalog = Catalog.shared
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    SearchField(text: $query, prompt: "모든 책과 시험지 검색")
                    if query.isEmpty {
                        Text("제목, 과목, 연도, 폴더 이름으로 찾을 수 있어요. 여러 단어는 띄어 쓰세요.\n예) 2024 수능 국어 · 화학 정답 · 불편한 편의점")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        let results = catalog.search(query)
                        Text(results.count >= 300 ? "300개 이상" : "\(results.count)개").font(.footnote).foregroundStyle(.secondary)
                        ForEach(results) { f in
                            BookRow(file: f)
                            Divider()
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("검색")
        }
    }
}
