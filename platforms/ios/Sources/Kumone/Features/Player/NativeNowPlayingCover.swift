#if os(iOS)
import SwiftUI
import UIKit

/// Owned by the main view, not shared across windows. The anchor supplies geometry only.
@MainActor
final class NativeNowPlayingSource: ObservableObject {
    weak var view: UIView?

    func frame(in reference: UIView) -> CGRect? {
        let referenceWindow = (reference as? UIWindow) ?? reference.window
        guard let view, let window = view.window, window === referenceWindow,
              !view.isHidden, PlayerCollapseGeometry.isUsableFrame(view.bounds) else { return nil }
        return view.convert(view.bounds, to: reference)
    }
}

@MainActor
enum NativeNowPlayingCoordinates {
    /// Uniform player scale commutes with the container's transform. Translation
    /// is a vector, so convert two points and subtract, rather than mixing
    /// window distances with a scaled/offset presentation container's units.
    static func transform(_ transform: CGAffineTransform, from source: UIView, to target: UIView) -> CGAffineTransform? {
        let sourceWindow = (source as? UIWindow) ?? source.window
        let targetWindow = (target as? UIWindow) ?? target.window
        guard let sourceWindow, sourceWindow === targetWindow,
              transform.a.isFinite, transform.a > 0, transform.a == transform.d,
              transform.b == 0, transform.c == 0,
              transform.tx.isFinite, transform.ty.isFinite else { return nil }
        let origin = source.convert(CGPoint.zero, to: target)
        let endpoint = source.convert(CGPoint(x: transform.tx, y: transform.ty), to: target)
        let offset = CGPoint(x: endpoint.x - origin.x, y: endpoint.y - origin.y)
        guard offset.x.isFinite, offset.y.isFinite else { return nil }
        return CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: transform.a, y: transform.a)
    }
}

@MainActor
struct NativeNowPlayingSourceAnchor: UIViewRepresentable {
    let source: NativeNowPlayingSource

    final class Coordinator {
        var source: NativeNowPlayingSource
        init(source: NativeNowPlayingSource) { self.source = source }
    }

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    func makeUIView(context: Context) -> UIView {
        let view = NativeNowPlayingPassthroughView()
        view.backgroundColor = .clear
        source.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let previous = context.coordinator.source
        if previous !== source, previous.view === view { previous.view = nil }
        context.coordinator.source = source
        source.view = view
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        if coordinator.source.view === view { coordinator.source.view = nil }
    }
}

private final class NativeNowPlayingPassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

