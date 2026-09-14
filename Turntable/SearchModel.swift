import MusicKit
import Observation

/// Debounced Apple Music catalog search for songs and albums.
/// Debounce pattern follows wesmatlock/MusicKitDemo (MIT).
@MainActor
@Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle           // query too short
        case loading
        case results        // may be empty, see `songs` and `albums`
        case failed(String)
    }

    var query = ""
    private(set) var phase: Phase = .idle
    private(set) var songs: [Song] = []
    private(set) var albums: [Album] = []
    private var lastTerm = ""

    var isEmptyResult: Bool { phase == .results && songs.isEmpty && albums.isEmpty }

    /// Call from `.task(id: query)`. SwiftUI cancels the previous task on each keystroke,
    /// so the sleep is the debounce.
    func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 2 else {
            phase = .idle
            songs = []
            albums = []
            lastTerm = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled, term != lastTerm else { return }
        await run(term: term)
    }

    func retry() async {
        lastTerm = ""
        await search()
    }

    private func run(term: String) async {
        phase = .loading
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self, Album.self])
            request.limit = 15
            let response = try await request.response()
            guard !Task.isCancelled else { return }
            songs = Array(response.songs)
            albums = Array(response.albums)
            lastTerm = term
            phase = .results
        } catch is CancellationError {
            return
        } catch {
            lastTerm = ""
            phase = .failed(Self.plain(error))
            DebugLog.shared.add("search", "failed for '\(term)': \(error)")
        }
    }

    private static func plain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("network") || text.localizedCaseInsensitiveContains("offline") {
            return "No connection. Check the network and try again."
        }
        return "Apple Music did not answer. In the simulator this usually means no Media account is signed in."
    }
}
