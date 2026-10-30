import XCTest
@testable import KumoneCore

@MainActor
final class CatalogPlaylistLibraryTests: XCTestCase {
    private func makeStore() -> LocalPlaylistStore {
        let suiteName = "CatalogPlaylistLibraryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LocalPlaylistStore(defaults: defaults)
    }

    private func track(source: String = "tx", metadata: [String: String] = ["songmid": "song-1"]) -> Track {
        Track(
            id: 42,
            name: "测试歌曲",
            artists: [ArtistRef(id: 3, name: "歌手")],
            album: AlbumRef(id: 4, name: "专辑", picUrl: "https://example.com/cover.jpg"),
            durationMS: 180_000,
            source: source,
            sourceMetadata: metadata
        )
    }

    func testSaveDeduplicatesQQAliasesAndPreservesEditedCopyAndTrackMetadata() throws {
        let store = makeStore()
        let firstID = try store.saveCatalogPlaylist(
            source: "tx", playlistID: "playlist-1", name: "原歌单", tracks: [track()],
            coverURL: "https://example.com/list.jpg", sourceName: "QQ 音乐",
            intent: .verifiedCompletePlaylist, declaredTrackCount: 1
        )
        store.rename(id: firstID, name: "我的编辑版")
        let edited = try XCTUnwrap(store.playlist(id: firstID))

        let duplicateID = try store.saveCatalogPlaylist(
            source: "qq", playlistID: "playlist-1", name: "服务端新名称",
            tracks: [track(metadata: ["songmid": "changed", "vendor": "preserved?"])],
            coverURL: nil, sourceName: "QQ", intent: .loadedTracksSnapshot
        )

        XCTAssertEqual(duplicateID, firstID)
        XCTAssertEqual(store.playlists.count, 1)
        XCTAssertEqual(store.playlist(id: firstID), edited)
        XCTAssertEqual(store.playlist(id: firstID)?.isLocalCopy, true)
        XCTAssertEqual(store.playlist(id: firstID)?.tracks.first?.sourceMetadata, ["songmid": "song-1"])
    }

    func testSaveDeduplicatesNeteaseAliases() throws {
        let store = makeStore()
        let firstID = try store.saveCatalogPlaylist(
            source: "wy", playlistID: "123", name: "网易歌单", tracks: [track(source: "wy")],
            coverURL: nil, sourceName: "网易云", intent: .verifiedCompletePlaylist,
            declaredTrackCount: 1
        )
        let duplicateID = try store.saveCatalogPlaylist(
            source: "netease", playlistID: "123", name: "另一个名称", tracks: [track(source: "wy")],
            coverURL: nil, sourceName: "网易云", intent: .loadedTracksSnapshot
        )
        XCTAssertEqual(duplicateID, firstID)
        XCTAssertEqual(store.playlists.count, 1)
    }

