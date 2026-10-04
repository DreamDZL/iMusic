#if os(iOS)
import SwiftUI

/// Owns the one-time "What's New" presentation marker. The marker contains
/// both marketing and build versions so an in-place update shows the log once,
/// while relaunching the same installed build does not interrupt playback.
@MainActor
final class IOSUpdateLogStore: ObservableObject {
    static let shared = IOSUpdateLogStore()

    @Published var isPresented = false
    @Published private(set) var version = ReleaseChecker.currentDisplayVersion

    private let lastPresentedKey = "ios.updateLog.lastPresentedIdentity"

    func presentIfNeeded() {
        let identity = ReleaseChecker.currentIdentity
        guard identity.isValid else { return }
        let marker = "\(identity.shortVersion)#\(identity.buildNumber)"
        guard UserDefaults.standard.string(forKey: lastPresentedKey) != marker else { return }
        UserDefaults.standard.set(marker, forKey: lastPresentedKey)
        version = identity.displayVersion
        isPresented = true
    }

    func present() {
        version = ReleaseChecker.currentDisplayVersion
        isPresented = true
    }
}

struct IOSUpdateLogSheet: View {
    @StateObject private var updateLog = IOSUpdateLogStore.shared
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String, String)] = [
        ("person.crop.circle", "账号同步", "顶部切换网易云与 QQ，分别管理登录、刷新和歌单副本；QQ 私人目录补充加密账号标识。"),
        ("waveform", "第三方音源", "在线播放和下载仅使用启用的 LX 音源；未报告实际音质时显示请求档位。"),
        ("text.bubble", "逐句歌词", "只通过歌词按钮切页；无操作 3 秒隐藏控制，点下半屏唤出，滚动浏览后才能点歌词定位。"),
        ("checklist", "批量操作", "收藏歌曲和歌单详情的批量删除支持全选与取消全选。"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHAT'S NEW")
                            .font(.caption.weight(.bold))
                            .tracking(1.8)
                            .foregroundStyle(Theme.accent)
                        Text("更新日志")
                            .font(.largeTitle.weight(.bold))
                        Text("iMusic \(updateLog.version)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.0)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(LocalizedStringKey(item.1)).font(.headline)
                                    Text(LocalizedStringKey(item.2))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 15)
                            if index < items.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                .padding(20)
            }
            .navigationTitle("更新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
