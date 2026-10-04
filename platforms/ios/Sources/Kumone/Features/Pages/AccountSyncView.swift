import SwiftUI

/// Optional account page for platform account metadata, listening history, and
/// one-way playlist copies into iMusic's local library.
struct AccountSyncView: View {
    private enum Channel: String, CaseIterable, Identifiable {
        case netease
        case qq

        var id: String { rawValue }
        var title: String { self == .netease ? "网易云" : "QQ 音乐" }
    }

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var qqMusic: QQMusicSessionStore
    @StateObject private var syncStore = ListeningSyncStore.shared
    @StateObject private var qqPlaylists = QQMusicPlaylistSyncStore.shared

    @State private var selectedChannel: Channel = .netease
    @State private var showLogin = false
    @State private var isRefreshing = false
    @State private var refreshToken: UUID?
    @State private var records: [PlayRecordItem] = []
    @State private var recordsUserID: Int?
    @State private var recordsError: String?
    @State private var showPlaylistPicker = false
    @State private var showQQPlaylistPicker = false
    @State private var showQQLogin = false

    private var channelTaskID: String {
        selectedChannel == .netease
            ? "netease:\(account.isLoggedIn):\(account.profile?.userId ?? 0)"
            : "qq:\(qqMusic.isLoggedIn):\(qqMusic.sessionRevision)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("同步渠道", selection: $selectedChannel) {
                    ForEach(Channel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("accountSyncChannelPicker")

                sourceOnlyNotice

                switch selectedChannel {
                case .netease:
                    if account.isLoggedIn, let profile = account.profile {
                        profileCard(profile)
                        cloudPlaylistsCard
                        syncCard
                        recentRecords
                    } else {
                        accountLoginCard(channel: .netease)
                    }
                case .qq:
                    if qqMusic.isLoggedIn {
                        qqProfileCard
                        qqMusicPlaylistsCard
                    } else {
                        accountLoginCard(channel: .qq)
                    }
                }

                PlayerClearanceSpacer()
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.top, 12)
        }
        .navigationTitle("账号同步")
        .toolbar {
            if (selectedChannel == .netease && account.isLoggedIn)
                || (selectedChannel == .qq && qqMusic.isLoggedIn) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshSelectedChannel(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("刷新账号数据")
                }
            }
        }
        .onChange(of: account.profile?.userId) { _, userID in
            if recordsUserID != userID {
                records = []
                recordsError = nil
                recordsUserID = userID
            }
        }
        .task(id: channelTaskID) {
            await refreshSelectedChannel(force: false)
        }
        .sheet(isPresented: $showLogin) {
#if os(iOS)
            ProviderWebLoginSheet(provider: .netease) { cookie in
                try await account.signInFromWeb(cookieHeader: cookie)
            }
            .presentationDetents([.large])
#else
            NavigationStack {
                LoginSheet()
                    .navigationTitle("登录账号")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.large])
