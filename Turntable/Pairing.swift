import Foundation
import Observation
import Security

/// Where the server is and what proves this phone is allowed to talk to it.
///
/// The app ships with neither. It starts unpaired, the pairing screen trades a short code
/// for a `{server_url, token}` pair, and every later request carries the token as a bearer.
/// The address lives in UserDefaults, the token in the Keychain, because it is a credential.
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
        case serverSaid(String)

        var errorDescription: String? {
            switch self {
            case .badAddress: "That address is not a web address. It looks like http://192.168.1.20:8787"
            case .badCode: "The server does not know that code. Check the six characters and try again."
            case .expired: "That code has expired. Ask for a fresh one; codes last 15 minutes."
            case .cannotReach: "Cannot reach that address. The server may be off, or the phone may be on a different network."
            case .noInternet: "This phone has no network connection."
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

    /// Trade the code for a token. Throws a `Failure` the screen can show verbatim.
    func pair(address: String, code: String) async throws {
        guard let base = Self.normalize(address) else { throw Failure.badAddress }

        var request = URLRequest(url: base.appending(path: "/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            "device_id": Config.deviceID,
        ])
        request.timeoutInterval = 10

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

        guard let decoded = try? JSONDecoder().decode(PairResponse.self, from: data),
              let url = URL(string: decoded.server_url), url.host() != nil
        else { throw Failure.serverSaid("The server's reply did not make sense.") }

        UserDefaults.standard.set(url.absoluteString, forKey: Key.serverURL)
        Keychain.write(decoded.token, account: Key.keychainAccount)
        serverURL = url
        token = decoded.token
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

    static func write(_ value: String, account: String) {
        delete(account)
        var request = query(account)
        request[kSecValueData as String] = Data(value.utf8)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(request as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
