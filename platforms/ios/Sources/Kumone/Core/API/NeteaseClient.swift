import Foundation
import os.log

enum NeteaseAPIError: LocalizedError {
    case http(Int)
    case business(code: Int, message: String?)
    case needLogin
    case missingProfile
    case decoding(String)
    case incompletePlaylist(expected: Int, received: Int)
    case incompleteSongData(expected: Int, received: Int)

    var errorDescription: String? {
        switch self {
        case .http(let status): return String(localized: "网络错误 (\(status))")
        case .business(let code, let message): return message ?? String(localized: "接口错误 (\(code))")
        case .needLogin: return String(localized: "需要登录")
        case .missingProfile: return String(localized: "网易云未返回账户资料，请重新登录后重试")
        case .decoding: return String(localized: "数据加载失败，请稍后重试")
        case .incompletePlaylist(let expected, let received):
            return String(localized: "歌单歌曲未完整加载（\(received)/\(expected)），请检查网络后重试")
        case .incompleteSongData(let expected, let received):
            return String(localized: "歌曲资料未完整加载（\(received)/\(expected)），请检查网络后重试")
        }
    }
}

/// Transport layer for NetEase Cloud Music. Owns the cookie jar and performs
/// weapi / eapi encrypted requests.
final class NeteaseClient: @unchecked Sendable {
    static let shared = NeteaseClient()

    private static let log = Logger(subsystem: "im.missuo.kumone", category: "api")
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    private static let cookieKeychainService = "com.moumusic.netease.session"
    private static let legacySessionInvalidatedKey = "com.moumusic.netease.legacy-session-invalidated.v1"

