import XCTest
@testable import KumoneCore

final class LXSyncWireCodecTests: XCTestCase {
    func testSmallFramesRemainPlainJSON() throws {
        let message = "[0,\"request-1\",[\"finished\"],[],[]]"

        XCTAssertEqual(try LXSyncWireCodec.encode(message), message)
        XCTAssertEqual(try LXSyncWireCodec.decode(message), message)
    }

    func testRecognizesLXSyncMobileHeartbeatWithoutParsingItAsJSON() {
        XCTAssertTrue(LXSyncWireCodec.isHeartbeatFrame("ping"))
        XCTAssertFalse(LXSyncWireCodec.isHeartbeatFrame("pong"))
        XCTAssertFalse(LXSyncWireCodec.isHeartbeatFrame("[0,\"request\"]"))
    }

    func testLargePlaylistSnapshotUsesCompressedFrameAndRoundTrips() throws {
        let track = #"{"id":"tx_12345","name":"夜空中最亮的星","artist":"逃跑计划"}"#
        let tracks = Array(repeating: track, count: 40).joined(separator: ",")
        let message = "[0,\"request-2\",[\"onListSyncAction\"],[{\"action\":\"list_data_overwrite\",\"data\":{\"userList\":[\(tracks)]}}],[]]"

        let frame = try LXSyncWireCodec.encode(message)

        XCTAssertTrue(frame.hasPrefix("cg_"))
        XCTAssertEqual(try LXSyncWireCodec.decode(frame), message)
    }

    func testUTF16LengthMatchesLXJavaScriptCompressionThreshold() throws {
        let atThreshold = String(repeating: "🎵", count: 512)
        let aboveThreshold = atThreshold + "🎵"

        XCTAssertEqual(atThreshold.utf16.count, LXSyncWireCodec.compressionThreshold)
        XCTAssertEqual(try LXSyncWireCodec.encode(atThreshold), atThreshold)
        XCTAssertTrue(try LXSyncWireCodec.encode(aboveThreshold).hasPrefix("cg_"))
    }

    func testDecodesStandardGzipBase64Frame() throws {
        // Standard gzip member generated independently of the iMusic encoder.
        let fixture = "H4sIAAAAAAAACvOJUAiuzEtWyMwrSS3KL0gtSkzKzMksqVRIy6woKS1KVdBV8BlVMhouo4lhNJOMlgyjxWEejasJAJ4Xll6QBgAA"
        let expected = String(repeating: "LX Sync interoperability fixture - ", count: 48)

        XCTAssertEqual(try LXSyncWireCodec.decode("cg_" + fixture), expected)
    }

    func testRejectsCorruptedCompressedFrames() {
        XCTAssertThrowsError(try LXSyncWireCodec.decode("cg_not-base64!"))
        XCTAssertThrowsError(try LXSyncWireCodec.decode("cg_" + Data("not gzip".utf8).base64EncodedString()))
    }

    func testRejectsFramesWithCorruptedGzipChecksumOrSize() throws {
        let message = String(repeating: "playlist track metadata ", count: 100)
        let frame = try LXSyncWireCodec.encode(message)
        var gzip = Data(base64Encoded: String(frame.dropFirst(3)))!

        gzip[gzip.count - 8] ^= 0x01
        XCTAssertThrowsError(try LXSyncWireCodec.decode("cg_" + gzip.base64EncodedString()))

        gzip = Data(base64Encoded: String(frame.dropFirst(3)))!
        gzip[gzip.count - 4] ^= 0x01
        XCTAssertThrowsError(try LXSyncWireCodec.decode("cg_" + gzip.base64EncodedString()))
    }
}
