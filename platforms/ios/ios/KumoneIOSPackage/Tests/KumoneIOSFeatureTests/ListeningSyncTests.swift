import Foundation
import Testing
@testable import KumoneCore

@Test func listeningSyncRequiresMoreThanAQuickSkip() {
    var playback = ListeningPlayback()
    playback.sample(position: 0, uptime: 0, rate: 1, isPlaying: true)
    playback.sample(position: 8, uptime: 8, rate: 1, isPlaying: true)
    #expect(!playback.qualifiesForSync(trackDuration: 180))
    #expect(playback.qualifiesForSync(trackDuration: 16))
    #expect(!playback.qualifiesForSync(trackDuration: 0))
    playback.sample(position: 30, uptime: 30, rate: 1, isPlaying: true)
    #expect(playback.qualifiesForSync(trackDuration: 180))
}
@Suite struct ListeningSyncTests {
    @Test func measuresElapsedAudioAcrossPauseBufferAndSeeks() {
        var playback = ListeningPlayback()
        playback.sample(position: 0, uptime: 0, rate: 1, isPlaying: true)
        playback.sample(position: 2, uptime: 2, rate: 1, isPlaying: false)
        playback.sample(position: 2, uptime: 300, rate: 1, isPlaying: false)
        playback.sample(position: 2, uptime: 310, rate: 1, isPlaying: true)
        playback.sample(position: 4, uptime: 312, rate: 1, isPlaying: true)
        playback.discontinuity()
        playback.sample(position: 160, uptime: 313, rate: 2, isPlaying: true)
        playback.sample(position: 164, uptime: 315, rate: 2, isPlaying: true)
        playback.discontinuity()
        playback.sample(position: 1, uptime: 316, rate: 0.5, isPlaying: true)
        playback.sample(position: 2, uptime: 318, rate: 0.5, isPlaying: false)
        #expect(playback.reportableSeconds == 8)
    }

    @Test func clockJumpsAndStallsDoNotAddListeningTime() {
        var playback = ListeningPlayback()
        playback.sample(position: 10, uptime: 1, rate: 1, isPlaying: true)
        playback.sample(position: 70, uptime: 2, rate: 1, isPlaying: true)
        playback.sample(position: 70, uptime: 9, rate: 1, isPlaying: true)
        playback.sample(position: 8, uptime: 10, rate: 1, isPlaying: true)
        #expect(playback.reportableSeconds == 0)
        playback.sample(position: 9, uptime: 11, rate: 1, isPlaying: false)
        playback.sample(position: 9, uptime: 12, rate: 1, isPlaying: false)
        #expect(playback.reportableSeconds == 1)
        #expect(ListeningPlayback().id != playback.id)
    }

    @Test func foreignIDsRequireAUniqueTitleArtistAndDurationMatch() {
        let foreign = makeTrack(40, title: "Ｓong", artists: ["One", "Two"], source: "tx")
        let identity = ListeningTrackIdentity(track: foreign)
        #expect(identity.neteaseID == nil)
        let match = makeTrack(41, title: "Song", artists: ["Two", "one"], duration: 181_000)
        let partialArtists = makeTrack(42, title: "Song", artists: ["One"])
        let live = makeTrack(43, title: "Song (Live)", artists: ["One", "Two"])
        let otherLength = makeTrack(44, title: "Song", artists: ["One", "Two"], duration: 190_000)
        let unknownLength = makeTrack(45, title: "Song", artists: ["One", "Two"], duration: 0)
        let noArtists = makeTrack(46, title: "Song", artists: [])
        let mismatches = [partialArtists, live, otherLength, unknownLength, noArtists]
        #expect(identity.uniqueMatch(in: mismatches) == nil)
        #expect(identity.uniqueMatch(in: mismatches + [match, match]) == 41)
        #expect(identity.uniqueMatch(in: [match, makeTrack(47, title: "Song", artists: ["One", "Two"])]) == nil)
    }

    @Test func nativeIDsAndObservedDurationAreKept() {
        let native = ListeningTrackIdentity(track: makeTrack(40, source: "netease"))
        #expect(native.neteaseID == 40)
        #expect(ListeningTrackIdentity(track: makeTrack(41)).neteaseID == 41)
        let foreign = makeTrack(50, duration: 0, source: "kg")
        #expect(ListeningTrackIdentity(track: foreign, observedDuration: 180).durationMS == 180_000)
        #expect(ListeningTrackIdentity(track: foreign, observedDuration: .infinity).durationMS == 0)
    }

    @Test func albumOnlyLiveAndRemixMarkersMustMatch() {
        let live = makeTrack(10, source: "kw", album: "巡回演唱会")
        let studio = makeTrack(11, album: "Original Album")
        let remix = makeTrack(12, album: "Remix Edition")
        let otherLive = makeTrack(13, album: "Live Tour")
        let identity = ListeningTrackIdentity(track: live)
        #expect(identity.uniqueMatch(in: [studio, remix]) == nil)
        #expect(identity.uniqueMatch(in: [studio, remix, otherLive]) == 13)
        #expect(ListeningTrackIdentity(track: studio).uniqueMatch(in: [otherLive]) == nil)
    }

