import SwiftUI

struct LXSyncSettingsView: View {
    @StateObject private var sync = LXSyncService.shared
    @State private var showForgetConfirmation = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: sync.isConnected ? "checkmark.icloud.fill" : "icloud")
                        .font(.title2)
                        .foregroundStyle(sync.isConnected ? .green : Theme.accent)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(sync.statusMessage)
                            .font(.headline)
                        if let lastSyncAt = sync.lastSyncAt {
                            Text("上次同步：\(lastSyncAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("连接后会同步收藏与兼容歌单")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if sync.isConnecting {
                        ProgressView()
                    }
                }
                .padding(.vertical, 5)

                if let error = sync.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                TextField("https://music.example.com", text: $sync.endpoint)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
#endif
                    .disabled(!LXSyncService.permitsConnectionSettingsEditing(
                        isConnected: sync.isConnected,
                        isConnecting: sync.isConnecting
                    ))

                SecureField("连接码", text: $sync.connectionCode)
#if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
#endif
                    .disabled(!LXSyncService.permitsConnectionSettingsEditing(
                        isConnected: sync.isConnected,
                        isConnecting: sync.isConnecting
                    ))

                Button {
                    Task {
                        do { try await sync.syncNow() }
                        catch { /* The service publishes an actionable error. */ }
                    }
                } label: {
                    Label(
                        sync.isConnected ? "立即同步" : "连接并同步",
                        systemImage: sync.isConnected ? "arrow.triangle.2.circlepath" : "link"
                    )
                }
                .disabled(sync.isConnecting || sync.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if sync.isConnected {
                    Button("断开连接", role: .destructive) {
                        sync.disconnect()
                    }
                }
            } header: {
                Text("LX Sync Server")
            } footer: {
                Text(sync.isConnected || sync.isConnecting
                     ? "更换服务器地址或连接码前，请先断开当前连接。首次连接会合并本机歌单与服务器列表。"
                     : "填写你自行部署的 LX Sync Server 地址和连接码。连接局域网服务器时，请允许 iOS 访问本地网络。首次连接会合并本机歌单与服务器列表。")
            }

            Section {
                Label("我喜欢的音乐", systemImage: "heart.fill")
                Label("本地歌单、导入歌单及歌单内歌曲", systemImage: "music.note.list")
                Label("歌单名称、曲目顺序与来源标记", systemImage: "arrow.up.arrow.down")
                Text("QQ 音乐和网易云歌单导入后是本地副本；iMusic 的增删改只同步到 LX Sync，不会写回平台账号。LX Sync 不同步音源脚本，音源需要在每台设备分别导入。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("同步内容")
            }

            Section {
                Button("清除 LX Sync 连接信息", role: .destructive) {
                    showForgetConfirmation = true
                }
            } footer: {
                Text("仅删除本机保存的服务器地址与连接凭据；本机歌单和收藏会保留。")
            }
        }
        .navigationTitle("LX 多设备同步")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "清除 LX Sync 连接信息？",
            isPresented: $showForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("清除连接信息", role: .destructive) { sync.forgetServer() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机资料库不会被删除。")
        }
        .task {
            await sync.reconnectIfConfigured()
        }
    }
}
