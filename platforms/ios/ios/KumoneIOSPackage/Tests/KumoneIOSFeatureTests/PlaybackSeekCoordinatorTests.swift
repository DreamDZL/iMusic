import XCTest
import AVFoundation
@testable import KumoneCore

@MainActor
final class PlaybackSeekCoordinatorTests: XCTestCase {
    func testSwitchingToNextTrackAfterSeekInvalidatesOldCompletionAndStartsAtZero() {
        var coordinator = PlaybackSeekCoordinator()
        let oldTrackSeek = coordinator.beginSeek(to: 72, itemAvailable: true)

        coordinator.beginTrackChange(resumingAt: nil)

        XCTAssertFalse(coordinator.isCurrent(oldTrackSeek))
        XCTAssertNil(coordinator.pendingPosition)
        XCTAssertEqual(coordinator.initialPlaybackPosition, 0)
    }

    func testExplicitTrackResumePositionIsPreserved() {
        var coordinator = PlaybackSeekCoordinator()

        coordinator.beginTrackChange(resumingAt: 38.5)

        XCTAssertEqual(coordinator.initialPlaybackPosition, 38.5)
        XCTAssertEqual(coordinator.takePendingPosition(), 38.5)
        XCTAssertNil(coordinator.pendingPosition)
    }

    func testSeekDuringSourceResolutionIsQueuedForTheNewItem() {
        var coordinator = PlaybackSeekCoordinator()
        coordinator.beginTrackChange(resumingAt: nil)

        let request = coordinator.beginSeek(to: 21.25, itemAvailable: false)

        XCTAssertTrue(coordinator.isCurrent(request))
        XCTAssertEqual(coordinator.takePendingPosition(), 21.25)
        XCTAssertNil(coordinator.pendingPosition)
    }

    func testNewSeekInvalidatesEarlierPendingSeek() {
        var coordinator = PlaybackSeekCoordinator()
        let earlier = coordinator.beginSeek(to: 12, itemAvailable: false)
        let latest = coordinator.beginSeek(to: 47, itemAvailable: false)

        XCTAssertFalse(coordinator.isCurrent(earlier))
        XCTAssertTrue(coordinator.isCurrent(latest))
        XCTAssertEqual(coordinator.pendingPosition, 47)
    }

    func testInvalidationClearsQueuedPositionAndRejectsStaleCompletion() {
        var coordinator = PlaybackSeekCoordinator()
        let request = coordinator.beginSeek(to: 47, itemAvailable: false)

        coordinator.invalidate()

        XCTAssertFalse(coordinator.isCurrent(request))
        XCTAssertNil(coordinator.pendingPosition)
        XCTAssertEqual(coordinator.initialPlaybackPosition, 0)
    }

    func testAVPlayerTrackReplacementAfterSeekKeepsNextItemAtZero() async throws {
        let mediaURL = try makeSilentWave(durationSeconds: 45)
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        let previousItem = AVPlayerItem(url: mediaURL)
        let player = AVPlayer(playerItem: previousItem)
        guard await waitUntilReady(previousItem) else {
            XCTFail("The local audio item did not become ready: \(String(describing: previousItem.error))")
            return
        }

        var coordinator = PlaybackSeekCoordinator()
        let previousSeek = coordinator.beginSeek(to: 32, itemAvailable: true)
        let seekCompletion = expectation(description: "Outgoing seek settles after item replacement")
        player.seek(
            to: CMTime(seconds: 32, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { _ in
            seekCompletion.fulfill()
        }

        PlaybackItemTransition.prepareForTrackChange(
            player: player,
            coordinator: &coordinator,
            resumingAt: nil
        )
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(coordinator.isCurrent(previousSeek))
        XCTAssertEqual(coordinator.initialPlaybackPosition, 0)

        let nextItem = AVPlayerItem(url: mediaURL)
        player.replaceCurrentItem(with: nextItem)
        guard await waitUntilReady(nextItem) else {
            XCTFail("The replacement audio item did not become ready: \(String(describing: nextItem.error))")
            player.replaceCurrentItem(with: nil)
            return
        }
        await fulfillment(of: [seekCompletion], timeout: 10)

        XCTAssertTrue(player.currentItem === nextItem)
        XCTAssertEqual(nextItem.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        player.replaceCurrentItem(with: nil)
    }

    private func waitUntilReady(_ item: AVPlayerItem) async -> Bool {
        for _ in 0..<200 {
            if item.status == .readyToPlay { return true }
            if item.status == .failed { return false }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return item.status == .readyToPlay
    }

    private func makeSilentWave(durationSeconds: UInt32) throws -> URL {
        let sampleRate: UInt32 = 44_100
        let sampleBytes: UInt32 = 2
        let payloadSize = sampleRate * durationSeconds * sampleBytes
        var wave = Data()

        func appendASCII(_ value: String) {
            wave.append(contentsOf: value.utf8)
        }
        func appendUInt16(_ value: UInt16) {
            wave.append(UInt8(truncatingIfNeeded: value))
            wave.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func appendUInt32(_ value: UInt32) {
            wave.append(UInt8(truncatingIfNeeded: value))
            wave.append(UInt8(truncatingIfNeeded: value >> 8))
            wave.append(UInt8(truncatingIfNeeded: value >> 16))
            wave.append(UInt8(truncatingIfNeeded: value >> 24))
        }

        appendASCII("RIFF")
        appendUInt32(36 + payloadSize)
        appendASCII("WAVEfmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * sampleBytes)
        appendUInt16(UInt16(sampleBytes))
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(payloadSize)
        wave.append(Data(repeating: 0, count: Int(payloadSize)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imusic-seek-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try wave.write(to: url, options: .atomic)
        return url
    }
}
