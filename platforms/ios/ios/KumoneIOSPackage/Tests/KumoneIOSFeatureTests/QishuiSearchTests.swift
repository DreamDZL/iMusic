import XCTest
@testable import KumoneCore

@MainActor
final class QishuiSearchTests: XCTestCase {
    func testPublicTrackPreservesStringIDBeyondJavaScriptIntegerPrecision() throws {
        let id = "7676337516358617115"
        let raw: [String: Any] = ["track_entity": [
            "base_info": ["id": id, "name": "测试歌曲", "duration_ms": 237_336],
            "related_info": ["artist_links": [["id": "1", "name": "测试歌手"]],
                             "album_link": ["id": "2", "name": "测试专辑"]]
        ]]
        let track = try XCTUnwrap(QishuiSearch.track(raw))
        XCTAssertEqual(track.source, "sd")
        XCTAssertEqual(track.sourceMetadata["songmid"], id)
        XCTAssertEqual(String(track.id), id)
        XCTAssertEqual(track.artistNames, "测试歌手")
        XCTAssertEqual(track.durationMS, 237_336)
    }

    func testSearchSourceChoicesAndLXAliases() {
        XCTAssertEqual(LXCatalogPlatform.catalogueCases.map(\.rawValue), ["aggregate", "kw", "kg", "tx", "wy", "sd"])
        XCTAssertFalse(LXCatalogPlatform.discoveryCases.contains(.sd))
        XCTAssertEqual(LXCatalogPlatform.displayName(for: "qs"), "汽水音乐")
        XCTAssertEqual(LXUserAPIService.protocolSource("sd", capabilities: ["qs": ["musicUrl"]]), "qs")
        XCTAssertEqual(LXUserAPIService.protocolSource("sd", capabilities: ["sd": ["musicUrl"]]), "sd")
        XCTAssertEqual(LXUserAPIService.protocolSource("sd", capabilities: ["sd": ["musicUrl"], "qs": ["lyric"]]), "sd")
        XCTAssertEqual(LXUserAPIService.protocolSource("sd", capabilities: ["sd": ["musicUrl"], "qs": ["lyric"]], action: "lyric"), "qs")
    }

    func testMalformedOrNumericIdentityDoesNotLosePrecision() {
        XCTAssertNil(QishuiSearch.track(["base_info": ["id": 7_676_337_516_358_617_115, "name": "x"]]))
        XCTAssertNil(QishuiSearch.track(["base_info": ["id": "not-an-id", "name": "x"]]))
    }

    func testActualPublicCatalogueShapeKeepsAlbumAndUsableCover() throws {
        let track = try XCTUnwrap(QishuiSearch.track(QishuiMockProtocol.catalogueTrack))
        XCTAssertEqual(track.album.name, "Fixture DJ album")
        XCTAssertEqual(track.album.id, 7_409_001_029_981_653_004)
        XCTAssertEqual(track.sourceMetadata["albumId"], "7409001029981653004")
        XCTAssertEqual(track.album.picUrl, "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/fixture~tplv-b829550vbb-crop-center:720:720.jpg")
        XCTAssertEqual(QishuiAPI.track(from: QishuiMockProtocol.catalogueTrack)?.album, track.album)
    }

    func testLegacyDiscoveryWrapperDoesNotDropAlbumMetadata() throws {
        let track = try XCTUnwrap(QishuiAPI.track(from: ["track": [
            "id": "7409001029981636620", "name": "Fixture DJ song", "duration": 202_632,
            "artists": [["name": "Fixture artist"]], "album": ["id": "1", "name": "Fixture album",
            "url_cover": ["uri": "tos-cn-v-2774c002/fixture", "urls": ["https://p3-luna.douyinpic.com/img/"]]]
        ]]))
        XCTAssertEqual(track.album.name, "Fixture album")
        XCTAssertNotNil(track.album.picUrl)
    }

