import Foundation
import Observation
import Security

/// One pairing code, in the two shapes the server mints and this app reads.
///
/// The person only ever handles one string, whichever shape it is. Which shape they get is
/// the server's decision, made from where the server is, not theirs:
///
/// - **LAN.** Six characters from the server's alphabet. The server is announcing itself on
///   the local network, the app finds it, and the code is the whole secret.
/// - **Remote.** `TT1-` and a base64url blob, minted when the server was started with
///   `TURNTABLE_PUBLIC_URL`. It carries the address the phone should redeem against as well
///   as the secret, because a server in a data centre cannot be discovered from a phone.
///
/// The blob is `<url>\n<secret>` in UTF-8. It is a transport, not a trust boundary: nothing
/// inside it is believed until it is parsed back out and checked here, field by field. It
/// carries no bearer token — only a single-use secret that expires in 15 minutes and is
/// stored on the server as a hash — so a code read over someone's shoulder buys a stranger
/// one race against the clock, not an account.
enum PairingCode: Equatable {
    case lan(String)
    case remote(url: URL, secret: String)

    static let prefix = "TT1-"
    /// The server's alphabet: Crockford base32 without the look-alikes, minus 0 and 1.
    static let alphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let lanLength = 6
    /// 16 of a 30 symbol alphabet is about 78 bits. The LAN code's 6 characters (~29 bits)
    /// are enough behind a ten-guess burn on a network you are already on; a remote server
    /// can be reachable from anywhere, so its secret is sized for that.
    static let remoteSecretLength = 16
    static let maxLength = 512
    static let maxAddressLength = 200
    static let maxHostLength = 128

    /// What the field holds right now. `incomplete` is its own answer, not a failure: half a
    /// pasted code is not a wrong code, and saying so is what keeps the screen honest.
    enum Reading: Equatable {
        case empty
        case incomplete
        case ready(PairingCode)
        case rejected(Pairing.Failure)

        var isReady: Bool { if case .ready = self { true } else { false } }
    }

    /// True for the pasted `TT1-` shape, which the field draws and folds case differently.
    static func isLong(_ text: String) -> Bool {
        text.prefix(prefix.count).uppercased() == prefix
    }

    static func read(_ raw: String) -> Reading {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= maxLength else { return .rejected(.badCodeFormat) }

        if isLong(trimmed) { return readRemote(String(trimmed.dropFirst(prefix.count))) }
        let short = String(trimmed.uppercased().filter(alphabet.contains))
        if short.count == lanLength { return .ready(.lan(short)) }
        return short.count < lanLength ? .incomplete : .rejected(.badCodeFormat)
    }

    /// Decode, then disbelieve. Anything that could still become a whole code with more
    /// characters reads as incomplete; only a payload that decoded and then failed on its
    /// merits is rejected.
    private static func readRemote(_ body: String) -> Reading {
        var compact = String(body.filter { !$0.isWhitespace })
        while compact.hasSuffix("=") { compact.removeLast() }
        guard !compact.isEmpty else { return .incomplete }
        guard compact.allSatisfy({ $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "-" || $0 == "_" })
        else { return .rejected(.badCodeFormat) }

        guard let data = decodeBase64URL(compact), let text = String(data: data, encoding: .utf8)
        else { return .incomplete }

        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .incomplete }
        let secret = String(parts[1])
        guard secret.count == remoteSecretLength, secret.allSatisfy(alphabet.contains) else { return .incomplete }

        switch address(String(parts[0])) {
        case .success(let url): return .ready(.remote(url: url, secret: secret))
        case .failure(let problem): return .rejected(problem)
        }
    }

    /// The address out of a remote code, checked before anything is sent to it.
    ///
    /// Plain http is allowed on a private network or a tailnet, where the packets do not
    /// leave a network the two devices already share. On the public internet it is not: the
    /// pairing secret goes out in the request and the device token comes back in the reply,
    /// both readable by anything on the path.
    static func address(_ raw: String) -> Result<URL, Pairing.Failure> {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count <= maxAddressLength,
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty, host.count <= maxHostLength,
              url.user() == nil, url.password() == nil,
              url.query() == nil, url.fragment() == nil
        else { return .failure(.badCodeFormat) }
        if let port = url.port, !(1...65535).contains(port) { return .failure(.badCodeFormat) }
        if scheme == "http", !isPrivate(host) { return .failure(.insecureAddress) }
        return .success(url)
    }

    /// Hosts whose traffic stays on a network the phone is already on. Kept deliberately
    /// narrow: anything not named here is treated as the public internet.
    static func isPrivate(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net")
            || host.hasSuffix(".internal") { return true }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8(String($0)) }
        if labels.count == 4, octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _): return true
            case (192, 168): return true
            case (172, 16...31): return true
            case (169, 254): return true
            case (100, 64...127): return true  // CGNAT, which is where Tailscale lives
            default: return false
            }
        }

        let v6 = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        if v6 == "::1" { return true }
        return v6.hasPrefix("fd") || v6.hasPrefix("fc") || v6.hasPrefix("fe80:")
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }
}

/// Where the server is and what proves this phone is allowed to talk to it.
///
/// The app ships with neither, and first run never asks for an address. It starts unpaired,
/// the pairing screen reads one code — six characters redeemed against whatever
/// `ServerDiscovery` found on the local network, or a `TT1-` code redeemed against the
/// address inside it — and the server answers with `{server_url, token}`. `server_url` is
/// the authoritative address from that point on: the tailnet or tunnel address when the
/// server was told one, which keeps working after the phone leaves this Wi-Fi. The address
/// lives in UserDefaults, the token in the Keychain, because it is a credential.
@MainActor
@Observable
final class Pairing {
    static let shared = Pairing()

