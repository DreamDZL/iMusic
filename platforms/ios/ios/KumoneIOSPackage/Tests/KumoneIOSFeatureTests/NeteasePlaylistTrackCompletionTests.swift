import XCTest
@testable import KumoneCore

final class NeteasePlaylistTrackCompletionTests: XCTestCase {
    func testCompletionFillsMissingTracksAndPreservesPlaylistOrderAndDuplicates() async throws {
        let preview = [Self.track(id: 3), Self.track(id: 1)]
        let complete = try await NeteaseAPI.completePlaylistTracks(
            expectedTrackIDs: [1, 2, 1, 3],
            declaredTrackCount: 4,
            previewTracks: preview,
            fetchDetails: { ids in
                XCTAssertEqual(ids, [2])
                return NeteaseAPI.SongDetailResponse(songs: [Self.track(id: 2)], privileges: nil)
            }
        )

        XCTAssertEqual(complete.tracks.map(\.id), [1, 2, 1, 3])
    }

    func testPartialDetailResponseFailsInsteadOfReturningTruncatedPlaylist() async {
        do {
            _ = try await NeteaseAPI.completePlaylistTracks(
                expectedTrackIDs: [1, 2, 3],
                declaredTrackCount: 3,
                previewTracks: [Self.track(id: 1)],
                fetchDetails: { ids in
                    XCTAssertEqual(ids, [2, 3])
                    return NeteaseAPI.SongDetailResponse(songs: [Self.track(id: 2)], privileges: nil)
                }
            )
            XCTFail("A partial detail response must not be accepted")
        } catch NeteaseAPIError.incompletePlaylist(let expected, let received) {
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(received, 2)
        } catch {
            XCTFail("Expected incompletePlaylist, received \(error)")
        }
    }

    func testDetailRequestFailurePropagatesWithoutReturningPreview() async {
        do {
            _ = try await NeteaseAPI.completePlaylistTracks(
                expectedTrackIDs: [1, 2],
                declaredTrackCount: 2,
                previewTracks: [Self.track(id: 1)],
                fetchDetails: { _ in throw FixtureError.requestFailed }
            )
            XCTFail("A failed detail request must fail playlist completion")
        } catch FixtureError.requestFailed {
            // Expected: the caller must report the failed import.
        } catch {
            XCTFail("Expected request failure, received \(error)")
        }
    }

    func testDeclaredCountLargerThanTrackIDListFailsBeforeFetching() async {
        do {
            _ = try await NeteaseAPI.completePlaylistTracks(
                expectedTrackIDs: [1, 2],
                declaredTrackCount: 3,
                previewTracks: [Self.track(id: 1), Self.track(id: 2)],
                fetchDetails: { _ in
                    XCTFail("No request should hide a missing track ID list")
                    return NeteaseAPI.SongDetailResponse(songs: [], privileges: nil)
                }
            )
            XCTFail("An incomplete authoritative ID list must fail")
        } catch NeteaseAPIError.incompletePlaylist(let expected, let received) {
            XCTAssertEqual(expected, 3)
            XCTAssertEqual(received, 2)
        } catch {
            XCTFail("Expected incompletePlaylist, received \(error)")
        }
    }

    func testPublicBusinessErrorIsNotReportedAsMalformedPlaylist() {
        XCTAssertNoThrow(try NeteaseAPI.validatePublicResponseCode(200, message: nil))
        XCTAssertNoThrow(try NeteaseAPI.validatePublicResponseCode(nil, message: nil))

        XCTAssertThrowsError(try NeteaseAPI.validatePublicResponseCode(429, message: "rate limited")) { error in
            guard case NeteaseAPIError.business(let code, let message) = error else {
                return XCTFail("Expected a NetEase business error, received \(error)")
            }
            XCTAssertEqual(code, 429)
            XCTAssertEqual(message, "rate limited")
        }
    }

    private static func track(id: Int) -> Track {
        Track(
            id: id,
            name: "Track \(id)",
            artists: [ArtistRef(id: 7, name: "Artist")],
            album: AlbumRef(id: 9, name: "Album", picUrl: nil),
            durationMS: 180_000,
            source: "wy"
        )
    }

    private enum FixtureError: Error {
        case requestFailed
    }
}
