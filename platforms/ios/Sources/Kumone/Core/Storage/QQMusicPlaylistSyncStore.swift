import Foundation
import Combine

/// Reads QQ Music playlists and copies explicitly selected playlists into the
/// local library. Edits stay in iMusic and can be synchronized through LX Sync;
/// this store intentionally has no QQ write operations.
@MainActor
final class QQMusicPlaylistSyncStore: ObservableObject {
    static let shared = QQMusicPlaylistSyncStore()

    struct ImportReport: Equatable {
        let inserted: Int
        let unchanged: Int
        let failed: [String]
    }

    @Published private(set) var playlists: [QQMusicAPI.Playlist] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImporting = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var errorMessage: String?

    private var lastRefreshAttempt: Date?

    private init() {}

    /// Refreshes only playlist metadata. Track pages are fetched only after an
    /// explicit import action, which keeps foreground refreshes light.
    func refresh(force: Bool = false) async {
        let session = QQMusicSessionStore.shared
        guard session.isLoggedIn, let requestCookie = session.cookie else {
            playlists = []
            errorMessage = nil
            return
        }
        guard !isRefreshing else { return }
        if !force,
           let lastRefreshAttempt,
           Date().timeIntervalSince(lastRefreshAttempt) < 5 * 60 {
            return
        }

        let sessionRevision = session.sessionRevision
        isRefreshing = true
        lastRefreshAttempt = .now
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let result = try await QQMusicAPI.shared.userPlaylists(cookie: requestCookie)
            guard session.sessionRevision == sessionRevision, session.isLoggedIn else { return }
            session.acceptRefreshedCookie(result.refreshedCookie,
                                          expectedSessionRevision: sessionRevision,
                                          expectedCookie: requestCookie)
            playlists = result.playlists
            lastRefreshedAt = .now
        } catch {
            guard session.sessionRevision == sessionRevision, session.isLoggedIn else { return }
            errorMessage = "QQ 歌单暂时无法获取，请稍后重试。"
        }
    }

    func isImported(_ playlistID: String) -> Bool {
        LocalPlaylistStore.shared.playlists.contains {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: playlistID)
        }
    }

    func importSelected(_ ids: Set<String>) async -> ImportReport {
        let session = QQMusicSessionStore.shared
        guard !isImporting else {
            return ImportReport(inserted: 0, unchanged: 0, failed: [])
        }
        guard session.isLoggedIn, session.cookie != nil else {
            return ImportReport(inserted: 0, unchanged: 0, failed: ["请先登录 QQ 音乐"])
        }

        let selected = playlists.filter { ids.contains($0.id) }
        guard !selected.isEmpty else {
            return ImportReport(inserted: 0, unchanged: 0, failed: [])
        }

        let sessionRevision = session.sessionRevision
        isImporting = true
        defer { isImporting = false }
        var inserted = 0
        var unchanged = 0
        var failed: [String] = []

        for playlist in selected {
            guard !Task.isCancelled else {
                failed.append("导入已取消")
                break
            }
            guard session.sessionRevision == sessionRevision, session.isLoggedIn else {
                failed.append("QQ 登录状态已变化，请重新选择歌单")
                break
            }
            if isImported(playlist.id) {
                unchanged += 1
                continue
            }
            guard let currentCookie = session.cookie else {
                failed.append("\(playlist.name)：QQ 登录已失效")
                break
            }
            do {
                let result = try await QQMusicAPI.shared.playlistTracks(
                    id: playlist.id,
                    cookie: currentCookie,
                    expectedTrackCount: playlist.trackCount
                )
                try Task.checkCancellation()
                guard session.sessionRevision == sessionRevision, session.isLoggedIn else {
                    failed.append("\(playlist.name)：QQ 登录状态已变化，未保存本地副本")
                    break
                }
                session.acceptRefreshedCookie(result.refreshedCookie,
                                              expectedSessionRevision: sessionRevision,
                                              expectedCookie: currentCookie)
                let tracks = result.tracks
                guard !tracks.isEmpty || playlist.trackCount == 0 else {
                    failed.append("\(playlist.name)：歌单没有可导入的歌曲")
                    continue
                }
                // Imports can await while LX Sync is merging another device's
                // library. Recheck the provider identity immediately before
                // creating a local copy so the same playlist is never added
                // twice in this window.
                if isImported(playlist.id) {
                    unchanged += 1
                    continue
                }
                guard LocalPlaylistStore.shared.create(
                    name: playlist.name,
                    tracks: tracks,
                    coverURL: playlist.coverURL,
                    sourceName: "QQ 音乐",
                    remoteSource: "qq",
                    remotePlaylistID: playlist.id,
                    remoteRevision: playlist.trackCount,
                    isLocalCopy: true
                ) != nil else {
                    failed.append("\(playlist.name)：无法创建本地歌单")
                    continue
                }
                inserted += 1
            } catch is CancellationError {
                failed.append("\(playlist.name)：导入已取消")
                break
            } catch {
                failed.append("\(playlist.name)：\(error.localizedDescription)")
            }
        }

        return ImportReport(inserted: inserted, unchanged: unchanged, failed: failed)
    }
}
