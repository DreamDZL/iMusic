import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    /// Shared so the loaded page survives sidebar switches (no skeleton flash).
    static let shared = HomeViewModel()

    enum State {
        case idle, loading, loaded
        case error(String)
    }

    /// The personalized radar family — global playlist IDs whose content is
    /// generated per logged-in account (same list YesPlayMusic special-cases).
    static let radarPlaylistIDs = [
        3_136_952_023, // 私人雷达
        2_829_883_282, // 华语私人雷达
        2_829_816_518, // 欧美私人雷达
        2_829_896_389, // 日系私人雷达
    ]

    struct RadarPlaylist: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    @Published var state: State = .idle
    @Published var recommendPlaylists: [PlaylistSummary] = []
    @Published var radarPlaylists: [RadarPlaylist] = []
    @Published var toplists: [ToplistItem] = []
    @Published var newAlbums: [AlbumSummary] = []
    @Published var topArtists: [ArtistSummary] = []
    @Published var dailyFirstCover: String?
    @Published private(set) var activeMode: HomeRecommendationMode = .netease
    @Published private(set) var activePlatform: LXCatalogPlatform = .wy
    @Published var recommendTracks: [Track] = []
    @Published var lxRecommendPlaylists: [LXPlaylistSummary] = []
    private struct LoadRequest: Equatable {
        let loggedIn: Bool
        let mode: HomeRecommendationMode
        let platform: LXCatalogPlatform
        let qishuiSessionRevision: Int
    }

    private var activeRequest: LoadRequest?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var lastLoadedAt: Date?
    private static let didPerformInstallRefreshKey = "moumusic.home.didPerformInstallRefresh.v2"
    private let recommendationCache = HomeRecommendationCache.shared

    private func cacheKey(for request: LoadRequest) -> HomeRecommendationCache.Key {
        HomeRecommendationCache.Key(
            loggedIn: request.loggedIn,
            mode: request.mode.rawValue,
            platform: request.platform.rawValue,
            qishuiSessionRevision: request.qishuiSessionRevision
        )
    }

    private func resetContent() {
        recommendPlaylists = []
        radarPlaylists = []
        toplists = []
        newAlbums = []
        topArtists = []
        dailyFirstCover = nil
        recommendTracks = []
        lxRecommendPlaylists = []
    }

    private func apply(_ snapshot: HomeRecommendationCache.Snapshot) {
        recommendPlaylists = snapshot.recommendPlaylists
        radarPlaylists = snapshot.radarPlaylists
        toplists = snapshot.toplists
        newAlbums = snapshot.newAlbums
        topArtists = snapshot.topArtists
        dailyFirstCover = snapshot.dailyFirstCover
        recommendTracks = snapshot.recommendTracks
        lxRecommendPlaylists = snapshot.lxRecommendPlaylists
        state = snapshot.hasContent ? .loaded : .idle
    }

    private func saveSnapshot(at date: Date = Date()) {
        guard let activeRequest else { return }
        recommendationCache.save(
            HomeRecommendationCache.Snapshot(
                savedAt: date,
                recommendPlaylists: recommendPlaylists,
                radarPlaylists: radarPlaylists,
                toplists: toplists,
                newAlbums: newAlbums,
                topArtists: topArtists,
                dailyFirstCover: dailyFirstCover,
                recommendTracks: recommendTracks,
                lxRecommendPlaylists: lxRecommendPlaylists
            ),
            for: cacheKey(for: activeRequest)
        )
    }

    func load(loggedIn: Bool, mode: HomeRecommendationMode,
              platform: LXCatalogPlatform,
              qishuiSessionRevision: Int = 0) async {
        let request = LoadRequest(loggedIn: loggedIn, mode: mode, platform: platform,
                                  qishuiSessionRevision: qishuiSessionRevision)
        let requestKey = cacheKey(for: request)

        // Apply a source-specific snapshot before starting a request. This is
        // the stale-while-revalidate pattern used by Beans Music: fresh data
        // returns immediately; stale data remains visible while refreshing.
        if activeRequest != request {
            activeRequest = request
            if let snapshot = recommendationCache.snapshot(for: requestKey) {
                apply(snapshot)
                lastLoadedAt = snapshot.savedAt
            } else {
                resetContent()
                lastLoadedAt = nil
                state = .idle
            }
        }

        if activeRequest == request {
            switch state {
            case .loaded:
                if let lastLoadedAt,
                   Date().timeIntervalSince(lastLoadedAt) < recommendationCache.ttl {
                    return
                }
            case .loading, .error:
                // The actual request is owned by the model rather than by the
                // SwiftUI view task. This lets it survive the first TabView
                // transition, which can cancel and recreate HomeView.
                if let loadTask {
                    await loadTask.value
                    return
                }
            case .idle:
                break
            }
        }

        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        activeRequest = request

        // A clean install gets a small, bounded warm-up retry because the
        // source/catalogue bridge may still be starting. Persist the marker
        // only after a successful request so a cancelled/failed first launch
        // can recover on the next launch. The v2 key also gives users who
        // upgraded from the broken v1 warm-up one automatic retry.
        let needsInstallRefresh = !UserDefaults.standard.bool(forKey: Self.didPerformInstallRefreshKey)
        state = .loading
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(request, generation: generation,
                                   warmStart: needsInstallRefresh)
        }
        loadTask = task
        await task.value
    }

    private func performLoad(_ request: LoadRequest, generation: Int,
                             warmStart: Bool) async {
        let attempts = warmStart ? 4 : 1
        for attempt in 0..<attempts {
            guard generation == loadGeneration else { return }
            await loadOnce(loggedIn: request.loggedIn, mode: request.mode,
                           platform: request.platform, generation: generation)
            guard generation == loadGeneration else { return }
            if case .loaded = state {
                lastLoadedAt = Date()
                if warmStart {
                    UserDefaults.standard.set(true, forKey: Self.didPerformInstallRefreshKey)
                }
                loadTask = nil
                return
            }
            if attempt + 1 < attempts {
                do {
                    try await Task.sleep(for: .milliseconds(700 + attempt * 900))
                } catch {
                    return
                }
            }
        }
        if generation == loadGeneration {
            loadTask = nil
        }
    }

    private func loadOnce(loggedIn: Bool, mode: HomeRecommendationMode,
                          platform: LXCatalogPlatform, generation: Int) async {
        guard generation == loadGeneration else { return }
        activeMode = mode
        activePlatform = mode == .netease ? .wy : platform
        let hasExistingContent = !recommendTracks.isEmpty || !recommendPlaylists.isEmpty
            || !lxRecommendPlaylists.isEmpty || !toplists.isEmpty
            || !newAlbums.isEmpty || !topArtists.isEmpty
        if !hasExistingContent {
            state = .loading
        }

        if mode == .lx {
            // LX recommendations are catalogue-only. The selected source is
            // still the only component allowed to resolve audio on iOS.
            let content = await LXCatalogService.recommendedContent(platform: platform, limit: 30)
            guard generation == loadGeneration else { return }
            lxRecommendPlaylists = content.playlists
            var tracks = content.tracks

            // The WY catalogue has a reliable live song feed, while its
            // recommended playlist details can occasionally fail independently
            // of the playlist list request. Keep the homepage useful in that
            // case and normalize these tracks before they enter the queue so
            // playback still goes through the selected LX source.
            if platform == .wy {
                let liveTracks = (try? await NeteaseAPI.hotSongs(limit: 30))?
                    .map { $0.normalizedForLXPlayback() } ?? []
                if !liveTracks.isEmpty {
                    tracks = liveTracks
                }
            }
            recommendTracks = tracks
            saveSnapshot()
            state = recommendTracks.isEmpty && lxRecommendPlaylists.isEmpty
                ? .error("LX 暂无推荐结果，请检查网络或切换推荐平台")
                : .loaded
            return
        }

        // Public NetEase recommendations are restored as a catalogue family.
        // No account or NetEase audio URL is used here; queued tracks are
        // resolved by the selected LX User API in PlayerService.
        async let playlistsTask = fetchRecommendPlaylists(loggedIn: loggedIn)
        async let hotSongsTask = try? NeteaseAPI.hotSongs(limit: 30)
        async let toplistsTask = try? NeteaseAPI.toplists()
        async let albumsTask = try? NeteaseAPI.newAlbums(limit: 20)
        async let artistsTask = try? NeteaseAPI.topArtists()

        recommendPlaylists = await playlistsTask
        guard generation == loadGeneration else { return }
        let hotSongs = await hotSongsTask ?? []
        guard generation == loadGeneration else { return }
        // Never replace a live recommendation feed with a fixed keyword
        // search. An empty response is shown as an empty state and can be
        // retried with pull-to-refresh.
        recommendTracks = hotSongs.map { $0.normalizedForLXPlayback() }
        guard generation == loadGeneration else { return }
        toplists = Array((await toplistsTask ?? []).prefix(12))
        newAlbums = await albumsTask ?? []
        topArtists = Array((await artistsTask ?? []).prefix(12))
        guard generation == loadGeneration else { return }
        if loggedIn {
            if let daily = try? await NeteaseAPI.dailyRecommendSongs() {
                dailyFirstCover = daily.first?.album.picUrl
            }
            await loadRadarPlaylists()
        }
        saveSnapshot()
        state = recommendPlaylists.isEmpty && recommendTracks.isEmpty
            && newAlbums.isEmpty && toplists.isEmpty && topArtists.isEmpty
            ? .error("网易云推荐暂时不可用，请检查网络后重试")
            : .loaded
    }

    func reload(loggedIn: Bool, mode: HomeRecommendationMode,
                platform: LXCatalogPlatform,
                qishuiSessionRevision: Int = 0) async {
        if let activeRequest {
            recommendationCache.invalidate(cacheKey(for: activeRequest))
        }
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        activeRequest = nil
        resetContent()
        lastLoadedAt = nil
        state = .idle
        await load(loggedIn: loggedIn, mode: mode, platform: platform,
                   qishuiSessionRevision: qishuiSessionRevision)
    }

    private func loadRadarPlaylists() async {
        let briefs = await withTaskGroup(of: (Int, NeteaseAPI.PlaylistBrief.Body?).self) { group in
            for id in Self.radarPlaylistIDs {
                group.addTask {
                    (id, try? await NeteaseAPI.playlistBrief(id: id))
                }
            }
            var byID: [Int: NeteaseAPI.PlaylistBrief.Body] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return byID
        }
        radarPlaylists = Self.radarPlaylistIDs.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            // Names arrive as "今天从《…》听起|私人雷达" — split into title/subtitle.
            let parts = (brief.name ?? "").components(separatedBy: "|")
            let title = parts.count > 1 ? parts.last! : (brief.name ?? String(localized: "雷达歌单"))
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return RadarPlaylist(id: id, title: title, subtitle: subtitle, coverURL: brief.coverImgUrl)
        }
    }

    private func fetchRecommendPlaylists(loggedIn: Bool) async -> [PlaylistSummary] {
        if loggedIn {
            async let recommend = try? NeteaseAPI.recommendResource()
            async let personalized = try? NeteaseAPI.personalizedPlaylists(limit: 30)
            let head = await recommend ?? []
            let tail = await personalized ?? []
            var seen = Set<Int>()
            return (head + tail).filter { seen.insert($0.id).inserted }
        }
        return (try? await NeteaseAPI.personalizedPlaylists(limit: 30)) ?? []
    }
}

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @StateObject private var model = HomeViewModel.shared
    @ObservedObject private var localLibrary = LocalPlaylistStore.shared
    /// Measured page width, used to size the portrait feature cards.
    @State private var shelfWidth: CGFloat = 390

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                featureCards
                if !localLibrary.recentTracks.isEmpty {
                    recentTracksShelf
                }
                standardHomeBody
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            shelfWidth = width
        }
        .navigationTitle("主页")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(homePlatforms) { platform in
                        Button {
                            selectHomePlatform(platform)
                        } label: {
                            if isHomePlatform(platform) {
                                Label(platform.displayName, systemImage: "checkmark")
                            } else {
                                Text(platform.displayName)
                            }
                        }
                    }
                } label: {
                    // Bare glyph: the toolbar's glass capsule already draws
                    // the circle, and `.circle` symbols doubled it.
                    Label(homeSourceTitle, systemImage: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("首页推荐来源：\(homeSourceTitle)")
                .accessibilityHint("更改首页为你推荐的音乐平台")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Destination.recents) {
                    Image(systemName: "clock")
                }
                .accessibilityLabel("最近播放")
                .accessibilityHint("打开最近播放的歌曲列表")
            }
        }
        // Toolbar glyphs use the label colour like the system apps; the
        // accent stays for selection and primary actions.
        .tint(.primary)
        #endif
        .task(id: homeTaskID) {
            guard !IOSUITestMode.isEnabled else { return }
            await loadCurrentHome()
        }
        .onAppear {
            guard !IOSUITestMode.isEnabled else { return }
            // The shared model keeps scroll state between tabs, but the feed
            // itself must be refreshed after its short cache expires.
            Task {
                await loadCurrentHome()
            }
        }
        .refreshable {
            guard !IOSUITestMode.isEnabled else { return }
            await loadCurrentHome(force: true)
        }
    }

    private var recentTracksShelf: some View {
        Shelf(title: "最近播放", rowHeight: Theme.Layout.coverShelfHeight) {
            ForEach(Array(localLibrary.recentTracks.prefix(12)), id: \.playbackKey) { track in
                Button {
                    player.play(
                        tracks: localLibrary.recentTracks,
                        source: .none,
                        startAt: track
                    )
                } label: {
                    // Same artwork size, radius and type as every other cover
                    // shelf, instead of a one-off 16pt-radius card.
                    VStack(alignment: .leading, spacing: 6) {
                        CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(320), animated: false)
                            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                            .background(.quaternary.opacity(0.45))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                            )
                        Text(track.name)
                            .font(Theme.Typography.cardTitle)
                            .lineLimit(1)
                        Text(track.artistNames)
                            .font(Theme.Typography.cardSubtitle)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: Theme.Layout.cardSize, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放最近听过的歌曲：\(track.name)，\(track.artistNames)")
            }
        }
    }

    private var homeTaskID: String {
        return "music-\(account.isLoggedIn)-\(settings.homeRecommendationMode.rawValue)-\(settings.homeRecommendationPlatform.rawValue)"
    }

    @ViewBuilder
    private var standardHomeBody: some View {
        switch model.state {
        case .idle, .loading:
            EmptyView()
        case .error(let message):
            ErrorStateView(message: message) {
                Task { await loadCurrentHome(force: true) }
            }
            .frame(minHeight: 400)
        case .loaded:
            if model.activeMode == .lx {
                lxLoadedBody
            } else {
                loadedBody
            }
        }
    }

    @MainActor
    private func loadCurrentHome(force: Bool = false) async {
        if force {
            await model.reload(loggedIn: account.isLoggedIn,
                               mode: settings.homeRecommendationMode,
                               platform: settings.homeRecommendationPlatform,
                               qishuiSessionRevision: 0)
        } else {
            await model.load(loggedIn: account.isLoggedIn,
                             mode: settings.homeRecommendationMode,
                             platform: settings.homeRecommendationPlatform,
                             qishuiSessionRevision: 0)
        }
    }

    private var lxLoadedBody: some View {
        // The active platform is shown by the toolbar filter, so the feed
        // does not repeat it as an extra coloured heading row.
        LazyVStack(alignment: .leading, spacing: 30) {
            if !model.lxRecommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.lxRecommendPlaylists.prefix(12)) { playlist in
                        lxPlaylistCard(playlist)
                    }
                }
            }

            if !model.recommendTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: model.activePlatform == .wy ? "热门歌曲" : "推荐歌曲")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: model.recommendTracks, showsSummary: false)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            PlayerClearanceSpacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homePlatforms: [LXCatalogPlatform] {
        LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }
    }

    private var homeSourceTitle: String {
        settings.homeRecommendationMode == .netease
            ? "网易云"
            : settings.homeRecommendationPlatform.displayName
    }

    private func isHomePlatform(_ platform: LXCatalogPlatform) -> Bool {
        if platform == .wy { return settings.homeRecommendationMode == .netease }
        return settings.homeRecommendationMode == .lx
            && settings.homeRecommendationPlatform == platform
    }

    private func selectHomePlatform(_ platform: LXCatalogPlatform) {
        settings.homeRecommendationPlatform = platform
        settings.homeRecommendationMode = platform == .wy ? .netease : .lx
    }

    private func lxPlaylistCard(_ playlist: LXPlaylistSummary) -> some View {
        NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: [playlist.source.displayName, playlist.author].compactMap { $0 }.joined(separator: " · "),
                playCount: playlist.playCount
            )
        }
        .buttonStyle(.plain)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            if !model.recommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.recommendPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        playlistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-rec-\(playlist.id)")
                    }
                }
            }

            if !model.recommendTracks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "热门歌曲")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: model.recommendTracks, showsSummary: false)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }

            if !model.radarPlaylists.isEmpty {
                Shelf(title: "雷达歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.radarPlaylists) { radar in
                        NavigationLink(value: Destination.playlist(radar.id)) {
                            CoverCardBody(
                                coverURL: radar.coverURL?.resizedImageURL(384),
                                title: radar.title,
                                subtitle: radar.subtitle
                            ) {
                                playPlaylist(radar.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.toplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.toplists) { toplist in
                        NavigationLink(value: Destination.playlist(toplist.id)) {
                            toplistCard(toplist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.newAlbums.isEmpty {
                Shelf(title: "新碟上架", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.newAlbums) { album in
                        albumCard(album)
                    }
                }
            }

            if !model.topArtists.isEmpty {
                Shelf(title: "推荐歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(model.topArtists) { artist in
                        artistCard(artist)
                    }
                }
            }

            PlayerClearanceSpacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feature cards

    /// Portrait "Top Picks" cards: about 62% of the page width so the next
    /// card peeks in, 3:4 ratio, eyebrow label above each card.
    private var featureCardSize: CGSize {
        let width = min(260, max(200, (shelfWidth - Theme.Layout.contentInset * 2) * 0.66))
        return CGSize(width: width, height: (width * 4 / 3).rounded())
    }

    private var featureCards: some View {
        let size = featureCardSize
        return VStack(alignment: .leading, spacing: 10) {
            Text("为你精选")
                .font(.title2.weight(.bold))
                .padding(.horizontal, Theme.Layout.contentInset)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    // Daily recommendations are always visible; the page shows
                    // a separate login CTA when account sync is unavailable.
                    NavigationLink(value: Destination.daily) {
                        FeatureCard(
                            eyebrow: String(localized: "为你推荐"),
                            title: String(localized: "每日推荐"),
                            subtitle: String(localized: "根据你的口味每日更新"),
                            icon: "calendar",
                            coverURL: model.dailyFirstCover?.resizedImageURL(600),
                            showsDate: true,
                            size: size
                        )
                    }
                    .buttonStyle(.interactiveCard)

                    Button {
                        player.startFM()
                    } label: {
                        FeatureCard(
                            eyebrow: String(localized: "电台"),
                            title: String(localized: "电台推荐"),
                            subtitle: String(localized: "按首页平台连续播放推荐"),
                            icon: "dot.radiowaves.left.and.right",
                            coverURL: (player.isFMMode ? player.currentTrack : nil)?
                                .album.picUrl?.resizedImageURL(600),
                            gradient: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                       Color(red: 0.36, green: 0.24, blue: 0.62)],
                            size: size
                        )
                    }
                    .buttonStyle(.interactiveCard)

                    if account.isLoggedIn {
                        Button {
                            startHeartbeatMode()
                        } label: {
                            FeatureCard(
                                eyebrow: String(localized: "根据收藏"),
                                title: String(localized: "心动模式"),
                                subtitle: String(localized: "你的收藏和相似推荐"),
                                icon: "heart.fill",
                                coverURL: localLibrary.favoriteTracks.first?
                                    .album.picUrl?.resizedImageURL(600),
                                gradient: [Color(red: 0.85, green: 0.19, blue: 0.41),
                                           Color(red: 0.98, green: 0.42, blue: 0.34)],
                                size: size
                            )
                        }
                        .buttonStyle(.interactiveCard)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, Theme.Layout.contentInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .frame(height: size.height + FeatureCard.eyebrowHeight)
        }
        .compatScrollClipDisabled()
    }

    private func startHeartbeatMode() {
        guard let likedList = account.likedSongsPlaylist else { return }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(likedList.id),
                            context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Cards

    private func playlistCard(_ playlist: PlaylistSummary) -> some View {
        NavigationLink(value: Destination.playlist(playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: playlist.copywriter,
                playCount: playlist.playCount
            ) {
                playPlaylist(playlist.id)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: AlbumSummary) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName
            ) {
                Task {
                    if let detail = try? await NeteaseAPI.album(id: album.id) {
                        player.play(tracks: detail.songs, source: .album(album.id),
                                    context: .album(id: album.id, name: album.name))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(value: Destination.artist(artist.id)) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func toplistCard(_ toplist: ToplistItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(384))
                    .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                Text(toplist.updateFrequency ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(8)
            }
            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
            Text(toplist.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Theme.Layout.cardSize, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func playPlaylist(_ id: Int) {
        Task {
            do {
                let detail = try await NeteaseAPI.playlistDetail(id: id)
                let complete = try await NeteaseAPI.completePlaylistTracks(from: detail)
                guard !complete.tracks.isEmpty else {
                    ToastCenter.shared.show("歌单没有可播放的歌曲")
                    return
                }
                player.play(tracks: complete.tracks, source: .playlist(id),
                            context: .playlist(id: id, name: detail.playlist.name))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }
}

// MARK: - Feature card

/// Portrait recommendation card in the style of the system "Top Picks"
/// shelf: an eyebrow label above, artwork filling the card, and a soft
/// gradient band carrying the title. Without artwork it falls back to a
/// tinted gradient with one large symbol, never an empty block.
struct FeatureCard: View {
    static let eyebrowHeight: CGFloat = 24

    var eyebrow: String = ""
    let title: String
    let subtitle: String
    let icon: String
    var coverURL: URL?
    var gradient: [Color] = [Color(red: 0.75, green: 0.16, blue: 0.22),
                             Color(red: 0.95, green: 0.35, blue: 0.28)]
    var showsDate = false
    var size = CGSize(width: 230, height: 306)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(eyebrow)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(height: Self.eyebrowHeight, alignment: .top)

            ZStack(alignment: .bottomLeading) {
                background
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.62), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
        .frame(width: size.width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var background: some View {
        if let coverURL {
            CachedAsyncImage(url: coverURL)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: size.width * 0.3, weight: .regular))
                    if showsDate {
                        Text("\(Calendar.current.component(.day, from: .now))")
                            .font(.system(size: size.width * 0.12, weight: .bold))
                            .offset(y: size.width * 0.04)
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .offset(y: -size.height * 0.1)
            }
            .accessibilityHidden(true)
        }
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var onPlay: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.flexibleCardWidth) private var flexibleWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                artwork
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    )
                if playCount > 0 {
                    PlayCountBadge(count: playCount)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if let onPlay {
                    PlayOverlayButton(visible: isHovering, action: onPlay)
                        .padding(8)
                }
            }

            // Semantic type (Dynamic Type) instead of fixed 13/11pt.
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            }
        }
        .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        if flexibleWidth {
            CachedAsyncImage(url: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            CachedAsyncImage(url: coverURL)
                .frame(width: size, height: size)
        }
    }
}
