import SwiftUI

// MARK: - 最近播放

struct RecentsView: View {
    @StateObject private var library = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @State private var query = ""

    private var visibleTracks: [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.recentTracks }
        return library.recentTracks.filter { track in
            track.name.localizedCaseInsensitiveContains(query)
                || track.artistNames.localizedCaseInsensitiveContains(query)
                || track.album.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !visibleTracks.isEmpty {
                    Button {
                        player.play(tracks: visibleTracks, source: .none)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .padding(.horizontal, Theme.Layout.contentInset)
                }

                if library.recentTracks.isEmpty {
                    EmptyStateView(
                        icon: "clock.arrow.circlepath",
                        title: "暂无播放记录",
                        subtitle: "开始播放后，最近听过的歌曲会出现在这里"
                    )
                        .frame(minHeight: 300)
                } else if visibleTracks.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲")
                        .frame(minHeight: 240)
                } else {
                    TrackListView(tracks: visibleTracks, style: .compact)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
            .padding(.top, 12)
        }
        .navigationTitle("最近播放")
        .searchable(text: $query, prompt: "搜索最近播放")
    }
}

// MARK: - 音乐云盘

struct CloudView: View {
    @State private var items: [CloudSongItem] = []
    @State private var sizeInfo: String?
    @State private var isLoading = true

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    if let sizeInfo {
                        Text(sizeInfo)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        player.play(tracks: tracks, source: .cloud, context: .cloud)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.accentGradient, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    .disabled(items.isEmpty)
                }
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, 12)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if items.isEmpty {
                    EmptyStateView(icon: "icloud", title: "云盘还没有歌曲",
                                   subtitle: "在网易云音乐客户端上传的歌曲会出现在这里")
                        .frame(minHeight: 300)
                } else {
                    TrackListView(tracks: tracks, style: .compact, source: .cloud, context: .cloud)
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("音乐云盘")
        .task {
            if items.isEmpty {
                await load()
            }
        }
    }

    private var tracks: [Track] {
        items.compactMap(\.simpleSong)
    }

    private func load() async {
        isLoading = items.isEmpty
        if let response = try? await NeteaseAPI.cloudSongs() {
            items = response.data ?? []
            if let size = response.size, let max = response.maxSize, max > 0 {
                let used = String(format: "%.1f", Double(size) / 1_073_741_824)
                let total = String(format: "%.0f", Double(max) / 1_073_741_824)
                sizeInfo = String(localized: "已使用 \(used) GB / \(total) GB")
            }
        }
        isLoading = false
    }
}
