import SwiftUI

struct RootTabView: View {
    enum Tab: String { case dj, video, podcasts }

    /// Launch environment TURNTABLE_TAB=video|podcasts opens that tab. Used for headless
    /// screenshots (`xcrun simctl launch` cannot tap). Harmless in normal use.
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["TURNTABLE_TAB"] ?? "") ?? .dj

    var body: some View {
        TabView(selection: $tab) {
            DJView()
                .tabItem { Label("DJ", systemImage: "music.note") }
                .tag(Tab.dj)
            VideoView()
                .tabItem { Label("Video", systemImage: "play.rectangle") }
                .tag(Tab.video)
            PodcastsView()
                .tabItem { Label("Podcasts", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.podcasts)
        }
    }
}

/// Honest placeholder for a tab that is not built yet. Says what will be there and when.
struct StubView: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(detail)
            }
            .navigationTitle(title)
        }
    }
}
