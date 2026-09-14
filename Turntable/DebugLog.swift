import AVFoundation
import Observation
import SwiftUI

/// In-app log. Route changes and agent traffic land here so they can be read on the phone
/// without a Mac attached.
@MainActor
@Observable
final class DebugLog {
    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let tag: String
        let message: String
    }

    static let shared = DebugLog()

    private(set) var entries: [Entry] = []
    private let cap = 400

    func add(_ tag: String, _ message: String) {
        entries.append(Entry(at: Date(), tag: tag, message: message))
        if entries.count > cap { entries.removeFirst(entries.count - cap) }
    }

    func clear() { entries.removeAll() }
}

/// Logs AVAudioSession route changes (AirPods on and off, speaker, wired), and reads the
/// current output for the DJ tab's status line. Read-only throughout: no audio session
/// category or activation calls, so this never hijacks playback.
@MainActor
@Observable
final class RouteLogger {
    private(set) var outputLabel: String
    private var observer: (any NSObjectProtocol)?

    init() {
        outputLabel = Self.label(for: AVAudioSession.sharedInstance().currentRoute)
    }

    func start() {
        guard observer == nil else { return }
        DebugLog.shared.add("route", "listening; current: \(Self.describe(AVAudioSession.sharedInstance().currentRoute))")
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let now = AVAudioSession.sharedInstance().currentRoute
            let line = "\(Self.name(reason)); was \(Self.describe(previous)); now \(Self.describe(now))"
            Task { @MainActor in
                DebugLog.shared.add("route", line)
                self.outputLabel = Self.label(for: now)
            }
        }
    }

    nonisolated private static func describe(_ route: AVAudioSessionRouteDescription?) -> String {
        guard let route, !route.outputs.isEmpty else { return "none" }
        return route.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
    }

    /// AirPods report as bluetoothA2DP (music) or bluetoothHFP (calls); portName is
    /// already the model name the user gave it, e.g. "Jo's AirPods Pro".
    nonisolated private static func label(for route: AVAudioSessionRouteDescription?) -> String {
        guard let output = route?.outputs.first else { return "No audio output" }
        switch output.portType {
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return output.portName
        case .builtInSpeaker:
            return "Speaker"
        case .headphones:
            return "Headphones"
        case .builtInReceiver:
            return "Receiver"
        case .usbAudio:
            return "USB audio"
        case .airPlay:
            return "AirPlay"
        case .carAudio:
            return "Car audio"
        case .HDMI:
            return "HDMI"
        default:
            return output.portName
        }
    }

    nonisolated private static func name(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: "new device available"
        case .oldDeviceUnavailable: "old device unavailable"
        case .categoryChange: "category change"
        case .override: "override"
        case .wakeFromSleep: "wake from sleep"
        case .noSuitableRouteForCategory: "no suitable route"
        case .routeConfigurationChange: "route configuration change"
        case .unknown, .none: "unknown"
        @unknown default: "unknown"
        }
    }
}

/// Everything a developer needs and nobody else does: which server this phone follows, what
/// the link is doing, and the raw log. One gear on the main screen leads here, and nothing
/// from this file appears anywhere else in the app. A grouped list is the right shape here
/// precisely because this is the settings page the main screens refuse to be.
struct AdvancedView: View {
    @Environment(AgentLink.self) private var agent
    @Environment(RouteLogger.self) private var routes
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = Pairing.shared
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            List {
                Section("Link") {
                    LabeledContent("State") {
                        Label(linkWord, systemImage: linkSymbol)
                            .labelStyle(.titleAndIcon)
                            .imageScale(.small)
                            .foregroundStyle(agent.link == .online ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    }
                    if let reason = agent.offlineReason {
                        LabeledContent("Reason") {
                            Text(reason).multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Last check-in",
                                   value: agent.lastContact.map { $0.formatted(date: .omitted, time: .standard) } ?? "none yet")
                    LabeledContent("Interval", value: "15 s")
                }

                Section("Server") {
                    LabeledContent("Address") {
                        Text(pairing.serverURL?.absoluteString ?? "unpaired")
                            .font(.footnote.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Token", value: pairing.token == nil ? "none" : "held in Keychain")
                }

                Section("This Phone") {
                    LabeledContent("Device ID") {
                        Text(Config.deviceID)
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    LabeledContent("App version", value: Config.appVersion)
                    LabeledContent("Audio output", value: routes.outputLabel)
                }

                Section {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        LabeledContent {
                            Text("\(DebugLog.shared.entries.count)").monospacedDigit()
                        } label: {
                            Label {
                                Text("Debug Log")
                            } icon: {
                                Image(systemName: "text.alignleft").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }

                Section {
                    Button("Pair with Another Server", role: .destructive) { confirmUnpair = true }
                } footer: {
                    Text("Turntable goes back to the welcome screen and needs a fresh pairing code.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .screenGround()
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Unpair this phone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    Pairing.shared.unpair()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private var linkWord: String {
        switch agent.link {
        case .idle: "Paused"
        case .online: "Online"
        case .offline: "Offline"
        }
    }

    private var linkSymbol: String {
        switch agent.link {
        case .idle: "pause.circle"
        case .online: "antenna.radiowaves.left.and.right"
        case .offline: "antenna.radiowaves.left.and.right.slash"
        }
    }
}

struct DebugLogView: View {
    private var log = DebugLog.shared

    var body: some View {
        Group {
            if log.entries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Logged Yet", systemImage: "text.alignleft")
                } description: {
                    Text("Route changes and agent check-ins land here.")
                }
            } else {
                List(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.tag.uppercased())
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Text(entry.at, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.separator)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .screenGround()
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { log.clear() }.disabled(log.entries.isEmpty)
            }
        }
    }
}
