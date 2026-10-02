import Combine
import Foundation

/// Budgets decorative rendering and optional audio analysis for the current
/// power, thermal, and scene-visibility state. Audio playback stays in AVFoundation.
@MainActor
final class RenderingBudget: ObservableObject {
    static let shared = RenderingBudget()

    @Published private(set) var minimumAnimationInterval: TimeInterval
    @Published private(set) var audioAnalysisStride: Int
    @Published private(set) var isSceneActive = true
    @Published private(set) var allowsContinuousEffects = true

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let processInfo = ProcessInfo.processInfo
        minimumAnimationInterval = 1.0 / 30.0
        audioAnalysisStride = 4
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

    nonisolated static func interval(
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

    /// Audio is processed in 512-frame windows (~86 windows/sec at 44.1 kHz).
    /// Sampling fewer windows keeps the playing indicator responsive while
    /// reducing FFT work on the real-time audio thread.
    nonisolated static func audioStride(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Int {
        if thermalState == .serious || thermalState == .critical { return 12 }
        if lowPowerMode || thermalState == .fair { return 6 }
        return 4
    }

    nonisolated static func permitsContinuousEffects(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        !lowPowerMode && thermalState == .nominal
    }

    nonisolated static func permitsAudioAnalysis(isSceneActive: Bool) -> Bool {
        isSceneActive
    }

    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        AudioSpectrum.shared.setAnalysisEnabled(Self.permitsAudioAnalysis(isSceneActive: active))
    }

    private func refresh() {
        let processInfo = ProcessInfo.processInfo
        let lowPowerMode = processInfo.isLowPowerModeEnabled
        let thermalState = processInfo.thermalState
        minimumAnimationInterval = Self.interval(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
        allowsContinuousEffects = Self.permitsContinuousEffects(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
        let stride = Self.audioStride(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
        if audioAnalysisStride != stride {
            audioAnalysisStride = stride
            AudioSpectrum.shared.setAnalysisStride(stride)
        }
    }
}
