import Foundation
import Combine

struct LocalPlaylist: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var coverURL: String?
    var sourceName: String?
    var tracks: [Track]
    let createdAt: Date
    var updatedAt: Date?
    /// When present, this local playlist mirrors a user-selected cloud
    /// playlist. The source is intentionally explicit so another provider can
    /// be added without confusing it with a normal local import.
    var remoteSource: String?
    var remotePlaylistID: String?
    var remoteRevision: Int?
    var lxSyncID: String?
    /// A selected provider playlist becomes a frozen local copy after the user
    /// edits it. The provider identity remains for attribution and deduplication.
    var isLocalCopy: Bool?

    init(id: UUID = UUID(), name: String, coverURL: String? = nil,
         sourceName: String? = nil, tracks: [Track] = [], createdAt: Date = .now,
         updatedAt: Date? = nil,
         remoteSource: String? = nil, remotePlaylistID: String? = nil,
         remoteRevision: Int? = nil, lxSyncID: String? = nil,
         isLocalCopy: Bool? = nil) {
        self.id = id
        self.name = name
        self.coverURL = coverURL
        self.sourceName = sourceName
        self.tracks = tracks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remoteSource = remoteSource
        self.remotePlaylistID = remotePlaylistID
        self.remoteRevision = remoteRevision
        self.lxSyncID = lxSyncID
        self.isLocalCopy = isLocalCopy
    }
}

enum LocalPlaylistSyncPolicy {
    static func shouldApplyProviderSnapshot(to playlist: LocalPlaylist?) -> Bool {
        playlist?.isLocalCopy != true
    }

    static func shouldRefreshFromProvider(_ playlist: LocalPlaylist) -> Bool {
        playlist.isLocalCopy != true
    }

    static func shouldPreserveLocalEdits(
        current: LocalPlaylist?,
        incomingLocalCopyFlag: Bool?,
        incomingUpdateTime: Int?
    ) -> Bool {
        guard let current, current.isLocalCopy == true else { return false }
        guard incomingLocalCopyFlag == true else { return true }
        guard let localUpdatedAt = current.updatedAt ?? current.createdAt,
              let incomingUpdateTime,
              incomingUpdateTime > 0 else { return true }
        let incomingUpdatedAt = Date(timeIntervalSince1970: TimeInterval(incomingUpdateTime) / 1_000)
        return incomingUpdatedAt <= localUpdatedAt
    }

    static func matchesProviderPlaylist(_ playlist: LocalPlaylist, source: String, id: String) -> Bool {
        playlist.remoteSource == source && playlist.remotePlaylistID == id
    }

    static func providerIdentityKey(source: String, id: String) -> String {
        "\(source.lowercased())\u{1F}\(id)"
    }

    static func deduplicateProviderPlaylists(_ playlists: [LXSyncUserPlaylist]) -> [LXSyncUserPlaylist] {
        var result: [LXSyncUserPlaylist] = []
        var groupedPlaylists: [[LXSyncUserPlaylist]] = []
        var resultIndicesByGroup: [Int] = []
        var indicesByProviderIdentity: [String: Int] = [:]

        for incoming in playlists {
            guard let source = incoming.source,
                  let sourceListID = incoming.sourceListId,
                  !sourceListID.isEmpty else {
                result.append(incoming)
                continue
            }
            let key = providerIdentityKey(source: source, id: sourceListID)
            guard let index = indicesByProviderIdentity[key] else {
                let groupIndex = groupedPlaylists.count
                indicesByProviderIdentity[key] = groupIndex
                resultIndicesByGroup.append(result.count)
                result.append(incoming)
                groupedPlaylists.append([incoming])
                continue
            }
            groupedPlaylists[index].append(incoming)
        }

        for (index, group) in groupedPlaylists.enumerated() {
            guard !group.isEmpty else { continue }
            let protectedCopies = group.filter { $0.iMusicLocalCopy == true }
            let candidates = protectedCopies.isEmpty ? group : protectedCopies
            var winner = candidates.sorted(by: isPreferredDuplicate).first ?? group[0]
            // The stable sync ID is independent of which row wins the content
            // comparison, so merge results do not vary with server row order.
            winner.id = group.map(\.id).min() ?? winner.id
            if !protectedCopies.isEmpty { winner.iMusicLocalCopy = true }
            result[resultIndicesByGroup[index]] = winner
        }

        return result
    }

