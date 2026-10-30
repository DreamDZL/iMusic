import SwiftUI

// MARK: - Skeletons

struct SkeletonView: View {
    var cornerRadius: CGFloat = Theme.Radius.standard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var renderingBudget = RenderingBudget.shared

    var body: some View {
        TimelineView(.animation(
            minimumInterval: renderingBudget.minimumAnimationInterval,
            paused: reduceMotion || !renderingBudget.isSceneActive
                || !renderingBudget.allowsContinuousEffects
        )) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.5) / 1.5
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.5))
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .primary.opacity(0.08), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: (geo.size.width * 1.6) * phase - geo.size.width * 0.6)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct SkeletonCardView: View {
    var size: CGFloat = Theme.Layout.cardSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonView().frame(width: size, height: size)
            SkeletonView(cornerRadius: 4).frame(width: size * 0.8, height: 12)
            SkeletonView(cornerRadius: 4).frame(width: size * 0.5, height: 10)
        }
    }
}

struct SkeletonShelf: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SkeletonView(cornerRadius: 4).frame(width: 120, height: 20)
            HStack(spacing: 16) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonCardView()
                }
            }
        }
    }
}

// MARK: - Staggered entrance

private enum AnimationCache {
    nonisolated(unsafe) static var animated = Set<String>()

    static func hasAnimated(_ key: String) -> Bool { animated.contains(key) }

    static func markAnimated(_ key: String) {
        if animated.count > 600 { animated.removeAll() }
        animated.insert(key)
    }
}

struct StaggeredAppearanceModifier: ViewModifier {
    let index: Int
    var itemID: String

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 16)
            .onAppear {
                if Platform.isReduceMotionEnabled
                    || AnimationCache.hasAnimated(itemID) {
                    isVisible = true
                    return
                }
                withAnimation(AppAnimation.snappy.delay(AppAnimation.stagger(for: index))) {
                    isVisible = true
                }
                AnimationCache.markAnimated(itemID)
            }
    }
}

extension View {
    func staggeredAppearance(index: Int, id: String) -> some View {
        modifier(StaggeredAppearanceModifier(index: index, itemID: id))
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?
    var action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ColorToken.tertiaryText)
                            .offset(x: isHovering ? 2 : 0)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(AppAnimation.quick) { isHovering = hovering }
                }
            } else {
                Text(title)
                    .font(.title2.weight(.semibold))
            }
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Collection header (playlist / album pages)

/// Header for playlist and album pages, laid out like the system music
/// collection page: centered artwork, title, accent curator line, a muted
/// detail line, two equal capsule actions and an expandable description.
struct CollectionHeader<Artwork: View, Actions: View>: View {
    let title: String
    var curator: String?
    var detail: String?
    var description: String?
    var playDisabled = false
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var actions: () -> Actions

    @State private var isDescriptionExpanded = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var artworkSide: CGFloat {
        #if os(iOS)
        return min(horizontalSizeClass == .regular ? 300 : 264, DeviceMetrics.portraitWidth * 0.66)
        #else
        return 240
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            artwork()
                .frame(width: artworkSide, height: artworkSide)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard + 2, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                .padding(.bottom, 18)

            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let curator, !curator.isEmpty {
                Text(curator)
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            HStack(spacing: 14) {
                Button(action: onPlay) {
                    Label("播放", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                Button(action: onShuffle) {
                    Label("随机播放", systemImage: "shuffle")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Theme.accent)
            .disabled(playDisabled)
            .padding(.top, 18)

            actions()
                .padding(.top, 10)

            if let description, !description.isEmpty {
                Button {
                    withAnimation(AppAnimation.standard) { isDescriptionExpanded.toggle() }
                } label: {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isDescriptionExpanded ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint(isDescriptionExpanded ? "收起简介" : "展开简介")
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}

extension CollectionHeader where Actions == EmptyView {
    init(
        title: String,
        curator: String? = nil,
        detail: String? = nil,
        description: String? = nil,
        playDisabled: Bool = false,
        onPlay: @escaping () -> Void,
        onShuffle: @escaping () -> Void,
        @ViewBuilder artwork: @escaping () -> Artwork
    ) {
        self.init(
            title: title, curator: curator, detail: detail, description: description,
            playDisabled: playDisabled, onPlay: onPlay, onShuffle: onShuffle,
            artwork: artwork, actions: { EmptyView() }
        )
    }
}

// MARK: - Badges

struct PlayCountBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(Theme.Typography.iconBadge)
            Text(Formatters.playCount(count))
                .font(Theme.Typography.badge)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(.black.opacity(0.35), in: Capsule())
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
    }
}

struct VIPBadge: View {
    var body: some View {
        Text("VIP")
            .font(Theme.Typography.iconBadge)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .stroke(Theme.accent.opacity(0.8), lineWidth: 1)
            )
    }
}

struct QualityTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.badge)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous)
                    .stroke(Theme.accent.opacity(0.7), lineWidth: 1)
            )
    }
}

