import SwiftUI

/// Past exams by type → year → subject, each paper with its answer key one tap away.
struct ExamFinderView: View {
    @ObservedObject private var catalog = Catalog.shared
    @ObservedObject private var store = ReadingStore.shared
    @AppStorage("exam.category") private var category = "수능"
    @AppStorage("exam.year") private var year = 0
    @AppStorage("exam.subject") private var subject = "전체"

    private var questions: [ExamPaper] { catalog.exams.filter { !$0.isAnswer && $0.category == category } }

    private var years: [Int] {
        Array(Set(questions.map(\.year))).filter { $0 > 0 }.sorted(by: >)
    }

    var body: some View {
        let ys = years
        let activeYear = ys.contains(year) ? year : (ys.first ?? 0)
        let inYear = questions.filter { $0.year == activeYear }
        let subjects = ["전체"] + Subjects.order.filter { s in inYear.contains { $0.subject == s } }
        let shown = inYear.filter { subject == "전체" || $0.subject == subject }
        let sessions = Dictionary(grouping: shown, by: \.session).sorted { a, b in
            let ma = a.value.first?.month ?? 0, mb = b.value.first?.month ?? 0
            return ma != mb ? ma > mb : a.key > b.key
        }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                Picker("", selection: $category) {
                    ForEach(Exams.categories, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                Chips(items: ys, selection: Binding(get: { activeYear }, set: { year = $0 })) { "\($0)" }
                Chips(items: subjects, selection: Binding(get: { subjects.contains(subject) ? subject : "전체" }, set: { subject = $0 })) { $0 }

                if shown.isEmpty {
                    Text(catalog.files.isEmpty ? "서재 목록을 불러오는 중이에요" : "해당하는 시험지가 없어요")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(sessions, id: \.key) { entry in
                    let session = entry.key
                    let papers = entry.value
                    Section {
                        VStack(spacing: 0) {
                            ForEach(papers.sorted { a, b in
                                let ia = Subjects.order.firstIndex(of: a.subject) ?? 99, ib = Subjects.order.firstIndex(of: b.subject) ?? 99
                                return ia != ib ? ia < ib : a.label.localizedStandardCompare(b.label) == .orderedAscending
                            }) { p in
                                ExamRow(paper: p, answer: catalog.answer(for: p.file))
                                Divider().padding(.leading, 16)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)
                    } header: {
                        HStack {
                            Text(session).font(.headline)
                            Spacer()
                            Text("\(papers.count)과목").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(.systemGroupedBackground))
                    }
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("기출문제")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ExamRow: View {
    let paper: ExamPaper
    let answer: BookFile?
    @ObservedObject private var store = ReadingStore.shared

    var body: some View {
        let s = store.existing(paper.file.path)
        HStack(spacing: 12) {
            Button { Opener.shared.open(paper.file) } label: {
                HStack(spacing: 10) {
                    Image(systemName: s?.finished == true ? "checkmark.circle.fill" : (s != nil ? "circle.lefthalf.filled" : "doc.text"))
                        .foregroundStyle(s?.finished == true ? Color.green : (s != nil ? Color.orange : Color.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paper.label).font(.subheadline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(paper.subject) · \(paper.file.sizeText)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let answer {
                Button { Opener.shared.open(answer) } label: {
                    Text("정답").font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.indigo.opacity(0.14), in: Capsule())
                        .foregroundStyle(.indigo)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contextMenu { BookMenu(file: paper.file) }
    }
}
