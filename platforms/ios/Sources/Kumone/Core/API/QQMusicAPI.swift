import Foundation

/// QQ's QR flow must expose redirect responses so the app can collect the
/// account cookies and exchange the OAuth code for a Music session.
private final class QQNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// QQ Music account metadata used for optional recommendation synchronisation.
///
/// The account session is used for profile synchronisation and, when the
/// provider returns a full authorized URL, for QQ Music account playback.
actor QQMusicAPI {
    static let shared = QQMusicAPI()

    struct QRCodePayload: Sendable {
        let imageData: Data
        let qrsig: String
    }

    enum QRStatus: Sendable {
        case waiting
        case scanned
        case success(cookie: String)
        case expired
    }

    struct Profile: Sendable {
        let id: String
        let name: String
        let avatarURL: String?
        /// A provider-issued session replacement, if the response rotated it.
        let refreshedCookie: String?
    }

    struct Playlist: Hashable, Identifiable, Sendable {
        enum Kind: String, Hashable, Sendable {
            case created
            case collected
        }

        let id: String
        let name: String
        let coverURL: String?
        let trackCount: Int
        let creatorName: String
        let kind: Kind

        var isLikedSongs: Bool { id == "qq-liked:201" }
    }

    struct PlaylistListResult: Sendable {
        let playlists: [Playlist]
        let refreshedCookie: String?
    }

    struct PlaylistTracksResult: Sendable {
        let tracks: [Track]
        let refreshedCookie: String?
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case loginCookieUnavailable
        case unavailable
        case qrCodeUnavailable
        case oauthFailed
        case tooManyPlaylists
        case tooManyTracks
        case incompletePlaylist

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "QQ 音乐返回了无法识别的信息，请重新登录后重试"
            case .loginCookieUnavailable:
                return "QQ 网页已打开，但没有读取到可用的账号凭据。请确认网页已登录后再点“登录完成”"
            case .unavailable: return "QQ 音乐登录已失效或 Cookie 已过期"
            case .qrCodeUnavailable: return "QQ 当前拒绝了二维码请求，请稍后重试"
            case .oauthFailed: return "QQ 扫码成功，但音乐登录凭证获取失败，请重新扫码"
            case .tooManyPlaylists: return "QQ 歌单数量超过安全分页上限，请减少后重试"
            case .tooManyTracks: return "QQ 歌单歌曲数量超过安全分页上限，未保存不完整副本"
            case .incompletePlaylist: return "QQ 歌单内容未能完整获取，请重试；未保存部分副本"
            }
        }
    }

    private let endpoint = URL(string: "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg")!
    private let session: URLSession
    private let redirectSession: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        cookieStorage = HTTPCookieStorage()
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration)

        let redirectConfiguration = URLSessionConfiguration.ephemeral
        redirectConfiguration.httpCookieStorage = cookieStorage
        redirectConfiguration.httpShouldSetCookies = true
        redirectConfiguration.httpCookieAcceptPolicy = .always
        redirectConfiguration.timeoutIntervalForRequest = 20
        redirectConfiguration.timeoutIntervalForResource = 45
        redirectSession = URLSession(
            configuration: redirectConfiguration,
            delegate: QQNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// QQ Music's old `/portal/login.html` page was removed.  The supported
    /// QR route is QQ's ptlogin flow: request the image, poll ptqrlogin, then
    /// follow the returned authorization URL so the Music cookies are stored.
    func qrCode() async throws -> QRCodePayload {
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(format: "%.6f", Double.random(in: 0...1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await redirectSession.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 403 {
            throw APIError.qrCodeUnavailable
        }
        guard Self.isSuccess(response), let qrsig = Self.cookieValue("qrsig", from: response), !qrsig.isEmpty else {
            throw APIError.invalidResponse
        }
        // QQ occasionally returns an HTML anti-bot page with HTTP 200. Never
        // pass that body to SwiftUI as a QR image, otherwise the sheet remains
        // blank with an endless spinner.
        guard Self.looksLikeImage(data) else { throw APIError.qrCodeUnavailable }
        return QRCodePayload(imageData: data, qrsig: qrsig)
    }

    func poll(qrsig: String) async throws -> QRStatus {
        var components = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        components.queryItems = [
            URLQueryItem(name: "u1", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptqrtoken", value: String(Self.hash33(qrsig))),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "22080914"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: ""),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "o1vId", value: "49283d5cbb01a744d46314da4608d929")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("qrsig=\(qrsig)", forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await redirectSession.data(for: request)
        guard Self.isSuccess(response), let body = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse
        }

        guard let parsed = Self.parsePTUI(body) else { throw APIError.invalidResponse }
        let status = parsed.code
        switch status {
        case "66": return .waiting
        case "67": return .scanned
        case "65": return .expired
        case "0":
            guard let jumpURL = parsed.url else { throw APIError.oauthFailed }
            try await completeOAuth(redirectURL: jumpURL)
            let cookie = cookieHeader()
            guard !cookie.isEmpty else { throw APIError.unavailable }
            return .success(cookie: cookie)
        default:
            return .waiting
        }
    }

    /// Finish the QQ login redirect chain and exchange the OAuth code for a
    /// Music session key. The old implementation stopped at the first jump,
    /// which left only a partial ptlogin cookie and made the QR login appear
    /// successful while playback/profile validation still failed.
    private func completeOAuth(redirectURL: URL) async throws {
        var currentURL = redirectURL

        // check_sig sets skey/p_skey on one or more redirect responses.
        for _ in 0..<6 {
            var request = URLRequest(url: currentURL)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue(cookieHeader(includeQRSig: true), forHTTPHeaderField: "Cookie")
            let (_, response) = try await redirectSession.data(for: request)
            collectCookies(from: response)

            guard let http = response as? HTTPURLResponse,
                  (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  !location.isEmpty else { break }

            if let absolute = URL(string: location), absolute.scheme != nil {
                currentURL = absolute
            } else if let resolved = URL(string: location, relativeTo: currentURL) {
                currentURL = resolved
            } else {
                break
            }
        }

        let key = cookieValue("qqmusic_key")
            ?? cookieValue("qm_keyst")
            ?? cookieValue("p_skey")
            ?? cookieValue("skey")
            ?? cookieValue("pskey")
            ?? ""
        let fields: [String: String] = [
            "response_type": "code",
            "client_id": "100497308",
            "redirect_uri": "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/",
            "scope": "all",
            "state": "state",
            "switch": "",
            "from_ptlogin": "1",
            "src": "1",
            "update_auth": "1",
            "openapi": "80901010_1030",
            "g_tk": String(Self.hash5381(key)),
            "auth_time": String(Int(Date().timeIntervalSince1970 * 1000)),
            "ui": "DFEC5395-9E69-4D3E-96A6-300BB770874D"
        ]

        var authRequest = URLRequest(url: URL(string: "https://graph.qq.com/oauth2.0/authorize")!)
        authRequest.httpMethod = "POST"
        authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        authRequest.setValue("https://graph.qq.com/", forHTTPHeaderField: "Referer")
        authRequest.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        authRequest.httpBody = Self.formEncode(fields).data(using: .utf8)
        let (_, authResponse) = try await redirectSession.data(for: authRequest)
        collectCookies(from: authResponse)

        guard let authHTTP = authResponse as? HTTPURLResponse,
              let location = authHTTP.value(forHTTPHeaderField: "Location"),
              let code = Self.extractCode(from: location), !code.isEmpty else {
            throw APIError.oauthFailed
        }

        let loginPayload: [String: Any] = [
            "comm": ["g_tk": 5381, "platform": "yqq", "ct": 24, "cv": 0],
            "req": [
                "module": "QQConnectLogin.LoginServer",
                "method": "QQLogin",
                "param": ["code": code]
            ]
        ]
        var loginRequest = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        loginRequest.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        loginRequest.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        loginRequest.httpBody = try JSONSerialization.data(withJSONObject: loginPayload)
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        collectCookies(from: loginResponse)

        guard Self.isSuccess(loginResponse) else { throw APIError.oauthFailed }
        if let root = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
           let req = root["req"] as? [String: Any],
           let codeValue = Self.integer(in: req, keys: ["code", "ret"]),
           codeValue != 0 {
            throw APIError.oauthFailed
        }

        if let root = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
           let req = root["req"] as? [String: Any],
           let data = req["data"] as? [String: Any] {
            if let musicKey = Self.text(data["musickey"]), !musicKey.isEmpty {
                setCookieValue(musicKey, for: "musickey")
                setCookieValue(musicKey, for: "qm_keyst")
                setCookieValue(musicKey, for: "qqmusic_key")
            }
            if let musicID = Self.text(data["musicid"]), !musicID.isEmpty {
                setCookieValue(musicID, for: "uin")
            }
        }
    }

    /// Resolve an authorized QQ Music URL through the account session. A
    /// missing/paid URL is reported to the caller so automatic playback can
    /// fall back to enabled LX sources instead of playing a preview segment.
    func musicURL(songMid: String, mediaMid: String?, quality: String,
                  cookie: String) async throws -> ResolvedAudio {
        let fields = Self.cookieFields(cookie)
        let uin = fields["qqmusic_uin"] ?? fields["uin"] ?? "0"
        let guid = String(Int.random(in: 100_000_000...2_000_000_000))
        let fileID = mediaMid?.isEmpty == false ? mediaMid! : songMid
        let file = Self.filename(for: quality, mediaMid: fileID)
        let requestBody: [String: Any] = [
            "comm": [
                "cv": 4747474,
                "ct": 24,
                "format": "json",
                "inCharset": "utf-8",
                "outCharset": "utf-8",
                "notice": 0,
                "platform": "yqq.json",
                "needNewCode": 1,
                "uin": Int(uin) ?? 0
            ],
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": [file],
                    "guid": guid,
                    "songmid": [songMid],
                    "songtype": [0],
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20"
                ]
            ]
        ]
        let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody, options: [])
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/portal/player.html", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        let container = (root["req_1"] as? [String: Any])
            ?? (root["req_0"] as? [String: Any])
        let payload = container?["data"] as? [String: Any]
        let info = (payload?["midurlinfo"] as? [[String: Any]])?.first
        guard let path = Self.text(info?["purl"]), !path.isEmpty else {
            throw APIError.unavailable
        }
        let rawURL: String
        if let absolute = URL(string: path), absolute.scheme != nil {
            rawURL = path
        } else if let host = (payload?["sip"] as? [String])?.first, !host.isEmpty {
            rawURL = host + path
        } else {
            throw APIError.unavailable
        }
        guard let url = URL(string: rawURL.replacingOccurrences(of: "http://", with: "https://")),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw APIError.unavailable
        }
        let returnedName = Self.text(info?["filename"]) ?? file
        return ResolvedAudio(url: url, quality: Self.quality(forFilename: returnedName))
    }

    func profile(cookie: String) async throws -> Profile {
        let cookieValues = Self.cookieFields(cookie)
        let cookieID = ["qqmusic_uin", "uin", "musicid", "loginUin", "p_uin"]
            .compactMap { key in
                Self.cookieValue(key, in: cookieValues).flatMap(Self.normalizedQQIdentifier)
            }
            .first
        let authKey = Self.playlistAuthKey(in: cookieValues)

        // QQ's profile CGI is frequently blocked or returns an HTML anti-bot
        // page to embedded clients even while the desktop web session is
        // valid. The web login already supplies QQ's numeric account ID and
        // signed session ticket; use those as the session identity and treat
        // the profile endpoint as optional metadata enrichment.
        guard authKey?.isEmpty == false else {
            throw APIError.loginCookieUnavailable
        }
        let cookieProfile = cookieID.map { id in
            Profile(
                id: id,
                name: Self.cookieNickname(in: cookieValues) ?? "QQ 音乐用户",
                avatarURL: nil,
                refreshedCookie: nil
            )
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled else { throw CancellationError() }
            guard Self.isSuccess(response), let object = Self.jsonObject(from: data) else {
                if let cookieProfile { return cookieProfile }
                throw APIError.invalidResponse
            }

            let dataObject = object["data"] as? [String: Any] ?? object
            let info = dataObject["info"] as? [String: Any]
                ?? dataObject["user"] as? [String: Any]
                ?? dataObject["profile"] as? [String: Any]
                ?? dataObject
            let responseID = Self.text(in: info, keys: ["uin", "uid", "user_id", "loginUin"])
                .flatMap(Self.normalizedQQIdentifier)
            let code = Self.integer(in: object, keys: ["code", "subcode"])
            guard let id = responseID ?? cookieID,
                  code == nil || code == 0 || cookieID != nil else {
                if let cookieProfile { return cookieProfile }
                throw APIError.unavailable
            }
            let name = Self.text(in: info, keys: ["nick", "nickname", "name", "nickName"])
                ?? Self.cookieNickname(in: cookieValues)
                ?? "QQ 音乐用户"
            let avatar = Self.text(in: info, keys: ["logo", "avatar", "avatarUrl", "avatar_url"])
            return Profile(id: id, name: name, avatarURL: avatar,
                           refreshedCookie: Self.mergedCookie(
                            original: cookie,
                            response: response as? HTTPURLResponse
                           ))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            if let cookieProfile { return cookieProfile }
            throw error
        }
    }

    /// Reads created and collected playlists. QQ exposes no supported personal
    /// playlist API, so this follows the same read-only web endpoints used by
    /// the QQ Music client and never calls account mutation endpoints.
    func userPlaylists(cookie: String) async throws -> PlaylistListResult {
        let profile = try await profile(cookie: cookie)
        let requestCookie = profile.refreshedCookie ?? cookie
        let cookieValues = Self.cookieFields(requestCookie)
        let authKey = Self.playlistAuthKey(in: cookieValues) ?? ""
        guard !authKey.isEmpty else { throw APIError.unavailable }
        let csrfKey = Self.csrfKey(in: cookieValues) ?? authKey
        let csrf = String(Self.hash5381(csrfKey))
        let createdURL = "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss"
        let collectedURL = "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg"

        async let createdRows = try? await fetchPlaylistPages(
            endpoint: createdURL,
            query: [
                "hostUin": "0", "hostuin": profile.id, "g_tk": csrf,
                "loginUin": profile.id, "format": "json", "inCharset": "utf8",
                "outCharset": "utf-8", "notice": "0", "platform": "yqq.json",
                "needNewCode": "0"
            ],
            listKey: "disslist", pageSize: 200, inclusiveEnd: false,
            cookie: requestCookie
        )
        async let collectedRows = try? await fetchPlaylistPages(
            endpoint: collectedURL,
            query: [
                "ct": "20", "cid": "205360956", "userid": profile.id,
                "reqtype": "3", "g_tk": csrf
            ],
            listKey: "cdlist", pageSize: 80, inclusiveEnd: true,
            cookie: requestCookie
        )
        let (createdResult, collectedResult) = await (createdRows, collectedRows)
        guard createdResult != nil || collectedResult != nil else { throw APIError.unavailable }
        let created = createdResult ?? []
        let collected = collectedResult ?? []
        let createdPlaylists = created.map { Self.mapPlaylist($0, kind: .created) }
        let collectedPlaylists = collected.map { Self.mapPlaylist($0, kind: .collected) }

        var seen = Set<String>()
        let playlists = (createdPlaylists + collectedPlaylists)
            .filter {
                let text = "\($0.name) \($0.creatorName)".lowercased()
                return !$0.id.isEmpty && !$0.name.isEmpty
                    && !text.contains("qzone") && !text.contains("空间") && !text.contains("背景音乐")
                    && seen.insert($0.id).inserted
            }
            .sorted {
                if $0.isLikedSongs != $1.isLikedSongs { return $0.isLikedSongs }
                if $0.kind != $1.kind { return $0.kind == .created }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return PlaylistListResult(playlists: playlists, refreshedCookie: profile.refreshedCookie)
    }

    /// Loads one playlist with the signed-in cookie and pages its tracks. The
    /// login sync uses this to make a local copy, and the UI can retry it.
    func playlistTracks(id: String, cookie: String) async throws -> PlaylistTracksResult {
        let profile = try await profile(cookie: cookie)
        let requestCookie = profile.refreshedCookie ?? cookie
        let isLikedSongs = id == "qq-liked:201"
        let playlistID: Int64
        if isLikedSongs {
            playlistID = 0
        } else if id.range(of: #"^\d+$"#, options: .regularExpression) != nil,
                  let parsedID = Int64(id) {
            playlistID = parsedID
        } else {
            throw APIError.invalidResponse
        }

        let cookieValues = Self.cookieFields(requestCookie)
        let authKey = Self.playlistAuthKey(in: cookieValues) ?? ""
        guard !authKey.isEmpty else { throw APIError.unavailable }
        let csrfKey = Self.csrfKey(in: cookieValues) ?? authKey
        let csrf = Self.hash5381(csrfKey)
        var tracks: [Track] = []
        var offset = 0
        var expectedCount = 0
        var completed = false
        let pageSize = 100
        let maximumPages = 100

        for page in 0..<maximumPages {
            try Task.checkCancellation()
            let payload: [String: Any] = [
                "comm": [
                    "ct": 24, "cv": 4_747_474, "platform": "yqq.json",
                    "uin": profile.id, "g_tk": csrf,
                    "g_tk_new_20200303": csrf, "authst": authKey,
                    "format": "json", "inCharset": "utf-8",
                    "outCharset": "utf-8", "notice": 0, "need_new_code": 1
                ],
                "playlist": [
                    "module": "music.srfDissInfo.DissInfo",
                    "method": "CgiGetDiss",
                    "param": [
                        "disstid": playlistID,
                        "dirid": isLikedSongs ? 201 : 0,
                        "tag": true, "song_begin": offset, "song_num": pageSize,
                        "userinfo": true, "orderlist": true, "onlysonglist": false
                    ]
                ]
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.httpBody = body
            request.setValue(requestCookie, forHTTPHeaderField: "Cookie")
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard Self.isSuccess(response),
                  let root = Self.jsonObject(from: data),
                  let block = root["playlist"] as? [String: Any],
                  Self.integer(in: block, keys: ["code", "result"]) == 0,
                  let result = block["data"] as? [String: Any] else {
                throw APIError.unavailable
            }
            if let rawTotal = Self.integer(in: result, keys: ["total_song_num", "songlist_size", "totalNum"]) {
                expectedCount = max(expectedCount, rawTotal)
            }
            let rows = result["songlist"] as? [[String: Any]] ?? []
            let hasMoreKeys = ["hasmore", "hasMore", "has_more"]
            let reportedHasMore = Self.boolean(in: result, keys: hasMoreKeys)
                ?? Self.boolean(in: block, keys: hasMoreKeys)
            if rows.isEmpty {
                guard reportedHasMore != true, expectedCount <= offset else {
                    throw APIError.incompletePlaylist
                }
                completed = true
                break
            }
            let mapped = rows.compactMap { LXCatalogService.track(from: $0, source: .tx) }
                .map { $0.normalizedForLXPlayback() }
            guard mapped.count == rows.count else { throw APIError.incompletePlaylist }
            tracks.append(contentsOf: mapped)

            offset += rows.count

            if expectedCount > 0, offset >= expectedCount {
                completed = true
                break
            }
            if reportedHasMore == false {
                guard expectedCount == 0 || offset >= expectedCount else {
                    throw APIError.incompletePlaylist
                }
                completed = true
                break
            }
            // When the endpoint omits both total and hasmore, keep paging until
            // an empty page confirms the end. A full page is never assumed to
            // be the whole playlist.
            if page == maximumPages - 1 { throw APIError.tooManyTracks }
        }

        guard completed, expectedCount == 0 || offset >= expectedCount else {
            throw APIError.incompletePlaylist
        }
        return PlaylistTracksResult(tracks: tracks, refreshedCookie: profile.refreshedCookie)
    }

    /// The directory's advertised count is independent from the selected
    /// playlist response, so callers can supply it as a second completeness
    /// check when the track endpoint omits its own total metadata.
    func playlistTracks(id: String, cookie: String, expectedTrackCount: Int) async throws -> PlaylistTracksResult {
        let result = try await playlistTracks(id: id, cookie: cookie)
        if expectedTrackCount > 0, result.tracks.count < expectedTrackCount {
            throw APIError.incompletePlaylist
        }
        return result
    }

    private func fetchPlaylistPages(
        endpoint: String,
        query baseQuery: [String: String],
        listKey: String,
        pageSize: Int,
        inclusiveEnd: Bool,
        cookie: String
    ) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var offset = 0
        let maxPages = 20

        for page in 0..<maxPages {
            try Task.checkCancellation()
            var query = baseQuery
            query["sin"] = String(offset)
            if inclusiveEnd {
                query["ein"] = String(offset + pageSize - 1)
            } else {
                query["size"] = String(pageSize)
            }
            let url = try Self.url(endpoint, query: query)
            let root = try await getJSON(url, cookie: cookie)
            guard let pageRows = Self.playlistRows(root, listKey: listKey) else {
                throw APIError.invalidResponse
            }
            rows.append(contentsOf: pageRows)
            let data = root["data"] as? [String: Any] ?? root
            let totalKeys = [
                "total", "totalCount", "totalcount", "total_num", "totalNum", "count",
                "dissnum", "diss_num", "disscount", "diss_count", "cdnum", "cd_num",
                "cdcount", "cd_count", "sum", "playlist_count", "playlistCount"
            ]
            let total = Self.integer(in: data, keys: totalKeys)
                ?? Self.integer(in: root, keys: totalKeys)
            let hasMoreKeys = ["hasmore", "hasMore", "has_more", "more"]
            let explicitHasMore = Self.boolean(in: data, keys: hasMoreKeys)
                ?? Self.boolean(in: root, keys: hasMoreKeys)

            if pageRows.isEmpty {
                guard explicitHasMore != true, total.map({ rows.count >= $0 }) ?? true else {
                    throw APIError.invalidResponse
                }
                return rows
            }
            if let total, total > 0, rows.count >= total { return rows }
            if explicitHasMore == false {
                guard total.map({ $0 <= rows.count }) ?? true else { throw APIError.invalidResponse }
                return rows
            }

            // Some QQ endpoints cap the returned page below the requested
            // size and omit a total. Continue by the number actually returned;
            // the next empty page is the only reliable end marker in that case.
            offset += pageRows.count
            if page == maxPages - 1 { throw APIError.tooManyPlaylists }
        }
        return rows
    }

    private func getJSON(_ url: URL, cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://y.qq.com/portal/profile.html", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response), let root = Self.jsonObject(from: data) else {
            throw APIError.invalidResponse
        }
        if let code = Self.integer(in: root, keys: ["code", "subcode"]), code != 0 {
            throw APIError.unavailable
        }
        return root
    }

    private static func url(_ raw: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: raw) else { throw APIError.invalidResponse }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }

    private static func playlistRows(_ root: [String: Any], listKey: String) -> [[String: Any]]? {
        let data = root["data"] as? [String: Any] ?? root
        return data[listKey] as? [[String: Any]]
    }

    private static func mapPlaylist(_ raw: [String: Any], kind: Playlist.Kind) -> Playlist {
        let rawID = text(raw["dissid"]) ?? text(raw["tid"]) ?? text(raw["dirid"])
            ?? text(raw["id"]) ?? text(raw["diss_id"]) ?? ""
        let isLiked = text(raw["dirid"]) == "201" || text(raw["dirId"]) == "201"
        let id = isLiked ? "qq-liked:201" : rawID
        let image = text(raw["diss_cover"]) ?? text(raw["logo"])
            ?? text(raw["picurl"]) ?? text(raw["cover"])
        let coverURL: String? = {
            guard let image, !image.isEmpty else { return nil }
            return image.hasPrefix("//") ? "https:\(image)" : image.replacingOccurrences(of: "http://", with: "https://")
        }()
        return Playlist(
            id: id,
            name: isLiked ? "我喜欢的音乐" : (text(raw["diss_name"]) ?? text(raw["name"]) ?? text(raw["title"]) ?? "QQ 音乐歌单"),
            coverURL: coverURL,
            trackCount: integer(in: raw, keys: ["song_cnt", "songnum", "total_song_num", "song_count"]) ?? 0,
            creatorName: text(raw["hostname"]) ?? text(raw["nick"]) ?? text(raw["creator"]) ?? "QQ 音乐",
            kind: kind
        )
    }

    private static func jsonObject(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return try? JSONSerialization.jsonObject(
            with: Data(text[start...end].utf8)
        ) as? [String: Any]
    }

    private static func text(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func integer(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }

    private static func boolean(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let value = value as? Bool { return value }
            if let value = value as? NSNumber { return value.intValue != 0 }
            if let value = value as? String {
                switch value.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: continue
                }
            }
        }
        return nil
    }

    private static func isSuccess(_ response: URLResponse) -> Bool {
        (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
    }

    private static func cookieValue(_ name: String, from response: URLResponse) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        for (key, value) in http.allHeaderFields {
            guard String(describing: key).lowercased() == "set-cookie" else { continue }
            let text = String(describing: value)
            for item in text.split(separator: ",") {
                let pair = item.split(separator: ";", maxSplits: 1).first ?? ""
                let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == name {
                    return fields[1]
                }
            }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func parsePTUI(_ body: String) -> (code: String, url: URL?)? {
        let fields = callbackFields(body)
        guard fields.count >= 3, let code = fields.first else { return nil }
        let candidate = fields.dropFirst().first(where: { $0.hasPrefix("http") })
        return (code, candidate.flatMap(URL.init(string:)))
    }

    private static func extractCode(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        return bytes.count >= 12 && Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46]
            && Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50]
    }

    private static func callbackFields(_ body: String) -> [String] {
        guard let start = body.firstIndex(of: "("),
              let end = body.lastIndex(of: ")"), start < end else { return [] }
        let payload = body[body.index(after: start)..<end]
        return payload.split(separator: ",", omittingEmptySubsequences: false).map { value in
            var item = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if item.hasPrefix("'") && item.hasSuffix("'") && item.count >= 2 {
                item.removeFirst()
                item.removeLast()
            }
            return item.replacingOccurrences(of: "\\'", with: "'")
        }
    }

    private static func hash33(_ value: String) -> Int {
        var result: Double = 0
        for unit in value.utf16 {
            result += Double(toInt32Shift(result)) + Double(unit)
        }
        return Int(toInt32(result) & 0x7FFF_FFFF)
    }

    private static func hash5381(_ value: String) -> Int {
        var result: Double = 5381
        for unit in value.utf16 {
            result += Double(toInt32Shift(result)) + Double(unit)
        }
        return Int(toInt32(result) & 0x7FFF_FFFF)
    }

    private static func toInt32Shift(_ value: Double) -> Int32 {
        Int32(bitPattern: toUInt32(value) &* 32)
    }

    private static func toInt32(_ value: Double) -> Int32 {
        Int32(bitPattern: toUInt32(value))
    }

    private static func toUInt32(_ value: Double) -> UInt32 {
        var remainder = value.truncatingRemainder(dividingBy: 4_294_967_296)
        if remainder < 0 { remainder += 4_294_967_296 }
        return UInt32(remainder)
    }

    private func collectCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url else { return }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            cookieStorage.setCookie(cookie)
        }
    }

    private func cookieValue(_ name: String) -> String? {
        cookieStorage.cookies?.first(where: { $0.name == name })?.value
    }

    private func setCookieValue(_ value: String, for name: String) {
        guard let cookie = HTTPCookie(properties: [
            .domain: ".qq.com",
            .path: "/",
            .name: name,
            .value: value
        ]) else { return }
        cookieStorage.setCookie(cookie)
    }

    private func cookieHeader(includeQRSig: Bool = false) -> String {
        let allowed = Set([
            "uin", "skey", "p_uin", "p_skey", "pt4_token", "qqmusic_uin",
            "qqmusic_key", "qm_keyst", "music_key", "musickey", "musicid",
            "loginUin", "pskey", "wxskey", "wx_skey"
        ])
        var pairs = cookieStorage.cookies?.filter {
            allowed.contains($0.name)
        }.map { "\($0.name)=\($0.value)" } ?? []
        if includeQRSig, let qrsig = cookieValue("qrsig"), !qrsig.isEmpty {
            pairs.insert("qrsig=\(qrsig)", at: 0)
        }
        return pairs
            .sorted()
            .joined(separator: "; ")
    }

    private static func mergedCookie(original: String, response: HTTPURLResponse?) -> String? {
        guard let response,
              let header = response.allHeaderFields.first(where: {
                  String(describing: $0.key).lowercased() == "set-cookie"
              })?.value else { return nil }
        var values = cookieFields(original)
        let text = String(describing: header)
        for part in text.split(separator: ",") {
            let pair = part.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if fields.count == 2 { values[fields[0].trimmingCharacters(in: .whitespaces)] = fields[1] }
        }
        return values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private static func cookieFields(_ cookie: String) -> [String: String] {
        cookie.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces)] = pair[1]
        }
    }

    private static func playlistAuthKey(in cookies: [String: String]) -> String? {
        let accepted = [
            "qm_keyst", "qqmusic_key", "music_key", "musickey",
            "p_skey", "pskey", "skey", "wx_skey", "wxskey"
        ]
        for key in accepted {
            if let value = cookies.first(where: { $0.key.lowercased() == key })?.value,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// QQ's `g_tk` is derived from its web-session skey. `authst` uses a
    /// separate music ticket when present, so keep the two credentials distinct.
    private static func csrfKey(in cookies: [String: String]) -> String? {
        let accepted = ["p_skey", "pskey", "skey", "wx_skey", "wxskey"]
        for key in accepted {
            if let value = cookieValue(key, in: cookies), !value.isEmpty { return value }
        }
        return playlistAuthKey(in: cookies)
    }

    private static func cookieValue(_ name: String, in cookies: [String: String]) -> String? {
        cookies.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private static func normalizedQQIdentifier(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("o") { value.removeFirst() }
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }),
              let number = UInt64(value), number > 0 else { return nil }
        return String(number)
    }

    private static func cookieNickname(in cookies: [String: String]) -> String? {
        guard let raw = cookies.first(where: { $0.key.lowercased().hasPrefix("ptnick_") })?.value,
              !raw.isEmpty else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        let name = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return name.isEmpty ? nil : name
    }

    private static func filename(for quality: String, mediaMid: String) -> String {
        switch quality.lowercased() {
        case "master", "atmos", "dolby", "surround", "hires", "flac", "lossless":
            return "F000\(mediaMid).flac"
        case "exhigh", "higher", "320k", "320":
            return "M800\(mediaMid).mp3"
        default:
            return "M500\(mediaMid).mp3"
        }
    }

    private static func quality(forFilename filename: String) -> String {
        let value = filename.uppercased()
        if value.hasPrefix("F000") { return "flac" }
        if value.hasPrefix("M800") { return "320k" }
        if value.hasPrefix("C600") { return "192k" }
        return "128k"
    }
}
