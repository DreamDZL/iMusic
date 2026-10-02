import XCTest
@testable import KumoneCore

final class EqualizerProcessingGateTests: XCTestCase {
    func testDisabledEqualizerSkipsAudioThreadLock() {
        let gate = EqualizerProcessingGate()
        XCTAssertFalse(gate.shouldEnterProcessingLock(frameCount: 512))
        gate.setEnabled(true)
        XCTAssertTrue(gate.shouldEnterProcessingLock(frameCount: 512))
        gate.setEnabled(false)
        XCTAssertFalse(gate.shouldEnterProcessingLock(frameCount: 512))
    }

    func testEnabledEqualizerProcessesNonemptyAudioBuffers() {
        XCTAssertTrue(MoumusicEqualizer.shouldProcessLockedBuffer(
            frameCount: 512,
            isEnabled: true,
            supportsFloat32: true
        ))
        XCTAssertFalse(MoumusicEqualizer.shouldProcessLockedBuffer(
            frameCount: 512,
            isEnabled: false,
            supportsFloat32: true
        ))
    }

    func testEmptyAudioBufferNeverEntersProcessingLock() {
        XCTAssertFalse(MoumusicEqualizer.shouldProcessLockedBuffer(
            frameCount: 0,
            isEnabled: true,
            supportsFloat32: true
        ))
    }

    func testUnsupportedAudioFormatSkipsEqualizerProcessing() {
        XCTAssertFalse(MoumusicEqualizer.shouldProcessLockedBuffer(
            frameCount: 512,
            isEnabled: true,
            supportsFloat32: false
        ))
    }
}
