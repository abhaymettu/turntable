import MusicKit
import SwiftUI

/// The main screen: album art first, one transport, and a deck at the bottom that always
/// holds something. System navigation bar and tab bar around it, Apple Music's own shape
/// inside it. Nothing here is a form and nothing here is a log.
struct DJView: View {
    @Environment(MusicService.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(AgentLink.self) private var agent
    @Environment(RouteLogger.self) private var routes
    @State private var search = SearchModel()
    @State private var showSearch = false
    @State private var showAdvanced = false
    @State private var showQueue = false
    @State private var showOffer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                    .padding(.top, 6)
                    .padding(.bottom, 12)

                hero
                    .padding(.horizontal, 22)

                trackTitle
                    .padding(.horizontal, 26)
                    .padding(.top, 18)

                position
                    .padding(.horizontal, 26)
                    .padding(.top, 14)

                transport
                    .padding(.top, 14)

                deck
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
            }
            .screenGround()
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdvanced = true } label: { Label("Advanced", systemImage: "gearshape") }
                }
            }
        }
        .task { await music.bootstrap() }
        .task {
            // TURNTABLE_SHEET=advanced|search opens a sheet on launch, the same headless
            // screenshot hook as TURNTABLE_TAB. Harmless in normal use.
            switch ProcessInfo.processInfo.environment["TURNTABLE_SHEET"] {
            case "advanced": showAdvanced = true
            case "search": showSearch = true
            default: break
            }
        }
        .sheet(isPresented: $showSearch) { SearchSheet(search: search).environment(player) }
        .sheet(isPresented: $showAdvanced) { AdvancedView() }
        .sheet(isPresented: $showQueue) { QueueSheet().environment(player) }
        .musicSubscriptionOffer(isPresented: $showOffer)
    }

    // MARK: Status

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Chip(symbol: agentSymbol, text: agentWord, emphasis: agent.link == .online)
                Chip(symbol: outputSymbol, text: routes.outputLabel)
                Chip(symbol: "list.bullet",
                     text: player.hasQueue ? "\(player.entries.count) in queue" : "Queue empty")
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .frame(height: 30)
        .animation(Theme.spring, value: agent.link)
    }

    private var agentWord: String {
        switch agent.link {
        case .idle: "Agent paused"
        case .online: "Agent online"
        case .offline: "Agent offline"
        }
    }

    /// Three different glyph shapes, not three colours: the state reads with the colour off.
    private var agentSymbol: String {
        switch agent.link {
        case .idle: "pause.circle"
        case .online: "antenna.radiowaves.left.and.right"
        case .offline: "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var outputSymbol: String {
        let name = routes.outputLabel
        if name.localizedCaseInsensitiveContains("airpods") { return "airpods" }
        switch name {
        case "Speaker": return "speaker.wave.2"
        case "Headphones", "USB audio": return "headphones"
        case "AirPlay": return "airplayaudio"
        case "No audio output": return "speaker.slash"
        default: return "hifispeaker"
        }
    }

    // MARK: Hero

    private var hero: some View {
        // ArtworkImage wants explicit point dimensions, so the square is measured here and
        // handed down rather than left to a resizable modifier it does not have.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(white: 0.05))
                if let artwork = player.current?.artwork {
                    ArtworkImage(artwork, width: side, height: side)
                } else {
                    VinylMark(size: side * 0.54, spinning: player.isPlaying)
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.8), radius: 28, y: 12)
        // The cover sits back a step while paused and steps forward on play: one quiet echo
        // of a state the transport glyph already states in shape.
        .scaleEffect(player.isPlaying ? 1 : 0.955)
        .animation(Theme.springy, value: player.isPlaying)
        .accessibilityHidden(true)
    }

    private var trackTitle: some View {
        VStack(spacing: 4) {
            Text(player.current?.title ?? "Nothing playing")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(player.current?.artist ?? "Your agent picks, or search to start one")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentTransition(.opacity)
        .animation(Theme.spring, value: player.current)
        .accessibilityElement(children: .combine)
    }

    private var position: some View {
        VStack(spacing: 6) {
            ProgressTrack(progress: player.progress)
            HStack {
                Text(clockString(player.position))
                Spacer()
                Text(player.current.map { clockString($0.duration) } ?? "0:00")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .opacity(player.current == nil ? 0.5 : 1)
        .animation(Theme.spring, value: player.current == nil)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 28) {
            secondaryTransport("backward.fill", "Previous") { await player.previous() }

            Button {
                Haptics.tap(.medium)
                Task { await player.togglePlayPause() }
            } label: {
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title.weight(.medium))
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                        .offset(x: player.isPlaying ? 0 : 2)
                }
                .frame(width: 66, height: 66)
                .shadow(color: .white.opacity(0.14), radius: 16)
            }
            .buttonStyle(PressStyle(scale: 0.93))
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            secondaryTransport("forward.fill", "Next") { await player.next() }
        }
        .opacity(hasTransport ? 1 : 0.5)
        .disabled(!hasTransport)
        .animation(Theme.spring, value: hasTransport)
    }

    /// Something is loaded: either a queue to move through, or a track already playing.
    private var hasTransport: Bool { player.hasQueue || player.current != nil }

    private func secondaryTransport(_ symbol: String, _ name: String, _ action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 50, height: 50)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
        }
        .buttonStyle(.press)
        .accessibilityLabel(name)
    }

    // MARK: The deck

    /// Always occupied, in every state, so the bottom of the screen never reads as a hole.
    @ViewBuilder
    private var deck: some View {
        Group {
            if let step = setupStep {
                SetupRow(step: step)
            } else if player.hasQueue {
                upNext
            } else {
                startRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .frame(height: 116)
        .card()
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next").font(.subheadline.weight(.semibold))
                Spacer()
                Button { showQueue = true } label: {
                    Label("All \(player.entries.count)", systemImage: "chevron.right")
                        .labelStyle(TrailingIconStyle())
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.press)
                .tint(Theme.accent)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(player.entries.prefix(10), id: \.id) { entry in
                        Button {
                            Haptics.tap()
                            Task { await player.jump(to: entry) }
                        } label: {
                            QueueTile(entry: entry, isCurrent: entry.id == player.current?.entryID)
                        }
                        .buttonStyle(.press)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 76)
        }
    }

    private var startRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                DeckIcon(symbol: "sparkle.magnifyingglass")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start something").font(.subheadline.weight(.semibold))
                    Text("Search the catalog, or wait for your agent\u{2019}s pick.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            Button { showSearch = true } label: {
                Text("Search Apple Music").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    // MARK: Apple Music setup

    struct SetupStep {
        let symbol: String
        let title: String
        let detail: String
        let action: String
        let perform: () async -> Void
    }

    /// The gate, phrased as the next step rather than as a failure. `.ready` returns nil and
    /// the deck goes back to the queue.
    private var setupStep: SetupStep? {
        switch music.gate {
        case .ready:
            return nil
        case .checking:
            return SetupStep(symbol: "clock.arrow.circlepath", title: "Checking Apple Music",
                             detail: "One moment while this phone reads its account.",
                             action: "") { }
        case .needsPermission:
            return SetupStep(symbol: "music.note.house", title: "Connect Apple Music",
                             detail: "Turntable plays through your own library and catalog.",
                             action: "Allow Access") { await music.requestAgain() }
        case .denied:
            return SetupStep(symbol: "switch.2", title: "Turn on music access",
                             detail: "Settings has Media & Apple Music for Turntable.",
                             action: "Open Settings") { openSettings() }
        case .noSubscription:
            return SetupStep(
                symbol: "person.crop.circle.badge.plus",
                title: "Sign In to Apple Music",
                detail: music.canOfferSubscription
                    ? "Playback needs an active subscription on this account."
                    : "Playback needs a Media account signed in on this device.",
                action: music.canOfferSubscription ? "See Options" : "Check Again"
            ) {
                if music.canOfferSubscription { showOffer = true } else { await music.refresh() }
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Deck pieces

/// Text on top, action underneath. Side by side, the button eats the width the sentence
/// needs and the detail truncates mid-word, which is the one thing this card must not do.
private struct SetupRow: View {
    let step: DJView.SetupStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                DeckIcon(symbol: step.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if step.action.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            if !step.action.isEmpty {
                Button { Task { await step.perform() } } label: {
                    Text(step.action).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Theme.accent)
                .foregroundStyle(.black)
            }
        }
    }
}

private struct DeckIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.body)
            .foregroundStyle(Theme.accent)
            .frame(width: 36, height: 36)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Label with the symbol after the text, the way a system disclosure row reads.
private struct TrailingIconStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.imageScale(.small)
        }
    }
}

