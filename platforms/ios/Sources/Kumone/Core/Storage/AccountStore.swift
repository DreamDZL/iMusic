import Foundation
#if os(iOS)
import OSLog
#endif

/// Account state used for optional metadata synchronisation.
///
/// This store never supplies an audio URL. Online playback on iOS remains
/// exclusively the responsibility of the selected LX User API source. The
/// account is only used for profile data, daily recommendations, play records,
/// and listening-duration synchronisation.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var profile: UserProfile? {
        didSet {
#if os(iOS)
            ListeningSyncStore.shared.activate(listeningSession)
#endif
        }
    }
    @Published var likedTrackIDs: Set<Int> = []
    @Published var userPlaylists: [PlaylistSummary] = []
    @Published var likedAlbums: [AlbumSummary] = []
    @Published var likedArtists: [ArtistSummary] = []
    @Published var isBootstrapped = false
    @Published private(set) var isSyncingPlaylists = false
    @Published private(set) var lastPlaylistSyncAt: Date?
    @Published private(set) var lastPlaylistSyncError: String?

    struct PlaylistSyncReport: Equatable {
        let inserted: Int
        let updated: Int
        let unchanged: Int
        let failed: [String]

        var changedCount: Int { inserted + updated }
    }

    var isLoggedIn: Bool { NeteaseClient.shared.isLoggedIn && profile != nil }
    var hasAuthCookie: Bool { NeteaseClient.shared.isLoggedIn }
    var vipType: Int { profile?.vipType ?? 0 }

    var likedSongsPlaylist: PlaylistSummary? {
        userPlaylists.first(where: \.isLikedSongsList) ?? userPlaylists.first
    }

    var createdPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId == uid && !$0.isLikedSongsList }
    }

    var subscribedPlaylists: [PlaylistSummary] {
        guard let uid = profile?.userId else { return [] }
        return userPlaylists.filter { $0.creator?.userId != uid }
    }

    private init() {}

    private var loginBootstrapTask: Task<Void, Never>?
    private var importedPlaylistSyncTask: Task<Void, Never>?
    private var loginSessionRevision = 0

#if os(iOS)
    private static let listeningBindingKey = "com.moumusic.netease.listening-owner.v1"
    private static let listeningLog = Logger(subsystem: "im.missuo.kumone", category: "listening-account")
    private lazy var listeningBinding: (accountID: Int, cookies: NeteaseClient.ScopedCookies)? = {
        guard let cookies = NeteaseClient.shared.scopedCookies(),
              let saved = ProviderSessionSupport.readCookie(service: Self.listeningBindingKey),
              let accountID = Self.boundListeningAccountID(saved, tokenDigest: cookies.tokenDigest) else { return nil }
        return (accountID, cookies)
    }()

    var listeningSession: ListeningSyncSession? {
        guard let cookies = NeteaseClient.shared.scopedCookies() else { return nil }
        if let id = profile?.userId, id > 0 {
            return ListeningSyncSession(accountID: id, revision: loginSessionRevision)
        }
        guard let binding = listeningBinding, binding.cookies.hasSameToken(as: cookies) else { return nil }
        return ListeningSyncSession(accountID: binding.accountID, revision: loginSessionRevision)
    }

    nonisolated static func boundListeningAccountID(_ value: String, tokenDigest: String) -> Int? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[1] == tokenDigest, let id = Int(parts[0]), id > 0 else { return nil }
        return id
    }

    func rememberListeningAccount(_ id: Int, using cookies: NeteaseClient.ScopedCookies) {
        guard id > 0, let current = NeteaseClient.shared.scopedCookies(),
              current.hasSameToken(as: cookies) else { return }
        if let binding = listeningBinding, binding.accountID == id, binding.cookies.hasSameToken(as: cookies) { return }
        listeningBinding = (id, cookies)
        do {
            try ProviderSessionSupport.writeCookie("\(id):\(cookies.tokenDigest)", service: Self.listeningBindingKey)
        } catch {
            Self.listeningLog.error("Unable to save account binding")
        }
    }

    private func forgetListeningAccount() {
        listeningBinding = nil
        if !ProviderSessionSupport.deleteCookie(service: Self.listeningBindingKey) {
            Self.listeningLog.error("Unable to delete account binding")
        }
    }
