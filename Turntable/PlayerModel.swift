import AVFAudio
import Combine
import Foundation
@preconcurrency import MusicKit
import Observation

/// Queue and transport.
///
/// Player choice, checked against the MusicKit swiftinterface in the iOS 26.5 SDK:
///
/// `SystemMusicPlayer` was the first choice, because it is the Music app's own player, so
/// the lock screen, Control Center and AirPods controls all follow it and audio survives
/// this app being killed. But its queue is write-only: `SystemMusicPlayer.queue` is a
/// `MusicPlayer.Queue`, which exposes only `currentEntry` and `insert`. There is no
/// `entries` list to show, reorder or remove from.
///
/// `ApplicationMusicPlayer.Queue` adds `entries`, a settable RandomAccessCollection.
/// M1 promises a visible queue with reorder and remove, so ApplicationMusicPlayer is forced
/// here. Transport (play, pause, next, previous) goes through the same player, because
/// steering one player while playing through another is a bug, not a feature.
///
/// Trade-off accepted for M1: playback stops if iOS kills the app. Background playback while
/// the app is alive still works. Revisit in M2 when the AirPods automation relaunches the app.
@MainActor
@Observable
final class PlayerModel {
    struct NowPlaying: Equatable {
        let entryID: String
        let songID: String?
        let title: String
        let artist: String
        let artwork: Artwork?
        let duration: TimeInterval

        // Artwork is not Equatable; the entry id already identifies the artwork.
        static func == (a: Self, b: Self) -> Bool {
            a.entryID == b.entryID && a.songID == b.songID && a.title == b.title
                && a.artist == b.artist && a.duration == b.duration
        }
    }

    private(set) var entries: [MusicKit.MusicPlayer.Queue.Entry] = []
    private(set) var current: NowPlaying?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    /// Last player error, one line, shown inline under the transport. Cleared on the next success.
    private(set) var lastError: String?

    private let player = ApplicationMusicPlayer.shared
    private var audioSessionReady = false
    private var cancellables: Set<AnyCancellable> = []
    private var ticker: Task<Void, Never>?

    var hasQueue: Bool { !entries.isEmpty }
    var progress: Double {
        guard let d = current?.duration, d > 0 else { return 0 }
        return min(1, max(0, position / d))
    }

