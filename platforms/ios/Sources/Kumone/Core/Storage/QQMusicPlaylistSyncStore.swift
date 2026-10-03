import Foundation
import Combine

/// Reads QQ Music playlists and keeps a one-way local copy. Edits stay in
/// iMusic and can be synchronized through LX Sync; this store intentionally
/// has no QQ write operations.
@MainActor
final class QQMusicPlaylistSyncStore: ObservableObject {
    static let shared = QQMusicPlaylistSyncStore()

    struct ImportReport: Equatable {
        let inserted: Int
        let updated: Int
        let unchanged: Int
        let failed: [String]

        var changedCount: Int { inserted + updated }
    }

    @Published private(set) var playlists: [QQMusicAPI.Playlist] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isImporting = false
    @Published private(set) var isSyncingAfterLogin = false
    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var lastLoginSyncMessage: String?

    private var lastRefreshAttempt: Date?
    private var lastRefreshedSessionRevision: Int?
    private var loginSyncTask: Task<Void, Never>?
    private var loginSyncTaskID: UUID?
    private var loginSyncTaskRevision: Int?

    private init() {}

    func hasValidatedSnapshot(for sessionRevision: Int) -> Bool {
        lastRefreshedSessionRevision == sessionRevision && errorMessage == nil
    }

    /// Seeds the first account-sync pass with the response that validated the
    /// just-completed login, avoiding a duplicate provider request.
    func acceptValidatedSnapshot(
        _ result: QQMusicAPI.PlaylistListResult,
        sessionRevision: Int
    ) {
        let session = QQMusicSessionStore.shared
        guard session.isLoggedIn, session.sessionRevision == sessionRevision else { return }
        playlists = result.playlists
        warningMessage = result.warningMessage
        errorMessage = nil
        lastRefreshedAt = .now
        lastRefreshAttempt = .now
        lastRefreshedSessionRevision = sessionRevision
    }

    /// Refreshes only playlist metadata. Track pages are fetched during the
    /// post-login copy or after a user explicitly retries a local copy.
    func refresh(force: Bool = false) async {
        let session = QQMusicSessionStore.shared
        guard session.isLoggedIn, let requestCookie = session.cookie else {
            playlists = []
            errorMessage = nil
            warningMessage = nil
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
        // Never reuse a playlist snapshot for a sync started after a refresh
        // failure. A successful fetch sets this back to the active revision.
        lastRefreshedSessionRevision = nil
        errorMessage = nil
        warningMessage = nil
        defer { isRefreshing = false }

        do {
            let result = try await QQMusicAPI.shared.userPlaylists(cookie: requestCookie)
            guard session.sessionRevision == sessionRevision, session.isLoggedIn else { return }
            session.acceptRefreshedCookie(result.refreshedCookie,
                                          expectedSessionRevision: sessionRevision,
                                          expectedCookie: requestCookie)
            session.recordPlaylistValidationSuccess(expectedSessionRevision: sessionRevision)
            playlists = result.playlists
            warningMessage = result.warningMessage
            lastRefreshedAt = .now
            lastRefreshedSessionRevision = sessionRevision
        } catch {
            guard session.sessionRevision == sessionRevision, session.isLoggedIn else { return }
            errorMessage = "QQ 歌单暂时无法获取：\(error.localizedDescription)"
            session.recordPlaylistValidationFailure(
                error.localizedDescription,
                expectedSessionRevision: sessionRevision
            )
        }
    }

    /// A successful sign-in immediately mirrors every visible QQ playlist to
    /// the local library. Track requests run serially and the local copies keep
    /// the existing protection against overwriting edits made in iMusic.
    func syncAfterLogin() async {
        let session = QQMusicSessionStore.shared
        while session.isLoggedIn {
            let revision = session.sessionRevision
            if let task = loginSyncTask, let taskID = loginSyncTaskID {
                let taskRevision = loginSyncTaskRevision
                await task.value
                if loginSyncTaskID == taskID {
                    loginSyncTask = nil
                    loginSyncTaskID = nil
                    loginSyncTaskRevision = nil
                }
                guard session.isLoggedIn else { return }
                if session.sessionRevision != revision || taskRevision != revision { continue }
                return
            }

            let taskID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runLoginSync(sessionRevision: revision)
            }
            loginSyncTask = task
            loginSyncTaskID = taskID
            loginSyncTaskRevision = revision
            await task.value
            if loginSyncTaskID == taskID {
                loginSyncTask = nil
                loginSyncTaskID = nil
                loginSyncTaskRevision = nil
            }
            guard session.isLoggedIn else { return }
            if session.sessionRevision == revision { return }
        }
    }

