import SwiftUI
#if os(iOS)
import AVFoundation
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
    /// Cover URL `artworkImage` was loaded from, to skip redundant reloads.
    @State private var artworkSourceKey: String?
    @State private var artworkPalette: ArtworkPaletteTransition
    @State private var activeIndex: Int?
    @State private var lyricLineFrames = LyricLineFrameStore()
    /// Lyric scroll viewport, in the "lyricsPage" coordinate space.
    @State private var lyricViewportFrame: CGRect = .zero
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
    /// Lyric size: 34pt at the default text size, following Dynamic Type.
    @ScaledMetric(relativeTo: .largeTitle) private var lyricFontSize: CGFloat = 34
    /// Shared space for the cover moving between song page and lyric header.
    @Namespace private var playerPageNamespace
    private static let artworkGeometryID = "nowPlayingArtwork"
    /// Tap counters that drive the transport animations and haptics, so
    /// remote commands and track ends never buzz the phone.
    @State private var skipForwardTrigger = 0
    @State private var skipBackTrigger = 0
    @State private var playPauseTrigger = 0
    /// Live finger offset of the song ⇄ lyrics page swipe.
    @State private var pageSwipeOffset: CGFloat = 0
    #if os(iOS)
    @State private var showQueueOnMobile = false
    @State private var showQueueSheet = false
    #endif

    /// Seed artwork and palette synchronously from memory so the very first
    /// frame of the open animation already shows the real cover and colour,
    /// instead of a grey placeholder that fades in.
    init() {
        let player = PlayerService.shared
        var seededImage: PlatformImage?
        var seededColors: ArtworkColors?
        if let picURL = player.currentTrack?.album.picUrl,
           let url = picURL.resizedImageURL(768),
           let image = ImageCache.shared.cachedImage(for: url) {
            seededImage = image
            seededColors = ArtworkPalette.extract(from: image, cacheKey: picURL)
        }
        #if os(iOS)
        let tint = NowPlayingTint.shared
        if seededColors == nil, tint.playbackKey != nil,
           tint.playbackKey == player.currentTrack?.playbackKey {
            seededColors = tint.colors
        }
        #endif
        _artworkImage = State(initialValue: seededImage)
        _artworkSourceKey = State(initialValue: seededImage == nil ? nil : player.currentTrack?.album.picUrl)
        _artworkPalette = State(initialValue: ArtworkPaletteTransition(colors: seededColors ?? .fallback))
    }

    var body: some View {
        ZStack {
            // Make the full-bleed artwork part of the destination's root,
            // rather than overflow drawn by a safe-area-sized geometry reader.
            // Only the controls measure the safe area below.
            backdrop

            GeometryReader { geo in
                let isCompact = geo.size.width < 720
                let phoneLandscape = isPhoneLandscape(size: geo.size)
                Group {
                    if phoneLandscape {
                        phoneLandscapeLayout(size: geo.size)
                    } else if isCompact {
                        compactLayout(size: geo.size)
                    } else {
                        regularLayout(size: geo.size)
                    }
                }
                // An intrinsically-wide child must not stretch the controls
                // and push them off-screen.
                .frame(width: geo.size.width, height: geo.size.height)
            }
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
        .onDisappear {
            lyricsControlsTask?.cancel()
            resumeTask?.cancel()
        }
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
            proxy.scrollTo(index, anchor: Self.lyricReadingAnchor)
        }
    }

    /// The sung line rests about a fifth of the way down the lyric viewport.
    private static let lyricReadingAnchor = UnitPoint(x: 0.5, y: 0.18)
    /// Subtle emphasis on the sung line; larger values clip long lines.
    static let activeLyricScale: CGFloat = 1.06

    /// Move the sung line into reading position. The short spring settles in
    /// well under a line's length, so the view never trails the audio; the
    /// previous 0.8s response could still be moving when the next line began.
    private func scrollToLyric(_ index: Int, proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(index, anchor: Self.lyricReadingAnchor)
        } else {
            withAnimation(NowPlayingMotion.lyricScroll) {
                proxy.scrollTo(index, anchor: Self.lyricReadingAnchor)
            }
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
#if os(iOS)
        artworkBackdrop
            .overlay {
                // Keep the artwork tone visible to the bottom edge. Darken
                // gently for legibility instead of fading to an opaque band.
                LinearGradient(
                    colors: [.black.opacity(0.06), .clear, .black.opacity(0.30)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .background(.black)
            // Rounded while the player is pulled down (0pt at rest). The clip
            // must come before `ignoresSafeArea`: applied after it, the clip
            // keeps the safe-area frame and cuts the backdrop off under the
            // status bar and above the home indicator, showing the app behind.
            .modifier(PlayerCardClip())
            .ignoresSafeArea()
#else
        artworkBackdrop.ignoresSafeArea()
#endif
    }

    private var artworkBackdrop: some View {
        // Energy: the drifting blobs move ~2pt/s, so they need only 4 fps; the
        // full rate is kept for the 0.8s palette cross-fade. Paused playback
        // freezes the backdrop entirely (it previously kept redrawing two
        // full-screen blurs at 24 fps even when nothing played).
        TimelineView(.animation(
            minimumInterval: artworkPalette.isTransitioning
                ? renderingBudget.minimumAnimationInterval
                : max(renderingBudget.minimumAnimationInterval, 0.25),
            paused: reduceMotion
                || !renderingBudget.isSceneActive
                || !renderingBudget.allowsContinuousEffects
                || (!player.isPlaying && !artworkPalette.isTransitioning)
        )) { _ in
            let uptime = ProcessInfo.processInfo.systemUptime
            let palette = artworkPalette.displayedColors(at: uptime)
            let motion = reduceMotion || !renderingBudget.allowsContinuousEffects ? 0.0 : uptime
            GeometryReader { geometry in
                ZStack {
                    artworkGradient(for: palette)
                    Circle()
                        .fill(palette.primary.opacity(0.46))
                        .frame(width: geometry.size.width * 1.15)
                        .blur(radius: 78)
                        .offset(
                            x: -geometry.size.width * 0.24 + CGFloat(sin(motion * 0.18)) * 10,
                            y: -geometry.size.height * 0.22 + CGFloat(cos(motion * 0.14)) * 8
                        )
                    Circle()
                        .fill(palette.secondary.opacity(0.44))
                        .frame(width: geometry.size.width * 0.98)
                        .blur(radius: 92)
                        .offset(
                            x: geometry.size.width * 0.26 + CGFloat(cos(motion * 0.16)) * 12,
                            y: geometry.size.height * 0.08 + CGFloat(sin(motion * 0.12)) * 10
                        )
                    LinearGradient(
                        colors: [.black.opacity(0.04), .clear, .black.opacity(0.22)],
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
                .init(color: palette.primary.opacity(0.94), location: 0.38),
                .init(color: palette.secondary.opacity(0.96), location: 0.82),
                .init(color: palette.secondary.opacity(0.88), location: 1),
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
        #if os(iOS)
        NowPlayingTint.shared.update(next, for: player.currentTrack?.playbackKey)
        #endif
    }

    private func loadArtwork() async {
        guard !Task.isCancelled else { return }
        // Keep the artwork seeded by `init` when it already belongs to this
        // track; clearing it first flashed the placeholder on every open.
        if artworkImage != nil,
           artworkSourceKey == player.currentTrack?.album.picUrl,
           artworkSourceKey != nil {
            #if os(iOS)
            NowPlayingTint.shared.update(artworkPalette.colors, for: player.currentTrack?.playbackKey)
            #endif
            return
        }
        // The previous cover stays until the new one is ready, then the two
        // cross-fade. Clearing it here flashed an empty placeholder between
        // songs, which read as a stutter.
        guard let track = player.currentTrack else {
            setArtwork(nil)
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
            setArtwork(nil)
            transitionArtworkPalette(to: .fallback)
            return
        }
        let cachedImage = await ImageCache.shared.image(for: url)
        guard !Task.isCancelled, player.currentTrack?.playbackKey == playbackKey else { return }
        if let image = cachedImage {
            #if os(iOS)
            // Decode off the main thread before display. A lazily decoded
            // 768px cover was decoded during the first animation frame, which
            // is the hitch felt on song changes at 120 Hz.
            let prepared = await image.byPreparingForDisplay() ?? image
            guard !Task.isCancelled, player.currentTrack?.playbackKey == playbackKey else { return }
            setArtwork(prepared)
            #else
            setArtwork(image)
            #endif
            artworkSourceKey = urlString
            transitionArtworkPalette(to: ArtworkPalette.extract(from: image, cacheKey: urlString))
        } else {
            guard player.currentTrack?.playbackKey == playbackKey else { return }
            setArtwork(nil)
            transitionArtworkPalette(to: .fallback)
        }
    }

    /// Swap the cover with a cross-fade (instant under Reduce Motion).
    private func setArtwork(_ image: PlatformImage?) {
        if image == nil { artworkSourceKey = nil }
        guard image !== artworkImage else { return }
        if reduceMotion {
            artworkImage = image
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { artworkImage = image }
        }
    }

    // MARK: - Layouts

    @ViewBuilder
    private func phoneLandscapeLayout(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if showLyricsOnMobile {
                    appleMusicLyricsPage()
                        .padding(.bottom, 54)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("appleMusicLyricsPage")
                } else {
                    let artworkSize = max(0, min(size.height - 124, 240))
                    HStack(spacing: 28) {
                        artworkView(size: artworkSize)

                        VStack(spacing: 8) {
                            Spacer(minLength: 0)
                            trackMetaView
                                .padding(.bottom, 8)
                            NowPlayingScrubber(showsRemainingTime: true)
                            primaryTransportControls
                            CompactVolumeControl()
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: 420)
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 36)
                    .padding(.bottom, 54)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("appleMusicSongPage")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            songPageAccessoryControls
                .frame(maxWidth: 360)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .padding(.bottom, 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("nowPlayingAccessoryControls")
        }
    }

    private func regularLayout(size: CGSize) -> some View {
        let artworkSize = max(120, min(340, size.width * 0.48, size.height - 300))
        return Group {
            if showLyricsOnMobile {
                appleMusicLyricsPage()
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
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
        // The deck keeps one fixed screen position whenever it is shown. On
        // the lyrics page it hides completely (accessory row included) so the
        // lyrics run full screen, as in the system player; tapping the lower
        // part of the page brings it back.
        let controlsHeight: CGFloat = 228
        let deckVisible = !showLyricsOnMobile || lyricsControlsVisible
        // Artwork takes the space left after the title row and deck, with the
        // same side margins as the controls (Apple's player keeps them equal).
        // Non-artwork content on the song page: top inset, spacers, the gap
        // below the artwork and the title row.
        let songPageChrome: CGFloat = isShortScreen ? 130 : 170
        let artworkSize = max(0, min(
            size.width - 52,
            size.height - controlsHeight - songPageChrome,
            400
        ))

        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                Group {
                    if showLyricsOnMobile {
                        appleMusicLyricsPage(revealRegionHeight: controlsHeight)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("appleMusicLyricsPage")
                    } else {
                        VStack(spacing: 0) {
                            Spacer(minLength: isShortScreen ? 12 : 20)

                            artworkView(size: artworkSize, matched: true)
                                // The cover glides into the lyric header
                                // thumbnail when switching pages.
                                // Paused artwork recedes slightly, like the
                                // system player; reduce motion skips the scale.
                                .scaleEffect(player.isPlaying || reduceMotion ? 1 : 0.8)
                                // Grows back with a slight overshoot, recedes
                                // without one, as the system player does.
                                .animation(
                                    reduceMotion ? nil
                                        : (player.isPlaying ? NowPlayingMotion.artworkPlay : NowPlayingMotion.artworkPause),
                                    value: player.isPlaying
                                )
                                .padding(.bottom, isShortScreen ? 22 : 34)

                            trackMetaView

                            Spacer(minLength: isShortScreen ? 8 : 16)
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, isShortScreen ? 24 : 34)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("appleMusicSongPage")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(pageSwipe(width: size.width))

                // Reserve the deck's footprint only while it is shown, so
                // hidden controls give the whole page back to the lyrics.
                if deckVisible {
                    Color.clear
                        .frame(height: controlsHeight)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if deckVisible {
                // A short rise with a fade (not a full slide from the screen
                // edge), so the deck appears to surface from below the lyrics.
                appleMusicPlaybackControls(height: controlsHeight)
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: 28).combined(with: .opacity),
                            removal: .offset(y: 18).combined(with: .opacity)
                        )
                    )
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NowPlayingMotion.page, value: showLyricsOnMobile)
    }

    /// Horizontal page swipe between song page and lyrics, besides the
    /// lyrics button: left shows lyrics, right returns to the song page.
    private func pageSwipe(width: CGFloat) -> PlayerPageSwipe {
        PlayerPageSwipe(
            showsLyrics: showLyricsOnMobile,
            pageWidth: width,
            reduceMotion: reduceMotion,
            offset: $pageSwipeOffset
        ) { showLyrics in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : NowPlayingMotion.page) {
                showLyricsOnMobile = showLyrics
                isUserScrolling = false
                resumeTask?.cancel()
            }
        }
    }

    private static let deckAccessoryHeight: CGFloat = 44
    private static let deckVerticalPadding: CGFloat = 8
    private static let deckRowSpacing: CGFloat = 4

    private func appleMusicPlaybackControls(height: CGFloat) -> some View {
        let playbackControlsHeight: CGFloat = 164

        return ZStack(alignment: .bottom) {
            VStack(spacing: Self.deckRowSpacing) {
                VStack(spacing: 4) {
                    NowPlayingScrubber(
                        onShowQuality: { showQualityPicker = true },
                        showsRemainingTime: true,
                        onSeek: {
                            guard showLyricsOnMobile else { return }
                            isUserScrolling = false
                            resumeTask?.cancel()
                            resumeTask = nil
                        }
                    )
                    .frame(height: 64)

                    primaryTransportControls
                        .frame(height: 64)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(
                            showLyricsOnMobile ? "lyricsTransportControls" : "nowPlayingTransportControls"
                        )

                    CompactVolumeControl()
                        .frame(height: 28)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(
                            showLyricsOnMobile ? "lyricsVolumeControl" : "nowPlayingVolumeControl"
                        )
                }
                .frame(height: playbackControlsHeight)
                .simultaneousGesture(TapGesture().onEnded {
                    if showLyricsOnMobile { scheduleLyricsControlsAutoHide() }
                })
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { _ in
                        guard showLyricsOnMobile else { return }
                        lyricsControlsTask?.cancel()
                        // Scrubbing must leave lyric-browse mode so the cursor can
                        // immediately scroll to the line at the new playback time.
                        if isUserScrolling {
                            isUserScrolling = false
                            resumeTask?.cancel()
                        }
                    }
                    .onEnded { _ in
                        if showLyricsOnMobile { scheduleLyricsControlsAutoHide() }
                    })

                songPageAccessoryControls
                    .frame(height: Self.deckAccessoryHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("nowPlayingAccessoryControls")
            }
            .padding(.vertical, Self.deckVerticalPadding)
            .frame(maxWidth: 460)
            .padding(.horizontal, 26)
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .bottom)
        }
        .frame(height: height, alignment: .bottom)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nowPlayingBottomControls")
    }

    /// - Parameter revealRegionHeight: height of the bottom band that brings
    ///   hidden controls back (the deck's footprint). Nil where the controls
    ///   never auto-hide (landscape keeps its accessory row).
    private func appleMusicLyricsPage(revealRegionHeight: CGFloat? = nil) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Distinct identifier: during the page change both covers
                    // briefly coexist, and UI tests address the hero cover.
                    artworkView(size: 56, matched: true, identifier: "lyricsHeaderArtwork")
                    trackMeta(compact: true)
                }
                .padding(.bottom, 14)

                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Same side margin as the playback deck so lyrics, header and
            // controls share one leading edge.
            .padding(.horizontal, 26)
            .padding(.top, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .coordinateSpace(name: "lyricsPage")
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("显示播放控制")) { revealLyricsControls() }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("lyricsPage"))
                .onEnded { value in
                    // While controls are hidden, a tap in the lower band (where
                    // the deck appears) reveals them instead of seeking.
                    if let revealRegionHeight,
                       NowPlayingPresentationMetrics.isLyricsControlsRevealTap(
                           locationY: value.location.y,
                           pageHeight: geometry.size.height,
                           revealRegionHeight: revealRegionHeight,
                           controlsVisible: lyricsControlsVisible
                       ) {
                        revealLyricsControls()
                        return
                    }
                    // Otherwise a tapped line seeks to its timestamp. Only taps
                    // inside the lyric viewport count; the header never seeks.
                    guard lyricViewportFrame.contains(value.location),
                          let id = lyricLineFrames.frames.first(where: { $0.value.contains(value.location) })?.key,
                          let line = player.lyrics?.lines.first(where: { $0.id == id }),
                          line.time.isFinite else { return }
                    resumeTask?.cancel()
                    isUserScrolling = false
                    player.seek(to: line.time)
                    if lyricsControlsVisible { scheduleLyricsControlsAutoHide() }
                })
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : NowPlayingMotion.page, value: lyricsControlsVisible)
    }

    private func revealLyricsControls() {
        guard showLyricsOnMobile else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : NowPlayingMotion.page) {
            lyricsControlsVisible = true
        }
        scheduleLyricsControlsAutoHide()
    }

    private func scheduleLyricsControlsAutoHide() {
        lyricsControlsTask?.cancel()
        lyricsControlsTask = Task { @MainActor in
            try? await Task.sleep(
                for: NowPlayingPresentationMetrics.lyricsControlsAutoHideDelay(
                    arguments: CommandLine.arguments
                )
            )
            guard !Task.isCancelled, showLyricsOnMobile, !isLyricsDragActive else { return }
            #if os(iOS)
            // VoiceOver users cannot find a hidden deck by tapping blind; keep
            // it visible for them.
            guard !UIAccessibility.isVoiceOverRunning else { return }
            #endif
            // Hiding is slower and calmer than revealing.
            withAnimation(reduceMotion ? .easeInOut(duration: 0.25)
                          : .spring(response: 0.7, dampingFraction: 0.95)) {
                lyricsControlsVisible = false
            }
        }
    }

    private var songPageAccessoryControls: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : NowPlayingMotion.page) {
                    showLyricsOnMobile.toggle()
                    isUserScrolling = false
                    resumeTask?.cancel()
                }
            } label: {
                accessoryGlyph(showLyricsOnMobile ? "quote.bubble.fill" : "quote.bubble",
                               isActive: showLyricsOnMobile)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(showLyricsOnMobile ? "返回歌曲页" : "显示同步歌词")
            .accessibilityAddTraits(showLyricsOnMobile ? .isSelected : [])
            .accessibilityIdentifier("showSynchronizedLyrics")

            // The output picker is a plain glyph like its neighbours; a filled
            // circle made it read as a different kind of control.
            RoutePickerButton(diameter: 44, glyphSize: 20, background: .clear)
                .frame(maxWidth: .infinity)

            if hasLyricTranslation {
                Button {
                    settings.showLyricsTranslation.toggle()
                } label: {
                    accessoryGlyph(settings.showLyricsTranslation ? "character.bubble.fill" : "character.bubble",
                                   isActive: settings.showLyricsTranslation)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(settings.showLyricsTranslation ? "隐藏歌词翻译" : "显示歌词翻译")
                .accessibilityAddTraits(settings.showLyricsTranslation ? .isSelected : [])
            }

            #if os(iOS)
            Button { showQueueSheet = true } label: {
                accessoryGlyph("list.bullet", isActive: false)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("播放队列")
            #endif
        }
        .frame(maxWidth: 360)
    }

    /// Active accessory toggles get a subtle rounded highlight rather than a
    /// colour change, so the row stays monochrome over any artwork palette.
    private func accessoryGlyph(_ systemName: String, isActive: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.78))
            .frame(width: 40, height: 34)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.white.opacity(0.18))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var hasLyricTranslation: Bool {
        player.lyrics?.lines.contains { line in
            guard let translation = line.translation else { return false }
            return !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } == true
    }

    private var primaryTransportControls: some View {
        HStack(spacing: 0) {
            // Music uses the double-triangle skip glyphs; the bar-ended
            // `.end` variants read as "jump to start/end" instead.
            Button {
                skipBackTrigger += 1
                if player.isFMMode { player.fmTrash() } else { player.previous() }
            } label: {
                Image(systemName: player.isFMMode ? "hand.thumbsdown.fill" : "backward.fill")
                    .font(.system(size: player.isFMMode ? 26 : 32, weight: .regular))
                    .modifier(SkipNudge(trigger: skipBackTrigger, direction: -1, enabled: !reduceMotion))
                    .frame(width: 72, height: 64)
                    // Highlight is drawn around the glyph; the tap area still
                    // spans the whole third of the row.
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")

            playPauseButton
                .frame(maxWidth: .infinity)

            Button {
                skipForwardTrigger += 1
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32, weight: .regular))
                    .modifier(SkipNudge(trigger: skipForwardTrigger, direction: 1, enabled: !reduceMotion))
                    .frame(width: 72, height: 64)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("下一首")
        }
        .foregroundStyle(.white)
        .buttonStyle(.playerTransport)
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.impact(weight: .light), trigger: skipForwardTrigger)
        .sensoryFeedback(.impact(weight: .light), trigger: skipBackTrigger)
    }


    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = max(0, min(size.width - 64, size.height * 0.38, 300))
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
        let artworkDim = max(0, min(size.width - 72, size.height * 0.43, 310))
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
        let artworkDimension = max(0, min(size.width - 112, size.height * 0.3, 250))
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
                including: showLyricsOnMobile || dismissNowPlayingDragAction == nil ? .none : .all
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

    /// - Parameter matched: tie this cover to the other page's cover, so it
    ///   glides and resizes between song page and lyric header.
    private func artworkView(
        size: CGFloat,
        matched: Bool = false,
        identifier: String = "nowPlayingArtworkImage"
    ) -> some View {
        // A flexible square canvas with the image as an overlay: the fill
        // image is cropped to the canvas, so non-square covers never spill
        // past the rounded clip while the frame animates.
        Color.clear
            .overlay {
                if let artworkImage {
                    // A new identity per image lets the swap cross-fade.
                    Image(platformImage: artworkImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .id(ObjectIdentifier(artworkImage))
                        // The new cover fades in over the old one, which stays
                        // opaque until removed: no mid-fade see-through dip.
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
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
            .clipped()
        // Radius and shadow scale with the artwork, so the 56pt lyric header
        // thumbnail does not get the same 18pt corners as the hero artwork.
        // Clip before the geometry match so the clip follows the moving frame.
        .clipShape(RoundedRectangle(cornerRadius: min(14, max(6, size * 0.045)), style: .continuous))
        // Shadow before the geometry match so it travels with the cover
        // between the two pages instead of waiting at the destination.
        .shadow(color: .black.opacity(size > 120 ? 0.32 : 0.2), radius: size > 120 ? 22 : 6, y: size > 120 ? 12 : 3)
        .modifier(MatchedArtwork(
            enabled: matched,
            id: Self.artworkGeometryID,
            namespace: playerPageNamespace
        ))
        .frame(width: size, height: size)
        .accessibilityLabel("专辑封面")
        .accessibilityIdentifier(identifier)
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

    private var trackMetaView: some View { trackMeta(compact: false) }

    /// Title row shared by the song page and the lyric header. The lyric
    /// header is a compact variant next to the 56pt thumbnail.
    private func trackMeta(compact: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(player.currentTrack?.name ?? "")
                    .font(compact ? Font.headline : Font.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                artistLink(compact: compact)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let track = player.currentTrack {
                let liked = localLibrary.isFavorite(track)
                Button {
                    localLibrary.toggleFavorite(track)
                } label: {
                    Image(systemName: liked ? "star.fill" : "star")
                        .font(.system(size: compact ? 15 : 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(liked ? 1 : 0.9))
                        // Fill/unfill morphs and the star bounces once.
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: liked)
                        .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                        .background { playerControlCircle }
                        .frame(width: 44, height: 44)
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
                        .font(.system(size: compact ? 15 : 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: compact ? 30 : 34, height: compact ? 30 : 34)
                        .background { playerControlCircle }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("更多操作")
            }
        }
        .frame(maxWidth: 460)
    }

    /// Artist name opens that artist's aggregate-search page. With several
    /// credited artists a menu lets the listener pick one, as in the system
    /// player.
    @ViewBuilder
    private func artistLink(compact: Bool) -> some View {
        let artists = (player.currentTrack?.artists ?? [])
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let label = Text(player.currentTrack?.artistNames ?? "")
            .font(compact ? Font.subheadline : Font.title3)
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        if artists.count > 1 {
            Menu {
                // LX artists often share id 0, so identify menu rows by index.
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    Button(artist.name) {
                        AppRouter.shared.openArtist(named: artist.name, avatarURL: artist.picUrl)
                    }
                }
            } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel("歌手：\(player.currentTrack?.artistNames ?? "")")
            .accessibilityHint("选择歌手并打开歌手页")
        } else if let artist = artists.first {
            Button {
                AppRouter.shared.openArtist(named: artist.name, avatarURL: artist.picUrl)
            } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel("歌手：\(artist.name)")
            .accessibilityHint("打开歌手页")
        } else {
            label
        }
    }

    /// Neutral translucent fill. Glass over a saturated artwork palette tints
    /// itself with that palette (the pink circles in red backdrops).
    private var playerControlCircle: some View {
        Circle().fill(.white.opacity(0.16))
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
                        icon: liked ? "star.fill" : "star",
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
            playPauseTrigger += 1
            player.togglePlayPause()
        } label: {
            // Symbol replace swaps pause ⇄ play with a scale-and-fade, and it
            // also animates when playback state changes from elsewhere.
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : PressMotion.release, value: player.isPlaying)
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerTransportButtonStyle(highlightDiameter: 84))
        .sensoryFeedback(.impact(weight: .light), trigger: playPauseTrigger)
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
                        LazyVStack(alignment: .leading, spacing: 24) {
                            Color.clear.frame(height: geometry.size.height * 0.06)
                            ForEach(lyrics.lines) { line in
                                bigLyricLine(line, isActive: line.id == activeIndex)
                                    .id(line.id)
                            }
                            Color.clear.frame(height: geometry.size.height * 0.78)
                        }
                        // The lyrics page already applies the shared side
                        // margin. The trailing room absorbs the sung line's
                        // 6% scale so long lines are not clipped.
                        .padding(.trailing, 24)
                    }
                    .coordinateSpace(name: "synchronizedLyrics")
                    .accessibilityIdentifier("synchronizedLyricsScrollView")
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named("lyricsPage"))
                    } action: { lyricViewportFrame = $0 }
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.08),
                                .init(color: .black, location: 0.86),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        scrollToLyric(index, proxy: proxy)
                    }
                    .onAppear {
                        // Start the active line near the top, matching the
                        // native lyrics reading position instead of centering
                        // it in a mostly empty viewport.
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.playbackKey) { _ in
                        activeIndex = nil
                        lyricLineFrames.frames.removeAll()
                    }
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard abs(value.translation.height) > abs(value.translation.width),
                                      !isLyricsDragActive else { return }
                                isLyricsDragActive = true
                                lyricsControlsTask?.cancel()
                                isUserScrolling = true
                                resumeTask?.cancel()
                            }
                            .onEnded { _ in
                                guard isLyricsDragActive else { return }
                                isLyricsDragActive = false
                                // Browsing ends on its own, like the system
                                // player: after a short pause the page glides
                                // back to the line that is being sung.
                                resumeTask?.cancel()
                                resumeTask = Task { @MainActor in
                                    try? await Task.sleep(for: NowPlayingPresentationMetrics.lyricsBrowseResumeDelay)
                                    guard !Task.isCancelled, !isLyricsDragActive else { return }
                                    isUserScrolling = false
                                    if let index = lyricsCursor.activeIndex {
                                        activeIndex = index
                                        scrollToLyric(index, proxy: proxy)
                                    }
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

    /// Depth-of-field like the system lyrics: every line except the sung one
    /// is blurred, more strongly the farther it is. Browsing clears the blur
    /// so the page can be read; Reduce Motion keeps the opacity cue only.
    /// The lines are static between line changes (the player no longer
    /// redraws per frame), so the blur is not re-rendered continuously.
    private func lyricBlurRadius(for lineID: Int, isActive: Bool) -> CGFloat {
        guard !isActive, !isUserScrolling, !reduceMotion else { return 0 }
        guard let activeIndex else { return 1.6 }
        let distance = CGFloat(abs(lineID - activeIndex))
        return min(1.0 + (distance - 1) * 0.8, 3.4)
    }

    /// Every line uses the same large bold style; the active line is set
    /// apart by opacity and sharpness only, so lines never reflow or jump in
    /// size as playback advances. Browsing (manual scroll) removes the blur
    /// so the whole page is readable.
    private func bigLyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                Text(romaji)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.9 : 0.34))
            }
            // Apple Music sets lyrics large (~34pt bold) and scales with
            // Dynamic Type; `lyricFontSize` tracks the user's text size.
            LyricMainText(
                line: line, isActive: isActive,
                font: .system(size: lyricFontSize, weight: .bold),
                inactiveOpacity: isUserScrolling ? 0.5 : 0.32,
                rubySize: lyricFontSize * 0.86,
                uniformWeight: true,
                inactiveScale: 1,
                inactiveBlur: 0
            )
            // The sung line's translation reads in near-white like the system
            // player's secondary lyric line; inactive ones stay muted.
            if settings.showLyricsTranslation, let translation = line.translation {
                Text(translation)
                    .font(.system(size: lyricFontSize * 0.62, weight: .semibold))
                    .foregroundStyle(.white.opacity(isActive ? 0.9 : 0.3))
            }
        }
        .multilineTextAlignment(.leading)
        // The sung line grows slightly from its leading edge. scaleEffect is
        // a render transform: neighbours never reflow, so the list stays still
        // while the emphasis moves.
        .scaleEffect(isActive ? Self.activeLyricScale : 1, anchor: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Frames go into a reference box, not @State: they change on every
        // scroll frame, and publishing them re-rendered the whole player.
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named("lyricsPage"))
        } action: { frame in
            lyricLineFrames.frames[line.id] = frame
        }
        .onDisappear { lyricLineFrames.frames[line.id] = nil }
        // One depth blur for the whole line (main text, romaji, translation).
        .blur(radius: lyricBlurRadius(for: line.id, isActive: isActive))
        // Soft spring with a touch of overshoot: the new line swells in while
        // the previous one relaxes, instead of a linear fade.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : NowPlayingMotion.lyricEmphasis, value: isActive)
        .animation(.easeOut(duration: 0.25), value: isUserScrolling)
    }
}

