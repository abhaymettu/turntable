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

/// Video. The player is the screen; pasting a link is a sheet. A 16:9 slab holds the same
/// place whether something is loaded or not, so the layout never collapses.
struct VideoView: View {
    @State private var model = VideoModel()
    @State private var showPaste = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stage
                    .padding(.horizontal, 20)
                recents
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .screenGround()
            .navigationTitle("Video")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPaste = true } label: { Label("Paste a Link", systemImage: "link.badge.plus") }
                }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showPaste) { PasteLinkSheet(model: model) }
        .animation(Theme.spring, value: model.phase)
        .task {
            // TURNTABLE_VIDEO_URL in the launch environment loads a video on open, the same
            // trick TURNTABLE_TAB uses, since `xcrun simctl launch` cannot tap the Play button.
            guard let url = ProcessInfo.processInfo.environment["TURNTABLE_VIDEO_URL"] else { return }
            model.pastedURL = url
            await model.submitPastedURL()
        }
    }

    // MARK: The stage

    @ViewBuilder
    private var stage: some View {
        switch model.phase {
        case .empty:
            slab {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent)
                    VStack(spacing: 3) {
                        Text("Nothing loaded yet").font(.headline)
                        Text("Paste a YouTube link and it plays right here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Paste a Link") { showPaste = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(Theme.accent)
                        .foregroundStyle(.black)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            }
        case .loading(let id):
            player(id: id)
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading\u{2026}").font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 12)
        case .playing(let id, let title):
            player(id: id)
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        case .failed(let message):
            slab {
                VStack(spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.accent)
                    Text("That link didn\u{2019}t resolve").font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                    Button("Try Another Link") { showPaste = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .tint(Theme.accent)
                        .foregroundStyle(.black)
                }
                .multilineTextAlignment(.center)
            }
        }
    }

    private func slab<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .card(Theme.artRadius)
    }

    private func player(id: String) -> some View {
        YouTubePlayerView(videoID: id)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Theme.artRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.artRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.7), radius: 20, y: 10)
    }

    // MARK: Recents

    @ViewBuilder
    private var recents: some View {
        if model.recents.isEmpty {
            // Sits under the slab rather than floating in the middle of the leftover space.
            Label("Links you play show up here for next time.", systemImage: "clock.arrow.circlepath")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.top, 18)
        } else {
            // A real section header inside the list, so the header and the first row share
            // one inset instead of the row separator cutting across the heading.
            List {
                Section {
                    ForEach(model.recents) { recent in
                        Button { Task { await model.play(id: recent.id) } } label: {
                            RecentRow(recent: recent)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Theme.separator)
                    }
                    .onDelete { indexSet in
                        for index in indexSet { model.forget(model.recents[index]) }
                    }
                } header: {
                    Text("Recent").foregroundStyle(.secondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .padding(.top, 10)
        }
    }
}

private struct RecentRow: View {
    let recent: VideoModel.Recent

    /// YouTube's public thumbnail host. No key, the same origin family as the oEmbed call
    /// the model already makes for the title.
    private var thumbnail: URL? {
        URL(string: "https://img.youtube.com/vi/\(recent.id)/mqdefault.jpg")
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: thumbnail) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "play.fill").font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .frame(width: 72, height: 41)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.separator, lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(recent.title).font(.subheadline).lineLimit(2)
                Text(recent.addedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle").foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// One field, one button, and it closes itself once the link resolves.
private struct PasteLinkSheet: View {
    var model: VideoModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("", text: $model.pastedURL,
                              prompt: Text("https://youtube.com/watch?v=\u{2026}").foregroundStyle(.tertiary))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focused)
                        .accessibilityLabel("YouTube link")
                        .onSubmit { play() }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .card(14, material: .thinMaterial)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                PrimaryButton(title: "Play", symbol: "play.fill",
                              enabled: !model.pastedURL.trimmingCharacters(in: .whitespaces).isEmpty) { play() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .screenGround()
            .navigationTitle("Paste a Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
    }

    private func play() {
        Task {
            await model.submitPastedURL()
            dismiss()
        }
    }
}
