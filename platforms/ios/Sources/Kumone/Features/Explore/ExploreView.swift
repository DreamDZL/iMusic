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
        guard !IOSUITestMode.isEnabled else { return }
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
    @StateObject private var model = ExploreViewModel.shared
    @EnvironmentObject private var settings: SettingsManager
    /// Measured page width for the featured carousel cards.
    @State private var exploreWidth: CGFloat = 390
    @State private var showsAllGenres = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !featuredPlaylists.isEmpty {
                    featuredCarousel(featuredPlaylists)
                }

                if model.platform == .wy && !model.newSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "新歌推荐")
                            .padding(.horizontal, Theme.Layout.contentInset)
                        TrackListView(tracks: Array(model.newSongs.prefix(8)), showsSummary: false)
                            .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }
                }

                if model.platform == .wy && !model.newAlbums.isEmpty {
                    Shelf(title: "新碟上架", rowHeight: Theme.Layout.coverShelfHeight) {
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
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "排行榜")
                                .padding(.horizontal, Theme.Layout.contentInset)
                            ToplistGrid(toplists: model.toplists)
                                .padding(.horizontal, Theme.Layout.contentInset)
                        }
                    }

                    if !model.tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: "精选歌曲", subtitle: model.platform.displayName)
                                .padding(.horizontal, Theme.Layout.contentInset)
                            TrackListView(tracks: model.tracks, showsSummary: false)
                                .padding(.horizontal, Theme.Layout.contentInset - 10)
                        }
                    }

                    if !visiblePlaylists.isEmpty {
                        SectionHeader(title: model.selectedCategory == "推荐" ? "更多歌单" : "\(model.selectedCategory)歌单")
                            .padding(.horizontal, Theme.Layout.contentInset)
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
        .accessibilityIdentifier("exploreContentScrollView")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            exploreWidth = width
        }
        .navigationTitle("新发现")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                discoveryMenu
            }
        }
        .tint(.primary)
        .task(id: "\(settings.homeRecommendationMode.rawValue)-\(settings.homeRecommendationPlatform.rawValue)") {
            model.prepare(platform: settings.homeRecommendationPlatform)
            guard !IOSUITestMode.isEnabled else { return }
            model.requestMore()
        }
        .onAppear {
            guard !IOSUITestMode.isEnabled else { return }
            model.refreshIfStale()
        }
        .onDisappear {
            model.cancelLoading()
        }
        .refreshable {
            guard !IOSUITestMode.isEnabled else { return }
            await model.refreshCurrent(force: true)
        }
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
        } label: {
            Label(
                discoveryFilterTitle,
                systemImage: "line.3.horizontal.decrease"
            )
        }
        .accessibilityLabel("筛选新发现：\(model.platform.displayName)、\(model.selectedCategory)")
    }

    private var discoveryFilterTitle: String {
        model.selectedCategory == "推荐"
            ? model.platform.displayName
            : "\(model.platform.displayName) · \(model.selectedCategory)"
    }

    private static let featuredCount = 5

    private var featuredPlaylists: [LXPlaylistSummary] {
        model.selectedCategory == "推荐" ? Array(model.playlists.prefix(Self.featuredCount)) : []
    }

    /// The grid below never repeats a playlist already shown in the
    /// featured carousel.
    private var visiblePlaylists: [LXPlaylistSummary] {
        model.selectedCategory == "推荐"
            ? Array(model.playlists.dropFirst(Self.featuredCount))
            : model.playlists
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

    /// Featured playlists at the top of New, as a horizontally paged shelf
    /// in the style of the system "New" tab: eyebrow, title and subtitle
    /// above a wide artwork card. The next card peeks in to signal swiping.
    private func featuredCarousel(_ playlists: [LXPlaylistSummary]) -> some View {
        let cardWidth = max(240, (exploreWidth - Theme.Layout.contentInset * 2) * 0.92)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(playlists) { playlist in
                    featuredPlaylistCard(playlist, width: cardWidth)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, Theme.Layout.contentInset, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .compatScrollClipDisabled()
    }

    private func featuredPlaylistCard(_ playlist: LXPlaylistSummary, width: CGFloat) -> some View {
        NavigationLink(value: Destination.lxPlaylist(source: playlist.source, id: playlist.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text("为你发现")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(playlist.name)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text([playlist.source.displayName, playlist.author].compactMap { $0 }.joined(separator: " · "))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 8)
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(900), animated: false)
                    .frame(width: width, height: (width * 0.66).rounded())
                    .background(.quaternary.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.interactiveCard)
        .accessibilityLabel("打开推荐歌单：\(playlist.name)")
    }

    /// Category tiles in the system "Browse Categories" style: solid colour,
    /// title at the bottom-left, no decorative glyphs. Eight are shown by
    /// default so the grid does not dominate the page.
    private var genreBrowser: some View {
        let visible = showsAllGenres
            ? ExploreViewModel.categories
            : Array(ExploreViewModel.categories.prefix(8))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "按类型浏览")
                if ExploreViewModel.categories.count > 8 {
                    Button(showsAllGenres ? "收起" : "全部") {
                        withAnimation(AppAnimation.standard) { showsAllGenres.toggle() }
                    }
                    .font(.body)
                    .tint(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(Array(visible.enumerated()), id: \.element) { index, category in
                    let isSelected = model.selectedCategory == category
                    Button {
                        model.select(category)
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            genreColor(index)
                            Text(category)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(12)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(genreColor(index), .white)
                                    .padding(10)
                            }
                        }
                    }
                    .buttonStyle(.interactiveCard)
                    .accessibilityLabel("浏览\(category)音乐")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
