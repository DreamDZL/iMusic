import Combine
import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security
#if os(iOS)
import UIKit
#endif

private struct LXSyncKeyInfo: Codable {
    let clientId: String
    let key: String
    let serverName: String
}

private struct LXSyncAddress {
    let components: URLComponents

    init(_ rawValue: String) throws {
        guard let parsed = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              parsed.host != nil,
              parsed.user == nil,
              parsed.password == nil,
              parsed.query == nil,
              parsed.fragment == nil else {
            throw LXSyncError.invalidServerAddress
        }
        var normalized = parsed
        normalized.path = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components = normalized
    }

    func httpURL(_ path: String) throws -> URL {
        var result = components
        result.path = joinedPath(path)
        guard let url = result.url else { throw LXSyncError.invalidServerAddress }
        return url
    }

    func socketURL(clientID: String, encryptedTicket: String) throws -> URL {
        var result = components
        result.scheme = components.scheme == "https" ? "wss" : "ws"
        result.path = joinedPath("socket")
        result.queryItems = [
            URLQueryItem(name: "i", value: clientID),
            URLQueryItem(name: "t", value: encryptedTicket),
        ]
        guard let url = result.url else { throw LXSyncError.invalidServerAddress }
        return url
    }

    private func joinedPath(_ suffix: String) -> String {
        let prefix = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + ([prefix, suffix].filter { !$0.isEmpty }.joined(separator: "/"))
    }
}

private enum LXSyncError: LocalizedError {
    case invalidServerAddress
    case invalidConnectionCode
    case incompatibleServer(String)
    case authorizationFailed
    case invalidServerResponse
    case disconnected
    case connectionTimedOut
    case server(String)
    case temporaryServer(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress: return "请输入有效的 LX Sync Server 地址"
        case .invalidConnectionCode: return "请输入 LX Sync 连接码"
        case .incompatibleServer(let message): return message
        case .authorizationFailed: return "LX Sync 认证失败，请检查连接码和服务地址"
        case .invalidServerResponse: return "LX Sync Server 返回了无法识别的数据"
        case .disconnected: return "LX Sync 连接已断开"
        case .connectionTimedOut: return "LX Sync 连接超时，请检查服务器和网络"
        case .server(let message): return message
        case .temporaryServer(let message): return message
        }
    }
}

enum LXSyncReconnectPolicy {
    static func delaySeconds(attempt: Int) -> Double {
        min(pow(2.0, Double(max(attempt, 0))), 60.0)
    }

    static func isRetryableNetworkFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        (500..<600).contains(statusCode)
    }

    static func isRetryableSocketClose(_ closeCode: URLSessionWebSocketTask.CloseCode) -> Bool {
        switch closeCode {
        case .goingAway, .abnormalClosure, .internalServerError, .noStatusReceived:
            return true
        default:
            return false
        }
    }

    static func isRetryableSocketFailure(
        _ error: Error,
        closeCode: URLSessionWebSocketTask.CloseCode,
        responseStatusCode: Int?
    ) -> Bool {
        if let responseStatusCode, responseStatusCode != 101 {
            return isRetryableHTTPStatus(responseStatusCode)
        }
        if isRetryableSocketClose(closeCode) { return true }
        return closeCode == .invalid && isRetryableNetworkFailure(error)
    }

}

private enum LXSyncSecureStore {
    private static let service = "com.jiajia2222.imusic.lx-sync"

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    static func removeAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
    }
}

/// LX Sync Server's v4 list protocol client. It preserves the server's
/// `defaultList` while mapping iMusic local favorites and playlists to the
/// compatible `loveList` and `userList` fields.
@MainActor
final class LXSyncService: ObservableObject {
    static let shared = LXSyncService()