    init() {
        player.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.readQueue() }
            }
            .store(in: &cancellables)
        player.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.readState() }
            }
            .store(in: &cancellables)
        readQueue()
        readState()
        startTicker()
    }

    // MARK: Queueing

    func enqueue(_ song: Song) async {
        await enqueue(item: song, label: song.title)
    }

    func enqueue(_ album: Album) async {
        await enqueue(item: album, label: album.title)
    }

    private func enqueue<Item: PlayableMusicItem>(item: Item, label: String) async {
        do {
            if entries.isEmpty {
                player.queue = [item]
                try await player.play()
            } else {
                try await player.queue.insert(item, position: .tail)
            }
            lastError = nil
            DebugLog.shared.add("queue", "added \(label)")
        } catch {
            fail("Could not queue \(label)", error)
        }
    }

    /// Agent pick: play this song now, keep the rest of the queue after it.
    func playNow(_ song: Song) async {
        do {
            if entries.isEmpty {
                player.queue = [song]
            } else {
                try await player.queue.insert(song, position: .afterCurrentEntry)
                try await player.skipToNextEntry()
            }
            try await player.play()
            configureAudioSession()
            lastError = nil
            DebugLog.shared.add("agent", "playing pick \(song.title) by \(song.artistName)")
        } catch {
            fail("Could not play \(song.title)", error)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        var copy = entries
        copy.move(fromOffsets: source, toOffset: destination)
        player.queue.entries = .init(copy)
    }

    func remove(at offsets: IndexSet) {
        var copy = entries
        copy.remove(atOffsets: offsets)
        player.queue.entries = .init(copy)
    }

    func jump(to entry: MusicKit.MusicPlayer.Queue.Entry) async {
        player.queue.currentEntry = entry
        do {
            try await player.play()
            configureAudioSession()
        } catch { fail("Could not play \(entry.title)", error) }
    }

    // MARK: Transport

    func togglePlayPause() async {
        if isPlaying {
            player.pause()
        } else {
            do {
                try await player.play()
                configureAudioSession()
            } catch { fail("Could not play", error) }
        }
    }

    func next() async {
        do { try await player.skipToNextEntry() } catch { fail("Could not skip", error) }
    }

    func previous() async {
        do { try await player.skipToPreviousEntry() } catch { fail("Could not go back", error) }
    }

    // MARK: Live snapshot (fresh reads, no cache)

    struct LiveSnapshot {
        struct Track {
            let songID: String?
            let title: String
            let artist: String
        }
        let playing: Bool
        let track: Track?
        let position: TimeInterval
    }

    /// Read the player directly, right now. The observable cache can lag; anything that
    /// reports to the server or applies a steer must use this.
    func liveSnapshot() -> LiveSnapshot {
        let playing = player.state.playbackStatus == .playing
        var track: LiveSnapshot.Track?
        if let entry = player.queue.currentEntry {
            var songID: String?
            if case let .song(song)? = entry.item { songID = song.id.rawValue }
            track = .init(songID: songID, title: entry.title, artist: entry.subtitle ?? "")
        }
        return LiveSnapshot(playing: playing, track: track, position: player.playbackTime)
    }

    func pause() {
        player.pause()
        DebugLog.shared.add("player", "paused")
    }

    // MARK: Audio session (background keep-alive)

    /// The audio background mode only keeps the process alive while an audio session is
    /// active. Activate on playback so the agent loop keeps running with the screen off.
    func configureAudioSession() {
        guard !audioSessionReady else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            audioSessionReady = true
            DebugLog.shared.add("player", "audio session active (background mode armed)")
        } catch {
            DebugLog.shared.add("player", "audio session failed: \(error.localizedDescription)")
        }
    }

    // MARK: Library

    /// Add a song to one of the user's library playlists by name. Uses the MusicKit user
    /// token the app already holds - the on-device answer to "add this to my playlist".
    func addToPlaylist(pick: AgentLink.Pick, playlistName: String) async throws -> String {
        var song: Song?
        if let catalogID = pick.catalog_id, !catalogID.isEmpty {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
            song = try await request.response().items.first
        } else if let entry = player.queue.currentEntry, case let .song(current)? = entry.item {
            song = current
        }
        guard let song else { throw SteerError.noSong }
        var playlists = MusicLibraryRequest<Playlist>()
        playlists.filter(matching: \.name, equalTo: playlistName)
        guard let playlist = try await playlists.response().items.first else {
            throw SteerError.noPlaylist(playlistName)
        }
        try await MusicLibrary.shared.add(song, to: playlist)
        return "added \(song.title) to playlist \(playlistName)"
    }

    enum SteerError: LocalizedError {
        case noSong
        case noPlaylist(String)
        var errorDescription: String? {
            switch self {
            case .noSong: return "no song to add (nothing playing, no catalog id)"
            case .noPlaylist(let name): return "no library playlist named \(name)"
            }
        }
    }

    // MARK: State

    private func readQueue() {
        entries = Array(player.queue.entries)
        if let entry = player.queue.currentEntry {
            var songID: String?
            var duration: TimeInterval = 0
            if case let .song(song)? = entry.item {
                songID = song.id.rawValue
                duration = song.duration ?? 0
            }
            let next = NowPlaying(
                entryID: entry.id,
                songID: songID,
                title: entry.title,
                artist: entry.subtitle ?? "",
                artwork: entry.artwork,
                duration: duration
            )
            if next != current { current = next }
        } else {
            current = nil
        }
    }

    private func readState() {
        isPlaying = player.state.playbackStatus == .playing
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.position = self.player.playbackTime
            }
        }
    }

    private func fail(_ what: String, _ error: Error) {
        lastError = what
        DebugLog.shared.add("player", "\(what): \(error)")
    }
}
