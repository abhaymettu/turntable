import SwiftUI

/// Shows, as a wall of cover art under a standard large title. Adding a feed is a sheet,
/// not a row on this screen, so the shelf stays a shelf.
struct PodcastsView: View {
    @State private var store = PodcastStore()
    @State private var player = PodcastPlayerModel()
    @State private var showAdd = false

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    var body: some View {
        NavigationStack {
            Group {
                if store.feeds.isEmpty {
                    ContentUnavailableView {
                        Label("No Shows Yet", systemImage: "waveform")
                    } description: {
                        Text("Paste an RSS link from any podcast host and its episodes land here.")
                    } actions: {
                        Button("Add a Show") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(Theme.accent)
                            .foregroundStyle(.black)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(store.feeds) { feed in
                                NavigationLink {
                                    PodcastFeedView(feed: feed, player: player)
                                } label: {
                                    ShowCard(feed: feed)
                                }
                                .buttonStyle(.press)
                                .contextMenu {
                                    Button(role: .destructive) { store.remove(feed) } label: {
                                        Label("Remove Show", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .screenGround()
            .navigationTitle("Shows")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Label("Add a Show", systemImage: "plus") }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.current != nil {
                    PodcastMiniPlayer(player: player)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: player.current?.id)
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showAdd) { AddFeedSheet(store: store) }
        .task {
            // TURNTABLE_PODCAST_FEED in the launch environment adds a feed on open, the
            // same trick TURNTABLE_TAB and TURNTABLE_VIDEO_URL use for headless screenshots.
            guard store.feeds.isEmpty,
                  let feed = ProcessInfo.processInfo.environment["TURNTABLE_PODCAST_FEED"]
            else { return }
            store.pastedFeedURL = feed
            await store.addPastedFeed()
        }
    }
}

private struct ShowCard: View {
    let feed: PodcastFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PodcastArtwork(url: feed.imageURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(feed.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(feed.episodes.count) episode\(feed.episodes.count == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PodcastFeedView: View {
    let feed: PodcastFeed
    var player: PodcastPlayerModel

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom, spacing: 14) {
                    PodcastArtwork(url: feed.imageURL, size: 100)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feed.title)
                            .font(.title3.weight(.bold))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Chip(symbol: "waveform", text: "\(feed.episodes.count) episodes")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(feed.episodes) { episode in
                    Button { player.play(episode) } label: {
                        EpisodeRow(
                            episode: episode,
                            isCurrent: player.current?.id == episode.id,
                            isPlaying: player.isPlaying
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.separator)
                }
            } header: {
                Text("Episodes").foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .screenGround()
        .navigationTitle(feed.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                PodcastMiniPlayer(player: player)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: player.current?.id)
    }
}

private struct EpisodeRow: View {
    let episode: PodcastFeed.Episode
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(isCurrent ? AnyShapeStyle(Theme.accent.opacity(0.16)) : AnyShapeStyle(.thinMaterial))
                Circle().strokeBorder(isCurrent ? Theme.accent.opacity(0.45) : Theme.separator, lineWidth: 0.5)
                Image(systemName: isCurrent && isPlaying ? "waveform" : "play.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.subheadline)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if let pubDate = episode.pubDate {
                        Text(pubDate, format: .dateTime.month(.abbreviated).day().year())
                    }
                    if episode.pubDate != nil && episode.durationSeconds != nil { Text("\u{00B7}") }
                    if let seconds = episode.durationSeconds { Text(runtime(seconds)) }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func runtime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

/// Floating material pill above the tab bar, the way a system now-playing bar sits: the
/// content behind it keeps scrolling and the OLED ground is never covered by a grey strip.
private struct PodcastMiniPlayer: View {
    var player: PodcastPlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(player.current?.title ?? "")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    ProgressTrack(progress: player.progress, height: 3)
                    Text("\(clockString(player.position)) / \(clockString(player.duration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.black)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.press)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .card(18)
        .shadow(color: .black.opacity(0.55), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Adding a feed is the only place a URL field belongs, and it closes itself on success.
private struct AddFeedSheet: View {
    var store: PodcastStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("", text: $store.pastedFeedURL,
                              prompt: Text("https://feeds.example.com/show.xml").foregroundStyle(.tertiary))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($focused)
                        .accessibilityLabel("RSS feed URL")
                        .onSubmit { add() }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .card(14, material: .thinMaterial)
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if case .failed(let message) = store.addPhase {
                    FailureNote(text: message)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .transition(.opacity)
                }

                Spacer()

                PrimaryButton(
                    title: "Add Show",
                    loading: store.addPhase == .loading,
                    enabled: !store.pastedFeedURL.trimmingCharacters(in: .whitespaces).isEmpty
                ) { add() }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .screenGround()
            .navigationTitle("Add a Show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(270)])
        .presentationDragIndicator(.visible)
        .onAppear { focused = true }
        .animation(Theme.spring, value: store.addPhase)
    }

    private func add() {
        Task {
            let before = store.feeds.count
            await store.addPastedFeed()
            if store.feeds.count > before { dismiss() }
        }
    }
}

/// Reserves space before load and holds a hairline outline, same treatment as ArtworkTile.
struct PodcastArtwork: View {
    let url: URL?
    /// nil fills the space it is given; a number pins it to that square.
    var size: CGFloat?

    private var radius: CGFloat { min(size ?? 160, 160) * 0.17 }

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "waveform").font(.title2).foregroundStyle(.tertiary) }
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
    }
}
