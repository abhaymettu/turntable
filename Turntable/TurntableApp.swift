import SwiftUI

@main
struct TurntableApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var pairing = Pairing.shared
    @State private var music = MusicService()
    @State private var player = PlayerModel()
    @State private var agent = AgentLink()
    @State private var routes = RouteLogger()
    @Environment(\.scenePhase) private var scenePhase

    init() { Theme.installBarAppearance() }

    var body: some Scene {
        WindowGroup {
            Group {
                if pairing.isPaired {
                    RootTabView()
                } else {
                    PairingView()
                }
            }
            .environment(music)
            .environment(player)
            .environment(agent)
            .environment(routes)
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase, initial: true) { _, phase in
                // The check-in loop runs from first foreground onward, background included.
                // The audio background mode keeps the process alive while music plays;
                // when iOS suspends a silent app the loop parks and resumes on wake.
                guard phase == .active, pairing.isPaired else { return }
                routes.start()
                agent.start(player: player)
            }
            .onChange(of: pairing.isPaired) { _, paired in
                // Pairing finished on this screen: start the loop without waiting for the
                // next foreground, and stop it the moment the phone is unpaired.
                if paired {
                    routes.start()
                    agent.start(player: player)
                    Task { await AppDelegate.requestNotifications() }
                } else {
                    agent.stop()
                }
            }
        }
    }
}
