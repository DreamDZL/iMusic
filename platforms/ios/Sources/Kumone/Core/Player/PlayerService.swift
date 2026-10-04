import AVFoundation
import Foundation

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// User-facing playback modes. The two shuffle variants are kept separate so
/// users can choose either a one-pass random order or a random order that
/// loops when the queue is exhausted.
enum PlaybackMode: String, CaseIterable, Identifiable {
    case sequential
    case repeatAll
    case repeatOne
    case shuffle
    case shuffleRepeat

    var id: Self { self }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
        case .shuffleRepeat: return "随机循环"
        }
    }

    var icon: String {
        switch self {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        case .shuffle, .shuffleRepeat: return "shuffle"
        }
    }

    var shuffleEnabled: Bool { self == .shuffle || self == .shuffleRepeat }

    var repeatMode: RepeatMode {
        switch self {
        case .sequential, .shuffle: return .off
        case .repeatAll, .shuffleRepeat: return .all
        case .repeatOne: return .one
        }
    }

    var next: PlaybackMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Consistent stopped state when a selected track cannot reach playable audio.
/// Keeping the elapsed position lets the user retry after fixing the source.
struct PausedPlaybackState: Equatable {
    let elapsed: TimeInterval
    let nowPlayingRate: Double
    let isPlaying: Bool
    let preservesCurrentItemForRetry: Bool

    init(elapsed: TimeInterval, preservingCurrentItemForRetry: Bool = false) {
        self.elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        nowPlayingRate = 0
        isPlaying = false
        self.preservesCurrentItemForRetry = preservingCurrentItemForRetry
    }
}

enum PlaybackQueuePolicy {
    static func insertionIndex(after currentIndex: Int, queueCount: Int) -> Int {
        min(max(currentIndex + 1, 0), max(queueCount, 0))
    }

    static func activeQueueIndex(
        forUpcomingIndex upcomingIndex: Int,
        playNextCount: Int,
        currentIndex: Int
    ) -> Int? {
        guard upcomingIndex >= playNextCount else { return nil }
        return currentIndex + 1 + upcomingIndex - playNextCount
    }

    static func canonicalQueueIndex(for itemID: String, itemIDs: [String]) -> Int? {
        itemIDs.firstIndex(of: itemID)
    }

    static func canonicalInsertionIndex(
        after currentItemID: String?,
        itemIDs: [String],
        fallbackIndex: Int
    ) -> Int {
        if let currentItemID,
           let currentIndex = itemIDs.firstIndex(of: currentItemID) {
            return currentIndex + 1
        }
        return min(max(fallbackIndex, 0), itemIDs.count)
    }

    static func restoredIndex(
        persistedIndex: Int?,
        currentItemID: String?,
        currentKey: String?,
        currentID: Int?,
        in tracks: [Track],
        itemIDs: [String]
    ) -> Int? {
        if let currentItemID,
           let index = itemIDs.firstIndex(of: currentItemID),
           tracks.indices.contains(index),
           currentKey == nil || tracks[index].playbackKey == currentKey {
            return index
        }
        if let persistedIndex,
           tracks.indices.contains(persistedIndex),
           currentKey == nil || tracks[persistedIndex].playbackKey == currentKey {
            return persistedIndex
        }
        return currentKey.flatMap { key in
            tracks.firstIndex(where: { $0.playbackKey == key })
        } ?? currentID.flatMap { id in
            tracks.firstIndex(where: { $0.id == id })
        }
    }
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

/// Queue state written to disk. The temporary "play next" list is optional
/// so older saved player states still decode without losing the main queue.
struct PersistedPlaybackState: Codable {
    var queue: [Track]
    var queueItemIDs: [String]? = nil
    var shuffledQueue: [Track]? = nil
    var shuffledItemIDs: [String]? = nil
    var playNextItemIDs: [String]? = nil
    var currentIndex: Int? = nil
    var currentItemID: String? = nil
    var currentID: Int?
    var currentKey: String?
    var currentTrack: Track? = nil
    var repeatMode: String
    var shuffle: Bool
    var recentContexts: [PlayContext]?
    var playNextQueue: [Track]? = nil
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Which lyric line is current.
///
/// Every lyric view used to derive this itself, which meant observing the clock
/// and re-rendering on every tick just to discover the line hadn't changed —
/// and for the now-playing page, whose body is the whole immersive layout, that
/// was five full re-evaluations a second. Computing it once here and publishing
/// only on a change turns that into one re-render per lyric line.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int?
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    private var queueItemIDs: [String] = []
    private var shuffledQueueItemIDs: [String] = []
    private var playNextItemIDs: [String] = []
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isResolvingSource = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    /// Resolved request tier when a source does not report actual audio metadata.
    @Published private(set) var requestedQuality: String?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false {
        didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "player.shuffle") }
    }

    var playbackMode: PlaybackMode {
        if shuffleEnabled {
            return repeatMode == .all ? .shuffleRepeat : .shuffle
        }
        switch repeatMode {
        case .off: return .sequential
        case .all: return .repeatAll
        case .one: return .repeatOne
        }
    }
    @Published var volume: Float = 1 {
        didSet {
#if os(iOS)
            // iOS output volume is owned by the system. The visible control
            // is MPVolumeView; keep AVPlayer at unity gain so it cannot cap
            // the system volume behind the user's back.
            engine.volume = 1
#else
            engine.volume = volume
            UserDefaults.standard.set(volume, forKey: "player.volume")
#endif
        }
    }

    /// Playback speed is owned by the player so it is consistent across the
    /// full-screen player, mini-player, CarPlay and interruption resume.
    @Published var playbackRate: Float = 1 {
        didSet {
            let clamped = min(max(playbackRate, 0.5), 2.0)
            if clamped != playbackRate {
                playbackRate = clamped
                return
            }
            UserDefaults.standard.set(Double(playbackRate), forKey: "player.playbackRate")
            guard isPlaying else { return }
            engine.rate = playbackRate
            NowPlayingManager.shared.updateElapsed(progress, rate: Double(playbackRate))
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }
    private var activeQueueItemIDs: [String] {
        shuffleEnabled ? shuffledQueueItemIDs : queueItemIDs
    }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    var currentQuality: AudioQuality { SettingsManager.shared.audioQuality }

    func availableQualitiesForCurrentTrack() async -> [AudioQuality] {
        guard let track = currentTrack else { return [] }
#if os(iOS)
        let names = Set(await LXUserAPIService.shared.availableQualityNames(for: track))
        var seenTypes = Set<String>()
        let available = AudioQuality.allCases.filter {
            names.contains($0.lxType) && seenTypes.insert($0.lxType).inserted
        }
        return available.isEmpty ? [.standard] : available
#else
        return AudioQuality.allCases
#endif
    }

    func selectQuality(_ quality: AudioQuality) {
        guard let track = currentTrack else { return }
        let resumeAt = progress
        SettingsManager.shared.audioQuality = quality
        startPlaying(track, indexUnchanged: true, resumeAt: resumeAt)
    }

    // MARK: - Engine

    private let engine = AVPlayer()

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        guard !isResolvingSource, let item = engine.currentItem else { return progress }
        let t = item.currentTime().seconds
        return t.isFinite ? t : progress
    }
    private var timeObserver: Any?
    private var lyricCursorObserver: Any?
    private var powerStateObservers: [NSObjectProtocol] = []
    private var lastPublishedSystemLyric: String?
    private var isSceneActive = true
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var resolveGeneration = 0
    private var sourceResolutionTask: Task<Void, Never>?
    private var lyricsResolutionTask: Task<Void, Never>?
    private var seekCoordinator = PlaybackSeekCoordinator()
    private var consecutiveFailures = 0
    private var scrobbled = false
    private var startScrobbled = false
