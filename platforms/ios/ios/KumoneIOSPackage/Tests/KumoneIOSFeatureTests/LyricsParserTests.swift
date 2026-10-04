import XCTest
@testable import KumoneCore

final class LyricsParserTests: XCTestCase {
    func testActiveLineTracksPlaybackTimeAndSeekBoundaries() {
        let lyrics = LyricsParser.parseLX(
            lyric: "[00:01.000]first line\n[00:02.500]second line"
        )

        XCTAssertNil(lyrics.activeIndex(at: 0.99))
        XCTAssertEqual(lyrics.activeIndex(at: 1.0), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 2.49), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 2.5), 1)
        XCTAssertEqual(lyrics.activeIndex(at: 60), 1)
        XCTAssertNil(lyrics.activeIndex(at: .infinity))
    }

    func testNeteaseYRCUsesProviderWordTimestamps() throws {
        let payload = #"{"lrc":{"lyric":"[00:01.000]hello\n[00:02.000]world"},"yrc":{"lyric":"[1000,900](1000,300,0)hel(1300,300,0)lo\n[2000,600](2000,300,0)world"}}"#
        let response = try JSONDecoder().decode(LyricResponse.self, from: Data(payload.utf8))
        let lyrics = LyricsParser.parse(response)

        XCTAssertEqual(lyrics.lines.map(\.text), ["hello", "world"])
        XCTAssertEqual(lyrics.lines[0].words?.map(\.text), ["hel", "lo"])
        XCTAssertEqual(lyrics.lines[0].words?[0].start ?? .nan, 1.0, accuracy: 0.0001)
        XCTAssertEqual(lyrics.lines[0].words?[1].start ?? .nan, 1.3, accuracy: 0.0001)
        XCTAssertEqual(lyrics.activeIndex(at: 1.9), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 2.0), 1)
    }

    func testLXVerbatimAndQRCFormatsKeepTheirOwnWordTiming() {
        let lxLyrics = LyricsParser.parseLX(
            lyric: "[00:01.000]hello",
            lxlyric: "[00:01.000]<0,300>hel<300,300>lo"
        )
        XCTAssertEqual(lxLyrics.lines.first?.words?.map(\.text), ["hel", "lo"])
        XCTAssertEqual(lxLyrics.lines.first?.words?[1].start ?? .nan, 1.3, accuracy: 0.0001)

        let qrcLyrics = LyricsParser.parseLX(
            lyric: "[1000,1000]hello(1000,300)world(1300,700)"
        )
        XCTAssertEqual(qrcLyrics.lines.first?.words?.map(\.text), ["hello", "world"])
        XCTAssertEqual(qrcLyrics.lines.first?.words?[1].start ?? .nan, 1.3, accuracy: 0.0001)
    }

    func testLXTimedLyricTextAndRunsStayAlignedAfterTrimmingWhitespace() throws {
        let lyrics = LyricsParser.parseLX(
            lyric: "[00:01.000]你好 世界",
            lxlyric: "[00:01.000]<0,300> 你好 <300,300>世界 "
        )
        let line = try XCTUnwrap(lyrics.lines.first)
        let words = try XCTUnwrap(line.words)

        XCTAssertEqual(line.text, "你好 世界")
        XCTAssertEqual(words.map(\.text).joined(), line.text)
        XCTAssertEqual(words[0].start, 1.075, accuracy: 0.0001)
        XCTAssertEqual(words[0].duration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(words[1].duration, 0.2, accuracy: 0.0001)
    }

    func testYRCAndQRCTrimTimedRunEdgesAlongWithDisplayedText() throws {
        let yrcLine = try XCTUnwrap(
            LyricsParser.parseYRC("[1000,900](1000,300,0) 你好 (1300,600,0)世界 ").first
        )
        let qrcLine = try XCTUnwrap(
            LyricsParser.parseQRC("[1000,900] 你好 (1000,300)世界 (1300,600) ").first
        )

        XCTAssertEqual(yrcLine.text, yrcLine.words?.map(\.text).joined())
        XCTAssertEqual(qrcLine.text, qrcLine.words?.map(\.text).joined())
        XCTAssertEqual(yrcLine.words?.first?.start ?? .nan, 1.075, accuracy: 0.0001)
        XCTAssertEqual(qrcLine.words?.first?.start ?? .nan, 1.075, accuracy: 0.0001)
        XCTAssertEqual(yrcLine.words?.last?.duration ?? .nan, 0.4, accuracy: 0.0001)
        XCTAssertEqual(qrcLine.words?.last?.duration ?? .nan, 0.4, accuracy: 0.0001)
    }

    func testWordAndCharacterProgressFollowProviderRunTiming() {
        let word = LyricWord(text: "你好", start: 2, duration: 0.8)

        XCTAssertEqual(word.progress(at: 1.9), 0, accuracy: 0.0001)
        XCTAssertEqual(word.progress(at: 2.0), 0, accuracy: 0.0001)
        XCTAssertEqual(word.progress(at: 2.4), 0.5, accuracy: 0.0001)
        XCTAssertEqual(word.progress(at: 2.8), 1, accuracy: 0.0001)
        XCTAssertEqual(word.progress(at: 3.0), 1, accuracy: 0.0001)

        XCTAssertEqual(word.characterProgress(at: 2.0, characterIndex: 0, characterCount: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(word.characterProgress(at: 2.2, characterIndex: 0, characterCount: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(word.characterProgress(at: 2.2, characterIndex: 1, characterCount: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(word.characterProgress(at: 2.4, characterIndex: 0, characterCount: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(word.characterProgress(at: 2.4, characterIndex: 1, characterCount: 2), 0, accuracy: 0.0001)
        XCTAssertEqual(word.characterProgress(at: 2.8, characterIndex: 1, characterCount: 2), 1, accuracy: 0.0001)
    }

    func testZeroDurationWordSwitchesAtItsTimestampAndInvalidClockDoesNotAdvance() {
        let word = LyricWord(text: "♪", start: 4, duration: 0)
        let invalidDurationWords = [
            LyricWord(text: "nan", start: 4, duration: .nan),
            LyricWord(text: "infinity", start: 4, duration: .infinity),
        ]

        XCTAssertEqual(word.progress(at: 3.99), 0)
        XCTAssertEqual(word.progress(at: 4), 1)
        XCTAssertEqual(word.progress(at: .infinity), 0)
        XCTAssertTrue(invalidDurationWords.allSatisfy { $0.progress(at: 5) == 0 })
    }
}