    private func runLoginSync(sessionRevision revision: Int) async {
        let session = QQMusicSessionStore.shared
        guard session.isLoggedIn, session.sessionRevision == revision else { return }
        isSyncingAfterLogin = true
        lastLoginSyncMessage = nil
        defer { isSyncingAfterLogin = false }

        // AccountSyncView also refreshes on the session change. Join that
        // request instead of issuing duplicate playlist calls.
        while isRefreshing {
            guard session.isLoggedIn, session.sessionRevision == revision else { return }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        guard session.isLoggedIn, session.sessionRevision == revision else { return }
        if lastRefreshedSessionRevision != revision || errorMessage != nil {
            await refresh(force: true)
        }
        guard session.isLoggedIn, session.sessionRevision == revision else { return }
        guard lastRefreshedSessionRevision == revision, errorMessage == nil else {
            lastLoginSyncMessage = errorMessage
            return
        }
        guard !playlists.isEmpty else {
            lastLoginSyncMessage = warningMessage.map {
                "没有导入歌单：\($0)"
            } ?? "账号中没有可同步的歌单"
            return
        }

        let report = await importSelected(Set(playlists.map(\.id)))
        guard session.isLoggedIn, session.sessionRevision == revision else { return }
        if report.failed.isEmpty {
            lastLoginSyncMessage = "QQ 歌单同步完成：新增 \(report.inserted)，更新 \(report.updated)，最新 \(report.unchanged)"
        } else {
            let details = report.failed.prefix(2).joined(separator: "；")
            let shortenedDetails = details.count > 220
                ? String(details.prefix(217)) + "…"
                : details
            lastLoginSyncMessage = "已同步 \(report.changedCount) 个，\(report.failed.count) 个歌单暂时失败：\(shortenedDetails)"
        }
        if let warning = warningMessage {
            lastLoginSyncMessage = [lastLoginSyncMessage, warning]
                .compactMap { $0 }
                .joined(separator: "；")
        }
    }

    func isImported(_ playlistID: String) -> Bool {
        LocalPlaylistStore.shared.playlists.contains {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: playlistID)
        }
    }