#if os(iOS)
    private var audioSessionActive = false
    private var pendingNeteaseTrackIDs: [String: Int] = [:]

#endif
    private var runtimeStarted = false

    private init() {
        engine.actionAtItemEnd = .pause
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
#if os(iOS)
        volume = 1
        engine.volume = 1
#else
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.volume = volume
#endif
        if let storedRate = UserDefaults.standard.object(forKey: "player.playbackRate") as? Double {
            playbackRate = min(max(Float(storedRate), 0.5), 2.0)
        } else {
            playbackRate = 1
        }
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off
        shuffleEnabled = UserDefaults.standard.bool(forKey: "player.shuffle")
    }

    /// Starts the parts of the player that touch system audio and media
    /// services.  Keeping this out of the singleton initializer is important
    /// on iOS: SwiftUI creates shared observable objects while the app scene
    /// is still being brought up, and iOS 27 can terminate an app that calls
    /// into an audio session or remote-command center too early.
    func startRuntime() {
        guard !runtimeStarted else { return }
        runtimeStarted = true

#if os(iOS)
        // Older builds published a custom Live Activity alongside Apple's
        // native Now Playing card. End any activity left by an upgrade and
        // keep the system card as the only lock-screen playback surface.
        if #available(iOS 16.2, *) {
            MoumusicPlaybackActivityManager.shared.endExistingActivities()
        }

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        installTimeObserver()
        observePowerStateChanges()

        statusObservation = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        NowPlayingManager.shared.attach(to: self)
        restoreState()
    }

#if os(iOS)
    /// A deterministic, silent player state for UI tests. It is reachable only
    /// through the explicit UI-test launch argument and never starts playback
    /// or persists the fixture into the user's queue.
    func installUITestFixture() {
        sourceResolutionTask?.cancel()
        lyricsResolutionTask?.cancel()
        resolveGeneration += 1
        engine.pause()
        engine.replaceCurrentItem(with: nil)
        seekCoordinator.invalidate()

        let track = Track(
            id: 27_000_001,
            name: "iMusic 测试曲目",
            artists: [ArtistRef(id: 27_000_002, name: "测试歌手")],
            album: AlbumRef(id: 27_000_003, name: "测试专辑", picUrl: "imusic-test://artwork"),
            durationMS: 180_000,
            source: "wy"
        )
        let lyrics = ParsedLyrics(lines: (0..<14).map { index in
            let start = Double(index * 4)
            let first = "第\(index + 1)句"
            return LyricLine(
                id: index,
                time: start,
                text: "\(first)同步歌词",
                words: [
                    LyricWord(text: first, start: start, duration: 1.2),
                    LyricWord(text: "同步歌词", start: start + 1.2, duration: 1.4),
                ]
            )
        })

        queue = [track]
        queueItemIDs = [UUID().uuidString]
        shuffledQueue = []
        shuffledQueueItemIDs = []
        shuffleEnabled = false
        playNextList = []
        playNextItemIDs = []
        currentIndex = 0
        source = .none
        currentTrack = track
        isPlaying = false
        isBuffering = false
        isResolvingSource = false
        duration = track.duration
        progress = 14
        requestedQuality = "320k"
        servedQuality = nil
        lyricsCursor.activeIndex = lyrics.activeIndex(at: progress)
        self.lyrics = lyrics
        showNowPlaying = false
        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }
