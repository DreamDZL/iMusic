import Foundation

/// One timed word (or short run) inside a verbatim (yrc) lyric line.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }

    /// Progress of this provider-timed lyric run at an AVPlayer clock value.
    /// Keeping the interpolation beside the source timing avoids each view
    /// inventing its own character split or boundary behavior.
    func progress(at time: TimeInterval) -> Double {
        guard time.isFinite, start.isFinite else { return 0 }
        guard duration.isFinite else { return 0 }
        guard duration > 0 else {
            return time >= start ? 1 : 0
        }
        return min(max((time - start) / duration, 0), 1)
    }

    /// Estimated progress for a grapheme cluster within a provider-timed run.
    /// QQ/LX/YRC sources time runs, not every grapheme, so this divides each
    /// run's interval evenly across the visible characters.
    func characterProgress(
        at time: TimeInterval,
        characterIndex: Int,
        characterCount: Int
    ) -> Double {
        guard characterCount > 0,
              characterIndex >= 0,
              characterIndex < characterCount else { return 0 }
        let runProgress = progress(at: time)
        let characterProgress = runProgress * Double(characterCount) - Double(characterIndex)
        return min(max(characterProgress, 0), 1)
    }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Optional Japanese reading segments populated from the system tokenizer.
    /// It stays nil for Latin, kana-only, and non-Japanese lines.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting; nil when only line-level
    /// (lrc) timing is available.
    var words: [LyricWord]?
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?

    var isEmpty: Bool { lines.isEmpty }

    /// Index of the active line for a playback position.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty, time.isFinite else { return nil }
        var low = 0, high = lines.count - 1, result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

enum LyricsParser {
    /// Parses the common LX User API lyric payload without forcing it through
    /// NetEase's response model.  LX sources may return translated or romaji
    /// lines alongside the main LRC body.
    static func parseLX(lyric: String, tlyric: String? = nil,
                        rlyric: String? = nil, lxlyric: String? = nil,
                        yrc: String? = nil) -> ParsedLyrics {
        var result = ParsedLyrics()
        let timedMain = parseLRC(lyric).filter { !$0.text.isEmpty }
        let main = timedMain.isEmpty ? parsePlainText(lyric) : timedMain
        var lines = main.enumerated().map { index, line in
            LyricLine(id: index, time: line.time, text: line.text)
        }

        // Some LX sources expose NetEase-style verbatim lyrics in a separate
        // `yrc` field. Prefer those exact word/run timings over line-level LRC.
        let verbatimLines = [
            parseYRC(yrc),
            parseLXVerbatim(lxlyric),
            parseQRC(yrc),
            parseQRC(lxlyric),
            parseQRC(lyric),
            parseLXVerbatim(yrc),
            parseYRC(lxlyric),
            parseLXVerbatim(lyric),
            parseYRC(lyric),
        ].first(where: { !$0.isEmpty }) ?? []
        if !verbatimLines.isEmpty { lines = verbatimLines }
        lines = timelineOrdered(lines)

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            for index in lines.indices {
                guard let nearest = secondary.min(by: {
                    abs($0.time - lines[index].time) < abs($1.time - lines[index].time)
                }), abs(nearest.time - lines[index].time) < 0.3 else { continue }
                lines[index][keyPath: keyPath] = nearest.text
            }
        }

