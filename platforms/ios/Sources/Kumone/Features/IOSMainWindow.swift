import SwiftUI

#if os(iOS)
public struct IOSMainWindow: View {
    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var qqMusic = QQMusicSessionStore.shared
    @StateObject private var kugou = KugouSessionStore.shared
    @StateObject private var toasts = ToastCenter.shared
    @StateObject private var updater = IOSUpdater.shared
    @StateObject private var updateLog = IOSUpdateLogStore.shared
    private let startup = IOSStartupCoordinator.shared
    @Namespace private var nowPlayingTransition
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The app's intended scheme, read on this ancestor so the search-active
    /// tab environment can't invert it (#31).
    private var resolvedColorScheme: ColorScheme {
        settings.appearance.colorScheme ?? systemColorScheme
    }

    @State private var selectedTab: IOSTab = .home
    @State private var homePath = NavigationPath()
    @State private var newPath = NavigationPath()
    @State private var radioPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @StateObject private var router = AppRouter.shared

    public init() {}

    public var body: some View {
        presentationRoot
            .environmentObject(player)
            .environmentObject(account)
            .environmentObject(settings)
            .environmentObject(qqMusic)
            .environmentObject(kugou)
            .environmentObject(toasts)
            .tint(Theme.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
            .animation(reduceMotion ? nil : AppAnimation.smooth, value: settings.appearance)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            // Login is exposed on a separate account page. It is metadata
            // synchronisation only; audio URLs still come exclusively from LX.
            .environment(\.openLogin, {
                selectedTab = .library
                libraryPath = NavigationPath()
                libraryPath.append(Destination.accountSync)
            })
            .task {
                RenderingBudget.shared.setSceneActive(scenePhase == .active)
                player.setSceneActive(scenePhase == .active)
                startup.start(
                    player: player,
                    account: account
                )
                if IOSUITestMode.hasPlayerFixture {
                    player.installUITestFixture()
                }
                if IOSUITestMode.autoOpensPlayer {
                    try? await Task.sleep(for: .seconds(6))
                    player.showNowPlaying = true
                }
                if !IOSUITestMode.isEnabled {
                    await LXSyncService.shared.reconnectIfConfigured()
                    updateLog.presentIfNeeded()
                    if settings.autoCheckUpdates {
                        IOSUpdater.shared.check(interactive: false)
                    }
                }
            }
            .onChange(of: scenePhase) { phase in
                RenderingBudget.shared.setSceneActive(phase == .active)
                player.setSceneActive(phase == .active)
                guard phase == .active else { return }
                guard !IOSUITestMode.isEnabled else { return }
                Task { @MainActor in
                    await account.refreshForOpen()
                    await MusicSessionRefreshCoordinator.shared.refreshIfNeeded()
                    await LXSyncService.shared.reconnectIfConfigured()
                }
            }
            .onChange(of: router.pending) { _, request in
                guard let request else { return }
                router.consume(request)
                // Push under the player first, then close it, so the page is
                // already in place when the cover slides away.
                appendToSelectedTab(request.destination)
                player.showNowPlaying = false
            }
            .onOpenURL { url in
                guard ["imusic", "moumusic"].contains(url.scheme?.lowercased() ?? "") else { return }
                player.showNowPlaying = true
            }
            .sheet(isPresented: $updater.showSheet) {
                IOSUpdaterSheet()
            }
            .sheet(isPresented: $updateLog.isPresented) {
                IOSUpdateLogSheet()
            }
            .overlay(alignment: .top) {
                if let toast = toasts.current {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                }
            }
            .animation(.spring(duration: 0.3), value: toasts.current)
    }

    @ViewBuilder
    private var presentationRoot: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            if #available(iOS 18.0, *) {
                zoomNowPlayingRoot
            } else {
                legacyPresentationRoot
            }
        } else {
            systemNowPlayingRoot
        }
    }

    private var systemNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: $player.showNowPlaying) {
                systemNowPlayingPresentation(zooms: false)
            }
    }

    @available(iOS 18.0, *)
    private var zoomNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: $player.showNowPlaying) {
                systemNowPlayingPresentation(zooms: true)
                    .navigationTransition(
                        .zoom(sourceID: NowPlayingTransitionID.surface, in: nowPlayingTransition)
                    )
            }
    }

    @ViewBuilder
    private func systemNowPlayingPresentation(zooms: Bool) -> some View {
        if #available(iOS 16.4, *) {
            nowPlayingPresentation(
                usesSystemInteractiveDismissal: zooms,
                dismissAnimation: nil
            )
            // fullScreenCover does not reliably expose the sheet grabber. Use
            // the player's single accessible grabber and suppress any system
            // indicator if this presentation adapts to a sheet.
            .presentationDragIndicator(.hidden)
            .presentationBackground(Color.clear)
        } else {
            nowPlayingPresentation(
                usesSystemInteractiveDismissal: true,
                dismissAnimation: nil
            )
        }
    }

    private var legacyPresentationRoot: some View {
        ZStack {
            appContent
                .allowsHitTesting(!player.showNowPlaying)
                .accessibilityHidden(player.showNowPlaying)

            if player.showNowPlaying {
                // Keep the real app behind the moving card, without a system
                // cover's rounded opening surface or an opaque underlay.
                nowPlayingPresentation(
                    usesSystemInteractiveDismissal: false,
                    dismissAnimation: NowPlayingPresentationMetrics.presentationAnimation
                )
                .accessibilityAddTraits(.isModal)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            }
        }
        .animation(NowPlayingPresentationMetrics.presentationAnimation, value: player.showNowPlaying)
    }

    @ViewBuilder
    private var appContent: some View {
        // Keep every iOS form factor on the same source-only surface. The
        // old split view still contains the desktop/provider navigation and
        // would reintroduce those entry points on iPad.
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            tabInterface
                .background(Color.clear)
        }
    }

    private func nowPlayingPresentation(
        usesSystemInteractiveDismissal: Bool,
        dismissAnimation: Animation?
    ) -> some View {
        IOSNowPlayingPresentation(
            isPresented: $player.showNowPlaying,
            usesSystemInteractiveDismissal: usesSystemInteractiveDismissal,
            dismissAnimation: dismissAnimation
        ) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(settings)
        }
    }

    @ViewBuilder
    private var tabInterface: some View {
        // iOS 26 and later supply the real system Liquid Glass through
        // TabView and its bottom accessory. Do not substitute a custom
        // Material tab bar on iOS 27, otherwise the system effect is lost.
        if #available(iOS 26.0, *) {
            iOS26TabInterface
        } else {
            customTabInterface
        }
    }

    /// Attach the bottom mini-player accessory only when something is playing.
    /// Leaving the modifier on with empty content still renders an empty,
    /// translucent accessory platter above the tab bar when idle (#35), so we
    /// apply it conditionally.
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            .tabBarMinimizeBehavior(.onScrollDown)
            // Keep one TabView identity while the accessory appears/disappears.
            .modifier(MiniPlayerAccessoryModifier(
                isActive: player.hasCurrentTrack,
                transitionNamespace: nowPlayingTransition,
                colorScheme: resolvedColorScheme
            ))
            .animation(AppAnimation.standard, value: player.hasCurrentTrack)
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("主页", systemImage: "house", value: .home) {
                tabStack(.home) { HomeView() }
            }

            Tab("新发现", systemImage: "square.grid.2x2", value: .new) {
                tabStack(.new) { ExploreView() }
            }

            Tab("电台", systemImage: "dot.radiowaves.left.and.right", value: .radio) {
                tabStack(.radio) { FMView() }
            }

            Tab("资料库", systemImage: "square.stack", value: .library) {
                tabStack(.library) { LocalPlaylistsView() }
            }

            // The search role pins the magnifying-glass tab at the trailing
            // edge, matching Music's separated search control.
            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                tabStack(.search) { SearchView(query: "") }
            }
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .background(NativeTabReselectionObserver {
            popToRoot(selectedTab)
        })
        .background(Color.clear)
    }

    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            // Construct only the selected page to keep launch work small.
            selectedPage

            VStack(spacing: 8) {
                if player.hasCurrentTrack {
                    IOSMiniPlayerBar(presentation: .legacyOverlay)
                        .nowPlayingTransitionSource(in: nowPlayingTransition)
                        .padding(.horizontal, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                GlassTabBar(items: Self.tabItems, selection: $selectedTab) { tab in
                    popToRoot(tab)
                }
            }
            .padding(.bottom, 6)
        }
        .animation(AppAnimation.standard, value: player.hasCurrentTrack)
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selectedTab {
        case .home:
            tabStack(.home) { HomeView() }
        case .new:
            tabStack(.new) { ExploreView() }
        case .radio:
            tabStack(.radio) { FMView() }
        case .search:
            tabStack(.search) { SearchView(query: "") }
        case .library:
            tabStack(.library) { LocalPlaylistsView() }
        }
    }

    private func appendToSelectedTab(_ destination: Destination) {
        switch selectedTab {
        case .home: homePath.append(destination)
        case .new: newPath.append(destination)
        case .radio: radioPath.append(destination)
        case .search: searchPath.append(destination)
        case .library: libraryPath.append(destination)
        }
    }

    private func popToRoot(_ tab: IOSTab) {
        switch tab {
        case .home: homePath = NavigationPath()
        case .new: newPath = NavigationPath()
        case .radio: radioPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .library: libraryPath = NavigationPath()
        }
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        NavigationStack(path: binding(for: tab)) {
            content().appDestinations()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .background(Color.clear)
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }

    private func binding(for tab: IOSTab) -> Binding<NavigationPath> {
        switch tab {
        case .home: return $homePath
        case .new: return $newPath
        case .radio: return $radioPath
        case .search: return $searchPath
        case .library: return $libraryPath
        }
    }
}