    func testMissingOrOversizedPublicLyricsAreNotPublished() {
        func raw(_ value: [String: Any]) -> [String: Any] { ["display_info": ["lyric_info": ["lyric_entity": value]]] }
        XCTAssertNil(QishuiSearch.lyrics(raw(["type": "encrypted", "content": "not public text"])))
        XCTAssertNil(QishuiSearch.lyrics(raw(["type": "lrc", "content": String(repeating: "a", count: 262_145)])))
        XCTAssertNil(QishuiSearch.lyrics(raw(["type": "krc", "content": "[bad]not timed"])))
        XCTAssertEqual(QishuiSearch.lyrics(raw(["type": "lrc", "content": "[00:01.000]fixture"]))?.lyric, "[00:01.000]fixture")
    }

    func testCoverValidationAndCompleteURLAreNotRewritten() {
        let complete = "https://p3-luna.douyinpic.com/img/fixture.jpg?signature=fixture"
        XCTAssertEqual(QishuiSearch.imageURL(["need_complete_url": true, "urls": [complete], "uri": "ignored"]), complete)
        XCTAssertNil(QishuiSearch.imageURL(["urls": ["https://evil.invalid/"], "uri": "fixture"]))
        XCTAssertNil(QishuiSearch.imageURL(["urls": ["https://p3.douyinpic.com/"], "uri": "../fixture"]))
        XCTAssertNil(QishuiSearch.imageURL(["urls": ["https://user:pass@p3.douyinpic.com/"], "uri": "fixture"]))
        XCTAssertNil(QishuiSearch.imageURL(["urls": ["https://p3.douyinpic.com/"], "uri": "fixture", "template_prefix": "x?redirect=evil"]))
    }

    func testPublicKRCIsConvertedToTimedLinesAndRelativeWordTimings() throws {
        let native = try XCTUnwrap(QishuiSearch.lyrics(QishuiMockProtocol.catalogueTrack))
        XCTAssertEqual(native.lyric, "[00:01.470]测试\n[01:02.345]歌词")
        let parsed = LyricsParser.parseLX(lyric: native.lyric, rlyric: native.rlyric, lxlyric: native.lxlyric)
        XCTAssertEqual(parsed.lines.map(\.text), ["测试", "歌词"])
        XCTAssertEqual(parsed.lines[0].time, 1.47, accuracy: 0.001)
        XCTAssertEqual(parsed.lines[0].words?[1].start ?? 0, 1.62, accuracy: 0.001)
        XCTAssertEqual(parsed.lines[1].time, 62.345, accuracy: 0.001)
        XCTAssertNil(parsed.lines[0].romaji)
    }

