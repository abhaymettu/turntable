import SwiftUI
import WebKit

/// The visible YouTube player. Never hidden, never offscreen, no background-audio tricks:
/// Google's embed terms require the player to be on screen for playback to be allowed.
struct YouTubePlayerView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard videoID != context.coordinator.loadedVideoID else { return }
        context.coordinator.loadedVideoID = videoID
        // Loaded as a top-level navigation, YouTube's embed page rejects most videos with
        // error 153 (no parent frame to check an origin against). Wrapping it in a page
        // whose base URL is youtube.com, with the player in an actual iframe, gives it a
        // same-origin parent to check and it plays normally.
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>html,body{margin:0;background:#000;}iframe{position:fixed;top:0;left:0;width:100%;height:100%;border:0;}</style>
        </head><body>
        <iframe src="https://www.youtube.com/embed/\(videoID)?playsinline=1"
                allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedVideoID: String?
    }
}

struct VideoView: View {
    @State private var model = VideoModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playerArea
                Divider()
                controls
            }
            .navigationTitle("Video")
        }
        .task {
            // TURNTABLE_VIDEO_URL in the launch environment loads a video on open, the same
            // trick TURNTABLE_TAB uses, since `xcrun simctl launch` cannot tap the Play button.
            guard let url = ProcessInfo.processInfo.environment["TURNTABLE_VIDEO_URL"] else { return }
            model.pastedURL = url
            await model.submitPastedURL()
        }
    }

    @ViewBuilder
    private var playerArea: some View {
        switch model.phase {
        case .empty:
            ContentUnavailableView {
                Label("No video loaded", systemImage: "play.rectangle")
            } description: {
                Text("Paste a YouTube link below. It plays right here, in the visible player.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading(let id):
            YouTubePlayerView(videoID: id)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        case .playing(let id, let title):
            VStack(alignment: .leading, spacing: 8) {
                YouTubePlayerView(videoID: id)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .padding(.horizontal)
            }
            .padding(.top, 8)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn\u{2019}t load that link", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        List {
            Section("Paste a link") {
                HStack {
                    TextField("https://youtube.com/watch?v=\u{2026}", text: $model.pastedURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .accessibilityLabel("YouTube link")
                        .onSubmit { Task { await model.submitPastedURL() } }
                    Button("Play") { Task { await model.submitPastedURL() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pastedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !model.recents.isEmpty {
                Section("Recent") {
                    ForEach(model.recents) { recent in
                        Button { Task { await model.play(id: recent.id) } } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recent.title).lineLimit(1)
                                Text(recent.addedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for index in indexSet { model.forget(model.recents[index]) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
