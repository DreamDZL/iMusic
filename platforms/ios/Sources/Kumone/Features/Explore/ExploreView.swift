import SwiftUI

@MainActor
final class ExploreViewModel: ObservableObject {
    static let shared = ExploreViewModel()

    static let categories = [
        "推荐", "最热", "最新", "华语", "流行", "摇滚", "民谣", "电子",
        "轻音乐", "说唱", "古典", "影视原声", "ACG", "古风", "怀旧", "治愈",
    ]

    @Published var platform: LXCatalogPlatform = .kw
    @Published var selectedCategory = "推荐"
    @Published var playlists: [LXPlaylistSummary] = []
    @Published var tracks: [Track] = []
    @Published var newSongs: [Track] = []
    @Published var newAlbums: [AlbumSummary] = []
    @Published var toplists: [ToplistItem] = []
    @Published var isLoading = false
    @Published var hasMore = true
    @Published var errorMessage: String?

    private var page = 1
    private var loadTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var lastLoadedAt: Date?

    func prepare(platform: LXCatalogPlatform) {
        guard platform != self.platform else { return }
        self.platform = platform
        resetContent()
    }

    func selectPlatform(_ platform: LXCatalogPlatform) {
        guard platform != self.platform else { return }
        prepare(platform: platform)
        requestMore()
    }

    func select(_ category: String) {
        guard category != selectedCategory else { return }
        selectedCategory = category
        resetContent()
        requestMore()
    }

    /// Re-entering New refreshes stale catalog content after ten minutes.
    /// Pull-to-refresh bypasses this window.
    func refreshCurrent(force: Bool = false) async {
        if !force, let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < 10 * 60 {
            return
        }
        resetContent()
        requestMore()
        guard let loadTask else { return }
        await loadTask.value
    }

    func refreshIfStale() {
        guard lastLoadedAt.map({ Date().timeIntervalSince($0) >= 10 * 60 }) ?? false else { return }
        resetContent()
        requestMore()
    }

    func requestMore() {
        guard !isLoading, hasMore, loadTask == nil else { return }
        let generation = requestGeneration
        loadTask = Task {
            await loadMore()
            if generation == requestGeneration { loadTask = nil }
        }
    }

    func cancelLoading() {
        guard loadTask != nil else { return }
        requestGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func resetContent() {
        requestGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        playlists = []
        tracks = []
        newSongs = []
        newAlbums = []
        toplists = []
        page = 1
        hasMore = true
        errorMessage = nil
        lastLoadedAt = nil
    }

    private func loadMore() async {
        let generation = requestGeneration
        guard !Task.isCancelled, generation == requestGeneration, !isLoading, hasMore else { return }
        isLoading = true
        defer {
            if generation == requestGeneration { isLoading = false }
        }

        do {
            let result: [LXPlaylistSummary]
            var fetchedTracks: [Track]?
            var fetchedNewSongs: [Track] = []
            var fetchedNewAlbums: [AlbumSummary] = []
            var fetchedToplists: [ToplistItem] = []
            if selectedCategory == "推荐" && page == 1 {
                let content = await LXCatalogService.recommendedContent(platform: platform, limit: 30)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                result = content.playlists
                fetchedTracks = content.tracks
                if platform == .wy {
                    async let charts = NeteaseAPI.toplists()
                    async let releases = NeteaseAPI.personalizedNewSongs(limit: 24)
                    async let albums = NeteaseAPI.newAlbums(limit: 24)
                    fetchedToplists = Array(((try? await charts) ?? []).prefix(10))
                    fetchedNewSongs = ((try? await releases) ?? []).map { $0.normalizedForLXPlayback() }
                    fetchedNewAlbums = (try? await albums) ?? []
                    try Task.checkCancellation()
                    guard generation == requestGeneration else { return }
                }
            } else if (selectedCategory == "最热" || selectedCategory == "最新") && platform != .wy {
                result = try await LXCatalogService.sortedSonglists(platform: platform,
                                                                     category: selectedCategory,
                                                                     page: page, limit: 30)
            } else {
                let keyword: String
                switch selectedCategory {
                case "最热": keyword = "热门"
                case "最新": keyword = "最新"
                default: keyword = selectedCategory
                }
                result = try await LXCatalogService.searchSonglists(keyword, platform: platform,
                                                                     page: page, limit: 30)
            }

            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            if let fetchedTracks { tracks = fetchedTracks }
            if selectedCategory == "推荐", page == 1 {
                toplists = fetchedToplists
                newSongs = fetchedNewSongs
                newAlbums = fetchedNewAlbums
            }
            var seen = Set(playlists.map { "\($0.source.rawValue)|\($0.id)" })
            playlists += result.filter { seen.insert("\($0.source.rawValue)|\($0.id)").inserted }
            page += 1
            hasMore = selectedCategory != "推荐" && result.count >= 30 && page <= 6
            errorMessage = playlists.isEmpty && tracks.isEmpty && newSongs.isEmpty
                && newAlbums.isEmpty && toplists.isEmpty
                ? "当前平台暂时没有可用内容，请切换平台或稍后重试"
                : nil
            lastLoadedAt = .now
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = playlists.isEmpty ? error.localizedDescription : nil
            hasMore = false
        }
    }
}

struct ExploreView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @EnvironmentObject private var bilibili: BilibiliSessionStore
    @State private var showBilibili = false
#endif

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.selectedCategory == "推荐",
                   let featured = model.playlists.first {
                    featuredPlaylistCard(featured)
                }

