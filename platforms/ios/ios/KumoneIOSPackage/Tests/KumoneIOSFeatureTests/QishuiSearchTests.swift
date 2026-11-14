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
    }

    func testMalformedOrNumericIdentityDoesNotLosePrecision() {
        XCTAssertNil(QishuiSearch.track(["base_info": ["id": 7_676_337_516_358_617_115, "name": "x"]]))
        XCTAssertNil(QishuiSearch.track(["base_info": ["id": "not-an-id", "name": "x"]]))
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

private final class QishuiMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response: [String: Any]
        if url.path.contains("/client/token/") {
            response = ["err_no": 0, "client_token": "test-token"]
        } else {
            var requestBody = request.httpBody
            if requestBody == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                requestBody = data
            }
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
