import Foundation
import Combine

#if os(iOS) || os(macOS)
@MainActor
final class QQMusicSessionStore: ObservableObject {
    static let shared = QQMusicSessionStore()

    enum SessionError: LocalizedError {
        case emptyCookie
        case invalidCookie
        case validationFailed

        var errorDescription: String? {
            switch self {
            case .emptyCookie: return "没有读取到 QQ 音乐登录状态，请先在网页登录"
            case .invalidCookie: return "QQ 音乐网页登录状态格式不正确，请重新登录"
            case .validationFailed: return "QQ 音乐登录已失效或 Cookie 已过期"
            }
        }
    }

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isValidatingStoredSession = false
    @Published private(set) var profileName: String?
    @Published private(set) var sessionValidationMessage: String?
    @Published private(set) var sessionRevision = 0

    var cookie: String? { isLoggedIn ? storedCookie : nil }

    var settingsStatusText: String {
        if isValidatingStoredSession { return "验证中" }
        if isLoggedIn, sessionValidationMessage != nil { return "同步异常" }
        if isLoggedIn { return "已登录" }
        if sessionValidationMessage != nil { return "需重新登录" }
        return "未登录"
    }

    private let keychainService = "com.moumusic.qqmusic.session"
    private let validatedAtKey = "provider.qqmusic.validated-at"
    private let validationInterval: TimeInterval = 12 * 60 * 60
    private var storedCookie: String?
    private var validationTask: Task<Void, Never>?
    private var loginAttemptRevision = 0

    private init() {
        storedCookie = ProviderSessionSupport.readCookie(service: keychainService)
        guard let cookie = storedCookie else { return }
        guard QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(cookie) else {
            UserDefaults.standard.removeObject(forKey: validatedAtKey)
            sessionValidationMessage = "已保存的 QQ 网页状态缺少 QQ 音乐曲目凭据，请退出后重新使用电脑端网页登录"
            return
        }
        let validatedAt = UserDefaults.standard.double(forKey: validatedAtKey)
        if validatedAt > 0, Date().timeIntervalSince1970 - validatedAt < validationInterval {
            // Restore a recently server-validated session immediately. The
            // account page refreshes playlists on demand; cold launch never
            // waits on QQ's private endpoints or adds avoidable radio work.
            isLoggedIn = true
            profileName = "QQ 音乐用户"
            return
        }
        isValidatingStoredSession = true
        validationTask = Task { @MainActor [weak self] in
            await self?.restoreStoredSession(cookie)
        }
    }

    private func restoreStoredSession(_ requestCookie: String) async {
        let requestRevision = sessionRevision
        defer {
            if sessionRevision == requestRevision, storedCookie == requestCookie {
                isValidatingStoredSession = false
                validationTask = nil
            }
        }
        do {
            let snapshot = try await QQMusicAPI.shared.userPlaylists(cookie: requestCookie)
            guard sessionRevision == requestRevision, storedCookie == requestCookie else { return }
            applyValidatedSession(snapshot, cookie: requestCookie, incrementRevision: true)
        } catch {
            guard sessionRevision == requestRevision, storedCookie == requestCookie else { return }
            isLoggedIn = false
            profileName = nil
            sessionValidationMessage = error.localizedDescription
        }
    }

    private func applyValidatedSession(
        _ snapshot: QQMusicAPI.PlaylistListResult,
        cookie requestCookie: String,
        incrementRevision: Bool
    ) {
        guard storedCookie == requestCookie else { return }
        let acceptedCookie = snapshot.refreshedCookie ?? requestCookie
        if acceptedCookie != requestCookie {
            do {
                try ProviderSessionSupport.writeCookie(acceptedCookie, service: keychainService)
                storedCookie = acceptedCookie
            } catch {
                // Keep the session cookie that already passed playlist validation.
            }
        }
        profileName = "QQ 音乐用户"
        sessionValidationMessage = nil
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: validatedAtKey)
        isLoggedIn = true
        isValidatingStoredSession = false
        if incrementRevision { sessionRevision &+= 1 }
        validationTask = nil
        let revision = sessionRevision
        QQMusicPlaylistSyncStore.shared.acceptValidatedSnapshot(snapshot, sessionRevision: revision)
    }

    func signIn(cookie rawCookie: String) async throws {
        let cookie = ProviderSessionSupport.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else { throw SessionError.emptyCookie }
        guard ProviderSessionSupport.looksLikeCookie(cookie) else { throw SessionError.invalidCookie }
        validationTask?.cancel()
        validationTask = nil
        isValidatingStoredSession = false
        sessionValidationMessage = nil
        loginAttemptRevision &+= 1
        let requestAttempt = loginAttemptRevision
        let requestRevision = sessionRevision
        // Validate the account against QQ's actual playlist APIs before
        // reporting a successful login. Cookie shape/profile fallbacks alone
        // can otherwise mark a session signed in while playlist sync fails.
        let playlistSnapshot = try await QQMusicAPI.shared.userPlaylists(cookie: cookie)
        guard requestAttempt == loginAttemptRevision,
              requestRevision == sessionRevision else { throw SessionError.validationFailed }
        do {
            try ProviderSessionSupport.writeCookie(cookie, service: keychainService)
        } catch {
            throw SessionError.validationFailed
        }
        storedCookie = cookie
        isLoggedIn = true
        applyValidatedSession(playlistSnapshot, cookie: cookie, incrementRevision: true)
    }

    func refreshProfile() async {
        guard isLoggedIn else { return }
        // Use the playlist store as the single request owner so foreground
        // account refresh and the settings refresh cannot race duplicate QQ
        // calls or overwrite each other's validated snapshot.
        await QQMusicPlaylistSyncStore.shared.refresh()
    }

    func recordPlaylistValidationSuccess(expectedSessionRevision: Int) {
        guard isLoggedIn, sessionRevision == expectedSessionRevision else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: validatedAtKey)
    }

    func recordTrackListSyncSuccess(expectedSessionRevision: Int) {
        guard isLoggedIn, sessionRevision == expectedSessionRevision else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: validatedAtKey)
        sessionValidationMessage = nil
    }

    /// Keeps playback available after a transient provider failure, while
    /// clearing the warm validation cache and showing that playlist sync needs
    /// attention. The next launch will validate the cookie with QQ again.
    func recordPlaylistValidationFailure(
        _ message: String,
        expectedSessionRevision: Int
    ) {
        guard isLoggedIn, sessionRevision == expectedSessionRevision else { return }
        UserDefaults.standard.removeObject(forKey: validatedAtKey)
        sessionValidationMessage = message
    }

    /// Applies a provider-rotated cookie returned by a successful read-only
    /// request. It stays in the existing Keychain item and is never logged.
    func acceptRefreshedCookie(
        _ rawCookie: String?,
        expectedSessionRevision: Int,
        expectedCookie: String
    ) {
        guard expectedSessionRevision == sessionRevision,
              storedCookie == expectedCookie else { return }
        guard let rawCookie else { return }
        let normalized = ProviderSessionSupport.normalizedCookie(rawCookie)
        guard QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(normalized),
              normalized != storedCookie else { return }
        do {
            try ProviderSessionSupport.writeCookie(normalized, service: keychainService)
        } catch {
            return
        }
        storedCookie = normalized
    }

    func signOut() {
        ProviderSessionSupport.deleteCookie(service: keychainService)
        storedCookie = nil
        profileName = nil
        isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: validatedAtKey)
        isValidatingStoredSession = false
        sessionValidationMessage = nil
        validationTask?.cancel()
        validationTask = nil
        loginAttemptRevision &+= 1
        sessionRevision &+= 1
    }
}
#endif
