import Foundation

/// Response parser for QQ Music's legacy desktop playlist detail endpoint.
/// LX Music Mobile uses this read-only endpoint before its `uniform_get_Dissinfo`
/// fallback; its response may be JSON or JSONP depending on the edge node.
enum QQMusicLegacyPlaylistResponse {
    struct Page {
        let rows: [[String: Any]]
        let totalCount: Int
        let hasMore: Bool
    }

    enum ResponseError: Swift.Error, LocalizedError {
        case invalidResponse
        case providerRejected(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "QQ 旧版歌单接口返回了无法识别的信息"
            case .providerRejected(let detail): return detail
            }
        }
    }

    static func endpointURL(playlistID: Int64) -> URL? {
        guard playlistID > 0,
              var components = URLComponents(string: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "onlysong", value: "0"),
            URLQueryItem(name: "new_format", value: "1"),
            URLQueryItem(name: "disstid", value: String(playlistID)),
            URLQueryItem(name: "loginUin", value: "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
        ]
        return components.url
    }

    static func decode(_ data: Data, offset: Int, pageSize: Int) throws -> Page {
        guard let responseText = String(data: data, encoding: .utf8),
              let start = responseText.firstIndex(of: "{"),
              let end = responseText.lastIndex(of: "}"), start <= end,
              let root = try? JSONSerialization.jsonObject(
                with: Data(responseText[start...end].utf8)
              ) as? [String: Any] else {
            throw ResponseError.invalidResponse
        }

        for key in ["code", "subcode"] {
            if let code = text(root[key]), code != "0" {
                throw ResponseError.providerRejected("QQ 音乐歌单详情接口返回响应码 \(code)")
            }
        }
        guard let lists = root["cdlist"] as? [[String: Any]],
              let playlist = lists.first,
              let allRows = playlist["songlist"] as? [[String: Any]] else {
            throw ResponseError.providerRejected("QQ 音乐旧版歌单接口没有返回歌单曲目")
        }

        let requestedOffset = max(offset, 0)
        let requestedSize = max(pageSize, 1)
        let startIndex = min(requestedOffset, allRows.count)
        let endIndex = startIndex + min(requestedSize, allRows.count - startIndex)
        let rows = Array(allRows[startIndex..<endIndex])
        let reportedCount = ["songnum", "total_song_num", "song_count", "song_count_total"]
            .compactMap { integer(playlist[$0]) }
            .first
        let totalCount = max(reportedCount ?? allRows.count, allRows.count)
        let hasMore = requestedOffset + rows.count < totalCount
            || (reportedCount == nil && rows.count == requestedSize && endIndex == allRows.count)
        return Page(rows: rows, totalCount: totalCount, hasMore: hasMore)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Generic QQ cookies (`p_skey`/`skey`) identify a QQ account but do not
/// prove QQ Music's playlist-detail endpoint can read its tracks. Keep the
/// login gate in one pure policy shared by login UI, session restore, and API.
enum QQMusicLoginCookiePolicy {
    private static let userCookieNames = [
        "uin", "qqmusic_uin", "p_uin", "musicid", "loginuin", "wxuin"
    ]
    private static let musicTicketNames = [
        "qm_keyst", "qqmusic_key", "music_key", "musickey"
    ]

    static func hasUsableMusicLoginCookie(_ cookie: String) -> Bool {
        let values = cookie.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { return }
            result[name] = value
        }

        let hasNumericUser = userCookieNames.contains { name in
            guard var value = values[name] else { return false }
            if value.lowercased().hasPrefix("o") { value.removeFirst() }
            guard value.allSatisfy(\.isNumber), let number = UInt64(value) else { return false }
            return number > 0
        }
        let hasMusicTicket = musicTicketNames.contains { !(values[$0] ?? "").isEmpty }
        return hasNumericUser && hasMusicTicket
    }
}

