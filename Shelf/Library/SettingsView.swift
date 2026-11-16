import SwiftUI

struct SetupView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var link = ""
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "books.vertical.fill").font(.system(size: 64)).foregroundStyle(.orange)
            Text("서재").font(.largeTitle.weight(.bold))
            Text("NAS의 Synology Drive 공유 링크를 붙여 넣으면\n그 안의 책과 시험지를 바로 읽을 수 있어요.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                TextField("http://…/d/s/…/…", text: $link, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    if let s = UIPasteboard.general.string { link = s }
                } label: { Label("클립보드에서 붙여넣기", systemImage: "doc.on.clipboard") }
                .font(.subheadline)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button {
                Task { await connect() }
            } label: {
                HStack { if checking { ProgressView().tint(.white) }; Text("연결하기") }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(link.isEmpty || checking)
            Spacer()
        }
        .padding(28)
    }

    private func connect() async {
        guard let s = ShareLink(string: link) else { error = "공유 링크 형식이 아니에요 (…/d/s/…/…)"; return }
        checking = true
        defer { checking = false }
        settings.share = s
        await DriveClient.shared.invalidateToken()
        do {
            _ = try await DriveClient.shared.list(nil)
            error = nil
            Catalog.shared.refresh()
        } catch {
            settings.share = nil
            self.error = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var sync = SyncCenter.shared
    @ObservedObject private var catalog = Catalog.shared
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var nas = NasOps.shared
    @State private var showNasLogin = false
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanMessage: String?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Circle().fill(sync.online ? Color.green : Color.gray).frame(width: 9, height: 9)
                        Text(sync.online ? "StudyOS 연결됨" : "StudyOS 연결 안 됨")
                        Spacer()
                        if sync.refreshing { ProgressView() }
                    }
                    Toggle("웹과 진도·형광펜 동기화", isOn: $settings.syncEnabled)
                    TextField("http://100.84.240.95:3000", text: $settings.studyOSAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("웹에 등록된 책", value: "\(sync.webDocs.count)권")
                    if let d = sync.lastSync { LabeledContent("마지막 동기화", value: d.formatted(date: .omitted, time: .shortened)) }
                    Button("지금 동기화") { Task { await sync.refresh(force: true) } }
                    Button("웹 서재 폴더 다시 검색") {
                        Task { scanMessage = await sync.scanWebLibrary() }
                    }
                    if let scanMessage { Text(scanMessage).font(.footnote).foregroundStyle(.secondary) }
                    if let e = sync.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
                } header: { Text("StudyOS 웹 연동") } footer: {
                    Text("Tailscale을 켜면 앱에서 읽은 쪽·형광펜·책갈피·읽은 시간이 웹 StudyOS에 그대로 반영돼요. 꺼져 있을 때 읽은 진도는 다음에 연결될 때 올라가요. 웹에 등록되지 않은 파일(대부분의 기출)은 '웹 서재 폴더 다시 검색'으로 웹에 등록할 수 있어요.")
                }

                Section("NAS 공유 링크") {
                    TextField("공유 링크", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote)
                    Button("링크 저장") {
                        if let s = ShareLink(string: link) {
                            settings.share = s
                            Task { await DriveClient.shared.invalidateToken(); catalog.refresh() }
                        }
                    }
                    .disabled(ShareLink(string: link) == nil || ShareLink(string: link) == settings.share)
                }

                Section {
                    if let a = nas.account {
                        LabeledContent("로그인", value: a)
                        Button("로그아웃", role: .destructive) { nas.logout() }
                    } else {
                        Button("NAS 계정으로 로그인") { showNasLogin = true }
                    }
                } header: { Text("올리기·삭제") } footer: {
                    Text("폴더 화면 오른쪽 위 버튼으로 PDF·EPUB을 올리고, 책을 길게 눌러 ‘NAS에서 삭제’로 지울 수 있어요. 지운 파일은 Synology Drive 휴지통으로 가요.")
                }

                Section("서재") {
                    LabeledContent("책·시험지", value: "\(catalog.files.count)개")
                    if let d = catalog.updatedAt { LabeledContent("목록 갱신", value: d.formatted(date: .abbreviated, time: .shortened)) }
                    Button(catalog.indexing ? "갱신 중… (\(catalog.indexedFolders))" : "서재 목록 새로고침") { catalog.refresh() }
                        .disabled(catalog.indexing)
                    LabeledContent("기기에 받은 용량", value: ByteCountFormatter.string(fromByteCount: downloads.downloadedBytes, countStyle: .file))
                    Button("받은 책 모두 지우기", role: .destructive) { confirmClear = true }
                }

                Section {
                    LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .onAppear { link = settings.share?.text ?? "" }
            .sheet(isPresented: $showNasLogin) { NasLoginView() }
            .confirmationDialog("기기에 받은 책 파일을 모두 지울까요? 읽은 기록과 형광펜은 남아요.", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("모두 지우기", role: .destructive) {
                    try? FileManager.default.removeItem(at: Paths.books)
                    _ = Paths.books
                    for f in catalog.files where downloads.isDownloaded(f) { downloads.delete(f) }
                    downloads.delete(BookFile(id: "_", path: "_", size: 0, modified: 0))
                }
            }
        }
    }
}
