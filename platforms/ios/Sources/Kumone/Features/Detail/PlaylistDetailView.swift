import SwiftUI

@MainActor
final class PlaylistDetailViewModel: ObservableObject {
    let playlistID: Int
    @Published var detail: PlaylistDetail?
    @Published var tracks: [Track] = []
    @Published var privileges: [Int: TrackPrivilege] = [:]
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var filter = ""
    @Published private(set) var hasCompleteTracks = false

    private var generation = 0

    init(playlistID: Int) {
        self.playlistID = playlistID
    }

    var filteredTracks: [Track] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.name.lowercased().contains(query)
                || $0.artistNames.lowercased().contains(query)
                || $0.album.name.lowercased().contains(query)
        }
    }

    func load() async {
        generation += 1
        let requestGeneration = generation
        isLoading = tracks.isEmpty
        errorMessage = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        do {
            let response = try await NeteaseAPI.playlistDetail(id: playlistID)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            let complete = try await NeteaseAPI.completePlaylistTracks(from: response)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            guard response.playlist.trackCount <= 0
                    || complete.tracks.count == response.playlist.trackCount else {
                throw NeteaseAPIError.incompletePlaylist(
                    expected: response.playlist.trackCount,
                    received: complete.tracks.count
                )
            }
            detail = response.playlist
            tracks = complete.tracks
            hasCompleteTracks = PlaylistTrackCompleteness.isComplete(
                declaredTrackCount: response.playlist.trackCount,
                authoritativeTrackIDs: response.playlist.trackIds,
                resolvedTrackCount: complete.tracks.count
            )
            merge(privileges: complete.privileges)
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            if tracks.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func merge(privileges list: [TrackPrivilege]?) {
        for privilege in list ?? [] {
            privileges[privilege.id] = privilege
        }
    }

    func remove(_ track: Track) {
        let oldCount = tracks.count
        tracks.removeAll { $0.id == track.id }
        if tracks.count != oldCount { hasCompleteTracks = false }
    }
}

struct PlaylistDetailView: View {
    let playlistID: Int
    var isLikedList = false

    @StateObject private var model: PlaylistDetailViewModel
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var localPlaylists = LocalPlaylistStore.shared
    @State private var showFullDescription = false
    @State private var showLoadedSnapshotConfirmation = false

    init(playlistID: Int, isLikedList: Bool = false) {
        self.playlistID = playlistID
        self.isLikedList = isLikedList
        _model = StateObject(wrappedValue: PlaylistDetailViewModel(playlistID: playlistID))
    }

    private var isOwnPlaylist: Bool {
        model.detail?.creator?.userId == account.profile?.userId
    }

    private var isCompact: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone || horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if let detail = model.detail {
                    if isCompact {
                        compactHeader(detail)
                            .padding(.top, 12)
                    } else {
                        regularHeader(detail)
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, 16)

                        if !isLikedList {
                            localCollectionAction(detail)
                                .padding(.horizontal, Theme.Layout.contentInset)
                        }
                    }

                    if model.tracks.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "歌单暂无歌曲")
                            .frame(minHeight: 240)
                    } else if model.filteredTracks.isEmpty {
                        EmptyStateView(icon: "magnifyingglass", title: "没有匹配的歌曲")
                            .frame(minHeight: 180)
                    } else {
                        TrackListView(
                            tracks: model.filteredTracks,
                            privileges: model.privileges,
                            source: .playlist(playlistID),
                            context: model.detail.map { .playlist(id: playlistID, name: $0.name) },
                            removableFromPlaylistID: isOwnPlaylist ? playlistID : nil,
                            onRemoved: { model.remove($0) }
                        )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }

                } else if model.isLoading {
                    loadingHeader
                } else if let message = model.errorMessage {
                    ErrorStateView(message: message) {
                        Task { await model.load() }
                    }
                    .frame(minHeight: 400)
                }
                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(model.detail?.name ?? String(localized: "歌单"))
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: playlistID) {
            await model.load()
        }
    }

    // MARK: - Compact (Mobile) Header

    private func compactHeader(_ detail: PlaylistDetail) -> some View {
        CollectionHeader(
            title: isLikedList ? String(localized: "我喜欢的音乐") : detail.name,
            curator: isLikedList ? nil : detail.creator?.nickname,
            detail: "\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放",
            description: detail.description?.replacingOccurrences(of: "\n", with: " "),
            playDisabled: playable.isEmpty,
            onPlay: {
                player.play(tracks: playable, source: .playlist(playlistID),
                            context: .playlist(id: playlistID, name: detail.name))
            },
            onShuffle: {
                player.playShuffled(tracks: playable, source: .playlist(playlistID),
                                    context: .playlist(id: playlistID, name: detail.name))
            }
        ) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(600))
        } actions: {
            HStack(spacing: 10) {
                if isLikedList {
                    Button {
                        startHeartbeat()
                    } label: {
                        Label("心动模式", systemImage: "heart.circle")
                            .frame(minHeight: 30)
                    }
                } else {
                    localCollectionAction(detail)
                    if !isOwnPlaylist, account.isLoggedIn {
                        Button {
                            toggleSubscribe(detail)
                        } label: {
                            Image(systemName: detail.subscribed ? "checkmark" : "plus")
                                .frame(width: 30, height: 30)
                        }
                        .accessibilityLabel(detail.subscribed ? "取消收藏网易云歌单" : "收藏网易云歌单")
                    }
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .frame(maxWidth: 320)
        }
    }

    // MARK: - Regular (Desktop / iPad) Header

    private func regularHeader(_ detail: PlaylistDetail) -> some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: detail.coverImgUrl?.resizedImageURL(512))
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(isLikedList ? String(localized: "我喜欢的音乐") : String(localized: "歌单"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(detail.name)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                if let creator = detail.creator {
                    HStack(spacing: 6) {
                        CachedAsyncImage(url: creator.avatarUrl?.resizedImageURL(48), animated: false)
                            .frame(width: 18, height: 18)
                            .clipShape(Circle())
                        Text(creator.nickname)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("\(detail.trackCount) 首 · \(Formatters.playCount(detail.playCount)) 次播放 · 更新于 \(Formatters.date(fromMS: detail.updateTime))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = detail.description, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                actionRow(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private func actionRow(_ detail: PlaylistDetail) -> some View {
        HStack(spacing: 10) {
            Button {
                player.play(tracks: playable, source: .playlist(playlistID),
                            context: .playlist(id: playlistID, name: detail.name))
            } label: {
                Label("播放全部", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
            }
            .buttonStyle(.pressable)
            .disabled(playable.isEmpty)

            if isLikedList {
                Button {
                    startHeartbeat()
                } label: {
                    Label("心动模式", systemImage: "heart.circle")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            } else if !isOwnPlaylist, account.isLoggedIn {
                Button {
                    toggleSubscribe(detail)
                } label: {
                    Label(detail.subscribed ? String(localized: "已收藏") : String(localized: "收藏"),
                          systemImage: detail.subscribed ? "checkmark" : "plus")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.pressable)
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索歌单内歌曲", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 130)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.05), in: Capsule())
        }
    }

    @ViewBuilder
    private func localCollectionAction(_ detail: PlaylistDetail) -> some View {
        let existingID = localPlaylists.playlists.first(where: {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "netease", id: String(detail.id))
        })?.id
        if let existingID {
            NavigationLink(value: Destination.localPlaylist(existingID)) {
                Label("已在资料库", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        } else if model.hasCompleteTracks {
            Button {
                saveLocalPlaylist(detail, intent: .verifiedCompletePlaylist)
            } label: {
                Label("收藏到本地资料库", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(model.tracks.isEmpty)
        } else {
            Button {
                showLoadedSnapshotConfirmation = true
            } label: {
                Label("保存已加载歌曲", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(model.tracks.isEmpty)
            .confirmationDialog(
                "保存已加载歌曲？",
                isPresented: $showLoadedSnapshotConfirmation,
                titleVisibility: .visible
            ) {
                Button("保存已加载歌曲") {
                    saveLocalPlaylist(detail, intent: .loadedTracksSnapshot)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("网易云未提供可核验的完整歌曲 ID 序列或声明总数。保存内容仅包含当前已加载的 \(model.tracks.count) 首歌曲，可能不是完整歌单。")
            }
        }
    }

    private func saveLocalPlaylist(_ detail: PlaylistDetail, intent: CatalogPlaylistSaveIntent) {
        do {
            _ = try localPlaylists.saveCatalogPlaylist(
                source: "netease",
                playlistID: String(detail.id),
                name: detail.name,
                tracks: model.tracks,
                coverURL: detail.coverImgUrl,
                sourceName: "网易云",
                intent: intent,
                declaredTrackCount: intent == .verifiedCompletePlaylist && detail.trackCount > 0
                    ? detail.trackCount : nil
            )
        } catch {
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    private var playable: [Track] {
        if SettingsManager.shared.enableUnblock { return model.tracks }
        return model.tracks.filter {
            $0.playability(privilege: model.privileges[$0.id],
                           isLoggedIn: account.isLoggedIn,
                           vipType: account.vipType) == .playable
        }
    }

    private func startHeartbeat() {
        Task {
            guard let seed = playable.randomElement() else { return }
            do {
                let tracks = try await NeteaseAPI.intelligenceList(songID: seed.id, playlistID: playlistID)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(playlistID), context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func toggleSubscribe(_ detail: PlaylistDetail) {
        Task {
            do {
                try await NeteaseAPI.subscribePlaylist(id: detail.id, subscribe: !detail.subscribed)
                model.detail?.subscribed.toggle()
                await account.refreshLibrary()
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private var loadingHeader: some View {
        HStack(spacing: 24) {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(.primary.opacity(0.05))
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)).frame(width: 80, height: 14)
                RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.1)).frame(width: 220, height: 24)
                RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.06)).frame(width: 140, height: 12)
            }
            Spacer()
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, 16)
    }
}
