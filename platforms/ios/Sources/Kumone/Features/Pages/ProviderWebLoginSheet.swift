#if os(iOS)
import SwiftUI
import WebKit

enum ProviderWebLoginKind: String, Identifiable {
    case netease
    case qqMusic
    case kugou

    var id: String { rawValue }

    var title: String {
        switch self {
        case .netease: return "网易云音乐"
        case .qqMusic: return "QQ 音乐"
        case .kugou: return "酷狗音乐"
        }
    }

    var loginURL: URL {
        switch self {
        case .netease: return URL(string: "https://music.163.com/login")!
        // Load each provider's own web surface in an ephemeral WKWebView.
        case .qqMusic: return URL(string: "https://y.qq.com/")!
        case .kugou: return URL(string: "https://m3ws.kugou.com/loginReg.php?act=login")!
        }
    }

    func accepts(domain: String) -> Bool {
        switch self {
        case .netease: return Self.isDomain(domain, within: "163.com")
        case .qqMusic: return Self.isDomain(domain, within: "qq.com")
        case .kugou: return Self.isDomain(domain, within: "kugou.com")
        }
    }

    private static func isDomain(_ domain: String, within root: String) -> Bool {
        let value = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return value == root || value.hasSuffix(".\(root)")
    }

    func looksLoggedIn(_ header: String) -> Bool {
        let values = header.split(separator: ";").reduce(into: [String: String]()) { result, item in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] = pair[1]
        }
        switch self {
        case .netease: return !(values["music_u"] ?? "").isEmpty
        case .qqMusic:
            // Do not close the login sheet for generic QQ cookies. Playlist
            // metadata can be visible while track details still reject the
            // session without a QQ Music ticket.
            return QQMusicLoginCookiePolicy.hasUsableMusicLoginCookie(header)
        case .kugou:
            return !(values["token"] ?? "").isEmpty &&
                !(values["userid"] ?? values["kugooid"] ?? "").isEmpty
        }
    }
}

/// Logs in on the provider's own website and transfers only its Cookie header
/// to the caller. The web view uses an ephemeral store and is never used as a
/// playback or API proxy.
struct ProviderWebLoginSheet: View {
    let provider: ProviderWebLoginKind
    let onSignIn: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var isReadingCookies = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if webView == nil { ProgressView("正在打开\(provider.title)…") }
                ProviderWebView(webView: $webView, url: provider.loginURL)
                    .ignoresSafeArea(.container, edges: .bottom)

                if let statusMessage {
                    VStack {
                        Spacer()
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.green.opacity(0.28), lineWidth: 1))
                            .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("网页登录\(provider.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登录完成") { readCookiesAndSignIn() }
                        .fontWeight(.semibold)
                        .disabled(isReadingCookies || webView == nil)
                }
            }
            .task(id: webView != nil) {
                await monitorCookies()
            }
            .alert("读取登录状态失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "请完成登录后重试")
            }
        }
    }

    private func readCookiesAndSignIn() {
        guard !isReadingCookies else { return }
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else {
            errorMessage = "登录页面还没有准备好，请稍后重试"
            return
        }
        isReadingCookies = true
        store.getAllCookies { cookies in
            let header = self.cookieHeader(from: cookies)

            Task { @MainActor in await signIn(cookie: header) }
        }
    }

    @MainActor
    private func monitorCookies() async {
        while !Task.isCancelled {
            guard !isReadingCookies,
                  let store = webView?.configuration.websiteDataStore.httpCookieStore else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            let header = await cookieHeader(from: store)
            if provider.looksLoggedIn(header) {
                await signIn(cookie: header)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func cookieHeader(from store: WKHTTPCookieStore) async -> String {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: self.cookieHeader(from: cookies))
            }
        }
    }

    private func cookieHeader(from cookies: [HTTPCookie]) -> String {
        var values: [String: String] = [:]
        let scoped = cookies.filter { provider.accepts(domain: $0.domain) }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                if $0.domain.count != $1.domain.count { return $0.domain.count > $1.domain.count }
                if $0.path.count != $1.path.count { return $0.path.count > $1.path.count }
                return $0.value < $1.value
            }
        for cookie in scoped where values[cookie.name] == nil && !cookie.value.isEmpty {
            values[cookie.name] = cookie.value
        }
        return values.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "; ")
    }

    @MainActor
    private func signIn(cookie: String) async {
        isReadingCookies = true
        do {
            guard !cookie.isEmpty else { throw ProviderLoginError.emptyCookie }
            try await onSignIn(cookie)
            isReadingCookies = false
            statusMessage = "\(provider.title)登录成功"
            ToastCenter.shared.show("\(provider.title)登录成功")
            dismiss()
        } catch {
            isReadingCookies = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProviderWebView: UIViewRepresentable {
    @Binding var webView: WKWebView?
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        DispatchQueue.main.async { webView = view }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // QQ and NetEase route some desktop login steps through a new
            // window. Keep that flow in the same ephemeral web view so the
            // resulting provider cookies stay readable by the login sheet.
            guard navigationAction.targetFrame == nil else { return nil }
            webView.load(navigationAction.request)
            return nil
        }
    }
}

private enum ProviderLoginError: LocalizedError {
    case emptyCookie
    var errorDescription: String? { "没有读取到有效登录 Cookie，请先完成登录" }
}
#endif
