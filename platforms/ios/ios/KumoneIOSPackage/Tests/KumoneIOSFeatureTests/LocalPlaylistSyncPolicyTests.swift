import XCTest
@testable import KumoneCore

final class LocalPlaylistSyncPolicyTests: XCTestCase {
    func testEditedProviderPlaylistStopsRefreshingFromProvider() {
        let localCopy = LocalPlaylist(
            name: "Edited copy",
            remoteSource: "netease",
            remotePlaylistID: "42",
            isLocalCopy: true
        )

        XCTAssertFalse(LocalPlaylistSyncPolicy.shouldRefreshFromProvider(localCopy))
        XCTAssertFalse(LocalPlaylistSyncPolicy.shouldApplyProviderSnapshot(to: localCopy))
    }

    func testUneditedProviderPlaylistContinuesRefreshing() {
        let imported = LocalPlaylist(
            name: "Imported playlist",
            remoteSource: "netease",
            remotePlaylistID: "42"
        )

        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldRefreshFromProvider(imported))
        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldApplyProviderSnapshot(to: imported))
        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldApplyProviderSnapshot(to: nil))
    }

    func testOlderLXSyncUpdateCannotClearAnEditedCopyFlag() {
        let localCopy = LocalPlaylist(
            name: "Edited copy",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            remoteSource: "netease",
            remotePlaylistID: "42",
            isLocalCopy: true
        )

        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldPreserveLocalEdits(
            current: localCopy,
            incomingLocalCopyFlag: nil,
            incomingUpdateTime: 3_000
        ))
        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldPreserveLocalEdits(
            current: localCopy,
            incomingLocalCopyFlag: false,
            incomingUpdateTime: 3_000
        ))
        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldPreserveLocalEdits(
            current: localCopy,
            incomingLocalCopyFlag: true,
            incomingUpdateTime: 1_999
        ))
        XCTAssertFalse(LocalPlaylistSyncPolicy.shouldPreserveLocalEdits(
            current: localCopy,
            incomingLocalCopyFlag: true,
            incomingUpdateTime: 3_000
        ))
        XCTAssertTrue(LocalPlaylistSyncPolicy.shouldPreserveLocalEdits(
            current: localCopy,
            incomingLocalCopyFlag: true,
            incomingUpdateTime: nil
        ))
    }

    func testOlderLXSyncSnapshotDoesNotReplaceEditedPlaylistContents() {
        let editedTrack = track(id: 2, name: "Local edit")
        let staleTrack = track(id: 1, name: "Provider version")
        let current = LocalPlaylist(
            name: "My edited name",
            tracks: [editedTrack],
            remoteSource: "netease",
            remotePlaylistID: "42",
            remoteRevision: 100,
            lxSyncID: "playlist-1",
            isLocalCopy: true
        )
        let olderClientSnapshot = LXSyncUserPlaylist(
            id: "playlist-1",
            name: "Provider playlist name",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 200,
            list: [LXSyncMusicInfo(track: staleTrack)]
        )

        let merged = LocalPlaylistSyncPolicy.merge(olderClientSnapshot, with: current)

        XCTAssertEqual(merged.name, "My edited name")
        XCTAssertEqual(merged.tracks.map(\.name), ["Local edit"])
        XCTAssertEqual(merged.remoteRevision, 100)
        XCTAssertTrue(merged.isLocalCopy == true)
    }

    func testNewerFlaggedLXSyncSnapshotCanPropagateEditsFromAnotherDevice() {
        let localTrack = track(id: 1, name: "Older local edit")
        let newerTrack = track(id: 2, name: "Newer device edit")
        let current = LocalPlaylist(
            name: "Older local edit",
            tracks: [localTrack],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            remoteSource: "netease",
            remotePlaylistID: "42",
            lxSyncID: "playlist-1",
            isLocalCopy: true
        )
        let newerSnapshot = LXSyncUserPlaylist(
            id: "playlist-1",
            name: "Newer device edit",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 3_000,
            list: [LXSyncMusicInfo(track: newerTrack)],
            iMusicLocalCopy: true
        )

        let merged = LocalPlaylistSyncPolicy.merge(newerSnapshot, with: current)

        XCTAssertEqual(merged.name, "Newer device edit")
        XCTAssertEqual(merged.tracks.map(\.name), ["Newer device edit"])
        XCTAssertTrue(merged.isLocalCopy == true)
    }

    func testProviderIdentityAllowsAccountImportToRecognizeLinkImport() {
        let linkImportedCopy = LocalPlaylist(
            name: "网易云歌单",
            remoteSource: "netease",
            remotePlaylistID: "42",
            isLocalCopy: true
        )

        XCTAssertTrue(LocalPlaylistSyncPolicy.matchesProviderPlaylist(
            linkImportedCopy,
            source: "netease",
            id: "42"
        ))
        XCTAssertFalse(LocalPlaylistSyncPolicy.matchesProviderPlaylist(
            linkImportedCopy,
            source: "netease",
            id: "43"
        ))
    }

    func testProviderDuplicateAcrossDevicesKeepsOneNewestCopy() {
        let older = LXSyncUserPlaylist(
            id: "sync-b",
            name: "Older copy",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 1_000
        )
        let newer = LXSyncUserPlaylist(
            id: "sync-z",
            name: "Newest copy",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 2_000,
            iMusicLocalCopy: true
        )

        let merged = LocalPlaylistSyncPolicy.deduplicateProviderPlaylists([older, newer])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "sync-b")
        XCTAssertEqual(merged[0].name, "Newest copy")
        XCTAssertEqual(merged[0].iMusicLocalCopy, true)
    }

    func testProviderDeduplicationPreservesEditedCopyAgainstNewerUnmarkedSnapshot() {
        let edited = LXSyncUserPlaylist(
            id: "sync-a",
            name: "My edited copy",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 1_000,
            iMusicLocalCopy: true
        )
        let unmarkedAccountSnapshot = LXSyncUserPlaylist(
            id: "sync-z",
            name: "Provider playlist",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 2_000,
            iMusicLocalCopy: false
        )

        let merged = LocalPlaylistSyncPolicy.deduplicateProviderPlaylists([
            unmarkedAccountSnapshot, edited
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "sync-a")
        XCTAssertEqual(merged[0].name, "My edited copy")
        XCTAssertEqual(merged[0].iMusicLocalCopy, true)
    }

    func testProviderDeduplicationTieBreakIsIndependentOfInputOrder() {
        let stale = LXSyncUserPlaylist(
            id: "a",
            name: "Older",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 1_000
        )
        let firstTie = LXSyncUserPlaylist(
            id: "z",
            name: "First tie",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 2_000
        )
        let secondTie = LXSyncUserPlaylist(
            id: "b",
            name: "Second tie",
            source: "netease",
            sourceListId: "42",
            locationUpdateTime: 2_000
        )

        let forward = LocalPlaylistSyncPolicy.deduplicateProviderPlaylists([stale, firstTie, secondTie])
        let reordered = LocalPlaylistSyncPolicy.deduplicateProviderPlaylists([firstTie, secondTie, stale])

        XCTAssertEqual(forward, reordered)
        XCTAssertEqual(forward.first?.id, "a")
        XCTAssertEqual(forward.first?.name, "Second tie")
    }

    func testCrossDeviceDeduplicationRetainsNewestLocalPlaylistID() {
        let olderLocalID = UUID()
        let newestLocalID = UUID()
        let olderLocalCopy = LocalPlaylist(
            id: olderLocalID,
            name: "Older local copy",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            remoteSource: "netease",
            remotePlaylistID: "42",
            lxSyncID: "sync-b",
            isLocalCopy: true
        )
        let newestLocalCopy = LocalPlaylist(
            id: newestLocalID,
            name: "Newest local edit",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 4),
            remoteSource: "netease",
            remotePlaylistID: "42",
            lxSyncID: "sync-z",
            isLocalCopy: true
        )
        let remoteCopies = [
            LXSyncUserPlaylist(
                id: "sync-z",
                name: "Remote newer copy",
                source: "netease",
                sourceListId: "42",
                locationUpdateTime: 3_000,
                iMusicLocalCopy: true
            ),
            LXSyncUserPlaylist(
                id: "sync-b",
                name: "Remote older copy",
                source: "netease",
                sourceListId: "42",
                locationUpdateTime: 2_500,
                iMusicLocalCopy: true
            ),
        ]

        let merged = LocalPlaylistSyncPolicy.mergeAll(
            remoteCopies,
            currentPlaylists: [olderLocalCopy, newestLocalCopy]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, newestLocalID)
        XCTAssertEqual(merged[0].name, "Newest local edit")
        XCTAssertEqual(merged[0].lxSyncID, "sync-b")
    }

    private func track(id: Int, name: String) -> Track {
        Track(
            id: id,
            name: name,
            artists: [ArtistRef(id: 1, name: "Artist")],
            album: AlbumRef(id: 1, name: "Album", picUrl: nil),
            durationMS: 180_000,
            source: "wy"
        )
    }
}
