import MusicKit
import Observation

/// Authorization and subscription state for Apple Music.
/// Pattern follows wesmatlock/MusicKitDemo (MIT), see README.
@MainActor
@Observable
final class MusicService {
    enum Gate: Equatable {
        case checking
        case needsPermission      // not asked yet
        case denied               // user said no, or parental restriction
        case noSubscription       // authorized, but cannot play catalog content
        case ready
    }

    private(set) var gate: Gate = .checking
    private(set) var status: MusicAuthorization.Status = .notDetermined
    /// True when Apple says this account can be offered a subscription. Drives the upgrade sheet.
    private(set) var canOfferSubscription = false
    private var subscriptionWatcher: Task<Void, Never>?

    /// Called on first appearance. Asks once when undetermined, otherwise just reads.
    func bootstrap() async {
        status = MusicAuthorization.currentStatus
        if status == .notDetermined {
            status = await MusicAuthorization.request()
        }
        await refresh()
    }

    func requestAgain() async {
        status = await MusicAuthorization.request()
        await refresh()
    }

    func refresh() async {
        switch status {
        case .authorized:
            await checkSubscription()
            watchSubscription()
        case .denied, .restricted:
            gate = .denied
        case .notDetermined:
            gate = .needsPermission
        @unknown default:
            gate = .denied
        }
    }

    private func checkSubscription() async {
        do {
            let sub = try await MusicSubscription.current
            apply(sub)
        } catch {
            // In the simulator with no Media account this throws. Treat as no subscription;
            // the view says what to do.
            gate = .noSubscription
            canOfferSubscription = false
            DebugLog.shared.add("music", "subscription check failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ sub: MusicSubscription) {
        canOfferSubscription = sub.canBecomeSubscriber
        gate = sub.canPlayCatalogContent ? .ready : .noSubscription
    }

    /// Subscription can change under us (user subscribes from the sheet). Keep following it.
    private func watchSubscription() {
        guard subscriptionWatcher == nil else { return }
        subscriptionWatcher = Task { [weak self] in
            for await sub in MusicSubscription.subscriptionUpdates {
                guard let self, !Task.isCancelled else { return }
                self.apply(sub)
            }
        }
    }
}
