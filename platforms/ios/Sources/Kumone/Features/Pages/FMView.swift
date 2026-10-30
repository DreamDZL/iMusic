import SwiftUI

/// 电台 tab, laid out like the system Radio page: one large station card that
/// starts or controls personal radio, then live picks from the same feed.
/// Nothing here is promotional filler; every tile comes from personal FM.
struct FMView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var localLibrary = LocalPlaylistStore.shared
    @Environment(\.openLogin) private var openLogin
    @State private var recommendations: [Track] = []
    @State private var isLoadingRecommendations = false
    @State private var recommendationError: String?
    /// Measured page width for the station card.
    @State private var pageWidth: CGFloat = 390

    var body: some View {
        // A scroll view root keeps the large title in the navigation bar; the
        // previous centred ZStack let the artwork slide under the title.
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                stationCard
                if account.hasAuthCookie {
                    recommendationSection
                } else {
                    loginPrompt
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 6)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            pageWidth = width
        }
        .navigationTitle("电台")
        .task(id: account.hasAuthCookie) {
            guard account.hasAuthCookie else {
                recommendations = []
                recommendationError = nil
                return
            }
            await loadRecommendations()
        }
        .refreshable {
            guard account.hasAuthCookie else { return }
            await loadRecommendations()
        }
    }

    private var nowPlaying: Track? {
        player.isFMMode ? player.currentTrack : nil
    }

    // MARK: - Station card

    private var stationCard: some View {
        let width = max(240, pageWidth - Theme.Layout.contentInset * 2)
        let height = min((width * 0.74).rounded(), 320)
        return VStack(alignment: .leading, spacing: 2) {
            Text(player.isFMMode ? "正在播放" : "个人电台")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("iMusic 电台")
                .font(.title3)
            Text("按首页平台连续推荐好音乐")
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 8)

            ZStack(alignment: .bottomLeading) {
                stationArtwork(width: width, height: height)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.66), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying?.name ?? String(localized: "电台推荐"))
                            .font(.headline)
                            .lineLimit(1)
                        Text(nowPlaying?.artistNames ?? String(localized: "点按播放开始收听"))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if player.isFMMode {
                        stationControls
                    } else {
                        Button {
                            player.startFM()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.title3)
                                .foregroundStyle(.black)
                                .frame(width: 48, height: 48)
                                .background(.white, in: Circle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("开始播放电台")
                    }
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            )
            .animation(AppAnimation.smooth, value: nowPlaying?.playbackKey)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    @ViewBuilder
    private func stationArtwork(width: CGFloat, height: CGFloat) -> some View {
        if let cover = nowPlaying?.album.picUrl?.resizedImageURL(768) {
            CachedAsyncImage(url: cover)
                .frame(width: width, height: height)
                .clipped()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.20, blue: 0.42),
                             Color(red: 0.42, green: 0.24, blue: 0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: min(width, height) * 0.3))
                    .foregroundStyle(.white.opacity(0.88))
                    .offset(y: -height * 0.08)
            }
            .frame(width: width, height: height)
            .accessibilityHidden(true)
        }
    }

    private var stationControls: some View {
        HStack(spacing: 0) {
            Button {
                player.fmTrash()
            } label: {
                stationGlyph("hand.thumbsdown")
            }
            .accessibilityLabel("不喜欢这首")
            .accessibilityHint("跳过当前歌曲")

            Button {
                player.togglePlayPause()
            } label: {
                stationGlyph(player.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            Button {
                player.fmNext()
            } label: {
                stationGlyph("forward.fill")
            }
            .accessibilityLabel("下一首")
            .accessibilityHint("播放下一首电台推荐")

            if let track = nowPlaying {
                let liked = localLibrary.isFavorite(track)
                Button {
                    localLibrary.toggleFavorite(track)
                } label: {
                    stationGlyph(liked ? "star.fill" : "star")
                }
                .accessibilityLabel(liked ? "取消收藏" : "收藏")
            }
        }
        .buttonStyle(.pressable)
    }

    private func stationGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title3.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: - Recommendations

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "为你推荐")
                if !recommendations.isEmpty, !isLoadingRecommendations {
                    Button("换一批") {
                        Task { await loadRecommendations() }
                    }
                    .tint(Theme.accent)
                }
            }

            recommendationContent
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    }

    @ViewBuilder
    private var recommendationContent: some View {
        if isLoadingRecommendations && recommendations.isEmpty {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonView().aspectRatio(1, contentMode: .fit)
                        SkeletonView(cornerRadius: 4).frame(height: 10)
                        SkeletonView(cornerRadius: 4).frame(width: 52, height: 9)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("正在获取电台推荐")
        } else if let recommendationError, recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("电台推荐暂时不可用", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.semibold))
                Text(recommendationError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("重试") { Task { await loadRecommendations() } }
                    .buttonStyle(.bordered)
                    .tint(Theme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if recommendations.isEmpty {
            Text("暂无可用的电台推荐")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(Array(recommendations.enumerated()), id: \.offset) { _, item in
                    Button {
                        player.play(tracks: recommendations, source: .none, startAt: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            CachedAsyncImage(url: item.album.picUrl?.resizedImageURL(300), animated: false)
                                .aspectRatio(1, contentMode: .fill)
                                .background(.quaternary.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                            Text(item.name)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(item.artistNames)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.interactiveCard)
                    .accessibilityLabel("播放电台推荐：\(item.name)，\(item.artistNames)")
                }
            }
        }
    }

    @MainActor
    private func loadRecommendations() async {
        guard account.hasAuthCookie else { return }
        isLoadingRecommendations = true
        recommendationError = nil
        defer { isLoadingRecommendations = false }
        do {
            let result = try await NeteaseAPI.personalFM()
            guard !Task.isCancelled else { return }
            recommendations = Array(result.prefix(6))
        } catch is CancellationError {
            return
        } catch {
            recommendations = []
            recommendationError = error.localizedDescription
        }
    }

    private var loginPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "为你推荐")
            Text("登录网易云后，这里会显示根据你的听歌口味生成的推荐。电台本身无需登录即可播放。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("登录") { openLogin() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.Layout.contentInset)
    }
}
