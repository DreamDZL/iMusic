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
        private var requestedDismissal = false
        private var interaction: UIPercentDrivenInteractiveTransition?
        private var interactionEnding = false
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
                let drag = NowPlayingDismissDragAction(
                    onChanged: { [weak self] in self?.dragChanged($0) },
                    onEnded: { [weak self] in self?.dragEnded($0, predicted: $1) }
                )
                let root = AnyView(value.content
                    .environment(\.dismissNowPlayingAction, { [weak self] in self?.close() })
                    .environment(\.dismissNowPlayingDragAction, drag))
                let host = NativeNowPlayingHost(rootView: root)
                self.host = host
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
            guard interaction == nil else { return }
            beginDismissal(requested: false)
        }

        private func dragChanged(_ translation: CGFloat) {
            guard active, translation.isFinite, !interactionEnding else { return }
            if interaction == nil {
                guard translation > 0, phase == .presented,
                      host?.presentedViewController == nil else { return }
                let driver = UIPercentDrivenInteractiveTransition()
                driver.completionCurve = .easeOut
                interaction = driver
                beginDismissal(requested: false)
                if phase != .dismissing { interaction = nil; return }
            }
            interaction?.update(NativeNowPlayingDismissPolicy.interactiveProgress(
                translation: translation, height: host?.view.bounds.height ?? 0
            ))
        }

        private func dragEnded(_ translation: CGFloat, predicted: CGFloat) {
            guard let interaction, !interactionEnding else { return }
            interactionEnding = true
            if NativeNowPlayingDismissPolicy.shouldRequestDismiss(
                translation: CGSize(width: 0, height: translation),
                predicted: CGSize(width: 0, height: predicted)
            ) {
                interaction.completionSpeed = completionSpeed(fraction: 1 - interaction.percentComplete)
                interaction.finish()
            } else {
                interaction.completionSpeed = completionSpeed(fraction: interaction.percentComplete)
                interaction.cancel()
            }
        }

        private func completionSpeed(fraction: CGFloat) -> CGFloat {
            // UIKit otherwise reverses a short pull in only a few milliseconds.
            // Give even that small excursion a visible, gentle rebound.
            let duration: CGFloat = UIAccessibility.isReduceMotionEnabled ? 0.22 : 0.48
            return max(0.01, min(1, fraction * duration / 0.3))
        }

        fileprivate func cancelInteraction() {
            guard let interaction, !interactionEnding else { return }
            interactionEnding = true
            interaction.completionSpeed = completionSpeed(fraction: interaction.percentComplete)
            interaction.cancel()
        }

        private func dismissalEnded(_ dismissed: NativeNowPlayingHost<AnyView>, completed: Bool) {
            guard host === dismissed else { return }
            interaction = nil
            interactionEnding = false
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

        func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
            interaction
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

private final class NativeNowPlayingHost<Content: View>: UIHostingController<Content> {
    // The player uses a dark artwork backdrop regardless of the library scheme.
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    var onAppear: (() -> Void)?

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
        let frame = opening ? context.finalFrame(for: controller) : context.initialFrame(for: controller)
        player.transform = .identity
        player.frame = frame
        if opening { container.addSubview(player) }
        player.layoutIfNeeded()

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
            self.animator = nil
            self.completion?(completed)
        }
        animator = spring
        return spring
    }
}
#endif
