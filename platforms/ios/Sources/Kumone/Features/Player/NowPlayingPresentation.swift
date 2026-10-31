import SwiftUI

/// Motion vocabulary for the player. Springs, not eases: the system player
/// moves with a soft settle, and one shared set keeps every part in step.
enum NowPlayingMotion {
    /// Song ↔ lyrics page change, deck show/hide, artwork move.
    static let page = Animation.spring(response: 0.5, dampingFraction: 0.86)
    /// Sung lyric line swelling in while the previous one relaxes.
    static let lyricEmphasis = Animation.spring(response: 0.55, dampingFraction: 0.78)
    /// Artwork growing back when playback resumes (slight overshoot).
    static let artworkPlay = Animation.spring(response: 0.55, dampingFraction: 0.66)
    /// Artwork receding when paused (no overshoot).
    static let artworkPause = Animation.spring(response: 0.5, dampingFraction: 0.9)
    /// Lyric auto-scroll to the sung line.
    static let lyricScroll = Animation.spring(response: 0.6, dampingFraction: 0.9)
}

#if os(iOS)
enum MiniPlayerSwipePolicy {
    /// Require real horizontal travel before accepting velocity prediction.
    /// Tiny flicks and diagonal/vertical expansion gestures must not skip songs.
    static func trackDirection(translation: CGSize, predictedTranslation: CGSize) -> Int? {
        guard abs(translation.width) >= 20,
              abs(translation.width) > abs(translation.height) * 1.5 else { return nil }
        let distance = translation.width
        let predicted = predictedTranslation.width
        guard abs(distance) >= 52 || (abs(predicted) >= 100 && distance * predicted > 0) else { return nil }
        return distance < 0 ? -1 : 1
    }
}

/// Last artwork palette shown by the player, keyed by the track it belongs
/// to. The full-screen cover paints this colour behind its content, and the
/// next open starts from it, so opening the player never flashes the white
/// system background or fades in from grey.
@MainActor
final class NowPlayingTint: ObservableObject {
    static let shared = NowPlayingTint()

    @Published private(set) var colors: ArtworkColors = .fallback
    private(set) var playbackKey: String?

    func update(_ colors: ArtworkColors, for playbackKey: String?) {
        self.playbackKey = playbackKey
        if self.colors != colors { self.colors = colors }
    }

    /// Colour that fills the presentation behind the player's content.
    var presentationColor: Color { colors.secondary }
}

/// Shared geometry and interaction constants for the iPhone Now Playing
/// presentation. Keeping these values together makes the relationship between
/// the drag indicator and the track header explicit and regression-testable.
enum NowPlayingPresentationMetrics {
    /// The compact layout starts at the safe-area edge, which already sits
    /// about 12pt below the Dynamic Island. One additional point produces the
    /// same visible 13pt gap used below the indicator.
    static let dynamicIslandSafeAreaClearance: CGFloat = 12
    static let indicatorTopSpacing: CGFloat = 1
    static let indicatorToHeaderSpacing: CGFloat = 13
    static let indicatorWidth: CGFloat = 44
    static let indicatorHeight: CGFloat = 5
    static let indicatorHitWidth: CGFloat = 180
    static let indicatorHitHeight: CGFloat = 82
    static let controlsRevealHitHeight: CGFloat = 132
    static let controlsTransitionOffset: CGFloat = 30
    static let controlsTransitionScale: CGFloat = 0.97
    static let lyricsControlsAutoHideDelay = Duration.seconds(3)
    /// After the reader stops scrolling, lyrics glide back to the sung line.
    static let lyricsBrowseResumeDelay = Duration.milliseconds(2500)

    /// While lyric controls are hidden, a tap in the lower band where the
    /// playback deck appears reveals the controls instead of seeking.
    static func isLyricsControlsRevealTap(
        locationY: CGFloat,
        pageHeight: CGFloat,
        revealRegionHeight: CGFloat,
        controlsVisible: Bool
    ) -> Bool {
        guard !controlsVisible, pageHeight > 0, revealRegionHeight > 0 else { return false }
        return locationY >= pageHeight - revealRegionHeight
    }

