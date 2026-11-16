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
    @State private var tab = 0

    var body: some View {
        if settings.share == nil {
            SetupView()
        } else {
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("지금 읽기", systemImage: "book.fill") }
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
