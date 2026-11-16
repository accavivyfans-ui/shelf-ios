import SwiftUI

@main
struct ShelfApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.orange)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await SyncCenter.shared.refresh() }
                if AppSettings.shared.share != nil { Catalog.shared.refreshIfStale() }
            } else if phase == .background {
                ReadingStore.shared.saveNow()
            }
        }
    }
}

struct RootView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var opener = Opener.shared
    @ObservedObject private var nas = NasOps.shared
    @State private var tab = 0

    var body: some View {
        if settings.share == nil {
            SetupView()
        } else {
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("읽는 중", systemImage: "book.fill") }
                    .tag(0)
                LibraryView()
                    .tabItem { Label("서재", systemImage: "books.vertical.fill") }
                    .tag(1)
                NavigationStack { ExamFinderView() }
                    .tabItem { Label("기출", systemImage: "list.clipboard") }
                    .tag(2)
                SearchView()
                    .tabItem { Label("검색", systemImage: "magnifyingglass") }
                    .tag(3)
            }
            .overlay(alignment: .bottom) { NasStatusBar() }
            .sheet(isPresented: $nas.showLogin) { NasLoginView() }
            .fileImporter(isPresented: $nas.picking, allowedContentTypes: [.pdf, .epub], allowsMultipleSelection: true) { nas.picked($0) }
            .confirmationDialog(nas.pendingDelete.map { "‘\($0.name)’을(를) NAS에서 지울까요?" } ?? "",
                                isPresented: Binding(get: { nas.pendingDelete != nil }, set: { if !$0 { nas.pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: nas.pendingDelete) { f in
                Button("NAS에서 삭제", role: .destructive) { nas.delete(f) }
            } message: { _ in
                Text("Synology Drive 휴지통으로 옮겨져요. 이 기기에 받은 파일과 읽은 기록도 지워져요.")
            }
            .fullScreenCover(item: $opener.file) { f in
                ReaderScreen(file: f)
            }
            .task {
                Catalog.shared.refreshIfStale()
                await SyncCenter.shared.refresh()
            }
        }
    }
}
