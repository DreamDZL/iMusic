import Foundation

enum IOSUITestMode {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static let isEnabled = arguments.contains("-imusic-ui-testing")
    static let hasPlayerFixture = isEnabled && arguments.contains("-imusic-ui-player-fixture")
}

#if os(iOS)

/// Starts optional account and source warm-ups without putting a launch page
/// over the library. The home screen owns its own stale-while-revalidate load.
@MainActor
final class IOSStartupCoordinator {
    static let shared = IOSStartupCoordinator()

    private var didStart = false
    private var preloadTasks: [Task<Void, Never>] = []

    private init() {}

    func start(
        player: PlayerService,
        account: AccountStore
    ) {
        guard !didStart else { return }
        didStart = true

        LegacyBackgroundCleanup.clear()
        player.startRuntime()

        guard !IOSUITestMode.isEnabled else { return }

        // These tasks do not gate the first frame or navigation. Network and
        // source initialization continue while the native home page is usable.
        preloadTasks.append(Task { @MainActor in
            await account.bootstrap()
        })
        preloadTasks.append(Task { @MainActor in
            await MusicSessionRefreshCoordinator.shared.refreshIfNeeded()
        })
        preloadTasks.append(Task { @MainActor in
            await LXUserAPIService.shared.ensureSelectedSourceLoaded()
        })
    }
}

/// Removes wallpaper data saved by earlier builds now that custom app/player
/// backgrounds have been removed. The file target is resolved only inside the
/// app's own Application Support directory.
private enum LegacyBackgroundCleanup {
    static func clear() {
        let defaults = UserDefaults.standard
        let pathKey = "moumusic.background.path.v1"
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        if let support {
            let directory = support.appendingPathComponent("MoumusicBackground", isDirectory: true)
            let legacyFile = directory.appendingPathComponent("wallpaper.jpg")
            try? FileManager.default.removeItem(at: legacyFile)
            if let remaining = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ), remaining.isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        [
            pathKey,
            "moumusic.background.data.v1",
            "moumusic.background.blur.v1",
            "moumusic.background.syncPlayer.v1",
            "moumusic.background.syncApp.v1"
        ].forEach { defaults.removeObject(forKey: $0) }
    }
}

#endif
