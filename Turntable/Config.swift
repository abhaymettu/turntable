import Foundation

/// Build-time constants. Nothing here points at a particular server: the address and the
/// token both arrive at pairing time and live in `Pairing`.
enum Config {
    static let checkInInterval: Duration = .seconds(15)

    /// The whole of setup, written to be pasted into a coding agent. Edit it here.
    ///
    /// It is drafted against what `AGENTS.md` and `server/server.py` actually do: the
    /// server is Python 3 with nothing to install, `./run.sh` starts it on 8787,
    /// `TURNTABLE_PUBLIC_URL` is the address a freshly paired phone is handed back, and
    /// `--pair` prints a six character code good for 15 minutes and one phone.
    static let setupPrompt = """
        Set up Turntable for me. Everything you need is at \
        https://github.com/abhaymettu/turntable

        1. Open that repo and read AGENTS.md first. It is written for you.

        2. Work out the address my phone should keep. If Tailscale is running on this \
        machine, that is its 100.x address. If Tailscale is not installed, install and \
        start it (brew install --cask tailscale, then tailscale up), and tell me in one \
        line that I need to turn Tailscale on on my phone too. Skipping Tailscale is fine, \
        but then Turntable only works while I am on this Wi-Fi.

        3. Start the server with that address:
           cd server && TURNTABLE_PUBLIC_URL=http://<address>:8787 ./run.sh
        Python 3, standard library only, nothing to install. Leave it running.

        4. Keep this machine on the same Wi-Fi as my phone for the next step. The app finds \
        the server over the local network to redeem the code, so it never asks me to type \
        an address.

        5. In a second shell: cd server && python3 server.py --pair

        6. Reply with ONLY the six character code it prints. No address, no explanation, \
        nothing else. It lasts 15 minutes and works once.
        """

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
