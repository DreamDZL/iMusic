#if os(iOS)
import SwiftUI
import UIKit
import QuartzCore

/// A short-lived ProMotion request for interaction, separate from the much
/// slower decorative background budget. The OS still owns actual scheduling.
@MainActor
final class PlayerMotionFrameRateLease: NSObject, ObservableObject {
    weak var window: UIWindow?
    private var link: CADisplayLink?
    private var deadline: CFTimeInterval = 0
    private lazy var target = TickTarget(owner: self)

    static func range(maximum: Int, lowPower: Bool,
                      thermal: ProcessInfo.ThermalState) -> CAFrameRateRange {
        let panel = Float(max(1, maximum))
        let constrained = lowPower || thermal == .serious || thermal == .critical
        let ceiling = min(panel, constrained ? 60 : panel)
        return CAFrameRateRange(minimum: min(ceiling, 80), maximum: ceiling, preferred: ceiling)
    }

    func request(duration: TimeInterval = 0.85) {
        guard let window, window.windowScene?.activationState == .foregroundActive,
              !UIAccessibility.isReduceMotionEnabled, duration.isFinite, duration > 0 else { return }
        deadline = CACurrentMediaTime() + min(duration, 2)
        let displayLink: CADisplayLink
        if let link { displayLink = link }
        else {
            displayLink = CADisplayLink(target: target, selector: #selector(TickTarget.tick(_:)))
            link = displayLink
            displayLink.add(to: .main, forMode: .common)
        }
        displayLink.preferredFrameRateRange = Self.range(
            maximum: window.screen.maximumFramesPerSecond,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: ProcessInfo.processInfo.thermalState)
    }

    func stop() {
        link?.invalidate()
        link = nil
        deadline = 0
    }

    private func tick(_ displayLink: CADisplayLink) {
        if CACurrentMediaTime() >= deadline || window?.windowScene?.activationState != .foregroundActive {
            stop()
        }
    }

    deinit { link?.invalidate() }

    @MainActor
    private final class TickTarget: NSObject {
        weak var owner: PlayerMotionFrameRateLease?
        init(owner: PlayerMotionFrameRateLease) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
}

struct PlayerMotionFrameRateAnchor: UIViewRepresentable {
    let lease: PlayerMotionFrameRateLease

    func makeUIView(context: Context) -> UIView { Anchor(lease: lease) }
    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? Anchor)?.lease = lease
        lease.window = uiView.window
    }
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        (uiView as? Anchor)?.lease?.stop()
    }

    private final class Anchor: UIView {
        weak var lease: PlayerMotionFrameRateLease?
        init(lease: PlayerMotionFrameRateLease) {
            self.lease = lease
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            lease?.window = window
            if window == nil { lease?.stop() }
        }
    }
}
#endif
