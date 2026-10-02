#if os(iOS)
import CommonCrypto
import Combine
import Foundation
import JavaScriptCore
import Security

/// iOS counterpart of LX Mobile's QuickJS bridge.  The provider script stays
/// user supplied; this class only implements the LX 2.0 host protocol.
@MainActor
final class LXUserAPIService: ObservableObject {
    struct ResolvedURL {
        let url: URL
        let quality: String
        /// Official provider APIs report the tier actually returned. LX User
        /// API scripts only return a URL, so their requested tier is not proof
        /// of the file's codec or bitrate.
        var qualityIsVerified: Bool = true
    }

    struct ResolvedLyrics {
        let lyric: String
        let tlyric: String?
        let rlyric: String?
        let lxlyric: String?
        let yrc: String?
    }

    struct SourceCheckResult: Equatable {
        enum Status: Equatable {
            case available
            case unavailable
            case requiresTrack
        }

        let status: Status
        let message: String
        let detail: String?

        var isAvailable: Bool { status == .available }
        var requiresTrack: Bool { status == .requiresTrack }
    }

    private struct SourceOperationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    static let shared = LXUserAPIService()
    private static let lyricsResolver = LXUserAPIService()
    private static let qualityResolver = LXUserAPIService()
    private static let downloadResolver = LXUserAPIService()

    private let session: URLSession
    private var context: JSContext?
    private var key = ""
    private var loadedID: String?
    private var loadedScript: String?
    private var tasks: [String: URLSessionDataTask] = [:]
    private var scriptRequestKeys = Set<String>()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var sourceInitializationTask: Task<Void, Never>?
    private var pendingInitializationID: String?
    private var sourceOperationActive = false
    private var sourceOperationWaiters: [SourceOperationWaiter] = []
    private var selectedSourceReloadPending = false
    private var selectedSourceReloadForced = false
    @Published private(set) var capabilities: [String: [String]] = [:]
    @Published private(set) var qualityCapabilities: [String: [String]] = [:]
    @Published private(set) var statusMessage = "未加载音源"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func loadSelectedSource() {
        guard !sourceOperationActive else {
            selectedSourceReloadPending = true
            selectedSourceReloadForced = true
            return
        }
        load(LXSourceStore.shared.selectedSource)
    }

    static func sourceConfigurationDidChange() {
        [shared, lyricsResolver, qualityResolver, downloadResolver]
            .forEach { $0.invalidateSourceWork() }
    }

    func resolveDownloadMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        try await Self.downloadResolver.resolveMusicURL(for: track, quality: quality)
    }

    /// Load a provider only when a request actually needs one.  A user's
    /// imported JavaScript must not be evaluated while the app scene is
    /// launching.
    func ensureSelectedSourceLoaded() {
        let selectedID = LXSourceStore.shared.selectedID
        guard loadedID != selectedID else { return }
        loadSelectedSource()
    }

    func load(_ source: LXSourceStore.Source?) {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = source?.id
        context = nil
        loadedID = source?.id
        loadedScript = source?.script
        capabilities = [:]
        qualityCapabilities = [:]
        statusMessage = source == nil ? "未选择音源" : "正在加载音源"
        guard let source,
              let preloadURL = Bundle.module.url(forResource: "LXUserAPIPreload", withExtension: "js"),
              let preload = try? String(contentsOf: preloadURL, encoding: .utf8) else {
            pendingInitializationID = nil
            statusMessage = "LX 预加载桥接文件不存在"
            return
        }

        let js = JSContext()
        js?.exceptionHandler = { _, exception in
            if let exception { print("[LX] JavaScript error: \(exception)") }
        }
        context = js
        key = UUID().uuidString
        installHostFunctions(in: js!)
        js?.evaluateScript(preload)
        if let exception = js?.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 桥接加载失败：\(exception.toString())"
            return
        }
        let setup = js?.objectForKeyedSubscript("lx_setup")
        setup?.call(withArguments: [key, source.id, source.name, source.description,
                                    source.version, source.author, source.homepage, source.script])
        if let exception = js?.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 音源初始化失败：\(exception.toString())"
            return
        }
        _ = js?.evaluateScript(source.script)
        if let exception = js?.exception {
            context = nil
            pendingInitializationID = nil
            statusMessage = "LX 音源脚本错误：\(exception.toString())"
            print("[LX] failed to load source \(source.name): \(exception)")
        }
        if context != nil {
            scheduleInitializationFallback(for: source.id)
        }
    }

    func resolveMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        let sourceMode = SettingsManager.shared.playbackSourceMode
        if sourceMode == .official {
            guard hasAuthenticatedAccount(for: track) else {
                throw LXError.sourceUnavailable("请先登录对应平台账号，并选择该平台歌曲")
            }
            return try await resolveOfficialMusicURL(for: track, quality: quality)
        }

        // Automatic mode follows the same rule as the player and download
        // manager: try the matching account source first, reject preview-only
        // URLs, then fall back to the enabled LX sources.
        if sourceMode == .automatic, hasAuthenticatedAccount(for: track),
           let official = try? await resolveOfficialMusicURL(for: track, quality: quality) {
            return official
        }
        try await acquireSourceOperation()
        defer { releaseSourceOperation() }
        try Task.checkCancellation()
        return try await resolveMusicURLAcrossSources(for: track, quality: quality)
#if false
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        guard capabilities.values.contains(where: { $0.contains("musicUrl") }) else {
            throw LXError.sourceUnavailable(statusMessage)
        }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var failures: [String] = []

        for platform in sourceCandidates(for: track, action: "musicUrl") {
            let platformName = LXCatalogPlatform.displayName(for: platform)
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                // IDs are platform-specific. A Kuwo RID cannot be sent to a
                // Kugou/QQ/NetEase source, so look up a matching result first.
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                    failures.append("\(platformName)：找不到对应歌曲")
                    continue
                }
                requestTrack = matched
            }

            let supportedQualitys = supportedQualityNames(for: requestTrack, platform: platform)
            let requestedQuality = Self.lxQuality(for: quality,
                                                  supported: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys)
            do {
                let response = try await request(source: platform, action: "musicUrl",
                                                 info: ["type": protocolQualityToken(requestedQuality, platform: platform),
                                                        "musicInfo": musicInfo(for: requestTrack,
                                                                                platform: platform,
                                                                                qualities: supportedQualitys)])
                guard let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    failures.append("\(platformName)：没有返回有效播放地址")
                    continue
                }
                let actualQuality = Self.resolvedQuality(
                    returned: (data["type"] as? String)
                        ?? (data["quality"] as? String)
                        ?? (data["format"] as? String),
                    requested: requestedQuality,
                    available: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
                )
                return ResolvedURL(url: url, quality: actualQuality)
            } catch {
                failures.append("\(platformName)：\(error.localizedDescription)")
            }
        }
        throw LXError.resolveFailed(failures.isEmpty
            ? ["当前音源没有可用的 musicUrl 平台"]
            : failures)