/// Follows the finger horizontally and decides on release whether to change
/// page. Only clearly horizontal drags count, so lyric scrolling, the
/// pull-down to close and taps are untouched. The wrong direction rubber
/// bands instead of moving freely.
private struct PlayerPageSwipe: ViewModifier {
    let showsLyrics: Bool
    let pageWidth: CGFloat
    let reduceMotion: Bool
    @Binding var offset: CGFloat
    let onCommit: (Bool) -> Void

    private enum Axis { case undecided, horizontal, rejected }

    /// Direction decided once per drag. `@GestureState` resets itself when a
    /// gesture is cancelled (rotation, track change, scroll take-over), so a
    /// stale "horizontal" lock can never leak into the next drag.
    @GestureState private var axis: Axis = .undecided
    /// The start-of-drag lock, kept for `onEnded` (gesture state has already
    /// reset by then).
    @State private var lockedHorizontal = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .offset(x: offset)
            .opacity(1 - min(abs(offset) / max(pageWidth, 1), 0.35))
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .updating($axis) { value, state, _ in
                        guard state == .undecided else { return }
                        let dx = abs(value.translation.width), dy = abs(value.translation.height)
                        state = dx > dy * 1.4 ? .horizontal : .rejected
                    }
                    .onChanged { value in
                        // Rewritten on every update, so each drag starts
                        // from its own lock and a cancelled one can't leak.
                        // The gesture state can trail by one update, so the
                        // first event applies the same rule itself.
                        let dx = value.translation.width
                        switch axis {
                        case .horizontal: lockedHorizontal = true
                        case .rejected: lockedHorizontal = false
                        case .undecided: lockedHorizontal = abs(dx) > abs(value.translation.height) * 1.4
                        }
                        guard lockedHorizontal, !reduceMotion else { return }
                        let toward = NowPlayingPresentationMetrics.pageSwipeAllowedDirection(showsLyrics: showsLyrics)
                        // Free movement toward the other page, resistance away.
                        offset = dx * toward > 0 ? dx * 0.55 : dx * 0.12
                    }
                    .onEnded { value in
                        // Only a drag that locked horizontal at its start may
                        // change page, however it ends.
                        let wasHorizontal = lockedHorizontal
                        lockedHorizontal = false
                        guard wasHorizontal, let target = NowPlayingPresentationMetrics.pageSwipeTarget(
                            translation: value.translation.width,
                            predictedTranslation: value.predictedEndTranslation.width,
                            showsLyrics: showsLyrics
                        ) else {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { offset = 0 }
                            return
                        }
                        // Drop the finger offset without animating it back
                        // toward the old side; the page change carries the
                        // motion from here.
                        var reset = Transaction()
                        reset.disablesAnimations = true
                        withTransaction(reset) { offset = 0 }
                        onCommit(target)
                    }
            )
            // A cancelled drag never reaches onEnded; settle the page anyway.
            .onChange(of: axis) { _, newValue in
                guard newValue == .undecided, offset != 0 else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { offset = 0 }
            }
            .onDisappear { offset = 0 }
    }
}

