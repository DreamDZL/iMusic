#if os(iOS) && DEBUG
import SwiftUI
import UIKit

/// Debug-only UIKit control experiment; never use this as the shipping player.
/// UIKit owns presentation and gestures: no SwiftUI presentation bindings,
/// private APIs, recognizer changes, custom animators, or custom drag handling.
struct NativeZoomRuntimeProbe: UIViewControllerRepresentable {
    let usesZoom: Bool

    func makeUIViewController(context: Context) -> NativeZoomProbeSourceController {
        NativeZoomProbeSourceController(usesZoom: usesZoom)
    }

    func updateUIViewController(_ controller: NativeZoomProbeSourceController, context: Context) {
        // The mode is fixed for this controller's lifetime; recreate to change it.
    }
}

final class NativeZoomProbeSourceController: UIViewController {
    private let usesZoom: Bool
    private let openButton = UIButton(type: .system)

    init(usesZoom: Bool) {
        self.usesZoom = usesZoom
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // Leave the root non-accessible so the real source button is searchable.
        openButton.setTitle("Open Native UIKit Probe", for: .normal)
        openButton.accessibilityIdentifier = "nativeUIKitProbeOpen"
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.addTarget(self, action: #selector(openProbe), for: .touchUpInside)
        view.addSubview(openButton)
        NSLayoutConstraint.activate([
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @objc private func openProbe() {
        guard presentedViewController == nil else { return }
        let destination = NativeZoomProbeDestinationController()
        if usesZoom {
            destination.modalPresentationStyle = .fullScreen
            let options = UIViewController.Transition.ZoomOptions()
            options.interactiveDismissShouldBegin = { [weak destination] _ in
                destination?.recordInteractiveDismissCallback()
                return true
            }
            let sourceButton = openButton
            destination.preferredTransition = .zoom(options: options) { [weak sourceButton] _ in
                guard let sourceButton, sourceButton.window != nil,
                      !sourceButton.isHidden, !sourceButton.bounds.isEmpty else { return nil }
                return sourceButton
            }
        } else {
            destination.modalPresentationStyle = .pageSheet
            destination.sheetPresentationController?.detents = [.large()]
            destination.sheetPresentationController?.prefersGrabberVisible = true
        }
        present(destination, animated: true)
    }
}

final class NativeZoomProbeDestinationController: UIViewController {
    private var ready = false
    private var callbackCount = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        // This solid view is the entire test destination, not an underlay mask.
        view.backgroundColor = .systemTeal
        view.accessibilityIdentifier = "nativeUIKitProbeDestination"
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Native UIKit probe"
        updateAccessibilityValue()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ready = true
        updateAccessibilityValue()
    }

    func recordInteractiveDismissCallback() {
        callbackCount += 1
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        view.accessibilityValue = "ready=\(ready); callbackCount=\(callbackCount)"
    }
}
#endif
