import SwiftUI
#if os(iOS)
import MediaPlayer
import UIKit
#endif

/// Single Apple Music-style now-playing surface with a song page and a synced
/// lyrics page, both backed by the current artwork palette.
struct NowPlayingView: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @ObservedObject private var localLibrary = LocalPlaylistStore.shared
    @ObservedObject private var renderingBudget = RenderingBudget.shared
    @EnvironmentObject private var settings: SettingsManager
    #if os(iOS)
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingDragAction) private var dismissNowPlayingDragAction
    #endif

    @State private var artworkImage: PlatformImage?
    @State private var artworkPalette = ArtworkPaletteTransition()
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var isLyricsDragActive = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var showLyricsOnMobile = false
    @State private var lyricsControlsVisible = true
    @State private var lyricsControlsTask: Task<Void, Never>?
    @State private var showQualityPicker = false
    @State private var showComments = false
    @State private var showAddToPlaylist = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @State private var showQueueOnMobile = false
    @State private var showQueueSheet = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            let phoneLandscape = isPhoneLandscape(size: geo.size)
            ZStack {
                backdrop

                if phoneLandscape {
                    phoneLandscapeLayout(size: geo.size)
                } else if isCompact {
                    compactLayout(size: geo.size)
                } else {
                    regularLayout(size: geo.size)
                }
            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push content off-screen.
            .frame(width: geo.size.width)
            .simultaneousGesture(playerPageSwipeGesture(height: geo.size.height))
        }
        #if os(macOS)
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        // iOS keeps its safe area: there the inset is the status bar / notch.
        .ignoresSafeArea()
        #endif
        .preferredColorScheme(settings.appearance.colorScheme)
        .task(id: player.currentTrack?.playbackKey) {
            await loadArtwork()
        }
        .task(id: artworkPalette.revision) {
            let revision = artworkPalette.revision
            guard artworkPalette.isTransitioning else { return }
            try? await Task.sleep(for: .seconds(ArtworkPaletteTransition.duration))
            guard !Task.isCancelled else { return }
            artworkPalette.finishTransition(revision: revision)
        }
        #if os(iOS)
        .onChange(of: player.currentTrack?.playbackKey) { _ in
            showLyricsOnMobile = false
            lyricsControlsTask?.cancel()
            lyricsControlsVisible = true
            isLyricsDragActive = false
            isUserScrolling = false
            resumeTask?.cancel()
            resumeTask = nil
        }
        #endif
        .onChange(of: showLyricsOnMobile) { _, isShowing in
            if isShowing {
                revealLyricsControls()
            } else {
                lyricsControlsTask?.cancel()
                lyricsControlsVisible = true
            }
        }
        .onChange(of: reduceMotion) { _, isEnabled in
            if isEnabled {
                artworkPalette.stopForReducedMotionOrPowerBudget()
            }
        }
        .onChange(of: renderingBudget.allowsContinuousEffects) { _, isEnabled in
            if !isEnabled {
                artworkPalette.stopForReducedMotionOrPowerBudget()
            }
        }
        .onChange(of: renderingBudget.isSceneActive) { _, isActive in
            if !isActive {
                artworkPalette.stopForReducedMotionOrPowerBudget()
            }
        }
        #if os(macOS)
        .onExitCommand {
            close()
        }
        #endif
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerSheet()
                .environmentObject(player)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showComments) {
            if let track = player.currentTrack {
                SongCommentsSheet(track: track)
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showQueueSheet) {
            MinimalQueueSheet(backdrop: artworkPalette.colors)
                .presentationDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                player.showNowPlaying = false
            }
        }
        #else
        player.showNowPlaying = false
        #endif
    }

    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.18))
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
#if os(iOS)
        artworkBackdrop
            .overlay {
                LinearGradient(
                    colors: [.black.opacity(0.12), .clear, .black.opacity(0.58)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .background(.black)
            .ignoresSafeArea()
#else
        artworkBackdrop.ignoresSafeArea()
#endif
    }

    /// The two Apple Music pages are a horizontal pager: a left swipe opens
    /// lyrics and a right swipe returns to the artwork controls. Ignore
    /// vertical drags so the lyric list scrolls normally, and ignore swipes
    /// beginning in the lower control area so seeking cannot change pages.
    private func playerPageSwipeGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 36)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > 90,
                      abs(horizontal) > abs(vertical) * 1.35,
                      value.startLocation.y < height * 0.72 else { return }
                let shouldShowLyrics = horizontal < 0
                guard shouldShowLyrics != showLyricsOnMobile else { return }
                withAnimation(AppAnimation.standard) {
                    showLyricsOnMobile = shouldShowLyrics
                }
            }
    }

    private var artworkBackdrop: some View {
        TimelineView(.animation(
            minimumInterval: renderingBudget.minimumAnimationInterval,
            paused: !artworkPalette.isTransitioning
        )) { _ in
            let palette = artworkPalette.displayedColors(at: ProcessInfo.processInfo.systemUptime)
            GeometryReader { geometry in
                ZStack {
                    artworkGradient(for: palette)
                    Circle()
                        .fill(palette.primary.opacity(0.46))
                        .frame(width: geometry.size.width * 1.15)
                        .blur(radius: 78)
                        .offset(x: -geometry.size.width * 0.24, y: -geometry.size.height * 0.22)
                    Circle()
                        .fill(palette.secondary.opacity(0.44))
                        .frame(width: geometry.size.width * 0.98)
                        .blur(radius: 92)
                        .offset(x: geometry.size.width * 0.26, y: geometry.size.height * 0.08)
                    LinearGradient(
                        colors: [.black.opacity(0.08), .clear, .black.opacity(0.58)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
    }

    private func artworkGradient(for palette: ArtworkColors) -> some View {
        // Keep the artwork-derived tone continuous across the page. A gentle
        // shade avoids the hard color bands from interpolating unrelated
        // primary and secondary artwork swatches.
        LinearGradient(
            stops: [
                .init(color: palette.primary.opacity(0.98), location: 0),
                .init(color: palette.primary.opacity(0.92), location: 0.32),
                .init(color: palette.secondary.opacity(0.94), location: 0.76),
                .init(color: .black.opacity(0.96), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func transitionArtworkPalette(to next: ArtworkColors) {
        let allowsAnimation = RenderingBudget.permitsArtworkPaletteTransition(
            isSceneActive: renderingBudget.isSceneActive,
            allowsContinuousEffects: renderingBudget.allowsContinuousEffects,
            reduceMotion: reduceMotion
        )
        artworkPalette.transition(
            to: next,
            at: ProcessInfo.processInfo.systemUptime,
            allowsAnimation: allowsAnimation
        )
    }

    private func loadArtwork() async {
        guard !Task.isCancelled else { return }
        artworkImage = nil
        guard let track = player.currentTrack else {
            transitionArtworkPalette(to: .fallback)
            return
        }
        let playbackKey = track.playbackKey
#if os(iOS)
        if IOSUITestMode.hasPlayerFixture, track.id == 27_000_001 {
            let image = Self.makeUITestArtwork()
            artworkImage = image
            transitionArtworkPalette(to: ArtworkPalette.extract(from: image, cacheKey: "imusic-ui-test-artwork"))
            return
        }
#endif
        var urlString = track.album.picUrl
        if urlString == nil {
            let query = [track.name, track.artistNames].filter { !$0.isEmpty }.joined(separator: " ")
            let result = try? await NeteaseAPI.search(query, type: .songs, limit: 6)
            guard !Task.isCancelled, player.currentTrack?.playbackKey == playbackKey else { return }
            if let result,
               let match = result.songs?.first(where: { $0.name == track.name }) ?? result.songs?.first {
                urlString = match.album.picUrl
            }
        }
        guard let urlString, let url = urlString.resizedImageURL(768) else {
            guard !Task.isCancelled, player.currentTrack?.playbackKey == playbackKey else { return }
            transitionArtworkPalette(to: .fallback)
            return
        }
        let cachedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled, player.currentTrack?.playbackKey == playbackKey else { return }
        if let image = cachedImage {
            artworkImage = image
            transitionArtworkPalette(to: ArtworkPalette.extract(from: image, cacheKey: urlString))
        } else {
            guard player.currentTrack?.playbackKey == playbackKey else { return }
            transitionArtworkPalette(to: .fallback)
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func phoneLandscapeLayout(size: CGSize) -> some View {
        if showLyricsOnMobile {
            appleMusicLyricsPage()
        } else {
            let artworkSize = min(size.height - 76, 280)
            HStack(spacing: 28) {
                artworkView(size: artworkSize)

                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    trackMetaView
                        .padding(.bottom, 8)
                    NowPlayingScrubber(showsRemainingTime: true)
                    primaryTransportControls
                    CompactVolumeControl()
                    songPageAccessoryControls
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 36)
        }
    }

    private func regularLayout(size: CGSize) -> some View {
        let artworkSize = max(120, min(340, size.width * 0.48, size.height - 300))
        return Group {
            if showLyricsOnMobile {
                VStack(spacing: 18) {
                    trackMetaView
                        .padding(.top, 12)
                    lyricsColumn
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, 48)
            } else {
                leftColumn(artworkSize: artworkSize)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 48)
            }
        }
        .padding(.vertical, size.height < 500 ? 24 : 40)
    }

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        appleMusicCompactLayout(size: size)
    }

    /// iPhone's primary player follows Apple's Now Playing hierarchy: artwork,
    /// one compact title/artist row, a timeline, three transport controls,
    /// volume, and a row for lyrics, output, and queue. Lyrics are the only
    /// alternate page.
    @ViewBuilder
    private func appleMusicCompactLayout(size: CGSize) -> some View {
        let isShortScreen = size.height < 680
        let artworkSize = min(size.width - 52, size.height * (isShortScreen ? 0.34 : 0.39), 360)

        if showLyricsOnMobile {
            appleMusicLyricsPage()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("appleMusicLyricsPage")
        } else {
            VStack(spacing: 0) {
                Spacer(minLength: isShortScreen ? 16 : 24)

                artworkView(size: artworkSize)
                    .padding(.bottom, isShortScreen ? 20 : 28)

                trackMetaView
                    .padding(.bottom, isShortScreen ? 8 : 14)

                NowPlayingScrubber(
                    onShowQuality: { showQualityPicker = true },
                    showsRemainingTime: true
                )
                .padding(.bottom, isShortScreen ? 3 : 8)

                primaryTransportControls
                    .padding(.bottom, isShortScreen ? 5 : 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("nowPlayingTransportControls")

                CompactVolumeControl()
                    .padding(.bottom, isShortScreen ? 2 : 10)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("nowPlayingVolumeControl")

                songPageAccessoryControls
            }
            .padding(.horizontal, 26)
            .padding(.top, isShortScreen ? 32 : 42)
            .padding(.bottom, isShortScreen ? 12 : 18)
            .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("appleMusicSongPage")
        }
    }

    private func appleMusicLyricsPage() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                artworkView(size: 54)
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                trackMetaView
            }
            .padding(.bottom, 18)

            lyricsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if lyricsControlsVisible {
                VStack(spacing: 5) {
                    NowPlayingScrubber(
                        onShowQuality: { showQualityPicker = true },
                        showsRemainingTime: true
                    )
                    primaryTransportControls
                    CompactVolumeControl()
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("lyricsVolumeControl")
                }
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("lyricsTransportControls")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, lyricsControlsVisible ? 12 : 20)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { revealLyricsControls() })
        .overlay(alignment: .bottom) {
            if !lyricsControlsVisible {
                Button(action: revealLyricsControls) {
                    Color.clear
                    .frame(height: 164)
                    .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("显示播放控制")
                    .accessibilityHint("显示暂停、切歌和音量控制")
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
        .animation(.easeInOut(duration: 0.28), value: lyricsControlsVisible)
    }

    private func revealLyricsControls() {
        guard showLyricsOnMobile else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            lyricsControlsVisible = true
        }
        scheduleLyricsControlsAutoHide()
    }

    private func scheduleLyricsControlsAutoHide() {
        lyricsControlsTask?.cancel()
        lyricsControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, showLyricsOnMobile else { return }
            withAnimation(.easeInOut(duration: 0.28)) {
                lyricsControlsVisible = false
            }
        }
    }

    private var songPageAccessoryControls: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(AppAnimation.standard) {
                    showLyricsOnMobile = true
                }
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("显示同步歌词")
            .accessibilityIdentifier("showSynchronizedLyrics")

            RoutePickerButton(diameter: 40, glyphSize: 18)
                .frame(maxWidth: .infinity)

            #if os(iOS)
            Button { showQueueSheet = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("播放队列")
            #endif
        }
        .frame(maxWidth: 360)
    }

    private var primaryTransportControls: some View {
        HStack(spacing: 0) {
            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.end.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            playPauseButton
                .frame(maxWidth: .infinity)

            Button(action: player.next) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .frame(maxWidth: 460)
    }


    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 64, size.height * 0.38, 300)
        return VStack(spacing: 20) {
            Spacer().frame(height: 44)
            if showLyricsOnMobile {
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    artworkView(size: artworkDim)
                    trackMetaView
                    MiniLyricsView {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity)
            }
            VStack(spacing: 12) {
                NowPlayingScrubber(onShowQuality: { showQualityPicker = true })
                    .padding(.horizontal, 24)
                CompactVolumeControl()
                    .padding(.horizontal, 24)
                controls
            }
            .padding(.bottom, 38)
        }
        .padding(.horizontal, 16)
    }

    private func lyricsCompactLayout(size: CGSize) -> some View {
        VStack(spacing: 14) {
            trackMetaView
                .padding(.top, 38)
            lyricsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            NowPlayingScrubber(onShowQuality: { showQualityPicker = true })
                .padding(.horizontal, 20)
            CompactVolumeControl()
                .padding(.horizontal, 20)
            controls
                .padding(.bottom, 32)
        }
        .padding(.horizontal, 16)
    }

    private func vinylCompactLayout(size: CGSize) -> some View {
        let artworkDim = min(size.width - 72, size.height * 0.43, 310)
        return VStack(spacing: 16) {
            Spacer().frame(height: 34)
            VinylTurntableView(
                artworkImage: artworkImage,
                isPlaying: player.isPlaying,
                trackId: player.currentTrack?.id,
                size: artworkDim,
                onTap: {
                    withAnimation(AppAnimation.standard) {
                        showLyricsOnMobile = true
                    }
                },
                onNextTrack: player.next,
                onPreviousTrack: player.previous
            )
            .frame(maxWidth: .infinity)
            trackMetaView
            MiniLyricsView {
                showLyricsOnMobile = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            NowPlayingScrubber(onShowQuality: { showQualityPicker = true })
                .padding(.horizontal, 20)
            controls
                .padding(.bottom, 32)
        }
        .padding(.horizontal, 16)
    }

    #if os(iOS)
    private func immersiveCompactLayout(size: CGSize) -> some View {
        let artworkDimension = min(size.width - 112, size.height * 0.3, 250)
        let showsExpandedArtwork = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(showsExpandedArtwork: showsExpandedArtwork)
                .padding(.bottom, 14)

            ZStack {
                immersiveArtworkContent(artworkDimension: artworkDimension)
                    .opacity(showsExpandedArtwork ? 1 : 0)
                    .allowsHitTesting(showsExpandedArtwork)
                    .accessibilityHidden(!showsExpandedArtwork)

                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    IOSImmersiveLyricsColumn()
                        .opacity(showLyricsOnMobile ? 1 : 0)
                        .allowsHitTesting(showLyricsOnMobile)
                        .accessibilityHidden(!showLyricsOnMobile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .overlayPreferenceValue(ImmersiveArtworkFramePreferenceKey.self) { frames in
            GeometryReader { proxy in
                if let compactAnchor = frames[.compact],
                   let expandedAnchor = frames[.expanded] {
                    let compactFrame = proxy[compactAnchor]
                    let expandedFrame = proxy[expandedAnchor]
                    let targetFrame = showsExpandedArtwork ? expandedFrame : compactFrame
                    let targetCenterX = showsExpandedArtwork
                        ? size.width / 2
                        : compactFrame.midX

                    immersiveArtworkSurface(isExpanded: showsExpandedArtwork)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetCenterX, y: targetFrame.midY)
                        .accessibilityIdentifier("immersiveArtwork")
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var immersiveControls: some View {
        VStack(spacing: 17) {
            NowPlayingScrubber(onShowQuality: { showQualityPicker = true })
            CompactTransportControls()
            CompactVolumeControl()
            CompactSecondaryControls(
                showsLyrics: showLyricsOnMobile,
                showsQueue: showQueueOnMobile,
                onShowComments: { showComments = true },
                onToggleLyrics: toggleImmersiveLyrics,
                onToggleQueue: toggleImmersiveQueue
            )
        }
        .padding(.top, 14)
        .padding(.bottom, 24)
        .accessibilityIdentifier("immersiveControls")
    }

    private func immersiveArtworkContent(artworkDimension: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Color.clear
                .frame(width: artworkDimension, height: artworkDimension)
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.expanded: $0] }
            MiniLyricsView(onOpen: showImmersiveLyrics)
                .frame(maxWidth: .infinity, maxHeight: 96)
            Spacer(minLength: 0)
        }
    }

    private func immersiveArtworkSurface(isExpanded: Bool) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(isExpanded ? 0.06 : 0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: isExpanded ? 48 : 18, weight: .light))
                            .foregroundStyle(.white.opacity(isExpanded ? 0.3 : 0.45))
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isExpanded ? 18 : 12,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.22),
            radius: isExpanded ? 36 : 10,
            y: isExpanded ? 18 : 4
        )
    }

    private func toggleImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            if showQueueOnMobile {
                showQueueOnMobile = false
                showLyricsOnMobile = true
            } else {
                showLyricsOnMobile.toggle()
            }
        }
    }

    private func showImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile = false
            showLyricsOnMobile = true
        }
    }

    private func toggleImmersiveQueue() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile.toggle()
        }
    }

    private func minimalCompactLayout(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkDimension = min(contentWidth, size.height * 0.52, 378)

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                MinimalTrackInfoRow(metadataOnly: true)
                    .padding(.top, NowPlayingPresentationMetrics.immersiveHeaderTopInset)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 90)

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)

                artworkView(size: artworkDimension)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)
                    .accessibilityIdentifier("immersiveArtwork")
                    .accessibilityLabel("显示歌词")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleMinimalLyrics() }
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)

                IOSMinimalLyricsColumn {
                    showLyricsOnMobile = false
                }
                .opacity(showLyricsOnMobile ? 1 : 0)
                .allowsHitTesting(showLyricsOnMobile)
                .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(
                minimalDismissGesture,
                including: showLyricsOnMobile ? .none : .all
            )
            .padding(.bottom, 34)

            minimalControls
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 32)
        .padding(.bottom, 46)
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
    }

    private var minimalControls: some View {
        VStack(spacing: 22) {
            ZStack {
                MinimalTrackInfoRow()
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)
                    .accessibilityHidden(showLyricsOnMobile)
                MinimalTrackInfoRow(actionsOnly: true)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .allowsHitTesting(showLyricsOnMobile)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 44)
            NowPlayingScrubber(onShowQuality: { showQualityPicker = true })
                .padding(.horizontal, 2)
                .padding(.top, 16)
            CompactVolumeControl()
                .padding(.horizontal, 2)
            MinimalTransportControls(
                backdrop: artworkPalette.colors,
                showQueue: $showQueueOnMobile
            )
                .padding(.horizontal, 2)
            HStack(spacing: 8) {
                Button { showComments = true } label: {
                    Label("评论", systemImage: "text.bubble")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
        .accessibilityIdentifier("immersiveControls")
    }

    private func toggleMinimalLyrics() {
        guard showLyricsOnMobile || player.lyrics?.isEmpty == false else { return }
        showLyricsOnMobile.toggle()
    }

    private var minimalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }
    #endif

    // MARK: - Views

    private func isPhoneLandscape(size: CGSize) -> Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
            && size.width > size.height
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var playerGlassCircle: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
        #else
        Circle().fill(.ultraThinMaterial)
        #endif
    }

    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: min(48, size * 0.42), weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 9)
        .accessibilityLabel("专辑封面")
        .accessibilityIdentifier("nowPlayingArtworkImage")
    }