#endif

    nonisolated static func playbackTimeObserverInterval(isSceneActive: Bool) -> TimeInterval {
        // Five foreground samples per second move the active lyric line.
        // Per-word highlighting reads AVPlayer's live clock at a separately
        // throttled display cadence, including under Low Power Mode.
        // The lower background cadence avoids unnecessary work while audio
        // continues playing off-screen.
        isSceneActive ? 0.2 : 1.0
    }

    nonisolated static func lyricCursorObserverInterval(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> TimeInterval {
        if thermalState == .critical { return 0.2 }
        if thermalState == .serious { return 0.15 }
        if lowPowerMode || thermalState == .fair { return 0.125 }
        return 0.1
    }

    /// Keep lyric and scrubber updates responsive in the foreground, while
    /// reducing non-audio work during background audio playback.
    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        guard runtimeStarted else { return }
        installTimeObserver()
        installLyricCursorObserver()
    }

    private func observePowerStateChanges() {
        guard powerStateObservers.isEmpty else { return }
        // Read thermal state before registering, matching ProcessInfo's
        // notification contract. RenderingBudget updates its UI cadence from
        // the same notifications; this observer only adjusts lyric sampling.
        _ = ProcessInfo.processInfo.thermalState
        let names: [Notification.Name] = [
            .NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification
        ]
        powerStateObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.installLyricCursorObserver()
                }
            }
        }
    }

    private func installTimeObserver() {
        if let timeObserver {
            engine.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        timeObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(
                seconds: Self.playbackTimeObserverInterval(isSceneActive: isSceneActive),
                preferredTimescale: 600
            ), queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isResolvingSource,
                      let item = self.engine.currentItem else { return }
                let seconds = item.currentTime().seconds
                guard seconds.isFinite else { return }

                // Background audio uses the slower shared observer. In the
                // foreground, a separate lyric-only observer samples at up to
                // 10 Hz without forcing scrubber or metadata publications.
                if !self.isSceneActive {
                    self.updateLyricsCursor(at: seconds)
                }

                // The scrubber does not. Publishing the position every tick
                // re-renders it — and SwiftUI rebuilds the display list for the
                // whole tree each time — to move the thumb a fraction of a
                // pixel. Half a second is still smoother than the eye needs.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(
                        seconds,
                        rate: self.isPlaying ? Double(self.playbackRate) : 0
                    )
                }
            }
        }
    }

    private func installLyricCursorObserver() {
        if let lyricCursorObserver {
            engine.removeTimeObserver(lyricCursorObserver)
            self.lyricCursorObserver = nil
        }
        guard runtimeStarted, isSceneActive,
              lyrics?.lines.contains(where: { $0.time.isFinite }) == true else { return }

        let processInfo = ProcessInfo.processInfo
        let interval = Self.lyricCursorObserverInterval(
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState
        )
        lyricCursorObserver = engine.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, !self.isResolvingSource,
                      let item = self.engine.currentItem else { return }
                let seconds = item.currentTime().seconds
                guard seconds.isFinite else { return }
                self.updateLyricsCursor(at: seconds)
            }
        }
    }

    /// Stop every playback surface when a track cannot start or the queue ends.
    /// Keep the selected track and elapsed position available for retry.
    private func settlePlaybackAsPaused(preservingCurrentItemForRetry: Bool = false) {
        engine.pause()
        snapshotPausedPlaybackPosition()
        let state = PausedPlaybackState(
            elapsed: progress,
            preservingCurrentItemForRetry: preservingCurrentItemForRetry
        )
#if os(iOS)
        deactivateAudioSession()
#endif
        if !state.preservesCurrentItemForRetry {
            itemStatusObservation?.invalidate()
            itemStatusObservation = nil
        }
        progress = state.elapsed
        isPlaying = state.isPlaying
        NowPlayingManager.shared.updateElapsed(state.elapsed, rate: state.nowPlayingRate)
        if state.preservesCurrentItemForRetry {
            // AudioSession activation can fail while the resolved item and its
            // tap are still ready to resume. Clear frozen bars and keep its
            // tap mode and status observation intact.
            AudioSpectrum.shared.reset()
        } else {
            AudioSpectrum.shared.markIdle()
        }
        persistState()
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            audioSessionActive = false
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // The system already silenced us; sync our state and UI.
                engine.pause()
                snapshotPausedPlaybackPosition()
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            guard activateAudioSession() else {
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                return
            }
            engine.play()
            engine.rate = playbackRate
            isPlaying = true
            NowPlayingManager.shared.updateElapsed(progress, rate: Double(playbackRate))
        @unknown default:
            break
        }
    }

    private func activateAudioSession() -> Bool {
        guard !audioSessionActive else { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            audioSessionActive = true
            return true
        } catch {
            print("Failed to activate audio session: \(error)")
            return false
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            audioSessionActive = false
        } catch {
            print("Failed to deactivate audio session: \(error)")
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        queueItemIDs = tracks.map { _ in UUID().uuidString }
        self.source = source
        playNextList.removeAll()
        playNextItemIDs.removeAll()
        // When shuffle is already enabled, starting a playlist should not
        // silently pin the first catalogue item. An explicit `startAt` still
        // wins when the user tapped a particular song.
        let startIndex = track.flatMap { selected in
            tracks.firstIndex(where: { $0.playbackKey == selected.playbackKey })
        } ?? (shuffleEnabled ? tracks.indices.randomElement()! : 0)
        let startTrack = tracks[startIndex]
        let startItemID = queueItemIDs[startIndex]
        if shuffleEnabled {
            reshuffle(keepingItemID: startItemID)
            currentIndex = 0
        } else {
            currentIndex = startIndex
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        if let idx = activeQueue.firstIndex(where: { $0.playbackKey == track.playbackKey }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        playNextItemIDs.append(UUID().uuidString)
        persistState()
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            engine.pause()
            snapshotPausedPlaybackPosition()
#if os(iOS)
            deactivateAudioSession()
#endif
            isPlaying = false
            AudioSpectrum.shared.reset()
        } else if engine.currentItem == nil || engine.currentItem?.status == .failed {
            // A restored session or failed resource needs a fresh URL. Retain
            // the last position so source retries (including quality changes)
            // resume where the user left off.
            startPlaying(track, indexUnchanged: true, resumeAt: progress)
            return
        } else {
#if os(iOS)
            guard activateAudioSession() else {
                ToastCenter.shared.show("无法启用音频会话，请稍后重试")
                settlePlaybackAsPaused(preservingCurrentItemForRetry: true)
                return
            }
#endif
            engine.play()
            engine.rate = playbackRate
            isPlaying = true
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? Double(playbackRate) : 0)
    }

    func pause() {
        if sourceResolutionTask != nil {
            sourceResolutionTask?.cancel()
            sourceResolutionTask = nil
            lyricsResolutionTask?.cancel()
            lyricsResolutionTask = nil
            resolveGeneration += 1
            isResolvingSource = false
        }
        engine.pause()
        snapshotPausedPlaybackPosition()
#if os(iOS)
        deactivateAudioSession()
#endif
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    /// Publishes the precise AVPlayer clock before switching the UI to its
    /// paused, low-frequency progress source.
    private func snapshotPausedPlaybackPosition() {
        guard !isResolvingSource, let item = engine.currentItem else { return }
        let settledPosition = PlaybackPositionPolicy.pauseSnapshot(
            livePosition: item.currentTime().seconds,
            publishedPosition: progress
        )
        progress = settledPosition
        updateLyricsCursor(at: settledPosition)
        NowPlayingManager.shared.updateElapsed(settledPosition, rate: 0)
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// The lead makes a line light up just before it is sung.
    private func updateLyricsCursor(at seconds: TimeInterval) {
        let index = lyrics?.activeIndex(at: seconds)
        if index != lyricsCursor.activeIndex {
            lyricsCursor.activeIndex = index
        }
        let snapshotLyric = index.flatMap { lyrics?.lines[$0].text }
            ?? lyrics?.lines.first?.text
        #if os(iOS)
        if snapshotLyric != lastPublishedSystemLyric {
            lastPublishedSystemLyric = snapshotLyric
            NowPlayingManager.shared.updateCurrentLyric(snapshotLyric)
        }
        #endif
    }

    func refreshLyricsCursor() {
        updateLyricsCursor(at: livePlaybackTime)
    }

    private func publishLyrics(_ parsed: ParsedLyrics, for track: Track, generation: Int) {
        lyrics = parsed
        updateLyricsCursor(at: livePlaybackTime)
        installLyricCursorObserver()

        // Many source adapters provide the original lyrics but omit the
        // translation field. Enrich the already-visible lyrics from a public
        // NetEase metadata match so English/Japanese songs can show a
        // translation when one exists, without delaying first paint.
        guard parsed.lines.contains(where: { $0.translation == nil }) else { return }
        Task { [weak self] in
            await self?.enrichTranslation(for: track, base: parsed, generation: generation)
        }
    }

    private func enrichTranslation(for track: Track, base: ParsedLyrics,
                                   generation: Int) async {
        let source = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        let candidate: Track?
        if ["wy", "netease", "163"].contains(source) {
            candidate = track
        } else {
            candidate = try? await NeteaseAPI.matchingSong(for: track,
                                                           requireDuration: false)
        }
        guard let candidate,
              let response = try? await NeteaseAPI.lyric(id: candidate.id) else { return }
        let metadata = LyricsParser.parse(response, includeVerbatim: false)
        guard !metadata.isEmpty, generation == resolveGeneration else { return }

        var merged = base
        var changed = false
        for index in merged.lines.indices where merged.lines[index].translation == nil {
            guard let nearest = metadata.lines.min(by: {
                abs($0.time - merged.lines[index].time) < abs($1.time - merged.lines[index].time)
            }), abs(nearest.time - merged.lines[index].time) < 0.5,
                  let translation = nearest.translation, !translation.isEmpty else { continue }
            merged.lines[index].translation = translation
            changed = true
        }
        guard changed, generation == resolveGeneration else { return }
        lyrics = merged
    }

    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        let target = seconds.isFinite ? max(0, seconds) : 0
        let itemAvailable = !isResolvingSource && engine.currentItem != nil
        let generation = seekCoordinator.beginSeek(to: target, itemAvailable: itemAvailable)
        progress = target
        updateLyricsCursor(at: target)
        NowPlayingManager.shared.updateElapsed(
            target,
            rate: isPlaying ? Double(playbackRate) : 0
        )

        guard itemAvailable else {
            // Keep a seek made while a source is resolving for the new item.
            // Calling AVPlayer.seek with no current item would silently lose it.
            completion?()
            return
        }

        engine.currentItem?.cancelPendingSeeks()
        engine.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekCoordinator.isCurrent(generation) else {
                    completion?()
                    return
                }

                let actualPosition = self.engine.currentItem?.currentTime().seconds ?? .nan
                let settledPosition = PlaybackPositionPolicy.settledPosition(
                    actualPosition: finished ? actualPosition : .nan,
                    requestedPosition: target
                )
                self.progress = settledPosition
                self.updateLyricsCursor(at: settledPosition)
                NowPlayingManager.shared.updateElapsed(
                    settledPosition,
                    rate: self.isPlaying ? Double(self.playbackRate) : 0
                )

                if finished, self.isPlaying {
                    self.resumePlaybackAfterSeek()
                }
                completion?()
            }
        }
    }

    @discardableResult
    private func resumePlaybackAfterSeek() -> Bool {
#if os(iOS)
        guard activateAudioSession() else {
            ToastCenter.shared.show("无法启用音频会话，请稍后重试")
            settlePlaybackAsPaused(preservingCurrentItemForRetry: true)
            return false
        }
#endif
        engine.play()
        engine.rate = playbackRate
        return true
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        let currentItemID = activeQueueItemIDs.indices.contains(currentIndex)
            ? activeQueueItemIDs[currentIndex]
            : nil
        shuffleEnabled.toggle()
        if shuffleEnabled {
            if currentTrack != nil, let itemID = currentItemID {
                reshuffle(keepingItemID: itemID)
                currentIndex = 0
            } else if !queue.isEmpty {
                // A restored queue can exist before the current item is
                // resolved. Build the shuffled order now instead of leaving
                // `activeQueue` empty until the next play request.
                let entries = Array(zip(queueItemIDs, queue)).shuffled()
                shuffledQueueItemIDs = entries.map { $0.0 }
                shuffledQueue = entries.map { $0.1 }
                currentIndex = -1
            }
        } else {
            if currentTrack != nil {
                currentIndex = currentItemID.flatMap {
                    PlaybackQueuePolicy.canonicalQueueIndex(for: $0, itemIDs: queueItemIDs)
                }
                    ?? queue.firstIndex(where: { $0.playbackKey == currentTrack?.playbackKey })
                    ?? 0
            } else {
                currentIndex = -1
            }
        }
        persistState()
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
    }

    /// Single-button mode cycle for the iOS minimal transport row:
    /// sequential → loop all → loop one → shuffle → sequential.
    func cyclePlaybackMode() {
        guard !isFMMode else { return }
        setPlaybackMode(playbackMode.next)
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        guard !isFMMode else { return }
        if mode.shuffleEnabled != shuffleEnabled {
            toggleShuffle()
        }
        repeatMode = mode.repeatMode
        if !queue.isEmpty { persistState() }
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        guard let index = upcomingTracks.firstIndex(where: { $0.playbackKey == track.playbackKey }) else {
            return
        }
        jumpToUpcoming(at: index)
    }

    func removeFromUpcoming(_ track: Track) {
        guard let index = upcomingTracks.firstIndex(where: { $0.playbackKey == track.playbackKey }) else {
            return
        }
        removeFromUpcoming(at: index)
    }

    func jumpToUpcoming(at upcomingIndex: Int) {
        guard upcomingTracks.indices.contains(upcomingIndex) else { return }
        if upcomingIndex < playNextList.count {
            let track = playNextList[upcomingIndex]
            let itemID = playNextItemIDs[upcomingIndex]
            playNextList.removeSubrange(0...upcomingIndex)
            playNextItemIDs.removeSubrange(0...upcomingIndex)
            playInsertedNextTrack(track, itemID: itemID)
            return
        }
        guard let idx = PlaybackQueuePolicy.activeQueueIndex(
            forUpcomingIndex: upcomingIndex,
            playNextCount: playNextList.count,
            currentIndex: currentIndex
        ), activeQueue.indices.contains(idx) else { return }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    func removeFromUpcoming(at upcomingIndex: Int) {
        guard upcomingTracks.indices.contains(upcomingIndex) else { return }
        if upcomingIndex < playNextList.count {
            playNextList.remove(at: upcomingIndex)
            playNextItemIDs.remove(at: upcomingIndex)
            persistState()
            return
        }

        guard let activeIndex = PlaybackQueuePolicy.activeQueueIndex(
            forUpcomingIndex: upcomingIndex,
            playNextCount: playNextList.count,
            currentIndex: currentIndex
        ), activeQueue.indices.contains(activeIndex) else { return }

        let itemID = activeQueueItemIDs[activeIndex]
        guard let queueIndex = PlaybackQueuePolicy.canonicalQueueIndex(
            for: itemID,
            itemIDs: queueItemIDs
        ) else { return }
        if shuffleEnabled {
            shuffledQueue.remove(at: activeIndex)
            shuffledQueueItemIDs.remove(at: activeIndex)
            queue.remove(at: queueIndex)
            queueItemIDs.remove(at: queueIndex)
        } else {
            queue.remove(at: activeIndex)
            queueItemIDs.remove(at: activeIndex)
            if let shuffledIndex = shuffledQueueItemIDs.firstIndex(of: itemID) {
                shuffledQueue.remove(at: shuffledIndex)
                shuffledQueueItemIDs.remove(at: shuffledIndex)
            }
        }
        persistState()
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
#if os(iOS)
        if SettingsManager.shared.homeRecommendationMode == .lx,
           LXSourceStore.shared.selectedSource == nil {
            ToastCenter.shared.show("请先在设置 → LX 音源中选择一个播放音源")
            return
        }
#endif
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        queueItemIDs = []
        shuffledQueue = []
        shuffledQueueItemIDs = []
        playNextList = []
        playNextItemIDs = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
#if os(iOS)
            guard SettingsManager.shared.homeRecommendationMode != .lx else { return }
#endif
            try? await NeteaseAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
#if os(iOS)
        if SettingsManager.shared.homeRecommendationMode == .lx {
            guard LXSourceStore.shared.selectedSource != nil else {
                ToastCenter.shared.show("请先在设置 → LX 音源中选择一个播放音源")
                return
            }
            if fmUpcoming.isEmpty {
                let platform = SettingsManager.shared.homeRecommendationPlatform
                fmUpcoming = (try? await LXCatalogService.recommendedTracks(platform: platform, limit: 30)) ?? []
            }
            guard !fmUpcoming.isEmpty else {
                ToastCenter.shared.show("LX 漫游暂时没有歌曲，请检查网络或更换推荐平台")
                return
            }
            let track = fmUpcoming.removeFirst()
            startPlaying(track, indexUnchanged: true)
            return
        }
#endif
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await NeteaseAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        startPlaying(track, indexUnchanged: true)
        if fmUpcoming.count < 1 {
            if let more = try? await NeteaseAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            let itemID = playNextItemIDs.removeFirst()
            playInsertedNextTrack(track, itemID: itemID)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
#if os(iOS)
                    deactivateAudioSession()
#endif
                    settlePlaybackAsPaused()
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Promote a temporary "play next" entry into the durable playback queue
    /// before starting it. This keeps navigation and restoration correct once
    /// the inserted song becomes current, including while shuffle is active.
    private func playInsertedNextTrack(_ track: Track, itemID: String) {
        let insertionIndex = PlaybackQueuePolicy.insertionIndex(
            after: currentIndex,
            queueCount: activeQueue.count
        )
        let currentItemID = activeQueueItemIDs.indices.contains(currentIndex)
            ? activeQueueItemIDs[currentIndex]
            : nil
        let canonicalInsertionIndex = PlaybackQueuePolicy.canonicalInsertionIndex(
            after: currentItemID,
            itemIDs: queueItemIDs,
            fallbackIndex: currentIndex + 1
        )
        queue.insert(track, at: canonicalInsertionIndex)
        queueItemIDs.insert(itemID, at: canonicalInsertionIndex)
        if shuffleEnabled {
            shuffledQueue.insert(track, at: min(insertionIndex, shuffledQueue.count))
            shuffledQueueItemIDs.insert(itemID, at: min(insertionIndex, shuffledQueueItemIDs.count))
        }
        currentIndex = insertionIndex
        startPlaying(track, indexUnchanged: true)
    }

    private func handleItemEnded() {
        guard isPlaying else { return }
        scrobbleIfNeeded(completed: true)
        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            seekCoordinator.invalidate()
            engine.replaceCurrentItem(with: nil)
            return
        }
        if repeatMode == .one, !isFMMode, playNextList.isEmpty {
            scrobbled = false
            seek(to: 0)
#if os(iOS)
            guard activateAudioSession() else {
                isPlaying = false
                ToastCenter.shared.show("无法启用音频会话，请稍后重试")
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                return
            }
#endif
            engine.play()
            isPlaying = true
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track, indexUnchanged: Bool = false,
                              resumeAt: TimeInterval? = nil) {
        let track = track.normalizedForLXPlayback()
        isResolvingSource = true
        // Stop and detach the previous item before starting an asynchronous
        // URL/lyric resolution. Otherwise a fast next/previous tap leaves the
        // old AVPlayerItem audible until the new source responds.
        PlaybackItemTransition.prepareForTrackChange(
            player: engine,
            coordinator: &seekCoordinator,
            resumingAt: resumeAt
        )
#if os(iOS)
        deactivateAudioSession()
#endif
        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
            endObserver = nil
        }
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        scrobbleIfNeeded(completed: false)
        currentTrack = track
        LocalPlaylistStore.shared.recordRecent(track)
        progress = seekCoordinator.initialPlaybackPosition
        duration = track.duration
        servedQuality = nil
        requestedQuality = nil
        unblockSource = nil
        isTrial = false
        lyrics = nil
        lastPublishedSystemLyric = nil
        installLyricCursorObserver()
        scrobbled = false
        startScrobbled = false
        isPlaying = true
        lyricsCursor.activeIndex = nil
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        sourceResolutionTask?.cancel()
        lyricsResolutionTask?.cancel()
        resolveGeneration += 1
        let generation = resolveGeneration

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        sourceResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveAndLoad(track, generation: generation)
            if generation == self.resolveGeneration {
                self.sourceResolutionTask = nil
            }
        }
        lyricsResolutionTask = Task { [weak self] in
            guard let self else { return }
            await self.loadLyrics(for: track, generation: generation)
            if generation == self.resolveGeneration {
                self.lyricsResolutionTask = nil
            }
        }
    }

    private func resolveAndLoad(_ track: Track, generation: Int) async {
        defer {
            if generation == resolveGeneration {
                isResolvingSource = false
            }
        }
        let quality = SettingsManager.shared.audioQuality.rawValue
#if os(macOS)
        let isLXCatalogTrack = track.source != nil
#endif
        var resolvedURL: URL?
        var servedByLXQuality: String?
        var resolvedRequestQuality: String?
#if os(macOS)
        var data: SongURLData?
#endif

#if os(iOS)
        // Cached downloads and enabled LX sources are the only iOS audio routes.
        if let local = DownloadManager.shared.record(for: track),
           FileManager.default.fileExists(atPath: local.fileURL.path) {
            resolvedURL = local.fileURL
            servedByLXQuality = local.qualityVerified == true ? local.quality : nil
            resolvedRequestQuality = local.quality
        } else {
            guard !LXSourceStore.shared.playbackSources.isEmpty else {
                guard generation == resolveGeneration else { return }
                ToastCenter.shared.show("请先在设置 → LX 音源中启用第三方音源")
                settlePlaybackAsPaused()
                return
            }
            do {
                var resolved: LXUserAPIService.ResolvedURL?
                var lastError: Error?
                // A signed source URL can expire or fail once while the
                // provider is waking up. Retry the same track once before
                // reporting a playback failure; advancing the queue here
                // would make an intermittent QQ result look like a wrong song.
                for attempt in 0..<2 {
                    guard !Task.isCancelled, generation == resolveGeneration else { return }
                    do {
                        resolved = try await LXUserAPIService.shared.resolveMusicURL(
                            for: track, quality: quality)
                        break
                    } catch {
                        guard generation == resolveGeneration, !Task.isCancelled else { return }
                        lastError = error
                        if attempt == 0 {
                            try? await Task.sleep(for: .milliseconds(350))
                        }
                    }
                }
                guard let resolved else {
                    throw lastError ?? LXUserAPIService.LXError.resolveFailed([])
                }
                resolvedURL = resolved.url
                servedByLXQuality = resolved.qualityIsVerified ? resolved.quality : nil
                resolvedRequestQuality = resolved.quality
            } catch {
                guard generation == resolveGeneration else { return }
                consecutiveFailures += 1
                ToastCenter.shared.show("《\(track.name)》播放失败：\(error.localizedDescription)")
                // A source-level error is not fixed by immediately trying five
                // more queue entries. Keep the current song visible so the user
                // can adjust the source or retry after reading the real error.
                settlePlaybackAsPaused()
                return
            }
        }
#else
        if resolvedURL == nil, !isLXCatalogTrack {
            data = try? await NeteaseAPI.songURL(ids: [track.id], level: quality).first
            if data?.url == nil, quality != AudioQuality.standard.rawValue {
                data = try? await NeteaseAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
            }
            if let urlString = data?.url {
                resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
            }
        }
        guard generation == resolveGeneration else { return }

        // Keep the legacy desktop-only fallback isolated from iOS. iOS must
        // never silently turn a failed source request into a Kuwo URL.
        if resolvedURL == nil || data?.freeTrialInfo != nil, SettingsManager.shared.enableUnblock {
            if let unblocked = await UnblockService.resolve(track) {
                guard generation == resolveGeneration else { return }
                resolvedURL = unblocked.url
                unblockSource = unblocked.source
                data = nil
                ToastCenter.shared.show(String(localized: "已使用第三方音源：\(unblocked.source)"))
            }
        }
#endif

        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            consecutiveFailures += 1
            let reason = track.playability(privilege: nil,
                                           isLoggedIn: AccountStore.shared.isLoggedIn,
                                           vipType: AccountStore.shared.vipType).reason
            ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(reason.map { "：\($0)" } ?? "")"))
            if consecutiveFailures < 5 {
                advanceToNext(userInitiated: false)
            } else {
                settlePlaybackAsPaused()
            }
            return
        }

        consecutiveFailures = 0
#if os(iOS)
        servedQuality = servedByLXQuality
        requestedQuality = resolvedRequestQuality
        NowPlayingManager.shared.updateResolvedQuality(servedQuality, for: track)
#else
        servedQuality = servedByLXQuality ?? data?.level
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }
#endif

        // Resolve the asset's audio track before the item goes live: an audio mix
        // attached after playback starts is silently ignored, so the spectrum tap
        // has to be spliced in here or not at all. Sources that refuse byte-range
        // requests never resolve a track — those play untapped and the UI falls
        // back to its decorative animation.
        let asset = AVURLAsset(url: url)
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        guard generation == resolveGeneration else { return }

        let item = AVPlayerItem(asset: asset)
        if let assetTrack, let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        } else {
            AudioSpectrum.shared.markUntappable()
        }

        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded()
            }
        }
        engine.replaceCurrentItem(with: item)
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            guard observedItem.status == .failed else { return }
            let itemID = ObjectIdentifier(observedItem)
            let reason = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handlePlaybackItemFailure(
                    itemID: itemID, reason: reason, generation: generation
                )
            }
        }
        let seekPosition = seekCoordinator.takePendingPosition()
        if let seekPosition, seekPosition > 0 {
            let initialSeekGeneration = seekCoordinator.beginResolvedItemSeek()
            engine.seek(to: CMTime(seconds: seekPosition, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, finished,
                          generation == self.resolveGeneration,
                          self.seekCoordinator.isCurrent(initialSeekGeneration),
                          self.isPlaying else { return }
                    guard self.resumePlaybackAfterSeek() else { return }
                }
            }
        } else {
#if os(iOS)
            guard activateAudioSession() else {
                ToastCenter.shared.show("无法启用音频会话，请稍后重试")
                settlePlaybackAsPaused(preservingCurrentItemForRetry: true)
                return
            }
#endif
            engine.play()
            engine.rate = playbackRate
        }
        isPlaying = true

        if !startScrobbled {
            startScrobbled = true
#if os(iOS)
            syncListeningStart(track: track, sourceID: source.sourceID)
#else
            let tid = track.id
            let sid = source.sourceID
            Task.detached { await NeteaseAPI.scrobbleStart(trackID: tid, sourceID: sid) }
#endif
        }

        // A local file or signed provider URL may resolve successfully while
        // AVFoundation rejects the actual resource. Check once after playback
        // setup as well as observing later status changes, so a very fast
        // failure cannot leave system playback controls stuck on "playing".
        if item.status == .failed {
            handlePlaybackItemFailure(
                itemID: ObjectIdentifier(item),
                reason: item.error?.localizedDescription,
                generation: generation
            )
        }

