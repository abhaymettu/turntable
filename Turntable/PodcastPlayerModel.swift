import AVFoundation
import Observation

/// One episode at a time through AVPlayer. Read-only route/session state stays in
/// RouteLogger; this model only starts and stops playback.
@MainActor
@Observable
final class PodcastPlayerModel {
    private(set) var current: PodcastFeed.Episode?
    private(set) var isPlaying = false
    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVPlayer?
    private var timeObserver: Any?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    func play(_ episode: PodcastFeed.Episode) {
        if current?.id == episode.id {
            togglePlayPause()
            return
        }
        stop()
        current = episode
        duration = episode.durationSeconds ?? 0
        let player = AVPlayer(url: episode.audioURL)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.position = time.seconds
            if let seconds = player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                self?.duration = seconds
            }
        }
        player.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        player = nil
        current = nil
        isPlaying = false
        position = 0
        duration = 0
    }
}
