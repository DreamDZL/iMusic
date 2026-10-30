import SwiftUI
import UniformTypeIdentifiers

struct LocalPlaylistsView: View {
    @StateObject private var store = LocalPlaylistStore.shared
    @ObservedObject private var sync = LXSyncService.shared
    @State private var showImport = false
    @State private var showCreate = false
    @State private var showSourceManager = false
    @State private var showReorderPlaylists = false
    @State private var isSelectingPlaylists = false
    @State private var selectedPlaylistIDs = Set<UUID>()
    @State private var showDeleteSelectedPlaylists = false
    @State private var newName = ""

    var body: some View {
        List {
            // One block of plain navigation rows with accent glyphs, as in
            // the system library. The page title already says 资料库, so the
            // block has no second "资料库" header.
            Section {
                NavigationLink(value: Destination.likedSongs) {
                    libraryRowLabel("我喜欢的音乐", icon: "star", detail: favoriteCountText)
                }
                .accessibilityIdentifier("libraryLikedSongs")
                .accessibilityLabel("我喜欢的音乐，\(likedSongsSubtitle)")
                libraryNavigationRow("最近播放", icon: "clock", destination: .recents)
                libraryNavigationRow("我的收藏", icon: "square.stack", destination: .collections)
                NavigationLink {
                    LXSyncSettingsView()
                } label: {
                    libraryRowLabel("同步资料库", icon: "arrow.triangle.2.circlepath", detail: nil) {
                        HStack(spacing: 5) {
                            if sync.isConnected {
                                Circle().fill(.green).frame(width: 7, height: 7)
                            }
                            Text(sync.statusMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .accessibilityIdentifier("librarySyncEntry")
            }
            .listSectionSeparator(.hidden, edges: .top)

            if !store.playlists.isEmpty || !isSelectingPlaylists {
                Section {
                    if store.playlists.isEmpty {
                        ContentUnavailableView {
                            Label("还没有播放列表", systemImage: "music.note.list")
                        } description: {
                            Text("创建播放列表，或导入你有权访问的公开歌单。")
                        } actions: {
                            Button("导入歌单") { showImport = true }
                                .buttonStyle(.borderedProminent)
                            Button("新建播放列表") { showCreate = true }
                        }
                        .listRowBackground(Color.clear)
                    }

                    ForEach(store.playlists) { playlist in
                        if isSelectingPlaylists {
                            Button {
                                togglePlaylistSelection(playlist.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedPlaylistIDs.contains(playlist.id)
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedPlaylistIDs.contains(playlist.id) ? Theme.accent : .secondary)
                                    playlistListRow(playlist)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(playlist.name)，\(selectedPlaylistIDs.contains(playlist.id) ? "已选择" : "未选择")")
                        } else {
                            NavigationLink(value: Destination.localPlaylist(playlist.id)) {
                                playlistListRow(playlist)
                            }
                            .contextMenu {
                                ShareLink(item: store.exportText(playlist)) {
                                    Label("导出歌单", systemImage: "square.and.arrow.up")
                                }
                                Button("删除歌单", role: .destructive) { store.delete(id: playlist.id) }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { store.delete(id: playlist.id) } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        store.movePlaylists(fromOffsets: offsets, toOffset: destination)
                    }
                } header: {
                    Text("我的播放列表")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .padding(.top, 14)
                        .padding(.bottom, 2)
                }
            }
        }
        .listStyle(.plain)
        .tint(Theme.accent)
        .navigationTitle("资料库")
#if os(iOS)
        .refreshable {
            let sync = LXSyncService.shared
            guard !sync.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do {
                try await sync.refreshFromServer()
            } catch {
                // LXSyncService publishes connection/sync errors for the sync
                // screen; keep the pull gesture itself from surfacing a
                // duplicate SwiftUI error presentation.
            }
        }
#endif
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelectingPlaylists {
                    Button("完成") {
                        isSelectingPlaylists = false
                        selectedPlaylistIDs.removeAll()
                    }
                } else {
                    Button("编辑") { isSelectingPlaylists = true }
                        .disabled(store.playlists.isEmpty)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isSelectingPlaylists {
                    Button(allPlaylistsSelected ? "取消全选" : "全选") {
                        if allPlaylistsSelected {
                            selectedPlaylistIDs.removeAll()
                        } else {
                            selectedPlaylistIDs = Set(store.playlists.map(\.id))
                        }
                    }
                    Button("删除 \(selectedExistingPlaylistIDs.count)", role: .destructive) {
                        showDeleteSelectedPlaylists = true
                    }
                    .disabled(selectedExistingPlaylistIDs.isEmpty)
                } else {
                    Menu {
                        Button {
                            showReorderPlaylists = true
                        } label: {
                            Label("调整歌单顺序", systemImage: "line.3.horizontal")
                        }
                        Button {
                            isSelectingPlaylists = true
                        } label: {
                            Label("批量删除歌单", systemImage: "checklist")
                        }
                        .disabled(store.playlists.isEmpty)
                        Button {
                            showImport = true
                        } label: {
                            Label("导入歌单", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showSourceManager = true
                        } label: {
                            Label("管理 LX 音源", systemImage: "waveform.badge.plus")
                        }
                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    } label: {
                        // Plain glyph; the toolbar glass already draws the circle.
                        Image(systemName: "ellipsis")
                            .accessibilityLabel("更多资料库选项")
                    }
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("新建播放列表")
                    }
                }
            }
        }
        .sheet(isPresented: $showSourceManager) {
            NavigationStack {
                LXSourceManagerView()
            }
        }
        .sheet(isPresented: $showReorderPlaylists) {
            ReorderLocalPlaylistsSheet()
        }
        .sheet(isPresented: $showImport) {
            ImportPlaylistSheet()
        }
        .alert("新建本地歌单", isPresented: $showCreate) {
            TextField("歌单名称", text: $newName)
            Button("创建") {
                _ = store.create(name: newName)
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            "删除选中的 \(selectedExistingPlaylistIDs.count) 个歌单？",
            isPresented: $showDeleteSelectedPlaylists,
            titleVisibility: .visible
        ) {
            Button("删除歌单", role: .destructive) {
                store.delete(ids: selectedExistingPlaylistIDs)
                selectedPlaylistIDs.removeAll()
                isSelectingPlaylists = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些歌单将从 iMusic 资料库中移除。")
        }
    }

    private func libraryNavigationRow(
        _ title: LocalizedStringKey,
        icon: String,
        destination: Destination
    ) -> some View {
        NavigationLink(value: destination) {
            libraryRowLabel(title, icon: icon, detail: nil)
        }
    }

    private func libraryRowLabel(
        _ title: LocalizedStringKey,
        icon: String,
        detail: String?
    ) -> some View {
        libraryRowLabel(title, icon: icon, detail: detail) { EmptyView() }
    }

    /// Library row: fixed-width accent glyph, title in body type, optional
    /// trailing detail (count or status) in secondary text.
    private func libraryRowLabel<Trailing: View>(
        _ title: LocalizedStringKey,
        icon: String,
        detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(title)
                .font(.title3)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            trailing()
        }
        .frame(minHeight: 44)
    }

    private var favoriteCountText: String? {
        store.favoriteTracks.isEmpty ? nil : "\(store.favoriteTracks.count)"
    }

    private func playlistListRow(_ playlist: LocalPlaylist) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(160), animated: false)
                .frame(width: 56, height: 56)
                .background(.quaternary.opacity(0.6))
                .overlay {
                    if playlist.coverURL == nil {
                        Image(systemName: "music.note.list")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body).lineLimit(1)
                Text(["\(playlist.tracks.count) 首歌曲", playlist.sourceName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var libraryShortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                libraryShortcut("最近播放", icon: "clock.arrow.circlepath", destination: .recents)
                libraryShortcut("我的收藏", icon: "square.grid.2x2", destination: .collections)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func libraryShortcut(
        _ title: String,
        icon: String,
        destination: Destination
    ) -> some View {
        NavigationLink(value: destination) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: 42)
                .compatGlass(interactive: true, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var likedSongsRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "star.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text("我喜欢的音乐")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(likedSongsSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, Theme.Layout.contentInset)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("我喜欢的音乐，\(likedSongsSubtitle)")
    }

    private var likedSongsSubtitle: String {
        let count = store.favoriteTracks.count
        return count == 0 ? "收藏的歌曲会保存在这里" : "\(count) 首歌曲 · 可通过 LX Sync 同步"
    }

    private var allPlaylistsSelected: Bool {
        !currentPlaylistIDs.isEmpty && currentPlaylistIDs.isSubset(of: selectedPlaylistIDs)
    }

    private var currentPlaylistIDs: Set<UUID> {
        Set(store.playlists.map(\.id))
    }

    private var selectedExistingPlaylistIDs: Set<UUID> {
        selectedPlaylistIDs.intersection(currentPlaylistIDs)
    }

    private func togglePlaylistSelection(_ id: UUID) {
        if selectedPlaylistIDs.contains(id) {
            selectedPlaylistIDs.remove(id)
        } else {
            selectedPlaylistIDs.insert(id)
        }
    }

    private func playlistRow(_ playlist: LocalPlaylist, showsChevron: Bool = true) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(160), animated: false)
                .frame(width: 68, height: 68)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    if playlist.coverURL == nil {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(["\(playlist.tracks.count) 首", playlist.sourceName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct LikedSongsView: View {
    @StateObject private var store = LocalPlaylistStore.shared
    @ObservedObject private var qqSession = QQMusicSessionStore.shared
    @ObservedObject private var qqPlaylists = QQMusicPlaylistSyncStore.shared
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openLogin) private var openLogin
    @State private var query = ""
    @State private var isImportingAccountFavorites = false
    @State private var isImportingQQFavorites = false
    @State private var isSelectingFavorites = false
    @State private var selectedFavoriteKeys = Set<String>()

    private var visibleTracks: [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.favoriteTracks }
        return store.favoriteTracks.filter { track in
            track.name.localizedCaseInsensitiveContains(query)
                || track.artistNames.localizedCaseInsensitiveContains(query)
                || track.album.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CollectionHeader(
                    title: String(localized: "我喜欢的音乐"),
                    curator: String(localized: "iMusic 资料库"),
                    detail: isImportingAccountFavorites || isImportingQQFavorites
                        ? String(localized: "正在导入账号收藏…")
                        : nil,
                    description: String(localized: "账号收藏会复制到 iMusic 资料库；在这里的收藏和删除不会写回网易云或 QQ 音乐。"),
                    playDisabled: visibleTracks.isEmpty,
                    onPlay: { player.play(tracks: visibleTracks, source: .none) },
                    onShuffle: { player.playShuffled(tracks: visibleTracks, source: .none) }
                ) {
                    LinearGradient(
                        colors: [Theme.accent, Theme.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.system(size: 88, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                }

                if store.favoriteTracks.isEmpty {
                    EmptyStateView(
                        icon: "star",
                        title: "还没有收藏歌曲",
                        subtitle: "在播放器或歌曲菜单中点按收藏按钮，即可将歌曲加入资料库"
                    )
                    .frame(minHeight: 260)
                } else {
                    if visibleTracks.isEmpty {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "没有匹配的歌曲",
                            subtitle: "试试搜索歌曲名、歌手或专辑"
                        )
                        .frame(minHeight: 220)
                    } else {
                        TrackListView(
                            tracks: visibleTracks,
                            source: .none,
                            selectedTrackKeys: isSelectingFavorites ? $selectedFavoriteKeys : nil
                        )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }
                }

                PlayerClearanceSpacer()
            }
            .padding(.top, 14)
        }
        .navigationTitle("我喜欢的音乐")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.favoriteTracks.isEmpty {
                    Button {
                        isSelectingFavorites.toggle()
                        if !isSelectingFavorites { selectedFavoriteKeys.removeAll() }
                    } label: {
                        Label(isSelectingFavorites ? "完成选择" : "选择歌曲",
                              systemImage: isSelectingFavorites ? "checkmark" : "checklist")
                    }
                }
                if isSelectingFavorites, !visibleTracks.isEmpty {
                    let keys = Set(visibleTracks.map(\.playbackKey))
                    let allSelected = keys.isSubset(of: selectedFavoriteKeys)
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected { selectedFavoriteKeys.subtract(keys) }
                        else { selectedFavoriteKeys.formUnion(keys) }
                    }
                    .accessibilityIdentifier("favoriteSelectAll")
                }
                if isSelectingFavorites, !selectedFavoriteKeys.isEmpty {
                    Button(role: .destructive) {
                        store.removeFavorites(playbackKeys: selectedFavoriteKeys)
                        selectedFavoriteKeys.removeAll()
                        isSelectingFavorites = false
                    } label: {
                        Label("删除所选（\(selectedFavoriteKeys.count)）", systemImage: "trash")
                    }
                }
                if !isSelectingFavorites {
                    // Account imports are occasional maintenance actions, so
                    // they move off the page body into one toolbar menu.
                    Menu {
                        Button(action: importAccountFavorites) {
                            Label("从网易云导入红心", systemImage: "icloud.and.arrow.down")
                        }
                        .disabled(isImportingAccountFavorites)
                        Button(action: importQQFavorites) {
                            Label("从 QQ 音乐导入收藏", systemImage: "arrow.down.circle")
                        }
                        .disabled(isImportingQQFavorites || qqPlaylists.isImporting)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("导入账号收藏")
                }
            }
        }
        .searchable(text: $query, prompt: "搜索收藏歌曲")
    }

    private func importAccountFavorites() {
        guard !isImportingAccountFavorites else { return }
        guard account.hasAuthCookie else {
            openLogin()
            return
        }
        isImportingAccountFavorites = true
        Task {
            defer { isImportingAccountFavorites = false }
            do {
                let report = try await account.importLikedSongsToLocalLibrary()
                ToastCenter.shared.show("已检查网易云红心 \(report.remoteCount) 首，新增 \(report.addedCount) 首")
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    private func importQQFavorites() {
        guard !isImportingQQFavorites else { return }
        guard qqSession.isLoggedIn else {
            openLogin()
            return
        }
        isImportingQQFavorites = true
        Task {
            defer { isImportingQQFavorites = false }
            do {
                let report = try await qqPlaylists.importLikedSongsToLocalLibrary()
                ToastCenter.shared.show("已检查 QQ 收藏 \(report.remoteCount) 首，新增 \(report.addedCount) 首")
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

}

struct ImportPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = LocalPlaylistStore.shared
    @State private var input = ""
    @State private var isImporting = false
    @State private var showFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("粘贴歌单") {
                    TextEditor(text: $input)
                        .frame(minHeight: 180)
                        .font(.body)
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty {
                                Text("粘贴任意支持平台的歌单链接，或粘贴包含链接的整段文字。也支持其他音乐软件导出的歌单 JSON；网易云、QQ、酷狗、酷我和咪咕歌曲会保留原平台标识，并由已选 LX 音源负责播放。")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.trailing, 8)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                Section("汽水音乐") {
                    Text("仅支持导入汽水音乐公开歌单。导入会读取完整曲目列表；播放、歌词和音质统一交给你已启用的 LX 音源，不再调用内置汽水播放接口。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("选择 JSON / 文本文件", systemImage: "doc.badge.plus")
                    }
                    .frame(minHeight: 44)
                    Button {
                        importPlaylist()
                    } label: {
                        HStack {
                            Text(isImporting ? "正在导入…" : "开始导入")
                            Spacer()
                            if isImporting { ProgressView() }
                        }
                    }
                    .disabled(isImporting || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .frame(minHeight: 44)
                }

                Section("说明") {
                    Text("歌单只保存到本机，不会修改原音乐软件。支持网易云、QQ、酷狗、酷我和咪咕的公开歌单链接，也支持从分享文本中自动识别链接及导入 JSON。在线目录只读取公开信息，实际播放仍使用你自己添加的 LX 音源。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle("导入歌单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    input = try readTextFile(at: url)
                } catch {
                    errorMessage = "读取文件失败：\(error.localizedDescription)"
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func importPlaylist() {
        isImporting = true
        Task {
            do {
                _ = try await store.importPlaylist(from: input)
                isImporting = false
                dismiss()
            } catch {
                isImporting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func readTextFile(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian,
                         .utf16BigEndian, .utf32, .utf32LittleEndian,
                         .utf32BigEndian, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}

struct LocalPlaylistDetailView: View {
    let playlistID: UUID

    @StateObject private var store = LocalPlaylistStore.shared
    @EnvironmentObject private var player: PlayerService
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showAddTracks = false
    @State private var showReorderTracks = false
    @State private var playlistQuery = ""
    @State private var isSelectingTracks = false
    @State private var selectedTrackKeys = Set<String>()
    var body: some View {
        ScrollView {
            if let playlist = store.playlist(id: playlistID) {
                VStack(alignment: .leading, spacing: 18) {
                    CollectionHeader(
                        title: playlist.name,
                        curator: playlist.sourceName ?? String(localized: "iMusic 资料库"),
                        detail: playlist.updatedAt.map {
                            "更新于 \($0.formatted(date: .abbreviated, time: .omitted))"
                        },
                        playDisabled: playlist.tracks.isEmpty,
                        onPlay: { player.play(tracks: playlist.tracks, source: .none) },
                        onShuffle: { player.playShuffled(tracks: playlist.tracks, source: .none) }
                    ) {
                        CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(600))
                            .overlay {
                                if playlist.coverURL == nil {
                                    Image(systemName: "music.note.list")
                                        .font(.system(size: 56, weight: .light))
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }

                    if playlist.tracks.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "歌单暂无歌曲")
                            .frame(minHeight: 260)
                    } else {
                        TrackListView(
                            tracks: filteredTracks(playlist.tracks),
                            source: .none,
                            onRemoved: { track in
                                store.remove(track, from: playlistID)
                                selectedTrackKeys.remove(track.playbackKey)
                            },
                            selectedTrackKeys: isSelectingTracks ? $selectedTrackKeys : nil
                        )
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                    }
                }
                .padding(.vertical, Theme.Layout.contentInset)
            } else {
                ErrorStateView(message: "歌单不存在") {}
                    .frame(minHeight: 360)
            }
            PlayerClearanceSpacer()
        }
        .navigationTitle(store.playlist(id: playlistID)?.name ?? "歌单")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isSelectingTracks.toggle()
                    if !isSelectingTracks { selectedTrackKeys.removeAll() }
                } label: {
                    Label(isSelectingTracks ? "完成选择" : "选择歌曲",
                          systemImage: isSelectingTracks ? "checkmark" : "checklist")
                }
                if isSelectingTracks, let playlist = store.playlist(id: playlistID) {
                    let keys = Set(filteredTracks(playlist.tracks).map(\.playbackKey))
                    let allSelected = !keys.isEmpty && keys.isSubset(of: selectedTrackKeys)
                    Button(allSelected ? "取消全选" : "全选") {
                        if allSelected { selectedTrackKeys.subtract(keys) }
                        else { selectedTrackKeys.formUnion(keys) }
                    }
                    .disabled(keys.isEmpty)
                    .accessibilityIdentifier("playlistSelectAll")
                }
                if isSelectingTracks, let playlist = store.playlist(id: playlistID), !selectedTrackKeys.isEmpty {
                    Button {
                        showAddTracks = true
                    } label: {
                        Label("加入歌单", systemImage: "text.badge.plus")
                    }
                    Button(role: .destructive) {
                        store.remove(selectedTracks(from: playlist), from: playlistID)
                        selectedTrackKeys.removeAll()
                        isSelectingTracks = false
                    } label: {
                        Label("删除所选", systemImage: "trash")
                    }
                }
                if !isSelectingTracks, let playlist = store.playlist(id: playlistID) {
                    // One "⋯" menu instead of a row of five toolbar glyphs.
                    Menu {
                        if !playlist.tracks.isEmpty {
                            Button {
                                showAddTracks = true
                            } label: {
                                Label("添加到歌单", systemImage: "text.badge.plus")
                            }
                            Button {
                                showReorderTracks = true
                            } label: {
                                Label("调整歌曲顺序", systemImage: "line.3.horizontal")
                            }
                        }
                        ShareLink(item: store.exportText(playlist)) {
                            Label("导出歌单", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            renameText = playlist.name
                            showRename = true
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            store.delete(id: playlistID)
                        } label: {
                            Label("删除歌单", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("歌单选项")
                }
            }
        }
        .alert("重命名歌单", isPresented: $showRename) {
            TextField("歌单名称", text: $renameText)
            Button("保存") { store.rename(id: playlistID, name: renameText) }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showAddTracks) {
            if let playlist = store.playlist(id: playlistID) {
                let tracks = selectedTracks(from: playlist)
                AddToPlaylistSheet(tracks: tracks.isEmpty ? playlist.tracks : tracks)
            }
        }
        .sheet(isPresented: $showReorderTracks) {
            ReorderLocalTracksSheet(playlistID: playlistID)
        }
        .searchable(text: $playlistQuery, prompt: "搜索此歌单")
    }

    private func filteredTracks(_ tracks: [Track]) -> [Track] {
        let query = playlistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter { track in
            track.name.localizedCaseInsensitiveContains(query)
                || track.artistNames.localizedCaseInsensitiveContains(query)
                || track.album.name.localizedCaseInsensitiveContains(query)
        }
    }

    private func selectedTracks(from playlist: LocalPlaylist) -> [Track] {
        playlist.tracks.filter { selectedTrackKeys.contains($0.playbackKey) }
    }

}

private struct ReorderLocalPlaylistsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = LocalPlaylistStore.shared
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.playlists) { playlist in
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(128), animated: false)
                            .frame(width: 48, height: 48)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.name).font(.body.weight(.medium)).lineLimit(1)
                            Text("\(playlist.tracks.count) 首歌曲")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove(perform: store.movePlaylists)
                .onDelete { offsets in
                    for playlist in offsets.sorted(by: >).map({ store.playlists[$0] }) {
                        store.delete(id: playlist.id)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editMode)
            .navigationTitle("歌单顺序")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

private struct ReorderLocalTracksSheet: View {
    let playlistID: UUID

    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = LocalPlaylistStore.shared
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            Group {
                if let playlist = store.playlist(id: playlistID) {
                    List {
                        ForEach(playlist.tracks, id: \.playbackKey) { track in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.name).font(.body.weight(.medium)).lineLimit(1)
                                Text(track.artistNames).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .onMove { offsets, destination in
                            store.moveTracks(fromOffsets: offsets, toOffset: destination, in: playlistID)
                        }
                        .onDelete { offsets in
                            guard let playlist = store.playlist(id: playlistID) else { return }
                            store.remove(offsets.map { playlist.tracks[$0] }, from: playlistID)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, $editMode)
                } else {
                    EmptyStateView(icon: "music.note.list", title: "歌单不存在")
                }
            }
            .navigationTitle("歌曲顺序")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
