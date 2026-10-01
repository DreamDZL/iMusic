import Foundation
import XCTest
@testable import KumoneCore

final class LXSyncReconnectPolicyTests: XCTestCase {
    func testRetryDelayGrowsToOneMinuteCeiling() {
        let expected = [1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0]

        for (attempt, seconds) in expected.enumerated() {
            XCTAssertEqual(LXSyncReconnectPolicy.delaySeconds(attempt: attempt), seconds)
        }
        XCTAssertEqual(LXSyncReconnectPolicy.delaySeconds(attempt: -1), 1.0)
    }

    func testOnlyTransientURLFailuresAreRetried() {
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableNetworkFailure(URLError(.timedOut)))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableNetworkFailure(URLError(.networkConnectionLost)))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableNetworkFailure(URLError(.badURL)))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableNetworkFailure(URLError(.cancelled)))
    }

    func testOnlyServerErrorsAreRetryableHTTPResponses() {
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableHTTPStatus(500))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableHTTPStatus(503))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableHTTPStatus(401))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableHTTPStatus(403))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableHTTPStatus(404))
    }

    func testSocketCloseCodesSeparateServerRestartsFromProtocolRejections() {
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketClose(.goingAway))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketClose(.abnormalClosure))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketClose(.internalServerError))

        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableSocketClose(.normalClosure))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableSocketClose(.protocolError))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableSocketClose(.policyViolation))
    }

    func testSocketHandshakeRetriesServerErrorsButStopsOnClientErrors() {
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.badServerResponse), closeCode: .invalid, responseStatusCode: 503
        ))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.badServerResponse), closeCode: .invalid, responseStatusCode: 401
        ))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.badServerResponse), closeCode: .noStatusReceived, responseStatusCode: 401
        ))
        XCTAssertFalse(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.badServerResponse), closeCode: .goingAway, responseStatusCode: 403
        ))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.networkConnectionLost), closeCode: .goingAway, responseStatusCode: 101
        ))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.timedOut), closeCode: .invalid, responseStatusCode: 101
        ))
        XCTAssertTrue(LXSyncReconnectPolicy.isRetryableSocketFailure(
            URLError(.timedOut), closeCode: .invalid, responseStatusCode: nil
        ))
    }
}