#if os(iOS)
    private static func makeUITestArtwork() -> PlatformImage {
        let size = CGSize(width: 512, height: 512)
        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            let colors = [
                UIColor(red: 0.04, green: 0.47, blue: 0.55, alpha: 1).cgColor,
                UIColor(red: 0.16, green: 0.78, blue: 0.68, alpha: 1).cgColor,
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            )!
            context.drawLinearGradient(
                gradient,
                start: CGPoint.zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            context.setFillColor(UIColor(red: 0.98, green: 0.70, blue: 0.38, alpha: 0.95).cgColor)
            context.fillEllipse(in: CGRect(x: 82, y: 84, width: 250, height: 250))
            context.setFillColor(UIColor(red: 0.18, green: 0.20, blue: 0.48, alpha: 0.95).cgColor)
            context.fillEllipse(in: CGRect(x: 227, y: 232, width: 226, height: 226))
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(14)
            context.setLineCap(.round)
            for (index, height) in [74.0, 144, 104, 190, 122, 70].enumerated() {
                let x = CGFloat(152 + index * 42)
                context.move(to: CGPoint(x: x, y: 256 - height / 2))
                context.addLine(to: CGPoint(x: x, y: 256 + height / 2))
            }
            context.strokePath()
        }
    }
#endif

    private var trackMetaView: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(.title2, design: .default, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .accessibilityAddTraits(.isHeader)
                Text(player.currentTrack?.artistNames ?? "")
                    .font(.system(.title3, design: .default, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let track = player.currentTrack {
                let liked = localLibrary.isFavorite(track)
                Button {
                    localLibrary.toggleFavorite(track)
                } label: {
                    Image(systemName: liked ? "star.fill" : "star")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                        .frame(width: 42, height: 44)
                        .background { playerGlassCircle }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(liked ? "取消收藏" : "收藏")

                Menu {
                    Button {
                        player.addToPlayNext(track)
                    } label: {
                        Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Button {
                        showAddToPlaylist = true
                    } label: {
                        Label("加入歌单…", systemImage: "music.note.list")
                    }

                    Button {
                        showQualityPicker = true
                    } label: {
                        Label("音质与音源", systemImage: "waveform")
                    }

                    Button {
                        player.toggleShuffle()
                    } label: {
                        Label(
                            player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                            systemImage: "shuffle"
                        )
                    }

                    Button {
                        player.cycleRepeatMode()
                    } label: {
                        Label(
                            player.repeatMode == .off ? "开启循环播放" : "切换循环模式",
                            systemImage: player.repeatMode == .one ? "repeat.1" : "repeat"
                        )
                    }

                    SleepTimerMenu(player: player)

                    Divider()

                    Button {
                        Platform.copyToPasteboard(
                            string: "https://music.163.com/#/song?id=\(track.id)"
                        )
                        ToastCenter.shared.show(String(localized: "链接已复制"))
                    } label: {
                        Label("复制链接", systemImage: "link")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 42, height: 44)
                        .background { playerGlassCircle }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("更多操作")
            }
        }
        .frame(maxWidth: 460)
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            Spacer()

            artworkView(size: artworkSize)
            trackMetaView

            VStack(spacing: 14) {
                NowPlayingScrubber(onShowQuality: { showQualityPicker = true })
                    .frame(maxWidth: 380)
                controls
            }

            Spacer()
        }
    }

    private var controls: some View {
        // Equal-width slots so the row always fits the screen: fixed-size
        // buttons in a plain HStack summed wider than a phone (≈430pt with the
        // like button), overflowing the layout and shoving the overlays and
        // metadata off the right edge. `maxWidth: .infinity` per control makes
        // the row scale to any width instead.
        HStack(spacing: 0) {
            if let track = player.currentTrack {
                let liked = localLibrary.isFavorite(track)
                circleButton(
                    icon: liked ? "heart.fill" : "heart",
                    size: 15, tint: liked ? Theme.accent : nil
                ) {
                    localLibrary.toggleFavorite(track)
                }
                .frame(maxWidth: .infinity)
            }

            if player.isFMMode {
                circleButton(icon: "trash", size: 14) {
                    player.fmTrash()
                }
                .frame(maxWidth: .infinity)
            } else {
                circleButton(
                    icon: "shuffle", size: 14,
                    tint: player.shuffleEnabled ? Theme.accent : nil
                ) {
                    player.toggleShuffle()
                }
                .frame(maxWidth: .infinity)
                circleButton(icon: "backward.fill", size: 16) {
                    player.previous()
                }
                .frame(maxWidth: .infinity)
            }

            playPauseButton
                .frame(maxWidth: .infinity)

            circleButton(icon: "forward.fill", size: 16) {
                player.next()
            }
            .frame(maxWidth: .infinity)

            RoutePickerButton(diameter: 40, glyphSize: 15)
                .frame(maxWidth: .infinity)

            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 40, height: 40)
                    .frame(maxWidth: .infinity)
            } else {
                circleButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 14,
                    tint: player.repeatMode != .off ? Theme.accent : nil
                ) {
                    player.cycleRepeatMode()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }

    private func circleButton(icon: String, size: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            Color.clear.frame(height: geometry.size.height * 0.08)
                            ForEach(lyrics.lines) { line in
                                bigLyricLine(line, isActive: line.id == activeIndex)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: geometry.size.height * 0.78)
                        }
                        .padding(.horizontal, 24)
                    }
                    .accessibilityIdentifier("synchronizedLyricsScrollView")
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.12),
                                .init(color: .black, location: 0.85),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.18))
                        }
                    }
                    .onAppear {
                        // Start the active line near the top, matching the
                        // native lyrics reading position instead of centering
                        // it in a mostly empty viewport.
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.playbackKey) { _ in
                        activeIndex = nil
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { _ in
                                guard !isLyricsDragActive else { return }
                                isLyricsDragActive = true
                                if showLyricsOnMobile, lyricsControlsVisible {
                                    lyricsControlsTask?.cancel()
                                }
                                isUserScrolling = true
                                resumeTask?.cancel()
                            }
                            .onEnded { _ in
                                isLyricsDragActive = false
                                resumeTask?.cancel()
                                resumeTask = Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    isUserScrolling = false
                                }
                                if showLyricsOnMobile, lyricsControlsVisible {
                                    scheduleLyricsControlsAutoHide()
                                }
                            }
                    )
                }
            }
        } else if player.lyrics != nil, player.lyrics?.isInstrumental != true {
            VStack(spacing: 10) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text("暂无歌词")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            guard line.time.isFinite else { return }
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(
                        isActive ? .largeTitle : .title3,
                        design: .default,
                        weight: isActive ? .bold : .semibold
                    ),
                    verbatim: settings.verbatimLyrics
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: isActive ? 0 : 0.6)
            .scaleEffect(1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!line.time.isFinite)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isActive)
    }
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let font: Font
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45
    var rubySize: CGFloat = 20

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var renderingBudget = RenderingBudget.shared

    var body: some View {
        if settings.lyricsDisplayStyle == .amll {
            AMLLyricText(
                line: line,
                isActive: isActive,
                font: font,
                verbatim: verbatim,
                inactiveOpacity: inactiveOpacity
            )
        } else if settings.lyricsAnnotation == .furigana, let segments = line.furigana, !segments.isEmpty,
           isActive, verbatim, let words = line.words, !words.isEmpty {
            TimelineView(.animation(
                minimumInterval: renderingBudget.minimumAnimationInterval,
                paused: !RenderingBudget.permitsTimeDrivenLyricUpdates(
                    isPlaying: player.isPlaying,
                    isSceneActive: renderingBudget.isSceneActive
                )
            )) { _ in
                RubyText(
                    segments: segments,
                    size: rubySize,
                    weight: .bold,
                    color: .white,
                    alphas: karaokeAlphas(words, at: player.livePlaybackTime + settings.lyricsOffset)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if settings.lyricsAnnotation == .furigana, let segments = line.furigana, !segments.isEmpty {
            RubyText(
                segments: segments,
                size: rubySize,
                weight: isActive ? .bold : .semibold,
                color: .white.opacity(isActive ? 1 : inactiveOpacity)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isActive, verbatim, let words = line.words, !words.isEmpty {
            TimelineView(.animation(
                minimumInterval: renderingBudget.minimumAnimationInterval,
                paused: !RenderingBudget.permitsTimeDrivenLyricUpdates(
                    isPlaying: player.isPlaying,
                    isSceneActive: renderingBudget.isSceneActive
                )
            )) { _ in
                karaoke(words, at: player.livePlaybackTime + settings.lyricsOffset).font(font)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(font)
                .foregroundStyle(.white.opacity(isActive ? 1 : inactiveOpacity))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.72)
        }
    }

    /// One concatenated `Text` (so it wraps) with an estimated progressive
    /// fill inside each source-timed run. Run boundaries still come from source.
    private func karaoke(_ words: [LyricWord], at time: TimeInterval) -> Text {
        let unsung = 0.28
        var out = Text(verbatim: "")
        for word in words {
            let characters = Array(word.text)
            for (index, character) in characters.enumerated() {
                let fraction = word.characterProgress(
                    at: time,
                    characterIndex: index,
                    characterCount: characters.count
                )
                let alpha = unsung + (1 - unsung) * fraction
                out = out + Text(verbatim: String(character))
                    .foregroundColor(.white.opacity(alpha))
            }
        }
        return out
    }

    private func karaokeAlphas(_ words: [LyricWord], at time: TimeInterval) -> [Double] {
        let unsung = 0.28
        return words.flatMap { word in
            let count = word.text.count
            return (0..<count).map { index in
                let fraction = word.characterProgress(
                    at: time,
                    characterIndex: index,
                    characterCount: count
                )
                return unsung + (1 - unsung) * fraction
            }
        }
    }
}

/// Apple Music-like lyric rendering without depending on a private or
/// reverse-engineered implementation. It reuses the source-provided word
/// timings, keeps the full line visible underneath, and fills the sung words
/// over it in real time.
private struct AMLLyricText: View {
    let line: LyricLine
    let isActive: Bool
    let font: Font
    let verbatim: Bool
    let inactiveOpacity: Double

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var renderingBudget = RenderingBudget.shared

    var body: some View {
        Group {
            if isActive, verbatim, let words = line.words, !words.isEmpty {
                TimelineView(.animation(
                    minimumInterval: renderingBudget.minimumAnimationInterval,
                    paused: !RenderingBudget.permitsTimeDrivenLyricUpdates(
                        isPlaying: player.isPlaying,
                        isSceneActive: renderingBudget.isSceneActive
                    )
                )) { _ in
                    ZStack(alignment: .leading) {
                        Text(line.text)
                            .foregroundStyle(.white.opacity(0.28))
                        timedText(words, at: player.livePlaybackTime + settings.lyricsOffset)
                    }
                }
            } else {
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(.white.opacity(isActive ? 1 : inactiveOpacity))
            }
        }
        .font(font.weight(isActive ? .bold : .semibold))
        .minimumScaleFactor(0.64)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(isActive ? 1 : 0.94, anchor: .leading)
        .blur(radius: isActive ? 0 : 0.35)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: isActive)
    }

    /// Per-grapheme highlight is a visual interpolation inside each source
    /// run; exact boundaries remain those returned by the lyric provider.
    private func timedText(_ words: [LyricWord], at time: TimeInterval) -> Text {
        var output = Text(verbatim: "")
        for word in words {
            let characters = Array(word.text)
            for (index, character) in characters.enumerated() {
                let progress = word.characterProgress(
                    at: time,
                    characterIndex: index,
                    characterCount: characters.count
                )
                let opacity = 0.34 + 0.66 * progress
                output = output + Text(verbatim: String(character))
                    .foregroundColor(.white.opacity(opacity))
            }
        }
        return output
    }
}

private struct QualityPickerSheet: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.dismiss) private var dismiss
    @State private var available: [AudioQuality] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section("当前歌曲") {
                    Text(player.currentTrack?.name ?? "未播放歌曲")
                        .lineLimit(2)
                    Text("可用音质会随当前平台和音源变化")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let servedQuality = player.servedQuality, !servedQuality.isEmpty {
                        Label {
                            Text("实际返回音质：\(AudioQuality(lxType: servedQuality)?.sourceDisplayName ?? servedQuality)。如果音源不支持所选音质，已自动降级。")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    } else if player.currentTrack != nil, !player.isResolvingSource {
                        Label("当前音源未报告实际音质；选择项只表示请求档位。",
                              systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !available.isEmpty {
                    Section("选择音质") {
                        ForEach(available) { quality in
                            Button {
                                player.selectQuality(quality)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(quality.sourceDisplayName)
                                            .font(.body.weight(.medium))
                                        if quality.isPlatformSpecific {
                                            Text("由当前播放来源实时探测，最终以返回地址为准")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if player.currentQuality == quality {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                        }
                    }
                } else if !loading {
                    Section("选择音质") {
                        Text("当前播放来源没有返回可用音质，请检查账号状态或音源是否支持该平台。")
                            .foregroundStyle(.secondary)
                    }
                }

                if loading {
                    ProgressView("正在读取音源支持的音质")
                }

                Section {
                    Text("如果选定音质不可用，自动模式会先尝试账号能力，再回退到已启用的第三方音源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("播放音质")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            available = await player.availableQualitiesForCurrentTrack()
            loading = false
        }
    }
}

#if os(iOS)
private struct IOSImmersiveLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            Color.clear.frame(height: 72)
                            ForEach(lyrics.lines) { line in
                                lyricLine(line, isActive: line.id == activeIndex)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: 96)
                        }
                        .padding(.horizontal, 2)
                    }
                    .mask(edgeMask)
                    .accessibilityIdentifier("syncedLyricsScroll")
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onAppear {
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.playbackKey) { _ in
                        activeIndex = nil
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { _ in
                                guard !isUserScrolling else { return }
                                resumeTask?.cancel()
                                isUserScrolling = true
                            }
                            .onEnded { _ in
                                resumeTask?.cancel()
                                resumeTask = Task {
                                    try? await Task.sleep(for: .seconds(3))
                                    guard !Task.isCancelled else { return }
                                    isUserScrolling = false
                                }
                            }
                    )
                }
            } else if player.lyrics != nil, player.lyrics?.isInstrumental != true {
                VStack(spacing: 10) {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("暂无歌词")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if player.lyrics?.isInstrumental == true {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("纯音乐，请欣赏")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear {
            resumeTask?.cancel()
        }
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.18))
        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            guard line.time.isFinite else { return }
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: 27, weight: isActive ? .bold : .semibold),
                    verbatim: settings.verbatimLyrics
                )

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Keep the focused line at its natural width. Scaling a long
            // English line by 7% makes it clip at the phone edge.
            .scaleEffect(isActive ? 1.0 : 0.82, anchor: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!line.time.isFinite)
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
    }
}

// MARK: - Compact now-playing sections

private enum ImmersiveArtworkTransition {
    /// A time-based ease-out curve stays fluid at the display's native refresh rate.
    static let animation = Animation.timingCurve(
        0.16,
        1,
        0.3,
        1,
        duration: 0.42
    )
    static let compactArtworkDimension: CGFloat = 62
    static let compactHeaderSpacing: CGFloat = 13
    static let expandedMetadataOffset = -(
        compactArtworkDimension + compactHeaderSpacing
    )
}

private enum ImmersiveArtworkFrame: Hashable {
    case compact
    case expanded
}

private struct ImmersiveArtworkFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ImmersiveArtworkFrame: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ImmersiveArtworkFrame: Anchor<CGRect>],
        nextValue: () -> [ImmersiveArtworkFrame: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct CompactTrackHeader: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var localLibrary = LocalPlaylistStore.shared
    @EnvironmentObject private var settings: SettingsManager
    @State private var showAddToPlaylist = false
    @State private var showComments = false

    let showsExpandedArtwork: Bool

    var body: some View {
        HStack(spacing: ImmersiveArtworkTransition.compactHeaderSpacing) {
            Color.clear
                .frame(
                    width: ImmersiveArtworkTransition.compactArtworkDimension,
                    height: ImmersiveArtworkTransition.compactArtworkDimension
                )
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.compact: $0] }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                Text(player.currentTrack?.artistNames ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(
                x: showsExpandedArtwork
                    ? ImmersiveArtworkTransition.expandedMetadataOffset
                    : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersiveTrackMetadata")

            if let track = player.currentTrack {
                let liked = localLibrary.isFavorite(track)
                HStack(spacing: 0) {
                    Button {
                        localLibrary.toggleFavorite(track)
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(liked ? "取消收藏" : "收藏")
                    .accessibilityIdentifier("immersiveFavoriteButton")

                    Menu {
                        Button {
                            player.addToPlayNext(track)
                        } label: {
                            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label("加入歌单…", systemImage: "music.note.list")
                        }

                        Button {
                            showComments = true
                        } label: {
                            Label("查看评论", systemImage: "text.bubble")
                        }

                        SleepTimerMenu(player: player)

                        Divider()

                        Button {
                            Platform.copyToPasteboard(
                                string: "https://music.163.com/#/song?id=\(track.id)"
                            )
                            ToastCenter.shared.show(String(localized: "链接已复制"))
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("immersiveMoreMenu")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
        .contentShape(Rectangle())
        .sheet(isPresented: $showComments) {
            if let track = player.currentTrack {
                SongCommentsSheet(track: track)
            }
        }
    }
}

private struct CompactTransportControls: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        HStack(spacing: 0) {
            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
    }
}

private struct CompactVolumeControl: View {
#if os(iOS)
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            MPSystemVolumeSlider()
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("系统音量")
    }
#else
    @EnvironmentObject private var player: PlayerService
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            // One GeometryReader with the gesture on the ZStack. A nested
            // GeometryReader (the old TranslucentSliderTrack) silently dropped
            // the drag, so the volume slider did nothing (#37).
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.28))
                    Capsule().fill(.white.opacity(0.78))
                        .frame(width: width * fraction)
                }
                .frame(height: isDragging ? 10 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.x, width: width)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.x, width: width)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func updateVolume(at location: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        player.volume = Float(min(max(location / width, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment:
            player.volume = min(player.volume + step, 1)
        case .decrement:
            player.volume = max(player.volume - step, 0)
        @unknown default:
            break
        }
    }
#endif
}

#if os(iOS)
private struct MPSystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.tintColor = .white
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.28)
            slider.accessibilityLabel = "系统音量"
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif

private struct CompactSecondaryControls: View {
    let showsLyrics: Bool
    let showsQueue: Bool
    let onShowComments: () -> Void
    let onToggleLyrics: () -> Void
    let onToggleQueue: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            secondaryButton(
                icon: "text.bubble",
                label: "查看评论",
                action: onShowComments
            )

            secondaryButton(
                icon: showsLyrics && !showsQueue ? "quote.bubble.fill" : "quote.bubble",
                label: showsLyrics ? "显示封面" : "显示歌词",
                isActive: showsLyrics && !showsQueue
            ) { onToggleLyrics() }

            RoutePickerButton(diameter: 44, glyphSize: 17)
                .frame(maxWidth: .infinity)

            secondaryButton(
                icon: "list.bullet",
                label: showsQueue ? "关闭播放队列" : "显示播放队列",
                isActive: showsQueue
            ) { onToggleQueue() }
        }
    }

    private func secondaryButton(
        icon: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct CompactQueueContent: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                modeButton(
                    icon: "arrow.right",
                    label: "顺序播放",
                    isActive: !player.shuffleEnabled && player.repeatMode == .off,
                    action: enableSequentialPlayback
                )
                modeButton(
                    icon: "shuffle",
                    label: player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    isActive: player.shuffleEnabled,
                    action: player.toggleShuffle
                )
                modeButton(
                    icon: "repeat",
                    label: "列表循环",
                    isActive: player.repeatMode == .all
                ) {
                    player.repeatMode = player.repeatMode == .all ? .off : .all
                }
                modeButton(
                    icon: "repeat.1",
                    label: "单曲循环",
                    isActive: player.repeatMode == .one
                ) {
                    player.repeatMode = player.repeatMode == .one ? .off : .one
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(player.upcomingTracks.count) 首")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.46))
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .light))
                    Text("播放队列是空的")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(
                            Array(player.upcomingTracks.prefix(100).enumerated()),
                            id: \.offset
                        ) { index, track in
                            CompactQueueRow(track: track, upcomingIndex: index)
                        }
                    }
                }
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .padding(.top, 6)
    }

    private func modeButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.76) : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isActive ? AnyShapeStyle(.white.opacity(0.66)) : AnyShapeStyle(.white.opacity(0.1)),
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func enableSequentialPlayback() {
        if player.shuffleEnabled {
            player.toggleShuffle()
        }
        player.repeatMode = .off
    }
}

