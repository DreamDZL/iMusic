import UIKit
import XCTest

final class KumoneIOSUITests: XCTestCase {
    @MainActor
    private func assertEventually(
        _ query: XCUIElementQuery,
        count expectedCount: Int,
        timeout: TimeInterval,
        message: String
    ) {
        var lastCount = -1
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                lastCount = query.count
                return lastCount == expectedCount
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            // Record what was there, so a CI failure shows the actual state.
            let matched = query.allElementsBoundByIndex
                .map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }
                .joined(separator: " | ")
            let attachment = XCTAttachment(string: "count \(lastCount): \(matched)")
            attachment.name = "assertEventually-mismatch"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("ASSERT-EVENTUALLY count \(lastCount) of \(expectedCount): \(matched)")
        }
        XCTAssertEqual(result, .completed, "\(message) (last count \(lastCount))")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The deck slides in when revealed; wait for the row to settle instead
    /// of sampling the first animation frame.
    @MainActor
    private func assertSettles(
        _ element: XCUIElement,
        atMidY expected: CGFloat,
        timeout: TimeInterval = 6,
        message: String
    ) {
        var lastMidY: CGFloat?
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                // A snapshot, not `frame`: reading `frame` of an element that
                // vanished between checks is a fatal test error.
                guard let snapshot = try? element.snapshot() else { return false }
                lastMidY = snapshot.frame.midY
                return abs(snapshot.frame.midY - expected) <= 1
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
            "\(message) (expected midY \(expected), last \(lastMidY.map { "\($0)" } ?? "none"))"
        )
    }

    /// The player's dark artwork backdrop must reach the very top and bottom
    /// of the screen. A clip on the safe-area frame once left the status-bar
    /// band and the bottom edge showing the light app behind the player.
    @MainActor
    private func assertPlayerCoversScreenEdges(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Give the zoom-in presentation time to settle on its final frame.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "presentation settles")], timeout: 1.5)
        let screenshot = XCUIScreen.main.screenshot().image
        guard let cgImage = screenshot.cgImage else {
            XCTFail("Could not read the player screenshot", file: file, line: line)
            return
        }
        let scale = CGFloat(cgImage.width) / screenshot.size.width
        // Left edge, clear of the clock text, the Dynamic Island and the
        // white home indicator in the bottom centre.
        let samples: [(String, CGPoint)] = [
            ("top", CGPoint(x: 24, y: 4)),
            ("bottom", CGPoint(x: 24, y: screenshot.size.height - 4))
        ]
        for (edge, point) in samples {
            let luminance = Self.luminance(of: cgImage, x: Int(point.x * scale), y: Int(point.y * scale))
            XCTAssertLessThan(luminance, 0.6,
                              "The player backdrop must cover the \(edge) edge (luminance \(luminance))",
                              file: file, line: line)
        }
    }

    private static func luminance(of image: CGImage, x: Int, y: Int) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Core Graphics is bottom-up: shift the image so pixel (x, y),
            // counted from the top, lands on the context's single pixel.
            context.draw(image, in: CGRect(
                x: -x, y: y - image.height + 1,
                width: image.width, height: image.height
            ))
            return true
        }
        guard drawn else { return 1 }
        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Let a lyric flick finish decelerating so the next tap is a tap, not
    /// a scroll-stop the scroll view swallows.
    @MainActor
    private func waitForScrollToSettle() {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "scroll settles")], timeout: 1.5)
    }

    @MainActor
    func testMainTabsNavigateAndCaptureScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing"]
        app.launch()

        let tabs = app.tabBars.buttons
        let destinations = [
            (tab: "主页", title: "主页"),
            (tab: "新发现", title: "新发现"),
            (tab: "电台", title: "电台"),
            (tab: "资料库", title: "资料库"),
            (tab: "搜索", title: "搜索"),
        ]

        for destination in destinations {
            let button = tabs[destination.tab]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing tab: \(destination.tab)")
            XCTAssertTrue(button.isHittable, "Tab is not tappable: \(destination.tab)")
            if !button.isSelected {
                button.tap()
            }
            XCTAssertTrue(button.isSelected, "Tab \(destination.tab) should be selected")

            let navigationTitle = app.navigationBars[destination.title]
            XCTAssertTrue(
                navigationTitle.waitForExistence(timeout: 20),
                "Tab \(destination.tab) did not show its root navigation title"
            )
            if destination.tab == "搜索" {
                XCTAssertTrue(app.staticTexts["热门搜索"].waitForExistence(timeout: 5),
                              "Search landing shows trending searches")
                XCTAssertFalse(app.staticTexts["快速浏览"].exists,
                               "Search landing no longer shows category tiles")
            }
            if destination.tab == "资料库" {
                XCTAssertTrue(
                    app.staticTexts["我的播放列表"].waitForExistence(timeout: 5),
                    "The library should keep its playlists section visible even when it is empty"
                )
            }
            if destination.tab == "新发现" {
                let topAttachment = XCTAttachment(screenshot: app.screenshot())
                topAttachment.name = "iMusic-新发现-顶部"
                topAttachment.lifetime = .keepAlways
                add(topAttachment)

                XCTAssertTrue(
                    app.staticTexts["按类型浏览"].waitForExistence(timeout: 5),
                    "New Discovery should expose its local genre browser without requiring network content"
                )
                XCTAssertTrue(
                    app.scrollViews["exploreContentScrollView"].waitForExistence(timeout: 5),
                    "New Discovery should expose a stable, accessible content scroll view"
                )
                let mandarinGenre = app.buttons["浏览华语音乐"]
                XCTAssertTrue(mandarinGenre.waitForExistence(timeout: 5))
                XCTAssertTrue(mandarinGenre.isHittable, "The local genre card should be visible at the top")
                mandarinGenre.tap()
                XCTAssertTrue(mandarinGenre.isSelected, "Selecting a genre should update its selected state")
                let genreAttachment = XCTAttachment(screenshot: app.screenshot())
                genreAttachment.name = "iMusic-新发现-类型"
                genreAttachment.lifetime = .keepAlways
                add(genreAttachment)
                continue
            }

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "iMusic-\(destination.tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testLibrarySyncEntryNavigatesFromLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing"]
        app.launch()

        let libraryTab = app.tabBars.buttons["资料库"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 15))
        libraryTab.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 10))

        let syncEntry = app.buttons["librarySyncEntry"]
        XCTAssertTrue(syncEntry.waitForExistence(timeout: 5), "The library should expose its LX sync entry")
        for _ in 0..<2 where !syncEntry.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(syncEntry.isHittable, "The LX sync entry should be reachable with at most two swipes")
        syncEntry.tap()

        XCTAssertTrue(
            app.navigationBars["LX 多设备同步"].waitForExistence(timeout: 10),
            "The library sync entry should open the LX multi-device sync settings page"
        )

        let backButton = app.navigationBars["LX 多设备同步"].buttons["资料库"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "The sync page should provide navigation back to the library")
        backButton.tap()
        XCTAssertTrue(
            app.navigationBars["资料库"].waitForExistence(timeout: 10),
            "Returning from LX sync settings should leave the user on the library tab"
        )
    }

    @MainActor
    func testAccountSyncShowsOnlySelectedChannel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing"]
        app.launch()
        let library = app.tabBars.buttons["资料库"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        app.buttons["更多资料库选项"].tap()
        app.buttons["设置"].tap()
        let accountLink = app.buttons["账号同步"]
        if !accountLink.isHittable { app.swipeUp() }
        XCTAssertTrue(accountLink.waitForExistence(timeout: 5))
        accountLink.tap()
        let picker = app.segmentedControls["accountSyncChannelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["accountLogin-netease"].exists)
        XCTAssertFalse(app.buttons["accountLogin-qq"].exists)
        picker.buttons["QQ 音乐"].tap()
        XCTAssertTrue(app.buttons["accountLogin-qq"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["accountLogin-netease"].exists)
        picker.buttons["网易云"].tap()
        XCTAssertTrue(app.buttons["accountLogin-netease"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["accountLogin-qq"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iMusic-账号同步-渠道切换"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAppleMusicPlayerSongAndLyricsPages() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-imusic-ui-testing",
            "-imusic-ui-player-fixture",
            "-imusic-ui-extended-lyrics-controls",
            // Light app behind the player, so a backdrop that stops short of
            // the screen edges shows up as bright pixels.
            "-settings.appearance", "light"
        ]
        app.launch()

        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let artwork = app.descendants(matching: .any)["nowPlayingArtworkImage"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let bottomControls = app.descendants(matching: .any)["nowPlayingBottomControls"]
        XCTAssertTrue(bottomControls.waitForExistence(timeout: 5), "The bottom playback deck must be available for reveal taps")
        let accessoryControls = app.buttons["showSynchronizedLyrics"]
        XCTAssertTrue(accessoryControls.exists)
        let songAccessoryMidY = accessoryControls.frame.midY
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingTransportControls"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingVolumeControl"].exists)
        assertPlayerCoversScreenEdges(app)

        let songAttachment = XCTAttachment(screenshot: app.screenshot())
        songAttachment.name = "iMusic-AppleMusic-歌曲页"
        songAttachment.lifetime = .keepAlways
        add(songAttachment)

        // The add-to-playlist sheet is a full navigation sheet: title bar,
        // Done and a New Playlist row; it no longer repeats the song.
        app.buttons["更多操作"].firstMatch.tap()
        let addToPlaylist = app.buttons["加入歌单…"]
        XCTAssertTrue(addToPlaylist.waitForExistence(timeout: 5))
        addToPlaylist.tap()
        let sheetBar = app.navigationBars["收藏到歌单"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 5), "Add to playlist must open as a titled sheet")
        XCTAssertTrue(app.buttons["addToPlaylistNewPlaylist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["addToPlaylistSelection"].exists,
                       "The sheet must not repeat the song being saved")
        let sheetAttachment = XCTAttachment(screenshot: app.screenshot())
        sheetAttachment.name = "iMusic-收藏到歌单"
        sheetAttachment.lifetime = .keepAlways
        add(sheetAttachment)
        app.buttons["addToPlaylistDone"].tap()
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(songPage.waitForExistence(timeout: 5))

        app.buttons["showSynchronizedLyrics"].tap()
        let lyricsPage = app.descendants(matching: .any)["appleMusicLyricsPage"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 10))
        let lyricsScroll = app.scrollViews["synchronizedLyricsScrollView"]
        XCTAssertTrue(lyricsScroll.waitForExistence(timeout: 10))
        let transportControls = app.descendants(matching: .any)["lyricsTransportControls"]
        let volumeControl = app.descendants(matching: .any)["lyricsVolumeControl"]
        let initialVisibleControls = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["lyricsTransportControls", "lyricsVolumeControl"])
        )
        let songTransportControls = app.descendants(matching: .any)["nowPlayingTransportControls"]
        // Full-screen lyrics: after the initial auto-hide the whole deck,
        // accessory row included, leaves the screen like the system player.
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 60),
                      "Lyrics transport controls must initially auto-hide")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 60),
                      "Lyrics volume control must initially auto-hide")
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 5),
                      "Full-screen lyrics must hide the bottom accessory row too")
        // Tapping the lower part of the lyrics page brings the deck back.
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        assertEventually(
            initialVisibleControls,
            count: 2,
            timeout: 5,
            message: "Lyrics transport and volume controls must be visible together after reveal"
        )
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5),
                      "Revealing controls must bring the accessory row back")
        assertSettles(accessoryControls, atMidY: songAccessoryMidY,
                      message: "The accessory row must reappear at the song page's position")
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 60),
                      "Lyrics transport controls must be removed from the accessibility tree when hidden")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 60),
                      "Lyrics volume control must be removed from the accessibility tree when hidden")
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 5),
                      "The accessory row must hide again with the controls")

        // Swiping toward the song page's side is the only horizontal swipe
        // that changes page; the opposite direction stays on lyrics.
        lyricsScroll.swipeLeft()
        XCTAssertTrue(lyricsPage.exists, "A left swipe on lyrics must not leave the lyrics page")
        XCTAssertFalse(songTransportControls.exists)
        XCTAssertFalse(transportControls.exists, "Transport controls must remain hidden during lyric browsing")

        lyricsScroll.swipeUp()
        XCTAssertTrue(lyricsPage.exists, "Vertical lyric scrolling must not navigate away from lyrics")
        XCTAssertFalse(transportControls.exists, "Browsing lyrics must not reveal the playback deck")
        waitForScrollToSettle()
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        let revealedPlaybackState = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier IN %@ OR (elementType == %@ AND label == %@) OR (elementType == %@ AND label == %@)",
                ["lyricsTransportControls", "lyricsVolumeControl"],
                NSNumber(value: XCUIElement.ElementType.staticText.rawValue), "0:14",
                NSNumber(value: XCUIElement.ElementType.button.rawValue), "选择播放音质，当前为请求 320 kbps"
            )
        )
        assertEventually(
            revealedPlaybackState,
            count: 4,
            // 2s was too tight on a slow CI simulator (a swipe there took
            // ~10s to settle); the deck itself reveals in well under 1s.
            timeout: 5,
            message: "Revealed playback state must simultaneously contain transport, volume, 0:14, and the current quality button"
        )
        XCTAssertTrue(app.buttons["showSynchronizedLyrics"].exists, "Revealed lyrics need the same bottom toolbar")
        // Start a fresh reveal window for the separate navigation action;
        // inspecting state and navigating are independent timed interactions.
        // Auto-hide and simultaneous playback-state assertions remain above.
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 60),
                      "The playback toolbar must still auto-hide after state inspection")
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5))
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(songTransportControls.waitForExistence(timeout: 5))
        XCTAssertTrue(songPage.waitForExistence(timeout: 5))
        XCTAssertTrue(lyricsPage.waitForNonExistence(timeout: 5))
        // Besides the button, a left swipe on the song page opens lyrics and
        // a right swipe on lyrics returns to the song page.
        artwork.swipeLeft()
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5), "A left swipe on the song page must open lyrics")
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 5))
        lyricsScroll.swipeRight()
        XCTAssertTrue(songPage.waitForExistence(timeout: 5), "A right swipe on lyrics must return to the song page")
        XCTAssertTrue(lyricsPage.waitForNonExistence(timeout: 5))
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5))
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 60),
                      "Lyrics transport controls must auto-hide after returning from the song page")

        let lyricsAttachment = XCTAttachment(screenshot: app.screenshot())
        lyricsAttachment.name = "iMusic-AppleMusic-歌词页"
        lyricsAttachment.lifetime = .keepAlways
        add(lyricsAttachment)

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        var landscapeSamples: [String] = []
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = window.frame
                landscapeSamples.append("\(Date().timeIntervalSince1970): \(frame)")
                return CGFloat(frame.size.width) > CGFloat(frame.size.height)
            },
            object: window
        )
        let landscapeResult = XCTWaiter.wait(for: [landscapeExpectation], timeout: 5)
        if landscapeResult != .completed {
            let geometry = XCTAttachment(string: landscapeSamples.joined(separator: "\n")
                + "\n" + app.debugDescription)
            geometry.name = "player-landscape-window-geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "player-landscape-failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(
            landscapeResult,
            .completed,
            "The app window must become wider than it is tall after rotating to landscape"
        )
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5))
        let landscapeAccessoryMidY = accessoryControls.frame.midY
        accessoryControls.tap()
        XCTAssertTrue(songPage.waitForExistence(timeout: 5))
        XCTAssertEqual(accessoryControls.frame.midY, landscapeAccessoryMidY, accuracy: 1.0,
                       "The accessory row must keep its position in landscape")
        accessoryControls.tap()
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5))
        XCTAssertEqual(accessoryControls.frame.midY, landscapeAccessoryMidY, accuracy: 1.0,
                       "The accessory row must remain fixed on landscape lyrics")
        XCUIDevice.shared.orientation = .portrait
    }

    /// A light rim showed around the player for ~2s after it opened: the zoom
    /// keeps the card rounded and inset while it settles, and the light app
    /// showed around it (before the fix: corners 0.75–0.79 at +0.86s). The
    /// player opens by itself (no tap, so XCUITest never waits for idle)
    /// while the screen is sampled continuously in light appearance. Each
    /// frame logs `EDGE-TIMELINE` luminance; frames are attached.
    @MainActor
    func testPlayerOpeningShowsNoLightRim() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-imusic-ui-testing",
            "-imusic-ui-player-fixture",
            "-imusic-ui-auto-open-player",
            "-settings.appearance", "light"
        ]
        app.launch()

        let first = XCUIScreen.main.screenshot().image
        let size = first.size
        print("EDGE-TIMELINE screen \(Int(size.width))x\(Int(size.height))pt scale \(first.scale)")
        let points: [(String, CGPoint)] = [
            ("cornerTL", CGPoint(x: 6, y: 6)),
            ("cornerTR", CGPoint(x: size.width - 6, y: 6)),
            ("cornerBL", CGPoint(x: 6, y: size.height - 6)),
            ("cornerBR", CGPoint(x: size.width - 6, y: size.height - 6)),
            ("top", CGPoint(x: size.width * 0.25, y: 3)),
            ("left", CGPoint(x: 2, y: size.height * 0.5)),
            ("right", CGPoint(x: size.width - 2, y: size.height * 0.5)),
            ("bottom", CGPoint(x: size.width * 0.25, y: size.height - 2)),
            ("center", CGPoint(x: size.width * 0.5, y: size.height * 0.62))
        ]

        let start = Date()
        var openedAt: TimeInterval?
        var baselineEdges: CGFloat?
        var attachedMarks = Set<Int>()
        var lightEdgeFailures: [String] = []
        while Date().timeIntervalSince(start) < 20 {
            let shot = XCUIScreen.main.screenshot()
            let elapsed = Date().timeIntervalSince(start)
            guard let image = shot.image.cgImage else { continue }
            let scale = CGFloat(image.width) / shot.image.size.width
            let values = points.map { name, point -> (String, CGFloat) in
                (name, Self.luminance(of: image, x: Int(point.x * scale), y: Int(point.y * scale)))
            }
            let line = values.map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: " ")
            // The opening starts with the first frame whose edges differ from
            // the library's (the centre can be dark on either screen).
            let edges = values.dropLast().map(\.1).reduce(0, +) / CGFloat(values.count - 1)
            if baselineEdges == nil { baselineEdges = edges }
            if openedAt == nil, let baselineEdges, abs(edges - baselineEdges) > 0.08 { openedAt = elapsed }
            let sinceOpen = openedAt.map { elapsed - $0 }
            print("EDGE-TIMELINE t=\(String(format: "%.2f", elapsed)) open=\(sinceOpen.map { String(format: "%.2f", $0) } ?? "-") \(line)")
            // Once the zoom is under way, nothing light may show at the edges
            // or corners, settled or not.
            if let sinceOpen, sinceOpen >= 0.4 {
                for (name, value) in values.dropLast() {
                    if value >= 0.55 {
                        lightEdgeFailures.append(
                            "Light \(name) (\(String(format: "%.2f", value))) at +\(String(format: "%.2f", sinceOpen))s after the player opened"
                        )
                    }
                }
            }

            // Attach the opening frame and roughly every 0.5s for 3s after.
            if let sinceOpen {
                let mark = Int((sinceOpen / 0.5).rounded(.down))
                if mark <= 8 && attachedMarks.insert(mark).inserted {
                    let attachment = XCTAttachment(screenshot: shot)
                    attachment.name = "player-open+\(String(format: "%.1f", sinceOpen))s"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                if sinceOpen > 5 { break }
            }
        }
        print("EDGE-TIMELINE openedAt=\(openedAt.map { String(format: "%.2f", $0) } ?? "never")")
        XCTAssertNotNil(openedAt, "The player must open by itself in this test")
        // Keep the same threshold and time window, but finish recording before
        // failing so early light pixels do not discard the settling evidence.
        XCTAssertTrue(lightEdgeFailures.isEmpty, lightEdgeFailures.joined(separator: "\n"))
    }

    /// Check status-bar rendering over the native player cover (light appearance).
    /// Logs the darkest and brightest pixel in the clock area as
    /// `STATUSBAR-EXPERIMENT`; light text over the dark player means max ≫ min
    /// with a dark background. Log-only.
    @MainActor
    func testStatusBarOverPlayerExperiment() throws {
        XCUIDevice.shared.orientation = .portrait
        for name in ["nativeCover"] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-imusic-ui-testing",
                "-imusic-ui-player-fixture",
                "-settings.appearance", "light"
            ]
            app.launch()
            let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
            guard miniPlayer.waitForExistence(timeout: 15) else {
                print("STATUSBAR-EXPERIMENT \(name) no mini player")
                continue
            }
            Self.logClock(name: "\(name)-library")
            miniPlayer.tap()
            _ = app.descendants(matching: .any)["appleMusicSongPage"].waitForExistence(timeout: 10)
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 3)
            Self.logClock(name: "\(name)-player")
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "statusbar-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }

    private static func logClock(name: String) {
        let shot = XCUIScreen.main.screenshot().image
        guard let image = shot.cgImage else { return }
        let scale = CGFloat(image.width) / shot.size.width
        // Clock: left of the Dynamic Island, about 30-110pt across, 14-36pt down.
        var low: CGFloat = 1, high: CGFloat = 0
        var y: CGFloat = 14
        while y <= 36 {
            var x: CGFloat = 30
            while x <= 110 {
                let value = luminance(of: image, x: Int(x * scale), y: Int(y * scale))
                low = min(low, value); high = max(high, value)
                x += 2
            }
            y += 2
        }
        print("STATUSBAR-EXPERIMENT \(name) min=\(String(format: "%.2f", low)) max=\(String(format: "%.2f", high))")
    }

    @MainActor
    func testSongPageGrabberDismissesWithoutLyricsScroll() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()
        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()
        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let grabber = app.descendants(matching: .any)["nowPlayingDismissIndicator"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        print("NATIVE-DISMISS song grabber=\(grabber.frame) page=\(songPage.frame)")
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 560)),
            withVelocity: XCUIGestureVelocity(2400),
            thenHoldForDuration: 0
        )
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 8),
                      "The song-page grabber must close the native player without a tap fallback")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSongPageArtworkDismissesIndependently() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()
        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()
        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let artwork = app.descendants(matching: .any)["nowPlayingArtworkImage"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let start = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 260)),
            withVelocity: XCUIGestureVelocity(2400),
            thenHoldForDuration: 0
        )
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 8),
                      "Artwork must close the native player independently, without a tap fallback")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlayerGrabberTapClosesWithoutDragging() {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()
        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()
        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let grabber = app.descendants(matching: .any)["nowPlayingDismissIndicator"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        grabber.tap()
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 8))
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSongPageSubthresholdPullKeepsPlayerOpenThenFullPullDismisses() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()
        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()
        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let grabber = app.descendants(matching: .any)["nowPlayingDismissIndicator"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let originalMidY = grabber.frame.midY
        let shortStart = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        // A short pull must spring back without closing. The same presentation
        // must still accept the next full pull, without a tap/relaunch fallback.
        shortStart.press(
            forDuration: 0.05,
            thenDragTo: shortStart.withOffset(CGVector(dx: 0, dy: 25)),
            withVelocity: .default,
            thenHoldForDuration: 0
        )
        let unexpectedDismissal = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: songPage
        )
        unexpectedDismissal.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedDismissal], timeout: 1), .completed,
                       "A subthreshold pull must leave the song page visible")
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "player-after-subthreshold-pull"
        attachment.lifetime = .keepAlways
        add(attachment)
        assertSettles(grabber, atMidY: originalMidY,
                      message: "The grabber must remain at its resting position after cancellation")
        XCTAssertTrue(songPage.exists)
        XCTAssertTrue(grabber.isHittable, "The cancelled pull must leave the player interactive")

        // Use the same page, without relaunching, reopening, or tapping close.
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 560)),
            withVelocity: XCUIGestureVelocity(2400),
            thenHoldForDuration: 0
        )
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 8),
                      "A full pull after cancellation must close the native player without a tap fallback")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRepeatedPlayerPageTransitionsAndCollapse() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture",
                               "-imusic-ui-extended-lyrics-controls"]
        app.launch()
        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        let song = app.descendants(matching: .any)["appleMusicSongPage"]
        let lyrics = app.descendants(matching: .any)["appleMusicLyricsPage"]
        let toggle = app.buttons["showSynchronizedLyrics"]
        for cycle in 0..<3 {
            miniPlayer.tap()
            XCTAssertTrue(song.waitForExistence(timeout: 10))
            for change in 0..<3 {
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                toggle.tap()
                XCTAssertTrue(lyrics.waitForExistence(timeout: 8))
                XCTAssertTrue(song.waitForNonExistence(timeout: 5),
                              "The outgoing song page must not remain over lyrics")
                let thumbnail = app.descendants(matching: .any)["lyricsHeaderArtwork"]
                XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
                let thumbnailSettled = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        guard let snapshot = try? thumbnail.snapshot() else { return false }
                        return abs(snapshot.frame.width - 56) <= 2
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [thumbnailSettled], timeout: 5), .completed,
                               "The cover must finish shrinking into the lyrics header")
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "player-cycle-\(cycle)-lyrics-\(change)"
                shot.lifetime = .keepAlways
                add(shot)
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                toggle.tap()
                XCTAssertTrue(song.waitForExistence(timeout: 8))
                XCTAssertTrue(lyrics.waitForNonExistence(timeout: 5),
                              "The outgoing lyrics must not remain over the hero artwork")
                let hero = app.descendants(matching: .any)["nowPlayingArtworkImage"]
                XCTAssertTrue(hero.waitForExistence(timeout: 5))
                let heroSettled = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        guard let snapshot = try? hero.snapshot() else { return false }
                        return snapshot.frame.width > 120
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [heroSettled], timeout: 5), .completed,
                               "The cover must expand back from the lyrics thumbnail")
            }
            let grabber = app.descendants(matching: .any)["nowPlayingDismissIndicator"]
            XCTAssertTrue(grabber.waitForExistence(timeout: 5))
            let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: 420)),
                        withVelocity: XCUIGestureVelocity(1000), thenHoldForDuration: 0)
            XCTAssertTrue(song.waitForNonExistence(timeout: 8))
            XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
            XCTAssertTrue(miniPlayer.isHittable,
                          "Collapsing must restore an interactive mini player on every cycle")
        }
    }

    @MainActor
    func testLyricsControlsAutoHideWithDefaultTiming() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()

        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let accessoryControls = app.buttons["showSynchronizedLyrics"]
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5))

        accessoryControls.tap()
        let lyricsPage = app.descendants(matching: .any)["appleMusicLyricsPage"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 10))
        let lyricsScroll = app.scrollViews["synchronizedLyricsScrollView"]
        XCTAssertTrue(lyricsScroll.waitForExistence(timeout: 10))

        let transportControls = app.descendants(matching: .any)["lyricsTransportControls"]
        let volumeControl = app.descendants(matching: .any)["lyricsVolumeControl"]
        // The real three-second window can finish during XCTest navigation
        // waits. The long interaction test separately verifies visible controls;
        // this default-policy smoke verifies eventual full-screen hiding,
        // that a tap in the lower area restores the row, and pull-to-close.
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 7),
                      "Default lyrics transport controls must eventually auto-hide")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 7),
                      "Default lyrics volume control must eventually auto-hide")
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 5),
                      "Full-screen lyrics must hide the accessory row")
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        // Only presence here: the default 3s auto-hide races a position
        // check. The extended-controls test asserts the fixed position.
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5),
                      "A tap in the lower area must bring the controls back")

        // The grabber and artwork should both reach native dismissal.
        // A tap fallback must not hide a broken drag.
        let grabber = app.descendants(matching: .any)["nowPlayingDismissIndicator"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        // `.fast` is only 750 px/s; a real flick is several times that.
        let flick = XCUIGestureVelocity(2400)
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        print("NATIVE-DISMISS lyrics grabber=\(grabber.frame) page=\(lyricsPage.frame) scroll=\(lyricsScroll.frame)")
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 560)),
            withVelocity: flick,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(lyricsPage.waitForNonExistence(timeout: 8),
                      "The grabber must close the player")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5),
                      "The mini player must be back after dismissing")
        miniPlayer.tap()
        XCTAssertTrue(songPage.waitForExistence(timeout: 8))
        let artwork = app.descendants(matching: .any)["nowPlayingArtworkImage"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let artworkStart = artwork.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        artworkStart.press(
            forDuration: 0.05,
            thenDragTo: artworkStart.withOffset(CGVector(dx: 0, dy: 260)),
            withVelocity: flick,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 8),
                      "Artwork must dismiss using the same drag as the grabber")
    }
}