// MARK: - Hover play overlay

struct PlayOverlayButton: View {
    var visible: Bool
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        #if os(macOS)
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.accent.opacity(0.92), in: Circle())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        }
        .buttonStyle(.pressable)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.7)
        .animation(AppAnimation.spring, value: visible)
        // Opacity alone leaves it clickable while invisible.
        .allowsHitTesting(visible)
        #else
        EmptyView()
        #endif
    }
}

// MARK: - Marquee

/// Scrolls text horizontally when it overflows, with faded edges.
///
/// Driven by Core Animation rather than SwiftUI. This view sits permanently in
/// the player bar, and a `repeatForever` SwiftUI animation keeps the entire view
/// graph re-rendering for as long as it runs — measured at ~15% of a core, for
/// as long as the current title happened to be long enough to scroll. A
/// `CABasicAnimation` is handed to the render server once and then costs this
/// process nothing.
struct MarqueeText: View {
    let text: String
    var fontSize: CGFloat = 13
    var fontWeight: PlatformFont.Weight = .medium

    var body: some View {
        MarqueeTextView.Representable(text: text, fontSize: fontSize, weight: fontWeight)
    }
}

final class MarqueeTextView: PlatformView {
    /// Gap between the two copies of the text.
    private static let gap: CGFloat = 32
    /// Points per second.
    private static let speed: CGFloat = 24
    /// Pause before a new title starts travelling, so it can be read first.
    private static let leadIn: CFTimeInterval = 1.6
    private static let fadeFraction = 0.06

    private let scroller = CALayer()
    private let first = CATextLayer()
    private let second = CATextLayer()
    private let fade = CAGradientLayer()

    private var text: String
    private var fontSize: CGFloat
    private var weight: PlatformFont.Weight
    private var textWidth: CGFloat = 0
    /// Guards against re-running layout on every display cycle: the host view
    /// calls layout() each frame while an animation is in flight, and tearing
    /// the animation down and rebuilding it there costs more than the SwiftUI
    /// version ever did.
    private var laidOutFor: CGSize = .zero
    private var needsMarquee: Bool { textWidth > bounds.width + 1 }

    /// `NSView.layer` is optional (needs `wantsLayer`); `UIView.layer` is not.
    /// A single optional accessor lets the shared setup code work on both.
    private var hostLayer: CALayer? { layer }

