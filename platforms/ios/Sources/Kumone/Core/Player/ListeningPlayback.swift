import Foundation

/// Accumulates elapsed listening from media-clock movement, bounded by
/// monotonic elapsed time. Media positions alone include seek jumps.
struct ListeningPlayback {
    let id = UUID()
    private(set) var seconds: TimeInterval = 0
    private var anchor: Sample?

    private struct Sample {
        let position: TimeInterval
        let uptime: TimeInterval
        let rate: Double
    }

    mutating func sample(position: TimeInterval, uptime: TimeInterval, rate: Double,
                         isPlaying: Bool) {
        guard position.isFinite, uptime.isFinite, rate.isFinite, rate > 0 else {
            discontinuity()
            return
        }
        let previous = anchor
        anchor = isPlaying ? Sample(position: position, uptime: uptime, rate: rate) : nil
        guard let previous else { return }
        let wallTime = uptime - previous.uptime
        let mediaTime = (position - previous.position) / previous.rate
        guard wallTime > 0, mediaTime > 0, mediaTime <= wallTime + 0.25 else { return }
        seconds += min(wallTime, mediaTime)
    }

    mutating func discontinuity() { anchor = nil }

    var reportableSeconds: Int { Int(seconds.rounded(.down)) }

    func qualifiesForSync(trackDuration: TimeInterval) -> Bool {
        let threshold = trackDuration.isFinite && trackDuration > 0
            ? min(30, max(5, trackDuration / 2))
            : 30
        return seconds >= threshold
    }
}

struct PersonalFMTrackHistory {
    private var seen: Set<String> = []

    func contains(_ track: Track) -> Bool {
        seen.contains(track.normalizedForLXPlayback().playbackKey)
    }

    mutating func unseen(_ tracks: [Track]) -> [Track] {
        tracks.map { $0.normalizedForLXPlayback() }.filter { seen.insert($0.playbackKey).inserted }
    }
}