#endif

    private func loadVerifiedProfile(revision: Int) async throws -> UserProfile? {
#if os(iOS)
        guard let cookies = NeteaseClient.shared.scopedCookies() else { throw NeteaseAPIError.needLogin }
        let loaded = try await NeteaseAPI.userAccount(using: cookies)
        guard revision == loginSessionRevision,
              let current = NeteaseClient.shared.scopedCookies(),
              current.hasSameToken(as: cookies) else { throw NeteaseAPIError.needLogin }
        if let loaded { rememberListeningAccount(loaded.userId, using: cookies) }
        return loaded
#else
        return try await NeteaseAPI.userAccount()
#endif
    }

    /// Called at launch and after login succeeds.
    func bootstrap() async {
        defer { isBootstrapped = true }
        guard hasAuthCookie else { return }
#if os(iOS)
        ListeningSyncStore.shared.activate(listeningSession)
#endif
        let revision = loginSessionRevision
        do {
            let loadedProfile = try await loadVerifiedProfile(revision: revision)
            guard revision == loginSessionRevision, hasAuthCookie else { return }
            profile = loadedProfile
        } catch {
            return
        }
        refreshCookieIfNeeded()
        await refreshLibrary()
    }

    /// Installs cookies captured from NetEase's own web login, then validates
    /// them against the account endpoint before exposing a signed-in state.
    func signInFromWeb(cookieHeader: String) async throws {
        loginSessionRevision &+= 1
        let revision = loginSessionRevision
        loginBootstrapTask?.cancel()
        importedPlaylistSyncTask?.cancel()
        isSyncingPlaylists = false
        lastPlaylistSyncAt = nil
        lastPlaylistSyncError = nil
        NeteaseClient.shared.clearAuthCookies()
#if os(iOS)
        forgetListeningAccount()
#endif
        profile = nil
        likedTrackIDs = []
        userPlaylists = []
        likedAlbums = []
        likedArtists = []

        do {
            try NeteaseClient.shared.ingestCookieString(cookieHeader)
            guard hasAuthCookie else { throw NeteaseAPIError.needLogin }
            guard let verifiedProfile = try await loadVerifiedProfile(revision: revision) else {
                throw NeteaseAPIError.missingProfile
            }
            guard revision == loginSessionRevision else { throw NeteaseAPIError.needLogin }
            profile = verifiedProfile
            isBootstrapped = true
            loginBootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshLibrary(syncImportedCopies: false, expectedRevision: revision)
                await self.refreshSublists(expectedRevision: revision)
            }
        } catch {
            if revision == loginSessionRevision {
                NeteaseClient.shared.clearAuthCookies()
#if os(iOS)
                forgetListeningAccount()
#endif
                profile = nil
                likedTrackIDs = []
                userPlaylists = []
                likedAlbums = []
                likedArtists = []
            }
            throw error
        }
    }

    func refreshLibrary(
        syncImportedCopies: Bool = true,
        expectedRevision: Int? = nil
    ) async {
        guard let uid = profile?.userId else { return }
        let revision = expectedRevision ?? loginSessionRevision
        guard revision == loginSessionRevision else { return }
        lastPlaylistSyncError = nil
        async let playlists = try? NeteaseAPI.userPlaylists(uid: uid)
        async let liked = try? NeteaseAPI.likedTrackIDs(uid: uid)
        let fetchedPlaylists = await playlists
        let fetchedLiked = await liked
        guard revision == loginSessionRevision,
              profile?.userId == uid,
              hasAuthCookie else { return }

        if let fetchedPlaylists {
            userPlaylists = fetchedPlaylists
        } else {
            lastPlaylistSyncError = "云端歌单暂时无法获取，稍后可重试。"
        }
        if let fetchedLiked {
            likedTrackIDs = Set(fetchedLiked)
        }

        // Do not show a successful sync timestamp when the playlist request
        // failed and the screen is still displaying stale cached data.
        if fetchedPlaylists != nil {
            if syncImportedCopies { scheduleImportedPlaylistCopySync(userID: uid, revision: revision) }
            lastPlaylistSyncAt = .now
        }
    }

    /// Refresh account-owned cloud playlists when the app comes back to the
    /// foreground. Existing local provider copies update in the background;
    /// their locally edited contents stay protected from a cloud overwrite.
    func refreshForOpen(force: Bool = false) async {
        guard hasAuthCookie else { return }
#if os(iOS)
        ListeningSyncStore.shared.activate(listeningSession)
#endif
        let now = Date()
        if !force,
           let last = lastPlaylistSyncAt,
           now.timeIntervalSince(last) < 20 {
            return
        }
        if profile == nil {
            await bootstrap()
            return
        }
        refreshCookieIfNeeded()
        await refreshLibrary()
    }

    /// Imports the selected cloud playlists into the app's local playlist
    /// page. The remote provider and ID are stored so later foreground opens
    /// can update the same local copy instead of creating duplicates.
    func importSelectedPlaylists(_ ids: Set<Int>) async -> PlaylistSyncReport {
        guard isLoggedIn else {
            return PlaylistSyncReport(inserted: 0, updated: 0, unchanged: 0,
                                      failed: ["请先登录网易云音乐"])
        }
        let selected = userPlaylists.filter { ids.contains($0.id) }
        return await syncPlaylists(selected, force: true)
    }

    func refreshSublists(expectedRevision: Int? = nil) async {
        guard let userID = profile?.userId else { return }
        let revision = expectedRevision ?? loginSessionRevision
        guard revision == loginSessionRevision, hasAuthCookie else { return }
        async let albums = try? NeteaseAPI.likedAlbums()
        async let artists = try? NeteaseAPI.likedArtists()
        let fetchedAlbums = await albums
        let fetchedArtists = await artists
        guard revision == loginSessionRevision,
              profile?.userId == userID,
              hasAuthCookie else { return }
        likedAlbums = fetchedAlbums ?? likedAlbums
        likedArtists = fetchedArtists ?? likedArtists
    }

    /// Copies the account's liked songs into iMusic's local favorites. This is
    /// an explicit one-way import; later local edits never write back to NetEase.
    func importLikedSongsToLocalLibrary() async throws -> (remoteCount: Int, addedCount: Int) {
        guard hasAuthCookie else { throw NeteaseAPIError.needLogin }
        let userID: Int
        if let profileUserID = profile?.userId {
            userID = profileUserID
        } else {
            let revision = loginSessionRevision
            guard let remoteProfile = try await loadVerifiedProfile(revision: revision) else {
                throw NeteaseAPIError.missingProfile
            }
            guard revision == loginSessionRevision, hasAuthCookie else { throw NeteaseAPIError.needLogin }
            profile = remoteProfile
            userID = remoteProfile.userId
        }

        let ids = try await NeteaseAPI.likedTrackIDs(uid: userID)
        var tracks: [Track] = []
        for offset in stride(from: 0, to: ids.count, by: 200) {
            let end = min(offset + 200, ids.count)
            let chunk = Array(ids[offset..<end])
            let response = try await NeteaseAPI.songDetails(ids: chunk)
            let tracksByID = Dictionary(response.songs.map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
            let resolved = chunk.compactMap { tracksByID[$0] }
            guard resolved.count == chunk.count else {
                throw NeteaseAPIError.incompleteSongData(
                    expected: ids.count,
                    received: tracks.count + resolved.count
                )
            }
            tracks.append(contentsOf: resolved)
        }
        let addedCount = LocalPlaylistStore.shared.mergeFavorites(tracks)
        return (remoteCount: ids.count, addedCount: addedCount)
    }

    func isLiked(_ trackID: Int) -> Bool {
        likedTrackIDs.contains(trackID)
    }

    func toggleLike(trackID: Int) async {
        guard isLoggedIn else {
            ToastCenter.shared.show("登录后即可收藏歌曲")
            return
        }
        let like = !likedTrackIDs.contains(trackID)
        if like { likedTrackIDs.insert(trackID) } else { likedTrackIDs.remove(trackID) }
        do {
            try await NeteaseAPI.likeTrack(id: trackID, like: like)
        } catch {
            if like { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
            ToastCenter.shared.show(error.localizedDescription)
        }
        NowPlayingManager.shared.refreshLikeState()
    }

    func logout() async {
        loginSessionRevision &+= 1
        loginBootstrapTask?.cancel()
        loginBootstrapTask = nil
        importedPlaylistSyncTask?.cancel()
        importedPlaylistSyncTask = nil
        isSyncingPlaylists = false
        lastPlaylistSyncAt = nil
        lastPlaylistSyncError = nil
#if os(iOS)
        forgetListeningAccount()
#endif
        profile = nil
        likedTrackIDs = []
        userPlaylists = []
        likedAlbums = []
        likedArtists = []
        isBootstrapped = true
        await NeteaseAPI.logout()
    }

    private func syncImportedPlaylistCopies(userID: Int, revision: Int) async {
        guard revision == loginSessionRevision, profile?.userId == userID else { return }
        let mirrored = LocalPlaylistStore.shared.playlists.filter {
            $0.remoteSource == "netease"
                && $0.remotePlaylistID != nil
                && LocalPlaylistSyncPolicy.isProviderRefreshEnabled($0)
                && LocalPlaylistSyncPolicy.shouldRefreshFromProvider($0)
        }
        guard !mirrored.isEmpty else { return }

        let candidates = mirrored.compactMap { local -> PlaylistSummary? in
            guard let rawID = local.remotePlaylistID, let id = Int(rawID) else { return nil }
            return userPlaylists.first { $0.id == id }
        }
        guard !candidates.isEmpty else { return }
        _ = await syncPlaylists(
            candidates,
            force: false,
            expectedUserID: userID,
            expectedSessionRevision: revision
        )
    }

    private func scheduleImportedPlaylistCopySync(userID: Int, revision: Int) {
        guard importedPlaylistSyncTask == nil else { return }
        importedPlaylistSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.syncImportedPlaylistCopies(userID: userID, revision: revision)
            self.importedPlaylistSyncTask = nil
        }
    }

    private func syncPlaylists(
        _ candidates: [PlaylistSummary],
        force: Bool,
        expectedUserID: Int? = nil,
        expectedSessionRevision: Int? = nil
    ) async -> PlaylistSyncReport {
        guard !candidates.isEmpty else {
            lastPlaylistSyncAt = .now
            return PlaylistSyncReport(inserted: 0, updated: 0, unchanged: 0, failed: [])
        }

        let revision = expectedSessionRevision ?? loginSessionRevision
        let userID = expectedUserID ?? profile?.userId
        guard revision == loginSessionRevision, let userID else {
            return PlaylistSyncReport(
                inserted: 0, updated: 0, unchanged: 0,
                failed: ["账号状态已变化，请重新登录后同步"]
            )
        }

        isSyncingPlaylists = true
        lastPlaylistSyncError = nil
        defer {
            isSyncingPlaylists = false
            if revision == loginSessionRevision { lastPlaylistSyncAt = .now }
        }

        var inserted = 0
        var updated = 0
        var unchanged = 0
        var failed: [String] = []

        for summary in candidates {
            guard !Task.isCancelled else { break }
            if revision != loginSessionRevision
                || !NeteaseClient.shared.isLoggedIn
                || profile?.userId != userID {
                failed.append("账号状态已变化，已停止歌单同步")
                break
            }
            let localCopy = LocalPlaylistStore.shared.playlists.first(where: {
                LocalPlaylistSyncPolicy.matchesProviderPlaylist(
                    $0,
                    source: "netease",
                    id: String(summary.id)
                )
            })
            if let localCopy, !LocalPlaylistSyncPolicy.shouldRefreshFromProvider(localCopy) {
                unchanged += 1
                continue
            }

            if !force,
               let local = localCopy,
               summary.updateTime > 0,
               local.remoteRevision == summary.updateTime {
                unchanged += 1
                continue
            }

            do {
                let tracks = try await allTracks(for: summary.id)
                guard !Task.isCancelled else { break }
                if revision != loginSessionRevision
                    || !NeteaseClient.shared.isLoggedIn
                    || profile?.userId != userID {
                    failed.append("账号状态已变化，未保存歌单副本")
                    break
                }
                let result = LocalPlaylistStore.shared.upsertRemotePlaylist(
                    source: "netease",
                    remoteID: summary.id,
                    name: summary.name,
                    coverURL: summary.coverURL,
                    sourceName: "网易云",
                    revision: summary.updateTime > 0 ? summary.updateTime : summary.trackCount,
                    tracks: tracks,
                    enableProviderRefresh: true
                )
                if result.inserted { inserted += 1 }
                else if result.changed { updated += 1 }
                else { unchanged += 1 }
            } catch {
                failed.append("\(summary.name)：\(error.localizedDescription)")
            }
        }

        if revision == loginSessionRevision, !failed.isEmpty {
            lastPlaylistSyncError = "部分歌单暂时无法同步"
        }
        return PlaylistSyncReport(
            inserted: inserted,
            updated: updated,
            unchanged: unchanged,
            failed: failed
        )
    }

    private func allTracks(for playlistID: Int) async throws -> [Track] {
        let response = try await NeteaseAPI.playlistDetail(id: playlistID)
        let complete = try await NeteaseAPI.completePlaylistTracks(from: response)
        return complete.tracks.map { $0.normalizedForLXPlayback() }
    }

    /// Refresh the login cookie at most once per calendar day.
    private func refreshCookieIfNeeded() {
        let key = "auth.lastCookieRefresh"
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: key) < today else { return }
        UserDefaults.standard.set(today, forKey: key)
        let revision = loginSessionRevision
        Task { [weak self] in
#if os(iOS)
            let before = NeteaseClient.shared.scopedCookies()
#endif
            await NeteaseAPI.refreshLogin()
#if os(iOS)
            guard let self, let before, revision == self.loginSessionRevision,
                  let after = NeteaseClient.shared.scopedCookies(), !after.hasSameToken(as: before) else { return }
            _ = try? await self.loadVerifiedProfile(revision: revision)
#endif
        }
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published var current: Toast?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ message: String) {
        current = Toast(message: message)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            current = nil
        }
    }
}