    private let session: URLSession
    private let cookieLock = NSLock()
    private var cookies: [String: String] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let legacyCookieFile = support.appendingPathComponent("cookies.json")
        if let storedCookie = ProviderSessionSupport.readCookie(service: Self.cookieKeychainService) {
            cookies = Self.parseCookieString(storedCookie)
            Self.markLegacySessionInvalidated()
            try? FileManager.default.removeItem(at: legacyCookieFile)
        } else if !UserDefaults.standard.bool(forKey: Self.legacySessionInvalidatedKey),
                  let data = try? Data(contentsOf: legacyCookieFile),
                  let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            do {
                try Self.persistToKeychain(stored)
                cookies = stored
                Self.markLegacySessionInvalidated()
                try? FileManager.default.removeItem(at: legacyCookieFile)
            } catch {
                Self.log.error("Unable to migrate NetEase session to Keychain")
            }
        } else {
            try? FileManager.default.removeItem(at: legacyCookieFile)
        }
    }

    // MARK: - Cookies

    var isLoggedIn: Bool { cookie(named: "MUSIC_U") != nil }

    func cookie(named name: String) -> String? {
        cookieLock.lock(); defer { cookieLock.unlock() }
        return cookies[name]
    }

    func setCookies(_ new: [String: String]) {
        cookieLock.lock()
        for (k, v) in new { cookies[k] = v }
        let snapshot = cookies
        cookieLock.unlock()
        persist(snapshot)
    }

    /// Ingests a `;;`-joined raw cookie string as returned by the QR login check.
    func ingestCookieString(_ raw: String) throws {
        let parsed = Self.parseCookieString(raw)
        cookieLock.lock()
        for (key, value) in parsed { cookies[key] = value }
        let snapshot = cookies
        cookieLock.unlock()
        try Self.persistToKeychain(snapshot)
        Self.markLegacySessionInvalidated()
    }

    func clearAuthCookies() {
        // Invalidate the old file-backed session first. Even if deleting that
        // file fails, a later launch must not migrate those credentials again.
        Self.markLegacySessionInvalidated()
        cookieLock.lock()
        cookies.removeValue(forKey: "MUSIC_U")
        cookies.removeValue(forKey: "__csrf")
        let snapshot = cookies
        cookieLock.unlock()
        persist(snapshot)
        removeLegacyCookieFile()
    }

    private func removeLegacyCookieFile() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        let legacyCookieFile = support.appendingPathComponent("cookies.json")
        guard FileManager.default.fileExists(atPath: legacyCookieFile.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacyCookieFile)
        } catch {
            Self.log.error("Unable to remove legacy NetEase session file")
        }
    }

    private func persist(_ snapshot: [String: String]) {
        do {
            try Self.persistToKeychain(snapshot)
            Self.markLegacySessionInvalidated()
        } catch {
            Self.log.error("Unable to save NetEase session to Keychain")
        }
    }

    private static func persistToKeychain(_ snapshot: [String: String]) throws {
        let header = snapshot.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
        if header.isEmpty {
            guard ProviderSessionSupport.deleteCookie(service: cookieKeychainService) else {
                throw ProviderSessionSupport.SessionError.storageFailed
            }
        } else {
            try ProviderSessionSupport.writeCookie(header, service: cookieKeychainService)
        }
    }

    private static func markLegacySessionInvalidated() {
        UserDefaults.standard.set(true, forKey: legacySessionInvalidatedKey)
        UserDefaults.standard.synchronize()
    }

    private static func parseCookieString(_ raw: String) -> [String: String] {
        let normalized = raw.replacingOccurrences(of: ";;", with: ";")
        return normalized.components(separatedBy: ";").reduce(into: [:]) { parsed, pair in
            guard let eq = pair.firstIndex(of: "=") else { return }
            let name = pair[..<eq].trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { return }
            parsed[name] = value
        }
    }

    private func cookieHeader(extra: [String: String], overrides: [String: String] = [:]) -> String {
        cookieLock.lock()
        var all = cookies
        cookieLock.unlock()
        for (k, v) in extra where all[k] == nil { all[k] = v }
        for (k, v) in overrides { all[k] = v }
        return all.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func absorbSetCookies(from response: HTTPURLResponse, url: URL) {
        guard let fields = response.allHeaderFields as? [String: String] else { return }
        let parsed = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !parsed.isEmpty else { return }
        var new: [String: String] = [:]
        for c in parsed where !c.value.isEmpty && c.value != "\"\"" {
            new[c.name] = c.value
        }
        if !new.isEmpty { setCookies(new) }
    }

    // MARK: - Requests

    /// POST to `https://music.163.com/weapi<path>` with weapi encryption.
    func weapi(_ path: String, _ payload: [String: Any] = [:],
               cookieOverrides: [String: String] = [:]) async throws -> Data {
        var body = payload
        body["csrf_token"] = cookie(named: "__csrf") ?? ""
        let json = try JSONSerialization.data(withJSONObject: body)
        let form = NeteaseCrypto.weapi(payload: json)

        var fullPath = path
        if let csrf = cookie(named: "__csrf"), !csrf.isEmpty {
            fullPath += (fullPath.contains("?") ? "&" : "?") + "csrf_token=\(csrf)"
        }
        let url = URL(string: "https://music.163.com/weapi\(fullPath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(extra: ["os": "pc", "appver": "3.1.17"], overrides: cookieOverrides),
                         forHTTPHeaderField: "Cookie")
        request.httpBody = Self.encodeForm(form)
        return try await perform(request)
    }

    /// POST to `https://interface.music.163.com/eapi<path>` with eapi encryption.
    /// The digest is computed over the corresponding `/api<path>` path.
    func eapi(_ path: String, _ payload: [String: Any] = [:],
              cookieOverrides: [String: String] = [:]) async throws -> Data {
        let apiPath = "/api" + path
        var body = payload
        var header: [String: String] = [
            "os": "pc",
            "appver": "3.1.17",
            "osver": "Version 14.0 (Build 23A344)",
            "deviceId": "kumone",
            "requestId": String(Int.random(in: 20_000_000...30_000_000)),
            "clientSign": "",
            "versioncode": "140",
            "buildver": String(Int(Date().timeIntervalSince1970)),
            "resolution": "1920x1080",
            "channel": "",
        ]
        if let musicU = cookie(named: "MUSIC_U") { header["MUSIC_U"] = musicU }
        if let csrf = cookie(named: "__csrf") { header["__csrf"] = csrf }
        body["header"] = header
        let json = try JSONSerialization.data(withJSONObject: body)
        let form = NeteaseCrypto.eapi(apiPath: apiPath, payload: json)

        let url = URL(string: "https://interface.music.163.com/eapi\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(cookieHeader(extra: ["os": "pc", "appver": "3.1.17"], overrides: cookieOverrides),
                         forHTTPHeaderField: "Cookie")
        request.httpBody = Self.encodeForm(form)
        return try await perform(request)
    }

    /// Unencrypted public API request used only for read-only metadata. Some
    /// comment endpoints reject the encrypted route even though comments are
    /// public, so callers can fall back without requiring a login.
    func publicGet(_ path: String) async throws -> Data {
        let url = URL(string: "https://music.163.com/api\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NeteaseAPIError.http(-1) }
        absorbSetCookies(from: http, url: request.url!)
        guard (200..<300).contains(http.statusCode) else {
            Self.log.error("HTTP \(http.statusCode) for \(request.url?.path ?? "?")")
            throw NeteaseAPIError.http(http.statusCode)
        }
        return data
    }

    /// Performs a request and decodes the response, surfacing business-level errors.
    func decoded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = obj["code"] as? Int, code != 200 {
            if code == 301 { throw NeteaseAPIError.needLogin }
            let message = (obj["message"] as? String) ?? (obj["msg"] as? String)
            throw NeteaseAPIError.business(code: code, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.log.error("Decoding \(String(describing: T.self)) failed: \(error)")
            throw NeteaseAPIError.decoding(String(describing: error))
        }
    }

    private static func encodeForm(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }
}