/// Install as a stable, zero-size background of app content. Content owns its opaque backdrop.
@MainActor
struct NativeNowPlayingCover<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let source: NativeNowPlayingSource
    let content: Content

    init(isPresented: Binding<Bool>, source: NativeNowPlayingSource,
         @ViewBuilder content: () -> Content) {
        _isPresented = isPresented
        self.source = source
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController {
        let presenter = NativeNowPlayingPresenter()
        let coordinator = context.coordinator
        coordinator.presenter = presenter
        presenter.onAppear = { [weak coordinator] in coordinator?.reconcile() }
        return presenter
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        (controller as? NativeNowPlayingPresenter)?.onAppear = nil
        coordinator.active = false
        coordinator.desired = false
        coordinator.cancelInteraction()
        coordinator.reconcile()
    }

    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate {
        private enum Phase { case idle, presenting, presented, dismissing }
        fileprivate weak var presenter: UIViewController?
        fileprivate var active = true
        fileprivate var desired: Bool
        private var value: NativeNowPlayingCover
        private var host: NativeNowPlayingHost<AnyView>?
        private var phase: Phase = .idle
        private var revision = 0
        private var dismissalRevision = 0
        private var presentationID = UUID()
        private var requestedDismissal = false
        private var interaction = false
        private var interactionEnding = false
        private var rebound: UIViewPropertyAnimator?
        private var collapseGeometry: PlayerCollapseGeometry?
        private weak var collapseWindow: UIWindow?
        private var clippingBeforePull: Bool?
        private var initialCornerRadius: CGFloat = 0
        private let frameRate = PlayerMotionFrameRateLease()
        private var childDismissalInFlight = false

        init(_ value: NativeNowPlayingCover) {
            self.value = value
            desired = value.isPresented
        }

        fileprivate func update(_ value: NativeNowPlayingCover) {
            self.value = value
            if desired != value.isPresented {
                desired = value.isPresented
                revision += 1
            }
            // The hosted tree observes playback itself. Replacing rootView on
            // every playback tick can invalidate SwiftUI's active drag state.
            reconcile()
        }

        fileprivate func reconcile() {
            switch phase {
            case .idle:
                guard active, desired, let presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil else { return }
                let id = UUID()
                presentationID = id
                let close: () -> Void = { [weak self] in
                    guard let self, self.presentationID == id else { return }
                    self.close()
                }
                let drag = NowPlayingDismissDragAction(
                    onChanged: { [weak self] translation in
                        guard let self, self.presentationID == id else { return }
                        self.dragChanged(translation)
                    },
                    onEnded: { [weak self] translation, predicted in
                        guard let self, self.presentationID == id else { return }
                        self.dragEnded(translation, predicted: predicted)
                    }
                )
                let root = AnyView(value.content
                    .environment(\.dismissNowPlayingAction, close)
                    .environment(\.dismissNowPlayingDragAction, drag)
                    .environment(\.nowPlayingDismissRegion, { [weak self] view, tap, excluded in
                        guard let self, self.presentationID == id else { return }
                        self.host?.registerRegion(view, acceptsTap: tap, excluded: excluded)
                    }))
                let host = NativeNowPlayingHost(rootView: root)
                self.host = host
                host.onDragChanged = drag.onChanged
                host.onDragEnded = drag.onEnded
                host.onClose = close
                host.modalPresentationStyle = .custom
                host.modalPresentationCapturesStatusBarAppearance = true
                host.transitioningDelegate = self
                host.view.backgroundColor = .clear
                host.onAppear = { [weak self] in self?.reconcile() }
                phase = .presenting
                // Retain the coordinator until UIKit finishes, including representable teardown.
                presenter.present(host, animated: true) { [self, weak host] in
                    guard let host, self.host === host else { return }
                    phase = .presented
                    reconcile()
                }
            case .presented:
                if !desired { beginDismissal(requested: true) }
            case .presenting, .dismissing:
                break // The completion reconciles the latest request, never an old snapshot.
            }
        }

        private func beginDismissal(requested: Bool) {
            guard phase == .presented, let host,
                  !childDismissalInFlight,
                  let owner = host.presentingViewController,
                  owner.presentedViewController === host else { return }
            stopRebound()
            interaction = false
            frameRate.stop()
            if host.presentedViewController != nil {
                // A partial-height child sheet does not necessarily produce
                // another host.viewDidAppear. Explicitly finish that sheet
                // before retrying, rather than losing the close request.
                childDismissalInFlight = true
                let requestRevision = revision
                host.dismiss(animated: active) { [self, weak host] in
                    childDismissalInFlight = false
                    guard let host, self.host === host else { return }
                    if revision == requestRevision && (!requested || !desired) {
                        beginDismissal(requested: requested)
                    } else {
                        reconcile()
                    }
                }
                return
            }
            requestedDismissal = requested
            dismissalRevision = revision
            phase = .dismissing
            owner.dismiss(animated: active)
        }

        private func close() {
            guard !interaction else { return }
            beginDismissal(requested: false)
        }

        private func dragChanged(_ translation: CGFloat) {
            guard active, translation.isFinite else { return }
            if !interaction {
                guard translation > 0, phase == .presented,
                      let host, host.presentedViewController == nil,
                      let view = host.viewIfLoaded, let window = view.window,
                      let superview = view.superview else { return }
                if collapseGeometry == nil { clippingBeforePull = view.clipsToBounds }
                stopRebound()
                guard let layoutFrame = PlayerCollapseGeometry.untransformedFrame(bounds: view.bounds, center: view.center),
                      let initialTransform = NativeNowPlayingCoordinates.transform(view.transform, from: superview, to: window),
                      let geometry = PlayerCollapseGeometry(
                        baseFrame: superview.convert(layoutFrame, to: window), viewport: window.bounds,
                        sourceFrame: value.source.frame(in: window), grabY: host.panOriginY,
                        initialTransform: initialTransform) else {
                    interactionEnding = true
                    restoreAfterPull()
                    host.cancelDismissPan()
                    return
                }
                collapseGeometry = geometry
                collapseWindow = window
                initialCornerRadius = view.layer.cornerRadius
                interaction = true
            }
            guard let view = host?.view, let geometry = collapseGeometry,
                  let window = collapseWindow, view.window === window,
                  let superview = view.superview,
                  let layoutFrame = PlayerCollapseGeometry.untransformedFrame(bounds: view.bounds, center: view.center),
                  geometry.canContinue(baseFrame: superview.convert(layoutFrame, to: window), viewport: window.bounds) else {
                cancelInteraction()
                host?.cancelDismissPan()
                return
            }
            frameRate.window = view.window
            frameRate.request()
            let reduced = UIAccessibility.isReduceMotionEnabled
            let pose = geometry.pose(translation: translation, reduceMotion: reduced)
            guard let transform = NativeNowPlayingCoordinates.transform(pose.transform, from: window, to: superview) else {
                cancelInteraction()
                host?.cancelDismissPan()
                return
            }
            // Do not begin a UIKit dismissal here. That sends viewWillDisappear
            // and can cancel the gesture which is still driving this motion.
            // Only the stable bounds/center rect is measured, never the already
            // transformed view's window frame. Each sample is absolute, not an
            // accumulation that would drift when the finger reverses direction.
            view.transform = transform
            view.clipsToBounds = true
            view.layer.cornerCurve = .continuous
            view.layer.cornerRadius = reduced ? 0
                : initialCornerRadius + (40 - initialCornerRadius) * min(1, pose.progress * 4)
            view.alpha = reduced ? 1 : 1 - pose.progress * 0.2
        }

        private func dragEnded(_ translation: CGFloat, predicted: CGFloat) {
            guard interaction, !interactionEnding else { return }
            interaction = false
            interactionEnding = true
            if NativeNowPlayingDismissPolicy.shouldRequestDismiss(
                translation: CGSize(width: 0, height: translation),
                predicted: CGSize(width: 0, height: predicted)
            ) {
                // The animator inherits the live transform; no reset to full
                // screen and no disappearance until the gesture has ended.
                frameRate.stop()
                beginDismissal(requested: false)
            } else {
                restoreAfterPull()
            }
        }

        private func stopRebound() {
            if rebound != nil, let view = host?.view, let layer = view.layer.presentation() {
                let transform = layer.affineTransform()
                let radius = layer.cornerRadius
                rebound?.stopAnimation(true)
                view.transform = transform
                view.layer.cornerRadius = radius
            } else {
                rebound?.stopAnimation(true)
            }
            rebound = nil
            interactionEnding = false
        }

        fileprivate func cancelInteraction() {
            guard interaction else { return }
            interaction = false
            interactionEnding = true
            restoreAfterPull()
        }

        private func restoreAfterPull() {
            guard let view = host?.view else {
                interactionEnding = false
                collapseGeometry = nil
                collapseWindow = nil
                clippingBeforePull = nil
                frameRate.stop()
                return
            }
            frameRate.window = view.window
            frameRate.request()
            let animator = UIAccessibility.isReduceMotionEnabled
                ? UIViewPropertyAnimator(duration: 0.22, curve: .easeOut)
                : UIViewPropertyAnimator(duration: 0.40,
                                         dampingRatio: NowPlayingPresentationMetrics.transitionSpringDamping)
            rebound = animator
            animator.addAnimations {
                view.transform = .identity
                view.layer.cornerRadius = 0
                view.alpha = 1
            }
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, let animator, self.rebound === animator else { return }
                self.rebound = nil
                self.interactionEnding = false
                view.clipsToBounds = self.clippingBeforePull ?? false
                self.collapseGeometry = nil
                self.collapseWindow = nil
                self.clippingBeforePull = nil
                view.superview?.setNeedsLayout()
                self.frameRate.stop()
                self.reconcile()
            }
            animator.startAnimation()
        }

        private func dismissalEnded(_ dismissed: NativeNowPlayingHost<AnyView>, completed: Bool) {
            guard host === dismissed else { return }
            interaction = false
            interactionEnding = false
            collapseGeometry = nil
            collapseWindow = nil
            clippingBeforePull = nil
            frameRate.stop()
            guard completed else {
                phase = .presented
                requestedDismissal = false
                reconcile()
                return
            }
            host = nil
            phase = .idle
            // An interactive completion closes the binding unless a newer request superseded it.
            if NativeNowPlayingDismissPolicy.shouldCloseBinding(
                completed: completed, active: active, requestedDismissal: requestedDismissal,
                dismissalRevision: dismissalRevision, currentRevision: revision
            ) {
                desired = false
                if value.isPresented { value.isPresented = false }
            }
            requestedDismissal = false
            reconcile()
        }

        func presentationController(forPresented presented: UIViewController,
                                    presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            NativeNowPlayingRetainedPresentation(presentedViewController: presented, presenting: presenting)
        }

        func animationController(forPresented presented: UIViewController,
                                 presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            NativeNowPlayingAnimator(opening: true, source: value.source)
        }

        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            NativeNowPlayingAnimator(opening: false, source: value.source,
                                     collapseGeometry: collapseGeometry, collapseWindow: collapseWindow,
                                     clippingBeforePull: clippingBeforePull) { [self, weak host] completed in
                guard let host else { return }
                dismissalEnded(host, completed: completed)
            }
        }

    }
}

