import Foundation

/// Build-time constants. Nothing here points at a particular server: the address and the
/// token both arrive at pairing time and live in `Pairing`.
enum Config {
    static let checkInInterval: Duration = .seconds(15)

    /// The whole of setup, written to be pasted into any coding agent. Edit it here.
    ///
    /// Written for the smallest agent that could do the job: one shell, Python 3, and a
    /// way to fetch a URL. It names no vendor, no plugin and no runtime, because the
    /// human pastes it into whatever they already talk to. Every step is drafted against
    /// what `server/server.py` actually does: stdlib only with nothing to install, port
    /// 8787 by default, `--pair` prints a six character code good for 15 minutes and one
    /// phone, and `TURNTABLE_PUBLIC_URL` is the address a freshly paired phone keeps.
    ///
    /// The Tailscale and tunnel options are last and marked optional on purpose. They are
    /// the one part of the old prompt an agent could not carry out without installing
    /// software and answering a login prompt, which is exactly what a texting agent
    /// cannot do.
    static let setupPrompt = """
        Set up Turntable for me. Everything you need is at \
        https://github.com/abhaymettu/turntable

        What this needs from you: a shell on a computer that is on the same Wi-Fi as my \
        phone right now, and Python 3. Nothing else. No installs, no accounts, no code \
        changes, no admin rights.

        1. Get the server. Clone the repo, or just download the one file it needs:
           curl -fsSL https://raw.githubusercontent.com/abhaymettu/turntable/main/server/server.py -o server.py

        2. Start it so it keeps running after your command returns. On macOS or Linux:
           nohup python3 server.py > turntable.log 2>&1 &
        Wait a second, then check it is up: curl -s http://localhost:8787/healthz
        That should print {"ok": true, ...}.

        3. Mint a pairing code, in the same shell:
           python3 server.py --pair

        4. Reply with ONLY the six characters it prints. No address, no explanation, \
        nothing else. The code lasts 15 minutes and works once.

        My phone finds the server on the Wi-Fi by itself, so it never asks me to type an \
        address. Keep that computer on my Wi-Fi until I have entered the code.

        OPTIONAL, skip if unsure: if that computer ALREADY has Tailscale or a tunnel \
        running, start the server in step 2 with the address my phone should keep, and \
        Turntable keeps working after I leave this Wi-Fi:
           TURNTABLE_PUBLIC_URL=http://<that address>:8787 nohup python3 server.py > turntable.log 2>&1 &
        Do not install anything for this. Without it pairing still works; I just have to \
        stay on this Wi-Fi, and we can redo it later.
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