    @Published var endpoint: String {
        didSet {
            UserDefaults.standard.set(endpoint, forKey: Self.endpointKey)
            if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stopNetworkMonitor()
            }
        }
    }
    @Published var connectionCode = ""
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var statusMessage = "尚未连接"
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncAt: Date?

    private static let endpointKey = "imusic.lxSync.endpoint"
    private static let dataKey = "imusic.lxSync.listData.v1"
    private static let lastSyncKey = "imusic.lxSync.lastSyncAt"

    private var listData: LXSyncListData
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var pendingSnapshotTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var reconnectGeneration = 0
    private var connectionGeneration = 0
    private var activeSocketGeneration: Int?
    private var connectionTask: Task<Void, Error>?
    private var connectionTaskGeneration: Int?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var pendingCalls: [String: CheckedContinuation<Any?, Error>] = [:]
    private var applyingRemoteData = false
    private var keyInfo: LXSyncKeyInfo?
    private var serverID: String?
    private var libraryObserver: NSObjectProtocol?
    private var networkMonitor: NWPathMonitor?
    private var networkMonitorGeneration = 0
    private let networkQueue = DispatchQueue(label: "com.jiajia2222.imusic.lx-sync-network")
    private var hadNetworkPath: Bool?
    private var userRequestedDisconnect = false

    private init() {
        endpoint = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        lastSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        if let saved = UserDefaults.standard.data(forKey: Self.dataKey),
           let decoded = try? JSONDecoder().decode(LXSyncListData.self, from: saved) {
            listData = decoded
        } else {
            listData = LXSyncListData()
        }
        if let codeData = LXSyncSecureStore.load(account: "connection-code"),
           let code = String(data: codeData, encoding: .utf8) {
            connectionCode = code
        }
        libraryObserver = NotificationCenter.default.addObserver(
            forName: .iMusicLocalLibraryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.localLibraryDidChange()
            }
        }
        updateNetworkMonitor()
    }

    nonisolated static func permitsNetworkMonitoring(
        endpointConfigured: Bool,
        userRequestedDisconnect: Bool
    ) -> Bool {
        endpointConfigured && !userRequestedDisconnect
    }

    private func updateNetworkMonitor() {
        let isConfigured = !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard Self.permitsNetworkMonitoring(
            endpointConfigured: isConfigured,
            userRequestedDisconnect: userRequestedDisconnect
        ) else {
            stopNetworkMonitor()
            return
        }
        guard networkMonitor == nil else { return }

        networkMonitorGeneration += 1
        let generation = networkMonitorGeneration
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.networkMonitorGeneration == generation else { return }
                let isAvailable = path.status == .satisfied
                let shouldReconnect = isAvailable && self.hadNetworkPath != true
                self.hadNetworkPath = isAvailable
                if shouldReconnect {
                    await self.reconnectIfConfigured()
                }
            }
        }
        networkMonitor = monitor
        monitor.start(queue: networkQueue)
    }

    private func stopNetworkMonitor() {
        guard let networkMonitor else { return }
        networkMonitorGeneration += 1
        networkMonitor.cancel()
        self.networkMonitor = nil
        hadNetworkPath = nil
    }

    func connect() async throws {
        if isConnected { return }
        if let connectionTask {
            try await connectionTask.value
            return
        }
        userRequestedDisconnect = false
        updateNetworkMonitor()
        disconnectSocket(message: "正在连接 LX Sync Server…")
        let generation = connectionGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { throw LXSyncError.disconnected }
            try await self.performConnection(generation: generation)
        }
        connectionTask = task
        connectionTaskGeneration = generation

        do {
            try await task.value
            clearConnectionTask(ifCurrent: generation)
        } catch {
            clearConnectionTask(ifCurrent: generation)
            throw error
        }
    }

    private func performConnection(generation: Int) async throws {
        guard isCurrentConnection(generation) else { throw LXSyncError.disconnected }
        let address: LXSyncAddress
        do {
            address = try LXSyncAddress(endpoint)
        } catch {
            lastError = error.localizedDescription
            statusMessage = "连接失败"
            throw error
        }
        let code = connectionCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty,
           LXSyncSecureStore.load(account: "connection-code") == nil {
            let error = LXSyncError.invalidConnectionCode
            lastError = error.localizedDescription
            statusMessage = "连接失败"
            throw error
        }

        isConnecting = true
        isConnected = false
        lastError = nil
        statusMessage = "正在验证服务器…"
        defer {
            if isCurrentConnection(generation) { isConnecting = false }
        }

        do {
            let serviceID = try await fetchServerID(address)
            guard isCurrentConnection(generation) else { throw LXSyncError.disconnected }
            serverID = serviceID
            let savedCode = code.isEmpty
                ? String(data: LXSyncSecureStore.load(account: "connection-code") ?? Data(), encoding: .utf8) ?? ""
                : code
            let storedCode = String(
                data: LXSyncSecureStore.load(account: "connection-code") ?? Data(),
                encoding: .utf8
            ) ?? ""
            let key = try await authenticate(
                address,
                serverID: serviceID,
                code: savedCode,
                forceConnectionCode: !code.isEmpty && code != storedCode
            )
            guard isCurrentConnection(generation) else { throw LXSyncError.disconnected }
            keyInfo = key
            if !savedCode.isEmpty {
                LXSyncSecureStore.save(Data(savedCode.utf8), account: "connection-code")
            }
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(key) {
                LXSyncSecureStore.save(data, account: "key:\(serviceID)")
            }

            var authKey = try Self.decodeKey(key.key)
            let ticket = try Self.aesEncrypt(Data("lx-music connect".utf8), key: authKey)
            authKey.resetBytes(in: 0..<authKey.count)
            let requestURL = try address.socketURL(clientID: key.clientId, encryptedTicket: ticket.base64EncodedString())
            let task = URLSession.shared.webSocketTask(with: requestURL)
            socket = task
            activeSocketGeneration = generation
            task.resume()
            startReceiving(from: task, generation: generation)
            statusMessage = "正在同步资料库…"
            try await waitUntilReady(generation: generation)
            guard isCurrentConnection(generation), isConnected else {
                throw LXSyncError.disconnected
            }
            reconnectAttempt = 0
        } catch {
            guard isCurrentConnection(generation) else { throw LXSyncError.disconnected }
            lastError = error.localizedDescription
            statusMessage = "连接失败"
            disconnectSocket(message: statusMessage, invalidatesConnection: false)
            if isRetryableNetworkFailure(error) {
                scheduleReconnect()
            }
            throw error
        }
    }

    func reconnectIfConfigured() async {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !userRequestedDisconnect,
              !isConnected,
              !isConnecting else { return }
        cancelScheduledReconnect()
        do { try await connect() }
        catch { /* The Library sync page presents the error when opened. */ }
    }

    func syncNow() async throws {
        cancelScheduledReconnect()
        do {
            if !isConnected {
                try await connect()
                return
            }
            try await sendFullListSnapshot()
        } catch {
            lastError = error.localizedDescription
            statusMessage = "同步失败"
            throw error
        }
    }

    func disconnect() {
        userRequestedDisconnect = true
        cancelScheduledReconnect()
        updateNetworkMonitor()
        disconnectSocket(message: "已断开")
    }

    func forgetServer() {
        disconnect()
        LXSyncSecureStore.removeAll()
        serverID = nil
        keyInfo = nil
        connectionCode = ""
        endpoint = ""
        lastSyncAt = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncKey)
    }

    fileprivate func localLibraryDidChange() {
        guard isConnected, !applyingRemoteData else { return }
        pendingSnapshotTask?.cancel()
        pendingSnapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self, self.isConnected else { return }
            do { try await self.sendFullListSnapshot() }
            catch { self.lastError = error.localizedDescription }
        }
    }

    private func makeLocalListData() -> LXSyncListData {
        let localPlaylists = LocalPlaylistStore.shared.preparePlaylistsForLXSync()
        let favorites = LocalPlaylistStore.shared.favoriteTracks.map(LXSyncMusicInfo.init(track:))
        let previous = Dictionary(listData.userList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let synced = localPlaylists.map { playlist -> LXSyncUserPlaylist in
            let syncID = playlist.lxSyncID ?? playlist.id.uuidString
            let prior = previous[syncID]
            return LXSyncUserPlaylist(
                id: syncID,
                name: playlist.name,
                source: playlist.remoteSource ?? prior?.source,
                sourceListId: playlist.remotePlaylistID ?? prior?.sourceListId,
                locationUpdateTime: Int((playlist.updatedAt ?? playlist.createdAt).timeIntervalSince1970 * 1_000),
                list: playlist.tracks.map(LXSyncMusicInfo.init(track:)),
                iMusicSourceName: playlist.sourceName,
                iMusicCoverURL: playlist.coverURL,
                iMusicLocalCopy: playlist.isLocalCopy
            )
        }
        return LXSyncListData(
            defaultList: listData.defaultList,
            loveList: favorites,
            userList: synced
        )
    }

    private func apply(_ newData: LXSyncListData) {
        listData = newData
        persistListData()
        applyingRemoteData = true
        LocalPlaylistStore.shared.replaceFromLXSync(
            playlists: newData.userList,
            favorites: newData.loveList.map(\.track)
        )
        applyingRemoteData = false
    }

    private func persistListData() {
        guard let data = try? listData.encodedJSON() else { return }
        UserDefaults.standard.set(data, forKey: Self.dataKey)
    }

    private func sendFullListSnapshot() async throws {
        guard isConnected else { throw LXSyncError.disconnected }
        listData = makeLocalListData()
        persistListData()
        let serialized = try listData.encodedJSON()
        guard let listJSON = String(data: serialized, encoding: .utf8) else {
            throw LXSyncError.invalidServerResponse
        }
        let actionJSON = "{\"action\":\"list_data_overwrite\",\"data\":\(listJSON)}"
        _ = try await callServer(path: ["onListSyncAction"], argumentsJSON: "[\(actionJSON)]")
        markSynced()
    }

    private func markSynced() {
        let now = Date()
        lastSyncAt = now
        UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
        lastError = nil
        statusMessage = "已同步"
    }

    private func waitUntilReady(generation: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard isCurrentConnection(generation) else {
                continuation.resume(throwing: LXSyncError.disconnected)
                return
            }
            readyContinuation = continuation
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self,
                      self.isCurrentConnection(generation),
                      self.readyContinuation != nil else { return }
                self.failHandshake(LXSyncError.connectionTimedOut)
            }
        }
    }

    private func startReceiving(from task: URLSessionWebSocketTask, generation: Int) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let value): text = value
                    case .data(let data):
                        guard let value = String(data: data, encoding: .utf8) else { continue }
                        text = value
                    @unknown default: continue
                    }
                    await self.handleMessage(text, generation: generation)
                }
            } catch {
                guard !Task.isCancelled else { return }
                let statusCode = (task.response as? HTTPURLResponse)?.statusCode
                self.socketDidClose(
                    error,
                    closeCode: task.closeCode,
                    responseStatusCode: statusCode,
                    generation: generation
                )
            }
        }
    }

    private func handleMessage(_ text: String, generation: Int) async {
        guard isCurrentConnection(generation) else { return }
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = message.first as? Int else { return }
        switch type {
        case 0:
            guard message.count >= 4,
                  let eventID = message[1] as? String,
                  let path = message[2] as? [String] else { return }
            let arguments = message[3] as? [Any] ?? []
            do {
                let result = try handleClientCall(path: path, arguments: arguments)
                if path.last == "list_sync_get_list_data" {
                    let idJSON = try JSONEncoder().encode(eventID)
                    guard let id = String(data: idJSON, encoding: .utf8),
                          let snapshot = String(data: try listData.encodedJSON(), encoding: .utf8) else {
                        throw LXSyncError.invalidServerResponse
                    }
                    // Keep the wire-model field order intact. The LX server hashes
                    // JSON.stringify(listData), so routing this value through an
                    // unordered NSDictionary can produce a different digest.
                    try await sendRawMessage("[1,\(id),null,\(snapshot)]")
                } else {
                    try await sendMessage([1, eventID, NSNull(), result ?? NSNull()])
                }
            } catch {
                try? await sendMessage([1, eventID, ["message": error.localizedDescription]])
            }
        case 1, 3:
            guard message.count >= 3, let eventID = message[1] as? String,
                  let continuation = pendingCalls.removeValue(forKey: eventID) else { return }
            if let error = message[2] as? [String: Any], let reason = error["message"] as? String {
                continuation.resume(throwing: LXSyncError.server(reason))
            } else {
                continuation.resume(returning: message.count > 3 ? message[3] : nil)
            }
        case 2:
            guard message.count >= 3, let callbackID = message[1] as? String else { return }
            try? await sendMessage([3, callbackID, NSNull(), NSNull()])
        default:
            break
        }
    }

    private func handleClientCall(path: [String], arguments: [Any]) throws -> Any? {
        guard let method = path.last else { throw LXSyncError.invalidServerResponse }
        switch method {
        case "getEnabledFeatures":
            return ["list": ["skipSnapshot": false]]
        case "finished":
            isConnected = true
            isConnecting = false
            statusMessage = "已连接"
            markSynced()
            handshakeTimeoutTask?.cancel()
            readyContinuation?.resume(returning: ())
            readyContinuation = nil
            return NSNull()
        case "onFeatureChanged":
            return NSNull()
        case "onListSyncAction":
            guard let action = arguments.first else { throw LXSyncError.invalidServerResponse }
            try applyRemoteAction(action)
            return NSNull()
        case "list_sync_get_md5":
            let snapshot = makeLocalListData()
            return Self.md5Hex(try snapshot.encodedJSON())
        case "list_sync_get_sync_mode":
            // Merging preserves both local and remote playlists on first connect.
            return "merge_local_remote"
        case "list_sync_get_list_data":
            listData = makeLocalListData()
            return NSNull()
        case "list_sync_set_list_data":
            guard let raw = arguments.first,
                  let serialized = try? JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed]),
                  let decoded = try? JSONDecoder().decode(LXSyncListData.self, from: serialized) else {
                throw LXSyncError.invalidServerResponse
            }
            apply(decoded)
            return NSNull()
        case "list_sync_finished":
            return NSNull()
        default:
            throw LXSyncError.server("LX Sync 暂不支持此操作：\(method)")
        }
    }

    private func applyRemoteAction(_ rawValue: Any) throws {
        guard let action = rawValue as? [String: Any],
              let name = action["action"] as? String else {
            throw LXSyncError.invalidServerResponse
        }
        let data = action["data"]
        switch name {
        case "list_data_overwrite":
            try replaceListData(data)
        case "list_create":
            guard let payload = data as? [String: Any],
                  let rawLists = payload["listInfos"],
                  let lists = Self.decode([LXSyncUserPlaylist].self, from: rawLists) else {
                throw LXSyncError.invalidServerResponse
            }
            let position = payload["position"] as? Int ?? listData.userList.count
            let existingIDs = Set(listData.userList.map(\.id))
            let additions = lists.filter { !existingIDs.contains($0.id) }
            listData.userList.insert(
                contentsOf: additions,
                at: min(max(position, 0), listData.userList.count)
            )
        case "list_remove":
            guard let ids = data as? [String] else { throw LXSyncError.invalidServerResponse }
            listData.userList.removeAll { ids.contains($0.id) }
        case "list_update":
            guard let lists = Self.decode([LXSyncUserPlaylist].self, from: data) else {
                throw LXSyncError.invalidServerResponse
            }
            for incoming in lists {
                if let index = listData.userList.firstIndex(where: { $0.id == incoming.id }) {
                    var copy = incoming
                    if copy.list.isEmpty { copy.list = listData.userList[index].list }
                    listData.userList[index] = copy
                }
            }
        case "list_update_position":
            guard let payload = data as? [String: Any],
                  let ids = payload["ids"] as? [String] else { throw LXSyncError.invalidServerResponse }
            let position = payload["position"] as? Int ?? listData.userList.count
            let selected = ids.compactMap { id in listData.userList.first { $0.id == id } }
            listData.userList.removeAll { ids.contains($0.id) }
            listData.userList.insert(contentsOf: selected, at: min(max(position, 0), listData.userList.count))
        case "list_music_add", "list_music_move":
            try applyMusicAdd(name: name, data: data)
        case "list_music_remove":
            guard let payload = data as? [String: Any],
                  let listID = payload["listId"] as? String,
                  let ids = payload["ids"] as? [String] else { throw LXSyncError.invalidServerResponse }
            updateMusicList(listID) { $0.removeAll { ids.contains($0.id) } }
        case "list_music_update":
            guard let updates = data as? [[String: Any]] else { throw LXSyncError.invalidServerResponse }
            for update in updates {
                guard let id = update["id"] as? String,
                      let info = Self.decode(LXSyncMusicInfo.self, from: update["musicInfo"]) else { continue }
                updateMusicList(id) { songs in
                    if let index = songs.firstIndex(where: { $0.id == info.id }) { songs[index] = info }
                }
            }
        case "list_music_update_position":
            guard let payload = data as? [String: Any],
                  let listID = payload["listId"] as? String,
                  let ids = payload["ids"] as? [String] else { throw LXSyncError.invalidServerResponse }
            let position = payload["position"] as? Int ?? 0
            updateMusicList(listID) { songs in
                let selected = ids.compactMap { id in songs.first { $0.id == id } }
                songs.removeAll { ids.contains($0.id) }
                songs.insert(contentsOf: selected, at: min(max(position, 0), songs.count))
            }
        case "list_music_overwrite":
            guard let payload = data as? [String: Any],
                  let listID = payload["listId"] as? String,
                  let songs = Self.decode([LXSyncMusicInfo].self, from: payload["musicInfos"]) else {
                throw LXSyncError.invalidServerResponse
            }
            updateMusicList(listID) { $0 = songs }
        case "list_music_clear":
            guard let ids = data as? [String] else { throw LXSyncError.invalidServerResponse }
            for id in ids { updateMusicList(id) { $0 = [] } }
        default:
            throw LXSyncError.server("未知的歌单同步操作：\(name)")
        }
        apply(listData)
        markSynced()
    }

    private func replaceListData(_ rawValue: Any?) throws {
        guard let decoded = Self.decode(LXSyncListData.self, from: rawValue) else {
            throw LXSyncError.invalidServerResponse
        }
        apply(decoded)
    }

    private func applyMusicAdd(name: String, data: Any?) throws {
        guard let payload = data as? [String: Any],
              let incoming = Self.decode([LXSyncMusicInfo].self, from: payload["musicInfos"]) else {
            throw LXSyncError.invalidServerResponse
        }
        let addAtTop = (payload["addMusicLocationType"] as? String) == "top"
        if name == "list_music_move" {
            guard let fromID = payload["fromId"] as? String else { throw LXSyncError.invalidServerResponse }
            updateMusicList(fromID) { songs in songs.removeAll { removed in incoming.contains(where: { $0.id == removed.id }) } }
        }
        let listID = (name == "list_music_move" ? payload["toId"] : payload["id"]) as? String
        guard let listID else { throw LXSyncError.invalidServerResponse }
        updateMusicList(listID) { songs in
            let existing = Set(songs.map(\.id))
            let additions = incoming.filter { !existing.contains($0.id) }
            if addAtTop { songs.insert(contentsOf: additions, at: 0) }
            else { songs.append(contentsOf: additions) }
        }
    }

    private func updateMusicList(_ id: String, update: (inout [LXSyncMusicInfo]) -> Void) {
        switch id {
        case "default": update(&listData.defaultList)
        case "love": update(&listData.loveList)
        default:
            guard let index = listData.userList.firstIndex(where: { $0.id == id }) else { return }
            update(&listData.userList[index].list)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from rawValue: Any?) -> T? {
        guard let rawValue,
              let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.fragmentsAllowed]) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func callServer(path: [String], argumentsJSON: String) async throws -> Any? {
        guard socket != nil else { throw LXSyncError.disconnected }
        let requestID = UUID().uuidString
        let pathData = try JSONEncoder().encode(path)
        guard let pathJSON = String(data: pathData, encoding: .utf8) else {
            throw LXSyncError.invalidServerResponse
        }
        let message = "[0,\"\(requestID)\",\(pathJSON),\(argumentsJSON),[]]"
        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[requestID] = continuation
            Task { [weak self] in
                do {
                    try await self?.sendRawMessage(message)
                } catch {
                    await self?.rejectCall(requestID, error: error)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                await self?.rejectCall(requestID, error: LXSyncError.connectionTimedOut)
            }
        }
    }

    private func rejectCall(_ id: String, error: Error) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func sendMessage(_ value: Any) async throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else { throw LXSyncError.invalidServerResponse }
        try await sendRawMessage(text)
    }

    private func sendRawMessage(_ text: String) async throws {
        guard let socket else { throw LXSyncError.disconnected }
        try await socket.send(.string(text))
    }

    private func socketDidClose(
        _ error: Error,
        closeCode: URLSessionWebSocketTask.CloseCode,
        responseStatusCode: Int?,
        generation: Int
    ) {
        guard isCurrentConnection(generation),
              activeSocketGeneration == generation,
              socket != nil else { return }
        let shouldReconnect = !userRequestedDisconnect && LXSyncReconnectPolicy.isRetryableSocketFailure(
            error,
            closeCode: closeCode,
            responseStatusCode: responseStatusCode
        )
        socket = nil
        activeSocketGeneration = nil
        isConnected = false
        statusMessage = "连接已断开"
        lastError = error.localizedDescription
        if readyContinuation != nil {
            failHandshake(shouldReconnect ? error : LXSyncError.server("LX Sync WebSocket 连接被服务端拒绝"))
        }
        let calls = pendingCalls.values
        pendingCalls.removeAll()
        for continuation in calls { continuation.resume(throwing: error) }
        if shouldReconnect { scheduleReconnect() }
    }

    /// Keep an established library sync alive when the server or transport
    /// drops its socket without a phone-network transition. The retry delay
    /// grows from one second to a one-minute ceiling, and an explicit user
    /// disconnect always cancels the loop.
    private func scheduleReconnect() {
        guard reconnectTask == nil,
              !userRequestedDisconnect,
              !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let generation = reconnectGeneration
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.userRequestedDisconnect {
                let delay = LXSyncReconnectPolicy.delaySeconds(attempt: self.reconnectAttempt)
                self.statusMessage = "连接中断，\(Int(delay)) 秒后重试"
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    break
                }

                guard !Task.isCancelled,
                      !self.userRequestedDisconnect,
                      !self.isConnected,
                      !self.isConnecting else { break }

                self.reconnectAttempt = min(self.reconnectAttempt + 1, 6)
                do {
                    try await self.connect()
                    if self.isConnected { break }
                } catch {
                    guard !self.userRequestedDisconnect else { break }
                    guard self.isRetryableNetworkFailure(error) else {
                        self.statusMessage = "连接失败"
                        break
                    }
                    self.lastError = error.localizedDescription
                }
            }
            if self.reconnectGeneration == generation {
                self.reconnectTask = nil
            }
        }
    }

    private func cancelScheduledReconnect() {
        guard connectionTask == nil else { return }
        reconnectGeneration += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
    }

    private func isRetryableNetworkFailure(_ error: Error) -> Bool {
        if let syncError = error as? LXSyncError {
            switch syncError {
            case .connectionTimedOut, .disconnected, .temporaryServer:
                return true
            default:
                return false
            }
        }
        return LXSyncReconnectPolicy.isRetryableNetworkFailure(error)
    }

    private func isCurrentConnection(_ generation: Int) -> Bool {
        connectionGeneration == generation
    }

    private func clearConnectionTask(ifCurrent generation: Int) {
        guard connectionTaskGeneration == generation else { return }
        connectionTask = nil
        connectionTaskGeneration = nil
    }

    private func failHandshake(_ error: Error) {
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    private func disconnectSocket(message: String, invalidatesConnection: Bool = true) {
        if invalidatesConnection {
            connectionGeneration &+= 1
            connectionTask?.cancel()
            connectionTask = nil
            connectionTaskGeneration = nil
        }
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        activeSocketGeneration = nil
        isConnected = false
        isConnecting = false
        statusMessage = message
        failHandshake(LXSyncError.disconnected)
        for continuation in pendingCalls.values {
            continuation.resume(throwing: LXSyncError.disconnected)
        }
        pendingCalls.removeAll()
    }

    private func fetchServerID(_ address: LXSyncAddress) async throws -> String {
        let hello = try await request(address.httpURL("hello"))
        let greeting = String(data: hello.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard greeting == "Hello~::^-^::~v4~" else {
            throw LXSyncError.incompatibleServer("LX Sync Server 协议版本不匹配，请升级服务器")
        }
        let response = try await request(address.httpURL("id"))
        let value = String(data: response.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "OjppZDo6"
        guard value.hasPrefix(prefix) else { throw LXSyncError.invalidServerResponse }
        let serverID = String(value.dropFirst(prefix.count))
        guard !serverID.isEmpty else { throw LXSyncError.invalidServerResponse }
        return serverID
    }

    private func authenticate(
        _ address: LXSyncAddress,
        serverID: String,
        code: String,
        forceConnectionCode: Bool
    ) async throws -> LXSyncKeyInfo {
        if !forceConnectionCode,
           let cached = LXSyncSecureStore.load(account: "key:\(serverID)"),
           let savedKey = try? JSONDecoder().decode(LXSyncKeyInfo.self, from: cached) {
            do {
                try await verifySavedKey(address, key: savedKey)
                return savedKey
            } catch {
                if code.isEmpty { throw error }
            }
        }
        guard !code.isEmpty else { throw LXSyncError.invalidConnectionCode }
        return try await authorizeWithCode(address, code: code)
    }

    private func verifySavedKey(_ address: LXSyncAddress, key: LXSyncKeyInfo) async throws {
        let rawKey = try Self.decodeKey(key.key)
        let message = Data("lx-music auth::\(deviceName)".utf8)
        let encrypted = try Self.aesEncrypt(message, key: rawKey)
        var request = URLRequest(url: try address.httpURL("ah"))
        request.setValue(key.clientId, forHTTPHeaderField: "i")
        request.setValue(encrypted.base64EncodedString(), forHTTPHeaderField: "m")
        let response = try await requestData(request)
        guard let body = String(data: response.data, encoding: .utf8),
              let decoded = Data(base64Encoded: body),
              try Self.aesDecrypt(decoded, key: rawKey) == Data("Hello~::^-^::~v4~".utf8) else {
            throw LXSyncError.authorizationFailed
        }
    }

    private func authorizeWithCode(_ address: LXSyncAddress, code: String) async throws -> LXSyncKeyInfo {
        let keyPair = try Self.makeRSAKeyPair()
        let passwordKey = Self.connectionKey(code)
        let message = "lx-music auth::\n\(keyPair.publicKeyBase64)\n\(deviceName)\nlx_music_mobile"
        let encrypted = try Self.aesEncrypt(Data(message.utf8), key: passwordKey)
        var request = URLRequest(url: try address.httpURL("ah"))
        request.setValue(encrypted.base64EncodedString(), forHTTPHeaderField: "m")
        let response = try await requestData(request)
        guard response.statusCode == 200,
              let body = String(data: response.data, encoding: .utf8),
              let cipher = Data(base64Encoded: body),
              let plain = SecKeyCreateDecryptedData(
                keyPair.privateKey,
                .rsaEncryptionOAEPSHA1,
                cipher as CFData,
                nil
              ) as Data?,
              let keyInfo = try? JSONDecoder().decode(LXSyncKeyInfo.self, from: plain) else {
            throw LXSyncError.authorizationFailed
        }
        return keyInfo
    }

    private func request(_ url: URL) async throws -> (data: Data, statusCode: Int) {
        try await requestData(URLRequest(url: url))
    }

    private func requestData(_ request: URLRequest) async throws -> (data: Data, statusCode: Int) {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LXSyncError.invalidServerResponse }
        if http.statusCode == 403 { throw LXSyncError.server("服务器暂时封锁了此网络地址") }
        if http.statusCode == 401 { throw LXSyncError.authorizationFailed }
        if LXSyncReconnectPolicy.isRetryableHTTPStatus(http.statusCode) {
            throw LXSyncError.temporaryServer("LX Sync Server 暂时不可用（HTTP \(http.statusCode)）")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LXSyncError.server("LX Sync Server 请求失败（HTTP \(http.statusCode)）")
        }
        return (data, http.statusCode)
    }

    private var deviceName: String {
        #if os(iOS)
        return "iMusic · \(UIDevice.current.name)"
        #else
        return "iMusic · \(ProcessInfo.processInfo.hostName)"
        #endif
    }

    private static func connectionKey(_ code: String) -> Data {
        let digest = Insecure.MD5.hash(data: Data(code.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined().prefix(16)
        return Data(hex.utf8)
    }

    private static func decodeKey(_ value: String) throws -> Data {
        guard let key = Data(base64Encoded: value), key.count == kCCKeySizeAES128 else {
            throw LXSyncError.invalidServerResponse
        }
        return key
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func aesEncrypt(_ data: Data, key: Data) throws -> Data {
        try aesCrypt(data, key: key, operation: CCOperation(kCCEncrypt))
    }

    private static func aesDecrypt(_ data: Data, key: Data) throws -> Data {
        try aesCrypt(data, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func aesCrypt(_ data: Data, key: Data, operation: CCOperation) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw LXSyncError.invalidServerResponse }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        inputBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw LXSyncError.authorizationFailed }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func makeRSAKeyPair() throws -> (privateKey: SecKey, publicKeyBase64: String) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2_048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false],
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let rawKey = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            if let error { throw error.takeRetainedValue() }
            throw LXSyncError.authorizationFailed
        }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        var bitStringBody = Data([0x00])
        bitStringBody.append(rawKey)
        var subjectBody = algorithm
        subjectBody.append(der(tag: 0x03, body: bitStringBody))
        let subjectPublicKeyInfo = der(tag: 0x30, body: subjectBody)
        return (privateKey, subjectPublicKeyInfo.base64EncodedString())
    }

    private static func der(tag: UInt8, body: Data) -> Data {
        var result = Data([tag])
        if body.count < 128 {
            result.append(UInt8(body.count))
        } else {
            var bytes = withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init)
            while bytes.first == 0 { bytes.removeFirst() }
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        result.append(body)
        return result
    }

}
