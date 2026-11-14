import Foundation

// Public catalogue protocol adapted from GSQZ/qishui-music-api, MIT License.
// https://github.com/GSQZ/qishui-music-api (commit 924add376cadf8a2268f11999051eb976e3b8e0d)
// No account credentials or protected audio are used by this catalogue client.
actor QishuiSearch {
    static let shared = QishuiSearch()
    private let session: URLSession
    private let deviceID = String(UInt64.random(in: 1_000_000_000_000_000_000...9_999_999_999_999_999_999))
    private var token: String?
    private struct CachedDetail {
        let track: Track
        let lyrics: LXCatalogService.NativeLyrics?
        let date: Date
    }
    private var details: [String: CachedDetail] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
    }

    private func url(host: String, path: String, tokenRequest: Bool = false) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/luna/v1/platform" + path
        let fixed: [String: String] = [
            "aid": "765213", "app_id": "765213", "app_name": "byte_autoservice_lite",
            "version_code": "100010", "version_name": "1.0.10", "channel": "bydSong",
            "sdk_aid": "753999", "caller_name": "luna_open_sdk", "sdk_version_code": "100000100",
            "sdk_version_name": "0.0.1", "sdk_channel": "Test", "vehicle_type": "BYD",
            "device_brand": "BYD", "device_type": "BYD", "device_platform": "android",
            "resolution": "1920x1080", "os_version": "13", "ac": "wifi",
            "device_id": deviceID, "did": deviceID, "iid": deviceID, "vehicle_id": "qishui-\(deviceID)",
            "_timestamp": String(Int(Date().timeIntervalSince1970)), "_nonce": String(UInt16.random(in: .min ... .max))
        ]
        components.queryItems = fixed.map { URLQueryItem(name: $0.key, value: $0.value) }
        if tokenRequest { components.queryItems?.append(URLQueryItem(name: "trigger_type", value: "cold_start")) }
        guard let url = components.url else { throw LXCatalogError.invalidResponse }
        return url
    }

    private func object(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 4_000_000,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LXCatalogError.invalidResponse
        }
        return root
    }

    private func clientToken() async throws -> String {
        if let token { return token }
        var request = URLRequest(url: try url(host: "open.qishui.com", path: "/client/token/get/", tokenRequest: true))
        request.setValue("LunaOpenSDK/1.0.10", forHTTPHeaderField: "User-Agent")
        let result = try await object(request)
        guard (result["err_no"] as? NSNumber)?.intValue == 0,
              let value = result["client_token"] as? String, !value.isEmpty else {
            throw LXCatalogError.unavailable
        }
        token = value
        return value
    }

    func search(_ keyword: String, page: Int, limit: Int) async throws -> [Track] {
        guard page > 0, limit > 0, page <= 10_000 else { throw LXCatalogError.invalidResponse }
        let searchID = UUID().uuidString
        let pageSize = min(limit, 100)
        var cursor = (page - 1) * pageSize
        var tracks: [Track] = []
        // Malformed/filtered rows must not turn an upstream has_more flag
        // into an unbounded request loop.
        for _ in 0..<20 where tracks.count < pageSize {
            try Task.checkCancellation()
            let body: [String: Any] = ["q": keyword, "cursor": String(cursor), "search_id": searchID,
                                   "from_search_id": searchID, "search_method": "input", "search_type": "track",
                                   "search_scene": "normal", "scene_name": "search", "ab_param": "",
                                   "last_viewed_media": [:], "common_params": [:]]
            let group = try await searchGroup(body)
            guard let group else { break }
            guard let rows = group["data"] as? [[String: Any]] else { throw LXCatalogError.invalidResponse }
            let remaining = pageSize - tracks.count
            let selected = rows.prefix(remaining)
            tracks.append(contentsOf: selected.compactMap { row in
                guard let entity = row["entity"] as? [String: Any],
                      let raw = entity["track"] as? [String: Any] else { return nil }
                let parsed = Self.track(raw)
                if let parsed { cache(parsed, lyrics: Self.lyrics(raw)) }
                return parsed
            })
            if rows.count >= remaining || rows.isEmpty || group["has_more"] as? Bool != true { break }
            let next = (group["next_cursor"] as? String).flatMap(Int.init)
                ?? (group["next_cursor"] as? NSNumber)?.intValue
            guard let next, next > cursor else { throw LXCatalogError.invalidResponse }
            cursor = next
        }
        return tracks
    }

    private func searchGroup(_ body: [String: Any]) async throws -> [String: Any]? {
        let data = try await catalogueData(path: "/search/", body: body)
        guard let groups = data["result_groups"] as? [[String: Any]] else { throw LXCatalogError.invalidResponse }
        return groups.first(where: { $0["id"] as? String == "tracks" })
    }

    // Public metadata only. Never read player_info, media/mcheck, audio URLs,
    // decryption keys, account cookies, or an imported source's credentials.
    private func catalogueData(path: String, body: [String: Any]) async throws -> [String: Any] {
        for attempt in 0...1 {
            try Task.checkCancellation()
            let current = try await clientToken()
            var request = URLRequest(url: try url(host: "open.douyin.com", path: path))
            request.httpMethod = "POST"
            request.setValue("LunaOpenSDK/1.0.10", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(current, forHTTPHeaderField: "access-token")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let root = try await object(request)
            let code = (root["err_no"] as? NSNumber)?.intValue ?? -1
            if code == 28001008, attempt == 0 {
                if token == current { token = nil }
                continue
            }
            guard code == 0, let data = root["data"] as? [String: Any] else { throw LXCatalogError.unavailable }
            return data
        }
        throw LXCatalogError.unavailable
    }

    /// Refreshes metadata for tracks saved by an older build. Callers must
    /// reject stale results before updating the current track/queue.
    func metadata(for track: Track) async throws -> Track {
        try await detail(for: track).track
    }

    func nativeLyrics(for track: Track) async throws -> LXCatalogService.NativeLyrics {
        guard let lyrics = try await detail(for: track, requireLyrics: true).lyrics else { throw LXCatalogError.unavailable }
        return lyrics
    }

    private func detail(for track: Track, requireLyrics: Bool = false) async throws -> CachedDetail {
        try Task.checkCancellation()
        let id = track.sourceMetadata["qishuiTrackID"] ?? track.sourceMetadata["songmid"]
            ?? track.sourceMetadata["songId"] ?? String(track.id)
        guard let numeric = Int(id), numeric > 0 else { throw LXCatalogError.invalidResponse }
        if let entry = details[id], Date().timeIntervalSince(entry.date) < 300,
           requireLyrics ? entry.lyrics != nil : !entry.track.album.name.isEmpty && entry.track.album.picUrl != nil {
            return entry
        }
        let data = try await catalogueData(path: "/media/mget/", body: [
            "media_list": [["id": id, "type": "track"]], "card_context": [:], "common_params": [:]
        ])
        guard let media = data["media_list"] as? [[String: Any]],
              let raw = media.first(where: { item in
                  let entity = item["track_entity"] as? [String: Any] ?? [:]
                  let base = entity["base_info"] as? [String: Any] ?? [:]
                  return base["id"] as? String == id
              }), let value = Self.track(raw), String(value.id) == id else { throw LXCatalogError.invalidResponse }
        try Task.checkCancellation()
        return cache(value, lyrics: Self.lyrics(raw))
    }

    @discardableResult
    private func cache(_ track: Track, lyrics: LXCatalogService.NativeLyrics?) -> CachedDetail {
        let id = track.sourceMetadata["songmid"] ?? String(track.id)
        if details.count >= 64, details[id] == nil,
           let oldest = details.min(by: { $0.value.date < $1.value.date })?.key { details.removeValue(forKey: oldest) }
        let entry = CachedDetail(track: track, lyrics: lyrics, date: Date())
        details[id] = entry
        return entry
    }

    static func track(_ raw: [String: Any]) -> Track? {
        let track = entity(raw)
        guard let base = track["base_info"] as? [String: Any],
              let id = base["id"] as? String, let numericID = Int(id), numericID > 0,
              let name = base["name"] as? String, !name.isEmpty else { return nil }
        let related = track["related_info"] as? [String: Any] ?? [:]
        let artists = (related["artist_links"] as? [[String: Any]] ?? []).compactMap { artist -> ArtistRef? in
            guard let name = artist["name"] as? String, !name.isEmpty else { return nil }
            return ArtistRef(id: Int(artist["id"] as? String ?? "") ?? 0, name: name)
        }
        let album = related["album_link"] as? [String: Any] ?? [:]
        let display = track["display_info"] as? [String: Any] ?? [:]
        let image = imageURL(display["cover_url"])
        return Track(id: numericID, name: name, artists: artists,
                     album: AlbumRef(id: Int(album["id"] as? String ?? "") ?? 0,
                                     name: album["name"] as? String ?? "", picUrl: image),
                      durationMS: (base["duration_ms"] as? NSNumber)?.intValue ?? 0,
                      source: "sd", sourceMetadata: ["songmid": id, "qishuiTrackID": id,
                                                     "albumId": album["id"] as? String ?? "0"])
    }

    private static func entity(_ raw: [String: Any]) -> [String: Any] {
        if let track = raw["track_entity"] as? [String: Any] { return track }
        if let entity = raw["entity"] as? [String: Any] {
            if let media = entity["media"] as? [String: Any] { return Self.entity(media) }
            if let track = entity["track"] as? [String: Any] { return Self.entity(track) }
        }
        if let track = raw["track"] as? [String: Any] { return Self.entity(track) }
        return raw
    }

    static func imageURL(_ value: Any?) -> String? {
        func trusted(_ value: String) -> URL? {
            guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let host = url.host?.lowercased(), host == "douyinpic.com" || host.hasSuffix(".douyinpic.com") else { return nil }
            return url
        }
        if let direct = value as? String { return trusted(direct)?.absoluteString }
        guard let image = value as? [String: Any], let urls = image["urls"] as? [String],
              let base = urls.compactMap(trusted).first else { return nil }
        if image["need_complete_url"] as? Bool == true { return base.absoluteString }
        guard let uri = image["uri"] as? String, !uri.isEmpty, uri.count <= 1024,
              uri.range(of: #"^[A-Za-z0-9_/-]+$"#, options: .regularExpression) != nil,
              !uri.hasPrefix("/"), !uri.contains(".."), base.query == nil, base.fragment == nil else { return nil }
        let prefix = image["template_prefix"] as? String ?? "tplv-b829550vbb"
        guard prefix.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { return nil }
        // Bare CDN object paths return HTTP 400; this public image template
        // returns a JPEG. Do not append it to already-complete signed URLs.
        return base.appendingPathComponent(uri + "~" + prefix + "-crop-center:720:720.jpg").absoluteString
    }

    static func lyrics(_ raw: [String: Any]) -> LXCatalogService.NativeLyrics? {
        let display = entity(raw)["display_info"] as? [String: Any] ?? [:]
        guard let info = display["lyric_info"] as? [String: Any],
              let main = info["lyric_entity"] as? [String: Any],
              let result = lyricEntity(main) else { return nil }
        let translations = info["lang_translations"] as? [String: Any] ?? [:]
        let translated = translations.keys.sorted().compactMap { key -> String? in
            guard let value = translations[key] as? [String: Any] else { return nil }
            return lyricEntity(value["lyric_entity"] as? [String: Any] ?? value)?.lyric
        }.first
        // An explicit empty romaji body prevents parseLX from treating this
        // verbatim timing stream as its legacy lxlyric-as-romaji fallback.
        return LXCatalogService.NativeLyrics(lyric: result.lyric, tlyric: translated,
                                              rlyric: result.lxlyric == nil ? nil : "", lxlyric: result.lxlyric)
    }

    private static func lyricEntity(_ entity: [String: Any]) -> (lyric: String, lxlyric: String?)? {
        guard let content = entity["content"] as? String, content.utf8.count <= 262_144,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        switch (entity["type"] as? String)?.lowercased() {
        case "lrc", "txt": return (content, nil)
        case "krc":
            // The public API returns decoded KRC, not an encrypted KRC file.
            // Convert its relative word tags to LX's supported verbatim format.
            let head = #/^\[(\d+),(\d+)\](.*)$/#
            var lrc: [String] = []
            var verbatim: [String] = []
            for line in content.components(separatedBy: .newlines) {
                guard let match = line.firstMatch(of: head), let start = Int(match.output.1),
                      start <= 86_400_000 else { continue }
                let body = String(match.output.3)
                let text = body.replacingOccurrences(of: #"<\d+,\d+,\d+>"#, with: "", options: .regularExpression)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let timestamp = String(format: "[%02d:%02d.%03d]", start / 60_000, start / 1000 % 60, start % 1000)
                lrc.append(timestamp + text)
                verbatim.append(timestamp + body.replacingOccurrences(of: #"<(\d+),(\d+),\d+>"#,
                                                                       with: "<$1,$2>", options: .regularExpression))
            }
            guard !lrc.isEmpty else { return nil }
            return (lrc.joined(separator: "\n"), verbatim.joined(separator: "\n"))
        default: return nil
        }
    }
}
