import SwiftUI

struct PodcastsView: View {
    @State private var store = PodcastStore()
    @State private var player = PodcastPlayerModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Add a feed") {
                    HStack {
                        TextField("RSS feed URL", text: $store.pastedFeedURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .accessibilityLabel("RSS feed URL")
                            .onSubmit { Task { await store.addPastedFeed() } }
                        Button("Add") { Task { await store.addPastedFeed() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.pastedFeedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    switch store.addPhase {
                    case .idle:
                        EmptyView()
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Fetching feed\u{2026}").font(.footnote).foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Your feeds") {
                    if store.feeds.isEmpty {
                        Text("No feeds yet. Paste an RSS link above, for example a show\u{2019}s feed from its podcast host.")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    } else {
                        ForEach(store.feeds) { feed in
                            NavigationLink {
                                PodcastFeedView(feed: feed, player: player)
                            } label: {
                                PodcastFeedRow(feed: feed)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet { store.remove(store.feeds[index]) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Podcasts")
            .safeAreaInset(edge: .bottom) {
                if player.current != nil {
                    PodcastMiniPlayer(player: player)
                }
            }
        }
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

private struct PodcastFeedRow: View {
    let feed: PodcastFeed

    var body: some View {
        HStack(spacing: 12) {
            PodcastArtwork(url: feed.imageURL, size: Theme.rowArtworkSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.title).lineLimit(1)
                Text("\(feed.episodes.count) episode\(feed.episodes.count == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PodcastFeedView: View {
    let feed: PodcastFeed
    var player: PodcastPlayerModel

    var body: some View {
        List {
            ForEach(feed.episodes) { episode in
                Button {
                    player.play(episode)
                } label: {
                    PodcastEpisodeRow(episode: episode, isCurrent: player.current?.id == episode.id, isPlaying: player.isPlaying)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .navigationTitle(feed.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if player.current != nil {
                PodcastMiniPlayer(player: player)
            }
        }
    }
}

private struct PodcastEpisodeRow: View {
    let episode: PodcastFeed.Episode
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent && isPlaying ? "speaker.wave.2.fill" : "play.circle")
                .font(.title3)
                .foregroundStyle(isCurrent ? Theme.accent : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).lineLimit(2)
                HStack(spacing: 4) {
                    if let pubDate = episode.pubDate {
                        Text(pubDate, format: .dateTime.month().day().year())
                    }
                    if let seconds = episode.durationSeconds {
                        Text("\u{00B7}")
                        Text(clock(seconds))
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes) min"
    }
}

private struct PodcastMiniPlayer: View {
    var player: PodcastPlayerModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * player.progress)
            }
            .frame(height: 2)
            .background(.quaternary)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.current?.title ?? "")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text("\(clock(player.position)) / \(clock(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Reserves space before load and holds a hairline outline, same treatment as ArtworkTile.
struct PodcastArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
