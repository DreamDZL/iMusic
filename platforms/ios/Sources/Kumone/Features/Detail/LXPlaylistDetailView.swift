import SwiftUI

@MainActor
final class LXPlaylistDetailViewModel: ObservableObject {
    typealias PlaylistLoader = @MainActor (LXCatalogPlatform, String) async throws -> LXPlaylistDetail

    @Published private(set) var detail: LXPlaylistDetail?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var generation = 0
    private var loadedIdentity: String?
    private let playlistLoader: PlaylistLoader

    init(playlistLoader: @escaping PlaylistLoader = { source, id in
        try await LXCatalogService.playlistDetail(source: source, id: id)
    }) {
        self.playlistLoader = playlistLoader
    }

    func load(source: LXCatalogPlatform, playlistID: String, force: Bool = false) async {
        generation += 1
        let requestGeneration = generation
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        let identity = "\(source.rawValue)|\(playlistID)"
        if loadedIdentity != identity {
            detail = nil
            errorMessage = nil
            loadedIdentity = identity
        }
        let cache = LXPlaylistDetailCache.shared
        if !force, let cached = cache.cached(source: source, id: playlistID) {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            if cached.detail.source == source, cached.detail.id == playlistID,
               cache.isFresh(cached) {
                detail = cached.detail
                errorMessage = nil
                isLoading = false
                return
            } else if cached.detail.source == source, cached.detail.id == playlistID {
                detail = cached.detail
                errorMessage = nil
            }
        }

        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await playlistLoader(source, playlistID)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            guard loaded.source == source, loaded.id == playlistID else {
                throw LXCatalogError.playlistIdentityMismatch
            }
            detail = loaded
            cache.save(loaded)
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return }
            // Keep a stale but valid detail page usable if the provider has a
            // temporary outage or changes its response envelope.
            if detail == nil || (error as? LXCatalogError) == .playlistIdentityMismatch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Detail page for an LX catalogue songlist. It never converts the ID to a
/// NetEase integer; the source and source-owned ID stay attached all the way
/// to the tracks and their User API resolver.
struct LXPlaylistDetailView: View {
    let source: LXCatalogPlatform
    let playlistID: String

    @StateObject private var model = LXPlaylistDetailViewModel()
    @EnvironmentObject private var player: PlayerService
    @StateObject private var localPlaylists = LocalPlaylistStore.shared
    @State private var showPartialSnapshotConfirmation = false

    private var savedPlaylistID: UUID? {
        guard let detail = model.detail else { return nil }
        return localPlaylists.playlists.first(where: {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: detail.source.rawValue, id: detail.id)
        })?.id
    }

    var body: some View {
        ScrollView {
            if model.isLoading && model.detail == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else if let errorMessage = model.errorMessage, model.detail == nil {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load(source: source, playlistID: playlistID, force: true) }
                }
                .frame(minHeight: 360)
            } else if let detail = model.detail {
                detailBody(detail)
            }
            PlayerClearanceSpacer()
        }
        .navigationTitle(model.detail?.name ?? "歌单")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(source.rawValue)|\(playlistID)") {
            await model.load(source: source, playlistID: playlistID)
        }
    }

    private func detailBody(_ detail: LXPlaylistDetail) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if let errorMessage = model.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await model.load(source: source, playlistID: playlistID, force: true) }
                }
                .frame(minHeight: 120)
            }

            HStack(alignment: .top, spacing: 16) {
                CachedAsyncImage(url: detail.coverURL?.resizedImageURL(512))
                    .frame(width: 142, height: 142)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(3)
                    Text([detail.source.displayName, detail.author].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(trackCountDescription(detail))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Layout.contentInset)

            catalogSaveButton(detail)
                .padding(.horizontal, Theme.Layout.contentInset)

            if let description = detail.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.horizontal, Theme.Layout.contentInset)
            }

            if detail.tracks.isEmpty {
                EmptyStateView(icon: "music.note.list", title: "歌单暂无歌曲")
                    .frame(minHeight: 240)
            } else {
                HStack {
                    Text("歌曲")
                        .font(.headline)
                    Spacer()
                    Button {
                        player.play(tracks: detail.tracks, source: .none,
                                    context: .recents)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, Theme.Layout.contentInset)

                TrackListView(tracks: detail.tracks)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            }
        }
        .padding(.vertical, Theme.Layout.contentInset)
    }

    @ViewBuilder
    private func catalogSaveButton(_ detail: LXPlaylistDetail) -> some View {
        if let savedPlaylistID {
            NavigationLink(value: Destination.localPlaylist(savedPlaylistID)) {
                Label("已在资料库", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        } else if detail.isTrackListComplete {
            Button {
                saveSnapshot(
                    detail,
                    intent: .verifiedCompletePlaylist,
                    declaredTrackCount: detail.declaredTrackCount
                )
            } label: {
                Label("收藏歌单", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(detail.tracks.isEmpty)
        } else {
            Button {
                showPartialSnapshotConfirmation = true
            } label: {
                Label("保存已加载歌曲", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(detail.tracks.isEmpty || detail.source == .aggregate)
            .confirmationDialog(
                "保存已加载歌曲？",
                isPresented: $showPartialSnapshotConfirmation,
                titleVisibility: .visible
            ) {
                Button("保存已加载歌曲") {
                    saveSnapshot(detail, intent: .loadedTracksSnapshot, declaredTrackCount: nil)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(partialSnapshotWarning(detail))
            }
        }
    }

    private func saveSnapshot(
        _ detail: LXPlaylistDetail,
        intent: CatalogPlaylistSaveIntent,
        declaredTrackCount: Int?
    ) {
        do {
            _ = try localPlaylists.saveCatalogPlaylist(
                source: detail.source.rawValue,
                playlistID: detail.id,
                name: detail.name,
                tracks: detail.tracks,
                coverURL: detail.coverURL,
                sourceName: detail.source.displayName,
                intent: intent,
                declaredTrackCount: declaredTrackCount
            )
        } catch {
            ToastCenter.shared.show(error.localizedDescription)
        }
    }

    private func trackCountDescription(_ detail: LXPlaylistDetail) -> String {
        if let declared = detail.declaredTrackCount, declared > 0 {
            return "\(detail.tracks.count) / \(declared) 首已加载"
        }
        return "\(detail.tracks.count) 首已加载 · 总数未知"
    }

    private func partialSnapshotWarning(_ detail: LXPlaylistDetail) -> String {
        let providerNote: String
        switch detail.source {
        case .kw:
            providerNote = "酷我当前详情请求最多取 1000 首。"
        case .mg:
            providerNote = "咪咕当前详情请求最多取 1000 首。"
        case .kg:
            providerNote = "酷狗公开详情没有可核对的权威总数。"
        case .tx:
            providerNote = "QQ 音乐本次接口返回数无法独立核实是否完整。"
        case .sd:
            providerNote = "汽水音乐没有提供可核对的权威总数。"
        case .wy, .aggregate:
            providerNote = ""
        }
        if let declared = detail.declaredTrackCount, declared != detail.tracks.count {
            return "平台声明 \(declared) 首，当前加载 \(detail.tracks.count) 首。\(providerNote)保存内容将是冻结的已加载歌曲快照，不包含未加载歌曲。"
        }
        return "此平台无法确认歌单是否已全部加载。\(providerNote)保存内容将是当前 \(detail.tracks.count) 首歌曲的冻结快照，可能不是完整歌单。"
    }
}
