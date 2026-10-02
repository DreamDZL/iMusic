import AVFoundation
import Foundation

/// Tracks seek requests that belong to the active playback item.
///
/// A new track invalidates callbacks from the previous item's seeks and drops
/// its queued position. An explicit resume position (for example, changing the
/// playback quality) is retained for the replacement item.
struct PlaybackSeekCoordinator {
    private(set) var generation = 0
    private(set) var pendingPosition: TimeInterval?

    var initialPlaybackPosition: TimeInterval { pendingPosition ?? 0 }

    @discardableResult
    mutating func beginSeek(to seconds: TimeInterval, itemAvailable: Bool) -> Int {
        generation += 1
        let target = seconds.isFinite ? max(0, seconds) : 0
        pendingPosition = itemAvailable ? nil : target
        return generation
    }

    mutating func beginTrackChange(resumingAt seconds: TimeInterval?) {
        generation += 1
        pendingPosition = seconds.map { $0.isFinite ? max(0, $0) : 0 }
    }

    mutating func takePendingPosition() -> TimeInterval? {
        defer { pendingPosition = nil }
        return pendingPosition
    }

    @discardableResult
    mutating func beginResolvedItemSeek() -> Int {
        generation += 1
        return generation
    }

    mutating func invalidate() {
        generation += 1
        pendingPosition = nil
    }

    func isCurrent(_ requestGeneration: Int) -> Bool {
        generation == requestGeneration
    }
}

@MainActor
enum PlaybackItemTransition {
    /// Detaches the outgoing item before asynchronous resolution of its
    /// replacement, cancelling seeks that must not affect the next track.
    static func prepareForTrackChange(
        player: AVPlayer,
        coordinator: inout PlaybackSeekCoordinator,
        resumingAt seconds: TimeInterval?
    ) {
        player.pause()
        coordinator.beginTrackChange(resumingAt: seconds)
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }
}
