import Foundation

// Public catalogue protocol adapted from GSQZ/qishui-music-api, MIT License.
// https://github.com/GSQZ/qishui-music-api (commit 924add376cadf8a2268f11999051eb976e3b8e0d)
// No account credentials or protected audio are used by this catalogue client.
actor QishuiSearch {
    static let shared = QishuiSearch()
    private let session: URLSession
    private let deviceID = String(UInt64.random(in: 1_000_000_000_000_000_000...9_999_999_999_999_999_999))
    private var token: String?

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
        while tracks.count < pageSize {
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
                return Self.track(raw)
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
        for attempt in 0...1 {
            let current = try await clientToken()
            var request = URLRequest(url: try url(host: "open.douyin.com", path: "/search/"))
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
            guard code == 0, let data = root["data"] as? [String: Any],
                  let groups = data["result_groups"] as? [[String: Any]] else { throw LXCatalogError.unavailable }
            return groups.first(where: { $0["id"] as? String == "tracks" }) ?? groups.first
        }
        throw LXCatalogError.unavailable
    }

    static func track(_ raw: [String: Any]) -> Track? {
        let track = raw["track_entity"] as? [String: Any] ?? raw
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
        let cover = display["cover_url"] as? [String: Any] ?? [:]
        var image: String?
        if let urls = cover["urls"] as? [String], let first = urls.first,
           let uri = cover["uri"] as? String, !uri.isEmpty,
           let root = URL(string: first), root.scheme == "https",
           let host = root.host?.lowercased(), host == "douyinpic.com" || host.hasSuffix(".douyinpic.com"),
           !uri.contains(".."), !uri.contains("?") {
            image = root.appendingPathComponent(uri).absoluteString
        }
        return Track(id: numericID, name: name, artists: artists,
                     album: AlbumRef(id: Int(album["id"] as? String ?? "") ?? 0,
                                     name: album["name"] as? String ?? "", picUrl: image),
                     durationMS: (base["duration_ms"] as? NSNumber)?.intValue ?? 0,
                     source: "sd", sourceMetadata: ["songmid": id, "qishuiTrackID": id])
    }
}