#if os(macOS)
        if let time = data?.time, time > 0 {
            duration = TimeInterval(time) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
#endif
    }

    private func handlePlaybackItemFailure(itemID: ObjectIdentifier,
                                           reason: String?,
                                           generation: Int) {
        guard generation == resolveGeneration,
              let currentItem = engine.currentItem,
              ObjectIdentifier(currentItem) == itemID,
              isPlaying else { return }
        ToastCenter.shared.show("音频源无法播放\(reason.map { "：\($0)" } ?? "")")
        settlePlaybackAsPaused()
    }

    /// Resolves the asset's audio track, giving up after `timeout` so a slow or
    /// uncooperative source delays playback no longer than it would today.
    private func loadAudioTrack(from asset: AVURLAsset, timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask {
                try? await asset.loadTracks(withMediaType: .audio).first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func loadLyrics(for track: Track, generation: Int) async {
#if os(iOS)
        let sourceKey = (track.source ?? track.sourceMetadata["source"] ?? "").lowercased()
        if ["wy", "netease", "163"].contains(sourceKey),
           let response = try? await NeteaseAPI.lyric(id: track.id) {
            guard generation == resolveGeneration else { return }
            let parsed = LyricsParser.parse(response)
            if !parsed.isEmpty {
                publishLyrics(parsed, for: track, generation: generation)
                return
            }
        }

        // Prefer the selected LX source's own lyric action. It may expose
        // yrc/lxlyric word timings that the catalogue adapters do not have.
        if !sourceKey.isEmpty,
           LXSourceStore.shared.selectedSource != nil,
           let lx = try? await LXUserAPIService.shared.resolveLyrics(for: track) {
            guard generation == resolveGeneration else { return }
            let parsed = LyricsParser.parseLX(lyric: lx.lyric, tlyric: lx.tlyric,
                                               rlyric: lx.rlyric, lxlyric: lx.lxlyric,
                                               yrc: lx.yrc)
            if !parsed.isEmpty {
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        // Catalogue lyrics are metadata only. Playback is still resolved by
        // the selected LX User API source in resolveAndLoad(_:generation:).
        if !sourceKey.isEmpty,
           let native = try? await LXCatalogService.nativeLyrics(for: track) {
            guard generation == resolveGeneration else { return }
            let parsed = LyricsParser.parseLX(lyric: native.lyric, tlyric: native.tlyric,
                                               rlyric: native.rlyric, lxlyric: native.lxlyric)
            if !parsed.isEmpty {
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        // If this platform has no lyric endpoint or no result, search every
        // supported catalogue platform by metadata. IDs are never reused
        // across platforms, so a matched track is required before fetching.
        let fallbackPlatforms = ["tx", "wy", "kw", "kg", "mg"]
        for platform in fallbackPlatforms where platform != sourceKey {
            guard let matched = await LXCatalogService.matchingTrack(track, on: platform),
                  let native = try? await LXCatalogService.nativeLyrics(for: matched) else {
                continue
            }
            let parsed = LyricsParser.parseLX(lyric: native.lyric,
                                               tlyric: native.tlyric,
                                               rlyric: native.rlyric,
                                               lxlyric: native.lxlyric)
            if !parsed.isEmpty {
                guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        // LX catalogue IDs are platform-specific. If the selected source has
        // no lyric implementation, use a public NetEase catalogue match only
        // for lyric metadata; audio still comes exclusively from LX.
        if !sourceKey.isEmpty {
            if let candidate = try? await NeteaseAPI.matchingSong(for: track),
               let response = try? await NeteaseAPI.lyric(id: candidate.id) {
                let parsed = LyricsParser.parse(response, includeVerbatim: false)
                if !parsed.isEmpty {
                    guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
                }
            }
        }

        // Do not leave the lyric panel in a permanent loading state when no
        // provider has lyrics for this track.
        guard generation == resolveGeneration else { return }
        lyrics = ParsedLyrics()
        updateLyricsCursor(at: progress)
        return
#else

        // LX song IDs belong to their own platform and must not be sent
        // directly to NetEase. For an LX result, search NetEase by metadata
        // only as a lyric fallback when the imported source has no lyric
        // action or returned an unusable body.
        let response: LyricResponse?
        if track.source == nil {
            response = try? await NeteaseAPI.lyric(id: track.id)
        } else {
            response = nil
        }
        guard generation == resolveGeneration else { return }
        if let response {
            let parsed = LyricsParser.parse(response)
            if !parsed.isEmpty {
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

#if os(iOS)
        // LX Mobile's built-in catalogue adapters own online lyrics. The
        // imported User API normally exposes only `musicUrl`, so asking it
        // for `lyric` cannot work for kw/kg/tx/mg sources.
        if track.source != nil,
           let native = try? await LXCatalogService.nativeLyrics(for: track) {
            let parsed = LyricsParser.parseLX(lyric: native.lyric,
                                               tlyric: native.tlyric,
                                               rlyric: native.rlyric,
                                               lxlyric: native.lxlyric)
            if !parsed.isEmpty {
                guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
            }
        }

        if track.source != nil {
            if let candidate = try? await NeteaseAPI.matchingSong(for: track),
               let response = try? await NeteaseAPI.lyric(id: candidate.id) {
                let parsed = LyricsParser.parse(response)
                if !parsed.isEmpty {
                    guard generation == resolveGeneration else { return }
               publishLyrics(parsed, for: track, generation: generation)
               return
                }
            }
        }
#endif

#endif

        guard generation == resolveGeneration else { return }
        // A completed lookup should render an empty state instead of leaving
        // the lyric panel in an infinite loading spinner.
        lyrics = ParsedLyrics()
        updateLyricsCursor(at: progress)
    }

    // MARK: - Scrobble

#if os(iOS)
    private func neteaseTrackID(for track: Track) async -> Int? {
        if track.source == nil && track.sourceMetadata["source"] == nil {
            return track.id
        }
        let matched = try? await NeteaseAPI.matchingSong(
            for: track, limit: 12, requireDuration: false
        )
        return matched?.id
    }

    private func syncListeningStart(track: Track, sourceID: Int) {
        // Listening history only needs the NetEase auth cookie. Requiring the
        // profile here made a temporary account/profile request failure look
        // like a logged-out account and silently skipped the sync.
        guard NeteaseClient.shared.isLoggedIn else { return }
        let key = track.playbackKey
        Task { [weak self] in
            guard let trackID = await self?.neteaseTrackID(for: track) else { return }
            // Keep the match available immediately. A very short track or a
            // fast user skip can finish before the startplay request returns.
            self?.pendingNeteaseTrackIDs[key] = trackID
            // This is an account history event only. The actual audio URL was
            // already resolved through the selected LX User API source.
            for attempt in 0..<3 {
                if await NeteaseAPI.scrobbleStart(trackID: trackID, sourceID: sourceID) {
                    guard !Task.isCancelled else { return }
                    return
                }
                guard attempt < 2, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
        }
    }

    private func syncListeningFinish(track: Track, sourceID: Int, seconds: Int) {
        guard seconds > 0 else { return }
        guard NeteaseClient.shared.isLoggedIn else {
            ListeningSyncStore.shared.recordFailure()
            return
        }
        let key = track.playbackKey
        let knownID = pendingNeteaseTrackIDs[key]
        Task { [weak self] in
            let trackID: Int?
            if let knownID {
                trackID = knownID
            } else {
                trackID = await self?.neteaseTrackID(for: track)
            }
            guard let trackID else {
                ListeningSyncStore.shared.recordFailure()
                return
            }

            // A failed request must not be presented as a successful local
            // sync. Retry transient cookie/network/API failures before giving
            // up; the next track can still use its own independent event.
            for attempt in 0..<3 {
                if await NeteaseAPI.scrobbleFinish(trackID: trackID,
                                                   sourceID: sourceID,
                                                   seconds: seconds) {
                    guard !Task.isCancelled else { return }
                    ListeningSyncStore.shared.record(seconds: seconds)
                    self?.pendingNeteaseTrackIDs.removeValue(forKey: key)
                    return
                }
                if attempt == 0 {
                    await NeteaseAPI.refreshLogin()
                }
                guard attempt < 2, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }

            guard !Task.isCancelled else { return }
            ListeningSyncStore.shared.recordFailure()
            ToastCenter.shared.show("网易云听歌时长同步失败，本次未计入同步时长")
        }
    }
#endif

    private func scrobbleIfNeeded(completed: Bool) {
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        // Some LX results omit duration metadata. On completion the AVPlayer
        // progress is still authoritative, so never turn a real listening
        // interval into a zero-second weblog event.
        let seconds = completed ? max(Int(duration), Int(progress)) : Int(progress)
        let sourceID = source.sourceID
#if os(iOS)
        syncListeningFinish(track: track, sourceID: sourceID, seconds: seconds)
#else
        Task.detached {
            await NeteaseAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
        }
#endif
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keepingItemID itemID: String) {
        guard let firstIndex = queueItemIDs.firstIndex(of: itemID),
              queue.indices.contains(firstIndex) else { return }
        let first = queue[firstIndex]
        var rest = Array(zip(queueItemIDs, queue))
        rest.remove(at: firstIndex)
        rest.shuffle()
        shuffledQueueItemIDs = [itemID] + rest.map { $0.0 }
        shuffledQueue = [first] + rest.map { $0.1 }
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6
    private static let stateWriteQueue = DispatchQueue(
        label: "com.kumone.player-state-persistence",
        qos: .utility
    )

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // CarPlay uses the same context resolver as the in-app queue. Keeping this
    // internal avoids a second playback pipeline while leaving the method out
    // of the public package API.
    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await NeteaseAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await NeteaseAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            let tracks = try await NeteaseAPI.dailyRecommendSongs()
                .map { $0.normalizedForLXPlayback() }
            return (tracks, .daily)
        case .cloud:
            let songs = try await NeteaseAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await NeteaseAPI.playRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await NeteaseAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await NeteaseAPI.playlistDetail(id: context.id)
            let complete = try await NeteaseAPI.completePlaylistTracks(from: response)
            return (complete.tracks, .playlist(context.id))
        }
    }

    private func persistState() {
        let persistedQueue = Array(queue.prefix(1000))
        let persistedQueueItemIDs = Array(queueItemIDs.prefix(1000))
        let persistedItemIDSet = Set(persistedQueueItemIDs)
        let persistedShuffleEntries = shuffleEnabled
            ? Array(zip(shuffledQueueItemIDs, shuffledQueue)
                .filter { persistedItemIDSet.contains($0.0) }
                .prefix(1000))
            : []
        let persistedShuffledItemIDs: [String]?
        let persistedShuffledQueue: [Track]?
        if shuffleEnabled {
            persistedShuffledItemIDs = persistedShuffleEntries.map { $0.0 }
            persistedShuffledQueue = persistedShuffleEntries.map { $0.1 }
        } else {
            persistedShuffledItemIDs = nil
            persistedShuffledQueue = nil
        }
        let currentItemID = !isFMMode && activeQueueItemIDs.indices.contains(currentIndex)
            ? activeQueueItemIDs[currentIndex]
            : nil
        let persistedActiveItemIDs = shuffleEnabled
            ? (persistedShuffledItemIDs ?? [])
            : persistedQueueItemIDs
        let persistedCurrentIndex = currentItemID.flatMap {
            persistedActiveItemIDs.firstIndex(of: $0)
        }
        let currentItemIsPersisted = persistedCurrentIndex != nil
        let state = PersistedPlaybackState(
            queue: persistedQueue,
            queueItemIDs: persistedQueueItemIDs,
            shuffledQueue: persistedShuffledQueue,
            shuffledItemIDs: persistedShuffledItemIDs,
            playNextItemIDs: Array(playNextItemIDs.prefix(200)),
            currentIndex: persistedCurrentIndex,
            currentItemID: currentItemIsPersisted ? currentItemID : nil,
            currentID: currentItemIsPersisted ? currentTrack?.id : nil,
            currentKey: currentItemIsPersisted ? currentTrack?.playbackKey : nil,
            currentTrack: isFMMode ? nil : currentTrack,
            repeatMode: repeatMode.rawValue,
            shuffle: shuffleEnabled,
            recentContexts: recentContexts,
            playNextQueue: Array(playNextList.prefix(200))
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = Self.stateFileURL
        Self.stateWriteQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PersistedPlaybackState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        let restoredPlayNext = Array((state.playNextQueue ?? []).prefix(200))
        guard !state.queue.isEmpty || state.currentTrack != nil || !restoredPlayNext.isEmpty else { return }
        queue = state.queue
        queueItemIDs = Self.validItemIDs(state.queueItemIDs, count: queue.count)
        playNextList = restoredPlayNext
        playNextItemIDs = Self.validItemIDs(
            state.playNextItemIDs,
            count: playNextList.count
        )
        shuffleEnabled = state.shuffle
        if shuffleEnabled {
            shuffledQueue = state.shuffledQueue ?? queue.shuffled()
            let restoredShuffleIDs = state.shuffledItemIDs
            let restoredShuffleMatchesTracks = restoredShuffleIDs.map { ids in
                zip(ids, shuffledQueue).allSatisfy { entry in
                    let (itemID, track) = entry
                    guard let queueIndex = queueItemIDs.firstIndex(of: itemID),
                          queue.indices.contains(queueIndex) else { return false }
                    return queue[queueIndex].playbackKey == track.playbackKey
                }
            } ?? false
            if let restoredShuffleIDs,
               restoredShuffleIDs.count == shuffledQueue.count,
               Set(restoredShuffleIDs) == Set(queueItemIDs),
               Set(restoredShuffleIDs).count == restoredShuffleIDs.count,
               restoredShuffleMatchesTracks {
                shuffledQueueItemIDs = restoredShuffleIDs
            } else {
                shuffledQueueItemIDs = Self.rebuildItemIDs(
                    for: shuffledQueue,
                    queue: queue,
                    queueItemIDs: queueItemIDs
                )
            }
        }
        let restoredIndex = PlaybackQueuePolicy.restoredIndex(
            persistedIndex: state.currentIndex,
            currentItemID: state.currentItemID,
            currentKey: state.currentKey,
            currentID: state.currentID,
            in: activeQueue,
            itemIDs: activeQueueItemIDs
        )
        let restoredTrack = restoredIndex.map { activeQueue[$0] } ?? state.currentTrack
        if let restoredTrack {
            currentIndex = restoredIndex ?? -1
            currentTrack = restoredTrack
            duration = restoredTrack.duration
            NowPlayingManager.shared.updateMetadata(for: restoredTrack, duration: duration)
            Task {
                await loadLyrics(for: restoredTrack, generation: resolveGeneration)
            }
        }
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }

    private static func validItemIDs(_ values: [String]?, count: Int) -> [String] {
        guard let values,
              values.count == count,
              Set(values).count == count else {
            return (0..<count).map { _ in UUID().uuidString }
        }
        return values
    }

    private static func rebuildItemIDs(
        for orderedTracks: [Track],
        queue: [Track],
        queueItemIDs: [String]
    ) -> [String] {
        var candidates: [String: [String]] = [:]
        for (track, itemID) in zip(queue, queueItemIDs) {
            candidates[track.playbackKey, default: []].append(itemID)
        }
        var consumed: [String: Int] = [:]
        return orderedTracks.map { track in
            let key = track.playbackKey
            let occurrence = consumed[key, default: 0]
            consumed[key] = occurrence + 1
            return candidates[key].flatMap { $0.indices.contains(occurrence) ? $0[occurrence] : nil }
                ?? UUID().uuidString
        }
    }
}
