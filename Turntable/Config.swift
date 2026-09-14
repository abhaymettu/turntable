import Foundation

/// Build-time constants. Nothing here points at a particular server: the address and the
/// token both arrive at pairing time and live in `Pairing`.
enum Config {
    static let checkInInterval: Duration = .seconds(15)

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Stable per-install id. identifierForVendor can change across reinstalls, so keep our own.
    static var deviceID: String {
        let key = "device_id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