    /// A strong ease-out lets the lyrics reclaim space immediately, then
    /// settles gently instead of moving at a constant speed.
    static let controlsLayoutAnimation = Animation.timingCurve(
        0.16, 1, 0.3, 1,
        duration: 0.38
    )
    /// Motion and opacity deliberately use separate tracks. The spring gives
    /// the controls a restrained pop while the alpha curve fades them in
    /// quickly and eases through the final few percent.
    static let controlsRevealMotionAnimation = Animation.spring(
        response: 0.44,
        dampingFraction: 0.82,
        blendDuration: 0.08
    )
    static let controlsDismissMotionAnimation = Animation.timingCurve(
        0.16, 1, 0.3, 1,
        duration: 0.28
    )
    static let controlsFadeInAnimation = Animation.timingCurve(
        0.16, 1, 0.3, 1,
        duration: 0.24
    )
    static let controlsFadeOutAnimation = Animation.timingCurve(
        0.16, 1, 0.3, 1,
        duration: 0.18
    )

    static let dismissDistance: CGFloat = 110
    static let dismissPrediction: CGFloat = 190
    static let miniPlayerExpandDistance: CGFloat = 28
    static let miniPlayerExpandPrediction: CGFloat = 72
    static let presentationAnimation = Animation.spring(
        response: 0.52,
        dampingFraction: 0.9,
        blendDuration: 0.1
    )

    static var immersiveHeaderTopInset: CGFloat {
        indicatorTopSpacing + indicatorHeight + indicatorToHeaderSpacing
    }

    static var dynamicIslandToIndicatorSpacing: CGFloat {
        dynamicIslandSafeAreaClearance + indicatorTopSpacing
    }

    static func shouldDismiss(
        translation: CGFloat,
        predictedTranslation: CGFloat
    ) -> Bool {
        translation > dismissDistance || predictedTranslation > dismissPrediction
    }

    static func shouldExpandFromMiniPlayer(
        translation: CGFloat,
        predictedTranslation: CGFloat
    ) -> Bool {
        translation < -miniPlayerExpandDistance
            || predictedTranslation < -miniPlayerExpandPrediction
    }

    /// The system can briefly report no accessory placement while it reparents
    /// the view between the expanded and inline tab-bar containers. Prefer the
    /// compact layout during that undefined interval so a full-width player
    /// cannot be laid out inside the inline container for a transient frame.
    static func shouldUseInlineMiniPlayerLayout(
        placementIsInline: Bool?
    ) -> Bool {
        placementIsInline ?? true
    }

    /// Give slow UI automation time to inspect transient controls without
    /// changing the shipping delay or persisting a test-only preference.
    static func lyricsControlsAutoHideDelay(arguments: [String]) -> Duration {
        #if DEBUG
        let requiredArguments: Set<String> = [
            "-imusic-ui-testing",
            "-imusic-ui-player-fixture",
            "-imusic-ui-extended-lyrics-controls"
        ]
        if requiredArguments.isSubset(of: Set(arguments)) {
            return .seconds(12)
        }
        #endif
        return lyricsControlsAutoHideDelay
    }
}

private struct DismissNowPlayingActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

struct NowPlayingDismissDragAction {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
}

private struct DismissNowPlayingDragActionKey: EnvironmentKey {
    static let defaultValue: NowPlayingDismissDragAction? = nil
}

extension EnvironmentValues {
    var dismissNowPlayingAction: (() -> Void)? {
        get { self[DismissNowPlayingActionKey.self] }
        set { self[DismissNowPlayingActionKey.self] = newValue }
    }

    var dismissNowPlayingDragAction: NowPlayingDismissDragAction? {
        get { self[DismissNowPlayingDragActionKey.self] }
        set { self[DismissNowPlayingDragActionKey.self] = newValue }
    }
}

