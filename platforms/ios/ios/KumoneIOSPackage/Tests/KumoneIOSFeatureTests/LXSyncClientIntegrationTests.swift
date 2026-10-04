import CommonCrypto
import Foundation
import XCTest
@testable import KumoneCore

@MainActor
final class LXSyncClientIntegrationTests: XCTestCase {
    func testLXSyncConnectionTicketUsesAES128ECBWithoutPadding() throws {
        let key = Data((0...15).map(UInt8.init))
        let plaintext = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        ])

        XCTAssertEqual(
            try LXSyncService.aesEncryptNoPadding(plaintext, key: key),
            Data([
                0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
                0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a,
            ])
        )
    }

    func testConnectAndSynchronizePlaylistChangesInBothDirections() async throws {
        let fixture = makeFixture()
        let service = fixture.service
        let preservedTrack = sampleTrack(id: 11, name: "本地保留歌曲")
        let favoriteTrack = sampleTrack(id: 12, name: "本地收藏")
        let preservedLocalID = try XCTUnwrap(fixture.store.create(
            name: "已有本地歌单",
            tracks: [preservedTrack]
        ))
        let qqPlaylist = fixture.store.upsertRemotePlaylist(
            source: "qq",
            remoteID: "qq-public-42",
            name: "QQ 收藏的公开歌单",
            coverURL: nil,
            sourceName: "QQ 音乐",
            revision: 2,
            tracks: [sampleTrack(id: 14, name: "QQ 本地歌曲")]
        )
        fixture.store.toggleFavorite(favoriteTrack)
        defer {
            service.disconnect()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        let connectionTask = Task { try await service.connect() }
        try await waitUntil { fixture.transport.socket != nil }
        let socket = try XCTUnwrap(fixture.transport.socket)
        let socketURL = try XCTUnwrap(fixture.transport.socketURL)
        let query = try XCTUnwrap(URLComponents(url: socketURL, resolvingAgainstBaseURL: false)?.queryItems)
        let ticketBase64 = try XCTUnwrap(query.first(where: { $0.name == "t" })?.value)
        let ticket = try XCTUnwrap(Data(base64Encoded: ticketBase64))
        XCTAssertEqual(ticket.count, 16, "LX Sync's ticket is one unpadded AES block")

        let remotePlaylist = LXSyncUserPlaylist(
            id: "remote-list",
            name: "远端歌单",
            list: [LXSyncMusicInfo(track: sampleTrack(id: 31, name: "远端歌曲"))]
        )
        let initialMergedData = LXSyncListData(
            loveList: [LXSyncMusicInfo(track: favoriteTrack)],
            userList: [
                LXSyncUserPlaylist(
                    id: preservedLocalID.uuidString,
                    name: "已有本地歌单",
                    list: [LXSyncMusicInfo(track: preservedTrack)]
                ),
                remotePlaylist,
                LXSyncUserPlaylist(
                    id: "old-provider-list",
                    name: "旧版服务端 QQ 收藏歌单",
                    source: "tx",
                    sourceListId: "qq-public-42",
                    list: [LXSyncMusicInfo(track: sampleTrack(id: 15, name: "旧的远端 QQ 歌曲"))]
                ),
            ]
        )
        try await finishHandshake(socket, initialData: initialMergedData)
        try await connectionTask.value

        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.statusMessage, "已同步")
        XCTAssertEqual(Set(fixture.store.playlists.map(\.name)), Set(["远端歌单", "已有本地歌单", "QQ 收藏的公开歌单"]))
        XCTAssertEqual(fixture.store.playlists.first(where: { $0.name == "远端歌单" })?.tracks.first?.name, "远端歌曲")
        XCTAssertEqual(fixture.store.playlists.first(where: { $0.name == "已有本地歌单" })?.tracks.first?.name, "本地保留歌曲")
        XCTAssertEqual(fixture.store.playlists.first(where: { $0.id == qqPlaylist.id })?.name, "QQ 收藏的公开歌单")
        XCTAssertEqual(fixture.store.playlists.first(where: { $0.id == qqPlaylist.id })?.tracks.first?.name, "QQ 本地歌曲")
        XCTAssertFalse(fixture.store.playlists.contains(where: { $0.name == "旧版服务端 QQ 收藏歌单" }))
        XCTAssertEqual(fixture.store.favoriteTracks.map(\.name), ["本地收藏"])

        let providerCollision = LXSyncUserPlaylist(
            id: "remote-list",
            name: "QQ 公共歌单",
            source: "tx",
            sourceListId: "42",
            list: [LXSyncMusicInfo(track: sampleTrack(id: 32, name: "不应覆盖的 QQ 歌曲"))]
        )
        try socket.sendServerCall(
            id: "provider-collision-update",
            method: "onListSyncAction",
            arguments: [["action": "list_update", "data": try jsonObject([providerCollision])]]
        )
        try await waitForAcknowledgement("provider-collision-update", on: socket)
        XCTAssertEqual(fixture.store.playlists.first(where: { $0.lxSyncID == "remote-list" })?.tracks.first?.name, "远端歌曲")

        let localID = try XCTUnwrap(fixture.store.create(
            name: "本地歌单",
            tracks: [sampleTrack(id: 42, name: "本地歌曲")]
        ))
        let initialSyncAt = service.lastSyncAt
        let createSnapshot = try await waitForSnapshot(socket)
        XCTAssertEqual(createSnapshot.userList.map(\.name), ["本地歌单", "已有本地歌单", "远端歌单"])
        XCTAssertFalse(createSnapshot.userList.contains(where: { $0.name.contains("QQ 收藏") }))
        XCTAssertEqual(createSnapshot.userList.first?.list.first?.name, "本地歌曲")
        try await waitUntil { service.lastSyncAt != initialSyncAt }

        let afterCreateSyncAt = service.lastSyncAt
        let messageCountBeforeDelete = socket.sentMessages.count
        fixture.store.delete(id: localID)
        let deleteSnapshot = try await waitForSnapshot(socket, after: messageCountBeforeDelete)
        XCTAssertEqual(deleteSnapshot.userList.map(\.name), ["已有本地歌单", "远端歌单"])
        try await waitUntil { service.lastSyncAt != afterCreateSyncAt }

        let addedRemotely = LXSyncUserPlaylist(
            id: "server-created-list",
            name: "服务端新增",
            list: [LXSyncMusicInfo(track: sampleTrack(id: 53, name: "服务端歌曲"))]
        )
        try socket.sendServerCall(
            id: "remote-create",
            method: "onListSyncAction",
            arguments: [[
                "action": "list_create",
                "data": ["listInfos": try jsonObject([addedRemotely]), "position": 0],
            ]]
        )
        try await waitUntil { fixture.store.playlists.contains(where: { $0.name == "服务端新增" }) }
        XCTAssertEqual(fixture.store.playlists.first?.tracks.first?.name, "服务端歌曲")

        try socket.sendServerCall(
            id: "remote-delete",
            method: "onListSyncAction",
            arguments: [["action": "list_remove", "data": ["server-created-list"]]]
        )
        try await waitUntil { !fixture.store.playlists.contains(where: { $0.name == "服务端新增" }) }

    }

    func testAuthenticationFailureDoesNotOpenSocketOrReportConnected() async {
        let fixture = makeFixture(rejectAuthorization: true)

        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        do {
            try await fixture.service.connect()
            XCTFail("Expected the server's authorization failure")
        } catch {
            XCTAssertFalse(fixture.service.isConnected)
            XCTAssertEqual(fixture.service.statusMessage, "连接失败")
            XCTAssertNil(fixture.transport.socket)
        }
    }

    private func makeFixture(rejectAuthorization: Bool = false) -> Fixture {
        let suiteName = "LXSyncClientIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set("https://sync.example.test/prefix", forKey: "imusic.lxSync.endpoint")
        let credentials = MemoryCredentials()
        credentials.save(Data("test-code".utf8), account: "connection-code")
        let keyData = Data("0123456789abcdef".utf8)
        let keyInfo: [String: String] = [
            "clientId": "test-client",
            "key": keyData.base64EncodedString(),
            "serverName": "test-server",
        ]
        credentials.save(try! JSONSerialization.data(withJSONObject: keyInfo), account: "key:test-server")
        let store = LocalPlaylistStore(defaults: defaults)
        let transport = FakeTransport(key: keyData, rejectAuthorization: rejectAuthorization)
        let service = LXSyncService(
            defaults: defaults,
            localStore: store,
            transport: transport,
            credentialStore: credentials,
            observesLibraryChanges: true
        )
        return Fixture(
            service: service,
            store: store,
            transport: transport,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func finishHandshake(_ socket: FakeSocket, initialData: LXSyncListData) async throws {
        try socket.sendServerCall(id: "features", method: "getEnabledFeatures")
        try await waitForAcknowledgement("features", on: socket)

        try socket.sendServerCall(id: "mode", method: "list_sync_get_sync_mode")
        try await waitForAcknowledgement("mode", on: socket)

        try socket.sendServerCall(id: "local-data", method: "list_sync_get_list_data")
        let localSnapshot = try await waitForSnapshotResponse("local-data", on: socket)
        XCTAssertTrue(localSnapshot.userList.contains(where: { $0.name == "已有本地歌单" }))
        XCTAssertFalse(localSnapshot.userList.contains(where: { $0.source == "qq" || $0.source == "tx" }))
        XCTAssertTrue(localSnapshot.loveList.contains(where: { $0.name == "本地收藏" }))

        try socket.sendServerCall(
            id: "initial-data",
            method: "list_sync_set_list_data",
            arguments: [try jsonObject(initialData)]
        )
        try await waitForAcknowledgement("initial-data", on: socket)

        try socket.sendServerCall(id: "sync-finished", method: "list_sync_finished")
        try await waitForAcknowledgement("sync-finished", on: socket)

        try socket.sendServerCall(id: "finished", method: "finished")
        try await waitForAcknowledgement("finished", on: socket)
    }

    private func waitForAcknowledgement(_ id: String, on socket: FakeSocket) async throws {
        try await waitUntil {
            socket.sentMessages.contains { message in
                guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                      let name = object["name"] as? String else { return false }
                return name.hasSuffix("__\(id)")
            }
        }
    }

    private func waitForSnapshotResponse(_ id: String, on socket: FakeSocket) async throws -> LXSyncListData {
        var result: LXSyncListData?
        try await waitUntil {
            for message in socket.sentMessages {
                guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                      (object["name"] as? String)?.hasSuffix("__\(id)") == true,
                      let value = object["data"],
                      let data = try? JSONSerialization.data(withJSONObject: value),
                      let decoded = try? JSONDecoder().decode(LXSyncListData.self, from: data) else { continue }
                result = decoded
                return true
            }
            return false
        }
        return try XCTUnwrap(result)
    }

    private func waitForSnapshot(_ socket: FakeSocket, after start: Int = 0) async throws -> LXSyncListData {
        var result: LXSyncListData?
        try await waitUntil {
            for message in socket.sentMessages.dropFirst(start) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                      (object["path"] as? [String])?.last == "onListSyncAction",
                      let arguments = object["data"] as? [[String: Any]],
                      let action = arguments.first,
                      action["action"] as? String == "list_data_overwrite",
                      let rawData = action["data"],
                      let data = try? JSONSerialization.data(withJSONObject: rawData),
                      let decoded = try? JSONDecoder().decode(LXSyncListData.self, from: data) else { continue }
                result = decoded
                return true
            }
            return false
        }
        return try XCTUnwrap(result)
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition did not become true", file: file, line: line)
        throw NSError(domain: "LXSyncClientIntegrationTests", code: 1)
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func sampleTrack(id: Int, name: String) -> Track {
        Track(
            id: id,
            name: name,
            artists: [ArtistRef(id: 1, name: "iMusic")],
            album: AlbumRef(id: 1, name: "同步测试", picUrl: nil),
            durationMS: 180_000,
            source: "wy"
        )
    }
}

@MainActor
private struct Fixture {
    let service: LXSyncService
    let store: LocalPlaylistStore
    let transport: FakeTransport
    let defaults: UserDefaults
    let suiteName: String
}

@MainActor
private final class MemoryCredentials: LXSyncCredentialStore {
    private var values: [String: Data] = [:]
    func load(account: String) -> Data? { values[account] }
    func save(_ data: Data, account: String) { values[account] = data }
    func removeAll() { values.removeAll() }
}

@MainActor
private final class FakeTransport: LXSyncTransport {
    private let key: Data
    private let rejectAuthorization: Bool
    private(set) var socket: FakeSocket?
    private(set) var socketURL: URL?

    init(key: Data, rejectAuthorization: Bool) {
        self.key = key
        self.rejectAuthorization = rejectAuthorization
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let statusCode = rejectAuthorization && request.url?.lastPathComponent == "ah" ? 401 : 200
        let body: Data
        switch request.url?.lastPathComponent {
        case "hello":
            body = Data("Hello~::^-^::~v4~".utf8)
        case "id":
            body = Data("OjppZDo6test-server".utf8)
        case "ah":
            body = try aesEncrypt(Data("Hello~::^-^::~v4~".utf8), key: key).base64EncodedData()
        default:
            body = Data()
        }
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (body, response)
    }

    func webSocketTask(with url: URL) -> LXSyncSocket {
        socketURL = url
        let value = FakeSocket()
        socket = value
        return value
    }
}

@MainActor
private final class FakeSocket: LXSyncSocket {
    private(set) var sentMessages: [String] = []
    private var incoming: [URLSessionWebSocketTask.Message] = []
    private var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    var response: URLResponse? {
        HTTPURLResponse(url: URL(string: "wss://sync.example.test/socket")!, statusCode: 101, httpVersion: "HTTP/1.1", headerFields: nil)
    }
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid

    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if !incoming.isEmpty { return incoming.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let frame) = message else { return }
        let decoded = try LXSyncWireCodec.decode(frame)
        sentMessages.append(decoded)
        guard let object = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any],
              object["path"] is [String],
              let id = object["name"] as? String else { return }
        try sendFrame(["name": id, "error": NSNull(), "data": NSNull()])
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.closeCode = closeCode
        receiver?.resume(throwing: URLError(.cancelled))
        receiver = nil
    }

    func sendServerCall(id: String, method: String, arguments: [Any] = []) throws {
        try sendFrame([
            "name": "\(method)__\(id)",
            "path": [method],
            "data": arguments,
        ])
    }

    private func sendFrame(_ value: Any) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: .string(text))
        } else {
            incoming.append(.string(text))
        }
    }
}

private func aesEncrypt(_ data: Data, key: Data) throws -> Data {
    var output = Data(count: data.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var outputLength = 0
    let status = output.withUnsafeMutableBytes { outputBytes in
        data.withUnsafeBytes { inputBytes in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
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
    guard status == kCCSuccess else { throw NSError(domain: "LXSyncClientIntegrationTests", code: Int(status)) }
    output.removeSubrange(outputLength..<output.count)
    return output
}