    /// What went wrong, in the words the pairing screen shows.
    enum Failure: LocalizedError, Equatable {
        case badCode
        case badCodeFormat
        case insecureAddress
        case expired
        case cannotReach
        case noInternet
        case noServerFound
        case serverSaid(String)

        var errorDescription: String? {
            switch self {
            case .badCode: "The server does not know that code. Check it against what your agent sent and try again."
            case .badCodeFormat: "That is not a Turntable code. Paste the whole thing your agent sent, on its own."
            case .insecureAddress: "That code points at a public address over plain http, which would send the code across the internet in the clear. Ask your agent for an https address."
            case .expired: "That code has expired. Ask your agent for a fresh one; codes last 15 minutes."
            case .cannotReach: "Could not reach the server at that address. It may have stopped, or the address may not be reachable from this phone."
            case .noInternet: "This phone has no network connection."
            case .noServerFound: "No Turntable server on this Wi-Fi yet. Ask your agent to start it and keep both on the same network, and check that Local Network is on for Turntable in Settings. If your agent is not on your Wi-Fi at all, ask it for the longer code that carries its address."
            case .serverSaid(let message): message
            }
        }
    }

    private struct PairResponse: Decodable {
        let server_url: String
        let token: String
    }

    private enum Key {
        static let serverURL = "server_base_url"
        static let keychainAccount = "server_token"
    }

    private(set) var serverURL: URL?
    private(set) var token: String?

    var isPaired: Bool { serverURL != nil && token != nil }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Key.serverURL) {
            serverURL = URL(string: raw)
        }
        token = Keychain.read(Key.keychainAccount)
    }

    /// Redeem one code. A remote code names the only address worth trying; a LAN code is
    /// tried against every address discovery turned up, first answer wins.
    ///
    /// Several candidates is the normal case for a LAN code, not the exception: one server
    /// shows up once per interface it answers on. They are tried in order and the first 200
    /// ends it, so a dead candidate costs one timeout rather than the pairing.
    func pair(_ code: PairingCode, candidates: [URL] = []) async throws {
        switch code {
        case .remote(let url, let secret):
            DebugLog.shared.add("pair", "redeeming a \(secret.count) character code at \(url.host() ?? "?")")
            try keep(await redeem(code: secret, at: url))

        case .lan(let secret):
            DebugLog.shared.add("pair", "redeeming a \(secret.count) character code against \(candidates.count) found address(es)")
            guard !candidates.isEmpty else { throw Failure.noServerFound }
            var lastFailure = Failure.noServerFound
            for base in candidates {
                do {
                    try keep(await redeem(code: secret, at: base))
                    return
                } catch let failure as Failure {
                    // A server that knows the code but calls it expired is the real answer;
                    // nothing further down the list can improve on it.
                    if case .expired = failure { throw failure }
                    lastFailure = failure
                }
            }
            throw lastFailure
        }
    }

    /// The address the phone keeps is the one the server named in its reply, never the one
    /// the code was redeemed against. A code can carry a tunnel URL and the server can still
    /// answer with the tailnet address it would rather be reached on.
    private func keep(_ decoded: PairResponse) throws {
        guard let url = URL(string: decoded.server_url), url.host() != nil else {
            throw Failure.serverSaid("The server's reply did not make sense.")
        }
        store(url: url, token: decoded.token)
    }

    /// Trade the code for a token at one address. Throws a `Failure` the screen can show.
    private func redeem(code: String, at base: URL) async throws -> PairResponse {
        var request = URLRequest(url: base.appending(path: "/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "device_id": Config.deviceID,
        ])
        request.timeoutInterval = 6

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet ? Failure.noInternet : Failure.cannotReach
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.cannotReach }
        if http.statusCode != 200 {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])??["reason"] as? String
            switch reason {
            case "expired": throw Failure.expired
            case "bad code": throw Failure.badCode
            case let other?: throw Failure.serverSaid(other)
            case nil: throw Failure.serverSaid("The server answered \(http.statusCode).")
            }
        }

        guard let decoded = try? JSONDecoder().decode(PairResponse.self, from: data) else {
            throw Failure.serverSaid("The server's reply did not make sense.")
        }
        return decoded
    }

    /// Point this phone at a different address without pairing again. Advanced only: the
    /// token stays valid, so this is for a server that moved, not for a new server.
    @discardableResult
    func setServerAddress(_ raw: String) -> Bool {
        guard let url = Self.normalize(raw) else { return false }
        UserDefaults.standard.set(url.absoluteString, forKey: Key.serverURL)
        serverURL = url
        return true
    }

    private func store(url: URL, token: String) {
        UserDefaults.standard.set(url.absoluteString, forKey: Key.serverURL)
        Keychain.write(token, account: Key.keychainAccount)
        serverURL = url
        self.token = token
    }

    func unpair() {
        UserDefaults.standard.removeObject(forKey: Key.serverURL)
        Keychain.delete(Key.keychainAccount)
        serverURL = nil
        token = nil
    }

    /// "192.168.1.20:8787" and "http://host/" both become a usable base URL.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

/// The three Keychain calls this app needs, and nothing else.
@MainActor
private enum Keychain {
    private static let service = "com.turntable.pairing"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A failed write is why a phone that just paired can come back unpaired, so it says
    /// so rather than returning quietly. Unsigned simulator builds have no keychain access
    /// group and fail here every time; a signed build does not.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        delete(account)
        var request = query(account)
        request[kSecValueData as String] = Data(value.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(request as CFDictionary, nil)
        if status != errSecSuccess {
            DebugLog.shared.add("pair", "keychain write failed, OSStatus \(status); this pairing will not survive a relaunch")
        }
        return status == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
