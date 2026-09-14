import SwiftUI

/// The standard iOS tab bar. It is translucent over the black ground rather than an opaque
/// strip, so the OLED background runs to the bottom edge and the chrome floats on it.
struct RootTabView: View {
    enum Tab: String { case dj, video, podcasts }

    /// Launch environment TURNTABLE_TAB=video|podcasts opens that tab. Used for headless
    /// screenshots (`xcrun simctl launch` cannot tap). Harmless in normal use.
    @State private var tab: Tab = Tab(rawValue: ProcessInfo.processInfo.environment["TURNTABLE_TAB"] ?? "") ?? .dj

    var body: some View {
        TabView(selection: $tab) {
            DJView()
                .tabItem { Label("Playing", systemImage: "play.circle.fill") }
                .tag(Tab.dj)
            VideoView()
                .tabItem { Label("Video", systemImage: "play.rectangle.fill") }
                .tag(Tab.video)
            PodcastsView()
                .tabItem { Label("Shows", systemImage: "waveform") }
                .tag(Tab.podcasts)
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}
