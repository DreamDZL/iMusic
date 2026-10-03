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
    @Published private(set) var profileName: String?
    @Published private(set) var sessionRevision = 0

    var cookie: String? { storedCookie }

    private let keychainService = "com.moumusic.qqmusic.session"
    private var storedCookie: String?

    private init() {
        storedCookie = ProviderSessionSupport.readCookie(service: keychainService)
        isLoggedIn = storedCookie != nil
    }

    func signIn(cookie rawCookie: String) async throws {
        let cookie = ProviderSessionSupport.normalizedCookie(rawCookie)
        guard !cookie.isEmpty else { throw SessionError.emptyCookie }
        guard ProviderSessionSupport.looksLikeCookie(cookie) else { throw SessionError.invalidCookie }
        sessionRevision &+= 1
        let requestRevision = sessionRevision
        guard let profile = try? await QQMusicAPI.shared.profile(cookie: cookie) else {
            throw SessionError.validationFailed
        }
        guard requestRevision == sessionRevision else { throw SessionError.validationFailed }
        do {
            try ProviderSessionSupport.writeCookie(cookie, service: keychainService)
        } catch {
            throw SessionError.validationFailed
        }
        var persistedCookie = cookie
        if let refreshedCookie = profile.refreshedCookie {
            do {
                try ProviderSessionSupport.writeCookie(refreshedCookie, service: keychainService)
                persistedCookie = refreshedCookie
            } catch {
                // The validated input cookie is already stored successfully.
            }
        }
        storedCookie = persistedCookie
        profileName = profile.name
        isLoggedIn = true
        sessionRevision &+= 1

        // Playlist synchronization begins after the login sheet can close;
        // it must never delay account validation or first playback.
        Task { @MainActor in
            await QQMusicPlaylistSyncStore.shared.syncAfterLogin()
        }
    }

    func refreshProfile() async {
        guard let requestCookie = storedCookie else { return }
        let requestRevision = sessionRevision
        guard let profile = try? await QQMusicAPI.shared.profile(cookie: requestCookie) else {
            guard requestRevision == sessionRevision, storedCookie == requestCookie else { return }
            signOut()
            return
        }
        guard requestRevision == sessionRevision, storedCookie == requestCookie else { return }
        profileName = profile.name
        isLoggedIn = true
        if let refreshedCookie = profile.refreshedCookie {
            do {
                try ProviderSessionSupport.writeCookie(refreshedCookie, service: keychainService)
                self.storedCookie = refreshedCookie
            } catch {
                // Keep the current in-memory cookie aligned with Keychain.
            }
        }
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
        guard !normalized.isEmpty, normalized != storedCookie else { return }
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
        sessionRevision &+= 1
    }
}
#endif
