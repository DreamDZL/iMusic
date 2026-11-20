import Testing
@testable import KumoneCore

@MainActor
struct LXProviderScopeTests {
    private let legacyID = 7_409_001_029_981_636_620

    private func track(source: String? = nil, id: Int = 186_016,
                       metadata: [String: String] = [:]) -> Track {
        Track(id: id, name: "fixture", artists: [ArtistRef(id: 1, name: "fixture artist")],
              album: AlbumRef(id: 0, name: "fixture album", picUrl: nil), durationMS: 202_632,
              source: source, sourceMetadata: metadata)
    }

    private func source(_ script: String) -> LXSourceStore.Source {
        LXSourceStore.Source(id: "lx-provider-scope", name: "scope fixture", description: "",
                             version: "", author: "", homepage: "", script: script, sourceURL: nil)
    }

    private func service(_ source: LXSourceStore.Source, fallback: Bool = false,
                         match: (@MainActor (Track, String) async -> Track?)? = nil) -> LXUserAPIService {
        LXUserAPIService(sourceSnapshot: { (0, [source]) }, catalogueMatch: match,
                         platformFallbackEnabled: { fallback })
    }

    private var neteaseSource: LXSourceStore.Source {
        source(#"""
        lx.on(lx.EVENT_NAMES.request, ({source, action, info}) => {
            if (source !== 'wy' || info.musicInfo.songmid !== '186016') throw new Error('wrong provider ID')
            if (action === 'lyric') return '[00:01.000]fixture'
            return 'https://fixture.invalid/audio.mp3'
        })
        lx.send(lx.EVENT_NAMES.inited, {sources:{wy:{type:'music',actions:['musicUrl','lyric'],qualitys:['128k']}}})
        """#)
    }

    @Test func exposesOnlyFourProvidersAndResolvesUnmarkedNetEase() async throws {
        let resolver = service(source(#"""
        lx.on(lx.EVENT_NAMES.request, ({source, info}) => {
            if (source !== 'wy' || info.musicInfo.songmid !== '186016') throw new Error('wrong provider ID')
            return 'https://fixture.invalid/audio.mp3'
        })
        const declaration = {type:'music',actions:['musicUrl'],qualitys:['128k']}
        const sources = Object.fromEntries(['kw','kg','tx','wy','mg','sd','qs','local'].map(id => [id,declaration]))
        lx.send(lx.EVENT_NAMES.inited, {sources})
        """#))

        let result = try await resolver.resolveMusicURL(for: track(), quality: "standard")
        #expect(result.url.lastPathComponent == "audio.mp3")
        #expect(!result.qualityIsVerified)
        #expect(Set(resolver.capabilities.keys) == Set(["kw", "kg", "tx", "wy"]))
        #expect(Set(resolver.qualityCapabilities.keys) == Set(["kw", "kg", "tx", "wy"]))
    }

    @Test func retiredOnlyScriptHasNoHealthCheckInterface() async {
        let retired = source(#"""
        lx.on(lx.EVENT_NAMES.request, () => 'https://fixture.invalid/retired.mp3')
        const declaration = {type:'music',actions:['musicUrl'],qualitys:['128k']}
        lx.send(lx.EVENT_NAMES.inited, {sources:{mg:declaration,sd:declaration,qs:declaration}})
        """#)
        let result = await LXUserAPIService().checkSource(retired)
        #expect(result.status == .unavailable)
        #expect(result.message == "没有可用的播放接口")
    }

    @Test func legacyTracksWithFallbackDisabledReturnUnsupportedBeforeLoadingScript() async {
        let resolver = service(neteaseSource, match: { _, _ in
            Issue.record("Disabled fallback must not query another catalogue")
            return nil
        })
        let legacyTracks = [
            track(source: "sd", id: legacyID),
            track(source: "qs", id: legacyID),
            track(source: "mg", id: legacyID),
            track(source: " ", id: legacyID, metadata: ["source": "migu"]),
            track(id: legacyID, metadata: ["qishuiTrackID": String(legacyID)]),
            track(source: "wy", id: legacyID, metadata: ["source": "sd"]),
            track(source: "unknown", id: legacyID)
        ]
        for original in legacyTracks {
            await #expect(throws: LXCatalogError.unsupported) {
                try await resolver.resolveMusicURL(for: original, quality: "standard")
            }
            await #expect(throws: LXCatalogError.unsupported) {
                try await resolver.resolveLyrics(for: original)
            }
            let qualities = await resolver.availableQualityNames(for: original)
            #expect(qualities.isEmpty)
        }
        #expect(resolver.statusMessage == "未加载音源")
    }

    @Test func enabledFallbackUsesMatchedIDForAudioLyricsAndQuality() async throws {
        let original = track(source: "sd", id: legacyID, metadata: ["songmid": String(legacyID)])
        var matches: [String] = []
        let resolver = service(neteaseSource, fallback: true, match: { track, platform in
            #expect(track.source == "sd")
            #expect(track.sourceMetadata["songmid"] == String(self.legacyID))
            matches.append(platform)
            return self.track(source: "wy")
        })

        let result = try await resolver.resolveMusicURL(for: original, quality: "standard")
        let lyrics = try await resolver.resolveLyrics(for: original)
        let qualities = await resolver.availableQualityNames(for: original)
        #expect(result.url.lastPathComponent == "audio.mp3")
        #expect(lyrics.lyric == "[00:01.000]fixture")
        #expect(qualities == ["128k"])
        #expect(matches == ["wy", "wy", "wy"])
        #expect(original.playbackKey.hasPrefix("sd:\(legacyID):"))
    }

    @Test func unrelatedCatalogueResultCannotAuthorizeFallback() async {
        let original = track(source: "mg", id: legacyID)
        let resolver = service(neteaseSource, fallback: true, match: { track, platform in
            #expect(platform == "wy")
            return track
        })
        await #expect(throws: LXCatalogError.unsupported) {
            try await resolver.resolveMusicURL(for: original, quality: "standard")
        }
        await #expect(throws: LXCatalogError.unsupported) {
            try await resolver.resolveLyrics(for: original)
        }
        let qualities = await resolver.availableQualityNames(for: original)
        #expect(qualities.isEmpty)
    }
}
