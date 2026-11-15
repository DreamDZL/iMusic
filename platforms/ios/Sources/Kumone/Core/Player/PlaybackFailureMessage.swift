import Foundation

enum PlaybackFailureMessage {
    static let unplayableMedia = "音源已返回地址，但音频无法加载。请重试或在设置中更换音源。"

    static func source(_ error: Error) -> String {
        #if os(iOS)
        if let error = error as? LXUserAPIService.LXError {
            switch error {
            case .noSource, .missingCapability, .requestTimedOut:
                return error.localizedDescription
            case .resolveFailed, .sourceUnavailable, .javascript:
                break
            }
        }
        #endif
        return "已启用的音源未能解析这首歌曲。请检查音源能力和网络后重试。"
    }
}
