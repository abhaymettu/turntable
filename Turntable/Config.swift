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
    /// 8787 by default, `--pair` prints a code good for 15 minutes and one phone, and
    /// `TURNTABLE_PUBLIC_URL` is what makes that code carry an address.
    ///
    /// The one branch in it is the agent's own situation, which only the agent knows: a
    /// shell on the human's Wi-Fi can be discovered by the phone, a shell in a data centre
    /// cannot. The branch changes what the server is started with. It does not change what
    /// comes back to the human, which is one code string either way.
    ///
    /// Nothing here asks the agent to install, sign up for, or log into anything. That is
    /// deliberate: a texting agent cannot answer a browser login prompt, and an agent that
    /// has no reachable address is told to say so in one line rather than improvise one.
    static let setupPrompt = """
        Set up Turntable for me. Everything you need is at \
        https://github.com/abhaymettu/turntable

        You need a shell and Python 3. Nothing to install, no account, no admin rights, \
        and no file in that repo to edit.

        FIRST work out which of these you are. It changes one step and nothing else.

        A. Your shell is on a computer that is on my Wi-Fi right now.
        B. Your shell is somewhere else: a cloud machine, a hosted runner, a server. My \
        phone cannot find you on a network it is not on, so the server has to sit at an \
        address my phone can already reach.

        1. Get the server, either way:
           curl -fsSL https://raw.githubusercontent.com/abhaymettu/turntable/main/server/server.py -o server.py

        2. Start it so it keeps running after your command returns.

        A: nohup python3 server.py > turntable.log 2>&1 &

        B: first find an address my phone can already reach this machine at. Use only \
        what is already there: a public hostname this machine already answers on, a \
        tunnel already installed and running, or a Tailscale address ONLY if my phone is \
        on that same tailnet. Do not install a tunnel, do not sign me up for anything, \
        and do not assume you can use my home computer. If there is no such address, \
        stop and tell me in one line that my phone cannot reach you, and I will run this \
        on my own machine instead. It has to be https:// unless it is a private or \
        tailnet address: the server refuses to mint a code for a public plain-http \
        address, because the code would cross the internet in the clear.
           TURNTABLE_PUBLIC_URL=https://<that address> nohup python3 server.py > turntable.log 2>&1 &

        Then check it is up, either way: curl -s http://localhost:8787/healthz
        That should print {"ok": true, ...}.

        3. Mint the code, same shell, either way:
           python3 server.py --pair

        4. Reply with the code it printed and nothing else. One unbroken string on its \
        own line, no quotes, no backticks, no explanation.
        In case A that is six characters. In case B it is longer and starts with TT1-, \
        because it carries your address inside it. Both go into the same box in my app, \
        so do not send the address separately and do not reformat the code.

        The code lasts 15 minutes and works once. If it expires, run step 3 again.
        In case A, keep that computer on my Wi-Fi until I have entered the code.
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
