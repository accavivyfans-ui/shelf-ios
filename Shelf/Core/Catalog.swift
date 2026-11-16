import Foundation

enum BookKind: String, Codable { case pdf, epub }

/// One readable file in the share. `path` is relative to the books folder ("고등교과서/화학.pdf").
struct BookFile: Codable, Hashable, Identifiable {
    var id: String
    var path: String
    var size: Int64
    var modified: Int

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var folderName: String { (folder as NSString).lastPathComponent }
    var topFolder: String { path.split(separator: "/").first.map(String.init) ?? "" }
    var kind: BookKind? {
        let e = (name as NSString).pathExtension.lowercased()
        return e == "pdf" ? .pdf : e == "epub" ? .epub : nil
    }
    var title: String { Titles.clean(name: name, folder: folderName) }
    var isExam: Bool { topFolder == "기출문제" || topFolder == "기출정답" || topFolder.hasPrefix("모의고사") }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

enum Titles {
    /// Turns raw file names into book titles: drops extensions, Anna's Archive metadata,
    /// "(용량 변경)" style tags and the session prefix that exam files repeat.
    static func clean(name: String, folder: String) -> String {
        var s = (name as NSString).deletingPathExtension
        if let r = s.range(of: " -- ") { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: ".no_watermark", with: "").replacingOccurrences(of: ".ko.mono", with: "")
        if !folder.isEmpty, s.hasPrefix(folder), s.count > folder.count + 1 {
            s = String(s.dropFirst(folder.count)).trimmingCharacters(in: .whitespaces)
        }
        for junk in ["(용량 변경)", "(용량변경)", "[홍보용]", "_교과서 PDF", "_교과서PDF", "교과서 전체 PDF", "_홍보용", "_홍보관용", "_홍보관", "(저용량)", "_전시본", " 전시본", "(웹용)", "_펼침면", "(펼침)", "_펼침", " 펼침", "(1)", " (1)"] {
            s = s.replacingOccurrences(of: junk, with: " ")
        }
        s = s.replacingOccurrences(of: "_", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -·"))
        return s.isEmpty ? (name as NSString).deletingPathExtension : s
    }
}

// MARK: - Subjects

enum Subjects {
    static let order = ["국어", "수학", "영어", "한국사", "사회", "과학", "직업", "제2외국어·한문", "정보·기술", "예체능", "기타"]

    private static let table: [(String, [String])] = [
        ("한국사", ["한국사", "국사"]),
        ("국어", ["국어", "언어", "화법", "언매", "문학", "독서", "매체", "작문"]),
        ("수학", ["수학", "미적", "확률", "기하", "대수", "가형", "나형", "수리"]),
        ("영어", ["영어", "외국어(영어)", "English"]),
        ("제2외국어·한문", ["일본", "중국", "독일", "프랑스", "스페인", "러시아", "아랍", "베트남", "한문", "제2외국어"]),
        ("과학", ["물리", "화학", "생명", "생물", "지구", "과학", "과탐", "역학", "전자기", "물질", "세포", "유전", "행성", "우주"]),
        ("사회", ["사회", "윤리", "지리", "세계사", "동아시아", "경제", "정치", "법", "역사", "사탐", "도덕", "시민"]),
        ("직업", ["농업", "공업", "상업", "수산", "해운", "해양", "가사", "직업", "인간 발달", "회계", "기초 제도", "프로그래밍"]),
        ("정보·기술", ["정보", "인공지능", "기술", "반도체", "디지털"]),
        ("예체능", ["음악", "미술", "체육", "스포츠"]),
    ]

    static func infer(_ title: String) -> String {
        for (subject, keys) in table where keys.contains(where: { title.localizedCaseInsensitiveContains($0) }) { return subject }
        return "기타"
    }
}

// MARK: - Exams

struct ExamPaper: Hashable, Identifiable {
    var file: BookFile
    var category: String      // 수능 / 모의평가 / 학력평가
    var session: String       // 폴더 이름
    var year: Int
    var month: Int            // 수능 = 11
    var subject: String
    var label: String
    var isAnswer: Bool
    var id: String { file.id }
}

enum Exams {
    static let categories = ["수능", "모의평가", "학력평가"]

    static func parse(_ f: BookFile) -> ExamPaper? {
        let parts = f.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "기출문제" || parts[0] == "기출정답" else { return nil }
        let category = parts[1]
        let session = parts[parts.count - 2]
        let year = firstNumber(session, digits: 4) ?? 0
        var month = 11
        if let r = session.range(of: #"(\d{1,2})월"#, options: .regularExpression) {
            month = Int(session[r].dropLast()) ?? 11
        } else if category == "수능" { month = 11 }
        let label = f.title
        let isAnswer = parts[0] == "기출정답" || label.contains("정답") || label.contains("해설")
        return ExamPaper(file: f, category: category, session: session, year: year, month: month, subject: Subjects.infer(label), label: label, isAnswer: isAnswer)
    }