private struct CompactQueueRow: View {
    let track: Track
    let upcomingIndex: Int

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            player.jumpToUpcoming(at: upcomingIndex)
        } label: {
            HStack(spacing: 11) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(Formatters.duration(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.name)，\(track.artistNames)")
    }
}



private struct IOSMinimalLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    let onClose: () -> Void

    @State private var activeIndex: Int?
    @State private var selectedIndex: Int?
    @State private var nearestIndex: Int?
    @State private var lineCenters: [Int: CGFloat] = [:]
    @State private var isDragging = false
    @State private var suppressesAutoScroll = false
    @State private var pendingLyricSeekID: UUID?
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var selectionTimeoutTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let lyrics = player.lyrics, !lyrics.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: geometry.size.height / 2)
                                ForEach(lyrics.lines) { line in
                                    lyricLine(
                                        line,
                                        isActive: line.id == activeIndex,
                                        isSelected: line.id == selectedIndex,
                                        availableWidth: geometry.size.width
                                    ) {
                                        guard let selectedIndex else {
                                            closeLyrics()
                                            return
                                        }
                                        guard selectedIndex == line.id else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        guard line.time.isFinite else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        let seekID = UUID()
                                        pendingLyricSeekID = seekID
                                        suppressesAutoScroll = true
                                        player.seek(to: line.time) {
                                            guard pendingLyricSeekID == seekID else { return }
                                            pendingLyricSeekID = nil
                                            suppressesAutoScroll = false
                                        }
                                        activeIndex = line.id
                                        self.selectedIndex = nil
                                        nearestIndex = nil
                                    }
                                    .id(line.id)
                                    .background {
                                        GeometryReader { lineGeometry in
                                            Color.clear.preference(
                                                key: MinimalLyricCentersKey.self,
                                                value: [
                                                    line.id: lineGeometry.frame(
                                                        in: .named("immersiveLyrics")
                                                    ).midY
                                                ]
                                            )
                                        }
                                    }
                                }
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal, 2)
                        }
                        .coordinateSpace(name: "immersiveLyrics")
                        .mask(edgeMask)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeLyrics)
                        .accessibilityIdentifier("syncedLyricsScroll")
                        .onPreferenceChange(MinimalLyricCentersKey.self) { centers in
                            lineCenters = centers
                            guard isDragging || scrollSettleTask != nil else { return }
                            nearestIndex = nearestLine(
                                to: geometry.size.height / 2,
                                in: centers
                            )
                            guard !isDragging else { return }
                            scheduleScrollSelection(
                                guideY: geometry.size.height / 2,
                                proxy: proxy
                            )
                        }
                        .onAppear {
                            activeIndex = lyricsCursor.activeIndex
                            if let activeIndex {
                                Task { @MainActor in
                                    await Task.yield()
                                    proxy.scrollTo(activeIndex, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: lyricsCursor.activeIndex) { index in
                            guard index != activeIndex else { return }
                            activeIndex = index
                            guard !suppressesAutoScroll,
                                  !isDragging, scrollSettleTask == nil,
                                  selectedIndex == nil, let index else { return }
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38)) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        .onChange(of: player.currentTrack?.playbackKey) { _ in
                            activeIndex = nil
                            selectedIndex = nil
                            nearestIndex = nil
                            pendingLyricSeekID = nil
                            suppressesAutoScroll = false
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    if !isDragging {
                                        scrollSettleTask?.cancel()
                                        scrollSettleTask = nil
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        selectedIndex = nil
                                        isDragging = true
                                    }
                                    nearestIndex = nearestLine(
                                        to: geometry.size.height / 2,
                                        in: lineCenters
                                    )
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    scheduleScrollSelection(
                                        guideY: geometry.size.height / 2,
                                        proxy: proxy
                                    )
                                }
                        )
                        .overlay {
                            selectionGuide(lyrics: lyrics)
                        }
                    }
                } else if player.lyrics != nil, player.lyrics?.isInstrumental != true {
                    VStack(spacing: 10) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 32, weight: .light))
                            .foregroundStyle(.white.opacity(0.45))
                        Text("暂无歌词")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                } else if player.lyrics?.isInstrumental == true {
                    VStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeLyrics)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            selectionTimeoutTask?.cancel()
        }
    }

    @ViewBuilder
    private func selectionGuide(lyrics: ParsedLyrics) -> some View {
        let isScrolling = isDragging || scrollSettleTask != nil
        if let index = isScrolling ? nearestIndex : selectedIndex,
           lyrics.lines.indices.contains(index) {
            HStack(spacing: 8) {
                if isScrolling {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    }
                    .frame(height: 1)
                } else {
                    Spacer()
                }

                Text(Formatters.duration(lyrics.lines[index].time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: 25)
            }
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
        }
    }

    private func nearestLine(to guideY: CGFloat, in centers: [Int: CGFloat]) -> Int? {
        centers.min { abs($0.value - guideY) < abs($1.value - guideY) }?.key
    }

    private func scheduleScrollSelection(guideY: CGFloat, proxy: ScrollViewProxy) {
        scrollSettleTask?.cancel()
        // ponytail: iOS 16 has no scroll phase API; replace with onScrollPhaseChange
        // when the deployment target reaches iOS 18.
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let selection = nearestLine(to: guideY, in: lineCenters) ?? nearestIndex
            selectedIndex = selection
            nearestIndex = selection
            scrollSettleTask = nil
            guard let selection else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                proxy.scrollTo(selection, anchor: .center)
            }
            scheduleSelectionTimeout(proxy: proxy)
        }
    }

    private func scheduleSelectionTimeout(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, selectedIndex != nil else { return }
            returnToActiveLine(proxy: proxy)
        }
    }

    private func returnToActiveLine(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        guard let activeIndex else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func closeLyrics() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        isDragging = false
        onClose()
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: LyricLine,
        isActive: Bool,
        isSelected: Bool,
        availableWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1 : 12.0 / 13.0, anchor: .leading)
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    font: .system(size: 17, weight: .bold),
                    verbatim: settings.verbatimLyrics
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(isActive ? 1 : 16.0 / 17.0, anchor: .leading)

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1 : 12.0 / 13.0, anchor: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .padding(.trailing, 0)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isActive)
        .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

