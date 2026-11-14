import XCTest
@testable import KumoneCore

@MainActor
final class LXQishuiBridgeTests: XCTestCase {
    private let id = "7409001029981636620"

    private func track(name: String = "fixture") -> Track {
        Track(id: Int(id)!, name: name, artists: [ArtistRef(id: 1, name: "fixture artist")],
              album: AlbumRef(id: 2, name: "fixture album", picUrl: nil), durationMS: 202_632,
              source: "sd", sourceMetadata: ["songmid": id, "qishuiTrackID": id])
    }

    private func imported(_ script: String, id: String = "sanitized-qishui-fixture") throws -> LXSourceStore.Source {
        // Exercise the actual JSON export parser, not a hand-built Source.
        let json: [String: Any] = ["data": ["info": ["id": id, "name": id], "script": script]]
        return try LXSourceStore.shared.decodeSourceData(JSONSerialization.data(withJSONObject: json), suggestedName: "fixture")
    }

    private func service(_ source: LXSourceStore.Source) -> LXUserAPIService {
        service([source])
    }

    private func service(_ sources: [LXSourceStore.Source], rejectNetwork: Bool = false,
                         catalogueMatch: (@MainActor (Track, String) async -> Track?)? = nil) -> LXUserAPIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = rejectNetwork ? [QishuiNoNetworkProtocol.self] : [QishuiBridgeMockProtocol.self]
        return LXUserAPIService(session: URLSession(configuration: configuration), sourceSnapshot: { (0, sources) },
                                catalogueMatch: catalogueMatch)
    }

    private func withPlatformFallback(_ enabled: Bool, operation: @MainActor () async throws -> Void) async rethrows {
        let settings = SettingsManager.shared
        let previous = settings.enableSourcePlatformFallback
        let defaults = UserDefaults.standard
        let key = "settings.sourcePlatformFallback"
        let persisted = defaults.object(forKey: key)
        settings.enableSourcePlatformFallback = enabled
        defer {
            settings.enableSourcePlatformFallback = previous
            // Preserve absence as well as the value: a default must not become
            // a newly persisted preference just because this test ran.
            if let persisted { defaults.set(persisted, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        try await operation()
    }

    private func assertMissingQishuiMusicURL(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let lxError = error as? LXUserAPIService.LXError,
              case .missingCapability(let platform, let action) = lxError else {
            XCTFail("Expected typed missingCapability, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(platform, "sd", file: file, line: line)
        XCTAssertEqual(action, "musicUrl", file: file, line: line)
    }

    func testImportedQishuiSourceResolvesThroughNativeHTTPAndPromiseBridge() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, async ({source, action, info}) => {
            if (source !== 'qs' || action !== 'musicUrl' || info.type !== '128k') throw new Error('wrong route')
            const music = info.musicInfo
            for (const key of ['id','songmid','songId','track_id','trackId']) {
                if (music[key] !== '7409001029981636620' || typeof music[key] !== 'string') throw new Error('rounded identity: ' + key)
            }
            if (music.source !== 'qs' || music.albumName !== 'fixture album') throw new Error('wrong metadata')
            return await new Promise((resolve, reject) => {
                lx.request('https://fixture.invalid/resolve', {method:'POST', body:JSON.stringify({id:music.id})}, (err, response, body) => {
                    if (err) return reject(err)
                    if (response.statusCode !== 200 || body.id !== music.songmid) return reject(new Error('wrong HTTP body'))
                    resolve(body.url)
                })
            })
        })
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#)
        let store = LXSourceStore.shared
        let selection = store.selectedID
        let enabled = store.enabledIDs
        let result = try await service(source).resolveMusicURL(for: track(), quality: "standard")
        XCTAssertEqual(result.url.absoluteString, "https://fixture.invalid/audio.mp3")
        XCTAssertEqual(result.quality, "128k")
        XCTAssertFalse(result.qualityIsVerified)
        XCTAssertEqual(store.selectedID, selection)
        XCTAssertEqual(store.enabledIDs, enabled)
    }

    func testDistinctSDAndQSActionsAreRoutedPerCapability() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, ({source, action}) => {
            if (action === 'musicUrl' && source === 'sd') return 'https://fixture.invalid/sd.mp3'
            if (action === 'lyric' && source === 'qs') return {lrc:{lyric:'[00:01.000]fixture'},yrc:'[1000,500](1000,500,0)fixture'}
            throw new Error('wrong alias for action')
        })
        lx.send(lx.EVENT_NAMES.inited, {sources:{
            sd:{type:'music',actions:['musicUrl'],qualitys:['128k']},
            qs:{type:'music',actions:['lyric'],qualitys:[]}
        }})
        """#)
        let resolver = service(source)
        let audio = try await resolver.resolveMusicURL(for: track(), quality: "standard")
        XCTAssertEqual(audio.url.lastPathComponent, "sd.mp3")
        let lyrics = try await resolver.resolveLyrics(for: track())
        XCTAssertEqual(lyrics.lyric, "[00:01.000]fixture")
        XCTAssertEqual(lyrics.yrc, "[1000,500](1000,500,0)fixture")
    }

    func testMissingQishuiCapabilityFailsWithoutCallingScriptOrNetwork() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, () => { throw new Error('must not run') })
        lx.send(lx.EVENT_NAMES.inited, {sources:{local:{type:'music',actions:['musicUrl'],qualitys:[]}}})
        """#)
        do {
            _ = try await service(source).resolveMusicURL(for: track(), quality: "standard")
            XCTFail("A non-Qishui source must not appear to support Qishui")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("汽水音乐"))
            XCTAssertTrue(error.localizedDescription.contains("musicUrl"))
            XCTAssertFalse(error.localizedDescription.contains("must not run"))
        }
    }

    func testActivatedWYOnlySourceFailsExactQishuiFastWithoutCatalogueOrHTTPWhenFallbackDisabled() async throws {
        try await withPlatformFallback(false) {
            let source = try imported(#"""
            lx.on(lx.EVENT_NAMES.request, () => new Promise((resolve, reject) => {
                lx.request('https://fixture.invalid/must-not-run', {}, error => error ? reject(error) : resolve('https://fixture.invalid/wrong.mp3'))
            }))
            lx.send(lx.EVENT_NAMES.inited, {sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
            """#)
            var matches = 0
            let resolver = service([source], rejectNetwork: true, catalogueMatch: { _, _ in
                matches += 1
                XCTFail("Disabled fallback must not query another catalogue")
                return nil
            })
            resolver.load(source)
            for _ in 0..<40 where resolver.capabilities["wy"] == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(resolver.capabilities["wy"], ["musicUrl"])
            let original = track()
            let selected = LXSourceStore.shared.selectedID
            let enabled = LXSourceStore.shared.enabledIDs
            let clock = ContinuousClock()
            let start = clock.now
            do {
                _ = try await resolver.resolveMusicURL(for: original, quality: "standard")
                XCTFail("WY support must not authorize a Qishui request")
            } catch {
                assertMissingQishuiMusicURL(error)
            }
            XCTAssertEqual(matches, 0)
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
            XCTAssertEqual(original.source, "sd")
            XCTAssertEqual(LXSourceStore.shared.selectedID, selected)
            XCTAssertEqual(LXSourceStore.shared.enabledIDs, enabled)
        }
    }

    func testQishuiLyricOnlySourceReturnsTypedMissingMusicURL() async throws {
        try await withPlatformFallback(false) {
            let source = try imported(#"""
            lx.on(lx.EVENT_NAMES.request, () => { throw new Error('must not request lyrics for playback') })
            lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['lyric'],qualitys:[]}}})
            """#)
            let resolver = service([source], rejectNetwork: true, catalogueMatch: { _, _ in
                XCTFail("Disabled fallback must not query another catalogue")
                return nil
            })
            do {
                _ = try await resolver.resolveMusicURL(for: track(), quality: "standard")
                XCTFail("A lyric capability is not an audio capability")
            } catch {
                assertMissingQishuiMusicURL(error)
            }
        }
    }

    func testAllActivatedSourcesMissingQishuiReturnTypedCapabilityError() async throws {
        try await withPlatformFallback(false) {
            let sources = try ["wy", "kw"].map { platform in
                try imported("""
                lx.on(lx.EVENT_NAMES.request, () => { throw new Error('must not call') })
                lx.send(lx.EVENT_NAMES.inited, {sources:{\(platform):{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
                """, id: "\(platform)-only-fixture")
            }
            do {
                _ = try await service(sources, rejectNetwork: true, catalogueMatch: { _, _ in
                    XCTFail("Disabled fallback must not query another catalogue")
                    return nil
                }).resolveMusicURL(for: track(), quality: "standard")
                XCTFail("Neither source supports Qishui")
            } catch {
                assertMissingQishuiMusicURL(error)
            }
        }
    }

    func testFailedInitializationMixedWithMissingCapabilityRetainsOperationalError() async throws {
        try await withPlatformFallback(false) {
            let failed = try imported(#"""
            lx.send(lx.EVENT_NAMES.inited, {status:false,sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
            """#, id: "failed-initialization-fixture")
            let wy = try imported(#"""
            lx.on(lx.EVENT_NAMES.request, () => { throw new Error('must not call') })
            lx.send(lx.EVENT_NAMES.inited, {sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
            """#, id: "wy-only-fixture")
            let resolver = service([failed, wy], rejectNetwork: true, catalogueMatch: { _, _ in
                XCTFail("Disabled fallback must not query another catalogue")
                return nil
            })
            do {
                _ = try await resolver.resolveMusicURL(for: track(), quality: "standard")
                XCTFail("Expected the mixed failure")
            } catch {
                guard let lxError = error as? LXUserAPIService.LXError,
                      case .resolveFailed(let failures) = lxError else {
                    return XCTFail("An uninitialized source must not be labeled as missing a capability: \(error)")
                }
                XCTAssertTrue(failures.contains { $0.contains("failed-initialization-fixture") && $0.contains("初始化失败") })
                XCTAssertTrue(failures.contains { $0.contains("wy-only-fixture") && $0.contains("musicUrl") })
            }
        }
    }

    func testQishuiBackendFailureIsNotReclassifiedAsMissingCapability() async throws {
        try await withPlatformFallback(false) {
            let source = try imported(#"""
            lx.on(lx.EVENT_NAMES.request, () => { throw new Error('fixture backend temporarily unavailable') })
            lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
            """#)
            do {
                _ = try await service([source], rejectNetwork: true).resolveMusicURL(for: track(), quality: "standard")
                XCTFail("Expected the backend failure")
            } catch {
                guard let lxError = error as? LXUserAPIService.LXError,
                      case .resolveFailed(let failures) = lxError else {
                    return XCTFail("A declared backend failure must remain retryable: \(error)")
                }
                XCTAssertTrue(failures.contains { $0.contains("fixture backend temporarily unavailable") })
            }
        }
    }

    func testCrossCatalogueMatchIsUsedOnlyWhenFallbackIsExplicitlyEnabled() async throws {
        try await withPlatformFallback(true) {
            let source = try imported(#"""
            lx.on(lx.EVENT_NAMES.request, ({source, info}) => {
                if (source !== 'wy' || info.musicInfo.songmid !== '186016') throw new Error('Qishui ID leaked into WY')
                return 'https://fixture.invalid/matched-wy.mp3'
            })
            lx.send(lx.EVENT_NAMES.inited, {sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
            """#)
            var matches = 0
            let resolver = service([source], rejectNetwork: true, catalogueMatch: { original, platform in
                matches += 1
                XCTAssertEqual(original.source, "sd")
                XCTAssertEqual(platform, "wy")
                return Track(id: 186_016, name: "fixture", artists: [],
                             album: AlbumRef(id: 0, name: "fixture", picUrl: nil), durationMS: 202_632,
                             source: "wy", sourceMetadata: ["songmid": "186016"])
            })
            let original = track()
            let result = try await resolver.resolveMusicURL(for: original, quality: "standard")
            XCTAssertEqual(result.url.lastPathComponent, "matched-wy.mp3")
            XCTAssertEqual(matches, 1)
            XCTAssertEqual(original.source, "sd")
            XCTAssertEqual(original.sourceMetadata["songmid"], id)
        }
    }

    func testDeclaredQishuiLyricURLIsFetchedUsingTheBoundedNativeSession() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, ({source, action}) => {
            if (source !== 'qs' || action !== 'lyric') throw new Error('wrong route')
            return {lrcUrl:'https://fixture.invalid/fixture.lrc'}
        })
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['lyric'],qualitys:[]}}})
        """#)
        let result = try await service(source).resolveLyrics(for: track())
        XCTAssertEqual(result.lyric, "[00:01.000]fixture lyric")
    }

    func testCancellingRealQishuiResolutionDiscardsContextAndAllowsNextRequest() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, ({info}) => {
            if (info.musicInfo.name === 'after-cancel') return 'https://fixture.invalid/next.mp3'
            return new Promise(resolve => setTimeout(() => resolve('https://fixture.invalid/stale.mp3'), 10000))
        })
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#)
        let resolver = service(source)
        let task = Task { try await resolver.resolveMusicURL(for: track(), quality: "standard") }
        for _ in 0..<40 where resolver.capabilities["sd"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled resolution must not return a late URL")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let next = try await resolver.resolveMusicURL(for: track(name: "after-cancel"), quality: "standard")
        XCTAssertEqual(next.url.lastPathComponent, "next.mp3")
    }

    func testQishuiOnlyHealthCheckNeedsARealTrackRatherThanSayingNoInterface() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, () => 'https://fixture.invalid/audio.mp3')
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#)
        let result = await LXUserAPIService.shared.checkSource(source)
        // A running Qishui track may supply its actual ID; otherwise do not
        // invent a synthetic Qishui identity for the health check.
        XCTAssertTrue(result.requiresTrack || result.isAvailable, result.detail ?? result.message)
    }

    func testFailedInitializationAfterASuccessfulLoadDoesNotKeepOldCapabilities() async throws {
        let good = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, () => 'https://fixture.invalid/audio.mp3')
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#, id: "good-initialization-fixture")
        let failed = try imported(#"""
        lx.send(lx.EVENT_NAMES.inited, {status:false,sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#, id: "failed-initialization-fixture")
        let resolver = service([good, failed], rejectNetwork: true)
        resolver.load(good)
        for _ in 0..<40 where resolver.capabilities["sd"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(resolver.capabilities["sd"], ["musicUrl"])
        resolver.load(failed)
        for _ in 0..<40 where !resolver.statusMessage.contains("初始化失败") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(resolver.statusMessage.contains("初始化失败"))
        XCTAssertTrue(resolver.capabilities.isEmpty)
        XCTAssertTrue(resolver.qualityCapabilities.isEmpty)
    }

    func testQueuedInitializationCannotRestoreCapabilitiesAfterUnload() async throws {
        let source = try imported(#"""
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#)
        let resolver = service([source], rejectNetwork: true)
        // The init native call is enqueued on MainActor. Unload before
        // yielding, so the old callback is deterministically still queued.
        resolver.load(source)
        resolver.load(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(resolver.capabilities.isEmpty)
        XCTAssertTrue(resolver.qualityCapabilities.isEmpty)
    }

    func testCancellationDuringActivationDiscardsLateInitializationWithoutChangingSelectedSource() async throws {
        try await withPlatformFallback(false) {
            let source = try imported(#"""
            lx.on(lx.EVENT_NAMES.request, ({info}) => new Promise((resolve, reject) => {
                lx.request('https://fixture.invalid/resolve', {method:'POST', body:JSON.stringify({id:info.musicInfo.id})}, (error, response, body) => {
                    if (error) return reject(error)
                    if (response.statusCode !== 200) return reject(new Error('wrong HTTP status'))
                    resolve(body.url)
                })
            }))
            setTimeout(() => lx.send(lx.EVENT_NAMES.inited, {
                sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}
            }), 200)
            """#)
            let resolver = service([source])
            let selected = LXSourceStore.shared.selectedID
            let enabled = LXSourceStore.shared.enabledIDs
            let task = Task { try await resolver.resolveMusicURL(for: track(), quality: "standard") }
            for _ in 0..<40 where resolver.statusMessage == "未加载音源" {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertEqual(resolver.statusMessage, "正在加载音源")
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancellation during activation must not return a URL or capability error")
            } catch is CancellationError {
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            // Let the cancelled context's initializer timer become due.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(resolver.capabilities.isEmpty)
            XCTAssertTrue(resolver.qualityCapabilities.isEmpty)
            XCTAssertEqual(LXSourceStore.shared.selectedID, selected)
            XCTAssertEqual(LXSourceStore.shared.enabledIDs, enabled)
            // Cancellation must not invalidate the reusable HTTP session or
            // poison future source activation.
            let next = try await resolver.resolveMusicURL(for: track(), quality: "standard")
            XCTAssertEqual(next.url.lastPathComponent, "audio.mp3")
        }
    }

    func testOldSourceTimerCannotFireANewContextsReusedTimerID() async throws {
        let source = try imported(#"""
        lx.on(lx.EVENT_NAMES.request, ({info}) => new Promise(resolve => {
            const next = info.musicInfo.name === 'after-cancel'
            setTimeout(() => resolve(next ? 'https://fixture.invalid/next.mp3' : 'https://fixture.invalid/stale.mp3'), next ? 400 : 150)
        }))
        lx.send(lx.EVENT_NAMES.inited, {sources:{qs:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
        """#)
        let resolver = service(source)
        let old = Task { try await resolver.resolveMusicURL(for: track(), quality: "standard") }
        for _ in 0..<40 where resolver.capabilities["sd"] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(30))
        old.cancel()
        _ = try? await old.value
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await resolver.resolveMusicURL(for: track(name: "after-cancel"), quality: "standard")
        XCTAssertEqual(result.url.lastPathComponent, "next.mp3")
        // Both contexts allocate timer ID 0. Before the generation-key guard,
        // the old 150 ms callback fired the new context's 400 ms timer early.
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(300))
    }
}

private final class QishuiNoNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("This fixture must not perform any HTTP requests")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

private final class QishuiBridgeMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/fixture.lrc" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[00:01.000]fixture lyric".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = QishuiMockProtocol.requestBody(request)
        let root = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let valid = request.httpMethod == "POST" && url.host == "fixture.invalid" && url.path == "/resolve"
            && root?["id"] as? String == "7409001029981636620"
        let response: [String: Any] = ["id": valid ? "7409001029981636620" : "wrong", "url": "https://fixture.invalid/audio.mp3"]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let http = HTTPURLResponse(url: url, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
