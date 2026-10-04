import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
#if os(iOS)
    @StateObject private var lxStore = LXSourceStore.shared
    @StateObject private var updateLog = IOSUpdateLogStore.shared
#endif
    @State private var cacheSize = "计算中…"
    @State private var showEqualizer = false
    @ObservedObject private var equalizer = MoumusicEqualizer.shared
#if os(iOS)
    @State private var showSourceManager = false
#endif
    // Keep the main controls visible on first launch. Every section remains
    // collapsible, but opening the settings page with every group closed makes
    // the app look empty and hides the controls users came here to change.
    @State private var expandedSections: Set<String> = [
        "audio", "accounts", "playback", "home", "sources",
        "appearance", "lyrics",
        "storage", "updates", "about"
    ]

    var body: some View {
        Form {
            SettingsDisclosureSection("音源与音质", isExpanded: sectionBinding("audio")) {
                Label("第三方音源", systemImage: "waveform")
                Text("播放仅使用已导入并启用的第三方音源。网易云与 QQ 登录只用于账号资料和歌单同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("默认播放音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text("\(quality.displayName) · \(quality.sourceDisplayName)")
                            .tag(quality)
                    }
                }
                Text("音质显示为音源明确返回的实际档位；若第三方音源未提供音质信息，会显示当前请求档位。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            SettingsDisclosureSection("账号与同步", isExpanded: sectionBinding("accounts")) {
                NavigationLink {
                    LXSyncSettingsView()
                } label: {
                    Label("LX 多设备同步", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    AccountSyncView()
                } label: {
                    Label("账号同步", systemImage: "person.crop.circle.badge.checkmark")
                }
                Text("管理网易云与 QQ 音乐的登录状态和歌单同步。平台账号音源不参与播放；凭据仅保存在本机钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            SettingsDisclosureSection("播放设置", isExpanded: sectionBinding("playback")) {
#if os(iOS)
                Toggle("播放失败时切换平台", isOn: $settings.enableSourcePlatformFallback)
                Text(settings.enableSourcePlatformFallback
                     ? "当前平台无法播放时，允许音源尝试其他平台的同名歌曲。"
                     : "单平台模式：只使用歌曲标记的平台，不跨平台匹配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
#endif
                Button {
                    showEqualizer = true
                } label: {
                    HStack {
                        Label("均衡器", systemImage: "waveform.path.ecg")
                        Spacer()
                        Text(equalizer.isEnabled ? "已开启" : "已关闭")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                Text("音频只使用已导入并启用的 LX 音源；歌词、封面和评论仍按歌曲平台获取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("音质在歌曲播放页调整；可用档位由当前 LX 音源支持的能力决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsDisclosureSection("首页推荐", isExpanded: sectionBinding("home")) {
                Picker("推荐内容", selection: $settings.homeRecommendationMode) {
                    ForEach(HomeRecommendationMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("推荐平台", selection: $settings.homeRecommendationPlatform) {
                    ForEach(LXCatalogPlatform.catalogueCases.filter { $0 != .aggregate }) { platform in
                        Text(platform.displayName).tag(platform)
                    }
                }
                Text("聚合搜索只属于搜索页；首页始终使用你选定的一个推荐平台，并在每次刷新时重新读取内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

#if os(iOS)
            SettingsDisclosureSection("LX 音源", isExpanded: sectionBinding("sources")) {
                sourceManagerRow
                Text("音源管理是独立页面：可导入文件或在线链接、切换当前音源，并测试 musicUrl 接口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
#endif

            SettingsDisclosureSection("主题模式", isExpanded: sectionBinding("appearance")) {
                AppearancePicker(selection: $settings.appearance)
                Text("Liquid Glass 的透明度与着色由 iPhone 的系统显示设置控制；iMusic 使用原生玻璃组件并跟随系统偏好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsDisclosureSection("歌词显示", isExpanded: sectionBinding("lyrics")) {
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Picker("日文歌词注音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
#if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                    Text("开启后仅保留垂直位置，桌面歌词始终位于屏幕水平中心。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
#endif
            }

            SettingsDisclosureSection("存储", isExpanded: sectionBinding("storage")) {
                LabeledContent("图片缓存", value: cacheSize)
                Button("清除缓存") { clearCache() }
            }

            SettingsDisclosureSection("更新", isExpanded: sectionBinding("updates")) {
                Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
#if os(iOS)
                Button {
                    IOSUpdater.shared.check(interactive: true)
                } label: {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    updateLog.present()
                } label: {
                    Label("查看更新日志", systemImage: "doc.text.magnifyingglass")
                }
#endif
            }

            SettingsDisclosureSection("关于", isExpanded: sectionBinding("about")) {
                LabeledContent("iMusic", value: appVersion)
                Text("播放、歌词和封面支持用户导入的 LX User API 音源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
#if os(iOS)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Material.thin)
        )
        .tint(Theme.accent)
#endif
#if os(macOS)
        .frame(width: 440, height: 520)
#endif
        .task { updateCacheSize() }
        .sheet(isPresented: $showEqualizer) {
            EqualizerView()
        }
#if os(iOS)
        .sheet(isPresented: $showSourceManager) {
            NavigationStack {
                LXSourceManagerView()
            }
        }
#endif
    }

    private var appVersion: String {
        ReleaseChecker.currentDisplayVersion
    }

#if os(iOS)
    private var sourceManagerRow: some View {
        Button {
            showSourceManager = true
        } label: {
            HStack {
                Label("管理 / 导入 LX 音源", systemImage: "waveform.badge.plus")
                Spacer()
                Text(lxStore.selectedSource?.name ?? "未启用")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
    }

#endif

    private func sectionBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedSections.contains(id) },
            set: { expanded in
                if expanded {
                    expandedSections.insert(id)
                } else {
                    expandedSections.remove(id)
                }
            }
        )
    }

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("im.missuo.Kumone/images", isDirectory: true)
    }

    private func updateCacheSize() {
        let directory = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let bytes = files.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            DispatchQueue.main.async { cacheSize = formatted }
        }
    }

    private func clearCache() {
        let directory = cacheDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            DispatchQueue.main.async {
                cacheSize = "0 字节"
                ToastCenter.shared.show("缓存已清除")
            }
        }
    }
}

private struct SettingsDisclosureSection<Content: View>: View {
    private let title: String
    @Binding private var isExpanded: Bool
    private let content: () -> Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                content()
            } label: {
                Text(title)
                    .font(.headline.weight(.semibold))
            }
        }
    }
}

/// A compact three-way control matching the native settings pattern in the
/// reference UI. The binding applies the same transition whether the user
/// taps a segment or changes the value from an accessibility action.
private struct AppearancePicker: View {
    @Binding var selection: AppAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Picker("主题", selection: appearanceBinding) {
            ForEach(AppAppearance.allCases) { appearance in
                Text(appearance.displayName)
                    .tag(appearance)
            }
        }
        .pickerStyle(.segmented)
        .tint(Theme.accent)
        .animation(reduceMotion ? nil : AppAnimation.smooth, value: selection)
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue != selection else { return }
                if reduceMotion {
                    selection = newValue
                } else {
                    withAnimation(AppAnimation.smooth) {
                        selection = newValue
                    }
                }
            }
        )
    }
}