private struct MinimalLyricCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - Minimal track info row

private struct MinimalTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var localLibrary = LocalPlaylistStore.shared
    @State private var showAddToPlaylist = false
    @State private var airPlayRequest = 0
    var metadataOnly = false
    var actionsOnly = false

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        moreMenu(for: track)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        favoriteButton(for: track)
                        moreMenu(for: track)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            Text(player.currentTrack?.artistNames ?? "")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private func favoriteButton(for track: Track) -> some View {
        let liked = localLibrary.isFavorite(track)
        return Button {
            localLibrary.toggleFavorite(track)
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(liked ? Theme.accent : .white.opacity(0.88))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(liked ? "取消收藏" : "收藏")
        .accessibilityIdentifier("immersiveFavoriteButton")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            Button {
                airPlayRequest += 1
            } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }

            Button {
                player.addToPlayNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button {
                        player.playbackRate = Float(rate)
                    } label: {
                        HStack {
                            Text("\(rate)×")
                            if abs(Double(player.playbackRate) - rate) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("播放速度", systemImage: "speedometer")
            }

            SleepTimerMenu(player: player)

            Divider()

            Button {
                Platform.copyToPasteboard(
                    string: "https://music.163.com/#/song?id=\(track.id)"
                )
                ToastCenter.shared.show(String(localized: "链接已复制"))
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("immersiveMoreMenu")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }
}

private struct MinimalTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors
    @Binding var showQueue: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("播放列表")
            .accessibilityIdentifier("immersivePlaylistButton")
                .frame(maxWidth: .infinity)

            Button(action: player.isFMMode ? player.fmTrash : player.previous) {
                Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 38, weight: .bold))
                    .contentTransition(.opacity)
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button(action: player.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .accessibilityLabel("下一首")

            playbackModeButton
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .sheet(isPresented: $showQueue) {
            queueSheet
        }
    }

    @ViewBuilder
    private var queueSheet: some View {
        if #available(iOS 16.4, *) {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
                .presentationBackgroundInteraction(.enabled)
        } else {
            MinimalQueueSheet(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
        }
    }

    @ViewBuilder
    private var playbackModeButton: some View {
        if player.isFMMode {
            Color.clear
                .frame(height: 44)
        } else {
            Menu {
                ForEach(PlaybackMode.allCases) { mode in
                    Button {
                        player.setPlaybackMode(mode)
                    } label: {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            } label: {
                Image(systemName: playbackModeIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(playbackModeTint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackModeLabel)
        }
    }

    private var playbackModeIcon: String {
        player.playbackMode.icon
    }

    private var playbackModeTint: Color {
        player.playbackMode == .sequential ? .white.opacity(0.88) : Theme.accent
    }

    private var playbackModeLabel: String {
        player.playbackMode.title
    }
}

private struct MinimalQueueSheet: View {
    @EnvironmentObject private var player: PlayerService
    let backdrop: ArtworkColors

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    if let current = player.currentTrack {
                        MinimalQueueSectionLabel("正在播放")
                        MinimalQueueRow(track: current, upcomingIndex: nil, isCurrent: true)

                        if !player.upcomingTracks.isEmpty {
                            MinimalQueueSectionLabel("即将播放")
                                .padding(.top, 10)
                            ForEach(
                                Array(player.upcomingTracks.prefix(100).enumerated()),
                                id: \.offset
                            ) { index, track in
                                MinimalQueueRow(
                                    track: track,
                                    upcomingIndex: index,
                                    isCurrent: false
                                )
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 28, weight: .light))
                            Text("播放队列是空的")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 240)
                    }
                }
                .padding(10)
            }
            .navigationTitle("播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(player.upcomingTracks.count + (player.hasCurrentTrack ? 1 : 0)) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // This queue panel has a dark artwork backdrop, so keep its semantic
        // primary/secondary row labels light even when the app uses Light mode.
        .preferredColorScheme(.dark)
        .background(queueBackdrop)
    }

    private var queueBackdrop: some View {
        ZStack {
            LinearGradient(
                colors: [backdrop.primary, backdrop.secondary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

private struct MinimalQueueSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

private struct MinimalQueueRow: View {
    let track: Track
    let upcomingIndex: Int?
    let isCurrent: Bool

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            guard !isCurrent else { return }
            if let upcomingIndex {
                player.jumpToUpcoming(at: upcomingIndex)
            } else {
                player.jumpTo(track)
            }
        } label: {
            HStack(spacing: 10) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : .primary)
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isCurrent {
                    PlayingIndicator(animating: player.isPlaying)
                } else {
                    Text(Formatters.duration(track.duration))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif


// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var renderingBudget = RenderingBudget.shared
    let onShowQuality: (() -> Void)?
    let showsRemainingTime: Bool

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    init(onShowQuality: (() -> Void)? = nil, showsRemainingTime: Bool = false) {
        self.onShowQuality = onShowQuality
        self.showsRemainingTime = showsRemainingTime
    }

    private func fraction(at playbackPosition: TimeInterval) -> Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : playbackPosition
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        TimelineView(.animation(
            minimumInterval: renderingBudget.minimumAnimationInterval,
            paused: !RenderingBudget.permitsTimeDrivenLyricUpdates(
                isPlaying: player.isPlaying,
                isSceneActive: renderingBudget.isSceneActive
            )
        )) { _ in
            scrubberContent(position: PlaybackPositionPolicy.displayPosition(
                isPlaying: player.isPlaying,
                livePosition: player.livePlaybackTime,
                publishedPosition: clock.progress
            ))
        }
    }

    private func scrubberContent(position: TimeInterval) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                let progress = fraction(at: position)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    Capsule()
                        .fill(.white)
                        .frame(width: max(4, width * progress), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * progress - thumbDiameter / 2)
                        .opacity(isHovering || isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0, width > 0 else { return }
                            isDragging = true
                            player.isScrubbing = true
                            dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                        }
                        .onEnded { _ in
                            player.seek(to: dragProgress)
                            isDragging = false
                            player.isScrubbing = false
                        }
                )
            }
            .frame(height: 14)
            .onHover { hovering in
                withAnimation(AppAnimation.quick) { isHovering = hovering }
            }

            HStack(alignment: .center, spacing: 8) {
                Text(Formatters.duration(isDragging ? dragProgress : position))
                Spacer()
                if let onShowQuality {
                    Button(action: onShowQuality) {
                        Label(qualityDisplayName, systemImage: "waveform")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择播放音质，当前为\(qualityDisplayName)")
                }
                Spacer()
                Text(showsRemainingTime
                     ? "−\(Formatters.duration(max(player.duration - (isDragging ? dragProgress : position), 0)))"
                     : Formatters.duration(player.duration))
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 13 : (isHovering ? 11 : 9)
    }

    private var qualityDisplayName: String {
        if let served = player.servedQuality {
            return AudioQuality(lxType: served)?.sourceDisplayName ?? served.uppercased()
        }
        if player.isResolvingSource { return "检测中" }
        return player.currentTrack == nil ? "未播放" : "音质未知"
    }
}

// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current?.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Group {
            if let line, !line.text.isEmpty {
                // The compact player used to render plain Text here, so long
                // pressing to switch Apple Music/AMLL style only changed the
                // full lyrics page. Reuse the same renderer in every player
                // surface.
                LyricMainText(
                    line: line,
                    isActive: emphasized,
                    font: .system(size: emphasized ? 17 : 14,
                                   weight: emphasized ? .bold : .medium),
                    verbatim: settings.verbatimLyrics,
                    inactiveOpacity: 0.45,
                    rubySize: 13
                )
            } else {
                Text(" ")
                    .font(.system(size: emphasized ? 17 : 14,
                                  weight: emphasized ? .bold : .medium))
                    .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            }
        }
        .font(.system(size: emphasized ? 17 : 14,
                      weight: emphasized ? .bold : .medium))
        .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .id(line?.id)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
