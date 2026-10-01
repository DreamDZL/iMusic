import Combine
import Foundation

/// Keeps decorative and frame-driven UI work within a device-aware frame
/// budget. Audio decoding and playback are left to AVFoundation; only visual
/// refreshes are reduced when Low Power Mode or thermal pressure is active.
@MainActor
final class RenderingBudget: ObservableObject {
    static let shared = RenderingBudget()

    @Published private(set) var minimumAnimationInterval: TimeInterval

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let processInfo = ProcessInfo.processInfo
        minimumAnimationInterval = 1.0 / 30.0
        // Apple requires reading the thermal state before registering for its
        // change notification. The refresh after observer registration also
        // closes the small race where the device changes state during setup.
        _ = processInfo.thermalState

        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .merge(with: NotificationCenter.default.publisher(
                for: ProcessInfo.thermalStateDidChangeNotification
            ))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            .store(in: &cancellables)

        refresh()
    }

    static func interval(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> TimeInterval {
        if thermalState == .serious || thermalState == .critical {
            return 1.0 / 10.0
        }
        if lowPowerMode || thermalState == .fair {
            return 1.0 / 15.0
        }
        return 1.0 / 30.0
    }

    private func refresh() {
        let processInfo = ProcessInfo.processInfo
        minimumAnimationInterval = Self.interval(
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState
        )
    }
}