    init(text: String, fontSize: CGFloat, weight: PlatformFont.Weight) {
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #endif
        hostLayer?.addSublayer(scroller)
        scroller.addSublayer(first)
        scroller.addSublayer(second)
        hostLayer?.mask = fade
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        for textLayer in [first, second] {
            textLayer.contentsScale = 2
            textLayer.truncationMode = .none
            textLayer.isWrapped = false
        }
        applyText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(text: String, fontSize: CGFloat, weight: PlatformFont.Weight) {
        guard text != self.text || fontSize != self.fontSize || weight != self.weight else { return }
        self.text = text
        self.fontSize = fontSize
        self.weight = weight
        applyText()
        relayout()
    }

    private var font: PlatformFont { .systemFont(ofSize: fontSize, weight: weight) }

    private var labelColor: CGColor {
        #if os(macOS)
        return NSColor.labelColor.cgColor
        #else
        return UIColor.label.cgColor
        #endif
    }

    private func applyText() {
        let font = self.font
        textWidth = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        for textLayer in [first, second] {
            textLayer.string = text
            textLayer.font = font
            textLayer.fontSize = fontSize
            textLayer.foregroundColor = labelColor
        }
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        guard bounds.size != laidOutFor else { return }
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A CGColor is a snapshot; unlike a dynamic NSColor it won't follow the
        // appearance on its own.
        first.foregroundColor = labelColor
        second.foregroundColor = labelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        first.contentsScale = scale
        second.contentsScale = scale
        relayout()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutFor else { return }
        relayout()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        first.foregroundColor = labelColor
        second.foregroundColor = labelColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let scale = window?.screen.scale ?? 2
        first.contentsScale = scale
        second.contentsScale = scale
        relayout()
    }
    #endif

    private func relayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        laidOutFor = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let lineHeight = ceil(font.ascender - font.descender)
        let y = ((bounds.height - lineHeight) / 2).rounded()
        first.frame = CGRect(x: 0, y: y, width: textWidth, height: lineHeight)
        second.frame = CGRect(x: textWidth + Self.gap, y: y, width: textWidth, height: lineHeight)
        second.isHidden = !needsMarquee
        scroller.anchorPoint = .zero
        scroller.bounds = CGRect(x: 0, y: 0,
                                 width: textWidth * 2 + Self.gap, height: bounds.height)
        scroller.position = .zero
        fade.frame = bounds
        fade.colors = fadeColors()
        fade.locations = fadeLocations()

        CATransaction.commit()
        restartAnimation()
    }

    private func fadeColors() -> [CGColor] {
        let opaque = PlatformColor.black.cgColor
        let clear = PlatformColor.black.withAlphaComponent(0).cgColor
        guard needsMarquee else { return [opaque, opaque, opaque, opaque] }
        return [clear, opaque, opaque, clear]
    }

    private func fadeLocations() -> [NSNumber] {
        guard needsMarquee else { return [0, 0, 1, 1] }
        return [0, NSNumber(value: Self.fadeFraction),
                NSNumber(value: 1 - Self.fadeFraction), 1]
    }

    private func restartAnimation() {
        scroller.removeAnimation(forKey: "marquee")
        guard needsMarquee, !Platform.isReduceMotionEnabled else { return }

        let distance = textWidth + Self.gap
        let animation = CABasicAnimation(keyPath: "position.x")
        animation.byValue = -distance
        animation.duration = CFTimeInterval(distance / Self.speed)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.beginTime = CACurrentMediaTime() + Self.leadIn
        scroller.add(animation, forKey: "marquee")
    }

    // MARK: Bridge

    struct Representable: PlatformViewRepresentable {
        let text: String
        let fontSize: CGFloat
        let weight: PlatformFont.Weight

        #if os(macOS)
        func makeNSView(context: Context) -> MarqueeTextView {
            MarqueeTextView(text: text, fontSize: fontSize, weight: weight)
        }
        func updateNSView(_ view: MarqueeTextView, context: Context) {
            view.update(text: text, fontSize: fontSize, weight: weight)
        }
        #else
        func makeUIView(context: Context) -> MarqueeTextView {
            MarqueeTextView(text: text, fontSize: fontSize, weight: weight)
        }
        func updateUIView(_ view: MarqueeTextView, context: Context) {
            view.update(text: text, fontSize: fontSize, weight: weight)
        }
        #endif
    }
}