    @Test func versionMarkersInAnyAliasOrTranslatedSubtitleMatter() throws {
        let json = #"{"id":10,"name":"Song","ar":[{"id":1,"name":"One"}],"al":{"id":1,"name":"Album"},"dt":180000,"alia":["Alternate name","Acoustic"],"tns":["重制"]}"#
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8)).withSource("kg")
        let identity = ListeningTrackIdentity(track: track)
        #expect(identity.versions == ["acoustic", "remaster"])
        #expect(identity.uniqueMatch(in: [makeTrack(11, album: "Acoustic Collection")]) == nil)
        #expect(identity.uniqueMatch(in: [makeTrack(12, album: "Acoustic Remaster")]) == 12)
    }

    @Test func queueSurvivesRestartAndSeparatesAccounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ListeningSyncFiles(directory: directory)
        var pending = makeEvent()
        var queue = try files.load(accountID: 11)
        queue.pending = [pending]
        queue.complete(pending, result: .retryable, now: Date(timeIntervalSince1970: 100))
        pending = try #require(queue.pending.first)
        #expect(pending.retryAfter == Date(timeIntervalSince1970: 115))

        var interrupted = makeEvent()
        interrupted.inFlight = true
        queue.pending.append(interrupted)
        try files.save(queue, accountID: 11)
        #expect(try files.load(accountID: 22).pending.isEmpty)

        var loaded = try files.load(accountID: 11)
        loaded.recoverInterruptedSubmissions()
        loaded.recoverInterruptedSubmissions()
        #expect(loaded.pending == [pending])
        #expect(loaded.uncertainCount == 1)
        #expect(loaded.acceptedCount == 0)
    }

    @Test func onlyConfirmedResultsCountAndRepeatedCompletionIsHarmless() {
        var queue = ListeningSyncQueue()
        let uncertain = makeEvent()
        let confirmed = makeEvent()
        let unmatched = makeEvent()
        queue.pending = [uncertain, confirmed, unmatched]
        let date = Date(timeIntervalSince1970: 1_000)

        queue.complete(uncertain, result: .uncertain, now: date)
        queue.complete(confirmed, result: .accepted, now: date)
        queue.complete(confirmed, result: .accepted, now: date)
        queue.markUnmatched(unmatched)
        #expect(queue.pending.isEmpty)
        #expect(queue.uncertainCount == 1)
        #expect(queue.unmatchedCount == 1)
        #expect(queue.acceptedCount == 1)
        #expect(queue.acceptedSeconds == confirmed.seconds)
        #expect(queue.lastSuccess?.date == date)
        #expect(queue.lastSuccess?.title == confirmed.track.title)
    }

    @Test func onlyPreDeliveryTransportErrorsAreRetryable() {
        #expect(ListeningSubmissionResult.transportFailure(URLError(.notConnectedToInternet)) == .retryable)
        #expect(ListeningSubmissionResult.transportFailure(URLError(.cannotFindHost)) == .retryable)
        #expect(ListeningSubmissionResult.transportFailure(URLError(.timedOut)) == .uncertain)
        #expect(ListeningSubmissionResult.transportFailure(URLError(.networkConnectionLost)) == .uncertain)
        #expect(ListeningSubmissionResult.transportFailure(URLError(.cancelled)) == .uncertain)
    }

#if os(iOS)
    @Test func offlineOwnerRequiresMatchingCredentialAndValidAccountID() {
        #expect(AccountStore.boundListeningAccountID("123:tokenDigest", tokenDigest: "tokenDigest") == 123)
        #expect(AccountStore.boundListeningAccountID("123:otherDigest", tokenDigest: "tokenDigest") == nil)
        #expect(AccountStore.boundListeningAccountID("0:tokenDigest", tokenDigest: "tokenDigest") == nil)
    }
#endif

    @Test func fmHistoryDeDuplicatesTracksAcrossBatchesUntilSessionEnds() {
        var history = PersonalFMTrackHistory()
        let first = makeTrack(11)
        let alias = first.withSource("163")
        let second = makeTrack(12, source: "wy")
        #expect(history.unseen([first, alias]).map(\.id) == [11])
        #expect(history.unseen([alias, second, second]).map(\.id) == [12])
        #expect(history.unseen([first, second]).isEmpty)
        var nextSession = PersonalFMTrackHistory()
        #expect(nextSession.unseen([first]).map(\.id) == [11])
    }

    private func makeEvent() -> ListeningSyncEvent {
        ListeningSyncEvent(id: UUID(), track: ListeningTrackIdentity(track: makeTrack(1)),
                           sourceID: 0, seconds: 42)
    }

    private func makeTrack(_ id: Int, title: String = "Song", artists: [String] = ["One"],
                           duration: Int = 180_000, source: String? = nil, album: String = "Album") -> Track {
        Track(id: id, name: title, artists: artists.enumerated().map { index, name in
            ArtistRef(id: index + 1, name: name)
        }, album: AlbumRef(id: 0, name: album, picUrl: nil), durationMS: duration, source: source)
    }
}