    static func firstNumber(_ s: String, digits: Int) -> Int? {
        guard let r = s.range(of: "\\d{\(digits)}", options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    private static let noise = ["문제지", "문제", "정답표", "정답", "해설", "홀수형", "짝수형", "학평", "모평", "학력평가", "모의평가", "대수능", "수능", "평가원", "서울", "인천", "경기", "부산", "대구", "최종", "교시", "영역", "탐구", "사탐", "과탐", "직탐", "형"]

    /// Character bigrams of the subject part of a label (dates, numbers and exam words removed).
    static func grams(_ label: String) -> Set<String> {
        var s = label.replacingOccurrences(of: "\\d{4}학년도|\\d{4}년|\\d+월|\\d+", with: "", options: .regularExpression)
        for n in noise { s = s.replacingOccurrences(of: n, with: "") }
        s = s.replacingOccurrences(of: "Ⅰ", with: "1").replacingOccurrences(of: "Ⅱ", with: "2").replacingOccurrences(of: "I", with: "1")
        let chars = Array(s.unicodeScalars.filter { ($0.value >= 0xAC00 && $0.value <= 0xD7A3) || CharacterSet.letters.contains($0) || $0 == "1" || $0 == "2" })
        guard chars.count > 1 else { return [] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) {
            var g = String.UnicodeScalarView()
            g.append(chars[i]); g.append(chars[i + 1])
            out.insert(String(g))
        }
        return out
    }

    static func score(_ a: ExamPaper, _ b: ExamPaper) -> Int {
        grams(a.label).intersection(grams(b.label)).count * 10 + (a.subject == b.subject ? 3 : 0)
    }

    /// Best answer key for a question paper: same session folder, most shared subject letters.
    static func answer(for paper: ExamPaper, in answers: [ExamPaper]) -> ExamPaper? {
        var best: (ExamPaper, Int)?
        for a in answers where a.session == paper.session && a.category == paper.category {
            let sc = score(paper, a)
            if sc > (best?.1 ?? 0) { best = (a, sc) }
        }
        guard let b = best, b.1 >= 3 else { return nil }
        return b.0
    }
}

// MARK: - Index of the whole share

@MainActor
final class Catalog: ObservableObject {
    static let shared = Catalog()

    @Published private(set) var files: [BookFile] = []
    @Published private(set) var indexing = false
    @Published private(set) var indexedFolders = 0
    @Published private(set) var rootId: String?
    @Published private(set) var updatedAt: Date?
    @Published var error: String?

    private(set) var byPath: [String: BookFile] = [:]
    private(set) var exams: [ExamPaper] = []
    private(set) var answersBySession: [String: [ExamPaper]] = [:]

    private var cacheURL: URL { Paths.support.appendingPathComponent("catalog.json") }

    private struct Cache: Codable { var rootId: String?; var files: [BookFile]; var date: Date }

    private init() {
        if let data = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: data) {
            rootId = c.rootId
            updatedAt = c.date
            apply(c.files)
        }
    }

    private func apply(_ list: [BookFile]) {
        files = list
        byPath = Dictionary(list.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        exams = list.compactMap(Exams.parse)
        answersBySession = Dictionary(grouping: exams.filter(\.isAnswer)) { "\($0.category)/\($0.session)" }
    }

    func answer(for file: BookFile) -> BookFile? {
        guard let p = Exams.parse(file), !p.isAnswer else { return nil }
        return Exams.answer(for: p, in: answersBySession["\(p.category)/\(p.session)"] ?? [])?.file
    }

    func question(for file: BookFile) -> BookFile? {
        guard let p = Exams.parse(file), p.isAnswer else { return nil }
        var best: (ExamPaper, Int)?
        for q in exams where !q.isAnswer && q.session == p.session && q.category == p.category {
            let sc = Exams.score(q, p)
            if sc > (best?.1 ?? 0) { best = (q, sc) }
        }
        guard let b = best, b.1 >= 10 else { return nil }
        return b.0.file
    }

    /// Finds the books folder inside the share (falls back to the share root).
    func resolveRoot() async throws -> String? {
        if let rootId { return rootId }
        let top = try await DriveClient.shared.list(nil)
        let id = top.first(where: { $0.isDir && $0.name == "books" })?.id
        rootId = id
        return id
    }

    func refreshIfStale() {
        if files.isEmpty || (updatedAt ?? .distantPast) < Date().addingTimeInterval(-6 * 3600) { refresh() }
    }

    func refresh() {
        guard !indexing else { return }
        indexing = true
        indexedFolders = 0
        error = nil
        Task {
            do {
                let root = try await resolveRoot()
                var result: [BookFile] = []
                var queue: [(String?, String)] = [(root, "")]
                while !queue.isEmpty {
                    let batch = Array(queue.prefix(8))
                    queue.removeFirst(batch.count)
                    let listed = try await withThrowingTaskGroup(of: (String, [DriveItem]).self) { group in
                        for (id, prefix) in batch {
                            group.addTask { (prefix, try await DriveClient.shared.list(id)) }
                        }
                        var out: [(String, [DriveItem])] = []
                        for try await r in group { out.append(r) }
                        return out
                    }
                    for (prefix, items) in listed {
                        for it in items {
                            let p = prefix.isEmpty ? it.name : prefix + "/" + it.name
                            if it.isDir {
                                if !it.name.hasPrefix(".") { queue.append((it.id, p)) }
                            } else {
                                let f = BookFile(id: it.id, path: p, size: it.size, modified: it.modified)
                                if f.kind != nil { result.append(f) }
                            }
                        }
                    }
                    indexedFolders += batch.count
                }
                result.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                apply(result)
                updatedAt = Date()
                if let data = try? JSONEncoder().encode(Cache(rootId: rootId, files: result, date: Date())) {
                    try? data.write(to: cacheURL, options: .atomic)
                }
            } catch {
                self.error = error.localizedDescription
            }
            indexing = false
        }
    }

    func search(_ q: String, limit: Int = 300) -> [BookFile] {
        let words = q.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var out: [BookFile] = []
        for f in files {
            let hay = f.path
            if words.allSatisfy({ hay.localizedCaseInsensitiveContains($0) }) {
                out.append(f)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
