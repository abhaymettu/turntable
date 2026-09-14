import Foundation

/// Posts the APNs device token to the server's `/apns-token` endpoint, the same
/// fire-and-forget style as AgentLink's check-in POST. Failure is logged, not surfaced,
/// since there is no UI waiting on this.
@MainActor
final class APNsLink {
    static let shared = APNsLink()

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    func submit(token: String) async {
        guard let base = Pairing.shared.serverURL, let bearer = Pairing.shared.token else {
            DebugLog.shared.add("apns", "not paired, token not posted")
            return
        }
        var request = URLRequest(url: base.appending(path: "/apns-token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": Config.deviceID,
            "token": token,
            "app_version": Config.appVersion,
        ])
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                DebugLog.shared.add("apns", "server rejected the token post")
                return
            }
            DebugLog.shared.add("apns", "token posted to server")
        } catch {
            DebugLog.shared.add("apns", "token post failed: \(error.localizedDescription)")
        }
    }
}