    func testSavedPlaylistSurvivesReloadWithoutEnablingProviderRefresh() throws {
        let suiteName = "CatalogPlaylistLibraryTests.reload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = LocalPlaylistStore(defaults: defaults)
        let id = try store.saveCatalogPlaylist(
            source: "tx", playlistID: "persistent-list", name: "收藏的歌单", tracks: [track()],
            coverURL: "https://example.com/list.jpg", sourceName: "QQ 音乐",
            intent: .verifiedCompletePlaylist, declaredTrackCount: 1
        )
        let reloaded = LocalPlaylistStore(defaults: defaults)
        let saved = try XCTUnwrap(reloaded.playlist(id: id))
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.name, "收藏的歌单")
        XCTAssertEqual(saved.remoteSource, "tx")
        XCTAssertEqual(saved.remotePlaylistID, "persistent-list")
        XCTAssertEqual(saved.coverURL, "https://example.com/list.jpg")
        XCTAssertEqual(saved.tracks, store.playlist(id: id)?.tracks)
        XCTAssertEqual(saved.isLocalCopy, true)
        XCTAssertNotEqual(saved.providerSyncEnabled, true)
        XCTAssertEqual(reloaded.preparePlaylistsForLXSync().first?.lxSyncID, id.uuidString)
    }

    func testRejectsEmptyInvalidAndIncompletePlaylists() {
        XCTAssertThrowsError(try CatalogPlaylistSaveValidator.validate(
            source: " ", playlistID: "1", name: "歌单", tracks: [track()]
        ))
        XCTAssertThrowsError(try CatalogPlaylistSaveValidator.validate(
            source: "tx", playlistID: "1", name: "歌单", tracks: []
        ))
        XCTAssertThrowsError(try CatalogPlaylistSaveValidator.validate(
            source: "tx", playlistID: "1", name: "  ", tracks: [track()]
        ))
        XCTAssertThrowsError(try CatalogPlaylistSaveValidator.validate(
            source: "tx", playlistID: "1", name: "歌单", tracks: [track(name: "")]
        ))
        XCTAssertThrowsError(try CatalogPlaylistSaveValidator.validate(
            source: "tx", playlistID: "1", name: "歌单", tracks: [track()], declaredTrackCount: 2
        ))
    }

    func testAcceptsUnknownProviderTrackCountWithoutClaimingCompleteness() throws {
        XCTAssertFalse(LXPlaylistTrackCompleteness.isComplete(
            declaredCount: nil, rawCount: 3, parsedCount: 3
        ))
        let detail = detail(id: "unknown-count", source: .kg)
        XCTAssertFalse(detail.isTrackListComplete)
        XCTAssertNoThrow(try CatalogPlaylistSaveValidator.validate(
            source: "kg", playlistID: "special-1", name: "狗音乐歌单", tracks: [track(source: "kg")]
        ))
        let store = makeStore()
        XCTAssertNoThrow(try store.saveCatalogPlaylist(
            source: detail.source.rawValue,
            playlistID: detail.id,
            name: detail.name,
            tracks: detail.tracks,
            coverURL: detail.coverURL,
            sourceName: detail.source.displayName,
            intent: .loadedTracksSnapshot
        ))
    }

    func testDeclaredCountMustMatchRawAndParsedTrackCounts() {
        XCTAssertTrue(LXPlaylistTrackCompleteness.isComplete(
            declaredCount: 2, rawCount: 2, parsedCount: 2
        ))
        XCTAssertFalse(LXPlaylistTrackCompleteness.isComplete(
            declaredCount: 3, rawCount: 2, parsedCount: 2
        ))
        XCTAssertFalse(LXPlaylistTrackCompleteness.isComplete(
            declaredCount: 2, rawCount: 2, parsedCount: 1
        ))
    }

    func testDeclaredCountParserRejectsMalformedAndConflictingValues() {
        XCTAssertEqual(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": 12, "songnum": "12"], keys: ["total", "songnum"]
        ), 12)
        XCTAssertNil(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": 2, "songnum": 3], keys: ["total", "songnum"]
        ))
        XCTAssertNil(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": NSNumber(value: true)], keys: ["total"]
        ))
        XCTAssertNil(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": NSNumber(value: 2.5)], keys: ["total"]
        ))
        XCTAssertEqual(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": NSNumber(value: 2.0)], keys: ["total"]
        ), 2)
        XCTAssertNil(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": -1], keys: ["total"]
        ))
        XCTAssertNil(LXPlaylistTrackCompleteness.declaredCount(
            in: ["total": "999999999999999999999999999999999"], keys: ["total"]
        ))
    }

    func testNeteasePreviewWithoutDeclaredCountOrIDsIsNotComplete() {
        XCTAssertFalse(PlaylistTrackCompleteness.isComplete(
            declaredTrackCount: 0, authoritativeTrackIDs: [], resolvedTrackCount: 3
        ))
        XCTAssertTrue(PlaylistTrackCompleteness.isComplete(
            declaredTrackCount: 3, authoritativeTrackIDs: [], resolvedTrackCount: 3
        ))
        XCTAssertTrue(PlaylistTrackCompleteness.isComplete(
            declaredTrackCount: 0,
            authoritativeTrackIDs: [TrackIDRef(id: 1), TrackIDRef(id: 2)],
            resolvedTrackCount: 2
        ))
        XCTAssertFalse(PlaylistTrackCompleteness.isComplete(
            declaredTrackCount: 3,
            authoritativeTrackIDs: [TrackIDRef(id: 1), TrackIDRef(id: 2)],
            resolvedTrackCount: 2
        ))
    }

    func testLXDetailLoaderRejectsMismatchedIdentityWithRetryableError() async {
        let model = LXPlaylistDetailViewModel { source, id in
            self.detail(id: "wrong-id", source: source)
        }

        await model.load(source: .tx, playlistID: "requested", force: true)

        XCTAssertNil(model.detail)
        XCTAssertEqual(model.errorMessage, LXCatalogError.playlistIdentityMismatch.localizedDescription)
        XCTAssertFalse(model.isLoading)
    }

    func testLXDetailLoaderIgnoresOlderInterleavedResponse() async {
        let oldStarted = expectation(description: "old request started")
        var finishOld: CheckedContinuation<LXPlaylistDetail, Error>?
        let model = LXPlaylistDetailViewModel { source, id in
            if id == "old" {
                oldStarted.fulfill()
                return try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<LXPlaylistDetail, Error>) in
                    finishOld = continuation
                }
            }
            return self.detail(id: id, source: source)
        }

        let oldRequest = Task { await model.load(source: .tx, playlistID: "old", force: true) }
        await fulfillment(of: [oldStarted], timeout: 2)
        await model.load(source: .tx, playlistID: "new", force: true)
        finishOld?.resume(returning: detail(id: "old", source: .tx))
        await oldRequest.value

        XCTAssertEqual(model.detail?.id, "new")
        XCTAssertFalse(model.isLoading)
    }

    func testLXDetailLoaderCancellationDoesNotLeaveLoadingOrError() async {
        let model = LXPlaylistDetailViewModel { source, id in
            try await Task.sleep(for: .seconds(5))
            return self.detail(id: id, source: source)
        }
        let request = Task { await model.load(source: .tx, playlistID: "cancelled", force: true) }
        await Task.yield()
        request.cancel()
        await request.value

        XCTAssertNil(model.detail)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testCancelledFreshCacheReadFinishesLoadingAfterCancelledRefresh() async {
        let playlistID = "cache-cancel-\(UUID().uuidString)"
        let cached = detail(id: playlistID, source: .tx)
        LXPlaylistDetailCache.shared.save(cached)

        let refreshStarted = expectation(description: "refresh started")
        var finishRefresh: CheckedContinuation<LXPlaylistDetail, Error>?
        let model = LXPlaylistDetailViewModel { source, id in
            refreshStarted.fulfill()
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<LXPlaylistDetail, Error>) in
                finishRefresh = continuation
            }
        }

        let refresh = Task {
            await model.load(source: .tx, playlistID: playlistID, force: true)
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        refresh.cancel()

        let cacheRead = Task {
            await model.load(source: .tx, playlistID: playlistID)
        }
        cacheRead.cancel()
        await cacheRead.value
        finishRefresh?.resume(returning: cached)
        await refresh.value

        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.detail)
    }

    private func detail(id: String, source: LXCatalogPlatform) -> LXPlaylistDetail {
        LXPlaylistDetail(
            id: id,
            name: "测试歌单",
            coverURL: nil,
            description: nil,
            author: nil,
            playCount: 0,
            tracks: [track(source: source.rawValue)],
            source: source,
            declaredTrackCount: nil,
            isTrackListComplete: false
        )
    }
}

private extension CatalogPlaylistLibraryTests {
    func track(name: String) -> Track {
        Track(
            id: 42,
            name: name,
            artists: [ArtistRef(id: 3, name: "歌手")],
            album: AlbumRef(id: 4, name: "专辑", picUrl: nil),
            durationMS: 180_000,
            source: "tx"
        )
    }
}