private final class NativeNowPlayingPresenter: UIViewController {
    var onAppear: (() -> Void)?

    override func loadView() { view = NativeNowPlayingPassthroughView() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?()
    }
}

private final class NativeNowPlayingHost<Content: View>: UIHostingController<Content>, UIGestureRecognizerDelegate {
    // The player uses a dark artwork backdrop regardless of the library scheme.
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    var onAppear: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat, CGFloat) -> Void)?
    var onClose: (() -> Void)?
    private final class Region {
        weak var view: UIView?
        let acceptsTap: Bool
        let excluded: Bool
        init(_ view: UIView, acceptsTap: Bool, excluded: Bool) {
            self.view = view
            self.acceptsTap = acceptsTap
            self.excluded = excluded
        }
    }
    private var regions: [Region] = []
    private var pan: UIPanGestureRecognizer!
    private var tap: UITapGestureRecognizer!
    private(set) var panOriginY: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()
        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        pan.delegate = self
        tap.delegate = self
        tap.require(toFail: pan)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
    }

    func registerRegion(_ view: UIView, acceptsTap: Bool, excluded: Bool) {
        regions.removeAll { $0.view == nil || $0.view === view }
        regions.append(Region(view, acceptsTap: acceptsTap, excluded: excluded))
    }

    func cancelDismissPan() {
        guard let pan, pan.state == .began || pan.state == .changed else { return }
        // A rotation/layout invalidation must end this touch sequence, not
        // restart a new collapse from its old accumulated translation.
        pan.isEnabled = false
        pan.isEnabled = true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard presentedViewController == nil else { return false }
        // Use only public UIKit controls and explicit SwiftUI geometry markers,
        // never SwiftUI's private hosting hierarchy or accessibility internals.
        var touched = touch.view
        while let candidate = touched, candidate !== view {
            if candidate is UIControl || candidate is UIScrollView { return false }
            touched = candidate.superview
        }
        let hits = regions.filter { region in
            guard let marker = region.view, marker.window === view.window,
                  !marker.isHidden, marker.bounds.width > 0, marker.bounds.height > 0 else { return false }
            return marker.bounds.contains(touch.location(in: marker))
        }
        guard !hits.contains(where: { $0.excluded }) else { return false }
        return hits.contains { recognizer === pan || $0.acceptsTap }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return true }
        let velocity = pan.velocity(in: view.window)
        return NativeNowPlayingDismissPolicy.shouldBeginPan(velocity: velocity)
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        recognizer === pan && other !== tap
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        // Window coordinates stay fixed while the hosting view follows the finger.
        let translation = recognizer.translation(in: view.window)
        switch recognizer.state {
        case .began:
            panOriginY = recognizer.location(in: view.window).y - translation.y
            onDragChanged?(max(0, translation.y))
        case .changed:
            onDragChanged?(max(0, translation.y))
        case .ended:
            let velocity = recognizer.velocity(in: view.window)
            let predicted = CGSize(width: translation.x + velocity.x * 0.2,
                                   height: translation.y + velocity.y * 0.2)
            let accepted = NativeNowPlayingDismissPolicy.shouldRequestDismiss(
                translation: CGSize(width: translation.x, height: translation.y), predicted: predicted)
            onDragEnded?(accepted ? translation.y : 0, accepted ? predicted.height : 0)
            panOriginY = nil
        case .cancelled, .failed:
            onDragEnded?(0, 0)
            panOriginY = nil
        default: break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { onClose?() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDragEnded?(0, 0)
        cancelDismissPan()
        panOriginY = nil
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        onDragEnded?(0, 0)
        cancelDismissPan()
        panOriginY = nil
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onAppear?() // Reconcile requests deferred while a child sheet was visible.
    }
}

