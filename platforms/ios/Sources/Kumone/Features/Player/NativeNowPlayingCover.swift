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
        coordinator.reconcile()
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        private enum Phase { case idle, presenting, presented, dismissing }
        fileprivate weak var presenter: UIViewController?
        fileprivate var active = true
        fileprivate var desired: Bool
        private var value: NativeNowPlayingCover
        private var host: NativeNowPlayingHost<Content>?
        private var phase: Phase = .idle
        private var revision = 0
        private var dismissalRevision = 0
        private var requestedDismissal = false

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
            host?.rootView = value.content
            reconcile()
        }

        fileprivate func reconcile() {
            switch phase {
            case .idle:
                guard active, desired, let presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil else { return }
                let host = NativeNowPlayingHost(rootView: value.content)
                self.host = host
                host.modalPresentationStyle = .fullScreen
                host.modalTransitionStyle = .crossDissolve
                host.preferredTransition = nil // Opening must remain UIKit's cross-dissolve.
                host.view.backgroundColor = .clear
                host.view.accessibilityViewIsModal = true
                host.onDismissalBegan = { [weak self] in self?.dismissalBegan() }
                host.onDismissalEnded = { [weak self, weak host] in
                    guard let host else { return }
                    self?.dismissalEnded(host)
                }
                host.onAppear = { [weak self] in self?.dismissalCancelled() }
                phase = .presenting
                // Retain the coordinator until UIKit finishes, including representable teardown.
                presenter.present(host, animated: true) { [self, weak host] in
                    guard let host, self.host === host else { return }
                    phase = .presented
                    host.presentationController?.delegate = self
                    reconcile()
                }
            case .presented:
                guard !desired, let host, let owner = host.presentingViewController,
                      owner.presentedViewController === host else { return }
                requestedDismissal = true
                dismissalRevision = revision
                phase = .dismissing
                // Install zoom only after the deliberate dismissal request.
                // Installing it while idle also installs UIKit's interactive
                // gestures, which can bypass the short-pull rejection policy.
                host.preferredTransition = .zoom { [weak self] _ in
                    guard let view = self?.value.source.view, view.window != nil,
                          !view.bounds.isEmpty,
                          view.bounds.origin.x.isFinite, view.bounds.origin.y.isFinite,
                          view.bounds.width.isFinite, view.bounds.height.isFinite else { return nil }
                    return view
                }
                owner.dismiss(animated: true) { [self, weak host] in
                    guard let host else { return }
                    dismissalEnded(host)
                }
            case .presenting, .dismissing:
                break // The completion reconciles the latest request, never an old snapshot.
            }
        }

        private func dismissalBegan() {
            guard phase == .presented else { return }
            requestedDismissal = false
            dismissalRevision = revision
            phase = .dismissing
        }

        private func dismissalCancelled() {
            guard phase == .dismissing, let host,
                  !host.isBeingDismissed, host.presentingViewController != nil else { return }
            phase = .presented
            host.preferredTransition = nil
            requestedDismissal = false
            reconcile()
        }

        private func dismissalEnded(_ dismissed: NativeNowPlayingHost<Content>) {
            guard host === dismissed else { return }
            dismissed.onDismissalBegan = nil
            dismissed.onDismissalEnded = nil
            dismissed.onAppear = nil
            host = nil
            phase = .idle
            // An interactive completion closes the binding unless a newer request superseded it.
            if active, !requestedDismissal, revision == dismissalRevision {
                desired = false
                if value.isPresented { value.isPresented = false }
            }
            requestedDismissal = false
            reconcile()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let host, presentationController.presentedViewController === host else { return }
            dismissalEnded(host)
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

    var onDismissalBegan: (() -> Void)?
    var onDismissalEnded: (() -> Void)?
    var onAppear: (() -> Void)?

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { onDismissalBegan?() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A child full-screen sheet also hides this view, but does not dismiss this controller.
        guard isBeingDismissed || presentingViewController == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onDismissalEnded?() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // This controller is presented outside SwiftUI's cover machinery.
        // Keep VoiceOver/XCTest in the visible modal, not the retained library.
        view.accessibilityViewIsModal = true
        UIAccessibility.post(notification: .screenChanged, argument: nil)
        onAppear?() // Interactive cancellation returns here without a completed disappearance.
    }
}
#endif