    private static func isPreferredDuplicate(_ lhs: LXSyncUserPlaylist, _ rhs: LXSyncUserPlaylist) -> Bool {
        switch (lhs.locationUpdateTime, rhs.locationUpdateTime) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return stableContentKey(lhs) < stableContentKey(rhs)
        }
    }

    private static func stableContentKey(_ playlist: LXSyncUserPlaylist) -> String {
        var content = playlist
        content.id = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(content) else { return content.name }
        return data.base64EncodedString()
    }

    static func merge(_ remote: LXSyncUserPlaylist, with current: LocalPlaylist?) -> LocalPlaylist {
        let preserveLocalEdits = shouldPreserveLocalEdits(
            current: current,
            incomingLocalCopyFlag: remote.iMusicLocalCopy,
            incomingUpdateTime: remote.locationUpdateTime
        )
        let preserved = preserveLocalEdits ? current : nil
        let coverURL = remote.iMusicCoverURL
            ?? remote.list.first(where: { $0.meta.picUrl != nil })?.meta.picUrl
        let updatedAt = remote.locationUpdateTime.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1_000)
        } ?? current?.updatedAt ?? current?.createdAt ?? .now

        return LocalPlaylist(
            id: current?.id ?? UUID(),
            name: preserved?.name ?? remote.name,
            coverURL: preserved != nil ? preserved?.coverURL : coverURL,
            sourceName: preserved != nil ? preserved?.sourceName : (remote.iMusicSourceName ?? remote.source),
            tracks: preserved?.tracks ?? remote.list.map { $0.track.normalizedForLXPlayback() },
            createdAt: current?.createdAt ?? updatedAt,
            updatedAt: preserved != nil ? preserved?.updatedAt : updatedAt,
            remoteSource: preserved != nil ? preserved?.remoteSource : remote.source,
            remotePlaylistID: preserved != nil ? preserved?.remotePlaylistID : remote.sourceListId,
            remoteRevision: preserved != nil ? preserved?.remoteRevision : remote.locationUpdateTime,
            lxSyncID: remote.id,
            isLocalCopy: current?.isLocalCopy == true || remote.iMusicLocalCopy == true
        )
    }

    static func mergeAll(
        _ syncedPlaylists: [LXSyncUserPlaylist],
        currentPlaylists: [LocalPlaylist]
    ) -> [LocalPlaylist] {
        let currentBySyncID = Dictionary(
            currentPlaylists.compactMap { playlist in playlist.lxSyncID.map { ($0, playlist) } },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByProviderIdentity = Dictionary(
            currentPlaylists.compactMap { playlist -> (String, LocalPlaylist)? in
                guard let source = playlist.remoteSource,
                      let remoteID = playlist.remotePlaylistID else { return nil }
                let key = providerIdentityKey(source: source, id: remoteID)
                return (key, playlist)
            },
            uniquingKeysWith: { current, duplicate in
                let currentDate = current.updatedAt ?? current.createdAt
                let duplicateDate = duplicate.updatedAt ?? duplicate.createdAt
                return duplicateDate > currentDate ? duplicate : current
            }
        )

        return deduplicateProviderPlaylists(syncedPlaylists).map { remote in
            let providerMatch: LocalPlaylist? = {
                guard let source = remote.source, let id = remote.sourceListId else { return nil }
                return currentByProviderIdentity[providerIdentityKey(source: source, id: id)]
            }()
            let current = [currentBySyncID[remote.id], providerMatch]
                .compactMap { $0 }
                .max { lhs, rhs in
                    (lhs.updatedAt ?? lhs.createdAt) < (rhs.updatedAt ?? rhs.createdAt)
                }
            return merge(remote, with: current)
        }
    }
}

enum PlaylistImportError: LocalizedError {
    case emptyInput
    case unsupportedLink
    case invalidFormat
    case noTracks

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "请输入歌单链接、文字或 JSON 文件内容"
        case .unsupportedLink: return "无法识别歌单链接；支持网易云、QQ、酷狗、酷我、咪咕和汽水公开歌单"
        case .invalidFormat: return "无法识别歌单格式"
        case .noTracks: return "歌单中没有可导入的歌曲"
        }
    }
}

@MainActor
final class LocalPlaylistStore: ObservableObject {
    static let shared = LocalPlaylistStore()

    @Published private(set) var playlists: [LocalPlaylist]
    @Published private(set) var favoriteTracks: [Track]
    @Published private(set) var recentTracks: [Track]