        merge(tlyric, into: \.translation)
        merge(rlyric ?? lxlyric, into: \.romaji)
        lines = addFurigana(to: lines)
        result.lines = lines
        return result
    }

    /// LX source scripts are not completely consistent: most return LRC,
    /// while some return escaped newlines or an un-timestamped lyric body.
    /// Normalize those forms before parsing so the UI never silently receives
    /// an empty `ParsedLyrics` just because the source omitted LRC timestamps.
    private static func parsePlainText(_ body: String) -> [(time: TimeInterval, text: String)] {
        let normalized = normalize(body)
        guard !normalized.isEmpty else { return [] }
        return normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                // Drop LRC metadata such as [ar:…] when a source has mixed
                // metadata and plain text, but keep ordinary lyric text.
                !(line.hasPrefix("[") && line.contains("]"))
            }
            .enumerated()
            // Plain text has no playback timeline. Keep it visible without
            // inventing timestamps that would immediately jump to its end.
            .map { _, text in (TimeInterval.infinity, text) }
    }

    private static func normalizePreservingWhitespace(_ body: String) -> String {
        body
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\\uFEFF", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    private static func normalize(_ body: String) -> String {
        normalizePreservingWhitespace(body)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses an LRC body into (time, text) pairs. Handles multiple timestamps
    /// per line and both `.` / `:` millisecond separators.
    static func parseLRC(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        var result: [(TimeInterval, String)] = []
        var offset = 0.0
        let timeTag = #/\[(\d+):(\d+)(?:[.:](\d+))?\]/#

        for rawLine in normalize(lrc).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("[offset:"),
               let end = line.firstIndex(of: "]"),
               let milliseconds = Double(line[line.index(line.startIndex, offsetBy: 8)..<end]) {
                offset = milliseconds / 1000
                continue
            }
            let matches = line.matches(of: timeTag)
            guard !matches.isEmpty else { continue }
            guard let lastMatch = matches.last else { continue }
            let content = String(line[lastMatch.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            for match in matches {
                let min = Double(match.output.1) ?? 0
                let sec = Double(match.output.2) ?? 0
                var frac = 0.0
                if let msStr = match.output.3, let ms = Double(msStr) {
                    frac = ms / pow(10, Double(msStr.count))
                }
                result.append((min * 60 + sec + frac + offset, content))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    /// Parses NetEase verbatim `yrc` lyrics: each content line is
    /// `[lineStartMs,lineDurMs](wStartMs,wDurMs,0)word(...)word…`. JSON metadata
    /// (credits) lines at the top don't match the `[num,num]` head and are
    /// skipped.
    static func parseYRC(_ yrc: String?) -> [LyricLine] {
        guard let yrc, !yrc.isEmpty else { return [] }
        let lineTag = #/^\[(\d+),(\d+)\]/#
        let wordTag = #/\((\d+),(\d+),\d+\)/#
        var lines: [LyricLine] = []
        var idx = 0
        for raw in yrc.components(separatedBy: .newlines) {
            // Keep lyric-edge spaces until trimTimedWords can shorten the
            // corresponding timed run instead of silently dropping them.
            let line = String(raw.drop(while: \.isWhitespace))
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            let contentStart = head.range.upperBound
            let content = line[contentStart...]
            let matches = content.matches(of: wordTag)
            var words: [LyricWord] = []
            for (offset, w) in matches.enumerated() {
                let start = (Double(w.output.1) ?? 0) / 1000
                let duration = (Double(w.output.2) ?? 0) / 1000
                let pieceStart = w.range.upperBound
                let pieceEnd = offset + 1 < matches.count
                    ? matches[offset + 1].range.lowerBound
                    : content.endIndex
                let piece = String(content[pieceStart..<pieceEnd])
                words.append(LyricWord(text: piece, start: start, duration: duration))
            }
            let timedWords = trimTimedWords(words)
            let trimmed = timedWords.map(\.text).joined()
            guard !trimmed.isEmpty, !timedWords.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: timedWords))
            idx += 1
        }
        return lines
    }

    /// Parses LX Music's native `lxlyric` format:
    /// `[00:00.000]<0,36>?<36,36>?<50,60>??`.
    /// Word offsets are relative to the line start, unlike NetEase YRC's
    /// absolute word timestamps.
    static func parseLXVerbatim(_ body: String?) -> [LyricLine] {
        guard let body, !body.isEmpty else { return [] }
        let lineTag = #/^\[(\d+):(\d+)(?:[.:](\d+))?\]/#
        let wordTag = #/<(\d+),(\d+)>/#
        var lines: [LyricLine] = []
        var idx = 0

        for raw in normalizePreservingWhitespace(body).components(separatedBy: .newlines) {
            // Preserve trailing lyric whitespace so its run duration is
            // adjusted in proportion to the visible graphemes below.
            let line = String(raw.drop(while: \.isWhitespace))
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let minutes = Double(head.output.1) ?? 0
            let seconds = Double(head.output.2) ?? 0
            let fraction = head.output.3.map { value in
                (Double(value) ?? 0) / pow(10, Double(value.count))
            } ?? 0
            let lineStart = minutes * 60 + seconds + fraction
            let content = line[head.range.upperBound...]
            let matches = content.matches(of: wordTag)
            guard !matches.isEmpty else { continue }

            var words: [LyricWord] = []
            for (offset, match) in matches.enumerated() {
                let start = lineStart + (Double(match.output.1) ?? 0) / 1000
                let duration = (Double(match.output.2) ?? 0) / 1000
                let pieceStart = match.range.upperBound
                let pieceEnd = offset + 1 < matches.count
                    ? matches[offset + 1].range.lowerBound
                    : content.endIndex
                let piece = String(content[pieceStart..<pieceEnd])
                words.append(LyricWord(text: piece, start: start, duration: duration))
            }

            let timedWords = trimTimedWords(words)
            let trimmed = timedWords.map(\.text).joined()
            guard !trimmed.isEmpty, !timedWords.isEmpty else { continue }
            lines.append(LyricLine(id: idx, time: lineStart, text: trimmed, words: timedWords))
            idx += 1
        }
        return lines
    }

    /// Parses QQ Music's plain QRC format after the lyric response is decoded:
    /// `[lineStartMs,lineDurationMs]text(wordStartMs,wordDurationMs)`. QQ may
    /// wrap the payload in an XML `LyricContent` attribute and escape its
    /// contents, so unwrap that form before reading the timed words.
    static func parseQRC(_ input: String?) -> [LyricLine] {
        guard let input, !input.isEmpty else { return [] }
        let body = qrcContent(in: normalize(input))
        let lineTag = #/^\[(\d+),(\d+)\](.*)$/#
        let wordTag = #/(.*?)\((\d+),(\d+)\)/#
        var lines: [LyricLine] = []

        for rawLine in body.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStart = (Double(head.output.1) ?? 0) / 1000
            let content = String(head.output.3)
            let matches = content.matches(of: wordTag)
            guard !matches.isEmpty else { continue }

            var words: [LyricWord] = []
            for match in matches {
                let piece = String(match.output.1)
                let start = (Double(match.output.2) ?? 0) / 1000
                let duration = (Double(match.output.3) ?? 0) / 1000
                guard !piece.isEmpty else { continue }
                words.append(LyricWord(text: piece, start: start, duration: duration))
            }
            let timedWords = trimTimedWords(words)
            let trimmed = timedWords.map(\.text).joined()
            guard !trimmed.isEmpty, !timedWords.isEmpty else { continue }
            lines.append(LyricLine(id: lines.count, time: lineStart, text: trimmed, words: timedWords))
        }
        return lines
    }

    /// Removes only line-edge whitespace from timed pieces, keeping the
    /// concatenated timing text byte-for-byte aligned with `LyricLine.text`.
    /// When a piece is trimmed, its duration is shortened proportionally so
    /// its visible graphemes retain the same relative timing within that run.
    private static func trimTimedWords(_ words: [LyricWord]) -> [LyricWord] {
        var result = words

        while let first = result.first {
            let characters = Array(first.text)
            let leadingWhitespace = characters.prefix(while: \.isWhitespace).count
            guard leadingWhitespace > 0 else { break }
            guard leadingWhitespace < characters.count else {
                result.removeFirst()
                continue
            }
            let remaining = characters.dropFirst(leadingWhitespace)
            let removedFraction = Double(leadingWhitespace) / Double(characters.count)
            let retainedFraction = 1 - removedFraction
            let shiftedStart = first.start + max(first.duration, 0) * removedFraction
            result[0] = LyricWord(
                text: String(remaining),
                start: shiftedStart,
                duration: max(first.duration, 0) * retainedFraction
            )
            break
        }

        while let last = result.last {
            let characters = Array(last.text)
            let trailingWhitespace = characters.reversed().prefix(while: \.isWhitespace).count
            guard trailingWhitespace > 0 else { break }
            guard trailingWhitespace < characters.count else {
                result.removeLast()
                continue
            }
            let retainedCount = characters.count - trailingWhitespace
            let retainedFraction = Double(retainedCount) / Double(characters.count)
            result[result.count - 1] = LyricWord(
                text: String(characters.prefix(retainedCount)),
                start: last.start,
                duration: max(last.duration, 0) * retainedFraction
            )
            break
        }

        return result
    }

    private static func qrcContent(in input: String) -> String {
        let attribute = #/LyricContent\s*=\s*"([^"]*)"/#
        guard let value = input.firstMatch(of: attribute) else { return input }
        return String(value.output.1)
            .replacingOccurrences(of: "&#xA;", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
    }

    static func parse(_ response: LyricResponse, includeVerbatim: Bool = true) -> ParsedLyrics {
        var out = ParsedLyrics()
        out.contributor = response.lyricUser?.nickname
        out.translationContributor = response.transUser?.nickname

        let lrcRaw = response.lrc?.lyric
        let yrcRaw = response.yrc?.lyric
        guard [lrcRaw, yrcRaw]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .contains(where: { !$0.isEmpty }) else { return out }
        var main = lrcRaw.map(parseLRC) ?? []
        if main.isEmpty, let lrcRaw {
            main = parsePlainText(lrcRaw)
        }

        // Instrumental marker handling (mirrors YesPlayMusic).
        let instrumentalMarker = "纯音乐，请欣赏"
        if main.count <= 10, main.contains(where: { $0.text.contains(instrumentalMarker) }) {
            out.isInstrumental = true
            main.removeAll { line in
                line.text.contains(instrumentalMarker)
                    || line.text.range(of: #"^作(词|曲)\s*[:：]"#, options: .regularExpression) != nil
            }
            if main.isEmpty {
                return out
            }
        }
        main.removeAll { $0.text.range(of: #"^作(词|曲)\s*[:：]\s*无$"#, options: .regularExpression) != nil }

        var lines = main.enumerated().map { idx, pair in
            LyricLine(id: idx, time: pair.time, text: pair.text)
        }
        // Prefer verbatim (word-by-word) lines when the song has them.
        if includeVerbatim, let yrcRaw, !yrcRaw.isEmpty {
            let yrcLines = parseYRC(yrcRaw)
            if !yrcLines.isEmpty { lines = yrcLines }
        }
        lines = timelineOrdered(lines)

        func merge(_ body: String?, into keyPath: WritableKeyPath<LyricLine, String?>) {
            guard let body, !body.isEmpty else { return }
            let secondary = parseLRC(body).filter { !$0.text.isEmpty }
            guard !secondary.isEmpty else { return }
            for i in lines.indices {
                // Nearest secondary line within 0.3s: verbatim (yrc) line times
                // can differ from the lrc-based translation/romaji by a few ms.
                var best: (delta: TimeInterval, text: String)?
                for (time, text) in secondary {
                    let delta = abs(time - lines[i].time)
                    if best == nil || delta < best!.delta { best = (delta, text) }
                }
                if let best, best.delta < 0.3 {
                    lines[i][keyPath: keyPath] = best.text
                }
            }
        }

        // Some responses include a partial ytlrc body and a complete tlyric
        // body. Merge both instead of letting the first non-nil field hide
        // translations that exist in the second one.
        merge(response.ytlrc?.lyric, into: \.translation)
        merge(response.tlyric?.lyric, into: \.translation)
        merge(response.yromalrc?.lyric ?? response.romalrc?.lyric, into: \.romaji)

        // Romaji is only meaningful for Japanese lyrics: fill the gaps Netease
        // left, and drop stray annotations on everything else.
        if RomajiTranscriber.isJapanese(lines.map(\.text)) {
            for i in lines.indices where lines[i].romaji == nil {
                lines[i].romaji = RomajiTranscriber.transcribe(lines[i].text)
            }
        } else {
            for i in lines.indices {
                lines[i].romaji = nil
            }
        }

        out.lines = lines
        out.lines = addFurigana(to: out.lines)
        return out
    }

    /// Active-line lookup uses binary search. Provider word-lyrics are usually
    /// ordered, but malformed exports can contain out-of-order timestamps;
    /// normalize once at parse time so playback never jumps to the wrong line.
    private static func timelineOrdered(_ input: [LyricLine]) -> [LyricLine] {
        input.enumerated()
            .sorted {
                if $0.element.time == $1.element.time { return $0.offset < $1.offset }
                return $0.element.time < $1.element.time
            }
            .enumerated()
            .map { index, pair in
                let line = pair.element
                return LyricLine(
                    id: index,
                    time: line.time,
                    text: line.text,
                    translation: line.translation,
                    romaji: line.romaji,
                    furigana: line.furigana,
                    words: line.words
                )
            }
    }

    private static func addFurigana(to input: [LyricLine]) -> [LyricLine] {
        guard !input.isEmpty else { return input }
        var lines = input
        for index in lines.indices where lines[index].furigana == nil {
            lines[index].furigana = Furigana.segments(for: lines[index].text)
        }
        return lines
    }

}
