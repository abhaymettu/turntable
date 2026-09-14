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

struct DebugLogView: View {
    @Environment(\.dismiss) private var dismiss
    private var log = DebugLog.shared

    var body: some View {
        NavigationStack {
            Group {
                if log.entries.isEmpty {
                    ContentUnavailableView(
                        "Nothing logged yet",
                        systemImage: "text.alignleft",
                        description: Text("Route changes and agent check-ins show up here.")
                    )
                } else {
                    List(log.entries.reversed()) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.tag).font(.caption.weight(.semibold))
                                Spacer()
                                Text(entry.at, format: .dateTime.hour().minute().second())
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.message).font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Debug log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { log.clear() }.disabled(log.entries.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
