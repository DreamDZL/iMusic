#if os(iOS)
import SwiftUI
import UIKit

/// Owned by the main view, not shared across windows. The anchor supplies geometry only.
@MainActor
final class NativeNowPlayingSource: ObservableObject {
    weak var view: UIView?
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
                      host?.presentedViewController == nil else { return }
                stopRebound()
                interaction = true
            }
            guard let view = host?.view else { return }
            frameRate.window = view.window
            frameRate.request()
            let progress = NativeNowPlayingDismissPolicy.interactiveProgress(
                translation: translation, height: host?.view.bounds.height ?? 0
            )
            // Do not begin a UIKit dismissal here. That sends viewWillDisappear
            // and can cancel the gesture which is still driving this motion.
            view.transform = CGAffineTransform(translationX: 0,
                y: NativeNowPlayingDismissPolicy.interactiveOffset(translation: translation, height: view.bounds.height))
                .scaledBy(x: 1 - 0.12 * progress, y: 1 - 0.12 * progress)
            view.clipsToBounds = true
            view.layer.cornerCurve = .continuous
            view.layer.cornerRadius = NowPlayingPresentationMetrics.dismissCornerRadius(progress: progress)
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
                frameRate.stop()
                return
            }
            frameRate.window = view.window
            frameRate.request()
            let animator = UIViewPropertyAnimator(
                duration: UIAccessibility.isReduceMotionEnabled ? 0.22 : 0.48, dampingRatio: 0.9)
            rebound = animator
            animator.addAnimations {
                view.transform = .identity
                view.layer.cornerRadius = 0
            }
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, let animator, self.rebound === animator else { return }
                self.rebound = nil
                self.interactionEnding = false
                view.clipsToBounds = false
                self.frameRate.stop()
                self.reconcile()
            }
            animator.startAnimation()
        }

        private func dismissalEnded(_ dismissed: NativeNowPlayingHost<AnyView>, completed: Bool) {
            guard host === dismissed else { return }
            interaction = false
            interactionEnding = false
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
            NativeNowPlayingAnimator(opening: false, source: value.source) { [self, weak host] completed in
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
        case .began, .changed:
            onDragChanged?(max(0, translation.y))
        case .ended:
            let velocity = recognizer.velocity(in: view.window)
            let predicted = CGSize(width: translation.x + velocity.x * 0.2,
                                   height: translation.y + velocity.y * 0.2)
            let accepted = NativeNowPlayingDismissPolicy.shouldRequestDismiss(
                translation: CGSize(width: translation.x, height: translation.y), predicted: predicted)
            onDragEnded?(accepted ? translation.y : 0, accepted ? predicted.height : 0)
        case .cancelled, .failed:
            onDragEnded?(0, 0)
        default: break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { onClose?() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        onDragEnded?(0, 0)
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
/// One interruptible timeline supports forward motion, scrubbing and rebound.
@MainActor
private final class NativeNowPlayingAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let opening: Bool
    private let source: NativeNowPlayingSource
    private let completion: ((Bool) -> Void)?
    private var animator: UIViewPropertyAnimator?
    private let frameRate = PlayerMotionFrameRateLease()

    init(opening: Bool, source: NativeNowPlayingSource, completion: ((Bool) -> Void)? = nil) {
        self.opening = opening
        self.source = source
        self.completion = completion
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.22 : 0.48
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
        let frame = opening ? context.finalFrame(for: controller)
            : CGRect(x: player.center.x - player.bounds.width / 2,
                     y: player.center.y - player.bounds.height / 2,
                     width: player.bounds.width, height: player.bounds.height)
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
        let sourceFrame: CGRect? = source.view.flatMap { anchor in
            guard anchor.window != nil, anchor.window === container.window else { return nil }
            let rect = anchor.convert(anchor.bounds, to: container)
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0, rect.intersects(container.bounds) else { return nil }
            return rect
        }
        let target = sourceFrame ?? CGRect(x: frame.minX, y: container.bounds.maxY,
                                          width: frame.width, height: max(1, frame.height * 0.12))
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        // Preserve artwork/text proportions. Independent x/y scaling flattened
        // the whole player into a strip instead of giving it iOS card motion.
        let scale = min(target.width / max(1, frame.width), target.height / max(1, frame.height))
        let collapsed = reduceMotion
            ? CGAffineTransform(translationX: 0, y: 24)
            : CGAffineTransform(translationX: target.midX - frame.midX, y: target.midY - frame.midY)
                .scaledBy(x: scale, y: scale)
        let originalClipping = player.clipsToBounds
        player.clipsToBounds = true
        player.layer.cornerCurve = .continuous
        if opening {
            player.transform = collapsed
            player.layer.cornerRadius = reduceMotion ? 0 : 18
        }
        let spring = UIViewPropertyAnimator(duration: transitionDuration(using: context), dampingRatio: 0.9)
        spring.addAnimations {
            player.transform = self.opening ? .identity : collapsed
            player.layer.cornerRadius = self.opening || reduceMotion ? 0 : 18
        }
        if !opening {
            // Reveal the real mini-player only at the end of the geometric
            // collapse, rather than showing compressed full-player controls.
            spring.addAnimations({ player.alpha = 0 }, delayFactor: reduceMotion ? 0 : 0.72)
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
