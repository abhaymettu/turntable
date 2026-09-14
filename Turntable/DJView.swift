import MusicKit
import SwiftUI

/// The DJ tab. One list: search on top, queue below, the Now Playing bar pinned at the
/// bottom. The bar is the only living element on the screen; everything else stays quiet.
struct DJView: View {
    @Environment(MusicService.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(AgentLink.self) private var agent
    @Environment(RouteLogger.self) private var routes
    @State private var search = SearchModel()
    @State private var showLog = false
    @State private var showOffer = false

    var body: some View {
        NavigationStack {
            Group {
                switch music.gate {
                case .checking:
                    ProgressView("Checking Apple Music")
                case .needsPermission:
                    GateView(
                        symbol: "music.note.house",
                        title: "Connect Apple Music",
                        detail: "Turntable needs permission to search the catalog and play on this phone.",
                        action: "Allow access"
                    ) { await music.requestAgain() }
                case .denied:
                    GateView(
                        symbol: "hand.raised",
                        title: "Apple Music access is off",
                        detail: "Turn on Media and Apple Music for Turntable in Settings, then come back.",
                        action: "Open Settings"
                    ) { openSettings() }
                case .noSubscription:
                    GateView(
                        symbol: "person.crop.circle.badge.exclamationmark",
                        title: "No Apple Music subscription",
                        detail: music.canOfferSubscription
                            ? "Playback needs an active subscription on this account."
                            : "Playback needs an active subscription. In the simulator, sign into a Media account in Settings first.",
                        action: music.canOfferSubscription ? "See subscription options" : "Check again"
                    ) {
                        if music.canOfferSubscription { showOffer = true } else { await music.refresh() }
                    }
                    .musicSubscriptionOffer(isPresented: $showOffer)
                case .ready:
                    readyBody
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    AgentStatusLabel(link: agent.link, lastContact: agent.lastContact, offlineReason: agent.offlineReason)
                    AudioOutputLabel(name: routes.outputLabel)
                    if agent.needsPairing {
                        Button("Pair again") { Pairing.shared.unpair() }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 10)
            }
            .navigationTitle("DJ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLog = true } label: { Label("Debug log", systemImage: "text.alignleft") }
                }
            }
            .sheet(isPresented: $showLog) { DebugLogView() }
        }
        .task { await music.bootstrap() }
    }

    private var readyBody: some View {
        List {
            Section {
                TextField("Search songs and albums", text: $search.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel("Search Apple Music")
                searchRows
            } header: {
                Text("Apple Music")
            }

            Section {
                queueRows
            } header: {
                HStack {
                    Text("Queue")
                    Spacer()
                    if player.hasQueue {
                        Text("\(player.entries.count)").monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .task(id: search.query) { await search.search() }
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar()
        }
    }

    @ViewBuilder
    private var searchRows: some View {
        switch search.phase {
        case .idle:
            Text("Type at least two letters.")
                .foregroundStyle(.secondary)
                .font(.footnote)
        case .loading:
            ForEach(0..<3, id: \.self) { _ in
                MediaRow(title: "Placeholder title", subtitle: "Placeholder artist", artwork: nil, kind: "Song")
                    .redacted(reason: .placeholder)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Search failed", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await search.retry() } }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        case .results:
            if search.isEmptyResult {
                Text("Nothing for \u{201C}\(search.query)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            ForEach(search.songs, id: \.id) { song in
                Button { Task { await player.enqueue(song) } } label: {
                    MediaRow(title: song.title, subtitle: song.artistName, artwork: song.artwork, kind: "Song")
                }
                .accessibilityHint("Adds to the queue")
            }
            ForEach(search.albums, id: \.id) { album in
                Button { Task { await player.enqueue(album) } } label: {
                    MediaRow(title: album.title, subtitle: album.artistName, artwork: album.artwork, kind: "Album")
                }
                .accessibilityHint("Adds every track to the queue")
            }
        }
    }

    @ViewBuilder
    private var queueRows: some View {
        if player.hasQueue {
            ForEach(player.entries, id: \.id) { entry in
                Button { Task { await player.jump(to: entry) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.id == player.current?.entryID ? "speaker.wave.2.fill" : "circle")
                            .font(.caption)
                            .frame(width: 16)
                            .foregroundStyle(entry.id == player.current?.entryID ? Theme.accent : Color.secondary.opacity(0.35))
                            .accessibilityHidden(true)
                        MediaRow(title: entry.title, subtitle: entry.subtitle ?? "", artwork: entry.artwork, kind: nil)
                    }
                }
                .accessibilityLabel(entry.id == player.current?.entryID ? "Now playing, \(entry.title)" : entry.title)
            }
            .onMove { player.move(from: $0, to: $1) }
            .onDelete { player.remove(at: $0) }
        } else {
            Text("Queue is empty. Search above and tap a song, or let the agent pick.")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// One of the four gate states. Same layout every time so the eye lands in the same place.
private struct GateView: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let perform: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            Button(action) { Task { await perform() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Dot plus word. The word carries the meaning; the dot only echoes it.
private struct AgentStatusLabel: View {
    let link: AgentLink.Link
    let lastContact: Date?
    let offlineReason: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(fill)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            Text(word)
                .font(.caption)
                .foregroundStyle(.secondary)
            if link == .offline, let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(link == .offline ? "Agent \(word), \(detail ?? "")" : "Agent \(word)")
    }

    private var detail: String? {
        if let offlineReason { return offlineReason }
        guard let lastContact else { return nil }
        return "last heard at \(lastContact.formatted(date: .omitted, time: .shortened))"
    }

    private var word: String {
        switch link {
        case .idle: "Agent paused"
        case .online: "Agent online"
        case .offline: "Agent offline"
        }
    }

    private var fill: Color {
        switch link {
        case .idle: Color.secondary.opacity(0.4)
        case .online: Theme.accent
        case .offline: Color.secondary
        }
    }
}

/// The current AVAudioSession output, read-only. Same treatment as AgentStatusLabel:
/// an icon plus the name, never color alone.
private struct AudioOutputLabel: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio output \(name)")
    }

    private var symbol: String {
        if name.localizedCaseInsensitiveContains("airpods") { return "airpods" }
        switch name {
        case "Speaker": return "speaker.wave.2"
        case "Headphones", "USB audio": return "headphones"
        case "AirPlay": return "airplayaudio"
        case "No audio output": return "speaker.slash"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

struct MediaRow: View {
    let title: String
    let subtitle: String
    let artwork: Artwork?
    let kind: String?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkTile(artwork: artwork, size: Theme.rowArtworkSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                HStack(spacing: 4) {
                    if let kind {
                        Text(kind)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(subtitle).lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Artwork with reserved space and a hairline so light covers hold against the surface.
struct ArtworkTile: View {
    let artwork: Artwork?
    let size: CGFloat
    var circular = false

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var shape: AnyShape {
        circular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Theme.artworkRadius, style: .continuous))
    }
}

/// The one living element: a record that turns while music plays, a thin progress line
/// under it. Reduced motion stops the turn; the play icon and the line still say the state.
struct NowPlayingBar: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Angle = .zero

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: geo.size.width * player.progress)
                    .animation(reduceMotion ? nil : .linear(duration: 0.5), value: player.progress)
            }
            .frame(height: 2)
            .background(.quaternary)
            .accessibilityHidden(true)

            HStack(spacing: 12) {
                ArtworkTile(artwork: player.current?.artwork, size: 44, circular: true)
                    .rotationEffect(angle)
                    .overlay { Circle().fill(.background).frame(width: 8, height: 8) }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.current?.title ?? "Nothing playing")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(player.current.map { "\($0.artist)  \u{00B7}  \(clock(player.position)) / \(clock($0.duration))" } ?? "Queue a song to start")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                HStack(spacing: 0) {
                    transport("backward.fill", "Previous") { await player.previous() }
                    transport(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "Pause" : "Play") { await player.togglePlayPause() }
                        .font(.title3)
                    transport("forward.fill", "Next") { await player.next() }
                }
                .disabled(!player.hasQueue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if let error = player.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .task(id: player.isPlaying) { await spin() }
    }

    private func transport(_ symbol: String, _ name: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    /// 33 rpm would be 1.8 s per turn. Slower reads calmer at this size.
    private func spin() async {
        guard player.isPlaying, !reduceMotion else { return }
        while !Task.isCancelled {
            withAnimation(.linear(duration: 4)) { angle += .degrees(360) }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