    private let key = "moumusic.localPlaylists.v1"
    private let favoritesKey = "imusic.localFavorites.v1"
    private let recentTracksKey = "imusic.recentTracks.v1"

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = UserDefaults.standard.data(forKey: key) {
            playlists = (try? decoder.decode([LocalPlaylist].self, from: data))
                ?? (try? JSONDecoder().decode([LocalPlaylist].self, from: data))
                ?? []
        } else { playlists = [] }
        if let data = UserDefaults.standard.data(forKey: favoritesKey) {
            favoriteTracks = (try? JSONDecoder().decode([Track].self, from: data)) ?? []
        } else { favoriteTracks = [] }
        if let data = UserDefaults.standard.data(forKey: recentTracksKey) {
            recentTracks = (try? JSONDecoder().decode([Track].self, from: data)) ?? []
        } else { recentTracks = [] }
    }

    func recordRecent(_ track: Track) {
        let normalized = track.normalizedForLXPlayback()
        recentTracks.removeAll { $0.playbackKey == normalized.playbackKey }
        recentTracks.insert(normalized, at: 0)
        recentTracks = Array(recentTracks.prefix(100))
        guard let data = try? JSONEncoder().encode(recentTracks) else { return }
        UserDefaults.standard.set(data, forKey: recentTracksKey)
    }

    func playlist(id: UUID) -> LocalPlaylist? {
        playlists.first { $0.id == id }
    }

    func isFavorite(_ track: Track) -> Bool {
        favoriteTracks.contains { $0.playbackKey == track.playbackKey }
    }

    func toggleFavorite(_ track: Track) {
        if let index = favoriteTracks.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            favoriteTracks.remove(at: index)
        } else {
            favoriteTracks.insert(track.normalizedForLXPlayback(), at: 0)
        }
        persistFavorites()
    }

    @discardableResult
    func mergeFavorites(_ tracks: [Track]) -> Int {
        var knownKeys = Set(favoriteTracks.map(\.playbackKey))
        let additions = tracks
            .map { $0.normalizedForLXPlayback() }
            .filter { knownKeys.insert($0.playbackKey).inserted }
        guard !additions.isEmpty else { return 0 }
        favoriteTracks.append(contentsOf: additions)
        persistFavorites()
        return additions.count
    }

    /// Assign stable LX list identifiers once so local lists remain addressable
    /// after another device merges them through the sync server.
    func preparePlaylistsForLXSync() -> [LocalPlaylist] {
        var changed = false
        for index in playlists.indices where playlists[index].lxSyncID == nil {
            playlists[index].lxSyncID = playlists[index].id.uuidString
            changed = true
        }
        if changed { persist() }
        return playlists
    }

    func replaceFromLXSync(playlists syncedPlaylists: [LXSyncUserPlaylist], favorites: [Track]) {
        playlists = LocalPlaylistSyncPolicy.mergeAll(syncedPlaylists, currentPlaylists: playlists)
        favoriteTracks = favorites.map { $0.normalizedForLXPlayback() }
        persist(notifySync: false)
        persistFavorites(notifySync: false)
    }

    func containsRemotePlaylist(source: String, id: Int) -> Bool {
        playlists.contains {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: source, id: String(id))
        }
    }

    /// Creates or updates a local mirror of a cloud playlist. Existing local
    /// imports are never matched by name; only an explicit provider + remote
    /// ID can be updated automatically.
    @discardableResult
    func upsertRemotePlaylist(
        source: String,
        remoteID: Int,
        name: String,
        coverURL: String?,
        sourceName: String,
        revision: Int,
        tracks: [Track]
    ) -> (id: UUID, inserted: Bool, changed: Bool) {
        let normalizedTracks = tracks.map { $0.normalizedForLXPlayback() }
        if let index = playlists.firstIndex(where: {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: source, id: String(remoteID))
        }) {
            let old = playlists[index]
            guard LocalPlaylistSyncPolicy.shouldApplyProviderSnapshot(to: old) else {
                return (old.id, false, false)
            }
            let changed = old.name != name
                || old.coverURL != coverURL
                || old.remoteRevision != revision
                || old.tracks != normalizedTracks
            guard changed else {
                return (old.id, false, false)
            }
            playlists[index].name = name
            playlists[index].coverURL = coverURL
            playlists[index].sourceName = sourceName
            playlists[index].tracks = normalizedTracks
            playlists[index].remoteRevision = revision
            playlists[index].updatedAt = .now
            persist()
            return (old.id, false, true)
        }

        let playlist = LocalPlaylist(
            name: name,
            coverURL: coverURL,
            sourceName: sourceName,
            tracks: normalizedTracks,
            remoteSource: source,
            remotePlaylistID: String(remoteID),
            remoteRevision: revision
        )
        playlists.insert(playlist, at: 0)
        persist()
        return (playlist.id, true, true)
    }

    @discardableResult
    func create(name: String, tracks: [Track] = [], coverURL: String? = nil,
                sourceName: String? = nil,
                remoteSource: String? = nil,
                remotePlaylistID: String? = nil,
                remoteRevision: Int? = nil,
                isLocalCopy: Bool? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let playlist = LocalPlaylist(name: trimmed, coverURL: coverURL,
                                     sourceName: sourceName, tracks: tracks,
                                     remoteSource: remoteSource,
                                     remotePlaylistID: remotePlaylistID,
                                     remoteRevision: remoteRevision,
                                     isLocalCopy: isLocalCopy)
        playlists.insert(playlist, at: 0)
        persist()
        return playlist.id
    }

    func rename(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard playlists[index].name != trimmed else { return }
        markAsLocalCopyIfProviderPlaylist(at: index)
        playlists[index].name = trimmed
        playlists[index].updatedAt = .now
        persist()
    }

    func movePlaylists(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        Self.move(&playlists, fromOffsets: offsets, toOffset: destination)
        let modifiedAt = Date()
        for index in playlists.indices { playlists[index].updatedAt = modifiedAt }
        persist()
    }

    func moveTracks(fromOffsets offsets: IndexSet, toOffset destination: Int, in playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let originalTracks = playlists[index].tracks
        var tracks = originalTracks
        Self.move(&tracks, fromOffsets: offsets, toOffset: destination)
        guard tracks != originalTracks else { return }
        markAsLocalCopyIfProviderPlaylist(at: index)
        playlists[index].tracks = tracks
        playlists[index].updatedAt = .now
        persist()
    }

    func delete(id: UUID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let key = trackKey(track)
        guard !playlists[index].tracks.contains(where: { trackKey($0) == key }) else {
            ToastCenter.shared.show("歌曲已经在这个歌单中")
            return
        }
        markAsLocalCopyIfProviderPlaylist(at: index)
        playlists[index].tracks.append(track)
        playlists[index].updatedAt = .now
        persist()
        ToastCenter.shared.show("已添加到「\(playlists[index].name)」")
    }

    /// Adds a group of tracks while preserving the order supplied by the caller.
    /// Local playlists are source-agnostic, so duplicates are skipped using the
    /// same source-aware key as the single-track API.
    @discardableResult
    func add(_ tracks: [Track], to playlistID: UUID) -> Int {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return 0 }

        var existingKeys = Set(playlists[index].tracks.map(trackKey))
        var added = 0
        for track in tracks {
            let key = trackKey(track)
            guard existingKeys.insert(key).inserted else { continue }
            playlists[index].tracks.append(track)
            added += 1
        }

        if added > 0 {
            markAsLocalCopyIfProviderPlaylist(at: index)
            playlists[index].updatedAt = .now
            persist()
        }
        return added
    }

    func remove(_ track: Track, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let key = trackKey(track)
        let originalCount = playlists[index].tracks.count
        playlists[index].tracks.removeAll { trackKey($0) == key }
        guard playlists[index].tracks.count != originalCount else { return }
        markAsLocalCopyIfProviderPlaylist(at: index)
        playlists[index].updatedAt = .now
        persist()
    }

    func remove(_ tracks: [Track], from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        let keys = Set(tracks.map(trackKey))
        guard !keys.isEmpty else { return }
        let originalCount = playlists[index].tracks.count
        playlists[index].tracks.removeAll { keys.contains(trackKey($0)) }
        guard playlists[index].tracks.count != originalCount else { return }
        markAsLocalCopyIfProviderPlaylist(at: index)
        playlists[index].updatedAt = .now
        persist()
    }

    @discardableResult
    func importPlaylist(from input: String) async throws -> UUID {
        let imported = try await PlaylistImportService.importPlaylist(from: input)
        if let remoteSource = imported.remoteSource,
           let remotePlaylistID = imported.remotePlaylistID,
           let existing = playlists.first(where: {
               LocalPlaylistSyncPolicy.matchesProviderPlaylist(
                   $0,
                   source: remoteSource,
                   id: remotePlaylistID
               )
           }) {
            return existing.id
        }
        let id = create(name: imported.name, tracks: imported.tracks,
                        coverURL: imported.coverURL, sourceName: imported.sourceName,
                        remoteSource: imported.remoteSource,
                        remotePlaylistID: imported.remotePlaylistID,
                        remoteRevision: imported.remoteRevision,
                        isLocalCopy: imported.isLocalCopy)
        guard let id else { throw PlaylistImportError.invalidFormat }
        return id
    }

    func exportText(_ playlist: LocalPlaylist) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(playlist),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private func persist(notifySync: Bool = true) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(playlists) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if notifySync { notifyLXSync() }
    }

    private func markAsLocalCopyIfProviderPlaylist(at index: Int) {
        guard playlists[index].remoteSource != nil || playlists[index].remotePlaylistID != nil else { return }
        playlists[index].isLocalCopy = true
    }

    private func persistFavorites(notifySync: Bool = true) {
        guard let data = try? JSONEncoder().encode(favoriteTracks) else { return }
        UserDefaults.standard.set(data, forKey: favoritesKey)
        if notifySync { notifyLXSync() }
    }

    private func notifyLXSync() {
        NotificationCenter.default.post(name: .iMusicLocalLibraryDidChange, object: nil)
    }

    private func trackKey(_ track: Track) -> String {
        let source = track.source ?? "wy"
        let mid = track.sourceMetadata["songmid"] ?? track.sourceMetadata["id"] ?? String(track.id)
        return "\(source)|\(mid)|\(track.name.lowercased())|\(track.artistNames.lowercased())"
    }

    private static func move<Element>(
        _ elements: inout [Element],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) {
        guard !offsets.isEmpty else { return }
        let validOffsets = offsets.filter { elements.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.sorted().map { elements[$0] }
        for index in validOffsets.sorted(by: >) { elements.remove(at: index) }
        let movedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - movedBeforeDestination, 0), elements.count)
        elements.insert(contentsOf: moving, at: insertionIndex)
    }
}