#endif
    }

    /// Resolves through an authenticated provider account when that provider
    /// exposes an official full-track URL. It never bypasses VIP checks or
    /// manufactures a URL when the account is not entitled to play the track.
    private func resolveOfficialMusicURL(for track: Track, quality: String) async throws -> ResolvedURL {
        switch canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy" {
        case "tx":
            guard let cookie = QQMusicSessionStore.shared.cookie,
                  QQMusicSessionStore.shared.isLoggedIn else {
                throw LXError.sourceUnavailable("QQ 音乐账号未登录")
            }
            let songMid = track.sourceMetadata["songmid"] ?? String(track.id)
            var lastError: Error?
            let requestedQualities = [quality, "exhigh", "standard"].reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            for requestedQuality in requestedQualities {
                do {
                    let audio = try await QQMusicAPI.shared.musicURL(
                        songMid: songMid,
                        mediaMid: track.sourceMetadata["strMediaMid"]?.isEmpty == false
                            ? track.sourceMetadata["strMediaMid"]
                            : track.sourceMetadata["media_mid"],
                        quality: requestedQuality,
                        cookie: cookie
                    )
                    return ResolvedURL(url: audio.url, quality: audio.quality)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? LXError.sourceUnavailable("QQ 音乐账号没有可用音质")
        case "kg":
            guard let cookie = KugouSessionStore.shared.cookie,
                  KugouSessionStore.shared.isLoggedIn else {
                throw LXError.sourceUnavailable("酷狗音乐账号未登录")
            }
            guard let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"],
                  !hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LXError.sourceUnavailable("酷狗歌曲缺少官方 hash，无法使用账号音源")
            }
            let requestedQualities = [quality, "hires", "lossless", "exhigh", "standard"]
                .reduce(into: [String]()) { result, item in
                    if !result.contains(item) { result.append(item) }
                }
            var lastError: Error?
            for requestedQuality in requestedQualities {
                do {
                    let audio = try await KugouAPI.shared.musicURL(
                        hash: hash,
                        quality: requestedQuality,
                        cookie: cookie,
                        albumID: track.sourceMetadata["albumId"],
                        albumAudioID: track.sourceMetadata["albumAudioId"]
                            ?? track.sourceMetadata["albumAudioID"]
                            ?? track.sourceMetadata["mixsongid"]
                    )
                    return ResolvedURL(url: audio.url, quality: audio.quality)
                } catch {
                    lastError = error
                }
            }
            throw lastError ?? LXError.sourceUnavailable("酷狗音乐账号没有可用音质")
        default:
            break
        }

        let requested = AudioQuality(rawValue: quality)
            ?? AudioQuality(lxType: quality)
            ?? .standard
        let data = try await NeteaseAPI.songURL(ids: [track.id], level: requested.neteaseLevel).first
        guard let data,
              let rawURL = data.url,
              let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw LXError.sourceUnavailable("官方账号没有返回可播放地址")
        }
        if data.freeTrialInfo != nil {
            throw LXError.sourceUnavailable("官方账号只返回试听片段")
        }
        if data.time > 0, track.duration > 0 {
            let returnedDuration = TimeInterval(data.time) / 1000
            let minimumFullLength = max(45, track.duration * 0.65)
            if returnedDuration < minimumFullLength {
                throw LXError.sourceUnavailable("官方账号只返回试听片段")
            }
        }
        return ResolvedURL(url: url, quality: NeteaseAPI.officialQuality(for: data).lxType)
    }

    private func hasAuthenticatedAccount(for track: Track) -> Bool {
        switch canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy" {
        case "tx":
            return QQMusicSessionStore.shared.isLoggedIn && QQMusicSessionStore.shared.cookie != nil
        case "wy":
            return NeteaseClient.shared.isLoggedIn
        case "kg":
            return KugouSessionStore.shared.isLoggedIn && KugouSessionStore.shared.cookie != nil
        default:
            return false
        }
    }

    private static func isNeteaseTrack(_ track: Track) -> Bool {
        guard let rawSource = track.source ?? track.sourceMetadata["source"] else {
            // Native NetEase catalogue responses do not carry an LX source
            // marker. They are the only unmarked tracks in the queue.
            return true
        }
        let source = rawSource
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty || ["wy", "163", "netease", "neteasecloudmusic", "cloudmusic"].contains(source)
    }

    private func resolveMusicURLAcrossSources(for track: Track, quality: String) async throws -> ResolvedURL {
        let sourceRevision = LXSourceStore.shared.configurationRevision
        let playbackSources = LXSourceStore.shared.playbackSources
        guard !playbackSources.isEmpty else { throw LXError.noSource }

        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var failures: [String] = []

        // Resolve each route before preparing fallbacks. This honors the
        // selected source and avoids doing catalogue work for backups when the
        // preferred source can play the track.
        for source in playbackSources {
            try Task.checkCancellation()
            try validateSourceConfiguration(sourceRevision, source: source)
            let isAvailable = await activate(source)
            try validateSourceConfiguration(sourceRevision, source: source)
            guard isAvailable else {
                failures.append("\(source.name): unavailable")
                continue
            }
            let platforms = sourceCandidates(for: track, action: "musicUrl")
            if platforms.isEmpty {
                failures.append("\(source.name): no musicUrl platform")
                continue
            }

            for platform in platforms {
                let requestTrack: Track
                if platform == primaryPlatform {
                    requestTrack = track
                } else {
                    // IDs are platform-specific. Match the song before using
                    // a different platform's musicUrl endpoint.
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else {
                        failures.append("\(source.name)/\(platform): track not found")
                        continue
                    }
                    requestTrack = matched
                }
                try Task.checkCancellation()
                try validateSourceConfiguration(sourceRevision, source: source)

                let supported = supportedQualityNames(for: requestTrack, platform: platform)
                let requested = Self.lxQuality(for: quality,
                                               supported: supported.isEmpty ? ["128k"] : supported)
                do {
                    let response = try await request(
                        source: platform,
                        action: "musicUrl",
                        info: [
                            "type": protocolQualityToken(requested, platform: platform),
                            "musicInfo": musicInfo(
                                for: requestTrack,
                                platform: platform,
                                qualities: supported
                            )
                        ]
                    )
                    try Task.checkCancellation()
                    try validateSourceConfiguration(sourceRevision, source: source)
                    guard let data = response["data"] as? [String: Any],
                          let rawURL = data["url"] as? String,
                          let url = URL(string: rawURL),
                          let scheme = url.scheme?.lowercased(),
                          scheme == "http" || scheme == "https" else {
                        failures.append("\(source.name)/\(platform): invalid URL")
                        continue
                    }

                    // The LX bridge echoes the requested `type`; it cannot
                    // confirm the provider's actual codec or bitrate.
                    return ResolvedURL(url: url, quality: requested,
                                       qualityIsVerified: false)
                } catch {
                    if error is CancellationError { throw error }
                    try validateSourceConfiguration(sourceRevision, source: source)
                    failures.append("\(source.name)/\(platform): \(error.localizedDescription)")
                }
            }
        }

        if failures.isEmpty {
            throw LXError.sourceUnavailable("No enabled LX source exposes musicUrl")
        }
        throw LXError.resolveFailed(failures)
    }

    /// Performs a real, read-only musicUrl request against the selected LX
    /// source. The test metadata is bundled locally so health checks never
    /// call a built-in music-platform catalogue endpoint.
    func checkSelectedSource() async -> SourceCheckResult {
        guard let source = LXSourceStore.shared.selectedSource else {
            return SourceCheckResult(status: .unavailable,
                                     message: "未选择音源",
                                     detail: "请先导入并启用一个 LX User API 音源。")
        }
        return await checkSource(source)
    }

    /// Checks any imported source in an isolated JavaScript context. Testing a
    /// disabled backup must not select it (which would silently enable it),
    /// and swapping the shared context could interrupt an in-flight lookup.
    func checkSource(_ source: LXSourceStore.Source) async -> SourceCheckResult {
        let checker = LXUserAPIService()
        let result = await withTaskCancellationHandler {
            defer { checker.cancelPendingRequests() }
            checker.load(source)
            await checker.waitForSourceReady()
            guard !Task.isCancelled else {
                return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
            }
            return await checker.checkLoadedSource()
        } onCancel: {
            Task { @MainActor in checker.cancelPendingRequests() }
        }
        if !Task.isCancelled, LXSourceStore.shared.selectedID == source.id {
            statusMessage = result.detail.map { "\(result.message)：\($0)" } ?? result.message
        }
        return result
    }

    private func checkLoadedSource() async -> SourceCheckResult {
        guard context != nil else {
            return SourceCheckResult(status: .unavailable,
                                     message: "音源脚本加载失败",
                                     detail: statusMessage)
        }

        let platformOrder = ["wy", "kw", "kg", "tx", "mg"]
        let supportedPlatforms = platformOrder.filter {
            capabilities[$0]?.contains("musicUrl") == true
        }
        guard !supportedPlatforms.isEmpty else {
            let detail = capabilities.isEmpty
                ? "脚本没有返回平台能力。"
                : "脚本已加载，但没有提供 musicUrl 接口。"
            return SourceCheckResult(status: .unavailable,
                                     message: "没有可用的播放接口",
                                     detail: detail)
        }

        var failures: [String] = []
        var requiresTrackPlatforms: [String] = []
        for platform in supportedPlatforms {
            guard !Task.isCancelled else {
                return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
            }
            let platformName = LXCatalogPlatform.displayName(for: platform)
            let currentTrack = PlayerService.shared.currentTrack
            let track = currentTrack.flatMap {
                canonicalPlatform($0.source ?? $0.sourceMetadata["source"]) == platform ? $0 : nil
            } ?? Self.sourceCheckTrack(for: platform)
            guard let track else {
                requiresTrackPlatforms.append(platformName)
                continue
            }

            let supportedQualitys = supportedQualityNames(for: track, platform: platform)
            let requestedQuality = Self.lxQuality(
                for: SettingsManager.shared.audioQuality.rawValue,
                supported: supportedQualitys.isEmpty ? ["128k"] : supportedQualitys
            )
            let info = musicInfo(for: track, platform: platform, qualities: supportedQualitys)
            do {
                let response = try await request(source: platform, action: "musicUrl",
                                                 info: ["type": protocolQualityToken(requestedQuality, platform: platform), "musicInfo": info])
                guard !Task.isCancelled else {
                    return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
                }
                guard let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    failures.append("\(platformName)：没有返回有效播放地址")
                    continue
                }

                let detail = "已通过 \(platformName) 的 musicUrl 接口，请求档位：\(requestedQuality)（音源未提供实际音质信息）"
                let result = SourceCheckResult(status: .available,
                                               message: "音源可用",
                                               detail: detail)
                statusMessage = "\(result.message)：\(detail)"
                return result
            } catch {
                if Task.isCancelled {
                    return SourceCheckResult(status: .unavailable, message: "检测已取消", detail: nil)
                }
                failures.append("\(platformName)：\(error.localizedDescription)")
            }
        }

        if !requiresTrackPlatforms.isEmpty {
            let attemptedDetail = failures.isEmpty ? nil : "已尝试的平台：\(failures.joined(separator: "；"))。"
            let trackDetail = "请先播放一首来自 \(requiresTrackPlatforms.joined(separator: "、")) 的歌曲，再重新检测。"
            return SourceCheckResult(status: .requiresTrack,
                                     message: "需要该平台歌曲才能确认",
                                     detail: [attemptedDetail, trackDetail].compactMap { $0 }.joined())
        }

        let detail = failures.isEmpty ? "音源没有返回可播放地址。" : failures.joined(separator: "；")
        let result = SourceCheckResult(status: .unavailable,
                                       message: "音源不可用",
                                       detail: detail)
        statusMessage = "\(result.message)：\(detail)"
        return result
    }

    func resolveLyrics(for track: Track) async throws -> ResolvedLyrics {
        let resolver = Self.lyricsResolver
        try await resolver.acquireSourceOperation()
        defer { resolver.releaseSourceOperation() }
        try Task.checkCancellation()
        return try await resolver.resolveLyricsAcrossSources(for: track)
#if false
        ensureSelectedSourceLoaded()
        await waitForSourceReady()
        guard context != nil else { throw LXError.noSource }
        let primarySource = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        for platform in sourceCandidates(for: track, action: "lyric") {
            guard capabilities[platform]?.contains("lyric") == true else { continue }
            let requestTrack: Track
            if platform == primarySource {
                requestTrack = track
            } else {
                guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                requestTrack = matched
            }
            for attempt in 0..<2 {
                guard let response = try? await request(source: platform, action: "lyric",
                                                        info: ["type": "lyric", "musicInfo": musicInfo(for: requestTrack, platform: platform)]),
                      let lyrics = await lyricPayload(from: response) else {
                    if attempt == 0 { try? await Task.sleep(for: .milliseconds(350)) }
                    continue
                }
                return lyrics
            }
        }
        throw LXError.resolveFailed([])
#endif
    }
    private func resolveLyricsAcrossSources(for track: Track) async throws -> ResolvedLyrics {
        let sourceRevision = LXSourceStore.shared.configurationRevision
        let playbackSources = LXSourceStore.shared.playbackSources
        guard !playbackSources.isEmpty else { throw LXError.noSource }

        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        for source in playbackSources {
            try Task.checkCancellation()
            try validateSourceConfiguration(sourceRevision, source: source)
            let isAvailable = await activate(source)
            try validateSourceConfiguration(sourceRevision, source: source)
            guard isAvailable else { continue }
            for platform in sourceCandidates(for: track, action: "lyric") {
                let requestTrack: Track
                if platform == primaryPlatform {
                    requestTrack = track
                } else {
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                    requestTrack = matched
                }
                try Task.checkCancellation()
                try validateSourceConfiguration(sourceRevision, source: source)

                for attempt in 0..<2 {
                    do {
                        let response = try await request(
                            source: platform,
                            action: "lyric",
                            info: [
                                "type": "lyric",
                                "musicInfo": musicInfo(for: requestTrack, platform: platform)
                            ]
                        )
                        try Task.checkCancellation()
                        try validateSourceConfiguration(sourceRevision, source: source)
                        if let lyrics = await lyricPayload(from: response) { return lyrics }
                    } catch {
                        if error is CancellationError { throw error }
                        try validateSourceConfiguration(sourceRevision, source: source)
                    }
                    if attempt == 0 { try? await Task.sleep(for: .milliseconds(350)) }
                }
            }
        }
        throw LXError.resolveFailed([])
    }

    /// LX source scripts do not all return the same lyric shape. In the wild
    /// `data` may be a string, an object with `lyric`/`lrc`, or an object that
    /// points to a separate LRC URL. Accept all of those forms so Kuwo,
    /// Kugou, QQ and Migu sources are not incorrectly reported as lyric-less.
    private func lyricPayload(from response: [String: Any]) async -> ResolvedLyrics? {
        let raw = response["data"]
        let object = raw as? [String: Any]
        var lyric = raw as? String
        var tlyric: String?
        var rlyric: String?
        var lxlyric: String?
        var yrc: String?

        if let object {
            func text(_ keys: [String]) -> String? {
                for key in keys {
                    if let value = object[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
                    if let nested = object[key] as? [String: Any],
                       let value = nested["lyric"] as? String { return value }
                }
                return nil
            }
            lyric = text(["lyric", "lrc", "lyricText", "content", "text"])
            tlyric = text(["tlyric", "translation", "translatedLyric"])
            rlyric = text(["rlyric", "romalrc", "romaji"])
            lxlyric = text(["lxlyric"])
            yrc = text(["yrc", "verbatim", "wordLyric"])

            if lyric == nil,
               let urlString = text(["lrcUrl", "lyricUrl", "url"]),
               let url = URL(string: urlString),
               let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                lyric = String(data: data, encoding: .utf8)
            }
        }

        guard let lyric = lyric ?? yrc,
              !lyric.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ResolvedLyrics(lyric: lyric, tlyric: tlyric, rlyric: rlyric,
                              lxlyric: lxlyric, yrc: yrc)
    }

    enum LXError: LocalizedError {
        case noSource
        case resolveFailed([String])
        case sourceUnavailable(String)
        case requestTimedOut
        case javascript(String)

        var errorDescription: String? {
            switch self {
            case .noSource: return "请先在“设置 → LX 音源”中导入并启用音源"
            case .resolveFailed(let failures):
                guard !failures.isEmpty else { return "LX 音源没有返回可播放地址" }
                return failures.prefix(2).joined(separator: "；")
            case .sourceUnavailable(let status):
                return status.isEmpty ? "LX 音源尚未返回可用播放接口" : status
            case .javascript(let message): return message
            case .requestTimedOut: return "LX 音源请求超时，请检查音源服务器和网络后重试"
            }
        }
    }

    private func installHostFunctions(in js: JSContext) {
        let consoleLog: @convention(block) (String) -> Void = { message in
            print("[LX] \(message)")
        }
        let console = JSValue(newObjectIn: js)
        console?.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "info" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "warn" as NSString)
        console?.setObject(consoleLog, forKeyedSubscript: "error" as NSString)
        js.setObject(console, forKeyedSubscript: "console" as NSString)

        let nativeCall: @convention(block) (String, String, String) -> Void = { [weak self] key, action, data in
            Task { @MainActor in
                guard let self, self.key == key else { return }
                self.handleNativeCall(action: action, data: data)
            }
        }
        js.setObject(nativeCall, forKeyedSubscript: "__lx_native_call__" as NSString)

        let str2b64: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let b642buf: @convention(block) (String) -> String = { value in
            let bytes = Data(base64Encoded: value) ?? Data()
            return "[" + bytes.map(String.init).joined(separator: ",") + "]"
        }
        let md5: @convention(block) (String) -> String = { value in
            md5Hex(value.removingPercentEncoding ?? value)
        }
        let aes: @convention(block) (String, String, String, String) -> String = { input, key, iv, mode in
            aesEncrypt(input: input, key: key, iv: iv, mode: mode)
        }
        let rsa: @convention(block) (String, String, String) -> String = { input, publicKey, padding in
            rsaEncrypt(input: input, publicKey: publicKey, padding: padding)
        }
        js.setObject(str2b64, forKeyedSubscript: "__lx_native_call__utils_str2b64" as NSString)
        js.setObject(b642buf, forKeyedSubscript: "__lx_native_call__utils_b642buf" as NSString)
        js.setObject(md5, forKeyedSubscript: "__lx_native_call__utils_str2md5" as NSString)
        js.setObject(aes, forKeyedSubscript: "__lx_native_call__utils_aes_encrypt" as NSString)
        js.setObject(rsa, forKeyedSubscript: "__lx_native_call__utils_rsa_encrypt" as NSString)

        let timeout: @convention(block) (Int, Int) -> Void = { [weak self] id, delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(0, delay))) {
                Task { @MainActor in self?.callJS(action: "__set_timeout__", data: id) }
            }
        }
        js.setObject(timeout, forKeyedSubscript: "__lx_native_call__set_timeout" as NSString)
    }

    private func handleNativeCall(action: String, data: String) {
        guard let payloadData = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) else { return }
        if action == "cancelRequest", let requestKey = object as? String {
            if scriptRequestKeys.remove(requestKey) != nil {
                tasks.removeValue(forKey: requestKey)?.cancel()
            } else {
                cancelPendingRequest(with: requestKey)
            }
            return
        }
        guard let payload = object as? [String: Any] else { return }
        switch action {
        case "init":
            sourceInitializationTask?.cancel()
            sourceInitializationTask = nil
            pendingInitializationID = nil
            guard payload["status"] as? Bool != false else {
                statusMessage = (payload["errorMessage"] as? String).map { "LX 音源初始化失败：\($0)" }
                    ?? "LX 音源初始化失败"
                return
            }
            if let info = payload["info"] as? [String: Any],
               let sources = info["sources"] as? [String: Any] {
                capabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    let actions = value["actions"] as? [String] ?? []
                    result[pair.key] = actions
                }
                qualityCapabilities = sources.reduce(into: [:]) { result, pair in
                    guard let value = pair.value as? [String: Any] else { return }
                    result[pair.key] = value["qualitys"] as? [String] ?? []
                }
                let active = capabilities
                    .filter { !$0.value.isEmpty }
                    .map { "\($0.key): \($0.value.joined(separator: ", "))" }
                    .sorted()
                statusMessage = active.isEmpty
                    ? "音源已加载，但没有可用接口"
                    : "音源已加载（\(active.joined(separator: "；"))）"
            }
        case "request":
            if let requestKey = payload["requestKey"] as? String,
               let url = payload["url"] as? String,
               let requestURL = URL(string: url) {
                scriptRequestKeys.insert(requestKey)
                sendScriptRequest(requestKey: requestKey, url: requestURL,
                                  options: payload["options"] as? [String: Any] ?? [:])
            }
        case "cancelRequest":
            if let requestKey = payload["requestKey"] as? String {
                if scriptRequestKeys.remove(requestKey) != nil {
                    tasks.removeValue(forKey: requestKey)?.cancel()
                } else {
                    cancelPendingRequest(with: requestKey)
                }
            }
        case "response":
            guard let requestKey = payload["requestKey"] as? String else { return }
            requestTimeoutTasks.removeValue(forKey: requestKey)?.cancel()
            if payload["status"] as? Bool == true, let result = payload["result"] as? [String: Any] {
                pending.removeValue(forKey: requestKey)?.resume(returning: result)
            } else {
                let message = payload["errorMessage"] as? String ?? "LX 音源没有返回有效响应"
                pending.removeValue(forKey: requestKey)?.resume(throwing: LXError.javascript(message))
            }
        default: break
        }
    }

    private func sendScriptRequest(requestKey: String, url: URL, options: [String: Any]) {
        guard scriptRequestKeys.contains(requestKey) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = (options["method"] as? String ?? "GET").uppercased()
        // Match LX Mobile's request helper. A number of source backends reject
        // URLSession's default identity or return HTML without these headers.
        request.setValue("Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let headers = options["headers"] as? [String: Any] {
            headers.forEach { request.setValue(String(describing: $0.value), forHTTPHeaderField: $0.key) }
        }
        let method = request.httpMethod ?? "GET"
        if let body = options["body"], !(body is NSNull) {
            if let string = body as? String {
                request.httpBody = Data(string.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            if request.value(forHTTPHeaderField: "Content-Type") == nil,
               method == "POST" || method == "PUT" || method == "PATCH" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if let form = options["form"] as? [String: Any] {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\($0.key.lxFormEncoded)=\(String(describing: $0.value).lxFormEncoded)" }.joined(separator: "&").utf8)
        } else if let formData = options["formData"] as? String {
            // Some older LX sources pass an already encoded formData string.
            // Preserve it instead of silently dropping the POST body.
            request.httpBody = Data(formData.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            }
        }
        if let timeout = options["timeout"] as? Double, timeout > 0 { request.timeoutInterval = min(timeout / 1000, 60) }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self, self.scriptRequestKeys.remove(requestKey) != nil else { return }
                self.tasks.removeValue(forKey: requestKey)
                let rawBody = data ?? Data()
                let body: Any
                if options["binary"] as? Bool == true {
                    // Binary responses are not parsed. The current LX source
                    // bridge only uses textual/JSON responses, but preserving
                    // this branch keeps the User API contract intact.
                    body = String(data: rawBody, encoding: .utf8) ?? ""
                } else if let jsonBody = try? JSONSerialization.jsonObject(with: rawBody) {
                    // LX User API scripts expect response.body to behave like
                    // LX Mobile's request helper: JSON bodies are objects,
                    // while non-JSON bodies remain strings.
                    body = jsonBody
                } else {
                    body = String(data: rawBody, encoding: .utf8) ?? ""
                }
                let http = response as? HTTPURLResponse
                var result: [String: Any] = [
                    "requestKey": requestKey,
                    "response": ["statusCode": http?.statusCode ?? 0,
                                  "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                                  "headers": (http?.allHeaderFields ?? [:]).reduce(into: [:]) { $0[String(describing: $1.key)] = String(describing: $1.value) },
                                  "body": body,
                                  "url": http?.url?.absoluteString ?? url.absoluteString,
                                  "ok": (200..<300).contains(http?.statusCode ?? 0)],
                ]
                if let error { result["error"] = error.localizedDescription }
                self.callJS(action: "response", data: result)
            }
        }
        tasks[requestKey] = task
        task.resume()
    }

    private func request(source: String, action: String, info: [String: Any]) async throws -> [String: Any] {
        guard context != nil else { throw LXError.noSource }
        let requestKey = "request__\(UUID().uuidString)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[requestKey] = continuation
                callJS(action: "request", data: ["requestKey": requestKey,
                                                    "data": ["source": source, "action": action, "info": info]])
                requestTimeoutTasks[requestKey] = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(20))
                    } catch {
                        return
                    }
                    guard let self, self.pending[requestKey] != nil else { return }
                    self.cancelPendingRequest(with: requestKey, error: LXError.requestTimedOut)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPendingRequest(with: requestKey) }
        }
    }

    private func cancelPendingRequest(
        with requestKey: String,
        error: Error = CancellationError()
    ) {
        requestTimeoutTasks.removeValue(forKey: requestKey)?.cancel()
        // The root LX callback may currently be waiting on one or more
        // `lx.request` calls. Cancel child work and discard this JS context so
        // late Promise callbacks cannot attach to the next source operation.
        callJS(action: "cancelRequest", data: ["requestKey": requestKey])
        guard let continuation = pending.removeValue(forKey: requestKey) else { return }
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = nil
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        scriptRequestKeys.removeAll()
        key = UUID().uuidString
        context = nil
        loadedID = nil
        loadedScript = nil
        capabilities = [:]
        qualityCapabilities = [:]
        statusMessage = "音源请求已取消，下次使用时重新加载"
        continuation.resume(throwing: error)
    }

    private func cancelPendingRequests() {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = nil
        for requestKey in Array(pending.keys) {
            cancelPendingRequest(with: requestKey)
        }
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        scriptRequestKeys.removeAll()
        context = nil
        loadedID = nil
        capabilities = [:]
        qualityCapabilities = [:]
        session.invalidateAndCancel()
    }

    /// `init` is delivered through a main-actor callback. A number of user API
    /// sources initialise through a short network request, so do not reject
    /// the first playback request before that response has had a chance to
    /// arrive.  We still stop after a bounded interval and report the source
    /// state instead of inventing capabilities.
    private func waitForSourceReady() async {
        guard loadedID != nil else { return }
        for _ in 0..<120 {
            if Task.isCancelled { return }
            if !capabilities.isEmpty || context == nil || pendingInitializationID == nil { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
    }

    /// Never leave the manager in a permanent loading state.  Crucially this
    /// timeout must not manufacture a platform/quality capability table: that
    /// made unsupported routes appear selectable and broke genuine playback.
    private func scheduleInitializationFallback(for sourceID: String) {
        sourceInitializationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled,
                  let self,
                  self.pendingInitializationID == sourceID,
                  self.loadedID == sourceID else { return }
            self.pendingInitializationID = nil
            self.statusMessage = "音源未在 6 秒内返回平台能力，请重新加载或更换音源"
        }
    }

    private func callJS(action: String, data: Any? = nil) {
        guard let context, let function = context.objectForKeyedSubscript("__lx_native__") else { return }
        let encoded: String?
        if let data, let json = try? JSONSerialization.data(withJSONObject: data), let string = String(data: json, encoding: .utf8) {
            encoded = string
        } else {
            encoded = nil
        }
        _ = function.call(withArguments: encoded == nil ? [key, action] : [key, action, encoded!])
    }

    private func sourceCandidates(for track: Track, action: String = "musicUrl") -> [String] {
        let primary = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var values: [String] = []

        // Soda Music is a playlist-import format only. Its IDs are not sent
        // to an LX source as a playable platform; imported tracks are matched
        // against the real catalogue platforms below instead.
        if primary != "sd" {
            values.append(primary)
        }

        if primary == "sd" {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        } else if SettingsManager.shared.enableSourcePlatformFallback {
            values.append(contentsOf: ["wy", "kw", "kg", "tx", "mg"])
        }
        var seen = Set<String>()
        return values.filter { platform in
            capabilities[platform]?.contains(action) == true && seen.insert(platform).inserted
        }
    }

    private func activate(_ source: LXSourceStore.Source) async -> Bool {
        if loadedID != source.id || loadedScript != source.script || context == nil {
            load(source)
        }
        await waitForSourceReady()
        return loadedID == source.id && context != nil && !capabilities.isEmpty
    }

    private func validateSourceConfiguration(
        _ revision: Int,
        source: LXSourceStore.Source? = nil
    ) throws {
        let store = LXSourceStore.shared
        guard store.configurationRevision == revision else { throw CancellationError() }
        if let source,
           !store.playbackSources.contains(where: { $0.id == source.id && $0.script == source.script }) {
            throw CancellationError()
        }
    }

    /// Music URL, lyric and per-track quality requests all switch this single
    /// JavaScript context while awaiting source callbacks. Keep each complete
    /// operation exclusive so another request cannot replace its context/key
    /// and strand the first continuation until timeout.
    private func acquireSourceOperation() async throws {
        try Task.checkCancellation()
        guard sourceOperationActive else {
            sourceOperationActive = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sourceOperationWaiters.append(SourceOperationWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelSourceOperationWaiter(id) }
        }
    }

    private func cancelSourceOperationWaiter(_ id: UUID) {
        guard let index = sourceOperationWaiters.firstIndex(where: { $0.id == id }) else { return }
        sourceOperationWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseSourceOperation() {
        if !sourceOperationWaiters.isEmpty {
            sourceOperationWaiters.removeFirst().continuation.resume()
            return
        }
        sourceOperationActive = false
        guard selectedSourceReloadPending else { return }
        selectedSourceReloadPending = false
        let forceReload = selectedSourceReloadForced
        selectedSourceReloadForced = false
        let source = LXSourceStore.shared.selectedSource
        guard forceReload || loadedID != source?.id || loadedScript != source?.script else { return }
        load(source)
    }

    private func invalidateSourceWork() {
        sourceInitializationTask?.cancel()
        sourceInitializationTask = nil
        pendingInitializationID = nil
        for requestKey in Array(pending.keys) {
            cancelPendingRequest(with: requestKey)
        }
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        scriptRequestKeys.removeAll()
        context = nil
        loadedID = nil
        loadedScript = nil
        capabilities = [:]
        qualityCapabilities = [:]
        statusMessage = "音源配置已更新"
        if sourceOperationActive {
            selectedSourceReloadPending = true
        }
    }

    private func canonicalPlatform(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }
        switch value {
        case "wy", "163", "netease", "neteasecloudmusic", "netease-cloud-music", "cloudmusic":
            return "wy"
        case "kw", "kuwo": return "kw"
        case "kg", "kugou": return "kg"
        case "tx", "qq", "qqmusic", "qq-music": return "tx"
        case "mg", "migu": return "mg"
        case "sd", "soda", "sodamusic", "soda-music", "qishui", "qishui-music": return "sd"
        default: return value
        }
    }

    /// This is only request metadata for the source's health check. It is not
    /// a playback catalogue and it never leaves the device except as part of
    /// the user-selected source's own `musicUrl` request.
    static func sourceCheckTrack(for platform: String) -> Track? {
        guard platform == "wy" else { return nil }
        return Track(
            id: 186_016,
            name: "晴天",
            artists: [ArtistRef(id: 1, name: "周杰伦")],
            album: AlbumRef(id: 0, name: "音源连通性测试", picUrl: nil),
            durationMS: 269_000,
            source: platform,
            sourceMetadata: [
                "id": "186016",
                "songmid": "186016",
                "songId": "186016",
                "copyrightId": "186016",
            ]
        )
    }

    // Canonical LX quality tokens, ordered from lowest to highest. Source-specific
    // names are normalized into this list only when the imported source declares them.
    private static let qualityOrder = ["128k", "320k", "flac", "flac24bit", "surround", "dolby", "atmos", "jymaster"]

    func availableQualityNames(for track: Track) async -> [String] {
        let resolver = Self.qualityResolver
        do {
            try await resolver.acquireSourceOperation()
        } catch {
            return []
        }
        defer { resolver.releaseSourceOperation() }
        guard !Task.isCancelled else { return [] }
        return await resolver.resolveAvailableQualityNames(for: track)
    }

    private func resolveAvailableQualityNames(for track: Track) async -> [String] {
        let store = LXSourceStore.shared
        let sourceRevision = store.configurationRevision
        let playbackSources = store.playbackSources
        let primaryPlatform = canonicalPlatform(track.source ?? track.sourceMetadata["source"]) ?? "wy"
        var available = Set<String>()
        if SettingsManager.shared.playbackSourceMode != .thirdParty {
            if primaryPlatform == "wy", NeteaseClient.shared.isLoggedIn {
                available.formUnion(await NeteaseAPI.officialQualityNames(
                    for: track.id, duration: track.duration
                ))
            } else if primaryPlatform == "tx", QQMusicSessionStore.shared.isLoggedIn {
                available.formUnion(await officialQualityNames(for: track, platform: "tx"))
            } else if primaryPlatform == "kg", KugouSessionStore.shared.isLoggedIn {
                available.formUnion(await officialQualityNames(for: track, platform: "kg"))
            }
        }
        for source in playbackSources {
            guard !Task.isCancelled,
                  store.configurationRevision == sourceRevision,
                  store.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { return [] }
            guard await activate(source) else { continue }
            guard !Task.isCancelled,
                  store.configurationRevision == sourceRevision,
                  store.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { return [] }
            let platforms = sourceCandidates(for: track, action: "musicUrl")
            // Quality probing is per-song and performs real network requests.
            // Probe the track's own catalogue first; only use one fallback
            // catalogue when that source cannot serve the primary platform.
            // This keeps the picker accurate without turning it into dozens of
            // cross-platform requests every time the sheet opens.
            let platformsToProbe = platforms.contains(primaryPlatform)
                ? [primaryPlatform]
                : Array(platforms.prefix(1))
            for platform in platformsToProbe {
                let qualityTrack: Track
                if platform == primaryPlatform {
                    qualityTrack = track
                } else {
                    guard let matched = await LXCatalogService.matchingTrack(track, on: platform) else { continue }
                    guard !Task.isCancelled,
                          store.configurationRevision == sourceRevision,
                          store.playbackSources.contains(where: {
                              $0.id == source.id && $0.script == source.script
                          }) else { return [] }
                    qualityTrack = matched
                }
                let declaredQualities = supportedQualityNames(for: qualityTrack, platform: platform)
                // `qualitys` describes what the adapter claims to support,
                // not what this particular song actually has.  Probe the
                // song's musicUrl response before exposing a quality picker;
                // otherwise a source that declares lossless/master globally
                // makes a 128K-only track advertise unavailable tiers.
                available.formUnion(await probeQualityNames(
                    source: source,
                    platform: platform,
                    track: qualityTrack,
                    declared: declaredQualities,
                    sourceRevision: sourceRevision
                ))
                guard store.configurationRevision == sourceRevision else { return [] }
            }
        }
        let order = Self.qualityOrder
        // The UI is best-first; protocol requests still use the canonical order.
        return order.reversed().filter(available.contains)
    }

    /// Probe account endpoints instead of presenting a hard-coded capability
    /// list. A returned URL and returned provider quality are both required,
    /// so a VIP-only or unavailable tier never appears in the picker.
    private func officialQualityNames(for track: Track, platform: String) async -> [String] {
        var result: [String] = []

        func append(_ resolvedQuality: String) {
            guard let quality = AudioQuality(lxType: resolvedQuality),
                  !result.contains(quality.lxType) else { return }
            result.append(quality.lxType)
        }

        if platform == "tx", let cookie = QQMusicSessionStore.shared.cookie {
            let songMid = track.sourceMetadata["songmid"] ?? String(track.id)
            let mediaMid = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]
                : track.sourceMetadata["media_mid"]
            for requested in ["flac", "320k", "128k"] {
                if let audio = try? await QQMusicAPI.shared.musicURL(
                    songMid: songMid, mediaMid: mediaMid, quality: requested, cookie: cookie
                ), isValidAudioURL(audio.url) {
                    append(audio.quality)
                }
            }
        }

        if platform == "kg", let cookie = KugouSessionStore.shared.cookie,
           let hash = track.sourceMetadata["hash"] ?? track.sourceMetadata["Hash"],
           !hash.isEmpty {
            let albumID = track.sourceMetadata["albumId"]
            let albumAudioID = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
            for requested in ["jymaster", "atmos", "dolby", "flac24bit", "flac", "320k", "128k"] {
                if let audio = try? await KugouAPI.shared.musicURL(
                    hash: hash, quality: requested, cookie: cookie,
                    albumID: albumID, albumAudioID: albumAudioID
                ), isValidAudioURL(audio.url) {
                    append(audio.quality)
                }
            }
        }

        return result
    }

    private func probeQualityNames(
        source: LXSourceStore.Source,
        platform: String,
        track: Track,
        declared: [String],
        sourceRevision: Int
    ) async -> Set<String> {
        guard !Task.isCancelled,
              LXSourceStore.shared.configurationRevision == sourceRevision,
              LXSourceStore.shared.playbackSources.contains(where: {
                  $0.id == source.id && $0.script == source.script
              }) else { return [] }
        guard await activate(source) else { return [] }
        guard !Task.isCancelled,
              LXSourceStore.shared.configurationRevision == sourceRevision,
              LXSourceStore.shared.playbackSources.contains(where: {
                  $0.id == source.id && $0.script == source.script
              }) else { return [] }
        let requestedQualities = declared.isEmpty ? ["128k"] : declared
        var requestable = Set<String>()

        for requested in requestedQualities {
            guard !Task.isCancelled,
                  LXSourceStore.shared.configurationRevision == sourceRevision,
                  LXSourceStore.shared.playbackSources.contains(where: {
                      $0.id == source.id && $0.script == source.script
                  }) else { break }
            do {
                let response = try await request(
                    source: platform,
                    action: "musicUrl",
                    info: [
                        "type": protocolQualityToken(requested, platform: platform),
                        "musicInfo": musicInfo(
                            for: track,
                            platform: platform,
                            qualities: requestedQualities
                        )
                    ]
                )
                guard LXSourceStore.shared.configurationRevision == sourceRevision,
                      let data = response["data"] as? [String: Any],
                      let rawURL = data["url"] as? String,
                      let url = URL(string: rawURL),
                      let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else { continue }

                // LX's bridge returns a URL and echoes the requested tier,
                // but does not expose the provider's actual codec/bitrate.
                // This only establishes that the source accepted the request.
                requestable.insert(Self.normalizedQuality(requested))
            } catch {
                if error is CancellationError { break }
                guard LXSourceStore.shared.configurationRevision == sourceRevision else { break }
            }
        }

        return requestable
    }

    private func isValidAudioURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Return the qualities that can be requested for this track.
    ///
    /// LX source `qualitys` describes the source adapter's capabilities, while
    /// catalogue file sizes describe the individual song.  Use both when the
    /// catalogue knows the song.  When it does not, the declaration is only a
    /// probe candidate; `probeQualityNames` must receive a matching URL for
    /// the request before the tier reaches the UI. LX sources cannot confirm
    /// the actual file quality.
    private func supportedQualityNames(for track: Track, platform: String) -> [String] {
        let order = Self.qualityOrder
        let declared = qualityCapabilities[platform, default: []]
            .map { Self.normalizedQuality($0) }
            .filter { order.contains($0) }
        let sourceNames = declared.isEmpty ? ["128k"] : order.filter(declared.contains)
        let concrete = Self.qualityNames(for: track)

        if !concrete.isEmpty {
            return order.filter { sourceNames.contains($0) && concrete.contains($0) }
        }

        return sourceNames
    }

    /// Preserve the token expected by the selected LX script. The UI treats
    /// aliases such as master/jymaster as one tier, but the request keeps the
    /// exact token advertised by the active source.
    private func protocolQualityToken(_ quality: String, platform: String) -> String {
        let canonical = Self.normalizedQuality(quality)
        return qualityCapabilities[platform, default: []].first {
            Self.normalizedQuality($0) == canonical
        } ?? quality
    }

    private func musicInfo(for track: Track, platform: String,
                           qualities requestedQualities: [String]? = nil) -> [String: Any] {
        // LX's User API receives the legacy MusicInfo object, not Kumone's
        // internal Track. This mirrors LX Mobile's toOldMusicInfo() exactly.
        let songmid = track.sourceMetadata["songmid"]
            ?? track.sourceMetadata["songId"]
            ?? String(track.id)
        let albumID = track.sourceMetadata["albumId"] ?? String(track.album.id)
        let canonicalQualities = requestedQualities?.isEmpty == false
            ? requestedQualities!
            : (Self.qualityNames(for: track).isEmpty ? ["128k"] : Self.qualityNames(for: track))
        let qualities = canonicalQualities.map { protocolQualityToken($0, platform: platform) }
        let qualityInfo = canonicalQualities.enumerated().map { index, canonical in
            let protocolToken = qualities[index]
            let size = track.sourceMetadata["lx.quality.\(canonical).size"]
                ?? track.sourceMetadata["lx.quality.\(protocolToken).size"]
                ?? ""
            return ["type": protocolToken, "size": size] as [String: Any]
        }
        let qualityMap = Dictionary(uniqueKeysWithValues: canonicalQualities.enumerated().map { index, canonical in
            let protocolToken = qualities[index]
            let size = track.sourceMetadata["lx.quality.\(canonical).size"]
                ?? track.sourceMetadata["lx.quality.\(protocolToken).size"]
                ?? ""
            return (protocolToken, ["size": size] as [String: Any])
        })
        var info: [String: Any] = [
            "name": track.name,
            "singer": track.artistNames,
            "source": platform,
            "songmid": songmid,
            "interval": String(format: "%02d:%02d", Int(track.duration) / 60, Int(track.duration) % 60),
            "albumName": track.album.name,
            "img": track.album.picUrl ?? "",
            "typeUrl": [:] as [String: String],
            "albumId": albumID,
            "types": qualityInfo,
            "_types": qualityMap,
        ]
        switch platform {
        case "kg":
            info["hash"] = track.sourceMetadata["hash"] ?? ""
            info["albumId"] = track.sourceMetadata["albumId"] ?? albumID
            info["albumAudioId"] = track.sourceMetadata["albumAudioId"]
                ?? track.sourceMetadata["albumAudioID"]
                ?? track.sourceMetadata["mixsongid"]
        case "tx":
            info["songId"] = Int(track.sourceMetadata["id"] ?? "") ?? track.id
            info["strMediaMid"] = track.sourceMetadata["strMediaMid"]?.isEmpty == false
                ? track.sourceMetadata["strMediaMid"]!
                : (track.sourceMetadata["media_mid"] ?? "")
            info["albumMid"] = track.sourceMetadata["albumMid"] ?? ""
        case "mg":
            info["copyrightId"] = track.sourceMetadata["copyrightId"] ?? songmid
            for key in ["lrcUrl", "mrcUrl", "trcUrl"] {
                if let value = track.sourceMetadata[key], !value.isEmpty { info[key] = value }
            }
        default:
            break
        }
        return info
    }

    private static func qualityNames(for track: Track) -> [String] {
        let order = Self.qualityOrder
        let concrete = order.filter { quality in
            guard let value = track.sourceMetadata["lx.quality.\(quality).size"] else { return false }
            return hasPositiveFileSize(value)
        }
        return concrete
    }

    private static func hasPositiveFileSize(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let match = normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let number = Double(String(normalized[match])), number > 0 else { return false }
        return true
    }

    private static func lxQuality(for quality: String, supported: [String]) -> String {
        let requested: String
        switch quality {
        case "master": requested = "jymaster"
        case "atmos": requested = "atmos"
        case "dolby": requested = "dolby"
        case "surround": requested = "surround"
        case "standard": requested = "128k"
        case "higher", "exhigh": requested = "320k"
        case "lossless": requested = "flac"
        case "hires": requested = "flac24bit"
        default: requested = "320k"
        }
        guard !supported.isEmpty else { return "128k" }
        let order = Self.qualityOrder
        guard let requestedIndex = order.firstIndex(of: Self.normalizedQuality(requested)) else { return supported[0] }
        return order[...requestedIndex].reversed().first(where: supported.contains)
            ?? supported.first
            ?? "128k"
    }
    private static func normalizedQuality(_ value: String) -> String {
        let value = value.lowercased().replacingOccurrences(of: " ", with: "")
        switch value {
        case "128", "128k", "mp3": return "128k"
        case "320", "320k": return "320k"
        case "flac", "lossless", "ape": return "flac"
        case "flac24", "flac24bit", "hires", "highres": return "flac24bit"
        case "master", "jymaster", "master_quality", "master-quality": return "jymaster"
        case "atmos", "immersive": return "atmos"
        case "dolby", "dolby-atmos", "dolbyatmos": return "dolby"
        case "surround", "spatial", "spatial-audio": return "surround"
        default: return value
        }
    }
    private static func resolvedQuality(returned: String?, requested: String,
                                        available _: [String]) -> String {
        guard let returned else { return requested }
        let normalized = normalizedQuality(returned)
        let order = Self.qualityOrder
        guard let requestedIndex = order.firstIndex(of: normalizedQuality(requested)),
              let returnedIndex = order.firstIndex(of: normalized),
              returnedIndex <= requestedIndex else { return requested }
        return normalized
    }
}