    func testOldSavedTrackCanFetchPublicDetailAndNativeLyricsWithoutAudio() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QishuiMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = QishuiSearch(session: session)
        let old = Track(id: 7_409_001_029_981_636_620, name: "old saved title", artists: [],
                        album: AlbumRef(id: 0, name: "", picUrl: nil), durationMS: 0,
                        source: "sd", sourceMetadata: ["songmid": "7409001029981636620"])
        let updated = try await service.metadata(for: old)
        let native = try await service.nativeLyrics(for: old)
        XCTAssertEqual(updated.album.name, "Fixture DJ album")
        XCTAssertEqual(updated.durationMS, 202_632)
        XCTAssertEqual(updated.sourceMetadata["songmid"], old.sourceMetadata["songmid"])
        XCTAssertEqual(native.lyric, "[00:01.470]测试\n[01:02.345]歌词")
        XCTAssertNil(updated.sourceMetadata["player_info"])
    }

    func testAlreadyCancelledPublicDetailDoesNotStartNetworkWork() async throws {
        let service = QishuiSearch()
        let track = try XCTUnwrap(QishuiSearch.track(QishuiMockProtocol.catalogueTrack))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.metadata(for: track)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled metadata work must not return a track")
        } catch is CancellationError {
        }
    }

    func testSavedAuxiliaryIDCannotReplacePlaybackIdentityForMetadataOrLyrics() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QishuiMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = QishuiSearch(session: session)
        let old = Track(id: 7_409_001_029_981_636_620, name: "old saved title", artists: [],
                        album: AlbumRef(id: 0, name: "", picUrl: nil), durationMS: 0,
                        source: "sd", sourceMetadata: ["songmid": "7409001029981636620", "qishuiTrackID": "999"])
        let catalogue = try await service.metadata(for: old)
        XCTAssertNotNil(old.mergingQishuiMetadata(catalogue))
        let native = try await service.nativeLyrics(for: old)
        XCTAssertEqual(native.lyric, "[00:01.470]测试\n[01:02.345]歌词")
    }

    func testLXBridgeRecognizesQishuiDeclaration() async throws {
        let source = LXSourceStore.Source(
            id: "qishui-alias-fixture", name: "fixture", description: "",
            version: "1", author: "tests", homepage: "https://example.invalid",
            script: #"""
            lx.on(lx.EVENT_NAMES.request, async ({source, info}) => {
                if (source !== 'qs' || info.musicInfo.songmid !== '7676337516358617115') {
                    throw new Error('wrong Qishui identity')
                }
                return 'https://example.invalid/audio.mp3'
            })
            lx.send(lx.EVENT_NAMES.inited, {
                status: true,
                sources: { qs: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } }
            })
            """#,
            sourceURL: nil
        )
        let service = LXUserAPIService.shared
        service.load(source)
        defer { service.loadSelectedSource() }
        for _ in 0..<40 where service.capabilities["sd"] == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(service.capabilities["sd"], ["musicUrl"])
        XCTAssertEqual(service.qualityCapabilities["sd"], ["128k"])
    }

    func testPaginationFillsPagesAcrossFixedProviderBatches() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QishuiMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = QishuiSearch(session: session)
        let first = try await service.search("fixture", page: 1, limit: 30)
        let second = try await service.search("fixture", page: 2, limit: 30)
        XCTAssertEqual(first.count, 30)
        XCTAssertEqual(second.count, 30)
        XCTAssertEqual(first.map(\.id), Array(1...30))
        XCTAssertEqual(second.map(\.id), Array(31...60))
    }
}

final class QishuiMockProtocol: URLProtocol {
    static var catalogueTrack: [String: Any] {
        ["track_entity": [
            "base_info": ["id": "7409001029981636620", "name": "Fixture DJ song", "duration_ms": 202_632],
            "related_info": ["artist_links": [["id": "7395696133375346738", "name": "Fixture artist"]],
                             "album_link": ["id": "7409001029981653004", "name": "Fixture DJ album"]],
            "display_info": [
                "cover_url": ["need_complete_url": false, "template_prefix": "tplv-b829550vbb",
                              "uri": "tos-cn-v-2774c002/fixture", "urls": ["https://p3-luna.douyinpic.com/img/"]],
                "lyric_info": ["lyric_entity": ["type": "krc", "content": "[1470,300]<0,150,0>测<150,150,0>试\n[62345,200]<0,100,0>歌<100,100,0>词"]]
            ],
            "player_info": ["excluded": "must never enter the Track model"]
        ]]
    }

    static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response: [String: Any]
        if url.path.contains("/client/token/") {
            response = ["err_no": 0, "client_token": "test-token"]
        } else if url.path.contains("/media/mget/") {
            let object = Self.requestBody(request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let media = object?["media_list"] as? [[String: Any]]
            XCTAssertEqual(media?.first?["id"] as? String, "7409001029981636620")
            response = ["err_no": 0, "data": ["media_list": [Self.catalogueTrack]]]
        } else {
            let requestBody = Self.requestBody(request)
            let body = requestBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let cursor = Int(body["cursor"] as? String ?? "0") ?? 0
            let end = min(cursor + 20, 80)
            let rows: [[String: Any]] = (cursor..<end).map { index in
                ["entity": ["track": ["base_info": ["id": String(index + 1), "name": "track \(index + 1)"]]]]
            }
            response = ["err_no": 0, "data": ["result_groups": [["id": "tracks", "data": rows,
                          "has_more": end < 80, "next_cursor": String(end)]]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
