import Foundation
import Observation

struct PodcastFeed: Identifiable, Codable, Equatable {
    let feedURL: URL
    var title: String
    var imageURL: URL?
    var episodes: [Episode]

    var id: String { feedURL.absoluteString }

    struct Episode: Identifiable, Codable, Equatable {
        let guid: String
        let title: String
        let pubDate: Date?
        let durationSeconds: Double?
        let audioURL: URL

        var id: String { guid }
    }
}

/// Pasted RSS feeds and their parsed episodes. Persisted to UserDefaults, not a database:
/// a handful of feeds is the expected scale.
@MainActor
@Observable
final class PodcastStore {
    enum AddPhase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    private(set) var feeds: [PodcastFeed] = []
    private(set) var addPhase: AddPhase = .idle
    var pastedFeedURL: String = ""

    private let defaultsKey = "podcast_feeds"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init() { load() }

    func addPastedFeed() async {
        let trimmed = pastedFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            addPhase = .failed("That doesn\u{2019}t look like a web address.")
            return
        }
        addPhase = .loading
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                addPhase = .failed("The server didn\u{2019}t return the feed.")
                return
            }
            guard let feed = RSSParser.parse(data: data, feedURL: url) else {
                addPhase = .failed("That link didn\u{2019}t parse as an RSS feed.")
                return
            }
            guard !feed.episodes.isEmpty else {
                addPhase = .failed("That feed parsed but has no episodes.")
                return
            }
            feeds.removeAll { $0.feedURL == feed.feedURL }
            feeds.insert(feed, at: 0)
            save()
            addPhase = .idle
            pastedFeedURL = ""
        } catch {
            addPhase = .failed("Couldn\u{2019}t reach that feed: \(error.localizedDescription)")
        }
    }

    func remove(_ feed: PodcastFeed) {
        feeds.removeAll { $0.id == feed.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        feeds = (try? JSONDecoder().decode([PodcastFeed].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(feeds) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// RSS plus the itunes: namespace extensions podcasts use for artwork and episode
/// duration, read with Foundation's XMLParser. No SPM dependency.
enum RSSParser {
    static func parse(data: Data, feedURL: URL) -> PodcastFeed? {
        let delegate = Delegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        guard xmlParser.parse() else { return nil }
        let title = delegate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return PodcastFeed(
            feedURL: feedURL,
            title: title.isEmpty ? (feedURL.host ?? "Podcast") : title,
            imageURL: delegate.imageURL,
            episodes: delegate.episodes
        )
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var title = ""
        var imageURL: URL?
        var episodes: [PodcastFeed.Episode] = []

        private var currentText = ""
        private var inItem = false
        private var itemTitle = ""
        private var itemPubDateRaw = ""
        private var itemDurationRaw = ""
        private var itemAudioURL: URL?
        private var itemGUID = ""

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            currentText = ""
            switch localName(elementName) {
            case "item":
                inItem = true
                itemTitle = ""; itemPubDateRaw = ""; itemDurationRaw = ""; itemAudioURL = nil; itemGUID = ""
            case "enclosure":
                if inItem, let urlString = attributeDict["url"] { itemAudioURL = URL(string: urlString) }
            case "image":
                if !inItem, imageURL == nil, let href = attributeDict["href"] { imageURL = URL(string: href) }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            switch localName(elementName) {
            case "title":
                if inItem { itemTitle = text } else if title.isEmpty { title = text }
            case "pubDate":
                if inItem { itemPubDateRaw = text }
            case "duration":
                if inItem { itemDurationRaw = text }
            case "guid":
                if inItem { itemGUID = text }
            case "url":
                if !inItem, imageURL == nil, let url = URL(string: text) { imageURL = url }
            case "item":
                if let audioURL = itemAudioURL {
                    let guid = itemGUID.isEmpty ? audioURL.absoluteString : itemGUID
                    episodes.append(
                        PodcastFeed.Episode(
                            guid: guid,
                            title: itemTitle.isEmpty ? "Untitled episode" : itemTitle,
                            pubDate: Self.parseDate(itemPubDateRaw),
                            durationSeconds: Self.parseDuration(itemDurationRaw),
                            audioURL: audioURL
                        )
                    )
                }
                inItem = false
            default:
                break
            }
            currentText = ""
        }

        private func localName(_ raw: String) -> String {
            guard let colon = raw.lastIndex(of: ":") else { return raw }
            return String(raw[raw.index(after: colon)...])
        }

        private static func parseDate(_ raw: String) -> Date? {
            guard !raw.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in [
                "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ",
            ] {
                formatter.dateFormat = format
                if let date = formatter.date(from: raw) { return date }
            }
            return nil
        }

        /// itunes:duration is either plain seconds or HH:MM:SS / MM:SS.
        private static func parseDuration(_ raw: String) -> Double? {
            guard !raw.isEmpty else { return nil }
            if let seconds = Double(raw) { return seconds }
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            guard !parts.isEmpty else { return nil }
            return parts.reversed().enumerated().reduce(0.0) { acc, pair in
                acc + pair.element * pow(60.0, Double(pair.offset))
            }
        }
    }
}
