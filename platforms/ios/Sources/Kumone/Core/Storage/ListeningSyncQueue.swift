import Foundation

struct ListeningSyncEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let track: ListeningTrackIdentity
    let sourceID: Int
    let seconds: Int

    var neteaseID: Int?
    var attempts = 0
    var retryAfter = Date.distantPast
    var inFlight = false
}

struct ListeningTrackIdentity: Codable, Equatable, Sendable {
    let title: String
    let artists: [String]
    let durationMS: Int
    let neteaseID: Int?
    let versions: Set<String>

    init(track: Track, observedDuration: TimeInterval = 0) {
        title = track.name
        artists = track.artists.map(\.name)
        durationMS = track.durationMS > 0 ? track.durationMS
            : (observedDuration.isFinite && observedDuration > 0 && observedDuration < 86_400
                ? Int(observedDuration * 1_000) : 0)
        let normalized = track.normalizedForLXPlayback()
        neteaseID = normalized.source == "wy" && track.id > 0 ? track.id : nil
        versions = Self.recordingVersions(track)
    }

    /// Do not strip version labels or match on a partial artist list. More
    /// than one distinct candidate remains ambiguous even if one ranks higher.
    func uniqueMatch(in candidates: [Track]) -> Int? {
        let targetTitle = Self.normalized(title)
        let targetArtists = Self.artistSet(artists)
        guard !targetTitle.isEmpty, !targetArtists.isEmpty, durationMS > 0 else { return nil }
        let ids = Set(candidates.compactMap { candidate -> Int? in
            guard candidate.id > 0, candidate.durationMS > 0,
                  Self.normalized(candidate.name) == targetTitle,
                  Self.artistSet(candidate.artists.map(\.name)) == targetArtists,
                  Self.recordingVersions(candidate) == versions,
                  abs(Double(candidate.durationMS) - Double(durationMS)) <= 3_000 else { return nil }
            return candidate.id
        })
        return ids.count == 1 ? ids.first : nil
    }

    private static func artistSet(_ artists: [String]) -> Set<String> {
        let separators = CharacterSet(charactersIn: "/&、,，;；")
        return Set(artists.flatMap { $0.components(separatedBy: separators) }
            .map(normalized).filter { !$0.isEmpty })
    }

    private static func recordingVersions(_ track: Track) -> Set<String> {
        // Match the version families used in search grouping. Sync considers
        // every alias and translated subtitle before writing remote history.
        let details = normalized(([track.name, track.album.name] + track.alias + track.transNames)
            .joined(separator: " "))
        return Set(versionGroups.compactMap { group in
            let found = group.contains { marker in
                if marker.utf8.allSatisfy({ $0 < 128 }) {
                    return details.range(of: "\\b\(marker)\\w*\\b", options: .regularExpression) != nil
                }
                return details.contains(marker)
            }
            return found ? group.first : nil
        })
    }

    private static let versionGroups = [
        ["live", "现场", "演唱会"], ["remix", "混音", "dj"],
        ["instrumental", "伴奏", "纯音乐"], ["cover", "翻唱"],
        ["acoustic", "不插电"], ["demo", "小样"], ["remaster", "重制"]
    ]

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum ListeningSubmissionResult: Equatable {
    case accepted, retryable, uncertain

    static func transportFailure(_ error: Error) -> Self {
        guard let error = error as? URLError else { return .uncertain }
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
            return .retryable
        default:
            return .uncertain
        }
    }
}

struct ListeningSyncQueue: Codable, Equatable {
    struct Success: Codable, Equatable {
        let title: String
        let seconds: Int
        let date: Date
    }

    var pending: [ListeningSyncEvent] = []
    private(set) var acceptedCount = 0
    private(set) var acceptedSeconds = 0
    private(set) var unmatchedCount = 0
    private(set) var uncertainCount = 0
    private(set) var lastSuccess: Success?

    mutating func recoverInterruptedSubmissions() {
        uncertainCount += pending.filter(\.inFlight).count
        pending.removeAll(where: \.inFlight)
    }

    mutating func complete(_ event: ListeningSyncEvent, result: ListeningSubmissionResult, now: Date) {
        guard let index = pending.firstIndex(where: { $0.id == event.id }) else { return }
        switch result {
        case .accepted:
            pending.remove(at: index)
            acceptedCount += 1
            acceptedSeconds += event.seconds
            lastSuccess = Success(title: event.track.title, seconds: event.seconds, date: now)
        case .uncertain:
            pending.remove(at: index)
            uncertainCount += 1
        case .retryable:
            pending[index].inFlight = false
            let attempts = min(pending[index].attempts + 1, 7)
            pending[index].attempts = attempts
            pending[index].retryAfter = now.addingTimeInterval(min(900, 15 * pow(2, Double(attempts - 1))))
        }
    }

    mutating func markUnmatched(_ event: ListeningSyncEvent) {
        guard let index = pending.firstIndex(where: { $0.id == event.id }) else { return }
        pending.remove(at: index)
        unmatchedCount += 1
    }
}

struct ListeningSyncFiles {
    let directory: URL

    private func file(_ accountID: Int) -> URL {
        directory.appendingPathComponent("netease-\(accountID)-v1.json")
    }

    func load(accountID: Int) throws -> ListeningSyncQueue {
        do {
            return try JSONDecoder().decode(ListeningSyncQueue.self, from: Data(contentsOf: file(accountID)))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ListeningSyncQueue()
        }
    }

    func save(_ queue: ListeningSyncQueue, accountID: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(queue).write(to: file(accountID), options: .atomic)
    }
}
