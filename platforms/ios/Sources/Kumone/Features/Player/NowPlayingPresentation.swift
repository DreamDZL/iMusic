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
/// to, so the next open can start from the same palette without a grey flash.
@MainActor
final class NowPlayingTint: ObservableObject {
    static let shared = NowPlayingTint()

    @Published private(set) var colors: ArtworkColors = .fallback
    private(set) var playbackKey: String?

    func update(_ colors: ArtworkColors, for playbackKey: String?) {
        self.playbackKey = playbackKey
        if self.colors != colors { self.colors = colors }
    }
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

    /// Direction that leads to the other page: left (-1) from the song page
    /// to lyrics, right (+1) from lyrics back to the song page.
    static func pageSwipeAllowedDirection(showsLyrics: Bool) -> CGFloat {
        showsLyrics ? 1 : -1
    }

    /// Page to show after a horizontal swipe, or nil to stay. Commits on a
    /// 60pt drag or a 200pt fling in the allowed direction.
    static func pageSwipeTarget(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        showsLyrics: Bool
    ) -> Bool? {
        let direction = pageSwipeAllowedDirection(showsLyrics: showsLyrics)
        let distance = translation * direction
        let predicted = predictedTranslation * direction
        guard distance >= 60 || (predicted >= 200 && distance > 0) else { return nil }
        return !showsLyrics
    }

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
    /// Compatibility presentation only; native zoom owns iPhone cover motion.
    static let presentationAnimation = Animation.easeInOut(duration: 0.35)

    static var immersiveHeaderTopInset: CGFloat {
        indicatorTopSpacing + indicatorHeight + indicatorToHeaderSpacing
    }

    static var dynamicIslandToIndicatorSpacing: CGFloat {
        dynamicIslandSafeAreaClearance + indicatorTopSpacing
    }

    /// 0 at rest, 1 once the player is pulled a third of the screen down.
    static func dismissProgress(dragOffset: CGFloat, height: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        return min(max(dragOffset / (height / 3), 0), 1)
    }

    /// Corner radius of the player card while it is pulled down; it reaches
    /// a display-like 40pt almost immediately so the edge reads as a card.
    static func dismissCornerRadius(progress: CGFloat) -> CGFloat {
        progress <= 0 ? 0 : min(40, 12 + progress * 120)
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
            // Loaded CI accessibility snapshots can each take several
            // seconds. Only the extended inspection fixture gets this window;
            // the separate default-timing regression still uses three seconds.
            return .seconds(45)
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

private struct PlayerCardCornerRadiusKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Corner radius of the player card while it is pulled down (0 at rest).
    var playerCardCornerRadius: CGFloat {
        get { self[PlayerCardCornerRadiusKey.self] }
        set { self[PlayerCardCornerRadiusKey.self] = newValue }
    }
}

/// Rounds the player's full-bleed backdrop while it is pulled down. Applied
/// to the backdrop *before* `ignoresSafeArea`, so it clips at the screen
/// edge; after it, the clip would cut the backdrop at the safe area.
/// The structure never changes (radius 0 at rest), so a drag in progress is
/// never torn down, and only this modifier re-renders per drag frame.
struct PlayerCardClip: ViewModifier {
    @Environment(\.playerCardCornerRadius) private var cornerRadius

    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

enum NativeNowPlayingDismissPolicy {
    static func shouldRequestDismiss(translation: CGSize, predicted: CGSize) -> Bool {
        guard translation.width.isFinite, translation.height.isFinite,
              predicted.width.isFinite, predicted.height.isFinite,
              translation.height >= 44,
              translation.height > abs(translation.width) * 1.25 else { return false }
        return translation.height > NowPlayingPresentationMetrics.dismissDistance
            || (predicted.height > NowPlayingPresentationMetrics.dismissPrediction
                && predicted.height > abs(predicted.width) * 1.25)
    }
}

/// A downward pull only requests dismissal. UIKit alone animates the cover;
/// this modifier never changes a view's position, scale, opacity or timing.
struct NativeNowPlayingDismissRequest: ViewModifier {
    @Environment(\.dismissNowPlayingAction) private var dismiss
    var acceptsTap = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if acceptsTap {
            // A recognized short pull must not fall through to tap-to-close.
            // Simultaneous tap+drag can accept both under system tap slop.
            content.gesture(
                DragGesture(minimumDistance: 14)
                    .exclusively(before: TapGesture())
                    .onEnded { result in
                        switch result {
                        case .first(let drag): requestDismissal(drag)
                        case .second: dismiss?()
                        }
                    }
            )
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 14).onEnded(requestDismissal)
            )
        }
    }

    private func requestDismissal(_ value: DragGesture.Value) {
        guard NativeNowPlayingDismissPolicy.shouldRequestDismiss(
            translation: value.translation, predicted: value.predictedEndTranslation
        ) else { return }
        dismiss?()
    }
}

/// Player content and one accessible close target, without a custom animator.
struct IOSNowPlayingPresentation<Content: View>: View {
    private let content: Content

    @Binding private var isPresented: Bool

    init(
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        _isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            content
            dragIndicator
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.dismissNowPlayingAction, dismiss)
        .accessibilityAction(.escape, dismiss)
    }

    private var dragIndicator: some View {
        dragIndicatorSurface
            .contentShape(Rectangle())
            .modifier(NativeNowPlayingDismissRequest(acceptsTap: true))
            // Keep one stable accessibility node for the entire hit target.
            // The inner clear surface and decorative capsule are not controls.
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("nowPlayingDismissIndicator")
            .accessibilityLabel("下拉关闭播放页")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("关闭播放页"), dismiss)
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
                .allowsHitTesting(false)
                .padding(.top, NowPlayingPresentationMetrics.indicatorTopSpacing)
        }
        .frame(
            width: NowPlayingPresentationMetrics.indicatorHitWidth,
            height: NowPlayingPresentationMetrics.indicatorHitHeight
        )
    }

    private func dismiss() {
        isPresented = false
    }
}
#endif