private struct MatchedArtwork: ViewModifier {
    let enabled: Bool
    let id: String
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

/// Skip glyph nudge: on each tap the arrows push ~10pt in their direction and
/// spring back, like the system player's forward/back buttons.
private struct SkipNudge: ViewModifier {
    let trigger: Int
    let direction: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                SpringKeyframe(10 * direction, duration: 0.12, spring: .snappy)
                SpringKeyframe(0, duration: 0.42, spring: .bouncy)
            }
        } else {
            content
        }
    }
}

/// Lyric line frames used only for tap hit-testing. Mutating it does not
/// invalidate any view.
private final class LyricLineFrameStore {
    var frames: [Int: CGRect] = [:]
}


/// Renders one complete timed lyric line. Word-level karaoke highlighting is
/// intentionally disabled throughout the player.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let font: Font
    var inactiveOpacity: Double = 0.45
    var rubySize: CGFloat = 20
    /// Keep every line bold so the active line changes emphasis by opacity
    /// alone, without the reflow a weight change causes.
    var uniformWeight = false
    var inactiveScale: CGFloat = 0.94
    var inactiveBlur: CGFloat = 0.35

    @EnvironmentObject private var settings: SettingsManager

    private var weight: Font.Weight {
        uniformWeight || isActive ? .bold : .semibold
    }

    var body: some View {
        Group {
            if settings.lyricsAnnotation == .furigana,
               let segments = line.furigana,
               !segments.isEmpty {
            RubyText(
                segments: segments,
                size: rubySize,
                weight: weight,
                color: .white.opacity(isActive ? 1 : inactiveOpacity)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(font)
                    .foregroundStyle(.white.opacity(isActive ? 1 : inactiveOpacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.72)
            }
        }
        .font(font.weight(weight))
        .minimumScaleFactor(0.64)
        .fixedSize(horizontal: false, vertical: true)
        .scaleEffect(isActive ? 1 : inactiveScale, anchor: .leading)
        // Skip the modifier when there is nothing to blur; a radius-0 blur
        // can still cost a render pass.
        .blur(radius: isActive || inactiveBlur == 0 ? 0 : inactiveBlur, opaque: false)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: isActive)
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
                        Label("当前请求：\(player.requestedQuality.flatMap { AudioQuality(lxType: $0)?.sourceDisplayName } ?? player.currentQuality.sourceDisplayName)。音源未提供实际音质信息。",
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
                        Text("当前音源没有返回可用音质，请检查音源是否支持该平台。")
                            .foregroundStyle(.secondary)
                    }
                }

                if loading {
                    ProgressView("正在读取音源支持的音质")
                }

                Section {
                    Text("如果选定音质不可用，会按已启用的第三方音源和可用档位回退。")
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
                        Image(systemName: liked ? "star.fill" : "star")
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
    @StateObject private var volume = SystemVolume()
    /// Resets itself when the drag is cancelled (dismissal, sheet,
    /// interruption), so the bar can never stay in its dragging state.
    @GestureState private var isTouching = false
    /// Level when a horizontal drag took hold; nil while no drag is active.
    @State private var dragStartLevel: Float?
    @State private var dragLevel: Float = 0

    private var isDragging: Bool { isTouching && dragStartLevel != nil }

    /// Thumbless bar drawn like the progress bar: one fill over one track,
    /// thickening while dragged. The restyled system slider stacked two
    /// translucent tracks under its thumb canvas, which showed as a lighter
    /// block beside the dot. Drags are relative, like the system bar: a touch
    /// alone never jumps the volume.
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
            GeometryReader { geo in
                let width = geo.size.width
                let level = CGFloat(isDragging ? dragLevel : volume.level)
                let trackHeight: CGFloat = isDragging ? 11 : 7
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(.white.opacity(isDragging ? 1 : 0.72))
                        .frame(width: max(trackHeight, width * min(max(level, 0), 1)), height: trackHeight)
                }
                .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isDragging)
                // Hardware buttons move the bar smoothly; drags follow the
                // finger directly.
                .animation(isDragging ? nil : .easeOut(duration: 0.18), value: volume.level)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($isTouching) { _, touching, _ in touching = true }
                        .onChanged { value in
                            guard width > 0 else { return }
                            if dragStartLevel == nil {
                                // Mostly vertical pulls are left alone.
                                guard abs(value.translation.width) >= abs(value.translation.height) else { return }
                                dragStartLevel = volume.level
                            }
                            dragLevel = draggedLevel(for: value.translation.width, width: width)
                            volume.set(dragLevel)
                        }
                        .onEnded { value in
                            if dragStartLevel != nil, width > 0 {
                                volume.set(draggedLevel(for: value.translation.width, width: width))
                            }
                            dragStartLevel = nil
                        }
                )
            }
            .frame(height: 28)
            // Keeps the system volume HUD away and carries the change to the
            // system; it is invisible and takes no touches.
            .background { SystemVolumeBridge(volume: volume) }
            .onAppear { volume.startTracking() }
            .onDisappear { volume.stopTracking() }
            // A cancelled drag never reaches onEnded.
            .onChange(of: isTouching) { _, touching in
                if !touching { dragStartLevel = nil }
            }
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((volume.level * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: volume.set(min(volume.level + 0.0625, 1))
                case .decrement: volume.set(max(volume.level - 0.0625, 0))
                @unknown default: break
                }
            }
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("系统音量")
    }

    private func draggedLevel(for translation: CGFloat, width: CGFloat) -> Float {
        let start = dragStartLevel ?? volume.level
        return min(max(start + Float(translation / width), 0), 1)
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
/// System output volume for the custom bar. Writes go through the hidden
/// `MPVolumeView` slider, the public way to set it. Reads come from
/// `AVAudioSession.outputVolume` KVO while the session is active, and from
/// that slider (which MediaPlayer keeps in sync, also while paused and the
/// session is inactive) through a light poll while the bar is on screen.
@MainActor
private final class SystemVolume: ObservableObject {
    @Published private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    fileprivate weak var volumeView: MPVolumeView?
    private var observation: NSKeyValueObservation?
    private var pollTask: Task<Void, Never>?
    /// Readings right after a local change are echoes of intermediate drag
    /// values; ignoring them keeps the bar from stepping back.
    private var lastLocalSet: TimeInterval = 0

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let value = session.outputVolume
            Task { @MainActor in self?.receive(value) }
        }
    }

    private var slider: UISlider? {
        volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    func set(_ value: Float) {
        // No slider, no change: the bar must not show a volume the system
        // does not have.
        guard let slider else { return }
        let clamped = min(max(value, 0), 1)
        lastLocalSet = ProcessInfo.processInfo.systemUptime
        level = clamped
        slider.setValue(clamped, animated: false)
        slider.sendActions(for: .valueChanged)
    }

    /// Two reads a second and a publish only on change: no redraw while the
    /// volume stays put.
    func startTracking() {
        if let value = slider?.value { receive(value) }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if let value = self.slider?.value { self.receive(value) }
            }
        }
    }

    func stopTracking() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func receive(_ value: Float) {
        guard ProcessInfo.processInfo.systemUptime - lastLocalSet > 0.35,
              abs(value - level) > 0.001 else { return }
        level = value
    }
}