private struct QueueTile: View {
    let entry: MusicKit.MusicPlayer.Queue.Entry
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkTile(artwork: entry.artwork, size: 52)
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2.weight(.bold))
                            .imageScale(.small)
                            .foregroundStyle(.black)
                            .padding(3)
                            .background(Circle().fill(Theme.accent))
                            .padding(3)
                    }
                }
            Text(entry.title)
                .font(.caption2)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(width: 52, alignment: .leading)
        }
        .accessibilityLabel(isCurrent ? "Now playing, \(entry.title)" : entry.title)
    }
}

// MARK: - Shared rows

struct MediaRow: View {
    let title: String
    let subtitle: String
    let artwork: Artwork?
    let kind: String?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkTile(artwork: artwork, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).lineLimit(1)
                HStack(spacing: 5) {
                    if let kind {
                        Text(kind.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// Artwork with reserved space and a hairline, so light covers still hold an edge against
/// the black ground.
struct ArtworkTile: View {
    let artwork: Artwork?
    let size: CGFloat

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.32))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        )
    }
}

// MARK: - Search

/// Search lives in a sheet so the main screen keeps no text field, and it uses the system
/// search field rather than a hand-built one.
struct SearchSheet: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Bindable var search: SearchModel
    @State private var justAdded: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            results
                .screenGround()
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Songs and Albums")
                .searchFocusedIfAvailable($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task(id: search.query) { await search.search() }
        .animation(Theme.spring, value: search.phase)
        // The only reason to open this sheet is to type, so the keyboard comes up with it.
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var results: some View {
        switch search.phase {
        case .idle:
            ContentUnavailableView {
                Label("Find Something to Play", systemImage: "magnifyingglass")
            } description: {
                Text("Two letters is enough. Tap a result to put it in the queue.")
            }
        case .loading:
            List {
                ForEach(0..<6, id: \.self) { _ in
                    MediaRow(title: "Placeholder title", subtitle: "Placeholder artist", artwork: nil, kind: "Song")
                        .redacted(reason: .placeholder)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .failed(let message):
            ContentUnavailableView {
                Label("Search Didn\u{2019}t Finish", systemImage: "antenna.radiowaves.left.and.right.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await search.retry() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .foregroundStyle(.black)
            }
        case .results:
            if search.isEmptyResult {
                ContentUnavailableView.search(text: search.query)
            } else {
                List {
                    ForEach(search.songs, id: \.id) { song in
                        row(id: song.id.rawValue, title: song.title, subtitle: song.artistName,
                            artwork: song.artwork, kind: "Song") { await player.enqueue(song) }
                    }
                    ForEach(search.albums, id: \.id) { album in
                        row(id: album.id.rawValue, title: album.title, subtitle: album.artistName,
                            artwork: album.artwork, kind: "Album") { await player.enqueue(album) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// The row confirms in place: the trailing glyph turns into a check for a beat, so the
    /// tap has an answer without a banner flying across the screen.
    private func row(
        id: String,
        title: String,
        subtitle: String,
        artwork: Artwork?,
        kind: String,
        add: @escaping () async -> Void
    ) -> some View {
        Button {
            Haptics.tap()
            Task {
                await add()
                withAnimation(Theme.springy) { justAdded = id }
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Theme.spring) { if justAdded == id { justAdded = nil } }
            }
        } label: {
            HStack(spacing: 12) {
                MediaRow(title: title, subtitle: subtitle, artwork: artwork, kind: kind)
                Image(systemName: justAdded == id ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(justAdded == id ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Theme.separator)
        .accessibilityHint(justAdded == id ? "Added to the queue" : "Adds to the queue")
    }
}

// MARK: - Queue

/// The full queue, where reordering and removing live. Kept off the main screen so that
/// screen stays a now-playing card rather than a list.
struct QueueSheet: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.hasQueue {
                    List {
                        ForEach(player.entries, id: \.id) { entry in
                            Button {
                                Haptics.tap()
                                Task { await player.jump(to: entry) }
                            } label: {
                                HStack(spacing: 12) {
                                    MediaRow(title: entry.title, subtitle: entry.subtitle ?? "",
                                             artwork: entry.artwork, kind: nil)
                                    if entry.id == player.current?.entryID {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.footnote)
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.separator)
                        }
                        .onMove { player.move(from: $0, to: $1) }
                        .onDelete { player.remove(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView {
                        Label("Queue Is Empty", systemImage: "list.bullet")
                    } description: {
                        Text("Search from the main screen, or let the agent pick.")
                    }
                }
            }
            .screenGround()
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { if player.hasQueue { EditButton() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }
}
