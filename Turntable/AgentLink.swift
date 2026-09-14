import Foundation
import MusicKit
import Observation
import UIKit

/// The agent plane. Every 15 seconds, foreground or background: POST /checkin with a FRESH
/// read of what is playing, then GET /now-playing and follow the pick.
///
/// The loop no longer stops in the background. With the audio background mode and an active
/// playback session, iOS keeps the process alive while music plays, so steers keep landing.
/// When the app is suspended (no audio playing), iOS parks the loop and it resumes on wake -
/// the server-side last_seen age is the honest signal for "the app is not listening".
///
/// Every steer outcome is reported back in the next check-in (applied_pick_id, last_steer_error),
/// so a failed steer is visible from the server instead of dying silently.
@MainActor
@Observable
final class AgentLink {
    enum Link: Equatable {
        case idle       // loop not running
        case online
        case offline
    }

    struct Pick: Decodable, Equatable {
        let action: String
        let source: String?
        let catalog_id: String?
        let title: String?
        let artist: String?
        let playlist_name: String?
        let pick_id: Int?
    }

    private struct CheckIn: Encodable {
        struct Track: Encodable {
            let title: String
            let artist: String
            let source: String
        }
        let device_id: String
        let app_version: String
        let playing: Bool
        let track: Track?
        let position_s: Double
        let ts: Double
        let app_state: String
        let applied_pick_id: Int?
        let last_steer_error: String?
    }

    /// Raised when the server does not accept this phone's token, so the UI can offer
    /// to pair again instead of blaming the network.
    enum LinkError: Error { case unauthorized }

    private(set) var link: Link = .idle
    private(set) var lastContact: Date?
    /// Why the link is offline, in plain words, for the status label and the server.
    private(set) var offlineReason: String?
    /// The token was rejected. The DJ tab offers a way back to the pairing screen.
    private(set) var needsPairing = false
    private var appliedPickID: Int?
    private var lastSteerError: String?
    private var loop: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func start(player: PlayerModel) {
        guard loop == nil else { return }
        DebugLog.shared.add("agent", "loop started, server \(Pairing.shared.serverURL?.absoluteString ?? "unpaired")")
        loop = Task { [weak self, weak player] in
            while !Task.isCancelled {
                guard let self, let player else { return }
                await self.tick(player: player)
                try? await Task.sleep(for: Config.checkInInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        link = .idle
    }

    private func tick(player: PlayerModel) async {
        // Fresh read at check-in time. The cached observable state can lag behind the real
        // player; the server and the user deserve the truth, not the cache.
        let snap = player.liveSnapshot()
        let body = CheckIn(
            device_id: Config.deviceID,
            app_version: Config.appVersion,
            playing: snap.playing,
            track: snap.track.map { .init(title: $0.title, artist: $0.artist, source: "apple_music") },
            position_s: snap.position,
            ts: Date().timeIntervalSince1970,
            app_state: Self.appStateName(),
            applied_pick_id: appliedPickID,
            last_steer_error: lastSteerError
        )
        do {
            _ = try await post("/checkin", body: body)
            let data = try await get("/now-playing")
            let pick = try JSONDecoder().decode(Pick.self, from: data)
            markOnline()
            await follow(pick, player: player)
        } catch LinkError.unauthorized {
            needsPairing = true
            markOffline(reason: "the server rejected this phone, pair again")
        } catch let urlError as URLError {
            markOffline(reason: Self.describe(urlError))
        } catch {
            markOffline(reason: "bad reply from server")
        }
    }

    private static func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "foreground"
        case .background: return "background"
        case .inactive: return "inactive"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "this phone has no network"
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            return "cannot reach the server"
        case .timedOut:
            return "server timed out"
        default:
            return "connection failed (\(error.code.rawValue))"
        }
    }

    private func markOnline() {
        if link != .online { DebugLog.shared.add("agent", "online") }
        needsPairing = false
        link = .online
        offlineReason = nil
        lastContact = Date()
    }

    private func markOffline(reason: String) {
        if link != .offline || offlineReason != reason {
            DebugLog.shared.add("agent", "offline: \(reason)")
        }
        link = .offline
        offlineReason = reason
    }

    /// Follow a pick once. Compare against what is playing, and remember the pick id so a
    /// user skip does not drag the same pick back every 15 seconds.
    private func follow(_ pick: Pick, player: PlayerModel) async {
        // The server's idle state is {"action": "none"} with no pick_id. A pick with no id is
        // the server saying nothing, not an instruction: acting on it would pause the user's
        // music every 15 seconds for as long as no real steer is set.
        guard let pickID = pick.pick_id else { return }
        if pickID == appliedPickID { return }
        switch pick.action {
        case "none", "pause":
            appliedPickID = pick.pick_id
            player.pause()
            lastSteerError = nil
            DebugLog.shared.add("agent", "paused by steer")
        case "play":
            guard pick.source == "apple_music",
                  let catalogID = pick.catalog_id, !catalogID.isEmpty
            else { return }
            if player.liveSnapshot().track?.songID == catalogID {
                appliedPickID = pick.pick_id
                return
            }
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(catalogID))
                guard let song = try await request.response().items.first else {
                    recordSteerError(pick: pick, "pick \(catalogID) not in catalog")
                    return
                }
                appliedPickID = pick.pick_id
                lastSteerError = nil
                await player.playNow(song)
                if let err = player.lastError {
                    recordSteerError(pick: pick, "play failed: \(err)")
                } else {
                    DebugLog.shared.add("agent", "applied play pick \(pick.pick_id ?? -1)")
                }
            } catch {
                recordSteerError(pick: pick, "pick lookup failed: \(error.localizedDescription)")
            }
        case "add_to_playlist":
            guard let playlistName = pick.playlist_name, !playlistName.isEmpty else {
                recordSteerError(pick: pick, "add_to_playlist missing playlist_name")
                return
            }
            do {
                let added = try await player.addToPlaylist(pick: pick, playlistName: playlistName)
                appliedPickID = pick.pick_id
                lastSteerError = nil
                DebugLog.shared.add("agent", added)
            } catch {
                recordSteerError(pick: pick, "add to playlist failed: \(error.localizedDescription)")
            }
        default:
            recordSteerError(pick: pick, "unknown action \(pick.action)")
        }
    }

    private func recordSteerError(pick: Pick, _ message: String) {
        appliedPickID = pick.pick_id
        lastSteerError = message
        DebugLog.shared.add("agent", message)
    }

    // MARK: HTTP

    /// Builds a request against the paired server with the bearer token attached.
    /// Unpaired is reported as "cannot connect", which is what it is from here.
    private func authorized(_ path: String) throws -> URLRequest {
        guard let base = Pairing.shared.serverURL, let token = Pairing.shared.token else {
            throw URLError(.cannotConnectToHost)
        }
        var request = URLRequest(url: base.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func post<T: Encodable>(_ path: String, body: T) async throws -> Data {
        var request = try authorized(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func get(_ path: String) async throws -> Data {
        try await send(authorized(path))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 { throw LinkError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }
}