/// An `MPVolumeView` kept in the window so the system routes volume changes
/// through it (and hides its HUD while the player is up), with blank track
/// and thumb images so nothing of it is seen. Touches and accessibility go
/// to the SwiftUI bar above it.
private struct SystemVolumeBridge: UIViewRepresentable {
    let volume: SystemVolume

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        attach(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // MPVolumeView can rebuild its slider after a route change.
        attach(uiView)
    }

    private func attach(_ view: MPVolumeView) {
        volume.volumeView = view
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first,
              slider.thumbImage(for: .normal) !== Self.blank else { return }
        slider.setMinimumTrackImage(Self.blank, for: .normal)
        slider.setMaximumTrackImage(Self.blank, for: .normal)
        slider.setThumbImage(Self.blank, for: .normal)
        slider.setThumbImage(Self.blank, for: .highlighted)
    }

    private static let blank: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
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
                        .onChange(of: player.seekRevision) { _ in
                            // A manual lyric scroll temporarily owns the list
                            // position. An explicit playback seek (including
                            // scrubbing the progress bar) must take ownership
                            // back and align the visible line to the new clock.
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                            pendingLyricSeekID = nil
                            suppressesAutoScroll = false
                            isDragging = false
                            selectedIndex = nil
                            nearestIndex = nil
                            activeIndex = lyricsCursor.activeIndex
                            guard let index = lyricsCursor.activeIndex else { return }
                            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)) {
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
            Image(systemName: liked ? "star.fill" : "star")
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
    let onSeek: (() -> Void)?

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    init(
        onShowQuality: (() -> Void)? = nil,
        showsRemainingTime: Bool = false,
        onSeek: (() -> Void)? = nil
    ) {
        self.onShowQuality = onShowQuality
        self.showsRemainingTime = showsRemainingTime
        self.onSeek = onSeek
    }

    private func fraction(at playbackPosition: TimeInterval) -> Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : playbackPosition
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        // The label changes once a second and the bar moves ~1.5pt/s, so 4 fps
        // is visually identical to 24 fps. Dragging uses `dragProgress` and is
        // unaffected.
        TimelineView(.animation(
            minimumInterval: max(renderingBudget.minimumAnimationInterval, 0.25),
            paused: !RenderingBudget.permitsTimeDrivenLyricUpdates(
                isPlaying: player.isPlaying,
                isSceneActive: renderingBudget.isSceneActive
            )
        )) { _ in
            scrubberContent(position: PlaybackPositionPolicy.displayPosition(
                isPlaying: player.isPlaying,
                isSeeking: player.isScrubbing,
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
                // Thumbless track like the system player: it thickens while
                // dragging instead of showing a knob.
                let trackHeight: CGFloat = isDragging ? 11 : 7
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(.white.opacity(isDragging ? 1 : 0.72))
                        .frame(width: max(trackHeight, width * progress), height: trackHeight)
                }
                .animation(.spring(response: 0.26, dampingFraction: 0.82), value: isDragging)
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
                            onSeek?()
                            player.seek(to: dragProgress) {
                                player.refreshLyricsCursor()
                            }
                            isDragging = false
                        }
                )
            }
            .frame(height: 24)
            .onHover { hovering in
                withAnimation(AppAnimation.quick) { isHovering = hovering }
            }

            HStack(alignment: .center, spacing: 8) {
                Text(Formatters.duration(isDragging ? dragProgress : position))
                Spacer()
                if let onShowQuality {
                    Button(action: onShowQuality) {
                        // A short format badge, like the system "Lossless"
                        // tag. The full wording stays in the accessibility label.
                        Text(qualityBadgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            // Fits the 64pt scrubber slot (24 track + 5 + 32)
                            // without overlapping the transport row; the
                            // padded content shape keeps a wide tap target.
                            .frame(minHeight: 32)
                            .padding(.horizontal, 8)
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
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.56))
        }
    }

    private var qualityBadgeText: String {
        if let served = player.servedQuality {
            return AudioQuality(lxType: served)?.badgeName ?? served.uppercased()
        }
        if let requested = player.requestedQuality, player.currentTrack != nil, !player.isResolvingSource {
            return AudioQuality(lxType: requested)?.badgeName ?? requested.uppercased()
        }
        return qualityDisplayName
    }

    private var qualityDisplayName: String {
        if let served = player.servedQuality {
            return AudioQuality(lxType: served)?.sourceDisplayName ?? served.uppercased()
        }
        if player.isResolvingSource { return "检测中" }
        guard player.currentTrack != nil else { return "未播放" }
        if let requested = player.requestedQuality {
            return "请求 " + (AudioQuality(lxType: requested)?.sourceDisplayName ?? requested.uppercased())
        }
        return "待播放"
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