enum IOSTab: Hashable {
    case home, new, radio, search, library
}

extension IOSMainWindow {
    static let tabItems: [GlassTabBar.Item] = [
        .init(tab: .home, title: "主页", icon: "house"),
        .init(tab: .new, title: "新发现", icon: "square.grid.2x2"),
        .init(tab: .radio, title: "电台", icon: "dot.radiowaves.left.and.right"),
        .init(tab: .library, title: "资料库", icon: "square.stack"),
        .init(tab: .search, title: "搜索", icon: "magnifyingglass"),
    ]
}

// MARK: - Mini player bar for iOS

private enum NowPlayingTransitionID {
    static let surface = "now-playing-surface"
}

@available(iOS 26.0, *)
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let isActive: Bool
    let transitionNamespace: Namespace.ID
    let colorScheme: ColorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.tabViewBottomAccessory {
                IOSMiniPlayerAccessory(transitionNamespace: transitionNamespace)
                    .environment(\.colorScheme, colorScheme)
            }
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private struct IOSMiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let transitionNamespace: Namespace.ID

    var body: some View {
        IOSMiniPlayerBar(presentation: presentation)
            .nowPlayingTransitionSource(in: transitionNamespace)
    }

    private var presentation: IOSMiniPlayerBar.Presentation {
        let placementIsInline = placement.map { $0 == .inline }
        return NowPlayingPresentationMetrics.shouldUseInlineMiniPlayerLayout(
            placementIsInline: placementIsInline
        ) ? .inlineAccessory : .bottomAccessory
    }
}

