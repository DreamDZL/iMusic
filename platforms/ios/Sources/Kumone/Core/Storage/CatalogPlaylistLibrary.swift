import Foundation

enum CatalogPlaylistSaveError: LocalizedError {
    case invalidIdentity
    case invalidName
    case noTracks
    case invalidTrack
    case incomplete(expected: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: return "歌单来源信息无效，无法收藏"
        case .invalidName: return "歌单名称无效，无法收藏"
        case .noTracks: return "歌单没有已加载的歌曲，无法收藏"
        case .invalidTrack: return "歌单包含无效歌曲，无法收藏"
        case let .incomplete(expected, received):
            return "歌单歌曲尚未完整加载（\(received)/\(expected)），请稍后重试"
        }
    }
}

enum CatalogPlaylistSaveIntent: Equatable {
    case verifiedCompletePlaylist
    case loadedTracksSnapshot
}

enum CatalogPlaylistSaveValidator {
    static func validate(
        source: String,
        playlistID: String,
        name: String,
        tracks: [Track],
        declaredTrackCount: Int? = nil
    ) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !playlistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogPlaylistSaveError.invalidIdentity
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogPlaylistSaveError.invalidName
        }
        guard !tracks.isEmpty else { throw CatalogPlaylistSaveError.noTracks }
        guard tracks.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CatalogPlaylistSaveError.invalidTrack
        }
        if let declaredTrackCount, declaredTrackCount > 0, tracks.count != declaredTrackCount {
            throw CatalogPlaylistSaveError.incomplete(expected: declaredTrackCount, received: tracks.count)
        }
    }
}

@MainActor
extension LocalPlaylistStore {
    /// Saves the exact track snapshot supplied by the caller. Completeness is a
    /// caller/UI decision: only pass a declared count when it is known and has
    /// already been verified. Omitting it stores a confirmed loaded-track snapshot,
    /// not a claim that the provider's playlist was fully fetched.
    @discardableResult
    func saveCatalogPlaylist(
        source: String,
        playlistID: String,
        name: String,
        tracks: [Track],
        coverURL: String?,
        sourceName: String?,
        intent: CatalogPlaylistSaveIntent,
        declaredTrackCount: Int? = nil
    ) throws -> UUID {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !playlistID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogPlaylistSaveError.invalidIdentity
        }
        if let existing = playlists.first(where: {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: source, id: playlistID)
        }) {
            return existing.id
        }
        switch intent {
        case .verifiedCompletePlaylist:
            try CatalogPlaylistSaveValidator.validate(
                source: source,
                playlistID: playlistID,
                name: name,
                tracks: tracks,
                declaredTrackCount: declaredTrackCount
            )
        case .loadedTracksSnapshot:
            // A snapshot saves only supplied tracks and deliberately makes no
            // claim against the provider's total, even if it is known to differ.
            try CatalogPlaylistSaveValidator.validate(
                source: source,
                playlistID: playlistID,
                name: name,
                tracks: tracks
            )
        }
        guard let id = create(
            name: name,
            tracks: tracks,
            coverURL: coverURL,
            sourceName: sourceName,
            remoteSource: source,
            remotePlaylistID: playlistID,
            isLocalCopy: true
        ) else {
            throw CatalogPlaylistSaveError.invalidName
        }
        return id
    }
}
