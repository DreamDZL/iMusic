#if os(iOS)
import ActivityKit
import Foundation

/// Legacy attributes kept so the app can close Live Activities created by
/// older builds during migration. New builds do not ship a Live Activity widget.
@available(iOS 16.1, *)
public struct MoumusicPlaybackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var artworkURL: String?
        public var elapsed: TimeInterval
        public var duration: TimeInterval
        public var isPlaying: Bool
        public var playbackRate: Double
        public var updatedAt: Date

        public init(
            title: String,
            artist: String,
            artworkURL: String?,
            elapsed: TimeInterval,
            duration: TimeInterval,
            isPlaying: Bool,
            playbackRate: Double = 1,
            updatedAt: Date = .now
        ) {
            self.title = title
            self.artist = artist
            self.artworkURL = artworkURL
            self.elapsed = max(0, elapsed)
            self.duration = max(0, duration)
            self.isPlaying = isPlaying
            self.playbackRate = max(0.1, playbackRate)
            self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey {
            case title, artist, artworkURL, elapsed, duration, isPlaying, playbackRate, updatedAt
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try values.decode(String.self, forKey: .title)
            artist = try values.decode(String.self, forKey: .artist)
            artworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL)
            elapsed = max(0, try values.decode(TimeInterval.self, forKey: .elapsed))
            duration = max(0, try values.decode(TimeInterval.self, forKey: .duration))
            isPlaying = try values.decode(Bool.self, forKey: .isPlaying)
            playbackRate = max(0.1, try values.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1)
            updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        }

        public var playbackInterval: ClosedRange<Date> {
            let safeRate = max(playbackRate, 0.1)
            let safeDuration = max(duration, 1)
            let safeElapsed = min(max(elapsed, 0), safeDuration)
            let start = updatedAt.addingTimeInterval(-safeElapsed / safeRate)
            return start...start.addingTimeInterval(safeDuration / safeRate)
        }
    }

    public var sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }
}

/// Cleans up Live Activities created by older versions of the app. Playback
/// uses Apple's native Now Playing card exclusively.
@available(iOS 16.2, *)
@MainActor
final class MoumusicPlaybackActivityManager {
    static let shared = MoumusicPlaybackActivityManager()

    private init() {}

    func endExistingActivities() {
        Task {
            for activity in Activity<MoumusicPlaybackActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
#endif
