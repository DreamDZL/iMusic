import Foundation
import XCTest
@testable import KumoneCore

final class PlaylistImportQueryTests: XCTestCase {
    func testRepeatedCaseInsensitiveParametersUseFirstNonEmptyValue() throws {
        let url = try XCTUnwrap(URL(string:
            "https://y.qq.com/n/ryqq/playlist?disstid=&DISSTID=first&disstid=second"
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        let values = PlaylistImportQuery.firstNonEmptyValues(from: items)

        XCTAssertEqual(values["disstid"], "first")
    }

    func testDifferentParametersRemainAvailable() throws {
        let url = try XCTUnwrap(URL(string:
            "https://y.qq.com/n/ryqq/playlist?disstid=42&source=share"
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        let values = PlaylistImportQuery.firstNonEmptyValues(from: items)

        XCTAssertEqual(values["disstid"], "42")
        XCTAssertEqual(values["source"], "share")
    }

    func testNetEasePlaylistIDSkipsEmptyRepeatedParameters() throws {
        let url = try XCTUnwrap(URL(string:
            "https://music.163.com/#/playlist?id=&ID=123456&id=789"
        ))
        let fragment = try XCTUnwrap(url.fragment)
        let items = try XCTUnwrap(URLComponents(string: fragment)?.queryItems)

        XCTAssertEqual(PlaylistImportQuery.firstIntegerValue(for: "id", from: items), 123456)
    }
}
