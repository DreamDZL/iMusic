import Testing
@testable import KumoneCore

struct SearchRecordingGroupsTests {
    private func track(_ id: Int, _ source: String, title: String = "Test Song", artist: String = "Artist",
                       album: String = "Test Album", duration: Int = 180_000) -> Track {
        Track(id: id, name: title, artists: [ArtistRef(id: 1, name: artist)],
              album: AlbumRef(id: 1, name: album, picUrl: nil), durationMS: duration, source: source)
    }

    @Test func lateProvidersAppendRowsAndKeepOriginalSelection() {
        let first = track(1, "tx")
        let second = track(2, "tx", title: "Another Song")
        let alternate = track(3, "kw", title: "test song", duration: 182_000)
        let late = track(4, "kg", title: "Late Song")
        var groups = SearchRecordingGroups()
        groups.append([first, second])
        groups.append([alternate, late, first])
        #expect(groups.tracks.map(\.playbackKey) == [first, second, late].map(\.playbackKey))
        #expect(groups.alternatives[first.playbackKey]?.map(\.playbackKey) == [alternate.playbackKey])
    }

    @Test func versionArtistAndMissingDurationPreventMerging() {
        let original = track(1, "tx")
        let different = [track(2, "wy", title: "Test Song (Live)"),
                         track(3, "kg", album: "Live at Home"),
                         track(4, "kg", artist: "Cover Artist"),
                         track(5, "kw", duration: 0),
                         track(6, "wy", duration: 190_000)]
        var groups = SearchRecordingGroups()
        groups.append([original] + different)
        #expect(groups.tracks.count == 6)
        #expect(groups.alternatives.isEmpty)
    }

    @Test func ambiguousCandidateRemainsSelectable() {
        let original = track(1, "tx")
        let samePlatformEdition = track(2, "tx", duration: 181_000)
        let candidate = track(3, "wy")
        var groups = SearchRecordingGroups()
        groups.append([original, samePlatformEdition])
        groups.append([candidate])
        #expect(groups.tracks == [original, samePlatformEdition, candidate])
        #expect(groups.alternatives.isEmpty)

        var reversed = SearchRecordingGroups()
        reversed.append([candidate])
        reversed.append([original, samePlatformEdition])
        #expect(reversed.tracks == [candidate, original, samePlatformEdition])
        #expect(reversed.alternatives.isEmpty)
    }
}
