import SwiftUI

/// 电台 — immersive personal FM page.
struct FMView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin
    @Environment(\.colorScheme) private var colorScheme
    @State private var recommendations: [Track] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationError: String?

    var body: some View {
        ZStack {
            backdrop
            if account.hasAuthCookie {
                content
            } else {
                loginPrompt
            }
        }
        .navigationTitle("电台")
        .compatHiddenToolbarBackground()
        .task(id: account.hasAuthCookie) {
            guard account.hasAuthCookie else {
                recommendations = []
                recommendationError = nil
                return
            }
            await loadRecommendations()
        }
    }

    private var track: Track? {
        player.isFMMode ? player.currentTrack : nil
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            Platform.windowBackgroundColor
            if let cover = track?.album.picUrl?.resizedImageURL(384) {
                CachedAsyncImage(url: cover)
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(colorScheme == .dark ? 0.45 : 0.3)
                    .saturation(1.4)
            }
            LinearGradient(
                colors: [.clear, Platform.windowBackgroundColor.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(AppAnimation.smooth, value: track?.id)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                if let cover = track?.album.picUrl?.resizedImageURL(768) {
                    CachedAsyncImage(url: cover)
                        .frame(width: 300, height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.quaternary.opacity(0.4))
                        .frame(width: 300, height: 300)
                        .overlay(
                            Image(systemName: "wave.3.right.circle")
                                .font(.system(size: 56, weight: .light))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .scaleEffect(player.isPlaying && player.isFMMode ? 1 : 0.94)
            .animation(AppAnimation.bouncy, value: player.isPlaying && player.isFMMode)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(track?.name ?? String(localized: "电台推荐"))
                        .font(.system(size: 22, weight: .bold))
                        .lineLimit(1)
                    if track?.fee == 1 {
                        VIPBadge()
                    }
                }
                Text(track?.artistNames ?? String(localized: "根据你的口味推荐好音乐"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 420)

            recommendationChoices

            if player.isFMMode {
                controls
            } else {
                Button {
                    player.startFM()
                } label: {
                    Label("开始播放", systemImage: "wave.3.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Theme.accentGradient, in: Capsule())
                        .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 3)
                }
                .buttonStyle(.pressable)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var recommendationChoices: some View {
        if isLoadingRecommendations {
            ProgressView("正在获取电台推荐…")
                .frame(maxWidth: 420, minHeight: 96)
        } else if let recommendationError, recommendations.isEmpty {
            VStack(spacing: 8) {
                Label("电台推荐暂时不可用", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                Text(recommendationError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("重试") { Task { await loadRecommendations() } }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 420, minHeight: 96)
        } else if recommendations.isEmpty {
            Text("暂无可用的电台推荐")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420, minHeight: 96)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                ForEach(Array(recommendations.prefix(6).enumerated()), id: \.offset) { _, item in
                    Button {
                        player.play(tracks: [item], source: .none)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CachedAsyncImage(url: item.album.picUrl?.resizedImageURL(256), animated: false)
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                            Text(item.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(item.artistNames)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放电台推荐：\(item.name)，\(item.artistNames)")
                }
            }
            .frame(maxWidth: 420)
        }
    }

    @MainActor
    private func loadRecommendations() async {
        guard account.hasAuthCookie else { return }
        isLoadingRecommendations = true
        recommendationError = nil
        defer { isLoadingRecommendations = false }
        do {
            recommendations = Array(try await NeteaseAPI.personalFM().prefix(6))
        } catch is CancellationError {
            return
        } catch {
            recommendations = []
            recommendationError = error.localizedDescription
        }
    }

    private var controls: some View {
        HStack(spacing: 26) {
            Button {
                player.fmTrash()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("不喜欢这首")
            .accessibilityHint("跳过当前歌曲")

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 64, height: 64)
                        .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 4)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button {
                player.fmNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("下一首")
            .accessibilityHint("播放下一首电台推荐")

            if let track {
                LikeButton(track: track, size: 16)
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.06), in: Circle())
            }
        }
    }

    private var loginPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "wave.3.right.circle")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tertiary)
                Text("登录后开启电台")
                .font(.headline)
            Text("网易云会根据你的听歌口味推荐音乐")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("登录") { openLogin() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }
}
