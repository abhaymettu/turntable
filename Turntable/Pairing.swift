import Foundation
import Observation
import Security

/// Where the server is and what proves this phone is allowed to talk to it.
///
/// The app ships with neither, and first run never asks for an address. It starts unpaired,
/// the pairing screen redeems a six character code against whatever `ServerDiscovery` found
/// on the local network, and the server answers with `{server_url, token}`. `server_url` is
/// the authoritative address from that point on: the tailnet or tunnel address when the
/// server was told one, which keeps working after the phone leaves this Wi-Fi. The address
/// lives in UserDefaults, the token in the Keychain, because it is a credential.
@MainActor
@Observable
final class Pairing {
    static let shared = Pairing()

    /// What went wrong, in the words the pairing screen shows.
    enum Failure: LocalizedError, Equatable {
        case badAddress
        case badCode
        case expired
        case cannotReach
        case noInternet
        case noServerFound
        case serverSaid(String)

        var errorDescription: String? {
            switch self {
            case .badAddress: "That address is not a web address. It looks like http://192.168.1.20:8787"
            case .badCode: "The server does not know that code. Check the six characters and try again."
            case .expired: "That code has expired. Ask your agent for a fresh one; codes last 15 minutes."
            case .cannotReach: "Found the server but could not reach it. It may have stopped since it answered."
            case .noInternet: "This phone has no network connection."
            case .noServerFound: "No Turntable server on this Wi-Fi yet. Ask your agent to start it, keep both on the same network, and check that Local Network is on for Turntable in Settings."
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

    /// Redeem the code against every address discovery turned up, first answer wins.
    ///
    /// Several candidates is the normal case, not the exception: one server shows up once
    /// per interface it answers on. They are tried in order and the first 200 ends it, so a
    /// dead candidate costs one timeout rather than the pairing.
    func pair(code: String, candidates: [URL]) async throws {
        guard !candidates.isEmpty else { throw Failure.noServerFound }
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        var lastFailure = Failure.noServerFound
        for base in candidates {
            do {
                let decoded = try await redeem(code: cleaned, at: base)
                guard let url = URL(string: decoded.server_url), url.host() != nil else {
                    throw Failure.serverSaid("The server's reply did not make sense.")
                }
                store(url: url, token: decoded.token)
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