/// Auth envelope used by QQ Music's account-bound read endpoints. Anonymous
/// web calls use `ct: 24`/`cv: 4747474`; once a Music ticket is attached, QQ's
/// account route expects the ticket-bearing client envelope instead.
enum QQMusicAccountRequestEnvelope {
    static func common(userID: String, musicTicket: String) -> [String: Any] {
        [
            "uin": userID,
            "format": "json",
            "ct": 19,
            "cv": 0,
            "authst": musicTicket,
        ]
    }
}

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
        let warningMessage: String?
    }

    struct PlaylistTracksResult: Sendable {
        let tracks: [Track]
        let refreshedCookie: String?
    }

    private struct PlaylistTrackPage {
        let rows: [[String: Any]]
        let totalCount: Int?
        let hasMore: Bool?
    }

    struct ResolvedAudio: Sendable {
        let url: URL
        let quality: String
    }

    enum APIError: LocalizedError {
        case invalidResponse
        case loginCookieUnavailable
        case unavailable
        case providerRejected(String)
        case sessionCredentialRejected(String, ticketMissing: Bool)
        case playlistListUnavailable(String?)
        case qrCodeUnavailable
        case oauthFailed
        case tooManyPlaylists
        case tooManyTracks
        case incompletePlaylist

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "QQ 音乐返回了无法识别的信息，请重新登录后重试"
            case .loginCookieUnavailable:
                return "QQ 网页登录状态缺少读取歌单曲目所需的 QQ 音乐凭据。请在电脑端 QQ 音乐网页完成登录和授权后，再回到 iMusic 点“登录完成”"
            case .unavailable: return "QQ 音乐登录已失效或 Cookie 已过期"
            case .providerRejected(let detail):
                return "QQ 音乐接口拒绝了请求（\(detail)），请稍后刷新歌单"
            case .sessionCredentialRejected(let detail, ticketMissing: true):
                return "QQ 音乐曲目接口拒绝了请求（\(detail)）。当前网页登录 Cookie 未包含 QQ 音乐曲目凭据 qm_keyst/qqmusic_key；请在电脑端 QQ 音乐网页重新登录后，再回到 iMusic 点“登录完成”"
            case .sessionCredentialRejected(let detail, ticketMissing: false):
                return "QQ 音乐拒绝了曲目请求（\(detail)）。已停止重复请求剩余歌单；请检查网页登录状态或重新登录后重试"
            case .playlistListUnavailable(let detail):
                if let detail, !detail.isEmpty {
                    return "QQ 音乐暂时无法读取歌单（\(detail)），请重新登录后刷新"
                }
                return "QQ 音乐暂时没有返回可识别的歌单列表，请重新登录后刷新"
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
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

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
        let uin = Self.qqUserIdentifier(in: fields) ?? "0"
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
        let cookieID = Self.qqUserIdentifier(in: cookieValues)

        // QQ's profile CGI is frequently blocked or returns an HTML anti-bot
        // page to embedded clients even while the desktop web session is
        // valid. However, generic QQ `skey` cookies are insufficient for
        // QQ Music track details. Require the Music ticket before returning a
        // profile or allowing the session to be cached as logged in.
        guard cookieID != nil, QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(cookie) else {
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
            URLQueryItem(name: "cid", value: "205360838"),
            URLQueryItem(name: "userid", value: cookieID ?? "0"),
            URLQueryItem(name: "reqfrom", value: "1"),
            URLQueryItem(name: "g_tk", value: String(Self.hash5381(Self.csrfKey(in: cookieValues) ?? ""))),
            URLQueryItem(name: "loginUin", value: cookieID ?? "0"),
            URLQueryItem(name: "hostUin", value: "0"),
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
            let name = "QQ 音乐用户"
            let avatar = Self.text(in: info, keys: ["logo", "avatar", "avatarUrl", "avatar_url"])
            let refreshedCookie = Self.mergedCookie(
                original: cookie,
                response: response as? HTTPURLResponse
            ).flatMap { candidate in
                QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(candidate) ? candidate : nil
            }
            return Profile(id: id, name: name, avatarURL: avatar,
                           refreshedCookie: refreshedCookie)
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
        guard QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(requestCookie) else {
            throw APIError.loginCookieUnavailable
        }
        let cookieValues = Self.cookieFields(requestCookie)
        let authKey = Self.playlistAuthKey(in: cookieValues) ?? ""
        guard !authKey.isEmpty else { throw APIError.unavailable }
        let csrfKey = Self.csrfKey(in: cookieValues) ?? authKey
        let csrf = String(Self.hash5381(csrfKey))
        let createdURL = "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss"
        let collectedURL = "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg"

        async let createdOutcome = fetchPlaylistPagesOutcome(
            endpoint: createdURL,
            query: [
                "hostuin": profile.id, "g_tk": csrf,
                "loginUin": profile.id, "format": "json", "inCharset": "utf8",
                "outCharset": "utf-8", "notice": "0", "platform": "yqq.json",
                "needNewCode": "0"
            ],
            listKey: "disslist", pageSize: 200, inclusiveEnd: false,
            cookie: requestCookie
        )
        async let collectedOutcome = fetchPlaylistPagesOutcome(
            endpoint: collectedURL,
            query: [
                "ct": "20", "cid": "205360956", "userid": profile.id,
                "reqtype": "3", "g_tk": csrf
            ],
            listKey: "cdlist", pageSize: 80, inclusiveEnd: true,
            cookie: requestCookie
        )
        let (createdResult, collectedResult) = try await (createdOutcome, collectedOutcome)
        guard createdResult.rows != nil || collectedResult.rows != nil else {
            let details = [createdResult.error, collectedResult.error]
                .compactMap { $0 }
                .joined(separator: "；")
            throw APIError.playlistListUnavailable(details.isEmpty ? nil : details)
        }
        let created = createdResult.rows ?? []
        let collected = collectedResult.rows ?? []
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
        let warnings = [
            createdResult.error.map { "创建的歌单：\($0)" },
            collectedResult.error.map { "收藏的歌单：\($0)" },
        ].compactMap { $0 }
        return PlaylistListResult(
            playlists: playlists,
            refreshedCookie: profile.refreshedCookie,
            warningMessage: warnings.isEmpty ? nil : warnings.joined(separator: "；")
        )
    }

    private struct PlaylistFetchOutcome: @unchecked Sendable {
        let rows: [[String: Any]]?
        let error: String?
    }

    private func fetchPlaylistPagesOutcome(
        endpoint: String,
        query: [String: String],
        listKey: String,
        pageSize: Int,
        inclusiveEnd: Bool,
        cookie: String
    ) async throws -> PlaylistFetchOutcome {
        do {
            let rows = try await fetchPlaylistPages(
                endpoint: endpoint,
                query: query,
                listKey: listKey,
                pageSize: pageSize,
                inclusiveEnd: inclusiveEnd,
                cookie: cookie
            )
            return PlaylistFetchOutcome(rows: rows, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            return PlaylistFetchOutcome(rows: nil, error: Self.safeRouteFailure(error))
        }
    }

    /// Loads one playlist with the signed-in cookie and pages its tracks. The
    /// login sync uses this to make a local copy, and the UI can retry it.
    func playlistTracks(id: String, cookie: String) async throws -> PlaylistTracksResult {
        try await playlistTracks(id: id, cookie: cookie, expectedTrackCount: 0)
    }

    /// The account directory's song count is passed into pagination so an
    /// apparently successful but truncated QQ response can fall back before
    /// the incomplete copy is rejected.
    func playlistTracks(
        id: String,
        cookie: String,
        expectedTrackCount: Int
    ) async throws -> PlaylistTracksResult {
        let profile = try await profile(cookie: cookie)
        let requestCookie = profile.refreshedCookie ?? cookie
        guard QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(requestCookie) else {
            throw APIError.loginCookieUnavailable
        }
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
        guard let musicTicket = Self.musicAuthTicket(in: cookieValues) else {
            throw APIError.loginCookieUnavailable
        }
        var tracks: [Track] = []
        var offset = 0
        var expectedCount = max(expectedTrackCount, 0)
        var completed = false
        let pageSize = 100
        let maximumPages = 100

        for page in 0..<maximumPages {
            try Task.checkCancellation()
            let trackPage = try await fetchPlaylistTrackPage(
                playlistID: playlistID,
                isLikedSongs: isLikedSongs,
                profileID: profile.id,
                musicTicket: musicTicket,
                offset: offset,
                pageSize: pageSize,
                expectedPlaylistCount: expectedCount > 0 ? expectedCount : nil,
                cookie: requestCookie,
                cookieValues: cookieValues
            )
            if let totalCount = trackPage.totalCount {
                expectedCount = max(expectedCount, totalCount)
            }
            let rows = trackPage.rows
            let reportedHasMore = trackPage.hasMore
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

    /// Reads a QQ account playlist, preferring the authenticated paginated
    /// route. Public LX-compatible endpoints remain fallbacks; the legacy
    /// desktop endpoint returns the full list and is requested once at offset
    /// zero only when the paginated routes do not return a complete page.
    private func fetchPlaylistTrackPage(
        playlistID: Int64,
        isLikedSongs: Bool,
        profileID: String,
        musicTicket: String,
        offset: Int,
        pageSize: Int,
        expectedPlaylistCount: Int?,
        cookie: String,
        cookieValues: [String: String]
    ) async throws -> PlaylistTrackPage {
        // `CgiGetDiss` is the account-bound route. Send QQ's ticket-bearing
        // client envelope with the signed-in UIN and cookie; do not reuse the
        // public web envelope from `uniform_get_Dissinfo`.
        let primaryComm = QQMusicAccountRequestEnvelope.common(
            userID: profileID,
            musicTicket: musicTicket
        )
        let commonParam: [String: Any] = [
            "disstid": playlistID,
            "tag": true,
            "song_begin": offset,
            "song_num": pageSize,
            "userinfo": true,
            "orderlist": true
        ]
        var primaryParam = commonParam
        primaryParam["dirid"] = isLikedSongs ? 201 : 0
        primaryParam["onlysonglist"] = false
        let primaryPayload: [String: Any] = [
            "comm": primaryComm,
            "playlist": [
                "module": "music.srfDissInfo.DissInfo",
                "method": "CgiGetDiss",
                "param": primaryParam
            ]
        ]

        // Match LX Music Mobile's public, anonymous uniform_get_Dissinfo
        // request shape. This is a fallback for public playlists; account
        // credentials are attached only to the authenticated CgiGetDiss route.
        let fallbackComm: [String: Any] = [
            "ct": 24, "cv": 4_747_474, "platform": "yqq.json",
            "uin": 0, "format": "json", "inCharset": "utf-8",
            "outCharset": "utf-8", "needNewCode": 1
        ]
        let fallbackParam: [String: Any] = [
            "disstid": playlistID,
            "tag": 1,
            "song_begin": offset,
            "song_num": pageSize,
            "userinfo": 1,
            "orderlist": 1,
            "onlysonglist": 0,
            "enc_host_uin": ""
        ]
        let fallbackPayload: [String: Any] = [
            "comm": fallbackComm,
            "req_1": [
                "module": "music.srfDissInfo.aiDissInfo",
                "method": "uniform_get_Dissinfo",
                "param": fallbackParam
            ]
        ]

        var sessionError: APIError?
        var routeErrors: [String] = []
        var bestIncompletePage: PlaylistTrackPage?

        // Read the signed-in account first so private playlists are not
        // needlessly requested through anonymous endpoints. Public routes
        // remain fallbacks for provider responses that omit account tracks.
        for (responseKey, payload) in [("playlist", primaryPayload), ("req_1", fallbackPayload)] {
            do {
                try Task.checkCancellation()
                let body = try JSONSerialization.data(withJSONObject: payload)
                var request = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 20
                request.httpBody = body
                request.httpShouldHandleCookies = false
                if responseKey == "playlist" {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.setValue("https://y.qq.com/n/yqq/playsquare/\(playlistID).html", forHTTPHeaderField: "Referer")
                request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.data(for: request)
                guard Self.isSuccess(response),
                      let root = Self.jsonObject(from: data) else {
                    throw Self.playlistTracksRejection(
                        from: data,
                        response: response,
                        cookieValues: cookieValues
                    )
                }
                if let rootCode = Self.text(root["code"]), rootCode != "0" {
                    throw APIError.providerRejected(Self.responseDiagnostic(from: root))
                }
                guard let block = root[responseKey] as? [String: Any],
                      Self.integer(in: block, keys: ["code", "result"]) == 0,
                      let result = block["data"] as? [String: Any],
                      let rows = result["songlist"] as? [[String: Any]] else {
                    throw Self.playlistTracksRejection(
                        from: data,
                        response: response,
                        cookieValues: cookieValues
                    )
                }
                let hasMoreKeys = ["hasmore", "hasMore", "has_more"]
                let page = PlaylistTrackPage(
                    rows: rows,
                    totalCount: Self.integer(in: result, keys: ["total_song_num", "songlist_size", "totalNum"]),
                    hasMore: Self.boolean(in: result, keys: hasMoreKeys)
                        ?? Self.boolean(in: block, keys: hasMoreKeys)
                )
                let knownCount = max(expectedPlaylistCount ?? 0, page.totalCount ?? 0)
                let requiredRows = knownCount > offset
                    ? min(pageSize, knownCount - offset)
                    : nil
                let expectedEnd = offset + page.rows.count
                let needsFallback = page.rows.isEmpty
                    || (requiredRows.map { page.rows.count < $0 } ?? false)
                    || (page.hasMore == true && page.rows.count < pageSize)
                    || (page.hasMore == false && knownCount > expectedEnd)
                guard needsFallback else { return page }
                if bestIncompletePage == nil || page.rows.count > bestIncompletePage!.rows.count {
                    bestIncompletePage = page
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as APIError {
                let routeName = responseKey == "playlist" ? "CgiGetDiss" : "uniform_get_Dissinfo"
                routeErrors.append("\(routeName)：\(Self.safeRouteFailure(error))")
                if responseKey == "playlist",
                   let apiError = error as? APIError,
                   case let .sessionCredentialRejected(_, ticketMissing) = apiError {
                    sessionError = sessionError ?? APIError.sessionCredentialRejected(
                        "QQ 音乐会话凭据未通过验证",
                        ticketMissing: ticketMissing
                    )
                }
            } catch {
                let routeName = responseKey == "playlist" ? "CgiGetDiss" : "uniform_get_Dissinfo"
                routeErrors.append("\(routeName)：\(Self.safeRouteFailure(error))")
            }
        }

        // Match LX Music Mobile's legacy GET fallback for public playlists.
        // It has no server-side pagination, so consume up to the app's 10k
        // track safety limit in this single request and never call it again.
        if !isLikedSongs, offset == 0,
           let url = QQMusicLegacyPlaylistResponse.endpointURL(playlistID: playlistID) {
            do {
                try Task.checkCancellation()
                let legacyPage = try await fetchLegacyPlaylistTrackPage(
                    url: url,
                    playlistID: playlistID,
                    pageSize: 10_000,
                    cookieValues: cookieValues
                )
                let knownCount = max(expectedPlaylistCount ?? 0, legacyPage.totalCount ?? 0)
                let requiredRows = knownCount > offset
                    ? min(10_000, knownCount - offset)
                    : nil
                let expectedEnd = offset + legacyPage.rows.count
                let contradictsExpectedCount = legacyPage.hasMore == false && knownCount > expectedEnd
                let isAdequate = (requiredRows.map { legacyPage.rows.count >= $0 } ?? true)
                    && !contradictsExpectedCount
                if isAdequate, (!legacyPage.rows.isEmpty || knownCount == 0) {
                    return legacyPage
                }
                if bestIncompletePage == nil || legacyPage.rows.count > bestIncompletePage!.rows.count {
                    bestIncompletePage = legacyPage
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                routeErrors.append("旧版 GET：\(Self.safeRouteFailure(error))")
            }
        }

        if let sessionError { throw sessionError }
        if let bestIncompletePage, !bestIncompletePage.rows.isEmpty {
            let knownCount = max(expectedPlaylistCount ?? 0, bestIncompletePage.totalCount ?? 0)
            let expectedEnd = offset + bestIncompletePage.rows.count
            let contradictsExpectedCount = bestIncompletePage.hasMore == false
                && knownCount > expectedEnd
            if contradictsExpectedCount, !routeErrors.isEmpty {
                throw APIError.providerRejected(routeErrors.joined(separator: "；"))
            }
            return bestIncompletePage
        }
        if !routeErrors.isEmpty {
            throw APIError.providerRejected(routeErrors.joined(separator: "；"))
        }
        if let bestIncompletePage { return bestIncompletePage }
        throw APIError.invalidResponse
    }

    private func fetchLegacyPlaylistTrackPage(
        url: URL,
        playlistID: Int64,
        pageSize: Int,
        cookieValues: [String: String]
    ) async throws -> PlaylistTrackPage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpShouldHandleCookies = false
        request.setValue("https://y.qq.com/n/yqq/playsquare/\(playlistID).html", forHTTPHeaderField: "Referer")
        request.setValue("https://y.qq.com", forHTTPHeaderField: "Origin")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard Self.isSuccess(response) else {
            throw Self.playlistTracksRejection(from: data, response: response, cookieValues: cookieValues)
        }

        do {
            let page = try QQMusicLegacyPlaylistResponse.decode(data, offset: 0, pageSize: pageSize)
            return PlaylistTrackPage(
                rows: page.rows,
                totalCount: page.totalCount,
                hasMore: page.hasMore
            )
        } catch let error as QQMusicLegacyPlaylistResponse.ResponseError {
            switch error {
            case .invalidResponse:
                throw APIError.invalidResponse
            case .providerRejected(let detail):
                throw APIError.providerRejected(detail)
            }
        }
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
            if let diagnostic = Self.providerError(in: root) {
                throw APIError.providerRejected(diagnostic)
            }
            guard let pageRows = Self.playlistRows(root, listKey: listKey) else {
                throw APIError.invalidResponse
            }
            rows.append(contentsOf: pageRows)
            let data = Self.playlistData(root)
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
        if let diagnostic = Self.providerError(in: root) {
            throw APIError.providerRejected(diagnostic)
        }
        return root
    }

    private static func responseDiagnostic(from data: Data) -> String {
        guard let root = jsonObject(from: data) else { return "无法识别的响应" }
        return responseDiagnostic(from: root)
    }

    private static func playlistTracksRejection(
        from data: Data,
        response: URLResponse,
        cookieValues: [String: String]
    ) -> APIError {
        let diagnostic = responseDiagnostic(from: data)
        let status = (response as? HTTPURLResponse)?.statusCode
        let lowerDiagnostic = diagnostic.lowercased()
        let explicitTicketFailure = [
            "authst", "ticket missing", "missing ticket",
            "缺少票据", "缺少曲目凭据", "音乐票据无效"
        ].contains { lowerDiagnostic.contains($0) }
        let explicitSessionFailure = explicitTicketFailure || [
            "unauthorized", "authentication failed", "invalid token",
            "token expired", "cookie expired", "登录失效", "未登录", "认证失败"
        ].contains { lowerDiagnostic.contains($0) }
        if explicitSessionFailure {
            let ticketMissing = musicAuthTicket(in: cookieValues) == nil && explicitTicketFailure
            return .sessionCredentialRejected(diagnostic, ticketMissing: ticketMissing)
        }
        if status == 401 || status == 403 {
            return .sessionCredentialRejected(diagnostic, ticketMissing: false)
        }
        return .providerRejected(diagnostic)
    }

    private static func responseDiagnostic(from root: [String: Any]) -> String {
        var detailObjects = [root]
        if let playlist = root["playlist"] as? [String: Any] {
            detailObjects.append(playlist)
            if let result = playlist["data"] as? [String: Any] {
                detailObjects.append(result)
            }
        }
        for key in ["req_1", "req_0"] {
            if let request = root[key] as? [String: Any] {
                detailObjects.append(request)
                if let result = request["data"] as? [String: Any] {
                    detailObjects.append(result)
                }
            }
        }
        if let data = root["data"] as? [String: Any] {
            detailObjects.append(data)
            if let nestedData = data["data"] as? [String: Any] {
                detailObjects.append(nestedData)
            }
        }
        for object in detailObjects {
            let code = text(in: object, keys: ["code", "subcode", "ret", "errCode"])
            let message = text(in: object, keys: ["message", "msg", "errMsg", "errmsg"])
            if let code, code != "0" {
                return message.map { "响应码 \(code)：\($0)" } ?? "响应码 \(code)"
            }
            if let message, !message.isEmpty { return message }
        }
        return "接口没有返回歌单数据"
    }

    /// Provider error messages are untrusted and can echo request/session
    /// values. Keep user-visible route diagnostics to a local failure class
    /// and a small allowlisted response code; never surface raw server text.
    private static func safeRouteFailure(_ error: Error) -> String {
        if let apiError = error as? APIError {
            switch apiError {
            case .providerRejected(let detail), .sessionCredentialRejected(let detail, _):
                if let code = safeQQResponseCode(in: detail) { return "响应码 \(code)" }
                return "服务端拒绝"
            case .invalidResponse:
                return "响应格式无法识别"
            case .loginCookieUnavailable:
                return "缺少 QQ 音乐曲目凭据"
            case .unavailable:
                return "服务暂不可用"
            default:
                return "请求未成功"
            }
        }
        if let urlError = error as? URLError {
            return "网络错误 \(urlError.code.rawValue)"
        }
        return "本地请求失败"
    }

    private static func safeQQResponseCode(in detail: String) -> String? {
        let lowered = detail.lowercased()
        if lowered.range(of: #"(?<![a-z0-9])3a44(?![a-z0-9])"#, options: .regularExpression) != nil {
            return "3a44"
        }
        guard let regex = try? NSRegularExpression(pattern: #"响应码\s*([0-9]{1,4})(?![0-9])"#),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              let range = Range(match.range(at: 1), in: detail) else { return nil }
        return String(detail[range])
    }

    private static func providerError(in root: [String: Any]) -> String? {
        var objects = [root]
        if let data = root["data"] as? [String: Any] {
            objects.append(data)
            if let nested = data["data"] as? [String: Any] { objects.append(nested) }
        }
        for object in objects {
            guard let code = text(in: object, keys: ["code", "subcode", "ret", "errCode"]),
                  code != "0" else { continue }
            return responseDiagnostic(from: root)
        }
        return nil
    }

    private static func url(_ raw: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: raw) else { throw APIError.invalidResponse }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw APIError.invalidResponse }
        return url
    }

    private static func playlistRows(_ root: [String: Any], listKey: String) -> [[String: Any]]? {
        let data = playlistData(root)
        return data[listKey] as? [[String: Any]]
    }

    private static func playlistData(_ root: [String: Any]) -> [String: Any] {
        guard let data = root["data"] as? [String: Any] else { return root }
        return data["data"] as? [String: Any] ?? data
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
            "loginUin", "login_type", "wxuin", "wx_skey", "wxskey", "wxrefresh_token",
            "pskey", "psrf_qqaccess_token", "psrf_qqrefresh_token"
        ].map { $0.lowercased() })
        var pairs = cookieStorage.cookies?.filter {
            allowed.contains($0.name.lowercased())
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

    private static func musicAuthTicket(in cookies: [String: String]) -> String? {
        let accepted = ["qm_keyst", "qqmusic_key", "music_key", "musickey"]
        for key in accepted {
            if let value = cookieValue(key, in: cookies), !value.isEmpty { return value }
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

    /// WeChat-backed QQ Music sessions identify the user with `wxuin`; using
    /// a stale `uin` from the same cookie header can make playlist reads target
    /// the wrong profile while the login UI still appears successful.
    private static func qqUserIdentifier(in cookies: [String: String]) -> String? {
        let loginType = cookieValue("login_type", in: cookies)
        let isWechatLogin = loginType == "2"
            || (cookieValue("wx_skey", in: cookies) != nil
                || cookieValue("wxskey", in: cookies) != nil)
                && cookieValue("p_skey", in: cookies) == nil
                && cookieValue("skey", in: cookies) == nil
        let names = isWechatLogin
            ? ["wxuin", "uin", "p_uin", "qqmusic_uin", "musicid", "loginUin"]
            : ["uin", "qqmusic_uin", "musicid", "loginUin", "p_uin", "wxuin"]
        return names
            .compactMap { cookieValue($0, in: cookies).flatMap(normalizedQQIdentifier) }
            .first
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