    /// Only untouched provider copies can be refreshed. Any local edit freezes
    /// the list as an iMusic copy and remains safe from a later remote snapshot.
    func canRefresh(_ playlistID: String) -> Bool {
        guard let localCopy = LocalPlaylistStore.shared.playlists.first(where: {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: playlistID)
        }) else { return false }
        return LocalPlaylistSyncPolicy.canRefreshProviderPlaylist(
            localCopy,
            source: "qq",
            id: playlistID
        )
    }

    func importSelected(
        _ ids: Set<String>,
        overwriteEdited: Set<String> = [],
        overwriteSnapshots: [String: LocalPlaylist] = [:]
    ) async -> ImportReport {
        let session = QQMusicSessionStore.shared
        guard !isImporting else {
            return ImportReport(inserted: 0, updated: 0, unchanged: 0, failed: [])
        }
        guard session.isLoggedIn, session.cookie != nil else {
            return ImportReport(inserted: 0, updated: 0, unchanged: 0, failed: ["请先登录 QQ 音乐"])
        }

        let selected = playlists.filter { ids.contains($0.id) }
        guard !selected.isEmpty else {
            return ImportReport(inserted: 0, updated: 0, unchanged: 0, failed: [])
        }

        let sessionRevision = session.sessionRevision
        isImporting = true
        defer { isImporting = false }
        var inserted = 0
        var updated = 0
        var unchanged = 0
        var failed: [String] = []
        var successfullyReadTrackList = false
        let localStore = LocalPlaylistStore.shared

        for playlist in selected {
            guard !Task.isCancelled else {
                failed.append("导入已取消")
                break
            }
            guard session.sessionRevision == sessionRevision, session.isLoggedIn else {
                failed.append("QQ 登录状态已变化，请重新选择歌单")
                break
            }
            let overwriteLocalCopy = overwriteEdited.contains(playlist.id)
            let expectedLocalCopy = overwriteSnapshots[playlist.id]
            if overwriteLocalCopy, expectedLocalCopy == nil {
                failed.append("\(playlist.name)：本地副本已变化，请重新选择")
                continue
            }
            if isImported(playlist.id), !canRefresh(playlist.id), !overwriteLocalCopy {
                unchanged += 1
                continue
            }
            guard let currentCookie = session.cookie else {
                failed.append("\(playlist.name)：QQ 登录已失效")
                break
            }
            do {
                let tracksResult = try await QQMusicAPI.shared.playlistTracks(
                    id: playlist.id,
                    cookie: currentCookie,
                    expectedTrackCount: playlist.trackCount
                )
                try Task.checkCancellation()
                guard session.sessionRevision == sessionRevision, session.isLoggedIn else {
                    failed.append("\(playlist.name)：QQ 登录状态已变化，未保存本地副本")
                    break
                }
                successfullyReadTrackList = true
                session.acceptRefreshedCookie(tracksResult.refreshedCookie,
                                              expectedSessionRevision: sessionRevision,
                                              expectedCookie: currentCookie)
                let tracks = tracksResult.tracks
                guard !tracks.isEmpty || playlist.trackCount == 0 else {
                    failed.append("\(playlist.name)：歌单没有可导入的歌曲")
                    continue
                }
                if overwriteLocalCopy {
                    let currentLocalCopy = localStore.playlists.first(where: {
                        LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: playlist.id)
                    })
                    guard currentLocalCopy == expectedLocalCopy else {
                        failed.append("\(playlist.name)：本地副本在更新期间发生变化，没有覆盖；请重试")
                        continue
                    }
                }
                // Rechecking occurs inside upsert after the network awaits, so
                // a concurrent edit or LX Sync merge cannot be overwritten.
                let upsertResult = localStore.upsertRemotePlaylist(
                    source: "qq",
                    remoteID: playlist.id,
                    name: playlist.name,
                    coverURL: playlist.coverURL,
                    sourceName: "QQ 音乐",
                    revision: playlist.trackCount,
                    tracks: tracks,
                    allowOverwritingLocalEdits: overwriteLocalCopy
                )
                if upsertResult.inserted {
                    inserted += 1
                } else if upsertResult.changed {
                    updated += 1
                } else {
                    unchanged += 1
                }
            } catch is CancellationError {
                failed.append("\(playlist.name)：导入已取消")
                break
            } catch {
                if let apiError = error as? QQMusicAPI.APIError,
                   case .providerRejected(let detail) = apiError,
                   detail.localizedCaseInsensitiveContains("3a44") {
                    let diagnostic = "QQ 歌单详情接口仍返回 3a44。接口阶段：\(detail)。此码不能证明登录失效；若为个人歌单，请检查 QQ 音乐个人主页和歌单可见性设置后重试"
                    session.recordPlaylistValidationFailure(
                        diagnostic,
                        expectedSessionRevision: sessionRevision
                    )
                    failed.append("\(playlist.name)：\(diagnostic)")
                    // Treat the observed provider response as a sync failure,
                    // but do not claim that this opaque code proves a missing
                    // ticket or invalidates the account session.
                    break
                }
                if let apiError = error as? QQMusicAPI.APIError,
                   case .sessionCredentialRejected = apiError {
                    session.recordPlaylistValidationFailure(
                        error.localizedDescription,
                        expectedSessionRevision: sessionRevision
                    )
                    failed.append("\(playlist.name)：\(error.localizedDescription)")
                    // This is a session-wide credential failure; repeating the
                    // same request for every playlist only adds long waits.
                    break
                }
                failed.append("\(playlist.name)：\(error.localizedDescription)")
            }
        }

        if failed.isEmpty, successfullyReadTrackList {
            session.recordTrackListSyncSuccess(expectedSessionRevision: sessionRevision)
        }

        return ImportReport(inserted: inserted, updated: updated, unchanged: unchanged, failed: failed)
    }
}