                if model.platform == .wy && !model.newSongs.isEmpty {
                    SectionHeader(title: "网易云新歌推荐")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: model.newSongs)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }

                if model.platform == .wy && !model.newAlbums.isEmpty {
                    Shelf(title: "网易云新碟", rowHeight: Theme.Layout.coverShelfHeight) {
                        ForEach(model.newAlbums) { album in
                            newAlbumCard(album)
                        }
                    }
                }

                genreBrowser

                if model.isLoading && model.playlists.isEmpty && model.tracks.isEmpty
                    && model.newSongs.isEmpty && model.newAlbums.isEmpty && model.toplists.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if let errorMessage = model.errorMessage,
                          model.playlists.isEmpty && model.tracks.isEmpty
                            && model.newSongs.isEmpty && model.newAlbums.isEmpty && model.toplists.isEmpty {
                    ErrorStateView(message: errorMessage) {
                        Task { await model.refreshCurrent(force: true) }
                    }
                    .frame(minHeight: 300)
                } else {
                    if model.platform == .wy && !model.toplists.isEmpty {
                        SectionHeader(title: "网易云排行榜")
                            .padding(.horizontal, Theme.Layout.contentInset)
                        ToplistGrid(toplists: model.toplists)
                            .padding(.horizontal, Theme.Layout.contentInset)
                    }

                    if !model.tracks.isEmpty {
                        SectionHeader(title: "\(model.platform.displayName) 精选歌曲")
                            .padding(.horizontal, Theme.Layout.contentInset)
                        TrackListView(tracks: model.tracks)
                            .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }

                    if !visiblePlaylists.isEmpty {
                        CardGrid {
                            ForEach(Array(visiblePlaylists.enumerated()), id: \.element.id) { index, playlist in
                                NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
                                    CoverCardBody(
                                        coverURL: playlist.coverURL?.resizedImageURL(384),
                                        title: playlist.name,
                                        subtitle: [playlist.source.displayName, playlist.author]
                                            .compactMap { $0 }.joined(separator: " · "),
                                        playCount: playlist.playCount
                                    )
                                }
                                .buttonStyle(.plain)
                                .staggeredAppearance(index: index % 10, id: "explore-\(playlist.source.rawValue)-\(playlist.id)")
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                    }

                    if model.isLoading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if model.hasMore {
                        Color.clear
                            .frame(height: 1)
                            .onAppear { model.requestMore() }
                    }
                }

                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("新内容")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                discoveryMenu
            }
        }
        .task(id: "\(settings.homeRecommendationMode.rawValue)-\(settings.homeRecommendationPlatform.rawValue)") {
            model.prepare(platform: settings.homeRecommendationPlatform)
            model.requestMore()
        }
        .onAppear {
            model.refreshIfStale()
        }
        .onDisappear {
            model.cancelLoading()
        }
        .refreshable {
            await model.refreshCurrent(force: true)
        }
#if os(iOS)
        .fullScreenCover(isPresented: $showBilibili) {
            NavigationStack {
                BilibiliContentView()
                    .environmentObject(bilibili)
            }
        }
