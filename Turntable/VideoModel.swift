import Foundation
import Observation

/// State for the Video tab. No API key: video ids come from parsing a pasted URL, and
/// titles come from YouTube's public oEmbed endpoint, which needs no key either.
@MainActor
@Observable
final class VideoModel {
    struct Recent: Identifiable, Codable, Equatable {
        let id: String
        var title: String
        var addedAt: Date
    }

    enum Phase: Equatable {
        case empty
        case loading(id: String)
        case playing(id: String, title: String)
        case failed(String)
    }

    private(set) var phase: Phase = .empty
    private(set) var recents: [Recent] = []
    var pastedURL: String = ""

    private let defaultsKey = "video_recents"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    init() { load() }

    func submitPastedURL() async {
        let trimmed = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let id = Self.extractVideoID(trimmed) else {
            phase = .failed("Couldn\u{2019}t find a YouTube video in that link. Paste a youtube.com or youtu.be link.")
            return
        }
        await play(id: id)
    }

    func play(id: String) async {
        phase = .loading(id: id)
        let title = await fetchTitle(id: id) ?? id
        phase = .playing(id: id, title: title)
        remember(id: id, title: title)
        pastedURL = ""
    }

    func forget(_ recent: Recent) {
        recents.removeAll { $0.id == recent.id }
        save()
    }

    private func fetchTitle(id: String) async -> String? {
        guard let url = URL(string: "https://www.youtube.com/oembed?url=https://www.youtube.com/watch%3Fv%3D\(id)&format=json") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            struct OEmbed: Decodable { let title: String }
            return try JSONDecoder().decode(OEmbed.self, from: data).title
        } catch {
            return nil
        }
    }

    private func remember(id: String, title: String) {
        recents.removeAll { $0.id == id }
        recents.insert(Recent(id: id, title: title, addedAt: Date()), at: 0)
        if recents.count > 10 { recents.removeLast(recents.count - 10) }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        recents = (try? JSONDecoder().decode([Recent].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Handles watch?v=, youtu.be/, embed/, and shorts/ forms. No API, just URL parsing.
    nonisolated static func extractVideoID(_ raw: String) -> String? {
        guard let url = URL(string: raw), let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        if url.path == "/watch",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let id = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           !id.isEmpty {
            return id
        }
        for prefix in ["/embed/", "/shorts/", "/live/"] where url.path.hasPrefix(prefix) {
            let id = String(url.path.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }
}