private extension View {
    @ViewBuilder
    func nowPlayingTransitionSource(in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: NowPlayingTransitionID.surface, in: namespace)
        } else {
            self
        }
    }
}

/// Renders mini-player content inside either a system-owned tab accessory or
/// the material-backed compatibility overlay used before iOS 26.
///
/// Do not add a background for `bottomAccessory` or `inlineAccessory`: the
/// tab view owns their Liquid Glass surface and adding another material creates
/// a visibly nested card.
struct IOSMiniPlayerBar: View {
    enum Presentation {
        case bottomAccessory
        case inlineAccessory
        case legacyOverlay

        var isInline: Bool { self == .inlineAccessory }
        var drawsBackground: Bool { self == .legacyOverlay }
    }

    @EnvironmentObject private var player: PlayerService
    @State private var swipeTrackKey: String?
    let presentation: Presentation

    var body: some View {
        playerBarSurface
            .simultaneousGesture(playerGesture)
    }

    @ViewBuilder
    private var playerBarSurface: some View {
        if presentation.drawsBackground {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Button(action: showNowPlaying) {
                trackSummary
            }
            .buttonStyle(.plain)
            .accessibilityLabel(nowPlayingAccessibilityLabel)
            .accessibilityHint("打开正在播放")
            .accessibilityIdentifier("miniPlayerOpenNowPlaying")
            // VoiceOver cannot perform the drag that skips back, so the
            // previous-track action is exposed as a named action instead.
            .accessibilityAction(named: Text("上一首")) {
                guard !player.isFMMode else { return }
                player.previous()
            }

            // Like the system mini player: play/pause and next only. Previous
            // is a horizontal swipe here and a button in the full player.
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: presentation.isInline ? 16 : 19, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: presentation.isInline ? 15 : 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(player.isFMMode)
            .opacity(player.isFMMode ? 0.35 : 1)
            .accessibilityLabel("下一首")
        }
        .padding(.leading, presentation.isInline ? 8 : 10)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity)
    }

    private var trackSummary: some View {
        HStack(alignment: .center, spacing: 10) {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(
                    width: artworkSize,
                    height: artworkSize
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: metadataSpacing) {
                Text(player.currentTrack?.name ?? "")
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(player.currentTrack?.artistNames ?? "")
                    .font(artistFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // The system accessory has a fixed height; cap growth so the two
            // lines never clip at the largest accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artworkSize: CGFloat {
        presentation.isInline ? 28 : 36
    }

    // Dynamic Type styles, so the accessory follows the user's text size
    // like other system chrome instead of pinning 10pt/8pt labels.
    private var titleFont: Font {
        presentation.isInline ? Font.footnote.weight(.semibold) : Font.subheadline.weight(.semibold)
    }

    private var artistFont: Font {
        presentation.isInline ? Font.caption2 : Font.footnote
    }

    private var metadataSpacing: CGFloat {
        presentation.isInline ? 0 : 1
    }

    private var nowPlayingAccessibilityLabel: String {
        let title = player.currentTrack?.name ?? String(localized: "正在播放")
        guard let artist = player.currentTrack?.artistNames, !artist.isEmpty else {
            return title
        }
        return "\(title)，\(artist)"
    }

    private var playerGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { _ in
                if swipeTrackKey == nil { swipeTrackKey = player.currentTrack?.playbackKey }
            }
            .onEnded { value in
                // A single axis decision prevents diagonal track swipes from
                // also opening the player. Never skip a newly selected song
                // when an async queue change arrives during this gesture.
                let gestureTrackKey = swipeTrackKey
                swipeTrackKey = nil
                guard gestureTrackKey == player.currentTrack?.playbackKey,
                      player.hasCurrentTrack else { return }
                if let direction = MiniPlayerSwipePolicy.trackDirection(
                    translation: value.translation,
                    predictedTranslation: value.predictedEndTranslation
                ) {
                    guard !player.isFMMode else { return }
                    if direction < 0 { player.next() } else { player.previous() }
                    return
                }
                guard abs(value.translation.height) > abs(value.translation.width) * 1.25 else { return }
                guard NowPlayingPresentationMetrics.shouldExpandFromMiniPlayer(
                    translation: value.translation.height,
                    predictedTranslation: value.predictedEndTranslation.height
                ) else { return }
                showNowPlaying()
            }
    }

    private func showNowPlaying() {
        player.showNowPlaying = true
    }
}

// The previous account/library surface contained the NetEase login and
// provider playlist actions. It is intentionally not part of the iOS target.
#if false
// MARK: - Removed iOS provider library

struct IOSLibraryView: View {
    @Binding var showLogin: Bool
    @EnvironmentObject private var account: AccountStore
    @StateObject private var lxStore = LXSourceStore.shared
    @State private var showSourceManager = false
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        List {
            Section {
                NavigationLink(value: Destination.localPlaylists) {
                    Label("本地歌单", systemImage: "music.note.list")
                }
            } header: {
                Text("歌单")
            } footer: {
                Text("本地歌单不需要登录，可导入其他音乐软件的歌单，也可以在歌曲页面添加歌曲。")
            }

            Section {
                Button {
                    showSourceManager = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.badge.plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "LX 音源")
                                .font(.headline)
                            Text(verbatim: lxStore.selectedSource.map { "已启用：\($0.name)" } ?? "未启用音源，可在这里导入")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    showSourceManager = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text(verbatim: "管理 / 导入 LX 音源")
                    }
                }
            } header: {
                Text(verbatim: "音源设置")
            } footer: {
                        Text(verbatim: "账号音源会优先提供完整音频；没有可用账号音频时，歌曲才会按这里启用的 LX User API 顺序回退。")
            }

            // Profile / Login header
            Section {
                if let profile = account.profile {
                    HStack(spacing: 14) {
                        CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(128))
                            .frame(width: 52, height: 52)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(profile.nickname)
                                    .font(.headline)
                                if profile.vipType > 0 {
                                    VIPBadge()
                                }
                            }
                            if let sig = profile.signature, !sig.isEmpty {
                                Text(sig)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("登录网易云音乐")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("同步我喜欢的音乐、歌单与每日推荐")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }

            if account.hasAuthCookie {
                Section("网易云音乐账号") {
                    if let liked = account.likedSongsPlaylist {
                        NavigationLink(value: Destination.playlist(liked.id)) {
                            Label("我喜欢的音乐", systemImage: "star.fill")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    NavigationLink(value: Destination.daily) {
                        Label("每日推荐", systemImage: "calendar")
                    }
                    NavigationLink(value: Destination.recents) {
                        Label("最近播放", systemImage: "clock.fill")
                    }
                    NavigationLink(value: Destination.collections) {
                        Label("我的收藏", systemImage: "star.fill")
                    }
                    NavigationLink(value: Destination.cloud) {
                        Label("音乐云盘", systemImage: "icloud.fill")
                    }
                }

                if !account.createdPlaylists.isEmpty {
                    Section {
                        ForEach(account.createdPlaylists) { playlist in
                            NavigationLink(value: Destination.playlist(playlist.id)) {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("创建的歌单")
                            Spacer()
                            Button {
                                showNewPlaylist = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                    }
                }

                if !account.subscribedPlaylists.isEmpty {
                    Section("收藏的歌单") {
                        ForEach(account.subscribedPlaylists) { playlist in
                            NavigationLink(value: Destination.playlist(playlist.id)) {
                                HStack(spacing: 10) {
                                    CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(80), animated: false)
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(playlist.name)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Text("\(playlist.trackCount) 首")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("我的")
        .sheet(isPresented: $showSourceManager) {
            NavigationStack {
                LXSourceManagerView()
            }
        }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("歌单名称", text: $newPlaylistName)
            Button("创建") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                newPlaylistName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        try await NeteaseAPI.createPlaylist(name: name, isPrivate: false)
                        await account.refreshLibrary()
                        ToastCenter.shared.show(String(localized: "歌单已创建"))
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) { newPlaylistName = "" }
        }
    }
}

#endif

/// Observe the native controller while forwarding SwiftUI's delegate behavior.
/// Forward all existing delegate behavior, including SwiftUI's selection work.
private struct NativeTabReselectionObserver: UIViewControllerRepresentable {
    var onReselect: () -> Void

    func makeUIViewController(context: Context) -> Observer {
        Observer(onReselect: onReselect)
    }

    func updateUIViewController(_ controller: Observer, context: Context) {
        controller.onReselect = onReselect
        controller.installWhenReady()
    }

    static func dismantleUIViewController(_ controller: Observer, coordinator: ()) {
        controller.uninstall()
    }

    final class Observer: UIViewController, UITabBarControllerDelegate {
        var onReselect: () -> Void
        private weak var observed: UITabBarController?
        private weak var originalDelegate: (any UITabBarControllerDelegate)?

        init(onReselect: @escaping () -> Void) {
            self.onReselect = onReselect
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installWhenReady()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installWhenReady()
        }

        func installWhenReady() {
            // SwiftUI may finish containment after the representable update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent != nil else { return }
                var root: UIViewController = self
                while let parent = root.parent { root = parent }
                guard let tabs = self.findTabs(in: root), tabs.delegate !== self else { return }
                self.uninstall()
                self.originalDelegate = tabs.delegate
                self.observed = tabs
                tabs.delegate = self
            }
        }

        private func findTabs(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            return controller.children.lazy.compactMap { self.findTabs(in: $0) }.first
        }

        func uninstall() {
            if let observed, observed.delegate === self {
                observed.delegate = originalDelegate
            }
            observed = nil
            originalDelegate = nil
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            let allowed = originalDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
            if allowed, tabBarController.selectedViewController === viewController {
                onReselect()
            }
            return allowed
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
#endif