#endif
    }

    private var discoveryMenu: some View {
        Menu {
            Section("音乐平台") {
                ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }) { platform in
                    Button {
                        model.selectPlatform(platform)
                    } label: {
                        if model.platform == platform {
                            Label(platform.displayName, systemImage: "checkmark")
                        } else {
                            Text(platform.displayName)
                        }
                    }
                }
            }

            Section("音乐类型") {
                ForEach(ExploreViewModel.categories, id: \.self) { category in
                    Button {
                        model.select(category)
                    } label: {
                        if model.selectedCategory == category {
                            Label(category, systemImage: "checkmark")
                        } else {
                            Text(category)
                        }
                    }
                }
            }
#if os(iOS)
            if settings.bilibiliContentEnabled {
                Button {
                    showBilibili = true
                } label: {
                    Label("哔哩哔哩", systemImage: "play.rectangle.fill")
                }
            }
#endif
        } label: {
            Label(
                discoveryFilterTitle,
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityLabel("筛选新内容：\(model.platform.displayName)、\(model.selectedCategory)")
    }

    private var discoveryFilterTitle: String {
        model.selectedCategory == "推荐"
            ? model.platform.displayName
            : "\(model.platform.displayName) · \(model.selectedCategory)"
    }

    private var visiblePlaylists: [LXPlaylistSummary] {
        model.selectedCategory == "推荐" ? Array(model.playlists.dropFirst()) : model.playlists
    }

    private func newAlbumCard(_ album: AlbumSummary) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName
            )
        }
        .buttonStyle(.plain)
    }

    private func featuredPlaylistCard(_ playlist: LXPlaylistSummary) -> some View {
        NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(900), animated: false)
                    .frame(maxWidth: .infinity)
                    .frame(height: featuredCardHeight)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.18), .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("为你发现")
                            .font(.caption.weight(.bold))
                            .tracking(1.2)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text(playlist.name)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text([playlist.source.displayName, playlist.author].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .padding(20)
            }
            .frame(height: featuredCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开推荐歌单：\(playlist.name)")
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var featuredCardHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 460 : 330
    }

    private var genreBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "按类型浏览")
                .padding(.horizontal, Theme.Layout.contentInset)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(Array(ExploreViewModel.categories.enumerated()), id: \.element) { index, category in
                    Button {
                        model.select(category)
                    } label: {
                        HStack(spacing: 10) {
                            Text(category)
                                .font(.headline.weight(.semibold))
                            Spacer(minLength: 0)
                            Image(systemName: model.selectedCategory == category ? "checkmark" : "arrow.up.right")
                                .font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 15)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
                        .background(genreColor(index), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("浏览\(category)音乐")
                    .accessibilityAddTraits(model.selectedCategory == category ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func genreColor(_ index: Int) -> Color {
        return switch index % 8 {
        case 0: Color(red: 0.55, green: 0.20, blue: 0.38)
        case 1: Color(red: 0.29, green: 0.34, blue: 0.63)
        case 2: Color(red: 0.13, green: 0.47, blue: 0.50)
        case 3: Color(red: 0.62, green: 0.34, blue: 0.17)
        case 4: Color(red: 0.40, green: 0.28, blue: 0.59)
        case 5: Color(red: 0.20, green: 0.45, blue: 0.34)
        case 6: Color(red: 0.61, green: 0.25, blue: 0.24)
        default: Color(red: 0.29, green: 0.39, blue: 0.51)
        }
    }
}

// MARK: - NetEase ranking page kept for the account/sidebar entry point.

struct ToplistGrid: View {
    let toplists: [ToplistItem]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20)],
            alignment: .leading, spacing: 20
        ) {
            ForEach(toplists) { toplist in
                NavigationLink(value: Destination.playlist(toplist.id)) {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: toplist.coverImgUrl?.resizedImageURL(256))
                            .frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(toplist.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(toplist.updateFrequency ?? "")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(toplist.tracks.prefix(3).enumerated()), id: \.offset) { i, preview in
                                    Text("\(i + 1). \(preview.first) - \(preview.second)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ToplistsView: View {
    @State private var toplists: [ToplistItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ToplistGrid(toplists: toplists)
                    .padding(Theme.Layout.contentInset)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("排行榜")
        .task {
            if toplists.isEmpty {
                toplists = (try? await NeteaseAPI.toplists()) ?? []
            }
        }
    }
}
