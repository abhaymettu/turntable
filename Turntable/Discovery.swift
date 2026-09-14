import Foundation
import Network
import Observation

/// Finds Turntable servers on the local network, so first run can ask for a code and
/// nothing else.
///
/// A freshly installed phone knows six characters and no address. Bonjour closes that gap:
/// `server.py` announces itself as `_turntable._tcp`, this browses for it, and the code is
/// redeemed against whatever turns up. Discovery is a way in, not a memory. The address the
/// phone keeps is the one `POST /pair` answers with, which is the tailnet or tunnel address
/// when the server has been told one, and works long after the phone leaves this Wi-Fi.
@MainActor
@Observable
final class ServerDiscovery {
    /// Every address found so far, IPv4 first because it is the one that survives being
    /// written into a URL without an interface scope.
    private(set) var candidates: [URL] = []

    private var browser: NWBrowser?
    private var resolving: [NWEndpoint: NWConnection] = [:]
    private static let queue = DispatchQueue(label: "turntable.discovery")

    func start() {
        guard browser == nil else { return }

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_turntable._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor [weak self] in
                DebugLog.shared.add("find", "browse: \(results.count) result(s)")
                self?.resolve(results.map(\.endpoint))
            }
        }
        browser.stateUpdateHandler = { state in
            // A browser that reports .failed or .waiting is usually one the Local Network
            // prompt was refused for. It leaves no candidates, which is what the screen says.
            Task { @MainActor in DebugLog.shared.add("find", "browser \(state)") }
        }
        browser.start(queue: Self.queue)
        self.browser = browser
    }

    /// The addresses found so far, waiting out the first round trips if there are none yet.
    ///
    /// Browsing takes a beat and typing six characters does not, so the code is regularly
    /// complete before the first result lands. Failing there would be a lie about the
    /// network; this waits instead, and only an empty return means nothing is out there.
    func addresses(waitingUpTo timeout: Duration) async -> [URL] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while candidates.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return candidates
    }

    func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolving.values { connection.cancel() }
        resolving.removeAll()
    }

    /// Bonjour hands back a service name. Turning that into something `URLSession` can use
    /// means opening a connection and asking the established path what it connected to.
    private func resolve(_ endpoints: [NWEndpoint]) {
        for endpoint in endpoints where resolving[endpoint] == nil {
            let connection = NWConnection(to: endpoint, using: .tcp)
            resolving[endpoint] = connection
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                let remote = connection.currentPath?.remoteEndpoint
                Task { @MainActor [weak self] in
                    self?.finish(endpoint, remote: remote)
                }
            }
            connection.start(queue: Self.queue)
        }
    }

    private func finish(_ endpoint: NWEndpoint, remote: NWEndpoint?) {
        resolving.removeValue(forKey: endpoint)?.cancel()
        DebugLog.shared.add("find", "resolved \(endpoint) -> \(remote.map(String.init(describing:)) ?? "nothing")")
        guard case .hostPort(let host, let port) = remote, let url = Self.url(host, port) else { return }
        guard !candidates.contains(url) else { return }
        // IPv4 goes to the front: it is the address that survives being written into a URL
        // without an interface scope, so it is the one most likely to answer first.
        if case .ipv4 = host { candidates.insert(url, at: 0) } else { candidates.append(url) }
    }

    private static func url(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> URL? {
        let text: String
        switch host {
        case .ipv4(let address):
            text = Self.unscoped(address)
        case .ipv6(let address):
            // A link-local v6 address means nothing without its interface scope, and no URL
            // carries one. The same service always answers on v4 or on its hostname too.
            guard !address.isLinkLocal else { return nil }
            text = "[\(Self.unscoped(address))]"
        case .name(let name, _):
            text = name.hasSuffix(".") ? String(name.dropLast()) : name
        @unknown default:
            return nil
        }
        guard !text.isEmpty else { return nil }
        return URL(string: "http://\(text):\(port.rawValue)")
    }

    /// A resolved Bonjour address arrives interface-scoped, as "192.168.1.192%en0". The
    /// zone is how the stack reaches it and is not part of the address a URL can hold.
    private static func unscoped(_ address: some IPAddress) -> String {
        String("\(address)".split(separator: "%").first ?? "")
    }
}