#endif
        }
        .sheet(isPresented: $showPlaylistPicker) {
            NavigationStack {
                RemotePlaylistPickerView()
                    .environmentObject(account)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showQQPlaylistPicker) {
            NavigationStack {
                QQMusicPlaylistPickerView()
                    .environmentObject(qqMusic)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showQQLogin) {
#if os(iOS)
            ProviderWebLoginSheet(provider: .qqMusic) { cookie in
                try await qqMusic.signIn(cookie: cookie)
            }
            .presentationDetents([.large])
#else
            QQMusicLoginSheet()
                .environmentObject(qqMusic)
                .presentationDetents([.large])
#endif
        }
    }

    private var sourceOnlyNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("账号资料与歌单同步", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
            Text("登录仅用于读取账号资料、歌单和播放记录；歌曲播放始终使用你启用的第三方音源。两个渠道分别管理，切换后只显示当前平台的数据。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func accountLoginCard(channel: Channel) -> some View {
        let providerName = channel == .netease ? "网易云音乐" : "QQ 音乐"
        let validating = channel == .qq && qqMusic.isValidatingStoredSession
        let validationMessage = channel == .qq ? qqMusic.sessionValidationMessage : nil
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("登录\(providerName)以开启同步")
                .font(.title3.weight(.semibold))
            Text("登录只用于同步账号信息和歌单，不会改变播放音源。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if validating {
                Label("正在验证已保存的登录状态…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if channel == .netease { showLogin = true }
                else { showQQLogin = true }
            } label: {
                Label("登录\(providerName)", systemImage: channel == .netease
                      ? "person.crop.circle.badge.checkmark" : "qrcode.viewfinder")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Theme.accentGradient, in: Capsule())
            }
            .buttonStyle(.pressable)
            .disabled(validating)
            .accessibilityIdentifier("accountLogin-\(channel.rawValue)")
            .frame(minHeight: 48)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var qqProfileCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(qqMusic.profileName ?? "QQ 音乐用户")
                    .font(.title3.weight(.semibold))
                Text(qqMusic.sessionValidationMessage == nil ? "账号状态已验证" : "歌单同步需要检查")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出", role: .destructive) { qqMusic.signOut() }
                .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func profileCard(_ profile: UserProfile) -> some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: profile.avatarUrl?.resizedImageURL(192)) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                Text(profile.nickname.isEmpty ? "已登录账号" : profile.nickname)
                    .font(.title3.weight(.semibold))
                Text("账号资料已同步")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("退出", role: .destructive) {
                Task { await account.logout(); records = [] }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("听歌同步", systemImage: "chart.bar.xaxis")
                .font(.headline)
            HStack(spacing: 10) {
                syncMetric(title: "本机已同步", value: syncStore.formattedDuration)
                syncMetric(title: "歌曲数", value: "\(syncStore.syncedTrackCount)")
                syncMetric(title: "状态", value: "已开启")
            }
            Text("播放歌曲达到有效时长后，iMusic 会把匹配到的歌曲播放记录和时长同步到账号。播放音频由已启用的第三方音源提供。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let date = syncStore.lastSyncedAt {
                Text("最近上报 " + RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("播放达到有效时长后会自动上报")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var cloudPlaylistsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("云端歌单", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                if account.isSyncingPlaylists {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("已获取 \(account.userPlaylists.count) 个歌单，包含我喜欢的音乐和收藏歌单。登录后会自动复制到本地；之后自动检查云端更新，并保留你在 iMusic 中的编辑。账号副本与 LX Sync 歌单分别管理。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if account.isSyncingAfterLogin {
                Label("正在将网易云歌单同步到本地…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let message = account.loginPlaylistSyncMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: account.lastPlaylistSyncAt == nil ? "clock" : "checkmark.circle.fill")
                    .foregroundStyle(account.lastPlaylistSyncAt == nil ? Color.secondary : Color.green)
                Text(lastPlaylistSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                    Button("刷新") {
                        Task { await refreshSelectedChannel(force: true) }
                }
                .font(.caption.weight(.semibold))
                .disabled(isRefreshing || account.isSyncingPlaylists)
            }

            Button {
                Task {
                    let report = await account.importSelectedPlaylists(Set(account.userPlaylists.map(\.id)))
                    ToastCenter.shared.show("新增 \(report.inserted) 个，更新 \(report.updated) 个，\(report.failed.count) 个未完成")
                }
            } label: {
                Label("立即同步网易云歌单", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRefreshing || account.isSyncingAfterLogin || account.isSyncingPlaylists || account.userPlaylists.isEmpty)

            Button {
                showPlaylistPicker = true
            } label: {
                Label("管理本地歌单副本", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(account.isSyncingAfterLogin || account.userPlaylists.isEmpty)

            if let error = account.lastPlaylistSyncError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var qqMusicPlaylistsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("云端歌单", systemImage: "music.note.list")
                    .font(.headline)
                Spacer()
                if qqPlaylists.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }

            if qqMusic.isLoggedIn {
                Text("已获取 \(qqPlaylists.playlists.count) 个歌单。包含我喜欢的音乐和收藏歌单。登录后会自动复制到本地；之后自动检查云端更新，并保留你在 iMusic 中的编辑。账号副本与 LX Sync 歌单分别管理。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if qqPlaylists.isSyncingAfterLogin {
                    Label("正在将 QQ 歌单同步到本地…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let message = qqPlaylists.lastLoginSyncMessage {
                    let hasIssue = message.contains("无法") || message.contains("失败")
                        || message.contains("警告") || message.contains("拒绝")
                        || message.contains("3a44") || message.contains("未能读取")
                    Label(message, systemImage: hasIssue ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(hasIssue ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if message.contains("重新登录") || message.contains("曲目凭据") {
                        Button("重新登录 QQ 音乐") { showQQLogin = true }
                            .font(.caption.weight(.semibold))
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: qqPlaylists.lastRefreshedAt == nil ? "clock" : "checkmark.circle.fill")
                        .foregroundStyle(qqPlaylists.lastRefreshedAt == nil ? Color.secondary : Color.green)
                    Text(qqPlaylists.lastRefreshedAt.map {
                        "上次刷新 " + RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now)
                    } ?? "尚未刷新 QQ 歌单")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("刷新") {
                        Task { await refreshSelectedChannel(force: true) }
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(qqPlaylists.isRefreshing || qqPlaylists.isImporting)
                }

                Button {
                    Task { await qqPlaylists.syncAfterLogin() }
                } label: {
                    HStack(spacing: 8) {
                        if qqPlaylists.isSyncingAfterLogin {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(qqPlaylists.isSyncingAfterLogin ? "正在同步 QQ 歌单…" : "立即同步 QQ 歌单")
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(qqPlaylists.isRefreshing || qqPlaylists.isImporting || qqPlaylists.isSyncingAfterLogin)

                Button {
                    showQQPlaylistPicker = true
                } label: {
                    Label("管理本地歌单副本", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(qqPlaylists.isRefreshing || qqPlaylists.playlists.isEmpty)

                if let error = qqPlaylists.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重新登录 QQ 音乐") { showQQLogin = true }
                            .font(.caption.weight(.semibold))
                    }
                }
                if let warning = qqPlaylists.warningMessage {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                if qqMusic.isValidatingStoredSession {
                    Label("正在验证 QQ 登录并读取歌单…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let validationMessage = qqMusic.sessionValidationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("登录 QQ 音乐后，可选择读取你创建或收藏的歌单并导入为本地副本。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showQQLogin = true
                } label: {
                    Label(qqMusic.isValidatingStoredSession ? "正在验证…" : "登录 QQ 音乐", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(qqMusic.isValidatingStoredSession)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var lastPlaylistSyncText: String {
        guard let date = account.lastPlaylistSyncAt else { return "尚未同步云端歌单" }
        return "上次同步 \(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now))"
    }

    private func syncMetric(title: String, value: String) -> some View {
        // The status metric is the short third label in this compact card.
        // Resolve its value from the server result instead of displaying a
        // permanent “enabled” state after a failed weblog request.
        let shownValue = title == "状态" ? syncStore.statusText : value
        return VStack(alignment: .leading, spacing: 5) {
            Text(shownValue)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recentRecords: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("最近播放", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
            }

            if let recordsError {
                Text(recordsError)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if (recordsUserID != account.profile?.userId || records.isEmpty) && !isRefreshing {
                Text("暂时没有播放记录。登录只用于同步账号信息，不会影响 LX 音源播放。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if recordsUserID == account.profile?.userId {
                TrackListView(tracks: records.map(\.song), style: .compact, source: .none, context: .recents)
            }
        }
    }

    private func refreshSelectedChannel(force: Bool) async {
        let channel = selectedChannel
        let taskID = channelTaskID
        let token = UUID()
        refreshToken = token
        isRefreshing = true
        defer { if refreshToken == token { isRefreshing = false } }

        switch channel {
        case .netease:
            guard account.isLoggedIn else { return }
            if recordsUserID != account.profile?.userId {
                records = []
                recordsUserID = account.profile?.userId
            }
            recordsError = nil
            await account.refreshForOpen(force: force)
            guard !Task.isCancelled, selectedChannel == channel, channelTaskID == taskID else { return }
            if account.isLoggedIn, let uid = account.profile?.userId {
                do {
                    let fetched = try await NeteaseAPI.playRecords(uid: uid, week: true)
                    guard !Task.isCancelled, selectedChannel == channel, channelTaskID == taskID,
                          refreshToken == token else { return }
                    recordsUserID = uid
                    records = fetched
                } catch {
                    guard !Task.isCancelled, selectedChannel == channel, channelTaskID == taskID,
                          refreshToken == token else { return }
                    recordsError = "播放记录暂时无法获取，稍后可重试。"
                }
            } else {
                recordsError = "账号状态已失效，请重新登录后再试。"
            }
        case .qq:
            guard qqMusic.isLoggedIn else { return }
            await qqPlaylists.refresh(force: force)
            guard !Task.isCancelled, selectedChannel == channel, channelTaskID == taskID else { return }
            await qqPlaylists.syncAfterLogin()
        }
    }

}

/// Shows the account's created and collected QQ playlists as read-only source
/// rows. Import creates a local copy; the app never sends playlist edits back.
struct QQMusicPlaylistPickerView: View {
    @StateObject private var playlists = QQMusicPlaylistSyncStore.shared
    @StateObject private var localPlaylists = LocalPlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<String>()
    @State private var importErrors: [String] = []
    @State private var importTask: Task<Void, Never>?
    @State private var overwriteCandidateID: String?
    @State private var showOverwriteConfirmation = false

    private var likedPlaylists: [QQMusicAPI.Playlist] {
        playlists.playlists.filter(\.isLikedSongs)
    }

    private var createdPlaylists: [QQMusicAPI.Playlist] {
        playlists.playlists.filter { $0.kind == .created && !$0.isLikedSongs }
    }

    private var collectedPlaylists: [QQMusicAPI.Playlist] {
        playlists.playlists.filter { $0.kind == .collected && !$0.isLikedSongs }
    }

    private var selectedPlaylists: [QQMusicAPI.Playlist] {
        playlists.playlists.filter { selectedIDs.contains($0.id) }
    }

    private var primaryActionTitle: String {
        let updateCount = selectedPlaylists.filter { playlists.canRefresh($0.id) }.count
        let importCount = selectedPlaylists.filter { !playlists.isImported($0.id) }.count
        if updateCount == 0 { return "导入 \(importCount)" }
        if importCount == 0 { return "更新 \(updateCount)" }
        return "导入 \(importCount) · 更新 \(updateCount)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("导入 QQ 音乐歌单", systemImage: "arrow.down.circle")
                            .font(.title3.weight(.semibold))
                        Spacer(minLength: 4)
                        Button("刷新列表") {
                            Task { await playlists.refresh(force: true) }
                        }
                        .font(.subheadline.weight(.medium))
                        .disabled(playlists.isRefreshing || playlists.isImporting)
                    }
                    Text("选中歌单可导入或更新未编辑的本地副本。对本地副本执行覆盖前会再次确认；任何操作都不会回写 QQ 账号，账号副本与 LX Sync 歌单分别管理。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                playlistSection("我喜欢的音乐", playlists: likedPlaylists)
                playlistSection("我创建的歌单", playlists: createdPlaylists)
                playlistSection("我收藏的歌单", playlists: collectedPlaylists)

                if let error = playlists.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !importErrors.isEmpty {
                    Label(importErrors.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if playlists.playlists.isEmpty && !playlists.isRefreshing {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "暂时没有可导入的歌单",
                        subtitle: "请刷新列表，或确认当前 QQ 账号中有可见歌单。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                }

                PlayerClearanceSpacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("QQ 歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if playlists.isImporting {
                    Button("停止导入", role: .destructive) { importTask?.cancel() }
                } else {
                    Button("取消") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    importSelected()
                } label: {
                    if playlists.isImporting {
                        ProgressView()
                    } else {
                        Text(primaryActionTitle)
                    }
                }
                .disabled(playlists.isImporting || selectedActionCount == 0)
            }
        }
        .interactiveDismissDisabled(playlists.isImporting)
        .onChange(of: playlists.playlists.map(\.id)) { _, currentIDs in
            selectedIDs.formIntersection(Set(currentIDs))
        }
        .onChange(of: localPlaylists.playlists) { _, currentCopies in
            selectedIDs = Set(selectedIDs.filter { id in
                guard let copy = currentCopies.first(where: {
                    LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: id)
                }) else { return true }
                return LocalPlaylistSyncPolicy.canRefreshProviderPlaylist(copy, source: "qq", id: id)
            })
        }
        .task {
            if playlists.playlists.isEmpty { await playlists.refresh() }
        }
        .alert("从 QQ 更新这个本地副本？", isPresented: $showOverwriteConfirmation) {
            Button("覆盖并更新", role: .destructive) {
                guard let id = overwriteCandidateID else { return }
                overwriteCandidateID = nil
                guard let snapshot = localPlaylists.playlists.first(where: {
                    LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: id)
                }) else {
                    ToastCenter.shared.show("本地副本已变化，请重新选择")
                    return
                }
                performImport(
                    ids: [id],
                    overwriteEdited: [id],
                    overwriteSnapshots: [id: snapshot],
                    dismissOnSuccess: false
                )
            }
            Button("取消", role: .cancel) { overwriteCandidateID = nil }
        } message: {
            Text("本地歌单可能包含 iMusic 上的更改。确认后，歌曲、名称和封面会替换为 QQ 当前版本；不会修改 QQ 账号。")
        }
    }

    private var selectedActionCount: Int {
        selectedPlaylists.filter { !playlists.isImported($0.id) || playlists.canRefresh($0.id) }.count
    }

    @ViewBuilder
    private func playlistSection(_ title: String, playlists items: [QQMusicAPI.Playlist]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                LazyVStack(spacing: 8) {
                    ForEach(items) { playlist in playlistRow(playlist) }
                }
            }
        }
    }

    private func playlistRow(_ playlist: QQMusicAPI.Playlist) -> some View {
        let localCopy = localPlaylists.playlists.first(where: {
            LocalPlaylistSyncPolicy.matchesProviderPlaylist($0, source: "qq", id: playlist.id)
        })
        let isImported = localCopy != nil
        let canRefresh = localCopy.map {
            LocalPlaylistSyncPolicy.canRefreshProviderPlaylist($0, source: "qq", id: playlist.id)
        } ?? false
        let isSelected = selectedIDs.contains(playlist.id)

        return Button {
            guard !playlists.isImporting else { return }
            if isImported && !canRefresh {
                overwriteCandidateID = playlist.id
                showOverwriteConfirmation = true
                return
            }
            if isSelected { selectedIDs.remove(playlist.id) }
            else { selectedIDs.insert(playlist.id) }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(128), animated: false) {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 52, height: 52)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(playlist.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isImported {
                            Text(canRefresh ? "已加入 · 可更新" : "本地副本 · 需确认覆盖")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(playlist.trackCount) 首 · \(playlist.creatorName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Image(systemName: isSelected
                      ? "checkmark.circle.fill"
                      : (isImported ? (canRefresh ? "arrow.clockwise.circle" : "arrow.counterclockwise.circle") : "circle"))
                    .font(.title3)
                    .foregroundStyle(isSelected || (isImported && canRefresh) ? Theme.accent : Color.secondary)
                    .frame(width: 44, height: 44)
            }
            .padding(10)
            .background(
                isSelected || (isImported && canRefresh) ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(playlists.isImporting)
        .accessibilityLabel("\(playlist.name)，\(isImported ? (canRefresh ? "已加入，可更新本地副本" : "本地副本，点按后确认覆盖更新") : (isSelected ? "已选择导入" : "未选择"))")
    }

    private func importSelected() {
        guard importTask == nil else { return }
        let actionIDs = Set(selectedPlaylists.compactMap { playlist in
            !playlists.isImported(playlist.id) || playlists.canRefresh(playlist.id)
                ? playlist.id
                : nil
        })
        guard !actionIDs.isEmpty else {
            ToastCenter.shared.show("当前没有可导入或更新的歌单，请刷新列表后重试")
            return
        }
        performImport(
            ids: actionIDs,
            overwriteEdited: [],
            overwriteSnapshots: [:],
            dismissOnSuccess: true
        )
    }

    private func performImport(
        ids: Set<String>,
        overwriteEdited: Set<String>,
        overwriteSnapshots: [String: LocalPlaylist],
        dismissOnSuccess: Bool
    ) {
        guard importTask == nil else { return }
        importTask = Task { @MainActor in
            defer { importTask = nil }
            let report = await playlists.importSelected(
                ids,
                overwriteEdited: overwriteEdited,
                overwriteSnapshots: overwriteSnapshots
            )
            if report.failed.isEmpty {
                guard report.changedCount > 0 || report.unchanged > 0 else {
                    importErrors = ["当前没有可导入或更新的歌单，请刷新列表后重试"]
                    return
                }
                importErrors = []
                ToastCenter.shared.show("新增 \(report.inserted) 个，更新 \(report.updated) 个，未变化 \(report.unchanged) 个")
                if dismissOnSuccess { dismiss() }
            } else {
                importErrors = report.failed
                ToastCenter.shared.show("新增 \(report.inserted) 个，更新 \(report.updated) 个，未变化 \(report.unchanged) 个，\(report.failed.count) 个未完成")
                selectedIDs = selectedIDs.filter { !playlists.isImported($0) || playlists.canRefresh($0) }
            }
        }
    }
}

/// Lets the user retry a one-way copy of cloud playlists into the local page.
/// Login already imports all visible playlists; this screen is for manual
/// retries. The source is provider-specific and never writes back to the
/// platform account.
struct RemotePlaylistPickerView: View {
    @EnvironmentObject private var account: AccountStore
    @StateObject private var localPlaylists = LocalPlaylistStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs = Set<Int>()
    @State private var isImporting = false

    private var likedPlaylists: [PlaylistSummary] {
        account.userPlaylists.filter(\.isLikedSongsList)
    }

    private var createdPlaylists: [PlaylistSummary] {
        account.createdPlaylists
    }

    private var subscribedPlaylists: [PlaylistSummary] {
        account.subscribedPlaylists
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("重新同步网易云歌单", systemImage: "arrow.down.circle")
                        .font(.title3.weight(.semibold))
                    Text("登录时已自动复制账号中的歌单。这里可以手动重试；你在 iMusic 修改过的本地歌单会保留，不会被云端覆盖。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                playlistSection("我喜欢的音乐", playlists: likedPlaylists)
                playlistSection("我的歌单", playlists: createdPlaylists)
                playlistSection("收藏的歌单", playlists: subscribedPlaylists)

                if account.userPlaylists.isEmpty {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "暂时没有云端歌单",
                        subtitle: "请先刷新账号数据，或确认当前账号有可见歌单。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                }

                PlayerClearanceSpacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("同步歌单")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    importSelected()
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Text("添加 \(selectedIDs.count)")
                    }
                }
                .disabled(isImporting || selectedIDs.isEmpty)
            }
        }
        .task {
            selectedIDs = Set(account.userPlaylists.filter {
                localPlaylists.containsRemotePlaylist(source: "netease", id: $0.id)
            }.map(\.id))
        }
    }

    @ViewBuilder
    private func playlistSection(_ title: String, playlists: [PlaylistSummary]) -> some View {
        if !playlists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                VStack(spacing: 8) {
                    ForEach(playlists) { playlist in
                        playlistRow(playlist)
                    }
                }
            }
        }
    }

    private func playlistRow(_ playlist: PlaylistSummary) -> some View {
        let isSelected = selectedIDs.contains(playlist.id)
        let isImported = localPlaylists.containsRemotePlaylist(source: "netease", id: playlist.id)

        return Button {
            if isSelected {
                selectedIDs.remove(playlist.id)
            } else {
                selectedIDs.insert(playlist.id)
            }
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: playlist.coverURL?.resizedImageURL(128), animated: false)
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(playlist.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isImported {
                            Text("已加入")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(playlist.trackCount) 首 · \(playlist.creator?.nickname ?? "云端歌单")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                    .frame(width: 44, height: 44)
            }
            .padding(10)
            .background(
                isSelected ? Theme.accent.opacity(0.10) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(playlist.name)，\(isSelected ? "已选择" : "未选择")")
    }

    private func importSelected() {
        isImporting = true
        Task {
            let report = await account.importSelectedPlaylists(selectedIDs)
            isImporting = false
            if report.failed.isEmpty {
                ToastCenter.shared.show("已添加 \(report.changedCount) 个歌单，后续会自动同步更新")
                dismiss()
            } else {
                ToastCenter.shared.show("已完成部分同步，\(report.failed.count) 个歌单稍后重试")
                dismiss()
            }
        }
    }
}