private extension String {
    var lxFormEncoded: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

private func md5Hex(_ value: String) -> String {
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    let data = Data(value.utf8)
    data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func aesEncrypt(input: String, key: String, iv: String, mode: String) -> String {
    guard let inputData = Data(base64Encoded: input), let keyData = Data(base64Encoded: key) else { return "" }
    let ivData = Data(base64Encoded: iv) ?? Data(repeating: 0, count: kCCBlockSizeAES128)
    let options: CCOptions = mode == "AES"
        ? CCOptions(kCCOptionECBMode)
        : CCOptions(kCCOptionPKCS7Padding)
    var output = [UInt8](repeating: 0, count: inputData.count + kCCBlockSizeAES128)
    var moved = 0
    let status = inputData.withUnsafeBytes { inputBuffer in
        keyData.withUnsafeBytes { keyBuffer in
            ivData.withUnsafeBytes { ivBuffer in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                        keyBuffer.baseAddress, keyData.count, mode == "AES" ? nil : ivBuffer.baseAddress,
                        inputBuffer.baseAddress, inputData.count, &output, output.count, &moved)
            }
        }
    }
    guard status == kCCSuccess else { return "" }
    return Data(output.prefix(moved)).base64EncodedString()
}

private func rsaEncrypt(input: String, publicKey: String, padding: String) -> String {
    guard let inputData = Data(base64Encoded: input), let keyData = Data(base64Encoded: publicKey) else { return "" }
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                       kSecAttrKeyClass: kSecAttrKeyClassPublic]
    guard let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) else { return "" }
    let algorithm: SecKeyAlgorithm = padding == "RSA/ECB/NoPadding" ? .rsaEncryptionRaw : .rsaEncryptionOAEPSHA1
    guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, inputData as CFData, nil) as Data? else { return "" }
    return encrypted.base64EncodedString()
}
#endif