/// Owns presentation mechanics for Now Playing. The compact player draws one
/// accessible drag indicator because full-screen covers do not consistently
/// display the system sheet indicator.
struct IOSNowPlayingPresentation<Content: View>: View {
    private let usesSystemInteractiveDismissal: Bool
    private let dismissAnimation: Animation?
    private let content: Content

    @Binding private var isPresented: Bool
    @State private var dragOffset: CGFloat = 0

    init(
        isPresented: Binding<Bool>,
        usesSystemInteractiveDismissal: Bool = false,
        dismissAnimation: Animation? = NowPlayingPresentationMetrics.presentationAnimation,
        @ViewBuilder content: () -> Content
    ) {
        _isPresented = isPresented
        self.usesSystemInteractiveDismissal = usesSystemInteractiveDismissal
        self.dismissAnimation = dismissAnimation
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let isInteractive = proxy.size.width < 720
            let usesCustomDrag = isInteractive && !usesSystemInteractiveDismissal

            ZStack(alignment: .top) {
                content
                    .environment(\.dismissNowPlayingAction, dismiss)
                    .environment(
                        \.dismissNowPlayingDragAction,
                        dismissDragAction(usesCustomDrag: usesCustomDrag)
                    )

                if isInteractive && !usesSystemInteractiveDismissal {
                    dragIndicator
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .offset(y: usesCustomDrag ? dragOffset : 0)
        }
    }

    @ViewBuilder
    private var dragIndicator: some View {
        if usesSystemInteractiveDismissal {
            dragIndicatorSurface
                .accessibilityLabel("下拉关闭播放页")
                .accessibilityAction(named: Text("关闭播放页"), dismiss)
        } else {
            dragIndicatorSurface
                .contentShape(Rectangle())
                .gesture(dismissGesture)
                .accessibilityLabel("下拉关闭播放页")
                .accessibilityAction(named: Text("关闭播放页"), dismiss)
        }
    }

    private var dragIndicatorSurface: some View {
        ZStack(alignment: .top) {
            Color.clear

            Capsule()
                .fill(.white.opacity(0.38))
                .frame(
                    width: NowPlayingPresentationMetrics.indicatorWidth,
                    height: NowPlayingPresentationMetrics.indicatorHeight
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
                .padding(.top, NowPlayingPresentationMetrics.indicatorTopSpacing)
        }
        .frame(
            width: NowPlayingPresentationMetrics.indicatorHitWidth,
            height: NowPlayingPresentationMetrics.indicatorHitHeight
        )
        .accessibilityIdentifier("nowPlayingDismissIndicator")
    }

    private var dismissGesture: some Gesture {
        // The surface itself moves during the drag. Measuring in global
        // coordinates keeps the gesture origin fixed and prevents feedback
        // oscillation between the finger and the moving hit target.
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                updateDismissDrag(value.translation.height)
            }
            .onEnded { value in
                finishDismissDrag(
                    value.translation.height,
                    value.predictedEndTranslation.height
                )
            }
    }

    private func dismissDragAction(usesCustomDrag: Bool) -> NowPlayingDismissDragAction {
        NowPlayingDismissDragAction(
            onChanged: { translation in
                guard usesCustomDrag else { return }
                updateDismissDrag(translation)
            },
            onEnded: finishDismissDrag
        )
    }

    private func updateDismissDrag(_ translation: CGFloat) {
        dragOffset = max(translation, 0)
    }

    private func finishDismissDrag(_ translation: CGFloat, _ predictedTranslation: CGFloat) {
        if NowPlayingPresentationMetrics.shouldDismiss(
            translation: translation,
            predictedTranslation: predictedTranslation
        ) {
            dismiss()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                dragOffset = 0
            }
        }
    }

    private func dismiss() {
        if let dismissAnimation {
            withAnimation(dismissAnimation) {
                isPresented = false
            }
        } else {
            isPresented = false
        }
    }
}
#endif