extension Notification.Name {
    static let iMusicLocalLibraryDidChange = Notification.Name("iMusicLocalLibraryDidChange")
}

private struct ImportedPlaylist {
    let name: String
    let coverURL: String?
    let sourceName: String?
    let tracks: [Track]
    let remoteSource: String?
    let remotePlaylistID: String?
    let remoteRevision: Int?
    let isLocalCopy: Bool?

    init(
        name: String,
        coverURL: String?,
        sourceName: String?,
        tracks: [Track],
        remoteSource: String? = nil,
        remotePlaylistID: String? = nil,
        remoteRevision: Int? = nil,
        isLocalCopy: Bool? = nil
    ) {
        self.name = name
        self.coverURL = coverURL
        self.sourceName = sourceName
        self.tracks = tracks
        self.remoteSource = remoteSource
        self.remotePlaylistID = remotePlaylistID
        self.remoteRevision = remoteRevision
        self.isLocalCopy = isLocalCopy
    }
}

private enum PlaylistImportService {
    static func importPlaylist(from input: String) async throws -> ImportedPlaylist {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw PlaylistImportError.emptyInput }

        // A share sheet often gives us a sentence rather than a bare URL,
        // for example: “这是我收藏的歌单 https://y.qq.com/...”。Extract
        // every URL first and try recognized playlist links in order.
        let candidates = extractURLs(from: value)
        if !candidates.isEmpty {
            var lastError: Error?
            var foundSupportedLink = false
            for url in candidates {
                var reference = playlistReference(from: url)
                if reference == nil {
                    reference = try? await resolvedPlaylistReference(from: url)
                }
                guard reference != nil else {
                    continue
                }
                foundSupportedLink = true
                do {
                    return try await importRemotePlaylist(from: url)
                } catch {
                    lastError = error
                }
            }
            if foundSupportedLink {
                throw lastError ?? PlaylistImportError.invalidFormat
            }
            throw PlaylistImportError.unsupportedLink
        }

        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return try importJSON(object)
        }

        throw PlaylistImportError.invalidFormat
    }

    private enum RemotePlaylistPlatform {
        case netease
        case catalog(LXCatalogPlatform)
        case qishuiPlaylist

        var displayName: String {
            switch self {
            case .netease: return LXCatalogPlatform.wy.displayName
            case .catalog(let platform): return platform.displayName
            case .qishuiPlaylist: return "汽水音乐"
            }
        }
    }

    private struct RemotePlaylistReference {
        let platform: RemotePlaylistPlatform
        let id: String
    }

    private static func importRemotePlaylist(from url: URL) async throws -> ImportedPlaylist {
        let resolvedURL = (try? await resolveRedirect(from: url)) ?? url
        guard let reference = playlistReference(from: resolvedURL)
                ?? playlistReference(from: url) else {
            throw PlaylistImportError.unsupportedLink
        }

        switch reference.platform {
        case .netease:
            return try await importNeteasePlaylist(id: reference.id)
        case .catalog(let platform):
            guard platform != .aggregate else { throw PlaylistImportError.unsupportedLink }
            do {
                let detail = try await LXCatalogService.playlistDetail(source: platform,
                                                                         id: reference.id)
                guard !detail.tracks.isEmpty else { throw PlaylistImportError.noTracks }
                return ImportedPlaylist(
                    name: detail.name,
                    coverURL: detail.coverURL,
                    sourceName: platform.displayName,
                    tracks: detail.tracks,
                    remoteSource: platform.rawValue,
                    remotePlaylistID: reference.id,
                    isLocalCopy: true
                )
            } catch let error as PlaylistImportError {
                throw error
            } catch {
                throw PlaylistImportError.invalidFormat
            }
        case .qishuiPlaylist:
            guard let shareURL = URL(string: reference.id) else {
                throw PlaylistImportError.unsupportedLink
            }
            return try await importQishuiPlaylist(url: shareURL)
        }
    }

    private static func importQishuiPlaylist(url: URL) async throws -> ImportedPlaylist {
        let resolved = try await QishuiAPI.shared.resolvePlaylist(sharedURL: url)
        let tracks = resolved.tracks.enumerated().map { index, item in
            let artistName = item.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = artistName.isEmpty ? "汽水音乐" : artistName
            let trackID = Int(item.id) ?? stableID("qishui|\(item.id)|\(item.name)|\(index)")
            let artistID = stableID("qishui-artist|\(artist)")
            var metadata = [
                "songmid": item.id,
                "qishuiTrackID": item.id,
                "qishuiURL": item.shareURL.absoluteString,
            ]
            if let albumName = item.albumName, !albumName.isEmpty {
                metadata["qishui.album"] = albumName
            }
            return Track(
                id: trackID,
                name: item.name,
                artists: [ArtistRef(id: artistID, name: artist)],
                album: AlbumRef(id: 0, name: item.albumName ?? "汽水音乐", picUrl: item.coverURL),
                durationMS: item.durationMS,
                source: "sd",
                sourceMetadata: metadata
            )
        }
        guard !tracks.isEmpty else { throw PlaylistImportError.noTracks }
        return ImportedPlaylist(
            name: resolved.name,
            coverURL: resolved.coverURL,
            sourceName: "汽水音乐",
            tracks: tracks,
            remoteSource: "sd",
            remotePlaylistID: resolved.id,
            remoteRevision: resolved.revision,
            isLocalCopy: true
        )
    }

    private static func importNeteasePlaylist(id: String) async throws -> ImportedPlaylist {
        guard let playlistID = Int(id) else { throw PlaylistImportError.unsupportedLink }

        var components = URLComponents(string: "https://music.163.com/api/v6/playlist/detail")!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(playlistID)),
            URLQueryItem(name: "n", value: "1000"),
        ]
        let root = try await fetchJSONObject(components.url!)
        if let code = integer(root["code"]), code != 200 {
            throw PlaylistImportError.invalidFormat
        }
        guard let playlist = (root["playlist"] as? [String: Any])
                ?? ((root["result"] as? [String: Any])?["playlist"] as? [String: Any]) else {
            throw PlaylistImportError.invalidFormat
        }

        var tracks = collectTracks(from: playlist["tracks"] ?? [], defaultSource: "wy")
        let ids = (playlist["trackIds"] as? [[String: Any]])?
            .compactMap { string($0["id"]) }
            .filter { !$0.isEmpty } ?? []
        // The v6 endpoint deliberately returns only a preview in `tracks`
        // even when n=1000. Fetch the full trackIds list so a shared playlist
        // is not silently truncated to ten songs.
        if tracks.count < ids.count, !ids.isEmpty {
            var detailComponents = URLComponents(string: "https://music.163.com/api/song/detail")!
            detailComponents.queryItems = [
                URLQueryItem(name: "ids", value: "[\(ids.joined(separator: ","))]"),
            ]
            if let details = try? await fetchJSONObject(detailComponents.url!) {
                let detailedTracks = collectTracks(from: details["songs"] ?? details["data"] ?? details,
                                                    defaultSource: "wy")
                if !detailedTracks.isEmpty { tracks = detailedTracks }
            }
        }
        guard !tracks.isEmpty else { throw PlaylistImportError.noTracks }

        let name = string(playlist["name"]) ?? "网易云歌单 \(playlistID)"
        let cover = string(playlist["coverImgUrl"])
            ?? string(playlist["picUrl"])
            ?? string(playlist["cover"])
        return ImportedPlaylist(name: name, coverURL: cover,
                                sourceName: "网易云", tracks: tracks,
                                remoteSource: "netease",
                                remotePlaylistID: String(playlistID),
                                remoteRevision: integer(playlist["updateTime"]),
                                isLocalCopy: true)
    }

    private static func resolvedPlaylistReference(from url: URL) async throws -> RemotePlaylistReference {
        let resolvedURL = try await resolveRedirect(from: url)
        guard let reference = playlistReference(from: resolvedURL) else {
            throw PlaylistImportError.unsupportedLink
        }
        return reference
    }

    /// Finds the public playlist identifier in a platform share URL. The
    /// patterns intentionally stay provider-specific so a song or artist URL
    /// cannot accidentally be imported as a playlist.
    private static func playlistReference(from url: URL) -> RemotePlaylistReference? {
        guard let host = url.host?.lowercased() else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map {
            ($0.name.lowercased(), $0.value ?? "")
        })
        let parts = url.path.split(separator: "/").map(String.init)

        func firstID(after markers: [String]) -> String? {
            for marker in markers {
                guard let index = parts.firstIndex(where: { $0.lowercased() == marker }),
                      index + 1 < parts.count else { continue }
                let value = parts[index + 1].split(separator: ".").first.map(String.init) ?? ""
                if !value.isEmpty { return value }
            }
            return nil
        }

        if host.contains("163cn.tv") || host.contains("music.163.com") {
            let path = url.path.lowercased()
            let fragment = url.fragment?.lowercased() ?? ""
            guard host.contains("163cn.tv") || path.contains("playlist") || fragment.contains("playlist") else {
                return nil
            }
            if let id = neteasePlaylistID(from: url) {
                return RemotePlaylistReference(platform: .netease, id: String(id))
            }
            return nil
        }

        if host == "y.qq.com" || host.hasSuffix(".y.qq.com") || host == "c.y.qq.com" {
            let id = query["disstid"] ?? query["playlistid"] ?? query["playlist_id"]
                ?? firstID(after: ["playlist", "playsquare"])
            guard let id, !id.isEmpty else { return nil }
            return RemotePlaylistReference(platform: .catalog(.tx), id: id)
        }

        if host.contains("kugou.com") {
            let id = query["globalid"] ?? query["listid"] ?? query["playlistid"]
                ?? firstID(after: ["single", "playlist", "special"])
            guard let id, !id.isEmpty else { return nil }
            // Kugou's newer share page appends the adapter and page size,
            // e.g. `/single/12345-5-9999.html`; the detail adapter expects
            // only the numeric special ID.
            let normalizedID: String
            if let first = id.split(separator: "-").first,
               Int(first) != nil {
                normalizedID = String(first)
            } else {
                normalizedID = id
            }
            return RemotePlaylistReference(platform: .catalog(.kg), id: normalizedID)
        }

        if host.contains("kuwo.cn") {
            let id = query["pid"] ?? query["playlistid"] ?? query["playlist_id"]
                ?? firstID(after: ["playlist_detail", "playlist", "songlist"])
            guard let id, !id.isEmpty else { return nil }
            return RemotePlaylistReference(platform: .catalog(.kw), id: id)
        }

        if host.contains("migu.cn") {
            let id = query["playlistid"] ?? query["playlist_id"]
                ?? firstID(after: ["collection", "playlist"])
            guard let id, !id.isEmpty else { return nil }
            return RemotePlaylistReference(platform: .catalog(.mg), id: id)
        }

        if QishuiAPI.isPlaylistURL(url) {
            return RemotePlaylistReference(platform: .qishuiPlaylist, id: url.absoluteString)
        }

        // A short `/s/...` URL is ambiguous until its redirect target is
        // known. Returning nil here makes importPlaylist resolve it first;
        // otherwise it would be sent to the single-track endpoint.
        if QishuiAPI.isShortShareURL(url) {
            return nil
        }

        return nil
    }

    private static func extractURLs(from text: String) -> [URL] {
        let pattern = #"https?://[^\s<>\"'，。！？；、）)\]}]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            var raw = String(text[matchRange])
            while let last = raw.last, ".,!?;:，。！？；、".contains(last) {
                raw.removeLast()
            }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return nil }
            return url
        }
    }

    private static func resolveRedirect(from url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url ?? url
    }

    private static func fetchJSONObject(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlaylistImportError.invalidFormat
        }
        return object
    }

    private static func neteasePlaylistID(from url: URL) -> Int? {
        func queryID(_ components: URLComponents?) -> Int? {
            components?.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value
                .flatMap(Int.init)
        }

        if let id = queryID(URLComponents(url: url, resolvingAgainstBaseURL: false)) {
            return id
        }
        if let fragment = url.fragment,
           let id = queryID(URLComponents(string: fragment)) {
            return id
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if let index = parts.firstIndex(where: { $0.lowercased() == "playlist" }),
           index + 1 < parts.count {
            return Int(parts[index + 1])
        }
        return nil
    }

    private static func importJSON(_ object: Any, defaultSource: String? = nil) throws -> ImportedPlaylist {
        let tracks = collectTracks(from: object, defaultSource: defaultSource)
        guard !tracks.isEmpty else { throw PlaylistImportError.noTracks }
        let root = object as? [String: Any]
        let name = string(root?["name"])
            ?? string(root?["title"])
            ?? string(root?["playlistName"])
            ?? "导入歌单"
        let cover = string(root?["coverURL"])
            ?? string(root?["coverUrl"])
            ?? string(root?["picUrl"])
            ?? string(root?["coverImgUrl"])
        return ImportedPlaylist(name: name, coverURL: cover,
                                sourceName: string(root?["source"]), tracks: tracks)
    }

    private static func collectTracks(from object: Any, defaultSource: String? = nil) -> [Track] {
        if let array = object as? [Any] {
            return array.flatMap { collectTracks(from: $0, defaultSource: defaultSource) }
        }
        guard let dictionary = object as? [String: Any] else { return [] }
        if let track = makeTrack(dictionary, defaultSource: defaultSource) { return [track] }

        let keys = ["tracks", "songs", "musicList", "musiclist", "list", "playlist", "data", "result"]
        for key in keys {
            if let nested = dictionary[key] {
                let tracks = collectTracks(from: nested, defaultSource: defaultSource)
                if !tracks.isEmpty { return tracks }
            }
        }
        return []
    }

    private static func makeTrack(_ value: [String: Any], defaultSource: String? = nil) -> Track? {
        let name = string(value["name"]) ?? string(value["songName"])
            ?? string(value["SongName"]) ?? string(value["title"])
            ?? string(value["songname"])
        guard let name, !name.isEmpty else { return nil }

        let artistValue = value["artists"] ?? value["ar"]
        let artistNames: [String]
        if let array = artistValue as? [[String: Any]] {
            artistNames = array.compactMap { string($0["name"]) }
        } else if let array = artistValue as? [String] {
            artistNames = array
        } else {
            let text = string(value["artist"]) ?? string(value["singer"])
                ?? string(value["singername"]) ?? string(value["Singers"])
                ?? string(value["artistNames"]) ?? "未知歌手"
            artistNames = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let artists = artistNames.enumerated().map { ArtistRef(id: $0.offset, name: $0.element) }
        let albumValue = value["album"] ?? value["al"]
        let albumDictionary = albumValue as? [String: Any]
        let albumName = string(albumDictionary?["name"])
            ?? string(value["albumName"]) ?? string(value["albumname"]) ?? ""
        let cover = string(albumDictionary?["picUrl"])
            ?? string(albumDictionary?["pic"])
            ?? string(value["coverURL"])
            ?? string(value["picUrl"])
            ?? string(value["img"])
        let rawID = string(value["id"]) ?? string(value["songid"])
            ?? string(value["songId"]) ?? string(value["songmid"])
            ?? string(value["mid"]) ?? string(value["hash"])
        guard let rawID, !rawID.isEmpty else { return nil }
        let id = Int(rawID) ?? stableID(rawID)
        guard id > 0 else { return nil }

        var metadata: [String: String] = [:]
        for key in ["songmid", "songMid", "songId", "hash", "FileHash", "copyrightId",
                    "albumId", "strMediaMid", "albumMid", "id"] {
            if let value = string(value[key]), !value.isEmpty { metadata[key] = value }
        }
        let source = string(value["source"])?.lowercased() ?? defaultSource
        return Track(id: id, name: name, artists: artists,
                     album: AlbumRef(id: Int(string(albumDictionary?["id"]) ?? "") ?? 0,
                                    name: albumName, picUrl: cover),
                     durationMS: durationMS(value), source: source,
                     sourceMetadata: metadata)
    }

    private static func durationMS(_ value: [String: Any]) -> Int {
        let raw = value["durationMS"] ?? value["dt"] ?? value["duration"] ?? value["interval"]
            ?? value["Duration"]
        if let number = raw as? NSNumber { return Int(number.doubleValue) }
        guard let text = string(raw) else { return 0 }
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2 { return Int((parts[0] * 60 + parts[1]) * 1000) }
        }
        let number = Double(text) ?? 0
        return Int(number < 1000 ? number * 1000 : number)
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func stableID(_ value: String) -> Int {
        var hash: UInt64 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 16_777_619 }
        return Int(hash & 0x7fff_ffff)
    }

}