/// Keep the real library and mini player in the same window during collapse.
private final class NativeNowPlayingRetainedPresentation: UIPresentationController {
    override var shouldRemovePresentersView: Bool { false }
    override var frameOfPresentedViewInContainerView: CGRect { containerView?.bounds ?? .zero }
    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // UIKit may lay out the container during a percent-driven transition.
        // Writing frame while the player has a transform gives undefined
        // geometry and can make the card jump under the finger.
        if presentedView?.transform == .identity {
            presentedView?.frame = frameOfPresentedViewInContainerView
        }
    }
}

/// A public UIKit spring, not a reproduction of Apple's private Music animator.
/// The terminal timeline inherits the gesture's live transform without a reset.
@MainActor
private final class NativeNowPlayingAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let opening: Bool
    private let source: NativeNowPlayingSource
    private let collapseGeometry: PlayerCollapseGeometry?
    private weak var collapseWindow: UIWindow?
    private let clippingBeforePull: Bool?
    private let completion: ((Bool) -> Void)?
    private var animator: UIViewPropertyAnimator?
    private let frameRate = PlayerMotionFrameRateLease()

    init(opening: Bool, source: NativeNowPlayingSource,
         collapseGeometry: PlayerCollapseGeometry? = nil, collapseWindow: UIWindow? = nil,
         clippingBeforePull: Bool? = nil,
         completion: ((Bool) -> Void)? = nil) {
        self.opening = opening
        self.source = source
        self.collapseGeometry = collapseGeometry
        self.collapseWindow = collapseWindow
        self.clippingBeforePull = clippingBeforePull
        self.completion = completion
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        guard !UIAccessibility.isReduceMotionEnabled else { return 0.22 }
        return opening
            ? NowPlayingPresentationMetrics.expandTransitionDuration
            : NowPlayingPresentationMetrics.dismissTransitionDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
        if let animator { return animator }
        let container = context.containerView
        let key: UITransitionContextViewControllerKey = opening ? .to : .from
        guard let controller = context.viewController(forKey: key),
              let player = context.view(forKey: opening ? .to : .from) else {
            let fallback = UIViewPropertyAnimator(duration: 0, curve: .linear)
            fallback.addCompletion { _ in context.completeTransition(false); self.completion?(false) }
            animator = fallback
            return fallback
        }
        let layoutFrame = PlayerCollapseGeometry.untransformedFrame(bounds: player.bounds, center: player.center)
        let frame = opening ? context.finalFrame(for: controller)
            : layoutFrame.map { player.superview?.convert($0, to: container) ?? $0 } ?? container.bounds
        if opening {
            player.transform = .identity
            player.frame = frame
            container.addSubview(player)
        }
        // On dismissal preserve the finger-follow transform. Writing frame
        // with that transform applied is undefined and causes a visible jump.
        player.layoutIfNeeded()
        frameRate.window = container.window
        frameRate.request()

        // Convert directly between views in the same window, never via global
        // screen coordinates or an unrelated scene's root controller.
        let frozenTarget: CGRect? = collapseGeometry.flatMap { geometry in
            guard let window = collapseWindow, window === container.window,
                  window.bounds == geometry.viewport else { return nil }
            return container.convert(geometry.targetFrame, from: window)
        }
        let geometry = PlayerCollapseGeometry(baseFrame: frame, viewport: container.bounds,
                                              sourceFrame: frozenTarget ?? source.frame(in: container))
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // Preserve artwork/text proportions. Independent x/y scaling flattened
        // the whole player into a strip instead of giving it iOS card motion.
        let containerTransform = geometry?.collapsedTransform(reduceMotion: reduceMotion)
            ?? CGAffineTransform(translationX: 0, y: 24)
        let collapsed = NativeNowPlayingCoordinates.transform(containerTransform, from: container, to: player.superview ?? container)
            ?? CGAffineTransform(translationX: 0, y: 24)
        let originalClipping = clippingBeforePull ?? player.clipsToBounds
        player.clipsToBounds = true
        player.layer.cornerCurve = .continuous
        if opening {
            player.transform = collapsed
            // Keep the real mini-player visible underneath until the full
            // surface has started to grow from its artwork anchor. Scaling the
            // complete player controls down to thumbnail size looks unlike the
            // system transition; fading them in avoids exposing that squeeze.
            player.alpha = 0
            player.layer.cornerRadius = reduceMotion ? 0 : 18
        }
        let spring = reduceMotion
            ? UIViewPropertyAnimator(duration: transitionDuration(using: context), curve: .easeOut)
            : UIViewPropertyAnimator(
                duration: transitionDuration(using: context),
                dampingRatio: NowPlayingPresentationMetrics.transitionSpringDamping
            )
        spring.addAnimations {
            player.transform = self.opening ? .identity : collapsed
            player.layer.cornerRadius = self.opening || reduceMotion ? 0 : 18
        }
        if opening {
            // Let the retained mini-player lead the motion by a beat, then
            // reveal the expanding surface as it clears the artwork anchor.
            spring.addAnimations(
                { player.alpha = 1 },
                delayFactor: reduceMotion ? 0 : NowPlayingPresentationMetrics.expandFadeDelay
            )
        } else {
            // Crossfade to the still-mounted mini-player before the full page
            // reaches thumbnail scale; this avoids compressing controls into
            // the album-art tile at the end of the collapse.
            spring.addAnimations(
                { player.alpha = 0 },
                delayFactor: reduceMotion ? 0 : NowPlayingPresentationMetrics.dismissFadeDelay
            )
        }
        spring.addCompletion { _ in
            let completed = !context.transitionWasCancelled
            player.transform = .identity
            player.alpha = 1
            player.layer.cornerRadius = 0
            player.clipsToBounds = originalClipping
            if self.opening && !completed { player.removeFromSuperview() }
            context.completeTransition(completed)
            self.frameRate.stop()
            self.animator = nil
            self.completion?(completed)
        }
        animator = spring
        return spring
    }
}

#endif
