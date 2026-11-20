import Foundation

/// Keeps the initially displayed row and appends new recordings without reordering.
struct SearchRecordingGroups {
    private(set) var tracks: [Track] = []
    private(set) var alternatives: [String: [Track]] = [:]
    private(set) var catalogueTracks: [Track] = []
    private var seen = Set<String>()
    private var indices: [RecordingKey: [Int]] = [:]

    mutating func append(_ results: [Track]) {
        let additions = results.filter { seen.insert($0.playbackKey).inserted }
        let batches = Dictionary(grouping: additions, by: RecordingKey.init)
        for track in additions {
            catalogueTracks.append(track)
            let key = RecordingKey(track)
            let matches = indices[key, default: []].filter {
                Self.source(of: tracks[$0]) != Self.source(of: track) && Self.sameRecording(tracks[$0], track)
            }
            if matches.count == 1, let index = matches.first {
                let primary = tracks[index]
                let source = Self.source(of: track)
                let competingEdit = batches[key, default: []].contains {
                    $0.playbackKey != track.playbackKey && Self.source(of: $0) == source
                        && Self.sameRecording(primary, $0)
                }
                if !competingEdit,
                   alternatives[primary.playbackKey, default: []].allSatisfy({ Self.source(of: $0) != source }) {
                    alternatives[primary.playbackKey, default: []].append(track)
                    continue
                }
            }
            indices[key, default: []].append(tracks.count)
            tracks.append(track)
        }
    }

    static func source(of track: Track) -> String {
        track.normalizedForLXPlayback().source ?? "wy"
    }

    static func sameRecording(_ lhs: Track, _ rhs: Track) -> Bool {
        let key = RecordingKey(lhs)
        guard !key.title.isEmpty, !key.artists.isEmpty, key == RecordingKey(rhs),
              lhs.duration > 0, rhs.duration > 0 else { return false }
        return abs(lhs.duration - rhs.duration) <= 3
    }

    private struct RecordingKey: Hashable {
        let title: String
        let artists: Set<String>
        let versions: Set<String>

        init(_ track: Track) {
            title = Self.normalize(track.name)
            artists = Set(track.artists.flatMap { $0.name.components(separatedBy: ["/", "&", "、", ",", "，", ";", "；"]) }
                .map(Self.normalize).filter { !$0.isEmpty })
            let details = [track.subtitle ?? "", track.album.name].joined(separator: " ").lowercased()
            let groups = [
                ["live", "现场", "演唱会"], ["remix", "混音", "dj"],
                ["instrumental", "伴奏", "纯音乐"], ["cover", "翻唱"],
                ["acoustic", "不插电"], ["demo", "小样"], ["remaster", "重制"]
            ]
            versions = Set(groups.compactMap { group in
                group.contains { marker in
                    if marker.utf8.allSatisfy({ $0 < 128 }) {
                        return details.range(of: "\\b\(marker)\\w*\\b", options: .regularExpression) != nil
                    }
                    return details.contains(marker)
                } ? group[0] : nil
            })
        }

        private static func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }
}

/// Bounded, in-memory hints from the most recently played search list.
@MainActor
enum SearchPlaybackAlternatives {
    private static var tracks: [String: [Track]] = [:]

    static func remember(for queue: [Track], groups: [String: [Track]]) {
        tracks = Dictionary(uniqueKeysWithValues: Set(queue.map(\.playbackKey)).compactMap { key in
            groups[key].map { (key, $0) }
        })
    }

    static func match(_ track: Track, on source: String) -> Track? {
        tracks[track.playbackKey]?.first {
            SearchRecordingGroups.source(of: $0) == source && SearchRecordingGroups.sameRecording(track, $0)
        }
    }
}
